defmodule ParrotSip do
  @moduledoc """
  SIP protocol implementation.

  This module provides the main API for SIP operations including:
  - UAC (User Agent Client) operations
  - UAS (User Agent Server) operations  
  - Transaction management
  - Dialog management
  - Message parsing and serialization
  """

  @doc """
  Sends a SIP request.

  ## Options
  - `timeout` - GenServer call timeout in milliseconds (default: 5000)
  """
  def send_request(uac, request, timeout \\ 5000) do
    GenServer.call(uac, {:send_request, request}, timeout)
  end

  @doc """
  Sends a SIP response.

  ## Options
  - `timeout` - GenServer call timeout in milliseconds (default: 5000)
  """
  def send_response(uas, response, timeout \\ 5000) do
    GenServer.call(uas, {:send_response, response}, timeout)
  end

  @doc """
  Parses a SIP message from a binary string.
  """
  def parse_message(binary) when is_binary(binary) do
    ParrotSip.Parser.parse(binary)
  end

  @doc """
  Serializes a SIP message to a binary string.
  """
  def serialize_message(message) do
    ParrotSip.Serializer.encode(message)
  end

  @doc """
  Creates a new dialog from an INVITE.
  """
  def create_dialog(invite_message, role) do
    ParrotSip.Dialog.create_from_invite(invite_message, role)
  end

  @doc """
  Gets the current state of a transaction by its ID.
  
  This function looks up the transaction process in the registry and retrieves
  its current state from the gen_statem state machine.
  
  ## Parameters
  - `transaction_id` - The unique transaction identifier
  
  ## Returns
  - `{:ok, state_name}` - The current state (e.g., :calling, :proceeding, :completed)
  - `{:error, :not_found}` - Transaction doesn't exist or has terminated
  
  ## Examples
  
      iex> # Transaction doesn't exist
      iex> ParrotSip.get_transaction_state("z9hG4bK776:invite:client")
      {:error, :not_found}
  
  """
  def get_transaction_state(transaction_id) do
    # Look up the transaction process via Registry
    case Registry.lookup(ParrotSip.Registry, {:transaction, transaction_id}) do
      [{pid, _}] when is_pid(pid) ->
        # Get the current state from gen_statem
        try do
          # gen_statem stores state in format {state_name, data}
          {state_name, _data} = :sys.get_state(pid)
          {:ok, state_name}
        catch
          :exit, _ -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end
end
