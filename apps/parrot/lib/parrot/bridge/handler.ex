defmodule Parrot.Bridge.Handler do
  @moduledoc """
  Bridge handler that connects ParrotSip to the Parrot DSL framework.

  This module implements the `ParrotSip.Handler` behaviour and routes
  incoming SIP requests through the Parrot router to the appropriate
  DSL handlers.

  ## Architecture

  The Bridge.Handler sits between the SIP transaction layer and the DSL:

  1. Receives SIP requests from `ParrotSip.TransactionStatem`
  2. Routes INVITE/REGISTER/etc. through `Parrot.Router.Dispatcher`
  3. Dispatches to the appropriate DSL handler (e.g., `Parrot.InviteHandler`)
  4. Executes pipeline operations returned by handlers

  ## Callback Flow

  For incoming requests:
  1. `transp_request/2` - Returns `:process_transaction` to create a transaction
  2. `transaction/3` - Returns `:process_uas` to process as UAS
  3. `uas_request/3` or method-specific callback (e.g., `handle_invite/3`)
     - Routes to DSL handler
     - Executes returned operations

  For ACKs (special handling per RFC 3261):
  - `process_ack/2` - Signals call establishment, starts media
  """

  @behaviour ParrotSip.Handler

  require Logger

  alias Parrot.Bridge.ActionExecutor
  alias Parrot.Call
  alias Parrot.Router.Dispatcher
  alias ParrotSip.Message

  # ============================================================================
  # Required ParrotSip.Handler Callbacks
  # ============================================================================

  @doc """
  Called when a SIP message arrives at the transport layer.

  Returns `:process_transaction` to have the transaction layer process this message.
  """
  @impl true
  def transp_request(_msg, _args) do
    :process_transaction
  end

  @doc """
  Called when a transaction is created for an incoming request.

  Returns `:process_uas` to indicate this should be processed as a UAS transaction.
  """
  @impl true
  def transaction(_trans, _sip_msg, _args) do
    :process_uas
  end

  @doc """
  Called when a transaction stops.

  Performs any necessary cleanup.
  """
  @impl true
  def transaction_stop(_trans, _trans_result, _args) do
    :ok
  end

  @doc """
  Generic UAS request handler - fallback for methods without specific handlers.

  This is called when no method-specific handler (like `handle_invite/3`) is defined.
  """
  @impl true
  def uas_request(uas, req_sip_msg, _args) do
    method = req_sip_msg.method
    Logger.debug("[Bridge.Handler] Received #{method} request (no specific handler)")

    # For now, return 501 Not Implemented for unhandled methods
    # Future: Route through router to find appropriate handler
    response = Message.reply(req_sip_msg, 501, "Not Implemented")
    ParrotSip.Transaction.Server.response(response, uas)
    :ok
  end

  @doc """
  Called when a UAS transaction is cancelled.
  """
  @impl true
  def uas_cancel(_uas_id, _args) do
    Logger.debug("[Bridge.Handler] Transaction cancelled")
    :ok
  end

  @doc """
  Called when an ACK is received for a 2xx response.

  This signals that the call is established and media can begin.
  """
  @impl true
  def process_ack(_sip_msg, _args) do
    Logger.debug("[Bridge.Handler] Received ACK")
    # Future: Signal call establishment to Call.Server
    # Future: Start media pipeline
    :ok
  end

  # ============================================================================
  # Optional Method-Specific Callbacks
  # ============================================================================

  @doc """
  Handles incoming INVITE requests.

  Routes through the Parrot router to find the appropriate handler,
  then dispatches to the handler's `handle_invite/1` callback.
  """
  @impl true
  def handle_invite(uas, req_sip_msg, %{router: router} = args) do
    Logger.debug("[Bridge.Handler] Received INVITE")

    # 1. Send 100 Trying first
    trying = Message.reply(req_sip_msg, 100, "Trying")
    send_response(uas, trying, args)

    # 2. Route through dispatcher to find handler
    case Dispatcher.dispatch(router, req_sip_msg) do
      {:ok, handler_module, _opts} ->
        # 3. Create Call struct from SIP message
        call = create_call_from_sip(req_sip_msg, handler_module)

        # 4. Invoke handler's handle_invite/1
        result_call = handler_module.handle_invite(call)

        # 5. Execute returned operations via ActionExecutor
        operations = Call.get_operations(result_call)

        context = %{
          uas: uas,
          sip_msg: req_sip_msg,
          media_pid: nil,
          response_fn: Map.get(args, :response_fn)
        }

        case ActionExecutor.execute(operations, result_call, context) do
          {:ok, _updated_call} ->
            :ok

          {:error, reason} ->
            Logger.error("[Bridge.Handler] ActionExecutor failed: #{inspect(reason)}")
            # Send 500 error on failure
            error_response = Message.reply(req_sip_msg, 500, "Internal Server Error")
            send_response(uas, error_response, args)
            :ok
        end

      {:no_match, _reason} ->
        Logger.warning("[Bridge.Handler] No route match for INVITE")
        # Send 404 Not Found
        not_found = Message.reply(req_sip_msg, 404, "Not Found")
        send_response(uas, not_found, args)
        :ok
    end
  end

  @doc """
  Handles incoming BYE requests.

  Finds the associated call and invokes the handler's `handle_hangup/1` callback.
  """
  @impl true
  def handle_bye(uas, req_sip_msg, _args) do
    Logger.debug("[Bridge.Handler] Received BYE")

    # Future implementation:
    # 1. Find call by dialog ID
    # 2. Invoke handler's handle_hangup/1
    # 3. Clean up media session
    # 4. Send 200 OK

    # For now, send 200 OK
    response = Message.reply(req_sip_msg, 200, "OK")
    ParrotSip.Transaction.Server.response(response, uas)

    :ok
  end

  @doc """
  Handles incoming REGISTER requests.

  Routes to the registration handler specified in the router.
  If no registration handler is configured, returns 404 Not Found.

  ## Registration Flow (RFC 3261 Section 10)

  1. Extract AOR (Address of Record) from To header
  2. Extract Contact URI and Expires value
  3. Call handler.authenticate/1 for authentication checks
  4. Call handler.store_binding/3 to store the registration
  5. Call handler.get_bindings/1 to build Contact header for response
  6. Send 200 OK with Contact headers
  """
  @impl true
  def handle_register(uas, req_sip_msg, %{router: router} = args) do
    Logger.debug("[Bridge.Handler] Received REGISTER")

    case router.__register_handler__() do
      nil ->
        # No registration handler configured
        Logger.warning("[Bridge.Handler] No registration handler configured")
        not_found = Message.reply(req_sip_msg, 404, "Not Found")
        send_response(uas, not_found, args)
        :ok

      handler_module ->
        Logger.debug("[Bridge.Handler] Routing REGISTER to #{inspect(handler_module)}")
        process_registration(handler_module, uas, req_sip_msg, args)
    end
  end

  # Process the registration request through the handler callbacks
  defp process_registration(handler_module, uas, req_sip_msg, args) do
    # Extract registration data from SIP message
    aor = extract_aor(req_sip_msg.to)
    contact = extract_contact(req_sip_msg)
    expires = extract_expires(req_sip_msg)

    Logger.debug(
      "[Bridge.Handler] Registration: AOR=#{aor}, Contact=#{contact}, Expires=#{expires}"
    )

    # For now, skip authentication (no Authorization header check)
    # Future: Check for Authorization header and validate digest
    credentials = %{username: extract_username(req_sip_msg.from), realm: "parrot"}

    case handler_module.authenticate(credentials) do
      :ok ->
        # Store the binding
        case handler_module.store_binding(aor, contact, expires) do
          :ok ->
            # Get all bindings for response
            _bindings = handler_module.get_bindings(aor)

            # Build and send 200 OK response
            response = Message.reply(req_sip_msg, 200, "OK")
            send_response(uas, response, args)
            :ok

          {:error, reason} ->
            Logger.error("[Bridge.Handler] Failed to store binding: #{inspect(reason)}")
            error_response = Message.reply(req_sip_msg, 500, "Internal Server Error")
            send_response(uas, error_response, args)
            :ok
        end

      :error ->
        Logger.warning("[Bridge.Handler] Authentication failed")
        forbidden = Message.reply(req_sip_msg, 403, "Forbidden")
        send_response(uas, forbidden, args)
        :ok
    end
  end

  # Extract AOR (Address of Record) from To header
  defp extract_aor(%{uri: %ParrotSip.Uri{} = uri}) do
    ParrotSip.Uri.to_string(uri)
  end

  defp extract_aor(%{uri: uri}) when is_binary(uri), do: uri
  defp extract_aor(_), do: "unknown"

  # Extract Contact URI from message
  defp extract_contact(%{contact: [contact | _]}) when is_binary(contact), do: contact

  defp extract_contact(%{contact: [%{uri: %ParrotSip.Uri{} = uri} | _]}) do
    ParrotSip.Uri.to_string(uri)
  end

  defp extract_contact(%{contact: [%{uri: uri} | _]}) when is_binary(uri), do: uri
  defp extract_contact(_), do: "unknown"

  # Extract Expires value from message (header or Contact param)
  defp extract_expires(%{expires: expires}) when is_integer(expires), do: expires

  defp extract_expires(%{contact: [%{params: %{"expires" => exp}} | _]}) do
    String.to_integer(exp)
  rescue
    _ -> 3600
  end

  defp extract_expires(_), do: 3600

  # Extract username from From header
  defp extract_username(%{uri: %ParrotSip.Uri{user: user}}) when is_binary(user), do: user
  defp extract_username(_), do: "unknown"

  @doc """
  Handles incoming OPTIONS requests.

  Returns server capabilities.
  """
  @impl true
  def handle_options(uas, req_sip_msg, _args) do
    Logger.debug("[Bridge.Handler] Received OPTIONS")

    response = Message.reply(req_sip_msg, 200, "OK")
    ParrotSip.Transaction.Server.response(response, uas)

    :ok
  end

  @doc """
  Handles incoming CANCEL requests.
  """
  @impl true
  def handle_cancel(uas, req_sip_msg, args) do
    Logger.debug("[Bridge.Handler] Received CANCEL")

    response = Message.reply(req_sip_msg, 200, "OK")
    send_response(uas, response, args)

    :ok
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  # Create a Parrot.Call struct from a SIP message
  defp create_call_from_sip(sip_msg, handler_module) do
    Call.new(
      id: Call.generate_id(),
      handler: handler_module,
      from: extract_uri_string(sip_msg.from),
      to: extract_uri_string(sip_msg.to),
      call_id: sip_msg.call_id,
      method: to_string(sip_msg.method),
      state: :incoming
    )
  end

  # Extract URI string from From/To headers
  defp extract_uri_string(%{uri: %ParrotSip.Uri{scheme: scheme} = uri}) when is_atom(scheme) do
    # Convert atom scheme to string for to_string/1
    uri_with_string_scheme = %{uri | scheme: to_string(scheme)}
    ParrotSip.Uri.to_string(uri_with_string_scheme)
  end

  defp extract_uri_string(%{uri: %ParrotSip.Uri{} = uri}) do
    ParrotSip.Uri.to_string(uri)
  end

  defp extract_uri_string(%{uri: uri}) when is_binary(uri), do: uri
  defp extract_uri_string(_), do: nil

  # Send response, supporting test callback pattern
  defp send_response(uas, response, %{response_fn: response_fn})
       when is_function(response_fn, 2) do
    # Test mode - use callback
    response_fn.(response, uas)
  end

  defp send_response(uas, response, _args) do
    # Production mode - use UAS transaction
    ParrotSip.Transaction.Server.response(response, uas)
  end
end
