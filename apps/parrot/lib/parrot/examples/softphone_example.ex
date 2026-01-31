defmodule Parrot.Examples.SoftphoneExample do
  @moduledoc """
  Complete example of using Parrot.SoftphoneClient to build a softphone.

  This example demonstrates:
  - Registration with a SIP server
  - Presence subscription and publishing
  - Making and receiving calls
  - Call control (hold, resume, DTMF)

  ## Running the Example

      # Start the example
      {:ok, phone} = Parrot.Examples.SoftphoneExample.start(
        username: "alice",
        domain: "pbx.example.com",
        password: System.get_env("SIP_PASSWORD"),
        subscribe_to: ["sip:bob@example.com", "sip:carol@example.com"]
      )

      # Make a call
      {:ok, call_id} = Parrot.SoftphoneClient.dial(phone, "sip:bob@example.com")

      # Hang up
      :ok = Parrot.SoftphoneClient.hangup(phone, call_id)

  ## Handler Implementation

  The example uses `ExampleHandler` which implements `Parrot.SoftphoneHandler`.
  All callbacks log events and can notify a parent process for testing.
  """

  alias Parrot.SoftphoneClient

  require Logger

  # ============================================================================
  # Handler Module
  # ============================================================================

  defmodule ExampleHandler do
    @moduledoc """
    Example SoftphoneHandler implementation with logging and event notification.
    """
    use Parrot.SoftphoneHandler

    @impl true
    def init(opts) do
      # Build config from opts
      config = %{
        username: Keyword.fetch!(opts, :username),
        domain: Keyword.fetch!(opts, :domain),
        auth_password: Keyword.get(opts, :password),
        auto_register: Keyword.get(opts, :auto_register, true),
        register_expires: Keyword.get(opts, :register_expires, 3600),
        transport: Keyword.get(opts, :transport, :udp),
        supported_codecs: Keyword.get(opts, :supported_codecs, [:pcma, :opus])
      }

      # Initial state
      state = %{
        notify_pid: Keyword.get(opts, :notify_pid),
        subscribe_to: Keyword.get(opts, :subscribe_to, []),
        presence_states: %{},
        active_calls: %{},
        auto_answer: Keyword.get(opts, :auto_answer, false)
      }

      {:ok, config, state}
    end

    # ========================================================================
    # Registration Callbacks
    # ========================================================================

    @impl true
    def handle_registered(info, state) do
      Logger.info("[Softphone] Registered successfully, expires in #{info.expires}s")
      notify(state, {:registered, info})

      # Subscribe to presence after registration
      Enum.each(state.subscribe_to, fn presentity ->
        Logger.debug("[Softphone] Subscribing to presence: #{presentity}")
        # Note: We can't call SoftphoneClient here as we don't have the pid
        # In practice, you'd schedule this via send/2 or use a separate process
      end)

      {:ok, state}
    end

    @impl true
    def handle_registration_failed(reason, state) do
      Logger.error("[Softphone] Registration failed: #{inspect(reason)}")
      notify(state, {:registration_failed, reason})

      # Retry after delay
      {:retry, 5000, state}
    end

    @impl true
    def handle_unregistered(state) do
      Logger.info("[Softphone] Unregistered")
      notify(state, :unregistered)
      {:ok, state}
    end

    # ========================================================================
    # Presence Callbacks
    # ========================================================================

    @impl true
    def handle_presence_update(presentity, presence, state) do
      status = presence[:status] || :unknown
      note = presence[:note]

      Logger.info("[Softphone] #{presentity} is #{status}#{if note, do: ": #{note}", else: ""}")
      notify(state, {:presence_update, presentity, presence})

      # Track presence states
      presence_states = Map.put(state.presence_states, presentity, presence)
      {:ok, %{state | presence_states: presence_states}}
    end

    @impl true
    def handle_subscription_terminated(presentity, reason, state) do
      Logger.warning("[Softphone] Subscription to #{presentity} terminated: #{inspect(reason)}")
      notify(state, {:subscription_terminated, presentity, reason})

      # Remove from tracked states
      presence_states = Map.delete(state.presence_states, presentity)
      {:ok, %{state | presence_states: presence_states}}
    end

    @impl true
    def handle_publish_success(state) do
      Logger.debug("[Softphone] Presence published successfully")
      notify(state, :publish_success)
      {:ok, state}
    end

    @impl true
    def handle_publish_failed(reason, state) do
      Logger.warning("[Softphone] Presence publish failed: #{inspect(reason)}")
      notify(state, {:publish_failed, reason})
      {:ok, state}
    end

    # ========================================================================
    # Call Callbacks
    # ========================================================================

    @impl true
    def handle_incoming_call(call_info, state) do
      from = call_info[:from] || "unknown"
      call_id = call_info[:call_id]

      Logger.info("[Softphone] Incoming call from #{from} (call_id: #{call_id})")
      notify(state, {:incoming_call, call_info})

      active_calls = Map.put(state.active_calls, call_id, %{from: from, direction: :inbound})
      new_state = %{state | active_calls: active_calls}

      if state.auto_answer do
        Logger.info("[Softphone] Auto-answering call")
        {:answer, [], new_state}
      else
        Logger.info("[Softphone] Ringing...")
        {:ring, new_state}
      end
    end

    @impl true
    def handle_ringing(call_id, state) do
      Logger.info("[Softphone] Remote party ringing (call_id: #{call_id})")
      notify(state, {:ringing, call_id})
      {:ok, state}
    end

    @impl true
    def handle_call_answered(call_id, state) do
      Logger.info("[Softphone] Call answered (call_id: #{call_id})")
      notify(state, {:call_answered, call_id})

      # Update call state
      active_calls =
        Map.update(state.active_calls, call_id, %{state: :connected}, fn call ->
          Map.put(call, :state, :connected)
        end)

      {:ok, %{state | active_calls: active_calls}}
    end

    @impl true
    def handle_call_rejected(call_id, reason, state) do
      Logger.info("[Softphone] Call rejected: #{inspect(reason)} (call_id: #{call_id})")
      notify(state, {:call_rejected, call_id, reason})

      active_calls = Map.delete(state.active_calls, call_id)
      {:ok, %{state | active_calls: active_calls}}
    end

    @impl true
    def handle_call_ended(call_id, reason, state) do
      Logger.info("[Softphone] Call ended: #{inspect(reason)} (call_id: #{call_id})")
      notify(state, {:call_ended, call_id, reason})

      active_calls = Map.delete(state.active_calls, call_id)
      {:ok, %{state | active_calls: active_calls}}
    end

    # ========================================================================
    # Private Helpers
    # ========================================================================

    defp notify(%{notify_pid: nil}, _event), do: :ok

    defp notify(%{notify_pid: pid}, event) when is_pid(pid) do
      send(pid, {:softphone_event, event})
    end
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a softphone with the given options.

  ## Options

  - `:username` - SIP username (required)
  - `:domain` - SIP domain (required)
  - `:password` - SIP password for authentication
  - `:auto_register` - Register automatically on start (default: true)
  - `:subscribe_to` - List of SIP URIs to subscribe to for presence
  - `:auto_answer` - Automatically answer incoming calls (default: false)
  - `:notify_pid` - PID to receive `{:softphone_event, event}` messages

  ## Examples

      # Basic start
      {:ok, phone} = SoftphoneExample.start(username: "alice", domain: "example.com")

      # With presence subscriptions
      {:ok, phone} = SoftphoneExample.start(
        username: "alice",
        domain: "example.com",
        password: "secret",
        subscribe_to: ["sip:bob@example.com"]
      )
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    SoftphoneClient.start_link(
      handler: ExampleHandler,
      handler_opts: opts
    )
  end

  @doc """
  Make an outbound call.

  ## Examples

      {:ok, call_id} = SoftphoneExample.call(phone, "sip:bob@example.com")
  """
  @spec call(pid(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def call(phone, destination) do
    SoftphoneClient.dial(phone, destination)
  end

  @doc """
  Answer an incoming call.
  """
  @spec answer(pid(), String.t()) :: :ok | {:error, term()}
  def answer(phone, call_id) do
    SoftphoneClient.answer(phone, call_id)
  end

  @doc """
  Reject an incoming call.

  ## Status Codes

  - `486` - Busy Here (default)
  - `603` - Decline
  - `480` - Temporarily Unavailable
  """
  @spec reject(pid(), String.t(), integer()) :: :ok | {:error, term()}
  def reject(phone, call_id, status_code \\ 486) do
    SoftphoneClient.reject(phone, call_id, status_code)
  end

  @doc """
  Hang up an active call.
  """
  @spec hangup(pid(), String.t()) :: :ok | {:error, term()}
  def hangup(phone, call_id) do
    SoftphoneClient.hangup(phone, call_id)
  end

  @doc """
  Place a call on hold.
  """
  @spec hold(pid(), String.t()) :: :ok | {:error, term()}
  def hold(phone, call_id) do
    SoftphoneClient.hold(phone, call_id)
  end

  @doc """
  Resume a held call.
  """
  @spec resume(pid(), String.t()) :: :ok | {:error, term()}
  def resume(phone, call_id) do
    SoftphoneClient.resume(phone, call_id)
  end

  @doc """
  Send DTMF digits.

  ## Examples

      :ok = SoftphoneExample.send_dtmf(phone, call_id, "1234#")
  """
  @spec send_dtmf(pid(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_dtmf(phone, call_id, digits) do
    SoftphoneClient.send_dtmf(phone, call_id, digits)
  end

  @doc """
  Set presence status.

  ## Examples

      # Available
      :ok = SoftphoneExample.set_presence(phone, :open, "At my desk")

      # Away
      :ok = SoftphoneExample.set_presence(phone, :closed, "In a meeting")
  """
  @spec set_presence(pid(), :open | :closed, String.t() | nil) :: :ok | {:error, term()}
  def set_presence(phone, status, note \\ nil) do
    SoftphoneClient.publish_presence(phone, %{status: status, note: note})
  end

  @doc """
  Subscribe to a contact's presence.
  """
  @spec watch(pid(), String.t()) :: :ok | {:error, term()}
  def watch(phone, presentity) do
    SoftphoneClient.subscribe(phone, presentity)
  end

  @doc """
  Unsubscribe from a contact's presence.
  """
  @spec unwatch(pid(), String.t()) :: :ok | {:error, term()}
  def unwatch(phone, presentity) do
    SoftphoneClient.unsubscribe(phone, presentity)
  end

  @doc """
  Unregister and stop the softphone.
  """
  @spec stop(pid()) :: :ok
  def stop(phone) do
    SoftphoneClient.unregister(phone)
    GenServer.stop(phone, :normal)
  end
end
