defmodule ParrotMedia.MediaSession do
  @moduledoc """
  Manages media sessions for SIP calls.

  MediaSession is responsible for:
    * SDP negotiation (offer/answer)
    * RTP port allocation
    * Media pipeline lifecycle management
    * Codec negotiation

  ## State Machine

  The MediaSession implements a state machine with the following states:
    * `:idle` - Initial state, waiting for SDP offer
    * `:negotiating` - Processing SDP offer/answer
    * `:ready` - Media parameters negotiated, ready to start
    * `:active` - Media flowing
    * `:terminating` - Cleanup in progress

  ## Example

      {:ok, session} = MediaSession.start_link(
        id: "session_123",
        dialog_id: "dialog_456",
        role: :uas,
        media_handler: MyApp.MediaHandler,
        handler_args: %{audio_file: "/path/to/audio.wav"}
      )

      {:ok, answer} = MediaSession.process_offer(session, sdp_offer)
  """

  @behaviour :gen_statem

  require Logger

  alias ExSDP
  alias ParrotMedia.{Inet, Sdp}
  alias ParrotMedia.MOS

  # Child spec for supervisor
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5000
    }
  end

  # State data structure
  defmodule Data do
    @moduledoc false
    defstruct [
      # Session ID
      :id,
      # Dialog ID this media session belongs to
      :dialog_id,
      # :uac or :uas
      :role,
      # Local SDP
      :local_sdp,
      # Remote SDP
      :remote_sdp,
      # RTP parameters
      :local_rtp_port,
      :remote_rtp_port,
      :remote_rtp_address,
      # RTP socket (kept open until pipeline takes ownership)
      :rtp_socket,
      # RTCP socket for receiving RTCP reports (RFC 3550)
      :rtcp_socket,
      # RTCP port (RTP port + 1)
      :local_rtcp_port,
      # RTCP receiver process PID
      :rtcp_receiver_pid,
      # Membrane pipeline PID
      :pipeline_pid,
      # Monitor reference for pipeline
      :pipeline_monitor,
      # Audio file to play (if any)
      :audio_file,
      # Owner process
      :owner_pid,
      # Monitor reference for owner
      :owner_monitor,
      # Media handler module
      :media_handler,
      # Media handler state
      :handler_state,
      # Supported codecs (ordered by preference)
      :supported_codecs,
      # Selected codec for this session
      :selected_codec,
      # Pipeline module to use
      :pipeline_module,
      # Audio source configuration
      :audio_source,
      # Audio sink configuration
      :audio_sink,
      # Output file for recording
      :output_file,
      # PortAudio device IDs
      :input_device_id,
      :output_device_id,
      # IP configuration for SDP
      :local_ip,
      :advertised_ip,
      # Process to notify of media events (play_complete, record_complete, dtmf_collected)
      :notify_pid,
      # DTMF collection state: %{max: int, terminators: list, timeout: int, digits: string, timer_ref: ref}
      :dtmf_collection,
      # Dynamic payload types from remote SDP (encoding name -> PT)
      # Per RFC 3551, PTs 96-127 are dynamically assigned
      # Example: %{"telephone-event" => 96, "no-op" => 97}
      :dynamic_payload_types,
      # Media direction for SDP (sendrecv, sendonly, recvonly, inactive)
      direction: :sendrecv,
      # MOS Calculator PID (if MOS monitoring is enabled)
      mos_calculator_pid: nil,
      # RTP forwarding configuration for B2BUA proxy mode
      # %{target_pid: pid(), direction: :both | :send_only | :recv_only} | nil
      rtp_forward_config: nil,
      # Whether RTP forwarding is paused
      rtp_forward_paused: false,
      # Fork.Manager PID for media forking
      fork_manager_pid: nil
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            dialog_id: String.t(),
            role: :uac | :uas,
            local_sdp: String.t() | nil,
            remote_sdp: String.t() | nil,
            local_rtp_port: non_neg_integer() | nil,
            remote_rtp_port: non_neg_integer() | nil,
            remote_rtp_address: String.t() | nil,
            rtp_socket: port() | nil,
            pipeline_pid: pid() | nil,
            pipeline_monitor: reference() | nil,
            audio_file: String.t() | nil,
            owner_pid: pid() | nil,
            owner_monitor: reference() | nil,
            media_handler: module(),
            handler_state: term(),
            supported_codecs: list(),
            selected_codec: atom() | nil,
            pipeline_module: module() | nil,
            audio_source: :file | :device | :silence | nil,
            audio_sink: :none | :device | :file | nil,
            output_file: String.t() | nil,
            input_device_id: non_neg_integer() | nil,
            output_device_id: non_neg_integer() | nil,
            local_ip: :auto | String.t() | tuple() | nil,
            advertised_ip: String.t() | tuple() | nil,
            notify_pid: pid() | nil,
            dtmf_collection: map() | nil,
            dynamic_payload_types: %{String.t() => non_neg_integer()} | nil,
            direction: :sendrecv | :sendonly | :recvonly | :inactive,
            mos_calculator_pid: pid() | nil,
            rtp_forward_config: %{target_pid: pid(), direction: :both | :send_only | :recv_only} | nil,
            rtp_forward_paused: boolean()
          }
  end

  # Public API

  @doc """
  Starts a media session.

  ## Required Options

  - `:id` - Session ID
  - `:dialog_id` - Dialog ID this session belongs to
  - `:role` - `:uac` or `:uas`
  - `:media_handler` - Media handler module implementing `ParrotMedia.MediaHandler` behaviour

  ## Optional Options

  - `:handler_args` - Arguments to pass to media handler init (defaults to %{})
  - `:owner` - Owner process PID (defaults to caller)
  - `:notify_pid` - Process to receive media event notifications (play_complete, record_complete, dtmf_collected)
  - `:audio_file` - Path to audio file to play (used when audio_source is :file)
  - `:audio_source` - Source of audio: `:file` | `:device` | `:silence` (defaults to :file if audio_file provided)
  - `:audio_sink` - Destination for received audio: `:none` | `:device` | `:file` (defaults to :none)
  - `:output_file` - Path to save received audio when audio_sink is :file
  - `:input_device_id` - PortAudio device ID for microphone when audio_source is :device
  - `:output_device_id` - PortAudio device ID for speaker when audio_sink is :device
  - `:supported_codecs` - List of supported codecs in preference order (defaults to [:pcma])
  - `:local_ip` - Local IP address for media: `:auto` | IP string | IP tuple (defaults to :auto)
  - `:advertised_ip` - IP to advertise in SDP if different from local_ip (for NAT scenarios)

  ## Notifications

  When `notify_pid` is set, the following messages will be sent to that process:

  - `{:media_event, session_id, {:play_complete, filename}}` - When audio file playback completes
  - `{:media_event, session_id, {:record_complete, filename, duration_ms}}` - When recording completes
  - `{:media_event, session_id, {:dtmf_collected, digits}}` - When DTMF collection completes
  - `{:media_event, session_id, {:dtmf_timeout, partial_digits}}` - When DTMF collection times out
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    Logger.debug("MediaSession.start_link called with opts: #{inspect(opts)}")

    result =
      :gen_statem.start_link(
        {:via, Registry, {ParrotMedia.Registry, {:media_session, opts[:id]}}},
        __MODULE__,
        opts,
        []
      )

    Logger.debug("MediaSession.start_link result: #{inspect(result)}")
    result
  end

  @doc """
  Generates an SDP offer (UAC case).

  ## Parameters

    * `session` - Session ID or PID
    * `timeout` - Optional timeout in milliseconds (default: 5000)
  """
  @spec generate_offer(String.t() | pid(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_offer(session, timeout \\ 5000) do
    :gen_statem.call(get_pid(session), :generate_offer, timeout)
  end

  @doc """
  Processes an SDP offer and generates an answer.

  ## Examples

      iex> {:ok, answer} = MediaSession.process_offer("session_1", "v=0\\r\\n...")
      {:ok, "v=0\\r\\no=- 123456 123456 IN IP4 127.0.0.1\\r\\n..."}

  ## Parameters

    * `session_id` - The session identifier
    * `sdp_offer` - The SDP offer as a string
    * `timeout` - Optional timeout in milliseconds (default: 5000)

  ## Returns

    * `{:ok, sdp_answer}` - Successfully negotiated, returns SDP answer
    * `{:error, reason}` - Negotiation failed
  """
  @spec process_offer(String.t() | pid(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def process_offer(session, sdp_offer, timeout \\ 5000) do
    Logger.debug("MediaSession.process_offer called for session: #{inspect(session)}")
    :gen_statem.call(get_pid(session), {:process_offer, sdp_offer}, timeout)
  end

  @doc """
  Processes an SDP answer (UAC case).

  ## Parameters

    * `session` - Session ID or PID
    * `sdp_answer` - The SDP answer as a string
    * `timeout` - Optional timeout in milliseconds (default: 5000)
  """
  @spec process_answer(String.t() | pid(), String.t(), timeout()) :: :ok | {:error, term()}
  def process_answer(session, sdp_answer, timeout \\ 5000) do
    :gen_statem.call(get_pid(session), {:process_answer, sdp_answer}, timeout)
  end

  @doc """
  Starts the media streams.

  ## Parameters

    * `session` - Session ID or PID
    * `timeout` - Optional timeout in milliseconds (default: 5000)
  """
  @spec start_media(String.t() | pid(), timeout()) :: :ok | {:error, term()}
  def start_media(session, timeout \\ 5000) do
    :gen_statem.call(get_pid(session), :start_media, timeout)
  end

  @doc """
  Pauses the media streams.

  ## Parameters

    * `session` - Session ID or PID
    * `timeout` - Optional timeout in milliseconds (default: 5000)
  """
  @spec pause_media(String.t() | pid(), timeout()) :: :ok | {:error, term()}
  def pause_media(session, timeout \\ 5000) do
    :gen_statem.call(get_pid(session), :pause_media, timeout)
  end

  @doc """
  Resumes the media streams.

  ## Parameters

    * `session` - Session ID or PID
    * `timeout` - Optional timeout in milliseconds (default: 5000)
  """
  @spec resume_media(String.t() | pid(), timeout()) :: :ok | {:error, term()}
  def resume_media(session, timeout \\ 5000) do
    :gen_statem.call(get_pid(session), :resume_media, timeout)
  end

  @doc """
  Terminates the media session.
  """
  @spec terminate_session(String.t() | pid()) :: :ok
  def terminate_session(session) do
    :gen_statem.stop(get_pid(session))
  end

  @doc """
  Sets the notify_pid for media event notifications.

  This allows setting or updating the process that receives media events
  (play_complete, record_complete, dtmf_collected, etc.) after the session
  has been created.

  ## Parameters

    * `session` - Session ID or PID
    * `pid` - The PID to receive media event notifications

  ## Returns

    * `:ok` on success
    * `{:error, reason}` on failure
  """
  @spec set_notify_pid(String.t() | pid(), pid()) :: :ok | {:error, term()}
  def set_notify_pid(session, pid) when is_pid(pid) do
    :gen_statem.call(get_pid(session), {:set_notify_pid, pid})
  end

  @doc """
  Sets RTP forwarding destination for proxy-mode B2BUA bridging.

  This configures the MediaSession to forward received RTP packets to another
  MediaSession, enabling proxy-mode B2BUA operation where media passes through
  the B2BUA.

  ## Parameters

    * `session` - Session ID or PID
    * `config` - Forwarding configuration map or nil to clear:
      * `:target_pid` - PID of the target MediaSession to forward to (required)
      * `:direction` - Direction of forwarding:
        * `:both` - Forward in both directions (default)
        * `:send_only` - Only forward outbound RTP
        * `:recv_only` - Only forward inbound RTP

  ## Returns

    * `:ok` on success
    * `{:error, :invalid_target_pid}` if target_pid is not a valid PID
    * `{:error, :invalid_direction}` if direction is not valid

  ## Examples

      # Configure bidirectional forwarding
      :ok = MediaSession.set_rtp_forward(session_a, %{
        target_pid: session_b_pid,
        direction: :both
      })

      # Clear forwarding configuration
      :ok = MediaSession.set_rtp_forward(session_a, nil)
  """
  @spec set_rtp_forward(String.t() | pid(), map() | nil, timeout()) :: :ok | {:error, term()}
  def set_rtp_forward(session, config, timeout \\ 5000) do
    :gen_statem.call(get_pid(session), {:set_rtp_forward, config}, timeout)
  end

  @doc """
  Pauses RTP forwarding.

  Temporarily stops forwarding RTP packets to the configured target.
  The forwarding configuration is preserved and can be resumed with `resume_forward/1`.

  ## Parameters

    * `session` - Session ID or PID
    * `timeout` - Optional timeout in milliseconds (default: 5000)

  ## Returns

    * `:ok` on success
    * `{:error, :no_forward_configured}` if no forwarding is configured
  """
  @spec pause_forward(String.t() | pid(), timeout()) :: :ok | {:error, term()}
  def pause_forward(session, timeout \\ 5000) do
    :gen_statem.call(get_pid(session), :pause_forward, timeout)
  end

  @doc """
  Resumes RTP forwarding after pause.

  Resumes forwarding RTP packets to the configured target after it was paused
  with `pause_forward/1`.

  ## Parameters

    * `session` - Session ID or PID
    * `timeout` - Optional timeout in milliseconds (default: 5000)

  ## Returns

    * `:ok` on success
    * `{:error, :no_forward_configured}` if no forwarding is configured
    * `{:error, :not_paused}` if forwarding is not currently paused
  """
  @spec resume_forward(String.t() | pid(), timeout()) :: :ok | {:error, term()}
  def resume_forward(session, timeout \\ 5000) do
    :gen_statem.call(get_pid(session), :resume_forward, timeout)
  end

  @doc """
  Forks media to an external destination.

  Creates a media fork that copies audio to a WebSocket or RTP endpoint.
  This is useful for real-time transcription, AI analysis, or recording.

  ## Parameters

    * `session` - Session ID or PID
    * `destination` - URL or address tuple:
      - `"ws://..." or "wss://..."` - WebSocket destination
      - `{ip_tuple, port}` - RTP destination
    * `opts` - Fork options:
      - `:direction` - `:rx`, `:tx`, or `:both` (default: `:both`)
      - `:format` - `:pcmu`, `:pcma`, `:opus`, or `:raw` (default: source format)
      - `:label` - Human-readable label for this fork
    * `timeout` - Optional timeout in milliseconds (default: 5000)

  ## Examples

      # Fork to WebSocket for transcription
      {:ok, fork_id} = MediaSession.fork_media(session_id, "wss://ai-service.com/audio")

      # Fork RX only to RTP endpoint
      {:ok, fork_id} = MediaSession.fork_media(session_id, {{192,168,1,100}, 5004}, direction: :rx)

  ## Returns

    * `{:ok, fork_id}` on success
    * `{:error, reason}` on failure
  """
  @spec fork_media(String.t() | pid(), String.t() | {tuple(), pos_integer()}, keyword(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def fork_media(session, destination, opts \\ [], timeout \\ 5000) do
    :gen_statem.call(get_pid(session), {:fork_media, destination, opts}, timeout)
  end

  @doc """
  Stops a media fork.

  Removes an active media fork by its ID.

  ## Parameters

    * `session` - Session ID or PID
    * `fork_id` - The fork identifier returned from `fork_media/4`
    * `timeout` - Optional timeout in milliseconds (default: 5000)

  ## Returns

    * `:ok` on success
    * `{:error, :not_found}` if fork doesn't exist
  """
  @spec stop_fork_media(String.t() | pid(), String.t(), timeout()) :: :ok | {:error, term()}
  def stop_fork_media(session, fork_id, timeout \\ 5000) do
    :gen_statem.call(get_pid(session), {:stop_fork_media, fork_id}, timeout)
  end

  @doc """
  Lists all active media forks.

  ## Parameters

    * `session` - Session ID or PID
    * `timeout` - Optional timeout in milliseconds (default: 5000)

  ## Returns

    * List of ForkState structs for all active forks
  """
  @spec list_forks(String.t() | pid(), timeout()) :: [ParrotMedia.Fork.Types.ForkState.t()]
  def list_forks(session, timeout \\ 5000) do
    :gen_statem.call(get_pid(session), :list_forks, timeout)
  end

  # Callbacks

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(opts) do
    # Required parameters
    id = Keyword.fetch!(opts, :id)
    dialog_id = Keyword.fetch!(opts, :dialog_id)
    role = Keyword.fetch!(opts, :role)
    media_handler = Keyword.fetch!(opts, :media_handler)

    # Optional parameters
    owner_pid = Keyword.get(opts, :owner, self())
    audio_file = Keyword.get(opts, :audio_file)
    handler_args = Keyword.get(opts, :handler_args, %{})
    # G.711 A-law by default
    supported_codecs = Keyword.get(opts, :supported_codecs, [:pcma])

    # New audio configuration options
    audio_source = Keyword.get(opts, :audio_source, if(audio_file, do: :file, else: :silence))
    audio_sink = Keyword.get(opts, :audio_sink, :none)
    output_file = Keyword.get(opts, :output_file)
    input_device_id = Keyword.get(opts, :input_device_id)
    output_device_id = Keyword.get(opts, :output_device_id)

    # Get pre-allocated RTP port if provided
    local_rtp_port = Keyword.get(opts, :local_rtp_port)

    # IP configuration - defaults to auto-detect
    local_ip = Keyword.get(opts, :local_ip, :auto)
    advertised_ip = Keyword.get(opts, :advertised_ip)

    # Notification configuration
    notify_pid = Keyword.get(opts, :notify_pid)

    # Monitor the owner process
    owner_monitor = Process.monitor(owner_pid)

    data = %Data{
      id: id,
      dialog_id: dialog_id,
      role: role,
      audio_file: audio_file,
      owner_pid: owner_pid,
      owner_monitor: owner_monitor,
      media_handler: media_handler,
      handler_state: nil,
      supported_codecs: supported_codecs,
      selected_codec: nil,
      pipeline_module: nil,
      audio_source: audio_source,
      audio_sink: audio_sink,
      output_file: output_file,
      input_device_id: input_device_id,
      output_device_id: output_device_id,
      local_rtp_port: local_rtp_port,
      local_ip: local_ip,
      advertised_ip: advertised_ip,
      notify_pid: notify_pid,
      dtmf_collection: nil
    }

    # Initialize media handler (required)
    case media_handler.init(handler_args) do
      {:ok, initial_handler_state} ->
        # Call handle_session_start callback
        case media_handler.handle_session_start(id, opts, initial_handler_state) do
          {:ok, handler_state} ->
            final_data = %{data | handler_state: handler_state}
            Logger.info("MediaSession #{id} starting for dialog #{dialog_id} as #{role}")
            {:ok, :idle, final_data}

          {:error, reason, _handler_state} ->
            Logger.error("MediaHandler failed to start session: #{inspect(reason)}")
            {:stop, {:handler_session_start_failed, reason}}
        end

      {:stop, reason} ->
        Logger.error("MediaHandler init failed: #{inspect(reason)}")
        {:stop, {:handler_init_failed, reason}}
    end
  end

  ###############
  # State: idle #
  ###############

  def idle({:call, from}, :generate_offer, data) when data.role == :uac do
    # Generate SDP offer
    {:ok, sdp, updated_data} = generate_sdp_offer(data)
    Logger.debug("MediaSession #{data.id}: Generated SDP offer")
    {:next_state, :negotiating, updated_data, [{:reply, from, {:ok, sdp}}]}
  end

  def idle({:call, from}, {:process_offer, sdp_offer}, data) when data.role == :uas do
    Logger.info("MediaSession #{data.id}: Processing SDP offer in idle state")

    # Call handler's handle_offer callback (handler is always present now)
    case data.media_handler.handle_offer(sdp_offer, :inbound, data.handler_state) do
      {:ok, modified_sdp, new_state} ->
        data = %{data | handler_state: new_state}
        process_offer_internal(from, modified_sdp, data)

      {:reject, reason, new_state} ->
        Logger.warning("MediaSession #{data.id}: Handler rejected offer: #{inspect(reason)}")

        {:keep_state, %{data | handler_state: new_state},
         [{:reply, from, {:error, {:handler_rejected, reason}}}]}

      {:noreply, new_state} ->
        data = %{data | handler_state: new_state}
        process_offer_internal(from, sdp_offer, data)
    end
  end

  # Owner process DOWN
  def idle(:info, {:DOWN, ref, :process, _pid, reason}, %{owner_monitor: ref} = data) do
    Logger.info("MediaSession #{data.id}: Owner process terminated: #{inspect(reason)}")
    cleanup_session(data)
    {:stop, :normal}
  end

  # Pipeline process DOWN
  def idle(:info, {:DOWN, _ref, :process, pid, reason}, %{pipeline_pid: pid} = data) do
    Logger.warning("MediaSession #{data.id}: Membrane pipeline terminated: #{inspect(reason)}")
    {:next_state, :ready, %{data | pipeline_pid: nil, pipeline_monitor: nil}}
  end

  # Unknown process DOWN
  def idle(:info, {:DOWN, _ref, :process, pid, _reason}, data) do
    Logger.debug("MediaSession #{data.id}: Unknown process down: #{inspect(pid)}")
    {:keep_state_and_data, []}
  end

  # Catch-all ONLY for :info messages (external, unpredictable) - forwards to media handler
  def idle(:info, msg, data), do: handle_media_message(msg, data)

  # get_state call
  def idle({:call, from}, :get_state, data), do: reply_with_state(from, :idle, data)

  # set_notify_pid call
  def idle({:call, from}, {:set_notify_pid, pid}, data) do
    {:keep_state, %{data | notify_pid: pid}, [{:reply, from, :ok}]}
  end

  # RTP forwarding calls - available in all states
  def idle({:call, from}, {:set_rtp_forward, config}, data) do
    handle_set_rtp_forward(from, config, data)
  end

  def idle({:call, from}, :pause_forward, data) do
    handle_pause_forward(from, data)
  end

  def idle({:call, from}, :resume_forward, data) do
    handle_resume_forward(from, data)
  end

  # Fork operations require active state
  def idle({:call, from}, {:fork_media, _destination, _opts}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_active}}]}
  end

  def idle({:call, from}, {:stop_fork_media, _fork_id}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_active}}]}
  end

  def idle({:call, from}, :list_forks, _data) do
    {:keep_state_and_data, [{:reply, from, []}]}
  end

  # No catch-all for :call, :cast, or other event types - let them crash

  defp process_offer_internal(from, sdp_offer, data) do
    # Process SDP offer and generate answer
    case process_sdp_offer(sdp_offer, data) do
      {:ok, sdp_answer, updated_data} ->
        Logger.info("MediaSession #{data.id}: Successfully processed offer and generated answer")

        Logger.debug(
          "MediaSession #{data.id}: Local RTP port: #{updated_data.local_rtp_port}, Remote: #{updated_data.remote_rtp_address}:#{updated_data.remote_rtp_port}"
        )

        {:next_state, :ready, updated_data, [{:reply, from, {:ok, sdp_answer}}]}

      {:error, reason} = error ->
        Logger.error("MediaSession #{data.id}: Failed to process offer: #{inspect(reason)}")
        {:next_state, :idle, data, [{:reply, from, error}]}
    end
  end

  # State: negotiating

  def negotiating({:call, from}, {:process_answer, sdp_answer}, data) when data.role == :uac do
    # Process SDP answer
    case process_sdp_answer(sdp_answer, data) do
      {:ok, updated_data} ->
        Logger.debug("MediaSession #{data.id}: Processed SDP answer")
        {:next_state, :ready, updated_data, [{:reply, from, :ok}]}

      {:error, reason} = error ->
        Logger.error("MediaSession #{data.id}: Failed to process answer: #{inspect(reason)}")
        {:next_state, :negotiating, data, [{:reply, from, error}]}
    end
  end

  # Owner process DOWN
  def negotiating(:info, {:DOWN, ref, :process, _pid, reason}, %{owner_monitor: ref} = data) do
    Logger.info("MediaSession #{data.id}: Owner process terminated: #{inspect(reason)}")
    cleanup_session(data)
    {:stop, :normal}
  end

  # Pipeline process DOWN
  def negotiating(:info, {:DOWN, _ref, :process, pid, reason}, %{pipeline_pid: pid} = data) do
    Logger.warning("MediaSession #{data.id}: Membrane pipeline terminated: #{inspect(reason)}")
    {:next_state, :ready, %{data | pipeline_pid: nil, pipeline_monitor: nil}}
  end

  # Unknown process DOWN
  def negotiating(:info, {:DOWN, _ref, :process, pid, _reason}, data) do
    Logger.debug("MediaSession #{data.id}: Unknown process down: #{inspect(pid)}")
    {:keep_state_and_data, []}
  end

  # Catch-all ONLY for :info messages (external, unpredictable) - forwards to media handler
  def negotiating(:info, msg, data), do: handle_media_message(msg, data)

  # get_state call
  def negotiating({:call, from}, :get_state, data), do: reply_with_state(from, :negotiating, data)

  # set_notify_pid call
  def negotiating({:call, from}, {:set_notify_pid, pid}, data) do
    {:keep_state, %{data | notify_pid: pid}, [{:reply, from, :ok}]}
  end

  # RTP forwarding calls - available in all states
  def negotiating({:call, from}, {:set_rtp_forward, config}, data) do
    handle_set_rtp_forward(from, config, data)
  end

  def negotiating({:call, from}, :pause_forward, data) do
    handle_pause_forward(from, data)
  end

  def negotiating({:call, from}, :resume_forward, data) do
    handle_resume_forward(from, data)
  end

  # No catch-all for :call, :cast, or other event types - let them crash

  # State: ready

  def ready({:call, from}, :start_media, data) do
    Logger.info("MediaSession #{data.id}: Starting media pipeline in ready state")

    # Notify handler that stream is starting (handler is always present now)
    {action, updated_data} =
      case data.media_handler.handle_stream_start(data.id, :outbound, data.handler_state) do
        {:noreply, new_state} ->
          {:noreply, %{data | handler_state: new_state}}

        {actions, new_state} when is_list(actions) ->
          {List.first(actions), %{data | handler_state: new_state}}

        {action, new_state} ->
          {action, %{data | handler_state: new_state}}
      end

    # Process any media action from handler
    updated_data = process_media_action(action, updated_data)

    # Close the RTP socket before starting pipeline (so pipeline can bind to the port)
    if updated_data.rtp_socket do
      Logger.debug("MediaSession #{data.id}: Closing temporary RTP socket before pipeline start")
      :gen_udp.close(updated_data.rtp_socket)
    end

    updated_data = %{updated_data | rtp_socket: nil}

    # Start MOS Calculator if MOS monitoring is enabled
    updated_data = maybe_start_mos_calculator(updated_data)

    # Start media pipeline
    case start_media_pipeline(updated_data) do
      {:ok, pipeline_pid, monitor_ref, rtcp_receiver_pid} ->
        Logger.info(
          "MediaSession #{data.id}: Media pipeline started successfully with PID: #{inspect(pipeline_pid)}"
        )

        final_data = %{
          updated_data
          | pipeline_pid: pipeline_pid,
            pipeline_monitor: monitor_ref,
            rtcp_receiver_pid: rtcp_receiver_pid
        }

        {:next_state, :active, final_data, [{:reply, from, :ok}]}

      {:error, reason} = error ->
        Logger.error(
          "MediaSession #{data.id}: Failed to start media pipeline: #{inspect(reason)}"
        )

        {:next_state, :ready, updated_data, [{:reply, from, error}]}
    end
  end

  # Owner process DOWN
  def ready(:info, {:DOWN, ref, :process, _pid, reason}, %{owner_monitor: ref} = data) do
    Logger.info("MediaSession #{data.id}: Owner process terminated: #{inspect(reason)}")
    cleanup_session(data)
    {:stop, :normal}
  end

  # Pipeline process DOWN
  def ready(:info, {:DOWN, _ref, :process, pid, reason}, %{pipeline_pid: pid} = data) do
    Logger.warning("MediaSession #{data.id}: Membrane pipeline terminated: #{inspect(reason)}")
    {:keep_state, %{data | pipeline_pid: nil, pipeline_monitor: nil}}
  end

  # Unknown process DOWN
  def ready(:info, {:DOWN, _ref, :process, pid, _reason}, data) do
    Logger.debug("MediaSession #{data.id}: Unknown process down: #{inspect(pid)}")
    {:keep_state_and_data, []}
  end

  # Catch-all ONLY for :info messages (external, unpredictable) - forwards to media handler
  def ready(:info, msg, data), do: handle_media_message(msg, data)

  # get_state call
  def ready({:call, from}, :get_state, data), do: reply_with_state(from, :ready, data)

  # set_notify_pid call
  def ready({:call, from}, {:set_notify_pid, pid}, data) do
    {:keep_state, %{data | notify_pid: pid}, [{:reply, from, :ok}]}
  end

  # RTP forwarding calls - available in all states
  def ready({:call, from}, {:set_rtp_forward, config}, data) do
    handle_set_rtp_forward(from, config, data)
  end

  def ready({:call, from}, :pause_forward, data) do
    handle_pause_forward(from, data)
  end

  def ready({:call, from}, :resume_forward, data) do
    handle_resume_forward(from, data)
  end

  #################
  # State: active #
  #################

  def active({:call, from}, :pause_media, data) do
    Logger.info("MediaSession #{data.id}: Pausing media")

    # Stop the pipeline
    if data.pipeline_pid && Process.alive?(data.pipeline_pid) do
      Logger.info("MediaSession #{data.id}: Stopping pipeline for pause")
      ensure_pipeline_termination(data.pipeline_pid, data.pipeline_module)
    end

    # Update direction to sendonly (we're holding)
    updated_data = %{data | pipeline_pid: nil, direction: :sendonly}
    {:next_state, :paused, updated_data, [{:reply, from, :ok}]}
  end

  # Owner process DOWN
  def active(:info, {:DOWN, ref, :process, _pid, reason}, %{owner_monitor: ref} = data) do
    Logger.info("MediaSession #{data.id}: Owner process terminated: #{inspect(reason)}")
    cleanup_session(data)
    {:stop, :normal}
  end

  # Pipeline process DOWN
  def active(:info, {:DOWN, _ref, :process, pid, reason}, %{pipeline_pid: pid} = data) do
    Logger.warning("MediaSession #{data.id}: Membrane pipeline terminated: #{inspect(reason)}")
    {:next_state, :ready, %{data | pipeline_pid: nil, pipeline_monitor: nil}}
  end

  # Unknown process DOWN
  def active(:info, {:DOWN, _ref, :process, pid, _reason}, data) do
    Logger.debug("MediaSession #{data.id}: Unknown process down: #{inspect(pid)}")
    {:keep_state_and_data, []}
  end

  # Catch-all ONLY for :info messages (external, unpredictable) - forwards to media handler
  def active(:info, msg, data), do: handle_media_message(msg, data)

  # get_state call
  def active({:call, from}, :get_state, data), do: reply_with_state(from, :active, data)

  # set_notify_pid call
  def active({:call, from}, {:set_notify_pid, pid}, data) do
    {:keep_state, %{data | notify_pid: pid}, [{:reply, from, :ok}]}
  end

  # RTP forwarding calls - available in all states
  def active({:call, from}, {:set_rtp_forward, config}, data) do
    handle_set_rtp_forward(from, config, data)
  end

  def active({:call, from}, :pause_forward, data) do
    handle_pause_forward(from, data)
  end

  def active({:call, from}, :resume_forward, data) do
    handle_resume_forward(from, data)
  end

  # Fork media to external destination
  def active({:call, from}, {:fork_media, destination, opts}, data) do
    handle_fork_media(from, destination, opts, data)
  end

  # Stop a media fork
  def active({:call, from}, {:stop_fork_media, fork_id}, data) do
    handle_stop_fork_media(from, fork_id, data)
  end

  # List active forks
  def active({:call, from}, :list_forks, data) do
    handle_list_forks(from, data)
  end

  #################
  # State: paused #
  #################

  def paused({:call, from}, :resume_media, data) do
    Logger.info("MediaSession #{data.id}: Resuming media")

    # Restore direction to sendrecv
    updated_data = %{data | direction: :sendrecv}

    # Restart the pipeline
    case start_media_pipeline(updated_data) do
      {:ok, pipeline_pid, monitor_ref, rtcp_receiver_pid} ->
        Logger.info("MediaSession #{data.id}: Pipeline restarted successfully")

        final_data = %{
          updated_data
          | pipeline_pid: pipeline_pid,
            pipeline_monitor: monitor_ref,
            rtcp_receiver_pid: rtcp_receiver_pid
        }

        {:next_state, :active, final_data, [{:reply, from, :ok}]}

      {:error, reason} = error ->
        Logger.error("MediaSession #{data.id}: Failed to restart pipeline: #{inspect(reason)}")
        {:keep_state, updated_data, [{:reply, from, error}]}
    end
  end

  # Owner process DOWN
  def paused(:info, {:DOWN, ref, :process, _pid, reason}, %{owner_monitor: ref} = data) do
    Logger.info("MediaSession #{data.id}: Owner process terminated: #{inspect(reason)}")
    cleanup_session(data)
    {:stop, :normal}
  end

  # Pipeline process DOWN
  def paused(:info, {:DOWN, _ref, :process, pid, reason}, %{pipeline_pid: pid} = data) do
    Logger.warning("MediaSession #{data.id}: Membrane pipeline terminated: #{inspect(reason)}")
    {:next_state, :ready, %{data | pipeline_pid: nil, pipeline_monitor: nil}}
  end

  # Media control messages
  def paused(:info, {:play_files, _files, _opts} = msg, data), do: handle_media_message(msg, data)
  def paused(:info, :stop_playback = msg, data), do: handle_media_message(msg, data)

  # Unknown process DOWN
  def paused(:info, {:DOWN, _ref, :process, pid, _reason}, data) do
    Logger.debug("MediaSession #{data.id}: Unknown process down: #{inspect(pid)}")
    {:keep_state_and_data, []}
  end

  # Catch-all ONLY for :info messages (external, unpredictable) - forwards to media handler
  def paused(:info, msg, data), do: handle_media_message(msg, data)

  # get_state call
  def paused({:call, from}, :get_state, data), do: reply_with_state(from, :paused, data)

  # set_notify_pid call
  def paused({:call, from}, {:set_notify_pid, pid}, data) do
    {:keep_state, %{data | notify_pid: pid}, [{:reply, from, :ok}]}
  end

  # RTP forwarding calls - available in all states
  def paused({:call, from}, {:set_rtp_forward, config}, data) do
    handle_set_rtp_forward(from, config, data)
  end

  def paused({:call, from}, :pause_forward, data) do
    handle_pause_forward(from, data)
  end

  def paused({:call, from}, :resume_forward, data) do
    handle_resume_forward(from, data)
  end

  #####################
  # State: terminated #
  #####################

  # Terminated state - minimal handling, we're shutting down
  def terminated(_event_type, _event_content, _data) do
    {:keep_state_and_data, []}
  end

  # Helper functions for common patterns

  # Handle pipeline events that trigger notifications
  defp handle_media_message({:pipeline_event, :play_complete, filename}, data) do
    Logger.info("MediaSession #{data.id}: Play complete for #{filename}")
    notify_event(data, {:play_complete, filename})
    {:keep_state_and_data, []}
  end

  defp handle_media_message({:pipeline_event, :record_complete, filename, duration_ms}, data) do
    Logger.info("MediaSession #{data.id}: Record complete for #{filename} (#{duration_ms}ms)")
    notify_event(data, {:record_complete, filename, duration_ms})
    {:keep_state_and_data, []}
  end

  # Handle DTMF digit from pipeline (RFC 4733 telephone-event)
  defp handle_media_message({:pipeline_event, :dtmf, digit}, data) do
    # Delegate to standard DTMF handler
    handle_media_message({:dtmf, digit}, data)
  end

  # Handle DTMF collection messages
  defp handle_media_message({:collect_dtmf, opts}, data) do
    Logger.info("MediaSession #{data.id}: Starting DTMF collection with opts: #{inspect(opts)}")

    max_digits = Keyword.get(opts, :max, 10)
    terminators = Keyword.get(opts, :terminators, ["#"])
    timeout = Keyword.get(opts, :timeout, 10_000)

    # Cancel any existing DTMF collection timer
    data = cancel_dtmf_timer(data)

    # Set up new collection state
    timer_ref = Process.send_after(self(), :dtmf_timeout, timeout)

    dtmf_collection = %{
      max: max_digits,
      terminators: terminators,
      timeout: timeout,
      digits: "",
      timer_ref: timer_ref
    }

    # Also forward to handler in case it wants to track state
    updated_data = %{data | dtmf_collection: dtmf_collection}
    forward_and_update(updated_data, {:collect_dtmf, opts})
  end

  # Handle DTMF digit received
  defp handle_media_message({:dtmf, digit}, %{dtmf_collection: nil} = data) do
    Logger.debug("MediaSession #{data.id}: Ignoring DTMF digit #{digit} - not collecting")
    {:keep_state_and_data, []}
  end

  defp handle_media_message({:dtmf, digit}, %{dtmf_collection: collection} = data) do
    Logger.info("MediaSession #{data.id}: Received DTMF digit: #{digit}")

    # Check if this is a terminator
    if digit in collection.terminators do
      # Collection complete via terminator
      Logger.info(
        "MediaSession #{data.id}: DTMF collection complete (terminator): #{collection.digits}"
      )

      cancel_dtmf_timer(data)
      notify_event(data, {:dtmf_collected, collection.digits})
      {:keep_state, %{data | dtmf_collection: nil}, []}
    else
      # Add digit to collection
      new_digits = collection.digits <> digit

      if String.length(new_digits) >= collection.max do
        # Max digits reached
        Logger.info("MediaSession #{data.id}: DTMF collection complete (max): #{new_digits}")
        cancel_dtmf_timer(data)
        notify_event(data, {:dtmf_collected, new_digits})
        {:keep_state, %{data | dtmf_collection: nil}, []}
      else
        # Continue collecting
        updated_collection = %{collection | digits: new_digits}
        {:keep_state, %{data | dtmf_collection: updated_collection}, []}
      end
    end
  end

  # Handle DTMF timeout
  defp handle_media_message(:dtmf_timeout, %{dtmf_collection: nil} = _data) do
    # No active collection, ignore
    {:keep_state_and_data, []}
  end

  defp handle_media_message(:dtmf_timeout, %{dtmf_collection: collection} = data) do
    Logger.info(
      "MediaSession #{data.id}: DTMF collection timeout with digits: #{collection.digits}"
    )

    notify_event(data, {:dtmf_timeout, collection.digits})
    {:keep_state, %{data | dtmf_collection: nil}, []}
  end

  # Handle start_record message
  defp handle_media_message({:start_record, path, opts}, data) do
    Logger.info("MediaSession #{data.id}: Starting recording to #{path}")
    updated_data = %{data | output_file: path, audio_sink: :file}
    forward_and_update(updated_data, {:start_record, path, opts})
  end

  # Handle play_audio message (TTS synthesis result)
  # Writes audio binary to a temp file and plays it using existing file playback
  defp handle_media_message({:play_audio, audio_binary, opts}, data) when is_binary(audio_binary) do
    Logger.info("MediaSession #{data.id}: Playing synthesized audio (#{byte_size(audio_binary)} bytes)")

    # Determine file extension from format
    format = Keyword.get(opts, :format, :wav)
    extension = audio_format_to_extension(format)

    # Create temp file for the audio
    temp_dir = System.tmp_dir!()
    filename = "parrot_tts_#{data.id}_#{System.unique_integer([:positive])}.#{extension}"
    temp_path = Path.join(temp_dir, filename)

    case File.write(temp_path, audio_binary) do
      :ok ->
        Logger.debug("MediaSession #{data.id}: Wrote TTS audio to temp file: #{temp_path}")

        # Convert the audio to WAV if needed (for non-WAV formats)
        # For now, we assume the TTS provider returns compatible audio
        # In the future, we could transcode MP3/Opus to WAV here

        # Play the temp file using existing infrastructure
        # The play_complete handler will clean up the file
        play_opts = Keyword.put(opts, :temp_file, true)
        handle_media_message({:play_files, [temp_path], play_opts}, data)

      {:error, reason} ->
        Logger.error("MediaSession #{data.id}: Failed to write TTS audio to temp file: #{inspect(reason)}")
        {:keep_state_and_data, []}
    end
  end

  # Default handler for other messages
  defp handle_media_message(msg, data) do
    case msg do
      {:play_files, _files, _opts} ->
        Logger.info("MediaSession #{data.id}: Handling play_files message")

      :stop_playback ->
        Logger.info("MediaSession #{data.id}: Handling stop_playback message")

      _ ->
        Logger.debug("MediaSession #{data.id}: Forwarding message to handler: #{inspect(msg)}")
    end

    forward_and_update(data, msg)
  end

  # Helper to forward message to handler and process actions
  defp forward_and_update(data, msg) do
    case forward_to_media_handler(msg, data) do
      {:ok, actions, new_handler_state} ->
        updated_data = %{data | handler_state: new_handler_state}
        updated_data = process_media_actions(actions, updated_data)
        {:keep_state, updated_data, []}

      {:noreply, new_handler_state} ->
        {:keep_state, %{data | handler_state: new_handler_state}, []}

      :no_handler_function ->
        # Handler doesn't implement handle_info/2 - this is okay
        Logger.debug(
          "MediaSession #{data.id}: Handler doesn't implement handle_info/2 for message: #{inspect(msg)}"
        )

        {:keep_state, data, []}

      :error ->
        # Handler exists but had an error or didn't handle the message
        Logger.warning(
          "MediaSession #{data.id}: Unexpected info message not handled: #{inspect(msg)}"
        )

        {:keep_state, data, []}
    end
  end

  # Send notification to notify_pid if configured
  defp notify_event(%{notify_pid: nil}, _event), do: :ok

  defp notify_event(%{notify_pid: pid, id: session_id}, event) when is_pid(pid) do
    send(pid, {:media_event, session_id, event})
    :ok
  end

  # Cancel existing DTMF timer if any
  defp cancel_dtmf_timer(%{dtmf_collection: nil} = data), do: data

  defp cancel_dtmf_timer(%{dtmf_collection: %{timer_ref: ref}} = data) when is_reference(ref) do
    Process.cancel_timer(ref)
    data
  end

  defp cancel_dtmf_timer(data), do: data

  defp reply_with_state(from, state, data) do
    state_info = %{
      state: state,
      id: data.id,
      dialog_id: data.dialog_id,
      role: data.role,
      has_local_sdp: data.local_sdp != nil,
      has_remote_sdp: data.remote_sdp != nil,
      pipeline_active: data.pipeline_pid != nil,
      rtp_forward_config: data.rtp_forward_config,
      rtp_forward_paused: data.rtp_forward_paused
    }

    {:keep_state_and_data, [{:reply, from, state_info}]}
  end

  # RTP Forwarding helpers

  # Handle set_rtp_forward call - validates and stores the forwarding configuration
  defp handle_set_rtp_forward(from, nil, data) do
    # Clearing the forwarding configuration
    Logger.info("MediaSession #{data.id}: Clearing RTP forwarding configuration")
    updated_data = %{data | rtp_forward_config: nil, rtp_forward_paused: false}
    {:keep_state, updated_data, [{:reply, from, :ok}]}
  end

  defp handle_set_rtp_forward(from, %{target_pid: target_pid} = _config, data)
       when not is_pid(target_pid) do
    Logger.warning("MediaSession #{data.id}: Invalid target_pid for RTP forwarding: #{inspect(target_pid)}")
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_target_pid}}]}
  end

  defp handle_set_rtp_forward(from, %{direction: direction} = _config, data)
       when direction not in [:both, :send_only, :recv_only] do
    Logger.warning("MediaSession #{data.id}: Invalid direction for RTP forwarding: #{inspect(direction)}")
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_direction}}]}
  end

  defp handle_set_rtp_forward(from, %{target_pid: target_pid, direction: direction} = config, data) do
    Logger.info("MediaSession #{data.id}: Setting RTP forwarding to #{inspect(target_pid)} with direction #{direction}")

    # Store the forwarding configuration
    updated_data = %{data | rtp_forward_config: config, rtp_forward_paused: false}

    # TODO: In future, notify the pipeline to set up actual RTP forwarding
    # For now, we just store the configuration for the B2BUA to use

    {:keep_state, updated_data, [{:reply, from, :ok}]}
  end

  # Handle pause_forward call
  defp handle_pause_forward(from, %{rtp_forward_config: nil} = _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :no_forward_configured}}]}
  end

  defp handle_pause_forward(from, data) do
    Logger.info("MediaSession #{data.id}: Pausing RTP forwarding")
    updated_data = %{data | rtp_forward_paused: true}

    # TODO: In future, notify the pipeline to pause RTP forwarding

    {:keep_state, updated_data, [{:reply, from, :ok}]}
  end

  # Handle resume_forward call
  defp handle_resume_forward(from, %{rtp_forward_config: nil} = _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :no_forward_configured}}]}
  end

  defp handle_resume_forward(from, %{rtp_forward_paused: false} = _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_paused}}]}
  end

  defp handle_resume_forward(from, data) do
    Logger.info("MediaSession #{data.id}: Resuming RTP forwarding")
    updated_data = %{data | rtp_forward_paused: false}

    # TODO: In future, notify the pipeline to resume RTP forwarding

    {:keep_state, updated_data, [{:reply, from, :ok}]}
  end

  # Fork media to external destination (WebSocket or RTP)
  defp handle_fork_media(from, destination, opts, data) do
    alias ParrotMedia.Fork.{Manager, Types.ForkConfig}

    # Ensure Fork.Manager is started - updates data with fork_manager_pid
    updated_data = ensure_fork_manager(data)

    case updated_data.fork_manager_pid do
      nil ->
        {:keep_state, updated_data, [{:reply, from, {:error, :fork_manager_not_available}}]}

      manager_pid ->
        # Parse destination to determine fork type
        fork_destination = parse_fork_destination(destination)

        case fork_destination do
          {:error, reason} ->
            {:keep_state, updated_data, [{:reply, from, {:error, reason}}]}

          valid_destination ->
            # Build fork config
            direction = Keyword.get(opts, :direction, :both)
            format = Keyword.get(opts, :format)
            label = Keyword.get(opts, :label)

            config = %ForkConfig{
              id: generate_fork_id(),
              destination: valid_destination,
              direction: direction,
              format: format,
              label: label
            }

            # Add fork to manager
            case Manager.add_fork(manager_pid, config) do
              {:ok, fork_id} ->
                # Send fork request to pipeline
                if updated_data.pipeline_pid do
                  send(updated_data.pipeline_pid, {:add_fork, build_pipeline_fork_config(config)})
                end

                Logger.info("MediaSession #{updated_data.id}: Added fork #{fork_id} to #{inspect(destination)}")
                {:keep_state, updated_data, [{:reply, from, {:ok, fork_id}}]}

              {:error, reason} ->
                {:keep_state, updated_data, [{:reply, from, {:error, reason}}]}
            end
        end
    end
  end

  defp handle_stop_fork_media(from, fork_id, data) do
    alias ParrotMedia.Fork.Manager

    case data.fork_manager_pid do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :fork_manager_not_available}}]}

      manager_pid ->
        case Manager.remove_fork(manager_pid, fork_id) do
          :ok ->
            # Send remove request to pipeline
            if data.pipeline_pid do
              send(data.pipeline_pid, {:remove_fork, fork_id})
            end

            Logger.info("MediaSession #{data.id}: Removed fork #{fork_id}")
            {:keep_state_and_data, [{:reply, from, :ok}]}

          {:error, reason} ->
            {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
        end
    end
  end

  defp handle_list_forks(from, data) do
    alias ParrotMedia.Fork.Manager

    forks =
      case data.fork_manager_pid do
        nil -> []
        manager_pid -> Manager.list_forks(manager_pid)
      end

    {:keep_state_and_data, [{:reply, from, forks}]}
  end

  defp ensure_fork_manager(%{fork_manager_pid: pid} = data) when is_pid(pid) do
    if Process.alive?(pid) do
      data
    else
      start_fork_manager(data)
    end
  end

  defp ensure_fork_manager(data) do
    start_fork_manager(data)
  end

  defp start_fork_manager(data) do
    alias ParrotMedia.Fork.Manager

    case Manager.start_link(
           session_id: data.id,
           parent_pid: data.notify_pid || data.owner_pid,
           pipeline_pid: data.pipeline_pid
         ) do
      {:ok, pid} ->
        Logger.debug("MediaSession #{data.id}: Started Fork.Manager #{inspect(pid)}")
        %{data | fork_manager_pid: pid}

      {:error, reason} ->
        Logger.error("MediaSession #{data.id}: Failed to start Fork.Manager: #{inspect(reason)}")
        data
    end
  end

  defp parse_fork_destination(destination) when is_binary(destination) do
    cond do
      String.starts_with?(destination, "ws://") or String.starts_with?(destination, "wss://") ->
        {:websocket, destination}

      String.starts_with?(destination, "rtp://") ->
        # Parse rtp://host:port format
        case parse_rtp_url(destination) do
          {:ok, ip, port} -> {:rtp, {ip, port}}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :invalid_destination_format}
    end
  end

  defp parse_fork_destination({ip, port}) when is_tuple(ip) and is_integer(port) do
    {:rtp, {ip, port}}
  end

  defp parse_fork_destination(_), do: {:error, :invalid_destination}

  defp parse_rtp_url(url) do
    uri = URI.parse(url)

    case uri do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, ip} -> {:ok, ip, port}
          {:error, _} -> {:error, :invalid_host}
        end

      _ ->
        {:error, :invalid_rtp_url}
    end
  end

  defp generate_fork_id do
    "fork-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  defp build_pipeline_fork_config(%ParrotMedia.Fork.Types.ForkConfig{} = config) do
    case config.destination do
      {:rtp, {ip, port}} ->
        %ParrotMedia.ForkConfig{
          id: config.id,
          destination_address: ip,
          destination_port: port
        }

      {:websocket, url} ->
        # For WebSocket forks, use WsForkSink via the new fork system
        # The pipeline already handles this with the ws_fork_sink pattern
        %{
          id: config.id,
          destination: {:websocket, url},
          direction: config.direction
        }
    end
  end

  # Private helpers

  # Codec mapping between symbols and RTP payload types
  # Per RFC 3551: PCMA (payload type 8), Opus (dynamic, typically 111)
  # Note: PCMU (G.711 μ-law, PT 0) is NOT supported - membrane_g711_plugin only has A-law
  defp codec_info(:pcma), do: {8, "PCMA/8000", ParrotMedia.AlawPipeline}
  defp codec_info(:opus), do: {111, "opus/48000/1", ParrotMedia.OpusPipeline}

  defp get_pipeline_module(codec) do
    {_, _, module} = codec_info(codec)
    module
  end

  defp get_pipeline_module_for_config(_codec, %{audio_source: :device}),
    do: ParrotMedia.PortAudioPipeline

  defp get_pipeline_module_for_config(_codec, %{audio_sink: :device}),
    do: ParrotMedia.PortAudioPipeline

  defp get_pipeline_module_for_config(codec, _data), do: get_pipeline_module(codec)

  defp get_pid(session) when is_binary(session) do
    case Registry.lookup(ParrotMedia.Registry, {:media_session, session}) do
      [{pid, _}] ->
        pid

      [] ->
        raise "MediaSession #{session} not found"
    end
  end

  defp get_pid(pid) when is_pid(pid), do: pid

  defp generate_sdp_offer(data) do
    # Allocate local RTP port and RTCP port, keep sockets open
    {local_rtp_port, rtp_socket, rtcp_socket} = allocate_rtp_port()

    # Get the IP address to use in SDP
    sdp_ip = get_sdp_ip(data)

    # Build SDP offer using the Sdp module
    case Sdp.build_offer(
           local_ip: sdp_ip,
           local_port: local_rtp_port,
           supported_codecs: data.supported_codecs,
           direction: data.direction
         ) do
      {:ok, sdp_string} ->
        updated_data = %{
          data
          | local_sdp: sdp_string,
            local_rtp_port: local_rtp_port,
            local_rtcp_port: local_rtp_port + 1,
            rtp_socket: rtp_socket,
            rtcp_socket: rtcp_socket
        }

        {:ok, sdp_string, updated_data}

      {:error, reason} ->
        # Close socket on error
        if rtp_socket, do: :gen_udp.close(rtp_socket)
        {:error, reason}
    end
  end

  defp process_sdp_offer(sdp_offer, data) do
    Logger.debug("MediaSession #{data.id}: Parsing SDP offer")

    with {:ok, parsed_sdp} <- Sdp.parse(sdp_offer),
         {:ok, audio_media} <- find_audio_media(parsed_sdp),
         {:ok, remote_info} <- extract_remote_info(parsed_sdp, audio_media, data.id),
         {:ok, selected_codec, handler_state} <- negotiate_codec(audio_media, data) do
      data_with_handler_state = %{data | handler_state: handler_state}
      {local_rtp_port, rtp_socket, rtcp_socket} = get_or_allocate_rtp_port(data_with_handler_state)

      # Extract ALL dynamic payload types from SDP (RFC 3551: PTs 96-127)
      # This gives us a map like %{"telephone-event" => 96, "no-op" => 97}
      dynamic_payload_types = extract_dynamic_payload_types(audio_media)

      if map_size(dynamic_payload_types) > 0 do
        Logger.info(
          "MediaSession #{data.id}: Remote dynamic payload types: #{inspect(dynamic_payload_types)}"
        )
      end

      # Get the IP address to use in SDP
      sdp_ip = get_sdp_ip(data_with_handler_state)

      # Use Sdp module to generate answer (includes telephone-event if offered)
      case Sdp.build_answer_for_codec(selected_codec,
             local_ip: sdp_ip,
             local_port: local_rtp_port,
             direction: data_with_handler_state.direction,
             offer_audio_media: audio_media
           ) do
        {:ok, sdp_answer} ->
          pipeline_module =
            get_pipeline_module_for_config(selected_codec, data_with_handler_state)

          # Update dynamic_payload_types to use the negotiated telephone-event PT from our answer
          # (not the offer's PT which might have a different clock rate)
          negotiated_dyn_pts =
            update_dynamic_pts_from_answer(sdp_answer, dynamic_payload_types)

          session_data =
            build_session_data(
              data_with_handler_state,
              sdp_offer,
              remote_info,
              selected_codec,
              local_rtp_port,
              rtp_socket,
              rtcp_socket,
              sdp_answer,
              pipeline_module,
              negotiated_dyn_pts
            )

          {:ok, final_data} =
            call_handler_if_present(session_data, sdp_answer, sdp_offer, selected_codec)

          Logger.info("MediaSession #{data.id}: SDP negotiation complete")
          {:ok, sdp_answer, final_data}

        {:error, reason} ->
          # Close socket on error
          if rtp_socket, do: :gen_udp.close(rtp_socket)
          {:error, reason}
      end
    end
  end

  defp find_audio_media(%{media: media}) do
    case Enum.find(media, &(&1.type == :audio)) do
      nil -> {:error, :no_audio_media}
      audio_media -> {:ok, audio_media}
    end
  end

  defp extract_remote_info(parsed_sdp, audio_media, session_id) do
    remote_rtp_address = get_remote_address(parsed_sdp, session_id)
    remote_rtp_port = audio_media.port

    Logger.info(
      "MediaSession #{session_id}: Remote RTP endpoint: #{remote_rtp_address}:#{remote_rtp_port}"
    )

    {:ok, %{address: remote_rtp_address, port: remote_rtp_port}}
  end

  defp get_remote_address(%{connection_data: %{address: addr}}, _session_id)
       when is_tuple(addr) do
    addr |> Tuple.to_list() |> Enum.join(".")
  end

  defp get_remote_address(%{connection_data: %{address: addr}}, _session_id)
       when is_binary(addr) do
    addr
  end

  defp get_remote_address(%{connection_data: %{address: addr}}, _session_id) do
    to_string(addr)
  end

  defp get_remote_address(_parsed_sdp, session_id) do
    Logger.warning(
      "MediaSession #{session_id}: No connection data in SDP, defaulting to 127.0.0.1"
    )

    "127.0.0.1"
  end

  defp negotiate_codec(audio_media, %{media_handler: handler} = data) do
    offered_codecs = extract_offered_codecs(audio_media)

    case handler.handle_codec_negotiation(
           offered_codecs,
           data.supported_codecs,
           data.handler_state
         ) do
      {:ok, codec, new_state} when is_atom(codec) ->
        {:ok, codec, new_state}

      {:ok, codec_list, new_state} when is_list(codec_list) ->
        codec = Enum.find(codec_list, &(&1 in offered_codecs)) || hd(codec_list)
        {:ok, codec, new_state}

      {:error, :no_common_codec, _new_state} ->
        Logger.warning("MediaSession #{data.id}: Handler found no common codec")
        {:error, :no_common_codec}
    end
  end

  defp get_or_allocate_rtp_port(
         %{local_rtp_port: port, rtp_socket: socket, rtcp_socket: rtcp_socket, id: session_id}
       )
       when not is_nil(port) do
    Logger.info("MediaSession #{session_id}: Using pre-allocated local RTP port: #{port}")
    {port, socket, rtcp_socket}
  end

  defp get_or_allocate_rtp_port(%{id: session_id}) do
    {port, rtp_socket, rtcp_socket} = allocate_rtp_port()
    Logger.info("MediaSession #{session_id}: Allocated new local RTP port: #{port}")
    {port, rtp_socket, rtcp_socket}
  end

  defp build_session_data(
         data,
         sdp_offer,
         remote_info,
         selected_codec,
         local_rtp_port,
         rtp_socket,
         rtcp_socket,
         sdp_answer,
         pipeline_module,
         dynamic_payload_types
       ) do
    %{
      data
      | local_sdp: sdp_answer,
        remote_sdp: sdp_offer,
        local_rtp_port: local_rtp_port,
        local_rtcp_port: local_rtp_port + 1,
        rtp_socket: rtp_socket,
        rtcp_socket: rtcp_socket,
        remote_rtp_port: remote_info.port,
        remote_rtp_address: remote_info.address,
        selected_codec: selected_codec,
        pipeline_module: pipeline_module,
        dynamic_payload_types: dynamic_payload_types
    }
  end

  defp call_handler_if_present(data, sdp_answer, sdp_offer, selected_codec) do
    data.media_handler.handle_negotiation_complete(
      sdp_answer,
      sdp_offer,
      selected_codec,
      data.handler_state
    )
    |> handle_callback_result(data)
  end

  defp handle_callback_result({:ok, new_state}, data) do
    {:ok, %{data | handler_state: new_state}}
  end

  defp handle_callback_result({:error, reason, new_state}, data) do
    Logger.error(
      "MediaSession #{data.id}: Handler negotiation complete error: #{inspect(reason)}"
    )

    {:ok, %{data | handler_state: new_state}}
  end

  defp extract_offered_codecs(audio_media) do
    # Map payload types to codec names
    # Per RFC 3551: Static payload types for audio
    #   0 = PCMU (G.711 mu-law)
    #   8 = PCMA (G.711 A-law)
    static_codec_map = %{
      0 => :pcmu,
      8 => :pcma
    }

    # Extract dynamic codecs from rtpmap attributes
    dynamic_codecs =
      audio_media.attributes
      |> Enum.filter(&match?(%ExSDP.Attribute.RTPMapping{}, &1))
      |> Enum.map(fn rtpmap ->
        case String.downcase(rtpmap.encoding) do
          "opus" -> {rtpmap.payload_type, :opus}
          "pcma" -> {rtpmap.payload_type, :pcma}
          "pcmu" -> {rtpmap.payload_type, :pcmu}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    # Merge static and dynamic codecs
    codec_map = Map.merge(static_codec_map, dynamic_codecs)

    # Extract codecs from fmt list
    audio_media.fmt
    |> Enum.map(fn pt -> codec_map[pt] end)
    |> Enum.reject(&is_nil/1)
  end

  # Extract ALL dynamic payload types from SDP rtpmap attributes
  # Returns a map of encoding name (lowercase) -> {payload_type, clock_rate}
  # Per RFC 3551, PTs 96-127 are dynamically assigned via SDP
  # Example: %{"telephone-event" => {96, 8000}, "opus" => {111, 48000}}
  defp extract_dynamic_payload_types(audio_media) do
    audio_media.attributes
    |> Enum.filter(&match?(%ExSDP.Attribute.RTPMapping{}, &1))
    |> Enum.map(fn %ExSDP.Attribute.RTPMapping{
                     encoding: encoding,
                     payload_type: pt,
                     clock_rate: clock_rate
                   } ->
      {String.downcase(encoding), {pt, clock_rate}}
    end)
    |> Map.new()
  end

  # Update dynamic payload types from the SDP answer
  # This ensures we use the negotiated telephone-event PT (which matches the codec clock rate)
  # rather than the offer's telephone-event which might have a different clock rate
  defp update_dynamic_pts_from_answer(sdp_answer, original_dyn_pts) do
    case Sdp.parse(sdp_answer) do
      {:ok, parsed_answer} ->
        case Enum.find(parsed_answer.media, &(&1.type == :audio)) do
          nil ->
            original_dyn_pts

          audio_media ->
            # Extract telephone-event from answer and update the map
            answer_dyn_pts = extract_dynamic_payload_types(audio_media)

            # Merge answer's telephone-event over original (answer takes precedence)
            case Map.get(answer_dyn_pts, "telephone-event") do
              nil -> original_dyn_pts
              te_pt -> Map.put(original_dyn_pts, "telephone-event", te_pt)
            end
        end

      {:error, _} ->
        original_dyn_pts
    end
  end

  defp process_sdp_answer(sdp_answer, data) do
    with {:ok, answer_info} <- Sdp.process_answer(sdp_answer) do
      pipeline_module = get_pipeline_module_for_config(answer_info.selected_codec, data)

      updated_data = %{
        data
        | remote_sdp: sdp_answer,
          remote_rtp_port: answer_info.remote_port,
          remote_rtp_address: answer_info.remote_ip,
          selected_codec: answer_info.selected_codec,
          pipeline_module: pipeline_module
      }

      {:ok, updated_data}
    end
  end

  defp allocate_rtp_port(config \\ %{}) do
    min_port = Map.get(config, :min_rtp_port, 16384)
    max_port = Map.get(config, :max_rtp_port, 32768)
    max_attempts = Map.get(config, :max_port_attempts, 100)

    case find_available_port(min_port, max_port, max_attempts) do
      {:ok, port, rtp_socket, rtcp_socket} ->
        {port, rtp_socket, rtcp_socket}

      {:error, :no_ports_available} ->
        # Fallback to random port as last resort
        Logger.error(
          "Failed to find available RTP port in range #{min_port}-#{max_port}, using random port"
        )

        port = min_port + :rand.uniform(max_port - min_port)

        # Try to open sockets for the fallback port
        with {:ok, rtp_socket} <- :gen_udp.open(port, [:binary, {:active, false}]),
             {:ok, rtcp_socket} <- :gen_udp.open(port + 1, [:binary, {:active, false}]) do
          {port, rtp_socket, rtcp_socket}
        else
          {:error, _} -> {port, nil, nil}
        end
    end
  end

  defp find_available_port(min_port, max_port, max_attempts) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.take(max_attempts)
    |> Stream.map(fn _ ->
      # Generate random port and ensure it's even (for RTP/RTCP pairing)
      candidate_port = min_port + :rand.uniform(max_port - min_port)
      rtp_port = if rem(candidate_port, 2) == 0, do: candidate_port, else: candidate_port - 1

      # Verify both RTP port and RTCP port (RTP+1) are available
      # Keep both sockets open - RTP for pipeline, RTCP for receiving reports
      with {:ok, rtp_socket} <- :gen_udp.open(rtp_port, [:binary, {:active, false}]),
           {:ok, rtcp_socket} <- :gen_udp.open(rtp_port + 1, [:binary, {:active, false}]) do
        # Return with both sockets open for RTP streaming and RTCP reception
        {:ok, rtp_port, rtp_socket, rtcp_socket}
      else
        {:error, :eaddrinuse} ->
          {:error, :in_use}

        error ->
          error
      end
    end)
    |> Enum.find({:error, :no_ports_available}, fn
      {:ok, _port, _rtp_socket, _rtcp_socket} -> true
      _ -> false
    end)
  end

  defp start_media_pipeline(data) do
    Logger.info("MediaSession #{data.id}: Creating Membrane pipeline for RTP audio streaming")

    Logger.info(
      "MediaSession #{data.id}: Remote endpoint from data: #{data.remote_rtp_address}:#{data.remote_rtp_port}"
    )

    # Create Membrane pipeline for RTP audio streaming
    init_arg = %{
      session_id: data.id,
      local_rtp_port: data.local_rtp_port,
      remote_rtp_address: data.remote_rtp_address,
      remote_rtp_port: data.remote_rtp_port,
      audio_file: data.audio_file || :deferred,
      media_handler: data.media_handler,
      handler_state: data.handler_state,
      # Pass new audio configuration
      audio_source: data.audio_source,
      audio_sink: data.audio_sink,
      output_file: data.output_file,
      input_device_id: data.input_device_id,
      output_device_id: data.output_device_id,
      # Pass the selected codec
      selected_codec: data.selected_codec,
      # Pass MediaSession PID for pipeline events (DTMF, play_complete, etc.)
      media_session_pid: self(),
      # Dynamic payload types from SDP (encoding name -> PT)
      # Per RFC 3551, PTs 96-127 are dynamically assigned
      dynamic_payload_types: data.dynamic_payload_types || %{}
    }

    Logger.info("MediaSession #{data.id}: Pipeline init args: #{inspect(init_arg)}")

    # Use the dynamically selected pipeline module based on negotiated codec
    pipeline_module = data.pipeline_module

    Logger.info(
      "MediaSession #{data.id}: Using pipeline module: #{inspect(pipeline_module)} for codec: #{inspect(data.selected_codec)}"
    )

    # Start the pipeline
    start_result = Membrane.Pipeline.start_link(pipeline_module, init_arg)

    case start_result do
      {:ok, pipeline_pid} ->
        Logger.info(
          "MediaSession #{data.id}: Membrane pipeline created with PID: #{inspect(pipeline_pid)}"
        )

        monitor_ref = Process.monitor(pipeline_pid)

        # Start RTCP receiver if we have an RTCP socket
        rtcp_receiver_pid = maybe_start_rtcp_receiver(data)

        {:ok, pipeline_pid, monitor_ref, rtcp_receiver_pid}

      {:ok, _supervisor_pid, pipeline_pid} ->
        # Membrane.Pipeline.start_link returns {ok, supervisor_pid, pipeline_pid}
        Logger.info(
          "MediaSession #{data.id}: Membrane pipeline created with PID: #{inspect(pipeline_pid)}"
        )

        monitor_ref = Process.monitor(pipeline_pid)

        # Start RTCP receiver if we have an RTCP socket
        rtcp_receiver_pid = maybe_start_rtcp_receiver(data)

        {:ok, pipeline_pid, monitor_ref, rtcp_receiver_pid}

      {:error, reason} = error ->
        Logger.error(
          "MediaSession #{data.id}: Failed to start Membrane pipeline: #{inspect(reason)}"
        )

        error
    end
  end

  # Starts RTCP receiver if we have an RTCP socket
  defp maybe_start_rtcp_receiver(%{rtcp_socket: nil}), do: nil

  defp maybe_start_rtcp_receiver(%{rtcp_socket: rtcp_socket, id: session_id} = data) do
    # Get clock rate from selected codec
    clock_rate = get_clock_rate(data.selected_codec)

    case ParrotMedia.RTCP.Receiver.start_link(
           rtcp_socket: rtcp_socket,
           session_id: session_id,
           clock_rate: clock_rate
         ) do
      {:ok, pid} ->
        Logger.info("[MediaSession] Started RTCP receiver for session #{session_id}")
        pid

      {:error, reason} ->
        Logger.warning("[MediaSession] Failed to start RTCP receiver: #{inspect(reason)}")
        nil
    end
  end

  defp get_clock_rate(:pcma), do: 8000
  defp get_clock_rate(:pcmu), do: 8000
  defp get_clock_rate(:g711), do: 8000
  defp get_clock_rate(:opus), do: 48000
  defp get_clock_rate(_), do: 8000

  defp process_media_action({:play, file_path}, data) do
    process_media_action({:play, file_path, []}, data)
  end

  defp process_media_action({:play, file_path, _opts}, data) do
    Logger.info("MediaSession #{data.id}: Playing file: #{file_path}")
    # Update the audio file and restart pipeline if needed
    updated_data = %{data | audio_file: file_path, audio_source: :file}
    restart_pipeline_if_needed(updated_data)
  end

  defp process_media_action({:play_sequence, files}, data) when is_list(files) do
    Logger.info("MediaSession #{data.id}: Playing sequence of #{length(files)} files")

    case files do
      [] ->
        data

      _files ->
        # If pipeline is running, send play_files_request to it
        # The pipeline will forward to SwitchableFileSource via notify_child action
        if data.pipeline_pid && Process.alive?(data.pipeline_pid) do
          send(data.pipeline_pid, {:play_files_request, files, loop: false})
          data
        else
          # Pipeline not running yet, set first file and let it start normally
          updated_data = %{data | audio_file: hd(files), audio_source: :file}
          restart_pipeline_if_needed(updated_data)
        end
    end
  end

  defp process_media_action({:play_loop, files}, data) when is_list(files) do
    Logger.info("MediaSession #{data.id}: Playing #{length(files)} files in loop")

    case files do
      [] ->
        data

      _files ->
        # If pipeline is running, send play_files_request to it
        # The pipeline will forward to SwitchableFileSource via notify_child action
        if data.pipeline_pid && Process.alive?(data.pipeline_pid) do
          send(data.pipeline_pid, {:play_files_request, files, loop: true})
          data
        else
          # Pipeline not running yet, set first file and let it start normally
          updated_data = %{data | audio_file: hd(files), audio_source: :file}
          restart_pipeline_if_needed(updated_data)
        end
    end
  end

  defp process_media_action(:stop, data) do
    Logger.info("MediaSession #{data.id}: Stopping media")
    stop_media_pipeline(data)
    data
  end

  defp process_media_action({:record, _file_path}, data) do
    Logger.warning("MediaSession #{data.id}: Recording not yet implemented")
    data
  end

  defp process_media_action({:use_audio_devices, opts}, data) do
    input = Keyword.get(opts, :input)
    output = Keyword.get(opts, :output)
    process_media_action({:connect_audio_device, input, output}, data)
  end

  defp process_media_action({:use_microphone, device_id}, data) do
    process_media_action({:connect_audio_device, device_id, nil}, data)
  end

  defp process_media_action({:use_speaker, device_id}, data) do
    process_media_action({:connect_audio_device, nil, device_id}, data)
  end

  defp process_media_action(:release_audio_devices, data) do
    process_media_action({:connect_audio_device, nil, nil}, data)
  end

  defp process_media_action({:connect_audio_device, nil, nil}, data) do
    Logger.info("MediaSession #{data.id}: Releasing all audio devices")

    Map.merge(data, %{
      input_device_id: nil,
      output_device_id: nil,
      audio_source: :silence,
      audio_sink: :none
    })
  end

  defp process_media_action({:connect_audio_device, input_device, nil}, data) do
    Logger.info("MediaSession #{data.id}: Connecting microphone: #{inspect(input_device)}")

    Map.merge(data, %{
      input_device_id: input_device,
      output_device_id: nil,
      audio_source: :device,
      audio_sink: :none
    })
  end

  defp process_media_action({:connect_audio_device, nil, output_device}, data) do
    Logger.info("MediaSession #{data.id}: Connecting speaker: #{inspect(output_device)}")

    Map.merge(data, %{
      input_device_id: nil,
      output_device_id: output_device,
      audio_source: :silence,
      audio_sink: :device
    })
  end

  defp process_media_action({:connect_audio_device, input_device, output_device}, data) do
    Logger.info(
      "MediaSession #{data.id}: Connecting audio devices - input: #{inspect(input_device)}, output: #{inspect(output_device)}"
    )

    Map.merge(data, %{
      input_device_id: input_device,
      output_device_id: output_device,
      audio_source: :device,
      audio_sink: :device
    })
  end

  defp process_media_action(:noreply, data), do: data

  # Fork media to external service
  # The fork_config is a ForkConfig struct with destination info
  defp process_media_action({:fork_media, %ParrotMedia.ForkConfig{} = fork_config}, data) do
    Logger.info(
      "MediaSession #{data.id}: Forking media to #{inspect(fork_config.destination_address)}:#{fork_config.destination_port}"
    )

    # Forward the fork request to the pipeline
    if data.pipeline_pid && Process.alive?(data.pipeline_pid) do
      send(data.pipeline_pid, {:add_fork, fork_config})
    else
      Logger.warning("MediaSession #{data.id}: Cannot fork media - pipeline not running")
    end

    data
  end

  # Stop a media fork by ID
  defp process_media_action({:stop_fork, fork_id}, data) when is_binary(fork_id) do
    Logger.info("MediaSession #{data.id}: Stopping media fork '#{fork_id}'")

    if data.pipeline_pid && Process.alive?(data.pipeline_pid) do
      send(data.pipeline_pid, {:remove_fork, fork_id})
    else
      Logger.warning("MediaSession #{data.id}: Cannot stop fork - pipeline not running")
    end

    data
  end

  defp process_media_action(actions, data) when is_list(actions) do
    Enum.reduce(actions, data, &process_media_action/2)
  end

  defp process_media_action(action, data) do
    Logger.warning("MediaSession #{data.id}: Unknown media action: #{inspect(action)}")
    data
  end

  defp restart_pipeline_if_needed(data) do
    if data.pipeline_pid && Process.alive?(data.pipeline_pid) do
      Logger.info("MediaSession #{data.id}: Restarting pipeline with new audio file")
      data_after_stop = stop_media_pipeline(data)

      case start_media_pipeline(data_after_stop) do
        {:ok, new_pipeline_pid, monitor_ref, rtcp_receiver_pid} ->
          %{
            data_after_stop
            | pipeline_pid: new_pipeline_pid,
              pipeline_monitor: monitor_ref,
              rtcp_receiver_pid: rtcp_receiver_pid
          }

        {:error, reason} ->
          Logger.error("MediaSession #{data.id}: Failed to restart pipeline: #{inspect(reason)}")
          data_after_stop
      end
    else
      # Pipeline not running yet, just update the data
      data
    end
  end

  # Forward messages to media handler
  defp forward_to_media_handler(msg, data) do
    if function_exported?(data.media_handler, :handle_info, 2) do
      try do
        case data.media_handler.handle_info(msg, data.handler_state) do
          {actions, new_state} when is_list(actions) ->
            {:ok, actions, new_state}

          {:noreply, new_state} ->
            {:noreply, new_state}

          {action, new_state} ->
            {:ok, [action], new_state}

          other ->
            Logger.warning(
              "MediaSession #{data.id}: Unexpected return from handle_info: #{inspect(other)}"
            )

            :error
        end
      rescue
        e ->
          Logger.error("MediaSession #{data.id}: Error in media handler: #{inspect(e)}")
          :error
      end
    else
      # Handler doesn't implement handle_info/2 - this is okay, it's optional
      :no_handler_function
    end
  end

  # Process multiple media actions
  defp process_media_actions(actions, data) when is_list(actions) do
    Enum.reduce(actions, data, &process_media_action/2)
  end

  defp process_media_actions(action, data) do
    Logger.info(
      "MediaSession #{data.id}: process_media_actions - action:#{inspect(action)}, data:#{inspect(data)}"
    )

    process_media_action(action, data)
  end

  defp stop_media_pipeline(data) do
    if data.pipeline_pid && Process.alive?(data.pipeline_pid) do
      Logger.info("MediaSession #{data.id}: Stopping pipeline")

      # Demonitor before stopping
      if data.pipeline_monitor do
        Process.demonitor(data.pipeline_monitor, [:flush])
      end

      ensure_pipeline_termination(data.pipeline_pid, data.pipeline_module)
    end

    %{data | pipeline_pid: nil, pipeline_monitor: nil}
  end

  defp cleanup_session(data) do
    # Demonitor pipeline if monitored
    if data.pipeline_monitor do
      Logger.debug("MediaSession #{data.id}: Demonitoring pipeline")
      Process.demonitor(data.pipeline_monitor, [:flush])
    end

    # Stop media pipeline if running
    if data.pipeline_pid && Process.alive?(data.pipeline_pid) do
      Logger.debug("MediaSession #{data.id}: Stopping Membrane pipeline")
      # Use ensure_pipeline_termination for proper cleanup
      ensure_pipeline_termination(data.pipeline_pid, data.pipeline_module)
    end

    # Stop MOS Calculator if running
    maybe_stop_mos_calculator(data)

    # Close RTP socket if still open
    if data.rtp_socket do
      Logger.debug("MediaSession #{data.id}: Closing RTP socket")
      :gen_udp.close(data.rtp_socket)
    end

    Logger.info("MediaSession #{data.id}: Cleaned up resources")
  end

  # Helper function to get the IP address to use in SDP
  defp get_sdp_ip(data) do
    # If advertised_ip is set, use that (for NAT scenarios)
    cond do
      data.advertised_ip != nil ->
        normalize_ip(data.advertised_ip)

      data.local_ip == :auto ->
        # Auto-detect using the existing function
        Inet.first_ipv4_address()

      data.local_ip != nil ->
        normalize_ip(data.local_ip)

      true ->
        # Fallback to auto-detect
        Inet.first_ipv4_address()
    end
  end

  # Helper to normalize IP to tuple format for ExSDP
  defp normalize_ip(ip) when is_tuple(ip), do: ip

  defp normalize_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, ip_tuple} -> ip_tuple
      # Fallback to localhost on parse error
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  # Fallback for any other format
  defp normalize_ip(_), do: {127, 0, 0, 1}

  # Map audio format atoms to file extensions for TTS audio temp files
  defp audio_format_to_extension(:wav), do: "wav"
  defp audio_format_to_extension(:mp3), do: "mp3"
  defp audio_format_to_extension(:opus), do: "opus"
  defp audio_format_to_extension(:ogg), do: "ogg"
  defp audio_format_to_extension(:flac), do: "flac"
  defp audio_format_to_extension(:aac), do: "aac"
  defp audio_format_to_extension(_), do: "wav"

  defp ensure_pipeline_termination(pipeline_pid, _pipeline_module) when is_pid(pipeline_pid) do
    ref = Process.monitor(pipeline_pid)

    termination_result =
      case Membrane.Pipeline.terminate(pipeline_pid, force?: true) do
        :ok -> :ok
        error -> error
      end

    case termination_result do
      :ok ->
        receive do
          {:DOWN, ^ref, :process, ^pipeline_pid, _reason} ->
            :ok
        after
          5_000 ->
            Logger.error(
              "Pipeline #{inspect(pipeline_pid)} failed to terminate gracefully, forcing shutdown"
            )

            Process.exit(pipeline_pid, :kill)

            receive do
              {:DOWN, ^ref, :process, ^pipeline_pid, _reason} -> :ok
            after
              1_000 -> :timeout
            end
        end

      error ->
        Process.demonitor(ref, [:flush])
        Logger.error("Failed to terminate pipeline #{inspect(pipeline_pid)}: #{inspect(error)}")
        error
    end
  end

  # MOS Calculator helpers

  @doc false
  # Start MOS Calculator if MOS monitoring is enabled
  defp maybe_start_mos_calculator(data) do
    if MOS.Config.enabled?() do
      config = MOS.Config.merge([])
      codec = map_selected_codec_to_mos_codec(data.selected_codec)

      case MOS.Calculator.start_link(
             session_id: data.id,
             codec: codec,
             config: config
           ) do
        {:ok, calc_pid} ->
          Logger.info("MediaSession #{data.id}: MOS Calculator started")
          %{data | mos_calculator_pid: calc_pid}

        {:error, reason} ->
          Logger.warning(
            "MediaSession #{data.id}: Failed to start MOS Calculator: #{inspect(reason)}"
          )

          data
      end
    else
      data
    end
  end

  @doc false
  # Stop MOS Calculator if running, returning the call summary
  defp maybe_stop_mos_calculator(%{mos_calculator_pid: nil}), do: :ok

  defp maybe_stop_mos_calculator(%{mos_calculator_pid: pid, id: session_id}) when is_pid(pid) do
    if Process.alive?(pid) do
      Logger.info("MediaSession #{session_id}: Stopping MOS Calculator")

      case MOS.Calculator.stop(pid) do
        %MOS.CallSummary{} = summary ->
          Logger.info(
            "MediaSession #{session_id}: MOS summary - avg: #{summary.avg_mos}, " <>
              "min: #{summary.min_mos}, max: #{summary.max_mos}"
          )

          :ok

        :ok ->
          :ok
      end
    else
      :ok
    end
  end

  defp map_selected_codec_to_mos_codec(:pcma), do: :g711
  defp map_selected_codec_to_mos_codec(:opus), do: :opus
  defp map_selected_codec_to_mos_codec(_), do: :g711

  @impl true
  def terminate(reason, _state, data) do
    Logger.info("MediaSession #{data.id}: Terminating due to #{inspect(reason)}")
    cleanup_session(data)
    :ok
  end
end
