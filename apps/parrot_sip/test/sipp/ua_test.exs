defmodule SippTest.UATest do
  @moduledoc """
  SIPp integration tests for the high-level UA module.

  These tests define the target API for ParrotSip.UA using TDD.
  Tests will fail until UA module is refactored to match this design.
  """
  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, SipStackHelper}
  alias ParrotSip.UA

  @moduletag :sipp

  # ============================================================================
  # Test Handler Module
  # ============================================================================

  defmodule TestHandler do
    @moduledoc """
    Test handler that tracks all events for assertions.
    """
    use ParrotSip.UA.Handler

    @impl true
    def init(test_pid) do
      {:ok, %{test_pid: test_pid}}
    end

    # Inbound calls

    @impl true
    def handle_incoming(ua, invite, entity, state) do
      send(state.test_pid, {:ua_event, :incoming, entity})

      # Auto-answer for tests
      sdp = generate_sdp()
      UA.answer(ua, entity, sdp: sdp)
      {:ok, state}
    end

    # Outbound call responses

    @impl true
    def handle_ringing(_ua, _response, entity, state) do
      send(state.test_pid, {:ua_event, :ringing, entity})
      {:ok, state}
    end

    @impl true
    def handle_answered(_ua, _response, entity, state) do
      send(state.test_pid, {:ua_event, :answered, entity})
      {:ok, state}
    end

    @impl true
    def handle_rejected(_ua, response, entity, state) do
      send(state.test_pid, {:ua_event, :rejected, response.status_code, entity})
      {:ok, state}
    end

    # Both directions

    @impl true
    def handle_hangup(_ua, _message, entity, state) do
      send(state.test_pid, {:ua_event, :hangup, entity})
      {:ok, state}
    end

    @impl true
    def handle_cancel(_ua, entity, state) do
      send(state.test_pid, {:ua_event, :cancel, entity})
      {:ok, state}
    end

    # Registration

    @impl true
    def handle_registered(_ua, _response, reg_id, state) do
      send(state.test_pid, {:ua_event, :registered, reg_id})
      {:ok, state}
    end

    @impl true
    def handle_registration_failed(_ua, response, reg_id, state) do
      send(state.test_pid, {:ua_event, :registration_failed, response.status_code, reg_id})
      {:ok, state}
    end

    defp generate_sdp do
      """
      v=0
      o=- #{System.unique_integer([:positive])} #{System.unique_integer([:positive])} IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 0 8
      a=rtpmap:0 PCMU/8000
      a=rtpmap:8 PCMA/8000
      """
    end
  end

  # ============================================================================
  # UAC Tests - Outbound Calls
  # ============================================================================

  describe "UA as client - dial scenarios" do
    test "basic outbound call - dial, answer, hangup" do
      sipp_port = random_port()
      local_port = random_port()

      # SIPp as UAS - answers and waits for BYE
      sipp_task = start_sipp_uas("basic/uas_bye.xml", sipp_port)

      # Start UA and wire up transport
      {:ok, ua} = UA.start_link(TestHandler, self(), port: local_port)
      handler = UA.get_handler(ua)
      {:ok, stack} = SipStackHelper.start_udp(handler, port: local_port)

      # Make call
      {:ok, entity} = UA.dial(ua, "sip:test@127.0.0.1:#{sipp_port}", sdp: build_sdp())

      # Should be client entity
      assert entity.type == :client
      assert entity.state == :trying

      # Wait for answer
      assert_receive {:ua_event, :answered, answered_entity}, 5_000
      assert answered_entity.id == entity.id
      assert answered_entity.state == :confirmed

      # Hang up
      :ok = UA.hangup(ua, entity)

      # Verify SIPp completed
      assert :ok = Task.await(sipp_task, 10_000)

      SipStackHelper.stop(stack)
      GenServer.stop(ua)
    end

    test "outbound call with 180 Ringing" do
      sipp_port = random_port()
      local_port = random_port()

      # SIPp sends 180 then 200
      sipp_task = start_sipp_uas("basic/uas_invite.xml", sipp_port)

      {:ok, ua} = UA.start_link(TestHandler, self(), port: local_port)
      handler = UA.get_handler(ua)
      {:ok, stack} = SipStackHelper.start_udp(handler, port: local_port)

      {:ok, entity} = UA.dial(ua, "sip:test@127.0.0.1:#{sipp_port}", sdp: build_sdp())

      # Wait for answer
      assert_receive {:ua_event, :answered, _entity}, 5_000

      assert :ok = Task.await(sipp_task, 10_000)
      SipStackHelper.stop(stack)
      GenServer.stop(ua)
    end

    test "outbound call rejected with 486 Busy" do
      sipp_port = random_port()
      local_port = random_port()

      # SIPp rejects with 486
      sipp_task = start_sipp_uas("basic/uas_busy.xml", sipp_port)

      {:ok, ua} = UA.start_link(TestHandler, self(), port: local_port)
      handler = UA.get_handler(ua)
      {:ok, stack} = SipStackHelper.start_udp(handler, port: local_port)

      {:ok, entity} = UA.dial(ua, "sip:test@127.0.0.1:#{sipp_port}", sdp: build_sdp())

      # Wait for rejection
      assert_receive {:ua_event, :rejected, 486, rejected_entity}, 5_000
      assert rejected_entity.id == entity.id

      assert :ok = Task.await(sipp_task, 10_000)
      SipStackHelper.stop(stack)
      GenServer.stop(ua)
    end

    test "cancel outbound call before answer" do
      sipp_port = random_port()
      local_port = random_port()

      # SIPp sends 180 and waits for CANCEL
      sipp_task = start_sipp_uas("cancel/uas_cancel.xml", sipp_port)

      {:ok, ua} = UA.start_link(TestHandler, self(), port: local_port)
      handler = UA.get_handler(ua)
      {:ok, stack} = SipStackHelper.start_udp(handler, port: local_port)

      {:ok, entity} = UA.dial(ua, "sip:test@127.0.0.1:#{sipp_port}", sdp: build_sdp())

      # Wait for ringing
      assert_receive {:ua_event, :ringing, _entity}, 5_000

      # Cancel
      :ok = UA.cancel(ua, entity)

      # Should get 487 Request Terminated
      assert_receive {:ua_event, :rejected, 487, _entity}, 5_000

      assert :ok = Task.await(sipp_task, 10_000)
      SipStackHelper.stop(stack)
      GenServer.stop(ua)
    end
  end

  describe "UA as client - registration" do
    test "successful registration" do
      sipp_port = random_port()
      local_port = random_port()

      # SIPp as registrar
      sipp_task = start_sipp_uas("basic/uas_register.xml", sipp_port)

      {:ok, ua} = UA.start_link(TestHandler, self(), port: local_port)
      handler = UA.get_handler(ua)
      {:ok, stack} = SipStackHelper.start_udp(handler, port: local_port)

      {:ok, reg_id} = UA.register(ua, "sip:127.0.0.1:#{sipp_port}", expires: 3600)

      # Wait for success
      assert_receive {:ua_event, :registered, ^reg_id}, 5_000

      assert :ok = Task.await(sipp_task, 10_000)
      SipStackHelper.stop(stack)
      GenServer.stop(ua)
    end
  end

  # ============================================================================
  # UAS Tests - Inbound Calls
  # ============================================================================

  describe "UA as server - incoming calls" do
    test "receive INVITE and auto-answer" do
      local_port = random_port()

      {:ok, ua} = UA.start_link(TestHandler, self(), port: local_port)
      handler = UA.get_handler(ua)
      {:ok, stack} = SipStackHelper.start_udp(handler, port: local_port)

      # SIPp as UAC - sends INVITE
      sipp_task = start_sipp_uac("basic/uac_invite.xml", local_port)

      # Should receive incoming event
      assert_receive {:ua_event, :incoming, entity}, 5_000
      assert entity.type == :server

      assert :ok = Task.await(sipp_task, 10_000)
      SipStackHelper.stop(stack)
      GenServer.stop(ua)
    end

    test "receive INVITE then BYE from remote" do
      local_port = random_port()

      {:ok, ua} = UA.start_link(TestHandler, self(), port: local_port)
      handler = UA.get_handler(ua)
      {:ok, stack} = SipStackHelper.start_udp(handler, port: local_port)

      # SIPp sends INVITE, waits, then sends BYE
      sipp_task = start_sipp_uac("basic/uac_bye.xml", local_port)

      assert_receive {:ua_event, :incoming, _entity}, 5_000
      assert_receive {:ua_event, :hangup, _entity}, 5_000

      assert :ok = Task.await(sipp_task, 10_000)
      SipStackHelper.stop(stack)
      GenServer.stop(ua)
    end
  end

  # ============================================================================
  # Entity State Tests
  # ============================================================================

  describe "Entity struct" do
    test "entity has correct fields" do
      local_port = random_port()
      sipp_port = random_port()

      sipp_task = start_sipp_uas("basic/uas_invite.xml", sipp_port)

      {:ok, ua} = UA.start_link(TestHandler, self(), port: local_port)
      handler = UA.get_handler(ua)
      {:ok, stack} = SipStackHelper.start_udp(handler, port: local_port)

      {:ok, entity} = UA.dial(ua, "sip:test@127.0.0.1:#{sipp_port}", sdp: build_sdp())

      # Check entity fields
      assert is_binary(entity.id)
      assert entity.type == :client
      assert entity.state == :trying
      assert entity.remote_uri == "sip:test@127.0.0.1:#{sipp_port}"
      assert is_binary(entity.local_uri)
      assert is_binary(entity.call_id)
      assert is_binary(entity.local_tag)

      assert_receive {:ua_event, :answered, answered_entity}, 5_000
      assert answered_entity.state == :confirmed
      assert is_binary(answered_entity.remote_tag)

      assert :ok = Task.await(sipp_task, 10_000)
      SipStackHelper.stop(stack)
      GenServer.stop(ua)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp random_port, do: Enum.random(20_000..30_000)

  defp start_sipp_uas(scenario, port) do
    Task.async(fn ->
      SippRunner.run_scenario(
        scenario_file: "test/sipp/scenarios/#{scenario}",
        remote_host: "127.0.0.1",
        remote_port: port,
        local_port: port,
        calls: 1,
        timeout: 15_000
      )
    end)
  end

  defp start_sipp_uac(scenario, remote_port) do
    Task.async(fn ->
      SippRunner.run_scenario(
        scenario_file: "test/sipp/scenarios/#{scenario}",
        remote_host: "127.0.0.1",
        remote_port: remote_port,
        local_port: random_port(),
        calls: 1,
        timeout: 15_000
      )
    end)
  end

  defp build_sdp do
    """
    v=0
    o=- #{System.unique_integer([:positive])} #{System.unique_integer([:positive])} IN IP4 127.0.0.1
    s=Test Call
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio 10000 RTP/AVP 0 8 101
    a=rtpmap:0 PCMU/8000
    a=rtpmap:8 PCMA/8000
    a=rtpmap:101 telephone-event/8000
    a=sendrecv
    """
  end
end
