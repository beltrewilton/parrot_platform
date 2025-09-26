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
  Facade function for generating a transaction branch parameter.

  This function initially delegates to ERSIP but will gradually be replaced
  with our pure Elixir implementation.

  RFC 3261 Section 8.1.1.7
  """
  @spec generate_branch(Message.t()) :: String.t()
  def generate_branch(_message) do
    ParrotSip.Branch.generate()
  end

  @doc """
  Facade function for generating a transaction ID based on the message type.

  RFC 3261 Section 17
  """
  @spec generate_id(Message.t()) :: String.t()
  def generate_id(message) do
    # TODO: Replace with pure Elixir implementation
    # This will combine method, branch, and other relevant parameters
    branch = get_branch(message)
    generate_transaction_id(determine_transaction_type(message), branch, message)
  end

  # Temporary helper function until Message.method is implemented
  defp get_method(%{method: method}) when is_atom(method), do: method
  defp get_method(_), do: :unknown

  @doc """
  Determines the transaction type based on a message.

  RFC 3261 Section 17
  """
  @spec determine_transaction_type(Message.t()) :: transaction_type()
  def determine_transaction_type(message) do
    sip_method = get_method(message)
    is_request = is_request?(message)

    cond do
      is_request && sip_method == :invite -> :invite_server
      is_request && sip_method != :invite -> :non_invite_server
      !is_request && get_cseq_method(message) == :invite -> :invite_client
      true -> :non_invite_client
    end
  end

  # Temporary helper function until Message.is_request? is implemented
  defp is_request?(%ParrotSip.Message{type: :request} = _msg) do
    true
  end

  defp is_request?(_msg) do
    false
  end

  # Temporary helper function until Message.cseq is implemented
  defp get_cseq_method(%{cseq: %{method: method}}), do: method
  defp get_cseq_method(_), do: :unknown

  # This function is already defined as a private function below
  # Removing the duplicate implementation

  @doc """
  Facade function for validating a SIP message for transaction processing.

  This function performs validation on the message according to RFC 3261
  requirements for transaction handling.

  RFC 3261 Section 17
  """
  @spec validate_message(Message.t()) :: {:ok, Message.t()} | {:error, String.t()}
  def validate_message(message) do
    # TODO: Implement thorough message validation
    # For now, basic validation checking required headers
    cond do
      !has_header?(message, "via") ->
        {:error, "Missing Via header"}

      !has_header?(message, "cseq") ->
        {:error, "Missing CSeq header"}

      !has_header?(message, "call-id") ->
        {:error, "Missing Call-ID header"}

      true ->
        {:ok, message}
    end
  end

  # Helper function to check if a message has a header
  defp has_header?(message, header_name) do
    downcased = String.downcase(header_name)

    case downcased do
      "via" -> not is_nil(message.via)
      "from" -> not is_nil(message.from)
      "to" -> not is_nil(message.to)
      "call-id" -> not is_nil(message.call_id)
      "cseq" -> not is_nil(message.cseq)
      "contact" -> not is_nil(message.contact)
      "max-forwards" -> not is_nil(message.max_forwards)
      "content-length" -> not is_nil(message.content_length)
      "content-type" -> not is_nil(message.content_type)
      _ -> Map.has_key?(message.other_headers || %{}, downcased)
    end
  end

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

  Per RFC 3261 Section 17.1.1, INVITE client transactions start in the calling state.

  ## Parameters

  - `request`: The SIP INVITE request that initiates the transaction

  ## Returns

  - `{:ok, transaction}`: A new transaction struct in calling state
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

  Per RFC 3261 Section 17.1.2, non-INVITE client transactions start in the trying state.

  ## Parameters

  - `request`: The SIP request that initiates the transaction

  ## Returns

  - `{:ok, transaction}`: A new transaction struct in trying state
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

  ## Parameters

  - `request`: The SIP INVITE request received

  ## Returns

  - `{:ok, transaction}`: A new transaction struct
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

  ## Parameters

  - `request`: The SIP request received

  ## Returns

  - `{:ok, transaction}`: A new transaction struct
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

  ## Parameters

  - `type`: The transaction type
  - `branch`: The branch parameter from the Via header
  - `request`: The SIP request

  ## Returns

  - A string representing the transaction ID
  """
  @spec generate_transaction_id(transaction_type(), String.t(), Message.t()) :: String.t()
  def generate_transaction_id(type, branch, request) do
    # Transaction ID is determined by branch parameter, method, and direction
    # For client transactions, use "branch:method:client"
    # For server transactions, use "branch:method:cseq"
    case type do
      :invite_client -> "#{branch}:invite:client"
      :non_invite_client -> "#{branch}:#{request.method}:client"
      :invite_server -> "#{branch}:#{request.method}:#{request.cseq.number}"
      :non_invite_server -> "#{branch}:#{request.method}:#{request.cseq.number}"
    end
  end


  @doc """
  Checks if a transaction matches the given response.

  ## Parameters

  - `transaction`: The transaction to check
  - `response`: The response to match against

  ## Returns

  - `true` if the transaction matches the response, `false` otherwise
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

  ## Parameters

  - `transaction`: The transaction to check
  - `request`: The request to match against

  ## Returns

  - `true` if the transaction matches the request, `false` otherwise
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

  ## Parameters

  - `message`: The SIP message

  ## Returns

  - `{:ok, branch}` if branch found
  - `{:error, :no_via}` if no Via header
  - `{:error, :no_branch}` if Via exists but no branch parameter
  """
  @spec extract_branch(Message.t()) :: {:ok, String.t()} | {:error, atom()}
  def extract_branch(%Message{via: nil}), do: {:error, :no_via}

  def extract_branch(%Message{via: %Headers.Via{parameters: %{"branch" => branch}}}),
    do: {:ok, branch}

  def extract_branch(%Message{via: [%Headers.Via{parameters: %{"branch" => branch}} | _]}),
    do: {:ok, branch}

  def extract_branch(%Message{via: %Headers.Via{}}), do: {:error, :no_branch}
  def extract_branch(%Message{via: [%Headers.Via{} | _]}), do: {:error, :no_branch}
  def extract_branch(_), do: {:error, :no_via}

  @doc """
  Classifies a SIP response by status code.

  ## Parameters

  - `status_code`: The SIP response status code

  ## Returns

  - `:provisional` for 1xx responses
  - `:success` for 2xx responses
  - `:failure` for 3xx-6xx responses
  """
  @spec classify_response(integer()) :: :provisional | :success | :failure
  def classify_response(code) when code >= 100 and code < 200, do: :provisional
  def classify_response(code) when code >= 200 and code < 300, do: :success
  def classify_response(code) when code >= 300 and code <= 699, do: :failure

  @doc """
  Pure state transition function - returns next state and actions without side effects.

  ## Parameters

  - `transaction`: Current transaction struct
  - `event`: Event tuple like `{:send_provisional, status}`, `{:receive_response, status}`, `{:timer, :g}`, etc.

  ## Returns

  - `{:ok, new_state, actions}` where actions is a list of atoms like `:start_timer_g`, `:cancel_timer_h`
  - `{:error, :invalid_transition}` for invalid state transitions
  """
  @spec next_state(t(), term()) :: {:ok, transaction_state(), [atom()]} | {:error, atom()}
  def next_state(%{type: :invite_server, state: :trying}, {:send_provisional, _status}) do
    {:ok, :proceeding, [:start_timer_g]}
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

  def next_state(%{type: :invite_client, state: :completed}, {:timer, :d}) do
    {:ok, :terminated, [:terminate]}
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

  ## Parameters

  - `transaction`: The transaction to check

  ## Returns

  - `{:retransmit_response, response}` if last_response exists
  - `:ignore` if no last_response
  """
  @spec retransmission_action(t()) :: {:retransmit_response, Message.t()} | :ignore
  def retransmission_action(%{last_response: nil}), do: :ignore
  def retransmission_action(%{last_response: response}), do: {:retransmit_response, response}

  @doc """
  Updates the last_response in a transaction.

  ## Parameters

  - `transaction`: The transaction to update
  - `response`: The response to store

  ## Returns

  - Updated transaction struct
  """
  @spec update_last_response(t(), Message.t()) :: t()
  def update_last_response(transaction, response) do
    %{transaction | last_response: response}
  end

  @doc """
  Updates the state in a transaction.

  ## Parameters

  - `transaction`: The transaction to update
  - `state`: The new state

  ## Returns

  - Updated transaction struct
  """
  @spec update_state(t(), transaction_state()) :: t()
  def update_state(transaction, state) do
    %{transaction | state: state}
  end

  @doc """
  Checks if a transaction is a client transaction.

  ## Parameters

  - `transaction`: The transaction to check

  ## Returns

  - `true` if the transaction is a client transaction, `false` otherwise
  """
  @spec is_client_transaction?(t()) :: boolean()
  def is_client_transaction?(transaction) do
    transaction.type in [:invite_client, :non_invite_client]
  end

  @doc """
  Checks if a transaction is a server transaction.

  ## Parameters

  - `transaction`: The transaction to check

  ## Returns

  - `true` if the transaction is a server transaction, `false` otherwise
  """
  @spec is_server_transaction?(t()) :: boolean()
  def is_server_transaction?(transaction) do
    transaction.type in [:invite_server, :non_invite_server]
  end

  @doc """
  Checks if a transaction is terminated.

  ## Parameters

  - `transaction`: The transaction to check

  ## Returns

  - `true` if the transaction is terminated, `false` otherwise
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
