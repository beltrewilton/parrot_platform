# Interactive Voice Response (IVR) Menu Test Script
# Run with: SIP_TRACE=true LOG_LEVEL=info mix run scripts/dev/test_ivr_menu.exs
#
# This demonstrates a complete IVR menu system using the Parrot DSL.
# Simulates a phone banking / customer support line with:
# - Welcome greeting and main menu
# - Sub-menus for different options
# - Invalid input handling with retries (max 3)
# - Timeout handling
# - Return to main menu option
#
# Call Flow:
# 1. Welcome -> Main Menu (Press 1 for Account, 2 for Support, 0 for Operator)
# 2. Account Menu: Press 1 for Balance, 2 for Recent Transactions, 9 for Main Menu
# 3. Support Menu: Please hold for support (bridge attempt)
# 4. Operator: Direct transfer to operator
# 5. Invalid input: Retry up to 3 times, then goodbye

require Logger

defmodule IVRMenuHandler do
  use Parrot.InviteHandler

  require Logger

  # Menu states
  @menu_main :main
  @menu_account :account
  @menu_support :support

  # Limits
  @max_retries 3

  # DTMF collection options
  @dtmf_opts [max: 1, timeout: 8_000, terminators: ["#"]]

  # Audio file paths (using the available file for demo)
  # In production, these would be separate audio files
  @audio %{
    welcome: "priv/audio/parrot-welcome.wav",
    main_menu: "priv/audio/parrot-welcome.wav",
    account_menu: "priv/audio/parrot-welcome.wav",
    balance: "priv/audio/parrot-welcome.wav",
    transactions: "priv/audio/parrot-welcome.wav",
    support_hold: "priv/audio/parrot-welcome.wav",
    operator_transfer: "priv/audio/parrot-welcome.wav",
    invalid_input: "priv/audio/parrot-welcome.wav",
    goodbye: "priv/audio/parrot-welcome.wav",
    returning_main: "priv/audio/parrot-welcome.wav"
  }

  @impl true
  def handle_invite(call) do
    Logger.info("[IVR] Call received from #{call.from}")
    Logger.info("[IVR] Starting IVR menu flow...")

    # Initialize call state and play welcome
    call
    |> answer()
    |> assign(:menu, @menu_main)
    |> assign(:retries, 0)
    |> assign(:last_audio, :welcome)
    |> play(@audio.welcome)
  end

  # Handle pending collect from prompt/3 pattern
  @impl true
  def handle_play_complete(_file, %{assigns: %{__pending_collect__: opts}} = call)
      when not is_nil(opts) do
    Logger.info("[IVR] Prompt audio complete, starting DTMF collection")

    call
    |> assign(:__pending_collect__, nil)
    |> collect_dtmf(opts)
  end

  # After welcome, play main menu
  def handle_play_complete(_file, %{assigns: %{last_audio: :welcome}} = call) do
    Logger.info("[IVR] Welcome complete, playing main menu")
    play_main_menu(call)
  end

  # After balance announcement, offer repeat or return to main
  def handle_play_complete(_file, %{assigns: %{last_audio: :balance}} = call) do
    Logger.info("[IVR] Balance announcement complete")

    call
    |> assign(:last_audio, :balance_options)
    |> prompt(@audio.account_menu, @dtmf_opts)
  end

  # After transactions announcement
  def handle_play_complete(_file, %{assigns: %{last_audio: :transactions}} = call) do
    Logger.info("[IVR] Transactions announcement complete")

    call
    |> assign(:last_audio, :transactions_options)
    |> prompt(@audio.account_menu, @dtmf_opts)
  end

  # After invalid input message, retry the current menu
  def handle_play_complete(_file, %{assigns: %{last_audio: :invalid, menu: menu}} = call) do
    Logger.info("[IVR] Invalid input message complete, retrying menu: #{menu}")
    play_current_menu(call, menu)
  end

  # After returning to main message
  def handle_play_complete(_file, %{assigns: %{last_audio: :returning_main}} = call) do
    Logger.info("[IVR] Returning to main menu")
    play_main_menu(call)
  end

  # After goodbye, hang up
  def handle_play_complete(_file, %{assigns: %{last_audio: :goodbye}} = call) do
    Logger.info("[IVR] Goodbye complete, ending call")
    call |> hangup()
  end

  # After support hold message, attempt bridge
  def handle_play_complete(_file, %{assigns: %{last_audio: :support_hold}} = call) do
    Logger.info("[IVR] Support hold complete, bridging to support queue")
    # In a real system, this would bridge to an ACD/queue
    # For demo, we simulate with a bridge attempt
    call
    |> assign(:last_audio, nil)
    |> bridge("sip:support@127.0.0.1:5090", timeout: 30_000)
  end

  # After operator transfer message, bridge to operator
  def handle_play_complete(_file, %{assigns: %{last_audio: :operator_transfer}} = call) do
    Logger.info("[IVR] Operator transfer, bridging to operator")

    call
    |> assign(:last_audio, nil)
    |> bridge("sip:operator@127.0.0.1:5090", timeout: 60_000)
  end

  # Default: continue with DTMF collection for current menu
  def handle_play_complete(_file, %{assigns: %{menu: menu}} = call) do
    Logger.info("[IVR] Audio complete, collecting DTMF for menu: #{menu}")
    call |> collect_dtmf(@dtmf_opts)
  end

  # ---------------------------------------------------------------------------
  # DTMF Handlers - Main Menu
  # ---------------------------------------------------------------------------

  @impl true
  # Main Menu: 1 = Account Info
  def handle_dtmf("1", %{assigns: %{menu: @menu_main}} = call) do
    Logger.info("[IVR] Main menu: Selected 1 (Account Info)")

    call
    |> assign(:menu, @menu_account)
    |> assign(:retries, 0)
    |> assign(:last_audio, :account_menu)
    |> play(@audio.account_menu)
  end

  # Main Menu: 2 = Support
  def handle_dtmf("2", %{assigns: %{menu: @menu_main}} = call) do
    Logger.info("[IVR] Main menu: Selected 2 (Support)")

    call
    |> assign(:menu, @menu_support)
    |> assign(:retries, 0)
    |> assign(:last_audio, :support_hold)
    |> play(@audio.support_hold)
  end

  # Main Menu: 0 = Operator
  def handle_dtmf("0", %{assigns: %{menu: @menu_main}} = call) do
    Logger.info("[IVR] Main menu: Selected 0 (Operator)")

    call
    |> assign(:last_audio, :operator_transfer)
    |> play(@audio.operator_transfer)
  end

  # Main Menu: * = Repeat menu
  def handle_dtmf("*", %{assigns: %{menu: @menu_main}} = call) do
    Logger.info("[IVR] Main menu: Selected * (Repeat)")
    play_main_menu(call)
  end

  # ---------------------------------------------------------------------------
  # DTMF Handlers - Account Menu
  # ---------------------------------------------------------------------------

  # Account Menu: 1 = Check Balance
  def handle_dtmf("1", %{assigns: %{menu: @menu_account}} = call) do
    Logger.info("[IVR] Account menu: Selected 1 (Balance)")

    # Simulate fetching account balance
    balance = "$1,234.56"
    Logger.info("[IVR] Account balance: #{balance}")

    call
    |> assign(:last_audio, :balance)
    |> play(@audio.balance)
  end

  # Account Menu: 2 = Recent Transactions
  def handle_dtmf("2", %{assigns: %{menu: @menu_account}} = call) do
    Logger.info("[IVR] Account menu: Selected 2 (Transactions)")

    call
    |> assign(:last_audio, :transactions)
    |> play(@audio.transactions)
  end

  # Account Menu: 9 = Return to Main Menu
  def handle_dtmf("9", %{assigns: %{menu: @menu_account}} = call) do
    Logger.info("[IVR] Account menu: Selected 9 (Return to Main)")
    return_to_main_menu(call)
  end

  # Account Menu: * = Repeat account menu
  def handle_dtmf("*", %{assigns: %{menu: @menu_account}} = call) do
    Logger.info("[IVR] Account menu: Selected * (Repeat)")

    call
    |> assign(:last_audio, :account_menu)
    |> prompt(@audio.account_menu, @dtmf_opts)
  end

  # ---------------------------------------------------------------------------
  # DTMF Handlers - Balance/Transaction Sub-options
  # ---------------------------------------------------------------------------

  # After balance: 1 = Repeat balance
  def handle_dtmf("1", %{assigns: %{last_audio: :balance_options}} = call) do
    Logger.info("[IVR] Balance: Selected 1 (Repeat)")

    call
    |> assign(:last_audio, :balance)
    |> play(@audio.balance)
  end

  # After balance: 9 = Return to main menu
  def handle_dtmf("9", %{assigns: %{last_audio: :balance_options}} = call) do
    Logger.info("[IVR] Balance: Selected 9 (Return to Main)")
    return_to_main_menu(call)
  end

  # After transactions: 1 = Repeat transactions
  def handle_dtmf("1", %{assigns: %{last_audio: :transactions_options}} = call) do
    Logger.info("[IVR] Transactions: Selected 1 (Repeat)")

    call
    |> assign(:last_audio, :transactions)
    |> play(@audio.transactions)
  end

  # After transactions: 9 = Return to main menu
  def handle_dtmf("9", %{assigns: %{last_audio: :transactions_options}} = call) do
    Logger.info("[IVR] Transactions: Selected 9 (Return to Main)")
    return_to_main_menu(call)
  end

  # ---------------------------------------------------------------------------
  # DTMF Handlers - Timeout and Invalid Input
  # ---------------------------------------------------------------------------

  # Timeout handling
  def handle_dtmf(:timeout, %{assigns: %{retries: retries}} = call)
      when retries >= @max_retries - 1 do
    Logger.info("[IVR] Timeout: Max retries (#{@max_retries}) reached, saying goodbye")
    say_goodbye(call)
  end

  def handle_dtmf(:timeout, %{assigns: %{retries: retries, menu: menu}} = call) do
    new_retries = retries + 1
    Logger.info("[IVR] Timeout: Retry #{new_retries}/#{@max_retries} for menu #{menu}")

    call
    |> assign(:retries, new_retries)
    |> assign(:last_audio, :invalid)
    |> play(@audio.invalid_input)
  end

  # Invalid input - any unhandled digit
  def handle_dtmf(digit, %{assigns: %{retries: retries}} = call)
      when retries >= @max_retries - 1 do
    Logger.info("[IVR] Invalid digit '#{digit}': Max retries reached, saying goodbye")
    say_goodbye(call)
  end

  def handle_dtmf(digit, %{assigns: %{retries: retries, menu: menu}} = call) do
    new_retries = retries + 1

    Logger.info(
      "[IVR] Invalid digit '#{digit}': Retry #{new_retries}/#{@max_retries} for menu #{menu}"
    )

    call
    |> assign(:retries, new_retries)
    |> assign(:last_audio, :invalid)
    |> play(@audio.invalid_input)
  end

  # ---------------------------------------------------------------------------
  # Bridge Complete Handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_bridge_complete(:answered, call) do
    Logger.info("[IVR] Bridge answered - call in progress")
    {:noreply, call}
  end

  def handle_bridge_complete({:failed, reason}, call) do
    Logger.info("[IVR] Bridge failed: #{inspect(reason)}, returning to main menu")

    # Bridge failed, return to main menu
    call
    |> assign(:menu, @menu_main)
    |> assign(:retries, 0)
    |> assign(:last_audio, :returning_main)
    |> play(@audio.returning_main)
  end

  # ---------------------------------------------------------------------------
  # Hangup Handler
  # ---------------------------------------------------------------------------

  @impl true
  def handle_hangup(call) do
    Logger.info("[IVR] Call ended - session ID: #{call.id}")

    Logger.info(
      "[IVR] Final state: menu=#{call.assigns[:menu]}, retries=#{call.assigns[:retries]}"
    )

    {:noreply, call}
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp play_main_menu(call) do
    Logger.info("[IVR] Playing main menu prompt")

    call
    |> assign(:menu, @menu_main)
    |> assign(:retries, 0)
    |> assign(:last_audio, :main_menu)
    |> prompt(@audio.main_menu, @dtmf_opts)
  end

  defp play_current_menu(call, @menu_main), do: play_main_menu(call)

  defp play_current_menu(call, @menu_account) do
    call
    |> assign(:last_audio, :account_menu)
    |> prompt(@audio.account_menu, @dtmf_opts)
  end

  defp play_current_menu(call, @menu_support) do
    # Support menu goes directly to hold music/bridge
    call
    |> assign(:last_audio, :support_hold)
    |> play(@audio.support_hold)
  end

  defp play_current_menu(call, _menu), do: play_main_menu(call)

  defp return_to_main_menu(call) do
    call
    |> assign(:menu, @menu_main)
    |> assign(:retries, 0)
    |> assign(:last_audio, :returning_main)
    |> play(@audio.returning_main)
  end

  defp say_goodbye(call) do
    call
    |> assign(:last_audio, :goodbye)
    |> play(@audio.goodbye)
  end
