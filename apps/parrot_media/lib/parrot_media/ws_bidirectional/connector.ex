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

  ## STUB IMPLEMENTATION

  This module is a stub for TDD. All functions return errors or do nothing.
  Tests should fail until this is properly implemented.
  """

  use GenServer
  require Logger

  alias ParrotMedia.WsBidirectional.Config

  @type connection_ref :: pid() | String.t()

  # Registry for bidirectional connection lookup (used in implementation)
  # @registry ParrotMedia.BidirectionalRegistry

  # ============================================================================
  # Public API (Stubs - to be implemented)
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
  def start_link(%Config{} = _config) do
    # STUB: Not implemented
    {:error, :not_implemented}
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
  def disconnect(_connection_ref) do
    # STUB: Not implemented
    {:error, :not_found}
  end

  @doc """
  Look up a connector by connection_id.

  ## Returns

  - `{:ok, pid}` - Connector found
  - `{:error, :not_found}` - No connector with this ID
  """
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(_connection_id) do
    # STUB: Not implemented
    {:error, :not_found}
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
  def send_audio(_connection_ref, _audio_data) do
    # STUB: Not implemented
    {:error, :not_found}
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
  def send_message(_connection_ref, _message) do
    # STUB: Not implemented
    {:error, :not_found}
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
  def register_source(_connection_ref, _source_pid) do
    # STUB: Not implemented
    {:error, :not_found}
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
  def mute(_connection_ref, _direction) do
    # STUB: Not implemented
    {:error, :not_found}
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
  def unmute(_connection_ref, _direction) do
    # STUB: Not implemented
    {:error, :not_found}
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
  def status(_connection_ref) do
    # STUB: Not implemented
    {:error, :not_found}
  end

  # ============================================================================
  # GenServer Callbacks (Stubs)
  # ============================================================================

  @impl true
  def init(_config) do
    # STUB: Not implemented
    {:stop, :not_implemented}
  end

  @impl true
  def handle_call(_request, _from, state) do
    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_cast(_request, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end
