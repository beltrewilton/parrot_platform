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
  """
  def send_request(uac, request) do
    GenServer.call(uac, {:send_request, request})
  end
  
  @doc """
  Sends a SIP response.
  """
  def send_response(uas, response) do
    GenServer.call(uas, {:send_response, response})
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
  Gets the current state of a transaction.
  """
  def get_transaction_state(transaction_id) do
    ParrotSip.Transaction.get_state(transaction_id)
  end
end