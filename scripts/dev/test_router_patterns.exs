# Router Pattern Matching Test Script
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_router_patterns.exs
#
# This script demonstrates ALL router features:
# - Pattern matching: "1xxx" (digit), "9~" (any chars), "*" (catch-all)
# - Scope matching with from_ip, from, to, header options
# - Pipeline definitions with plug
# - Multiple routes with priority ordering
# - Route logging to show which handler matched
#
# Test scenarios:
# - Dial 1xxx (e.g., 1234) -> ExtensionHandler
# - Dial 9xxx (e.g., 9123456) -> OutboundHandler
# - Dial * (anything else) -> DefaultHandler
# - From specific IP (192.168.1.x) -> PrivilegedHandler (higher priority)

require Logger

# =============================================================================
# Handler Modules - Each handler represents a different call handling scenario
# =============================================================================

defmodule ExtensionHandler do
  @moduledoc """
  Handles internal extension calls (pattern: 1xxx - exactly 4 digits starting with 1).
  Example: 1234, 1000, 1999
  """
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("""
    [ExtensionHandler] MATCHED!
      Pattern: 1xxx (internal extension)
      To: #{call.to}
      From: #{call.from}
    """)

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[ExtensionHandler] Playback complete: #{file}")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[ExtensionHandler] Call ended - internal extension")
    {:noreply, call}
  end
end

defmodule OutboundHandler do
  @moduledoc """
  Handles outbound calls (pattern: 9~ - starts with 9, any length).
  Example: 9123456789, 9011123456789
  """
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("""
    [OutboundHandler] MATCHED!
      Pattern: 9~ (outbound dialing)
      To: #{call.to}
      From: #{call.from}
    """)

    # In a real scenario, we might strip the 9 and bridge to external gateway
    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[OutboundHandler] Playback complete: #{file}")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[OutboundHandler] Call ended - outbound call")
    {:noreply, call}
  end
end

defmodule PrivilegedHandler do
  @moduledoc """
  Handles calls from privileged IPs (scope: from_ip 192.168.1.0/24).
  These calls get special treatment regardless of what number they dial.
  """
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("""
    [PrivilegedHandler] MATCHED!
      Scope: from_ip 192.168.1.0/24 (privileged network)
      To: #{call.to}
      From: #{call.from}
      Note: Privileged handler has higher priority due to route ordering
    """)

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[PrivilegedHandler] Playback complete: #{file}")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[PrivilegedHandler] Call ended - privileged caller")
    {:noreply, call}
  end
end

defmodule PartnerDomainHandler do
  @moduledoc """
  Handles calls from partner domain (scope: from "*@partner.example.com").
  """
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("""
    [PartnerDomainHandler] MATCHED!
      Scope: from *@partner.example.com (partner domain)
      To: #{call.to}
      From: #{call.from}
    """)

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[PartnerDomainHandler] Playback complete: #{file}")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[PartnerDomainHandler] Call ended - partner caller")
    {:noreply, call}
  end
end

defmodule EmergencyHandler do
  @moduledoc """
  Handles emergency calls (pattern: 911).
  Exact pattern match takes precedence over wildcard patterns.
  """
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("""
    [EmergencyHandler] MATCHED!
      Pattern: 911 (exact match - emergency services)
      To: #{call.to}
      From: #{call.from}
      PRIORITY: Emergency calls are processed immediately!
    """)

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[EmergencyHandler] Playback complete: #{file}")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[EmergencyHandler] Call ended - emergency call")
    {:noreply, call}
  end
end

defmodule OperatorHandler do
  @moduledoc """
  Handles operator calls (pattern: 0).
  """
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("""
    [OperatorHandler] MATCHED!
      Pattern: 0 (exact match - operator)
      To: #{call.to}
      From: #{call.from}
    """)

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[OperatorHandler] Playback complete: #{file}")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[OperatorHandler] Call ended - operator call")
    {:noreply, call}
  end
end

defmodule DefaultHandler do
  @moduledoc """
  Catch-all handler for any call that doesn't match other patterns.
  Pattern: "*" matches everything.
  """
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("""
    [DefaultHandler] MATCHED!
      Pattern: * (catch-all default handler)
      To: #{call.to}
      From: #{call.from}
      Note: This is the fallback for unmatched patterns
    """)

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[DefaultHandler] Playback complete: #{file}")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[DefaultHandler] Call ended - default routing")
    {:noreply, call}
  end
end

# =============================================================================
# Router Definition - Demonstrates all router features
# =============================================================================

