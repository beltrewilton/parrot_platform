defmodule ParrotSip.UA.Client do
  @moduledoc """
  Client API for making outbound SIP requests.

  This module provides a simple API for making outbound SIP requests
  (INVITE, REGISTER, BYE) from a UA process.

  ## Usage

      # Make a call
      ParrotSip.UA.Client.invite(ua, "sip:bob@example.com")

      # Make a call with custom headers
      ParrotSip.UA.Client.invite(ua, "sip:bob@example.com", headers: %{"X-Custom" => "value"})

      # Register
      ParrotSip.UA.Client.register(ua)

      # Send BYE
      ParrotSip.UA.Client.bye(ua, dialog_id)
  """

  @doc """
  Sends an INVITE request to establish a call.

  ## Parameters
  - `ua` - UA process pid
  - `to_uri` - Target URI (e.g., "sip:bob@example.com")
  - `opts` - Optional parameters:
    - `:headers` - Custom headers map
    - `:body` - SDP body string
    - `:callback` - Custom callback function (overrides UA behaviour callbacks)

  ## Returns
  - `{:ok, transaction_id}` - Transaction started
  - `{:error, reason}` - Failed to build or send request
  """
  @spec invite(pid(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def invite(ua, to_uri, opts \\ []) do
    GenServer.call(ua, {:send_invite, to_uri, opts})
  end

  @doc """
  Sends a REGISTER request.

  ## Parameters
  - `ua` - UA process pid
  - `opts` - Optional parameters:
    - `:headers` - Custom headers map
    - `:expires` - Expires value (overrides config)

  ## Returns
  - `{:ok, transaction_id}` - Transaction started
  - `{:error, reason}` - Failed to build or send request
  """
  @spec register(pid(), keyword()) :: {:ok, term()} | {:error, term()}
  def register(ua, opts \\ []) do
    GenServer.call(ua, {:send_register, opts})
  end

  @doc """
  Sends a BYE request to terminate a dialog.

  ## Parameters
  - `ua` - UA process pid
  - `dialog_id` - Dialog identifier
  - `opts` - Optional parameters:
    - `:headers` - Custom headers map

  ## Returns
  - `{:ok, transaction_id}` - Transaction started
  - `{:error, reason}` - Failed to build or send request
  """
  @spec bye(pid(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def bye(ua, dialog_id, opts \\ []) do
    GenServer.call(ua, {:send_bye, dialog_id, opts})
  end

  @doc """
  Cancels an ongoing INVITE transaction.

  ## Parameters
  - `ua` - UA process pid
  - `transaction_id` - Transaction to cancel

  ## Returns
  - `:ok` - CANCEL sent
  - `{:error, reason}` - Failed to cancel
  """
  @spec cancel(pid(), term()) :: :ok | {:error, term()}
  def cancel(ua, transaction_id) do
    GenServer.call(ua, {:cancel_invite, transaction_id})
  end
end
