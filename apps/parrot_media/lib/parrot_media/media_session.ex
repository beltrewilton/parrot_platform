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
  alias ParrotMedia.Inet

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
      # Membrane pipeline PID
      :pipeline_pid,
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
      :advertised_ip
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
            pipeline_pid: pid() | nil,
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
            advertised_ip: String.t() | tuple() | nil
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
  - `:audio_file` - Path to audio file to play (used when audio_source is :file)
  - `:audio_source` - Source of audio: `:file` | `:device` | `:silence` (defaults to :file if audio_file provided)
  - `:audio_sink` - Destination for received audio: `:none` | `:device` | `:file` (defaults to :none)
  - `:output_file` - Path to save received audio when audio_sink is :file
  - `:input_device_id` - PortAudio device ID for microphone when audio_source is :device
  - `:output_device_id` - PortAudio device ID for speaker when audio_sink is :device
  - `:supported_codecs` - List of supported codecs in preference order (defaults to [:pcma])
  - `:local_ip` - Local IP address for media: `:auto` | IP string | IP tuple (defaults to :auto)
  - `:advertised_ip` - IP to advertise in SDP if different from local_ip (for NAT scenarios)
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
  """
  @spec generate_offer(String.t() | pid()) :: {:ok, String.t()} | {:error, term()}
  def generate_offer(session) do
    :gen_statem.call(get_pid(session), :generate_offer)
  end

  @doc """
  Processes an SDP offer and generates an answer.

  ## Examples

      iex> {:ok, answer} = MediaSession.process_offer("session_1", "v=0\\r\\n...")
      {:ok, "v=0\\r\\no=- 123456 123456 IN IP4 127.0.0.1\\r\\n..."}

  ## Parameters

    * `session_id` - The session identifier
    * `sdp_offer` - The SDP offer as a string

  ## Returns

    * `{:ok, sdp_answer}` - Successfully negotiated, returns SDP answer
    * `{:error, reason}` - Negotiation failed
  """
  @spec process_offer(String.t() | pid(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def process_offer(session, sdp_offer) do
    Logger.debug("MediaSession.process_offer called for session: #{inspect(session)}")
    :gen_statem.call(get_pid(session), {:process_offer, sdp_offer})
  end

  @doc """
  Processes an SDP answer (UAC case).
  """
  @spec process_answer(String.t() | pid(), String.t()) :: :ok | {:error, term()}
  def process_answer(session, sdp_answer) do
    :gen_statem.call(get_pid(session), {:process_answer, sdp_answer})
  end

  @doc """
  Starts the media streams.
  """
  @spec start_media(String.t() | pid()) :: :ok | {:error, term()}
  def start_media(session) do
    :gen_statem.call(get_pid(session), :start_media)
  end

  @doc """
  Pauses the media streams.
  """
  @spec pause_media(String.t() | pid()) :: :ok | {:error, term()}
  def pause_media(session) do
    :gen_statem.call(get_pid(session), :pause_media)
  end

  @doc """
  Resumes the media streams.
  """
  @spec resume_media(String.t() | pid()) :: :ok | {:error, term()}
  def resume_media(session) do
    :gen_statem.call(get_pid(session), :resume_media)
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
      advertised_ip: advertised_ip
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
    {:next_state, :ready, %{data | pipeline_pid: nil}}
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
    {:next_state, :ready, %{data | pipeline_pid: nil}}
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

    # Start media pipeline
    case start_media_pipeline(updated_data) do
      {:ok, pipeline_pid} ->
        Logger.info(
          "MediaSession #{data.id}: Media pipeline started successfully with PID: #{inspect(pipeline_pid)}"
        )

        final_data = %{updated_data | pipeline_pid: pipeline_pid}
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
    {:next_state, :ready, %{data | pipeline_pid: nil}}
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

  def active({:call, from}, :pause_media, _data) do
    # Pause not implemented
    {:keep_state_and_data, [{:reply, from, {:error, :not_implemented}}]}
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
    {:next_state, :ready, %{data | pipeline_pid: nil}}
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

  def paused({:call, from}, :resume_media, _data) do
    # Resume not implemented
    {:keep_state_and_data, [{:reply, from, {:error, :not_implemented}}]}
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
    {:next_state, :ready, %{data | pipeline_pid: nil}}
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

  defp handle_media_message(msg, data) do
    case msg do
      {:play_files, _files, _opts} ->
        Logger.info("MediaSession #{data.id}: Handling play_files message")

      :stop_playback ->
        Logger.info("MediaSession #{data.id}: Handling stop_playback message")

      _ ->
        Logger.debug("MediaSession #{data.id}: Forwarding message to handler: #{inspect(msg)}")
    end

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

        {:keep_state_and_data, []}

      :error ->
        # Handler exists but had an error or didn't handle the message
        Logger.warning(
          "MediaSession #{data.id}: Unexpected info message not handled: #{inspect(msg)}"
        )

        {:keep_state_and_data, []}
    end
  end

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
  defp codec_info(:opus), do: {111, "opus/48000/2", ParrotMedia.OpusPipeline}

  defp get_codec_payload_type(codec) do
    {pt, _, _} = codec_info(codec)
    pt
  end

  defp get_codec_rtpmap(codec) do
    {pt, rtpmap, _} = codec_info(codec)
    {pt, rtpmap}
  end

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
    # Allocate local RTP port
    local_rtp_port = allocate_rtp_port()

    # Get the IP address to use in SDP
    sdp_ip = get_sdp_ip(data)

    # Build media formats based on supported codecs
    formats = Enum.map(data.supported_codecs, &get_codec_payload_type/1)

    # Build RTP mappings
    attributes =
      Enum.flat_map(data.supported_codecs, fn codec ->
        {pt, rtpmap} = get_codec_rtpmap(codec)

        [
          %ExSDP.Attribute.RTPMapping{
            payload_type: pt,
            encoding: String.split(rtpmap, "/") |> List.first(),
            clock_rate: rtpmap |> String.split("/") |> Enum.at(1) |> String.to_integer()
          }
        ]
      end) ++ [:sendrecv]

    # Create SDP using ex_sdp
    sdp = %ExSDP{
      version: 0,
      origin: %ExSDP.Origin{
        username: "-",
        session_id: :os.system_time(:second),
        session_version: :os.system_time(:second),
        network_type: "IN",
        address: sdp_ip
      },
      session_name: "Parrot Media Session",
      connection_data: %ExSDP.ConnectionData{
        network_type: "IN",
        address: sdp_ip
      },
      timing: %ExSDP.Timing{
        start_time: 0,
        stop_time: 0
      },
      media: [
        %ExSDP.Media{
          type: :audio,
          port: local_rtp_port,
          protocol: "RTP/AVP",
          fmt: formats,
          attributes: attributes
        }
      ]
    }

    sdp_string = to_string(sdp)
    updated_data = %{data | local_sdp: sdp_string, local_rtp_port: local_rtp_port}
    {:ok, sdp_string, updated_data}
  end

  defp process_sdp_offer(sdp_offer, data) do
    Logger.debug("MediaSession #{data.id}: Parsing SDP offer")

    with {:ok, parsed_sdp} <- ExSDP.parse(sdp_offer),
         {:ok, audio_media} <- find_audio_media(parsed_sdp),
         {:ok, remote_info} <- extract_remote_info(parsed_sdp, audio_media, data.id),
         {:ok, selected_codec, handler_state} <- negotiate_codec(audio_media, data) do
      data_with_handler_state = %{data | handler_state: handler_state}
      local_rtp_port = get_or_allocate_rtp_port(data_with_handler_state)
      sdp_answer = generate_answer_sdp(local_rtp_port, selected_codec, data_with_handler_state)
      pipeline_module = get_pipeline_module_for_config(selected_codec, data_with_handler_state)

      session_data =
        build_session_data(
          data_with_handler_state,
          sdp_offer,
          remote_info,
          selected_codec,
          local_rtp_port,
          sdp_answer,
          pipeline_module
        )

      {:ok, final_data} =
        call_handler_if_present(session_data, sdp_answer, sdp_offer, selected_codec)

      Logger.info("MediaSession #{data.id}: SDP negotiation complete")
      {:ok, sdp_answer, final_data}
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

  defp get_or_allocate_rtp_port(%{local_rtp_port: port, id: session_id}) when not is_nil(port) do
    Logger.info("MediaSession #{session_id}: Using pre-allocated local RTP port: #{port}")
    port
  end

  defp get_or_allocate_rtp_port(%{id: session_id}) do
    port = allocate_rtp_port()
    Logger.info("MediaSession #{session_id}: Allocated new local RTP port: #{port}")
    port
  end

  defp build_session_data(
         data,
         sdp_offer,
         remote_info,
         selected_codec,
         local_rtp_port,
         sdp_answer,
         pipeline_module
       ) do
    %{
      data
      | local_sdp: sdp_answer,
        remote_sdp: sdp_offer,
        local_rtp_port: local_rtp_port,
        remote_rtp_port: remote_info.port,
        remote_rtp_address: remote_info.address,
        selected_codec: selected_codec,
        pipeline_module: pipeline_module
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

  defp generate_answer_sdp(local_rtp_port, selected_codec, data) do
    {pt, rtpmap} = get_codec_rtpmap(selected_codec)

    # Get the IP address to use in SDP
    sdp_ip = get_sdp_ip(data)

    sdp = %ExSDP{
      version: 0,
      origin: %ExSDP.Origin{
        username: "-",
        session_id: :os.system_time(:second),
        session_version: :os.system_time(:second),
        network_type: "IN",
        address: sdp_ip
      },
      session_name: "Parrot Media Session",
      connection_data: %ExSDP.ConnectionData{
        network_type: "IN",
        address: sdp_ip
      },
      timing: %ExSDP.Timing{
        start_time: 0,
        stop_time: 0
      },
      media: [
        %ExSDP.Media{
          type: :audio,
          port: local_rtp_port,
          protocol: "RTP/AVP",
          fmt: [pt],
          attributes: [
            %ExSDP.Attribute.RTPMapping{
              payload_type: pt,
              encoding: String.split(rtpmap, "/") |> List.first(),
              clock_rate: rtpmap |> String.split("/") |> Enum.at(1) |> String.to_integer()
            },
            :sendrecv
          ]
        }
      ]
    }

    to_string(sdp)
  end

  defp process_sdp_answer(sdp_answer, data) do
    with {:ok, parsed_sdp} <- ExSDP.parse(sdp_answer),
         {:ok, audio_media} <- find_audio_media(parsed_sdp),
         {:ok, remote_info} <- extract_answer_remote_info(parsed_sdp, audio_media, data.id),
         {:ok, updated_data} <- build_answer_data(sdp_answer, remote_info, audio_media, data) do
      {:ok, updated_data}
    end
  end

  defp extract_answer_remote_info(parsed_sdp, audio_media, session_id) do
    remote_address = get_remote_address(parsed_sdp, session_id)
    remote_port = audio_media.port

    {:ok, %{address: remote_address, port: remote_port}}
  end

  defp build_answer_data(sdp_answer, remote_info, audio_media, data) do
    selected_codec =
      audio_media
      |> extract_offered_codecs()
      |> List.first(:pcma)

    pipeline_module = get_pipeline_module_for_config(selected_codec, data)

    updated_data = %{
      data
      | remote_sdp: sdp_answer,
        remote_rtp_port: remote_info.port,
        remote_rtp_address: remote_info.address,
        selected_codec: selected_codec,
        pipeline_module: pipeline_module
    }

    {:ok, updated_data}
  end

  defp allocate_rtp_port(config \\ %{}) do
    min_port = Map.get(config, :min_rtp_port, 16384)
    max_port = Map.get(config, :max_rtp_port, 32768)
    max_attempts = Map.get(config, :max_port_attempts, 100)

    case find_available_port(min_port, max_port, max_attempts) do
      {:ok, port} ->
        port

      {:error, :no_ports_available} ->
        # Fallback to random port as last resort
        Logger.error(
          "Failed to find available RTP port in range #{min_port}-#{max_port}, using random port"
        )

        min_port + :rand.uniform(max_port - min_port)
    end
  end

  defp find_available_port(min_port, max_port, max_attempts) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.take(max_attempts)
    |> Stream.map(fn _ ->
      port = min_port + :rand.uniform(max_port - min_port)

      case :gen_udp.open(port, [:binary, {:active, false}]) do
        {:ok, socket} ->
          :gen_udp.close(socket)
          {:ok, port}

        {:error, :eaddrinuse} ->
          {:error, :in_use}

        error ->
          error
      end
    end)
    |> Enum.find({:error, :no_ports_available}, fn
      {:ok, _port} -> true
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
      selected_codec: data.selected_codec
    }

    Logger.info("MediaSession #{data.id}: Pipeline init args: #{inspect(init_arg)}")

    # Use the dynamically selected pipeline module based on negotiated codec
    pipeline_module = data.pipeline_module || ParrotMedia.RtpPipeline

    Logger.info(
      "MediaSession #{data.id}: Using pipeline module: #{inspect(pipeline_module)} for codec: #{inspect(data.selected_codec)}"
    )

    # Start the pipeline based on the module type
    start_result =
      if pipeline_module == ParrotMedia.RtpPipeline do
        # RtpPipeline is a GenServer
        GenServer.start_link(pipeline_module, init_arg)
      else
        # AlawPipeline uses Membrane.Pipeline
        Membrane.Pipeline.start_link(pipeline_module, init_arg)
      end

    case start_result do
      {:ok, pipeline_pid} ->
        Logger.info(
          "MediaSession #{data.id}: Membrane pipeline created with PID: #{inspect(pipeline_pid)}"
        )

        Process.monitor(pipeline_pid)
        {:ok, pipeline_pid}

      {:ok, _supervisor_pid, pipeline_pid} ->
        # Membrane.Pipeline.start_link returns {ok, supervisor_pid, pipeline_pid}
        Logger.info(
          "MediaSession #{data.id}: Membrane pipeline created with PID: #{inspect(pipeline_pid)}"
        )

        Process.monitor(pipeline_pid)
        {:ok, pipeline_pid}

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
      [first | _rest] ->
        updated_data = %{data | audio_file: first, audio_source: :file}
        restart_pipeline_if_needed(updated_data)

      [] ->
        data
    end
  end

  defp process_media_action({:play_loop, files}, data) when is_list(files) do
    Logger.info("MediaSession #{data.id}: Playing #{length(files)} files in loop")

    case files do
      [first | _rest] ->
        updated_data = %{data | audio_file: first, audio_source: :file}
        restart_pipeline_if_needed(updated_data)

      [] ->
        data
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
      stop_media_pipeline(data)

      case start_media_pipeline(data) do
        {:ok, new_pipeline_pid} ->
          %{data | pipeline_pid: new_pipeline_pid}

        {:error, reason} ->
          Logger.error("MediaSession #{data.id}: Failed to restart pipeline: #{inspect(reason)}")
          data
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
      ensure_pipeline_termination(data.pipeline_pid, data.pipeline_module)
    end

    %{data | pipeline_pid: nil}
  end

  defp cleanup_session(data) do
    # Stop media pipeline if running
    if data.pipeline_pid && Process.alive?(data.pipeline_pid) do
      Logger.debug("MediaSession #{data.id}: Stopping Membrane pipeline")
      # Use ensure_pipeline_termination for proper cleanup
      ensure_pipeline_termination(data.pipeline_pid, data.pipeline_module)
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

  defp ensure_pipeline_termination(pipeline_pid, pipeline_module) when is_pid(pipeline_pid) do
    ref = Process.monitor(pipeline_pid)

    termination_result =
      if pipeline_module == ParrotMedia.RtpPipeline do
        try do
          GenServer.stop(pipeline_pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
      else
        case Membrane.Pipeline.terminate(pipeline_pid, force?: true) do
          :ok -> :ok
          error -> error
        end
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

  @impl true
  def terminate(reason, _state, data) do
    Logger.info("MediaSession #{data.id}: Terminating due to #{inspect(reason)}")
    cleanup_session(data)
    :ok
  end
end
