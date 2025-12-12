#!/usr/bin/env elixir

IO.puts("Starting ParrotSip...")
{:ok, _} = Application.ensure_all_started(:parrot_sip)

# Get the transport handler
transport_handler = Process.whereis(ParrotSip.TransportHandler)
IO.puts("✓ TransportHandler: #{inspect(transport_handler)}")

# Create and start a UDP listener
alias ParrotTransport.Types.ListenerConfig
alias ParrotTransport.UdpListener

config = %ListenerConfig{
  transport: :udp,
  port: 5062,
  ip: {127, 0, 0, 1},
  trace: true
}

IO.puts("\nStarting UDP listener on 127.0.0.1:5062...")
{:ok, udp_listener} = UdpListener.start_link(config)
IO.puts("✓ UDP Listener: #{inspect(udp_listener)}")

# Get the actual bound address
{:ok, {local_ip, local_port}} = UdpListener.get_local_address(udp_listener)
IO.puts("✓ Bound to: #{:inet.ntoa(local_ip)}:#{local_port}")

# Register the listener with TransportHandler
:ok =
  ParrotSip.TransportHandler.register_transport(
    transport_handler,
    udp_listener,
    :udp,
    local_ip,
    local_port
  )

IO.puts("✓ Registered transport with TransportHandler")

# Verify it worked
{:ok, {transport_type, host, port}} =
  ParrotSip.TransportHandler.get_default_transport(transport_handler)

IO.puts("✓ Default transport: #{transport_type}://#{host}:#{port}")

# Create a UAC
notify_fun = fn event, _owner ->
  IO.inspect(event, label: "UAC Event")
  :ok
end

IO.puts("\nCreating UAC...")

result =
  ParrotSip.UAC.start_link(
    dest_uri: "sip:test@127.0.0.1:5061",
    from_uri: "sip:alice@#{host}:#{port}",
    sdp:
      "v=0\r\no=- 123 456 IN IP4 #{host}\r\ns=-\r\nc=IN IP4 #{host}\r\nt=0 0\r\nm=audio 8000 RTP/AVP 0\r\n",
    owner: self(),
    notify_fun: notify_fun,
    local_host: host,
    local_port: port,
    transport: transport_type
  )

case result do
  {:ok, uac} ->
    IO.puts("✓ UAC created: #{inspect(uac)}")
    IO.puts("\nWaiting for events (will timeout in 3 seconds)...")
    Process.sleep(3000)

  {:error, reason} ->
    IO.puts("✗ UAC creation failed: #{inspect(reason)}")
end

IO.puts("\nDone.")
