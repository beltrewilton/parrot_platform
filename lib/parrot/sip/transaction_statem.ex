defmodule Parrot.Sip.TransactionStatem do
  @moduledoc """
  SIP Transaction State Machine

  States:
  - :trying      - Initial state for non-INVITE transactions
  - :calling     - Initial state for INVITE client transactions
  - :proceeding  - Processing state for INVITE server transactions
  - :completed   - Final response sent/received
  - :confirmed   - Final state for successful transactions
  - :terminated  - Terminal state

  State Transitions:
  - trying -> proceeding -> completed -> terminated
  - calling -> proceeding -> completed -> terminated
  - proceeding -> completed -> confirmed -> terminated

  Events:
  - {:process_se, se}     - Process transaction events
  - {:send, response}     - Send response
  - :cancel              - Cancel transaction
  - {:set_owner, code, pid} - Set transaction owner
  - {:DOWN, ref, :process, pid, _} - Owner process down
  - {:event, timer_event} - Timer events
  """
  @behaviour :gen_statem

  require Logger

  @inspect_opts [pretty: false, limit: :infinity, width: 80, syntax_colors: []]

  alias Parrot.Sip.Headers.Via
  alias Parrot.Sip.Transaction
  alias Parrot.Sip.{Handler, UAS, Message, Parser}

  @type t :: {:trans, pid()}
  @type client_result :: {:stop, term()} | {:message, term()}
  @type client_callback :: (client_result -> any())
  @type handler :: term()

  # State definition for the state machine
  @type state_name :: :proceeding | :calling | :completed | :confirmed | :trying | :terminated
  @type state :: %{
          type: :client | :server,
          trans: term(),
          owner_mon: reference() | nil,
          data: map(),
          log: boolean(),
          logbranch: String.t()
        }

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      type: :worker,
      # or :permanent depending on your needs
      restart: :temporary,
      shutdown: 5000
    }
  end

  @spec start_link(term()) :: :gen_statem.start_ret()
  def start_link(args) do
    # Expect args to include a %Parrot.Sip.Transaction{} as the first or a named argument.
    transaction =
      case args do
        [%Parrot.Sip.Transaction{} = t | _] -> t
        %{transaction: %Parrot.Sip.Transaction{} = t} -> t
        _ -> raise ArgumentError, "start_link expects a %Parrot.Sip.Transaction{} in args"
      end

    :gen_statem.start_link(
      via_tuple(transaction),
      __MODULE__,
      args,
      []
    )
  end

  def server_process(%Parrot.Sip.Message{method: :ack} = sip_msg, handler) do
    Logger.debug("server_process ack")
    dbg(sip_msg)
    dbg(handler)

    case find_server(sip_msg) do
      {:ok, pid} ->
        Logger.debug("Forward the ACK to the transaction FSM (gen_statem)")
        :gen_statem.cast(pid, {:received, sip_msg})
        :ok

      :error ->
        Logger.debug(
          "If no transaction found, this might be a 2xx ACK (handled by dialog/user handler)"
        )

        handler_module = handler.module
        handler_args = handler.args

        if function_exported?(handler_module, :process_ack, 2) do
          Logger.debug("Calling process_ack/2 in handler")
          handler_module.process_ack(sip_msg, handler_args)
        else
          Logger.warning("No process_ack/2 in handler for stray ACK")
          :ok
        end
    end
  end

  def server_process(%Parrot.Sip.Message{} = sip_msg, handler) do
    case find_server(sip_msg) do
      {:ok, pid} ->
        :gen_statem.cast(pid, {:received, sip_msg})

      :error ->
        case sip_msg do
          # Handle in-dialog requests (both From and To have tags)
          %Message{
            headers: %{
              "from" => %{parameters: %{"tag" => _from_tag}},
              "to" => %{parameters: %{"tag" => _to_tag}}
            }
          } = in_dialog_msg ->
            Logger.debug("Processing in-dialog request: #{in_dialog_msg.method}")
            handle_in_dialog_request(in_dialog_msg, handler)

          # Handle new dialog requests
          _new_dialog_msg ->
            Logger.debug("Creating new transaction for #{sip_msg.method}")

            dbg(Transaction.determine_transaction_type(sip_msg))

            transaction =
              case Transaction.determine_transaction_type(sip_msg) do
                :invite_server ->
                  {:ok, t} = Transaction.create_invite_server(sip_msg)
                  t

                :non_invite_server ->
                  {:ok, t} = Transaction.create_non_invite_server(sip_msg)
                  t

                other ->
                  raise ArgumentError, "Unsupported transaction type: #{inspect(other)}"
              end

            start_transaction([transaction, handler])
        end
    end
  end

  @spec server_response(term(), Parrot.Sip.Transaction.t()) :: :ok
  def server_response(resp, %Parrot.Sip.Transaction{} = transaction) do
    Logger.debug("Sending response: #{inspect(resp)}")
    dbg(via_tuple(transaction))
    :gen_statem.cast(via_tuple(transaction), {:send, resp})
  end

  @spec create_server_response(term(), term()) :: :ok
  def create_server_response(resp_sip_msg, req_sip_msg) do
    trans_id = Transaction.generate_id(req_sip_msg)

    case Registry.lookup(Parrot.Registry, trans_id) do
      [{pid, _}] when is_pid(pid) ->
        :gen_statem.cast(pid, {:send, resp_sip_msg})

      _ ->
        Logger.debug("No transaction found for response, sending directly")
        # TODO: Implement direct response sending with pure Elixir
        # For now, just return :ok
        :ok
    end
  end

  @spec server_cancel(term()) :: {:reply, term()}
  def server_cancel(%Message{} = cancel_sip_msg) do
    # Generate transaction ID for the original INVITE this CANCEL is targeting
    trans_id = generate_cancel_transaction_id(cancel_sip_msg)

    case Registry.lookup(Parrot.Registry, trans_id) do
      [{pid, _}] when is_pid(pid) ->
        Logger.debug("Found transaction to CANCEL: #{inspect(trans_id, @inspect_opts)}")
        :gen_statem.cast(pid, :cancel)
        resp = Message.reply(cancel_sip_msg, 200, "OK")
        {:reply, resp}

      _ ->
        Logger.debug("cannot find transaction to CANCEL: #{inspect(trans_id, @inspect_opts)}")
        resp = Message.reply(cancel_sip_msg, 481, "Call/Transaction Does Not Exist")
        {:reply, resp}
    end
  end

  @spec server_set_owner(integer(), pid(), t()) :: :ok
  def server_set_owner(code, owner_pid, %Parrot.Sip.Transaction{} = transaction)
      when is_pid(owner_pid) and is_integer(code) do
    :gen_statem.cast(via_tuple(transaction), {:set_owner, code, owner_pid})
  end

  @spec client_new(term(), map(), client_callback()) :: t()
  def client_new(transaction, options, callback) do
    # Pass transaction as first element to match init/1 expectations
    args = [transaction, options, callback]

    case Parrot.Sip.Transaction.Supervisor.start_child(args) do
      {:ok, pid} ->
        {:trans, pid}

      {:error, _} = error ->
        Logger.error("client failed to create transaction: #{inspect(error, @inspect_opts)}")
        {:trans, spawn(fn -> :ok end)}
    end
  end

  @spec client_response(term(), binary()) :: :ok
  def client_response(via, msg) when is_binary(msg) do
    case Parser.parse(msg) do
      {:ok, sip_msg} ->
        # Generate transaction ID from branch and method
        branch =
          case via do
            %Via{parameters: %{"branch" => b}} -> b
            _ -> nil
          end

        # For responses, extract method from CSeq header
        method =
          case sip_msg.headers["cseq"] do
            %{method: m} ->
              m

            cseq when is_binary(cseq) ->
              [_, method_str] = String.split(cseq, " ", parts: 2)
              String.trim(method_str) |> String.downcase() |> String.to_atom()

            _ ->
              nil
          end

        trans_id =
          if branch && method do
            "#{branch}:#{method}:client"
          else
            Logger.warning("Cannot generate transaction ID for response")
            nil
          end

        if trans_id do
          case Registry.lookup(Parrot.Registry, trans_id) do
            [{pid, _}] when is_pid(pid) ->
              :gen_statem.cast(pid, {:received, sip_msg})

            _ ->
              Logger.warning(
                "cannot find transaction for request: #{inspect(via, @inspect_opts)}"
              )
          end
        end

      {:error, _} = error ->
        Logger.warning("failed to parse response: #{inspect(error, @inspect_opts)}")
    end
  end

  @spec client_cancel(t()) :: :ok
  def client_cancel({:trans, pid}) do
    :gen_statem.cast(pid, :cancel)
  end

  @spec count() :: non_neg_integer()
  def count do
    Parrot.Sip.Transaction.Supervisor.num_active()
  end

  @impl :gen_statem
  def init([%Parrot.Sip.Transaction{} = transaction | rest]) do
    sip_msg = transaction.request
    method = transaction.method
    request_uri = sip_msg.request_uri
    transaction_id = transaction.id
    branch = transaction.branch
    call_id = sip_msg.headers["call-id"]

    # Register with the full transaction ID, not just the branch
    Registry.register(Parrot.Registry, transaction_id, nil)

    # Determine if this is a client or server transaction based on the transaction type
    transaction_type = transaction.type

    Logger.metadata(
      trans_id: transaction_id,
      method: method,
      call_id: call_id,
      branch: branch
    )

    if transaction_type == :invite_client || transaction_type == :non_invite_client do
      # Client transaction initialization
      {options, callback} =
        case rest do
          [opts, cb] when is_map(opts) and is_function(cb) -> {opts, cb}
          [cb] when is_function(cb) -> {%{}, cb}
          _ -> {%{}, nil}
        end

      state = %{
        type: :client,
        data: %{
          # For client, handler is the callback function
          handler: callback,
          origmsg: sip_msg,
          transaction: transaction,
          options: options,
          # Store original request for client
          outreq: sip_msg,
          cancelled: false
        },
        timers: %{},
        log: Parrot.Config.log_transactions(),
        logbranch: branch
      }

      Logger.debug(
        "trans: client: #{method} #{request_uri}; call-id: #{call_id}; branch: #{branch}"
      )

      # Send the initial request, optionally to an explicit next-hop proxy.
      send_client_request(sip_msg, options)

      # Start in calling state for client transactions
      {:ok, :calling, state}
    else
      # Server transaction initialization - extract handler from rest like original code
      handler =
        case rest do
          [h | _] -> h
          _ -> nil
        end

      state = %{
        type: :server,
        data: %{
          handler: handler,
          origmsg: sip_msg,
          transaction: transaction,
          auto_resp: 500
        },
        timers: %{},
        log: Parrot.Config.log_transactions(),
        logbranch: branch
      }

      Logger.debug(
        "trans: server: #{method} #{request_uri}; call-id: #{call_id}; branch: #{branch}"
      )

      {:ok, :trying, state,
       [{:next_event, :cast, {:handle_transaction_setup, [:server, sip_msg, method, handler]}}]}
    end
  end

  @impl :gen_statem
  def callback_mode, do: :state_functions

  # Real implementation of process_actions/2 to handle SIP actions and timers.
  defp process_actions([], _data) do
    Logger.debug("[process_actions] No more actions to process.")
    {:keep_state_and_data, []}
  end

  defp process_actions([action | rest], data) do
    Logger.debug(
      "[process_actions] Processing action: #{inspect(action)} with data: #{inspect(data, pretty: false, limit: 10)}"
    )

    case action do
      {:send_response, response} ->
        Logger.debug("[process_actions] Action is :send_response. Response: #{inspect(response)}")
        source = response_source_for_send(data, response)

        if source do
          Logger.debug("[process_actions] Sending response using source: #{inspect(source)}")
          maybe_inspect_bye_response_destination(response, source)
          Parrot.Sip.Transport.send_response(%{response | source: source}, source)
        else
          require Logger

          Logger.error(
            "[process_actions] No source found for send_response/2; cannot send SIP response!"
          )
        end

        Logger.debug(
          "[process_actions] Finished :send_response action, processing rest: #{inspect(rest)}"
        )

        process_actions(rest, data)

      {:send_request, request} ->
        Logger.debug("[process_actions] Action is :send_request. Request: #{inspect(request)}")
        send_client_request(request, Map.get(data, :options, %{}))

        Logger.debug(
          "[process_actions] Finished :send_request action, processing rest: #{inspect(rest)}"
        )

        process_actions(rest, data)

      {:start_timer, timer_name, timeout} ->
        Logger.debug(
          "[process_actions] Action is :start_timer. Timer: #{inspect(timer_name)}, Timeout: #{inspect(timeout)}"
        )

        data = cancel_named_timer(timer_name, data)
        ref = Process.send_after(self(), {:event, timer_name}, timeout)
        timers = Map.put(data.timers || %{}, timer_name, ref)

        Logger.debug("[process_actions] Timer started. Timers map: #{inspect(timers)}")

        case process_actions(rest, %{data | timers: timers}) do
          {:keep_state_and_data, _} -> {:keep_state, data}
          {:keep_state, _} -> {:keep_state, data}
          :stop -> {:stop, :normal, data}
        end

      {:cancel_timer, timer_name} ->
        Logger.debug("[process_actions] Action is :cancel_timer. Timer: #{inspect(timer_name)}")
        data = cancel_named_timer(timer_name, data)

        Logger.debug("[process_actions] Timer cancelled. Timers map: #{inspect(data.timers)}")

        process_actions(rest, data)

      :terminate_transaction ->
        Logger.debug("[process_actions] Action is :terminate_transaction. Stopping.")
        :stop

      :retransmit_last_response ->
        Logger.debug("[process_actions] Action is :retransmit_last_response.")

        if last = last_response_for_retransmit(data) do
          Logger.debug("[process_actions] Retransmitting last response: #{inspect(last)}")
          source = response_source_for_send(data, last)

          if source do
            maybe_inspect_bye_response_destination(last, source)
            Parrot.Sip.Transport.send_response(%{last | source: source}, source)
          else
            Logger.error(
              "[process_actions] No source found for retransmit_last_response; cannot retransmit SIP response!"
            )
          end
        else
          Logger.debug("[process_actions] No last response to retransmit.")
        end

        process_actions(rest, data)

      {:notify_user, msg} ->
        Logger.debug("[process_actions] Action is :notify_user. Message: #{inspect(msg)}")
        # Implement user notification if needed
        process_actions(rest, data)

      :ignore ->
        Logger.debug("[process_actions] Action is :ignore. Skipping.")

        process_actions(rest, data)

      _ ->
        Logger.debug("[process_actions] Unknown action: #{inspect(action)}. Skipping.")

        process_actions(rest, data)
    end
  end

  @doc false
  def response_source_for_send(data, response) do
    cond do
      source = request_source_for_response(data) ->
        Logger.debug("[process_actions] Found request source: #{inspect(source)}")
        source

      Map.has_key?(response, :source) and not is_nil(response.source) ->
        Logger.debug(
          "[process_actions] Found source in response.source: #{inspect(response.source)}"
        )

        response.source

      request = request_message_for_response(data) ->
        Logger.debug("[process_actions] Falling back to top Via from request: #{inspect(request)}")
        source_from_top_via(request)

      true ->
        Logger.debug("[process_actions] No source found in any known location.")
        nil
    end
  end

  defp request_source_for_response(data) do
    cond do
      Map.has_key?(data, :source) and not is_nil(data.source) ->
        data.source

      match?(%{source: source} when not is_nil(source), Map.get(data, :trans)) ->
        data.trans.source

      match?(%{request: %{source: source}} when not is_nil(source), Map.get(data, :trans)) ->
        data.trans.request.source

      match?(%{source: source} when not is_nil(source), Map.get(data, :data)) ->
        data.data.source

      match?(
        %{transaction: %{request: %{source: source}}} when not is_nil(source),
        Map.get(data, :data)
      ) ->
        data.data.transaction.request.source

      match?(%{origmsg: %{source: source}} when not is_nil(source), Map.get(data, :data)) ->
        data.data.origmsg.source

      match?(%{source: source} when not is_nil(source), Map.get(data, :transaction)) ->
        data.transaction.source

      match?(
        %{request: %{source: source}} when not is_nil(source),
        Map.get(data, :transaction)
      ) ->
        data.transaction.request.source

      match?(%{source: source} when not is_nil(source), Map.get(data, :origmsg)) ->
        data.origmsg.source

      true ->
        nil
    end
  end

  defp request_message_for_response(data) do
    cond do
      match?(%Message{}, Map.get(data, :origmsg)) ->
        data.origmsg

      match?(%{request: %Message{}}, Map.get(data, :transaction)) ->
        data.transaction.request

      match?(%{request: %Message{}}, Map.get(data, :trans)) ->
        data.trans.request

      match?(%{origmsg: %Message{}}, Map.get(data, :data)) ->
        data.data.origmsg

      match?(%{transaction: %{request: %Message{}}}, Map.get(data, :data)) ->
        data.data.transaction.request

      true ->
        nil
    end
  end

  defp source_from_top_via(%Message{} = message) do
    case Message.top_via(message) do
      %Via{} = via ->
        Logger.debug("[process_actions] Building source from top Via: #{inspect(via)}")
        source_from_via(via)

      _ ->
        nil
    end
  end

  defp source_from_via(%Via{} = via) do
    host = Map.get(via.parameters, "received", via.host)
    port = via_port(via)

    %Parrot.Sip.Source{
      local: {nil, nil},
      remote: {parse_host_address(host), port},
      transport: via_transport(via.transport),
      source_id: nil
    }
  end

  defp via_port(%Via{port: port, transport: transport, parameters: parameters}) do
    default_port = port || default_port_for_transport(transport)

    case Map.get(parameters, "rport") do
      nil ->
        default_port

      "" ->
        default_port

      rport when is_integer(rport) ->
        rport

      rport when is_binary(rport) ->
        case Integer.parse(rport) do
          {parsed, _} -> parsed
          :error -> default_port
        end

      _other ->
        default_port
    end
  end

  defp default_port_for_transport(:udp), do: 5060
  defp default_port_for_transport(:tcp), do: 5060
  defp default_port_for_transport(:tls), do: 5061
  defp default_port_for_transport(:ws), do: 80
  defp default_port_for_transport(:wss), do: 443
  defp default_port_for_transport(_transport), do: 5060

  defp via_transport(transport) when transport in [:udp, :tcp, :tls, :ws, :wss], do: transport
  defp via_transport("UDP"), do: :udp
  defp via_transport("TCP"), do: :tcp
  defp via_transport("TLS"), do: :tls
  defp via_transport("WS"), do: :ws
  defp via_transport("WSS"), do: :wss
  defp via_transport(_transport), do: :udp

  defp parse_host_address(host) when is_binary(host) do
    case :inet.parse_ipv4_address(String.to_charlist(host)) do
      {:ok, ip} ->
        ip

      {:error, _} ->
        case :inet.parse_ipv6_address(String.to_charlist(host)) do
          {:ok, ip} -> ip
          {:error, _} -> host
        end
    end
  end

  defp parse_host_address(host), do: host

  defp maybe_inspect_bye_response_destination(%Message{type: :response, method: :bye}, source) do
    IO.inspect(format_source_destination(source), label: "SIP BYE response destination")
  end

  defp maybe_inspect_bye_response_destination(_response, _source), do: :ok

  defp format_source_destination(%Parrot.Sip.Source{remote: {host, port}}) do
    "#{format_host(host)}:#{port}"
  end

  defp format_host(host) when is_tuple(host) do
    host
    |> :inet.ntoa()
    |> to_string()
  end

  defp format_host(host), do: to_string(host)

  defp last_response_for_retransmit(data) do
    cond do
      match?(%{last_response: last_response} when not is_nil(last_response), Map.get(data, :trans)) ->
        data.trans.last_response

      match?(
        %{last_response: last_response} when not is_nil(last_response),
        Map.get(data, :transaction)
      ) ->
        data.transaction.last_response

      match?(
        %{transaction: %{last_response: last_response}} when not is_nil(last_response),
        Map.get(data, :data)
      ) ->
        data.data.transaction.last_response

      true ->
        nil
    end
  end

  defp maybe_send_non_2xx_invite_ack(
         %{status_code: status_code, headers: %{"to" => to_header}},
         %{origmsg: %Message{method: :invite} = request, options: options}
       )
       when status_code >= 300 and status_code <= 699 do
    ack_headers =
      %{
        "via" => request.headers["via"],
        "from" => request.headers["from"],
        "to" => to_header,
        "call-id" => request.headers["call-id"],
        "cseq" => ack_cseq(request.headers["cseq"]),
        "max-forwards" => request.headers["max-forwards"]
      }
      |> maybe_put_ack_header("route", request.headers["route"])
      |> maybe_put_ack_header("user-agent", request.headers["user-agent"])

    ack_request = Message.new_request(:ack, request.request_uri, ack_headers)
    options = options || %{}

    case Map.get(options, :test_pid) do
      pid when is_pid(pid) ->
        send(pid, {:non_2xx_ack_sent, ack_request, Map.get(options, :destination)})

      _other ->
        send_client_request(ack_request, options)
    end
  end

  defp maybe_send_non_2xx_invite_ack(_response, _data), do: :ok

  defp ack_cseq(%{number: number}),
    do: %Parrot.Sip.Headers.CSeq{number: number, method: :ack}

  defp ack_cseq(cseq), do: cseq

  defp maybe_put_ack_header(headers, _name, nil), do: headers
  defp maybe_put_ack_header(headers, name, value), do: Map.put(headers, name, value)

  defp cancel_named_timer(timer_name, data) do
    timers = data.timers || %{}

    case Map.pop(timers, timer_name) do
      {nil, _} ->
        data

      {ref, new_timers} ->
        Process.cancel_timer(ref)
        %{data | timers: new_timers}
    end
  end

  def trying(
        :cast,
        {:handle_transaction_setup, [:server, sip_msg, :ack, handler]},
        %{data: %{transaction: transaction}} = _state
      ) do
    Logger.warning(
      "ACK that matches transaction received for transaction ID: #{sip_msg.transaction_id}"
    )

    :process_uas = Handler.transaction(transaction, sip_msg, handler)
    UAS.process_ack(sip_msg, handler)
  end

  def trying(
        :cast,
        {:handle_transaction_setup, [:server, sip_msg, _method, _handler]},
        %{data: %{transaction: transaction, handler: handler}} = state
      ) do
    Logger.debug(":handle_transaction_setup -> Trying transaction setup")

    # Only send 100 Trying for INVITE server transactions (RFC 3261 17.2.1)
    # Non-INVITE server transactions should not automatically send 100 Trying (RFC 3261 17.2.2)
    if sip_msg.method == :invite do
      trying_resp =
        Parrot.Sip.Message.reply(sip_msg, 100, "Trying")
        |> Map.put(:body, "")

      UAS.response(trying_resp, transaction)
    end

    case Handler.transaction(transaction, sip_msg, handler) do
      :ok ->
        Logger.debug("Handler.transaction(transaction, sip_msg, handler) -> :ok")
        :ok

      :process_uas ->
        Logger.debug("Handler.transaction(transaction, sip_msg, handler) -> :process_uas")
        UAS.process(transaction, sip_msg, handler)
    end

    {:keep_state, state}
  end

  def trying(:cast, {:send, response}, %{data: %{transaction: transaction} = data} = state) do
    Logger.debug(
      "trying(:cast, {:send, response}, %{data: %{transaction: transaction} = data} = state)"
    )

    # Handle sending a response in the trying state using actions
    {new_transaction, actions} =
      Parrot.Sip.Transaction.handle_event({:send, response}, transaction)

    new_data = %{data | transaction: new_transaction}
    new_state = %{state | data: new_data}

    process_actions(actions, new_state)
  end

  def trying(:cast, :cancel, %{data: %{handler: handler, transaction: transaction}} = data) do
    Logger.debug("trans: canceling server transaction. state: #{inspect(data, @inspect_opts)}")
    UAS.process_cancel(transaction, handler)
    {:keep_state, data}
  end

  # Handle cancel events for client transactions
  def trying(:cast, :cancel, %{data: %{cancelled: true}} = data) do
    Logger.debug(
      "trans: transaction is already cancelled. state: #{inspect(data, @inspect_opts)}"
    )

    {:keep_state, data}
  end

  def trying(:cast, :cancel, %{data: %{cancelled: false, outreq: out_req} = inner_data} = data) do
    cancel_client_transaction(data, inner_data, out_req)
  end

  # Handle set_owner events
  def trying(:cast, {:set_owner, code, pid}, %{owner_mon: ref, data: data} = state) do
    Logger.debug(
      "trans: set owner to: #{inspect(pid)} with code: #{inspect(code)}. state: #{inspect(data)}"
    )

    if ref, do: Process.demonitor(ref, [:flush])
    new_ref = Process.monitor(pid)
    new_inner_data = Map.put(data, :auto_resp, code)
    new_state = %{state | owner_mon: new_ref, data: new_inner_data}
    {:keep_state, new_state}
  end

  # Handle sending responses in trying state
  def trying(:cast, {:send, response}, %{data: %{trans: trans} = data} = state) do
    Logger.debug(
      "trying state: processing {:send, response} for transaction type: #{trans.type}, method: #{trans.method}"
    )

    Logger.debug("Response being sent: #{response.status_code} #{response.reason_phrase}")

    # Process the send event through the transaction state machine
    {new_trans, actions} = Parrot.Sip.Transaction.handle_event({:send, response}, trans)

    Logger.debug(
      "Transaction state after handle_event: #{new_trans.state}, actions: #{inspect(actions)}"
    )

    new_data = %{data | trans: new_trans}

    # Process the actions returned by the transaction
    case process_actions(actions, new_data) do
      {:keep_state_and_data, _} ->
        # Check if state changed
        if trans.state != new_trans.state do
          {:next_state, new_trans.state, %{state | data: new_data}}
        else
          {:keep_state, %{state | data: new_data}}
        end

      {:keep_state, _} ->
        # Check if state changed
        if trans.state != new_trans.state do
          {:next_state, new_trans.state, %{state | data: new_data}}
        else
          {:keep_state, %{state | data: new_data}}
        end

      :stop ->
        {:stop, :normal, %{state | data: new_data}}
    end
  end

  # CATCH-ALL CLAUSES FOR ALL STATES

  def trying(_event_type, _event, state) do
    Logger.warning("TransactionStatem.trying/3: Ignoring unexpected event")
    {:keep_state, state}
  end

  # PROCEEDING STATE
  def proceeding(:cast, :cancel, %{data: %{cancelled: true}} = state) do
    Logger.debug(
      "trans: transaction is already cancelled. state: #{inspect(state, @inspect_opts)}"
    )

    {:keep_state, state}
  end

  def proceeding(
        :cast,
        :cancel,
        %{data: %{cancelled: false, outreq: out_req} = inner_data} = state
      ) do
    cancel_client_transaction(state, inner_data, out_req)
  end

  def proceeding(:cast, event, data), do: handle_common_event(event, data)

  def proceeding(event_type, event, state) do
    Logger.warning("TransactionStatem.proceeding/3: Ignoring unexpected event")
    dbg(event_type)
    dbg(event)
    dbg(state)
    {:keep_state, state}
  end

  # CALLING STATE
  def calling(
        :cast,
        {:received, %{type: :response} = response},
        %{type: :client, data: data} = state
      ) do
    Logger.debug(
      "Client transaction received response: #{response.status_code} #{response.reason_phrase}"
    )

    # Call the user callback with the response
    if is_function(data.handler) do
      data.handler.({:response, response})
    end

    maybe_send_non_2xx_invite_ack(response, data)

    # Handle state transitions based on response code
    cond do
      response.status_code >= 100 and response.status_code < 200 ->
        # Provisional response - stay in calling state
        {:keep_state, state}

      response.status_code >= 200 and response.status_code < 300 ->
        # Success response - move to completed state
        {:next_state, :completed, state}

      response.status_code >= 300 ->
        # Final response - move to completed state
        {:next_state, :completed, state}
    end
  end

  def calling(:cast, :cancel, %{data: %{cancelled: true}} = state) do
    Logger.debug(
      "trans: transaction is already cancelled. state: #{inspect(state, @inspect_opts)}"
    )

    {:keep_state, state}
  end

  def calling(:cast, :cancel, %{data: %{cancelled: false, outreq: out_req} = inner_data} = state) do
    cancel_client_transaction(state, inner_data, out_req)
  end

  def calling(:cast, event, data), do: handle_common_event(event, data)

  def calling(event_type, event, state) do
    Logger.warning("TransactionStatem.calling/3: Ignoring unexpected event")
    dbg(event_type)
    dbg(event)
    dbg(state)
    {:keep_state, state}
  end

  # COMPLETED STATE
  # Handle sending responses in completed state for retransmissions
  def completed(:cast, {:send, _response}, %{data: %{trans: trans}} = state) do
    Logger.debug(
      "completed state: processing {:send, response} for transaction type: #{trans.type}"
    )

    # In completed state, we can only retransmit the last response
    if trans.last_response do
      Logger.debug("Retransmitting last response in completed state")
      Parrot.Sip.Transport.send_response(trans.last_response)
    end

    {:keep_state, state}
  end

  def completed(:cast, {:received, msg}, %{type: :server, data: data} = state) do
    # For server transactions, delegate to handle_common_event to process the ACK properly
    case handle_common_event({:received, msg}, data) do
      {:next_state, new_state_name, new_data} ->
        {:next_state, new_state_name, %{state | data: new_data}}

      {:keep_state, new_data} ->
        {:keep_state, %{state | data: new_data}}

      {:stop, reason, new_data} ->
        {:stop, reason, %{state | data: new_data}}
    end
  end

  def completed(:cast, {:received, _msg}, %{type: :client} = state) do
    # Client-side final responses can be retransmitted by the provider.
    # There is nothing to send back from this generic transaction layer here,
    # so we simply absorb the duplicate response.
    {:keep_state, state}
  end

  def completed(:cast, event, data), do: handle_common_event(event, data)

  def completed(_event_type, _event, state) do
    Logger.warning("TransactionStatem.completed/3: Ignoring unexpected event")
    {:keep_state, state}
  end

  # CONFIRMED STATE
  def confirmed(:cast, event, data), do: handle_common_event(event, data)

  def confirmed(_event_type, _event, state) do
    Logger.warning("TransactionStatem.confirmed/3: Ignoring unexpected event")
    {:keep_state, state}
  end

  # TERMINATED STATE
  def terminated(:cast, event, data), do: handle_common_event(event, data)

  def terminated(_event_type, _event, state) do
    Logger.warning("TransactionStatem.terminated/3: Ignoring unexpected event")
    {:keep_state, state}
  end

  defp send_client_request(%Message{} = sip_msg, options) when is_map(options) do
    case Map.get(options, :destination) do
      {host, port} when is_binary(host) and is_integer(port) ->
        Parrot.Sip.Transport.Udp.send_request(%{destination: {host, port}, message: sip_msg})

      _other ->
        Parrot.Sip.Transport.send_request(sip_msg)
    end
  end

  defp cancel_client_transaction(state, inner_data, out_req) do
    Logger.debug("trans: canceling client transaction. state: #{inspect(state, @inspect_opts)}")

    cancel_req =
      Message.new_request(:cancel, out_req.request_uri, %{
        "call-id" => out_req.headers["call-id"],
        "from" => out_req.headers["from"],
        "to" => out_req.headers["to"],
        "cseq" => %{number: out_req.headers["cseq"].number, method: :cancel},
        "via" => out_req.headers["via"]
      })

    {:ok, cancel_transaction} = Transaction.create_non_invite_client(cancel_req)
    _ = client_new(cancel_transaction, Map.get(inner_data, :options, %{}), fn _ -> :ok end)

    {:keep_state, %{state | data: %{inner_data | cancelled: true}},
     [{:state_timeout, 32_000, :cancel_timeout}]}
  end

  # Handle common events across states
  defp handle_common_event({:received, sip_msg} = ev, %{trans: trans} = data) do
    # Log response info if it's a response
    case sip_msg.type do
      :response ->
        log_response_info(sip_msg, data)

      _ ->
        :ok
    end

    {new_trans, actions} = Parrot.Sip.Transaction.handle_event(ev, trans)
    new_data = %{data | trans: new_trans}

    # Check if the transaction state has changed and we need to transition gen_statem state
    result =
      case {trans.state, new_trans.state} do
        {old_state, new_state} when old_state != new_state ->
          # State has changed, transition to the new state
          case process_actions(actions, new_data) do
            {:keep_state_and_data, _} -> {:next_state, new_state, new_data}
            {:keep_state, _} -> {:next_state, new_state, new_data}
            :stop -> {:stop, :normal, new_data}
          end

        _ ->
          # State hasn't changed
          case process_actions(actions, new_data) do
            {:keep_state_and_data, _} -> {:keep_state, new_data}
            {:keep_state, _} -> {:keep_state, new_data}
            :stop -> {:stop, :normal, new_data}
          end
      end

    result
  end

  # Add terminate callback
  @impl :gen_statem
  def terminate(reason, _state, data) do
    case reason do
      :normal -> Logger.debug("trans: finished. state: #{inspect(data, @inspect_opts)}")
      _ -> Logger.error("trans: finished with error: #{inspect(reason, @inspect_opts)}")
    end

    :ok
  end

  # Handle info messages
  @impl :gen_statem
  def handle_event(
        :info,
        {:DOWN, ref, :process, pid, _},
        _state,
        %{trans: trans, owner_mon: ref, data: %{origmsg: _sip_msg}} = data
      ) do
    if trans.last_response && trans.last_response.status_code >= 200 do
      {:keep_state, data}
    else
      handle_owner_down(pid, data)
    end
  end

  def handle_event(:info, {:event, timer_event}, _state, %{trans: trans} = data) do
    Logger.debug(
      "trans: timer fired #{inspect(timer_event)}. state: #{inspect(data, @inspect_opts)}"
    )

    {new_trans, actions} = Parrot.Sip.Transaction.handle_event({:timer, timer_event}, trans)
    new_data = %{data | trans: new_trans}

    case process_actions(actions, new_data) do
      :continue -> {:keep_state, new_data}
      :stop -> {:stop, :normal, new_data}
    end
  end

  def handle_event(
        :state_timeout,
        :cancel_timeout,
        _state,
        %{trans: trans, data: %{callback: callback}} = data
      ) do
    unless trans.last_response && trans.last_response.status_code >= 200 do
      Logger.warning("trans: remote side did not respond after CANCEL request: terminate")
      callback.({:stop, :timeout})
    end

    {:stop, :normal, data}
  end

  # Timer expiry for transaction termination (for Timer H/J)
  def handle_event(:state_timeout, :terminate, _state, data) do
    Logger.debug("TransactionStatem: Timer expired, terminating transaction.")
    {:stop, :normal, data}
  end

  # Handle DOWN messages for client transactions
  def handle_event(
        :info,
        {:DOWN, ref, :process, pid, _},
        _state,
        %{trans: trans, owner_mon: ref, data: %{outreq: out_req}} = data
      ) do
    request_msg =
      case out_req do
        %{request: msg} -> msg
        %Message{} = msg -> msg
        _ -> nil
      end

    if (request_msg && request_msg.method == :invite) and
         not (trans.last_response && trans.last_response.status_code >= 200) do
      Logger.debug(
        "trans: owner is dead: #{inspect(pid)}: cancel transaction. state: #{inspect(data)}"
      )

      {:keep_state, data, [{:next_event, :cast, :cancel}]}
    else
      {:keep_state, data}
    end
  end

  # Handle unexpected messages
  def handle_event(:info, msg, _state, data) do
    Logger.error("trans: unexpected info: #{inspect(msg, @inspect_opts)}")
    {:keep_state, data}
  end

  # Handle unexpected casts
  def handle_event(:cast, msg, _state, data) do
    Logger.error("trans: unexpected cast: #{inspect(msg, @inspect_opts)}")
    {:keep_state, data}
  end

  # Handle unexpected calls
  def handle_event({:call, from}, request, _state, data) do
    Logger.error("trans: unexpected call: #{inspect(request, @inspect_opts)}")
    {:keep_state, data, [{:reply, from, {:error, {:unexpected_call, request}}}]}
  end

  defp log_response_info(sip_msg, data) do
    call_id = sip_msg.headers["call-id"] || "unknown"
    branch = data.logbranch
    method = to_string(sip_msg.method || :unknown)

    Logger.debug(
      "trans: client: response on #{method}: #{sip_msg.status_code} #{sip_msg.reason_phrase}; call-id: #{call_id}; branch: #{branch}"
    )
  end

  defp handle_owner_down(pid, %{data: %{auto_resp: code}} = data) do
    Logger.debug(
      "trans: owner is dead: #{inspect(pid)}: auto reply with #{inspect(code)}. state: #{inspect(data)}"
    )

    resp = Message.reply(data.data.origmsg, code)
    {new_trans, actions} = Parrot.Sip.Transaction.handle_event({:send, resp}, data.trans)
    new_data = %{data | trans: new_trans}

    case process_actions(actions, new_data) do
      :continue -> {:keep_state, new_data}
      :stop -> {:stop, :normal, new_data}
    end
  end

  # Private functions
  defp find_server(sip_msg) do
    Logger.debug("trans: attempting to generate_id")
    trans_id = Transaction.generate_id(sip_msg)
    Logger.debug("#{inspect(trans_id)}")

    case Registry.lookup(Parrot.Registry, trans_id) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  # Returns a Registry tuple using the branch parameter from the topmost Via header.
  #
  # This is used for RFC 3261 transaction matching, where the branch parameter uniquely
  # identifies a transaction. See RFC 3261 Section 17.2.3.
  # Accepts a %Parrot.Sip.Transaction{} and extracts the branch or id for Registry.
  defp via_tuple(%Parrot.Sip.Transaction{id: id}) when is_binary(id) do
    Logger.debug("via_tuple: Using transaction ID: #{id}")
    {:via, Registry, {Parrot.Registry, id}}
  end

  defp via_tuple(%Parrot.Sip.Transaction{branch: branch}) when is_binary(branch) do
    Logger.debug("via_tuple: Fallback to branch (no ID): #{branch}")
    {:via, Registry, {Parrot.Registry, branch}}
  end

  # Helper to start a transaction with error handling
  # Helper function to handle in-dialog requests
  defp handle_in_dialog_request(%Message{} = sip_msg, handler) do
    Logger.debug("Handling in-dialog request: #{sip_msg.method}")

    # Create a new transaction for the in-dialog request
    transaction =
      case Transaction.determine_transaction_type(sip_msg) do
        :non_invite_server ->
          {:ok, t} = Transaction.create_non_invite_server(sip_msg)
          t

        :invite_server ->
          {:ok, t} = Transaction.create_invite_server(sip_msg)
          t

        other ->
          raise ArgumentError,
                "Unsupported transaction type for in-dialog request: #{inspect(other)}"
      end

    # Start the transaction which will handle the request through the normal flow
    start_transaction([transaction, handler])
  end

  # Helper function to generate transaction ID for CANCEL requests
  defp generate_cancel_transaction_id(%Message{} = cancel_msg) do
    # CANCEL uses same transaction ID as the INVITE it's cancelling
    # but with INVITE method instead of CANCEL
    invite_cseq = %{Message.cseq(cancel_msg) | method: :invite}

    invite_msg = %{
      cancel_msg
      | method: :invite,
        headers: Map.put(cancel_msg.headers, "cseq", invite_cseq)
    }

    Transaction.generate_id(invite_msg)
  end

  defp start_transaction(args) do
    case Parrot.Sip.Transaction.Supervisor.start_child(args) do
      {:ok, _} ->
        :ok

      {:error, _} = error ->
        Logger.error("server failed to create transaction: #{inspect(error, @inspect_opts)}")
    end
  end
end
