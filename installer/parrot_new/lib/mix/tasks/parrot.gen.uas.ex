defmodule Mix.Tasks.Parrot.Gen.Uas do
  @shortdoc "Generates a new Parrot UAS (User Agent Server) application"
  @moduledoc """
  Generates a new Parrot UAS application from a template.

  ## Usage

      mix parrot.gen.uas APP_NAME [OPTIONS]

  ## Examples

      mix parrot.gen.uas my_uas_app
      mix parrot.gen.uas my_uas_app --port 5080
      mix parrot.gen.uas my_uas_app --module MyCompany.UasApp

  ## Options

    * `--port` - The SIP port to listen on (default: 5060)
    * `--module` - The module name to use (default: derived from app name)

  The generator creates:

    * A complete UAS application using ParrotSip.UA.Handler
    * ParrotMedia.Handler implementation for audio playback
    * Transport setup with SIP stack wiring
    * README with usage instructions

  The generated application will:

    * Answer incoming SIP calls
    * Negotiate SDP and play audio to callers
    * Handle BYE/CANCEL gracefully
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
    port = opts[:port] || 5060
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
    create_file(Path.join(path, "lib/#{app}/server.ex"), EEx.eval_string(server_template(), assigns: binding))
    create_file(Path.join(path, "lib/#{app}/handler.ex"), EEx.eval_string(handler_template(), assigns: binding))
    create_file(Path.join(path, "lib/#{app}/media_handler.ex"), EEx.eval_string(media_handler_template(), assigns: binding))
    create_file(Path.join(path, "test/#{app}_test.exs"), EEx.eval_string(test_template(), assigns: binding))
    create_file(Path.join(path, ".gitignore"), gitignore_template())
    create_file(Path.join(path, ".formatter.exs"), formatter_template())

    Mix.shell().info("""

    Your Parrot UAS application has been generated!

    To get started:

        cd #{app_name}
        mix deps.get
        iex -S mix

    Your SIP endpoint will be available at:
        sip:service@<your-ip>:#{port}

    Test with a SIP client or SIPp:
        sipp -sn uac 127.0.0.1:#{port} -m 1

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
      audio_file: System.get_env("AUDIO_FILE")

    config :logger, :console,
      format: "$time $metadata[$level] $message\\n",
      metadata: [:file, :line]
    """
  end

  defp readme_template do
    """
    # <%= @module %> - Parrot UAS Application

    A SIP User Agent Server (UAS) application built with Parrot Platform.

    ## Overview

    This application:
    - Listens for incoming SIP INVITE requests
    - Answers calls with SDP negotiation
    - Plays audio to callers using ParrotMedia
    - Handles BYE/CANCEL gracefully

    ## Running the Application

    ```bash
    # Start the application
    iex -S mix

    # Or on a specific port
    PORT=5080 iex -S mix
    ```

    ## Testing

    Use any SIP client (Twinkle, Linphone, Zoiper) or SIPp:

    ```bash
    # Test with SIPp
    sipp -sn uac 127.0.0.1:<%= @port %> -m 1
    ```

    ## Configuration

    Environment variables:
    - `PORT` - SIP listening port (default: <%= @port %>)
    - `AUDIO_FILE` - Path to WAV file to play (default: parrot-welcome.wav)

    ## Architecture

    - `<%= @module %>.Server` - Main GenServer managing UA and transport
    - `<%= @module %>.Handler` - ParrotSip.UA.Handler for SIP events
    - `<%= @module %>.MediaHandler` - ParrotMedia.Handler for media events
    """
  end

  defp main_module_template do
    """
    defmodule <%= @module %> do
      @moduledoc \"\"\"
      <%= @module %> - A SIP User Agent Server (UAS) application.

      This UAS answers incoming calls and plays audio to callers.

      ## Usage

          # The application starts automatically via Application callback
          # To check active calls:
          <%= @module %>.calls()
      \"\"\"

      @doc \"\"\"
      Returns the current active calls.
      \"\"\"
      def calls do
        <%= @module %>.Server.get_calls()
      end
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
          {<%= @module %>.Server, port: port, audio_file: audio_file}
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

  defp server_template do
    """
    defmodule <%= @module %>.Server do
      @moduledoc \"\"\"
      Main server that manages the UA and transport.
      \"\"\"

      use GenServer
      require Logger

      alias ParrotSip.{UA, Stack}

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

      def get_calls do
        GenServer.call(__MODULE__, :get_calls)
      end

      @impl true
      def init(opts) do
        port = Keyword.get(opts, :port, <%= @port %>)
        audio_file = Keyword.get(opts, :audio_file)

        Logger.info("<%= @module %>.Server starting on port \#{port}")

        # Start UA with handler
        {:ok, ua} = UA.start_link(<%= @module %>.Handler, {self(), audio_file}, port: port)

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
      def handle_call(:get_calls, _from, state) do
        {:reply, state.calls, state}
      end

      @impl true
      def handle_cast({:call_started, entity, media_session}, state) do
        call_info = %{entity: entity, media_session: media_session, started_at: DateTime.utc_now()}
        {:noreply, %{state | calls: Map.put(state.calls, entity.id, call_info)}}
      end

      @impl true
      def handle_cast({:call_ended, entity_id}, state) do
        {:noreply, %{state | calls: Map.delete(state.calls, entity_id)}}
      end

      @impl true
      def handle_info(msg, state) do
        Logger.debug("<%= @module %>.Server received: \#{inspect(msg)}")
        {:noreply, state}
      end

      @impl true
      def terminate(_reason, state) do
        if state.stack, do: Stack.stop(state.stack)
        if state.ua && Process.alive?(state.ua), do: GenServer.stop(state.ua)
        :ok
      end
    end
    """
  end

  defp handler_template do
    """
    defmodule <%= @module %>.Handler do
      @moduledoc \"\"\"
      UA Handler for SIP events.
      \"\"\"

      use ParrotSip.UA.Handler
      require Logger

      alias ParrotSip.UA
      alias ParrotMedia.MediaSession

      defstruct [:server_pid, :audio_file, :media_sessions]

      @impl true
      def init({server_pid, audio_file}) do
        {:ok, %__MODULE__{server_pid: server_pid, audio_file: audio_file, media_sessions: %{}}}
      end

      @impl true
      def handle_incoming(ua, invite, entity, state) do
        Logger.info("Incoming call from: \#{entity.remote_uri}")

        session_id = "media_\#{entity.id}"

        case start_media_session(session_id, entity, invite.body, state) do
          {:ok, media_session, local_sdp} ->
            UA.answer(ua, entity, sdp: local_sdp)
            MediaSession.start_media(media_session)
            media_sessions = Map.put(state.media_sessions, entity.id, media_session)
            GenServer.cast(state.server_pid, {:call_started, entity, media_session})
            {:ok, %{state | media_sessions: media_sessions}}

          {:error, reason} ->
            Logger.error("Failed to create media session: \#{inspect(reason)}")
            UA.reject(ua, entity, 503, "Service Unavailable")
            {:ok, state}
        end
      end

      @impl true
      def handle_answered(_ua, _response, _entity, state) do
        # Not used for UAS - we are the one sending the answer
        {:ok, state}
      end

      @impl true
      def handle_hangup(_ua, _message, entity, state) do
        Logger.info("Call ended: \#{entity.call_id}")
        cleanup_media(entity.id, state)
        GenServer.cast(state.server_pid, {:call_ended, entity.id})
        {:ok, %{state | media_sessions: Map.delete(state.media_sessions, entity.id)}}
      end

      @impl true
      def handle_cancel(_ua, entity, state) do
        Logger.info("Call cancelled: \#{entity.call_id}")
        cleanup_media(entity.id, state)
        GenServer.cast(state.server_pid, {:call_ended, entity.id})
        {:ok, %{state | media_sessions: Map.delete(state.media_sessions, entity.id)}}
      end

      defp start_media_session(session_id, entity, remote_sdp, state) do
        {:ok, media_session} = MediaSession.start_link(
          id: session_id,
          dialog_id: entity.call_id,
          role: :uas,
          media_handler: <%= @module %>.MediaHandler,
          handler_args: %{entity_id: entity.id},
          supported_codecs: [:pcma, :pcmu],
          audio_file: state.audio_file
        )

        case MediaSession.process_offer(media_session, remote_sdp) do
          {:ok, local_sdp} -> {:ok, media_session, local_sdp}
          {:error, reason} ->
            MediaSession.terminate_session(media_session)
            {:error, reason}
        end
      end

      defp cleanup_media(entity_id, state) do
        case Map.get(state.media_sessions, entity_id) do
          nil -> :ok
          session -> MediaSession.terminate_session(session)
        end
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
        {{:play, file}, state}  # Loop the audio
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