end

# Router configuration
defmodule IVRMenuRouter do
  use Parrot.Router

  invite("*", IVRMenuHandler)
end

# ---------------------------------------------------------------------------
# Start the IVR Server
# ---------------------------------------------------------------------------

IO.puts("""
================================================================================
                    PARROT IVR MENU DEMONSTRATION
================================================================================

Starting IVR menu test server on port 5080...

IVR MENU STRUCTURE:

  MAIN MENU (Press 1, 2, 0, or * to repeat)
  ├── 1: Account Information
  │   ├── 1: Check Balance
  │   │   ├── 1: Repeat balance
  │   │   └── 9: Return to main menu
  │   ├── 2: Recent Transactions
  │   │   ├── 1: Repeat transactions
  │   │   └── 9: Return to main menu
  │   ├── 9: Return to main menu
  │   └── *: Repeat account menu
  ├── 2: Customer Support (bridge to support queue)
  ├── 0: Operator (bridge to operator)
  └── *: Repeat main menu

INVALID INPUT HANDLING:
  - Max retries: 3
  - After 3 invalid inputs or timeouts: "Goodbye" and hangup
  - Timeout per menu: 8 seconds

NOTE: All audio files use the same placeholder (parrot-welcome.wav).
      In production, each menu would have its own audio prompt.

""")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: IVRMenuRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("IVR Menu server listening on port #{port}")
    IO.puts("Call sip:ivr@127.0.0.1:#{port}")
    IO.puts("")
    IO.puts("Test with DTMF:")
    IO.puts("  1     -> Account menu")
    IO.puts("  1,1   -> Check balance")
    IO.puts("  1,2   -> Recent transactions")
    IO.puts("  2     -> Support (bridge attempt)")
    IO.puts("  0     -> Operator (bridge attempt)")
    IO.puts("  3,3,3 -> Invalid x3 -> Goodbye")
    IO.puts("")
    IO.puts("Press Ctrl+C to stop\n")
    IO.puts("================================================================================\n")

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
