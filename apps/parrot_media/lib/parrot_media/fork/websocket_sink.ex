defmodule ParrotMedia.Fork.WebSocketSink do
  @moduledoc """
  Membrane Sink element that forwards audio to a WebSocket server.

  WebSocketSink establishes a direct WebSocket connection and forwards all
  received audio buffers as binary frames. This enables real-time media
  forking for AI services like:

  - OpenAI Realtime API
  - Google Speech-to-Text
  - Cloud-based transcription services
  - AI-powered conversation analysis

  ## Pipeline Integration

  WebSocketSink is designed to be dynamically added to a pipeline that includes
  a Membrane.Tee element:

      # Add fork to existing pipeline
      fork_spec = [
        child({:ws_fork, fork_id}, %WebSocketSink{
          url: "wss://api.openai.com/v1/realtime",
          headers: [{"Authorization", "Bearer sk-..."}],
          on_connected: fn -> Logger.info("Fork connected!") end
        }),
        get_child(:media_tee)
        |> via_out(Pad.ref(:push_output, fork_id))
        |> get_child({:ws_fork, fork_id})
      ]

  ## Connection Lifecycle

  1. On `handle_setup/2`: Establishes WebSocket connection
  2. On `handle_buffer/4`: Forwards audio as binary WebSocket frames
  3. On `handle_end_of_stream/3`: Sends close frame and disconnects
  4. On connection error: Invokes `on_error` callback, continues buffering

  ## Reconnection Strategy

  - Initial connection failures are reported via `on_error` callback
  - Mid-stream disconnections trigger automatic reconnection with exponential backoff
  - Buffered audio during reconnection is dropped to prevent unbounded memory growth
  - Maximum 5 reconnection attempts before giving up

  ## Example

      defmodule MyPipeline do
        use Membrane.Pipeline

        def handle_info({:fork_to, url}, _ctx, state) do
          spec = [
            child(:fork_sink, %ParrotMedia.Fork.WebSocketSink{
              url: url,
              format: :pcmu,
              on_connected: fn -> IO.puts("Connected!") end,
              on_error: fn reason -> IO.puts("Error: \#{inspect(reason)}") end
            }),
            get_child(:tee)
            |> via_out(Pad.ref(:push_output, :fork))
            |> get_child(:fork_sink)
          ]
          {[spec: spec], state}
        end
      end
  """

  use Membrane.Sink

  require Logger

  alias ParrotMedia.Fork.Types

  def_input_pad(:input,
    flow_control: :push,
    accepted_format: _any
  )

  def_options(
    url: [
      spec: String.t(),
      description: "WebSocket URL to connect to (ws:// or wss://)"
    ],
    format: [
      spec: Types.format(),
      default: :pcmu,
      description: "Audio format being sent (for logging/metadata)"
    ],
    headers: [
      spec: keyword(),
      default: [],
      description: "Additional headers for WebSocket handshake (e.g., Authorization)"
    ],
    on_connected: [
      spec: (-> any()) | nil,
      default: nil,
      description: "Callback invoked when WebSocket connection is established"
    ],
    on_error: [
      spec: (term() -> any()) | nil,
      default: nil,
      description: "Callback invoked on connection error"
    ],
    max_retries: [
      spec: non_neg_integer(),
      default: 5,
      description: "Maximum reconnection attempts (0 = unlimited)"
    ],
    backoff_initial: [
      spec: pos_integer(),
      default: 100,
      description: "Initial backoff delay in milliseconds"
    ],
    backoff_max: [
      spec: pos_integer(),
      default: 5000,
      description: "Maximum backoff delay in milliseconds"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      url: opts.url,
      format: opts.format,
      headers: opts.headers,
      on_connected: opts.on_connected,
      on_error: opts.on_error,
      max_retries: opts.max_retries,
      backoff_initial: opts.backoff_initial,
      backoff_max: opts.backoff_max,
      connection_pid: nil,
      connected: false,
      frames_sent: 0,
      frames_dropped: 0,
      reconnect_attempt: 0
    }

    Logger.info("WebSocketSink: Initializing for #{opts.url}")

    {[], state}
  end

  @impl true
  def handle_setup(_ctx, state) do
    case start_connection(state) do
      {:ok, conn_pid} ->
        Logger.debug("WebSocketSink: Connection process started: #{inspect(conn_pid)}")
        {[], %{state | connection_pid: conn_pid}}

      {:error, reason} ->
        Logger.error("WebSocketSink: Failed to start connection: #{inspect(reason)}")
        invoke_error_callback(state, reason)
        {[], state}
    end
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    if state.connected and state.connection_pid do
      # Send audio as binary WebSocket frame
      send(state.connection_pid, {:send, {:binary, buffer.payload}})
      {[], %{state | frames_sent: state.frames_sent + 1}}
    else
      # Not connected, drop the frame
      if state.frames_dropped < 10 or rem(state.frames_dropped, 100) == 0 do
        Logger.warning(
          "WebSocketSink: Not connected, dropping frame (#{state.frames_dropped + 1} total dropped)"
        )
      end

      {[], %{state | frames_dropped: state.frames_dropped + 1}}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    Logger.info(
      "WebSocketSink: End of stream. Sent #{state.frames_sent} frames, dropped #{state.frames_dropped}"
    )

    # Close WebSocket connection gracefully
    if state.connection_pid and Process.alive?(state.connection_pid) do
      send(state.connection_pid, {:send, :close})
    end

    {[], state}
  end

  @impl true
  def handle_info({:connection_event, :connected}, _ctx, state) do
    Logger.info("WebSocketSink: Connected to #{state.url}")

    # Reset reconnect counter on successful connection
    new_state = %{state | connected: true, reconnect_attempt: 0}

    # Invoke callback
    invoke_connected_callback(state)

    {[], new_state}
  end

  def handle_info({:connection_event, {:disconnected, reason}}, _ctx, state) do
    Logger.warning("WebSocketSink: Disconnected: #{inspect(reason)}")
    {[], %{state | connected: false}}
  end

  def handle_info({:connection_event, {:reconnecting, attempt}}, _ctx, state) do
    Logger.info("WebSocketSink: Reconnecting, attempt #{attempt}")
    {[], %{state | reconnect_attempt: attempt}}
  end

  def handle_info({:connection_event, {:initial_connection_failed, reason}}, _ctx, state) do
    Logger.error("WebSocketSink: Initial connection failed: #{inspect(reason)}")
    invoke_error_callback(state, reason)
    {[], %{state | connected: false, connection_pid: nil}}
  end

  def handle_info({:connection_event, {:max_retries_exceeded, _attempts}}, _ctx, state) do
    Logger.error("WebSocketSink: Max retries exceeded, giving up")
    invoke_error_callback(state, :max_retries_exceeded)
    {[], %{state | connected: false}}
  end

  def handle_info({:connection_event, {:failed, reason}}, _ctx, state) do
    Logger.error("WebSocketSink: Connection failed: #{inspect(reason)}")
    invoke_error_callback(state, reason)
    {[], %{state | connected: false, connection_pid: nil}}
  end

  def handle_info({:connection_event, {:ws_message, _data}}, _ctx, state) do
    # Received message from server - could be used for acknowledgments
    # Currently just log at debug level
    Logger.debug("WebSocketSink: Received message from server")
    {[], state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, _ctx, state) do
    if pid == state.connection_pid do
      Logger.warning("WebSocketSink: Connection process died: #{inspect(reason)}")
      invoke_error_callback(state, {:connection_died, reason})
      {[], %{state | connected: false, connection_pid: nil}}
    else
      {[], state}
    end
  end

  def handle_info(msg, _ctx, state) do
    Logger.debug("WebSocketSink: Unhandled message: #{inspect(msg)}")
    {[], state}
  end

  @impl true
  def handle_terminate_request(_ctx, state) do
    cleanup(state)
    {[terminate: :normal], state}
  end

  # Private functions

  defp start_connection(state) do
    # Parse headers for Fresh
    fresh_headers =
      Enum.map(state.headers, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        {key, value} -> {key, value}
      end)

    fresh_opts = [
      headers: fresh_headers,
      backoff_initial: state.backoff_initial,
      backoff_max: state.backoff_max
    ]

    connection_state = %{
      parent: self(),
      fork_id: "websocket_sink",
      max_retries: state.max_retries,
      has_connected: false,
      reconnect_attempt: 0
    }

    # Use the existing WsAudioForker.Connection module
    ParrotMedia.WsAudioForker.Connection.start_link(
      uri: state.url,
      state: connection_state,
      opts: fresh_opts
    )
  end

  defp invoke_connected_callback(%{on_connected: nil}), do: :ok

  defp invoke_connected_callback(%{on_connected: callback}) when is_function(callback, 0) do
    try do
      callback.()
    rescue
      e ->
        Logger.warning("WebSocketSink: on_connected callback error: #{inspect(e)}")
    end
  end

  defp invoke_error_callback(%{on_error: nil}, _reason), do: :ok

  defp invoke_error_callback(%{on_error: callback}, reason) when is_function(callback, 1) do
    try do
      callback.(reason)
    rescue
      e ->
        Logger.warning("WebSocketSink: on_error callback error: #{inspect(e)}")
    end
  end

  defp cleanup(state) do
    if state.connection_pid and Process.alive?(state.connection_pid) do
      # Send close frame
      send(state.connection_pid, {:send, :close})
      # Give it a moment to close gracefully
      Process.sleep(100)

      if Process.alive?(state.connection_pid) do
        Process.exit(state.connection_pid, :shutdown)
      end
    end

    Logger.debug(
      "WebSocketSink: Cleanup complete. Sent #{state.frames_sent}, dropped #{state.frames_dropped}"
    )
  end
end
