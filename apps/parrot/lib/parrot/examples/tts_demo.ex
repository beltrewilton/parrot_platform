defmodule Parrot.Examples.TTSDemo do
  @moduledoc """
  TTS (Text-to-Speech) demonstration handler showcasing Parrot DSL TTS features.

  This example demonstrates how to use text-to-speech capabilities in the Parrot
  VoIP platform. It covers basic synthesis, DTMF collection with TTS prompts,
  profile switching, and error handling.

  ## Quick Start

      # 1. Configure TTS (see Configuration section below)
      # 2. Start the server
      {:ok, stack} = Parrot.Examples.TTSDemo.start(port: 15062)

      # 3. Call in to hear TTS
      gophone dial sip:demo@127.0.0.1:15062

      # 4. Stop when done
      Parrot.Examples.TTSDemo.stop(stack)

  ## Configuration

  TTS requires configuration in your application config. Here's a complete example:

      # config/config.exs or config/runtime.exs
      config :parrot, :tts,
        # Default profile used when no profile is specified
        default_profile: :standard,

        # Define TTS profiles for different use cases
        profiles: [
          standard: [
            provider: :openai,
            voice: "alloy",
            format: :mp3
          ],
          announcements: [
            provider: :openai,
            voice: "nova",
            format: :mp3
          ],
          prompts: [
            provider: :google,
            voice: "en-US-Neural2-F",
            language: "en-US"
          ],
          spanish: [
            provider: :google,
            voice: "es-ES-Neural2-A",
            language: "es-ES"
          ]
        ],

        # Provider credentials (use environment variables for production)
        credentials: [
          openai: [api_key: {:system, "OPENAI_API_KEY"}],
          google: [api_key: {:system, "GOOGLE_TTS_API_KEY"}],
          azure: [
            api_key: {:system, "AZURE_TTS_API_KEY"},
            region: "eastus"
          ]
        ],

        # Optional: Cache settings
        cache_dir: "priv/tts_cache",
        cache_ttl: :timer.hours(24)

  For testing without a real TTS provider, use the mock provider:

      config :parrot, :tts,
        default_profile: :mock,
        profiles: [
          mock: [
            provider: Parrot.Examples.CustomTTSProvider,
            voice: "alice",
            format: :wav,
            api_key: "test-key"
          ]
        ]

  ## Testing

      # Basic call - hear TTS greeting and menu
      gophone dial sip:demo@127.0.0.1:15062

      # With DTMF input
      gophone dial -dtmf=1 -dtmf_delay=2s sip:demo@127.0.0.1:15062
      gophone dial -dtmf=2 -dtmf_delay=2s sip:demo@127.0.0.1:15062

  ## Features Demonstrated

  ### 1. Basic `say/2` Usage

  The simplest TTS operation - synthesize and play text with default profile:

      call |> say("Hello, welcome to the TTS demo.")

  ### 2. `say/3` with Profile Option

  Use a named TTS profile configured in application config:

      call |> say("Important announcement", profile: :announcements)

  ### 3. `say/3` with Voice/Engine/Language Options

  Specify TTS parameters directly (overrides profile settings):

      # Specify voice directly
      call |> say("Hello", voice: "en-US-Neural2-F")

      # Specify language and engine
      call |> say("Bonjour", language: "fr-FR", engine: :google)

      # Combine multiple options
      call |> say("Hola, bienvenido",
        engine: :azure,
        voice: "es-MX-DaliaNeural",
        language: "es-MX"
      )

  ### 4. `say_prompt/3` for TTS with DTMF Collection

  Combines TTS synthesis with DTMF collection - speak a prompt then collect digits:

      call |> say_prompt("Please enter your PIN followed by pound.",
        max: 4,
        timeout: 10_000,
        terminators: ["#"]
      )

  The collected digits are received in `handle_dtmf/2`.

  You can also combine TTS options with DTMF collection options:

      call |> say_prompt("Por favor ingrese su PIN.",
        profile: :spanish,
        max: 4,
        timeout: 15_000,
        terminators: ["#"]
      )

  ### 5. Error Handling via `handle_tts_error/3`

  Override this callback to handle synthesis failures gracefully:

      @impl true
      def handle_tts_error(text, error, call) do
        Logger.error("TTS failed for: \#{text}, error: \#{inspect(error)}")

        # Options for handling TTS errors:
        # 1. Play fallback audio
        call |> play("priv/audio/tts-unavailable.wav")

        # 2. Track errors and hang up after multiple failures
        # error_count = Map.get(call.assigns, :tts_errors, 0) + 1
        # if error_count >= 3 do
        #   call |> hangup()
        # else
        #   {:noreply, %{call | assigns: Map.put(call.assigns, :tts_errors, error_count)}}
        # end

        # 3. Simply continue without playing anything
        # {:noreply, call}
      end

  ## Architecture

  The module is organized into three components:

  - `Handler` - Implements `Parrot.InviteHandler` with TTS operations
  - `Router` - Uses `Parrot.Router` to route INVITEs to the Handler
  - `start/1` and `stop/1` - Convenience functions to manage the SIP stack

  ## TTS Options Reference

  | Option     | Type    | Description                                    |
  |------------|---------|------------------------------------------------|
  | `:profile` | atom    | Named TTS profile from config                  |
  | `:voice`   | string  | Voice identifier (e.g., "alloy", "nova")       |
  | `:engine`  | atom    | TTS engine (`:openai`, `:google`, `:azure`)    |
  | `:language`| string  | Language/locale code (e.g., "en-US", "fr-FR")  |

  ## DTMF Collection Options (for `say_prompt/3`)

  | Option        | Type    | Default | Description                        |
  |---------------|---------|---------|-------------------------------------|
  | `:max`        | integer | 20      | Maximum digits to collect           |
  | `:timeout`    | integer | 30_000  | Collection timeout in milliseconds  |
  | `:terminators`| list    | []      | Digits that end collection early    |

  ## See Also

  - `Parrot.InviteHandler` - Full behaviour documentation
  - `Parrot.Call` - Pipeline operations reference
  - `Parrot.TTS.Provider` - Custom TTS provider implementation
  - `Parrot.Examples.CustomTTSProvider` - Example custom TTS provider
  - `Parrot.Examples.SimpleIVR` - Basic IVR without TTS
  """

  require Logger

  # ============================================================================
  # Handler - TTS-based call handling
  # ============================================================================

  defmodule Handler do
    @moduledoc """
    TTS demo handler that demonstrates text-to-speech features.

    Shows:
    - Basic `say/2` for default TTS playback
    - `say/3` with profile, voice, engine, and language options
    - `say_prompt/3` for TTS with DTMF collection
    - Error handling with `handle_tts_error/3`
    - Retry patterns for timeout handling
    """
    use Parrot.InviteHandler

    require Logger

    # -------------------------------------------------------------------------
    # Main Entry Point
    # -------------------------------------------------------------------------

    @impl true
    def handle_invite(call) do
      Logger.info("[TTSDemo] INVITE from #{inspect(call.from)}")
      Logger.info("[TTSDemo] Answering call with TTS greeting...")

      call
      |> answer()
      # 1. Basic say/2 - synthesize and play with default profile
      |> say("Hello, welcome to the Parrot text to speech demo.")
      # 2. say/3 with profile option - use a named TTS profile
      |> say("This message uses the announcements profile.", profile: :announcements)
      # 3. say_prompt/3 for DTMF collection after TTS
      |> say_prompt(
        "Please press 1 for sales, 2 for support, 3 for Spanish demo, or 4 to hear this menu again.",
        max: 1,
        timeout: 15_000
      )
    end

    # -------------------------------------------------------------------------
    # DTMF Handlers - Demonstrating Various say/3 Options
    # -------------------------------------------------------------------------

    @impl true
    def handle_dtmf("1", call) do
      Logger.info("[TTSDemo] User pressed 1 - Sales (demonstrating voice option)")

      call
      # Demonstrate say/3 with :voice option
      |> say("Connecting you to the sales department.",
        voice: "nova"
      )
      |> say("Our sales team is ready to help you.", voice: "alloy")
      |> say("Thank you for your interest. Goodbye.")
      |> hangup()
    end

    @impl true
    def handle_dtmf("2", call) do
      Logger.info("[TTSDemo] User pressed 2 - Support (demonstrating engine/language options)")

      call
      # Demonstrate say/3 with :engine and :language options
      |> say("Connecting you to technical support.",
        engine: :openai,
        language: "en-US"
      )
      |> say("A representative will be with you shortly.")
      |> say("Goodbye and thank you for calling.")
      |> hangup()
    end

    @impl true
    def handle_dtmf("3", call) do
      Logger.info("[TTSDemo] User pressed 3 - Spanish demo (demonstrating profile switching)")

      call
      # Demonstrate say/3 with :profile for language switching
      |> say("Switching to Spanish.", profile: :standard)
      |> say("Gracias por llamar. Bienvenido a la demo de texto a voz.", profile: :spanish)
      # Demonstrate say_prompt/3 with combined TTS and DTMF options
      |> say_prompt(
        "Presione uno para continuar en espanol, o cualquier otra tecla para volver al menu principal.",
        profile: :spanish,
        max: 1,
        timeout: 10_000
      )
    end

    @impl true
    def handle_dtmf("4", call) do
      Logger.info("[TTSDemo] User pressed 4 - Replay menu")

      # Replay the menu using say_prompt
      call
      |> say_prompt(
        "Please press 1 for sales, 2 for support, 3 for Spanish demo, or 4 to hear this menu again.",
        max: 1,
        timeout: 15_000
      )
    end

    @impl true
    def handle_dtmf(:timeout, call) do
      Logger.info("[TTSDemo] DTMF timeout - no input received")

      # Track retry count for graceful timeout handling
      retries = Map.get(call.assigns, :menu_retries, 0)

      if retries >= 2 do
        call
        |> say("We did not receive any input after multiple attempts. Goodbye.")
        |> hangup()
      else
        call
        |> assign(:menu_retries, retries + 1)
        |> say("We did not receive any input. Let's try again.")
        |> say_prompt(
          "Please press 1 for sales, 2 for support, 3 for Spanish demo, or 4 to hear this menu again.",
          max: 1,
          timeout: 15_000
        )
      end
    end

    @impl true
    def handle_dtmf(digit, call) do
      Logger.info("[TTSDemo] Invalid input: #{digit}")

      call
      |> say("Sorry, #{digit} is not a valid option.")
      |> say_prompt(
        "Please press 1 for sales, 2 for support, 3 for Spanish demo, or 4 to hear this menu again.",
        max: 1,
        timeout: 10_000
      )
    end

    # -------------------------------------------------------------------------
    # Playback Complete Handler - Required for say_prompt to work
    # -------------------------------------------------------------------------

    @impl true
    def handle_play_complete(_file, %{assigns: %{__pending_collect__: opts}} = call)
        when not is_nil(opts) do
      # IMPORTANT: This pattern is required for say_prompt/3 to work correctly.
      # After TTS playback completes, we start DTMF collection.
      Logger.debug("[TTSDemo] TTS playback complete, starting DTMF collection")

      call
      |> assign(:__pending_collect__, nil)
      |> collect_dtmf(opts)
    end

    @impl true
    def handle_play_complete(_file, call) do
      {:noreply, call}
    end

    # -------------------------------------------------------------------------
    # Hangup Handler
    # -------------------------------------------------------------------------

    @impl true
    def handle_hangup(call) do
      Logger.info("[TTSDemo] Call ended")
      {:noreply, call}
    end

    # -------------------------------------------------------------------------
    # TTS Error Handler - Custom error handling for synthesis failures
    # -------------------------------------------------------------------------

    @impl true
    def handle_tts_error(text, error, call) do
      # Log the error with full details for debugging
      Logger.error("[TTSDemo] TTS synthesis failed")
      Logger.error("[TTSDemo]   Text: #{inspect(text)}")
      Logger.error("[TTSDemo]   Error: #{inspect(error)}")

      # Track error count for escalation
      error_count = Map.get(call.assigns, :tts_errors, 0) + 1

      if error_count >= 3 do
        # Too many TTS failures - gracefully end the call
        Logger.error("[TTSDemo] Too many TTS errors (#{error_count}), ending call")

        call
        |> assign(:tts_errors, error_count)
        |> play("priv/audio/error.wav")
        |> hangup()
      else
        # Continue with fallback audio, don't crash the call
        Logger.warning("[TTSDemo] TTS error #{error_count}/3, using fallback audio")

        call
        |> assign(:tts_errors, error_count)
        |> play("priv/audio/tts-fallback.wav")
      end
    end
  end

  # ============================================================================
  # Router - Routes INVITEs to Handler
  # ============================================================================

  defmodule Router do
    @moduledoc """
    Router that routes all INVITEs to the TTSDemo Handler.
    """
    use Parrot.Router

    # Route all INVITE requests to our handler
    invite("*", Parrot.Examples.TTSDemo.Handler)
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the TTSDemo server using the Parrot DSL stack.

  ## Options

    - `:port` - UDP port to listen on (default: 15062)

  ## Returns

    - `{:ok, stack}` - Stack struct with listener info
    - `{:error, reason}` - Startup failed

  ## Examples

      # Start on default port
      {:ok, stack} = Parrot.Examples.TTSDemo.start()

      # Start on a specific port
      {:ok, stack} = Parrot.Examples.TTSDemo.start(port: 15062)

      # Stop when done
      Parrot.Examples.TTSDemo.stop(stack)

  ## Prerequisites

  Before starting, ensure TTS is configured in your application config.
  See the module documentation for full configuration examples.

  Minimal test configuration using the mock provider:

      config :parrot, :tts,
        default_profile: :mock,
        profiles: [
          mock: [
            provider: Parrot.Examples.CustomTTSProvider,
            voice: "alice",
            format: :wav,
            api_key: "test-key"
          ]
        ]

  """
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, 15062)

    # Create a ParrotSip.Handler that uses Bridge.Handler with our DSL router
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: Router})

    # Start the SIP stack
    case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: port) do
      {:ok, stack} ->
        actual_port = ParrotSip.Stack.get_port(stack)
        Logger.info("[TTSDemo] Started on port #{actual_port}")
        {:ok, stack}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops the TTSDemo server.

  ## Examples

      {:ok, stack} = Parrot.Examples.TTSDemo.start()
      :ok = Parrot.Examples.TTSDemo.stop(stack)

  """
  def stop(stack) do
    ParrotSip.Stack.stop(stack)
  end
end
