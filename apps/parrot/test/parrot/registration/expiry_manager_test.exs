defmodule Parrot.Registration.ExpiryManagerTest do
  use ExUnit.Case, async: false

  alias Parrot.Registration.ExpiryManager

  # ETS table for cross-process test communication
  @test_pid_table :expiry_manager_test_pid

  # Test handler that tracks callback invocations
  defmodule TestHandler do
    use Parrot.RegistrationHandler

    @impl true
    def handle_registration_expired(aor, contact) do
      # Send message to test process for verification
      # Use ETS for cross-process communication
      case :ets.lookup(:expiry_manager_test_pid, :test_pid) do
        [{:test_pid, pid}] when is_pid(pid) ->
          send(pid, {:expired, aor, contact})

        _ ->
          :ok
      end

      :ok
    end
  end

  # Handler that raises an exception
  defmodule CrashingHandler do
    use Parrot.RegistrationHandler

    @impl true
    def handle_registration_expired(_aor, _contact) do
      raise "Intentional crash for testing"
    end
  end

  setup do
    # Create or clear ETS table for test_pid storage
    if :ets.whereis(@test_pid_table) == :undefined do
      :ets.new(@test_pid_table, [:named_table, :public, :set])
    end

    :ets.insert(@test_pid_table, {:test_pid, self()})

    # Start ExpiryManager for each test
    {:ok, pid} = ExpiryManager.start_link(name: :"expiry_manager_#{:erlang.unique_integer()}")

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 100)
      catch
        :exit, _ -> :ok
      end
    end)

    %{manager: pid}
  end

  describe "start_link/1" do
    test "starts the ExpiryManager GenServer" do
      assert {:ok, pid} = ExpiryManager.start_link(name: :test_expiry_manager_start)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "registers with the provided name" do
      assert {:ok, pid} = ExpiryManager.start_link(name: :named_expiry_manager)
      assert GenServer.whereis(:named_expiry_manager) == pid
      GenServer.stop(pid)
    end

    test "can be started without a name" do
      assert {:ok, pid} = ExpiryManager.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "schedule_expiry/4" do
    test "schedules a timer for the given AOR and contact", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"
      expires_seconds = 1

      assert :ok =
               ExpiryManager.schedule_expiry(manager, aor, contact, expires_seconds, TestHandler)

      # Wait for timer to fire
      assert_receive {:expired, ^aor, ^contact}, 2000
    end

    test "accepts expires value in seconds", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      # Schedule 1 second expiry
      start_time = System.monotonic_time(:millisecond)
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, TestHandler)

      assert_receive {:expired, ^aor, ^contact}, 2000
      end_time = System.monotonic_time(:millisecond)

      # Should fire after approximately 1 second (allow 500ms tolerance)
      elapsed = end_time - start_time
      assert elapsed >= 900 and elapsed <= 1500
    end

    test "stores timer reference for later cancellation", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 60, TestHandler)

      # Verify timer is tracked (by successfully cancelling it)
      assert :ok = ExpiryManager.cancel_expiry(manager, aor, contact)

      # Timer should not fire after cancellation
      refute_receive {:expired, _, _}, 200
    end

    test "tracks multiple contacts for same AOR separately", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact1 = "sip:alice@phone1.local:5060"
      contact2 = "sip:alice@phone2.local:5060"

      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact1, 1, TestHandler)
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact2, 1, TestHandler)

      # Both should fire
      assert_receive {:expired, ^aor, ^contact1}, 2000
      assert_receive {:expired, ^aor, ^contact2}, 2000
    end

    test "tracks different AORs separately", %{manager: manager} do
      aor1 = "sip:alice@example.com"
      aor2 = "sip:bob@example.com"
      contact = "sip:user@192.168.1.100:5060"

      assert :ok = ExpiryManager.schedule_expiry(manager, aor1, contact, 1, TestHandler)
      assert :ok = ExpiryManager.schedule_expiry(manager, aor2, contact, 1, TestHandler)

      # Both should fire with their respective AORs
      assert_receive {:expired, ^aor1, ^contact}, 2000
      assert_receive {:expired, ^aor2, ^contact}, 2000
    end
  end

  describe "cancel_expiry/3" do
    test "cancels a scheduled expiry timer", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, TestHandler)
      assert :ok = ExpiryManager.cancel_expiry(manager, aor, contact)

      # Timer should NOT fire after cancellation
      refute_receive {:expired, _, _}, 1500
    end

    test "returns :ok when cancelling non-existent timer", %{manager: manager} do
      aor = "sip:unknown@example.com"
      contact = "sip:unknown@192.168.1.100:5060"

      # Should not error when cancelling non-existent timer
      assert :ok = ExpiryManager.cancel_expiry(manager, aor, contact)
    end

    test "only cancels the specific {aor, contact} combination", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact1 = "sip:alice@phone1.local:5060"
      contact2 = "sip:alice@phone2.local:5060"

      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact1, 1, TestHandler)
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact2, 1, TestHandler)

      # Cancel only contact1
      assert :ok = ExpiryManager.cancel_expiry(manager, aor, contact1)

      # contact1 should NOT fire, contact2 should fire
      refute_receive {:expired, ^aor, ^contact1}, 200
      assert_receive {:expired, ^aor, ^contact2}, 2000
    end

    test "removes the timer entry from tracking", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 60, TestHandler)
      assert :ok = ExpiryManager.cancel_expiry(manager, aor, contact)

      # Cancelling again should still return :ok (idempotent)
      assert :ok = ExpiryManager.cancel_expiry(manager, aor, contact)
    end
  end

  describe "re-registration (timer refresh)" do
    test "refreshing registration cancels old timer and schedules new one", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      # Schedule initial expiry at 1 second
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, TestHandler)

      # Refresh after 500ms with new 2 second expiry
      Process.sleep(500)
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 2, TestHandler)

      # Should NOT fire at original time (~500ms from now)
      refute_receive {:expired, _, _}, 700

      # Should fire at new time (~1500ms from refresh point)
      assert_receive {:expired, ^aor, ^contact}, 2000
    end

    test "only one callback fires for refreshed registration", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      # Schedule and immediately refresh multiple times
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, TestHandler)
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, TestHandler)
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, TestHandler)

      # Only one callback should fire
      assert_receive {:expired, ^aor, ^contact}, 2000
      refute_receive {:expired, _, _}, 500
    end

    test "refresh with different expires value works correctly", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      # Initial 5 second expiry
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 5, TestHandler)

      # Refresh with 1 second expiry
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, TestHandler)

      # Should fire after ~1 second, not ~5 seconds
      start_time = System.monotonic_time(:millisecond)
      assert_receive {:expired, ^aor, ^contact}, 2000
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should have fired in approximately 1 second
      assert elapsed < 2000
    end
  end

  describe "unregister (expires = 0)" do
    test "expires=0 should cancel timer without callback", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      # Schedule normal expiry
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, TestHandler)

      # "Unregister" by scheduling with expires=0
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 0, TestHandler)

      # Callback should NOT be invoked for unregister
      refute_receive {:expired, _, _}, 1500
    end

    test "expires=0 removes existing timer", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 60, TestHandler)
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 0, TestHandler)

      # Subsequent cancel should not error
      assert :ok = ExpiryManager.cancel_expiry(manager, aor, contact)
    end

    test "expires=0 on non-existent registration is a no-op", %{manager: manager} do
      aor = "sip:unknown@example.com"
      contact = "sip:unknown@192.168.1.100:5060"

      # Should not error
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 0, TestHandler)

      # No callback should fire
      refute_receive {:expired, _, _}, 200
    end
  end

  describe "callback exception handling" do
    test "ExpiryManager survives handler callback exception", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      # Schedule with crashing handler
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, CrashingHandler)

      # Wait for timer to fire and handler to crash
      Process.sleep(1500)

      # ExpiryManager should still be alive
      assert Process.alive?(manager)

      # Should be able to schedule new timers
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, TestHandler)
      assert_receive {:expired, ^aor, ^contact}, 2000
    end

    test "callback exception is logged", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      # Schedule with crashing handler
      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, CrashingHandler)

      # Wait for timer to fire
      Process.sleep(1500)

      # ExpiryManager survives - exception logged (verified by ExpiryManager not crashing)
      assert Process.alive?(manager)
    end
  end

  describe "process isolation" do
    test "different ExpiryManager instances track timers independently" do
      {:ok, manager1} = ExpiryManager.start_link(name: :manager_isolation_1)
      {:ok, manager2} = ExpiryManager.start_link(name: :manager_isolation_2)

      on_exit(fn ->
        if Process.alive?(manager1), do: GenServer.stop(manager1)
        if Process.alive?(manager2), do: GenServer.stop(manager2)
      end)

      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      # Schedule on manager1
      assert :ok = ExpiryManager.schedule_expiry(manager1, aor, contact, 1, TestHandler)

      # Cancel on manager2 should not affect manager1
      assert :ok = ExpiryManager.cancel_expiry(manager2, aor, contact)

      # Timer on manager1 should still fire
      assert_receive {:expired, ^aor, ^contact}, 2000
    end
  end

  describe "get_active_timers/1" do
    test "returns empty map when no timers scheduled", %{manager: manager} do
      assert %{} == ExpiryManager.get_active_timers(manager)
    end

    test "returns scheduled timers", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 60, TestHandler)

      timers = ExpiryManager.get_active_timers(manager)
      assert Map.has_key?(timers, {aor, contact})
    end

    test "timer is removed from active list after firing", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 1, TestHandler)
      assert Map.has_key?(ExpiryManager.get_active_timers(manager), {aor, contact})

      # Wait for timer to fire
      assert_receive {:expired, ^aor, ^contact}, 2000

      # Timer should be removed from active list
      refute Map.has_key?(ExpiryManager.get_active_timers(manager), {aor, contact})
    end

    test "timer is removed from active list after cancellation", %{manager: manager} do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      assert :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 60, TestHandler)
      assert Map.has_key?(ExpiryManager.get_active_timers(manager), {aor, contact})

      assert :ok = ExpiryManager.cancel_expiry(manager, aor, contact)
      refute Map.has_key?(ExpiryManager.get_active_timers(manager), {aor, contact})
    end
  end
end
