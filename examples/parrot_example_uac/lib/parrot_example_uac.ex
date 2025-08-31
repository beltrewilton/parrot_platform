defmodule ParrotExampleUac do
  @moduledoc """
  Example UAC (User Agent Client) application with PortAudio support.
  
  This application demonstrates:
  - Making outbound SIP calls
  - Using system microphone for outbound audio
  - Playing received audio through system speakers
  - Bidirectional G.711 audio streaming
  - Proper call lifecycle management
  
  ## Architecture
  
  This UAC uses a simpler pattern than UAS:
  
  1. **UAC Callbacks** - The main module (ParrotExampleUac) handles SIP responses
     - Uses UAC.request/2 with a callback function
     - The callback receives SIP responses directly
     - Processes responses in handle_uac_response/2
  
  2. **MediaHandler** (ParrotExampleUac.MediaHandler) - Handles media session callbacks
     - Manages audio streaming lifecycle
     - Handles codec negotiation
     - Controls audio device configuration
  
  3. **Minimal Transport Handler** - Embedded in this module
     - Required by the transport layer but does minimal work
     - Just returns :noreply or :ok for all callbacks
  
  Unlike UAS which uses HandlerAdapter.Core, UAC primarily uses direct callbacks
  for response handling, making the architecture simpler for client applications.
  
  ## Usage
  
      # Start the UAC
      ParrotExampleUac.start()
      
      # Make a call using default audio devices
      ParrotExampleUac.call("sip:service@127.0.0.1:5060")
      
      # Make a call with specific audio devices
      ParrotExampleUac.call("sip:service@127.0.0.1:5060", input_device: 1, output_device: 2)
      
      # List available audio devices
      ParrotExampleUac.list_audio_devices()
      
      # Hang up the current call
      ParrotExampleUac.hangup()
  """
  
  use GenServer
  require Logger
  
  alias Parrot.Sip.{UAC, Message, Headers, Dialog}
  alias Parrot.Sip.Headers.{From, To, CallId}
  alias Parrot.Media.{MediaSession, MediaSessionSupervisor, AudioDevices}
  alias ParrotExampleUac.MediaHandler
  
  @server_name {:via, Registry, {Parrot.Registry, __MODULE__}}
  
  defmodule State do
    @moduledoc false
    defstruct [
      :transport_ref,
      :current_call,
      :media_session,
      :dialog_id,
      :call_id,
      :local_tag,
      :remote_tag,
      :input_device_id,
      :output_device_id
    ]
  end
  
  # Client API
  
  @doc """
  Starts the UAC application.
  """
  def start(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: @server_name) do
      {:ok, pid} ->
        Logger.info("ParrotExampleUac started successfully")
        {:ok, pid}
      {:error, {:already_started, pid}} ->
        Logger.info("ParrotExampleUac already running")
        {:ok, pid}
      error ->
        error
    end
  end
  
  @doc """
  Lists available audio devices.
  """
  def list_audio_devices do
    IO.puts("\n")
    AudioDevices.print_devices()
    IO.puts("\nNote: Use the device IDs shown above when calling ParrotExampleUac.call/2")
    IO.puts("Example: ParrotExampleUac.call(\"sip:service@127.0.0.1:5060\", input_device: 1, output_device: 2)")
    :ok
  end
  
  @doc """
  Makes an outbound call.
  
  Options:
    - :input_device - Audio input device ID (defaults to system default)
    - :output_device - Audio output device ID (defaults to system default)
  """
  def call(uri, opts \\ []) do
    GenServer.call(@server_name, {:make_call, uri, opts})
  end
  
  @doc """
  Hangs up the current call.
  """
  def hangup do
    GenServer.call(@server_name, :hangup)
  end
  
  @doc """
  Gets the current call status.
  """
  def status do
    GenServer.call(@server_name, :status)
  end
  
  # Server Callbacks
  
  @impl true
  def init(opts) do
    Logger.info("Initializing ParrotExampleUac")
    
    input_device = get_audio_device(opts[:input_device], :input)
    output_device = get_audio_device(opts[:output_device], :output)
    transport_opts = Keyword.get(opts, :transport, %{})
    
    with {:ok, ref} <- start_transport(transport_opts) do
      state = %State{
        transport_ref: ref,
        input_device_id: input_device,
        output_device_id: output_device
      }
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:transport_error, reason}}
    end
  end
  
  defp get_audio_device(nil, :input), do: get_default_device(&AudioDevices.get_default_input/0)
  defp get_audio_device(nil, :output), do: get_default_device(&AudioDevices.get_default_output/0)
  defp get_audio_device(device_id, _type), do: device_id
  
  defp get_default_device(get_fn) do
    case get_fn.() do
      {:ok, device_id} -> device_id
      _ -> nil
    end
  end
  
  @impl true
  def handle_call({:make_call, _uri, _opts}, _from, %{current_call: %{}} = state) do
    {:reply, {:error, :call_in_progress}, state}
  end
  
  def handle_call({:make_call, uri, opts}, _from, state) do
    # Override default devices if specified
    input_device = opts[:input_device] || state.input_device_id
    output_device = opts[:output_device] || state.output_device_id
      
      case do_make_call(uri, input_device, output_device, state) do
        {:ok, new_state} ->
          {:reply, :ok, new_state}
          
        {:error, reason} = error ->
          Logger.error("Failed to make call: #{inspect(reason)}")
          {:reply, error, state}
      end
    end
  
  @impl true
  def handle_call(:hangup, _from, state) do
    if state.current_call do
      new_state = do_hangup(state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :no_active_call}, state}
    end
  end
  
  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      active_call: state.current_call != nil,
      call_id: state.call_id,
      dialog_id: state.dialog_id,
      media_active: state.media_session != nil
    }
    
    {:reply, status, state}
  end
  
  @impl true
  def handle_info({:uac_response, response}, state) do
    new_state = handle_uac_response(response, state)
    {:noreply, new_state}
  end
  
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
  
  # Private Functions
  
  defp start_transport(opts) do
    listen_port = opts[:listen_port] || 0  # Use ephemeral port
    
    # Create a minimal handler inline - UAC doesn't need a separate handler module
    # since the actual response handling is done via the UAC callback
    handler = Parrot.Sip.Handler.new(
      __MODULE__,  # Use this module as the handler
      self(),
      log_level: :debug,
      sip_trace: true
    )
    
    case Parrot.Sip.Transport.StateMachine.start_udp(%{
      handler: handler,
      listen_port: listen_port
    }) do
      :ok ->
        {:ok, make_ref()}
      error ->
        error
    end
  end
  
  # Minimal transport handler callbacks - required by Parrot.Sip.Handler behaviour
  # For UAC, these just return minimal responses since actual processing
  # happens via UAC.request callbacks
  
  @doc false
  def transp_request(_msg, _owner_pid), do: :noreply
  
  @doc false
  def transaction(_trans, _sip_msg, _owner_pid), do: :ok
  
  @doc false
  def transaction_stop(_trans, _result, _owner_pid), do: :ok
  
  @doc false
  def uas_request(_uas, _req_sip_msg, _owner_pid), do: :ok
  
  @doc false
  def uas_cancel(_uas_id, _owner_pid), do: :ok
  
  @doc false
  def process_ack(_sip_msg, _owner_pid), do: :ok
  
  defp do_make_call(uri, input_device, output_device, state) do
    # Generate call parameters using library helpers
    local_ip = get_local_ip()
    call_id = Headers.generate_call_id(local_ip)
    local_tag = Headers.generate_tag()
    
    # Create dialog ID using library function
    dialog_id = Dialog.new(call_id, local_tag, nil, :uac)
    dialog_id_str = Dialog.to_string(dialog_id)
    
    # Step 1: Prepare UAC session using MediaSessionManager
    Logger.debug("Preparing UAC media session with audio devices...")
    {:ok, media_pid} = MediaSessionSupervisor.start_session(
      id: "uac-media-#{call_id}",
      dialog_id: dialog_id_str,
      role: :uac,
      media_handler: MediaHandler,
      handler_args: %{},
      supported_codecs: [:opus, :pcma],
      # Configure audio devices upfront so PortAudioPipeline is selected
      input_device_id: input_device,
      output_device_id: output_device,
      audio_source: if(input_device, do: :device, else: :silence),
      audio_sink: if(output_device, do: :device, else: :none)
    )

    case MediaSession.generate_offer(media_pid) do
      {:ok, sdp_offer} ->
        Logger.debug("UAC session prepared with SDP offer")
        
        # Step 2: Create INVITE with the SDP from MediaSessionManager
        # Using library helpers for header creation
        headers = %{
          "via" => [Headers.new_via_with_branch(local_ip, "udp", 5060)],
          "from" => Headers.new_from_with_tag("sip:parrot_uac@#{local_ip}", "Parrot UAC"),
          "to" => Headers.new_to(uri),
          "call-id" => CallId.new(call_id),
          "cseq" => Headers.new_cseq(1, :invite),
          "contact" => Headers.new_contact("sip:parrot_uac@#{local_ip}:5060"),
          "content-type" => "application/sdp",
          "allow" => Headers.standard_allow() |> Headers.format_allow(),
          "supported" => Headers.new_supported(["replaces", "timer"]) |> Headers.format_supported(),
          "max-forwards" => Headers.default_max_forwards()
        }
        
        invite = Message.new_request(:invite, uri, headers)
        |> Message.set_body(sdp_offer)
        
        # Create UAC callback that will handle the SIP response
        callback = create_uac_callback(self())
        
        # Step 3: Send INVITE with callback for response handling
        {:uac_id, transaction} = UAC.request(invite, callback)
        Logger.info("INVITE sent, transaction: #{inspect(transaction)}")
        
        # Store session info for later
        new_state = %{state |
          current_call: uri,
          call_id: call_id,
          local_tag: local_tag,
          dialog_id: dialog_id,
          media_session: media_pid
        }
        
        {:ok, new_state}
        
      {:error, reason} ->
        Logger.error("Failed to prepare UAC session: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp create_uac_callback(pid) do
    fn response ->
      send(pid, {:uac_response, response})
    end
  end
  
  defp handle_uac_response({:response, %{status_code: code} = response}, state)
       when code >= 100 and code < 200 do
    # Provisional response
    Logger.info("Call progress: #{code} #{response.reason_phrase}")
    
    if code == 180 do
      IO.puts("\n🔔 Ringing...")
    end
    
    state
  end

  defp handle_uac_response({:response, %{status_code: 200} = response}, state) do
    # Success - check method using pattern matching
    handle_200_response(response, state)
  end

  defp handle_uac_response({:response, %{status_code: code} = response}, state)
       when code >= 300 and code < 400 do
    # Redirect
    Logger.info("Call redirected: #{code} #{response.reason_phrase}")
    IO.puts("\n↪️  Call redirected: #{response.reason_phrase}")
    state
  end

  defp handle_uac_response({:response, %{status_code: code} = response}, state)
       when code >= 400 do
    # Error
    Logger.error("Call failed: #{code} #{response.reason_phrase}")
    IO.puts("\n❌ Call failed: #{response.reason_phrase}")
    
    # Clean up
    if state.media_session do
      MediaSession.terminate_session(state.media_session)
    end
    
    Process.delete({:call_context, state.call_id})
    
    %{state |
      current_call: nil,
      call_id: nil,
      local_tag: nil,
      dialog_id: nil,
      media_session: nil
    }
  end
  
  defp handle_uac_response({:error, reason}, state) do
    Logger.error("UAC error: #{inspect(reason)}")
    IO.puts("\n❌ Call error: #{inspect(reason)}")
    
    # Clean up
    if state.media_session do
      MediaSession.terminate_session(state.media_session)
    end
    
    Process.delete({:call_context, state.call_id})
    
    %{state |
      current_call: nil,
      call_id: nil,
      local_tag: nil,
      media_session: nil,
      dialog_id: nil,
      remote_tag: nil
    }
  end
  
  # Helper for handling 200 OK responses based on method
  defp handle_200_response(%{headers: %{"cseq" => %{method: :invite}}} = response, state) do
    # Success - call answered
    Logger.info("Call answered!")
    IO.puts("\n✅ Call connected! Audio devices active.")
    IO.puts("🎤 Speaking through microphone...")
    IO.puts("🔊 Listening through speakers...")
    IO.puts("\nPress Enter to hang up")
    
    # Extract remote tag and update dialog ID
    remote_tag = case response.headers["to"] do
      %{parameters: %{"tag" => tag}} -> tag
      _ -> nil
    end
    Logger.debug("Remote tag: #{inspect(remote_tag)}")
    
    # Update dialog with remote tag
    updated_dialog = Dialog.new(state.call_id, state.local_tag, remote_tag, :uac)
    
    # Send ACK immediately after receiving 200 OK for INVITE
    Logger.info("Sending ACK for 200 OK...")
    send_ack(state, response)
    
    # Extract SDP answer from response
    sdp_answer = response.body
    Logger.debug("Completing UAC setup with SDP answer...")

    case MediaSession.process_answer(state.media_session, sdp_answer) do
      :ok ->
        MediaSession.start_media(state.media_session)
        
        Logger.info("UAC setup completed successfully, media is flowing")
        
        # Start a task to wait for Enter key
        Task.start(fn ->
          IO.gets("")
          GenServer.call(@server_name, :hangup)
        end)
        
        %{state |
          dialog_id: updated_dialog,
          remote_tag: remote_tag
        }
        
      {:error, reason} ->
        Logger.error("Failed to complete UAC setup: #{inspect(reason)}")
        IO.puts("\n❌ Failed to establish media: #{inspect(reason)}")
        # TODO: Send BYE to terminate the call
        state
    end
  end
  
  defp handle_200_response(%{headers: %{"cseq" => %{method: :bye}}}, state) do
    # Success response to BYE - no ACK needed
    Logger.info("BYE acknowledged")
    # Clean up already done in do_hangup
    state
  end
  
  defp handle_200_response(%{headers: %{"cseq" => cseq}} = _response, state) do
    # Other successful response
    Logger.debug("Success response for #{inspect(cseq)}")
    state
  end
  
  defp send_ack(state, response) do
    # Extract remote tag from response
    remote_tag = case response.headers["to"] do
      %{parameters: %{"tag" => tag}} -> tag
      _ -> state.remote_tag
    end
    
    local_ip = get_local_ip()
    
    headers = %{
      "via" => [Headers.new_via_with_branch(local_ip, "udp", 5060)],
      "from" => From.new("sip:parrot_uac@#{local_ip}", "Parrot UAC", state.local_tag),
      "to" => To.new(state.current_call, nil, %{"tag" => remote_tag}),
      "call-id" => CallId.new(state.call_id),
      "cseq" => Headers.new_cseq(1, :ack),
      "contact" => Headers.new_contact("sip:parrot_uac@#{local_ip}:5060"),
      "max-forwards" => Headers.default_max_forwards()
    }
    
    ack = Message.new_request(:ack, state.current_call, headers)
    
    # ACK is sent without expecting a response
    UAC.ack_request(ack)
    Logger.info("ACK sent to #{state.current_call}")
  end
  
  defp do_hangup(state) do
    Logger.info("Hanging up call")
    
    local_ip = get_local_ip()
    
    # Send BYE
    headers = %{
      "via" => [Headers.new_via_with_branch(local_ip, "udp", 5060)],
      "from" => From.new("sip:parrot_uac@#{local_ip}", "Parrot UAC", state.local_tag),
      "to" => To.new(state.current_call, nil, %{"tag" => state.remote_tag}),
      "call-id" => CallId.new(state.call_id),
      "cseq" => Headers.new_cseq(2, :bye),
      "contact" => Headers.new_contact("sip:parrot_uac@#{local_ip}:5060"),
      "max-forwards" => Headers.default_max_forwards()
    }
    
    bye = Message.new_request(:bye, state.current_call, headers)
    
    callback = create_uac_callback(self())
    UAC.request(bye, callback)
    
    # Stop media session
    if state.media_session do
      MediaSession.terminate_session(state.media_session)
    end
    
    # Clean up
    Process.delete({:call_context, state.call_id})
    
    IO.puts("\n📞 Call ended")
    
    %{state |
      current_call: nil,
      call_id: nil,
      local_tag: nil,
      remote_tag: nil,
      media_session: nil,
      dialog_id: nil
    }
  end
  
  
  defp get_local_ip do
    {:ok, addrs} = :inet.getifaddrs()
    
    addrs
    |> Enum.flat_map(fn {_iface, opts} ->
      opts
      |> Enum.filter(fn {:addr, addr} -> tuple_size(addr) == 4 and addr != {127, 0, 0, 1}
                       _ -> false end)
      |> Enum.map(fn {:addr, addr} -> addr end)
    end)
    |> List.first()
    |> case do
      nil -> {127, 0, 0, 1}
      addr -> addr
    end
    |> Tuple.to_list()
    |> Enum.join(".")
  end
  
end
