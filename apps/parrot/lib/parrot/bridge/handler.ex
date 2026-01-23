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
  @spec transp_request(Message.t(), term()) :: :process_transaction | :noreply
  def transp_request(_msg, _args) do
    :process_transaction
  end

  @doc """
  Called when a transaction is created for an incoming request.

  Returns `:process_uas` to indicate this should be processed as a UAS transaction.
  """
  @impl true
  @spec transaction(ParrotSip.Transaction.t(), Message.t(), term()) :: :process_uas | :ok
  def transaction(_trans, _sip_msg, _args) do
    :process_uas
  end

  @doc """
  Called when a transaction stops.

  Performs any necessary cleanup.
  """
  @impl true
  @spec transaction_stop(ParrotSip.Transaction.t(), term(), term()) :: :ok
  def transaction_stop(_trans, _trans_result, _args) do
    :ok
  end

  @doc """
  Generic UAS request handler - fallback for methods without specific handlers.

  This is called when no method-specific handler (like `handle_invite/3`) is defined.
  """
  @impl true
  @spec uas_request(ParrotSip.Transaction.t(), Message.t(), term()) :: :ok
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
  @spec uas_cancel(term(), term()) :: :ok
  def uas_cancel(_uas_id, _args) do
    Logger.debug("[Bridge.Handler] Transaction cancelled")
    :ok
  end

  @doc """
  Called when an ACK is received for a 2xx response.

  This signals that the call is established and media can begin.
  """
  @impl true
  @spec process_ack(Message.t(), term()) :: :ok
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

  ## SDP Negotiation (FR-001 to FR-004)

  When the INVITE contains an SDP offer in the body:
  1. Creates a MediaSession for the call
  2. Calls MediaSession.process_offer() to generate an SDP answer
  3. Passes the SDP answer through context to ActionExecutor
  4. ActionExecutor includes the SDP answer in the 200 OK response

  This enables standard SIP clients (pjsua, linphone) to connect successfully.
  """
  @impl true
  @spec handle_invite(ParrotSip.Transaction.t(), Message.t(), map()) :: :ok
  def handle_invite(uas, req_sip_msg, %{router: router} = args) do
    Logger.debug("[Bridge.Handler] Received INVITE")

    # 1. Send 100 Trying first
    trying = Message.reply(req_sip_msg, 100, "Trying")
    send_response(uas, trying, args)

    # 2. Route through dispatcher to find handler
    case Dispatcher.dispatch(router, req_sip_msg) do
      {:ok, handler_module, _opts} ->
        # 3. Extract SDP offer and create MediaSession if present (FR-001, FR-002)
        case setup_media_session(req_sip_msg, args) do
          {:ok, media_pid, sdp_answer} ->
            # SDP negotiation succeeded - proceed with normal flow
            process_invite_with_media(
              uas,
              req_sip_msg,
              args,
              handler_module,
              media_pid,
              sdp_answer
            )

          :no_sdp ->
            # Late-offer flow - no SDP in INVITE, proceed without media
            process_invite_with_media(uas, req_sip_msg, args, handler_module, nil, nil)

          {:error, reason} ->
            # SDP negotiation failed (FR-009, FR-012) - invoke handle_sdp_error
            Logger.warning(
              "[Bridge.Handler] SDP negotiation failed, invoking handle_sdp_error: #{inspect(reason)}"
            )

            call = create_call_from_sip(req_sip_msg, handler_module)
            handle_sdp_error_result(handler_module, reason, call, uas, req_sip_msg, args)
        end

      {:no_match, _reason} ->
        Logger.warning("[Bridge.Handler] No route match for INVITE")
        # Send 404 Not Found
        not_found = Message.reply(req_sip_msg, 404, "Not Found")
        send_response(uas, not_found, args)
        :ok
    end
  end

  # Process INVITE with media (normal flow or late-offer)
  defp process_invite_with_media(uas, req_sip_msg, args, handler_module, media_pid, sdp_answer) do
    # Build invite data for Call.Server
    invite = %{
      id: Call.generate_id(),
      from: extract_uri_string(req_sip_msg.from),
      to: extract_uri_string(req_sip_msg.to),
      call_id: req_sip_msg.call_id,
      method: to_string(req_sip_msg.method)
    }

    # Build context for Call.Server (includes SIP context for ActionExecutor)
    context = %{
      uas: uas,
      sip_msg: req_sip_msg,
      media_pid: media_pid,
      dialog_id: req_sip_msg.call_id,
      sdp_answer: sdp_answer,
      response_fn: Map.get(args, :response_fn)
    }

    # Start Call.Server which will invoke handle_invite and execute operations
    case Parrot.Call.Server.start_link(
           handler: handler_module,
           invite: invite,
           context: context
         ) do
      {:ok, call_server_pid} ->
        Logger.debug("[Bridge.Handler] Started Call.Server #{inspect(call_server_pid)}")

        # Wire up MediaSession's notify_pid to Call.Server for event delivery
        # This ensures media events (play_complete, dtmf_collected, etc.) reach
        # the Call.Server which will invoke the appropriate handler callbacks
        if media_pid do
          session_id = "call_#{req_sip_msg.call_id}"
          ParrotMedia.MediaSession.set_notify_pid(session_id, call_server_pid)
          Logger.debug("[Bridge.Handler] Wired notify_pid for #{session_id} to Call.Server")
        end

        :ok

      {:error, reason} ->
        Logger.error("[Bridge.Handler] Failed to start Call.Server: #{inspect(reason)}")
        error_response = Message.reply(req_sip_msg, 500, "Internal Server Error")
        send_response(uas, error_response, args)
        :ok
    end
  end

  # Handle the result of handler.handle_sdp_error/2 (T034, T035, T036)
  defp handle_sdp_error_result(handler_module, reason, call, uas, req_sip_msg, args) do
    # Invoke handler's handle_sdp_error/2 callback
    result = handler_module.handle_sdp_error(reason, call)

    case result do
      {:noreply, _call} ->
        # Handler didn't handle the error - auto-reject with 488 (T036, FR-012)
        Logger.debug("[Bridge.Handler] Handler returned {:noreply, _}, auto-rejecting with 488")
        error_response = Message.reply(req_sip_msg, 488, "Not Acceptable Here")
        send_response(uas, error_response, args)
        :ok

      %Call{} = result_call ->
        # Handler returned operations - execute them
        operations = Call.get_operations(result_call)

        context = %{
          uas: uas,
          sip_msg: req_sip_msg,
          media_pid: nil,
          sdp_answer: nil,
          response_fn: Map.get(args, :response_fn)
        }

        case ActionExecutor.execute(operations, result_call, context) do
          {:ok, _updated_call} ->
            :ok

          {:error, exec_reason} ->
            Logger.error("[Bridge.Handler] ActionExecutor failed: #{inspect(exec_reason)}")
            error_response = Message.reply(req_sip_msg, 500, "Internal Server Error")
            send_response(uas, error_response, args)
            :ok
        end
    end
  end

  @doc """
  Handles incoming BYE requests.

  Looks up the Call.Server by call_id and dispatches the :hangup event,
  stops the media session, and sends 200 OK.
  """
  @impl true
  @spec handle_bye(ParrotSip.Transaction.t(), Message.t(), term()) :: :ok
  def handle_bye(uas, req_sip_msg, _args) do
    Logger.debug("[Bridge.Handler] Received BYE")

    call_id = req_sip_msg.call_id

    # Dispatch :hangup event to Call.Server (T042)
    # This notifies the DSL handler that the remote party has hung up
    case Parrot.Call.Server.lookup_by_call_id(call_id) do
      {:ok, call_server_pid} ->
        Logger.debug("[Bridge.Handler] Dispatching :hangup to Call.Server for #{call_id}")
        Parrot.Call.Server.cast_dispatch(call_server_pid, :hangup)

      {:error, :not_found} ->
        Logger.debug("[Bridge.Handler] No Call.Server found for #{call_id}")
    end

    # Stop the MediaSession for this call
    session_id = "call_#{call_id}"

    case ParrotMedia.MediaSessionSupervisor.find_session(session_id) do
      {:ok, media_pid} ->
        Logger.debug("[Bridge.Handler] Stopping MediaSession #{session_id}")
        ParrotMedia.MediaSessionSupervisor.stop_session(media_pid)

      {:error, :not_found} ->
        Logger.debug("[Bridge.Handler] No MediaSession found for #{session_id}")
    end

    # Send 200 OK
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
  @spec handle_register(ParrotSip.Transaction.t(), Message.t(), map()) :: :ok
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
            # RFC 3261 Section 10.3: Response MUST include Contact headers
            # with expires parameter for each binding
            bindings = handler_module.get_bindings(aor)
            contact_headers = build_contact_headers(bindings)

            # Build and send 200 OK response with Contact headers
            response =
              Message.reply(req_sip_msg, 200, "OK")
              |> Message.put_contact(contact_headers)

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
  # Handle single Contact struct (common case)
  defp extract_contact(%{contact: %{uri: %ParrotSip.Uri{} = uri}}) do
    ParrotSip.Uri.to_string(uri)
  end

  defp extract_contact(%{contact: %{uri: uri}}) when is_binary(uri), do: uri

  # Handle Contact as a list (less common)
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
  Builds Contact headers from registration bindings.

  Converts binding data (with contact URI, expires, registered_at, and optional q)
  into ParrotSip.Headers.Contact structs with expires parameters showing the
  remaining registration time and optional q-value for Contact priority.

  Per RFC 3261 Section 10.3, the registrar MUST return Contact headers
  in the 200 OK response with the actual expiration interval for each binding.
  Per RFC 3261 Section 10.2.1.2, q-values indicate preference (0.0-1.0).

  ## Arguments

  - `bindings` - List of binding maps with :contact, :expires, :registered_at,
    and optional :q keys

  ## Returns

  List of `%ParrotSip.Headers.Contact{}` structs with expires and optional q parameters.
  """
  @spec build_contact_headers([map()]) :: [ParrotSip.Headers.Contact.t()]
  def build_contact_headers([]), do: []

  def build_contact_headers(bindings) when is_list(bindings) do
    now = System.system_time(:second)

    Enum.map(bindings, fn binding ->
      # Calculate remaining time: expires - (now - registered_at)
      elapsed = now - binding.registered_at
      remaining = max(0, binding.expires - elapsed)

      # Create Contact with expires parameter
      # RFC 3261 Section 10.3: Response MUST include Contact with expires
      contact =
        ParrotSip.Headers.Contact.new(binding.contact)
        |> ParrotSip.Headers.Contact.with_expires(remaining)

      # Add optional q-value if present
      # RFC 3261 Section 10.2.1.2: q-value indicates Contact preference
      case Map.get(binding, :q) do
        nil -> contact
        q when is_float(q) -> ParrotSip.Headers.Contact.with_q(contact, q)
      end
    end)
  end

  @doc """
  Handles incoming OPTIONS requests.

  Returns server capabilities.
  """
  @impl true
  @spec handle_options(ParrotSip.Transaction.t(), Message.t(), term()) :: :ok
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
  @spec handle_cancel(ParrotSip.Transaction.t(), Message.t(), map()) :: :ok
  def handle_cancel(uas, req_sip_msg, args) do
    Logger.debug("[Bridge.Handler] Received CANCEL")

    response = Message.reply(req_sip_msg, 200, "OK")
    send_response(uas, response, args)

    :ok
  end

  @doc """
  Handles incoming SUBSCRIBE requests for presence event notification.

  Routes to the presence handler specified in the router.
  If no presence handler is configured, returns 404 Not Found.

  ## Subscription Flow (RFC 6665, RFC 3856)

  1. Extract watcher (From) and presentity (To/Request-URI) URIs
  2. Call handler.authorize_subscription/2 for authorization check
  3. Based on authorization result:
     - :allow → Store subscription, send 200 OK, trigger initial NOTIFY
     - :deny → Send 403 Forbidden
     - :pending → Store subscription, send 202 Accepted (for approval flows)
  4. Call handler.store_subscription/1 to persist the subscription
  5. Send appropriate response with Expires header

  ## RFC References

  - RFC 6665 Section 4.2.1: Creating a Subscription
  - RFC 3856 Section 5: SUBSCRIBE for Presence
  """
  @impl true
  @spec handle_subscribe(ParrotSip.Transaction.t(), Message.t(), map()) :: :ok
  def handle_subscribe(uas, req_sip_msg, %{router: router} = args) do
    Logger.debug("[Bridge.Handler] Received SUBSCRIBE")

    case router.__presence_handler__() do
      nil ->
        # No presence handler configured
        Logger.warning("[Bridge.Handler] No presence handler configured")
        not_found = Message.reply(req_sip_msg, 404, "Not Found")
        send_response(uas, not_found, args)
        :ok

      handler_module ->
        Logger.debug("[Bridge.Handler] Routing SUBSCRIBE to #{inspect(handler_module)}")
        process_subscription(handler_module, uas, req_sip_msg, args)
    end
  end

  # Process the subscription request through the handler callbacks
  # RFC 6665 Section 4.2.1: Subscription creation
  defp process_subscription(handler_module, uas, req_sip_msg, args) do
    # Extract watcher and presentity URIs from SIP message
    # RFC 3856 Section 5.1: Watcher = From, Presentity = To/Request-URI
    watcher = extract_watcher_uri(req_sip_msg.from)
    presentity = extract_presentity_uri(req_sip_msg)
    expires = extract_subscription_expires(req_sip_msg)

    Logger.debug(
      "[Bridge.Handler] Subscription: Watcher=#{watcher}, Presentity=#{presentity}, Expires=#{expires}"
    )

    # RFC 6665 Section 4.2.1: Check authorization
    case handler_module.authorize_subscription(watcher, presentity) do
      :allow ->
        # RFC 6665 Section 4.2.1.1: Authorized subscription
        handle_allowed_subscription(
          handler_module,
          uas,
          req_sip_msg,
          args,
          watcher,
          presentity,
          expires
        )

      :deny ->
        # RFC 6665 Section 4.2.1.2: Denied subscription
        Logger.warning(
          "[Bridge.Handler] Subscription denied for #{watcher} watching #{presentity}"
        )

        forbidden = Message.reply(req_sip_msg, 403, "Forbidden")
        send_response(uas, forbidden, args)
        :ok

      :pending ->
        # RFC 6665 Section 4.2.1.3: Pending subscription (requires approval)
        handle_pending_subscription(
          handler_module,
          uas,
          req_sip_msg,
          args,
          watcher,
          presentity,
          expires
        )
    end
  end

  # Handle an authorized subscription
  defp handle_allowed_subscription(
         handler_module,
         uas,
         req_sip_msg,
         args,
         watcher,
         presentity,
         expires
       ) do
    # Generate unique subscription ID
    subscription_id = generate_subscription_id()

    # Build subscription data
    subscription = %{
      watcher: watcher,
      presentity: presentity,
      dialog_id: req_sip_msg.call_id,
      expires: expires,
      subscription_id: subscription_id
    }

    # Store the subscription
    case handler_module.store_subscription(subscription) do
      :ok ->
        # Build and send 200 OK response with Expires header
        # RFC 6665 Section 4.2.1: Response MUST contain Expires header
        response =
          Message.reply(req_sip_msg, 200, "OK")
          |> Map.put(:expires, expires)

        send_response(uas, response, args)

        # Trigger initial NOTIFY with current presence state
        # RFC 3856 Section 5.2: Initial NOTIFY after subscription
        trigger_initial_notify(handler_module, subscription)

        :ok

      {:error, reason} ->
        Logger.error("[Bridge.Handler] Failed to store subscription: #{inspect(reason)}")
        error_response = Message.reply(req_sip_msg, 500, "Internal Server Error")
        send_response(uas, error_response, args)
        :ok
    end
  end

  # Handle a pending subscription (requires approval)
  defp handle_pending_subscription(
         handler_module,
         uas,
         req_sip_msg,
         args,
         watcher,
         presentity,
         expires
       ) do
    # Generate unique subscription ID
    subscription_id = generate_subscription_id()

    # Build subscription data with pending state
    subscription = %{
      watcher: watcher,
      presentity: presentity,
      dialog_id: req_sip_msg.call_id,
      expires: expires,
      subscription_id: subscription_id,
      state: :pending
    }

    # Store the subscription (even in pending state)
    case handler_module.store_subscription(subscription) do
      :ok ->
        # Build and send 202 Accepted response with Expires header
        # RFC 6665 Section 4.2.1.3: Pending subscriptions return 202
        response =
          Message.reply(req_sip_msg, 202, "Accepted")
          |> Map.put(:expires, expires)

        send_response(uas, response, args)
        :ok

      {:error, reason} ->
        Logger.error("[Bridge.Handler] Failed to store pending subscription: #{inspect(reason)}")
        error_response = Message.reply(req_sip_msg, 500, "Internal Server Error")
        send_response(uas, error_response, args)
        :ok
    end
  end

  # Extract watcher URI from From header
  # RFC 3856 Section 5.1: Watcher is identified in the From header
  defp extract_watcher_uri(%{uri: %ParrotSip.Uri{} = uri}) do
    ParrotSip.Uri.to_string(uri)
  end

  defp extract_watcher_uri(%{uri: uri}) when is_binary(uri), do: uri
  defp extract_watcher_uri(_), do: "unknown"

  # Extract presentity URI from To header or Request-URI
  # RFC 3856 Section 5.1: Presentity is identified in the Request-URI or To header
  defp extract_presentity_uri(%{to: %{uri: %ParrotSip.Uri{} = uri}}) do
    ParrotSip.Uri.to_string(uri)
  end

  defp extract_presentity_uri(%{to: %{uri: uri}}) when is_binary(uri), do: uri
  defp extract_presentity_uri(%{request_uri: uri}) when is_binary(uri), do: uri
  defp extract_presentity_uri(_), do: "unknown"

  # Extract subscription Expires value from message
  # RFC 6665 Section 4.2.1: Default is 3600 seconds
  defp extract_subscription_expires(%{expires: expires}) when is_integer(expires), do: expires
  defp extract_subscription_expires(_), do: 3600

  # Generate unique subscription ID
  defp generate_subscription_id do
    "sub-#{:erlang.unique_integer([:positive])}-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
  end

  # Trigger initial NOTIFY to the subscriber with current presence state
  # RFC 3856 Section 5.2: Notifier sends initial NOTIFY upon subscription
  defp trigger_initial_notify(handler_module, subscription) do
    # Get current presence state for the presentity
    presence_state = handler_module.get_presence(subscription.presentity)

    Logger.debug(
      "[Bridge.Handler] Triggering initial NOTIFY for #{subscription.watcher} watching #{subscription.presentity}"
    )

    # Use Parrot.Presence.notify/2 to send the NOTIFY
    # This is fire-and-forget, actual delivery is asynchronous
    Parrot.Presence.notify(subscription.presentity, presence_state)
  end

  @doc """
  Handles incoming PUBLISH requests for presence state publication.

  Routes to the presence handler specified in the router.
  If no presence handler is configured, returns 404 Not Found.

  ## Publication Flow (RFC 3903)

  1. Extract presentity URI from To header or Request-URI
  2. Parse PIDF+XML body to extract presence state
  3. Call handler.handle_publish/2 to store the presence state
  4. Send 200 OK response
  5. Trigger NOTIFY to all subscribers via Parrot.Presence.notify/2

  ## RFC References

  - RFC 3903 Section 4: PUBLISH Request Processing
  - RFC 3903 Section 4.4: PUBLISH Body (PIDF+XML)
  - RFC 3863: Presence Information Data Format (PIDF)
  """
  @impl true
  @spec handle_publish(ParrotSip.Transaction.t(), Message.t(), map()) :: :ok
  def handle_publish(uas, req_sip_msg, %{router: router} = args) do
    Logger.debug("[Bridge.Handler] Received PUBLISH")

    case router.__presence_handler__() do
      nil ->
        # No presence handler configured
        Logger.warning("[Bridge.Handler] No presence handler configured")
        not_found = Message.reply(req_sip_msg, 404, "Not Found")
        send_response(uas, not_found, args)
        :ok

      handler_module ->
        Logger.debug("[Bridge.Handler] Routing PUBLISH to #{inspect(handler_module)}")
        process_publication(handler_module, uas, req_sip_msg, args)
    end
  end

  # Process the publication request through the handler callbacks
  # RFC 3903 Section 4: PUBLISH request processing
  defp process_publication(handler_module, uas, req_sip_msg, args) do
    # Extract presentity URI from To header
    # RFC 3903 Section 4.1: Request-URI identifies the resource being published
    presentity = extract_presentity_uri(req_sip_msg)

    Logger.debug("[Bridge.Handler] Publication: Presentity=#{presentity}")

    # Parse PIDF+XML body to extract presence state
    # RFC 3903 Section 4.4: PUBLISH body contains the event state document
    case parse_pidf_body(req_sip_msg.body) do
      {:ok, presence_state} ->
        Logger.debug(
          "[Bridge.Handler] Parsed presence state: #{inspect(presence_state)}"
        )

        # Call handler to store the presence state
        # RFC 3903 Section 4.4: ESC stores the event state
        case handler_module.handle_publish(presentity, presence_state) do
          :ok ->
            # Build and send 200 OK response
            # RFC 3903 Section 4.6: 200 OK indicates successful publication
            response = Message.reply(req_sip_msg, 200, "OK")
            send_response(uas, response, args)

            # Trigger NOTIFY to all subscribers
            # RFC 3903 Section 4.4: ESC sends NOTIFY to subscribers after state change
            Parrot.Presence.notify(presentity, presence_state)

            :ok

          {:error, reason} ->
            Logger.error("[Bridge.Handler] Failed to handle publication: #{inspect(reason)}")
            error_response = Message.reply(req_sip_msg, 500, "Internal Server Error")
            send_response(uas, error_response, args)
            :ok
        end

      {:error, :invalid_pidf} ->
        # RFC 3903 Section 4.4: Invalid body results in 400 Bad Request
        Logger.warning("[Bridge.Handler] Invalid PIDF body in PUBLISH request")
        bad_request = Message.reply(req_sip_msg, 400, "Bad Request")
        send_response(uas, bad_request, args)
        :ok
    end
  end

  # Parse PIDF+XML body from PUBLISH request
  # RFC 3863: Presence Information Data Format
  defp parse_pidf_body(nil), do: {:error, :invalid_pidf}
  defp parse_pidf_body(""), do: {:error, :invalid_pidf}

  defp parse_pidf_body(body) when is_binary(body) do
    ParrotSip.Presence.Pidf.parse(body)
  end

  # ============================================================================
  # SDP Extraction and MediaSession Creation (US1: SDP Negotiation)
  # ============================================================================

  @doc """
  Extracts the SDP offer from an INVITE message body.

  Returns `{:ok, sdp_string}` if the body contains SDP content,
  or `{:error, :no_sdp}` if the body is nil, empty, or whitespace-only.

  ## Examples

      iex> extract_sdp_offer(%Message{body: "v=0\\r\\n..."})
      {:ok, "v=0\\r\\n..."}

      iex> extract_sdp_offer(%Message{body: nil})
      {:error, :no_sdp}
  """
  @spec extract_sdp_offer(Message.t()) :: {:ok, String.t()} | {:error, :no_sdp}
  def extract_sdp_offer(%Message{body: nil}), do: {:error, :no_sdp}
  def extract_sdp_offer(%Message{body: ""}), do: {:error, :no_sdp}

  def extract_sdp_offer(%Message{body: body}) when is_binary(body) do
    trimmed = String.trim(body)

    if trimmed == "" do
      {:error, :no_sdp}
    else
      {:ok, body}
    end
  end

  @doc """
  Sets up a MediaSession for the call if SDP offer is present.

  Creates a MediaSession, calls process_offer to negotiate SDP, and returns
  the media PID and SDP answer. If no SDP is present in the INVITE body,
  returns {:no_sdp} for late-offer flow.

  ## Parameters
  - `sip_msg` - The INVITE SIP message
  - `args` - Handler args (may contain media configuration)

  ## Returns
  - `{:ok, media_pid, sdp_answer}` - If SDP negotiation succeeds
  - `{:error, reason}` - If SDP negotiation fails (FR-009, FR-012)
  - `:no_sdp` - If no SDP in INVITE body (late-offer flow)
  """
  @spec setup_media_session(Message.t(), map()) ::
          {:ok, pid(), String.t()} | {:error, atom()} | :no_sdp
  def setup_media_session(sip_msg, args) do
    # Test injection: allow forcing SDP errors for testing (T034-T036)
    if Map.get(args, :force_sdp_error) do
      error_reason = Map.get(args, :sdp_error_reason, :codec_mismatch)
      Logger.debug("[Bridge.Handler] Test mode: forcing SDP error #{inspect(error_reason)}")
      {:error, error_reason}
    else
      setup_media_session_impl(sip_msg, args)
    end
  end

  # Actual implementation of setup_media_session
  defp setup_media_session_impl(sip_msg, _args) do
    case extract_sdp_offer(sip_msg) do
      {:ok, sdp_offer} ->
        # Create MediaSession for the call
        session_id = "call_#{sip_msg.call_id}"
        dialog_id = sip_msg.call_id

        media_opts = [
          id: session_id,
          dialog_id: dialog_id,
          role: :uas,
          media_handler: Parrot.DSL.MediaHandler,
          handler_args: %{call_id: sip_msg.call_id},
          audio_source: :silence,
          audio_sink: :none,
          supported_codecs: [:pcmu, :pcma]
        ]

        Logger.debug("[Bridge.Handler] Creating MediaSession for call #{sip_msg.call_id}")

        case ParrotMedia.MediaSessionSupervisor.start_session(media_opts) do
          {:ok, media_pid} ->
            # Call process_offer to get SDP answer (FR-003)
            case ParrotMedia.MediaSession.process_offer(media_pid, sdp_offer) do
              {:ok, sdp_answer} ->
                Logger.debug("[Bridge.Handler] SDP negotiation successful")
                {:ok, media_pid, sdp_answer}

              {:error, reason} ->
                Logger.error("[Bridge.Handler] SDP negotiation failed: #{inspect(reason)}")
                # Stop the media session on failure
                send(media_pid, {:stop_media})
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("[Bridge.Handler] Failed to create MediaSession: #{inspect(reason)}")
            {:error, :media_session_error}
        end

      {:error, :no_sdp} ->
        # No SDP in INVITE - late-offer flow, defer to ACK
        Logger.debug("[Bridge.Handler] No SDP in INVITE - late-offer flow")
        :no_sdp
    end
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
