defmodule Parrot.Call do
  @moduledoc """
  Represents a VoIP call and provides a pipeline-friendly API for call operations.

  The Call struct is the central data structure for building call handling logic
  in Parrot. It supports pipeline operations via the `|>` operator, allowing you
  to chain signaling, media, and bridging operations in a declarative style.

  ## Usage

  Build call handling pipelines:

      call
      |> answer()
      |> assign(:menu, :main)
      |> play("welcome.wav")
      |> prompt("enter-pin.wav", collect: [max: 4, timeout: 10_000])

  Each operation returns the updated call struct with the operation recorded
  in an internal list for later execution by the framework.

  ## Fields

  * `:id` - Unique identifier for this call session
  * `:handler` - The module implementing `Parrot.InviteHandler` for this call
  * `:from` - The SIP From URI (caller)
  * `:to` - The SIP To URI (callee)
  * `:call_id` - SIP Call-ID header value
  * `:state` - Current call state (`:incoming`, `:ringing`, `:answered`, `:terminated`)
  * `:method` - The SIP method (typically "INVITE")
  * `:assigns` - Per-call state storage (map)
  * `:__operations__` - Internal list of operations to execute (do not modify directly)

  ## Operations

  ### Signaling
  * `answer/1`, `answer/2` - Answer the call
  * `reject/2` - Reject the call with a status code
  * `hangup/1` - Hang up the call

  ### State
  * `assign/3` - Store per-call state

  ### Playback
  * `play/2`, `play/3` - Play audio file(s)

  ### Text-to-Speech
  * `say/2`, `say/3` - Synthesize and play text
  * `say_prompt/3` - Synthesize and play text, then collect DTMF digits

  ### Recording
  * `record/2`, `record/3` - Start recording
  * `stop_record/1` - Stop recording

  ### DTMF
  * `collect_dtmf/2` - Collect DTMF digits
  * `prompt/3` - Play audio and collect DTMF

  ### Bridging
  * `bridge/2`, `bridge/3` - Bridge to another endpoint
  * `fork/2`, `fork/3` - Fork call to multiple endpoints

  ### B2BUA Operations
  * `originate/2`, `originate/3` - Create outbound leg
  * `connect_legs/3`, `connect_legs/4` - Connect two legs for media bridging
  * `hold/2` - Put a leg on hold
  * `resume/2` - Resume a held leg
  * `transfer/3`, `transfer/4` - Transfer a leg (blind or attended)
  * `hangup_leg/2` - Hang up a specific leg
  """

  @type call_state :: :incoming | :ringing | :answered | :terminated

  @type t :: %__MODULE__{
          id: String.t() | nil,
          handler: module() | nil,
          from: String.t() | nil,
          to: String.t() | nil,
          call_id: String.t() | nil,
          state: call_state(),
          method: String.t() | nil,
          assigns: map(),
          __operations__: list(),
          __uas__: term() | nil,
          __media_pid__: pid() | nil,
          __dialog_id__: String.t() | nil,
          __sip_msg__: term() | nil,
          __bidirectional_ws_pid__: pid() | nil
        }

  defstruct id: nil,
            handler: nil,
            from: nil,
            to: nil,
            call_id: nil,
            state: :incoming,
            method: nil,
            assigns: %{},
            __operations__: [],
            __uas__: nil,
            __media_pid__: nil,
            __dialog_id__: nil,
            __sip_msg__: nil,
            __bidirectional_ws_pid__: nil

  @doc """
  Creates a new Call struct from keyword options.

  ## Options

  * `:id` - Unique call ID (auto-generated if not provided)
  * `:handler` - Handler module implementing `Parrot.InviteHandler`
  * `:from` - The SIP From URI
  * `:to` - The SIP To URI
  * `:call_id` - SIP Call-ID header
  * `:method` - The SIP method

  ## Examples

      Call.new(from: "sip:alice@example.com", to: "sip:bob@example.com", method: "INVITE")

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id) || generate_id(),
      handler: Keyword.get(opts, :handler),
      from: Keyword.get(opts, :from),
      to: Keyword.get(opts, :to),
      call_id: Keyword.get(opts, :call_id),
      state: Keyword.get(opts, :state, :incoming),
      method: Keyword.get(opts, :method),
      assigns: Keyword.get(opts, :assigns, %{}),
      __operations__: [],
      __uas__: Keyword.get(opts, :uas),
      __media_pid__: Keyword.get(opts, :media_pid),
      __dialog_id__: Keyword.get(opts, :dialog_id),
      __sip_msg__: Keyword.get(opts, :sip_msg)
    }
  end

  @doc """
  Generates a unique call ID.

  ## Examples

      iex> id = Parrot.Call.generate_id()
      iex> is_binary(id) and String.length(id) > 0
      true
  """
  @spec generate_id() :: String.t()
  def generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Signaling Operations
  # ---------------------------------------------------------------------------

  @doc """
  Answers the call with default options.

  ## Examples

      call |> answer()

  """
  @spec answer(t()) :: t()
  def answer(%__MODULE__{} = call) do
    add_operation(call, {:answer, []})
  end

  @doc """
  Answers the call with SDP options.

  ## Options

  * `:codecs` - List of codecs to offer

  ## Examples

      call |> answer(codecs: [:pcma])

  """
  @spec answer(t(), keyword()) :: t()
  def answer(%__MODULE__{} = call, opts) when is_list(opts) do
    add_operation(call, {:answer, opts})
  end

  @doc """
  Rejects the call with the given SIP status code.

  ## Examples

      call |> reject(486)  # Busy Here
      call |> reject(403)  # Forbidden

  """
  @spec reject(t(), integer()) :: t()
  def reject(%__MODULE__{} = call, status_code) when is_integer(status_code) do
    add_operation(call, {:reject, status_code})
  end

  @doc """
  Hangs up the call.

  ## Examples

      call |> hangup()

  """
  @spec hangup(t()) :: t()
  def hangup(%__MODULE__{} = call) do
    add_operation(call, {:hangup, []})
  end

  # ---------------------------------------------------------------------------
  # State Operations
  # ---------------------------------------------------------------------------

  @doc """
  Assigns a key-value pair to the call's assigns map.

  Assigns are per-call state that persists for the duration of the call.
  Use this to store menu state, retry counters, or any call-specific data.

  ## Examples

      call
      |> assign(:menu, :main)
      |> assign(:retries, 0)

  """
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{assigns: assigns} = call, key, value) when is_atom(key) do
    %{call | assigns: Map.put(assigns, key, value)}
  end

  # ---------------------------------------------------------------------------
  # Playback Operations
  # ---------------------------------------------------------------------------

  @doc """
  Plays an audio file or list of files.

  ## Examples

      call |> play("welcome.wav")
      call |> play(["intro.wav", "menu.wav"])

  """
  @spec play(t(), String.t() | list(String.t())) :: t()
  def play(%__MODULE__{} = call, file_or_files) do
    add_operation(call, {:play, file_or_files, []})
  end

  @doc """
  Plays an audio file with options.

  ## Options

  * `:loop` - Whether to loop the audio (default: false)
  * `:volume` - Volume level (0.0 to 1.0)

  ## Examples

      call |> play("music.wav", loop: true)
      call |> play("audio.wav", loop: true, volume: 0.8)

  """
  @spec play(t(), String.t() | list(String.t()), keyword()) :: t()
  def play(%__MODULE__{} = call, file_or_files, opts) when is_list(opts) do
    add_operation(call, {:play, file_or_files, opts})
  end

  # ---------------------------------------------------------------------------
  # Text-to-Speech Operations
  # ---------------------------------------------------------------------------

  @doc """
  Synthesizes and plays text using text-to-speech with default profile.

  The text will be converted to speech using the default TTS profile
  configured for the application.

  ## Examples

      call |> say("Hello, welcome to our service.")
      call |> say("Please enter your account number.")

  """
  @spec say(t(), String.t()) :: t()
  def say(%__MODULE__{} = call, text) when is_binary(text) do
    add_operation(call, {:say, text, []})
  end

  @doc """
  Synthesizes and plays text using text-to-speech with options.

  ## Options

  * `:profile` - Named TTS profile to use (e.g., `:announcements`, `:prompts`)
  * `:voice` - Voice identifier to use (e.g., "en-US-Neural2-F")
  * `:engine` - TTS engine to use (e.g., `:google`, `:aws`, `:azure`)
  * `:language` - Language/locale code (e.g., "en-US", "fr-FR")

  ## Examples

      call |> say("Hello there", profile: :announcements)
      call |> say("Welcome", voice: "en-US-Neural2-F")
      call |> say("Bonjour", language: "fr-FR", engine: :google)

  """
  @spec say(t(), String.t(), keyword()) :: t()
  def say(%__MODULE__{} = call, text, opts) when is_binary(text) and is_list(opts) do
    add_operation(call, {:say, text, opts})
  end

  # ---------------------------------------------------------------------------
  # DTMF Operations
  # ---------------------------------------------------------------------------

  @default_collect_opts [max: 20, timeout: 30_000, terminators: []]

  @doc """
  Starts DTMF digit collection on the active call.

  ## Options

    * `:max` - Maximum digits to collect (default: 20)
    * `:timeout` - Timeout in milliseconds (default: 30,000)
    * `:terminators` - Digits that end collection early (default: [])

  ## Examples

      call |> collect_dtmf(max: 4, timeout: 10_000, terminators: ["#"])

  """
  @spec collect_dtmf(t(), keyword()) :: t()
  def collect_dtmf(%__MODULE__{} = call, opts \\ []) do
    opts = Keyword.merge(@default_collect_opts, opts)
    add_operation(call, {:collect_dtmf, opts})
  end

  @doc """
  Plays an audio file then starts DTMF collection after playback completes.

  The handler must check for `__pending_collect__` in `handle_play_complete/2`:

      def handle_play_complete(file, %{assigns: %{__pending_collect__: opts}} = call)
          when not is_nil(opts) do
        call
        |> assign(:__pending_collect__, nil)
        |> collect_dtmf(opts)
      end

  ## Options

  Same as `collect_dtmf/2`:
    * `:max` - Maximum digits to collect (default: 20)
    * `:timeout` - Timeout in milliseconds (default: 30,000)
    * `:terminators` - Digits that end collection early (default: [])

  ## Examples

      call |> prompt("enter-pin.wav", max: 4, timeout: 10_000)

  """
  @spec prompt(t(), String.t(), keyword()) :: t()
  def prompt(%__MODULE__{} = call, file, opts \\ []) do
    call
    |> assign(:__pending_collect__, opts)
    |> play(file)
  end

  @doc """
  Synthesizes text using TTS and plays it, then starts DTMF collection after playback.

  This function combines `say/3` with DTMF collection. The text is synthesized
  using the configured TTS profile, played to the caller, and then DTMF
  collection begins automatically after playback completes.

  The handler must check for `__pending_collect__` in `handle_play_complete/2`
  (same pattern as `prompt/3`).

  ## Options

  TTS options (passed to synthesizer):
    * `:profile` - Named TTS profile to use (default: `:default`)
    * `:voice` - Voice identifier to use
    * `:engine` - TTS engine to use
    * `:language` - Language/locale code

  DTMF collection options:
    * `:max` - Maximum digits to collect (default: 20)
    * `:timeout` - Timeout in milliseconds (default: 30,000)
    * `:terminators` - Digits that end collection early (default: [])

  ## Examples

      # Simple PIN entry with TTS
      call |> say_prompt("Please enter your 4-digit PIN.", max: 4, timeout: 10_000)

      # With TTS profile and DTMF terminator
      call |> say_prompt("Enter your account number followed by pound.",
        max: 10,
        terminators: ["#"],
        profile: :prompts
      )

  """
  @spec say_prompt(t(), String.t(), keyword()) :: t()
  def say_prompt(%__MODULE__{} = call, text, opts \\ []) when is_binary(text) do
    # Merge with default DTMF collection options
    opts = Keyword.merge(@default_collect_opts, opts)

    # Extract DTMF collection options for __pending_collect__
    collect_keys = [:max, :timeout, :terminators]
    collect_opts = Keyword.take(opts, collect_keys)

    call
    |> assign(:__pending_collect__, collect_opts)
    |> add_operation({:say_prompt, text, opts})
  end

  # ---------------------------------------------------------------------------
  # Recording Operations
  # ---------------------------------------------------------------------------

  @doc """
  Starts recording to the specified file.

  ## Examples

      call |> record("recording.wav")

  """
  @spec record(t(), String.t()) :: t()
  def record(%__MODULE__{} = call, filename) when is_binary(filename) do
    add_operation(call, {:record, filename, []})
  end

  @doc """
  Starts recording with options.

  ## Options

  * `:max_duration` - Maximum recording duration in milliseconds
  * `:beep` - Whether to play a beep before recording (default: false)

  ## Examples

      call |> record("recording.wav", max_duration: 60_000)
      call |> record("recording.wav", max_duration: 60_000, beep: true)

  """
  @spec record(t(), String.t(), keyword()) :: t()
  def record(%__MODULE__{} = call, filename, opts)
      when is_binary(filename) and is_list(opts) do
    add_operation(call, {:record, filename, opts})
  end

  @doc """
  Stops the current recording.

  ## Examples

      call |> stop_record()

  """
  @spec stop_record(t()) :: t()
  def stop_record(%__MODULE__{} = call) do
    add_operation(call, {:stop_record, []})
  end

  # ---------------------------------------------------------------------------
  # Bridging Operations
  # ---------------------------------------------------------------------------

  @doc """
  Bridges the call to another endpoint.

  ## Examples

      call |> bridge("sip:dest@somewhere")

  """
  @spec bridge(t(), String.t()) :: t()
  def bridge(%__MODULE__{} = call, destination) when is_binary(destination) do
    add_operation(call, {:bridge, destination, []})
  end

  @doc """
  Bridges the call to another endpoint with options.

  ## Options

  * `:timeout` - Timeout in milliseconds
  * `:headers` - Map of headers to add to the outgoing INVITE
  * `:handler` - B-leg handler module

  ## Examples

      call |> bridge("sip:dest@somewhere", timeout: 30_000)
      call |> bridge("sip:dest@somewhere", handler: MyBLegHandler)

  """
  @spec bridge(t(), String.t(), keyword()) :: t()
  def bridge(%__MODULE__{} = call, destination, opts)
      when is_binary(destination) and is_list(opts) do
    add_operation(call, {:bridge, destination, opts})
  end

  @doc """
  Forks the call to multiple endpoints.

  ## Examples

      destinations = [
        {"sip:alice@device1", handler: Handler1},
        {"sip:alice@device2", handler: Handler2}
      ]
      call |> fork(destinations)

  """
  @spec fork(t(), list()) :: t()
  def fork(%__MODULE__{} = call, destinations) when is_list(destinations) do
    add_operation(call, {:fork, destinations, []})
  end

  @doc """
  Forks the call to multiple endpoints with options.

  ## Options

  * `:strategy` - Fork strategy (`:first_answer`, `:ring_all`)
  * `:timeout` - Timeout in milliseconds

  ## Examples

      call |> fork(destinations, strategy: :first_answer, timeout: 30_000)

  """
  @spec fork(t(), list(), keyword()) :: t()
  def fork(%__MODULE__{} = call, destinations, opts)
      when is_list(destinations) and is_list(opts) do
    add_operation(call, {:fork, destinations, opts})
  end

  # ---------------------------------------------------------------------------
  # B2BUA Operations
  # ---------------------------------------------------------------------------

  @typedoc """
  Leg identifier - can be an atom (e.g., :a_leg, :b_leg) or string.
  """
  @type leg_id :: atom() | String.t()

  @doc """
  Creates an outbound leg to the given destination.

  This provides explicit leg control for B2BUA scenarios where you need
  to manage individual call legs independently.

  ## Examples

      call |> originate("sip:dest@pbx.local")

  """
  @spec originate(t(), String.t()) :: t()
  def originate(%__MODULE__{} = call, destination) when is_binary(destination) do
    add_operation(call, {:originate, destination, []})
  end

  @doc """
  Creates an outbound leg to the given destination with options.

  ## Options

  * `:as` - Custom leg ID (atom or string). If not provided, auto-generated.
  * `:timeout` - Timeout in milliseconds for the origination attempt.
  * `:headers` - Map of custom SIP headers to add to the outgoing INVITE.

  ## Examples

      call |> originate("sip:dest@pbx.local", as: :b_leg)
      call |> originate("sip:dest@pbx.local", as: :b_leg, timeout: 30_000)
      call |> originate("sip:dest@pbx.local", headers: %{"X-Custom" => "value"})

  """
  @spec originate(t(), String.t(), keyword()) :: t()
  def originate(%__MODULE__{} = call, destination, opts)
      when is_binary(destination) and is_list(opts) do
    add_operation(call, {:originate, destination, opts})
  end

  @doc """
  Connects two answered legs for media bridging.

  Both legs must be in the answered state before connecting.

  ## Examples

      call |> connect_legs(:a_leg, :b_leg)
      call |> connect_legs("leg-1", "leg-2")

  """
  @spec connect_legs(t(), leg_id(), leg_id()) :: t()
  def connect_legs(%__MODULE__{} = call, leg_a, leg_b) do
    add_operation(call, {:connect_legs, leg_a, leg_b, []})
  end

  @doc """
  Connects two answered legs for media bridging with options.

  ## Options

  * `:media` - Media bridging mode: `:proxy` (default) or `:direct`

  ## Examples

      call |> connect_legs(:a_leg, :b_leg, media: :proxy)
      call |> connect_legs(:a_leg, :b_leg, media: :direct)

  """
  @spec connect_legs(t(), leg_id(), leg_id(), keyword()) :: t()
  def connect_legs(%__MODULE__{} = call, leg_a, leg_b, opts) when is_list(opts) do
    add_operation(call, {:connect_legs, leg_a, leg_b, opts})
  end

  @doc """
  Puts a leg on hold.

  When a leg is placed on hold, media is paused and the remote party
  typically receives hold music or silence.

  ## Examples

      call |> hold(:b_leg)
      call |> hold("custom-leg-id")

  """
  @spec hold(t(), leg_id()) :: t()
  def hold(%__MODULE__{} = call, leg_id) do
    add_operation(call, {:hold, leg_id})
  end

  @doc """
  Resumes a held leg.

  Restores media flow for a leg that was previously placed on hold.

  ## Examples

      call |> resume(:b_leg)
      call |> resume("custom-leg-id")

  """
  @spec resume(t(), leg_id()) :: t()
  def resume(%__MODULE__{} = call, leg_id) do
    add_operation(call, {:resume, leg_id})
  end

  @doc """
  Transfers a leg to a new destination (blind transfer).

  Blind transfer immediately redirects the leg to the new destination
  without consultation. Use `transfer/4` with `type: :attended` for
  attended (consultative) transfers.

  ## Examples

      call |> transfer(:b_leg, "sip:new-agent@pbx.local")

  ## RFC References

  - RFC 3515 - REFER method
  """
  @spec transfer(t(), leg_id(), String.t()) :: t()
  def transfer(%__MODULE__{} = call, leg_id, destination) when is_binary(destination) do
    add_operation(call, {:transfer, leg_id, destination, []})
  end

  @doc """
  Transfers a leg to a new destination with options.

  ## Options

  * `:type` - Transfer type: `:blind` (default) or `:attended`
  * `:timeout` - Timeout in milliseconds for the transfer attempt.
  * `:headers` - Map of custom SIP headers (e.g., Referred-By).

  ## Examples

      # Blind transfer (default)
      call |> transfer(:b_leg, "sip:new@pbx.local", type: :blind)

      # Attended (consultative) transfer
      call |> transfer(:b_leg, "sip:new@pbx.local", type: :attended)

      # With custom headers
      call |> transfer(:b_leg, "sip:new@pbx.local",
        headers: %{"Referred-By" => "sip:operator@pbx.local"}
      )

  ## RFC References

  - RFC 3515 - REFER method
  - RFC 3891 - REFER with Replaces (attended transfer)
  """
  @spec transfer(t(), leg_id(), String.t(), keyword()) :: t()
  def transfer(%__MODULE__{} = call, leg_id, destination, opts)
      when is_binary(destination) and is_list(opts) do
    add_operation(call, {:transfer, leg_id, destination, opts})
  end

  @doc """
  Hangs up a specific leg.

  Unlike `hangup/1` which terminates the entire call, this only
  terminates the specified leg. Useful when managing multiple legs
  in a B2BUA scenario.

  ## Examples

      call |> hangup_leg(:b_leg)
      call |> hangup_leg("custom-leg-id")

  """
  @spec hangup_leg(t(), leg_id()) :: t()
  def hangup_leg(%__MODULE__{} = call, leg_id) do
    add_operation(call, {:hangup_leg, leg_id})
  end

  # ---------------------------------------------------------------------------
  # Media Forking Operations
  # ---------------------------------------------------------------------------

  @doc """
  Forks media to an external service for processing.

  Media forking allows streaming a copy of the call's audio to an external
  destination via RTP. Common use cases include:

  - Real-time transcription services
  - Call recording servers
  - Audio analysis systems
  - AI-powered conversation analysis

  ## Arguments

  - `destination` - The destination in "host:port" format (e.g., "192.168.1.100:5000")

  ## Examples

      call |> fork_media("192.168.1.100:5000")
      call |> fork_media("transcription.example.com:8080")

  """
  @spec fork_media(t(), String.t()) :: t()
  def fork_media(%__MODULE__{} = call, destination) when is_binary(destination) do
    add_operation(call, {:fork_media, destination, []})
  end

  @doc """
  Forks media to an external service with options.

  ## Options

  * `:fork_id` - Unique identifier for this fork (used for stopping later)
  * `:transport` - Transport type (currently only `:rtp` is supported)

  ## Examples

      call |> fork_media("192.168.1.100:5000", fork_id: "transcription")
      call |> fork_media("192.168.1.100:5000", fork_id: "recording", transport: :rtp)

  """
  @spec fork_media(t(), String.t(), keyword()) :: t()
  def fork_media(%__MODULE__{} = call, destination, opts)
      when is_binary(destination) and is_list(opts) do
    add_operation(call, {:fork_media, destination, opts})
  end

  @doc """
  Stops a media fork by its ID.

  ## Arguments

  - `fork_id` - The unique identifier of the fork to stop

  ## Examples

      call |> stop_fork_media("transcription")

  """
  @spec stop_fork_media(t(), String.t()) :: t()
  def stop_fork_media(%__MODULE__{} = call, fork_id) when is_binary(fork_id) do
    add_operation(call, {:stop_fork_media, fork_id})
  end

  # ---------------------------------------------------------------------------
  # Bidirectional WebSocket Operations
  # ---------------------------------------------------------------------------

  @doc """
  Connects to a bidirectional WebSocket for real-time AI audio streaming.

  Establishes a WebSocket connection that enables bidirectional audio streaming
  between the call and an external AI service (e.g., OpenAI Realtime API).

  ## Examples

      call |> connect_bidirectional_ws("wss://api.openai.com/v1/realtime")

  """
  @spec connect_bidirectional_ws(t(), String.t()) :: t()
  def connect_bidirectional_ws(call, url), do: connect_bidirectional_ws(call, url, [])

  @doc """
  Connects to a bidirectional WebSocket with options.

  ## Options

  * `:headers` - List of HTTP headers for the WebSocket connection
  * `:callback_module` - Module implementing WebSocket message callbacks
  * `:callback_state` - Initial state for the callback module
  * `:inbound_format` - Audio format for inbound audio (AI → caller)
  * `:outbound_format` - Audio format for outbound audio (caller → AI)
  * `:sample_rate` - Sample rate for audio (e.g., 24000 for OpenAI)

  ## Examples

      call |> connect_bidirectional_ws("wss://api.openai.com/v1/realtime",
        headers: [{"Authorization", "Bearer token"}],
        callback_module: MyApp.OpenAICallback,
        sample_rate: 24000
      )

  """
  @spec connect_bidirectional_ws(t(), String.t(), keyword()) :: t()
  def connect_bidirectional_ws(%__MODULE__{} = call, url, opts)
      when is_binary(url) and is_list(opts) do
    add_operation(call, {:connect_bidirectional_ws, url, opts})
  end

  @doc """
  Disconnects from the bidirectional WebSocket.

  Gracefully closes the WebSocket connection and stops audio streaming.

  ## Examples

      call |> disconnect_bidirectional_ws()

  """
  @spec disconnect_bidirectional_ws(t()) :: t()
  def disconnect_bidirectional_ws(%__MODULE__{} = call) do
    add_operation(call, {:disconnect_bidirectional_ws, []})
  end

  @doc """
  Mutes outbound audio (caller → AI).

  Stops sending the caller's audio to the AI service while maintaining
  the connection. Useful during AI responses to prevent interruption.

  ## Examples

      call |> mute_outbound()

  """
  @spec mute_outbound(t()) :: t()
  def mute_outbound(%__MODULE__{} = call) do
    add_operation(call, {:mute_bidirectional, :outbound})
  end

  @doc """
  Unmutes outbound audio (caller → AI).

  Resumes sending the caller's audio to the AI service.

  ## Examples

      call |> unmute_outbound()

  """
  @spec unmute_outbound(t()) :: t()
  def unmute_outbound(%__MODULE__{} = call) do
    add_operation(call, {:unmute_bidirectional, :outbound})
  end

  @doc """
  Mutes inbound audio (AI → caller).

  Stops sending AI audio to the caller while maintaining the connection.

  ## Examples

      call |> mute_inbound()

  """
  @spec mute_inbound(t()) :: t()
  def mute_inbound(%__MODULE__{} = call) do
    add_operation(call, {:mute_bidirectional, :inbound})
  end

  @doc """
  Unmutes inbound audio (AI → caller).

  Resumes sending AI audio to the caller.

  ## Examples

      call |> unmute_inbound()

  """
  @spec unmute_inbound(t()) :: t()
  def unmute_inbound(%__MODULE__{} = call) do
    add_operation(call, {:unmute_bidirectional, :inbound})
  end

  @doc """
  Sends a message through the bidirectional WebSocket.

  Used to send control messages or data to the AI service,
  such as session configuration or conversation items.

  ## Examples

      call |> send_ws_message(~s({"type": "response.create"}))
      call |> send_ws_message(Jason.encode!(%{type: "session.update"}))

  """
  @spec send_ws_message(t(), String.t() | binary()) :: t()
  def send_ws_message(%__MODULE__{} = call, message) when is_binary(message) do
    add_operation(call, {:send_ws_message, message})
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns the list of operations in execution order.

  ## Examples

      call
      |> answer()
      |> play("welcome.wav")
      |> Call.get_operations()
      #=> [{:answer, []}, {:play, "welcome.wav", []}]

  """
  @spec get_operations(t()) :: list()
  def get_operations(%__MODULE__{__operations__: operations}) do
    Enum.reverse(operations)
  end

  # Private helper to add an operation to the list
  # Operations are stored in reverse order for O(1) prepend, reversed on read
  defp add_operation(%__MODULE__{__operations__: operations} = call, operation) do
    %{call | __operations__: [operation | operations]}
  end
end
