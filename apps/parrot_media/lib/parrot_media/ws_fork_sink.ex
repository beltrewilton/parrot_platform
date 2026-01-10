defmodule ParrotMedia.WsForkSink do
  @moduledoc """
  Membrane Sink element for forwarding audio to a WsAudioForker process.

  WsForkSink receives audio buffers from a Membrane pipeline and forwards them
  via message passing to a WsAudioForker GenServer. This enables WebSocket-based
  media forking for use cases like:

  - Real-time transcription services via WebSocket
  - Cloud-based speech recognition
  - AI-powered conversation analysis
  - External audio processing services

  ## Pipeline Integration

  WsForkSink is designed to be dynamically added to a pipeline that includes
  a Membrane.Tee element. When a WebSocket fork is requested:

  1. WsAudioForker establishes the WebSocket connection
  2. WsForkSink is spawned as a new child element
  3. It's linked to a `push_output` pad on the Tee
  4. It forwards all received buffers to the forker via messages
  5. The forker sends the audio over WebSocket to the remote service

  ## Example

      # In a pipeline handle_info callback
      def handle_info({:add_ws_fork, forker_pid, fork_id}, _ctx, state) do
        fork_spec = [
          child({:ws_fork_sink, fork_id}, %WsForkSink{
            forker_pid: forker_pid,
            fork_id: fork_id
          }),
          get_child(:media_tee)
          |> via_out(Pad.ref(:push_output, fork_id))
          |> get_child({:ws_fork_sink, fork_id})
        ]
        {[spec: fork_spec], state}
      end

  ## Message Format

  WsForkSink sends messages in the format:

      {:audio_frame, fork_id, payload}

  Where:
  - `fork_id` is the configured fork identifier (String.t)
  - `payload` is the raw audio bytes (binary)

  ## Error Handling

  Errors are handled gracefully to ensure the main call pipeline isn't affected:
  - If forker_pid is nil, audio is dropped with a warning log
  - If forker_pid becomes unavailable, audio is still sent (Erlang message semantics)
  - Pipeline errors should NOT crash the main call flow
  """

  use Membrane.Sink

  require Logger

  def_input_pad(:input,
    flow_control: :push,
    accepted_format: _any
  )

  def_options(
    forker_pid: [
      spec: pid() | nil,
      default: nil,
      description: "PID of WsAudioForker to forward audio to"
    ],
    fork_id: [
      spec: String.t() | nil,
      default: nil,
      description: "Fork identifier for logging and message routing"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    fork_id = opts.fork_id || "anonymous"

    state = %{
      forker_pid: opts.forker_pid,
      fork_id: fork_id,
      frames_sent: 0,
      errors: 0
    }

    if opts.forker_pid do
      Logger.info("WsForkSink [#{fork_id}]: Initializing with forker #{inspect(opts.forker_pid)}")
    else
      Logger.warning("WsForkSink [#{fork_id}]: Initializing with nil forker_pid")
    end

    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case state.forker_pid do
      nil ->
        # No forker available, skip sending but don't crash
        if state.errors < 10 or rem(state.errors, 100) == 0 do
          Logger.warning(
            "WsForkSink [#{state.fork_id}]: No forker_pid available, dropping audio frame"
          )
        end

        {[], %{state | errors: state.errors + 1}}

      forker_pid ->
        # Forward audio to forker - use send which doesn't fail even if process is dead
        send(forker_pid, {:audio_frame, state.fork_id, buffer.payload})
        {[], %{state | frames_sent: state.frames_sent + 1}}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    Logger.info(
      "WsForkSink [#{state.fork_id}]: End of stream. Sent #{state.frames_sent} frames, #{state.errors} errors"
    )

    # Optionally notify forker of end of stream
    if state.forker_pid do
      send(state.forker_pid, {:fork_end_of_stream, state.fork_id})
    end

    {[], state}
  end

  @impl true
  def handle_terminate_request(_ctx, state) do
    Logger.debug("WsForkSink [#{state.fork_id}]: Terminating after #{state.frames_sent} frames")
    {[terminate: :normal], state}
  end

  # Public helper functions for testing and direct integration

  @doc """
  Forward audio data directly to a forker (simple form without fork_id).

  Used by WsForkSink internally and can be used for integration tests.

  ## Example

      :ok = WsForkSink.forward_to_forker(forker_pid, audio_data)

  """
  @spec forward_to_forker(pid(), binary()) :: :ok
  def forward_to_forker(forker_pid, audio_data) when is_pid(forker_pid) do
    send(forker_pid, {:audio_frame, audio_data})
    :ok
  end

  @doc """
  Forward audio data directly to a forker with fork_id.

  Used by WsForkSink internally and can be used for integration tests.

  ## Example

      :ok = WsForkSink.forward_to_forker(forker_pid, "my-fork", audio_data)

  """
  @spec forward_to_forker(pid(), String.t(), binary()) :: :ok
  def forward_to_forker(forker_pid, fork_id, audio_data) when is_pid(forker_pid) do
    send(forker_pid, {:audio_frame, fork_id, audio_data})
    :ok
  end
end
