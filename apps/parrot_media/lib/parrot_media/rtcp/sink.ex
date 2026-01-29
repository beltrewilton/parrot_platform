defmodule ParrotMedia.RTCP.Sink do
  @moduledoc """
  RTCP Sink for receiving and processing RTCP packets.

  This module parses incoming RTCP packets (primarily Receiver Reports and
  Sender Reports), extracts quality metrics, and forwards them to the MOS
  Calculator for call quality assessment.

  ## Metrics Extracted

  From RTCP Receiver Reports (RFC 3550 Section 6.4.1):
  - **Fraction Lost**: Packet loss percentage since last report
  - **Jitter**: Interarrival jitter in RTP timestamp units, converted to ms
  - **RTT**: Round-trip time calculated from LSR + DLSR

  ## Usage

  The Sink can be used as a Membrane element in media pipelines:

      |> via_out(:rtcp_output)
      |> child(:rtcp_sink, %ParrotMedia.RTCP.Sink{session_id: session_id})

  ## RFC References

  - RFC 3550 Section 6: RTCP Control Protocol
  - RFC 3550 Section 6.4.1: RR: Receiver Report RTCP Packet
  - RFC 3550 Appendix A.8: Estimating the Round-Trip Time
  """

  require Logger
  import Bitwise

  alias ExRTCP.Packet
  alias ExRTCP.Packet.ReceiverReport
  alias ExRTCP.Packet.SenderReport
  alias ExRTCP.Packet.ReceptionReport

  # Default clock rate for audio codecs
  @default_clock_rate 8000

  @type rtcp_metrics :: %{
          ssrc: non_neg_integer(),
          jitter_ms: float(),
          loss_percent: float(),
          rtt_ms: float() | nil,
          lsr: non_neg_integer(),
          dlsr: non_neg_integer()
        }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Parses an RTCP packet and extracts quality metrics.

  ## Parameters

  - `data` - Raw RTCP packet binary

  ## Returns

  - `{:ok, metrics}` - Parsed metrics from the first reception report
  - `{:ok, :no_reports}` - Packet parsed but contains no reception reports
  - `{:error, :invalid_rtcp}` - Malformed RTCP packet
  - `{:error, :not_rtcp}` - Data is not an RTCP packet (e.g., RTP)

  ## Examples

      iex> {:ok, metrics} = ParrotMedia.RTCP.Sink.parse_rtcp(rtcp_data)
      iex> metrics.jitter_ms
      15.5
  """
  @spec parse_rtcp(binary()) :: {:ok, rtcp_metrics()} | {:ok, :no_reports} | {:error, atom()}
  def parse_rtcp(data) when byte_size(data) < 8 do
    {:error, :invalid_rtcp}
  end

  def parse_rtcp(<<2::2, _::6, pt::8, _rest::binary>>) when pt < 200 do
    # Packet types < 200 are RTP, not RTCP
    {:error, :not_rtcp}
  end

  def parse_rtcp(data) do
    case Packet.decode(data) do
      {:ok, %ReceiverReport{reports: []}} ->
        {:ok, :no_reports}

      {:ok, %ReceiverReport{reports: [report | _]}} ->
        {:ok, extract_metrics(report)}

      {:ok, %SenderReport{reports: []}} ->
        {:ok, :no_reports}

      {:ok, %SenderReport{reports: [report | _]}} ->
        {:ok, extract_metrics(report)}

      {:ok, _other_packet} ->
        # SDES, BYE, etc. - no metrics to extract
        {:ok, :no_reports}

      {:error, :invalid_packet} ->
        {:error, :invalid_rtcp}

      {:error, :unknown_type} ->
        {:error, :invalid_rtcp}
    end
  end

  @doc """
  Converts jitter from RTP timestamp units to milliseconds.

  ## Parameters

  - `jitter` - Jitter value in RTP timestamp units
  - `clock_rate` - RTP clock rate (e.g., 8000 for G.711, 48000 for Opus)

  ## Formula

      jitter_ms = jitter / (clock_rate / 1000)

  ## Examples

      iex> ParrotMedia.RTCP.Sink.convert_jitter(160, 8000)
      20.0
  """
  @spec convert_jitter(non_neg_integer(), pos_integer()) :: float()
  def convert_jitter(0, _clock_rate), do: 0.0

  def convert_jitter(jitter, clock_rate) when clock_rate > 0 do
    jitter / (clock_rate / 1000)
  end

  @doc """
  Calculates round-trip time from LSR and DLSR fields.

  Uses the formula from RFC 3550 Appendix A.8:

      RTT = current_time - LSR - DLSR

  Where:
  - LSR is the middle 32 bits of the NTP timestamp from the last SR
  - DLSR is the delay since last SR in 1/65536 second units

  ## Parameters

  - `lsr` - Last SR timestamp (middle 32 bits of NTP)
  - `dlsr` - Delay since last SR (1/65536 second units)
  - `opts` - Options:
    - `:current_ntp` - Current NTP middle 32 bits (for testing)

  ## Returns

  - `{:ok, rtt_ms}` - RTT in milliseconds
  - `{:ok, nil}` - Cannot calculate RTT (no SR received yet, LSR=0)

  ## Examples

      iex> ParrotMedia.RTCP.Sink.calculate_rtt(0x12345678, 0x00010000)
      {:ok, 150.5}
  """
  @spec calculate_rtt(non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, float() | nil}
  def calculate_rtt(lsr, dlsr, opts \\ [])

  def calculate_rtt(0, _dlsr, _opts), do: {:ok, nil}

  def calculate_rtt(lsr, dlsr, opts) do
    current_ntp =
      case Keyword.get(opts, :current_ntp) do
        nil -> get_current_ntp_mid32()
        ntp -> ntp
      end

    # Calculate time since SR was sent (in 1/65536 second units)
    # LSR is middle 32 bits of NTP, DLSR is in 1/65536 sec units
    # RTT = (current - LSR) - DLSR, all in 1/65536 units
    time_since_sr = current_ntp - lsr

    # Convert to 1/65536 units by shifting
    # NTP middle 32 bits: upper 16 are seconds, lower 16 are fractions
    # We need to treat the difference as 1/65536 units
    rtt_units = time_since_sr - dlsr

    # Convert from 1/65536 seconds to milliseconds
    # 1/65536 sec = 1000/65536 ms ≈ 0.01526 ms
    rtt_ms = max(0.0, rtt_units * 1000 / 65536)

    {:ok, rtt_ms}
  end

  @doc """
  Converts fraction_lost (0-255) to percentage (0-100).

  ## Examples

      iex> ParrotMedia.RTCP.Sink.fraction_lost_to_percent(128)
      50.0

      iex> ParrotMedia.RTCP.Sink.fraction_lost_to_percent(0)
      0.0
  """
  @spec fraction_lost_to_percent(0..255) :: float()
  def fraction_lost_to_percent(fraction) when fraction >= 0 and fraction <= 255 do
    fraction / 256.0 * 100
  end

  @doc """
  Sends RTCP metrics to the MOS Calculator for the given session.

  ## Parameters

  - `session_id` - Media session identifier
  - `metrics` - Map with `:jitter_ms`, `:rtt_ms`, `:loss_percent`

  ## Returns

  - `:ok` - Metrics sent (or no calculator found)
  """
  @spec send_to_calculator(String.t(), map()) :: :ok
  def send_to_calculator(session_id, metrics) do
    case Registry.lookup(ParrotMedia.MOS.Registry, session_id) do
      [{pid, _}] ->
        # Send RTCP metrics to calculator
        # The Calculator will use these for more accurate MOS calculation
        GenServer.cast(pid, {:rtcp_metrics, metrics})
        :ok

      [] ->
        Logger.debug("[RTCP.Sink] No MOS Calculator for session #{session_id}")
        :ok
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp extract_metrics(%ReceptionReport{} = report) do
    %{
      ssrc: report.ssrc,
      jitter_ms: convert_jitter(report.jitter, @default_clock_rate),
      loss_percent: fraction_lost_to_percent(report.fraction_lost),
      lsr: report.last_sr,
      dlsr: report.delay
    }
  end

  defp get_current_ntp_mid32 do
    # Get current time as NTP timestamp middle 32 bits
    # NTP epoch is Jan 1, 1900; Unix epoch is Jan 1, 1970
    # Difference is 2208988800 seconds
    ntp_offset = 2_208_988_800

    {mega, sec, micro} = :os.timestamp()
    unix_sec = mega * 1_000_000 + sec
    ntp_sec = unix_sec + ntp_offset

    # Fractional part (lower 16 bits of middle 32)
    frac = trunc(micro / 1_000_000 * 65536)

    # Middle 32 bits: lower 16 bits of seconds + upper 16 bits of fraction
    ((ntp_sec &&& 0xFFFF) <<< 16) ||| frac
  end
end
