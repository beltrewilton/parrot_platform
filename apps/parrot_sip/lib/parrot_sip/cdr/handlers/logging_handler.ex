defmodule ParrotSip.CDR.Handlers.LoggingHandler do
  @moduledoc """
  Example CDR handler that logs CDR events.

  This handler demonstrates the `ParrotSip.CDR.Handler` behaviour and can be
  used as a reference implementation for custom handlers. It logs CDR events
  using Elixir's `Logger` with configurable log levels and metadata.

  ## Usage

      # Register with default options (info level, call_id metadata)
      ParrotSip.CDR.register_handler(ParrotSip.CDR.Handlers.LoggingHandler, [])

      # Register with custom log level
      ParrotSip.CDR.register_handler(ParrotSip.CDR.Handlers.LoggingHandler,
        level: :debug
      )

      # Register with custom metadata fields
      ParrotSip.CDR.register_handler(ParrotSip.CDR.Handlers.LoggingHandler,
        level: :info,
        metadata: [:call_id, :disposition, :direction]
      )

  ## Options

  - `:level` - Log level (`:debug`, `:info`, `:warning`, `:error`). Default: `:info`
  - `:metadata` - CDR fields to include in log metadata. Default: `[:call_id]`

  ## Log Output

  Each CDR generates a log entry in the format:

      CDR generated: <cdr_id> - <disposition> - <caller_uri> -> <callee_uri>

  With the configured metadata fields attached for structured logging.

  ## Example Log Output

      [info] CDR generated: cdr-abc123 - answered - sip:alice@example.com -> sip:bob@example.com call_id=call-xyz@example.com

  """

  @behaviour ParrotSip.CDR.Handler

  require Logger

  @doc """
  Initializes the LoggingHandler with the given options.

  ## Options

  - `:level` - Log level (atom). Default: `:info`
  - `:metadata` - List of CDR fields to include in log metadata. Default: `[:call_id]`

  ## Returns

  - `{:ok, state}` - Always succeeds with initialized state

  ## Examples

      iex> LoggingHandler.init([])
      {:ok, %{level: :info, metadata_keys: [:call_id]}}

      iex> LoggingHandler.init(level: :debug, metadata: [:call_id, :disposition])
      {:ok, %{level: :debug, metadata_keys: [:call_id, :disposition]}}

  """
  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(opts) when is_list(opts) do
    level = Keyword.get(opts, :level, :info)
    metadata_keys = Keyword.get(opts, :metadata, [:call_id])

    {:ok, %{level: level, metadata_keys: metadata_keys}}
  end

  @doc """
  Logs a CDR event when a call completes.

  Logs the CDR at the configured log level with the configured metadata fields.
  The log message includes the CDR ID, disposition, and caller/callee URIs.

  ## Parameters

  - `cdr` - The Call Detail Record struct
  - `state` - Handler state from `init/1` containing level and metadata_keys

  ## Returns

  - `:ok` - Always succeeds

  """
  @impl true
  @spec handle_cdr(ParrotSip.CDR.t(), map()) :: :ok
  def handle_cdr(cdr, %{level: level, metadata_keys: keys}) do
    metadata = build_metadata(cdr, keys)

    Logger.log(level, fn ->
      "CDR generated: #{cdr.id} - #{cdr.disposition} - #{cdr.caller_uri} -> #{cdr.callee_uri}"
    end, metadata)

    :ok
  end

  # Builds log metadata from CDR fields based on configured metadata_keys.
  # Gracefully handles missing fields by returning nil values.
  @spec build_metadata(ParrotSip.CDR.t(), [atom()]) :: keyword()
  defp build_metadata(cdr, keys) do
    Enum.map(keys, fn key ->
      {key, Map.get(cdr, key)}
    end)
  end
end
