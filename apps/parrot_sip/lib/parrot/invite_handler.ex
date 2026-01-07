defmodule Parrot.InviteHandler do
  @moduledoc """
  Behaviour for handling incoming SIP INVITE requests in IVR-style applications.

  This behaviour defines callbacks that are invoked during the lifecycle of an
  incoming call. Modules implementing this behaviour can control call flow by
  returning a `call` map that may contain pipeline operations.

  ## Required Callbacks

  - `handle_invite/1` - Called when an INVITE is received. Must return a call map.

  ## Optional Callbacks

  All other callbacks are optional and have default implementations:

  - `handle_play_complete/2` - Called when audio playback finishes
  - `handle_dtmf/2` - Called when DTMF digits are collected or timeout occurs
  - `handle_bridge_complete/2` - Called when a bridged call ends
  - `handle_fork_complete/2` - Called when a forked dial attempt completes
  - `handle_record_complete/3` - Called when recording finishes
  - `handle_hangup/1` - Called when the caller hangs up

  ## Example

      defmodule MyApp.IvrHandler do
        @behaviour Parrot.InviteHandler

        @impl true
        def handle_invite(call) do
          call
          |> Map.put(:next, {:play, "welcome.wav"})
        end

        @impl true
        def handle_play_complete("welcome.wav", call) do
          call
          |> Map.put(:next, {:collect_dtmf, max_digits: 4, timeout: 5000})
        end

        @impl true
        def handle_dtmf(digits, call) when is_binary(digits) do
          call
          |> Map.put(:next, {:hangup, :normal})
        end

        def handle_dtmf(:timeout, call) do
          call
          |> Map.put(:next, {:play, "timeout.wav"})
        end
      end

  ## Call Map

  The `call` map is passed through all callbacks and contains call state.
  Handlers can add custom keys for application-specific state.

  Reserved keys include:
  - `:dialog_id` - The SIP dialog identifier
  - `:caller` - Caller information from the From header
  - `:called` - Called number from the Request-URI
  - `:next` - The next action to perform (set by handler)

  ## Return Values

  Most callbacks return either:
  - `map()` - Updated call map, potentially with `:next` action
  - `{:noreply, map()}` - Updated call map with no automatic action

  The `handle_invite/1` callback must return a `map()`.
  """

  # Type definitions

  @typedoc """
  The call state map passed through all callbacks.

  Contains call metadata and can include custom application state.
  """
  @type call :: map()

  @typedoc """
  Result of a bridge attempt.
  """
  @type bridge_result :: :answered | {:failed, term()}

  @typedoc """
  Result of a fork/dial attempt.
  """
  @type fork_result :: {:answered, term()} | :no_answer

  @typedoc """
  Standard callback return - either updated call map or noreply tuple.
  """
  @type callback_return :: call() | {:noreply, call()}

  # Required callback

  @doc """
  Called when an INVITE request is received.

  This is the entry point for handling an incoming call. The handler should
  return a call map, optionally with a `:next` key indicating the first action
  to perform (e.g., answer, play audio, collect DTMF).

  ## Parameters

  - `invite` - Map containing INVITE request information including:
    - `:dialog_id` - The SIP dialog identifier
    - `:caller` - Caller information
    - `:called` - Called number/URI
    - `:headers` - SIP headers from the request

  ## Returns

  A call map that will be passed to subsequent callbacks.
  """
  @callback handle_invite(invite :: map()) :: map()

  # Optional callbacks

  @doc """
  Called when audio playback completes.

  Invoked after a `play` operation finishes. The handler can decide
  what action to take next based on which file completed.

  ## Parameters

  - `filename` - The audio file that finished playing
  - `call` - Current call state

  ## Returns

  Updated call map or `{:noreply, call}` to take no automatic action.
  """
  @callback handle_play_complete(filename :: String.t(), call :: map()) ::
              callback_return()

  @doc """
  Called when DTMF digits are collected or a timeout occurs.

  Invoked after a `collect_dtmf` operation completes, either because
  the requested digits were collected or a timeout occurred.

  ## Parameters

  - `digits` - The collected DTMF digits as a string, or `:timeout`
  - `call` - Current call state

  ## Returns

  Updated call map or `{:noreply, call}` to take no automatic action.
  """
  @callback handle_dtmf(digits :: String.t() | :timeout, call :: map()) ::
              callback_return()

  @doc """
  Called when a bridged call completes.

  Invoked after a `bridge` operation ends, either because the remote
  party answered and then hung up, or because the bridge attempt failed.

  ## Parameters

  - `result` - Either `:answered` (call was connected) or `{:failed, reason}`
  - `call` - Current call state

  ## Returns

  Updated call map or `{:noreply, call}` to take no automatic action.
  """
  @callback handle_bridge_complete(
              result :: bridge_result(),
              call :: map()
            ) :: callback_return()

  @doc """
  Called when a forked dial attempt completes.

  Invoked after a `fork` or parallel dial operation completes. This is used
  when dialing multiple destinations simultaneously.

  ## Parameters

  - `result` - Either `{:answered, winner_info}` or `:no_answer`
  - `call` - Current call state

  ## Returns

  Updated call map or `{:noreply, call}` to take no automatic action.
  """
  @callback handle_fork_complete(
              result :: fork_result(),
              call :: map()
            ) :: callback_return()

  @doc """
  Called when a recording completes.

  Invoked after a `record` operation finishes, either due to silence
  detection, max duration, or DTMF termination.

  ## Parameters

  - `filename` - Path to the recorded audio file
  - `duration_ms` - Duration of the recording in milliseconds
  - `call` - Current call state

  ## Returns

  Updated call map or `{:noreply, call}` to take no automatic action.
  """
  @callback handle_record_complete(
              filename :: String.t(),
              duration_ms :: non_neg_integer(),
              call :: map()
            ) :: callback_return()

  @doc """
  Called when the caller hangs up.

  Invoked when a BYE request is received from the caller. This allows
  the handler to perform cleanup or logging.

  ## Parameters

  - `call` - Current call state

  ## Returns

  Must return `{:noreply, call}` as no further actions are possible.
  """
  @callback handle_hangup(call :: map()) :: {:noreply, map()}

  # Mark optional callbacks
  @optional_callbacks [
    handle_play_complete: 2,
    handle_dtmf: 2,
    handle_bridge_complete: 2,
    handle_fork_complete: 2,
    handle_record_complete: 3,
    handle_hangup: 1
  ]
end
