defmodule ParrotExampleUac.SipHandler do
  @moduledoc """
  SIP Handler for the UAC transport layer.
  
  This module handles SIP protocol events at the transport level.
  It's required by the Parrot transport layer but kept minimal for UAC
  since the actual response processing is done via UAC callbacks.
  
  ## Callbacks
  
  - `transp_request/2` - Handles incoming SIP requests (ignored for UAC)
  - `transp_response/2` - Handles incoming SIP responses (consumed but not processed)
  - `transp_error/3` - Handles transport errors
  - Other callbacks are required by the transport but unused in UAC mode
  """
  
  require Logger
  
  @doc """
  Handles incoming SIP requests.
  UAC typically doesn't receive requests, so we ignore them.
  """
  def transp_request(_msg, _owner_pid) do
    :ignore
  end
  
  @doc """
  Handles incoming SIP responses.
  We consume the message to prevent further processing, but don't handle it
  here since the UAC callback mechanism handles the actual response.
  """
  def transp_response(_msg, _owner_pid) do
    # The UAC.request callback handles the actual response processing
    :consume
  end
  
  @doc """
  Handles transport errors.
  """
  def transp_error(error, reason, _owner_pid) do
    Logger.error("Transport error: #{inspect(error)}, reason: #{inspect(reason)}")
    :ok
  end
  
  # Required callbacks that aren't used in UAC mode
  def process_ack(_msg, _state), do: :ignore
  def transaction(_event, _id, _state), do: :ignore
  def transaction_stop(_event, _id, _state), do: :ignore
  def uas_cancel(_msg, _state), do: :ignore
  def uas_request(_msg, _dialog_id, _state), do: :ignore
end