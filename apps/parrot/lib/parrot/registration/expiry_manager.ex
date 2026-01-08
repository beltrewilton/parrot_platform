defmodule Parrot.Registration.ExpiryManager do
  @moduledoc """
  Manages registration expiry timers for SIP REGISTER bindings.

  The ExpiryManager tracks registration bindings by `{aor, contact}` tuples
  and schedules timer callbacks when registrations expire. Uses ETS for
  efficient timer tracking and `Process.send_after/3` for scheduling.

  ## Features

  - Schedule expiry timers for registration bindings
  - Cancel timers on re-registration or unregister (expires=0)
  - Automatically refresh timers on re-registration
  - Exception-safe callback invocation (won't crash on handler errors)

  ## Usage

  Typically started as part of the Parrot supervision tree. The framework
  calls `schedule_expiry/5` after a successful `store_binding/3` call.

      # Schedule a timer for 3600 seconds
      :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 3600, MyHandler)

      # Cancel a timer (e.g., on explicit unregister)
      :ok = ExpiryManager.cancel_expiry(manager, aor, contact)

      # Unregister via expires=0 (cancels without callback)
      :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 0, MyHandler)

  ## Timer Lifecycle

  1. Registration received with expires > 0 -> schedule timer
  2. Re-registration received -> cancel old timer, schedule new timer
  3. Unregister (expires=0) received -> cancel timer without callback
  4. Timer fires -> invoke handler callback, remove from tracking

  ## Recovery

  Timer state is held in ETS and process memory. If the ExpiryManager
  crashes, active timers are lost. The supervision tree should restart
  it with `restart: :permanent`. Registrations will naturally expire
  and clients will re-register.
  """

  use GenServer
  require Logger

  # ETS table options: one entry per {aor, contact}, concurrent access
  @ets_opts [:set, :public, read_concurrency: true, write_concurrency: true]

  defstruct [:ets_table]

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts the ExpiryManager GenServer.

  ## Options

  - `:name` - Optional name for process registration

  ## Examples

      {:ok, pid} = ExpiryManager.start_link(name: Parrot.ExpiryManager)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Schedules an expiry timer for a registration binding.

  If `expires` is 0, any existing timer is cancelled without invoking
  the callback (unregister case). If a timer already exists for this
  `{aor, contact}` pair, it is cancelled and a new timer is scheduled.

  ## Arguments

  - `manager` - The ExpiryManager process reference
  - `aor` - Address of Record (e.g., "sip:alice@example.com")
  - `contact` - Contact URI (e.g., "sip:alice@192.168.1.100:5060")
  - `expires` - Time in seconds until expiration (0 = unregister)
  - `handler` - Module implementing `Parrot.RegistrationHandler`

  ## Returns

  - `:ok` - Timer scheduled (or cancelled if expires=0)

  ## Examples

      # Normal registration
      :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 3600, MyHandler)

      # Unregister (cancels timer, no callback)
      :ok = ExpiryManager.schedule_expiry(manager, aor, contact, 0, MyHandler)
  """
  @spec schedule_expiry(
          GenServer.server(),
          String.t(),
          String.t(),
          non_neg_integer(),
          module()
        ) :: :ok
  def schedule_expiry(manager, aor, contact, expires, handler) do
    GenServer.call(manager, {:schedule_expiry, aor, contact, expires, handler})
  end

  @doc """
  Cancels an expiry timer for a registration binding.

  If no timer exists for the `{aor, contact}` pair, this is a no-op.

  ## Arguments

  - `manager` - The ExpiryManager process reference
  - `aor` - Address of Record
  - `contact` - Contact URI

  ## Returns

  - `:ok` - Timer cancelled (or already absent)

  ## Examples

      :ok = ExpiryManager.cancel_expiry(manager, aor, contact)
  """
  @spec cancel_expiry(GenServer.server(), String.t(), String.t()) :: :ok
  def cancel_expiry(manager, aor, contact) do
    GenServer.call(manager, {:cancel_expiry, aor, contact})
  end

  @doc """
  Returns a map of currently active timers.

  Useful for debugging and testing. Keys are `{aor, contact}` tuples.

  ## Returns

  A map with `{aor, contact}` keys and timer info values.

  ## Examples

      timers = ExpiryManager.get_active_timers(manager)
      #=> %{{"sip:alice@example.com", "sip:alice@192.168.1.100:5060"} => %{...}}
  """
  @spec get_active_timers(GenServer.server()) :: map()
  def get_active_timers(manager) do
    GenServer.call(manager, :get_active_timers)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for timer tracking
    table = :ets.new(:expiry_timers, @ets_opts)

    Logger.debug("ExpiryManager started with ETS table #{inspect(table)}")

    {:ok, %__MODULE__{ets_table: table}}
  end

  @impl true
  def handle_call({:schedule_expiry, aor, contact, expires, handler}, _from, state) do
    key = {aor, contact}

    # Cancel any existing timer for this binding
    cancel_timer_for_key(state.ets_table, key)

    if expires > 0 do
      # Schedule new timer
      timer_ref = schedule_timer(key, expires, handler)

      # Store in ETS
      :ets.insert(state.ets_table, {key, %{timer_ref: timer_ref, handler: handler}})

      Logger.debug("Scheduled expiry timer for #{aor} contact #{contact} in #{expires}s")
    else
      # expires=0 means unregister - just cancel, no new timer
      Logger.debug("Unregister for #{aor} contact #{contact} - timer cancelled")
    end

    {:reply, :ok, state}
  end

  def handle_call({:cancel_expiry, aor, contact}, _from, state) do
    key = {aor, contact}
    cancel_timer_for_key(state.ets_table, key)

    Logger.debug("Cancelled expiry timer for #{aor} contact #{contact}")

    {:reply, :ok, state}
  end

  def handle_call(:get_active_timers, _from, state) do
    timers =
      state.ets_table
      |> :ets.tab2list()
      |> Map.new()

    {:reply, timers, state}
  end

  @impl true
  def handle_info({:timer_expired, key, handler}, state) do
    {aor, contact} = key

    # Remove from ETS first
    :ets.delete(state.ets_table, key)

    # Invoke handler callback with exception protection
    invoke_callback_safe(handler, aor, contact)

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("ExpiryManager received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  # Cancel any existing timer for the given key
  defp cancel_timer_for_key(table, key) do
    case :ets.lookup(table, key) do
      [{^key, %{timer_ref: timer_ref}}] ->
        Process.cancel_timer(timer_ref)
        :ets.delete(table, key)

      [] ->
        :ok
    end
  end

  # Schedule a timer using Process.send_after
  defp schedule_timer(key, expires_seconds, handler) do
    expires_ms = expires_seconds * 1000
    Process.send_after(self(), {:timer_expired, key, handler}, expires_ms)
  end

  # Invoke handler callback with exception protection
  defp invoke_callback_safe(handler, aor, contact) do
    try do
      handler.handle_registration_expired(aor, contact)
    rescue
      e ->
        Logger.error(
          "Exception in handle_registration_expired callback for #{aor} contact #{contact}: " <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        :error
    catch
      kind, reason ->
        Logger.error(
          "Caught #{kind} in handle_registration_expired callback for #{aor} contact #{contact}: " <>
            inspect(reason)
        )

        :error
    end
  end
end
