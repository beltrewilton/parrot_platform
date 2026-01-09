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
    ParrotSip.Transaction.Server.response(uas, response)
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
  def handle_invite(uas, req_sip_msg, %{router: _router} = _args) do
    Logger.debug("[Bridge.Handler] Received INVITE")

    # Future implementation:
    # 1. Route through router.dispatch(req_sip_msg)
    # 2. Create Parrot.Call struct
    # 3. Spawn Call.Server
    # 4. Invoke handler's handle_invite/1
    # 5. Execute returned operations via ActionExecutor

    # For now, send 100 Trying to acknowledge receipt
    trying = Message.reply(req_sip_msg, 100, "Trying")
    ParrotSip.Transaction.Server.response(uas, trying)

    :ok
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
    ParrotSip.Transaction.Server.response(uas, response)

    :ok
  end

  @doc """
  Handles incoming REGISTER requests.

  Routes to the registration handler specified in the router.
  """
  @impl true
  def handle_register(uas, req_sip_msg, %{router: _router} = _args) do
    Logger.debug("[Bridge.Handler] Received REGISTER")

    # Future implementation:
    # 1. Get registration handler from router.__register_handler__()
    # 2. Invoke handler callbacks (authenticate, store_binding, etc.)
    # 3. Send appropriate response

    # For now, send 200 OK
    response = Message.reply(req_sip_msg, 200, "OK")
    ParrotSip.Transaction.Server.response(uas, response)

    :ok
  end

  @doc """
  Handles incoming OPTIONS requests.

  Returns server capabilities.
  """
  @impl true
  def handle_options(uas, req_sip_msg, _args) do
    Logger.debug("[Bridge.Handler] Received OPTIONS")

    response = Message.reply(req_sip_msg, 200, "OK")
    ParrotSip.Transaction.Server.response(uas, response)

    :ok
  end

  @doc """
  Handles incoming CANCEL requests.
  """
  @impl true
  def handle_cancel(uas, req_sip_msg, _args) do
    Logger.debug("[Bridge.Handler] Received CANCEL")

    response = Message.reply(req_sip_msg, 200, "OK")
    ParrotSip.Transaction.Server.response(uas, response)

    :ok
  end
end
