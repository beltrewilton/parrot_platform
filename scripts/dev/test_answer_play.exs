# Simple answer and play test using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_answer_play.exs
#
# Answers incoming calls and plays the welcome audio file.

require Logger

defmodule TestAnswerPlayHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[AnswerPlay] INVITE received from #{call.from}")

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[AnswerPlay] Playback complete: #{file}")
    # Hang up after playing
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[AnswerPlay] Call ended")
    {:noreply, call}
  end
end

defmodule TestAnswerPlayRouter do
  use Parrot.Router

  invite("*", TestAnswerPlayHandler)
end

IO.puts("Starting answer+play DSL test server on port 5080...")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestAnswerPlayRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("Server listening on port #{port}")
    IO.puts("Call sip:test@127.0.0.1:#{port} to hear the welcome message")
    IO.puts("Press Ctrl+C to stop\n")

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
