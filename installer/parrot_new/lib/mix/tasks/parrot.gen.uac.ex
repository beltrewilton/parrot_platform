defmodule Mix.Tasks.Parrot.Gen.Uac do
  @shortdoc "Generates a new Parrot UAC (User Agent Client) application"
  @moduledoc """
  Generates a new Parrot UAC application from a template.

  ## Usage

      mix parrot.gen.uac APP_NAME [OPTIONS]

  ## Examples

      mix parrot.gen.uac my_uac_app
      mix parrot.gen.uac my_uac_app --port 5070
      mix parrot.gen.uac my_uac_app --module MyCompany.UacApp
      mix parrot.gen.uac my_uac_app --dev

  ## Options

    * `--port` - The local SIP port to bind (default: 5070)
    * `--module` - The module name to use (default: derived from app name)
    * `--dev` - Use path dependencies for local development (for contributors)

  The generator creates:

    * A complete UAC application using ParrotSip.UA.Handler
    * ParrotMedia.Handler implementation for audio handling
    * Transport setup with SIP stack wiring
    * README with usage instructions

  The generated application will:

    * Make outbound SIP calls
    * Negotiate SDP and stream audio to callees
    * Handle call progress (ringing, answered, rejected)
    * Handle BYE gracefully
  """

  use Mix.Task
  import Mix.Generator

  @switches [
    port: :integer,
    module: :string,
    dev: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse!(args, switches: @switches) do
      {opts, [app_name]} ->
        generate(app_name, opts)

      {_, _} ->
        Mix.raise("Expected exactly one argument (the application name)")
    end
  end

  defp generate(app_name, opts) do
    path = Path.expand(app_name)
    app = to_app_name(app_name)
    module = opts[:module] || to_module_name(app_name)
    port = opts[:port] || 5070
    dev = opts[:dev] || false

    binding = [
      app: app,
      module: module,
      port: port,
      dev: dev
    ]

    create_directory(path)
    create_directory(Path.join(path, "lib/#{app}"))
    create_directory(Path.join(path, "config"))
    create_directory(Path.join(path, "test"))

    create_file(Path.join(path, "mix.exs"), EEx.eval_string(mix_exs_template(), assigns: binding))
    create_file(Path.join(path, "config/config.exs"), EEx.eval_string(config_template(), assigns: binding))
    create_file(Path.join(path, "README.md"), EEx.eval_string(readme_template(), assigns: binding))
    create_file(Path.join(path, "lib/#{app}.ex"), EEx.eval_string(main_module_template(), assigns: binding))
    create_file(Path.join(path, "lib/#{app}/application.ex"), EEx.eval_string(application_template(), assigns: binding))
    create_file(Path.join(path, "lib/#{app}/client.ex"), EEx.eval_string(client_template(), assigns: binding))
    create_file(Path.join(path, "lib/#{app}/handler.ex"), EEx.eval_string(handler_template(), assigns: binding))
    create_file(Path.join(path, "lib/#{app}/media_handler.ex"), EEx.eval_string(media_handler_template(), assigns: binding))
    create_file(Path.join(path, "test/#{app}_test.exs"), EEx.eval_string(test_template(), assigns: binding))
    create_file(Path.join(path, ".gitignore"), gitignore_template())
    create_file(Path.join(path, ".formatter.exs"), formatter_template())

    Mix.shell().info("""

    Your Parrot UAC application has been generated!

    To get started:

        cd #{app_name}
        mix deps.get
        iex -S mix

    To make a call:

        iex> #{module}.dial("sip:service@127.0.0.1:5060")

    To hang up:

        iex> #{module}.hangup("call_id")

    Check the README.md for more information.
    """)
  end

  defp to_app_name(name) do
    name
    |> Path.basename()
    |> String.downcase()
    |> String.replace(~r/[^\w]/, "_")
    |> String.trim("_")
  end

  defp to_module_name(name) do
    name
    |> String.split(~r/[^a-zA-Z0-9]/)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end

  # Templates

  defp mix_exs_template do
    ~S"""
    defmodule <%= @module %>.MixProject do
      use Mix.Project

      def project do
        [
          app: :<%= @app %>,
          version: "0.1.0",
          elixir: "~> 1.16",
          start_permanent: Mix.env() == :prod,
          deps: deps()
        ]
      end

      def application do
        [
          extra_applications: [:logger],
          mod: {<%= @module %>.Application, []}
        ]
      end

      defp deps do
        <%= if @dev do %>
        # Development dependencies - path to local parrot_platform
        # Change these paths to match your local setup
        [
          {:parrot_sip, path: "../parrot_platform/apps/parrot_sip"},
          {:parrot_transport, path: "../parrot_platform/apps/parrot_transport"},
          {:parrot_media, path: "../parrot_platform/apps/parrot_media"}
        ]
        <% else %>
        [
          {:parrot_sip, "~> 0.0.1"},
          {:parrot_transport, "~> 0.0.1"},
          {:parrot_media, "~> 0.0.1"}
        ]
        <% end %>
      end
    end
    """
  end

  defp config_template do
    """
    import Config

    config :<%= @app %>,
      port: String.to_integer(System.get_env("PORT") || "<%= @port %>"),
      # PortAudio device IDs - use ParrotMedia.PortAudio.list_devices() to find yours
      # Set to nil to use system defaults
      input_device_id: nil,
      output_device_id: nil,
      # Alternative: audio file mode (update client.ex to use audio_file instead of devices)
      audio_file: System.get_env("AUDIO_FILE")

    config :logger, :console,
      format: "$time $metadata[$level] $message\\n",
      metadata: [:file, :line]
    """
  end

  defp readme_template do
    """
    # <%= @module %> - Parrot UAC Application

    A SIP User Agent Client (UAC) application built with Parrot Platform.

    ## Overview

    This application:
    - Makes outbound SIP calls
    - Uses your microphone and speaker for real-time audio (PortAudio)
    - Handles call progress (ringing, answered, rejected)
    - Handles BYE gracefully

    ## Running the Application

    ```bash
    # Start the application
    iex -S mix

    # Or on a specific port
    PORT=5080 iex -S mix
    ```

    ## Making Calls

    ```elixir
    # Make a call
    iex> <%= @module %>.dial("sip:service@192.168.1.100:5060")
    {:ok, "call_abc123"}

    # List active calls
    iex> <%= @module %>.calls()
    %{"call_abc123" => %{...}}

    # Hang up a call
    iex> <%= @module %>.hangup("call_abc123")
    :ok
    ```

    ## Audio Device Configuration

    By default, the UAC uses your system's default microphone and speaker.
    To use specific audio devices, find your device IDs:

    ```elixir
    iex> ParrotMedia.PortAudio.list_devices()
    [
      %{id: 0, name: "Built-in Microphone", ...},
      %{id: 1, name: "Built-in Output", ...},
      ...
    ]
    ```

    Then configure in `config/config.exs`:

    ```elixir
    config :<%= @app %>,
      input_device_id: 0,   # Your microphone device ID
      output_device_id: 1   # Your speaker device ID
    ```

    ## Alternative: Audio File Mode

    To play an audio file instead of using mic/speaker, edit `lib/<%= @app %>/client.ex`
    and swap the commented MediaSession configuration blocks.

    ## Configuration

    - `PORT` - Local SIP port to bind (default: <%= @port %>)
    - `input_device_id` - PortAudio input device ID (nil = system default)
    - `output_device_id` - PortAudio output device ID (nil = system default)
    - `AUDIO_FILE` - Path to WAV file (only used in audio file mode)

    ## Architecture

    - `<%= @module %>.Client` - Main GenServer managing UA and transport
    - `<%= @module %>.Handler` - ParrotSip.UA.Handler for call events
    - `<%= @module %>.MediaHandler` - ParrotMedia.Handler for media events
    """
  end

  defp main_module_template do
    """
    defmodule <%= @module %> do
      @moduledoc \"\"\"
      <%= @module %> - A SIP User Agent Client (UAC) application.

      This UAC makes outbound calls and streams audio to callees.

      ## Usage

          # Make a call
          <%= @module %>.dial("sip:service@127.0.0.1:5060")

          # List active calls
          <%= @module %>.calls()

          # Hang up a call
          <%= @module %>.hangup("call_id")
      \"\"\"

      @doc \"\"\"
      Make an outbound call to the given SIP URI.
      \"\"\"
      defdelegate dial(uri), to: <%= @module %>.Client

      @doc \"\"\"
      Hang up an active call by ID.
      \"\"\"
      defdelegate hangup(call_id), to: <%= @module %>.Client

      @doc \"\"\"
      List all active calls.
      \"\"\"
      defdelegate calls(), to: <%= @module %>.Client
    end
    """
  end

  defp application_template do
    """
    defmodule <%= @module %>.Application do
      @moduledoc false

      use Application
      require Logger

      @impl true
      def start(_type, _args) do
        port = Application.get_env(:<%= @app %>, :port, <%= @port %>)
        input_device_id = Application.get_env(:<%= @app %>, :input_device_id)
        output_device_id = Application.get_env(:<%= @app %>, :output_device_id)
        audio_file = Application.get_env(:<%= @app %>, :audio_file, default_audio())

        Logger.info("Starting <%= @module %> on port \#{port}")

        children = [
          {<%= @module %>.Client,
            port: port,
            input_device_id: input_device_id,
            output_device_id: output_device_id,
            audio_file: audio_file}
        ]

        opts = [strategy: :one_for_one, name: <%= @module %>.Supervisor]
        Supervisor.start_link(children, opts)
      end

      defp default_audio do
        Path.join(:code.priv_dir(:parrot_media), "audio/parrot-welcome.wav")
      end
    end
    """
  end

  defp client_template do
    """
    defmodule <%= @module %>.Client do
      @moduledoc \"\"\"
      UAC client that makes outbound SIP calls.
      \"\"\"

      use GenServer
      require Logger

      alias ParrotSip.{UA, Stack}
      alias ParrotMedia.MediaSession

      # ==========================================================================
      # Configuration - modify these for your environment
      # ==========================================================================

      # Listen address - used for SDP generation and transport binding
      # Use {127, 0, 0, 1} for local dev, your actual IP for production
      @listen_addr {127, 0, 0, 1}

      # Transport protocol: :udp | :tcp | :tls
      @transport :udp

      # ==========================================================================

      defstruct [:ua, :stack, :port, :audio_file, :input_device_id, :output_device_id, :calls]

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def dial(uri) do
        GenServer.call(__MODULE__, {:dial, uri})
      end

      def hangup(call_id) do
        GenServer.call(__MODULE__, {:hangup, call_id})
      end

      def calls do
        GenServer.call(__MODULE__, :get_calls)
      end

      @impl true
      def init(opts) do
        port = Keyword.get(opts, :port, <%= @port %>)
        audio_file = Keyword.get(opts, :audio_file)
        input_device_id = Keyword.get(opts, :input_device_id)
        output_device_id = Keyword.get(opts, :output_device_id)

        Logger.info("<%= @module %>.Client starting on port \#{port}")

        # Start UA with handler
        {:ok, ua} = UA.start_link(<%= @module %>.Handler, {self(), audio_file}, port: port)
        Logger.info("UA started: \#{inspect(ua)}")

        # Start SIP stack (handles transport + routing automatically)
        handler = UA.get_handler(ua)
        {:ok, stack} = Stack.start_link(
          handler: handler,
          transport: @transport,
          ip: @listen_addr,
          port: port
        )

        actual_port = Stack.get_port(stack)
        Logger.info("SIP stack started on port \#{actual_port}")

        state = %__MODULE__{
          ua: ua,
          stack: stack,
          port: actual_port,
          audio_file: audio_file,
          input_device_id: input_device_id,
          output_device_id: output_device_id,
          calls: %{}
        }

        {:ok, state}
      end

      @impl true
      def handle_call({:dial, uri}, _from, state) do
        Logger.info("Dialing: \#{uri}")

        # Generate a unique session ID
        session_id = "media_\#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

        # Create MediaSession first (for UAC, we generate the offer)
        # PortAudio mode (default) - use system mic/speaker for real calls
        {:ok, media_session} = MediaSession.start_link(
          id: session_id,
          dialog_id: session_id,  # Will be updated when we have real dialog_id
          role: :uac,
          media_handler: <%= @module %>.MediaHandler,
          handler_args: %{},
          supported_codecs: [:pcma, :pcmu],
          audio_source: :device,
          audio_sink: :device,
          input_device_id: state.input_device_id,
          output_device_id: state.output_device_id
        )

        # Alternative: Audio file mode - uncomment below and comment out PortAudio block above
        # {:ok, media_session} = MediaSession.start_link(
        #   id: session_id,
        #   dialog_id: session_id,
        #   role: :uac,
        #   media_handler: <%= @module %>.MediaHandler,
        #   handler_args: %{},
        #   supported_codecs: [:pcma, :pcmu],
        #   audio_file: state.audio_file
        # )

        # Generate SDP offer via MediaSession (transitions to :negotiating state)
        {:ok, sdp} = MediaSession.generate_offer(media_session)

        result = UA.dial(state.ua, uri, sdp: sdp)
        handle_dial_result(result, media_session, state)
      end

      defp handle_dial_result({:ok, entity}, media_session, %{calls: calls} = state) do
        call_info = %{
          entity: entity,
          media_session: media_session,
          started_at: DateTime.utc_now()
        }
        {:reply, {:ok, entity.id}, %{state | calls: Map.put(calls, entity.id, call_info)}}
      end

      defp handle_dial_result(error, media_session, state) do
        MediaSession.terminate_session(media_session)
        {:reply, error, state}
      end

      def handle_call({:hangup, call_id}, _from, %{calls: calls} = state) do
        do_hangup(call_id, Map.get(calls, call_id), state)
      end

      defp do_hangup(_call_id, nil, state) do
        {:reply, {:error, :not_found}, state}
      end

      defp do_hangup(call_id, %{entity: entity}, %{ua: ua, calls: calls} = state) do
        UA.hangup(ua, entity)
        {:reply, :ok, %{state | calls: Map.delete(calls, call_id)}}
      end

      def handle_call(:get_calls, _from, state) do
        {:reply, state.calls, state}
      end

      @impl true
      def handle_cast({:call_answered, entity, remote_sdp}, %{calls: calls} = state) do
        Logger.info("Call answered: \#{entity.id}")
        do_call_answered(Map.get(calls, entity.id), remote_sdp, state)
      end

      defp do_call_answered(nil, _remote_sdp, state) do
        {:noreply, state}
      end

      defp do_call_answered(%{media_session: media_session}, remote_sdp, state) do
        # Process the answer (MediaSession is already in :negotiating state)
        process_answer_result(MediaSession.process_answer(media_session, remote_sdp), media_session, state)
      end

      defp process_answer_result(:ok, media_session, state) do
        MediaSession.start_media(media_session)
        {:noreply, state}
      end

      defp process_answer_result({:error, reason}, _media_session, state) do
        Logger.error("Failed to process answer: \#{inspect(reason)}")
        {:noreply, state}
      end

      @impl true
      def handle_cast({:call_ended, entity_id}, %{calls: calls} = state) do
        do_call_ended(entity_id, Map.get(calls, entity_id), state)
      end

      defp do_call_ended(_entity_id, nil, state) do
        {:noreply, state}
      end

      defp do_call_ended(entity_id, %{media_session: media_session}, %{calls: calls} = state) do
        MediaSession.terminate_session(media_session)
        {:noreply, %{state | calls: Map.delete(calls, entity_id)}}
      end

      defp do_call_ended(entity_id, %{}, %{calls: calls} = state) do
        # No media session to clean up
        {:noreply, %{state | calls: Map.delete(calls, entity_id)}}
      end

      @impl true
      def handle_info(msg, state) do
        Logger.debug("<%= @module %>.Client received: \#{inspect(msg)}")
        {:noreply, state}
      end

      @impl true
      def terminate(_reason, state) do
        Logger.info("<%= @module %>.Client terminating")
        stop_stack(state.stack)
        stop_ua(state.ua)
        :ok
      end

      defp stop_stack(nil), do: :ok
      defp stop_stack(stack), do: Stack.stop(stack)

      defp stop_ua(nil), do: :ok
      defp stop_ua(ua) do
        if Process.alive?(ua), do: GenServer.stop(ua), else: :ok
      end

    end
    """
  end

  defp handler_template do
    """
    defmodule <%= @module %>.Handler do
      @moduledoc \"\"\"
      UA Handler for outbound call events.
      \"\"\"

      use ParrotSip.UA.Handler
      require Logger

      defstruct [:client_pid, :audio_file]

      @impl true
      def init({client_pid, audio_file}) do
        Logger.info("<%= @module %>.Handler initialized")
        {:ok, %__MODULE__{client_pid: client_pid, audio_file: audio_file}}
      end

      @impl true
      def handle_incoming(_ua, _invite, _entity, state) do
        # UAC doesn't handle incoming calls
        {:ok, state}
      end

      @impl true
      def handle_ringing(_ua, _response, entity, state) do
        Logger.info("Call ringing: \#{entity.id}")
        {:ok, state}
      end

      @impl true
      def handle_answered(_ua, response, entity, state) do
        Logger.info("Call answered: \#{entity.id}")

        remote_sdp = response.body
        GenServer.cast(state.client_pid, {:call_answered, entity, remote_sdp})

        {:ok, state}
      end

      @impl true
      def handle_rejected(_ua, response, entity, state) do
        Logger.info("Call rejected: \#{entity.id}, status: \#{response.status_code}")
        GenServer.cast(state.client_pid, {:call_ended, entity.id})
        {:ok, state}
      end

      @impl true
      def handle_hangup(_ua, _message, entity, state) do
        Logger.info("Call ended: \#{entity.id}")
        GenServer.cast(state.client_pid, {:call_ended, entity.id})
        {:ok, state}
      end

      @impl true
      def handle_cancel(_ua, entity, state) do
        Logger.info("Call cancelled: \#{entity.id}")
        GenServer.cast(state.client_pid, {:call_ended, entity.id})
        {:ok, state}
      end
    end
    """
  end

  defp media_handler_template do
    """
    defmodule <%= @module %>.MediaHandler do
      @moduledoc \"\"\"
      Media handler for audio events.
      \"\"\"

      @behaviour ParrotMedia.Handler
      require Logger

      @impl true
      def init(args), do: {:ok, args}

      @impl true
      def handle_session_start(session_id, _opts, state) do
        Logger.info("Media session started: \#{session_id}")
        {:ok, state}
      end

      @impl true
      def handle_session_stop(session_id, reason, state) do
        Logger.info("Media session stopped: \#{session_id}, reason: \#{inspect(reason)}")
        {:ok, state}
      end

      @impl true
      def handle_offer(_sdp, _direction, state), do: {:noreply, state}

      @impl true
      def handle_answer(_sdp, _direction, state), do: {:noreply, state}

      @impl true
      def handle_codec_negotiation(offered, supported, state) do
        codec = Enum.find(offered, &(&1 in supported)) || hd(supported)
        {:ok, codec, state}
      end

      @impl true
      def handle_negotiation_complete(_local, _remote, codec, state) do
        Logger.info("Codec negotiated: \#{codec}")
        {:ok, state}
      end

      @impl true
      def handle_stream_start(session_id, direction, state) do
        Logger.info("Stream started: \#{session_id}, direction: \#{direction}")
        {:noreply, state}
      end

      @impl true
      def handle_stream_stop(session_id, reason, state) do
        Logger.info("Stream stopped: \#{session_id}, reason: \#{inspect(reason)}")
        {:ok, state}
      end

      @impl true
      def handle_stream_error(session_id, error, state) do
        Logger.error("Stream error: \#{session_id}, error: \#{inspect(error)}")
        {:continue, state}
      end

      @impl true
      def handle_play_complete(file, state) do
        Logger.info("Playback complete: \#{file}")
        {:stop, state}
      end

      @impl true
      def handle_media_request(request, state) do
        Logger.debug("Media request: \#{inspect(request)}")
        {:noreply, state}
      end
    end
    """
  end

  defp test_template do
    """
    defmodule <%= @module %>Test do
      use ExUnit.Case

      test "module exists" do
        assert function_exported?(<%= @module %>, :dial, 1)
        assert function_exported?(<%= @module %>, :hangup, 1)
        assert function_exported?(<%= @module %>, :calls, 0)
      end
    end
    """
  end

  defp gitignore_template do
    """
    /_build/
    /cover/
    /deps/
    /doc/
    /.fetch
    erl_crash.dump
    *.ez
    *.tar
    /.elixir_ls/
    .DS_Store
    """
  end

  defp formatter_template do
    """
    [
      inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
    ]
    """
  end
end
