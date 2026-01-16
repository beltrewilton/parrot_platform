# Simple DTMF test server script
# Run with: mix run test_dtmf_server.exs

# Compile test support modules
Code.compile_file("apps/parrot_sip/test/support/sip_stack_helper.ex")
Code.compile_file("apps/parrot_sip/test/sipp/support/dtmf_test_handler.ex")

IO.puts("Starting DTMF test server on port 5080...")

# Create handler that will print DTMF to console
handler = SippTest.DTMFTestHandler.new(test_pid: self())
{:ok, stack} = SippTest.SipStackHelper.start_udp(handler, port: 5080)

IO.puts("DTMF test server listening on port #{stack.port}")
IO.puts("Call sip:test@127.0.0.1:5080 and send DTMF digits")
IO.puts("Press Ctrl+C to stop\n")

# Loop to receive and print DTMF messages
defmodule DTMFPrinter do
  def loop do
    receive do
      {:dtmf_collected, digits} ->
        IO.puts("\n*** DTMF COLLECTED: #{digits} ***\n")
        loop()

      {:dtmf_timeout, partial} ->
        IO.puts("\n*** DTMF TIMEOUT (partial: #{partial}) ***\n")
        loop()

      {:media_event, _session_id, {:dtmf_collected, digits}} ->
        IO.puts("\n*** DTMF COLLECTED: #{digits} ***\n")
        loop()

      {:media_event, _session_id, {:dtmf_timeout, partial}} ->
        IO.puts("\n*** DTMF TIMEOUT (partial: #{partial}) ***\n")
        loop()

      other ->
        IO.puts("Received: #{inspect(other)}")
        loop()
    end
  end
end

DTMFPrinter.loop()
