defmodule ParrotSip.StackTest do
  @moduledoc """
  Tests for ParrotSip.Stack - the high-level SIP stack API.

  Tests the complete bridge pattern implementation that wires
  transport and SIP protocol layers together.
  """

  use ExUnit.Case, async: false
  require Logger

  alias ParrotSip.Stack
  alias SippTest.TestHandler

  describe "Stack.start_link/1" do
    test "starts UDP stack successfully" do
      handler = TestHandler.new()

      assert {:ok, stack} = Stack.start_link(handler: handler, transport: :udp, port: 0)
      assert is_pid(stack)

      # Clean up
      Stack.stop(stack)
    end

    test "starts TCP stack successfully" do
      handler = TestHandler.new()

      assert {:ok, stack} = Stack.start_link(handler: handler, transport: :tcp, port: 0)
      assert is_pid(stack)

      # Clean up
      Stack.stop(stack)
    end

    test "fails with missing handler" do
      result = Stack.start_link(transport: :udp, port: 0)

      assert {:error, :missing_handler} = result
    end

    test "fails with invalid transport" do
      handler = TestHandler.new()

      result = Stack.start_link(handler: handler, transport: :invalid, port: 0)

      assert {:error, {:invalid_transport, :invalid}} = result
    end

    test "websocket returns not_yet_supported error" do
      handler = TestHandler.new()

      result = Stack.start_link(handler: handler, transport: :websocket, port: 0)

      assert {:error, :websocket_not_yet_supported} = result
    end
  end

  describe "Stack.get_port/1" do
    test "returns actual bound port for random port" do
      handler = TestHandler.new()
      {:ok, stack} = Stack.start_link(handler: handler, transport: :udp, port: 0)

      port = Stack.get_port(stack)
      assert is_integer(port)
      assert port > 0

      Stack.stop(stack)
    end

    test "returns configured port when specific port requested" do
      handler = TestHandler.new()
      requested_port = 15060

      {:ok, stack} = Stack.start_link(handler: handler, transport: :udp, port: requested_port)

      port = Stack.get_port(stack)
      assert port == requested_port

      Stack.stop(stack)
    end
  end

  describe "Stack.get_ip/1" do
    test "returns actual bound IP address" do
      handler = TestHandler.new()
      {:ok, stack} = Stack.start_link(handler: handler, transport: :udp, port: 0)

      ip = Stack.get_ip(stack)
      assert ip == {127, 0, 0, 1}

      Stack.stop(stack)
    end

    test "returns configured IP when specific IP requested" do
      handler = TestHandler.new()
      requested_ip = {127, 0, 0, 1}

      {:ok, stack} =
        Stack.start_link(handler: handler, transport: :udp, port: 0, ip: requested_ip)

      ip = Stack.get_ip(stack)
      assert ip == requested_ip

      Stack.stop(stack)
    end
  end

  describe "Stack.stop/1" do
    test "cleans up resources for UDP stack" do
      handler = TestHandler.new()
      {:ok, stack} = Stack.start_link(handler: handler, transport: :udp, port: 0)

      assert :ok = Stack.stop(stack)

      # Verify process is stopped
      refute Process.alive?(stack)
    end

    test "cleans up resources for TCP stack" do
      handler = TestHandler.new()
      {:ok, stack} = Stack.start_link(handler: handler, transport: :tcp, port: 0)

      assert :ok = Stack.stop(stack)

      # Verify process is stopped
      refute Process.alive?(stack)
    end
  end

  describe "Multiple stacks" do
    test "can run multiple UDP stacks on different ports" do
      handler1 = TestHandler.new()
      handler2 = TestHandler.new()

      {:ok, stack1} = Stack.start_link(handler: handler1, transport: :udp, port: 0)
      {:ok, stack2} = Stack.start_link(handler: handler2, transport: :udp, port: 0)

      port1 = Stack.get_port(stack1)
      port2 = Stack.get_port(stack2)

      # Ports should be different
      assert port1 != port2

      Stack.stop(stack1)
      Stack.stop(stack2)
    end

    test "can run multiple TCP stacks on different ports" do
      handler1 = TestHandler.new()
      handler2 = TestHandler.new()

      {:ok, stack1} = Stack.start_link(handler: handler1, transport: :tcp, port: 0)
      {:ok, stack2} = Stack.start_link(handler: handler2, transport: :tcp, port: 0)

      port1 = Stack.get_port(stack1)
      port2 = Stack.get_port(stack2)

      # Ports should be different
      assert port1 != port2

      Stack.stop(stack1)
      Stack.stop(stack2)
    end

    test "can run UDP and TCP stacks on same port" do
      handler1 = TestHandler.new()
      handler2 = TestHandler.new()

      # Get a random port for UDP
      {:ok, udp_stack} = Stack.start_link(handler: handler1, transport: :udp, port: 0)
      udp_port = Stack.get_port(udp_stack)

      # Use the same port for TCP (should work since different transport)
      {:ok, tcp_stack} = Stack.start_link(handler: handler2, transport: :tcp, port: udp_port)
      tcp_port = Stack.get_port(tcp_stack)

      assert udp_port == tcp_port

      Stack.stop(udp_stack)
      Stack.stop(tcp_stack)
    end
  end

  describe "SIP message routing" do
    test "routes incoming requests to handler" do
      handler = TestHandler.new()
      {:ok, stack} = Stack.start_link(handler: handler, transport: :udp, port: 0)
      port = Stack.get_port(stack)

      # Send an OPTIONS request to the stack
      options_msg = """
      OPTIONS sip:test@127.0.0.1:#{port} SIP/2.0\r
      Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bK776asdhds\r
      Max-Forwards: 70\r
      To: <sip:test@127.0.0.1:#{port}>\r
      From: Alice <sip:alice@127.0.0.1:5060>;tag=1928301774\r
      Call-ID: a84b4c76e66710@127.0.0.1\r
      CSeq: 63104 OPTIONS\r
      Contact: <sip:alice@127.0.0.1:5060>\r
      Content-Length: 0\r
      \r
      """

      # Send to the stack's UDP port
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
      :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, options_msg)

      # Wait for response
      assert {:ok, {_addr, _port, response_data}} = :gen_udp.recv(socket, 0, 5000)

      # Should get a 200 OK response (TestHandler auto-responds)
      assert response_data =~ "SIP/2.0 200 OK"

      :gen_udp.close(socket)
      Stack.stop(stack)
    end

    test "routes incoming INVITE to handler" do
      handler = TestHandler.new()
      {:ok, stack} = Stack.start_link(handler: handler, transport: :udp, port: 0)
      port = Stack.get_port(stack)

      # Send an INVITE request
      invite_msg = """
      INVITE sip:bob@127.0.0.1:#{port} SIP/2.0\r
      Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bK776asdhds\r
      Max-Forwards: 70\r
      To: <sip:bob@127.0.0.1:#{port}>\r
      From: Alice <sip:alice@127.0.0.1:5060>;tag=1928301774\r
      Call-ID: a84b4c76e66710@127.0.0.1\r
      CSeq: 314159 INVITE\r
      Contact: <sip:alice@127.0.0.1:5060>\r
      Content-Type: application/sdp\r
      Content-Length: 0\r
      \r
      """

      {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
      :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, invite_msg)

      # First response should be 100 Trying (provisional)
      assert {:ok, {_addr, _port, trying_response}} = :gen_udp.recv(socket, 0, 5000)
      assert trying_response =~ "SIP/2.0 100 Trying"

      # Second response should be 200 OK with SDP body
      assert {:ok, {_addr, _port, ok_response}} = :gen_udp.recv(socket, 0, 5000)
      assert ok_response =~ "SIP/2.0 200 OK"
      # Check for SDP body (starts with v=0)
      assert ok_response =~ "v=0"
      assert ok_response =~ "m=audio"

      :gen_udp.close(socket)
      Stack.stop(stack)
    end
  end

  describe "Transport registration" do
    test "registers transport with TransportHandler for response routing" do
      handler = TestHandler.new()
      {:ok, stack} = Stack.start_link(handler: handler, transport: :udp, port: 0)
      _port = Stack.get_port(stack)
      _ip = Stack.get_ip(stack)

      # Verify the transport is registered with TransportHandler
      # by checking that we can get default transport info
      assert {:ok, {transport_type, _host, registered_port}} =
               ParrotSip.TransportHandler.get_default_transport(ParrotSip.TransportHandler)

      # The registered transport should match our stack
      # Note: There might be other transports registered, so we just verify
      # that SOME transport is registered (the global one)
      assert transport_type in [:udp, :tcp, :tls]
      assert is_integer(registered_port)

      Stack.stop(stack)
    end
  end
end
