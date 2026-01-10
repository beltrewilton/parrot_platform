defmodule ParrotSip.CDR.Handler do
  @moduledoc """
  Behaviour for CDR (Call Detail Record) handlers.

  Implement this behaviour to receive CDR events when calls complete.
  CDRs are generated automatically for every INVITE dialog upon termination
  and delivered to all registered handlers.

  ## Semantics

  Handlers use fire-and-forget semantics:
  - Handler errors are logged but don't affect other handlers
  - Each handler receives CDRs independently
  - Handler state is maintained per-handler instance

  ## Callbacks

  - `c:init/1` - Initialize handler state (optional)
  - `c:handle_cdr/2` - Process a CDR when a call completes

  ## Example: Simple Logger Handler

      defmodule MyApp.CDR.LoggerHandler do
        @behaviour ParrotSip.CDR.Handler

        require Logger

        @impl true
        def init(_args), do: {:ok, %{}}

        @impl true
        def handle_cdr(cdr, state) do
          Logger.info("CDR generated",
            call_id: cdr.call_id,
            disposition: cdr.disposition,
            duration_ms: cdr.talk_duration_ms
          )
          :ok
        end
      end

  ## Example: Database Storage Handler

      defmodule MyApp.CDR.DatabaseHandler do
        @behaviour ParrotSip.CDR.Handler

        @impl true
        def init(opts) do
          repo = Keyword.fetch!(opts, :repo)
          {:ok, %{repo: repo}}
        end

        @impl true
        def handle_cdr(cdr, %{repo: repo} = state) do
          changeset = MyApp.CDRRecord.changeset(%MyApp.CDRRecord{}, cdr_to_map(cdr))

          case repo.insert(changeset) do
            {:ok, _record} -> :ok
            {:error, changeset} -> {:error, changeset.errors}
          end
        end

        defp cdr_to_map(cdr) do
          %{
            call_id: cdr.call_id,
            caller_uri: cdr.caller_uri,
            callee_uri: cdr.callee_uri,
            disposition: cdr.disposition,
            ring_duration_ms: cdr.ring_duration_ms,
            talk_duration_ms: cdr.talk_duration_ms,
            started_at: cdr.invite_received_at,
            ended_at: cdr.ended_at
          }
        end
      end

  ## Example: Metrics Handler

      defmodule MyApp.CDR.MetricsHandler do
        @behaviour ParrotSip.CDR.Handler

        @impl true
        def init(opts) do
          prefix = Keyword.get(opts, :metric_prefix, "sip.cdr")
          {:ok, %{prefix: prefix}}
        end

        @impl true
        def handle_cdr(cdr, %{prefix: prefix}) do
          # Increment call counter by disposition
          :telemetry.execute(
            [prefix, :call, :completed],
            %{count: 1},
            %{disposition: cdr.disposition, direction: cdr.direction}
          )

          # Record durations
          if cdr.talk_duration_ms > 0 do
            :telemetry.execute(
              [prefix, :call, :duration],
              %{duration_ms: cdr.talk_duration_ms},
              %{disposition: cdr.disposition}
            )
          end

          :ok
        end
      end

  ## Example: Webhook Forwarder Handler

      defmodule MyApp.CDR.WebhookHandler do
        @behaviour ParrotSip.CDR.Handler

        require Logger

        @impl true
        def init(opts) do
          url = Keyword.fetch!(opts, :webhook_url)
          headers = Keyword.get(opts, :headers, [{"content-type", "application/json"}])
          {:ok, %{url: url, headers: headers}}
        end

        @impl true
        def handle_cdr(cdr, %{url: url, headers: headers}) do
          body = Jason.encode!(cdr_to_json(cdr))

          case :httpc.request(:post, {url, headers, "application/json", body}, [], []) do
            {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
              :ok

            {:ok, {{_, status, _}, _, body}} ->
              Logger.warning("Webhook returned non-2xx status",
                status: status,
                call_id: cdr.call_id
              )
              {:error, {:http_error, status, body}}

            {:error, reason} ->
              Logger.error("Webhook request failed",
                reason: inspect(reason),
                call_id: cdr.call_id
              )
              {:error, reason}
          end
        end

        defp cdr_to_json(cdr) do
          %{
            id: cdr.id,
            call_id: cdr.call_id,
            correlation_id: cdr.correlation_id,
            caller_uri: cdr.caller_uri,
            callee_uri: cdr.callee_uri,
            disposition: cdr.disposition,
            termination_cause: termination_cause_to_json(cdr.termination_cause),
            ring_duration_ms: cdr.ring_duration_ms,
            talk_duration_ms: cdr.talk_duration_ms,
            direction: cdr.direction,
            invite_received_at: DateTime.to_iso8601(cdr.invite_received_at),
            ended_at: DateTime.to_iso8601(cdr.ended_at),
            answered_at: cdr.answered_at && DateTime.to_iso8601(cdr.answered_at)
          }
        end

        defp termination_cause_to_json(%{initiator: initiator, reason: reason, sip_status: status}) do
          %{initiator: initiator, reason: reason, sip_status: status}
        end
      end

  ## Registering Handlers

  Handlers are registered with the CDR.Writer process at startup:

      # In your application supervision tree
      children = [
        {ParrotSip.CDR.Writer, [
          handlers: [
            {MyApp.CDR.LoggerHandler, []},
            {MyApp.CDR.DatabaseHandler, [repo: MyApp.Repo]},
            {MyApp.CDR.MetricsHandler, [metric_prefix: "parrot.cdr"]}
          ]
        ]}
      ]

  """

  alias ParrotSip.CDR

  @doc """
  Initialize handler state.

  Called when the handler is registered with the CDR.Writer.
  The `args` parameter contains handler-specific configuration
  passed during registration.

  ## Parameters

  - `args` - Handler-specific initialization arguments

  ## Return Values

  - `{:ok, state}` - Handler initialized successfully with the given state
  - `{:error, reason}` - Handler initialization failed

  ## Default Implementation

  If not implemented, passes `args` through as the initial state:

      def init(args), do: {:ok, args}

  """
  @callback init(args :: term()) :: {:ok, state :: term()} | {:error, reason :: term()}

  @doc """
  Handle a CDR when a call completes.

  Called for each CDR generated when an INVITE dialog terminates.
  The handler should process the CDR (log, store, forward, etc.)
  and return `:ok` on success.

  ## Parameters

  - `cdr` - The Call Detail Record struct
  - `state` - The handler's current state (from init/1 or previous handle_cdr/2)

  ## Return Values

  - `:ok` - CDR processed successfully
  - `{:error, reason}` - CDR processing failed (logged, but doesn't affect other handlers)

  ## Notes

  - This callback is required
  - Errors are logged but don't prevent other handlers from receiving the CDR
  - Long-running operations should be delegated to background processes
  - The same CDR may be delivered to multiple handlers concurrently

  """
  @callback handle_cdr(cdr :: CDR.t(), state :: term()) :: :ok | {:error, term()}

  @optional_callbacks [init: 1]

  @doc """
  Default implementation of init/1 that passes args through as state.

  This function provides a sensible default for handlers that don't
  need complex initialization. If your handler requires custom setup,
  implement the `c:init/1` callback in your handler module instead.

  ## Example

  For a handler that doesn't need initialization:

      defmodule MyApp.SimpleHandler do
        @behaviour ParrotSip.CDR.Handler

        # init/1 not implemented - uses default

        @impl true
        def handle_cdr(cdr, _state) do
          IO.puts("Call completed: \#{cdr.call_id}")
          :ok
        end
      end

  """
  @spec init(term()) :: {:ok, term()}
  def init(args), do: {:ok, args}
end
