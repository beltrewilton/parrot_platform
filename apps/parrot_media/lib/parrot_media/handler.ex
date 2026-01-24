defmodule ParrotMedia.Handler do
  @moduledoc """
  Behaviour for implementing media session handlers in Parrot.

  The `ParrotMedia.Handler` behaviour provides callbacks for handling media-specific
  events during SIP calls, including SDP negotiation, codec selection, media stream
  lifecycle, and real-time media processing.

  ## Overview

  MediaHandler complements `ParrotSip.UasHandler` by providing fine-grained control over
  media sessions. While UasHandler manages SIP protocol events, MediaHandler focuses
  on the actual media streams (audio/video).

  Media handlers receive messages through `handle_info/2` from your SIP handlers,
  allowing for powerful media control patterns:

  - Play single or multiple audio files with looping options
  - Fork audio to WebSocket servers for transcription/analysis
  - Receive processed audio from external services
  - Mix audio streams for conferencing
  - Implement IVR systems with dynamic media control

  ## Message-Based Media Control

  MediaHandler uses Erlang message passing for media control, making it easy
  to trigger media operations from anywhere in your application:

  ```elixir
  # From your SIP handler or anywhere else
  send(media_handler_pid, {:play_files, ["welcome.wav", "menu.wav"], loop: true})
  send(media_handler_pid, {:play_files, ["music.wav"], loop: false})  # Play once
  send(media_handler_pid, {:stop_playback})

  # Connect audio devices (for UAC or soft phone scenarios)
  send(media_handler_pid, {:connect_microphone})  # Connect mic for input
  send(media_handler_pid, {:connect_speakers})    # Connect speakers for output
  send(media_handler_pid, {:connect_audio_devices}) # Connect both
  ```

  ## Basic Usage

  ```elixir
  defmodule MyApp.MediaHandler do
    @behaviour ParrotMedia.Handler

    @impl true
    def init(_args) do
      {:ok, %{
        audio_queue: [],
        looping: false
      }}
    end

    # Pattern matching for play_files with different options
    @impl true
    def handle_info({:play_files, files, [loop: true]}, state) do
      # Play files in a loop
      {[{:play_loop, files}], %{state | audio_queue: files}}
    end
    
    @impl true
    def handle_info({:play_files, files, opts}, state) when is_list(opts) do
      # Play files in sequence (default when loop not specified)
      {[{:play_sequence, files}], %{state | audio_queue: files}}
    end

    @impl true
    def handle_info({:stop_playback}, state) do
      {[:stop], %{state | audio_queue: [], looping: false}}
    end
    
    @impl true
    def handle_info(_msg, state) do
      {:noreply, state}
    end
  end
  ```

  ## Integration with UasHandler

  ```elixir
  defmodule MyApp do
    use ParrotSip.UasHandler
    @behaviour ParrotMedia.Handler
    
    @impl ParrotSip.UasHandler
    def handle_invite(request, state) do
      # Create media session
      {:ok, media_pid} = ParrotMedia.MediaSession.start_link(
        id: "call_123",
        role: :uas,
        media_handler: __MODULE__,
        handler_args: %{}
      )
      
      # Store media handler PID for later use
      state = Map.put(state, :media_handler, media_pid)
      
      # Process SDP
      case ParrotMedia.MediaSession.process_offer("call_123", request.body) do
        {:ok, sdp_answer} ->
          # Trigger media operations after accepting call
          send(media_pid, {:play_files, ["welcome.wav"], loop: false})
          
          {:respond, 200, "OK", %{}, sdp_answer, state}
        {:error, _} ->
          {:respond, 488, "Not Acceptable Here", %{}, "", state}
      end
    end
    
    @impl ParrotSip.UasHandler  
    def handle_info({:dtmf, digit}, %{media_handler: media_pid} = state) do
      # React to DTMF by playing different files
      files = case digit do
        "1" -> ["option1.wav"]
        "2" -> ["option2.wav"]
        _ -> ["invalid.wav", "menu.wav"]
      end
      
      send(media_pid, {:play_files, files, []})
      {:noreply, state}
    end
  end
  ```

  ## Callback Flow

  The typical callback sequence for a call:

  1. `init/1` - Handler initialization
  2. `handle_session_start/3` - Media session created
  3. `handle_offer/3` - SDP offer received (optional)
  4. `handle_codec_negotiation/3` - Select codec
  5. `handle_negotiation_complete/4` - Negotiation done
  6. `handle_stream_start/3` - Media streaming begins
  7. `handle_info/2` - Process media control messages
  8. `handle_stream_stop/3` - Media streaming ends
  9. `handle_session_stop/3` - Cleanup

  ## Media Control Messages

  - `{:play_files, files, opts}` - Play one or more audio files
    - Options: `loop: true/false` - Whether to loop the files
  - `{:stop_playback}` - Stop current playback
  """

  @typedoc "Handler state - can be any term"
  @type state :: term()

  @typedoc "Media session ID"
  @type session_id :: String.t()

  @typedoc "SDP direction"
  @type direction :: :inbound | :outbound

  @typedoc "Codec atom"
  @type codec :: :pcmu | :pcma | :opus | atom()

  @typedoc """
  Media actions that can be returned from callbacks.

  Actions for file playback:
  - `{:play, file_path}` - Play an audio file
  - `{:play_sequence, files}` - Play multiple files in sequence
  - `{:play_loop, files}` - Play files in a continuous loop

  Actions for device control:
  - `{:connect_audio_device, input_device, output_device}` - Connect specific audio
  devices
    - Both devices: Full duplex audio (microphone + speaker)
    - Input only (output nil): Microphone only for recording/sending
    - Output only (input nil): Speaker only for playback
    - Both nil: Release all audio devices

  Control actions:
  - `:stop` - Stop current media playback
  - `:noreply` - No action needed
  """
  @type media_action ::
          {:play, file_path :: String.t()}
          | {:play_sequence, [String.t()]}
          | {:play_loop, [String.t()]}
          | {:connect_audio_device, input_device :: String.t() | integer() | nil,
             output_device :: String.t() | integer() | nil}
          | :stop
          | :noreply

  # Session Lifecycle Callbacks

  @doc """
  Initialize the media handler.

  Called when a new media session starts. This happens when MediaSession
  is started for a dialog.

  ## Parameters

  - `args` - Arguments passed when starting the handler

  ## Returns

  - `{:ok, state}` - Initialize with the given state
  - `{:stop, reason}` - Prevent the handler from starting

  ## Example

      @impl true
      def init(args) do
        {:ok, %{
          preferred_codec: :opus,
          quality_threshold: 5.0,
          play_queue: []
        }}
      end
  """
  @callback init(args :: term()) :: {:ok, state} | {:stop, reason :: term()}

  @doc """
  Handle media session start.

  Called when a media session is being established.

  ## Parameters

  - `session_id` - Unique session identifier
  - `opts` - Session options
  - `state` - Current handler state

  ## Returns

  - `{:ok, state}` - Session started successfully
  - `{:error, reason, state}` - Session start failed
  """
  @callback handle_session_start(session_id, opts :: keyword(), state) ::
              {:ok, state} | {:error, reason :: term(), state}

  @doc """
  Handle media session stop.

  Called when a media session is terminating.

  ## Parameters

  - `session_id` - Session identifier
  - `reason` - Termination reason
  - `state` - Current handler state

  ## Returns

  - `{:ok, state}` - Acknowledged
  """
  @callback handle_session_stop(session_id, reason :: term(), state) :: {:ok, state}

  # SDP Negotiation Callbacks

  @doc """
  Process an SDP offer.

  Called before the media session processes an SDP offer. The handler can
  modify the SDP or reject it.

  ## Parameters

  - `sdp` - The SDP offer as a string
  - `direction` - `:inbound` or `:outbound`
  - `state` - Current handler state

  ## Returns

  - `{:ok, modified_sdp, state}` - Use modified SDP
  - `{:reject, reason, state}` - Reject the offer
  - `{:noreply, state}` - Process SDP without modification
  """
  @callback handle_offer(sdp :: String.t(), direction, state) ::
              {:ok, modified_sdp :: String.t(), state}
              | {:reject, reason :: term(), state}
              | {:noreply, state}

  @doc """
  Process an SDP answer.

  Called before the media session finalizes an SDP answer.

  ## Parameters

  - `sdp` - The SDP answer as a string
  - `direction` - `:inbound` or `:outbound`
  - `state` - Current handler state

  ## Returns

  - `{:ok, modified_sdp, state}` - Use modified SDP
  - `{:reject, reason, state}` - Reject the answer
  - `{:noreply, state}` - Process SDP without modification
  """
  @callback handle_answer(sdp :: String.t(), direction, state) ::
              {:ok, modified_sdp :: String.t(), state}
              | {:reject, reason :: term(), state}
              | {:noreply, state}

  @doc """
  Customize codec selection.

  Called during SDP negotiation to select the best codec from offered
  and supported lists.

  ## Parameters

  - `offered_codecs` - Codecs offered by remote party
  - `supported_codecs` - Codecs supported locally
  - `state` - Current handler state

  ## Returns

  - `{:ok, codec, state}` - Select a single codec
  - `{:ok, codec_list, state}` - Return ordered preference list
  - `{:error, :no_common_codec, state}` - No acceptable codec

  ## Example

      @impl true
      def handle_codec_negotiation(offered, supported, state) do
        # Prefer Opus > G.711A (PCMU not supported)
        cond do
          :opus in offered and :opus in supported ->
            {:ok, :opus, state}
          :pcma in offered and :pcma in supported ->
            {:ok, :pcma, state}
          true ->
            {:error, :no_common_codec, state}
        end
      end
  """
  @callback handle_codec_negotiation(
              offered_codecs :: [codec()],
              supported_codecs :: [codec()],
              state
            ) ::
              {:ok, codec(), state}
              | {:ok, [codec()], state}
              | {:error, :no_common_codec, state}

  @doc """
  Called after SDP negotiation completes.

  Provides the final negotiated parameters.

  ## Parameters

  - `local_sdp` - Final local SDP
  - `remote_sdp` - Final remote SDP
  - `selected_codec` - The negotiated codec
  - `state` - Current handler state

  ## Returns

  - `{:ok, state}` - Negotiation accepted
  - `{:error, reason, state}` - Reject the negotiation
  """
  @callback handle_negotiation_complete(
              local_sdp :: String.t(),
              remote_sdp :: String.t(),
              selected_codec :: codec(),
              state
            ) ::
              {:ok, state} | {:error, reason :: term(), state}

  # Media Stream Callbacks

  @doc """
  Handle media stream start.

  Called when media stream is about to start. Can return media actions
  to execute.

  ## Parameters

  - `session_id` - Session identifier
  - `direction` - `:inbound`, `:outbound`, or `:bidirectional`
  - `state` - Current handler state

  ## Returns

  - `media_action` - Single action to execute
  - `{media_action, state}` - Action with state update
  - `{[media_action], state}` - Multiple actions
  - `{:noreply, state}` - No action

  ## Example

      @impl true
      def handle_stream_start(_session_id, :inbound, state) do
        # Play welcome message
        {{:play, "/audio/welcome.wav"}, state}
      end
  """
  @callback handle_stream_start(
              session_id,
              direction :: :inbound | :outbound | :bidirectional,
              state
            ) ::
              media_action()
              | {media_action(), state}
              | {[media_action()], state}
              | {:noreply, state}

  @doc """
  Handle media stream stop.

  Called when media stream stops.

  ## Parameters

  - `session_id` - Session identifier
  - `reason` - Stop reason
  - `state` - Current handler state

  ## Returns

  - `{:ok, state}` - Acknowledged
  """
  @callback handle_stream_stop(session_id, reason :: term(), state) :: {:ok, state}

  @doc """
  Handle media stream errors.

  ## Parameters

  - `session_id` - Session identifier
  - `error` - Error details
  - `state` - Current handler state

  ## Returns

  - `{:retry, state}` - Retry the operation
  - `{:continue, state}` - Continue despite error
  - `{:stop, reason, state}` - Stop the stream
  """
  @callback handle_stream_error(session_id, error :: term(), state) ::
              {:retry, state} | {:continue, state} | {:stop, reason :: term(), state}

  # Media Control Callbacks

  @doc """
  Handle playback completion.

  Called when an audio file finishes playing.

  ## Parameters

  - `file_path` - Path of completed file
  - `state` - Current handler state

  ## Returns

  - `media_action` - Next action to execute
  - `{media_action, state}` - Action with state update
  - `{:noreply, state}` - No action
  """
  @callback handle_play_complete(file_path :: String.t(), state) ::
              media_action() | {media_action(), state} | {:noreply, state}

  @doc """
  Handle custom media requests.

  Allows for extensibility with custom requests.

  ## Parameters

  - `request` - Custom request
  - `state` - Current handler state

  ## Returns

  - `media_action` - Action to execute
  - `{media_action, state}` - Action with state update
  - `{:error, reason, state}` - Invalid request
  """
  @callback handle_media_request(request :: term(), state) ::
              media_action() | {media_action(), state} | {:error, reason :: term(), state}

  @doc """
  Handle arbitrary Erlang messages sent to the media handler.

  This is the primary callback for implementing message-based media control.
  Messages can be sent from your SIP handlers or any other part of your application
  to control media playback, audio forking, and other media operations.

  ## Common Messages

  - `{:play_files, files, opts}` - Play one or more audio files
  - `{:fork_audio, url, opts}` - Fork audio to WebSocket endpoint  
  - `{:received_audio, data, metadata}` - Audio received from external service
  - `{:stop_playback}` - Stop current playback
  - `{:pause_playback}` - Pause current playback
  - `{:resume_playback}` - Resume paused playback
  - `{:set_volume, level}` - Adjust playback volume
  - Custom messages specific to your application

  ## Parameters

  - `msg` - Any Erlang term
  - `state` - Current handler state

  ## Returns

  - `{[media_action], state}` - List of actions to execute with new state
  - `{media_action, state}` - Single action with new state
  - `{:noreply, state}` - Continue with new state, no media action
  - `{:stop, reason, state}` - Stop the handler

  ## Examples

      @impl true
      def handle_info({:play_files, files, opts}, state) do
        loop = Keyword.get(opts, :loop, false)
        actions = if loop do
          [{:play_loop, files}]
        else
          [{:play_sequence, files}]
        end
        {actions, %{state | current_playlist: files}}
      end

      @impl true
      def handle_info({:fork_audio, url, opts}, state) do
        bidirectional = Keyword.get(opts, :bidirectional, false)
        actions = [{:fork_audio, url, bidirectional: bidirectional}]
        {actions, Map.put(state, :fork_urls, [url | state.fork_urls])}
      end

      @impl true  
      def handle_info({:received_audio, audio_data, %{source: source}}, state) do
        # Process audio from external service
        case process_external_audio(audio_data, source) do
          {:play, processed_audio} ->
            {[{:play, processed_audio}], state}
          {:store, processed_audio} ->
            {:noreply, store_audio(state, processed_audio)}
          :ignore ->
            {:noreply, state}
        end
      end
  """
  @callback handle_info(msg :: term(), state) ::
              {[media_action()], state}
              | {media_action(), state}
              | {:noreply, state}
              | {:stop, reason :: term(), state}

  # Optional callbacks - all except init
  @optional_callbacks [
    handle_session_stop: 3,
    handle_offer: 3,
    handle_answer: 3,
    handle_stream_stop: 3,
    handle_stream_error: 3,
    handle_play_complete: 2,
    handle_media_request: 2,
    handle_info: 2
  ]
end
