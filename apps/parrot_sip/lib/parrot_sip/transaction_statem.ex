defmodule ParrotSip.TransactionStatem do
  @moduledoc """
  SIP Transaction State Machine implementation per RFC 3261 Section 17.

  This module implements the SIP transaction layer using OTP's `gen_statem` behavior.
  It handles both client and server transactions for INVITE and non-INVITE methods,
  managing reliability, retransmissions, and proper state transitions according to RFC 3261.

  ## Transaction Types (RFC 3261 Section 17)

  1. **INVITE Client Transaction** - Handles outgoing INVITE requests
  2. **INVITE Server Transaction** - Handles incoming INVITE requests  
  3. **Non-INVITE Client Transaction** - Handles outgoing non-INVITE requests
  4. **Non-INVITE Server Transaction** - Handles incoming non-INVITE requests

  ## State Machine States

  - `:trying` - Initial state for non-INVITE server transactions (RFC 3261 17.2.2)
  - `:calling` - Initial state for INVITE client transactions (RFC 3261 17.1.1)
  - `:proceeding` - Processing state after provisional response (RFC 3261 17.1.1, 17.2.1)
  - `:completed` - Final response sent/received, awaiting ACK (RFC 3261 17.1.1, 17.2.1)
  - `:confirmed` - ACK received, final state for INVITE server (RFC 3261 17.2.1)
  - `:terminated` - Terminal state, transaction cleanup

  ## Timer Management (RFC 3261 Section 17.1.2.2)

  The module implements all RFC 3261 transaction timers:
  - **Timer A** - Retransmit INVITE requests (500ms, exponential backoff)
  - **Timer B** - INVITE transaction timeout (32s)
  - **Timer C** - Proxy INVITE transaction timeout (3min)
  - **Timer D** - Completed state timeout for INVITE client (32s)
  - **Timer E** - Retransmit non-INVITE requests (500ms, exponential backoff)
  - **Timer F** - Non-INVITE transaction timeout (32s)
  - **Timer G** - Retransmit final responses for INVITE server (500ms, exponential backoff)
  - **Timer H** - INVITE server transaction timeout (32s)
  - **Timer I** - Confirmed state timeout for INVITE server (5s TCP, 0s UDP)
  - **Timer J** - Non-INVITE server transaction timeout (32s)
  - **Timer K** - Completed state timeout for non-INVITE client (5s TCP, 0s UDP)

  ## State Transitions

  ### INVITE Client Transaction (RFC 3261 17.1.1)
  ```
  calling -> proceeding -> completed -> terminated
      |                       |
      +--------> completed ---+
  ```

  ### INVITE Server Transaction (RFC 3261 17.2.1)
  ```
  proceeding -> completed -> confirmed -> terminated
                    |
                    +----> terminated
  ```

  ### Non-INVITE Transactions (RFC 3261 17.1.2, 17.2.2)
  ```
  trying -> completed -> terminated
     |
     +----> terminated
  ```

  ## Usage

  Create a new client transaction:
  ```elixir
  transaction = %ParrotSip.Transaction{...}
  callback = fn result -> handle_response(result) end
  {:trans, pid} = ParrotSip.TransactionStatem.client_new(transaction, %{}, callback)
  ```

  Create a new server transaction (typically done automatically):
  ```elixir
  transaction = %ParrotSip.Transaction{...}
  {:ok, pid} = ParrotSip.TransactionStatem.server_new(transaction, handler)
  ```

  ## Events
  - `{:send, response}` - Send response (server transactions)
  - `{:received, message}` - Process incoming SIP message
  - `:cancel` - Cancel transaction
  - `{:set_owner, code, pid}` - Set transaction owner process
  - `{:DOWN, ref, :process, pid, _}` - Owner process monitoring
  - `{:event, timer_event}` - Timer expiration events
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

  @doc """
  Returns a child specification for starting the transaction state machine under a supervisor.

  This function is called by OTP supervisors when starting transaction processes.
  The transaction state machine is configured as a temporary worker that will
  terminate when the transaction completes.

  ## Parameters
  - `args` - Arguments passed to `start_link/1`, should contain a `%ParrotSip.Transaction{}`

  ## Returns
  A child specification map compatible with OTP supervisors.

  ## Example
  ```elixir
  transaction = %ParrotSip.Transaction{...}
  child_spec = ParrotSip.TransactionStatem.child_spec([transaction, handler])
  ```

  ## RFC References
  - RFC 3261 Section 17: Transaction Layer
  """
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

  @doc """
  Starts a new transaction state machine process.

  This function starts a new gen_statem process for handling a SIP transaction.
  It expects the first argument to be a `%ParrotSip.Transaction{}` struct and
  registers the process using the transaction's ID or branch parameter.

  ## Parameters
  - `args` - List or map containing a `%ParrotSip.Transaction{}` and optional additional arguments

  ## Returns
  - `{:ok, pid}` - Successfully started transaction process
  - `{:error, reason}` - Failed to start process

  ## Example
  ```elixir
  transaction = %ParrotSip.Transaction{...}
  {:ok, pid} = ParrotSip.TransactionStatem.start_link([transaction, handler])
  ```

  ## RFC References
  - RFC 3261 Section 17: Transaction Layer
  """
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

  @doc """
  Processes incoming SIP messages for server transactions.

  This function is the main entry point for handling incoming SIP requests.
  It determines if a transaction already exists for the message, and either
  forwards the message to an existing transaction or creates a new one.

  ## Parameters
  - `sip_msg` - Incoming SIP message (`%ParrotSip.Message{}`)
  - `handler` - Handler module/function for processing the message

  ## Returns
  `:ok` - Message has been processed

  ## Behavior
  - **ACK messages**: Special handling for transaction completion (RFC 3261 17.2.1)
  - **In-dialog requests**: Messages with From and To tags
  - **New requests**: Creates new server transaction

  ## Transaction Creation
  For new requests, determines transaction type:
  - `:invite_server` - For INVITE method
  - `:non_invite_server` - For all other methods

  ## RFC References
  - RFC 3261 Section 17.2: Server Transaction
  - RFC 3261 Section 17.2.3: Matching Requests to Server Transactions
  """
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

  @doc """
  Sends a response from a server transaction.

  This function is used by server applications to send SIP responses back to clients.
  The response will be handled according to the current transaction state and RFC 3261
  reliability requirements (retransmissions, state transitions, etc.).

  ## Parameters
  - `resp` - SIP response message (typically a `%ParrotSip.Message{}` with type `:response`)
  - `transaction` - The `%ParrotSip.Transaction{}` struct for the server transaction

  ## Returns
  `:ok` - Response has been queued for sending

  ## Response Handling
  - **1xx responses**: Keep transaction in `:proceeding` state, may send multiple
  - **2xx-6xx responses**: Transition to `:completed` state, start retransmission timers
  - Responses are automatically retransmitted per RFC 3261 reliability rules

  ## Example
  ```elixir
  # Send 100 Trying
  trying_resp = ParrotSip.Message.reply(request, 100, "Trying")
  :ok = ParrotSip.TransactionStatem.server_response(trying_resp, transaction)

  # Send final response
  ok_resp = ParrotSip.Message.reply(request, 200, "OK")
  :ok = ParrotSip.TransactionStatem.server_response(ok_resp, transaction)
  ```

  ## RFC References
  - RFC 3261 Section 17.2: Server Transaction
  - RFC 3261 Section 17.2.1: INVITE Server Transaction
  - RFC 3261 Section 17.2.2: Non-INVITE Server Transaction
  """
  @spec server_response(term(), ParrotSip.Transaction.t()) :: :ok
  def server_response(resp, %ParrotSip.Transaction{} = transaction) do
    Logger.debug("Sending response: #{inspect(resp)}")
    :gen_statem.cast(via_tuple(transaction), {:send, resp})
  end

  @doc """
  Creates and sends a server response for a given request.

  This function looks up the transaction for a request and sends a response.
  It's typically used for stateless response generation or when the transaction
  context is not directly available.

  ## Parameters
  - `resp_sip_msg` - SIP response message to send
  - `req_sip_msg` - Original SIP request message (used for transaction lookup)

  ## Returns
  - `:ok` - Response sent successfully
  - `{:error, reason}` - Failed to find transaction or send response

  ## Behavior
  1. Generates transaction ID from the request message
  2. Looks up the transaction in the Registry
  3. Sends the response via the transaction state machine

  ## Example
  ```elixir
  request = %ParrotSip.Message{method: :invite, ...}
  response = ParrotSip.Message.reply(request, 200, "OK")
  :ok = ParrotSip.TransactionStatem.create_server_response(response, request)
  ```

  ## RFC References
  - RFC 3261 Section 17.2: Server Transaction
  """
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

  @doc """
  Processes a CANCEL request for server transactions.

  This function handles incoming CANCEL requests by finding the corresponding
  INVITE server transaction and cancelling it. Returns an appropriate response
  to the CANCEL request itself.

  ## Parameters
  - `cancel_sip_msg` - CANCEL request message (`%ParrotSip.Message{}`)

  ## Returns
  `{:reply, response}` - SIP response to send back for the CANCEL request

  ## Response Codes
  - **200 OK**: CANCEL was successful, target transaction found and cancelled
  - **481 Call/Transaction Does Not Exist**: No matching transaction found

  ## Behavior
  1. Generates transaction ID for the original INVITE being cancelled
  2. Looks up the INVITE server transaction
  3. Sends cancel event to the transaction
  4. Returns 200 OK or 481 response as appropriate

  ## Example
  ```elixir
  cancel_msg = %ParrotSip.Message{method: :cancel, ...}
  {:reply, response} = ParrotSip.TransactionStatem.server_cancel(cancel_msg)
  # response.status_code will be 200 or 481
  ```

  ## RFC References
  - RFC 3261 Section 9.2: Server Processing of CANCEL
  - RFC 3261 Section 17.2.1: INVITE Server Transaction cancellation
  """
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

  @doc """
  Sets the owner process for a server transaction with an auto-response code.

  The owner process will be monitored, and if it dies before sending a final
  response, the transaction will automatically send the specified response code.
  This prevents server transactions from hanging indefinitely.

  ## Parameters
  - `code` - HTTP status code to send if owner dies before final response (e.g., 500)
  - `owner_pid` - PID of the process that owns this transaction
  - `transaction` - The `%ParrotSip.Transaction{}` struct

  ## Returns
  `:ok` - Owner has been set and is being monitored

  ## Behavior
  - Previous owner monitoring is stopped if an owner was already set
  - New owner is monitored with `Process.monitor/1`
  - If owner dies and no final response sent, auto-response with `code` is sent
  - Common auto-response codes: 500 (Internal Server Error), 503 (Service Unavailable)

  ## Example
  ```elixir
  transaction = %ParrotSip.Transaction{...}
  :ok = ParrotSip.TransactionStatem.server_set_owner(500, self(), transaction)
  ```

  ## RFC References
  - RFC 3261 Section 17.2: Server Transaction (transaction lifecycle management)
  """
  @spec server_set_owner(integer(), pid(), t()) :: :ok
  def server_set_owner(code, owner_pid, %ParrotSip.Transaction{} = transaction)
      when is_pid(owner_pid) and is_integer(code) do
    :gen_statem.cast(via_tuple(transaction), {:set_owner, code, owner_pid})
  end

  @doc """
  Sets the owner process for a client transaction.

  The owner process will be monitored, and if it dies, the transaction will be
  cancelled automatically. This provides automatic cleanup for client transactions
  when the controlling process terminates unexpectedly.

  ## Parameters
  - `owner_pid` - PID of the process that owns this transaction
  - `transaction` - The `%ParrotSip.Transaction{}` struct

  ## Returns
  `:ok` - Owner has been set and is being monitored

  ## Behavior
  - Previous owner monitoring is stopped if an owner was already set
  - New owner is monitored with `Process.monitor/1`
  - If owner dies, transaction is automatically cancelled

  ## Example
  ```elixir
  transaction = %ParrotSip.Transaction{...}
  :ok = ParrotSip.TransactionStatem.client_set_owner(self(), transaction)
  ```

  ## RFC References
  - RFC 3261 Section 17.1: Client Transaction (transaction lifecycle management)
  """
  @spec client_set_owner(pid(), t()) :: :ok
  def client_set_owner(owner_pid, %ParrotSip.Transaction{} = transaction)
      when is_pid(owner_pid) do
    :gen_statem.cast(via_tuple(transaction), {:set_owner, nil, owner_pid})
  end

  @doc """
  Creates a new client transaction for outgoing SIP requests.

  This function starts a new client transaction state machine for sending SIP requests.
  Client transactions handle reliability, retransmissions, and proper state transitions
  for outgoing requests according to RFC 3261.

  ## Parameters
  - `transaction` - A `%ParrotSip.Transaction{}` struct containing request details
  - `options` - Map of transaction options (currently unused)
  - `callback` - Function called with transaction results: `{:response, response}` or `{:stop, reason}`

  ## Returns
  `{:trans, pid}` - Transaction handle containing the process PID

  ## Usage
  ```elixir
  # Create INVITE client transaction
  invite_msg = %ParrotSip.Message{method: :invite, ...}
  {:ok, transaction} = ParrotSip.Transaction.create_invite_client(invite_msg)

  callback = fn
    {:response, response} -> handle_response(response)
    {:stop, reason} -> handle_completion(reason)
  end

  {:trans, pid} = ParrotSip.TransactionStatem.client_new(transaction, %{}, callback)
  ```

  ## State Machine
  - INVITE transactions start in `:calling` state (RFC 3261 17.1.1)
  - Non-INVITE transactions start in `:trying` state (RFC 3261 17.1.2)

  ## RFC References
  - RFC 3261 Section 17.1: Client Transaction
  - RFC 3261 Section 17.1.1: INVITE Client Transaction
  - RFC 3261 Section 17.1.2: Non-INVITE Client Transaction
  """
  @spec client_new(term(), map(), client_callback()) :: t()
  def client_new(transaction, options, callback) do
    # Pass transaction as first element to match init/1 expectations
    args = [transaction, options, callback]

    case ParrotSip.Transaction.Supervisor.start_child(args) do
      {:ok, pid} ->
        {:trans, pid}

      {:error, reason} = error ->
        Logger.error("client failed to create transaction: #{inspect(error, @inspect_opts)}")
        {:error, reason}
    end
  end

  @doc """
  Processes a SIP response for client transactions.

  This function handles incoming SIP responses by parsing the message,
  determining which client transaction it belongs to, and forwarding
  it to the appropriate transaction state machine.

  ## Parameters
  - `via` - Via header from the response (used for transaction matching)
  - `msg` - Raw SIP response message as binary string

  ## Returns
  `:ok` - Response has been processed

  ## Behavior
  1. Parses the binary SIP message
  2. Extracts branch parameter from Via header
  3. Extracts method from CSeq header
  4. Generates transaction ID for lookup
  5. Forwards response to matching client transaction

  ## Transaction Matching
  Client transactions are matched using:
  - Branch parameter from Via header
  - Method from CSeq header
  - Transaction type (client)

  ## Example
  ```elixir
  via = %ParrotSip.Headers.Via{parameters: %{"branch" => "z9hG4bK123"}}
  sip_response = "SIP/2.0 200 OK\r\nCSeq: 1 INVITE\r\n..."
  :ok = ParrotSip.TransactionStatem.client_response(via, sip_response)
  ```

  ## RFC References
  - RFC 3261 Section 17.1: Client Transaction
  - RFC 3261 Section 17.1.3: Matching Responses to Client Transactions
  """
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

  @doc """
  Cancels an ongoing client transaction.

  Sends a CANCEL request for INVITE client transactions or marks non-INVITE
  transactions as cancelled. For INVITE transactions, this generates and sends
  a CANCEL request with the same Call-ID, From, and To as the original INVITE.

  ## Parameters
  - `transaction` - Transaction handle `{:trans, pid}` returned from `client_new/3`

  ## Returns
  `:ok` - Cancel request has been initiated

  ## Behavior
  - For INVITE transactions: Generates and sends CANCEL request (RFC 3261 9.1)
  - For non-INVITE transactions: Marks transaction as cancelled
  - Already cancelled transactions ignore additional cancel requests

  ## Example
  ```elixir
  {:trans, _pid} = transaction = ParrotSip.TransactionStatem.client_new(...)
  :ok = ParrotSip.TransactionStatem.client_cancel(transaction)
  ```

  ## RFC References
  - RFC 3261 Section 9.1: CANCEL Processing
  - RFC 3261 Section 17.1.1.5: Cancelling INVITE Client Transactions
  """
  @spec client_cancel(t()) :: :ok
  def client_cancel({:trans, pid}) do
    :gen_statem.cast(pid, :cancel)
  end

  @doc """
  Returns the total number of active transactions.

  This function counts all transaction processes currently registered in the
  ParrotSip.Registry, providing a way to monitor transaction load and detect
  potential resource issues.

  ## Returns
  Non-negative integer representing the number of active transactions

  ## Example

      active_count = ParrotSip.TransactionStatem.count()
      IO.puts("Active transactions: \#{active_count}")

  ## Use Cases
  - Monitoring system load
  - Debugging transaction leaks
  - Performance analysis
  - Health checks
  """
  @spec count() :: non_neg_integer()
  def count do
    # Count all transaction processes registered in the Registry
    # This works regardless of which supervisor they're under
    Registry.count(ParrotSip.Registry)
  end

  @doc """
  Initializes the transaction state machine.

  This function is called by gen_statem when starting a new transaction process.
  It sets up the initial state, registers the transaction, and determines whether
  this is a client or server transaction based on the transaction type.

  ## Parameters
  - `[transaction | rest]` - List starting with `%ParrotSip.Transaction{}` followed by additional args

  ## Returns
  - `{:ok, initial_state, state_data}` - Successfully initialized
  - `{:stop, reason}` - Initialization failed

  ## Initialization Process
  1. Extract transaction details (method, branch, call-id)
  2. Register transaction in ParrotSip.Registry for message routing
  3. Set up logging metadata for debugging
  4. Determine client vs server transaction type
  5. Initialize state data structure
  6. Start in appropriate initial state

  ## Initial States
  - **INVITE Client**: `:calling` state (RFC 3261 17.1.1)
  - **Non-INVITE Client**: `:trying` state (RFC 3261 17.1.2)
  - **Server Transactions**: `:trying` state (RFC 3261 17.2.1, 17.2.2)

  ## RFC References
  - RFC 3261 Section 17.1: Client Transaction initialization
  - RFC 3261 Section 17.2: Server Transaction initialization
  """
  # Client transaction - INVITE
  @impl :gen_statem
  def init([%ParrotSip.Transaction{type: :invite_client} = transaction, options, callback]) do
    init_client_transaction(transaction, options, callback)
  end

  # Client transaction - non-INVITE
  def init([%ParrotSip.Transaction{type: :non_invite_client} = transaction, options, callback]) do
    init_client_transaction(transaction, options, callback)
  end

  # Server transaction - all other transaction types
  def init([%ParrotSip.Transaction{} = transaction, handler]) do
    init_server_transaction(transaction, handler)
  end

  # Client transaction initialization helper
  defp init_client_transaction(transaction, options, callback) do
    %{request: sip_msg, id: transaction_id, branch: branch, type: client_type} = transaction
    registry = Map.get(options, :registry, ParrotSip.Registry)

    Registry.register(registry, transaction_id, nil)

    Logger.metadata(
      trans_id: transaction_id,
      method: transaction.method,
      call_id: sip_msg.call_id,
      branch: branch
    )

    Logger.debug(
      "trans: client: #{transaction.method} #{sip_msg.request_uri}; " <>
        "call-id: #{sip_msg.call_id}; branch: #{branch}"
    )

    state = %{
      type: :client,
      data: %{
        handler: callback,
        origmsg: sip_msg,
        transaction: transaction,
        options: options,
        outreq: sip_msg,
        cancelled: false
      },
      owner_mon: nil,
      timers: %{},
      log:
        Map.get(
          options,
          :debug_log,
          Application.get_env(:parrot_sip, :transaction_debug_log, false)
        ),
      logbranch: branch
    }

    # Extract destination from message source
    destination =
      case sip_msg.source do
        %{remote: remote} when not is_nil(remote) -> remote
        _ -> nil
      end

    # Send the initial request via transport handler
    send_via_transport_handler(:send_request, sip_msg, destination)

    # Build timer actions based on client type
    timer_actions =
      case client_type do
        :invite_client ->
          timer_a = Map.get(options, :timer_a, 500)
          timer_b = Map.get(options, :timer_b, 32000)

          [
            {:next_event, :internal, {:start_timer, :a, timer_a}},
            {:next_event, :internal, {:start_timer, :b, timer_b}}
          ]

        :non_invite_client ->
          timer_e = Map.get(options, :timer_e, 500)
          timer_f = Map.get(options, :timer_f, 32000)

          [
            {:next_event, :internal, {:start_timer, :e, timer_e}},
            {:next_event, :internal, {:start_timer, :f, timer_f}}
          ]
      end

    {:ok, transaction.state, state, timer_actions}
  end

  # Server transaction initialization helper
  defp init_server_transaction(transaction, handler) do
    %{request: sip_msg, id: transaction_id, branch: branch} = transaction
    registry = ParrotSip.Registry

    Registry.register(registry, transaction_id, nil)

    Logger.metadata(
      trans_id: transaction_id,
      method: transaction.method,
      call_id: sip_msg.call_id,
      branch: branch
    )

    Logger.debug(
      "trans: server: #{transaction.method} #{sip_msg.request_uri}; " <>
        "call-id: #{sip_msg.call_id}; branch: #{branch}"
    )

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
      log: Application.get_env(:parrot_sip, :transaction_debug_log, false),
      logbranch: branch
    }

    {:ok, :trying, state,
     [
       {:next_event, :cast,
        {:handle_transaction_setup, [:server, sip_msg, transaction.method, handler]}}
     ]}
  end

  @doc """
  Returns the gen_statem callback mode.

  This function specifies that the state machine uses state function callbacks,
  where each state is implemented as a separate function (trying/3, calling/3, etc.).
  This provides clear separation between different transaction states.

  ## Returns
  `:state_functions` - Each state is implemented as a separate function

  ## RFC References
  - RFC 3261 Section 17: Transaction Layer state machines
  """
  @impl :gen_statem
  def callback_mode, do: :state_functions

  # Helper to classify response status code to event format
  defp classify_to_event(code) when code >= 100 and code < 200, do: {:send_provisional, code}
  defp classify_to_event(code), do: {:send_final, code}

  # Helper to call Handler state transition callbacks
  defp call_state_transition_callback(:proceeding, transaction, sip_msg, handler) do
    Handler.transaction_proceeding(transaction, sip_msg, handler)
  end

  defp call_state_transition_callback(:completed, transaction, sip_msg, handler) do
    Handler.transaction_completed(transaction, sip_msg, handler)
  end

  defp call_state_transition_callback(:confirmed, transaction, sip_msg, handler) do
    Handler.transaction_confirmed(transaction, sip_msg, handler)
  end

  defp call_state_transition_callback(_state, _transaction, _sip_msg, _handler), do: :ok

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
          # Call state transition callback if handler exists (only for server transactions with Handler struct)
          if state.data.handler && is_struct(state.data.handler, ParrotSip.Handler) &&
               state.data[:origmsg] do
            call_state_transition_callback(
              new_state_atom,
              new_transaction,
              state.data.origmsg,
              state.data.handler
            )
          end

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

        new_data = %{data | timers: timers}

        case process_actions(rest, new_data) do
          {:keep_state_and_data, _} -> {:keep_state, new_data}
          {:keep_state, updated_data} -> {:keep_state, updated_data}
          :stop -> {:stop, :normal, new_data}
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
      :start_timer_a ->
        process_timer_action(:start_timer, :a, 500, rest, data)

      :start_timer_b ->
        process_timer_action(:start_timer, :b, 32000, rest, data)

      :start_timer_c ->
        process_timer_action(:start_timer, :c, 180_000, rest, data)

      :start_timer_d ->
        process_timer_action(:start_timer, :d, 32000, rest, data)

      :start_timer_e ->
        process_timer_action(:start_timer, :e, 500, rest, data)

      :start_timer_f ->
        process_timer_action(:start_timer, :f, 32000, rest, data)

      :start_timer_g ->
        process_timer_action(:start_timer, :g, 500, rest, data)

      :start_timer_h ->
        process_timer_action(:start_timer, :h, 32000, rest, data)

      :start_timer_i ->
        process_timer_action(:start_timer, :i, 5000, rest, data)

      :start_timer_j ->
        process_timer_action(:start_timer, :j, 32000, rest, data)

      :start_timer_k ->
        process_timer_action(:start_timer, :k, 5000, rest, data)

      # Timer cancel actions from Transaction.next_state/2
      :cancel_timer_a ->
        process_timer_action(:cancel_timer, :a, nil, rest, data)

      :cancel_timer_b ->
        process_timer_action(:cancel_timer, :b, nil, rest, data)

      :cancel_timer_c ->
        process_timer_action(:cancel_timer, :c, nil, rest, data)

      :cancel_timer_d ->
        process_timer_action(:cancel_timer, :d, nil, rest, data)

      :cancel_timer_e ->
        process_timer_action(:cancel_timer, :e, nil, rest, data)

      :cancel_timer_f ->
        process_timer_action(:cancel_timer, :f, nil, rest, data)

      :cancel_timer_g ->
        process_timer_action(:cancel_timer, :g, nil, rest, data)

      :cancel_timer_h ->
        process_timer_action(:cancel_timer, :h, nil, rest, data)

      :cancel_timer_i ->
        process_timer_action(:cancel_timer, :i, nil, rest, data)

      :cancel_timer_j ->
        process_timer_action(:cancel_timer, :j, nil, rest, data)

      :cancel_timer_k ->
        process_timer_action(:cancel_timer, :k, nil, rest, data)

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

    # For Timer G, track the initial interval for exponential backoff
    updated_data =
      if timer_name == :g do
        Map.put(updated_data, :timer_g_interval, timeout)
      else
        updated_data
      end

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
        Process.cancel_timer(ref, info: false)
        # Flush any pending timer messages
        receive do
          {:event, ^timer_name} -> :ok
        after
          0 -> :ok
        end

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

  @doc """
  Handles the TRYING state for server transactions.

  The `:trying` state is the initial state for server transactions, where the transaction
  has been created but no provisional response has been sent yet. For INVITE server
  transactions, this state automatically sends a "100 Trying" response.

  ## State Transitions
  - **On provisional response (1xx)**: Transition to `:proceeding` state
  - **On final response (2xx-6xx)**: Transition to `:completed` state
  - **On CANCEL**: Process cancellation request

  ## Parameters
  - `event_type` - Type of event (`:cast`, `:info`, `:state_timeout`)
  - `event` - The specific event data
  - `state` - Current state data

  ## Events Handled
  - `{:handle_transaction_setup, [...]}` - Complete transaction initialization
  - `{:send, response}` - Send response and transition states
  - `:cancel` - Handle CANCEL request
  - `{:set_owner, code, pid}` - Set transaction owner

  ## RFC References
  - RFC 3261 Section 17.2.1: INVITE Server Transaction (proceeding state)
  - RFC 3261 Section 17.2.2: Non-INVITE Server Transaction (trying state)
  """
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

  # Handle initial INVITE (no To tag) - send 100 Trying
  def trying(
        :cast,
        {:handle_transaction_setup,
         [
           :server,
           %{method: :invite, to: %{parameters: to_params}} = sip_msg,
           :invite,
           _handler
         ]},
        %{data: %{transaction: transaction, handler: handler}} = state
      )
      when not is_map_key(to_params, "tag") do
    Logger.debug(":handle_transaction_setup -> Initial INVITE (sending 100 Trying)")

    # Call transaction state callback for :trying state
    Handler.transaction_trying(transaction, sip_msg, handler)

    # Send 100 Trying for initial INVITE per RFC 3261 17.2.1
    trying_resp =
      ParrotSip.Message.reply(sip_msg, 100, "Trying")
      |> Map.put(:body, "")

    UAS.response(trying_resp, transaction)

    # After sending 100 Trying, INVITE server transactions move to proceeding
    # Store the provisional response we sent
    updated_state = put_in(state, [:data, :last_response], trying_resp)

    result =
      case Handler.transaction(transaction, sip_msg, handler) do
        :ok ->
          Logger.debug(
            "Handler.transaction(transaction, sip_msg, handler) -> :ok, moving to proceeding"
          )

          Handler.transaction_proceeding(transaction, sip_msg, handler)
          {:next_state, :proceeding, updated_state}

        :process_uas ->
          Logger.debug(
            "Handler.transaction(transaction, sip_msg, handler) -> :process_uas, moving to proceeding"
          )

          UAS.process(transaction, sip_msg, handler)
          Handler.transaction_proceeding(transaction, sip_msg, handler)
          {:next_state, :proceeding, updated_state}

        err ->
          Logger.error("Handler.transaction failed: #{inspect(err)}")
          {:keep_state, state}
      end

    result
  end

  # Handle re-INVITE (has To tag) - skip 100 Trying
  def trying(
        :cast,
        {:handle_transaction_setup,
         [
           :server,
           %{method: :invite, to: %{parameters: %{"tag" => _}}} = sip_msg,
           :invite,
           _handler
         ]},
        %{data: %{transaction: transaction, handler: handler}} = state
      ) do
    Logger.debug(":handle_transaction_setup -> re-INVITE (skipping 100 Trying)")

    # Call transaction state callback for :trying state
    Handler.transaction_trying(transaction, sip_msg, handler)

    # For re-INVITEs, skip 100 Trying - dialog is already established
    # Process directly without sending provisional response
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

  # Handle non-INVITE transactions - no 100 Trying per RFC 3261 17.2.2
  def trying(
        :cast,
        {:handle_transaction_setup, [:server, sip_msg, _method, _handler]},
        %{data: %{transaction: transaction, handler: handler}} = state
      ) do
    Logger.debug(":handle_transaction_setup -> Non-INVITE transaction (no 100 Trying)")

    # Call transaction state callback for :trying state
    Handler.transaction_trying(transaction, sip_msg, handler)

    # Non-INVITE transactions stay in trying until first response
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

  # RFC 3261 Section 9.2: CANCEL for INVITE - respond with 487 Request Terminated
  def trying(
        :cast,
        :cancel,
        %{data: %{handler: handler, transaction: %{request: %{method: :invite}} = transaction}} =
          state
      ) do
    Logger.debug(
      "trans: canceling INVITE server transaction. state: #{inspect(state, @inspect_opts)}"
    )

    UAS.process_cancel(transaction, handler)
    resp = UAS.make_reply(487, "Request Terminated", transaction, transaction.request)
    server_response(resp, transaction)
    {:keep_state, state}
  end

  # CANCEL for non-INVITE transactions
  def trying(:cast, :cancel, %{data: %{handler: handler, transaction: transaction}} = state) do
    Logger.debug(
      "trans: canceling non-INVITE server transaction. state: #{inspect(state, @inspect_opts)}"
    )

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
    # Schedule cancel timeout (configurable for testing, default 32s per RFC 3261)
    cancel_timeout = Application.get_env(:parrot_sip, :cancel_timeout, 32_000)

    {:keep_state, %{state | data: %{data | cancelled: true}},
     [{:state_timeout, cancel_timeout, :cancel_timeout}]}
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

  def trying(:internal, {:start_timer, timer_name, timeout}, state) do
    # Handle timer start events
    handle_event(:internal, {:start_timer, timer_name, timeout}, :trying, state)
  end

  def trying(:cast, event, state), do: handle_common_event(event, state)

  def trying(:info, event, state), do: handle_event(:info, event, :trying, state)

  def trying(:state_timeout, event, state),
    do: handle_event(:state_timeout, event, :trying, state)

  def trying(event_type, _event, state) do
    Logger.debug("TransactionStatem.trying/3: Ignoring unexpected event: #{inspect(event_type)}")
    {:keep_state, state}
  end

  @doc """
  Handles the PROCEEDING state for transactions.

  The `:proceeding` state occurs after a provisional response (1xx) has been sent
  or received. Transactions remain in this state while processing continues and
  additional provisional responses may be sent.

  ## State Transitions
  - **On additional provisional response (1xx)**: Remain in `:proceeding`
  - **On final response (2xx-6xx)**: Transition to `:completed` state
  - **On CANCEL (server)**: Process cancellation

  ## Parameters
  - `event_type` - Type of event (`:cast`, `:info`, `:state_timeout`)
  - `event` - The specific event data
  - `state` - Current state data

  ## Events Handled
  All events are delegated to common event handlers that manage:
  - Response sending and state transitions
  - Message reception and processing
  - Timer management
  - Owner process monitoring

  ## RFC References
  - RFC 3261 Section 17.1.1: INVITE Client Transaction (proceeding state)
  - RFC 3261 Section 17.2.1: INVITE Server Transaction (proceeding state)
  """
  # RFC 3261 Section 9.2: CANCEL for INVITE in proceeding - respond with 487 Request Terminated
  def proceeding(
        :cast,
        :cancel,
        %{data: %{handler: handler, transaction: %{request: %{method: :invite}} = transaction}} =
          state
      ) do
    Logger.debug(
      "trans: canceling INVITE server transaction in proceeding state. state: #{inspect(state, @inspect_opts)}"
    )

    UAS.process_cancel(transaction, handler)
    resp = UAS.make_reply(487, "Request Terminated", transaction, transaction.request)
    server_response(resp, transaction)
    {:keep_state, state}
  end

  # CANCEL for non-INVITE transactions in proceeding
  def proceeding(:cast, :cancel, %{data: %{handler: handler, transaction: transaction}} = state) do
    Logger.debug(
      "trans: canceling non-INVITE server transaction in proceeding state. state: #{inspect(state, @inspect_opts)}"
    )

    UAS.process_cancel(transaction, handler)
    {:keep_state, state}
  end

  def proceeding(:cast, event, state), do: handle_common_event(event, state)

  def proceeding(:info, event, state), do: handle_event(:info, event, :proceeding, state)

  def proceeding(:state_timeout, event, state),
    do: handle_event(:state_timeout, event, :proceeding, state)

  def proceeding(event_type, _event, state) do
    Logger.debug(
      "TransactionStatem.proceeding/3: Ignoring unexpected event: #{inspect(event_type)}"
    )

    {:keep_state, state}
  end

  @doc """
  Handles the CALLING state for INVITE client transactions.

  The `:calling` state is the initial state for INVITE client transactions after
  the INVITE request has been sent. The transaction waits in this state for the
  first response from the server.

  ## State Transitions
  - **On provisional response (1xx)**: Transition to `:proceeding` state
  - **On final response (2xx-6xx)**: Transition to `:completed` state
  - **On Timer B expiry**: Transaction timeout, transition to `:terminated`

  ## Parameters
  - `event_type` - Type of event (`:cast`, `:info`, `:state_timeout`)
  - `event` - The specific event data  
  - `state` - Current state data

  ## Events Handled
  - `{:received, response}` - Process incoming SIP response
  - Timer events for retransmissions and timeouts
  - CANCEL requests
  - Owner process monitoring

  ## Timer Behavior
  - **Timer A**: Retransmits INVITE request (500ms, exponential backoff)
  - **Timer B**: Transaction timeout (32 seconds)

  ## RFC References
  - RFC 3261 Section 17.1.1.1: INVITE Client Transaction (calling state)
  - RFC 3261 Section 17.1.2.2: Timer management
  """
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

  def calling(:internal, {:start_timer, timer_name, timeout}, state) do
    # Handle timer start events
    handle_event(:internal, {:start_timer, timer_name, timeout}, :calling, state)
  end

  def calling(:cast, event, state), do: handle_common_event(event, state)

  def calling(:info, event, state), do: handle_event(:info, event, :calling, state)

  def calling(:state_timeout, event, state),
    do: handle_event(:state_timeout, event, :calling, state)

  def calling(event_type, _event, state) do
    Logger.debug("TransactionStatem.calling/3: Ignoring unexpected event: #{inspect(event_type)}")
    {:keep_state, state}
  end

  @doc """
  Handles the COMPLETED state for transactions.

  The `:completed` state occurs after a final response (2xx-6xx) has been sent or received.
  For server transactions, this state handles retransmissions of the final response.
  For client transactions, this state waits for ACK (INVITE) or timer expiry (non-INVITE).

  ## State Transitions
  - **INVITE Server**: On ACK received → `:confirmed` state
  - **INVITE Client**: On Timer D expiry → `:terminated` state  
  - **Non-INVITE**: On timer expiry → `:terminated` state

  ## Parameters
  - `event_type` - Type of event (`:cast`, `:info`, `:state_timeout`)
  - `event` - The specific event data
  - `state` - Current state data

  ## Events Handled
  - `{:send, response}` - Retransmit last response (server transactions)
  - `{:received, ack}` - Process ACK message (INVITE server)
  - `{:received, request}` - Retransmit response for duplicate requests
  - Timer events for retransmissions and timeouts

  ## Timer Behavior
  - **Timer G**: Retransmits final response (INVITE server, 500ms exponential backoff)
  - **Timer H**: Transaction timeout (INVITE server, 32s)
  - **Timer D**: Wait time (INVITE client, 32s)
  - **Timer J**: Wait time (non-INVITE server, 32s)
  - **Timer K**: Wait time (non-INVITE client, 5s TCP, 0s UDP)

  ## RFC References
  - RFC 3261 Section 17.1.1.3: INVITE Client Transaction (completed state)
  - RFC 3261 Section 17.1.2.3: Non-INVITE Client Transaction (completed state)
  - RFC 3261 Section 17.2.1: INVITE Server Transaction (completed state)
  - RFC 3261 Section 17.2.2: Non-INVITE Server Transaction (completed state)
  """
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

  def completed(:state_timeout, event, state),
    do: handle_event(:state_timeout, event, :completed, state)

  def completed(event_type, _event, state) do
    Logger.debug(
      "TransactionStatem.completed/3: Ignoring unexpected event: #{inspect(event_type)}"
    )

    {:keep_state, state}
  end

  @doc """
  Handles the CONFIRMED state for INVITE server transactions.

  The `:confirmed` state is only used by INVITE server transactions after receiving
  an ACK for the final response. This state provides time for any remaining messages
  to be processed before transaction termination.

  ## State Transitions
  - **On Timer I expiry**: Transition to `:terminated` state

  ## Parameters
  - `event_type` - Type of event (`:cast`, `:info`, `:state_timeout`)
  - `event` - The specific event data
  - `state` - Current state data

  ## Events Handled
  All events are delegated to common handlers. Most events are ignored in this state
  as the transaction is winding down.

  ## Timer Behavior
  - **Timer I**: Confirmed state timeout (5s for TCP, 0s for UDP)

  ## RFC References
  - RFC 3261 Section 17.2.1: INVITE Server Transaction (confirmed state)
  """
  def confirmed(:cast, event, state), do: handle_common_event(event, state)

  def confirmed(:info, event, state), do: handle_event(:info, event, :confirmed, state)

  def confirmed(:state_timeout, event, state),
    do: handle_event(:state_timeout, event, :confirmed, state)

  def confirmed(event_type, _event, state) do
    Logger.debug(
      "TransactionStatem.confirmed/3: Ignoring unexpected event: #{inspect(event_type)}"
    )

    {:keep_state, state}
  end

  @doc """
  Handles the TERMINATED state for all transactions.

  The `:terminated` state is the final state for all transaction types. Once a
  transaction reaches this state, it ignores all events and will be garbage collected.
  This state represents the end of the transaction lifecycle.

  ## State Transitions
  None - this is the terminal state

  ## Parameters
  - `event_type` - Type of event (`:cast`, `:info`, `:state_timeout`)
  - `event` - The specific event data (ignored)
  - `state` - Current state data

  ## Events Handled
  All events are ignored with a warning logged. The transaction is no longer active.

  ## RFC References
  - RFC 3261 Section 17: Transaction Layer (transaction termination)
  """
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

  defp handle_common_event(
         {:received, %{type: :response, status_code: status_code} = sip_msg},
         %{type: :client, data: %{transaction: transaction} = data} = state
       ) do
    log_response_info(sip_msg, state)

    # Call the user callback with the response for client transactions
    if is_function(data.handler) do
      data.handler.({:response, sip_msg})
    end

    apply_state_transition(transaction, {:receive_response, status_code}, state,
      update_response: sip_msg
    )
  end

  defp handle_common_event(
         {:received, %{type: :response, status_code: status_code} = sip_msg},
         %{data: %{transaction: transaction}} = state
       ) do
    log_response_info(sip_msg, state)

    apply_state_transition(transaction, {:receive_response, status_code}, state,
      update_response: sip_msg
    )
  end

  defp handle_common_event(
         {:received, %{type: :request, method: :ack}},
         %{data: %{transaction: transaction}} = state
       ) do
    apply_state_transition(transaction, {:receive_ack}, state)
  end

  defp handle_common_event({:received, _sip_msg}, state) do
    {:keep_state, state}
  end

  defp handle_common_event({:set_owner, code, pid}, %{owner_mon: ref, data: data} = state) do
    Logger.debug("trans: set owner to: #{inspect(pid)} with code: #{inspect(code)}.")

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
  defp handle_common_event(
         :cancel,
         %{type: :client, data: %{cancelled: false, outreq: out_req} = data} = state
       ) do
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
    # Schedule cancel timeout (configurable for testing, default 32s per RFC 3261)
    cancel_timeout = Application.get_env(:parrot_sip, :cancel_timeout, 32_000)

    {:keep_state, %{state | data: %{data | cancelled: true}},
     [{:state_timeout, cancel_timeout, :cancel_timeout}]}
  end

  # Handle cancel for server transactions - just ignore
  defp handle_common_event(:cancel, %{type: :server} = state) do
    {:keep_state, state}
  end

  defp handle_common_event(_event, state) do
    {:keep_state, state}
  end

  @doc """
  Handles transaction termination and cleanup.

  This function is called when the transaction state machine is terminating,
  either normally or due to an error. It provides logging and cleanup opportunities.

  ## Parameters
  - `reason` - Termination reason (`:normal`, `:shutdown`, error tuple, etc.)
  - `_state` - Final state name (unused)
  - `data` - Final state data

  ## Returns
  `:ok` - Termination handled

  ## Behavior
  - Normal termination (`:normal`): Logs debug message
  - Error termination: Logs error message with reason
  - State data is logged for debugging purposes

  ## RFC References
  - RFC 3261 Section 17: Transaction Layer (cleanup and termination)
  """
  @impl :gen_statem
  def terminate(reason, state_name, %{data: data} = _state) do
    case reason do
      :normal ->
        Logger.debug("trans: finished. state: #{inspect(data, @inspect_opts)}")

        # If this is a client transaction with a callback, notify it
        # Check if we're terminating due to timeout (when in calling/trying state)
        if data[:handler] && is_function(data.handler) do
          case state_name do
            :calling ->
              # INVITE client timeout (Timer B)
              try do
                data.handler.({:stop, :timeout})
              rescue
                FunctionClauseError -> :ok
                _ -> :ok
              end

            :trying ->
              # Non-INVITE client timeout (Timer F)  
              try do
                data.handler.({:stop, :timeout})
              rescue
                FunctionClauseError -> :ok
                _ -> :ok
              end

            _ ->
              # Normal termination
              try do
                data.handler.({:stop, :normal})
              rescue
                FunctionClauseError -> :ok
                _ -> :ok
              end
          end
        end

      _ ->
        Logger.error("trans: finished with error: #{inspect(reason, @inspect_opts)}")

        # Notify callback of error if present
        if data[:handler] && is_function(data.handler) do
          data.handler.({:stop, reason})
        end
    end

    :ok
  end

  @doc """
  Handles events that occur outside the normal state function flow.

  This function handles system events that can occur in any state, such as
  process monitoring (DOWN messages), timer events, and unexpected messages.
  It implements the gen_statem handle_event callback for managing cross-state concerns.

  ## Parameters
  - `event_type` - Type of event (`:info`, `:cast`, `{:call, from}`, `:state_timeout`)
  - `event` - The specific event data
  - `state_name` - Current state name (`:trying`, `:calling`, etc.)
  - `state` - Current state data

  ## Events Handled
  - `{:DOWN, ref, :process, pid, reason}` - Owner process died
  - `{:event, timer_name}` - Timer expiration (A, B, C, D, E, F, G, H, I, J, K)
  - `:cancel_timeout` - CANCEL request timeout
  - `:terminate` - Transaction termination timeout

  ## Owner Process Monitoring
  When the owner process dies:
  - **Client transactions**: Automatically cancelled to prevent resource leaks
  - **Server transactions**: Auto-response sent if no final response was sent

  ## Timer Events
  Handles all RFC 3261 transaction timers with appropriate retransmissions,
  state transitions, and termination logic.

  ## RFC References
  - RFC 3261 Section 17.1.2.2: Timer Values and Behavior
  - RFC 3261 Section 17.2.4: Handling Transport Errors
  """
  @impl :gen_statem
  def handle_event(
        :info,
        {:DOWN, monitor_ref, :process, pid, reason} = msg,
        state_name,
        state
      ) do
    Logger.debug(
      "Received DOWN message: #{inspect(msg)} in state #{state_name}. State owner_mon: #{inspect(Map.get(state, :owner_mon))}, type: #{inspect(Map.get(state, :type))}"
    )

    case state do
      %{owner_mon: ^monitor_ref, type: :client} ->
        # For client transactions, cancel when owner dies
        Logger.debug(
          "Client transaction owner died (reason: #{inspect(reason)}), canceling transaction"
        )

        handle_common_event(:cancel, state)

      %{owner_mon: ^monitor_ref, type: :server, data: %{transaction: transaction}} ->
        # For server transactions, send auto-response if no final response sent yet
        case transaction.last_response do
          %{status_code: code} when code >= 200 ->
            Logger.debug("Server owner died but final response already sent")
            {:keep_state, state}

          _ ->
            Logger.debug("Server owner died, sending auto-response")
            handle_owner_down(pid, state)
        end

      _ ->
        Logger.debug("DOWN message doesn't match our owner_mon")
        {:keep_state, state}
    end
  end

  # Special handling for Timer A - INVITE client retransmission with exponential backoff
  def handle_event(
        :info,
        {:event, :a},
        :calling,
        %{data: %{transaction: %{type: :invite_client}, outreq: request}, timers: timers} = state
      ) do
    Logger.debug("trans: timer A fired, retransmitting INVITE request and rescheduling")

    # Retransmit the request
    send_via_transport_handler(:send_request, request, nil)

    # Reschedule timer A with exponential backoff (double the interval)
    # Cancel old timer and flush any pending timer messages to prevent race condition
    if Map.has_key?(timers, :a) do
      Process.cancel_timer(timers[:a], info: false)
      # Flush any pending timer A messages
      receive do
        {:event, :a} -> :ok
      after
        0 -> :ok
      end
    end

    # Get the current interval and double it
    # Timer A starts at 500ms (T1 in RFC 3261)
    current_interval = Map.get(state.data, :timer_a_interval, 500)
    new_interval = current_interval * 2

    timer_ref = Process.send_after(self(), {:event, :a}, new_interval)
    new_timers = Map.put(timers, :a, timer_ref)

    new_data = Map.put(state.data, :timer_a_interval, new_interval)
    {:keep_state, %{state | timers: new_timers, data: new_data}}
  end

  # Special handling for Timer E - Non-INVITE client retransmission with exponential backoff
  def handle_event(
        :info,
        {:event, :e},
        :trying,
        %{data: %{transaction: %{type: :non_invite_client}, outreq: request}, timers: timers} =
          state
      ) do
    Logger.debug("trans: timer E fired, retransmitting non-INVITE request and rescheduling")

    # Retransmit the request
    send_via_transport_handler(:send_request, request, nil)

    # Reschedule timer E with exponential backoff (double the interval, max T2 = 4000ms)
    # Cancel old timer and flush any pending timer messages to prevent race condition
    if Map.has_key?(timers, :e) do
      Process.cancel_timer(timers[:e], info: false)
      # Flush any pending timer E messages
      receive do
        {:event, :e} -> :ok
      after
        0 -> :ok
      end
    end

    # Get the current interval and double it, capping at 4000ms (T2) per RFC 3261
    current_interval = Map.get(state.data, :timer_e_interval, 500)
    new_interval = min(current_interval * 2, 4000)

    timer_ref = Process.send_after(self(), {:event, :e}, new_interval)
    new_timers = Map.put(timers, :e, timer_ref)

    new_data = Map.put(state.data, :timer_e_interval, new_interval)
    {:keep_state, %{state | timers: new_timers, data: new_data}}
  end

  # Special handling for Timer G - server retransmission with exponential backoff
  def handle_event(
        :info,
        {:event, :g},
        :completed,
        %{data: %{transaction: transaction}, timers: timers} = state
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
    # Cancel old timer and flush any pending timer messages to prevent race condition
    if Map.has_key?(timers, :g) do
      Process.cancel_timer(timers[:g], info: false)
      # Flush any pending timer G messages
      receive do
        {:event, :g} -> :ok
      after
        0 -> :ok
      end
    end

    # Get the current interval and double it, capping at 4000ms per RFC 3261
    # Timer G starts at 500ms (set when entering completed state)
    current_interval = Map.get(state.data, :timer_g_interval, 500)
    new_interval = min(current_interval * 2, 4000)

    timer_ref = Process.send_after(self(), {:event, :g}, new_interval)
    new_timers = Map.put(timers, :g, timer_ref)

    new_data = Map.put(state.data, :timer_g_interval, new_interval)
    {:keep_state, %{state | timers: new_timers, data: new_data}}
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
        :internal,
        {:start_timer, timer_name, timeout},
        _state_name,
        state
      ) do
    # Process timer start actions
    actions = [{:start_timer, timer_name, timeout}]

    case process_actions(actions, state) do
      {:keep_state_and_data, _} -> {:keep_state, state}
      {:keep_state, new_state} -> {:keep_state, new_state}
      :stop -> {:stop, :normal, state}
    end
  end

  def handle_event(
        :state_timeout,
        :cancel_timeout,
        _state,
        %{data: %{transaction: transaction, handler: handler}} = state
      ) do
    case transaction.last_response do
      %{status_code: code} when code >= 200 ->
        # Final response already received
        :ok

      _ ->
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

  @doc """
  Returns a Registry via tuple for transaction process registration.

  This function creates the Registry via tuple used for process registration and lookup.
  The tuple uses the transaction ID or branch parameter for unique identification
  according to RFC 3261 transaction matching rules.

  ## Parameters
  - `transaction` - A `%ParrotSip.Transaction{}` struct

  ## Returns
  `{:via, Registry, {ParrotSip.Registry, transaction_id}}` - Registry via tuple

  ## Transaction Matching (RFC 3261 17.2.3)
  Transactions are matched using:
  1. Primary: Transaction ID (if available)
  2. Fallback: Branch parameter from Via header

  ## Example
  ```elixir
  transaction = %ParrotSip.Transaction{id: "branch123:invite:server"}
  via_tuple = ParrotSip.TransactionStatem.via_tuple(transaction)
  # Returns: {:via, Registry, {ParrotSip.Registry, "branch123:invite:server"}}
  ```

  ## RFC References
  - RFC 3261 Section 17.2.3: Matching Requests to Server Transactions
  - RFC 3261 Section 8.1.1.7: Via Header Field
  """
  def via_tuple(%ParrotSip.Transaction{id: id}) when is_binary(id) do
    Logger.debug("via_tuple: Using transaction ID: #{id}")
    {:via, Registry, {ParrotSip.Registry, id}}
  end

  def via_tuple(%ParrotSip.Transaction{branch: branch}) when is_binary(branch) do
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
