defmodule ParrotSip.Transaction do
  @moduledoc """
  Implementation of SIP transaction management according to RFC 3261 Section 17.

  A SIP transaction consists of a single request and any responses to that request,
  which include zero or more provisional responses and one or more final responses.
  Transactions are a fundamental component of the SIP protocol, providing reliability,
  message sequencing, and state management.

  As defined in RFC 3261, there are four types of transactions:
  - INVITE Client Transaction (Section 17.1.1)
  - Non-INVITE Client Transaction (Section 17.1.2)
  - INVITE Server Transaction (Section 17.2.1)
  - Non-INVITE Server Transaction (Section 17.2.2)

  Each transaction type has its own state machine and handling rules.

  This module provides functionality for:
  - Creating client and server transactions
  - Generating transaction IDs and branch parameters
  - Managing transaction state transitions
  - Handling transaction timeouts and retransmissions
  - Correlating responses to requests

  This module provides the pure functional implementation of SIP transactions.
  For stateful transaction management, see ParrotSip.TransactionStatem.

  References:
  - RFC 3261: SIP: Session Initiation Protocol (https://tools.ietf.org/html/rfc3261)
    - Section 17: Transactions
    - Section 8.1.1.7: Transaction Identifier
    - Section 17.1: Client Transaction
    - Section 17.2: Server Transaction
  """

  require Logger

  alias ParrotSip.Message
  alias ParrotSip.Headers

  @type transaction_type ::
          :invite_client | :non_invite_client | :invite_server | :non_invite_server
  @type transaction_state ::
          :calling
          | :trying
          | :proceeding
          | :completed
          | :confirmed
          | :terminated

  @doc """
  Generates a unique branch parameter for SIP transactions.

  The branch parameter is a mandatory part of the Via header and serves as a
  transaction identifier. Per RFC 3261 Section 8.1.1.7, the branch ID MUST
  start with the magic cookie "z9hG4bK" to indicate RFC 3261 compliance.

  ## Purpose
  - Uniquely identifies a transaction within the scope of a client
  - Enables stateless proxies to detect loops
  - Required for transaction matching

  ## RFC References
  - RFC 3261 Section 8.1.1.7: Via header branch parameter requirements
  - RFC 3261 Section 17.1.3: Matching responses to client transactions
  - RFC 3261 Section 17.2.3: Matching requests to server transactions

  ## Examples

      iex> branch = ParrotSip.Transaction.generate_branch(%ParrotSip.Message{})
      iex> String.starts_with?(branch, "z9hG4bK")
      true

      iex> branch1 = ParrotSip.Transaction.generate_branch(%ParrotSip.Message{})
      iex> branch2 = ParrotSip.Transaction.generate_branch(%ParrotSip.Message{})
      iex> branch1 != branch2
      true

  """
  @spec generate_branch(Message.t()) :: String.t()
  def generate_branch(_message) do
    ParrotSip.Branch.generate()
  end

  @doc """
  Generates a unique transaction ID for a SIP message.

  Transaction IDs are used internally to uniquely identify and track transactions.
  The ID combines the branch parameter, method, and role (client/server) to ensure
  uniqueness across all transaction types.

  ## Transaction ID Format
  - Client transactions: `<branch>:<method>:client`
  - Server transactions: `<branch>:<method>:<cseq_number>`

  Special case: ACK requests for non-2xx responses use `:invite` as the method
  to match the original INVITE transaction (RFC 3261 Section 17.1.1.3).

  ## RFC References
  - RFC 3261 Section 17: Transaction layer
  - RFC 3261 Section 17.1.1.3: ACK matching for INVITE client transactions
  - RFC 3261 Section 17.2.3: Matching requests to server transactions

  ## Examples

      iex> via = %ParrotSip.Headers.Via{
      ...>   host: "example.com",
      ...>   port: 5060,
      ...>   transport: "UDP",
      ...>   parameters: %{"branch" => "z9hG4bK776asdhds"}
      ...> }
      iex> invite = %ParrotSip.Message{
      ...>   type: :request,
      ...>   method: :invite,
      ...>   via: via,
      ...>   cseq: %{number: 1, method: :invite}
      ...> }
      iex> ParrotSip.Transaction.generate_id(invite)
      "z9hG4bK776asdhds:invite:1"

  """
  @spec generate_id(Message.t()) :: String.t()
  def generate_id(message) do
    branch = get_branch(message)
    generate_transaction_id(determine_transaction_type(message), branch, message)
  end

  # Helper function to safely extract method from message
  defp get_method(%{method: method}) when is_atom(method), do: method
  defp get_method(_), do: :unknown

  @doc """
  Determines the transaction type from a SIP message.

  There are four transaction types defined in RFC 3261:
  - `:invite_server` - Server receiving an INVITE request
  - `:non_invite_server` - Server receiving a non-INVITE request  
  - `:invite_client` - Client sending an INVITE request
  - `:non_invite_client` - Client sending a non-INVITE request

  The type is determined by:
  1. Whether the message is a request or response
  2. The method (INVITE vs. non-INVITE)

  ## RFC References
  - RFC 3261 Section 17.1.1: INVITE Client Transaction
  - RFC 3261 Section 17.1.2: Non-INVITE Client Transaction  
  - RFC 3261 Section 17.2.1: INVITE Server Transaction
  - RFC 3261 Section 17.2.2: Non-INVITE Server Transaction

  ## Examples

      iex> invite_request = %ParrotSip.Message{type: :request, method: :invite}
      iex> ParrotSip.Transaction.determine_transaction_type(invite_request)
      :invite_server

      iex> register_request = %ParrotSip.Message{type: :request, method: :register}
      iex> ParrotSip.Transaction.determine_transaction_type(register_request)
      :non_invite_server

      iex> invite_response = %ParrotSip.Message{
      ...>   type: :response, 
      ...>   status_code: 200,
      ...>   cseq: %{method: :invite, number: 1}
      ...> }
      iex> ParrotSip.Transaction.determine_transaction_type(invite_response)
      :invite_client

  """
  @spec determine_transaction_type(Message.t()) :: transaction_type()
  def determine_transaction_type(message) do
    determine_transaction_type_impl(
      is_request?(message),
      get_method(message),
      get_cseq_method(message)
    )
  end

  # Request transactions - server side
  defp determine_transaction_type_impl(true, :invite, _cseq_method) do
    :invite_server
  end

  defp determine_transaction_type_impl(true, _method, _cseq_method) do
    :non_invite_server
  end

  # Response transactions - client side
  defp determine_transaction_type_impl(false, _method, :invite) do
    :invite_client
  end

  defp determine_transaction_type_impl(false, _method, _cseq_method) do
    :non_invite_client
  end

  # Helper function to check if message is a request
  defp is_request?(%ParrotSip.Message{type: :request}), do: true
  defp is_request?(_), do: false

  # Helper function to safely extract CSeq method from message
  defp get_cseq_method(%{cseq: %{method: method}}), do: method
  defp get_cseq_method(_), do: :unknown

  # This function is already defined as a private function below
  # Removing the duplicate implementation

  @doc """
  Validates a SIP message for transaction processing.

  Checks that the message contains all mandatory headers required for transaction
  processing according to RFC 3261. The required headers are:
  - Via: Contains routing information and branch parameter
  - CSeq: Sequence number and method
  - Call-ID: Unique identifier for the call/dialog

  ## RFC References
  - RFC 3261 Section 8.1.1: Via header requirements
  - RFC 3261 Section 8.1.1.5: CSeq header requirements
  - RFC 3261 Section 8.1.1.4: Call-ID header requirements
  - RFC 3261 Section 17: Transaction layer

  ## Examples

      iex> valid_msg = %ParrotSip.Message{
      ...>   via: %ParrotSip.Headers.Via{host: "example.com"},
      ...>   cseq: %{number: 1, method: :invite},
      ...>   call_id: "abc123@example.com"
      ...> }
      iex> {:ok, _} = ParrotSip.Transaction.validate_message(valid_msg)

      iex> invalid_msg = %ParrotSip.Message{via: nil, cseq: nil, call_id: nil}
      iex> {:error, "Missing Via header"} = ParrotSip.Transaction.validate_message(invalid_msg)

  """
  @spec validate_message(Message.t()) :: {:ok, Message.t()} | {:error, String.t()}
  def validate_message(message) do
    # RFC 3261 Section 8.1.1: Required headers for all SIP messages
    with :ok <- validate_via_header(message),
         :ok <- validate_cseq_header(message),
         :ok <- validate_call_id_header(message),
         :ok <- validate_from_header(message),
         :ok <- validate_to_header(message),
         :ok <- validate_request_specific(message),
         :ok <- validate_response_specific(message) do
      {:ok, message}
    end
  end

  # Via header validation (RFC 3261 Section 8.1.1.7)
  defp validate_via_header(%{via: via}) when is_list(via) and length(via) > 0, do: :ok
  defp validate_via_header(_), do: {:error, "Missing or invalid Via header"}

  # CSeq header validation (RFC 3261 Section 8.1.1.5)
  defp validate_cseq_header(%{cseq: %{number: num, method: method}})
       when is_integer(num) and is_atom(method),
       do: :ok

  defp validate_cseq_header(_), do: {:error, "Missing or invalid CSeq header"}

  # Call-ID header validation (RFC 3261 Section 8.1.1.4)
  defp validate_call_id_header(%{call_id: call_id}) when is_binary(call_id) and call_id != "",
    do: :ok

  defp validate_call_id_header(_), do: {:error, "Missing or invalid Call-ID header"}

  # From header validation (RFC 3261 Section 8.1.1.3)
  defp validate_from_header(%{from: %{uri: uri}}) when not is_nil(uri), do: :ok
  defp validate_from_header(_), do: {:error, "Missing or invalid From header"}

  # To header validation (RFC 3261 Section 8.1.1.2)
  defp validate_to_header(%{to: %{uri: uri}}) when not is_nil(uri), do: :ok
  defp validate_to_header(_), do: {:error, "Missing or invalid To header"}

  # Request-specific validation (RFC 3261 Section 8.1.1)
  defp validate_request_specific(%{type: :request, method: :register} = message) do
    # REGISTER requests must have Contact header (RFC 3261 Section 10.2)
    validate_contact_header_present(message)
  end

  defp validate_request_specific(%{type: :request, method: method, request_uri: uri})
       when is_atom(method) and is_binary(uri) and uri != "",
       do: :ok

  defp validate_request_specific(%{type: :request}),
    do: {:error, "Invalid request: missing method or request URI"}

  defp validate_request_specific(_), do: :ok

  # Response-specific validation (RFC 3261 Section 8.1.2)
  defp validate_response_specific(%{type: :response, status_code: code, reason_phrase: phrase})
       when is_integer(code) and code >= 100 and code < 700 and is_binary(phrase),
       do: :ok

  defp validate_response_specific(%{type: :response}),
    do: {:error, "Invalid response: missing or invalid status code or reason phrase"}

  defp validate_response_specific(_), do: :ok

  # Contact header validation helper
  defp validate_contact_header_present(%{contact: contact}) when not is_nil(contact), do: :ok

  defp validate_contact_header_present(_),
    do: {:error, "REGISTER request must have Contact header"}

  defstruct [
    :id,
    :type,
    :state,
    :request,
    :last_response,
    :branch,
    :method,
    :created_at,
    :role
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: transaction_type(),
          state: transaction_state(),
          request: Message.t(),
          last_response: Message.t() | nil,
          branch: String.t(),
          method: atom(),
          created_at: integer(),
          role: :uas | :uac | nil
        }

  @doc """
  Creates a new client transaction for an INVITE request.

  INVITE client transactions are used when a UAC (User Agent Client) sends an
  INVITE request to establish a session. The transaction starts in the `:calling`
  state and handles all responses to the INVITE, including provisional (1xx),
  success (2xx), and failure (3xx-6xx) responses.

  ## State Machine
  - Initial state: `:calling`
  - Provisional response (1xx) → `:proceeding`
  - Final response (2xx-6xx) → `:completed` or `:terminated`

  ## RFC References
  - RFC 3261 Section 17.1.1: INVITE Client Transaction
  - RFC 3261 Section 17.1.1.1: Overview of INVITE Transaction
  - RFC 3261 Section 17.1.1.2: Formal Description (State Machine)

  ## Parameters

  - `request`: The SIP INVITE request that initiates the transaction

  ## Returns

  - `{:ok, transaction}`: A new transaction struct in `:calling` state

  ## Examples

      iex> via = %ParrotSip.Headers.Via{
      ...>   host: "client.example.com",
      ...>   port: 5060,
      ...>   transport: "UDP",
      ...>   parameters: %{"branch" => "z9hG4bK776asdhds"}
      ...> }
      iex> invite = %ParrotSip.Message{
      ...>   type: :request,
      ...>   method: :invite,
      ...>   via: via,
      ...>   cseq: %{number: 1, method: :invite}
      ...> }
      iex> {:ok, transaction} = ParrotSip.Transaction.create_invite_client(invite)
      iex> transaction.state
      :calling
      iex> transaction.type
      :invite_client
      iex> transaction.role
      :uac

  """
  @spec create_invite_client(Message.t()) :: {:ok, t()}
  def create_invite_client(request) do
    # Extract branch parameter from Via header
    branch = get_branch(request)

    # Create transaction ID
    id = generate_transaction_id(:invite_client, branch, request)

    # Create the transaction in calling state (RFC 3261 17.1.1)
    transaction = %__MODULE__{
      id: id,
      type: :invite_client,
      state: :calling,
      request: request,
      last_response: nil,
      branch: branch,
      method: :invite,
      created_at: System.system_time(:millisecond),
      role: :uac
    }

    {:ok, transaction}
  end

  @doc """
  Creates a new client transaction for a non-INVITE request.

  Non-INVITE client transactions handle all SIP methods except INVITE, including
  REGISTER, OPTIONS, BYE, CANCEL, etc. These transactions start in the `:trying`
  state and have a simpler state machine than INVITE transactions.

  ## Purpose
  - Handle client-side processing of non-INVITE requests
  - Manage retransmissions and timeouts for non-INVITE methods
  - Provide reliability for request/response exchanges

  ## State Machine
  - Initial state: `:trying`
  - Provisional response (1xx) → `:proceeding`
  - Final response (2xx-6xx) → `:completed`
  - Timer K expires → `:terminated`

  ## RFC References
  - RFC 3261 Section 17.1.2: Non-INVITE Client Transaction
  - RFC 3261 Section 17.1.2.1: Overview
  - RFC 3261 Section 17.1.2.2: Formal Description

  ## Parameters

  - `request`: The SIP request that initiates the transaction (REGISTER, OPTIONS, etc.)

  ## Returns

  - `{:ok, transaction}`: A new transaction struct in `:trying` state

  ## Examples

      iex> via = %ParrotSip.Headers.Via{
      ...>   host: "client.example.com",
      ...>   port: 5060,
      ...>   transport: "UDP",
      ...>   parameters: %{"branch" => "z9hG4bK-register-123"}
      ...> }
      iex> register = %ParrotSip.Message{
      ...>   type: :request,
      ...>   method: :register,
      ...>   via: via,
      ...>   cseq: %{number: 1, method: :register}
      ...> }
      iex> {:ok, transaction} = ParrotSip.Transaction.create_non_invite_client(register)
      iex> transaction.state
      :trying
      iex> transaction.type
      :non_invite_client
      iex> transaction.role
      :uac
      iex> transaction.method
      :register

  """
  @spec create_non_invite_client(Message.t()) :: {:ok, t()}
  def create_non_invite_client(request) do
    # Extract branch parameter from Via header
    branch = get_branch(request)

    # Create transaction ID
    id = generate_transaction_id(:non_invite_client, branch, request)

    # Create the transaction in trying state (RFC 3261 17.1.2)
    transaction = %__MODULE__{
      id: id,
      type: :non_invite_client,
      state: :trying,
      request: request,
      last_response: nil,
      branch: branch,
      method: request.method,
      created_at: System.system_time(:millisecond),
      role: :uac
    }

    {:ok, transaction}
  end

  @doc """
  Creates a new server transaction for an INVITE request.

  INVITE server transactions are used when a UAS (User Agent Server) receives an
  INVITE request. The transaction starts in the `:trying` state and handles the
  complete INVITE/response/ACK sequence for session establishment.

  ## Purpose
  - Handle server-side processing of INVITE requests
  - Manage provisional and final response sending
  - Handle ACK reception for error responses
  - Provide reliable session establishment

  ## State Machine
  - Initial state: `:trying`
  - Send provisional response → `:proceeding`
  - Send 2xx response → `:terminated` (no ACK handling)
  - Send 3xx-6xx response → `:completed`
  - Receive ACK → `:confirmed`
  - Timer I expires → `:terminated`

  ## RFC References
  - RFC 3261 Section 17.2.1: INVITE Server Transaction
  - RFC 3261 Section 17.2.1.1: Overview
  - RFC 3261 Section 17.2.1.2: Formal Description

  ## Parameters

  - `request`: The SIP INVITE request received by the server

  ## Returns

  - `{:ok, transaction}`: A new transaction struct in `:trying` state

  ## Examples

      iex> via = %ParrotSip.Headers.Via{
      ...>   host: "proxy.example.com",
      ...>   port: 5060,
      ...>   transport: "UDP",
      ...>   parameters: %{"branch" => "z9hG4bK-invite-456"}
      ...> }
      iex> invite = %ParrotSip.Message{
      ...>   type: :request,
      ...>   method: :invite,
      ...>   via: via,
      ...>   cseq: %{number: 2, method: :invite}
      ...> }
      iex> {:ok, transaction} = ParrotSip.Transaction.create_invite_server(invite)
      iex> transaction.state
      :trying
      iex> transaction.type
      :invite_server
      iex> transaction.role
      :uas
      iex> transaction.method
      :invite

  """
  @spec create_invite_server(Message.t()) :: {:ok, t()}
  def create_invite_server(request) do
    # Extract branch parameter from Via header
    branch = get_branch(request)

    # Create transaction ID
    id = generate_transaction_id(:invite_server, branch, request)

    # Create the transaction in initial state
    transaction = %__MODULE__{
      id: id,
      type: :invite_server,
      state: :trying,
      request: request,
      last_response: nil,
      branch: branch,
      method: :invite,
      created_at: System.system_time(:millisecond),
      role: :uas
    }

    {:ok, transaction}
  end

  @doc """
  Creates a new server transaction for a non-INVITE request.

  Non-INVITE server transactions handle all SIP methods except INVITE when
  received by a server. This includes REGISTER, OPTIONS, BYE, CANCEL, etc.
  These transactions have a simpler state machine than INVITE server transactions.

  ## Purpose
  - Handle server-side processing of non-INVITE requests
  - Manage response sending and retransmissions
  - Provide reliability for non-session requests
  - Handle method-specific processing (REGISTER, OPTIONS, etc.)

  ## State Machine
  - Initial state: `:trying`
  - Send provisional response → `:proceeding`
  - Send final response → `:completed`
  - Timer J expires → `:terminated`

  ## RFC References
  - RFC 3261 Section 17.2.2: Non-INVITE Server Transaction
  - RFC 3261 Section 17.2.2.1: Overview
  - RFC 3261 Section 17.2.2.2: Formal Description

  ## Parameters

  - `request`: The SIP request received by the server (REGISTER, OPTIONS, etc.)

  ## Returns

  - `{:ok, transaction}`: A new transaction struct in `:trying` state

  ## Examples

      iex> via = %ParrotSip.Headers.Via{
      ...>   host: "registrar.example.com",
      ...>   port: 5060,
      ...>   transport: "TCP",
      ...>   parameters: %{"branch" => "z9hG4bK-register-789"}
      ...> }
      iex> register = %ParrotSip.Message{
      ...>   type: :request,
      ...>   method: :register,
      ...>   via: via,
      ...>   cseq: %{number: 5, method: :register}
      ...> }
      iex> {:ok, transaction} = ParrotSip.Transaction.create_non_invite_server(register)
      iex> transaction.state
      :trying
      iex> transaction.type
      :non_invite_server
      iex> transaction.role
      :uas
      iex> transaction.method
      :register

  """
  @spec create_non_invite_server(Message.t()) :: {:ok, t()}
  def create_non_invite_server(request) do
    # Extract branch parameter from Via header
    branch = get_branch(request)

    # Create transaction ID
    id = generate_transaction_id(:non_invite_server, branch, request)

    # Create the transaction in trying state (per RFC 3261 17.2.2)
    transaction = %__MODULE__{
      id: id,
      type: :non_invite_server,
      state: :trying,
      request: request,
      last_response: nil,
      branch: branch,
      method: request.method,
      created_at: System.system_time(:millisecond),
      role: :uas
    }

    {:ok, transaction}
  end

  @doc """
  Generates a transaction ID based on the transaction parameters.

  Transaction IDs are used internally to uniquely identify and correlate transactions
  within the transaction layer. The ID format varies based on transaction type to
  ensure proper matching of requests and responses according to RFC 3261.

  ## Purpose
  - Uniquely identify transactions for correlation
  - Enable proper request/response matching
  - Support transaction state management
  - Handle special cases like ACK matching

  ## Transaction ID Format
  - Client transactions: `<branch>:<method>:client`
  - Server transactions: `<branch>:<method>:<cseq_number>`
  - Special case: ACK requests use `:invite` method for matching

  ## RFC References
  - RFC 3261 Section 17.1.3: Matching responses to client transactions
  - RFC 3261 Section 17.2.3: Matching requests to server transactions
  - RFC 3261 Section 17.1.1.3: ACK handling in INVITE client transactions

  ## Parameters

  - `type`: The transaction type (`:invite_client`, `:non_invite_client`, etc.)
  - `branch`: The branch parameter from the Via header
  - `request`: The SIP request containing method and CSeq information

  ## Returns

  - A string representing the unique transaction ID

  ## Examples

      iex> request = %ParrotSip.Message{
      ...>   method: :invite,
      ...>   cseq: %{number: 1, method: :invite}
      ...> }
      iex> ParrotSip.Transaction.generate_transaction_id(:invite_client, "z9hG4bK123", request)
      "z9hG4bK123:invite:client"

      iex> request = %ParrotSip.Message{
      ...>   method: :register,
      ...>   cseq: %{number: 42, method: :register}
      ...> }
      iex> ParrotSip.Transaction.generate_transaction_id(:non_invite_server, "z9hG4bK456", request)
      "z9hG4bK456:register:42"

      iex> ack_request = %ParrotSip.Message{
      ...>   method: :ack,
      ...>   cseq: %{number: 1, method: :ack}
      ...> }
      iex> ParrotSip.Transaction.generate_transaction_id(:invite_server, "z9hG4bK789", ack_request)
      "z9hG4bK789:invite:1"

  """
  @spec generate_transaction_id(transaction_type(), String.t(), Message.t()) :: String.t()
  def generate_transaction_id(type, branch, request) do
    # Transaction ID is determined by branch parameter, method, and direction
    # For client transactions, use "branch:method:client"
    # For server transactions, use "branch:method:cseq"
    # Special case: ACK for non-2xx responses is part of the INVITE transaction (RFC 3261 17.1.1.3)
    case type do
      :invite_client ->
        "#{branch}:invite:client"

      :non_invite_client ->
        "#{branch}:#{request.method}:client"

      :invite_server ->
        # ACK requests should match the INVITE transaction ID
        method = if request.method == :ack, do: :invite, else: request.method
        "#{branch}:#{method}:#{request.cseq.number}"

      :non_invite_server ->
        # ACK requests should match the INVITE transaction ID
        method = if request.method == :ack, do: :invite, else: request.method
        "#{branch}:#{method}:#{request.cseq.number}"
    end
  end

  @doc """
  Checks if a transaction matches the given response.

  Response matching is critical for correlating SIP responses with their
  corresponding client transactions. Per RFC 3261, a response matches a
  client transaction if the branch parameter in the Via header and the
  method in the CSeq header match the transaction.

  ## Purpose
  - Correlate responses with client transactions
  - Ensure responses are processed by correct transaction
  - Implement RFC 3261 transaction matching rules
  - Prevent response misdelivery

  ## Matching Rules
  - Must be a client transaction (UAC role)
  - Via branch parameter must match transaction branch
  - CSeq method must match transaction method
  - Only matches first Via header (top Via)

  ## RFC References
  - RFC 3261 Section 17.1.3: Matching responses to client transactions
  - RFC 3261 Section 8.1.3.3: Via header processing
  - RFC 3261 Section 8.1.1.5: CSeq header

  ## Parameters

  - `transaction`: The client transaction to check matching against
  - `response`: The SIP response to match

  ## Returns

  - `true` if the response matches the transaction, `false` otherwise

  ## Examples

      iex> via = %ParrotSip.Headers.Via{
      ...>   host: "client.example.com",
      ...>   parameters: %{"branch" => "z9hG4bK123"}
      ...> }
      iex> transaction = %ParrotSip.Transaction{
      ...>   role: :uac,
      ...>   branch: "z9hG4bK123",
      ...>   method: :invite
      ...> }
      iex> response = %ParrotSip.Message{
      ...>   via: via,
      ...>   cseq: %{method: :invite}
      ...> }
      iex> ParrotSip.Transaction.matches_response?(transaction, response)
      true

      iex> via = %ParrotSip.Headers.Via{
      ...>   host: "client.example.com",
      ...>   parameters: %{"branch" => "z9hG4bK999"}
      ...> }
      iex> transaction = %ParrotSip.Transaction{
      ...>   role: :uac,
      ...>   branch: "z9hG4bK123",
      ...>   method: :invite
      ...> }
      iex> response = %ParrotSip.Message{
      ...>   via: via,
      ...>   cseq: %{method: :invite}
      ...> }
      iex> ParrotSip.Transaction.matches_response?(transaction, response)
      false

  """
  @spec matches_response?(t(), Message.t()) :: boolean()
  def matches_response?(%{role: :uac, branch: branch, method: method}, %Message{
        via: via,
        cseq: %{method: cseq_method}
      })
      when cseq_method == method do
    case extract_top_via(via) do
      %Headers.Via{parameters: %{"branch" => ^branch}} -> true
      _ -> false
    end
  end

  def matches_response?(_, _), do: false

  @doc """
  Checks if a transaction matches the given request.

  Request matching is used primarily for server transactions to correlate
  incoming requests (especially ACK requests) with existing transactions.
  This is crucial for INVITE server transactions that need to receive
  ACK requests for error responses.

  ## Purpose
  - Correlate ACK requests with INVITE server transactions
  - Match retransmitted requests to existing transactions
  - Implement RFC 3261 server transaction matching rules
  - Handle special ACK processing for error responses

  ## Matching Rules
  - Must be a server transaction (UAS role)
  - Via branch parameter must match transaction branch
  - For INVITE transactions: ACK method matches regardless of original method
  - For other transactions: method must match exactly
  - Only matches first Via header (top Via)

  ## RFC References
  - RFC 3261 Section 17.2.3: Matching requests to server transactions
  - RFC 3261 Section 17.2.1: INVITE Server Transaction (ACK handling)
  - RFC 3261 Section 8.1.3.3: Via header processing

  ## Parameters

  - `transaction`: The server transaction to check matching against
  - `request`: The SIP request to match (often an ACK)

  ## Returns

  - `true` if the request matches the transaction, `false` otherwise

  ## Examples

      iex> via = %ParrotSip.Headers.Via{
      ...>   host: "proxy.example.com",
      ...>   parameters: %{"branch" => "z9hG4bK456"}
      ...> }
      iex> invite_transaction = %ParrotSip.Transaction{
      ...>   role: :uas,
      ...>   branch: "z9hG4bK456",
      ...>   method: :invite
      ...> }
      iex> ack_request = %ParrotSip.Message{
      ...>   method: :ack,
      ...>   via: via
      ...> }
      iex> ParrotSip.Transaction.matches_request?(invite_transaction, ack_request)
      true

      iex> via = %ParrotSip.Headers.Via{
      ...>   host: "proxy.example.com",
      ...>   parameters: %{"branch" => "z9hG4bK789"}
      ...> }
      iex> register_transaction = %ParrotSip.Transaction{
      ...>   role: :uas,
      ...>   branch: "z9hG4bK789",
      ...>   method: :register
      ...> }
      iex> register_request = %ParrotSip.Message{
      ...>   method: :register,
      ...>   via: via
      ...> }
      iex> ParrotSip.Transaction.matches_request?(register_transaction, register_request)
      true

  """
  @spec matches_request?(t(), Message.t()) :: boolean()
  def matches_request?(%{role: :uas, branch: branch, method: :invite}, %Message{
        method: :ack,
        via: via
      }) do
    case extract_top_via(via) do
      %Headers.Via{parameters: %{"branch" => ^branch}} -> true
      _ -> false
    end
  end

  def matches_request?(%{role: :uas, branch: branch, method: method}, %Message{
        method: req_method,
        via: via
      })
      when method == req_method do
    case extract_top_via(via) do
      %Headers.Via{parameters: %{"branch" => ^branch}} -> true
      _ -> false
    end
  end

  def matches_request?(_, _), do: false

  @doc """
  Extracts the branch parameter from a SIP message's Via header.

  The branch parameter is mandatory for transaction identification and must
  be present in the topmost Via header. This function safely extracts the
  branch parameter while handling various Via header formats (single header
  or header list).

  ## Purpose
  - Extract branch parameter for transaction identification
  - Handle different Via header representations
  - Provide safe access with error handling
  - Support transaction correlation logic

  ## Via Header Format
  The Via header contains routing information and the branch parameter:
  `Via: SIP/2.0/UDP host:port;branch=z9hG4bK<unique-id>`

  ## RFC References
  - RFC 3261 Section 8.1.1.7: Via header branch parameter
  - RFC 3261 Section 20.42: Via header field
  - RFC 3261 Section 17.1.3: Transaction matching

  ## Parameters

  - `message`: The SIP message containing Via header(s)

  ## Returns

  - `{:ok, branch}` if branch parameter found in top Via header
  - `{:error, :no_via}` if no Via header present
  - `{:error, :no_branch}` if Via header exists but lacks branch parameter

  ## Examples

      iex> via = %ParrotSip.Headers.Via{
      ...>   host: "example.com",
      ...>   parameters: %{"branch" => "z9hG4bK776asdhds"}
      ...> }
      iex> message = %ParrotSip.Message{via: via}
      iex> ParrotSip.Transaction.extract_branch(message)
      {:ok, "z9hG4bK776asdhds"}

      iex> via_list = [
      ...>   %ParrotSip.Headers.Via{
      ...>     host: "proxy.example.com",
      ...>     parameters: %{"branch" => "z9hG4bK123"}
      ...>   },
      ...>   %ParrotSip.Headers.Via{
      ...>     host: "client.example.com",
      ...>     parameters: %{"branch" => "z9hG4bK456"}
      ...>   }
      ...> ]
      iex> message = %ParrotSip.Message{via: via_list}
      iex> ParrotSip.Transaction.extract_branch(message)
      {:ok, "z9hG4bK123"}

      iex> message = %ParrotSip.Message{via: nil}
      iex> ParrotSip.Transaction.extract_branch(message)
      {:error, :no_via}

      iex> via = %ParrotSip.Headers.Via{
      ...>   host: "example.com",
      ...>   parameters: %{}
      ...> }
      iex> message = %ParrotSip.Message{via: via}
      iex> ParrotSip.Transaction.extract_branch(message)
      {:error, :no_branch}

  """
  @spec extract_branch(Message.t()) :: {:ok, String.t()} | {:error, atom()}
  def extract_branch(%Message{via: nil}), do: {:error, :no_via}
  def extract_branch(%Message{via: []}), do: {:error, :no_via}

  def extract_branch(%Message{via: [%Headers.Via{parameters: %{"branch" => branch}} | _]}),
    do: {:ok, branch}

  def extract_branch(%Message{via: [%Headers.Via{} | _]}), do: {:error, :no_branch}

  @doc """
  Classifies a SIP response by status code.

  Response classification is fundamental to SIP transaction processing as
  different response classes trigger different state transitions and behaviors.
  This classification follows the standard HTTP/SIP response code ranges.

  ## Purpose
  - Categorize responses for transaction state machine processing
  - Determine appropriate transaction actions
  - Implement RFC 3261 response handling rules
  - Support conditional state transitions

  ## Response Classes
  - **Provisional (1xx)**: Informational responses indicating progress
  - **Success (2xx)**: Request succeeded and was accepted
  - **Failure (3xx-6xx)**: Request failed for various reasons

  ## RFC References
  - RFC 3261 Section 21: Response Codes
  - RFC 3261 Section 17.1: Client Transaction (response handling)
  - RFC 3261 Section 17.2: Server Transaction (response generation)

  ## Parameters

  - `status_code`: The SIP response status code (100-699)

  ## Returns

  - `:provisional` for 1xx responses (100-199)
  - `:success` for 2xx responses (200-299)
  - `:failure` for 3xx-6xx responses (300-699)

  ## Examples

      iex> ParrotSip.Transaction.classify_response(100)
      :provisional

      iex> ParrotSip.Transaction.classify_response(180)
      :provisional

      iex> ParrotSip.Transaction.classify_response(200)
      :success

      iex> ParrotSip.Transaction.classify_response(404)
      :failure

      iex> ParrotSip.Transaction.classify_response(500)
      :failure

  """
  @spec classify_response(integer()) :: :provisional | :success | :failure
  def classify_response(code) when code >= 100 and code < 200, do: :provisional
  def classify_response(code) when code >= 200 and code < 300, do: :success
  def classify_response(code) when code >= 300 and code <= 699, do: :failure

  @doc """
  Pure state transition function - returns next state and actions without side effects.

  This is the core state machine implementation for SIP transactions. It takes
  the current transaction state and an event, then returns the new state and
  any actions that should be performed. This is a pure function with no side
  effects, making it easily testable and predictable.

  ## Purpose
  - Implement RFC 3261 transaction state machines
  - Handle state transitions for all transaction types
  - Determine timer actions for each state change
  - Provide pure functional transaction logic

  ## Event Types
  - `{:send_provisional, status}` - Sending 1xx response
  - `{:send_final, status}` - Sending 2xx-6xx response
  - `{:receive_response, status}` - Receiving response (client)
  - `{:receive_ack}` - Receiving ACK request
  - `{:timer, timer_name}` - Timer expiration

  ## Actions
  - `:start_timer_x` - Start a specific timer
  - `:cancel_timer_x` - Cancel a specific timer
  - `:terminate` - Terminate the transaction

  ## RFC References
  - RFC 3261 Section 17.1.1.2: INVITE Client Transaction state machine
  - RFC 3261 Section 17.1.2.2: Non-INVITE Client Transaction state machine
  - RFC 3261 Section 17.2.1.2: INVITE Server Transaction state machine
  - RFC 3261 Section 17.2.2.2: Non-INVITE Server Transaction state machine

  ## Parameters

  - `transaction`: Current transaction struct with type and state
  - `event`: Event tuple triggering the state transition

  ## Returns

  - `{:ok, new_state, actions}` for valid transitions
  - `{:error, :invalid_transition}` for invalid state transitions

  ## Examples

      iex> transaction = %ParrotSip.Transaction{
      ...>   type: :invite_server,
      ...>   state: :trying
      ...> }
      iex> ParrotSip.Transaction.next_state(transaction, {:send_provisional, 180})
      {:ok, :proceeding, []}

      iex> transaction = %ParrotSip.Transaction{
      ...>   type: :invite_client,
      ...>   state: :calling
      ...> }
      iex> ParrotSip.Transaction.next_state(transaction, {:receive_response, 200})
      {:ok, :terminated, [:cancel_timer_a, :cancel_timer_b]}

      iex> transaction = %ParrotSip.Transaction{
      ...>   type: :non_invite_server,
      ...>   state: :completed
      ...> }
      iex> ParrotSip.Transaction.next_state(transaction, {:timer, :j})
      {:ok, :terminated, [:terminate]}

  """
  @spec next_state(t(), term()) :: {:ok, transaction_state(), [atom()]} | {:error, atom()}
  def next_state(%{type: :invite_server, state: :trying}, {:send_provisional, _status}) do
    {:ok, :proceeding, []}
  end

  def next_state(%{type: :invite_server, state: :trying}, {:send_final, status})
      when status >= 300 and status <= 699 do
    {:ok, :completed, [:start_timer_g, :start_timer_h]}
  end

  def next_state(%{type: :invite_server, state: :trying}, {:send_final, status})
      when status >= 200 and status < 300 do
    {:ok, :terminated, []}
  end

  def next_state(%{type: :invite_server, state: :proceeding}, {:send_provisional, _status}) do
    {:ok, :proceeding, []}
  end

  def next_state(%{type: :invite_server, state: :proceeding}, {:send_final, status})
      when status >= 300 and status <= 699 do
    {:ok, :completed, [:cancel_timer_c, :start_timer_g, :start_timer_h]}
  end

  def next_state(%{type: :invite_server, state: :proceeding}, {:send_final, status})
      when status >= 200 and status < 300 do
    {:ok, :terminated, [:cancel_timer_c]}
  end

  def next_state(%{type: :invite_server, state: :completed}, {:receive_ack}) do
    {:ok, :confirmed, [:cancel_timer_g, :cancel_timer_h, :start_timer_i]}
  end

  def next_state(%{type: :invite_server, state: :completed}, {:timer, :h}) do
    {:ok, :terminated, [:terminate]}
  end

  def next_state(%{type: :invite_server, state: :confirmed}, {:timer, :i}) do
    {:ok, :terminated, [:terminate]}
  end

  def next_state(%{type: :non_invite_server, state: :trying}, {:send_provisional, _status}) do
    {:ok, :proceeding, []}
  end

  def next_state(%{type: :non_invite_server, state: :trying}, {:send_final, _status}) do
    {:ok, :completed, [:start_timer_j]}
  end

  def next_state(%{type: :non_invite_server, state: :proceeding}, {:send_provisional, _status}) do
    {:ok, :proceeding, []}
  end

  def next_state(%{type: :non_invite_server, state: :proceeding}, {:send_final, _status}) do
    {:ok, :completed, [:start_timer_j]}
  end

  def next_state(%{type: :non_invite_server, state: :completed}, {:timer, :j}) do
    {:ok, :terminated, [:terminate]}
  end

  def next_state(%{type: :invite_client, state: :calling}, {:receive_response, status})
      when status >= 100 and status < 200 do
    {:ok, :proceeding, [:cancel_timer_a, :cancel_timer_b]}
  end

  def next_state(%{type: :invite_client, state: :calling}, {:receive_response, status})
      when status >= 200 and status < 300 do
    {:ok, :terminated, [:cancel_timer_a, :cancel_timer_b]}
  end

  def next_state(%{type: :invite_client, state: :calling}, {:receive_response, status})
      when status >= 300 and status <= 699 do
    {:ok, :completed, [:cancel_timer_a, :cancel_timer_b, :start_timer_d]}
  end

  def next_state(%{type: :invite_client, state: :proceeding}, {:receive_response, status})
      when status >= 200 and status < 300 do
    {:ok, :terminated, []}
  end

  def next_state(%{type: :invite_client, state: :proceeding}, {:receive_response, status})
      when status >= 300 and status <= 699 do
    {:ok, :completed, [:start_timer_d]}
  end

  def next_state(%{type: :invite_client, state: :calling}, {:timer, :b}) do
    # Timer B fires in calling state - timeout for INVITE client transaction
    {:ok, :terminated, [:terminate_transaction]}
  end

  def next_state(%{type: :invite_client, state: :proceeding}, {:timer, :b}) do
    # Timer B can also fire in proceeding state - timeout for INVITE client transaction
    {:ok, :terminated, [:terminate_transaction]}
  end

  def next_state(%{type: :invite_client, state: :completed}, {:timer, :d}) do
    {:ok, :terminated, [:terminate]}
  end

  def next_state(%{type: :non_invite_client, state: :trying}, {:timer, :f}) do
    # Timer F fires in trying state - timeout for non-INVITE client transaction
    {:ok, :terminated, [:terminate_transaction]}
  end

  def next_state(%{type: :non_invite_client, state: :proceeding}, {:timer, :f}) do
    # Timer F can also fire in proceeding state - timeout for non-INVITE client transaction
    {:ok, :terminated, [:terminate_transaction]}
  end

  def next_state(%{type: :non_invite_client, state: :trying}, {:receive_response, status})
      when status >= 100 and status < 200 do
    {:ok, :proceeding, [:cancel_timer_e, :cancel_timer_f]}
  end

  def next_state(%{type: :non_invite_client, state: :trying}, {:receive_response, status})
      when status >= 200 and status <= 699 do
    {:ok, :completed, [:cancel_timer_e, :cancel_timer_f, :start_timer_k]}
  end

  def next_state(%{type: :non_invite_client, state: :proceeding}, {:receive_response, status})
      when status >= 200 and status <= 699 do
    {:ok, :completed, [:start_timer_k]}
  end

  def next_state(%{type: :non_invite_client, state: :completed}, {:timer, :k}) do
    {:ok, :terminated, [:terminate]}
  end

  def next_state(_transaction, _event), do: {:error, :invalid_transition}

  @doc """
  Returns retransmission action based on transaction's last_response.

  When a server transaction receives a retransmitted request, it should
  retransmit the last response that was sent. This function determines
  the appropriate action based on whether a response has been sent.

  ## Purpose
  - Handle request retransmissions properly
  - Implement RFC 3261 retransmission rules
  - Maintain transaction reliability
  - Avoid response loss during network issues

  ## Retransmission Rules
  - If a response was previously sent, retransmit it
  - If no response sent yet, ignore the retransmission
  - This applies to both INVITE and non-INVITE server transactions

  ## RFC References
  - RFC 3261 Section 17.2.1: INVITE Server Transaction
  - RFC 3261 Section 17.2.2: Non-INVITE Server Transaction
  - RFC 3261 Section 8.1.3.1: Server behavior for retransmissions

  ## Parameters

  - `transaction`: The server transaction to check for retransmission

  ## Returns

  - `{:retransmit_response, response}` if last_response exists and should be retransmitted
  - `:ignore` if no last_response exists (no response sent yet)

  ## Examples

      iex> response = %ParrotSip.Message{
      ...>   type: :response,
      ...>   status_code: 200
      ...> }
      iex> transaction = %ParrotSip.Transaction{
      ...>   last_response: response
      ...> }
      iex> ParrotSip.Transaction.retransmission_action(transaction)
      {:retransmit_response, %ParrotSip.Message{type: :response, status_code: 200}}

      iex> transaction = %ParrotSip.Transaction{
      ...>   last_response: nil
      ...> }
      iex> ParrotSip.Transaction.retransmission_action(transaction)
      :ignore

  """
  @spec retransmission_action(t()) :: {:retransmit_response, Message.t()} | :ignore
  def retransmission_action(%{last_response: nil}), do: :ignore
  def retransmission_action(%{last_response: response}), do: {:retransmit_response, response}

  @doc """
  Updates the last_response in a transaction.

  When a server transaction sends a response, it should store that response
  for potential retransmission. This function updates the transaction with
  the most recent response that was sent.

  ## Purpose
  - Store response for retransmission handling
  - Maintain transaction state consistency
  - Support reliable message delivery
  - Enable proper duplicate request handling

  ## Usage
  - Called when server transaction sends any response
  - Response stored for retransmission on duplicate requests
  - Essential for both INVITE and non-INVITE transactions

  ## RFC References
  - RFC 3261 Section 17.2.1: INVITE Server Transaction
  - RFC 3261 Section 17.2.2: Non-INVITE Server Transaction
  - RFC 3261 Section 8.1.3.1: Server behavior

  ## Parameters

  - `transaction`: The transaction to update
  - `response`: The SIP response that was sent

  ## Returns

  - Updated transaction struct with last_response set

  ## Examples

      iex> transaction = %ParrotSip.Transaction{
      ...>   id: "test",
      ...>   last_response: nil
      ...> }
      iex> response = %ParrotSip.Message{
      ...>   type: :response,
      ...>   status_code: 200
      ...> }
      iex> updated = ParrotSip.Transaction.update_last_response(transaction, response)
      iex> updated.last_response.status_code
      200

  """
  @spec update_last_response(t(), Message.t()) :: t()
  def update_last_response(transaction, response) do
    %{transaction | last_response: response}
  end

  @doc """
  Updates the state in a transaction.

  Transaction state changes are fundamental to SIP transaction processing.
  This function provides a clean way to update a transaction's state while
  maintaining immutability of the transaction struct.

  ## Purpose
  - Update transaction state after events
  - Maintain transaction state machine integrity
  - Support functional programming patterns
  - Enable transaction state tracking

  ## Valid States
  - `:calling` - INVITE client initial state
  - `:trying` - Server initial state, non-INVITE client initial state
  - `:proceeding` - Provisional response received/sent
  - `:completed` - Final response received/sent
  - `:confirmed` - ACK received (INVITE server only)
  - `:terminated` - Transaction finished

  ## RFC References
  - RFC 3261 Section 17.1: Client Transaction states
  - RFC 3261 Section 17.2: Server Transaction states
  - RFC 3261 Section 17: Transaction layer overview

  ## Parameters

  - `transaction`: The transaction to update
  - `state`: The new transaction state

  ## Returns

  - Updated transaction struct with new state

  ## Examples

      iex> transaction = %ParrotSip.Transaction{
      ...>   id: "test",
      ...>   state: :trying
      ...> }
      iex> updated = ParrotSip.Transaction.update_state(transaction, :proceeding)
      iex> updated.state
      :proceeding

      iex> transaction = %ParrotSip.Transaction{
      ...>   id: "test",
      ...>   state: :completed
      ...> }
      iex> updated = ParrotSip.Transaction.update_state(transaction, :terminated)
      iex> updated.state
      :terminated

  """
  @spec update_state(t(), transaction_state()) :: t()
  def update_state(transaction, state) do
    %{transaction | state: state}
  end

  @doc """
  Checks if a transaction is a client transaction.

  Client transactions are created when a UAC (User Agent Client) sends
  a request. This includes both INVITE and non-INVITE client transactions.
  Client transactions handle responses and manage retransmissions of requests.

  ## Purpose
  - Identify client-side transactions
  - Support role-based transaction processing
  - Enable proper message routing
  - Facilitate transaction categorization

  ## Client Transaction Types
  - `:invite_client` - INVITE requests from UAC
  - `:non_invite_client` - Non-INVITE requests from UAC

  ## RFC References
  - RFC 3261 Section 17.1: Client Transaction
  - RFC 3261 Section 17.1.1: INVITE Client Transaction
  - RFC 3261 Section 17.1.2: Non-INVITE Client Transaction

  ## Parameters

  - `transaction`: The transaction to check

  ## Returns

  - `true` if the transaction is a client transaction, `false` otherwise

  ## Examples

      iex> client_tx = %ParrotSip.Transaction{
      ...>   type: :invite_client
      ...> }
      iex> ParrotSip.Transaction.is_client_transaction?(client_tx)
      true

      iex> client_tx = %ParrotSip.Transaction{
      ...>   type: :non_invite_client
      ...> }
      iex> ParrotSip.Transaction.is_client_transaction?(client_tx)
      true

      iex> server_tx = %ParrotSip.Transaction{
      ...>   type: :invite_server
      ...> }
      iex> ParrotSip.Transaction.is_client_transaction?(server_tx)
      false

  """
  @spec is_client_transaction?(t()) :: boolean()
  def is_client_transaction?(transaction) do
    transaction.type in [:invite_client, :non_invite_client]
  end

  @doc """
  Checks if a transaction is a server transaction.

  Server transactions are created when a UAS (User Agent Server) receives
  a request. This includes both INVITE and non-INVITE server transactions.
  Server transactions handle request processing and manage response generation.

  ## Purpose
  - Identify server-side transactions
  - Support role-based transaction processing
  - Enable proper request handling
  - Facilitate transaction categorization

  ## Server Transaction Types
  - `:invite_server` - INVITE requests received by UAS
  - `:non_invite_server` - Non-INVITE requests received by UAS

  ## RFC References
  - RFC 3261 Section 17.2: Server Transaction
  - RFC 3261 Section 17.2.1: INVITE Server Transaction
  - RFC 3261 Section 17.2.2: Non-INVITE Server Transaction

  ## Parameters

  - `transaction`: The transaction to check

  ## Returns

  - `true` if the transaction is a server transaction, `false` otherwise

  ## Examples

      iex> server_tx = %ParrotSip.Transaction{
      ...>   type: :invite_server
      ...> }
      iex> ParrotSip.Transaction.is_server_transaction?(server_tx)
      true

      iex> server_tx = %ParrotSip.Transaction{
      ...>   type: :non_invite_server
      ...> }
      iex> ParrotSip.Transaction.is_server_transaction?(server_tx)
      true

      iex> client_tx = %ParrotSip.Transaction{
      ...>   type: :invite_client
      ...> }
      iex> ParrotSip.Transaction.is_server_transaction?(client_tx)
      false

  """
  @spec is_server_transaction?(t()) :: boolean()
  def is_server_transaction?(transaction) do
    transaction.type in [:invite_server, :non_invite_server]
  end

  @doc """
  Checks if a transaction is terminated.

  The terminated state is the final state for all SIP transactions.
  Once a transaction reaches this state, it should be cleaned up and
  removed from the transaction layer. This function helps identify
  transactions that are ready for cleanup.

  ## Purpose
  - Identify completed transactions for cleanup
  - Support transaction lifecycle management
  - Enable resource cleanup and garbage collection
  - Determine transaction processing completion

  ## Termination Triggers
  - Timer expiration (various timers per transaction type)
  - Final response sent/received (for some transaction types)
  - ACK received (for INVITE server transactions)
  - Error conditions

  ## RFC References
  - RFC 3261 Section 17.1: Client Transaction termination
  - RFC 3261 Section 17.2: Server Transaction termination
  - RFC 3261 Section 17: Transaction layer lifecycle

  ## Parameters

  - `transaction`: The transaction to check

  ## Returns

  - `true` if the transaction is in `:terminated` state, `false` otherwise

  ## Examples

      iex> terminated_tx = %ParrotSip.Transaction{
      ...>   state: :terminated
      ...> }
      iex> ParrotSip.Transaction.is_terminated?(terminated_tx)
      true

      iex> active_tx = %ParrotSip.Transaction{
      ...>   state: :proceeding
      ...> }
      iex> ParrotSip.Transaction.is_terminated?(active_tx)
      false

      iex> completed_tx = %ParrotSip.Transaction{
      ...>   state: :completed
      ...> }
      iex> ParrotSip.Transaction.is_terminated?(completed_tx)
      false

  """
  @spec is_terminated?(t()) :: boolean()
  def is_terminated?(transaction) do
    transaction.state == :terminated
  end

  defp get_branch(request) do
    via = extract_top_via_strict(request.via)
    via.parameters["branch"]
  end

  defp extract_top_via(%Headers.Via{} = via), do: via
  defp extract_top_via([via | _]) when is_struct(via, Headers.Via), do: via
  defp extract_top_via(_), do: nil

  defp extract_top_via_strict(%Headers.Via{} = via), do: via
  defp extract_top_via_strict([via | _]) when is_struct(via, Headers.Via), do: via
  defp extract_top_via_strict(_), do: raise(ArgumentError, "Request must have a Via header")
end
