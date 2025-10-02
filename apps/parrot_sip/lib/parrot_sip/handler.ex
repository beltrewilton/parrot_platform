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

  # Optional method-specific callbacks
  @callback handle_options(ParrotSip.UAS.t(), ParrotSip.Message.t(), any()) :: :ok
  @callback handle_invite(ParrotSip.UAS.t(), ParrotSip.Message.t(), any()) :: :ok
  @callback handle_bye(ParrotSip.UAS.t(), ParrotSip.Message.t(), any()) :: :ok
  @callback handle_cancel(ParrotSip.UAS.t(), ParrotSip.Message.t(), any()) :: :ok
  @callback handle_register(ParrotSip.UAS.t(), ParrotSip.Message.t(), any()) :: :ok
  @callback handle_subscribe(ParrotSip.UAS.t(), ParrotSip.Message.t(), any()) :: :ok
  @callback handle_notify(ParrotSip.UAS.t(), ParrotSip.Message.t(), any()) :: :ok
  @callback handle_message(ParrotSip.UAS.t(), ParrotSip.Message.t(), any()) :: :ok
  @callback handle_info(ParrotSip.UAS.t(), ParrotSip.Message.t(), any()) :: :ok

  # Optional transaction state callbacks
  @callback handle_transaction_trying(ParrotSip.Transaction.t(), ParrotSip.Message.t(), any()) ::
              :ok
  @callback handle_transaction_proceeding(
              ParrotSip.Transaction.t(),
              ParrotSip.Message.t(),
              any()
            ) :: :ok
  @callback handle_transaction_completed(
              ParrotSip.Transaction.t(),
              ParrotSip.Message.t(),
              any()
            ) :: :ok
  @callback handle_transaction_confirmed(
              ParrotSip.Transaction.t(),
              ParrotSip.Message.t(),
              any()
            ) :: :ok

  @optional_callbacks [
    handle_options: 3,
    handle_invite: 3,
    handle_bye: 3,
    handle_cancel: 3,
    handle_register: 3,
    handle_subscribe: 3,
    handle_notify: 3,
    handle_message: 3,
    handle_info: 3,
    handle_transaction_trying: 3,
    handle_transaction_proceeding: 3,
    handle_transaction_completed: 3,
    handle_transaction_confirmed: 3
  ]

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
    # Try method-specific callback first, fall back to generic uas_request
    method = req_sip_msg.method
    method_callback = method_to_callback(method)

    if function_exported?(mod, method_callback, 3) do
      apply(mod, method_callback, [uas, req_sip_msg, args])
    else
      mod.uas_request(uas, req_sip_msg, args)
    end
  end

  # Map SIP methods to callback function names
  defp method_to_callback(:options), do: :handle_options
  defp method_to_callback(:invite), do: :handle_invite
  defp method_to_callback(:bye), do: :handle_bye
  defp method_to_callback(:cancel), do: :handle_cancel
  defp method_to_callback(:register), do: :handle_register
  defp method_to_callback(:subscribe), do: :handle_subscribe
  defp method_to_callback(:notify), do: :handle_notify
  defp method_to_callback(:message), do: :handle_message
  defp method_to_callback(:info), do: :handle_info
  defp method_to_callback(_), do: nil

  @spec uas_cancel(ParrotSip.UAS.id(), handler()) :: :ok
  def uas_cancel(uas_id, %__MODULE__{module: mod, args: args}) do
    mod.uas_cancel(uas_id, args)
  end

  @spec process_ack(ParrotSip.Message.t(), handler()) :: :ok
  def process_ack(sip_msg, %__MODULE__{module: mod, args: args}) do
    mod.process_ack(sip_msg, args)
  end

  @spec transaction_trying(ParrotSip.Transaction.t(), ParrotSip.Message.t(), handler()) :: :ok
  def transaction_trying(trans, sip_msg, %__MODULE__{module: mod, args: args}) do
    if function_exported?(mod, :handle_transaction_trying, 3) do
      apply(mod, :handle_transaction_trying, [trans, sip_msg, args])
    else
      :ok
    end
  end

  @spec transaction_proceeding(ParrotSip.Transaction.t(), ParrotSip.Message.t(), handler()) ::
          :ok
  def transaction_proceeding(trans, sip_msg, %__MODULE__{module: mod, args: args}) do
    if function_exported?(mod, :handle_transaction_proceeding, 3) do
      apply(mod, :handle_transaction_proceeding, [trans, sip_msg, args])
    else
      :ok
    end
  end

  @spec transaction_completed(ParrotSip.Transaction.t(), ParrotSip.Message.t(), handler()) :: :ok
  def transaction_completed(trans, sip_msg, %__MODULE__{module: mod, args: args}) do
    if function_exported?(mod, :handle_transaction_completed, 3) do
      apply(mod, :handle_transaction_completed, [trans, sip_msg, args])
    else
      :ok
    end
  end

  @spec transaction_confirmed(ParrotSip.Transaction.t(), ParrotSip.Message.t(), handler()) :: :ok
  def transaction_confirmed(trans, sip_msg, %__MODULE__{module: mod, args: args}) do
    if function_exported?(mod, :handle_transaction_confirmed, 3) do
      apply(mod, :handle_transaction_confirmed, [trans, sip_msg, args])
    else
      :ok
    end
  end
end
