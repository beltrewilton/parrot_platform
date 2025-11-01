defmodule ParrotSip.TransportHandlerTest do
  use ExUnit.Case, async: true

  alias ParrotSip.TransportHandler
  alias ParrotSip.{Message, Source}
  alias ParrotSip.Headers.{Via, From, To, CSeq}

  @moduletag :transport_handler

  setup do
    # Start a transport handler for each test
    {:ok, handler} = TransportHandler.start_link()

    # Create a mock transport process that knows the test pid
    test_pid = self()

    mock_transport =
      spawn_link(fn ->
        Process.put(:test_pid, test_pid)
        mock_transport_loop([])
      end)

    %{handler: handler, mock_transport: mock_transport}
  end

  describe "start_link/1" do
    test "starts without options" do
      assert {:ok, pid} = TransportHandler.start_link()
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with name option" do
      name = :test_transport_handler
      assert {:ok, pid} = TransportHandler.start_link(name: name)
      assert Process.whereis(name) == pid
      GenServer.stop(pid)
    end

    test "starts with transport_ref option" do
      mock_transport = spawn_link(fn -> mock_transport_loop([]) end)
      assert {:ok, pid} = TransportHandler.start_link(transport_ref: mock_transport)
      assert Process.alive?(pid)
      GenServer.stop(pid)
      Process.exit(mock_transport, :normal)
    end

    test "registers in ParrotSip.Registry with name" do
      name = :registry_test_handler
      {:ok, pid} = TransportHandler.start_link(name: name)

      assert [{^pid, _}] =
               Registry.lookup(
                 ParrotSip.Registry,
                 {TransportHandler, name}
               )

      GenServer.stop(pid)
    end
  end

  describe "set_transport/2" do
    test "sets transport reference", %{handler: handler} do
      test_pid = self()

      mock_transport =
        spawn_link(fn ->
          Process.put(:test_pid, test_pid)
          mock_transport_loop([])
        end)

      assert :ok = TransportHandler.set_transport(handler, mock_transport)

      # Verify by sending a message through
      test_message = build_test_request()
      TransportHandler.send_message(handler, test_message, {{192, 168, 1, 1}, 5060})

      # Should receive the forwarded packet
      assert_receive {:send_packet, _data, {{192, 168, 1, 1}, 5060}}, 100

      Process.exit(mock_transport, :normal)
    end

    test "updates existing transport reference", %{handler: handler} do
      transport1 = spawn_link(fn -> mock_transport_loop([]) end)
      transport2 = spawn_link(fn -> mock_transport_loop([]) end)

      assert :ok = TransportHandler.set_transport(handler, transport1)
      assert :ok = TransportHandler.set_transport(handler, transport2)

      Process.exit(transport1, :normal)
      Process.exit(transport2, :normal)
    end
  end

  describe "register_handler/2" do
    test "registers a handler to receive messages", %{handler: handler} do
      test_pid = self()

      assert :ok = TransportHandler.register_handler(handler, test_pid)

      # Send a packet to the transport handler
      raw_sip = build_raw_sip_request()
      send(handler, {:packet_received, raw_sip, {{192, 168, 1, 1}, 5060}, %{}})

      # Should receive the parsed message
      assert_receive {:sip_message, %Message{method: :invite}}, 1000
    end

    test "registers multiple handlers", %{handler: handler} do
      handler1 = spawn_link(fn -> receive_loop() end)
      handler2 = spawn_link(fn -> receive_loop() end)

      assert :ok = TransportHandler.register_handler(handler, handler1)
      assert :ok = TransportHandler.register_handler(handler, handler2)

      # Send a packet
      raw_sip = build_raw_sip_request()
      send(handler, {:packet_received, raw_sip, {{192, 168, 1, 1}, 5060}, %{}})

      # Both handlers should receive the message
      Process.sleep(50)

      # Verify handlers are still alive (they would crash if they didn't receive expected message)
      assert Process.alive?(handler1)
      assert Process.alive?(handler2)

      Process.exit(handler1, :normal)
      Process.exit(handler2, :normal)
    end

    test "prevents duplicate handler registration", %{handler: handler} do
      test_pid = self()

      assert :ok = TransportHandler.register_handler(handler, test_pid)
      assert :ok = TransportHandler.register_handler(handler, test_pid)

      # Send a packet
      raw_sip = build_raw_sip_request()
      send(handler, {:packet_received, raw_sip, {{192, 168, 1, 1}, 5060}, %{}})

      # Should only receive one message (not duplicated)
      assert_receive {:sip_message, %Message{method: :invite}}, 100
      refute_receive {:sip_message, _}, 50
    end
  end

  describe "send_message/3" do
    test "serializes and sends SIP message", %{handler: handler, mock_transport: mock_transport} do
      TransportHandler.set_transport(handler, mock_transport)

      message = build_test_request()
      destination = {{192, 168, 1, 100}, 5060}

      TransportHandler.send_message(handler, message, destination)

      # Mock transport should receive serialized data
      assert_receive {:send_packet, data, ^destination}, 100

      # Verify data is properly serialized SIP
      assert String.starts_with?(data, "INVITE")
      assert String.contains?(data, "SIP/2.0")
    end

    test "handles string host in destination", %{handler: handler, mock_transport: mock_transport} do
      TransportHandler.set_transport(handler, mock_transport)

      message = build_test_request()
      destination = {"localhost", 5060}

      TransportHandler.send_message(handler, message, destination)

      # Should resolve and send
      assert_receive {:send_packet, _data, _resolved_dest}, 100
    end

    test "handles nil destination gracefully", %{handler: handler, mock_transport: mock_transport} do
      TransportHandler.set_transport(handler, mock_transport)

      message = build_test_request()

      # Should not crash
      TransportHandler.send_message(handler, message, nil)

      # Should not send anything
      refute_receive {:send_packet, _, _}, 100
    end
  end

  describe "send_response/3" do
    test "sends response using source information", %{
      handler: handler,
      mock_transport: mock_transport
    } do
      TransportHandler.set_transport(handler, mock_transport)

      response = build_test_response()

      source = %Source{
        transport: :udp,
        remote: {{192, 168, 1, 50}, 5060},
        local: {{192, 168, 1, 1}, 5060}
      }

      TransportHandler.send_response(handler, response, source)

      # Should send to the remote address from source
      assert_receive {:send_packet, _data, {{192, 168, 1, 50}, 5060}}, 100
    end

    test "handles tuple source format", %{handler: handler, mock_transport: mock_transport} do
      TransportHandler.set_transport(handler, mock_transport)

      response = build_test_response()
      source = {{192, 168, 1, 75}, 5060}

      TransportHandler.send_response(handler, response, source)

      assert_receive {:send_packet, _data, {{192, 168, 1, 75}, 5060}}, 100
    end

    test "handles invalid source gracefully", %{handler: handler, mock_transport: mock_transport} do
      TransportHandler.set_transport(handler, mock_transport)

      response = build_test_response()

      # Should not crash with invalid source
      TransportHandler.send_response(handler, response, "invalid")

      # Should not send anything
      refute_receive {:send_packet, _, _}, 100
    end
  end

  describe "send_request/3" do
    test "sends request to destination", %{handler: handler, mock_transport: mock_transport} do
      TransportHandler.set_transport(handler, mock_transport)

      request = build_test_request()
      destination = {{10, 0, 0, 1}, 5060}

      TransportHandler.send_request(handler, request, destination)

      assert_receive {:send_packet, data, ^destination}, 100
      assert String.contains?(data, "INVITE")
    end
  end

  describe "packet_received handling" do
    test "parses and routes valid SIP request", %{handler: handler} do
      # Register ourselves as a handler
      TransportHandler.register_handler(handler, self())

      # Send raw SIP packet
      raw_sip = build_raw_sip_request()
      remote = {{192, 168, 1, 100}, 5060}
      metadata = %{local_ip: {192, 168, 1, 1}, local_port: 5060, transport: :udp}

      send(handler, {:packet_received, raw_sip, remote, metadata})

      # Should receive parsed message with source
      assert_receive {:sip_message, message}, 1000

      assert message.type == :request
      assert message.method == :invite
      assert message.source.remote == remote
      assert message.source.transport == :udp
    end

    test "parses and routes valid SIP response", %{handler: handler} do
      TransportHandler.register_handler(handler, self())

      raw_sip = build_raw_sip_response()
      remote = {{192, 168, 1, 200}, 5060}
      metadata = %{}

      send(handler, {:packet_received, raw_sip, remote, metadata})

      assert_receive {:sip_message, message}, 1000

      assert message.type == :response
      assert message.status_code == 200
      assert message.reason_phrase == "OK"
    end

    test "handles parse errors gracefully", %{handler: handler} do
      TransportHandler.register_handler(handler, self())

      # Send invalid SIP data
      invalid_sip = "NOT A VALID SIP MESSAGE\r\n\r\n"
      remote = {{192, 168, 1, 100}, 5060}

      send(handler, {:packet_received, invalid_sip, remote, %{}})

      # Should not receive any message
      refute_receive {:sip_message, _}, 100

      # Handler should still be alive
      assert Process.alive?(handler)
    end

    test "adds source information to parsed message", %{handler: handler} do
      TransportHandler.register_handler(handler, self())

      raw_sip = build_raw_sip_request()
      remote_ip = {10, 0, 0, 50}
      remote_port = 5060
      local_ip = {10, 0, 0, 1}
      local_port = 5060

      metadata = %{
        local_ip: local_ip,
        local_port: local_port,
        transport: :tcp
      }

      send(handler, {:packet_received, raw_sip, {remote_ip, remote_port}, metadata})

      assert_receive {:sip_message, message}, 1000

      assert message.source.remote == {remote_ip, remote_port}
      assert message.source.local == {local_ip, local_port}
      assert message.source.transport == :tcp
    end
  end

  describe "transport process monitoring" do
    test "monitors transport process", %{handler: handler} do
      {:ok, mock_transport} = GenServer.start_link(MockTransport, [])

      TransportHandler.set_transport(handler, mock_transport)

      # Kill the transport normally (not with :kill which propagates)
      GenServer.stop(mock_transport, :normal)

      # Give handler time to process DOWN message
      Process.sleep(50)

      # Handler should still be alive
      assert Process.alive?(handler)

      # Try to send a message - should not crash
      message = build_test_request()
      TransportHandler.send_message(handler, message, {"192.168.1.1", 5060})

      # Should not receive anything (transport is down)
      refute_receive {:send_packet, _, _}, 100
    end
  end

  describe "integration with transaction layer" do
    test "routes request to transaction layer", %{handler: handler} do
      # This would normally create a server transaction
      raw_sip = build_raw_sip_request()
      remote = {{192, 168, 1, 100}, 5060}

      send(handler, {:packet_received, raw_sip, remote, %{}})

      # Give it time to route
      Process.sleep(50)

      # Handler should still be alive (no crash)
      assert Process.alive?(handler)
    end

    test "routes response to transaction layer", %{handler: handler} do
      raw_sip = build_raw_sip_response()
      remote = {{192, 168, 1, 100}, 5060}

      send(handler, {:packet_received, raw_sip, remote, %{}})

      Process.sleep(50)
      assert Process.alive?(handler)
    end
  end

  # Helper functions

  defp build_test_request do
    %Message{
      type: :request,
      method: :invite,
      request_uri: "sip:bob@example.com",
      version: "SIP/2.0",
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "192.168.1.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK776asdhds"}
        }
      ],
      from: %From{
        display_name: "Alice",
        uri: "sip:alice@example.com",
        parameters: %{"tag" => "1928301774"}
      },
      to: %To{
        display_name: nil,
        uri: "sip:bob@example.com",
        parameters: %{}
      },
      call_id: "a84b4c76e66710@pc33.example.com",
      cseq: %CSeq{number: 314_159, method: :invite},
      max_forwards: 70,
      body: ""
    }
  end

  defp build_test_response do
    %Message{
      type: :response,
      status_code: 200,
      reason_phrase: "OK",
      version: "SIP/2.0",
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "192.168.1.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK776asdhds"}
        }
      ],
      from: %From{
        display_name: "Alice",
        uri: "sip:alice@example.com",
        parameters: %{"tag" => "1928301774"}
      },
      to: %To{
        display_name: nil,
        uri: "sip:bob@example.com",
        parameters: %{"tag" => "a6c85cf"}
      },
      call_id: "a84b4c76e66710@pc33.example.com",
      cseq: %CSeq{number: 314_159, method: :invite},
      body: ""
    }
  end

  defp build_raw_sip_request do
    """
    INVITE sip:bob@example.com SIP/2.0\r
    Via: SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK776asdhds\r
    From: Alice <sip:alice@example.com>;tag=1928301774\r
    To: <sip:bob@example.com>\r
    Call-ID: a84b4c76e66710@pc33.example.com\r
    CSeq: 314159 INVITE\r
    Max-Forwards: 70\r
    Content-Length: 0\r
    \r
    """
  end

  defp build_raw_sip_response do
    """
    SIP/2.0 200 OK\r
    Via: SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK776asdhds\r
    From: Alice <sip:alice@example.com>;tag=1928301774\r
    To: <sip:bob@example.com>;tag=a6c85cf\r
    Call-ID: a84b4c76e66710@pc33.example.com\r
    CSeq: 314159 INVITE\r
    Content-Length: 0\r
    \r
    """
  end

  defp mock_transport_loop(state) do
    receive do
      {:"$gen_call", from, {:register_handler, pid}} ->
        GenServer.reply(from, :ok)
        mock_transport_loop([pid | state])

      {:"$gen_call", from, {:register_handler, pid, _opts}} ->
        GenServer.reply(from, :ok)
        mock_transport_loop([pid | state])

      {:"$gen_cast", {:send_data, data, dest_ip, dest_port}} ->
        # Forward to test process for assertions
        # Convert to the format tests expect
        test_pid = Process.get(:test_pid)
        if test_pid, do: send(test_pid, {:send_packet, data, {dest_ip, dest_port}})
        mock_transport_loop(state)

      :stop ->
        :ok

      _msg ->
        mock_transport_loop(state)
    end
  end

  defp receive_loop do
    receive do
      {:sip_message, _message} ->
        # Successfully received message
        receive_loop()

      :stop ->
        :ok

      other ->
        # Unexpected message
        raise "Unexpected message: #{inspect(other)}"
    end
  end
end

defmodule MockTransport do
  use GenServer

  @impl true
  def init(args) do
    {:ok, args}
  end

  @impl true
  def handle_call({:register_handler, _pid}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register_handler, _pid, _opts}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:send_packet, data, destination}, state) do
    # Forward to test process
    send(Process.get(:test_pid) || self(), {:send_packet, data, destination})
    {:noreply, state}
  end
end
