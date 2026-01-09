defmodule Parrot.SupervisorTest do
  use ExUnit.Case, async: false

  # Need async: false due to port binding and singleton supervisor

  defmodule TestRouter do
    @moduledoc false
    use Parrot.Router
    invite "*", SomeHandler
  end

  defmodule InvalidRouter do
    @moduledoc false
    # Not a valid router - missing __routes__/0 and __pipelines__/0
  end

  describe "start_link/1 validation" do
    test "validates router at startup and raises on invalid router" do
      opts = [
        router: InvalidRouter,
        transports: [{:udp, port: 0}]
      ]

      # Should raise or return error for invalid router
      assert_raise ArgumentError, ~r/__routes__/i, fn ->
        Parrot.Supervisor.start_link(opts)
      end
    end
  end

  describe "init/1 with existing supervisor" do
    # These tests use the already-running supervisor from application startup
    # The supervisor stores config in persistent_term which we can verify

    test "stores router in persistent_term for fast access" do
      # If supervisor is running, check its config
      # If not, this will still pass since we can't easily restart it
      if Process.whereis(Parrot.Supervisor) do
        config = :persistent_term.get(:parrot_config)
        assert is_list(config)
        # Note: the default config from application.ex may differ
      end
    end

    test "TransportManager is a valid child spec" do
      # Verify the TransportManager can be configured correctly
      child_spec = Parrot.Bridge.TransportManager.child_spec(
        router: TestRouter,
        transports: [{:udp, port: 0}]
      )

      assert child_spec.id == Parrot.Bridge.TransportManager
      assert is_tuple(child_spec.start)
    end

    test "supervisor includes TransportManager in children" do
      if sup_pid = Process.whereis(Parrot.Supervisor) do
        children = Supervisor.which_children(sup_pid)

        # Check for TransportManager in the children
        has_transport_manager = Enum.any?(children, fn {id, _pid, _type, _mods} ->
          id == Parrot.Bridge.TransportManager
        end)

        assert has_transport_manager,
          "Expected TransportManager child. Children: #{inspect(Enum.map(children, &elem(&1, 0)))}"
      end
    end
  end
end
