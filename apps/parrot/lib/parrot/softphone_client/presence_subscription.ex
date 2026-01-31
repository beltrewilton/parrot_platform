defmodule Parrot.SoftphoneClient.PresenceSubscription do
  @moduledoc """
  Presence subscription state machine for watching a single presentity.

  Manages the SUBSCRIBE/NOTIFY lifecycle for SIP presence:
  - Send SUBSCRIBE with Event: presence
  - Handle 200 OK and wait for NOTIFY
  - Parse PIDF+XML from NOTIFY body
  - Refresh subscription before expiry
  - Handle termination via Subscription-State header

  ## States

  ```
  :idle → :subscribing → :active → :refreshing
               ↓            ↓           ↓
          :terminated ←────┴───────────┘
  ```

  ## Usage

      {:ok, sub} = PresenceSubscription.start_link(
        presentity: "sip:bob@example.com",
        config: config,
        notify_pid: self()
      )

      :ok = PresenceSubscription.subscribe(sub)
      # Receive {:presence_event, :presence_update, "sip:bob@example.com", presence}

  ## Notifications

  Sends messages to `notify_pid`:
  - `{:presence_event, :presence_update, presentity, %{status: :open | :closed, note: ...}}`
  - `{:presence_event, :subscription_terminated, presentity, reason}`
  """

  @behaviour :gen_statem

  require Logger

  # Refresh 60 seconds before expiry
  @refresh_buffer_seconds 60
  # Default timeout for SUBSCRIBE requests
  @subscribe_timeout_ms 32_000

  defstruct [
    :presentity,
    :config,
    :notify_pid,
    :dialog_id,
    :transaction_pid,
    expires: 3600,
    cseq: 1,
    refresh_scheduled: false
  ]

  @type t :: %__MODULE__{
          presentity: String.t(),
          config: map(),
          notify_pid: pid() | nil,
          dialog_id: String.t() | nil,
          transaction_pid: pid() | nil,
          expires: non_neg_integer(),
          cseq: non_neg_integer(),
          refresh_scheduled: boolean()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the presence subscription state machine.

  ## Options

  - `:presentity` - SIP URI of the user to watch
  - `:config` - Configuration map with username, domain, auth credentials
  - `:notify_pid` - PID to receive presence events
  - `:name` - Optional name for the process
  """
  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    :gen_statem.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Start subscribing to the presentity's presence.
  """
  def subscribe(pid, opts \\ []) do
    :gen_statem.call(pid, {:subscribe, opts})
  end

  @doc """
  Unsubscribe (sends SUBSCRIBE with Expires: 0).
  """
  def unsubscribe(pid) do
    :gen_statem.call(pid, :unsubscribe)
  end

  @doc """
  Manually refresh the subscription.
  """
  def refresh(pid) do
    :gen_statem.call(pid, :refresh)
  end

  @doc """
  Get current state (for testing).
  """
  def get_state(pid) do
    :gen_statem.call(pid, :get_state)
  end

  @doc """
  Get current state data (for testing).
  """
  def get_data(pid) do
    :gen_statem.call(pid, :get_data)
  end

  # ============================================================================
  # gen_statem Callbacks
  # ============================================================================

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    presentity = Keyword.fetch!(opts, :presentity)
    config = Keyword.fetch!(opts, :config)
    notify_pid = Keyword.fetch!(opts, :notify_pid)

    data = %__MODULE__{
      presentity: presentity,
      config: config,
      notify_pid: notify_pid
    }

    {:ok, :idle, data}
  end

  # ============================================================================
  # State: :idle
  # ============================================================================

  @doc false
  def idle(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def idle({:call, from}, {:subscribe, _opts}, data) do
    case send_subscribe(data) do
      {:ok, dialog_id, new_data} ->
        {:next_state, :subscribing,
         %{new_data | dialog_id: dialog_id},
         [{:reply, from, :ok}, {:state_timeout, @subscribe_timeout_ms, :timeout}]}

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def idle({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :idle}]}
  end

  def idle({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def idle({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_subscribed}}]}
  end

  def idle(:info, msg, data) do
    Logger.warning("PresenceSubscription idle: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # State: :subscribing
  # ============================================================================

  @doc false
  def subscribing(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def subscribing(:info, {:sip_response, %{status_code: code} = resp}, data)
      when code >= 200 and code < 300 do
    expires = extract_expires(resp)
    refresh_delay = max((expires - @refresh_buffer_seconds) * 1000, 30_000)

    {:next_state, :active,
     %{data | expires: expires, refresh_scheduled: true},
     [{{:timeout, :refresh}, refresh_delay, :refresh}]}
  end

  def subscribing(:info, {:sip_response, %{status_code: code}}, data)
      when code >= 300 do
    notify_handler(:subscription_terminated, data.presentity, {:status, code}, data)
    {:next_state, :terminated, data}
  end

  def subscribing(:info, {:timeout, :subscribe_timeout}, data) do
    notify_handler(:subscription_terminated, data.presentity, :timeout, data)
    {:next_state, :terminated, data}
  end

  def subscribing(:state_timeout, :timeout, data) do
    notify_handler(:subscription_terminated, data.presentity, :timeout, data)
    {:next_state, :terminated, data}
  end

  def subscribing({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :subscribing}]}
  end

  def subscribing({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def subscribing({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :subscribing}}]}
  end

  def subscribing(:info, msg, data) do
    Logger.warning("PresenceSubscription subscribing: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # State: :active
  # ============================================================================

  @doc false
  def active(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def active(:info, {:sip_notify, notify}, data) do
    handle_notify(notify, data)
  end

  def active({{:timeout, :refresh}, :refresh}, _event, data) do
    case send_subscribe(data, refresh: true) do
      {:ok, _dialog_id, new_data} ->
        {:next_state, :refreshing,
         %{new_data | refresh_scheduled: false},
         [{:state_timeout, @subscribe_timeout_ms, :timeout}]}

      {:error, reason} ->
        notify_handler(:subscription_terminated, data.presentity, reason, data)
        {:next_state, :terminated, data}
    end
  end

  def active({:call, from}, :refresh, data) do
    case send_subscribe(data, refresh: true) do
      {:ok, _dialog_id, new_data} ->
        {:next_state, :refreshing,
         %{new_data | refresh_scheduled: false},
         [{:reply, from, :ok}, {:state_timeout, @subscribe_timeout_ms, :timeout}]}

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def active({:call, from}, :unsubscribe, data) do
    case send_subscribe(data, expires: 0) do
      {:ok, _dialog_id, new_data} ->
        {:next_state, :unsubscribing,
         new_data,
         [{:reply, from, :ok}, {:state_timeout, @subscribe_timeout_ms, :timeout}]}

      {:error, _reason} ->
        # Even on error, consider unsubscribed locally
        {:next_state, :terminated, data, [{:reply, from, :ok}]}
    end
  end

  def active({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :active}]}
  end

  def active({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def active(:info, msg, data) do
    Logger.warning("PresenceSubscription active: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # State: :refreshing
  # ============================================================================

  @doc false
  def refreshing(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def refreshing(:info, {:sip_response, %{status_code: code} = resp}, data)
      when code >= 200 and code < 300 do
    expires = extract_expires(resp)
    refresh_delay = max((expires - @refresh_buffer_seconds) * 1000, 30_000)

    {:next_state, :active,
     %{data | expires: expires, refresh_scheduled: true},
     [{{:timeout, :refresh}, refresh_delay, :refresh}]}
  end

  def refreshing(:info, {:sip_response, %{status_code: code}}, data)
      when code >= 300 do
    notify_handler(:subscription_terminated, data.presentity, {:status, code}, data)
    {:next_state, :terminated, data}
  end

  def refreshing(:info, {:sip_notify, notify}, data) do
    # Can still receive NOTIFYs while refreshing
    handle_notify(notify, data)
  end

  def refreshing(:state_timeout, :timeout, data) do
    notify_handler(:subscription_terminated, data.presentity, :timeout, data)
    {:next_state, :terminated, data}
  end

  def refreshing({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :refreshing}]}
  end

  def refreshing({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def refreshing({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :refreshing}}]}
  end

  def refreshing(:info, msg, data) do
    Logger.warning("PresenceSubscription refreshing: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # State: :unsubscribing
  # ============================================================================

  @doc false
  def unsubscribing(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def unsubscribing(:info, {:sip_response, %{status_code: code}}, data)
      when code >= 200 and code < 300 do
    {:next_state, :terminated, %{data | refresh_scheduled: false}}
  end

  def unsubscribing(:info, {:sip_response, %{status_code: _code}}, data) do
    # Even on error, consider unsubscribed
    {:next_state, :terminated, data}
  end

  def unsubscribing(:state_timeout, :timeout, data) do
    {:next_state, :terminated, data}
  end

  def unsubscribing({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :unsubscribing}]}
  end

  def unsubscribing({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def unsubscribing({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :unsubscribing}}]}
  end

  def unsubscribing(:info, msg, data) do
    Logger.warning("PresenceSubscription unsubscribing: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # State: :terminated
  # ============================================================================

  @doc false
  def terminated(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def terminated({:call, from}, {:subscribe, _opts}, data) do
    # Allow re-subscribing from terminated state
    case send_subscribe(data) do
      {:ok, dialog_id, new_data} ->
        {:next_state, :subscribing,
         %{new_data | dialog_id: dialog_id},
         [{:reply, from, :ok}, {:state_timeout, @subscribe_timeout_ms, :timeout}]}

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def terminated({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :terminated}]}
  end

  def terminated({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def terminated({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :terminated}}]}
  end

  def terminated(:info, msg, data) do
    Logger.warning("PresenceSubscription terminated: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  @spec send_subscribe(t(), keyword()) :: {:ok, String.t(), t()} | {:error, term()}
  defp send_subscribe(data, opts \\ []) do
    # Validate config
    with {:ok, _username} <- fetch_config(data.config, :username),
         {:ok, _domain} <- fetch_config(data.config, :domain) do
      expires = Keyword.get(opts, :expires, data.expires)
      is_refresh = Keyword.get(opts, :refresh, false)

      # Generate dialog ID if not refreshing
      dialog_id = if is_refresh, do: data.dialog_id, else: generate_dialog_id()

      # Increment CSeq
      new_cseq = data.cseq + 1

      # TODO: Actually send SUBSCRIBE via ParrotSip
      # - Event: presence
      # - Accept: application/pidf+xml
      # - Expires: <value>
      Logger.debug(
        "PresenceSubscription: sending SUBSCRIBE for #{data.presentity} with expires=#{expires}"
      )

      {:ok, dialog_id, %{data | cseq: new_cseq}}
    end
  end

  defp fetch_config(config, key) do
    case Map.fetch(config, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} when is_atom(value) and not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_config, key}}
    end
  end

  defp handle_notify(notify, data) do
    subscription_state = parse_subscription_state(notify)

    case subscription_state do
      :terminated ->
        reason = parse_termination_reason(notify)
        notify_handler(:subscription_terminated, data.presentity, reason, data)
        {:next_state, :terminated, data}

      _ ->
        # Parse PIDF presence from body
        case parse_pidf(notify.body) do
          {:ok, presence} ->
            notify_handler(:presence_update, data.presentity, presence, data)
            {:keep_state, data}

          {:error, _reason} ->
            # Invalid PIDF, ignore
            {:keep_state, data}
        end
    end
  end

  defp parse_subscription_state(%{subscription_state: state}) when is_atom(state) do
    state
  end

  defp parse_subscription_state(%{headers: headers}) do
    case headers["Subscription-State"] do
      nil -> :active
      header when is_binary(header) ->
        cond do
          String.starts_with?(header, "terminated") -> :terminated
          String.starts_with?(header, "pending") -> :pending
          true -> :active
        end
    end
  end

  defp parse_subscription_state(_), do: :active

  defp parse_termination_reason(%{reason: reason}) when is_atom(reason) do
    reason
  end

  defp parse_termination_reason(%{headers: headers}) do
    case headers["Subscription-State"] do
      nil -> :unknown
      header when is_binary(header) ->
        # Parse "terminated;reason=expired"
        case Regex.run(~r/reason=(\w+)/, header) do
          [_, reason] -> String.to_atom(reason)
          _ -> :unknown
        end
    end
  end

  defp parse_termination_reason(_), do: :unknown

  defp parse_pidf(nil), do: {:error, :no_body}
  defp parse_pidf(""), do: {:error, :empty_body}

  defp parse_pidf(body) when is_binary(body) do
    # Simple PIDF parsing - extract basic status
    # In production, use a proper XML parser
    cond do
      String.contains?(body, "<basic>open</basic>") ->
        note = extract_note(body)
        {:ok, %{status: :open, note: note}}

      String.contains?(body, "<basic>closed</basic>") ->
        note = extract_note(body)
        {:ok, %{status: :closed, note: note}}

      true ->
        {:error, :invalid_pidf}
    end
  end

  defp extract_note(body) do
    case Regex.run(~r/<note>([^<]*)<\/note>/, body) do
      [_, note] -> note
      _ -> nil
    end
  end

  defp extract_expires(%{expires: expires}) when is_integer(expires) do
    expires
  end

  defp extract_expires(%{headers: headers}) do
    case headers["Expires"] do
      nil -> 3600
      expires when is_binary(expires) -> String.to_integer(expires)
      expires when is_integer(expires) -> expires
    end
  end

  defp extract_expires(_), do: 3600

  defp notify_handler(event, presentity, info, data) do
    if data.notify_pid do
      send(data.notify_pid, {:presence_event, event, presentity, info})
    end
  end

  defp generate_dialog_id do
    "sub-#{:erlang.unique_integer([:positive])}-#{:rand.uniform(1_000_000)}"
  end
end
