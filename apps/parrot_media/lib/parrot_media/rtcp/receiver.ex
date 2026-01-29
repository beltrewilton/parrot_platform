defmodule ParrotMedia.RTCP.Receiver do
  @moduledoc """
  Receives and processes incoming RTCP packets.

  This GenServer listens on the RTCP socket (RTP port + 1) and processes
  incoming RTCP packets, primarily Receiver Reports. Quality metrics from
  these reports are forwarded to the MOS Calculator.

  ## Usage

      {:ok, receiver} = ParrotMedia.RTCP.Receiver.start_link(
        rtcp_socket: socket,
        session_id: "session-123",
        clock_rate: 8000
      )

  ## RFC References

  - RFC 3550 Section 6: RTCP Control Protocol
  - RFC 3550 Section 6.4.1: RR: Receiver Report
  """

  use GenServer

  require Logger

  alias ParrotMedia.RTCP.Sink

  @default_clock_rate 8000

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts the RTCP receiver process.

  ## Options

  - `:rtcp_socket` - The UDP socket for RTCP (required)
  - `:session_id` - The media session ID (required)
  - `:clock_rate` - RTP clock rate for jitter conversion (default: 8000)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stops the RTCP receiver.
  """
  def stop(receiver) do
    GenServer.stop(receiver)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    rtcp_socket = Keyword.fetch!(opts, :rtcp_socket)
    session_id = Keyword.fetch!(opts, :session_id)
    clock_rate = Keyword.get(opts, :clock_rate, @default_clock_rate)

    # Set socket to active mode to receive packets
    :inet.setopts(rtcp_socket, active: true)

    state = %{
      rtcp_socket: rtcp_socket,
      session_id: session_id,
      clock_rate: clock_rate,
      packets_received: 0
    }

    Logger.debug("[RTCP.Receiver] Started for session #{session_id}")

    {:ok, state}
  end

  @impl true
  def handle_info({:udp, socket, _ip, _port, data}, %{rtcp_socket: socket} = state) do
    case Sink.parse_rtcp(data) do
      {:ok, :no_reports} ->
        # Packet parsed but no RR data to extract
        {:noreply, %{state | packets_received: state.packets_received + 1}}

      {:ok, metrics} ->
        # Metrics extracted, forward to MOS Calculator
        rtcp_metrics = %{
          jitter_ms: metrics.jitter_ms,
          loss_percent: metrics.loss_percent
        }

        # Try to calculate RTT if we have LSR/DLSR
        rtcp_metrics =
          case Sink.calculate_rtt(metrics.lsr, metrics.dlsr) do
            {:ok, nil} -> rtcp_metrics
            {:ok, rtt_ms} -> Map.put(rtcp_metrics, :rtt_ms, rtt_ms)
          end

        Sink.send_to_calculator(state.session_id, rtcp_metrics)

        Logger.debug(
          "[RTCP.Receiver] Session #{state.session_id}: jitter=#{metrics.jitter_ms}ms, loss=#{metrics.loss_percent}%"
        )

        {:noreply, %{state | packets_received: state.packets_received + 1}}

      {:error, reason} ->
        Logger.warning("[RTCP.Receiver] Failed to parse RTCP: #{reason}")
        {:noreply, state}
    end
  end

  def handle_info({:udp_closed, _socket}, state) do
    Logger.debug("[RTCP.Receiver] Socket closed for session #{state.session_id}")
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.warning("[RTCP.Receiver] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.debug(
      "[RTCP.Receiver] Stopping for session #{state.session_id}, received #{state.packets_received} packets"
    )

    :ok
  end
end
