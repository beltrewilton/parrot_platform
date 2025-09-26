defmodule ParrotSip.TransactionStatem do
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

  alias ParrotSip.Headers.Via
  alias ParrotSip.Transaction
  alias ParrotSip.{Handler, UAS, Message, Parser}

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
    # Expect args to include a %ParrotSip.Transaction{} as the first or a named argument.
    transaction =
      case args do
        [%ParrotSip.Transaction{} = t | _] -> t
        %{transaction: %ParrotSip.Transaction{} = t} -> t
        _ -> raise ArgumentError, "start_link expects a %ParrotSip.Transaction{} in args"
      end

    :gen_statem.start_link(
      via_tuple(transaction),
      __MODULE__,
      args,
      []
    )
  end

  def server_process(%ParrotSip.Message{method: :ack} = sip_msg, handler) do
    Logger.debug("server_process ack")

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

  # in-dialog message received
  def server_process(
        %ParrotSip.Message{
          from: %ParrotSip.Headers.From{parameters: %{"tag" => _from_tag}},
          to: %ParrotSip.Headers.To{parameters: %{"tag" => _to_tag}}
        } = sip_msg,
        handler
      ) do
    case find_server(sip_msg) do
      {:ok, pid} ->
        :gen_statem.cast(pid, {:received, sip_msg})

      :error ->
        Logger.debug("Processing in-dialog request: #{sip_msg.method}")
        handle_in_dialog_request(sip_msg, handler)
    end
  end

  def server_process(%ParrotSip.Message{} = sip_msg, handler) do
    case find_server(sip_msg) do
      {:ok, pid} ->
        :gen_statem.cast(pid, {:received, sip_msg})

      :error ->
        Logger.debug("Creating new transaction for #{sip_msg.method}")

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

  @spec server_response(term(), ParrotSip.Transaction.t()) :: :ok
  def server_response(resp, %ParrotSip.Transaction{} = transaction) do
    Logger.debug("Sending response: #{inspect(resp)}")
    :gen_statem.cast(via_tuple(transaction), {:send, resp})
  end

  @spec create_server_response(term(), term()) :: :ok | {:error, String.t()}
  def create_server_response(resp_sip_msg, req_sip_msg) do
    trans_id = Transaction.generate_id(req_sip_msg)

    case Registry.lookup(ParrotSip.Registry, trans_id) do
      [{pid, _}] when is_pid(pid) ->
        Logger.debug("Found transaction to create reponse: #{inspect(trans_id, @inspect_opts)}")
        :gen_statem.cast(pid, {:send, resp_sip_msg})

      _ ->
        Logger.error("No transaction found for response")
        # TODO: should we support stateless responses. If so, when?
        {:error, "No transaction found"}
    end
  end

  @spec server_cancel(term()) :: {:reply, term()}
  def server_cancel(%Message{} = cancel_sip_msg) do
    # Generate transaction ID for the original INVITE this CANCEL is targeting
    trans_id = generate_cancel_transaction_id(cancel_sip_msg)

    case Registry.lookup(ParrotSip.Registry, trans_id) do
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
  def server_set_owner(code, owner_pid, %ParrotSip.Transaction{} = transaction)
      when is_pid(owner_pid) and is_integer(code) do
    :gen_statem.cast(via_tuple(transaction), {:set_owner, code, owner_pid})
  end

  @spec client_set_owner(pid(), t()) :: :ok
  def client_set_owner(owner_pid, %ParrotSip.Transaction{} = transaction)
      when is_pid(owner_pid) do
    :gen_statem.cast(via_tuple(transaction), {:set_owner, nil, owner_pid})
  end

  @spec client_new(term(), map(), client_callback()) :: t()
  def client_new(transaction, options, callback) do
    # Pass transaction as first element to match init/1 expectations
    args = [transaction, options, callback]

    case ParrotSip.Transaction.Supervisor.start_child(args) do
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
          case sip_msg.cseq do
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
          case Registry.lookup(ParrotSip.Registry, trans_id) do
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
    # Count all transaction processes registered in the Registry
    # This works regardless of which supervisor they're under
    Registry.count(ParrotSip.Registry)
  end

  @impl :gen_statem
  def init([%ParrotSip.Transaction{} = transaction | rest]) do
    sip_msg = transaction.request
    method = transaction.method
    request_uri = sip_msg.request_uri
    transaction_id = transaction.id
    branch = transaction.branch
    call_id = sip_msg.call_id

    # Extract optional registry name from args, default to ParrotSip.Registry
    registry = Keyword.get(rest, :registry, ParrotSip.Registry)

    # Register with the full transaction ID, not just the branch
    Registry.register(registry, transaction_id, nil)

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
        owner_mon: nil,
        timers: %{},
        # TODO: Make configurable
        log: false,
        logbranch: branch
      }

      Logger.debug(
        "trans: client: #{method} #{request_uri}; call-id: #{call_id}; branch: #{branch}"
      )

      # Send the initial request via transport handler
      send_via_transport_handler(:send_request, sip_msg, nil)

      # Start in the transaction's initial state (calling for INVITE, trying for non-INVITE)
      initial_state = transaction.state
      {:ok, initial_state, state}
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
        owner_mon: nil,
        timers: %{},
        # TODO: Make configurable
        log: false,
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

  # Helper to classify response status code to event format
  defp classify_to_event(code) when code >= 100 and code < 200, do: {:send_provisional, code}
  defp classify_to_event(code), do: {:send_final, code}

  # Helper function to apply state transitions from Transaction.next_state/2
  # This centralizes the common pattern of:
  # 1. Update transaction state
  # 2. Optionally update last_response
  # 3. Check if gen_statem state should transition
  # 4. Process actions
  defp apply_state_transition(transaction, event, state, opts \\ []) do
    update_response = Keyword.get(opts, :update_response, nil)
    send_response = Keyword.get(opts, :send_response, false)
    
    case Transaction.next_state(transaction, event) do
      {:ok, new_state_atom, actions} ->
        # Update transaction struct
        new_transaction = 
          if update_response do
            transaction
            |> Transaction.update_state(new_state_atom)
            |> Transaction.update_last_response(update_response)
          else
            Transaction.update_state(transaction, new_state_atom)
          end
        
        new_data = %{state.data | transaction: new_transaction}
        new_state = %{state | data: new_data}

        # Optionally send response via transport
        if send_response && update_response do
          source = extract_source(state, update_response)
          if source do
            send_via_transport_handler(:send_response, update_response, source)
          end
        end

        # Check if gen_statem state should transition
        if transaction.state != new_state_atom do
          case process_actions(actions, new_state) do
            :stop -> {:stop, :normal, new_state}
            {:keep_state, result_state} -> {:next_state, new_state_atom, result_state}
            other -> other
          end
        else
          process_actions(actions, new_state)
        end
      
      {:error, _reason} ->
        {:keep_state, state}
    end
  end

  # Real implementation of process_actions/2 to handle SIP actions and timers.
  defp process_actions([], data) do
    Logger.debug("[process_actions] No more actions to process.")
    {:keep_state, data}
  end

  defp process_actions([action | rest], data) do
    Logger.debug(
      "[process_actions] Processing action: #{inspect(action)} with data: #{inspect(data, pretty: false, limit: 10)}"
    )

    case action do
      {:send_response, response} ->
        Logger.debug("[process_actions] Action is :send_response. Response: #{inspect(response)}")
        # Try to get the source from state, transaction, or response
        source = extract_source(data, response)

        if source do
          Logger.debug("[process_actions] Sending response using source: #{inspect(source)}")
          send_via_transport_handler(:send_response, response, source)
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
        send_via_transport_handler(:send_request, request, nil)

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

        last_response =
          get_in(data, [:transaction, :last_response]) ||
            get_in(data, [:data, :transaction, :last_response])

        if last_response do
          Logger.debug(
            "[process_actions] Retransmitting last response: #{inspect(last_response)}"
          )

          source = extract_source(data, last_response)

          if source do
            send_via_transport_handler(:send_response, last_response, source)
          else
            send_via_transport_handler(:send_response, last_response, nil)
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

      :terminate ->
        Logger.debug("[process_actions] Action is :terminate. Stopping.")
        :stop

      # Timer start actions from Transaction.next_state/2
      :start_timer_a -> process_timer_action(:start_timer, :a, 500, rest, data)
      :start_timer_b -> process_timer_action(:start_timer, :b, 32000, rest, data)
      :start_timer_c -> process_timer_action(:start_timer, :c, 180000, rest, data)
      :start_timer_d -> process_timer_action(:start_timer, :d, 32000, rest, data)
      :start_timer_e -> process_timer_action(:start_timer, :e, 500, rest, data)
      :start_timer_f -> process_timer_action(:start_timer, :f, 32000, rest, data)
      :start_timer_g -> process_timer_action(:start_timer, :g, 500, rest, data)
      :start_timer_h -> process_timer_action(:start_timer, :h, 32000, rest, data)
      :start_timer_i -> process_timer_action(:start_timer, :i, 5000, rest, data)
      :start_timer_j -> process_timer_action(:start_timer, :j, 32000, rest, data)
      :start_timer_k -> process_timer_action(:start_timer, :k, 5000, rest, data)

      # Timer cancel actions from Transaction.next_state/2
      :cancel_timer_a -> process_timer_action(:cancel_timer, :a, nil, rest, data)
      :cancel_timer_b -> process_timer_action(:cancel_timer, :b, nil, rest, data)
      :cancel_timer_c -> process_timer_action(:cancel_timer, :c, nil, rest, data)
      :cancel_timer_d -> process_timer_action(:cancel_timer, :d, nil, rest, data)
      :cancel_timer_e -> process_timer_action(:cancel_timer, :e, nil, rest, data)
      :cancel_timer_f -> process_timer_action(:cancel_timer, :f, nil, rest, data)
      :cancel_timer_g -> process_timer_action(:cancel_timer, :g, nil, rest, data)
      :cancel_timer_h -> process_timer_action(:cancel_timer, :h, nil, rest, data)
      :cancel_timer_i -> process_timer_action(:cancel_timer, :i, nil, rest, data)
      :cancel_timer_j -> process_timer_action(:cancel_timer, :j, nil, rest, data)
      :cancel_timer_k -> process_timer_action(:cancel_timer, :k, nil, rest, data)

      _ ->
        Logger.debug("[process_actions] Unknown action: #{inspect(action)}. Skipping.")
        process_actions(rest, data)
    end
  end

  defp process_timer_action(:start_timer, timer_name, timeout, rest, data) do
    Logger.debug("[process_actions] Starting timer #{timer_name} with timeout #{timeout}ms")
    data = cancel_named_timer(timer_name, data)
    ref = Process.send_after(self(), {:event, timer_name}, timeout)
    updated_data = %{data | timers: Map.put(data.timers || %{}, timer_name, ref)}
    
    case process_actions(rest, updated_data) do
      {:keep_state_and_data, _} -> {:keep_state, updated_data}
      {:keep_state, result_data} -> {:keep_state, result_data}
      :stop -> {:stop, :normal, updated_data}
    end
  end

  defp process_timer_action(:cancel_timer, timer_name, _timeout, rest, data) do
    Logger.debug("[process_actions] Cancelling timer #{timer_name}")
    data = cancel_named_timer(timer_name, data)
    process_actions(rest, data)
  end

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

  defp extract_source(data, response) do
    cond do
      # Check direct source in data
      Map.has_key?(data, :source) and not is_nil(data.source) ->
        Logger.debug("[extract_source] Found source in data.source: #{inspect(data.source)}")
        data.source

      # Check nested data.data.source
      Map.has_key?(data, :data) and Map.has_key?(data.data, :source) and
          not is_nil(data.data.source) ->
        Logger.debug(
          "[extract_source] Found source in data.data.source: #{inspect(data.data.source)}"
        )

        data.data.source

      # Check transaction source
      Map.has_key?(data, :transaction) and Map.has_key?(data.transaction, :source) and
          not is_nil(data.transaction.source) ->
        Logger.debug(
          "[extract_source] Found source in data.transaction.source: #{inspect(data.transaction.source)}"
        )

        data.transaction.source

      # Check nested data.data.transaction.source
      Map.has_key?(data, :data) and Map.has_key?(data.data, :transaction) and
        Map.has_key?(data.data.transaction, :source) and not is_nil(data.data.transaction.source) ->
        Logger.debug("[extract_source] Found source in data.data.transaction.source")
        data.data.transaction.source

      # Check origmsg source
      Map.has_key?(data, :origmsg) and Map.has_key?(data.origmsg, :source) and
          not is_nil(data.origmsg.source) ->
        Logger.debug(
          "[extract_source] Found source in data.origmsg.source: #{inspect(data.origmsg.source)}"
        )

        data.origmsg.source

      # Check nested data.data.origmsg.source
      Map.has_key?(data, :data) and Map.has_key?(data.data, :origmsg) and
        Map.has_key?(data.data.origmsg, :source) and not is_nil(data.data.origmsg.source) ->
        Logger.debug("[extract_source] Found source in data.data.origmsg.source")
        data.data.origmsg.source

      # Try to build from Via header
      Map.has_key?(data, :origmsg) and is_map(data.origmsg) and
        Map.has_key?(data.origmsg, :via) and not is_nil(data.origmsg.via) ->
        via = data.origmsg.via
        Logger.debug("[extract_source] Built source from Via header: #{inspect(via)}")
        %ParrotSip.Source{remote: {via.host, via.port}, transport: via.transport}

      # Check response source
      Map.has_key?(response, :source) and not is_nil(response.source) ->
        Logger.debug(
          "[extract_source] Found source in response.source: #{inspect(response.source)}"
        )

        response.source

      true ->
        Logger.debug("[extract_source] No source found in any known location.")
        nil
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
        ParrotSip.Message.reply(sip_msg, 100, "Trying")
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

  def trying(:cast, {:send, response}, %{data: %{transaction: transaction}} = state) do
    Logger.debug(
      "trying(:cast, {:send, response}, %{data: %{transaction: transaction} = data} = state)"
    )

    event = classify_to_event(response.status_code)
    apply_state_transition(transaction, event, state, 
      update_response: response, 
      send_response: true
    )
  end

  def trying(:cast, :cancel, %{data: %{handler: handler, transaction: transaction}} = state) do
    Logger.debug("trans: canceling server transaction. state: #{inspect(state, @inspect_opts)}")
    UAS.process_cancel(transaction, handler)
    {:keep_state, state}
  end

  # Handle cancel events for client transactions
  def trying(:cast, :cancel, %{data: %{cancelled: true}} = state) do
    Logger.debug(
      "trans: transaction is already cancelled. state: #{inspect(state, @inspect_opts)}"
    )

    {:keep_state, state}
  end

  def trying(:cast, :cancel, %{data: %{cancelled: false, outreq: out_req} = data} = state) do
    Logger.debug("trans: canceling client transaction. state: #{inspect(state, @inspect_opts)}")
    # Generate CANCEL request from original request
    cancel_req = %Message{
      type: :request,
      method: :cancel,
      request_uri: out_req.request_uri,
      call_id: out_req.call_id,
      from: out_req.from,
      to: out_req.to,
      cseq: %{number: out_req.cseq.number, method: :cancel},
      via: out_req.via,
      other_headers: %{}
    }

    {:ok, cancel_transaction} = Transaction.create_non_invite_client(cancel_req)
    _ = client_new(cancel_transaction, %{}, fn _ -> :ok end)
    # Schedule cancel timeout
    {:keep_state, %{state | data: %{data | cancelled: true}},
     [{:state_timeout, 32_000, :cancel_timeout}]}
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

  def trying(:cast, event, state), do: handle_common_event(event, state)

  def trying(:info, event, state), do: handle_event(:info, event, :trying, state)

  def trying(:state_timeout, event, state), do: handle_event(:state_timeout, event, :trying, state)

  def trying(event_type, _event, state) do
    Logger.debug("TransactionStatem.trying/3: Ignoring unexpected event: #{inspect(event_type)}")
    {:keep_state, state}
  end

  # PROCEEDING STATE
  def proceeding(:cast, event, state), do: handle_common_event(event, state)

  def proceeding(:info, event, state), do: handle_event(:info, event, :proceeding, state)

  def proceeding(:state_timeout, event, state), do: handle_event(:state_timeout, event, :proceeding, state)

  def proceeding(event_type, _event, state) do
    Logger.debug(
      "TransactionStatem.proceeding/3: Ignoring unexpected event: #{inspect(event_type)}"
    )

    {:keep_state, state}
  end

  # CALLING STATE
  def calling(
        :cast,
        {:received, %{type: :response, status_code: status_code} = response},
        %{type: :client, data: %{transaction: transaction} = data} = state
      ) do
    Logger.debug(
      "Client transaction received response: #{response.status_code} #{response.reason_phrase}"
    )

    # Call the user callback with the response
    if is_function(data.handler) do
      data.handler.({:response, response})
    end

    apply_state_transition(transaction, {:receive_response, status_code}, state,
      update_response: response
    )
  end

  def calling(:cast, event, state), do: handle_common_event(event, state)

  def calling(:info, event, state), do: handle_event(:info, event, :calling, state)

  def calling(:state_timeout, event, state), do: handle_event(:state_timeout, event, :calling, state)

  def calling(event_type, _event, state) do
    Logger.debug("TransactionStatem.calling/3: Ignoring unexpected event: #{inspect(event_type)}")
    {:keep_state, state}
  end

  # COMPLETED STATE
  # Handle sending responses in completed state for retransmissions
  def completed(:cast, {:send, _response}, %{data: %{transaction: transaction}} = state) do
    Logger.debug(
      "completed state: processing {:send, response} for transaction type: #{transaction.type}"
    )

    # In completed state, we can only retransmit the last response
    if transaction.last_response do
      Logger.debug("Retransmitting last response in completed state")
      source = extract_source(state, transaction.last_response)
      if source do
        send_via_transport_handler(:send_response, transaction.last_response, source)
      end
    end

    {:keep_state, state}
  end

  def completed(:cast, {:received, msg}, %{type: :server} = state) do
    handle_common_event({:received, msg}, state)
  end

  def completed(:cast, {:received, _msg}, %{type: :client} = state) do
    # For client transactions, retransmit last response if available
    if last = get_in(state, [:data, :transaction, :last_response]) do
      source = get_in(state, [:data, :transaction, :source])
      send_via_transport_handler(:send_response, last, source)
    end

    {:keep_state, state}
  end

  def completed(:cast, event, state), do: handle_common_event(event, state)
  
  def completed(:info, event, state), do: handle_event(:info, event, :completed, state)

  def completed(:state_timeout, event, state), do: handle_event(:state_timeout, event, :completed, state)

  def completed(event_type, _event, state) do
    Logger.debug(
      "TransactionStatem.completed/3: Ignoring unexpected event: #{inspect(event_type)}"
    )

    {:keep_state, state}
  end

  # CONFIRMED STATE
  def confirmed(:cast, event, state), do: handle_common_event(event, state)
  
  def confirmed(:info, event, state), do: handle_event(:info, event, :confirmed, state)

  def confirmed(:state_timeout, event, state), do: handle_event(:state_timeout, event, :confirmed, state)

  def confirmed(event_type, _event, state) do
    Logger.debug(
      "TransactionStatem.confirmed/3: Ignoring unexpected event: #{inspect(event_type)}"
    )

    {:keep_state, state}
  end

  # TERMINATED STATE
  def terminated(:cast, _event, state) do
    Logger.warning(
      "TransactionStatem.terminated/3: Transaction already terminated, ignoring event"
    )

    {:keep_state, state}
  end

  def terminated(_event_type, _event, state) do
    Logger.warning(
      "TransactionStatem.terminated/3: Transaction already terminated, ignoring event"
    )

    {:keep_state, state}
  end

  # Handle common events across states
  defp handle_common_event({:send, response}, %{data: %{transaction: transaction}} = state) do
    event = classify_to_event(response.status_code)
    apply_state_transition(transaction, event, state, 
      update_response: response, 
      send_response: true
    )
  end

  defp handle_common_event({:received, %{type: :response, status_code: status_code} = sip_msg}, %{type: :client, data: %{transaction: transaction} = data} = state) do
    log_response_info(sip_msg, state)
    
    # Call the user callback with the response for client transactions
    if is_function(data.handler) do
      data.handler.({:response, sip_msg})
    end
    
    apply_state_transition(transaction, {:receive_response, status_code}, state,
      update_response: sip_msg
    )
  end

  defp handle_common_event({:received, %{type: :response, status_code: status_code} = sip_msg}, %{data: %{transaction: transaction} = data} = state) do
    log_response_info(sip_msg, state)
    
    apply_state_transition(transaction, {:receive_response, status_code}, state,
      update_response: sip_msg
    )
  end

  defp handle_common_event({:received, %{type: :request, method: :ack}}, %{data: %{transaction: transaction}} = state) do
    apply_state_transition(transaction, {:receive_ack}, state)
  end

  defp handle_common_event({:received, _sip_msg}, state) do
    {:keep_state, state}
  end

  defp handle_common_event({:set_owner, code, pid}, %{owner_mon: ref, data: data} = state) do
    Logger.debug(
      "trans: set owner to: #{inspect(pid)} with code: #{inspect(code)}."
    )

    if ref, do: Process.demonitor(ref, [:flush])
    new_ref = Process.monitor(pid)
    Logger.debug("trans: monitoring owner #{inspect(pid)}, monitor ref: #{inspect(new_ref)}")
    new_inner_data = if code, do: Map.put(data, :auto_resp, code), else: data
    new_state = %{state | owner_mon: new_ref, data: new_inner_data}
    Logger.debug("trans: new state owner_mon: #{inspect(new_state.owner_mon)}")
    {:keep_state, new_state}
  end

  # Handle cancel for client transactions - already cancelled
  defp handle_common_event(:cancel, %{type: :client, data: %{cancelled: true}} = state) do
    Logger.debug("trans: transaction is already cancelled.")
    {:keep_state, state}
  end

  # Handle cancel for client transactions - not yet cancelled
  defp handle_common_event(:cancel, %{type: :client, data: %{cancelled: false, outreq: out_req} = data} = state) do
    Logger.debug("trans: canceling client transaction.")
    # Generate CANCEL request from original request
    cancel_req = %Message{
      type: :request,
      method: :cancel,
      request_uri: out_req.request_uri,
      call_id: out_req.call_id,
      from: out_req.from,
      to: out_req.to,
      cseq: %{number: out_req.cseq.number, method: :cancel},
      via: out_req.via,
      other_headers: %{}
    }

    {:ok, cancel_transaction} = Transaction.create_non_invite_client(cancel_req)
    _ = client_new(cancel_transaction, %{}, fn _ -> :ok end)
    # Schedule cancel timeout
    {:keep_state, %{state | data: %{data | cancelled: true}},
     [{:state_timeout, 32_000, :cancel_timeout}]}
  end

  # Handle cancel for server transactions - just ignore
  defp handle_common_event(:cancel, %{type: :server} = state) do
    {:keep_state, state}
  end

  defp handle_common_event(_event, state) do
    {:keep_state, state}
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
        {:DOWN, monitor_ref, :process, pid, reason} = msg,
        state_name,
        state
      ) do
    Logger.debug("Received DOWN message: #{inspect(msg)} in state #{state_name}. State owner_mon: #{inspect(Map.get(state, :owner_mon))}, type: #{inspect(Map.get(state, :type))}")
    
    case state do
      %{owner_mon: ^monitor_ref, type: :client} ->
        # For client transactions, cancel when owner dies
        Logger.debug("Client transaction owner died (reason: #{inspect(reason)}), canceling transaction")
        handle_common_event(:cancel, state)
        
      %{owner_mon: ^monitor_ref, type: :server, data: %{transaction: transaction}} ->
        # For server transactions, send auto-response if no final response sent yet
        if transaction.last_response && transaction.last_response.status_code >= 200 do
          Logger.debug("Server owner died but final response already sent")
          {:keep_state, state}
        else
          Logger.debug("Server owner died, sending auto-response")
          handle_owner_down(pid, state)
        end
        
      _ ->
        Logger.debug("DOWN message doesn't match our owner_mon")
        {:keep_state, state}
    end
  end

  def handle_event(
        :info,
        {:event, :g = timer_event},
        :completed,
        %{data: %{transaction: transaction} = data, timers: timers} = state
      ) do
    Logger.debug("trans: timer G fired, retransmitting response and rescheduling")

    # Retransmit the last response
    if transaction.last_response do
      source = extract_source(state, transaction.last_response)
      if source do
        send_via_transport_handler(:send_response, transaction.last_response, source)
      end
    end

    # Reschedule timer G with exponential backoff (double the interval, max 4000ms per RFC 3261)
    # Cancel old timer first
    if Map.has_key?(timers, :g) do
      Process.cancel_timer(timers[:g])
    end

    # Get the current interval (stored timer ref doesn't help, so start with 500ms and double it)
    # In a real implementation, we'd track the interval. For now, use 1000ms (doubled from initial 500ms)
    new_interval = min(1000, 4000)
    timer_ref = Process.send_after(self(), {:event, :g}, new_interval)
    new_timers = Map.put(timers, :g, timer_ref)

    {:keep_state, %{state | timers: new_timers}}
  end

  def handle_event(
        :info,
        {:event, timer_event},
        _state,
        %{data: %{transaction: transaction} = data} = state
      ) do
    Logger.debug(
      "trans: timer fired #{inspect(timer_event)}. state: #{inspect(state, @inspect_opts)}"
    )

    case Transaction.next_state(transaction, {:timer, timer_event}) do
      {:ok, new_state_atom, actions} ->
        new_trans = Transaction.update_state(transaction, new_state_atom)
        new_data = %{data | transaction: new_trans}
        new_state = %{state | data: new_data}

        case process_actions(actions, new_state) do
          {:keep_state_and_data, _} -> {:keep_state, new_state}
          {:keep_state, _} -> {:keep_state, new_state}
          :stop -> {:stop, :normal, new_state}
        end
      
      {:error, _reason} ->
        {:keep_state, state}
    end
  end

  def handle_event(
        :state_timeout,
        :cancel_timeout,
        _state,
        %{data: %{transaction: transaction, handler: handler}} = state
      ) do
    unless transaction.last_response && transaction.last_response.status_code >= 200 do
      Logger.warning("trans: remote side did not respond after CANCEL request: terminate")

      if is_function(handler) do
        handler.({:stop, :timeout})
      end
    end

    {:stop, :normal, state}
  end

  # Timer expiry for transaction termination (for Timer H/J)
  def handle_event(:state_timeout, :terminate, _state, state) do
    Logger.debug("TransactionStatem: Timer expired, terminating transaction.")
    {:stop, :normal, state}
  end

  # Handle DOWN messages for client transactions
  def handle_event(
        :info,
        {:DOWN, ref, :process, pid, _},
        _state,
        %{owner_mon: ref, data: %{transaction: transaction, outreq: out_req}} = state
      ) do
    request_msg =
      case out_req do
        %{request: msg} -> msg
        %Message{} = msg -> msg
        _ -> nil
      end

    if (request_msg && request_msg.method == :invite) and
         not (transaction.last_response && transaction.last_response.status_code >= 200) do
      Logger.debug(
        "trans: owner is dead: #{inspect(pid)}: cancel transaction. state: #{inspect(state)}"
      )

      {:keep_state, state, [{:next_event, :cast, :cancel}]}
    else
      {:keep_state, state}
    end
  end

  # Handle unexpected messages
  def handle_event(:info, msg, _state, state) do
    Logger.error("trans: unexpected info: #{inspect(msg, @inspect_opts)}")
    {:keep_state, state}
  end

  # Handle unexpected casts
  def handle_event(:cast, msg, _state, state) do
    Logger.error("trans: unexpected cast: #{inspect(msg, @inspect_opts)}")
    {:keep_state, state}
  end

  # Handle unexpected calls
  def handle_event({:call, from}, request, _state, state) do
    Logger.error("trans: unexpected call: #{inspect(request, @inspect_opts)}")
    {:keep_state, state, [{:reply, from, {:error, {:unexpected_call, request}}}]}
  end

  defp log_response_info(sip_msg, state) do
    call_id = sip_msg.call_id || "unknown"
    branch = state.logbranch
    method = to_string(sip_msg.method || :unknown)

    Logger.debug(
      "trans: client: response on #{method}: #{sip_msg.status_code} #{sip_msg.reason_phrase}; call-id: #{call_id}; branch: #{branch}"
    )
  end

  defp handle_owner_down(
         pid,
         %{data: %{auto_resp: code, origmsg: origmsg, transaction: transaction}} = state
       ) do
    Logger.debug(
      "trans: owner is dead: #{inspect(pid)}: auto reply with #{inspect(code)}. state: #{inspect(state)}"
    )

    resp = Message.reply(origmsg, code)
    event = classify_to_event(code)
    
    apply_state_transition(transaction, event, state,
      update_response: resp,
      send_response: true
    )
  end

  # Private functions
  defp find_server(sip_msg) do
    Logger.debug("trans: attempting to generate_id")
    trans_id = Transaction.generate_id(sip_msg)
    Logger.debug("#{inspect(trans_id)}")

    case Registry.lookup(ParrotSip.Registry, trans_id) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  # Returns a Registry tuple using the branch parameter from the topmost Via header.
  #
  # This is used for RFC 3261 transaction matching, where the branch parameter uniquely
  # identifies a transaction. See RFC 3261 Section 17.2.3.
  # Accepts a %ParrotSip.Transaction{} and extracts the branch or id for Registry.
  defp via_tuple(%ParrotSip.Transaction{id: id}) when is_binary(id) do
    Logger.debug("via_tuple: Using transaction ID: #{id}")
    {:via, Registry, {ParrotSip.Registry, id}}
  end

  defp via_tuple(%ParrotSip.Transaction{branch: branch}) when is_binary(branch) do
    Logger.debug("via_tuple: Fallback to branch (no ID): #{branch}")
    {:via, Registry, {ParrotSip.Registry, branch}}
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
    invite_cseq = %{cancel_msg.cseq | method: :invite}

    invite_msg = %{
      cancel_msg
      | method: :invite,
        cseq: invite_cseq
    }

    Transaction.generate_id(invite_msg)
  end

  defp start_transaction(args) do
    case ParrotSip.Transaction.Supervisor.start_child(args) do
      {:ok, _} ->
        :ok

      {:error, _} = error ->
        Logger.error("server failed to create transaction: #{inspect(error, @inspect_opts)}")
    end
  end

  # Helper function to send messages via transport handler
  defp send_via_transport_handler(action, message, destination_or_source) do
    # Try to find the transport handler
    # First try the registered name
    transport_handler =
      case Process.whereis(ParrotSip.TransportHandler) do
        nil ->
          # Try to find via Registry
          case Registry.lookup(ParrotSip.Registry, {ParrotSip.TransportHandler, :default}) do
            [{_pid, handler_pid}] -> handler_pid
            _ -> nil
          end

        pid ->
          pid
      end

    if transport_handler do
      case action do
        :send_request ->
          ParrotSip.TransportHandler.send_request(
            transport_handler,
            message,
            destination_or_source
          )

        :send_response ->
          ParrotSip.TransportHandler.send_response(
            transport_handler,
            message,
            destination_or_source
          )

        _ ->
          Logger.error("Unknown transport action: #{action}")
      end
    else
      Logger.warning("No transport handler available - message not sent")
    end
  end
end
