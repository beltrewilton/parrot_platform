defmodule ParrotMedia.WsAudioForker do
  @moduledoc """
  GenServer for forking call audio to WebSocket endpoints.

  WsAudioForker streams audio frames to external AI transcription services
  (Deepgram, AssemblyAI, OpenAI Realtime) with built-in reconnection,
  backpressure handling, and failure isolation.

  ## Starting a Fork

      config = WsAudioForker.Config.new(
        fork_id: "transcription_1",
        url: "wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=16000",
        headers: [{"Authorization", "Token \#{api_key}"}],
        callback_module: MyApp.TranscriptionHandler
      )

      {:ok, pid} = WsAudioForker.start_link(config)

  ## Sending Audio

      # From WsForkSink (Membrane pipeline) or directly:
      WsAudioForker.send_audio(pid, audio_binary)

      # Or via fork_id lookup:
      WsAudioForker.send_audio("transcription_1", audio_binary)

  ## Stopping a Fork

      WsAudioForker.stop("transcription_1")
      # or
      WsAudioForker.stop(pid)

  ## Supervision

  Forkers are designed to be supervised. They handle their own reconnection
  but will terminate on permanent failures (max retries exceeded).

      children = [
        {WsAudioForker, config}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)
  """

  use GenServer
  require Logger

  alias ParrotMedia.WsAudioForker.Config
  alias ParrotMedia.WsAudioForker.Connection

  @type fork_ref :: pid() | String.t()

  @registry ParrotMedia.WsForkerRegistry

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a WebSocket audio forker.

  ## Parameters

  - `config` - `WsAudioForker.Config` struct with fork settings

  ## Returns

  - `{:ok, pid}` - Forker started successfully
  - `{:error, reason}` - Failed to start (invalid config, etc.)

  ## Examples

      config = Config.new(
        fork_id: "my_fork",
        url: "wss://api.deepgram.com/v1/listen",
        headers: [{"Authorization", "Token abc123"}]
      )

      {:ok, pid} = WsAudioForker.start_link(config)
  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    case Config.validate(config) do
      :ok ->
        case GenServer.start_link(__MODULE__, config, name: via_tuple(config.fork_id)) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            # Translate GenServer's error format to our API contract
            {:error, {:already_registered, pid}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns a child specification for starting under a supervisor.
  """
  def child_spec(%Config{} = config) do
    %{
      id: {__MODULE__, config.fork_id},
      start: {__MODULE__, :start_link, [config]},
      restart: :transient
    }
  end

  @doc """
  Stop a forker gracefully.

  Closes the WebSocket connection and terminates the process.

  ## Parameters

  - `fork_ref` - PID or fork_id string

  ## Returns

  - `:ok` - Forker stopped
  - `{:error, :not_found}` - Forker not found
  """
  @spec stop(fork_ref()) :: :ok | {:error, :not_found}
  def stop(fork_ref) when is_pid(fork_ref) do
    if Process.alive?(fork_ref) do
      GenServer.stop(fork_ref, :normal)
    else
      {:error, :not_found}
    end
  end

  def stop(fork_id) when is_binary(fork_id) do
    case whereis(fork_id) do
      {:ok, pid} -> stop(pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Look up a forker by fork_id.

  ## Returns

  - `{:ok, pid}` - Forker found
  - `{:error, :not_found}` - No forker with this ID
  """
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(fork_id) when is_binary(fork_id) do
    case Registry.lookup(@registry, {:ws_forker, fork_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Send an audio frame to the forker.

  Audio is buffered if the WebSocket is temporarily disconnected.
  Oldest frames are dropped if buffer is full.

  ## Parameters

  - `fork_ref` - PID or fork_id string
  - `audio_data` - Binary audio data
  - `opts` - Optional metadata (default: [])

  ## Returns

  - `:ok` - Frame queued/sent
  - `{:error, :not_found}` - Forker not found
  - `{:error, :not_connected}` - Not connected and buffer full

  ## Examples

      WsAudioForker.send_audio(pid, <<audio_bytes::binary>>)
      WsAudioForker.send_audio("fork_1", audio_data, timestamp: 12345)
  """
  @spec send_audio(fork_ref(), binary(), keyword()) ::
          :ok | {:error, :not_found | :not_connected}
  def send_audio(fork_ref, audio_data, opts \\ [])

  def send_audio(fork_ref, audio_data, opts) when is_pid(fork_ref) do
    if Process.alive?(fork_ref) do
      GenServer.cast(fork_ref, {:send_audio, audio_data, opts})
      :ok
    else
      {:error, :not_found}
    end
  end

  def send_audio(fork_id, audio_data, opts) when is_binary(fork_id) do
    case whereis(fork_id) do
      {:ok, pid} -> send_audio(pid, audio_data, opts)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Get current forker status.

  ## Returns

  - `{:ok, status}` - Current status map
  - `{:error, :not_found}` - Forker not found

  ## Status Fields

  - `:connection_state` - `:connected`, `:disconnected`, `:connecting`, `:reconnecting`
  - `:buffer_size` - Current frames in buffer
  - `:buffer_capacity` - Max buffer size
  - `:frames_sent` - Total frames sent to WebSocket
  - `:frames_dropped` - Frames dropped due to backpressure
  - `:reconnect_count` - Number of reconnections
  """
  @spec status(fork_ref()) :: {:ok, map()} | {:error, :not_found}
  def status(fork_ref) when is_pid(fork_ref) do
    if Process.alive?(fork_ref) do
      GenServer.call(fork_ref, :status)
    else
      {:error, :not_found}
    end
  end

  def status(fork_id) when is_binary(fork_id) do
    case whereis(fork_id) do
      {:ok, pid} -> status(pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Check if forker is connected.

  ## Returns

  - `true` - WebSocket is connected
  - `false` - Not connected (disconnected, reconnecting, etc.)
  - `{:error, :not_found}` - Forker not found
  """
  @spec connected?(fork_ref()) :: boolean() | {:error, :not_found}
  def connected?(fork_ref) when is_pid(fork_ref) do
    if Process.alive?(fork_ref) do
      GenServer.call(fork_ref, :connected?)
    else
      {:error, :not_found}
    end
  end

  def connected?(fork_id) when is_binary(fork_id) do
    case whereis(fork_id) do
      {:ok, pid} -> connected?(pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    Logger.info("WsAudioForker #{config.fork_id}: Starting, connecting to #{config.url}")

    # Start the Fresh WebSocket connection
    case start_connection(config) do
      {:ok, conn_pid} ->
        Process.monitor(conn_pid)

        state = %{
          config: config,
          conn_pid: conn_pid,
          connection_state: :connecting,
          frames_sent: 0,
          frames_dropped: 0,
          reconnect_count: 0,
          buffer: :queue.new(),
          buffer_size: 0
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("WsAudioForker #{config.fork_id}: Failed to start connection: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:send_audio, audio_data, _opts}, state) do
    case state.connection_state do
      :connected ->
        # Send directly to WebSocket
        send_to_websocket(state.conn_pid, audio_data)
        {:noreply, %{state | frames_sent: state.frames_sent + 1}}

      _other ->
        # Buffer the audio frame if disconnected
        new_state = buffer_frame(state, audio_data)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      connection_state: state.connection_state,
      buffer_size: state.buffer_size,
      buffer_capacity: state.config.buffer_size,
      frames_sent: state.frames_sent,
      frames_dropped: state.frames_dropped,
      reconnect_count: state.reconnect_count
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.connection_state == :connected, state}
  end

  @impl true
  def handle_info({:connection_event, :connected}, state) do
    Logger.info("WsAudioForker #{state.config.fork_id}: Connected to WebSocket")

    # Flush buffered frames
    new_state = flush_buffer(%{state | connection_state: :connected})

    # Notify callback if configured
    notify_callback(state.config, {:fork_event, state.config.fork_id, :connected})

    {:noreply, new_state}
  end

  def handle_info({:connection_event, {:disconnected, reason}}, state) do
    Logger.warning("WsAudioForker #{state.config.fork_id}: Disconnected, reason: #{inspect(reason)}")

    new_state = %{state | connection_state: :disconnected}

    # Notify callback if configured
    notify_callback(state.config, {:fork_event, state.config.fork_id, {:disconnected, reason}})

    {:noreply, new_state}
  end

  def handle_info({:connection_event, {:reconnecting, attempt}}, state) do
    Logger.info("WsAudioForker #{state.config.fork_id}: Reconnecting, attempt #{attempt}")

    new_state = %{state | connection_state: :reconnecting, reconnect_count: attempt}

    # Notify callback if configured
    notify_callback(state.config, {:fork_event, state.config.fork_id, {:reconnecting, attempt}})

    {:noreply, new_state}
  end

  def handle_info({:connection_event, {:failed, reason}}, state) do
    Logger.error("WsAudioForker #{state.config.fork_id}: Connection failed permanently: #{inspect(reason)}")

    # Notify callback if configured
    notify_callback(state.config, {:fork_event, state.config.fork_id, {:failed, reason}})

    {:stop, {:shutdown, {:connection_failed, reason}}, state}
  end

  def handle_info({:connection_event, {:ws_message, data}}, state) do
    # Forward WebSocket messages to callback
    notify_callback(state.config, {:fork_event, state.config.fork_id, {:ws_message, data}})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, conn_pid, reason}, %{conn_pid: conn_pid} = state) do
    Logger.warning("WsAudioForker #{state.config.fork_id}: Connection process died: #{inspect(reason)}")

    # The connection process died - this may or may not restart depending on Fresh's behavior
    # For now, we treat this as a disconnect
    new_state = %{state | connection_state: :disconnected}
    {:noreply, new_state}
  end

  # Handle audio frames sent from WsForkSink
  def handle_info({:audio_frame, audio_data}, state) do
    case state.connection_state do
      :connected ->
        send_to_websocket(state.conn_pid, audio_data)
        {:noreply, %{state | frames_sent: state.frames_sent + 1}}

      _other ->
        new_state = buffer_frame(state, audio_data)
        {:noreply, new_state}
    end
  end

  def handle_info({:audio_frame, _fork_id, audio_data}, state) do
    # Fork_id variant - we ignore the fork_id since we already know who we are
    case state.connection_state do
      :connected ->
        send_to_websocket(state.conn_pid, audio_data)
        {:noreply, %{state | frames_sent: state.frames_sent + 1}}

      _other ->
        new_state = buffer_frame(state, audio_data)
        {:noreply, new_state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("WsAudioForker #{state.config.fork_id}: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("WsAudioForker #{state.config.fork_id}: Terminating, reason: #{inspect(reason)}")

    # Stop the WebSocket connection gracefully
    if state.conn_pid && Process.alive?(state.conn_pid) do
      Fresh.close(state.conn_pid, 1000, "Forker shutting down")
    end

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(fork_id) do
    {:via, Registry, {@registry, {:ws_forker, fork_id}}}
  end

  defp start_connection(%Config{} = config) do
    # The Connection module will handle Fresh callbacks and forward events to us
    parent = self()

    Connection.start_link(
      uri: config.url,
      state: %{parent: parent, fork_id: config.fork_id},
      opts: [
        headers: config.headers
      ]
    )
  end

  defp send_to_websocket(conn_pid, audio_data) do
    Fresh.send(conn_pid, {:binary, audio_data})
  end

  defp buffer_frame(state, audio_data) do
    if state.buffer_size >= state.config.buffer_size do
      # Buffer full - drop oldest frame
      {{:value, _dropped}, new_buffer} = :queue.out(state.buffer)
      new_buffer = :queue.in(audio_data, new_buffer)

      %{state | buffer: new_buffer, frames_dropped: state.frames_dropped + 1}
    else
      # Add to buffer
      new_buffer = :queue.in(audio_data, state.buffer)
      %{state | buffer: new_buffer, buffer_size: state.buffer_size + 1}
    end
  end

  defp flush_buffer(state) do
    # Send all buffered frames
    buffer_list = :queue.to_list(state.buffer)

    Enum.each(buffer_list, fn audio_data ->
      send_to_websocket(state.conn_pid, audio_data)
    end)

    frames_flushed = length(buffer_list)

    %{
      state
      | buffer: :queue.new(),
        buffer_size: 0,
        frames_sent: state.frames_sent + frames_flushed
    }
  end

  defp notify_callback(%Config{callback_module: nil}, _event), do: :ok

  defp notify_callback(%Config{callback_module: module, callback_state: callback_state}, event) do
    # Invoke the callback module's handle_fork_event
    if function_exported?(module, :handle_fork_event, 2) do
      try do
        module.handle_fork_event(event, callback_state)
      rescue
        e ->
          Logger.error("Callback error: #{inspect(e)}")
      end
    end

    :ok
  end
end
