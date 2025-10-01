defmodule ParrotSip.Handler do
  @moduledoc """
  Parrot SIP Stack
  SIP stack handler
  """

  @type handler :: %__MODULE__{
          module: module(),
          args: term(),
          log_level: atom() | nil,
          sip_trace: boolean() | nil
        }

  @type transp_request_ret :: :noreply | :process_transaction

  defstruct [:module, :args, :log_level, :sip_trace]

  @callback transp_request(ParrotSip.Message.t(), any()) :: :process_transaction | :noreply
  @callback transaction(ParrotSip.Transaction.t(), ParrotSip.Message.t(), any()) ::
              :process_uas | :ok
  @callback transaction_stop(ParrotSip.Transaction.t(), any(), any()) :: :ok
  @callback uas_request(ParrotSip.UAS.t(), ParrotSip.Message.t(), any()) :: :ok
  @callback uas_cancel(ParrotSip.UAS.id(), any()) :: :ok
  @callback process_ack(ParrotSip.Message.t(), any()) :: :ok

  @spec new(module(), any()) :: handler()
  @spec new(module(), any(), keyword()) :: handler()

  def new(module, args, opts \\ []) do
    %__MODULE__{
      module: module,
      args: args,
      log_level: Keyword.get(opts, :log_level),
      sip_trace: Keyword.get(opts, :sip_trace)
    }
  end

  @spec args(handler()) :: any()
  def args(%__MODULE__{args: args}), do: args

  @spec transp_request(ParrotSip.Message.t(), handler()) :: transp_request_ret()
  def transp_request(msg, %__MODULE__{module: mod, args: args}) do
    mod.transp_request(msg, args)
  end

  @spec transaction(ParrotSip.Transaction.t(), ParrotSip.Message.t(), handler()) ::
          :ok | :process_uas
  def transaction(trans, sip_msg, %__MODULE__{module: mod, args: args}) do
    mod.transaction(trans, sip_msg, args)
  end

  @spec transaction_stop(ParrotSip.Transaction.t(), term(), handler()) :: :ok
  def transaction_stop(trans, trans_result, %__MODULE__{module: mod, args: args}) do
    mod.transaction_stop(trans, trans_result, args)
  end

  def transaction_stop(_trans, _trans_result, _handler) do
    :ok
  end

  @spec uas_request(ParrotSip.UAS.t(), ParrotSip.Message.t(), handler()) :: :ok
  def uas_request(uas, req_sip_msg, %__MODULE__{module: mod, args: args}) do
    mod.uas_request(uas, req_sip_msg, args)
  end

  @spec uas_cancel(ParrotSip.UAS.id(), handler()) :: :ok
  def uas_cancel(uas_id, %__MODULE__{module: mod, args: args}) do
    mod.uas_cancel(uas_id, args)
  end

  @spec process_ack(ParrotSip.Message.t(), handler()) :: :ok
  def process_ack(sip_msg, %__MODULE__{module: mod, args: args}) do
    mod.process_ack(sip_msg, args)
  end
end
