defmodule Parrot.Examples.MiniPBX.RouterTest do
  @moduledoc """
  Tests for the Mini PBX Router module.

  Verifies that:
  - Router compiles and routes correctly
  - Pattern matching works for extension patterns
  - Pipelines are defined correctly
  - Registration and presence handlers are set
  """
  use ExUnit.Case, async: true

  alias Parrot.Examples.MiniPBX.Router

  # Ensure the module is loaded before tests run
  setup_all do
    Code.ensure_loaded!(Router)
    :ok
  end

  describe "router configuration" do
    test "returns routes list" do
      routes = Router.__routes__()
      assert is_list(routes)
      assert length(routes) > 0
    end

    test "returns pipelines map" do
      pipelines = Router.__pipelines__()
      assert is_map(pipelines)
    end

    test "returns registration handler" do
      handler = Router.__register_handler__()
      # Should have a registration handler configured
      assert handler == Parrot.Examples.MiniPBX.Registration
    end
  end

  describe "route matching" do
    test "routes 1xxx pattern to Extensions handler" do
      routes = Router.__routes__()
      # Find a route that matches 1xxx pattern
      extension_route = Enum.find(routes, fn route ->
        route.pattern == "1xxx"
      end)

      assert extension_route != nil
      assert extension_route.handler == Parrot.Examples.MiniPBX.Extensions
    end

    test "routes 9xxx pattern to Outbound handler" do
      routes = Router.__routes__()
      outbound_route = Enum.find(routes, fn route ->
        route.pattern == "9xxx"
      end)

      assert outbound_route != nil
      assert outbound_route.handler == Parrot.Examples.MiniPBX.Outbound
    end

    test "routes auto-attendant to 100" do
      routes = Router.__routes__()
      aa_route = Enum.find(routes, fn route ->
        route.pattern == "100"
      end)

      assert aa_route != nil
      assert aa_route.handler == Parrot.Examples.MiniPBX.AutoAttendant
    end
  end

  describe "pipeline configuration" do
    test "defines authenticated pipeline with plugs" do
      pipelines = Router.__pipelines__()
      assert is_map(pipelines)

      auth_pipeline = Map.get(pipelines, :authenticated)
      assert auth_pipeline != nil
      assert is_list(auth_pipeline)
      assert :verify_registration in auth_pipeline
    end
  end
end
