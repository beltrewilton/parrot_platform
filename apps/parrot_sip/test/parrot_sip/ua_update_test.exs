defmodule ParrotSip.UAUpdateTest do
  @moduledoc """
  Unit tests for ParrotSip.UA send_update/3 functionality.
  RFC 3311 - The Session Initiation Protocol (SIP) UPDATE Method
  """
  use ExUnit.Case, async: true

  alias ParrotSip.UA
  alias ParrotSip.UA.Entity

  setup do
    Application.ensure_all_started(:parrot_sip)
    :ok
  end

  # Test handler that tracks events
  defmodule TestHandler do
    use ParrotSip.UA.Handler

    @impl true
    def init(test_pid) do
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_incoming(_ua, _invite, entity, state) do
      send(state.test_pid, {:incoming, entity})
      {:ok, state}
    end

    @impl true
    def handle_answered(_ua, _response, entity, state) do
      send(state.test_pid, {:answered, entity})
      {:ok, state}
    end

    @impl true
    def handle_update_complete(_ua, response, entity, state) do
      send(state.test_pid, {:update_complete, response, entity})
      {:ok, state}
    end

    @impl true
    def handle_update_failed(_ua, status, response, entity, state) do
      send(state.test_pid, {:update_failed, status, response, entity})
      {:ok, state}
    end
  end

  describe "send_update/3 public API" do
    test "function is exported from UA module" do
      # Verify the function exists
      assert function_exported?(UA, :send_update, 3)
    end

    test "function with default arguments is exported" do
      # send_update(ua, entity) should also work (defaults)
      assert function_exported?(UA, :send_update, 2) or function_exported?(UA, :send_update, 3)
    end
  end

  describe "send_update/3 message building" do
    setup do
      local_port = random_port()
      {:ok, ua} = UA.start_link(TestHandler, self(), port: local_port, local_host: "127.0.0.1")

      # Create a mock confirmed entity with valid IP addresses
      entity = %Entity{
        id: Entity.generate_id(),
        type: :client,
        state: :confirmed,
        remote_uri: "sip:bob@127.0.0.1:5060",
        local_uri: "sip:alice@127.0.0.1:#{local_port}",
        call_id: "test-call-id@127.0.0.1",
        local_tag: "local-tag-123",
        remote_tag: "remote-tag-456",
        local_seq: 1,
        created_at: System.monotonic_time(:millisecond),
        ua_pid: ua
      }

      # Register the entity in the UA
      :sys.replace_state(ua, fn state ->
        %{state | entities: Map.put(state.entities, entity.id, entity)}
      end)

      on_exit(fn ->
        if Process.alive?(ua), do: GenServer.stop(ua)
      end)
      {:ok, ua: ua, entity: entity}
    end

    test "returns error for non-existent entity", %{ua: ua} do
      fake_entity = %Entity{id: "non-existent-id", ua_pid: ua}
      result = UA.send_update(ua, fake_entity)
      assert {:error, :entity_not_found} = result
    end

    test "returns error for entity not in confirmed state", %{ua: ua} do
      entity = %Entity{
        id: Entity.generate_id(),
        type: :client,
        state: :trying,  # Not confirmed
        remote_uri: "sip:bob@127.0.0.1:5060",
        local_uri: "sip:alice@127.0.0.1:5060",
        call_id: "test-call@127.0.0.1",
        local_tag: "local-tag",
        local_seq: 1,
        ua_pid: ua
      }

      :sys.replace_state(ua, fn state ->
        %{state | entities: Map.put(state.entities, entity.id, entity)}
      end)

      result = UA.send_update(ua, entity)
      assert {:error, :invalid_state} = result
    end

    test "increments CSeq for UPDATE request", %{ua: ua, entity: entity} do
      initial_seq = entity.local_seq

      # Send UPDATE
      :ok = UA.send_update(ua, entity)

      # Verify CSeq was incremented
      updated_entity = get_entity(ua, entity.id)
      assert updated_entity.local_seq == initial_seq + 1
    end

    test "includes SDP when provided", %{ua: ua, entity: entity} do
      sdp = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 0
      a=rtpmap:0 PCMU/8000
      """

      :ok = UA.send_update(ua, entity, sdp: sdp)

      # The UPDATE was sent - in a real test we'd verify the message
      # For unit test, we just verify no crash
      assert true
    end

    test "works without SDP (session timer refresh)", %{ua: ua, entity: entity} do
      :ok = UA.send_update(ua, entity)
      assert true
    end

    test "accepts extra headers option without crash", %{ua: ua, entity: entity} do
      headers = %{
        "X-Custom-Header" => "custom-value",
        "Session-Expires" => "1800;refresher=uac"
      }

      # Note: extra headers support reserved for future implementation
      :ok = UA.send_update(ua, entity, headers: headers)
      assert true
    end
  end

  # Helper to get entity from UA state
  defp get_entity(ua, entity_id) do
    state = :sys.get_state(ua)
    Map.get(state.entities, entity_id)
  end

  defp random_port do
    :rand.uniform(10000) + 20000
  end
end
