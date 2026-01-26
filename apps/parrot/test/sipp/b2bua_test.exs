defmodule Parrot.Sipp.B2BUATest do
  @moduledoc """
  SIPp integration tests for B2BUA functionality.

  These tests verify B2BUA call bridging, forking, hold/resume, and transfer
  using real SIP traffic via SIPp.

  ## Test Categories

  - **Bridge tests**: Basic call bridging (A-leg to B-leg)
  - **Fork tests**: Call forking with simultaneous ring
  - **Hold/resume tests**: Re-INVITE based hold and resume
  - **Transfer tests**: REFER-based blind transfer

  ## Architecture

  B2BUA scenarios require Parrot to act as both UAS (for A-leg) and UAC (for B-leg).
  Tests use multiple SIPp instances:
  - UAC instance (A-leg caller) -> Parrot B2BUA
  - UAS instance (B-leg destination) <- Parrot B2BUA

  ## Running Tests

      # Run all B2BUA tests
      mix test apps/parrot/test/sipp/b2bua_test.exs --include sipp

      # Run with debug logging
      LOG_LEVEL=debug SIP_TRACE=true mix test apps/parrot/test/sipp/b2bua_test.exs --include sipp

      # Run specific test
      mix test apps/parrot/test/sipp/b2bua_test.exs:100 --include sipp

  ## Prerequisites

  - SIPp installed and available in PATH
  - B2BUA modules implemented (Parrot.Bridge.B2BUA, Parrot.Leg, etc.)
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, SipStackHelper}

  @moduletag :sipp
  @moduletag :b2bua

  # ===========================================================================
  # Test Handlers
  # ===========================================================================

  defmodule BridgeHandler do
    @moduledoc """
    B2BUA handler that bridges incoming calls to a configurable B-leg.

    This handler demonstrates the intended B2BUA usage pattern:
    1. Receive INVITE on A-leg
    2. Answer A-leg
    3. Originate call to B-leg
    4. Bridge A and B when B answers
    5. Handle BYE from either side
    """
    use Parrot.InviteHandler

    @impl true
    def handle_invite(call) do
      # Get B-leg target from call metadata or assigns
      bleg_target = call.assigns[:bleg_target] || "sip:bob@127.0.0.1:5070"

      call
      |> answer()
      |> bridge(bleg_target, timeout: 30_000)
    end

    @impl true
    def handle_leg_event(call, _leg_id, :ringing) do
      {:ok, call}
    end

    @impl true
    def handle_leg_event(call, _leg_id, {:answered, _sdp}) do
      {:ok, call}
    end

    @impl true
    def handle_leg_event(call, _leg_id, {:failed, _reason}) do
      {:ok, call |> hangup()}
    end

    @impl true
    def handle_leg_event(call, _leg_id, :bye) do
      {:ok, call |> hangup()}
    end

    @impl true
    def handle_leg_event(call, _leg_id, _event) do
      {:ok, call}
    end

    @impl true
    def handle_hangup(call) do
      {:noreply, call}
    end
  end

  defmodule ForkHandler do
    @moduledoc """
    B2BUA handler that forks calls to multiple destinations.
    First destination to answer wins.
    """
    use Parrot.InviteHandler

    @impl true
    def handle_invite(call) do
      targets = call.assigns[:fork_targets] || [
        "sip:target1@127.0.0.1:5070",
        "sip:target2@127.0.0.1:5071"
      ]

      call
      |> answer()
      |> fork(targets, strategy: :simultaneous, timeout: 30_000)
    end

    @impl true
    def handle_leg_event(call, leg_id, {:answered, _sdp}) do
      # First to answer wins - bridge to this leg
      {:bridge, leg_id, call}
    end

    @impl true
    def handle_leg_event(call, _leg_id, :cancelled) do
      # Another leg won, this one was cancelled
      {:ok, call}
    end

    @impl true
    def handle_leg_event(call, _leg_id, {:failed, _reason}) do
      # Check if all legs failed
      {:ok, call}
    end

    @impl true
    def handle_leg_event(call, _leg_id, :bye) do
      {:ok, call |> hangup()}
    end

    @impl true
    def handle_leg_event(call, _leg_id, _event) do
      {:ok, call}
    end

    @impl true
    def handle_hangup(call) do
      {:noreply, call}
    end
  end

  defmodule TransferHandler do
    @moduledoc """
    B2BUA handler that supports REFER-based transfers.
    """
    use Parrot.InviteHandler

    @impl true
    def handle_invite(call) do
      bleg_target = call.assigns[:bleg_target] || "sip:bob@127.0.0.1:5070"

      call
      |> answer()
      |> bridge(bleg_target, timeout: 30_000)
    end

    @impl true
    def handle_leg_event(call, _leg_id, {:refer_requested, to_uri}) do
      # Accept the transfer - B2BUA will handle the mechanics
      {:ok, call |> transfer(:b_leg, to_uri)}
    end

    @impl true
    def handle_leg_event(call, _leg_id, {:transfer_complete, _leg_id}) do
      # Transfer successful - hang up A-leg
      {:ok, call |> hangup_leg(:a_leg)}
    end

    @impl true
    def handle_leg_event(call, _leg_id, {:transfer_failed, _reason}) do
      # Transfer failed - continue with current call
      {:ok, call}
    end

    @impl true
    def handle_leg_event(call, _leg_id, _event) do
      {:ok, call}
    end

    @impl true
    def handle_hangup(call) do
      {:noreply, call}
    end
  end

  defmodule ReferRejectHandler do
    @moduledoc """
    B2BUA handler that rejects incoming REFER requests.
    Used to test inbound REFER rejection.
    """
    use Parrot.InviteHandler

    @impl true
    def handle_invite(call) do
      call |> answer()
    end

    @impl true
    def handle_leg_event(call, _leg_id, {:refer_requested, _to_uri}) do
      # Reject the transfer request
      {:reject_refer, 403, call}
    end

    @impl true
    def handle_leg_event(call, _leg_id, _event) do
      {:ok, call}
    end

    @impl true
    def handle_hangup(call) do
      {:noreply, call}
    end
  end

  # ===========================================================================
  # Test Routers
  # ===========================================================================

  defmodule BridgeRouter do
    use Parrot.Router
    invite("*", Parrot.Sipp.B2BUATest.BridgeHandler)
  end

  defmodule ForkRouter do
    use Parrot.Router
    invite("*", Parrot.Sipp.B2BUATest.ForkHandler)
  end

  defmodule TransferRouter do
    use Parrot.Router
    invite("*", Parrot.Sipp.B2BUATest.TransferHandler)
  end

  defmodule ReferRejectRouter do
    use Parrot.Router
    invite("*", Parrot.Sipp.B2BUATest.ReferRejectHandler)
  end

  # ===========================================================================
  # Test Setup
  # ===========================================================================

  # Get scenario directory path
  defp scenario_dir do
    Path.expand("b2bua", __DIR__)
  end

  # Get umbrella root for parrot_sip scenarios
  defp umbrella_root do
    Path.expand("../../../..", __DIR__)
  end

  # ===========================================================================
  # Bridge Tests
  # ===========================================================================

  describe "basic bridge" do
    @tag :skip
    @tag timeout: 30_000
    test "A-leg calls B2BUA, B-leg answers, call bridged, A-leg hangs up" do
      # Note: This test requires B2BUA functionality to be fully implemented.
      # It is marked as skip until the B2BUA module is ready.

      # Port assignments
      b2bua_port = Enum.random(20_000..22_000)
      bleg_port = Enum.random(22_001..24_000)

      # Start B2BUA stack
      handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{
        router: BridgeRouter,
        bleg_target: "sip:bob@127.0.0.1:#{bleg_port}"
      })
      {:ok, stack} = SipStackHelper.start_udp(handler, port: b2bua_port)

      # Start B-leg SIPp UAS in background
      bleg_task = Task.async(fn ->
        SippRunner.run_scenario(
          scenario_file: scenario_dir() <> "/uas_bridge_basic_bleg.xml",
          remote_host: "127.0.0.1",
          remote_port: bleg_port,
          local_port: bleg_port,
          calls: 1,
          timeout: 25_000
        )
      end)

      # Give B-leg time to start listening
      Process.sleep(500)

      # Run A-leg SIPp UAC
      result = SippRunner.run_scenario(
        scenario_file: scenario_dir() <> "/uac_bridge_basic.xml",
        remote_host: "127.0.0.1",
        remote_port: b2bua_port,
        calls: 1,
        timeout: 20_000
      )

      # Assert both legs completed successfully
      assert result == :ok
      assert Task.await(bleg_task, 25_000) == :ok

      # Cleanup
      SipStackHelper.stop(stack)
    end

    @tag :skip
    @tag timeout: 30_000
    test "A-leg calls B2BUA, B-leg rejects with 486 Busy" do
      # Note: This test requires B2BUA functionality to be fully implemented.

      b2bua_port = Enum.random(20_000..22_000)
      bleg_port = Enum.random(22_001..24_000)

      handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{
        router: BridgeRouter,
        bleg_target: "sip:bob@127.0.0.1:#{bleg_port}"
      })
      {:ok, stack} = SipStackHelper.start_udp(handler, port: b2bua_port)

      # Start B-leg SIPp UAS that rejects
      bleg_task = Task.async(fn ->
        SippRunner.run_scenario(
          scenario_file: scenario_dir() <> "/uas_bridge_reject_bleg.xml",
          remote_host: "127.0.0.1",
          remote_port: bleg_port,
          local_port: bleg_port,
          calls: 1,
          timeout: 20_000
        )
      end)

      Process.sleep(500)

      # Run A-leg - should receive error response
      result = SippRunner.run_scenario(
        scenario_file: scenario_dir() <> "/uac_bridge_reject.xml",
        remote_host: "127.0.0.1",
        remote_port: b2bua_port,
        calls: 1,
        timeout: 15_000
      )

      assert result == :ok
      assert Task.await(bleg_task, 20_000) == :ok

      SipStackHelper.stop(stack)
    end
  end

  # ===========================================================================
  # Fork Tests
  # ===========================================================================

  describe "fork simultaneous" do
    @tag :skip
    @tag timeout: 45_000
    test "fork to multiple destinations, first answer wins" do
      # Note: This test requires fork functionality to be fully implemented.

      forker_port = Enum.random(20_000..22_000)
      target1_port = Enum.random(22_001..24_000)
      target2_port = Enum.random(24_001..26_000)

      handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{
        router: ForkRouter,
        fork_targets: [
          "sip:target1@127.0.0.1:#{target1_port}",
          "sip:target2@127.0.0.1:#{target2_port}"
        ]
      })
      {:ok, stack} = SipStackHelper.start_udp(handler, port: forker_port)

      # Start fast target (answers in 200ms)
      fast_task = Task.async(fn ->
        SippRunner.run_scenario(
          scenario_file: scenario_dir() <> "/uas_fork_target_fast.xml",
          remote_host: "127.0.0.1",
          remote_port: target1_port,
          local_port: target1_port,
          calls: 1,
          timeout: 30_000
        )
      end)

      # Start slow target (answers in 1500ms, should get CANCEL)
      slow_task = Task.async(fn ->
        SippRunner.run_scenario(
          scenario_file: scenario_dir() <> "/uas_fork_target_slow.xml",
          remote_host: "127.0.0.1",
          remote_port: target2_port,
          local_port: target2_port,
          calls: 1,
          timeout: 30_000
        )
      end)

      Process.sleep(500)

      # Run caller
      result = SippRunner.run_scenario(
        scenario_file: scenario_dir() <> "/uac_fork_simultaneous.xml",
        remote_host: "127.0.0.1",
        remote_port: forker_port,
        calls: 1,
        timeout: 25_000
      )

      assert result == :ok

      # Both tasks should complete (fast wins, slow gets cancelled)
      assert Task.await(fast_task, 30_000) == :ok
      assert Task.await(slow_task, 30_000) == :ok

      SipStackHelper.stop(stack)
    end
  end

  # ===========================================================================
  # Hold/Resume Tests
  # ===========================================================================

  describe "hold and resume" do
    @tag :skip
    @tag timeout: 45_000
    test "A-leg puts call on hold and resumes via re-INVITE" do
      # Note: This test requires B2BUA hold/resume functionality.

      b2bua_port = Enum.random(20_000..22_000)
      bleg_port = Enum.random(22_001..24_000)

      handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{
        router: BridgeRouter,
        bleg_target: "sip:bob@127.0.0.1:#{bleg_port}"
      })
      {:ok, stack} = SipStackHelper.start_udp(handler, port: b2bua_port)

      # Start B-leg that handles hold/resume re-INVITEs
      bleg_task = Task.async(fn ->
        SippRunner.run_scenario(
          scenario_file: scenario_dir() <> "/uas_hold_resume_bleg.xml",
          remote_host: "127.0.0.1",
          remote_port: bleg_port,
          local_port: bleg_port,
          calls: 1,
          timeout: 35_000
        )
      end)

      Process.sleep(500)

      # Run A-leg with hold/resume
      result = SippRunner.run_scenario(
        scenario_file: scenario_dir() <> "/uac_hold_resume.xml",
        remote_host: "127.0.0.1",
        remote_port: b2bua_port,
        calls: 1,
        timeout: 30_000
      )

      assert result == :ok
      assert Task.await(bleg_task, 35_000) == :ok

      SipStackHelper.stop(stack)
    end
  end

  # ===========================================================================
  # Transfer Tests
  # ===========================================================================

  describe "blind transfer" do
    @tag :skip
    @tag timeout: 45_000
    test "A-leg sends REFER to transfer B-leg to C" do
      # Note: This test requires REFER handling to be implemented.

      b2bua_port = Enum.random(20_000..22_000)
      bleg_port = Enum.random(22_001..24_000)
      target_port = 5080  # Transfer target port (as specified in scenario)

      handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{
        router: TransferRouter,
        bleg_target: "sip:bob@127.0.0.1:#{bleg_port}"
      })
      {:ok, stack} = SipStackHelper.start_udp(handler, port: b2bua_port)

      # Start B-leg (will be disconnected after transfer)
      bleg_task = Task.async(fn ->
        SippRunner.run_scenario(
          scenario_file: scenario_dir() <> "/uas_blind_transfer_bleg.xml",
          remote_host: "127.0.0.1",
          remote_port: bleg_port,
          local_port: bleg_port,
          calls: 1,
          timeout: 30_000
        )
      end)

      # Start transfer target (C)
      target_task = Task.async(fn ->
        SippRunner.run_scenario(
          scenario_file: scenario_dir() <> "/uas_blind_transfer_target.xml",
          remote_host: "127.0.0.1",
          remote_port: target_port,
          local_port: target_port,
          calls: 1,
          timeout: 30_000
        )
      end)

      Process.sleep(500)

      # Run A-leg that initiates transfer
      result = SippRunner.run_scenario(
        scenario_file: scenario_dir() <> "/uac_blind_transfer.xml",
        remote_host: "127.0.0.1",
        remote_port: b2bua_port,
        calls: 1,
        timeout: 25_000
      )

      assert result == :ok

      # B-leg should complete (gets BYE after transfer)
      assert Task.await(bleg_task, 30_000) == :ok

      # Transfer target should complete
      assert Task.await(target_task, 30_000) == :ok

      SipStackHelper.stop(stack)
    end
  end

  describe "inbound REFER" do
    @tag :skip
    @tag timeout: 30_000
    test "B2BUA receives and rejects incoming REFER" do
      # Note: This test verifies REFER rejection.

      b2bua_port = Enum.random(20_000..22_000)

      handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{
        router: ReferRejectRouter
      })
      {:ok, stack} = SipStackHelper.start_udp(handler, port: b2bua_port)

      Process.sleep(100)

      # Run scenario that sends REFER (expects rejection)
      result = SippRunner.run_scenario(
        scenario_file: scenario_dir() <> "/uas_refer_inbound.xml",
        remote_host: "127.0.0.1",
        remote_port: b2bua_port,
        calls: 1,
        timeout: 20_000
      )

      assert result == :ok

      SipStackHelper.stop(stack)
    end
  end

  # ===========================================================================
  # Scenario File Verification Tests
  # ===========================================================================

  describe "scenario files" do
    test "all B2BUA scenario files exist" do
      scenarios = [
        "uac_bridge_basic.xml",
        "uas_bridge_basic_bleg.xml",
        "uac_bridge_reject.xml",
        "uas_bridge_reject_bleg.xml",
        "uac_fork_simultaneous.xml",
        "uas_fork_target_fast.xml",
        "uas_fork_target_slow.xml",
        "uac_hold_resume.xml",
        "uas_hold_resume_bleg.xml",
        "uac_blind_transfer.xml",
        "uas_blind_transfer_bleg.xml",
        "uas_blind_transfer_target.xml",
        "uas_refer_inbound.xml"
      ]

      for scenario <- scenarios do
        path = scenario_dir() <> "/" <> scenario
        assert File.exists?(path), "Scenario file missing: #{path}"
      end
    end

    test "scenario files are valid XML" do
      scenarios = Path.wildcard(scenario_dir() <> "/*.xml")

      for scenario_path <- scenarios do
        content = File.read!(scenario_path)

        # Basic XML validation - should start with XML declaration
        assert String.starts_with?(content, "<?xml"),
               "Invalid XML in #{scenario_path}"

        # Should contain scenario element
        assert String.contains?(content, "<scenario"),
               "Missing scenario element in #{scenario_path}"
      end
    end
  end
end
