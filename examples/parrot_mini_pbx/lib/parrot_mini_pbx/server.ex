defmodule ParrotMiniPbx.Server do
  @moduledoc """
  GenServer that manages the SIP stack for Mini PBX.

  This server:
  - Creates a ParrotSip.Handler using Parrot.Bridge.Handler
  - Starts a ParrotSip.Stack with the handler
  - Provides access to the actual bound port
  - Cleanly shuts down the stack on termination
  """
  use GenServer

  require Logger

  alias Parrot.Examples.MiniPBX.Router

  defstruct [:stack_pid, :port]

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Starts the Mini PBX server.

  ## Options

  - `:port` - Port to bind (default: 5060)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the actual port the SIP stack is listening on.
  """
  @spec get_port() :: non_neg_integer()
  def get_port do
    GenServer.call(__MODULE__, :get_port)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 5060)

    # Create the SIP handler with the Mini PBX router
    # The handler wraps Parrot.Bridge.Handler with router context
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: Router})

    # Start the SIP stack
    case ParrotSip.Stack.start_link(
           handler: handler,
           transport: :udp,
           port: port,
           ip: {0, 0, 0, 0}
         ) do
      {:ok, stack_pid} ->
        # Get the actual bound port (might differ if port was 0)
        actual_port = ParrotSip.Stack.get_port(stack_pid)
        Logger.info("[ParrotMiniPbx.Server] Started SIP stack on port #{actual_port}")

        state = %__MODULE__{
          stack_pid: stack_pid,
          port: actual_port
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("[ParrotMiniPbx.Server] Failed to start SIP stack: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, state.port, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[ParrotMiniPbx.Server] Terminating: #{inspect(reason)}")

    # Stop the SIP stack cleanly
    if state.stack_pid && Process.alive?(state.stack_pid) do
      ParrotSip.Stack.stop(state.stack_pid)
    end

    :ok
  end
end
