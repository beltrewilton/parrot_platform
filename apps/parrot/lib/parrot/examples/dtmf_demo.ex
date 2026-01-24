defmodule Parrot.Examples.DTMFDemo do
  @moduledoc """
  Example DTMF collection handler demonstrating various IVR patterns.

  This example shows how to build an interactive voice response system using
  the Parrot DSL with DTMF digit collection.

  ## Features Demonstrated

  - Basic `collect_dtmf/2` usage for collecting digits
  - `prompt/3` convenience function for play+collect
  - Multi-step IVR flow with state management via `assign/3`
  - `handle_dtmf/2` callback with pattern matching on call state
  - `handle_play_complete/2` callback for pending collect handling
  - `handle_media_started/1` callback for tracking call start time
  - `handle_media_stopped/2` callback for calculating call duration

  ## Running the Example

      # Start with the convenience function
      {:ok, stack} = Parrot.Examples.DTMFDemo.start(port: 15062)

  ## Testing with pjsua

      # Basic call - should hear welcome, press 1 for PIN entry
      pjsua --null-audio sip:dtmf-demo@127.0.0.1:15062

      # Once connected, use pjsua commands:
      # - Press digits on the dial pad to send DTMF
      # - Press 'h' to hang up

      # Alternative: Use linphone, Opal, or any standard SIP softphone

  ## IVR Flow

  1. Answer and play welcome message
  2. Collect single digit for menu selection
  3. Based on digit:
     - "1" - Prompt for 4-digit PIN (validates "1234")
     - "2" - Play option two message
     - Other - Play invalid option message
     - Timeout - Say goodbye and hang up
  """

  require Logger

  # ============================================================================
  # Handler - implements Parrot.InviteHandler behaviour
  # ============================================================================

  defmodule Handler do
    @moduledoc """
    IVR handler demonstrating DTMF collection patterns.

    Uses assigns to track state:
    - `:step` - Current IVR step (`:menu` or `:pin`)
    - `:media_started_at` - Monotonic timestamp when media started (for duration tracking)
    """
    use Parrot.InviteHandler

    require Logger

    @impl true
    def handle_invite(call) do
      Logger.info("[DTMFDemo] INVITE from #{inspect(call.from)}")

      call
      |> answer()
      |> assign(:step, :menu)
      |> play("priv/audio/parrot-welcome.wav")
    end

    @impl true
    def handle_play_complete(file, %{assigns: %{__pending_collect__: opts}} = call)
        when not is_nil(opts) do
      # Handle pending collect from prompt/3
      Logger.info("[DTMFDemo] Playback complete for #{file}, starting DTMF collection")

      call
      |> assign(:__pending_collect__, nil)
      |> collect_dtmf(opts)
    end

    def handle_play_complete("priv/audio/parrot-welcome.wav", %{assigns: %{step: :pin}} = call) do
      # PIN step - collect 4 digits
      Logger.info("[DTMFDemo] PIN prompt complete, collecting PIN")
      call |> collect_dtmf(max: 4, timeout: 10_000, terminators: ["#"])
    end

    def handle_play_complete("priv/audio/parrot-welcome.wav", call) do
      # Menu step (default) - collect 1 digit
      Logger.info("[DTMFDemo] Welcome playback complete, collecting menu selection")
      call |> collect_dtmf(max: 1, timeout: 5_000)
    end

    def handle_play_complete(file, call) do
      Logger.info("[DTMFDemo] Playback complete: #{file}")
      {:noreply, call}
    end

    @impl true
    def handle_dtmf(digit, %{assigns: %{step: :menu}} = call) when is_binary(digit) do
      Logger.info("[DTMFDemo] Menu selection: #{digit}")

      case digit do
        "1" ->
          call
          |> assign(:step, :pin)
          |> play("priv/audio/parrot-welcome.wav")

        "2" ->
          call |> play("priv/audio/parrot-welcome.wav")

        _ ->
          call |> play("priv/audio/parrot-welcome.wav")
      end
    end

    def handle_dtmf(pin, %{assigns: %{step: :pin}} = call) when is_binary(pin) do
      Logger.info("[DTMFDemo] PIN entered: #{pin}")

      if pin == "1234" do
        Logger.info("[DTMFDemo] PIN correct! Authorized.")
        call |> play("priv/audio/parrot-welcome.wav")
      else
        Logger.info("[DTMFDemo] PIN incorrect: #{pin}")
        call |> play("priv/audio/parrot-welcome.wav")
      end
    end

    def handle_dtmf(:timeout, %{assigns: %{step: step}} = call) do
      Logger.info("[DTMFDemo] DTMF timeout in step: #{step}, hanging up")
      call |> hangup()
    end

    def handle_dtmf(digits, call) do
      Logger.info("[DTMFDemo] Unhandled DTMF: #{inspect(digits)}")
      {:noreply, call}
    end

    @impl true
    def handle_hangup(call) do
      Logger.info("[DTMFDemo] Call ended")
      {:noreply, call}
    end

    # -------------------------------------------------------------------------
    # Media Lifecycle Callbacks
    # -------------------------------------------------------------------------

    @impl true
    def handle_media_started(call) do
      # Record when media started for duration tracking
      start_time = System.monotonic_time(:millisecond)
      Logger.info("[DTMFDemo] Media started, recording start time")

      # Store in assigns for later duration calculation
      {:noreply, %{call | assigns: Map.put(call.assigns, :media_started_at, start_time)}}
    end

    @impl true
    def handle_media_stopped(reason, call) do
      # Calculate and log call duration if we have a start time
      case Map.get(call.assigns, :media_started_at) do
        nil ->
          Logger.info("[DTMFDemo] Media stopped (reason: #{inspect(reason)}), no start time recorded")

        start_time ->
          end_time = System.monotonic_time(:millisecond)
          duration_ms = end_time - start_time
          duration_sec = Float.round(duration_ms / 1000, 2)

          Logger.info(
            "[DTMFDemo] Media stopped (reason: #{inspect(reason)}), " <>
              "call duration: #{duration_sec}s (#{duration_ms}ms)"
          )
      end

      {:noreply, call}
    end
  end

  # ============================================================================
  # Router - routes INVITEs to the Handler
  # ============================================================================

  defmodule Router do
    @moduledoc """
    Router for DTMFDemo that routes DTMF demo calls to the handler.
    """
    use Parrot.Router

    # Route INVITE requests to our DTMF demo handler
    invite("dtmf-demo@*", Parrot.Examples.DTMFDemo.Handler)
    invite("*", Parrot.Examples.DTMFDemo.Handler)
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the DTMF demo server on the specified port.

  ## Options

    - `:port` - UDP port to listen on (default: 15062)

  ## Returns

    - `{:ok, stack}` - Stack PID with server details
    - `{:error, reason}` - Startup failed

  ## Examples

      {:ok, stack} = Parrot.Examples.DTMFDemo.start(port: 15062)
      # Server is now listening on port 15062

      # To stop the server:
      Parrot.Examples.DTMFDemo.stop(stack)
  """
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, 15062)

    # Create handler using Bridge.Handler with our router
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: Router})

    # Start the SIP stack using the production-ready ParrotSip.Stack
    case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: port) do
      {:ok, stack} ->
        actual_port = ParrotSip.Stack.get_port(stack)
        Logger.info("[DTMFDemo] Started on port #{actual_port}")
        {:ok, stack}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops the DTMF demo server.

  ## Examples

      {:ok, stack} = Parrot.Examples.DTMFDemo.start()
      :ok = Parrot.Examples.DTMFDemo.stop(stack)
  """
  def stop(stack) do
    ParrotSip.Stack.stop(stack)
  end
end
