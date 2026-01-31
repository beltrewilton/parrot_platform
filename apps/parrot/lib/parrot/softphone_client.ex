defmodule Parrot.SoftphoneClient do
  @moduledoc """
  A SIP softphone client that can register, manage presence, and make/receive calls.

  This module coordinates the Registration, PresenceSubscription, and PresencePublisher
  subsystems to provide a complete softphone client API.

  ## Usage

      # Define a handler module
      defmodule MyApp.PhoneHandler do
        use Parrot.SoftphoneHandler

        def init(opts) do
          config = %{
            username: opts.username,
            domain: opts.domain,
            auth_password: opts.password,
            auto_register: true
          }
          {:ok, config, %{}}
        end

        def handle_registered(info, state) do
          Logger.info("Registered: \#{inspect(info)}")
          {:ok, state}
        end

        def handle_incoming_call(call_info, state) do
          {:ring, state}  # or {:answer, [], state} or {:reject, 486, state}
        end

        # ... other callbacks
      end

      # Start the softphone
      {:ok, phone} = Parrot.SoftphoneClient.start_link(
        handler: MyApp.PhoneHandler,
        handler_opts: %{username: "alice", domain: "pbx.example.com", password: "secret"}
      )

      # Use the API
      :ok = Parrot.SoftphoneClient.register(phone)
      :ok = Parrot.SoftphoneClient.subscribe(phone, "sip:bob@example.com")
      :ok = Parrot.SoftphoneClient.publish_presence(phone, %{status: :open, note: "Available"})
      {:ok, call_id} = Parrot.SoftphoneClient.dial(phone, "sip:bob@example.com")

  ## Handler Callbacks

  See `Parrot.SoftphoneHandler` for the complete callback behavior.
  """

  use GenServer

  require Logger

  alias Parrot.SoftphoneClient.{Config, Registration, PresenceSubscription, PresencePublisher}

  @type call_id :: String.t()
  @type presence_state :: %{status: :open | :closed, note: String.t() | nil}

  defstruct [
    :config,
    :handler,
    :handler_state,
    :registration_pid,
    :publisher_pid,
    :subscription_supervisor,
    registration_status: :unregistered,
    subscriptions: %{},
    calls: %{}
  ]

  @type t :: %__MODULE__{
          config: map(),
          handler: module(),
          handler_state: term(),
          registration_pid: pid() | nil,
          publisher_pid: pid() | nil,
          subscription_supervisor: pid() | nil,
          registration_status: :unregistered | :registering | :registered | :unregistering,
          subscriptions: %{String.t() => pid()},
          calls: %{String.t() => map()}
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a softphone client.

  ## Options

  - `:handler` - Module implementing `Parrot.SoftphoneHandler` behavior (required)
  - `:handler_opts` - Options passed to handler's `init/1` callback
  - `:name` - Optional name for the process

  ## Example

      {:ok, phone} = Parrot.SoftphoneClient.start_link(
        handler: MyHandler,
        handler_opts: %{username: "alice", domain: "example.com"}
      )
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Register with the SIP server.
  """
  @spec register(pid()) :: :ok | {:error, term()}
  def register(pid), do: GenServer.call(pid, :register)

  @doc """
  Unregister from the SIP server.
  """
  @spec unregister(pid()) :: :ok | {:error, term()}
  def unregister(pid), do: GenServer.call(pid, :unregister)

  @doc """
  Get current registration status.
  """
  @spec registration_status(pid()) :: {:ok, :registered | :unregistered | :registering | :unregistering}
  def registration_status(pid), do: GenServer.call(pid, :registration_status)

  @doc """
  Subscribe to a presentity's presence.
  """
  @spec subscribe(pid(), String.t(), keyword()) :: :ok | {:error, term()}
  def subscribe(pid, presentity, opts \\ []) do
    GenServer.call(pid, {:subscribe, presentity, opts})
  end

  @doc """
  Unsubscribe from a presentity's presence.
  """
  @spec unsubscribe(pid(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(pid, presentity) do
    GenServer.call(pid, {:unsubscribe, presentity})
  end

  @doc """
  Publish own presence state.
  """
  @spec publish_presence(pid(), presence_state(), keyword()) :: :ok | {:error, term()}
  def publish_presence(pid, state, opts \\ []) do
    GenServer.call(pid, {:publish_presence, state, opts})
  end

  @doc """
  Make an outbound call.
  """
  @spec dial(pid(), String.t(), keyword()) :: {:ok, call_id()} | {:error, term()}
  def dial(pid, destination, opts \\ []) do
    GenServer.call(pid, {:dial, destination, opts})
  end

  @doc """
  Answer an incoming call.
  """
  @spec answer(pid(), call_id(), keyword()) :: :ok | {:error, term()}
  def answer(pid, call_id, opts \\ []) do
    GenServer.call(pid, {:answer, call_id, opts})
  end

  @doc """
  Reject an incoming call.
  """
  @spec reject(pid(), call_id(), non_neg_integer()) :: :ok | {:error, term()}
  def reject(pid, call_id, status_code \\ 486) do
    GenServer.call(pid, {:reject, call_id, status_code})
  end

  @doc """
  Hang up a call.
  """
  @spec hangup(pid(), call_id()) :: :ok | {:error, term()}
  def hangup(pid, call_id) do
    GenServer.call(pid, {:hangup, call_id})
  end

  @doc """
  Send DTMF digits.
  """
  @spec send_dtmf(pid(), call_id(), String.t()) :: :ok | {:error, term()}
  def send_dtmf(pid, call_id, digits) do
    GenServer.call(pid, {:send_dtmf, call_id, digits})
  end

  @doc """
  Place a call on hold.
  """
  @spec hold(pid(), call_id()) :: :ok | {:error, term()}
  def hold(pid, call_id), do: GenServer.call(pid, {:hold, call_id})

  @doc """
  Resume a held call.
  """
  @spec resume(pid(), call_id()) :: :ok | {:error, term()}
  def resume(pid, call_id), do: GenServer.call(pid, {:resume, call_id})

  @doc """
  Get current state (for testing).
  """
  def get_state(pid), do: GenServer.call(pid, :get_state)

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    handler_opts = Keyword.get(opts, :handler_opts, %{})

    # Call handler's init/1 to get config and initial state
    case handler.init(handler_opts) do
      {:ok, config, handler_state} ->
        init_with_config(handler, config, handler_state)

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp init_with_config(handler, config, handler_state) do
    # Validate config
    case Config.validate(config) do
      {:ok, validated_config} ->
        # Start registration process
        {:ok, reg_pid} =
          Registration.start_link(
            config: validated_config,
            notify_pid: self()
          )

        # Start subscription supervisor
        {:ok, sub_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

        data = %__MODULE__{
          config: validated_config,
          handler: handler,
          handler_state: handler_state,
          registration_pid: reg_pid,
          subscription_supervisor: sub_sup
        }

        # Auto-register if configured
        if validated_config.auto_register do
          send(self(), :auto_register)
        end

        {:ok, data}

      {:error, reason} ->
        {:stop, {:config_error, reason}}
    end
  end

  # ============================================================================
  # Registration Handlers
  # ============================================================================

  @impl true
  def handle_call(:register, _from, state) do
    case Registration.register(state.registration_pid) do
      :ok ->
        {:reply, :ok, %{state | registration_status: :registering}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:unregister, _from, state) do
    case Registration.unregister(state.registration_pid) do
      :ok ->
        {:reply, :ok, %{state | registration_status: :unregistering}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:registration_status, _from, state) do
    {:reply, {:ok, state.registration_status}, state}
  end

  # ============================================================================
  # Subscription Handlers
  # ============================================================================

  def handle_call({:subscribe, presentity, _opts}, _from, state) do
    if Map.has_key?(state.subscriptions, presentity) do
      {:reply, {:error, :already_subscribed}, state}
    else
      case start_subscription(presentity, state) do
        {:ok, sub_pid} ->
          subscriptions = Map.put(state.subscriptions, presentity, sub_pid)
          {:reply, :ok, %{state | subscriptions: subscriptions}}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:unsubscribe, presentity}, _from, state) do
    case Map.pop(state.subscriptions, presentity) do
      {nil, _} ->
        {:reply, {:error, :not_subscribed}, state}

      {sub_pid, subscriptions} ->
        PresenceSubscription.unsubscribe(sub_pid)
        DynamicSupervisor.terminate_child(state.subscription_supervisor, sub_pid)
        {:reply, :ok, %{state | subscriptions: subscriptions}}
    end
  end

  # ============================================================================
  # Presence Publishing Handlers
  # ============================================================================

  def handle_call({:publish_presence, presence_state, _opts}, _from, state) do
    state = ensure_publisher_started(state)

    case PresencePublisher.publish(state.publisher_pid, presence_state) do
      :ok ->
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  # ============================================================================
  # Call Management Handlers
  # ============================================================================

  def handle_call({:dial, destination, _opts}, _from, state) do
    call_id = generate_call_id()

    call_state = %{
      id: call_id,
      direction: :outbound,
      destination: destination,
      state: :dialing,
      held: false
    }

    # TODO: Actually initiate call via ParrotSip.UA
    Logger.debug("SoftphoneClient: dialing #{destination}")

    calls = Map.put(state.calls, call_id, call_state)
    {:reply, {:ok, call_id}, %{state | calls: calls}}
  end

  def handle_call({:answer, call_id, _opts}, _from, state) do
    case Map.get(state.calls, call_id) do
      nil ->
        {:reply, {:error, :call_not_found}, state}

      call_state ->
        # TODO: Actually answer via ParrotSip.UA
        Logger.debug("SoftphoneClient: answering call #{call_id}")

        updated_call = %{call_state | state: :answered}
        calls = Map.put(state.calls, call_id, updated_call)
        {:reply, :ok, %{state | calls: calls}}
    end
  end

  def handle_call({:reject, call_id, status_code}, _from, state) do
    case Map.get(state.calls, call_id) do
      nil ->
        {:reply, {:error, :call_not_found}, state}

      _call_state ->
        # TODO: Actually reject via ParrotSip.UA
        Logger.debug("SoftphoneClient: rejecting call #{call_id} with #{status_code}")

        calls = Map.delete(state.calls, call_id)
        {:reply, :ok, %{state | calls: calls}}
    end
  end

  def handle_call({:hangup, call_id}, _from, state) do
    case Map.get(state.calls, call_id) do
      nil ->
        {:reply, {:error, :call_not_found}, state}

      _call_state ->
        # TODO: Actually hangup via ParrotSip.UA
        Logger.debug("SoftphoneClient: hanging up call #{call_id}")

        # Call will be removed when call_ended event received
        {:reply, :ok, state}
    end
  end

  def handle_call({:hold, call_id}, _from, state) do
    case Map.get(state.calls, call_id) do
      nil ->
        {:reply, {:error, :call_not_found}, state}

      call_state ->
        # TODO: Actually send re-INVITE with hold SDP
        Logger.debug("SoftphoneClient: placing call #{call_id} on hold")

        updated_call = %{call_state | held: true}
        calls = Map.put(state.calls, call_id, updated_call)
        {:reply, :ok, %{state | calls: calls}}
    end
  end

  def handle_call({:resume, call_id}, _from, state) do
    case Map.get(state.calls, call_id) do
      nil ->
        {:reply, {:error, :call_not_found}, state}

      call_state ->
        # TODO: Actually send re-INVITE with active SDP
        Logger.debug("SoftphoneClient: resuming call #{call_id}")

        updated_call = %{call_state | held: false}
        calls = Map.put(state.calls, call_id, updated_call)
        {:reply, :ok, %{state | calls: calls}}
    end
  end

  def handle_call({:send_dtmf, call_id, digits}, _from, state) do
    case Map.get(state.calls, call_id) do
      nil ->
        {:reply, {:error, :call_not_found}, state}

      _call_state ->
        # TODO: Actually send DTMF via INFO or RTP
        Logger.debug("SoftphoneClient: sending DTMF #{digits} on call #{call_id}")
        {:reply, :ok, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # ============================================================================
  # Event Handlers (handle_info)
  # ============================================================================

  @impl true
  def handle_info(:auto_register, state) do
    Registration.register(state.registration_pid)
    {:noreply, %{state | registration_status: :registering}}
  end

  # Registration events
  def handle_info({:registration_event, :registered, info}, state) do
    new_handler_state = invoke_handler(:handle_registered, [info], state)

    {:noreply,
     %{state | handler_state: new_handler_state, registration_status: :registered}}
  end

  def handle_info({:registration_event, :registration_failed, reason}, state) do
    new_handler_state = invoke_handler(:handle_registration_failed, [reason], state)

    {:noreply,
     %{state | handler_state: new_handler_state, registration_status: :unregistered}}
  end

  def handle_info({:registration_event, :unregistered, _info}, state) do
    new_handler_state = invoke_handler(:handle_unregistered, [], state)

    {:noreply,
     %{state | handler_state: new_handler_state, registration_status: :unregistered}}
  end

  # Presence events
  def handle_info({:presence_event, :presence_update, presentity, presence}, state) do
    new_handler_state = invoke_handler(:handle_presence_update, [presentity, presence], state)
    {:noreply, %{state | handler_state: new_handler_state}}
  end

  def handle_info({:presence_event, :subscription_terminated, presentity, reason}, state) do
    new_handler_state = invoke_handler(:handle_subscription_terminated, [presentity, reason], state)
    subscriptions = Map.delete(state.subscriptions, presentity)
    {:noreply, %{state | handler_state: new_handler_state, subscriptions: subscriptions}}
  end

  def handle_info({:presence_event, :publish_success, _info}, state) do
    new_handler_state = invoke_handler(:handle_publish_success, [], state)
    {:noreply, %{state | handler_state: new_handler_state}}
  end

  def handle_info({:presence_event, :publish_failed, reason}, state) do
    new_handler_state = invoke_handler(:handle_publish_failed, [reason], state)
    {:noreply, %{state | handler_state: new_handler_state}}
  end

  # Call events
  def handle_info({:incoming_call, call_id, call_info}, state) do
    call_state = %{
      id: call_id,
      direction: :inbound,
      from: call_info.from,
      state: :ringing,
      held: false
    }

    calls = Map.put(state.calls, call_id, call_state)
    new_state = %{state | calls: calls}

    case invoke_handler_with_result(:handle_incoming_call, [call_info], new_state) do
      {:answer, _opts, handler_state} ->
        # Auto-answer
        Logger.debug("SoftphoneClient: auto-answering call #{call_id}")
        updated_call = %{call_state | state: :answered}
        calls = Map.put(calls, call_id, updated_call)
        {:noreply, %{new_state | handler_state: handler_state, calls: calls}}

      {:ring, handler_state} ->
        # Just ring
        {:noreply, %{new_state | handler_state: handler_state}}

      {:reject, status_code, handler_state} ->
        # Reject
        Logger.debug("SoftphoneClient: rejecting call #{call_id} with #{status_code}")
        calls = Map.delete(calls, call_id)
        {:noreply, %{new_state | handler_state: handler_state, calls: calls}}
    end
  end

  def handle_info({:call_answered, call_id, _info}, state) do
    new_handler_state = invoke_handler(:handle_call_answered, [call_id], state)

    calls =
      Map.update(state.calls, call_id, nil, fn call ->
        if call, do: %{call | state: :answered}, else: nil
      end)

    {:noreply, %{state | handler_state: new_handler_state, calls: calls}}
  end

  def handle_info({:call_rejected, call_id, reason}, state) do
    new_handler_state = invoke_handler(:handle_call_rejected, [call_id, reason], state)
    calls = Map.delete(state.calls, call_id)
    {:noreply, %{state | handler_state: new_handler_state, calls: calls}}
  end

  def handle_info({:call_ended, call_id, reason}, state) do
    new_handler_state = invoke_handler(:handle_call_ended, [call_id, reason], state)
    calls = Map.delete(state.calls, call_id)
    {:noreply, %{state | handler_state: new_handler_state, calls: calls}}
  end

  def handle_info({:ringing, call_id}, state) do
    new_handler_state = invoke_handler(:handle_ringing, [call_id], state)
    {:noreply, %{state | handler_state: new_handler_state}}
  end

  def handle_info(msg, state) do
    Logger.warning("SoftphoneClient: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp start_subscription(presentity, state) do
    child_spec = %{
      id: presentity,
      start:
        {PresenceSubscription, :start_link,
         [
           [
             presentity: presentity,
             config: state.config,
             notify_pid: self()
           ]
         ]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(state.subscription_supervisor, child_spec) do
      {:ok, pid} ->
        PresenceSubscription.subscribe(pid)
        {:ok, pid}

      {:error, _} = error ->
        error
    end
  end

  defp ensure_publisher_started(%{publisher_pid: nil} = state) do
    {:ok, pid} =
      PresencePublisher.start_link(
        config: state.config,
        notify_pid: self()
      )

    %{state | publisher_pid: pid}
  end

  defp ensure_publisher_started(state), do: state

  defp invoke_handler(callback, args, state) do
    case apply(state.handler, callback, args ++ [state.handler_state]) do
      {:ok, new_state} -> new_state
      {:retry, _delay, new_state} -> new_state
      _ -> state.handler_state
    end
  end

  defp invoke_handler_with_result(callback, args, state) do
    apply(state.handler, callback, args ++ [state.handler_state])
  end

  defp generate_call_id do
    "call-#{:erlang.unique_integer([:positive])}-#{:rand.uniform(1_000_000)}"
  end
end
