defmodule ParrotSip.Subscription do
  @moduledoc """
  SIP Subscription State Machine Implementation

  Implements RFC 6665 (supersedes RFC 3265) - SIP-Specific Event Notification
  and RFC 3903 - SIP PUBLISH.

  This module manages the lifecycle of SIP event subscriptions using Erlang's
  `:gen_statem` behavior. It supports both subscriber and notifier roles.

  ## RFC 6665 Section 4.1.2 - Subscription State Machine

  Subscription states:
  - **pending**: Subscription received but not yet authorized
  - **active**: Subscription is active and notifications will be sent
  - **terminated**: Subscription has ended

  State transitions:
  ```
                   SUBSCRIBE
                      |
                      v
              +---------------+
              |   :pending    |<----+ 1xx response
              +---------------+     |
                |          |        |
        2xx OK  |  4xx/5xx/6xx      |
                |          |        |
                |          v        |
                |    (terminated)   |
                |                   |
                v                   |
              +---------------+     |
              |   :active     |-----+
              +---------------+     re-SUBSCRIBE
                |
        expires |
        or BYE  |
                v
              +---------------+
              | :terminated   |
              +---------------+
                      |
                      v
                  (stopped)
  ```

  ## Roles

  - **:subscriber**: Entity that sends SUBSCRIBE and receives NOTIFYs
  - **:notifier**: Entity that receives SUBSCRIBE and sends NOTIFYs

  ## Timer Ownership

  Per the design, the Subscription gen_statem owns refresh/expires timers,
  while DialogStatem owns dialog-level state.

  ## Events Handled

  ### Subscriber Role
  - `{:cast, {:subscribe_response, response}}` - Process SUBSCRIBE response
  - `{:call, from, {:notify_received, notify}}` - Process received NOTIFY

  ### Notifier Role
  - `{:cast, :authorize}` - Authorize pending subscription
  - `{:call, from, {:send_notify, state, body}}` - Generate NOTIFY request
  - `{:cast, {:unsubscribe, msg}}` - Process unsubscribe (expires=0)
  - `{:cast, {:terminate, reason}}` - Terminate subscription
  - `{:call, from, {:publish, msg}}` - Process PUBLISH request (RFC 3903)

  ## References

  - RFC 6665: SIP-Specific Event Notification (supersedes RFC 3265)
  - RFC 6665 Section 4.1.2: Subscription State Machine
  - RFC 3903: Session Initiation Protocol (SIP) Extension for Event State Publication
  - RFC 3856: Presence Information Data Format (PIDF)
  """
  @behaviour :gen_statem

  require Logger

  alias ParrotSip.{Message, Branch}
  alias ParrotSip.Headers.{Via, From, To, CSeq, Event, SubscriptionState}

  @type role :: :subscriber | :notifier
  @type subscription_state :: :pending | :active | :terminated
  @type start_link_ret :: {:ok, pid()} | {:error, {:already_started, pid()}} | {:error, term()}

  defmodule Data do
    @moduledoc """
    Internal data structure for Subscription state machine.

    ## Fields

    - `id` - Unique subscription identifier
    - `role` - `:subscriber` or `:notifier`
    - `dialog_pid` - PID of the associated dialog
    - `event_package` - Event package name (e.g., "presence", "dialog")
    - `expires` - Subscription duration in seconds
    - `state_body` - Current state information body (for notifier)
    - `cseq` - Current CSeq number for requests
    - `dialog_mon` - Monitor reference for dialog process
    """
    defstruct [
      :id,
      :role,
      :dialog_pid,
      :event_package,
      :expires,
      :state_body,
      :cseq,
      :dialog_mon
    ]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            role: ParrotSip.Subscription.role(),
            dialog_pid: pid() | nil,
            event_package: String.t() | nil,
            expires: non_neg_integer() | nil,
            state_body: String.t() | nil,
            cseq: non_neg_integer(),
            dialog_mon: reference() | nil
          }
  end

  # API

  @doc """
  Returns child spec for use with supervisors.
  """
  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      type: :worker,
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc """
  Starts a new Subscription state machine.

  ## Options

  - `:id` - Unique subscription identifier (required)
  - `:role` - `:subscriber` or `:notifier` (required)
  - `:dialog_pid` - PID of the associated dialog (required)
  - `:event_package` - Event package name (required)
  - `:expires` - Subscription duration in seconds (required)

  ## Examples

      iex> Subscription.start_link([
      ...>   id: "sub-123",
      ...>   role: :subscriber,
      ...>   dialog_pid: dialog_pid,
      ...>   event_package: "presence",
      ...>   expires: 3600
      ...> ])
      {:ok, pid}
  """
  @spec start_link(keyword()) :: start_link_ret()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)

    :gen_statem.start_link(
      {:via, Registry, {ParrotSip.Registry, {:subscription, id}}},
      __MODULE__,
      opts,
      []
    )
  end

  @doc """
  Finds a subscription by ID.

  ## Examples

      iex> Subscription.find("sub-123")
      {:ok, pid}

      iex> Subscription.find("non-existent")
      {:error, :not_found}
  """
  @spec find(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def find(subscription_id) do
    case Registry.lookup(ParrotSip.Registry, {:subscription, subscription_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns the count of active subscriptions.
  """
  @spec count() :: non_neg_integer()
  def count do
    ParrotSip.Subscription.Supervisor.num_active()
  end

  # ===========================================================================
  # Public Introspection APIs
  # ===========================================================================

  @doc """
  Returns the current state name of the subscription state machine.

  ## Returns
    - `:pending` - Subscription received but not yet authorized
    - `:active` - Subscription is active
    - `:terminated` - Subscription has ended
  """
  @spec get_state(pid()) :: subscription_state()
  def get_state(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_state)
  end

  @doc """
  Returns the subscription role.

  ## Returns
    - `{:ok, :subscriber}` or `{:ok, :notifier}`
  """
  @spec get_role(pid()) :: {:ok, role()}
  def get_role(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_role)
  end

  @doc """
  Returns the subscription expiration time in seconds.

  ## Returns
    - `{:ok, expires}` where expires is a non-negative integer
  """
  @spec get_expires(pid()) :: {:ok, non_neg_integer() | nil}
  def get_expires(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_expires)
  end

  @doc """
  Returns the state body (for notifiers).

  ## Returns
    - `{:ok, state_body}` where state_body is a string or nil
  """
  @spec get_state_body(pid()) :: {:ok, String.t() | nil}
  def get_state_body(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_state_body)
  end

  # gen_statem callbacks

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    role = Keyword.fetch!(opts, :role)
    dialog_pid = Keyword.fetch!(opts, :dialog_pid)
    event_package = Keyword.fetch!(opts, :event_package)
    expires = Keyword.fetch!(opts, :expires)

    Logger.info(
      "subscription #{id}: initializing as #{role} for event package #{event_package}"
    )

    # Monitor the dialog process
    dialog_mon = Process.monitor(dialog_pid)

    data = %Data{
      id: id,
      role: role,
      dialog_pid: dialog_pid,
      event_package: event_package,
      expires: expires,
      state_body: nil,
      cseq: 1,
      dialog_mon: dialog_mon
    }

    # RFC 6665 Section 4.1.2: Initial state is pending
    {:ok, :pending, data}
  end

  # State: pending

  @doc false
  def pending({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :pending}]}
  end

  def pending({:call, from}, request, data) when request in [:get_role, :get_expires, :get_state_body] do
    result = handle_introspection_call(request, data)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def pending({:call, from}, {:notify_received, notify_msg}, data) do
    # RFC 6665 Section 4.1.3: Subscriber MUST accept NOTIFY in any state
    Logger.debug("subscription #{data.id}: received NOTIFY in pending state")
    process_notify(:pending, notify_msg, data, from)
  end

  def pending({:call, from}, {:send_notify, sub_state, body}, data) when data.role == :notifier do
    # Notifier can send NOTIFY from pending state
    Logger.debug("subscription #{data.id}: sending NOTIFY in pending state")
    notify_msg = build_notify_message(data, sub_state, body)
    {:keep_state, data, [{:reply, from, {:ok, notify_msg}}]}
  end

  def pending({:call, from}, {:publish, _publish_msg}, data) when data.role == :notifier do
    # Can receive PUBLISH in pending state
    Logger.debug("subscription #{data.id}: received PUBLISH in pending state")
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def pending({:call, from}, _event, _data) do
    # Unknown call
    {:keep_state_and_data, [{:reply, from, {:error, :unexpected_call}}]}
  end

  def pending(:cast, {:subscribe_response, %Message{status_code: code}}, data)
      when code >= 100 and code < 200 do
    # Provisional response - stay in pending
    Logger.debug("subscription #{data.id}: received #{code} provisional response")
    {:keep_state, data}
  end

  def pending(:cast, {:subscribe_response, %Message{status_code: code, expires: expires}}, data)
      when code >= 200 and code < 300 do
    # 2xx response - transition to active
    Logger.info("subscription #{data.id}: activated with #{code} response")

    # Update expires from response if present
    new_expires = expires || data.expires
    updated_data = %{data | expires: new_expires}

    # Set expiry timer
    actions = [{:state_timeout, new_expires * 1000, :subscription_expired}]

    {:next_state, :active, updated_data, actions}
  end

  def pending(:cast, {:subscribe_response, %Message{status_code: code}}, data)
      when code >= 300 do
    # Error response - terminate
    Logger.info("subscription #{data.id}: rejected with #{code} response")
    {:stop, :normal}
  end

  def pending(:cast, :authorize, data) when data.role == :notifier do
    # Notifier authorizes the subscription
    Logger.info("subscription #{data.id}: authorized, transitioning to active")

    # Set expiry timer
    actions = [{:state_timeout, data.expires * 1000, :subscription_expired}]

    {:next_state, :active, data, actions}
  end

  def pending(:cast, {:terminate, reason}, data) do
    Logger.info("subscription #{data.id}: terminating from pending state: #{inspect(reason)}")
    {:stop, :normal}
  end

  def pending(:info, {:state_timeout, :subscription_expired}, data) do
    Logger.info("subscription #{data.id}: expired in pending state")
    {:stop, :normal}
  end

  def pending(:info, {:DOWN, _ref, :process, _pid, _reason}, data) do
    Logger.info("subscription #{data.id}: dialog terminated")
    {:stop, :normal}
  end

  def pending(event_type, event_content, data) do
    handle_event(event_type, event_content, data)
  end

  # State: active

  @doc false
  def active({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :active}]}
  end

  def active({:call, from}, request, data) when request in [:get_role, :get_expires, :get_state_body] do
    result = handle_introspection_call(request, data)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def active({:call, from}, {:notify_received, notify_msg}, data) do
    Logger.debug("subscription #{data.id}: received NOTIFY in active state")
    process_notify(:active, notify_msg, data, from)
  end

  def active({:call, from}, {:send_notify, sub_state, body}, data) when data.role == :notifier do
    Logger.debug("subscription #{data.id}: sending NOTIFY in active state")
    notify_msg = build_notify_message(data, sub_state, body)
    {:keep_state, data, [{:reply, from, {:ok, notify_msg}}]}
  end

  def active({:call, from}, {:publish, publish_msg}, data) when data.role == :notifier do
    # RFC 3903: Process PUBLISH request
    Logger.debug("subscription #{data.id}: received PUBLISH")
    body = publish_msg.body
    updated_data = %{data | state_body: body}
    {:keep_state, updated_data, [{:reply, from, :ok}]}
  end

  def active({:call, from}, _event, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :unexpected_call}}]}
  end

  def active(:cast, {:subscribe_response, %Message{status_code: code, expires: expires}}, data)
      when code >= 200 and code < 300 do
    # Re-SUBSCRIBE response - update expires
    Logger.debug("subscription #{data.id}: re-SUBSCRIBE accepted with #{code}")

    new_expires = expires || data.expires
    updated_data = %{data | expires: new_expires}

    # Reset expiry timer
    actions = [{:state_timeout, new_expires * 1000, :subscription_expired}]

    {:keep_state, updated_data, actions}
  end

  def active(:cast, {:unsubscribe, _msg}, data) do
    # SUBSCRIBE with expires=0
    Logger.info("subscription #{data.id}: unsubscribe received")
    {:stop, :normal}
  end

  def active(:cast, {:terminate, reason}, data) do
    Logger.info("subscription #{data.id}: terminating from active state: #{inspect(reason)}")
    {:stop, :normal}
  end

  def active(:state_timeout, :subscription_expired, data) do
    Logger.info("subscription #{data.id}: expired")
    {:stop, :normal}
  end

  def active(:info, {:state_timeout, :subscription_expired}, data) do
    Logger.info("subscription #{data.id}: expired (via info)")
    {:stop, :normal}
  end

  def active(:info, {:DOWN, _ref, :process, _pid, _reason}, data) do
    Logger.info("subscription #{data.id}: dialog terminated")
    {:stop, :normal}
  end

  def active(event_type, event_content, data) do
    handle_event(event_type, event_content, data)
  end

  # State: terminated

  @doc false
  def terminated({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :terminated}]}
  end

  def terminated({:call, from}, request, data) when request in [:get_role, :get_expires, :get_state_body] do
    result = handle_introspection_call(request, data)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def terminated(_, _, _data) do
    {:stop, :normal}
  end

  # Private functions

  # Handle introspection calls for public API
  defp handle_introspection_call(:get_role, %Data{role: role}) do
    {:ok, role}
  end

  defp handle_introspection_call(:get_expires, %Data{expires: expires}) do
    {:ok, expires}
  end

  defp handle_introspection_call(:get_state_body, %Data{state_body: state_body}) do
    {:ok, state_body}
  end

  defp process_notify(_current_state, notify_msg, data, from) do
    # Check Subscription-State header
    case notify_msg.subscription_state do
      %SubscriptionState{state: :terminated} ->
        Logger.info("subscription #{data.id}: received terminated NOTIFY")
        # Reply first, then stop the process
        {:stop_and_reply, :normal, [{:reply, from, :ok}]}

      %SubscriptionState{state: :active, parameters: params} ->
        # Update expires if present
        new_expires =
          case Map.get(params, "expires") do
            nil -> data.expires
            exp_str -> String.to_integer(exp_str)
          end

        updated_data = %{data | expires: new_expires}
        {:keep_state, updated_data, [{:reply, from, :ok}]}

      %SubscriptionState{state: :pending} ->
        # Stay in current state
        {:keep_state, data, [{:reply, from, :ok}]}

      _ ->
        # Default - stay in current state
        {:keep_state, data, [{:reply, from, :ok}]}
    end
  end

  defp build_notify_message(data, sub_state, body) do
    subscription_state = SubscriptionState.new(sub_state)

    %Message{
      type: :request,
      method: :notify,
      request_uri: "sip:subscriber@example.com",
      version: "SIP/2.0",
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => Branch.generate()}
      },
      from: %From{
        display_name: "Notifier",
        uri: "sip:notifier@example.com",
        parameters: %{"tag" => "notifier-tag"}
      },
      to: %To{
        display_name: "Subscriber",
        uri: "sip:subscriber@example.com",
        parameters: %{"tag" => "subscriber-tag"}
      },
      call_id: "notify-#{data.id}@example.com",
      cseq: %CSeq{number: data.cseq, method: :notify},
      event: %Event{event: data.event_package, parameters: %{}},
      subscription_state: subscription_state,
      other_headers: %{},
      body: body || ""
    }
  end

  defp handle_event(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  defp handle_event(event_type, event_content, data) do
    Logger.warning(
      "subscription #{data.id}: unexpected event #{inspect(event_type)}: #{inspect(event_content)}"
    )

    :keep_state_and_data
  end
end
