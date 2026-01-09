defmodule Parrot.Examples.SimpleIVR do
  @moduledoc """
  Simple IVR example demonstrating the Parrot DSL layer.

  This example shows how to build a simple IVR (Interactive Voice Response)
  using the high-level Parrot DSL instead of low-level ParrotSip.Handler callbacks.

  ## Running the Example

      # Start with the convenience function
      {:ok, stack} = Parrot.Examples.SimpleIVR.start(port: 15061)

  ## Testing

      gophone dial sip:welcome@127.0.0.1:15061
      gophone dial -dtmf=1 -dtmf_delay=2s sip:welcome@127.0.0.1:15061

  ## What It Does

  - Answers incoming INVITE requests
  - Plays a welcome audio file (when media integration is complete)
  - Hangs up after playback completes

  ## Architecture

  The module is organized into three components:

  - `Handler` - Implements the `Parrot.InviteHandler` behaviour with DSL operations
  - `Router` - Uses `Parrot.Router` to route INVITEs to the Handler
  - `start/1` - Convenience function to start the SIP stack

  ## Comparison to Low-Level Handler

  This DSL-based implementation reduces ~90 lines of boilerplate to ~30 lines
  of focused call handling logic. The DSL provides:

  - Automatic SDP negotiation via `answer()`
  - Pipeline-style call operations
  - Clean callback separation for events like `handle_play_complete`
  """

  require Logger

  # ============================================================================
  # Handler - DSL-based call handling
  # ============================================================================

  defmodule Handler do
    @moduledoc """
    IVR handler that answers calls and plays welcome audio.
    """
    use Parrot.InviteHandler

    require Logger

    @impl true
    def handle_invite(call) do
      Logger.info("[SimpleIVR] INVITE from #{inspect(call.from)}")
      Logger.info("[SimpleIVR] Answering call...")

      call
      |> answer()
      |> play("priv/audio/welcome.wav")
    end

    @impl true
    def handle_play_complete(_file, call) do
      Logger.info("[SimpleIVR] Playback complete, hanging up")

      call
      |> hangup()
    end

    @impl true
    def handle_hangup(call) do
      Logger.info("[SimpleIVR] Call ended")
      {:noreply, call}
    end
  end

  # ============================================================================
  # Router - Routes INVITEs to Handler
  # ============================================================================

  defmodule Router do
    @moduledoc """
    Router that routes all INVITEs to the SimpleIVR Handler.
    """
    use Parrot.Router

    # Route all INVITE requests to our handler
    invite("*", Parrot.Examples.SimpleIVR.Handler)
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the SimpleIVR server using the Parrot DSL stack.

  ## Options

    - `:port` - UDP port to listen on (default: 15061)

  ## Returns

    - `{:ok, stack}` - Stack struct with listener info
    - `{:error, reason}` - Startup failed

  ## Examples

      {:ok, stack} = Parrot.Examples.SimpleIVR.start(port: 15061)
      # stack.port contains the actual bound port
  """
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, 15061)

    # Create a ParrotSip.Handler that uses Bridge.Handler with our DSL router
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: Router})

    # Start the SIP stack
    case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: port) do
      {:ok, stack} ->
        actual_port = ParrotSip.Stack.get_port(stack)
        Logger.info("[SimpleIVR] Started on port #{actual_port}")
        {:ok, stack}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
