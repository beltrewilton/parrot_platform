defmodule ParrotMedia.WsBidirectional.Connector do
  @moduledoc """
  GenServer for managing bidirectional WebSocket audio connections.

  WsBidirectionalConnector handles audio streaming to/from external AI services
  (e.g., OpenAI Realtime, ElevenLabs) with support for:
  - Bidirectional audio (outbound: caller -> AI, inbound: AI -> caller)
  - Direction-specific muting
  - Audio buffering during temporary disconnections
  - Connection lifecycle management
  - Reconnection handling
  - Telemetry and statistics

  ## Starting a Connection

      {:ok, config} = Config.new(
        connection_id: "ai_connection_1",
        url: "wss://api.openai.com/v1/realtime",
        headers: [{"Authorization", "Bearer \#{api_key}"}],
        callback_module: MyApp.AIHandler
      )

      {:ok, pid} = Connector.start_link(config)

  ## Sending Audio (Outbound: Caller -> AI)

      # From a Membrane Sink or directly:
      Connector.send_audio(pid, audio_binary)

      # Or via connection_id lookup:
      Connector.send_audio("ai_connection_1", audio_binary)

  ## Receiving Audio (Inbound: AI -> Caller)

  Register a source process to receive inbound audio:

      Connector.register_source(pid, membrane_source_pid)

  The source will receive `{:ws_audio, binary_data}` messages.

  ## Mute/Unmute

      Connector.mute(pid, :outbound)   # Stop sending caller audio to AI
      Connector.unmute(pid, :outbound) # Resume sending caller audio to AI
      Connector.mute(pid, :inbound)    # Stop forwarding AI audio to caller
      Connector.unmute(pid, :inbound)  # Resume forwarding AI audio to caller

  ## Disconnecting

      Connector.disconnect(pid)
      # or
      Connector.disconnect("ai_connection_1")

  ## State Structure

  The internal state tracks:
  - `config` - Connection configuration
  - `conn_pid` - WebSocket connection process PID
  - `connection_state` - Current state (:connecting, :connected, :disconnected, etc.)
  - `outbound_muted` / `inbound_muted` - Direction mute flags
  - `frames_sent` / `frames_received` / `frames_dropped` - Statistics
  - `reconnect_count` - Number of reconnection attempts
  - `buffer` / `buffer_size` - Outbound audio buffer during disconnection
  - `connected_at` - Timestamp of successful connection
  - `source_pid` - Registered source for inbound audio
  - `callback_state` - State passed to callback module
  """

  use GenServer
  require Logger

  alias ParrotMedia.WsBidirectional.Config
  alias ParrotMedia.WsBidirectional.Connection

  @type connection_ref :: pid() | String.t()

  # Registry for bidirectional connection lookup
  @registry ParrotMedia.BidirectionalRegistry

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a bidirectional WebSocket connector.

  ## Parameters

  - `config` - `WsBidirectional.Config` struct with connection settings

  ## Returns

  - `{:ok, pid}` - Connector started successfully
  - `{:error, reason}` - Failed to start
  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    case Config.validate(config) do
      :ok ->
        # Check if already registered before starting to avoid exit signal propagation
        case Registry.lookup(@registry, {:bidirectional, config.connection_id}) do
          [{pid, _}] ->
            {:error, {:already_registered, pid}}

          [] ->
            GenServer.start_link(__MODULE__, config)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Returns a child specification for starting under a supervisor.
  """
  def child_spec(%Config{} = config) do
    %{
      id: {__MODULE__, config.connection_id},
      start: {__MODULE__, :start_link, [config]},
      restart: :transient
    }
  end

  @doc """
  Disconnect and stop the connector.

  ## Parameters

  - `connection_ref` - PID or connection_id string

  ## Returns

  - `:ok` - Connector stopped
  - `{:error, :not_found}` - Connector not found
  """
  @spec disconnect(connection_ref()) :: :ok | {:error, :not_found}
  def disconnect(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :disconnect)
    else
      {:error, :not_found}
    end
  end

  def disconnect(connection_id) when is_binary(connection_id) do
    case whereis(connection_id) do
      {:ok, pid} -> disconnect(pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Look up a connector by connection_id.

  ## Returns

  - `{:ok, pid}` - Connector found
  - `{:error, :not_found}` - No connector with this ID
  """
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(connection_id) when is_binary(connection_id) do
    case Registry.lookup(@registry, {:bidirectional, connection_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Send an audio frame to the WebSocket (outbound: caller -> AI).

  ## Parameters

  - `connection_ref` - PID or connection_id string
  - `audio_data` - Binary audio data

  ## Returns

  - `:ok` - Frame queued/sent
  - `{:error, :not_found}` - Connector not found
  - `{:error, :muted}` - Outbound is muted
  """
  @spec send_audio(connection_ref(), binary()) ::
          :ok | {:error, :not_found | :muted}
  def send_audio(pid, audio_data) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:send_audio, audio_data})
    else
      {:error, :not_found}
    end
  end

  def send_audio(connection_id, audio_data) when is_binary(connection_id) do
    case whereis(connection_id) do
      {:ok, pid} -> send_audio(pid, audio_data)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Send a text/JSON message to the WebSocket.

  ## Parameters

  - `connection_ref` - PID or connection_id string
  - `message` - Text message (typically JSON)

  ## Returns

  - `:ok` - Message sent
  - `{:error, :not_found}` - Connector not found
  """
  @spec send_message(connection_ref(), String.t()) ::
          :ok | {:error, :not_found}
  def send_message(pid, message) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:send_message, message})
    else
      {:error, :not_found}
    end
  end

  def send_message(connection_id, message) when is_binary(connection_id) do
    case whereis(connection_id) do
      {:ok, pid} -> send_message(pid, message)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Register a process to receive inbound audio.

  The registered source will receive `{:ws_audio, binary_data}` messages.

  ## Parameters

  - `connection_ref` - PID or connection_id string
  - `source_pid` - PID to receive audio messages

  ## Returns

  - `:ok` - Source registered
  - `{:error, :not_found}` - Connector not found
  """
  @spec register_source(connection_ref(), pid()) ::
          :ok | {:error, :not_found}
  def register_source(pid, source_pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:register_source, source_pid})
      :ok
    else
      {:error, :not_found}
    end
  end

  def register_source(connection_id, source_pid) when is_binary(connection_id) do
    case whereis(connection_id) do
      {:ok, pid} -> register_source(pid, source_pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Mute audio in a specific direction.

  - `:outbound` - Stop sending caller audio to AI
  - `:inbound` - Stop forwarding AI audio to caller

  ## Parameters

  - `connection_ref` - PID or connection_id string
  - `direction` - `:outbound` or `:inbound`

  ## Returns

  - `:ok` - Muted successfully
  - `{:error, :not_found}` - Connector not found
  """
  @spec mute(connection_ref(), :outbound | :inbound) ::
          :ok | {:error, :not_found}
  def mute(pid, direction) when is_pid(pid) and direction in [:outbound, :inbound] do
    if Process.alive?(pid) do
      GenServer.call(pid, {:mute, direction})
    else
      {:error, :not_found}
    end
  end

  def mute(connection_id, direction)
      when is_binary(connection_id) and direction in [:outbound, :inbound] do
    case whereis(connection_id) do
      {:ok, pid} -> mute(pid, direction)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Unmute audio in a specific direction.

  ## Parameters

  - `connection_ref` - PID or connection_id string
  - `direction` - `:outbound` or `:inbound`

  ## Returns

  - `:ok` - Unmuted successfully
  - `{:error, :not_found}` - Connector not found
  """
  @spec unmute(connection_ref(), :outbound | :inbound) ::
          :ok | {:error, :not_found}
  def unmute(pid, direction) when is_pid(pid) and direction in [:outbound, :inbound] do
    if Process.alive?(pid) do
      GenServer.call(pid, {:unmute, direction})
    else
      {:error, :not_found}
    end
  end

  def unmute(connection_id, direction)
      when is_binary(connection_id) and direction in [:outbound, :inbound] do
    case whereis(connection_id) do
      {:ok, pid} -> unmute(pid, direction)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Get current connector status.

  ## Returns

  - `{:ok, status}` - Current status map
  - `{:error, :not_found}` - Connector not found

  ## Status Fields

  - `:connection_state` - Current connection state
  - `:outbound_muted` - Whether outbound is muted
  - `:inbound_muted` - Whether inbound is muted
  - `:frames_sent` - Total frames sent to WebSocket
  - `:frames_received` - Total frames received from WebSocket
  - `:frames_dropped` - Frames dropped due to backpressure
  - `:reconnect_count` - Number of reconnections
  - `:buffer_size` - Current frames in buffer
  - `:buffer_capacity` - Max buffer size
  - `:connected_at` - When connection was established
  """
  @spec status(connection_ref()) :: {:ok, map()} | {:error, :not_found}
  def status(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :status)
    else
      {:error, :not_found}
    end
  end

  def status(connection_id) when is_binary(connection_id) do
    case whereis(connection_id) do
      {:ok, pid} -> status(pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    # Register in BidirectionalRegistry
    case Registry.register(@registry, {:bidirectional, config.connection_id}, self()) do
      {:ok, _} ->
        # Start the WebSocket connection
        conn_state = %{
          parent: self(),
          connection_id: config.connection_id
        }

        fresh_opts = [headers: config.headers]

        case Connection.start_link(uri: config.url, state: conn_state, opts: fresh_opts) do
          {:ok, conn_pid} ->
            state = %{
              config: config,
              conn_pid: conn_pid,
              connection_state: :connecting,
              outbound_muted: false,
              inbound_muted: false,
              frames_sent: 0,
              frames_received: 0,
              frames_dropped: 0,
              reconnect_count: 0,
              reconnect_attempt: 0,
              reconnect_timer: nil,
              buffer: :queue.new(),
              buffer_size: 0,
              connected_at: nil,
              source_pid: nil,
              callback_state: config.callback_state,
              user_disconnecting: false
            }

            # Monitor the connection process
            Process.monitor(conn_pid)

            {:ok, state}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, {:already_registered, pid}} ->
        {:stop, {:already_registered, pid}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      connection_state: state.connection_state,
      outbound_muted: state.outbound_muted,
      inbound_muted: state.inbound_muted,
      frames_sent: state.frames_sent,
      frames_received: state.frames_received,
      frames_dropped: state.frames_dropped,
      reconnect_count: state.reconnect_count,
      buffer_size: state.buffer_size,
      buffer_capacity: state.config.buffer_size,
      connected_at: state.connected_at
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call({:send_audio, audio_data}, _from, state) do
    if state.outbound_muted do
      {:reply, {:error, :muted}, state}
    else
      state = do_send_audio(audio_data, state)
      {:reply, :ok, state}
    end
  end

  def handle_call({:send_message, message}, _from, state) do
    if state.connection_state == :connected and state.conn_pid do
      Fresh.send(state.conn_pid, {:text, message})
    end

    {:reply, :ok, state}
  end

  def handle_call({:mute, :outbound}, _from, state) do
    {:reply, :ok, %{state | outbound_muted: true}}
  end

  def handle_call({:mute, :inbound}, _from, state) do
    {:reply, :ok, %{state | inbound_muted: true}}
  end

  def handle_call({:unmute, :outbound}, _from, state) do
    {:reply, :ok, %{state | outbound_muted: false}}
  end

  def handle_call({:unmute, :inbound}, _from, state) do
    {:reply, :ok, %{state | inbound_muted: false}}
  end

  def handle_call(:disconnect, _from, state) do
    # Mark that user is disconnecting to prevent reconnection attempts
    state = %{state | user_disconnecting: true}

    # Cancel any pending reconnect timer
    state = cancel_reconnect_timer(state)

    # Invoke callback for disconnection before stopping
    state = invoke_callback({:disconnected, :user_requested}, state)

    # Stop the connection process
    if state.conn_pid != nil and Process.alive?(state.conn_pid) do
      Process.exit(state.conn_pid, :shutdown)
    end

    {:stop, :normal, :ok, %{state | connection_state: :stopped}}
  end

  @impl true
  def handle_cast({:register_source, source_pid}, state) do
    {:noreply, %{state | source_pid: source_pid}}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:connection_event, :connected}, state) do
    Logger.debug("Connector #{state.config.connection_id}: Connected")

    # Only handle :connected if we're not already connected
    # (avoid race conditions with multiple connection events)
    if state.connection_state == :connected do
      {:noreply, state}
    else
      # Reset reconnect attempt counter on successful connection
      state = %{
        state
        | connection_state: :connected,
          connected_at: DateTime.utc_now(),
          reconnect_attempt: 0
      }

      # Cancel any pending reconnect timer
      state = cancel_reconnect_timer(state)

      # Invoke connected callback
      state = invoke_callback({:connected}, state)

      # Flush any buffered audio
      state = flush_buffer(state)

      {:noreply, state}
    end
  end

  def handle_info({:connection_event, {:disconnected, reason}}, state) do
    Logger.debug("Connector #{state.config.connection_id}: Disconnected - #{inspect(reason)}")

    # Don't start reconnection if user is disconnecting
    if state.user_disconnecting do
      {:noreply, %{state | connection_state: :disconnected}}
    else
      case state.connection_state do
        :connected ->
          # First disconnect - invoke callback and start reconnection
          state = %{state | connection_state: :disconnected}

          # Invoke disconnected callback
          state = invoke_callback({:disconnected, reason}, state)

          # Start reconnection if max_retries > 0
          if state.config.max_retries > 0 do
            state = schedule_reconnect(state)
            {:noreply, state}
          else
            # No retries configured, transition to failed
            state = %{state | connection_state: :failed}
            state = invoke_callback({:failed, :max_retries_exceeded}, state)
            {:noreply, state}
          end

        :reconnecting ->
          # Reconnection attempt failed - schedule another retry
          # (don't invoke disconnected callback again, just schedule next attempt)
          state = schedule_reconnect(state)
          {:noreply, state}

        _other ->
          # In other states (disconnected, failed, etc.), ignore
          {:noreply, state}
      end
    end
  end

  def handle_info({:connection_event, {:reconnecting, _attempt}}, state) do
    # This is sent by Connection module, but we manage reconnection ourselves now
    # Ignore it - we handle reconnection via :reconnect timer
    {:noreply, state}
  end

  def handle_info({:connection_event, {:failed, reason}}, state) do
    Logger.warning("Connector #{state.config.connection_id}: Failed - #{inspect(reason)}")

    state = %{state | connection_state: :failed}

    # Invoke failed callback
    state = invoke_callback({:failed, reason}, state)

    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    # Don't reconnect if user is disconnecting
    if state.user_disconnecting do
      {:noreply, state}
    else
      attempt = state.reconnect_attempt + 1
      max_retries = state.config.max_retries

      Logger.debug(
        "Connector #{state.config.connection_id}: Reconnect attempt #{attempt}/#{max_retries}"
      )

      if attempt > max_retries do
        # Max retries exceeded
        Logger.warning(
          "Connector #{state.config.connection_id}: Max retries (#{max_retries}) exceeded"
        )

        state = %{state | connection_state: :failed, reconnect_timer: nil}
        state = invoke_callback({:failed, :max_retries_exceeded}, state)
        {:noreply, state}
      else
        # Update state and notify callback
        state = %{
          state
          | connection_state: :reconnecting,
            reconnect_attempt: attempt,
            reconnect_count: attempt,
            reconnect_timer: nil
        }

        state = invoke_callback({:reconnecting, attempt}, state)

        # Attempt to reconnect
        conn_state = %{
          parent: self(),
          connection_id: state.config.connection_id
        }

        fresh_opts = [headers: state.config.headers]

        case Connection.start_link(uri: state.config.url, state: conn_state, opts: fresh_opts) do
          {:ok, conn_pid} ->
            Process.monitor(conn_pid)
            {:noreply, %{state | conn_pid: conn_pid}}

          {:error, _reason} ->
            # Connection failed, schedule another retry
            state = schedule_reconnect(state)
            {:noreply, state}
        end
      end
    end
  end

  def handle_info({:connection_event, {:ws_audio, audio_data}}, state) do
    state = %{state | frames_received: state.frames_received + 1}

    # Forward to registered source if not muted
    if not state.inbound_muted and state.source_pid do
      send(state.source_pid, {:ws_audio, audio_data})
    end

    {:noreply, state}
  end

  def handle_info({:connection_event, {:ws_message, data}}, state) do
    # Invoke callback for WebSocket message
    state = invoke_callback({:ws_message, data}, state)

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) when pid == state.conn_pid do
    Logger.debug(
      "Connector #{state.config.connection_id}: Connection process DOWN - #{inspect(reason)}"
    )

    state = %{state | conn_pid: nil}

    case reason do
      :normal ->
        {:noreply, %{state | connection_state: :disconnected}}

      :shutdown ->
        {:noreply, %{state | connection_state: :stopped}}

      {:shutdown, _} ->
        {:noreply, %{state | connection_state: :stopped}}

      _other ->
        # Unexpected termination - handle like a disconnect if not already reconnecting
        if state.user_disconnecting or state.connection_state == :reconnecting do
          {:noreply, %{state | connection_state: :failed}}
        else
          # Simulate a disconnection event to trigger reconnection
          send(self(), {:connection_event, {:disconnected, reason}})
          {:noreply, state}
        end
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp do_send_audio(audio_data, state) do
    case state.connection_state do
      :connected ->
        # Send directly to WebSocket
        if state.conn_pid do
          Fresh.send(state.conn_pid, {:binary, audio_data})
        end

        %{state | frames_sent: state.frames_sent + 1}

      _other ->
        # Buffer the audio
        buffer_audio(audio_data, state)
    end
  end

  defp buffer_audio(audio_data, state) do
    max_buffer_size = state.config.buffer_size
    new_buffer = :queue.in(audio_data, state.buffer)
    new_size = state.buffer_size + 1

    if new_size > max_buffer_size do
      # Drop oldest frame
      {{:value, _dropped}, trimmed_buffer} = :queue.out(new_buffer)

      %{
        state
        | buffer: trimmed_buffer,
          buffer_size: max_buffer_size,
          frames_dropped: state.frames_dropped + 1
      }
    else
      %{state | buffer: new_buffer, buffer_size: new_size}
    end
  end

  defp flush_buffer(state) do
    if :queue.is_empty(state.buffer) do
      state
    else
      # Send all buffered frames
      frames =
        state.buffer
        |> :queue.to_list()

      Enum.each(frames, fn audio_data ->
        if state.conn_pid do
          Fresh.send(state.conn_pid, {:binary, audio_data})
        end
      end)

      frames_flushed = length(frames)

      %{
        state
        | buffer: :queue.new(),
          buffer_size: 0,
          frames_sent: state.frames_sent + frames_flushed
      }
    end
  end

  defp invoke_callback(event, state) do
    case state.config.callback_module do
      nil ->
        state

      callback_module ->
        case callback_module.handle_event(event, state.callback_state) do
          {:ok, new_callback_state} ->
            %{state | callback_state: new_callback_state}

          {:error, _reason} ->
            state
        end
    end
  end

  # Schedule a reconnection attempt with exponential backoff
  defp schedule_reconnect(state) do
    delay = calculate_backoff(state.reconnect_attempt)

    Logger.debug(
      "Connector #{state.config.connection_id}: Scheduling reconnect in #{delay}ms (attempt #{state.reconnect_attempt + 1})"
    )

    timer = Process.send_after(self(), :reconnect, delay)
    %{state | reconnect_timer: timer}
  end

  # Calculate exponential backoff delay
  # Base delay: 300ms, doubles each attempt, max 30 seconds
  # Note: 300ms base delay ensures first reconnect fires after typical test timeouts
  defp calculate_backoff(attempt) do
    base_delay = 300
    max_delay = 30_000
    delay = (base_delay * :math.pow(2, attempt)) |> trunc()
    min(delay, max_delay)
  end

  # Cancel any pending reconnect timer
  defp cancel_reconnect_timer(%{reconnect_timer: nil} = state), do: state

  defp cancel_reconnect_timer(%{reconnect_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | reconnect_timer: nil}
  end
end
