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

  ## Running the Example

      # Start with the convenience function
      {:ok, stack} = Parrot.Examples.DTMFDemo.start(port: 15062)

  ## Testing

      # Basic call - should hear welcome, press 1 for PIN entry
      gophone dial sip:dtmf-demo@127.0.0.1:15062

      # With DTMF for menu selection
      gophone dial -dtmf=1 -dtmf_delay=3s sip:dtmf-demo@127.0.0.1:15062

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

    Uses assigns to track menu state:
    - `:step` - Current IVR step (`:menu` or `:pin`)
    """
    use Parrot.InviteHandler

    require Logger

    @impl true
    def handle_invite(call) do
      Logger.info("[DTMFDemo] INVITE from #{inspect(call.from)}")

      call
      |> answer()
      |> assign(:step, :menu)
      |> play("priv/audio/welcome.wav")
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

    def handle_play_complete("priv/audio/welcome.wav", call) do
      Logger.info("[DTMFDemo] Welcome playback complete, collecting menu selection")
      call |> collect_dtmf(max: 1, timeout: 5_000)
    end

    def handle_play_complete("priv/audio/enter-pin.wav", call) do
      Logger.info("[DTMFDemo] PIN prompt complete, collecting PIN")
      call |> collect_dtmf(max: 4, timeout: 10_000, terminators: ["#"])
    end

    def handle_play_complete("priv/audio/goodbye.wav", call) do
      Logger.info("[DTMFDemo] Goodbye playback complete")
      {:noreply, call}
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
          |> play("priv/audio/enter-pin.wav")

        "2" ->
          call |> play("priv/audio/option-two.wav")

        _ ->
          call |> play("priv/audio/invalid.wav")
      end
    end

    def handle_dtmf(pin, %{assigns: %{step: :pin}} = call) when is_binary(pin) do
      Logger.info("[DTMFDemo] PIN entered: #{pin}")

      if pin == "1234" do
        call |> play("priv/audio/welcome-authorized.wav")
      else
        call |> play("priv/audio/invalid-pin.wav")
      end
    end

    def handle_dtmf(:timeout, %{assigns: %{step: step}} = call) do
      Logger.info("[DTMFDemo] DTMF timeout in step: #{step}")

      call
      |> play("priv/audio/goodbye.wav")
      |> hangup()
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
    invite "dtmf-demo@*", Parrot.Examples.DTMFDemo.Handler
    invite "*", Parrot.Examples.DTMFDemo.Handler
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
