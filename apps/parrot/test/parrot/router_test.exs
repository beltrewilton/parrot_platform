defmodule Parrot.RouterTest do
  use ExUnit.Case, async: true

  alias ParrotSip.Message

  # ---------------------------------------------------------------------------
  # Test Router Modules
  # ---------------------------------------------------------------------------

  defmodule SimpleRouter do
    use Parrot.Router

    invite("*", DefaultHandler)
  end

  defmodule PatternRouter do
    use Parrot.Router

    # Specific patterns first
    invite("1xxx", ExtensionsHandler)
    invite("9~", OutboundHandler)
    # Catch-all last
    invite("*", DefaultHandler)
  end

  defmodule PipelineRouter do
    use Parrot.Router

    pipeline :authenticated do
      plug(:verify_registration)
      plug(:check_acl)
    end

    pipeline :rate_limited do
      plug(:apply_rate_limit)
    end

    scope "/", from_ip: "192.168.1.0/24" do
      pipe_through(:authenticated)
      invite("1xxx", ExtensionsHandler)
      invite("*", InternalDefaultHandler)
    end

    invite("*", RejectHandler)
  end

  defmodule MultiPipelineRouter do
    use Parrot.Router

    pipeline :first do
      plug(:step_one)
    end

    pipeline :second do
      plug(:step_two)
    end

    scope "/" do
      pipe_through([:first, :second])
      invite("*", MultiPipeHandler)
    end
  end

  defmodule IpMatchingRouter do
    use Parrot.Router

    # Single IP CIDR
    scope "/", from_ip: "192.168.1.0/24" do
      invite("*", InternalHandler)
    end

    # List of specific IPs
    scope "/", from_ip: ["10.0.0.1", "10.0.0.2"] do
      invite("*", TrunkHandler)
    end

    # Exact IP match
    scope "/", from_ip: "172.16.0.100" do
      invite("*", SpecificHostHandler)
    end

    invite("*", DefaultHandler)
  end

  defmodule HeaderMatchingRouter do
    use Parrot.Router

    scope "/", header: {"X-Tenant", "acme"} do
      invite("*", AcmeTenantHandler)
    end

    scope "/", header: {"X-Priority", "high"} do
      invite("*", PriorityHandler)
    end

    invite("*", DefaultHandler)
  end

  defmodule FromMatchingRouter do
    use Parrot.Router

    scope "/", from: "*@partner.com" do
      invite("*", PartnerHandler)
    end

    scope "/", from: "admin@*" do
      invite("*", AdminHandler)
    end

    invite("*", DefaultHandler)
  end

  defmodule ToMatchingRouter do
    use Parrot.Router

    scope "/", to: "support@*" do
      invite("*", SupportHandler)
    end

    invite("*", DefaultHandler)
  end

  defmodule CombinedMatchingRouter do
    use Parrot.Router

    scope "/", from_ip: "10.0.0.0/8", header: {"X-Priority", "high"} do
      invite("*", PriorityTrunkHandler)
    end

    invite("*", DefaultHandler)
  end

  defmodule MethodHandlerRouter do
    use Parrot.Router

    invite("*", InviteHandler)
    register(MyRegistrationHandler)
    presence(MyPresenceHandler)
  end

  defmodule NestedScopeRouter do
    use Parrot.Router

    pipeline :outer do
      plug(:outer_plug)
    end

    pipeline :inner do
      plug(:inner_plug)
    end

    scope "/", from_ip: "192.168.0.0/16" do
      pipe_through(:outer)

      scope "/", header: {"X-Department", "sales"} do
        pipe_through(:inner)
        invite("1xxx", SalesExtensionsHandler)
      end

      invite("*", InternalDefaultHandler)
    end

    invite("*", RejectHandler)
  end

  # ---------------------------------------------------------------------------
  # Test: use Parrot.Router macro (Task qax.3.1)
  # ---------------------------------------------------------------------------

  describe "use Parrot.Router" do
    test "defines __routes__/0 function" do
      assert function_exported?(SimpleRouter, :__routes__, 0)
    end

    test "defines __pipelines__/0 function" do
      assert function_exported?(SimpleRouter, :__pipelines__, 0)
    end

    test "defines __register_handler__/0 function" do
      assert function_exported?(MethodHandlerRouter, :__register_handler__, 0)
    end

    test "defines __presence_handler__/0 function" do
      assert function_exported?(MethodHandlerRouter, :__presence_handler__, 0)
    end

    test "defines dispatch/1 function" do
      assert function_exported?(SimpleRouter, :dispatch, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Test: pipeline/2 macro (Task qax.3.2)
  # ---------------------------------------------------------------------------

  describe "pipeline/2 macro" do
    test "defines named pipeline with plugs" do
      pipelines = PipelineRouter.__pipelines__()
      assert Map.has_key?(pipelines, :authenticated)
      assert pipelines[:authenticated] == [:verify_registration, :check_acl]
    end

    test "supports multiple pipelines" do
      pipelines = PipelineRouter.__pipelines__()
      assert Map.has_key?(pipelines, :authenticated)
      assert Map.has_key?(pipelines, :rate_limited)
    end

    test "preserves plug order" do
      pipelines = PipelineRouter.__pipelines__()
      assert pipelines[:authenticated] == [:verify_registration, :check_acl]
    end
  end

  # ---------------------------------------------------------------------------
  # Test: scope/2 macro (Task qax.3.3)
  # ---------------------------------------------------------------------------

  describe "scope/2 macro" do
    test "groups routes with from_ip matcher" do
      routes = PipelineRouter.__routes__()
      # First route should have from_ip scope condition
      scoped_route = Enum.find(routes, fn r -> r.handler == ExtensionsHandler end)
      assert scoped_route != nil
      assert scoped_route.scope[:from_ip] == "192.168.1.0/24"
    end

    test "routes outside scope have no scope conditions" do
      routes = PipelineRouter.__routes__()
      reject_route = Enum.find(routes, fn r -> r.handler == RejectHandler end)
      assert reject_route != nil
      assert reject_route.scope == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Test: pipe_through/1 macro (Task qax.3.4)
  # ---------------------------------------------------------------------------

  describe "pipe_through/1 macro" do
    test "associates pipeline with routes in scope" do
      routes = PipelineRouter.__routes__()
      extensions_route = Enum.find(routes, fn r -> r.handler == ExtensionsHandler end)
      assert extensions_route != nil
      assert :authenticated in extensions_route.pipelines
    end

    test "supports multiple pipelines" do
      routes = MultiPipelineRouter.__routes__()
      route = Enum.find(routes, fn r -> r.handler == MultiPipeHandler end)
      assert route != nil
      assert :first in route.pipelines
      assert :second in route.pipelines
    end

    test "routes outside scope have no pipelines" do
      routes = PipelineRouter.__routes__()
      reject_route = Enum.find(routes, fn r -> r.handler == RejectHandler end)
      assert reject_route != nil
      assert reject_route.pipelines == []
    end
  end

  # ---------------------------------------------------------------------------
  # Test: invite/2 macro (Task qax.3.5)
  # ---------------------------------------------------------------------------

  describe "invite/2 macro" do
    test "creates route for catch-all pattern" do
      routes = SimpleRouter.__routes__()
      assert length(routes) == 1
      [route] = routes
      assert route.pattern == "*"
      assert route.handler == DefaultHandler
    end

    test "creates routes for multiple patterns" do
      routes = PatternRouter.__routes__()
      assert length(routes) == 3

      patterns = Enum.map(routes, & &1.pattern)
      assert "1xxx" in patterns
      assert "9~" in patterns
      assert "*" in patterns
    end

    test "preserves route order (first defined = first checked)" do
      routes = PatternRouter.__routes__()
      [first, second, third] = routes
      assert first.pattern == "1xxx"
      assert second.pattern == "9~"
      assert third.pattern == "*"
    end
  end

  # ---------------------------------------------------------------------------
  # Test: register/1 and presence/1 macros (Task qax.3.6)
  # ---------------------------------------------------------------------------

  describe "register/1 macro" do
    test "sets the registration handler" do
      assert MethodHandlerRouter.__register_handler__() == MyRegistrationHandler
    end
  end

  describe "presence/1 macro" do
    test "sets the presence handler" do
      assert MethodHandlerRouter.__presence_handler__() == MyPresenceHandler
    end
  end

  # ---------------------------------------------------------------------------
  # Test: IP matching with CIDR support (Task qax.3.7)
  # ---------------------------------------------------------------------------

  describe "IP matching with CIDR" do
    test "matches IP within CIDR range" do
      message = build_invite("100", source_ip: {192, 168, 1, 50})
      assert {:ok, InternalHandler, opts} = IpMatchingRouter.dispatch(message)
      assert opts[:pipelines] == []
    end

    test "does not match IP outside CIDR range" do
      message = build_invite("100", source_ip: {192, 168, 2, 50})
      # Should fall through to DefaultHandler
      assert {:ok, DefaultHandler, _opts} = IpMatchingRouter.dispatch(message)
    end

    test "matches IP in list of IPs" do
      message = build_invite("100", source_ip: {10, 0, 0, 1})
      assert {:ok, TrunkHandler, _opts} = IpMatchingRouter.dispatch(message)
    end

    test "matches second IP in list" do
      message = build_invite("100", source_ip: {10, 0, 0, 2})
      assert {:ok, TrunkHandler, _opts} = IpMatchingRouter.dispatch(message)
    end

    test "does not match IP not in list" do
      message = build_invite("100", source_ip: {10, 0, 0, 3})
      assert {:ok, DefaultHandler, _opts} = IpMatchingRouter.dispatch(message)
    end

    test "matches exact IP (implicit /32)" do
      message = build_invite("100", source_ip: {172, 16, 0, 100})
      assert {:ok, SpecificHostHandler, _opts} = IpMatchingRouter.dispatch(message)
    end

    test "handles missing source gracefully" do
      message = build_invite("100", source_ip: nil)
      # Should fall through to DefaultHandler when source is missing
      assert {:ok, DefaultHandler, _opts} = IpMatchingRouter.dispatch(message)
    end
  end

  # ---------------------------------------------------------------------------
  # Test: Route dispatch function (Task qax.3.8)
  # ---------------------------------------------------------------------------

  describe "dispatch/1" do
    test "returns handler for matching route" do
      message = build_invite("100")
      assert {:ok, DefaultHandler, _opts} = SimpleRouter.dispatch(message)
    end

    test "returns pipelines to run" do
      message = build_invite("1234", source_ip: {192, 168, 1, 10})
      assert {:ok, ExtensionsHandler, opts} = PipelineRouter.dispatch(message)
      assert :authenticated in opts[:pipelines]
    end

    test "returns assigns with matched pattern" do
      message = build_invite("1234")
      assert {:ok, ExtensionsHandler, opts} = PatternRouter.dispatch(message)
      assert opts[:assigns][:matched_pattern] == "1xxx"
    end

    test "matches pattern 1xxx for 4-digit extension starting with 1" do
      message = build_invite("1234")
      assert {:ok, ExtensionsHandler, _opts} = PatternRouter.dispatch(message)
    end

    test "does not match 1xxx for 3-digit number" do
      message = build_invite("123")
      assert {:ok, DefaultHandler, _opts} = PatternRouter.dispatch(message)
    end

    test "does not match 1xxx for 5-digit number" do
      message = build_invite("12345")
      assert {:ok, DefaultHandler, _opts} = PatternRouter.dispatch(message)
    end

    test "matches pattern 9~ for any string starting with 9" do
      message = build_invite("9")
      assert {:ok, OutboundHandler, _opts} = PatternRouter.dispatch(message)
    end

    test "matches pattern 9~ for longer string starting with 9" do
      message = build_invite("918005551234")
      assert {:ok, OutboundHandler, _opts} = PatternRouter.dispatch(message)
    end

    test "catches all with * pattern" do
      message = build_invite("anything")
      assert {:ok, DefaultHandler, _opts} = PatternRouter.dispatch(message)
    end

    test "returns :no_match for non-INVITE requests" do
      message = %Message{
        type: :request,
        method: :register,
        request_uri: "sip:registrar@example.com"
      }

      assert {:no_match, :method_not_routed} = SimpleRouter.dispatch(message)
    end
  end

  describe "dispatch with header matching" do
    test "matches route by header value" do
      message = build_invite("100", headers: %{"x-tenant" => "acme"})
      assert {:ok, AcmeTenantHandler, _opts} = HeaderMatchingRouter.dispatch(message)
    end

    test "does not match with different header value" do
      message = build_invite("100", headers: %{"x-tenant" => "other"})
      assert {:ok, DefaultHandler, _opts} = HeaderMatchingRouter.dispatch(message)
    end

    test "does not match when header is missing" do
      message = build_invite("100")
      assert {:ok, DefaultHandler, _opts} = HeaderMatchingRouter.dispatch(message)
    end
  end

  describe "dispatch with from URI matching" do
    test "matches route by from domain pattern" do
      message = build_invite("100", from: "sip:user@partner.com")
      assert {:ok, PartnerHandler, _opts} = FromMatchingRouter.dispatch(message)
    end

    test "matches route by from user pattern" do
      message = build_invite("100", from: "sip:admin@example.com")
      assert {:ok, AdminHandler, _opts} = FromMatchingRouter.dispatch(message)
    end

    test "does not match with different from" do
      message = build_invite("100", from: "sip:user@other.com")
      assert {:ok, DefaultHandler, _opts} = FromMatchingRouter.dispatch(message)
    end
  end

  describe "dispatch with to URI matching" do
    test "matches route by to user pattern" do
      message = build_invite("support", to: "sip:support@example.com")
      assert {:ok, SupportHandler, _opts} = ToMatchingRouter.dispatch(message)
    end

    test "does not match with different to user" do
      message = build_invite("sales", to: "sip:sales@example.com")
      assert {:ok, DefaultHandler, _opts} = ToMatchingRouter.dispatch(message)
    end
  end

  describe "dispatch with combined matchers" do
    test "matches when all conditions are met" do
      message =
        build_invite("100",
          source_ip: {10, 0, 0, 50},
          headers: %{"x-priority" => "high"}
        )

      assert {:ok, PriorityTrunkHandler, _opts} = CombinedMatchingRouter.dispatch(message)
    end

    test "does not match when IP fails" do
      message =
        build_invite("100",
          source_ip: {192, 168, 1, 1},
          headers: %{"x-priority" => "high"}
        )

      assert {:ok, DefaultHandler, _opts} = CombinedMatchingRouter.dispatch(message)
    end

    test "does not match when header fails" do
      message =
        build_invite("100",
          source_ip: {10, 0, 0, 50},
          headers: %{"x-priority" => "low"}
        )

      assert {:ok, DefaultHandler, _opts} = CombinedMatchingRouter.dispatch(message)
    end
  end

  describe "dispatch with nested scopes" do
    test "inherits outer scope conditions and pipelines" do
      message =
        build_invite("1234",
          source_ip: {192, 168, 1, 1},
          headers: %{"x-department" => "sales"}
        )

      assert {:ok, SalesExtensionsHandler, opts} = NestedScopeRouter.dispatch(message)
      # Should have both outer and inner pipelines
      assert :outer in opts[:pipelines]
      assert :inner in opts[:pipelines]
    end

    test "inner scope requires both conditions" do
      # Has IP but not header
      message = build_invite("1234", source_ip: {192, 168, 1, 1})
      assert {:ok, InternalDefaultHandler, opts} = NestedScopeRouter.dispatch(message)
      assert :outer in opts[:pipelines]
      refute :inner in opts[:pipelines]
    end

    test "falls through when outer scope fails" do
      # Wrong IP
      message =
        build_invite("1234",
          source_ip: {10, 0, 0, 1},
          headers: %{"x-department" => "sales"}
        )

      assert {:ok, RejectHandler, _opts} = NestedScopeRouter.dispatch(message)
    end
  end

  # ---------------------------------------------------------------------------
  # Test Helpers
  # ---------------------------------------------------------------------------

  defp build_invite(user_part, opts \\ []) do
    source_ip = Keyword.get(opts, :source_ip, {127, 0, 0, 1})
    headers = Keyword.get(opts, :headers, %{})
    from = Keyword.get(opts, :from, "sip:caller@example.com")
    to = Keyword.get(opts, :to, "sip:#{user_part}@example.com")

    source =
      if source_ip do
        %{ip: source_ip, port: 5060}
      else
        nil
      end

    # Parse from/to URIs to get the user/domain parts
    from_struct = parse_uri_to_from(from)
    to_struct = parse_uri_to_to(to)

    %Message{
      type: :request,
      method: :invite,
      request_uri: to,
      source: source,
      from: from_struct,
      to: to_struct,
      other_headers: headers
    }
  end

  defp parse_uri_to_from(uri) do
    case ParrotSip.Uri.parse(uri) do
      {:ok, parsed_uri} ->
        %ParrotSip.Headers.From{
          display_name: nil,
          uri: parsed_uri,
          parameters: %{}
        }

      {:error, _} ->
        %ParrotSip.Headers.From{uri: uri, parameters: %{}}
    end
  end

  defp parse_uri_to_to(uri) do
    case ParrotSip.Uri.parse(uri) do
      {:ok, parsed_uri} ->
        %ParrotSip.Headers.To{
          display_name: nil,
          uri: parsed_uri,
          parameters: %{}
        }

      {:error, _} ->
        %ParrotSip.Headers.To{uri: uri, parameters: %{}}
    end
  end
end
