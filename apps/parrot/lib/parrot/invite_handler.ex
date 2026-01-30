defmodule Parrot.InviteHandler do
  @moduledoc """
  Behaviour for handling incoming INVITE requests in Parrot VoIP applications.

  The InviteHandler provides a declarative, pipeline-based API for building
  call handling logic. Implement this behaviour to define how your application
  responds to incoming calls, DTMF input, and various call events.

  ## Usage

  Use `use Parrot.InviteHandler` in your module to get default implementations
  of all callbacks and import `Parrot.Call` functions for building pipelines:

      defmodule MyApp.IVRHandler do
        use Parrot.InviteHandler

        def handle_invite(invite) do
          invite
          |> answer()
          |> assign(:menu, :main)
          |> play("welcome.wav")
        end

        def handle_dtmf("1", %{assigns: %{menu: :main}} = call) do
          call
          |> assign(:menu, :sales)
          |> bridge("sip:sales@internal")
        end

        def handle_dtmf("2", %{assigns: %{menu: :main}} = call) do
          call
          |> assign(:menu, :support)
          |> bridge("sip:support@internal")
        end

        def handle_dtmf(_digit, call) do
          call |> play("invalid-option.wav")
        end
      end

  ## The `prompt/3` Pattern

  The `prompt/3` function provides a convenient way to play an audio file
  and then collect DTMF digits. It works by storing the collection options
  in `assigns[:__pending_collect__]` and queuing a play operation.

  When the audio finishes, your `handle_play_complete/2` callback is invoked.
  You must check for pending collect options and start DTMF collection:

      def handle_play_complete(_file, %{assigns: %{__pending_collect__: opts}} = call)
          when not is_nil(opts) do
        call
        |> assign(:__pending_collect__, nil)
        |> collect_dtmf(opts)
      end

      def handle_play_complete(_file, call) do
        {:noreply, call}
      end

  This two-phase approach allows the play operation to complete before
  starting DTMF collection, ensuring proper timing of the IVR flow.

  ## Automatic SDP Negotiation

  When an INVITE with SDP is received, Parrot automatically handles SDP negotiation:

  1. Creates a MediaSession for the call
  2. Calls `MediaSession.process_offer/2` to negotiate codecs
  3. Includes the SDP answer in the 200 OK response

  If negotiation fails (e.g., no compatible codecs), the `handle_sdp_error/2` callback
  is invoked. The default implementation rejects with 488 Not Acceptable Here.

  Media lifecycle events are delivered via `handle_media_started/1` and
  `handle_media_stopped/2` callbacks for observability (e.g., tracking call duration,
  emitting telemetry).

  ## Callbacks

  All callbacks receive a `Parrot.Call` struct and should return either:
  - A `Parrot.Call` struct with operations queued (for most handlers)
  - `{:noreply, call}` for event handlers that don't queue operations

  ### Required Callbacks

  - `handle_invite/1` - Called when an INVITE is received. Must be implemented.

  ### Optional Callbacks (with defaults)

  All other callbacks have default implementations that return `{:noreply, call}`.
  Override only the ones you need:

  - `handle_play_complete/2` - Called when audio playback finishes
  - `handle_dtmf/2` - Called when DTMF digits are received or timeout occurs
  - `handle_prompt_complete/3` - Called when play+collect completes
  - `handle_bridge_complete/2` - Called when a bridge attempt completes
  - `handle_fork_complete/2` - Called when a fork attempt completes
  - `handle_record_complete/3` - Called when recording finishes
  - `handle_conference_join/2` - Called when joining a conference
  - `handle_conference_leave/3` - Called when leaving a conference
  - `handle_fork_media_connected/2` - Called when media fork connects
  - `handle_fork_media_error/3` - Called when media fork fails
  - `handle_hangup/1` - Called when the call ends
  - `handle_sdp_error/2` - Called when SDP negotiation fails
  - `handle_media_started/1` - Called when media stream starts
  - `handle_media_stopped/2` - Called when media stream stops
  - `handle_tts_error/3` - Called when TTS synthesis fails
  - `handle_leg_event/3` - Called when a B2BUA leg event occurs (ringing, answered, failed, bye, etc.)
  """

  alias Parrot.Call

  @doc """
  Called when an INVITE request is received.

  This is the entry point for call handling. Return a `Call` struct with
  operations queued to define how the call should be processed.

  ## Example

      def handle_invite(invite) do
        invite
        |> answer()
        |> play("welcome.wav")
      end
  """
  @callback handle_invite(call :: Call.t()) :: Call.t()

  @doc """
  Called when audio playback completes.

  ## Arguments

  - `filename` - The file that finished playing
  - `call` - The current call state

  ## Return

  Return `{:noreply, call}` or a `Call` struct with new operations.
  """
  @callback handle_play_complete(filename :: String.t(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when DTMF digits are received or collection times out.

  ## Arguments

  - `digits_or_timeout` - The collected digits as a string, or `:timeout`
  - `call` - The current call state

  ## Example

      def handle_dtmf("1", call), do: call |> play("option-one.wav")
      def handle_dtmf(:timeout, call), do: call |> play("goodbye.wav") |> hangup()
  """
  @callback handle_dtmf(digits_or_timeout :: String.t() | :timeout, call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when a prompt (play + collect) completes.

  ## Arguments

  - `filename` - The prompt file that was played
  - `digits` - The collected DTMF digits
  - `call` - The current call state
  """
  @callback handle_prompt_complete(filename :: String.t(), digits :: String.t(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when a bridge attempt completes.

  ## Arguments

  - `result` - The bridge result:
    - `:answered` - B-leg answered
    - `{:failed, reason}` - Bridge failed with reason (`:busy`, `:no_answer`, etc.)
  - `call` - The current call state
  """
  @callback handle_bridge_complete(result :: :answered | {:failed, atom()}, call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when a fork attempt completes.

  ## Arguments

  - `result` - The fork result:
    - `{:answered, destination}` - Which destination answered
    - `{:failed, reason}` - All destinations failed
  - `call` - The current call state
  """
  @callback handle_fork_complete(
              result :: {:answered, String.t()} | {:failed, atom()},
              call :: Call.t()
            ) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when recording completes.

  ## Arguments

  - `filename` - The recording file path
  - `duration` - Recording duration in milliseconds
  - `call` - The current call state
  """
  @callback handle_record_complete(
              filename :: String.t(),
              duration :: non_neg_integer(),
              call :: Call.t()
            ) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when the call joins a conference.

  ## Arguments

  - `room` - The conference room identifier
  - `call` - The current call state
  """
  @callback handle_conference_join(room :: String.t(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when the call leaves a conference.

  ## Arguments

  - `room` - The conference room identifier
  - `reason` - Why the call left (`:normal`, `:kicked`, etc.)
  - `call` - The current call state
  """
  @callback handle_conference_leave(room :: String.t(), reason :: atom(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when a media fork connection is established.

  This callback is invoked when a media fork successfully connects to its
  destination (WebSocket URL or RTP endpoint). Use this for logging, telemetry,
  or updating call state.

  ## Arguments

  - `fork_id` - The fork identifier (may be auto-generated if not specified)
  - `call` - The current call state

  ## Example

      def handle_fork_media_connected(fork_id, call) do
        Logger.info("Media fork \#{fork_id} connected")
        {:noreply, %{call | assigns: Map.put(call.assigns, :fork_active, true)}}
      end
  """
  @callback handle_fork_media_connected(fork_id :: String.t(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when a media fork fails to connect or encounters an error.

  This callback is invoked when a media fork cannot connect to its destination
  or encounters an error during streaming. Use this for error handling, fallback
  logic, or retry mechanisms.

  ## Arguments

  - `fork_id` - The fork identifier
  - `reason` - The error reason (e.g., `:connection_refused`, `:timeout`, `{:ws_error, code}`)
  - `call` - The current call state

  ## Example

      def handle_fork_media_error(fork_id, reason, call) do
        Logger.warning("Media fork \#{fork_id} failed: \#{inspect(reason)}")
        # Optionally retry with a different endpoint
        {:noreply, call}
      end

      # Retry with fallback transcription service
      def handle_fork_media_error(fork_id, _reason, %{assigns: %{retry_count: n}} = call) when n < 3 do
        call
        |> assign(:retry_count, n + 1)
        |> fork_media("wss://backup-transcription.example.com/audio", fork_id: fork_id)
      end
  """
  @callback handle_fork_media_error(fork_id :: String.t(), reason :: term(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when the call ends.

  Use this for cleanup logic like updating presence or logging.

  ## Arguments

  - `call` - The final call state
  """
  @callback handle_hangup(call :: Call.t()) :: {:noreply, Call.t()} | Call.t()

  @doc """
  Called when SDP negotiation fails (FR-009, FR-012).

  This callback is invoked when `MediaSession.process_offer/2` fails, typically due to:
  - `:codec_mismatch` - No common codec between offer and server capabilities
  - `:invalid_sdp` - Malformed SDP in the INVITE body
  - `:media_session_error` - MediaSession creation or process_offer failed

  The default implementation rejects the call with 488 Not Acceptable Here.
  Override this to implement custom error handling (e.g., logging, alternative responses).

  ## Arguments

  - `reason` - The error reason (atom)
  - `call` - The current call state

  ## Example

      # Custom handler that logs and rejects with a different code
      def handle_sdp_error(reason, call) do
        Logger.error("SDP negotiation failed: \#{inspect(reason)}")
        call |> reject(406)
      end

      # Handler that accepts calls without SDP (late-offer flow)
      def handle_sdp_error(:no_sdp, call) do
        call |> answer()  # Will use late-offer flow
      end

      def handle_sdp_error(_reason, call) do
        call |> reject(488)
      end
  """
  @callback handle_sdp_error(reason :: atom(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when the media session is established and media starts flowing (FR-010).

  This callback is invoked when the MediaSession signals that media has started.
  Use this for observability tasks such as:
  - Recording the call start time for duration tracking
  - Starting call recording
  - Updating call state for monitoring
  - Emitting telemetry events

  The default implementation returns `{:noreply, call}`.

  ## Arguments

  - `call` - The current call state

  ## Example

      def handle_media_started(call) do
        start_time = System.monotonic_time(:millisecond)
        {:noreply, %{call | assigns: Map.put(call.assigns, :media_started_at, start_time)}}
      end
  """
  @callback handle_media_started(call :: Call.t()) :: {:noreply, Call.t()} | Call.t()

  @doc """
  Called when the media session stops (FR-011).

  This callback is invoked when the MediaSession signals that media has stopped.
  The reason indicates why media stopped:
  - `:normal` - Normal termination (e.g., BYE received)
  - `:terminated` - Call was terminated
  - `:error` - Media error occurred
  - Other atoms as appropriate

  Use this for observability and cleanup tasks such as:
  - Calculating call duration
  - Finalizing call recordings
  - Updating CDR records
  - Emitting telemetry events

  The default implementation returns `{:noreply, call}`.

  ## Arguments

  - `reason` - The reason for media stopping (atom)
  - `call` - The current call state

  ## Example

      def handle_media_stopped(reason, call) do
        duration = calculate_duration(call.assigns[:media_started_at])
        Logger.info("Call ended after \#{duration}ms, reason: \#{reason}")
        {:noreply, call}
      end
  """
  @callback handle_media_stopped(reason :: atom(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when TTS synthesis fails (FR-017, FR-018, FR-019).

  This callback is invoked when the `say/2` or `say_prompt/3` operations fail to
  synthesize text to audio. The default implementation logs a warning and returns
  `{:noreply, call}`, allowing the call to continue.

  Override this to implement custom error handling such as:
  - Playing a fallback audio file
  - Tracking error metrics
  - Retrying with a different TTS provider
  - Terminating the call after multiple failures

  ## Arguments

  - `text` - The text that failed to synthesize
  - `error` - The error reason (may be an atom or tuple with details)
  - `call` - The current call state

  ## Return

  Return `{:noreply, call}` or a `Call` struct with new operations.

  ## Example

      # Play fallback audio when TTS fails
      def handle_tts_error(_text, _error, call) do
        call |> play("tts-error-fallback.wav")
      end

      # Track errors and hang up after 3 failures
      def handle_tts_error(_text, _error, %{assigns: %{tts_errors: n}} = call) when n >= 2 do
        call |> play("goodbye.wav") |> hangup()
      end

      def handle_tts_error(text, error, call) do
        Logger.warning("TTS failed for: \#{text}, error: \#{inspect(error)}")
        count = Map.get(call.assigns, :tts_errors, 0)
        {:noreply, %{call | assigns: Map.put(call.assigns, :tts_errors, count + 1)}}
      end
  """
  @callback handle_tts_error(text :: String.t(), error :: term(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when a leg event occurs in a B2BUA scenario (T07).

  This callback is invoked when a leg (outbound call) experiences a state change
  during call bridging, forking, or transfer operations. Use pattern matching on
  the event to handle different leg states.

  ## Arguments

  - `call` - The current call state
  - `leg_id` - The identifier for the leg (atom like `:b_leg` or string like `"custom-leg-123"`)
  - `event` - The event that occurred (see Events below)

  ## Events

  | Event | Description |
  |-------|-------------|
  | `:trying` | Outbound INVITE sent |
  | `:ringing` | Received 180 Ringing |
  | `{:early_media, sdp}` | Received 183 with SDP |
  | `{:answered, sdp}` | Received 200 OK |
  | `{:failed, reason}` | Leg failed |
  | `:bye` | Remote party sent BYE |
  | `:cancelled` | Leg cancelled (another answered) |
  | `:held` | Leg placed on hold |
  | `:resumed` | Leg resumed |
  | `{:refer_requested, uri}` | Remote sent REFER |
  | `{:transfer_complete, leg_id}` | Transfer succeeded |
  | `{:transfer_failed, reason}` | Transfer failed |

  ## Return Values

  | Return | Effect |
  |--------|--------|
  | `{:ok, call}` | Continue |
  | `{:bridge, leg_id, call}` | Connect this leg to A-leg |
  | `{:reject_refer, reason, call}` | Reject REFER request |

  ## Example

      def handle_leg_event(call, leg_id, :ringing) do
        Logger.info("\#{leg_id} is ringing")
        {:ok, call}
      end

      def handle_leg_event(call, leg_id, {:answered, _sdp}) do
        Logger.info("\#{leg_id} answered")
        {:ok, call}
      end

      def handle_leg_event(call, leg_id, {:failed, reason}) do
        Logger.warn("\#{leg_id} failed: \#{inspect(reason)}")
        {:ok, call |> play("unavailable.wav") |> hangup()}
      end

      def handle_leg_event(call, _leg_id, :bye) do
        {:ok, call |> hangup()}
      end

      # Bridge on answer during fork
      def handle_leg_event(call, leg_id, {:answered, _sdp}) do
        {:bridge, leg_id, call}
      end

      # Reject transfers from untrusted legs
      def handle_leg_event(call, :untrusted_leg, {:refer_requested, _uri}) do
        {:reject_refer, :forbidden, call}
      end
  """
  @callback handle_leg_event(
              call :: Call.t(),
              leg_id :: atom() | String.t(),
              event :: leg_event()
            ) ::
              {:ok, Call.t()}
              | {:bridge, atom() | String.t(), Call.t()}
              | {:reject_refer, atom(), Call.t()}

  @typedoc """
  Leg events that can occur during B2BUA operations.

  - `:trying` - Outbound INVITE sent
  - `:ringing` - Received 180 Ringing
  - `{:early_media, sdp}` - Received 183 with SDP
  - `{:answered, sdp}` - Received 200 OK
  - `{:failed, reason}` - Leg failed
  - `:bye` - Remote party sent BYE
  - `:cancelled` - Leg cancelled (another answered)
  - `:held` - Leg placed on hold
  - `:resumed` - Leg resumed
  - `{:refer_requested, uri}` - Remote sent REFER
  - `{:transfer_complete, leg_id}` - Transfer succeeded
  - `{:transfer_failed, reason}` - Transfer failed
  """
  @type leg_event ::
          :trying
          | :ringing
          | {:early_media, String.t()}
          | {:answered, String.t()}
          | {:failed, atom() | term()}
          | :bye
          | :cancelled
          | :held
          | :resumed
          | {:refer_requested, String.t()}
          | {:transfer_complete, atom() | String.t()}
          | {:transfer_failed, atom() | term()}

  @doc """
  Provides default implementations and imports Call functions.

  When you `use Parrot.InviteHandler`, you get:

  1. Default implementations of all callbacks (returning `{:noreply, call}`)
  2. Import of all `Parrot.Call` functions for pipeline operations
  3. The `@behaviour Parrot.InviteHandler` annotation

  Override any callback by defining it in your module.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Parrot.InviteHandler

      import Parrot.Call,
        only: [
          answer: 1,
          answer: 2,
          reject: 2,
          hangup: 1,
          assign: 3,
          play: 2,
          play: 3,
          say: 2,
          say: 3,
          say_prompt: 2,
          say_prompt: 3,
          record: 2,
          record: 3,
          stop_record: 1,
          collect_dtmf: 1,
          collect_dtmf: 2,
          prompt: 2,
          prompt: 3,
          bridge: 2,
          bridge: 3,
          fork: 2,
          fork: 3,
          fork_media: 2,
          fork_media: 3,
          stop_fork_media: 2,
          # B2BUA operations
          originate: 2,
          originate: 3,
          connect_legs: 3,
          connect_legs: 4,
          hold: 2,
          resume: 2,
          transfer: 3,
          transfer: 4,
          hangup_leg: 2
        ]

      @impl Parrot.InviteHandler
      def handle_play_complete(_filename, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_dtmf(_digits_or_timeout, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_prompt_complete(_filename, _digits, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_bridge_complete(_result, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_fork_complete(_result, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_record_complete(_filename, _duration, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_conference_join(_room, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_conference_leave(_room, _reason, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_fork_media_connected(_fork_id, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_fork_media_error(_fork_id, _reason, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_hangup(call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_sdp_error(_reason, call) do
        # Default: reject with 488 Not Acceptable Here (FR-012)
        call |> reject(488)
      end

      @impl Parrot.InviteHandler
      def handle_media_started(call) do
        # Default: return {:noreply, call} (FR-010)
        # Handlers can override to track call start time, emit telemetry, etc.
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_media_stopped(_reason, call) do
        # Default: return {:noreply, call} (FR-011)
        # Handlers can override to calculate duration, finalize recordings, etc.
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_tts_error(text, error, call) do
        # Default: log warning and return {:noreply, call} (FR-018)
        # This allows the call to continue without crashing
        require Logger
        Logger.warning("TTS synthesis failed for text #{inspect(text)}: #{inspect(error)}")
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_leg_event(call, _leg_id, _event) do
        # Default: return {:ok, call} (T07)
        # Handler controls all termination - no automatic cleanup
        {:ok, call}
      end

      defoverridable handle_play_complete: 2,
                     handle_dtmf: 2,
                     handle_prompt_complete: 3,
                     handle_bridge_complete: 2,
                     handle_fork_complete: 2,
                     handle_record_complete: 3,
                     handle_conference_join: 2,
                     handle_conference_leave: 3,
                     handle_fork_media_connected: 2,
                     handle_fork_media_error: 3,
                     handle_hangup: 1,
                     handle_sdp_error: 2,
                     handle_tts_error: 3,
                     handle_media_started: 1,
                     handle_media_stopped: 2,
                     handle_leg_event: 3
    end
  end
end
