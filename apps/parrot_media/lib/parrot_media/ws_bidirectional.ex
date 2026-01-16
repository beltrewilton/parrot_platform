defmodule ParrotMedia.WsBidirectional do
  @moduledoc """
  Public API for bidirectional WebSocket audio connections.

  Enables real-time speech-to-speech AI integrations by streaming caller audio
  to WebSocket endpoints and playing AI responses back to the caller.

  ## Quick Start

      # Create configuration
      config = WsBidirectional.Config.new!(
        connection_id: "call_123_ai",
        url: "wss://api.openai.com/v1/realtime",
        headers: [{"Authorization", "Bearer sk-..."}],
        callback_module: MyApp.AIHandler
      )

      # Start the connection
      {:ok, pid} = WsBidirectional.start_link(config)

      # Send caller audio (typically from pipeline via Sink)
      WsBidirectional.send_audio(pid, audio_binary)

      # Control audio flow
      WsBidirectional.mute(:outbound, pid)   # Stop sending to AI
      WsBidirectional.unmute(:outbound, pid) # Resume sending

      # Send control message to AI
      WsBidirectional.send_message(pid, Jason.encode!(%{type: "end_turn"}))

      # Disconnect when done
      WsBidirectional.disconnect(pid)

  ## Integration with Parrot DSL

  Typically used via DSL operations:

      call
      |> connect_bidirectional_ws("wss://ai.example.com", headers: [...])
      |> ...

  See `Parrot.Call` for DSL documentation.

  ## See Also

  - `WsBidirectional.Config` - Connection configuration
  - `WsBidirectional.Callback` - Event callback behaviour
  """

  alias ParrotMedia.WsBidirectional.Config
  alias ParrotMedia.WsBidirectional.Connector

  @typedoc """
  Reference to a connection, either a PID or the connection_id string.
  """
  @type connection_ref :: pid() | String.t()

  @typedoc """
  Audio direction: :inbound (from WebSocket to caller) or :outbound (from caller to WebSocket).
  """
  @type direction :: :inbound | :outbound

  # ============================================================================
  # Lifecycle
  # ============================================================================

  @doc """
  Start a bidirectional WebSocket connection.

  Establishes connection to the specified WebSocket endpoint and prepares
  for bidirectional audio streaming.

  ## Parameters

  - `config` - `WsBidirectional.Config` struct with connection settings

  ## Returns

  - `{:ok, pid}` - Connection started successfully
  - `{:error, :already_registered}` - Connection with this ID already exists
  - `{:error, :invalid_config}` - Configuration validation failed
  - `{:error, reason}` - Other startup failure

  ## Examples

      config = Config.new!(connection_id: "c1", url: "wss://api.example.com")
      {:ok, pid} = WsBidirectional.start_link(config)
  """
  @spec start_link(Config.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(%Config{} = config) do
    Connector.start_link(config)
  end

  @doc """
  Returns a child specification for starting under a supervisor.

  ## Parameters

  - `config` - `WsBidirectional.Config` struct with connection settings

  ## Returns

  A `Supervisor.child_spec()` map suitable for use in a supervision tree.

  ## Examples

      config = Config.new!(connection_id: "c1", url: "wss://api.example.com")
      children = [
        {WsBidirectional, config}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)
  """
  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{
      id: {__MODULE__, config.connection_id},
      start: {__MODULE__, :start_link, [config]},
      type: :worker,
      restart: :transient,
      shutdown: 5000
    }
  end

  @doc """
  Stop a bidirectional connection gracefully.

  Closes the WebSocket, cleans up resources, and terminates the process.

  ## Parameters

  - `connection_ref` - PID or connection_id string

  ## Returns

  - `:ok` - Connection stopped
  - `{:error, :not_found}` - Connection not found

  ## Examples

      :ok = WsBidirectional.disconnect("call_123_ai")
      :ok = WsBidirectional.disconnect(pid)
  """
  @spec disconnect(connection_ref()) :: :ok | {:error, :not_found}
  def disconnect(connection_ref) do
    with pid when is_pid(pid) <- resolve_ref(connection_ref) do
      Connector.disconnect(pid)
    end
  end

  # ============================================================================
  # Audio Control
  # ============================================================================

  @doc """
  Send an audio frame to the WebSocket.

  Called by the Membrane Sink element or directly. Audio is queued if
  the connection is temporarily disconnected (up to buffer_size frames).

  ## Parameters

  - `connection_ref` - PID or connection_id string
  - `audio_data` - Binary audio data in the configured outbound_format
  - `opts` - Optional metadata (e.g., `[timestamp: 12345]`)

  ## Returns

  - `:ok` - Frame sent or queued
  - `{:error, :not_found}` - Connection not found
  - `{:error, :muted}` - Outbound direction is muted

  ## Examples

      :ok = WsBidirectional.send_audio(pid, audio_binary)
      :ok = WsBidirectional.send_audio("call_123_ai", audio_binary, timestamp: 12345)
  """
  @spec send_audio(connection_ref(), binary(), keyword()) ::
          :ok | {:error, :not_found | :muted}
  def send_audio(connection_ref, audio_data, _opts \\ []) do
    with pid when is_pid(pid) <- resolve_ref(connection_ref) do
      Connector.send_audio(pid, audio_data)
    end
  end

  @doc """
  Mute audio in the specified direction.

  - `:outbound` - Stop sending caller audio to WebSocket
  - `:inbound` - Stop playing WebSocket audio to caller

  ## Parameters

  - `direction` - `:inbound` or `:outbound`
  - `connection_ref` - PID or connection_id string

  ## Returns

  - `:ok` - Direction muted
  - `{:error, :not_found}` - Connection not found

  ## Examples

      :ok = WsBidirectional.mute(:outbound, pid)
      :ok = WsBidirectional.mute(:inbound, "call_123_ai")
  """
  @spec mute(direction(), connection_ref()) :: :ok | {:error, :not_found}
  def mute(direction, connection_ref) do
    with pid when is_pid(pid) <- resolve_ref(connection_ref) do
      Connector.mute(pid, direction)
    end
  end

  @doc """
  Unmute audio in the specified direction.

  ## Parameters

  - `direction` - `:inbound` or `:outbound`
  - `connection_ref` - PID or connection_id string

  ## Returns

  - `:ok` - Direction unmuted
  - `{:error, :not_found}` - Connection not found

  ## Examples

      :ok = WsBidirectional.unmute(:outbound, pid)
      :ok = WsBidirectional.unmute(:inbound, "call_123_ai")
  """
  @spec unmute(direction(), connection_ref()) :: :ok | {:error, :not_found}
  def unmute(direction, connection_ref) do
    with pid when is_pid(pid) <- resolve_ref(connection_ref) do
      Connector.unmute(pid, direction)
    end
  end

  # ============================================================================
  # Messaging
  # ============================================================================

  @doc """
  Send a text/JSON message to the WebSocket.

  Used for sending control messages to AI services (e.g., end turn,
  configuration updates, etc.).

  ## Parameters

  - `connection_ref` - PID or connection_id string
  - `message` - String or binary to send

  ## Returns

  - `:ok` - Message sent
  - `{:error, :not_found}` - Connection not found
  - `{:error, :not_connected}` - WebSocket not currently connected

  ## Examples

      :ok = WsBidirectional.send_message(pid, Jason.encode!(%{type: "end_turn"}))
      :ok = WsBidirectional.send_message("call_123_ai", ~s({"action": "interrupt"}))
  """
  @spec send_message(connection_ref(), String.t() | binary()) ::
          :ok | {:error, :not_found | :not_connected}
  def send_message(connection_ref, message) do
    with pid when is_pid(pid) <- resolve_ref(connection_ref) do
      Connector.send_message(pid, message)
    end
  end

  # ============================================================================
  # Status
  # ============================================================================

  @doc """
  Get current connection status.

  ## Parameters

  - `connection_ref` - PID or connection_id string

  ## Returns

  - `{:ok, status}` - Status map with connection details
  - `{:error, :not_found}` - Connection not found

  ## Status Fields

  - `:connection_state` - `:connecting`, `:connected`, `:disconnected`, etc.
  - `:outbound_muted` - Boolean
  - `:inbound_muted` - Boolean
  - `:frames_sent` - Total frames sent
  - `:frames_received` - Total frames received
  - `:frames_dropped` - Frames dropped due to backpressure
  - `:reconnect_count` - Number of reconnection attempts
  - `:connected_at` - DateTime when connected (or nil)

  ## Examples

      {:ok, status} = WsBidirectional.status(pid)
      status.connection_state
      # => :connected

      {:ok, %{frames_sent: sent, frames_received: received}} = WsBidirectional.status("call_123_ai")
  """
  @spec status(connection_ref()) :: {:ok, map()} | {:error, :not_found}
  def status(connection_ref) do
    with pid when is_pid(pid) <- resolve_ref(connection_ref) do
      Connector.status(pid)
    end
  end

  @doc """
  Check if connection is currently connected.

  ## Parameters

  - `connection_ref` - PID or connection_id string

  ## Returns

  - `true` - WebSocket is connected
  - `false` - Not connected
  - `{:error, :not_found}` - Connection not found

  ## Examples

      true = WsBidirectional.connected?(pid)
      false = WsBidirectional.connected?("call_123_ai")
  """
  @spec connected?(connection_ref()) :: boolean() | {:error, :not_found}
  def connected?(connection_ref) do
    case status(connection_ref) do
      {:ok, %{connection_state: :connected}} -> true
      {:ok, _} -> false
      {:error, _} = error -> error
    end
  end

  # ============================================================================
  # Lookup
  # ============================================================================

  @doc """
  Look up a connection by connection_id.

  ## Parameters

  - `connection_id` - The unique identifier for the connection

  ## Returns

  - `{:ok, pid}` - Connection found
  - `{:error, :not_found}` - No connection with this ID

  ## Examples

      {:ok, pid} = WsBidirectional.whereis("call_123_ai")
      {:error, :not_found} = WsBidirectional.whereis("nonexistent")
  """
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(connection_id) when is_binary(connection_id) do
    Connector.whereis(connection_id)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Helper to resolve pid or string to pid
  defp resolve_ref(pid) when is_pid(pid), do: pid

  defp resolve_ref(connection_id) when is_binary(connection_id) do
    case whereis(connection_id) do
      {:ok, pid} -> pid
      {:error, _} = error -> error
    end
  end
end
