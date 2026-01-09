defmodule Parrot.Bridge.ActionExecutor do
  @moduledoc """
  Executes pipeline operations from `Parrot.Call` into actual SIP responses and media commands.

  The ActionExecutor translates the declarative DSL operations (like `answer()`, `play()`, `hangup()`)
  into concrete actions:

  - `:answer` → Send 200 OK with SDP, start MediaSession
  - `:reject` → Send error response (4xx/5xx)
  - `:hangup` → Send BYE, stop MediaSession
  - `:play` → Send play command to MediaSession

  ## Usage

  Called by `Parrot.Call.Server` after each callback invocation:

      operations = Call.get_operations(call)
      {:ok, updated_call} = ActionExecutor.execute(operations, call, context)

  ## Context

  The context map contains:
  - `:uas` - The UAS transaction reference (for sending responses)
  - `:sip_msg` - The original SIP request message
  - `:media_pid` - The MediaSession process (if started)
  """

  require Logger

  alias Parrot.Call
  alias ParrotSip.Message
  alias ParrotSip.Transaction.Server, as: UAS

  @type operation ::
          {:answer, keyword()}
          | {:reject, integer()}
          | {:reject, integer(), keyword()}
          | {:hangup, keyword()}
          | {:play, String.t() | [String.t()], keyword()}

  @type context :: %{
          required(:uas) => term(),
          required(:sip_msg) => ParrotSip.Message.t(),
          required(:media_pid) => pid() | nil,
          optional(:response_fn) => (Message.t(), term() -> :ok)
        }

  @type execute_result ::
          {:ok, Call.t()}
          | {:error, :no_uas}
          | {:error, :no_media_session}
          | {:error, :invalid_state}
          | {:error, term()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Execute a list of pipeline operations.

  Processes operations in order, updating call state as needed.
  Stops on first error or signaling operation (answer/reject/hangup).

  ## Parameters
  - `operations` - List of operations from `Call.get_operations/1`
  - `call` - Current call state
  - `context` - Execution context (uas, sip_msg, media_pid)

  ## Returns
  - `{:ok, updated_call}` - Operations executed successfully
  - `{:error, reason}` - Execution failed
  """
  @spec execute([operation()], Call.t(), context()) :: execute_result()
  def execute([], call, _context), do: {:ok, call}

  def execute([operation | rest], call, context) do
    case execute_operation(operation, call, context) do
      {:ok, updated_call, :continue} ->
        execute(rest, updated_call, context)

      {:ok, updated_call, :stop} ->
        # Signaling operation - don't process further operations
        {:ok, updated_call}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Execute the `:answer` operation.

  1. Build 200 OK response with SDP
  2. Send via `ParrotSip.Transaction.Server.response/2`
  3. Update call state to `:answered`

  Note: MediaSession startup is handled separately after ACK is received.
  """
  @spec execute_answer(Call.t(), context(), keyword()) :: execute_result()
  def execute_answer(_call, %{uas: nil}, _opts), do: {:error, :no_uas}

  def execute_answer(call, %{sip_msg: sip_msg} = context, _opts) do
    Logger.debug("[ActionExecutor] Executing answer operation")

    # Build 200 OK response
    # Note: SDP body for media negotiation is not included in this basic implementation.
    # The current behavior sends a 200 OK without SDP, which means no media session
    # parameters are exchanged. Full SDP negotiation requires integration with
    # MediaSession to generate an SDP answer based on the offer in the INVITE.
    response = Message.reply(sip_msg, 200, "OK")

    # Send the response
    send_response(context, response)

    # Update call state
    updated_call = %{call | state: :answered}

    {:ok, updated_call}
  end

  @doc """
  Execute the `:reject` operation.

  1. Build error response with given status code
  2. Send via `ParrotSip.Transaction.Server.response/2`
  3. Update call state to `:terminated`
  """
  @spec execute_reject(Call.t(), context(), integer()) :: execute_result()
  def execute_reject(_call, %{uas: nil}, _status_code), do: {:error, :no_uas}

  def execute_reject(call, %{sip_msg: sip_msg} = context, status_code) do
    Logger.debug("[ActionExecutor] Executing reject operation with status #{status_code}")

    # Get reason phrase for status code
    reason = status_code_reason(status_code)

    # Build error response
    response = Message.reply(sip_msg, status_code, reason)

    # Send the response
    send_response(context, response)

    # Update call state
    updated_call = %{call | state: :terminated}

    {:ok, updated_call}
  end

  @doc """
  Execute the `:hangup` operation.

  1. Stop MediaSession if running
  2. Update call state to `:terminated`

  Note: BYE request transmission is not currently implemented. The current behavior
  stops the local media session but does not send a BYE to the remote party.
  Call termination relies on the remote party initiating the BYE.
  """
  @spec execute_hangup(Call.t(), context()) :: execute_result()
  def execute_hangup(call, %{media_pid: media_pid} = _context) do
    Logger.debug("[ActionExecutor] Executing hangup operation")

    # Stop media session if running
    # Note: Sending to a dead process is safe (message silently discarded)
    if media_pid do
      Logger.debug("[ActionExecutor] Stopping media session #{inspect(media_pid)}")
      send(media_pid, {:stop_media})
    end

    # Note: BYE request transmission is not implemented in ActionExecutor.
    # The current behavior only stops the local media session and updates call state.
    # To properly terminate an established call, the Bridge.Handler or a UAC module
    # must send the BYE request using dialog state. Currently, call termination
    # relies on the remote party sending BYE.
    updated_call = %{call | state: :terminated}

    {:ok, updated_call}
  end

  @doc """
  Execute the `:play` operation.

  1. Verify call is in `:answered` state
  2. Verify media_pid is available
  3. Send `{:play_files, files, opts}` to MediaSession
  """
  @spec execute_play(Call.t(), context(), String.t() | [String.t()], keyword()) ::
          execute_result()
  def execute_play(%Call{state: state}, _context, _files, _opts) when state != :answered do
    {:error, :invalid_state}
  end

  def execute_play(_call, %{media_pid: nil}, _files, _opts) do
    {:error, :no_media_session}
  end

  def execute_play(call, %{media_pid: media_pid} = _context, files, opts) do
    Logger.debug("[ActionExecutor] Executing play operation: #{inspect(files)}")

    # Normalize files to list
    file_list = if is_list(files), do: files, else: [files]

    # Send play command to media session
    send(media_pid, {:play_files, file_list, opts})

    {:ok, call}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Execute a single operation
  defp execute_operation({:answer, opts}, call, context) do
    case execute_answer(call, context, opts) do
      {:ok, updated_call} -> {:ok, updated_call, :stop}
      error -> error
    end
  end

  defp execute_operation({:reject, status_code}, call, context) do
    case execute_reject(call, context, status_code) do
      {:ok, updated_call} -> {:ok, updated_call, :stop}
      error -> error
    end
  end

  defp execute_operation({:reject, status_code, _opts}, call, context) do
    case execute_reject(call, context, status_code) do
      {:ok, updated_call} -> {:ok, updated_call, :stop}
      error -> error
    end
  end

  defp execute_operation({:hangup, _opts}, call, context) do
    case execute_hangup(call, context) do
      {:ok, updated_call} -> {:ok, updated_call, :stop}
      error -> error
    end
  end

  defp execute_operation({:play, files, opts}, call, context) do
    case execute_play(call, context, files, opts) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  defp execute_operation(unknown, _call, _context) do
    Logger.warning("[ActionExecutor] Unknown operation: #{inspect(unknown)}")
    {:error, {:unknown_operation, unknown}}
  end

  # Send response - handle different modes
  defp send_response(context, response) do
    uas = Map.get(context, :uas)

    case Map.get(context, :response_fn) do
      response_fn when is_function(response_fn, 2) ->
        # Test mode with callback function
        response_fn.(response, uas)

      nil when is_pid(uas) ->
        # Test mode - send message to process
        send(uas, {:response_sent, response})
        :ok

      nil ->
        # Production mode - use UAS transaction
        UAS.response(response, uas)
    end
  end

  # Map status codes to reason phrases
  defp status_code_reason(100), do: "Trying"
  defp status_code_reason(180), do: "Ringing"
  defp status_code_reason(183), do: "Session Progress"
  defp status_code_reason(200), do: "OK"
  defp status_code_reason(400), do: "Bad Request"
  defp status_code_reason(401), do: "Unauthorized"
  defp status_code_reason(403), do: "Forbidden"
  defp status_code_reason(404), do: "Not Found"
  defp status_code_reason(408), do: "Request Timeout"
  defp status_code_reason(480), do: "Temporarily Unavailable"
  defp status_code_reason(486), do: "Busy Here"
  defp status_code_reason(487), do: "Request Terminated"
  defp status_code_reason(488), do: "Not Acceptable Here"
  defp status_code_reason(500), do: "Internal Server Error"
  defp status_code_reason(501), do: "Not Implemented"
  defp status_code_reason(503), do: "Service Unavailable"
  defp status_code_reason(code), do: "Status #{code}"
end
