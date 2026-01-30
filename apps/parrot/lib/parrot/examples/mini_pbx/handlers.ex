defmodule Parrot.Examples.MiniPBX.Extensions do
  @moduledoc """
  Handler for internal extension-to-extension calls.

  Routes calls between registered extensions with features like:
  - Registration lookup and bridging
  - Voicemail on no-answer
  - Busy handling
  - Presence notification (when Presence handler is implemented)

  ## Call Flow

      Incoming INVITE
           │
           ▼
      Extract extension from To URI
           │
           ▼
      Lookup registration in Storage
           │
      ┌────┴────┐
      │         │
      ▼         ▼
  Found     Not Found
      │         │
      ▼         ▼
  Answer    Reject 404
  Bridge
      │
      ▼
  Bridge Complete
      │
  ┌───┼───────┐
  │   │       │
  ▼   ▼       ▼
  OK  Busy  No Answer
      │       │
      ▼       ▼
  Play msg  Voicemail

  ## Example

      # Internal call from 1002 to 1001
      INVITE sip:1001@pbx.local
      From: <sip:1002@pbx.local>
      To: <sip:1001@pbx.local>

      # Extensions handler:
      # 1. Looks up 1001 in Storage
      # 2. Finds contact: sip:1001@192.168.1.100:5060
      # 3. Answers and bridges to that contact
  """
  use Parrot.InviteHandler

  require Logger

  alias Parrot.Examples.MiniPBX.Storage

  @ring_timeout 30_000

  @impl true
  def handle_invite(call) do
    Logger.info("[Extensions] Extension call from #{call.from} to #{call.to}")

    # Extract extension number from To URI (e.g., "sip:1001@pbx.local" -> "1001")
    extension = extract_extension(call.to)

    case Storage.lookup_extension(extension) do
      {:ok, contact} ->
        Logger.info("[Extensions] Found registration for #{extension}: #{contact}")

        call
        |> assign(:extension, extension)
        |> assign(:caller, call.from)
        |> answer()
        |> bridge(contact, timeout: @ring_timeout)

      {:error, :not_registered} ->
        Logger.info("[Extensions] Extension #{extension} not registered")
        call |> reject(404)
    end
  end

  @impl true
  def handle_bridge_complete(:answered, call) do
    Logger.info("[Extensions] Bridge answered for extension #{call.assigns[:extension]}")
    # Notify presence (when implemented)
    # Presence.notify(call.assigns.extension, :busy)
    {:noreply, call}
  end

  @impl true
  def handle_bridge_complete({:failed, :no_answer}, call) do
    Logger.info("[Extensions] No answer for extension #{call.assigns[:extension]}, forwarding to voicemail")

    call
    |> assign(:voicemail, true)
    |> play("voicemail-greeting.wav", [])
  end

  @impl true
  def handle_bridge_complete({:failed, :busy}, call) do
    Logger.info("[Extensions] Extension #{call.assigns[:extension]} is busy")

    call
    |> play("extension-busy.wav", [])
    |> hangup()
  end

  @impl true
  def handle_bridge_complete({:failed, reason}, call) do
    Logger.info("[Extensions] Bridge failed for extension #{call.assigns[:extension]}: #{inspect(reason)}")

    call
    |> play("extension-unavailable.wav", [])
    |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[Extensions] Call ended for extension #{call.assigns[:extension]}")
    # Notify presence (when implemented)
    # Presence.notify(call.assigns.extension, :available)
    {:noreply, call}
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  # Extracts extension number from a SIP URI
  # "sip:1001@pbx.local" -> "1001"
  # "sip:1001@pbx.local:5060" -> "1001"
  defp extract_extension(uri) when is_binary(uri) do
    uri
    |> String.replace(~r/^sip:/i, "")
    |> String.split("@")
    |> List.first()
  end

  defp extract_extension(_), do: nil
end

