defmodule Parrot.SIPp.SoftphoneIntegrationTest do
  @moduledoc """
  SIPp integration tests for Parrot.SoftphoneClient.

  Tests the complete softphone client functionality:
  - Registration with authentication
  - Presence subscription and NOTIFY handling
  - Presence publishing
  - Incoming and outgoing calls

  ## Running Tests

      # Run all softphone integration tests
      mix test test/sipp/softphone_integration_test.exs --only sipp

  ## Status

  These tests require the SoftphoneClient subsystems (Registration,
  PresenceSubscription, PresencePublisher) to actually send SIP messages
  via ParrotSip. Currently, those modules have TODOs for the actual
  message sending, so these tests are marked as pending.

  Once the TODO comments in the following files are implemented:
  - lib/parrot/softphone_client/registration.ex
  - lib/parrot/softphone_client/presence_subscription.ex
  - lib/parrot/softphone_client/presence_publisher.ex

  Remove the @tag :pending_implementation from these tests.
  """

  use ExUnit.Case, async: false

  alias Parrot.SoftphoneClient

  @moduletag :sipp
  @moduletag :softphone

  # ============================================================================
  # Test Handler
  # ============================================================================

  defmodule TestHandler do
    @moduledoc false
    use Parrot.SoftphoneHandler

    @impl true
    def init(opts) do
      config = %{
        username: opts[:username] || "alice",
        domain: opts[:domain] || "example.com",
        auth_password: opts[:password] || "secret123",
        auto_register: opts[:auto_register] || false,
        transport: :udp,
        local_port: opts[:local_port] || 0,
        supported_codecs: [:pcma]
      }

      state = %{
        test_pid: opts[:test_pid],
        events: []
      }

      {:ok, config, state}
    end

    @impl true
    def handle_registered(info, state) do
      send(state.test_pid, {:handler_event, :registered, info})
      {:ok, %{state | events: [{:registered, info} | state.events]}}
    end

    @impl true
    def handle_registration_failed(reason, state) do
      send(state.test_pid, {:handler_event, :registration_failed, reason})
      {:ok, state}
    end

    @impl true
    def handle_presence_update(presentity, presence, state) do
      send(state.test_pid, {:handler_event, :presence_update, presentity, presence})
      {:ok, %{state | events: [{:presence_update, presentity, presence} | state.events]}}
    end

    @impl true
    def handle_incoming_call(call_info, state) do
      send(state.test_pid, {:handler_event, :incoming_call, call_info})
      {:answer, [], state}
    end

    @impl true
    def handle_call_answered(call_id, state) do
      send(state.test_pid, {:handler_event, :call_answered, call_id})
      {:ok, state}
    end

    @impl true
    def handle_call_rejected(call_id, reason, state) do
      send(state.test_pid, {:handler_event, :call_rejected, call_id, reason})
      {:ok, state}
    end

    @impl true
    def handle_call_ended(call_id, reason, state) do
      send(state.test_pid, {:handler_event, :call_ended, call_id, reason})
      {:ok, state}
    end
  end

  # ============================================================================
  # Setup Helpers
  # ============================================================================

  defp start_softphone(opts \\ []) do
    handler_opts =
      Keyword.merge(
        [test_pid: self(), auto_register: false],
        opts
      )

    {:ok, pid} =
      SoftphoneClient.start_link(
        handler: TestHandler,
        handler_opts: handler_opts
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    {:ok, pid}
  end

  # ============================================================================
  # Registration Tests
  # ============================================================================

  describe "registration with authentication" do
    @describetag :pending_implementation

    @tag timeout: 15_000
    test "registers successfully with 401 challenge" do
      # Start SIPp as registrar server
      # sipp_result = SippRunner.run_scenario(
      #   scenario_file: "test/sipp/scenarios/softphone/uas_registrar.xml",
      #   local_port: 5061,
      #   timeout: 10_000
      # )

      {:ok, phone} = start_softphone(domain: "127.0.0.1:5061")

      :ok = SoftphoneClient.register(phone)

      # Wait for registration success
      assert_receive {:handler_event, :registered, %{expires: 3600}}, 10_000
    end

    @tag timeout: 15_000
    test "re-registers before expiry" do
      {:ok, phone} = start_softphone(domain: "127.0.0.1:5061")

      :ok = SoftphoneClient.register(phone)

      # Wait for initial registration
      assert_receive {:handler_event, :registered, _}, 10_000

      # Wait for re-registration (would need short expires in scenario)
      # assert_receive {:handler_event, :registered, _}, 70_000
    end
  end

  # ============================================================================
  # Presence Subscription Tests
  # ============================================================================

  describe "presence subscription" do
    @describetag :pending_implementation

    @tag timeout: 15_000
    test "subscribes and receives NOTIFY" do
      # Start SIPp as presence server
      # sipp_result = SippRunner.run_scenario(
      #   scenario_file: "test/sipp/scenarios/softphone/uas_presence_server.xml",
      #   local_port: 5062,
      #   timeout: 10_000
      # )

      {:ok, phone} = start_softphone()

      :ok = SoftphoneClient.subscribe(phone, "sip:bob@127.0.0.1:5062")

      # Wait for presence update from NOTIFY
      assert_receive {:handler_event, :presence_update, "sip:bob@127.0.0.1:5062", presence},
                     10_000

      assert presence.status == :open
    end

    @tag timeout: 15_000
    test "handles multiple subscriptions" do
      {:ok, phone} = start_softphone()

      :ok = SoftphoneClient.subscribe(phone, "sip:bob@127.0.0.1:5062")
      :ok = SoftphoneClient.subscribe(phone, "sip:carol@127.0.0.1:5062")

      # Wait for both presence updates
      assert_receive {:handler_event, :presence_update, _, _}, 10_000
      assert_receive {:handler_event, :presence_update, _, _}, 10_000
    end
  end

  # ============================================================================
  # Presence Publishing Tests
  # ============================================================================

  describe "presence publishing" do
    @describetag :pending_implementation

    @tag timeout: 15_000
    test "publishes presence with PIDF" do
      # Start SIPp as PUBLISH server
      # sipp_result = SippRunner.run_scenario(
      #   scenario_file: "test/sipp/scenarios/softphone/uas_publish_server.xml",
      #   local_port: 5063,
      #   timeout: 10_000
      # )

      {:ok, phone} = start_softphone(domain: "127.0.0.1:5063")

      :ok = SoftphoneClient.publish_presence(phone, %{status: :open, note: "Available"})

      # Wait for publish success (if callback is implemented)
      # assert_receive {:handler_event, :publish_success, _}, 10_000
    end
  end

  # ============================================================================
  # Incoming Call Tests
  # ============================================================================

  describe "incoming calls" do
    @describetag :pending_implementation

    @tag timeout: 15_000
    test "answers incoming call" do
      {:ok, phone} = start_softphone()

      # Get the port the softphone is listening on
      state = SoftphoneClient.get_state(phone)
      _local_port = state.config.local_port

      # Start SIPp as caller
      # sipp_result = SippRunner.run_scenario(
      #   scenario_file: "test/sipp/scenarios/softphone/uac_caller.xml",
      #   remote_port: local_port,
      #   timeout: 10_000
      # )

      # Wait for incoming call event
      assert_receive {:handler_event, :incoming_call, call_info}, 5_000
      assert call_info.from =~ "bob"

      # Wait for call answered (auto-answer in TestHandler)
      assert_receive {:handler_event, :call_answered, _call_id}, 5_000

      # Wait for call ended
      assert_receive {:handler_event, :call_ended, _call_id, _reason}, 5_000
    end
  end

  # ============================================================================
  # Outgoing Call Tests
  # ============================================================================

  describe "outgoing calls" do
    @describetag :pending_implementation

    @tag timeout: 15_000
    test "dials and completes call" do
      # Start SIPp as callee
      # sipp_result = SippRunner.run_scenario(
      #   scenario_file: "test/sipp/scenarios/softphone/uas_callee.xml",
      #   local_port: 5064,
      #   timeout: 10_000
      # )

      {:ok, phone} = start_softphone()

      {:ok, call_id} = SoftphoneClient.dial(phone, "sip:bob@127.0.0.1:5064")
      assert is_binary(call_id)

      # Wait for call answered
      assert_receive {:handler_event, :call_answered, ^call_id}, 5_000

      # Hang up
      :ok = SoftphoneClient.hangup(phone, call_id)

      # Wait for call ended
      assert_receive {:handler_event, :call_ended, ^call_id, _reason}, 5_000
    end

    @tag timeout: 15_000
    test "handles call rejection" do
      {:ok, phone} = start_softphone()

      {:ok, _call_id} = SoftphoneClient.dial(phone, "sip:bob@127.0.0.1:5064")

      # Simulate rejection (would come from SIPp scenario)
      # assert_receive {:handler_event, :call_rejected, ^_call_id, _reason}, 5_000
    end
  end

  # ============================================================================
  # Hold/Resume Tests
  # ============================================================================

  describe "call hold and resume" do
    @describetag :pending_implementation

    @tag timeout: 15_000
    test "places call on hold and resumes" do
      {:ok, phone} = start_softphone()

      # Establish call first
      {:ok, call_id} = SoftphoneClient.dial(phone, "sip:bob@127.0.0.1:5064")

      # Simulate call answered
      send(phone, {:call_answered, call_id, %{}})
      assert_receive {:handler_event, :call_answered, ^call_id}, 1_000

      # Put on hold
      :ok = SoftphoneClient.hold(phone, call_id)

      state = SoftphoneClient.get_state(phone)
      assert state.calls[call_id].held == true

      # Resume
      :ok = SoftphoneClient.resume(phone, call_id)

      state = SoftphoneClient.get_state(phone)
      assert state.calls[call_id].held == false
    end
  end
end
