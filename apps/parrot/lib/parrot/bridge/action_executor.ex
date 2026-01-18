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
  - `:sdp_answer` - The SDP answer string (if SDP negotiation was performed)
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
          | {:say, String.t(), keyword()}
          | {:say_prompt, String.t(), keyword()}
          | {:record, String.t(), keyword()}
          | {:stop_record, keyword()}
          | {:collect_dtmf, keyword()}
          | {:connect_bidirectional_ws, String.t(), keyword()}
          | {:disconnect_bidirectional_ws, list()}
          | {:mute_bidirectional, :inbound | :outbound}
          | {:unmute_bidirectional, :inbound | :outbound}
          | {:send_ws_message, String.t() | binary()}

  @type context :: %{
          required(:uas) => term(),
          required(:sip_msg) => ParrotSip.Message.t(),
          required(:media_pid) => pid() | nil,
          required(:sdp_answer) => String.t() | nil,
          optional(:response_fn) => (Message.t(), term() -> :ok),
          optional(:synthesizer) => pid() | nil
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

    # Build 200 OK response with optional SDP answer body
    #
    # When sdp_answer is provided in context (from Bridge.Handler's setup_media_session),
    # include it in the 200 OK body with proper Content-Type and Content-Length headers.
    # This enables standard SIP clients to complete the offer/answer exchange.
    #
    # For late-offer scenarios (no SDP in INVITE), sdp_answer will be nil and we
    # send an empty body response.
    sdp_answer = Map.get(context, :sdp_answer)

    # Build Contact header with our local address
    # The Contact tells the remote party where to send subsequent requests (BYE, etc.)
    local_contact = build_local_contact(sip_msg.source)

    response =
      Message.reply(sip_msg, 200, "OK")
      |> Message.put_contact(local_contact)
      |> put_sdp_body(sdp_answer)

    # Send the response - returns {:ok, final_response} with To tag added
    {:ok, final_response} = send_response(context, response)

    # Compute dialog_id from the SIP message and final response
    # For UAS: local_tag = To tag (us), remote_tag = From tag (them)
    dialog_id = compute_dialog_id(sip_msg, final_response)
    Logger.debug("[ActionExecutor] Dialog established: #{dialog_id}")

    # Start media session if present (FR-006)
    # Per RFC 3261, media can start after 200 OK is sent
    # This enables audio playback and recording operations
    start_media_if_present(context)

    # Update call state with dialog_id
    updated_call = %{call | state: :answered, __dialog_id__: dialog_id}

    {:ok, updated_call}
  end

  # Start media session if media_pid is present in context
  @spec start_media_if_present(context()) :: :ok
  defp start_media_if_present(%{media_pid: media_pid}) when is_pid(media_pid) do
    Logger.debug("[ActionExecutor] Starting media session #{inspect(media_pid)}")
    # Use the public API instead of sending a message directly
    ParrotMedia.MediaSession.start_media(media_pid)
    :ok
  end

  defp start_media_if_present(_context), do: :ok

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
  2. Send BYE to remote party (if dialog exists)
  3. Update call state to `:terminated`
  """
  @spec execute_hangup(Call.t(), context()) :: execute_result()
  def execute_hangup(call, context) do
    Logger.debug("[ActionExecutor] Executing hangup operation")

    # 1. Stop media session if running
    # Note: Sending to a dead process is safe (message silently discarded)
    media_pid = Map.get(context, :media_pid)

    if media_pid do
      Logger.debug("[ActionExecutor] Stopping media session #{inspect(media_pid)}")
      send(media_pid, {:stop_media})
    end

    # 2. Send BYE if we have a dialog
    case call.__dialog_id__ do
      nil ->
        Logger.warning("[ActionExecutor] No dialog_id, cannot send BYE")

      dialog_id ->
        send_bye(dialog_id, call)
    end

    # 3. Update call state
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

  @doc """
  Execute the `:record` operation.

  1. Verify call is in `:answered` state
  2. Verify media_pid is available
  3. Send `{:start_record, filename, opts}` to MediaSession
  """
  @spec execute_record(Call.t(), context(), String.t(), keyword()) :: execute_result()
  def execute_record(%Call{state: state}, _context, _filename, _opts) when state != :answered do
    {:error, :invalid_state}
  end

  def execute_record(_call, %{media_pid: nil}, _filename, _opts) do
    {:error, :no_media_session}
  end

  def execute_record(call, %{media_pid: media_pid} = _context, filename, opts) do
    Logger.debug("[ActionExecutor] Executing record operation: #{filename}")

    # Send record command to media session
    send(media_pid, {:start_record, filename, opts})

    {:ok, call}
  end

  @doc """
  Execute the `:stop_record` operation.

  1. Verify call is in `:answered` state
  2. Verify media_pid is available
  3. Send `{:stop_record}` to MediaSession
  """
  @spec execute_stop_record(Call.t(), context(), keyword()) :: execute_result()
  def execute_stop_record(%Call{state: state}, _context, _opts) when state != :answered do
    {:error, :invalid_state}
  end

  def execute_stop_record(_call, %{media_pid: nil}, _opts) do
    {:error, :no_media_session}
  end

  def execute_stop_record(call, %{media_pid: media_pid} = _context, _opts) do
    Logger.debug("[ActionExecutor] Executing stop_record operation")

    # Send stop record command to media session
    send(media_pid, {:stop_record})

    {:ok, call}
  end

  @doc """
  Execute the `:collect_dtmf` operation.

  1. Verify call is in `:answered` state
  2. Verify media_pid is available
  3. Send `{:collect_dtmf, opts}` to MediaSession

  Emits debug-level logging per FR-013 requirement:
  "System MUST emit debug-level log entries when DTMF digits are received,
  showing digit value and collection state."
  """
  @spec execute_collect_dtmf(Call.t(), context(), keyword()) :: execute_result()
  def execute_collect_dtmf(%Call{state: state}, _context, _opts) when state != :answered do
    {:error, :invalid_state}
  end

  def execute_collect_dtmf(_call, %{media_pid: nil}, _opts) do
    {:error, :no_media_session}
  end

  def execute_collect_dtmf(call, %{media_pid: media_pid} = _context, opts) do
    Logger.debug(
      "[ActionExecutor] Starting DTMF collection: max=#{opts[:max]}, timeout=#{opts[:timeout]}ms, terminators=#{inspect(opts[:terminators])}"
    )

    # Send collect_dtmf command to media session
    send(media_pid, {:collect_dtmf, opts})

    {:ok, call}
  end

  @doc """
  Execute the `:say` operation.

  1. Verify call is in `:answered` state
  2. Verify media_pid is available
  3. Call Synthesizer to convert text to audio
  4. Send `{:play_audio, audio_data, opts}` to MediaSession

  The Synthesizer is obtained from context (for testability) or uses the
  default `Parrot.TTS.Synthesizer` module.
  """
  @spec execute_say(Call.t(), context(), String.t(), keyword()) :: execute_result()
  def execute_say(%Call{state: state}, _context, _text, _opts) when state != :answered do
    {:error, :invalid_state}
  end

  def execute_say(_call, %{media_pid: nil}, _text, _opts) do
    {:error, :no_media_session}
  end

  def execute_say(call, %{media_pid: media_pid} = context, text, opts) do
    Logger.debug("[ActionExecutor] Executing say operation: #{inspect(text)}")

    # Get the profile from opts, defaulting to :default
    profile = Keyword.get(opts, :profile, :default)

    # Get synthesizer from context (for testing) or use the default
    synthesizer = Map.get(context, :synthesizer)

    # Call synthesizer to get audio
    synthesis_result =
      if synthesizer do
        # Test mode: synthesizer is a mock Agent that holds a function
        synth_fn = Agent.get(synthesizer, & &1)
        synth_fn.(text, profile, opts)
      else
        # Production mode: call actual Synthesizer
        # Note: This requires Parrot.TTS.Synthesizer to be started
        # For now, we'll log and return a placeholder error if not available
        try do
          Parrot.TTS.Synthesizer.get_audio(text, profile, opts)
        catch
          :exit, _ -> {:error, :synthesizer_not_available}
        end
      end

    case synthesis_result do
      {:ok, audio_data, format} ->
        # Send audio to media session for playback
        play_opts = Keyword.put(opts, :format, format)
        send(media_pid, {:play_audio, audio_data, play_opts})
        {:ok, call}

      {:error, reason} ->
        Logger.error("[ActionExecutor] TTS synthesis failed: #{inspect(reason)}")
        {:error, {:synthesis_failed, reason}}
    end
  end

  @doc """
  Execute a list of pipeline operations with TTS error handler support.

  Similar to `execute/3`, but uses the error-handler-aware versions of TTS operations.
  When TTS synthesis fails, invokes the tts_error_handler from context instead of
  returning an error, allowing the call to continue.

  ## Context Options

  - `:tts_error_handler` - Function `(text, error, call) -> call` to handle errors.
    If not provided, uses a default handler that logs and returns the call unchanged.
  """
  @spec execute_with_error_handler([operation()], Call.t(), context()) :: execute_result()
  def execute_with_error_handler([], call, _context), do: {:ok, call}

  def execute_with_error_handler([operation | rest], call, context) do
    case execute_operation_with_error_handler(operation, call, context) do
      {:ok, updated_call, :continue} ->
        execute_with_error_handler(rest, updated_call, context)

      {:ok, updated_call, :stop} ->
        {:ok, updated_call}

      {:error, _reason} = error ->
        error
    end
  end

  # Execute a single operation with TTS error handler support
  defp execute_operation_with_error_handler({:say, text, opts}, call, context) do
    case execute_say_with_error_handler(call, context, text, opts) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  defp execute_operation_with_error_handler({:say_prompt, text, opts}, call, context) do
    case execute_say_prompt_with_error_handler(call, context, text, opts) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  # For non-TTS operations, delegate to the regular execute_operation
  defp execute_operation_with_error_handler(operation, call, context) do
    execute_operation(operation, call, context)
  end

  @doc """
  Execute the `:say` operation with error handler callback support.

  When synthesis fails, invokes the tts_error_handler from context (or default)
  instead of returning an error. This allows the call to continue after TTS failures.

  ## Context Options

  - `:tts_error_handler` - Function `(text, error, call) -> call` to handle errors.
    If not provided, uses a default handler that logs and returns the call unchanged.
  """
  @spec execute_say_with_error_handler(Call.t(), context(), String.t(), keyword()) ::
          {:ok, Call.t()}
  def execute_say_with_error_handler(%Call{state: state}, _context, _text, _opts)
      when state != :answered do
    {:error, :invalid_state}
  end

  def execute_say_with_error_handler(_call, %{media_pid: nil}, _text, _opts) do
    {:error, :no_media_session}
  end

  def execute_say_with_error_handler(call, %{media_pid: media_pid} = context, text, opts) do
    Logger.debug("[ActionExecutor] Executing say operation with error handler: #{inspect(text)}")

    profile = Keyword.get(opts, :profile, :default)
    synthesizer = Map.get(context, :synthesizer)

    synthesis_result =
      if synthesizer do
        synth_fn = Agent.get(synthesizer, & &1)
        synth_fn.(text, profile, opts)
      else
        try do
          Parrot.TTS.Synthesizer.get_audio(text, profile, opts)
        catch
          :exit, _ -> {:error, :synthesizer_not_available}
        end
      end

    case synthesis_result do
      {:ok, audio_data, format} ->
        play_opts = Keyword.put(opts, :format, format)
        send(media_pid, {:play_audio, audio_data, play_opts})
        {:ok, call}

      {:error, reason} ->
        Logger.warning("[ActionExecutor] TTS synthesis failed, invoking error handler: #{inspect(reason)}")
        error_handler = Map.get(context, :tts_error_handler) || &default_tts_error_handler/3
        handler_result = error_handler.(text, reason, call)
        # Handle both {:noreply, call} and raw call return patterns
        updated_call = case handler_result do
          {:noreply, c} -> c
          c -> c
        end
        {:ok, updated_call}
    end
  end

  @doc """
  Execute the `:say_prompt` operation with error handler callback support.

  When synthesis fails, invokes the tts_error_handler from context (or default)
  instead of returning an error. This allows the call to continue after TTS failures.
  """
  @spec execute_say_prompt_with_error_handler(Call.t(), context(), String.t(), keyword()) ::
          {:ok, Call.t()}
  def execute_say_prompt_with_error_handler(%Call{state: state}, _context, _text, _opts)
      when state != :answered do
    {:error, :invalid_state}
  end

  def execute_say_prompt_with_error_handler(_call, %{media_pid: nil}, _text, _opts) do
    {:error, :no_media_session}
  end

  def execute_say_prompt_with_error_handler(call, %{media_pid: media_pid} = context, text, opts) do
    Logger.debug("[ActionExecutor] Executing say_prompt operation with error handler: #{inspect(text)}")

    profile = Keyword.get(opts, :profile, :default)
    synthesizer = Map.get(context, :synthesizer)

    synthesis_result =
      if synthesizer do
        synth_fn = Agent.get(synthesizer, & &1)
        synth_fn.(text, profile, opts)
      else
        try do
          Parrot.TTS.Synthesizer.get_audio(text, profile, opts)
        catch
          :exit, _ -> {:error, :synthesizer_not_available}
        end
      end

    case synthesis_result do
      {:ok, audio_data, format} ->
        play_opts = Keyword.put(opts, :format, format)
        send(media_pid, {:play_audio, audio_data, play_opts})

        # Store DTMF collection options for deferred collection
        collect_keys = [:max, :timeout, :terminators]
        collect_opts = Keyword.take(opts, collect_keys)
        updated_call = %{call | assigns: Map.put(call.assigns, :__pending_collect__, collect_opts)}

        {:ok, updated_call}

      {:error, reason} ->
        Logger.warning("[ActionExecutor] TTS synthesis failed for say_prompt, invoking error handler: #{inspect(reason)}")
        error_handler = Map.get(context, :tts_error_handler) || &default_tts_error_handler/3
        handler_result = error_handler.(text, reason, call)
        # Handle both {:noreply, call} and raw call return patterns
        updated_call = case handler_result do
          {:noreply, c} -> c
          c -> c
        end
        {:ok, updated_call}
    end
  end

  # Default TTS error handler - logs warning and returns {:noreply, call}
  # Signature matches handle_tts_error callback: (text, error, call) -> {:noreply, call} | call
  @spec default_tts_error_handler(String.t(), term(), Call.t()) :: {:noreply, Call.t()}
  defp default_tts_error_handler(text, error, call) do
    Logger.warning("TTS synthesis failed for text #{inspect(text)}: #{inspect(error)}")
    {:noreply, call}
  end

  @doc """
  Execute the `:say_prompt` operation.

  Combines TTS synthesis with deferred DTMF collection. This operation:
  1. Verifies call is in `:answered` state
  2. Verifies media_pid is available
  3. Calls Synthesizer to convert text to audio
  4. Sends `{:play_audio, audio_data, opts}` to MediaSession
  5. Stores DTMF collection options in call.assigns[:__pending_collect__]

  The DTMF collection will be triggered after playback completes via the
  `handle_play_complete/2` callback in the handler, which checks for
  `__pending_collect__` and starts collection.

  ## Options

  TTS options (passed to synthesizer):
    * `:profile` - Named TTS profile (default: `:default`)
    * `:voice` - Voice identifier
    * `:language` - Language/locale code

  DTMF collection options (stored in __pending_collect__):
    * `:max` - Maximum digits to collect
    * `:timeout` - Collection timeout in ms
    * `:terminators` - Digits that end collection early
  """
  @spec execute_say_prompt(Call.t(), context(), String.t(), keyword()) :: execute_result()
  def execute_say_prompt(%Call{state: state}, _context, _text, _opts) when state != :answered do
    {:error, :invalid_state}
  end

  def execute_say_prompt(_call, %{media_pid: nil}, _text, _opts) do
    {:error, :no_media_session}
  end

  def execute_say_prompt(call, %{media_pid: media_pid} = context, text, opts) do
    Logger.debug("[ActionExecutor] Executing say_prompt operation: #{inspect(text)}")

    # Get the profile from opts, defaulting to :default
    profile = Keyword.get(opts, :profile, :default)

    # Get synthesizer from context (for testing) or use the default
    synthesizer = Map.get(context, :synthesizer)

    # Call synthesizer to get audio
    synthesis_result =
      if synthesizer do
        # Test mode: synthesizer is a mock Agent that holds a function
        synth_fn = Agent.get(synthesizer, & &1)
        synth_fn.(text, profile, opts)
      else
        # Production mode: call actual Synthesizer
        try do
          Parrot.TTS.Synthesizer.get_audio(text, profile, opts)
        catch
          :exit, _ -> {:error, :synthesizer_not_available}
        end
      end

    case synthesis_result do
      {:ok, audio_data, format} ->
        # Send audio to media session for playback
        play_opts = Keyword.put(opts, :format, format)
        send(media_pid, {:play_audio, audio_data, play_opts})

        # Extract and store DTMF collection options in __pending_collect__
        # These will be used by handle_play_complete to start collection
        collect_keys = [:max, :timeout, :terminators]
        collect_opts = Keyword.take(opts, collect_keys)
        updated_call = %{call | assigns: Map.put(call.assigns, :__pending_collect__, collect_opts)}

        {:ok, updated_call}

      {:error, reason} ->
        Logger.error("[ActionExecutor] TTS synthesis failed for say_prompt: #{inspect(reason)}")
        {:error, {:synthesis_failed, reason}}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Execute a single operation
  defp execute_operation({:answer, opts}, call, context) do
    case execute_answer(call, context, opts) do
      # Answer continues so subsequent operations (play, collect_dtmf) can execute
      {:ok, updated_call} -> {:ok, updated_call, :continue}
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

  defp execute_operation({:record, filename, opts}, call, context) do
    case execute_record(call, context, filename, opts) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  defp execute_operation({:stop_record, opts}, call, context) do
    case execute_stop_record(call, context, opts) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  defp execute_operation({:collect_dtmf, opts}, call, context) do
    case execute_collect_dtmf(call, context, opts) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  defp execute_operation({:say, text, opts}, call, context) do
    case execute_say(call, context, text, opts) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  defp execute_operation({:say_prompt, text, opts}, call, context) do
    case execute_say_prompt(call, context, text, opts) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  # Bidirectional WebSocket operations
  defp execute_operation({:connect_bidirectional_ws, url, opts}, call, context) do
    case execute_connect_bidirectional_ws(call, context, url, opts) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  defp execute_operation({:disconnect_bidirectional_ws, _opts}, call, context) do
    case execute_disconnect_bidirectional_ws(call, context) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  defp execute_operation({:mute_bidirectional, direction}, call, context) do
    case execute_mute_bidirectional(call, context, direction) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  defp execute_operation({:unmute_bidirectional, direction}, call, context) do
    case execute_unmute_bidirectional(call, context, direction) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  defp execute_operation({:send_ws_message, message}, call, context) do
    case execute_send_ws_message(call, context, message) do
      {:ok, updated_call} -> {:ok, updated_call, :continue}
      error -> error
    end
  end

  defp execute_operation(unknown, _call, _context) do
    Logger.warning("[ActionExecutor] Unknown operation: #{inspect(unknown)}")
    {:error, {:unknown_operation, unknown}}
  end

  # Send response - handle different modes
  # Returns {:ok, final_response} in all modes for consistency
  @spec send_response(context(), Message.t()) :: {:ok, Message.t()}
  defp send_response(context, response) do
    uas = Map.get(context, :uas)

    case Map.get(context, :response_fn) do
      response_fn when is_function(response_fn, 2) ->
        # Test mode with callback function
        response_fn.(response, uas)
        {:ok, response}

      nil when is_pid(uas) ->
        # Test mode - send message to process
        send(uas, {:response_sent, response})
        {:ok, response}

      nil ->
        # Production mode - use UAS transaction
        # Returns {:ok, final_response} with To tag added
        UAS.response(response, uas)
    end
  end

  # Compute dialog_id from request and response messages
  # For UAS: local_tag = To tag (our tag), remote_tag = From tag (their tag)
  @spec compute_dialog_id(Message.t(), Message.t()) :: String.t()
  defp compute_dialog_id(request, response) do
    call_id = request.call_id

    # From tag (remote party) from request
    remote_tag = get_in(request.from.parameters, ["tag"])

    # To tag (us) from response - added by Transaction.Server
    local_tag = get_in(response.to.parameters, ["tag"])

    # Generate dialog ID from UAS perspective
    ParrotSip.Dialog.generate_id(:uas, call_id, local_tag, remote_tag)
  end

  # Send BYE request to terminate dialog
  @spec send_bye(String.t(), Call.t()) :: :ok
  defp send_bye(dialog_id, call) do
    # Look up dialog and create BYE request
    case ParrotSip.DialogStatem.uac_request(dialog_id, %Message{method: :bye}) do
      {:ok, bye_request} ->
        Logger.info("[ActionExecutor] Sending BYE for call #{call.id}")

        # Send BYE via client transaction
        # We don't need to wait for the response - fire and forget
        bye_callback = fn
          {:message, %{status_code: status}} ->
            Logger.debug("[ActionExecutor] BYE response: #{status}")
            :ok

          {:stop, reason} ->
            Logger.debug("[ActionExecutor] BYE transaction stopped: #{inspect(reason)}")
            :ok
        end

        ParrotSip.Transaction.Client.request(bye_request, bye_callback)
        :ok

      {:error, :no_dialog} ->
        Logger.warning("[ActionExecutor] Dialog #{dialog_id} not found, cannot send BYE")
        :ok

      {:error, :timeout} ->
        Logger.warning("[ActionExecutor] Timeout looking up dialog #{dialog_id}")
        :ok
    end
  end

  # Set SDP body on response (or empty body if no SDP answer)
  # Per RFC 3261 Section 13.2.1: 200 OK to INVITE includes SDP answer
  @spec put_sdp_body(Message.t(), String.t() | nil) :: Message.t()
  defp put_sdp_body(response, nil) do
    response
    |> Map.put(:body, "")
    |> Map.put(:content_length, 0)
    |> Map.put(:content_type, nil)
  end

  defp put_sdp_body(response, sdp_answer) when is_binary(sdp_answer) do
    response
    |> Map.put(:body, sdp_answer)
    |> Map.put(:content_length, byte_size(sdp_answer))
    |> Map.put(:content_type, "application/sdp")
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

  # ============================================================================
  # Bidirectional WebSocket Operations (Stubs)
  # Real implementation will be added in Phase 4 (US2-US4)
  # ============================================================================

  @spec execute_connect_bidirectional_ws(Call.t(), context(), String.t(), keyword()) ::
          {:ok, Call.t()}
  defp execute_connect_bidirectional_ws(call, _context, _url, _opts) do
    # Phase 4 implementation will establish WsBidirectional connection
    {:ok, call}
  end

  @spec execute_disconnect_bidirectional_ws(Call.t(), context()) :: {:ok, Call.t()}
  defp execute_disconnect_bidirectional_ws(call, _context) do
    # Phase 4 implementation will close WsBidirectional connection
    {:ok, call}
  end

  @spec execute_mute_bidirectional(Call.t(), context(), :inbound | :outbound) :: {:ok, Call.t()}
  defp execute_mute_bidirectional(call, _context, _direction) do
    # Phase 4 implementation will mute WsBidirectional stream direction
    {:ok, call}
  end

  @spec execute_unmute_bidirectional(Call.t(), context(), :inbound | :outbound) :: {:ok, Call.t()}
  defp execute_unmute_bidirectional(call, _context, _direction) do
    # Phase 4 implementation will unmute WsBidirectional stream direction
    {:ok, call}
  end

  @spec execute_send_ws_message(Call.t(), context(), String.t() | binary()) :: {:ok, Call.t()}
  defp execute_send_ws_message(call, _context, _message) do
    # Phase 4 implementation will send message via WsBidirectional connection
    {:ok, call}
  end

  # Build a Contact header with our local address
  # Per RFC 3261, the Contact in a 2xx response tells the remote party
  # where to send subsequent requests (BYE, re-INVITE, etc.)
  @spec build_local_contact(ParrotSip.Source.t() | nil) :: ParrotSip.Headers.Contact.t() | nil
  defp build_local_contact(%ParrotSip.Source{local: {{_, _, _, _} = ip, port}}) do
    %ParrotSip.Headers.Contact{
      uri: %ParrotSip.Uri{
        scheme: "sip",
        host: :inet.ntoa(ip) |> to_string(),
        port: port,
        host_type: :ipv4,
        parameters: %{},
        headers: %{}
      },
      parameters: %{}
    }
  end

  defp build_local_contact(%ParrotSip.Source{local: {{_, _, _, _, _, _, _, _} = ip, port}}) do
    %ParrotSip.Headers.Contact{
      uri: %ParrotSip.Uri{
        scheme: "sip",
        host: :inet.ntoa(ip) |> to_string(),
        port: port,
        host_type: :ipv6,
        parameters: %{},
        headers: %{}
      },
      parameters: %{}
    }
  end

  defp build_local_contact(_), do: nil
end
