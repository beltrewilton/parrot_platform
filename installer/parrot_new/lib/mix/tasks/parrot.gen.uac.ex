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

  ## Options

    * `--port` - The local SIP port to bind (default: 5070)
    * `--module` - The module name to use (default: derived from app name)

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
    module: :string
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

    binding = [
      app: app,
      module: module,
      port: port
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
    """
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
        [
          {:parrot_sip, "~> 0.0.1"},
          {:parrot_transport, "~> 0.0.1"},
          {:parrot_media, "~> 0.0.1"}
        ]
      end
    end
    """
  end

  defp config_template do
    """
    import Config

    config :<%= @app %>,
      port: String.to_integer(System.get_env("PORT") || "<%= @port %>"),
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
    - Negotiates SDP and streams audio
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

    ## Configuration

    Environment variables:
    - `PORT` - Local SIP port to bind (default: <%= @port %>)
    - `AUDIO_FILE` - Path to WAV file to stream (default: parrot-welcome.wav)

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
        audio_file = Application.get_env(:<%= @app %>, :audio_file, default_audio())

        Logger.info("Starting <%= @module %> on port \#{port}")

        children = [
          {<%= @module %>.Client, port: port, audio_file: audio_file}
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

      alias ParrotSip.{UA, Stack, SDP}

      # ==========================================================================
      # Configuration - modify these for your environment
      # ==========================================================================

      # Listen address - used for SDP generation and transport binding
      # Use {127, 0, 0, 1} for local dev, your actual IP for production
      @listen_addr {127, 0, 0, 1}

      # Transport protocol: :udp | :tcp | :tls
      @transport :udp

      # ==========================================================================

      defstruct [:ua, :stack, :port, :audio_file, :calls]

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
          calls: %{}
        }

        {:ok, state}
      end

      @impl true
      def handle_call({:dial, uri}, _from, state) do
        Logger.info("Dialing: \#{uri}")

        # Generate random RTP port for media
        local_port = Enum.random(20000..30000)

        # Build SDP offer using helper
        sdp = SDP.audio_offer(
          host: @listen_addr,
          port: local_port,
          codecs: [:pcma, :pcmu],
          session_name: "<%= @module %>"
        )

        case UA.dial(state.ua, uri, sdp: sdp) do
          {:ok, entity} ->
            call_info = %{
              entity: entity,
              local_port: local_port,
              started_at: DateTime.utc_now()
            }

            calls = Map.put(state.calls, entity.id, call_info)
            {:reply, {:ok, entity.id}, %{state | calls: calls}}

          error ->
            {:reply, error, state}
        end
      end

      def handle_call({:hangup, call_id}, _from, state) do
        case Map.get(state.calls, call_id) do
          nil ->
            {:reply, {:error, :not_found}, state}

          call_info ->
            UA.hangup(state.ua, call_info.entity)
            calls = Map.delete(state.calls, call_id)
            {:reply, :ok, %{state | calls: calls}}
        end
      end

      def handle_call(:get_calls, _from, state) do
        {:reply, state.calls, state}
      end

      @impl true
      def handle_cast({:call_answered, entity, remote_sdp}, state) do
        Logger.info("Call answered: \#{entity.id}")

        case Map.get(state.calls, entity.id) do
          nil ->
            {:noreply, state}

          call_info ->
            case start_media_session(call_info, remote_sdp, state) do
              {:ok, media_session} ->
                call_info = Map.put(call_info, :media_session, media_session)
                calls = Map.put(state.calls, entity.id, call_info)
                {:noreply, %{state | calls: calls}}

              {:error, reason} ->
                Logger.error("Failed to start media: \#{inspect(reason)}")
                {:noreply, state}
            end
        end
      end

      @impl true
      def handle_cast({:call_ended, entity_id}, state) do
        case Map.get(state.calls, entity_id) do
          nil ->
            {:noreply, state}

          call_info ->
            if call_info[:media_session] do
              ParrotMedia.MediaSession.terminate_session(call_info.media_session)
            end

            calls = Map.delete(state.calls, entity_id)
            {:noreply, %{state | calls: calls}}
        end
      end

      @impl true
      def handle_info(msg, state) do
        Logger.debug("<%= @module %>.Client received: \#{inspect(msg)}")
        {:noreply, state}
      end

      @impl true
      def terminate(_reason, state) do
        Logger.info("<%= @module %>.Client terminating")
        if state.stack, do: Stack.stop(state.stack)
        if state.ua && Process.alive?(state.ua), do: GenServer.stop(state.ua)
        :ok
      end

      defp start_media_session(call_info, remote_sdp, state) do
        session_id = "media_\#{call_info.entity.id}"

        {:ok, media_session} = ParrotMedia.MediaSession.start_link(
          id: session_id,
          dialog_id: call_info.entity.call_id,
          role: :uac,
          media_handler: <%= @module %>.MediaHandler,
          handler_args: %{entity_id: call_info.entity.id},
          supported_codecs: [:pcma, :pcmu],
          audio_file: state.audio_file
        )

        case ParrotMedia.MediaSession.process_answer(media_session, remote_sdp) do
          {:ok, _} ->
            ParrotMedia.MediaSession.start_media(media_session)
            {:ok, media_session}

          error ->
            ParrotMedia.MediaSession.terminate_session(media_session)
            error
        end
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
