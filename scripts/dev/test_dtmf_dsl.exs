# DTMF test server using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_dtmf_dsl.exs
#
# This uses the high-level DSL layer (InviteHandler, Router, Bridge.Handler)
# instead of the low-level SIP/media primitives.

require Logger

# Define the DTMF handler using the DSL
defmodule TestDTMFHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[TestDTMF] INVITE received from #{call.from}")
    Logger.info("[TestDTMF] Answering and starting DTMF collection...")

    # Answer and immediately start collecting DTMF
    # Collect up to 4 digits with 10 second timeout, # terminates
    call
    |> answer()
    |> collect_dtmf(max: 4, timeout: 10_000, terminators: ["#"])
  end

  @impl true
  def handle_dtmf(digits, call) when is_binary(digits) do
    Logger.info("[TestDTMF] *** DTMF COLLECTED: #{digits} ***")
    IO.puts("\n*** DTMF COLLECTED: #{digits} ***\n")

    # Continue collecting
    call |> collect_dtmf(max: 4, timeout: 10_000, terminators: ["#"])
  end

  def handle_dtmf(:timeout, call) do
    Logger.info("[TestDTMF] DTMF timeout, waiting for more...")
    IO.puts("\n*** DTMF TIMEOUT ***\n")

    # Continue collecting
    call |> collect_dtmf(max: 4, timeout: 10_000, terminators: ["#"])
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[TestDTMF] Call ended")
    {:noreply, call}
  end
end

# Define the router
defmodule TestDTMFRouter do
  use Parrot.Router

  invite("*", TestDTMFHandler)
end

# Start the server
IO.puts("Starting DTMF DSL test server on port 5080...")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestDTMFRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("DTMF DSL server listening on port #{port}")
    IO.puts("Call sip:test@127.0.0.1:#{port} and send DTMF digits")
    IO.puts("Press Ctrl+C to stop\n")

    # Keep the script running
    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
