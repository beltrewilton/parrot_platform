defmodule ParrotSip.UA do
  @moduledoc """
  User Agent (UA) GenServer that combines UAC and UAS functionality.

  This GenServer manages a SIP User Agent, handling both outgoing (client) and
  incoming (server) SIP transactions. It implements the ParrotSip.Handler behavior
  to receive incoming requests and routes them to user-defined callbacks.

  ## Usage

      defmodule MyUA do
        use ParrotSip.UA.Behaviour

        def init(_config) do
          {:ok, %{}}
        end

        def handle_ringing(_status, _response, state) do
          IO.puts("Phone is ringing...")
          {:ok, state}
        end

        def handle_answered(_status, _response, state) do
          IO.puts("Call answered!")
          {:ok, state}
        end

        def handle_incoming_call(_invite, _transaction, state) do
          {:accept, state}
        end

        def handle_bye(_bye, state) do
          {:ok, state}
        end
      end

      # Start the UA
      config = %ParrotSip.UA.Config{
        from: %ParrotSip.Headers.From{uri: "sip:alice@example.com", parameters: %{}},
        local_host: "192.168.1.100",
        local_port: 5060,
        outbound_proxy: "sip:proxy.example.com:5060"
      }

      {:ok, ua} = ParrotSip.UA.start_link(MyUA, config)
  """

  use GenServer
  require Logger

  alias ParrotSip.{Message, Handler, Uri}
  alias ParrotSip.Headers.Contact
  alias ParrotSip.UA.{Config, MessageBuilder}

  @behaviour Handler

  defstruct [
    # User's callback module
    :callback_module,
    # UA configuration
    :config,
    # User's state
    :user_state,
    # Active calls by Call-ID: %{call_id => %{type, call_state}}
    :calls,
    # Auth retry state by Call-ID: %{call_id => %{original_request, auth_attempted}}
    :auth_retry_state,
    # Active dialogs: %{dialog_id => %{call_id, dialog_struct}}
    :dialogs,
    # Nonce count for auth (increments per realm/nonce)
    :auth_nc,
    # Registration state: %{state, timer_ref, expires, retry_count}
    :registration
  ]

  @type t :: %__MODULE__{
          callback_module: module(),
          config: Config.t(),
          user_state: term(),
          calls: map(),
          auth_retry_state: map(),
          dialogs: map(),
          auth_nc: map(),
          registration: map() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts a UA GenServer.

  ## Parameters
  - `callback_module` - Module implementing ParrotSip.UA.Behaviour
  - `config` - UA configuration struct
  - `opts` - GenServer options (e.g., `name:`)

  ## Returns
  - `{:ok, pid}` - UA process started
  - `{:error, reason}` - Failed to start
  """
  @spec start_link(module(), Config.t(), keyword()) :: GenServer.on_start()
  def start_link(callback_module, %Config{} = config, opts \\ []) do
    GenServer.start_link(__MODULE__, {callback_module, config}, opts)
  end

  @doc """
  Gets the UA's Handler struct for passing to SIP stack.

  Returns a Handler struct that can be passed to transaction/dialog layers.
  """
  @spec get_handler(pid()) :: Handler.handler()
  def get_handler(ua_pid) do
    Handler.new(__MODULE__, ua_pid)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init({callback_module, %Config{} = config}) do
    case callback_module.init(config) do
      {:ok, user_state} ->
        state = %__MODULE__{
          callback_module: callback_module,
          config: config,
          user_state: user_state,
          calls: %{},
          auth_retry_state: %{},
          dialogs: %{},
          auth_nc: %{},
          registration: nil
        }

        # Start auto-registration if enabled
        if config.registration && config.registration.enabled do
          send(self(), :start_registration)
        end

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # ============================================================================
  # Handler Behaviour Implementation
  # ============================================================================

  @impl Handler
  def transp_request(_msg, _args) do
    :process_transaction
  end

  @impl Handler
  def transaction(_trans, _sip_msg, _args) do
    :process_uas
  end

  @impl Handler
  def transaction_stop(_trans, _result, _args) do
    :ok
  end

  @impl Handler
  def uas_request(uas, %Message{method: method} = sip_msg, handler) do
    # Route to method-specific handler if available
    case method do
      :invite -> handle_invite(uas, sip_msg, handler)
      :ack -> handle_ack(uas, sip_msg, handler)
      :bye -> handle_bye(uas, sip_msg, handler)
      :cancel -> handle_cancel(uas, sip_msg, handler)
      :options -> handle_options(uas, sip_msg, handler)
      :register -> handle_register(uas, sip_msg, handler)
      _ -> :ok
    end
  end

  @impl Handler
  def uas_cancel(_uas_id, _handler) do
    :ok
  end

  @impl Handler
  def process_ack(_sip_msg, _handler) do
    :ok
  end

  # ============================================================================
  # Method-Specific Handlers (UAS)
  # ============================================================================

  @impl Handler
  def handle_invite(uas, %Message{} = invite, %Handler{args: ua_pid}) do
    GenServer.cast(ua_pid, {:incoming_invite, uas, invite})
    :ok
  end

  defp handle_ack(_uas, %Message{} = ack, %Handler{args: ua_pid}) do
    GenServer.cast(ua_pid, {:incoming_ack, ack})
    :ok
  end

  @impl Handler
  def handle_bye(uas, %Message{} = bye, %Handler{args: ua_pid}) do
    GenServer.cast(ua_pid, {:incoming_bye, uas, bye})
    :ok
  end

  @impl Handler
  def handle_cancel(_uas, %Message{} = cancel, %Handler{args: ua_pid}) do
    GenServer.cast(ua_pid, {:incoming_cancel, cancel})
    :ok
  end

  @impl Handler
  def handle_options(uas, %Message{} = options, %Handler{args: ua_pid}) do
    GenServer.cast(ua_pid, {:incoming_options, uas, options})
    :ok
  end

  @impl Handler
  def handle_register(uas, %Message{} = register, %Handler{args: ua_pid}) do
    GenServer.cast(ua_pid, {:incoming_register, uas, register})
    :ok
  end

  # ============================================================================
  # GenServer handle_cast for Incoming Requests
  # ============================================================================

  @impl true
  def handle_cast({:incoming_invite, uas, invite}, state) do
    # Call user's handle_incoming_call callback
    case state.callback_module.handle_incoming_call(invite, uas, state.user_state) do
      {:accept, new_user_state} ->
        # Send 200 OK
        response = Message.reply(invite, 200, "OK")
        ParrotSip.Transaction.Server.response(response, uas)
        {:noreply, %{state | user_state: new_user_state}}

      {:accept, sdp_body, new_user_state} ->
        # Send 200 OK with SDP
        response = Message.reply(invite, 200, "OK")
        response = %{response | body: sdp_body}
        ParrotSip.Transaction.Server.response(response, uas)
        {:noreply, %{state | user_state: new_user_state}}

      {:ring, new_user_state} ->
        # Send 180 Ringing
        response = Message.reply(invite, 180, "Ringing")
        ParrotSip.Transaction.Server.response(response, uas)
        {:noreply, %{state | user_state: new_user_state}}

      {:reject, status_code, reason, new_user_state} ->
        # Send rejection response
        response = Message.reply(invite, status_code, reason)
        ParrotSip.Transaction.Server.response(response, uas)
        {:noreply, %{state | user_state: new_user_state}}
    end
  end

  def handle_cast({:incoming_ack, ack}, state) do
    # Call user's handle_ack callback if defined
    case state.callback_module.handle_ack(ack, state.user_state) do
      {:ok, new_user_state} ->
        {:noreply, %{state | user_state: new_user_state}}
    end
  end

  def handle_cast({:incoming_bye, uas, bye}, state) do
    # Call user's handle_bye callback
    case state.callback_module.handle_bye(bye, state.user_state) do
      {:ok, new_user_state} ->
        # Send 200 OK to BYE
        response = Message.reply(bye, 200, "OK")
        ParrotSip.Transaction.Server.response(response, uas)
        {:noreply, %{state | user_state: new_user_state}}
    end
  end

  def handle_cast({:incoming_cancel, cancel}, state) do
    # Call user's handle_cancel callback
    case state.callback_module.handle_cancel(cancel, state.user_state) do
      {:ok, new_user_state} ->
        {:noreply, %{state | user_state: new_user_state}}
    end
  end

  def handle_cast({:incoming_options, uas, options}, state) do
    # Auto-respond to OPTIONS with 200 OK
    response = Message.reply(options, 200, "OK")
    ParrotSip.Transaction.Server.response(response, uas)
    {:noreply, state}
  end

  def handle_cast({:incoming_register, uas, register}, state) do
    # Auto-respond to REGISTER with 200 OK
    # (This is for when UA receives REGISTER, not when it sends one)
    response = Message.reply(register, 200, "OK")
    ParrotSip.Transaction.Server.response(response, uas)
    {:noreply, state}
  end

  # UAC response - 180 Ringing
  def handle_cast(
        {:uac_response, callback_module,
         {:response, %Message{status_code: 180} = response}},
        state
      ) do
    case callback_module.handle_ringing(180, response, state.user_state) do
      {:ok, new_user_state} ->
        {:noreply, %{state | user_state: new_user_state}}

      {:stop, reason, new_user_state} ->
        {:stop, reason, %{state | user_state: new_user_state}}
    end
  end

  # UAC response - Other 1xx provisional (181, 182, 183)
  def handle_cast(
        {:uac_response, callback_module,
         {:response, %Message{status_code: status_code} = response}},
        state
      )
      when status_code >= 100 and status_code < 200 do
    case callback_module.handle_progress(status_code, response, state.user_state) do
      {:ok, new_user_state} ->
        {:noreply, %{state | user_state: new_user_state}}

      {:stop, reason, new_user_state} ->
        {:stop, reason, %{state | user_state: new_user_state}}
    end
  end

  # UAC response - 2xx Success
  def handle_cast(
        {:uac_response, callback_module,
         {:response, %Message{status_code: status_code} = response}},
        state
      )
      when status_code >= 200 and status_code < 300 do
    case callback_module.handle_answered(status_code, response, state.user_state) do
      {:ok, new_user_state} ->
        {:noreply, %{state | user_state: new_user_state}}

      {:stop, reason, new_user_state} ->
        {:stop, reason, %{state | user_state: new_user_state}}
    end
  end

  # UAC response - 3xx Redirect
  def handle_cast(
        {:uac_response, callback_module,
         {:response, %Message{status_code: status_code, contact: contacts} = response}},
        state
      )
      when status_code >= 300 and status_code < 400 do
    contact_list = contacts || []

    case callback_module.handle_redirect(status_code, response, contact_list, state.user_state) do
      {:redirect, contact, new_user_state} ->
        redirect_uri = extract_contact_uri(contact)

        case MessageBuilder.build_invite(state.config, redirect_uri, []) do
          {:ok, invite_msg} ->
            callback = make_uac_callback(callback_module)
            _transaction_id = ParrotSip.Transaction.Client.request(invite_msg, callback)
            {:noreply, %{state | user_state: new_user_state}}

          {:error, _reason} ->
            {:noreply, %{state | user_state: new_user_state}}
        end

      {:stop, reason, new_user_state} ->
        {:stop, reason, %{state | user_state: new_user_state}}
    end
  end

  # UAC response - 401/407 Authentication challenge
  def handle_cast(
        {:uac_response, _callback_module,
         {:response, %Message{status_code: status_code} = response}},
        state
      )
      when status_code in [401, 407] do
    handle_auth_challenge(response, state)
  end

  # UAC response - 4xx/5xx/6xx Error
  def handle_cast(
        {:uac_response, callback_module,
         {:response, %Message{status_code: status_code} = response}},
        state
      )
      when status_code >= 400 do
    case callback_module.handle_rejected(status_code, response, state.user_state) do
      {:ok, new_user_state} ->
        {:noreply, %{state | user_state: new_user_state}}

      {:stop, reason, new_user_state} ->
        {:stop, reason, %{state | user_state: new_user_state}}
    end
  end

  # UAC response - Transaction completed
  def handle_cast({:uac_response, _callback_module, {:stop, :normal}}, state) do
    {:noreply, state}
  end

  # UAC response - Timeout
  def handle_cast(
        {:uac_response, callback_module, {:timeout, timeout_type}},
        state
      ) do
    case callback_module.handle_timeout(timeout_type, state.user_state) do
      {:retry, new_user_state} ->
        {:noreply, %{state | user_state: new_user_state}}

      {:stop, reason, new_user_state} ->
        {:stop, reason, %{state | user_state: new_user_state}}
    end
  end

  # UAC response - Other/unknown
  def handle_cast({:uac_response, _callback_module, _other}, state) do
    {:noreply, state}
  end

  # Registration response - 2xx Success
  def handle_cast(
        {:register_response, callback_module,
         {:response, %Message{status_code: status_code} = response}},
        state
      )
      when status_code >= 200 and status_code < 300 do
    expires =
      response.expires || (state.config.registration && state.config.registration.expires) || 3600

    new_state = schedule_registration_refresh(state, expires)

    case callback_module.handle_register_response(status_code, response, new_state.user_state) do
      {:ok, new_user_state} ->
        {:noreply, %{new_state | user_state: new_user_state}}
    end
  end

  # Registration response - 4xx/5xx/6xx Error
  def handle_cast(
        {:register_response, callback_module,
         {:response, %Message{status_code: status_code} = response}},
        state
      )
      when status_code >= 400 do
    retry_count = (state.registration && state.registration.retry_count) || 0
    {:noreply, new_state} = schedule_registration_retry(state, retry_count)

    case callback_module.handle_register_response(status_code, response, new_state.user_state) do
      {:ok, new_user_state} ->
        {:noreply, %{new_state | user_state: new_user_state}}
    end
  end

  # Registration response - Other
  def handle_cast({:register_response, _callback_module, _transaction_result}, state) do
    {:noreply, state}
  end

  # ============================================================================
  # GenServer handle_call for Client API
  # ============================================================================

  @impl true
  def handle_call({:send_invite, to_uri, opts}, _from, state) do
    # Build INVITE message
    case MessageBuilder.build_invite(state.config, to_uri, opts) do
      {:ok, invite_msg} ->
        # Create callback that routes responses back to user's behaviour
        callback = make_uac_callback(state.callback_module)

        # Send via UAC
        transaction_id = ParrotSip.Transaction.Client.request(invite_msg, callback)

        call_id = invite_msg.call_id

        # Track call
        new_calls = Map.put(state.calls, call_id, %{
          type: :outgoing_call,
          state: :calling,
          to_uri: to_uri
        })

        # Store auth retry state for this call
        new_auth_retry = Map.put(state.auth_retry_state, call_id, %{
          original_request: invite_msg,
          auth_attempted: false
        })

        {:reply, {:ok, transaction_id}, %{state | calls: new_calls, auth_retry_state: new_auth_retry}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_register, opts}, _from, state) do
    # Build REGISTER message
    case MessageBuilder.build_register(state.config, opts) do
      {:ok, register_msg} ->
        # Allow user to modify REGISTER before sending
        case state.callback_module.handle_register(register_msg, state.user_state) do
          {:ok, modified_msg, new_user_state} ->
            # Create callback
            callback = make_register_callback(state.callback_module)

            # Send via UAC
            transaction_id = ParrotSip.Transaction.Client.request(modified_msg, callback)

            call_id = modified_msg.call_id

            # Track registration as a special "call"
            new_calls = Map.put(state.calls, call_id, %{
              type: :registration,
              state: :registering
            })

            # Store auth retry state for this registration
            new_auth_retry = Map.put(state.auth_retry_state, call_id, %{
              original_request: modified_msg,
              auth_attempted: false
            })

            {:reply, {:ok, transaction_id}, %{
              state
              | calls: new_calls,
                auth_retry_state: new_auth_retry,
                user_state: new_user_state
            }}

          {:cancel, new_user_state} ->
            {:reply, {:error, :cancelled_by_user}, %{state | user_state: new_user_state}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_bye, dialog_id, opts}, _from, state) do
    # Find dialog
    case Map.get(state.dialogs, dialog_id) do
      nil ->
        {:reply, {:error, :dialog_not_found}, state}

      dialog ->
        # Build BYE message
        # TODO: Track CSeq per dialog
        cseq = Keyword.get(opts, :cseq, 1)
        opts = Keyword.put(opts, :cseq, cseq)

        case MessageBuilder.build_bye(state.config, dialog, opts) do
          {:ok, bye_msg} ->
            # Create callback
            callback = make_uac_callback(state.callback_module)

            # Send via UAC
            transaction_id = ParrotSip.Transaction.Client.request(bye_msg, callback)

            # Store transaction
            new_transactions = Map.put(state.client_transactions, transaction_id, %{
              type: :bye,
              dialog_id: dialog_id
            })

            {:reply, {:ok, transaction_id}, %{state | client_transactions: new_transactions}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:cancel_invite, transaction_id}, _from, state) do
    # Send CANCEL
    :ok = ParrotSip.Transaction.Client.cancel(transaction_id)

    {:reply, :ok, state}
  end

  # ============================================================================
  # UAC Callback Factories
  # ============================================================================

  # Creates a callback function that routes UAC responses to user's behaviour module
  defp make_uac_callback(callback_module) do
    ua_pid = self()

    fn transaction_result ->
      GenServer.cast(ua_pid, {:uac_response, callback_module, transaction_result})
    end
  end

  # Creates a callback function specifically for REGISTER responses
  defp make_register_callback(callback_module) do
    ua_pid = self()

    fn transaction_result ->
      GenServer.cast(ua_pid, {:register_response, callback_module, transaction_result})
    end
  end


  # ============================================================================
  # GenServer handle_info for Registration
  # ============================================================================

  @impl true
  def handle_info(:start_registration, state) do
    send_registration(state)
  end

  def handle_info(:refresh_registration, state) do
    send_registration(state)
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Registration Management
  # ============================================================================

  defp send_registration(state) do
    case ParrotSip.UA.Client.register(self(), []) do
      {:ok, _transaction_id} ->
        # Mark registration as in progress
        new_registration = %{
          state: :registering,
          timer_ref: nil,
          expires: nil,
          retry_count: 0
        }

        {:noreply, %{state | registration: new_registration}}

      {:error, _reason} ->
        # Schedule retry
        schedule_registration_retry(state, 0)
    end
  end

  defp schedule_registration_retry(state, retry_count) do
    # Exponential backoff: retry_interval * (2 ^ retry_count), max 5 minutes
    base_interval = (state.config.registration && state.config.registration.retry_interval) || 60
    retry_interval = min(base_interval * :math.pow(2, retry_count), 300)
    retry_interval_ms = trunc(retry_interval * 1000)

    timer_ref = Process.send_after(self(), :refresh_registration, retry_interval_ms)

    new_registration = %{
      state: :retry_pending,
      timer_ref: timer_ref,
      expires: nil,
      retry_count: retry_count + 1
    }

    {:noreply, %{state | registration: new_registration}}
  end

  defp schedule_registration_refresh(state, expires) do
    # Refresh 30 seconds before expiry, or at half-interval, whichever is sooner
    refresh_in = max(trunc(expires / 2), expires - 30)
    refresh_in_ms = refresh_in * 1000

    # Cancel existing timer if any
    if state.registration && state.registration.timer_ref do
      Process.cancel_timer(state.registration.timer_ref)
    end

    timer_ref = Process.send_after(self(), :refresh_registration, refresh_in_ms)

    new_registration = %{
      state: :registered,
      timer_ref: timer_ref,
      expires: expires,
      retry_count: 0
    }

    %{state | registration: new_registration}
  end

  # ============================================================================
  # Authentication Handling
  # ============================================================================

  defp handle_auth_challenge(%Message{status_code: status_code, call_id: call_id} = response, state) do
    # Get auth header (WWW-Authenticate for 401, Proxy-Authenticate for 407)
    auth_header = get_auth_header(response, status_code)

    if auth_header do
      # Parse the challenge
      case ParrotSip.Auth.parse_auth_header(auth_header) do
        {:ok, challenge} ->
          # Look up auth retry state by Call-ID
          case Map.get(state.auth_retry_state, call_id) do
            nil ->
              # No auth retry state for this call
              {:noreply, state}

            auth_retry_data ->
              attempt_auth_retry(call_id, auth_retry_data, challenge, status_code, state)
          end

        {:error, _reason} ->
          # Failed to parse auth challenge
          {:noreply, state}
      end
    else
      # No auth header in response
      {:noreply, state}
    end
  end

  defp get_auth_header(%Message{other_headers: headers}, 401) do
    headers["WWW-Authenticate"] || headers["www-authenticate"]
  end

  defp get_auth_header(%Message{other_headers: headers}, 407) do
    headers["Proxy-Authenticate"] || headers["proxy-authenticate"]
  end

  defp attempt_auth_retry(call_id, auth_retry_data, challenge, status_code, state) do
    # Check if we already attempted auth for this call
    if auth_retry_data.auth_attempted do
      # Already tried auth, don't retry again - call user's handle_rejected
      case state.callback_module.handle_rejected(
             status_code,
             %Message{status_code: status_code},
             state.user_state
           ) do
        {:ok, new_user_state} ->
          {:noreply, %{state | user_state: new_user_state}}

        {:stop, reason, new_user_state} ->
          {:stop, reason, %{state | user_state: new_user_state}}
      end
    else
      # Check if we have credentials
      case get_credentials_for_challenge(challenge, state.config) do
        {:ok, username, password} ->
          retry_with_auth(
            call_id,
            auth_retry_data,
            challenge,
            username,
            password,
            status_code,
            state
          )

        :no_credentials ->
          # No credentials available, call handle_rejected
          case state.callback_module.handle_rejected(
                 status_code,
                 %Message{status_code: status_code},
                 state.user_state
               ) do
            {:ok, new_user_state} ->
              {:noreply, %{state | user_state: new_user_state}}

            {:stop, reason, new_user_state} ->
              {:stop, reason, %{state | user_state: new_user_state}}
          end
      end
    end
  end

  defp get_credentials_for_challenge(_challenge, %Config{registration: nil}), do: :no_credentials

  defp get_credentials_for_challenge(_challenge, %Config{
         registration: %{enabled: false}
       }),
       do: :no_credentials

  defp get_credentials_for_challenge(_challenge, %Config{
         registration: %{username: username, password: password}
       })
       when is_binary(username) and is_binary(password) do
    {:ok, username, password}
  end

  defp get_credentials_for_challenge(_challenge, _config), do: :no_credentials

  defp retry_with_auth(call_id, auth_retry_data, challenge, username, password, status_code, state) do
    original_request = auth_retry_data.original_request

    # Get or increment nonce count
    nonce_key = {challenge["realm"], challenge["nonce"]}
    nc = Map.get(state.auth_nc, nonce_key, 0) + 1
    nc_hex = :io_lib.format("~8.16.0b", [nc]) |> IO.iodata_to_binary()

    # Create authorization header
    auth_credentials =
      ParrotSip.Auth.create_authorization(
        original_request.method,
        Uri.to_string(original_request.request_uri),
        challenge,
        username,
        password,
        nc: nc_hex
      )

    auth_header_value = ParrotSip.Auth.format_auth_header(auth_credentials)

    # Add auth header to request
    auth_header_name = if status_code == 401, do: "Authorization", else: "Proxy-Authorization"

    updated_headers =
      Map.put(original_request.other_headers || %{}, auth_header_name, auth_header_value)

    authenticated_request = %{original_request | other_headers: updated_headers}

    # Send authenticated request
    callback = make_uac_callback(state.callback_module)
    _new_transaction_id = ParrotSip.Transaction.Client.request(authenticated_request, callback)

    # Update auth retry state - mark as attempted and update original request
    updated_auth_retry = %{
      original_request: authenticated_request,
      auth_attempted: true
    }

    new_auth_retry_state = Map.put(state.auth_retry_state, call_id, updated_auth_retry)
    new_auth_nc = Map.put(state.auth_nc, nonce_key, nc)

    {:noreply, %{state | auth_retry_state: new_auth_retry_state, auth_nc: new_auth_nc}}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp extract_contact_uri(%Contact{uri: uri}) when is_binary(uri), do: uri
  defp extract_contact_uri(%Contact{uri: %Uri{} = uri}), do: Uri.to_string(uri)
  defp extract_contact_uri(_), do: nil
end
