# Test the prompt/3 DSL primitive (play + collect_dtmf)
# Run with: SIP_TRACE=true LOG_LEVEL=info mix run scripts/dev/test_prompt_dsl.exs
#
# This tests the higher-level prompt/3 which combines playing audio
# with DTMF collection in one operation.

require Logger

defmodule TestPromptHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[TestPrompt] INVITE received from #{call.from}")
    Logger.info("[TestPrompt] Answering and playing prompt...")

    # Answer and use prompt/3 to play audio then collect DTMF
    call
    |> answer()
    |> prompt("priv/audio/parrot-welcome.wav", max: 4, timeout: 10_000, terminators: ["#"])
  end

  @impl true
  def handle_play_complete(file, %{assigns: %{__pending_collect__: opts}} = call)
      when not is_nil(opts) do
    # Handle pending collect from prompt/3
    Logger.info("[TestPrompt] Playback complete for #{file}, starting DTMF collection")

    call
    |> assign(:__pending_collect__, nil)
    |> collect_dtmf(opts)
  end

  def handle_play_complete(file, call) do
    Logger.info("[TestPrompt] Playback complete: #{file}")
    {:noreply, call}
  end

  @impl true
  def handle_dtmf(digits, call) when is_binary(digits) do
    Logger.info("[TestPrompt] *** DTMF COLLECTED: #{digits} ***")
    IO.puts("\n*** DTMF COLLECTED: #{digits} ***\n")

    # Play prompt again for next collection
    call |> prompt("priv/audio/parrot-welcome.wav", max: 4, timeout: 10_000, terminators: ["#"])
  end

  def handle_dtmf(:timeout, call) do
    Logger.info("[TestPrompt] DTMF timeout")
    IO.puts("\n*** DTMF TIMEOUT ***\n")

    # Try again
    call |> prompt("priv/audio/parrot-welcome.wav", max: 4, timeout: 10_000, terminators: ["#"])
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[TestPrompt] Call ended")
    {:noreply, call}
  end
end

defmodule TestPromptRouter do
  use Parrot.Router

  invite("*", TestPromptHandler)
end

IO.puts("Starting prompt DSL test server on port 5080...")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestPromptRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("Prompt DSL server listening on port #{port}")
    IO.puts("Call sip:test@127.0.0.1:#{port}")
    IO.puts("You will hear welcome audio, then can send DTMF")
    IO.puts("Press Ctrl+C to stop\n")

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
