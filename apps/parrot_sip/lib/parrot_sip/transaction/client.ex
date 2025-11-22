defmodule ParrotSip.Transaction.Client do
  @moduledoc """
  Client Transaction Layer

  This module provides functionality for the client side of SIP transactions,
  including sending requests and handling responses.
  """
  require Logger

  alias ParrotSip.{Transaction, Dialog, Message, Branch, Uri}
  alias ParrotSip.TransactionStatem
  alias ParrotSip.Headers.{Via, CSeq}

  @type callback :: (client_trans_result -> any())
  @type client_trans_result :: {:message, any()} | {:stop, any()} | Transaction.client_result()
  @type id :: {:uac_id, Transaction.t()}
  @type options :: %{
          optional(:sip) => map(),
          optional(:owner) => pid()
        }

  @spec request(Message.t(), Uri.t() | String.t(), callback()) :: id()
  def request(%Message{} = sip_msg, _nexthop, uac_callback) do
    # Generate a random branch for this transaction
    branch = Branch.generate()

    # Add the branch to the topmost Via header
    sip_msg = add_branch_to_via(sip_msg, branch)

    # nexthop is passed to transport layer, not stored in message

    # Create the transaction based on method
    {:ok, transaction} = create_client_transaction(sip_msg, branch)

    callback_fun = make_transaction_handler(transaction, uac_callback)

    case TransactionStatem.client_new(transaction, %{}, callback_fun) do
      {:trans, _pid} = trans -> {:uac_id, trans}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec request(Message.t(), callback()) :: id()
  def request(%Message{} = sip_msg, uac_callback) do
    # Generate a random branch for this transaction
    branch = Branch.generate()

    # Add the branch to the topmost Via header
    sip_msg = add_branch_to_via(sip_msg, branch)

    # Create the transaction based on method
    {:ok, transaction} = create_client_transaction(sip_msg, branch)

    callback_fun = make_transaction_handler(transaction, uac_callback)

    case TransactionStatem.client_new(transaction, %{}, callback_fun) do
      {:trans, _pid} = trans -> {:uac_id, trans}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec request_with_opts(Message.t(), options(), callback()) :: id()
  def request_with_opts(%Message{} = sip_msg, uac_options, uac_callback) do
    # Generate a random branch for this transaction
    branch = Branch.generate()

    # Add the branch to the topmost Via header
    sip_msg = add_branch_to_via(sip_msg, branch)

    # Create the transaction based on method
    {:ok, transaction} = create_client_transaction(sip_msg, branch)

    callback_fun = make_transaction_handler(transaction, uac_callback)

    case TransactionStatem.client_new(transaction, uac_options, callback_fun) do
      {:trans, _pid} = trans -> {:uac_id, trans}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cancel(id()) :: :ok
  def cancel({:uac_id, trans}) do
    TransactionStatem.client_cancel(trans)
  end

  # Internal Implementation

  @spec make_transaction_handler(Transaction.t(), callback()) :: callback()
  defp make_transaction_handler(
         %ParrotSip.Transaction{
           request: %ParrotSip.Message{
             request_uri: request_uri,
             via: via,
             source: source
           }
         } = transaction,
         cb
       ) do
    fn
      {:stop, :normal} ->
        :ok

      {:response,
       %Message{type: :response, status_code: status_code, to: to, from: from} = response} =
          trans_result
      when status_code >= 200 and status_code < 300 and transaction.method == :invite ->
        # RFC 3261 Section 13.2.2.4: UAC core MUST generate an ACK request for each 2xx
        # received from the transaction layer. The ACK for 2xx is NOT part of the INVITE
        # transaction - it's a separate transaction.
        Logger.debug("Auto-generating ACK for 2xx INVITE response")

        # TODO
        # The ACK MUST contain the same credentials as the INVITE.  If
        # the 2xx contains an offer (based on the rules above), the ACK MUST
        # carry an answer in its body.

        # Add the branch to the topmost Via header
        sip_msg =
          %Message{
            type: :request,
            request_uri: request_uri,
            method: :ack,
            version: "SIP/2.0",
            via: via,
            from: from,
            to: to,
            call_id: transaction.request.call_id,
            cseq: %CSeq{number: transaction.request.cseq.number, method: :ack},
            source: source
          }
          # new randon branch for this transcation
          |> add_branch_to_via(Branch.generate())

        # Create outbound request map for Transport
        # Send ACK via transport handler
        %ParrotSip.Headers.To{uri: %ParrotSip.Uri{host: host, port: port}} = response.to
        send_via_transport_handler(sip_msg, {host, port})

        # Continue with normal processing
        Dialog.uac_result(transaction.request, trans_result)
        cb.(trans_result)

      trans_result ->
        Dialog.uac_result(transaction.request, trans_result)
        cb.(trans_result)
    end
  end

  @spec add_branch_to_via(Message.t(), String.t()) :: Message.t()
  defp add_branch_to_via(%Message{via: []}, _branch),
    do: raise("Cannot add branch to empty Via list")

  defp add_branch_to_via(%Message{via: [first_via | rest]} = msg, branch) do
    updated_via = Via.with_parameter(first_via, "branch", branch)
    %{msg | via: [updated_via | rest]}
  end

  @spec create_client_transaction(Message.t(), String.t()) :: {:ok, Transaction.t()}
  defp create_client_transaction(%Message{method: method} = request, branch) do
    # Ensure the request has the branch in its Via header
    request_with_branch = add_branch_to_via(request, branch)

    # Create transaction based on method
    case String.upcase(to_string(method)) do
      "INVITE" -> Transaction.create_invite_client(request_with_branch)
      _ -> Transaction.create_non_invite_client(request_with_branch)
    end
  end

  # Helper function to send messages via transport handler
  defp send_via_transport_handler(message, destination) do
    # Try to find the transport handler
    transport_handler =
      case Process.whereis(ParrotSip.TransportHandler) do
        nil ->
          # Try to find via Registry
          # Registry.lookup returns [{registered_process_pid, value}]
          # In our case, value is the handler pid we want
          case Registry.lookup(ParrotSip.Registry, {ParrotSip.TransportHandler, :default}) do
            [{_registered_pid, handler_pid}] -> handler_pid
            _ -> nil
          end

        pid ->
          pid
      end

    if transport_handler do
      ParrotSip.TransportHandler.send_request(transport_handler, message, destination)
      :ok
    else
      require Logger
      Logger.warning("No transport handler available - ACK not sent")
      :ok
    end
  end
end