defmodule Parrot.Examples.MiniPBX.Outbound do
  @moduledoc """
  Handler for outbound PSTN calls.

  Routes calls through configured carriers with:
  - Dial 9 + number for outside line
  - Multi-carrier support with priority
  - First-answer failover strategy
  - E.164 number validation

  ## Carrier Configuration

  Carriers are tried in order. If the first carrier fails, the call
  automatically routes to the next carrier.

      @carriers [
        {"carrier1.example.com", priority: 1},
        {"carrier2.example.com", priority: 2}
      ]

  ## Call Flow

      Incoming INVITE (sip:9xxx@pbx.local)
           │
           ▼
      Extract number (strip leading 9)
           │
           ▼
      Validate (E.164: 10-15 digits)
           │
      ┌────┴────┐
      │         │
      ▼         ▼
   Valid     Invalid
      │         │
      ▼         ▼
   Answer    Reject 404
   Fork to carriers
      │
      ┌────┴────┐
      │         │
      ▼         ▼
  Answered  All Failed
      │         │
      ▼         ▼
  Continue  Error msg
            + Hangup

  ## Example

      # User dials outside number
      INVITE sip:91234567890@pbx.local
      From: <sip:1001@pbx.local>

      # Handler:
      # 1. Extracts 1234567890
      # 2. Validates format
      # 3. Forks to carrier1, carrier2
      # 4. First to answer wins
  """
  use Parrot.InviteHandler

  require Logger

  @carriers [
    {"carrier1.example.com", priority: 1},
    {"carrier2.example.com", priority: 2}
  ]

  @fork_timeout 30_000

  @impl true
  def handle_invite(call) do
    Logger.info("[Outbound] Outbound call from #{call.from} to #{call.to}")

    # Extract the dialed number (strip leading 9 and domain)
    number = extract_number(call.to)

    case validate_number(number) do
      {:ok, normalized} ->
        Logger.info("[Outbound] Routing #{normalized} to PSTN carriers")
        destinations = build_destinations(normalized)

        call
        |> assign(:dialed_number, normalized)
        |> assign(:caller, call.from)
        |> answer()
        |> fork(destinations, strategy: :first_answer, timeout: @fork_timeout)

      {:error, :invalid} ->
        Logger.info("[Outbound] Invalid number format: #{number}")
        call |> reject(404)
    end
  end

  @impl true
  def handle_fork_complete({:answered, destination}, call) do
    Logger.info("[Outbound] Call connected via #{destination}")
    {:noreply, call}
  end

  @impl true
  def handle_fork_complete({:failed, :all_failed}, call) do
    Logger.info("[Outbound] All carriers failed for #{call.assigns[:dialed_number]}")

    call
    |> play("call-cannot-be-completed.wav", [])
    |> hangup()
  end

  @impl true
  def handle_fork_complete({:failed, reason}, call) do
    Logger.info("[Outbound] Fork failed: #{inspect(reason)}")

    call
    |> play("call-error.wav", [])
    |> hangup()
  end

  # ===========================================================================
  # Public API (for testing)
  # ===========================================================================

  @doc """
  Validates a phone number for E.164 format.

  Valid numbers are 10-15 digits with no other characters.
  """
  @spec validate_number(String.t()) :: {:ok, String.t()} | {:error, :invalid}
  def validate_number(number) when is_binary(number) do
    if Regex.match?(~r/^\d{10,15}$/, number) do
      {:ok, number}
    else
      {:error, :invalid}
    end
  end

  def validate_number(_), do: {:error, :invalid}

  @doc """
  Builds the list of carrier destinations for a number.
  """
  @spec build_destinations(String.t()) :: [String.t()]
  def build_destinations(number) do
    @carriers
    |> Enum.sort_by(fn {_host, opts} -> Keyword.get(opts, :priority, 99) end)
    |> Enum.map(fn {host, _opts} -> "sip:#{number}@#{host}" end)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # Extracts number from To URI: "sip:91234567890@pbx.local" -> "1234567890"
  defp extract_number(uri) when is_binary(uri) do
    uri
    |> String.replace(~r/^sip:/i, "")
    |> String.split("@")
    |> List.first()
    |> String.replace(~r/^9/, "")  # Strip leading 9 (outside line prefix)
  end

  defp extract_number(_), do: ""
end

