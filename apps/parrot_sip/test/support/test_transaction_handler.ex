defmodule ParrotSip.Test.TestTransactionHandler do
  @moduledoc """
  A simple test handler for transaction tests that implements the Handler behavior.
  """

  @behaviour ParrotSip.Handler

  @impl true
  def transp_request(_msg, _args), do: :noreply

  @impl true
  def transaction(_trans, _msg, _args), do: :ok

  @impl true
  def transaction_stop(_trans, _result, _args), do: :ok

  @impl true
  def uas_request(_uas, _msg, _args), do: :ok

  @impl true
  def uas_cancel(_uas_id, _args), do: :ok

  @impl true
  def process_ack(_msg, _args), do: :ok
end
