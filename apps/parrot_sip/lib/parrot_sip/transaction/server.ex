defmodule ParrotSip.Transaction.Server do
  @moduledoc """
  Server Transaction Layer

  This module provides functionality for the server side of SIP transactions,
  including handling incoming requests and generating responses.
  """

  alias ParrotSip.Transaction
  alias ParrotSip.DialogStatem
  alias ParrotSip.Handler
  alias ParrotSip.TransactionStatem
  alias ParrotSip.Message

  require Logger

  @allowed_methods [:invite, :ack, :bye, :cancel, :options, :register]

  @spec process(any(), Message.t(), Handler.handler()) ::
          :ok
  def process(trans, sip_msg0, handler) do
    Logger.debug("UAS: process #{inspect(sip_msg0.method)}")

    process_list = [
      fn sip_msg ->
        validate_request(sip_msg)
      end,
      fn sip_msg ->
        Logger.debug("UAS: process_request #{inspect(sip_msg.method)}")

        # Check if this is an in-dialog request
        DialogStatem.uas_request(sip_msg)
        Logger.debug("UAS: process_request process #{inspect(sip_msg.method)}")
        {:process, sip_msg}
      end,
      fn sip_msg ->
        case sip_msg.method == :cancel do
          false -> {:process, sip_msg}
          true -> TransactionStatem.server_cancel(sip_msg)
        end
      end,
      fn sip_msg ->
        # Instead of make_uas, use the Transaction struct directly.
        # Handler.uas_request expects a transaction struct with role: :uas
        Handler.uas_request(trans, sip_msg, handler)
      end
    ]

    case do_process(process_list, sip_msg0) do
      {:reply, resp} -> TransactionStatem.server_response(resp, trans)
      _ -> :ok
    end
  end

  @spec process_ack(Message.t(), Handler.handler()) :: :ok
  def process_ack(req_sip_msg, _handler) do
    # Try to find dialog for ACK
    case DialogStatem.uas_find(req_sip_msg) do
      {:ok, _dialog} ->
        Logger.debug("uas: found dialog for ACK")

      :not_found ->
        Logger.debug("uas: cannot find dialog for ACK")
    end

    :ok
  end

  @spec process_cancel(Transaction.t() | any(), Handler.handler()) :: :ok
  def process_cancel(%Transaction{request: cancel_msg} = trans, handler) do
    # RFC 3261 Section 9.2: CANCEL can only cancel pending requests
    # Check if this CANCEL matches an established dialog
    case DialogStatem.uas_find(cancel_msg) do
      {:ok, dialog_pid} ->
        # Found a dialog - check if it's in confirmed state
        dialog_state = get_dialog_state(dialog_pid)

        case dialog_state do
          :confirmed ->
            # RFC 3261 Section 9.2: CANCEL cannot cancel a confirmed dialog
            # The UAC should use BYE instead
            Logger.debug("uas: rejecting CANCEL for confirmed dialog - should use BYE")
            resp = Message.reply(cancel_msg, 481, "Call/Transaction Does Not Exist")
            TransactionStatem.server_response(resp, trans)
            :ok

          :early ->
            # Early dialog - CANCEL is valid, proceed normally
            Logger.debug("uas: CANCEL for early dialog - proceeding")
            id = {:uas_id, trans}
            Handler.uas_cancel(id, handler)

          _ ->
            # Unknown state - allow handler to decide
            Logger.debug("uas: CANCEL for dialog in unknown state")
            id = {:uas_id, trans}
            Handler.uas_cancel(id, handler)
        end

      :not_found ->
        # No dialog found - this is a CANCEL for a transaction that hasn't
        # established a dialog yet (normal case)
        Logger.debug("uas: CANCEL for pending transaction")
        id = {:uas_id, trans}
        Handler.uas_cancel(id, handler)
    end
  end

  def process_cancel(trans, handler) do
    # Handle non-Transaction arguments (e.g., test mocks)
    id = {:uas_id, trans}
    Handler.uas_cancel(id, handler)
  end

  # RFC 3261 Section 12.1.1: Dialog-creating response with tag already present
  @spec response(Message.t(), Transaction.t()) :: :ok
  def response(
        %Message{status_code: status_code, to: %{parameters: %{"tag" => _tag}}} = resp_sip_msg,
        %Transaction{request: %Message{method: method} = req_sip_msg} = transaction
      )
      when status_code >= 200 and status_code < 300 and method in [:invite, :subscribe] do
    Logger.debug("UAS: response #{inspect(resp_sip_msg.method)} - tag present")

    resp_sip_msg = DialogStatem.uas_response(resp_sip_msg, req_sip_msg)
    TransactionStatem.server_response(resp_sip_msg, transaction)
  end

  # RFC 3261 Section 12.1.1: Dialog-creating response without tag - generate and add one
  def response(
        %Message{status_code: status_code, to: %{parameters: params} = to_header} = resp_sip_msg,
        %Transaction{request: %Message{method: method} = req_sip_msg} = transaction
      )
      when status_code >= 200 and status_code < 300 and method in [:invite, :subscribe] do
    Logger.debug("UAS: response #{inspect(resp_sip_msg.method)} - adding tag")

    # Generate and add To tag for dialog-creating responses
    tag = generate_tag()
    updated_to = %{to_header | parameters: Map.put(params, "tag", tag)}
    resp_sip_msg_with_tag = %{resp_sip_msg | to: updated_to}

    resp_sip_msg = DialogStatem.uas_response(resp_sip_msg_with_tag, req_sip_msg)
    TransactionStatem.server_response(resp_sip_msg, transaction)
  end

  # Non-dialog-creating response - process as-is
  def response(resp_sip_msg, %Transaction{request: req_sip_msg} = transaction) do
    Logger.debug("UAS: response #{inspect(resp_sip_msg.method)}")

    resp_sip_msg = DialogStatem.uas_response(resp_sip_msg, req_sip_msg)
    TransactionStatem.server_response(resp_sip_msg, transaction)
  end

  # Test/mock transaction reference - bypass transaction layer
  def response(resp_sip_msg, _mock_transaction_ref) do
    Logger.debug("UAS: response #{inspect(resp_sip_msg.status_code)} (mock transaction)")
    :ok
  end

  @spec response_retransmit(Message.t(), Transaction.t()) :: :ok
  def response_retransmit(resp_sip_msg, transaction) do
    TransactionStatem.server_response(resp_sip_msg, transaction)
  end

  @spec sipmsg(Transaction.t()) :: Message.t()
  def sipmsg(%Transaction{request: req_sip_msg}), do: req_sip_msg

  # Get the current state of a dialog
  @spec get_dialog_state(pid()) :: :early | :confirmed | :terminated | :unknown
  defp get_dialog_state(dialog_pid) do
    try do
      :sys.get_state(dialog_pid)
      |> case do
        {state, _data} when state in [:early, :confirmed, :terminated] -> state
        _ -> :unknown
      end
    catch
      :exit, _ -> :unknown
    end
  end

  @spec make_reply(integer(), binary(), Transaction.t(), Message.t()) :: Message.t()
  def make_reply(code, reason_phrase, %Transaction{} = _transaction, req_sip_msg) do
    Logger.debug("UAS: make_reply #{inspect(code)} #{inspect(reason_phrase)}")

    # Create response using Message.reply
    response = Message.reply(req_sip_msg, code, reason_phrase)

    # For dialog-creating responses (2xx to INVITE/SUBSCRIBE), add a To tag if not present
    case {response.to, code, req_sip_msg.method} do
      {%{parameters: params} = to_header, status_code, method}
      when status_code >= 200 and status_code < 300 and
             method in [:invite, :subscribe] ->
        # Check if tag already exists
        if Map.has_key?(params, "tag") do
          response
        else
          # Generate and add To tag for dialog-creating responses
          tag = generate_tag()
          updated_to = %{to_header | parameters: Map.put(params, "tag", tag)}
          %{response | to: updated_to}
        end

      _ ->
        # Keep response as is (non-dialog creating)
        response
    end
  end

  @spec set_owner(integer(), pid(), Transaction.t()) :: :ok
  def set_owner(auto_resp_code, pid, transaction) do
    TransactionStatem.server_set_owner(auto_resp_code, pid, transaction)
  end

  # Internal implementation

  # Generate a random tag for responses
  @spec generate_tag() :: binary()
  defp generate_tag, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  # Validate incoming SIP request - replaces ersip_uas.process_request
  @spec validate_request(Message.t()) :: {:process, Message.t()} | {:reply, Message.t()}
  defp validate_request(%Message{method: method} = sip_msg) when method in @allowed_methods,
    do: {:process, sip_msg}

  defp validate_request(%Message{} = sip_msg) do
    # Method not allowed, return 405 Method Not Allowed
    {:reply,
     sip_msg
     |> Message.reply(405, "Method Not Allowed")
     |> Map.put(:allow, Enum.map(@allowed_methods, &to_string/1))}
  end

  @spec do_process(
          [
            (Message.t() ->
               :ok | {:process, Message.t()} | {:reply, Message.t()})
          ],
          Message.t()
        ) :: :ok | {:reply, Message.t()}
  defp do_process([], _), do: :ok

  defp do_process([f | rest], sip_msg) do
    case f.(sip_msg) do
      :ok -> :ok
      {:reply, _} = reply -> reply
      {:process, sip_msg1} -> do_process(rest, sip_msg1)
    end
  end
end