defmodule Parrot.Examples.MiniPBX.AutoAttendant do
  @moduledoc """
  Auto-attendant IVR handler.

  Provides the main company greeting with menu options:
  - Press 1 for sales
  - Press 2 for support
  - Press 0 for operator

  ## Call Flow

      Incoming INVITE to 100
           │
           ▼
      Answer + Play welcome
           │
           ▼
      Play main menu
           │
      ┌────┼────────┐
      │    │        │
      ▼    ▼        ▼
     1    2         0
      │    │        │
      ▼    ▼        ▼
   Sales Support Operator
      │    │        │
      └────┴────────┴──► Bridge
                         │
                    ┌────┴────┐
                    │         │
                    ▼         ▼
               Answered   Failed
                    │         │
                    ▼         ▼
               Continue   Error msg
                            + Hangup

  Timeout Flow:
  - First timeout: Retry (max 2)
  - Third timeout: Goodbye + Hangup
  """
  use Parrot.InviteHandler

  require Logger

  @max_retries 2
  @ring_timeout 30_000
  @menu_timeout 5_000

  # Department mappings
  @sales_dest "sip:sales@internal"
  @support_dest "sip:support@internal"
  @operator_dest "sip:operator@internal"

  @impl true
  def handle_invite(call) do
    Logger.info("[AutoAttendant] Call to auto-attendant from #{call.from}")

    call
    |> assign(:menu, :main)
    |> assign(:retries, 0)
    |> answer()
    |> play("welcome.wav", [])
  end

  @impl true
  def handle_play_complete(filename, call) do
    cond do
      # After welcome, play main menu
      String.contains?(filename, "welcome") ->
        call
        |> play("main-menu.wav", [])
        |> collect_dtmf(max_digits: 1, timeout: @menu_timeout)

      # After retry message, play menu again
      String.contains?(filename, "try-again") or String.contains?(filename, "sorry") ->
        call
        |> play("main-menu.wav", [])
        |> collect_dtmf(max_digits: 1, timeout: @menu_timeout)

      # After goodbye, hang up
      String.contains?(filename, "goodbye") ->
        call |> hangup()

      # After error message (operators busy), hang up is already queued
      String.contains?(filename, "busy") or String.contains?(filename, "unavailable") ->
        {:noreply, call}

      true ->
        {:noreply, call}
    end
  end

  @impl true
  def handle_dtmf("1", %{assigns: %{menu: :main}} = call) do
    Logger.info("[AutoAttendant] Option 1 - Bridging to Sales")
    call |> bridge(@sales_dest, timeout: @ring_timeout)
  end

  @impl true
  def handle_dtmf("2", %{assigns: %{menu: :main}} = call) do
    Logger.info("[AutoAttendant] Option 2 - Bridging to Support")
    call |> bridge(@support_dest, timeout: @ring_timeout)
  end

  @impl true
  def handle_dtmf("0", %{assigns: %{menu: :main}} = call) do
    Logger.info("[AutoAttendant] Option 0 - Bridging to Operator")
    call |> bridge(@operator_dest, timeout: @ring_timeout)
  end

  @impl true
  def handle_dtmf(:timeout, call) do
    retries = call.assigns[:retries] || 0

    if retries < @max_retries do
      Logger.info("[AutoAttendant] Timeout - retry #{retries + 1}")

      call
      |> assign(:retries, retries + 1)
      |> play("sorry-try-again.wav", [])
    else
      Logger.info("[AutoAttendant] Max retries reached - goodbye")
      call |> play("goodbye.wav", [])
    end
  end

  # Invalid option (not 1, 2, or 0)
  @impl true
  def handle_dtmf(digit, %{assigns: %{menu: :main}} = call) when is_binary(digit) do
    Logger.info("[AutoAttendant] Invalid option: #{digit}")
    retries = call.assigns[:retries] || 0

    if retries < @max_retries do
      call
      |> assign(:retries, retries + 1)
      |> play("invalid-option-try-again.wav", [])
    else
      call |> play("goodbye.wav", [])
    end
  end

  @impl true
  def handle_bridge_complete(:answered, call) do
    Logger.info("[AutoAttendant] Bridge answered")
    {:noreply, call}
  end

  @impl true
  def handle_bridge_complete({:failed, reason}, call) do
    Logger.info("[AutoAttendant] Bridge failed: #{inspect(reason)}")

    call
    |> play("all-operators-busy.wav", [])
    |> hangup()
  end
end

