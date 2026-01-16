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
      mos_calculator_pid: nil
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
            mos_calculator_pid: pid() | nil
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
      {:ok, pipeline_pid, monitor_ref} ->
        Logger.info(
          "MediaSession #{data.id}: Media pipeline started successfully with PID: #{inspect(pipeline_pid)}"
        )

        final_data = %{updated_data | pipeline_pid: pipeline_pid, pipeline_monitor: monitor_ref}
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

  #################
  # State: paused #
  #################

  def paused({:call, from}, :resume_media, data) do
    Logger.info("MediaSession #{data.id}: Resuming media")

    # Restore direction to sendrecv
    updated_data = %{data | direction: :sendrecv}

    # Restart the pipeline
    case start_media_pipeline(updated_data) do
      {:ok, pipeline_pid, monitor_ref} ->
        Logger.info("MediaSession #{data.id}: Pipeline restarted successfully")
        final_data = %{updated_data | pipeline_pid: pipeline_pid, pipeline_monitor: monitor_ref}
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
      pipeline_active: data.pipeline_pid != nil
    }

    {:keep_state_and_data, [{:reply, from, state_info}]}
  end

  # Private helpers

  # Codec mapping between symbols and RTP payload types
  # Codec mapping - using standard SDP names
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
    # Allocate local RTP port and keep socket open
    {local_rtp_port, rtp_socket} = allocate_rtp_port()

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
            rtp_socket: rtp_socket
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
      {local_rtp_port, rtp_socket} = get_or_allocate_rtp_port(data_with_handler_state)

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

  defp get_or_allocate_rtp_port(%{local_rtp_port: port, rtp_socket: socket, id: session_id})
       when not is_nil(port) do
    Logger.info("MediaSession #{session_id}: Using pre-allocated local RTP port: #{port}")
    {port, socket}
  end

  defp get_or_allocate_rtp_port(%{id: session_id}) do
    {port, socket} = allocate_rtp_port()
    Logger.info("MediaSession #{session_id}: Allocated new local RTP port: #{port}")
    {port, socket}
  end

  defp build_session_data(
         data,
         sdp_offer,
         remote_info,
         selected_codec,
         local_rtp_port,
         rtp_socket,
         sdp_answer,
         pipeline_module,
         dynamic_payload_types
       ) do
    %{
      data
      | local_sdp: sdp_answer,
        remote_sdp: sdp_offer,
        local_rtp_port: local_rtp_port,
        rtp_socket: rtp_socket,
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
    static_codec_map = %{
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
      {:ok, port, socket} ->
        {port, socket}

      {:error, :no_ports_available} ->
        # Fallback to random port as last resort
        Logger.error(
          "Failed to find available RTP port in range #{min_port}-#{max_port}, using random port"
        )

        port = min_port + :rand.uniform(max_port - min_port)
        # Try to open socket for the fallback port
        case :gen_udp.open(port, [:binary, {:active, false}]) do
          {:ok, socket} -> {port, socket}
          {:error, _} -> {port, nil}
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
      # Keep RTP socket open to maintain port reservation
      with {:ok, rtp_socket} <- :gen_udp.open(rtp_port, [:binary, {:active, false}]),
           {:ok, rtcp_socket} <- :gen_udp.open(rtp_port + 1, [:binary, {:active, false}]) do
        # Close RTCP socket - only need to reserve RTP port
        :gen_udp.close(rtcp_socket)
        # Return with socket kept open for port reservation
        {:ok, rtp_port, rtp_socket}
      else
        {:error, :eaddrinuse} ->
          {:error, :in_use}

        error ->
          error
      end
    end)
    |> Enum.find({:error, :no_ports_available}, fn
      {:ok, _port, _socket} -> true
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
      audio_file: data.audio_file || :default_audio,
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
        {:ok, pipeline_pid, monitor_ref}

      {:ok, _supervisor_pid, pipeline_pid} ->
        # Membrane.Pipeline.start_link returns {ok, supervisor_pid, pipeline_pid}
        Logger.info(
          "MediaSession #{data.id}: Membrane pipeline created with PID: #{inspect(pipeline_pid)}"
        )

        monitor_ref = Process.monitor(pipeline_pid)
        {:ok, pipeline_pid, monitor_ref}

      {:error, reason} = error ->
        Logger.error(
          "MediaSession #{data.id}: Failed to start Membrane pipeline: #{inspect(reason)}"
        )

        error
    end
  end

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
        {:ok, new_pipeline_pid, monitor_ref} ->
          %{data_after_stop | pipeline_pid: new_pipeline_pid, pipeline_monitor: monitor_ref}

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
        %{} = summary ->
          Logger.info(
            "MediaSession #{session_id}: MOS summary - avg: #{summary[:avg_mos]}, " <>
              "min: #{summary[:min_mos]}, max: #{summary[:max_mos]}"
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
