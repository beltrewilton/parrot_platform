defmodule ParrotSip.CDR.HandlerRegistrationTest do
  @moduledoc """
  Tests for CDR handler registration functions in ParrotSip.CDR module.
  """
  use ExUnit.Case, async: false

  alias ParrotSip.CDR

  @moduletag :cdr

  # Test handler that initializes successfully
  defmodule SuccessHandler do
    @moduledoc false
    @behaviour ParrotSip.CDR.Handler

    @impl true
    def init(args) do
      {:ok, Map.new(args)}
    end

    @impl true
    def handle_cdr(_cdr, _state), do: :ok
  end

  # Test handler that fails during init
  defmodule FailingInitHandler do
    @moduledoc false
    @behaviour ParrotSip.CDR.Handler

    @impl true
    def init(_args) do
      {:error, :init_failure}
    end

    @impl true
    def handle_cdr(_cdr, _state), do: :ok
  end

  # Test handler without init/1 (uses default)
  defmodule NoInitHandler do
    @moduledoc false
    @behaviour ParrotSip.CDR.Handler

    @impl true
    def handle_cdr(_cdr, _state), do: :ok
  end

  # Test handler that transforms args in init
  defmodule TransformingHandler do
    @moduledoc false
    @behaviour ParrotSip.CDR.Handler

    @impl true
    def init(args) do
      # Transform keyword list into a map with additional fields
      state = %{
        config: Map.new(args),
        initialized_at: DateTime.utc_now(),
        call_count: 0
      }

      {:ok, state}
    end

    @impl true
    def handle_cdr(_cdr, _state), do: :ok
  end

  setup do
    # Ensure application is started (CDR.Registry needs to be running)
    Application.ensure_all_started(:parrot_sip)
    # Clear handlers before each test
    CDR.clear_handlers()
    :ok
  end

  describe "register_handler/2" do
    test "registers a handler with successful init" do
      assert :ok = CDR.register_handler(SuccessHandler, foo: "bar")

      handlers = CDR.list_handlers()
      assert length(handlers) == 1
      assert {SuccessHandler, %{foo: "bar"}} in handlers
    end

    test "registers handler that transforms args in init" do
      assert :ok = CDR.register_handler(TransformingHandler, key: "value")

      handlers = CDR.list_handlers()
      assert length(handlers) == 1
      [{TransformingHandler, state}] = handlers
      assert state.config == %{key: "value"}
      assert state.call_count == 0
      assert %DateTime{} = state.initialized_at
    end

    test "uses default init when handler doesn't implement init/1" do
      args = %{some: "state"}
      assert :ok = CDR.register_handler(NoInitHandler, args)

      handlers = CDR.list_handlers()
      assert {NoInitHandler, %{some: "state"}} in handlers
    end

    test "returns error when init fails" do
      assert {:error, :init_failed, :init_failure} =
               CDR.register_handler(FailingInitHandler, [])

      # Handler should not be registered
      assert CDR.list_handlers() == []
    end

    test "returns error when handler already registered" do
      assert :ok = CDR.register_handler(SuccessHandler, first: true)
      assert {:error, :already_registered} = CDR.register_handler(SuccessHandler, second: true)

      # Original registration should be preserved
      handlers = CDR.list_handlers()
      assert length(handlers) == 1
      assert {SuccessHandler, %{first: true}} in handlers
    end

    test "registers multiple different handlers" do
      assert :ok = CDR.register_handler(SuccessHandler, id: 1)
      assert :ok = CDR.register_handler(TransformingHandler, id: 2)

      handlers = CDR.list_handlers()
      assert length(handlers) == 2

      modules = Enum.map(handlers, fn {mod, _state} -> mod end)
      assert SuccessHandler in modules
      assert TransformingHandler in modules
    end
  end

  describe "unregister_handler/1" do
    test "removes registered handler" do
      CDR.register_handler(SuccessHandler, [])
      assert length(CDR.list_handlers()) == 1

      assert :ok = CDR.unregister_handler(SuccessHandler)
      assert CDR.list_handlers() == []
    end

    test "is idempotent - returns :ok for non-registered handler" do
      assert :ok = CDR.unregister_handler(SuccessHandler)
      assert :ok = CDR.unregister_handler(SuccessHandler)
    end

    test "only removes specified handler" do
      CDR.register_handler(SuccessHandler, id: 1)
      CDR.register_handler(TransformingHandler, id: 2)
      assert length(CDR.list_handlers()) == 2

      assert :ok = CDR.unregister_handler(SuccessHandler)

      handlers = CDR.list_handlers()
      assert length(handlers) == 1
      assert {TransformingHandler, _state} = List.first(handlers)
    end
  end

  describe "list_handlers/0" do
    test "returns empty list when no handlers registered" do
      assert CDR.list_handlers() == []
    end

    test "returns all registered handlers with their state" do
      CDR.register_handler(SuccessHandler, config: "a")
      CDR.register_handler(TransformingHandler, config: "b")

      handlers = CDR.list_handlers()
      assert length(handlers) == 2

      # Verify both handlers are present
      handler_map = Map.new(handlers)
      assert handler_map[SuccessHandler] == %{config: "a"}
      assert handler_map[TransformingHandler].config == %{config: "b"}
    end
  end

  describe "clear_handlers/0" do
    test "removes all registered handlers" do
      CDR.register_handler(SuccessHandler, [])
      CDR.register_handler(TransformingHandler, [])
      assert length(CDR.list_handlers()) == 2

      assert :ok = CDR.clear_handlers()
      assert CDR.list_handlers() == []
    end

    test "is idempotent on empty registry" do
      assert :ok = CDR.clear_handlers()
      assert :ok = CDR.clear_handlers()
      assert CDR.list_handlers() == []
    end
  end
end
