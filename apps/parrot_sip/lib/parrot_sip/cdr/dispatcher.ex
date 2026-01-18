defmodule ParrotSip.CDR.Dispatcher do
  @moduledoc """
  Dispatches CDRs to registered handlers using fire-and-forget Tasks.

  The Dispatcher is responsible for delivering CDRs to all registered handlers
  asynchronously. Each handler receives the CDR in a separate Task, ensuring:

  - Handler failures are isolated and don't affect other handlers
  - The caller returns immediately without waiting for handlers to complete
  - All handlers execute concurrently for maximum throughput

  ## Usage

  Typically called by the CDR.Writer when a call completes:

      handlers = [
        {MyApp.CDR.LoggerHandler, %{level: :info}},
        {MyApp.CDR.DatabaseHandler, %{repo: MyApp.Repo}}
      ]

      :ok = Dispatcher.dispatch(cdr, handlers)

  ## Error Handling

  Handler failures are logged at the `:error` level but do not propagate:

  - If a handler returns `{:error, reason}`, the error is logged
  - If a handler raises an exception, it is caught and logged
  - Other handlers continue processing regardless of failures

  """

  require Logger

  alias ParrotSip.CDR

  @doc """
  Dispatches a CDR to all registered handlers asynchronously.

  Spawns a Task for each handler to deliver the CDR. The function returns
  immediately with `:ok` regardless of whether handlers succeed or fail.

  ## Parameters

  - `cdr` - The Call Detail Record to dispatch
  - `handlers` - List of `{handler_module, state}` tuples where:
    - `handler_module` - A module implementing `ParrotSip.CDR.Handler`
    - `state` - The handler's initialized state

  ## Returns

  - `:ok` - Always returns `:ok` immediately (fire-and-forget)

  ## Examples

      iex> handlers = [{MyLoggerHandler, %{}}]
      iex> Dispatcher.dispatch(cdr, handlers)
      :ok

  """
  @spec dispatch(CDR.t(), [{module(), term()}]) :: :ok
  def dispatch(_cdr, []), do: :ok

  def dispatch(%CDR{} = cdr, handlers) when is_list(handlers) do
    for {handler_module, state} <- handlers do
      Task.start(fn ->
        deliver_to_handler(cdr, handler_module, state)
      end)
    end

    :ok
  end

  # Delivers a CDR to a single handler with error handling.
  # Catches both error returns and exceptions, logging failures.
  @spec deliver_to_handler(CDR.t(), module(), term()) :: :ok
  defp deliver_to_handler(%CDR{} = cdr, handler_module, state) do
    case handler_module.handle_cdr(cdr, state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("CDR handler #{inspect(handler_module)} returned error",
          reason: inspect(reason),
          call_id: cdr.call_id,
          cdr_id: cdr.id
        )

        :ok
    end
  rescue
    exception ->
      Logger.error("CDR handler #{inspect(handler_module)} raised exception",
        exception: Exception.format(:error, exception, __STACKTRACE__),
        call_id: cdr.call_id,
        cdr_id: cdr.id
      )

      :ok
  end
end