defmodule Parrot.Examples.MiniPBX.Registration do
  @moduledoc """
  Registration handler for Mini PBX.

  Handles REGISTER requests with:
  - Digest authentication via password lookup
  - Mnesia storage integration
  - Multiple contacts per extension
  - Expiry handling and cleanup

  ## Demo Credentials

  For this example, passwords are the same as extension numbers:
  - Extension 1001: password "1001"
  - Extension 1002: password "1002"
  - etc.

  In production, use a proper user database with hashed passwords.

  ## Registration Flow

      REGISTER sip:1001@pbx.local
      From: <sip:1001@pbx.local>
      Contact: <sip:1001@192.168.1.100:5060>
      Expires: 3600

      1. Framework extracts credentials
      2. get_password("1001") -> {:ok, "1001"}
      3. Framework validates digest
      4. authenticate(%{username: "1001", ...}) -> :ok
      5. store_binding("sip:1001@pbx.local", "sip:...", 3600)
      6. Framework sends 200 OK with Contact headers
  """
  use Parrot.RegistrationHandler

  require Logger

  alias Parrot.Examples.MiniPBX.Storage

  # Demo passwords - in production, use a database
  # Password = extension number for simplicity
  @demo_extensions ["1001", "1002", "1003", "1004", "1005",
                    "1006", "1007", "1008", "1009", "1010"]

  @impl true
  def get_password(username) do
    # For demo, password equals extension number
    if username in @demo_extensions do
      {:ok, username}
    else
      :error
    end
  end

  @impl true
  def authenticate(_credentials) do
    # Additional authentication checks could go here
    # (rate limiting, account status, etc.)
    :ok
  end

  @impl true
  def store_binding(aor, contact, expires) do
    if expires > 0 do
      Logger.info("[Registration] Storing binding: #{aor} -> #{contact} (#{expires}s)")
      Storage.register(aor, contact, expires)
    else
      Logger.info("[Registration] Removing binding: #{aor} -> #{contact}")
      Storage.unregister(aor, contact)
    end
  end

  @impl true
  def get_bindings(aor) do
    case Storage.get_registrations(aor) do
      {:ok, registrations} ->
        Enum.map(registrations, fn reg ->
          %{
            contact: reg.contact,
            expires: reg.expires,
            registered_at: datetime_to_unix(reg.registered_at)
          }
        end)
    end
  end

  @impl true
  def handle_registration_expired(aor, contact) do
    Logger.info("[Registration] Expiring binding: #{aor} -> #{contact}")
    Storage.unregister(aor, contact)
    # Could also update presence here
    # Presence.notify(aor, %{status: :offline})
    :ok
  end

  # Convert DateTime to Unix timestamp (seconds)
  defp datetime_to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp datetime_to_unix(other), do: other
end

defmodule Parrot.Examples.MiniPBX.Presence do
  @moduledoc """
  Presence handler for Mini PBX.

  Handles SUBSCRIBE/NOTIFY for presence with:
  - BLF (Busy Lamp Field) indication
  - Extension status tracking
  - Subscription management

  ## Presence States

  - `:available` - Extension is ready to receive calls
  - `:busy` - Extension is on a call
  - `:dnd` - Do Not Disturb enabled
  - `:offline` - Extension not registered

  ## BLF (Busy Lamp Field) Support

  When extensions subscribe to each other's presence:
  1. Phone A subscribes to "sip:1002@pbx.local"
  2. Mini PBX stores subscription
  3. When 1002's state changes, NOTIFY sent to A
  4. Phone A updates BLF lamp (green/red/etc.)

  ## Example

      # Subscribe to presence
      SUBSCRIBE sip:1002@pbx.local
      From: <sip:1001@pbx.local>
      Event: presence

      # Presence handler:
      # 1. authorize_subscription("sip:1001@...", "sip:1002@...") -> :allow
      # 2. store_subscription(...)
      # 3. Framework sends 200 OK
      # 4. Framework sends initial NOTIFY with current state
  """

  use Parrot.PresenceHandler

  require Logger

  alias Parrot.Examples.MiniPBX.Storage

  @impl true
  def authorize_subscription(watcher, presentity) do
    Logger.info("[Presence] Subscription request: #{watcher} -> #{presentity}")
    # For Mini PBX demo, allow all internal subscriptions
    :allow
  end

  @impl true
  def store_subscription(subscription) do
    Logger.info("[Presence] Storing subscription: #{subscription[:watcher]} -> #{subscription[:presentity]}")
    Storage.save_subscription(subscription)
  end

  @impl true
  def get_subscriptions(presentity) do
    Storage.get_subscriptions(presentity)
  end

  @impl true
  def get_presence(presentity) do
    case Storage.get_presence_state(presentity) do
      {:ok, :available} ->
        %{status: :open, note: "Available"}

      {:ok, :busy} ->
        %{status: :closed, note: "On a call"}

      {:ok, :dnd} ->
        %{status: :closed, note: "Do not disturb"}

      {:ok, :offline} ->
        %{status: :closed, note: "Offline"}

      {:error, :not_found} ->
        %{status: :closed, note: "Offline"}
    end
  end

  @impl true
  def handle_publish(presentity, presence_state) do
    status = presence_state[:status] || :offline
    Logger.info("[Presence] Publishing state for #{presentity}: #{status}")
    Storage.set_presence_state(presentity, status)
  end
end
