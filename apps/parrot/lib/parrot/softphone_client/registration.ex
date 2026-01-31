defmodule Parrot.SoftphoneClient.Registration do
  @moduledoc """
  Registration state machine for SIP softphone client.

  Manages the REGISTER lifecycle including:
  - Initial registration
  - 401/407 authentication challenge handling
  - Automatic re-registration before expiry
  - Unregistration (expires=0)

  ## States

  ```
  :unregistered → :registering → :registered
                       ↓              ↓
                :awaiting_auth ──────┘
                       ↓
                   :failed
  ```

  ## Usage

      {:ok, reg} = Registration.start_link(
        config: %{
          username: "alice",
          domain: "example.com",
          auth_password: "secret",
          register_expires: 3600
        },
        notify_pid: self()
      )

      :ok = Registration.register(reg)
      # Receive {:registration_event, :registered, %{expires: 3600}}

  ## Notifications

  The state machine sends messages to `notify_pid`:
  - `{:registration_event, :registered, %{expires: expires}}`
  - `{:registration_event, :registration_failed, reason}`
  - `{:registration_event, :unregistered, %{}}`
  """

  @behaviour :gen_statem

  require Logger

  alias ParrotSip.Auth

  # Re-register 60 seconds before expiry
  @re_register_buffer_seconds 60
  # Default timeout for registration attempts
  @registration_timeout_ms 32_000

  defstruct [
    :config,
    :notify_pid,
    :current_call_id,
    :transaction_pid,
    cseq: 1,
    nonce_count: %{},
    auth_attempted: false,
    re_register_scheduled: false
  ]

  @type t :: %__MODULE__{
          config: map(),
          notify_pid: pid() | nil,
          current_call_id: String.t() | nil,
          transaction_pid: pid() | nil,
          cseq: non_neg_integer(),
          nonce_count: map(),
          auth_attempted: boolean(),
          re_register_scheduled: boolean()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the registration state machine.

  ## Options

  - `:config` - Configuration map with username, domain, auth credentials
  - `:notify_pid` - PID to receive registration events
  - `:name` - Optional name for the process
  """
  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    :gen_statem.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Initiate registration with the SIP registrar.
  """
  def register(pid) do
    :gen_statem.call(pid, :register)
  end

  @doc """
  Unregister from the SIP registrar (expires=0).
  """
  def unregister(pid) do
    :gen_statem.call(pid, :unregister)
  end

  @doc """
  Manually refresh registration (trigger re-register).
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
    config = Keyword.fetch!(opts, :config)
    notify_pid = Keyword.fetch!(opts, :notify_pid)

    data = %__MODULE__{
      config: config,
      notify_pid: notify_pid
    }

    {:ok, :unregistered, data}
  end

  # ============================================================================
  # State: :unregistered
  # ============================================================================

  @doc false
  def unregistered(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def unregistered({:call, from}, :register, data) do
    case send_register(data) do
      {:ok, call_id, new_data} ->
        {:next_state, :registering,
         %{new_data | current_call_id: call_id, auth_attempted: false},
         [{:reply, from, :ok}, {:state_timeout, @registration_timeout_ms, :timeout}]}

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def unregistered({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :unregistered}]}
  end

  def unregistered({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def unregistered({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_registered}}]}
  end

  def unregistered(:info, msg, data) do
    Logger.warning("Registration unregistered: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # State: :registering
  # ============================================================================

  @doc false
  def registering(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def registering(:info, {:sip_response, %{status_code: code} = resp}, data)
      when code >= 200 and code < 300 do
    expires = extract_expires(resp)
    notify_handler(:registered, %{expires: expires}, data)

    # Schedule re-registration before expiry
    re_register_delay = max((expires - @re_register_buffer_seconds) * 1000, 1000)

    {:next_state, :registered,
     %{data | auth_attempted: false, re_register_scheduled: true},
     [{{:timeout, :re_register}, re_register_delay, :re_register}]}
  end

  def registering(:info, {:sip_response, %{status_code: code} = resp}, data)
      when code in [401, 407] do
    handle_auth_challenge(resp, data)
  end

  def registering(:info, {:sip_response, %{status_code: code}}, data)
      when code >= 300 do
    notify_handler(:registration_failed, {:status, code}, data)
    {:next_state, :failed, data}
  end

  def registering(:info, {:timeout, :registration_timeout}, data) do
    notify_handler(:registration_failed, :timeout, data)
    {:next_state, :failed, data}
  end

  def registering(:state_timeout, :timeout, data) do
    notify_handler(:registration_failed, :timeout, data)
    {:next_state, :failed, data}
  end

  def registering({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :registering}]}
  end

  def registering({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def registering({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :registering}}]}
  end

  def registering(:info, msg, data) do
    Logger.warning("Registration registering: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # State: :awaiting_auth
  # ============================================================================

  @doc false
  def awaiting_auth(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def awaiting_auth(:info, {:sip_response, %{status_code: code} = resp}, data)
      when code >= 200 and code < 300 do
    expires = extract_expires(resp)
    notify_handler(:registered, %{expires: expires}, data)

    re_register_delay = max((expires - @re_register_buffer_seconds) * 1000, 1000)

    {:next_state, :registered,
     %{data | auth_attempted: false, re_register_scheduled: true},
     [{{:timeout, :re_register}, re_register_delay, :re_register}]}
  end

  def awaiting_auth(:info, {:sip_response, %{status_code: code}}, data)
      when code in [401, 407] do
    # Second auth challenge - auth failed
    notify_handler(:registration_failed, :auth_failed, data)
    {:next_state, :failed, data}
  end

  def awaiting_auth(:info, {:sip_response, %{status_code: code}}, data)
      when code >= 300 do
    notify_handler(:registration_failed, {:status, code}, data)
    {:next_state, :failed, data}
  end

  def awaiting_auth(:state_timeout, :timeout, data) do
    notify_handler(:registration_failed, :timeout, data)
    {:next_state, :failed, data}
  end

  def awaiting_auth({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :awaiting_auth}]}
  end

  def awaiting_auth({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def awaiting_auth({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :awaiting_auth}}]}
  end

  def awaiting_auth(:info, msg, data) do
    Logger.warning("Registration awaiting_auth: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # State: :registered
  # ============================================================================

  @doc false
  def registered(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def registered({{:timeout, :re_register}, :re_register}, _event, data) do
    case send_register(data) do
      {:ok, call_id, new_data} ->
        {:next_state, :registering,
         %{new_data | current_call_id: call_id, auth_attempted: false, re_register_scheduled: false},
         [{:state_timeout, @registration_timeout_ms, :timeout}]}

      {:error, reason} ->
        notify_handler(:registration_failed, reason, data)
        {:next_state, :failed, data}
    end
  end

  def registered({:call, from}, :unregister, data) do
    case send_register(data, expires: 0) do
      {:ok, call_id, new_data} ->
        {:next_state, :unregistering,
         %{new_data | current_call_id: call_id},
         [{:reply, from, :ok}, {:state_timeout, @registration_timeout_ms, :timeout}]}

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def registered({:call, from}, :refresh, data) do
    case send_register(data) do
      {:ok, call_id, new_data} ->
        {:next_state, :registering,
         %{new_data | current_call_id: call_id, auth_attempted: false, re_register_scheduled: false},
         [{:reply, from, :ok}, {:state_timeout, @registration_timeout_ms, :timeout}]}

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def registered({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :registered}]}
  end

  def registered({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def registered(:info, msg, data) do
    Logger.warning("Registration registered: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # State: :unregistering
  # ============================================================================

  @doc false
  def unregistering(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def unregistering(:info, {:sip_response, %{status_code: code}}, data)
      when code >= 200 and code < 300 do
    notify_handler(:unregistered, %{}, data)
    {:next_state, :unregistered, %{data | re_register_scheduled: false}}
  end

  def unregistering(:info, {:sip_response, %{status_code: code}}, data)
      when code >= 300 do
    # Failed to unregister - still consider ourselves unregistered
    notify_handler(:unregistered, %{}, data)
    {:next_state, :unregistered, data}
  end

  def unregistering(:state_timeout, :timeout, data) do
    # Timeout unregistering - consider ourselves unregistered anyway
    notify_handler(:unregistered, %{}, data)
    {:next_state, :unregistered, data}
  end

  def unregistering({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :unregistering}]}
  end

  def unregistering({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def unregistering({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :unregistering}}]}
  end

  def unregistering(:info, msg, data) do
    Logger.warning("Registration unregistering: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # State: :failed
  # ============================================================================

  @doc false
  def failed(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def failed({:call, from}, :register, data) do
    # Allow retry from failed state
    case send_register(data) do
      {:ok, call_id, new_data} ->
        {:next_state, :registering,
         %{new_data | current_call_id: call_id, auth_attempted: false},
         [{:reply, from, :ok}, {:state_timeout, @registration_timeout_ms, :timeout}]}

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def failed({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :failed}]}
  end

  def failed({:call, from}, :get_data, data) do
    {:keep_state_and_data, [{:reply, from, data}]}
  end

  def failed({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :failed}}]}
  end

  def failed(:info, msg, data) do
    Logger.warning("Registration failed: unexpected message #{inspect(msg)}")
    {:keep_state, data}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  @spec send_register(t(), keyword()) :: {:ok, String.t(), t()} | {:error, term()}
  defp send_register(data, opts \\ []) do
    # Validate config has required fields
    with {:ok, username} <- fetch_config(data.config, :username),
         {:ok, domain} <- fetch_config(data.config, :domain) do
      expires = Keyword.get(opts, :expires, data.config[:register_expires] || 3600)

      # Generate Call-ID
      call_id = generate_call_id()

      # Increment CSeq
      new_cseq = data.cseq + 1

      # TODO: Actually send REGISTER via ParrotSip.UA or Transaction.Client
      # For now, return success to allow state machine testing
      Logger.debug("Registration: sending REGISTER for #{username}@#{domain} with expires=#{expires}")

      {:ok, call_id, %{data | cseq: new_cseq}}
    end
  end

  defp fetch_config(config, key) do
    case Map.fetch(config, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} when is_atom(value) and not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_config, key}}
    end
  end

  defp handle_auth_challenge(resp, data) do
    if data.auth_attempted do
      # Already tried auth once - fail
      notify_handler(:registration_failed, :auth_failed, data)
      {:next_state, :failed, data}
    else
      # Check if we have credentials
      password = data.config[:auth_password]

      if password do
        case retry_with_auth(resp, data) do
          {:ok, new_data} ->
            {:next_state, :awaiting_auth, new_data,
             [{:state_timeout, @registration_timeout_ms, :timeout}]}

          {:error, reason} ->
            notify_handler(:registration_failed, reason, data)
            {:next_state, :failed, data}
        end
      else
        notify_handler(:registration_failed, :no_credentials, data)
        {:next_state, :failed, data}
      end
    end
  end

  defp retry_with_auth(resp, data) do
    # Get auth header based on status code
    auth_header =
      case resp.status_code do
        401 -> resp.headers["WWW-Authenticate"]
        407 -> resp.headers["Proxy-Authenticate"]
      end

    case Auth.parse_auth_header(auth_header) do
      {:ok, challenge} ->
        # Create authorization
        username = data.config[:auth_username] || data.config[:username]
        password = data.config[:auth_password]
        realm = challenge["realm"]
        nonce = challenge["nonce"]

        # Track nonce count
        nonce_key = {realm, nonce}
        nc = Map.get(data.nonce_count, nonce_key, 0) + 1
        nc_hex = :io_lib.format("~8.16.0b", [nc]) |> IO.iodata_to_binary()

        _auth_credentials =
          Auth.create_authorization(
            :register,
            "sip:#{data.config.domain}",
            challenge,
            username,
            password,
            nc: nc_hex
          )

        # TODO: Send authenticated REGISTER
        Logger.debug("Registration: sending authenticated REGISTER")

        new_nonce_count = Map.put(data.nonce_count, nonce_key, nc)
        {:ok, %{data | auth_attempted: true, nonce_count: new_nonce_count, cseq: data.cseq + 1}}

      {:error, reason} ->
        {:error, {:parse_error, reason}}
    end
  end

  defp extract_expires(resp) do
    # Try to extract from response
    resp[:expires] || resp.headers["Expires"] || 3600
  end

  defp notify_handler(event, info, data) do
    if data.notify_pid do
      send(data.notify_pid, {:registration_event, event, info})
    end
  end

  defp generate_call_id do
    "reg-#{:erlang.unique_integer([:positive])}-#{:rand.uniform(1_000_000)}"
  end
end
