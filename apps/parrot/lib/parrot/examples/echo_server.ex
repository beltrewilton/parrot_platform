defmodule Parrot.Examples.EchoServer do
  @moduledoc """
  Echo server - answers calls using the Parrot DSL.

  A minimal example demonstrating the Parrot DSL for building SIP applications.
  Uses `Parrot.InviteHandler` for call handling and `Parrot.Router` for routing.

  ## Running the Example

      # Start in IEx
      iex -S mix
      {:ok, stack} = Parrot.Examples.EchoServer.start(port: 15060)

  ## Testing

      # With gophone
      gophone dial sip:test@127.0.0.1:15060

      # With SIPp
      sipp -sn uac 127.0.0.1:15060 -m 1
  """

  require Logger

  # ============================================================================
  # Handler - implements Parrot.InviteHandler behaviour
  # ============================================================================

  defmodule Handler do
    @moduledoc """
    Simple handler that answers all incoming calls.
    """
    use Parrot.InviteHandler

    @impl true
    def handle_invite(call) do
      call |> answer()
    end

    @impl true
    def handle_hangup(call) do
      {:noreply, call}
    end
  end

  # ============================================================================
  # Router - routes INVITEs to the Handler
  # ============================================================================

  defmodule Router do
    @moduledoc """
    Routes all INVITEs to the EchoServer handler.
    """
    use Parrot.Router

    invite "*", Parrot.Examples.EchoServer.Handler
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the echo server on the given port.

  ## Options
    - `:port` - UDP port to listen on (default: 15060)

  ## Returns
    - `{:ok, stack}` - Stack PID with server details
    - `{:error, reason}` - Startup failed

  ## Examples

      {:ok, stack} = Parrot.Examples.EchoServer.start(port: 15060)
      # Server is now listening on port 15060

      # To stop the server:
      Parrot.Examples.EchoServer.stop(stack)
  """
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, 15060)

    # Create handler using Bridge.Handler with our router
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: Router})

    # Start the SIP stack using the production-ready ParrotSip.Stack
    case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: port) do
      {:ok, stack} ->
        actual_port = ParrotSip.Stack.get_port(stack)
        Logger.info("[EchoServer] Started on port #{actual_port}")
        {:ok, stack}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops the echo server.

  ## Examples

      {:ok, stack} = Parrot.Examples.EchoServer.start()
      :ok = Parrot.Examples.EchoServer.stop(stack)
  """
  def stop(stack) do
    ParrotSip.Stack.stop(stack)
  end
end