defmodule TestRouterPatterns do
  @moduledoc """
  Comprehensive router demonstrating all pattern matching features.

  ## Route Priority (order matters!)

  Routes are evaluated top-to-bottom. First match wins.
  This allows us to:
  1. Put specific IP-based rules first (privileged access)
  2. Put specific domain-based rules next (partner access)
  3. Put exact matches before wildcards (911 before 9~)
  4. Put pattern-based rules in order of specificity
  5. Put catch-all (*) last

  ## Features Demonstrated

  - Scopes with from_ip (CIDR notation)
  - Scopes with from URI patterns
  - Pipelines with plugs
  - Exact pattern matching (911, 0)
  - Digit placeholder patterns (1xxx)
  - Wildcard suffix patterns (9~)
  - Catch-all patterns (*)
  """
  use Parrot.Router

  # ---------------------------------------------------------------------------
  # Pipeline Definitions
  # ---------------------------------------------------------------------------

  # Authentication pipeline - would verify caller credentials
  pipeline :authenticated do
    plug :verify_registration
    plug :check_acl
  end

  # Logging pipeline - for audit trails
  pipeline :logged do
    plug :log_call
  end

  # Rate limiting pipeline
  pipeline :rate_limited do
    plug :check_rate_limit
  end

  # ---------------------------------------------------------------------------
  # Scoped Routes - Higher Priority (checked first)
  # ---------------------------------------------------------------------------

  # Privileged network scope - calls from internal network get special treatment
  # Note: This scope is checked first, so 192.168.1.x callers bypass normal routing
  scope "/", from_ip: "192.168.1.0/24" do
    pipe_through [:authenticated, :logged]

    # All calls from privileged network go to PrivilegedHandler
    invite "*", PrivilegedHandler
  end

  # Partner domain scope - calls from partner.example.com domain
  scope "/", from: "*@partner.example.com" do
    pipe_through :logged

    invite "*", PartnerDomainHandler
  end

  # ---------------------------------------------------------------------------
  # Pattern-Based Routes - Standard Priority
  # ---------------------------------------------------------------------------

  # Emergency services - exact match, highest priority after scoped routes
  invite "911", EmergencyHandler

  # Operator - exact match
  invite "0", OperatorHandler

  # Internal extensions - 4-digit numbers starting with 1
  # Examples: 1000, 1234, 1999
  invite "1xxx", ExtensionHandler

  # Outbound dialing - starts with 9, any length
  # Examples: 9123456789, 911234567890 (note: 911 won't match here due to order)
  invite "9~", OutboundHandler

  # ---------------------------------------------------------------------------
  # Catch-All Route - Lowest Priority (checked last)
  # ---------------------------------------------------------------------------

  # Default handler for anything not matched above
  invite "*", DefaultHandler
end

# =============================================================================
# Main Script - Start the server
# =============================================================================

IO.puts("""
================================================================================
Router Pattern Matching Test Server
================================================================================

Starting server on port 5080...

PATTERN MATCHING RULES (in priority order):
------------------------------------------

1. SCOPE: from_ip 192.168.1.0/24
   - Calls from 192.168.1.x network -> PrivilegedHandler
   - Pipelines: [:authenticated, :logged]

2. SCOPE: from *@partner.example.com
   - Calls from partner.example.com domain -> PartnerDomainHandler
   - Pipelines: [:logged]

3. PATTERN: "911" (exact match)
   - Emergency calls -> EmergencyHandler

4. PATTERN: "0" (exact match)
   - Operator calls -> OperatorHandler

5. PATTERN: "1xxx" (4 digits starting with 1)
   - Internal extensions (1000-1999) -> ExtensionHandler
   - Examples: 1000, 1234, 1999

6. PATTERN: "9~" (9 followed by anything)
   - Outbound dialing -> OutboundHandler
   - Examples: 91234567890, 9011123456789

7. PATTERN: "*" (catch-all)
   - Everything else -> DefaultHandler
   - Examples: 2000, abc, any-string

TEST EXAMPLES:
--------------
  sip:1234@127.0.0.1:5080       -> ExtensionHandler (matches 1xxx)
  sip:9123456789@127.0.0.1:5080 -> OutboundHandler (matches 9~)
  sip:911@127.0.0.1:5080        -> EmergencyHandler (exact match)
  sip:0@127.0.0.1:5080          -> OperatorHandler (exact match)
  sip:hello@127.0.0.1:5080      -> DefaultHandler (catch-all)
  sip:2000@127.0.0.1:5080       -> DefaultHandler (no pattern match)

NOTE: Scope-based routing (from_ip, from) requires the SIP message to contain
      the appropriate source information. For localhost testing, most calls
      will come from 127.0.0.1 and won't match the 192.168.1.0/24 scope.

================================================================================
""")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestRouterPatterns})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)

    IO.puts("Server listening on port #{port}")
    IO.puts("Press Ctrl+C to stop\n")

    # Log the routes for verification
    IO.puts("Registered Routes:")
    IO.puts("-----------------")

    TestRouterPatterns.__routes__()
    |> Enum.with_index(1)
    |> Enum.each(fn {route, index} ->
      scope_info =
        if map_size(route.scope) > 0 do
          " [scope: #{inspect(route.scope)}]"
        else
          ""
        end

      pipeline_info =
        if length(route.pipelines) > 0 do
          " [pipelines: #{inspect(route.pipelines)}]"
        else
          ""
        end

      IO.puts("  #{index}. #{inspect(route.pattern)} -> #{inspect(route.handler)}#{scope_info}#{pipeline_info}")
    end)

    IO.puts("\nPipelines:")
    IO.puts("---------")

    TestRouterPatterns.__pipelines__()
    |> Enum.each(fn {name, plugs} ->
      IO.puts("  #{inspect(name)}: #{inspect(plugs)}")
    end)

    IO.puts("")

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
