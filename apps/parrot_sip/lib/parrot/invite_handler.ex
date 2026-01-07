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

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Parrot.InviteHandler

      # Import pipeline operations
      import Parrot.InviteHandler,
        only: [
          answer: 1,
          answer: 2,
          reject: 2,
          hangup: 1,
          assign: 3,
          play: 2,
          play: 3,
          record: 2,
          record: 3,
          stop_record: 1,
          collect_dtmf: 2,
          bridge: 2,
          bridge: 3,
          fork: 2,
          fork: 3
        ]

      # Default implementations for optional callbacks

      @doc false
      def handle_play_complete(_filename, call) do
        {:noreply, call}
      end

      @doc false
      def handle_dtmf(_digits_or_timeout, call) do
        {:noreply, call}
      end

      @doc false
      def handle_bridge_complete(_result, call) do
        {:noreply, call}
      end

      @doc false
      def handle_fork_complete(_result, call) do
        {:noreply, call}
      end

      @doc false
      def handle_record_complete(_filepath, _duration, call) do
        {:noreply, call}
      end

      @doc false
      def handle_hangup(call) do
        {:noreply, call}
      end

      defoverridable handle_play_complete: 2,
                     handle_dtmf: 2,
                     handle_bridge_complete: 2,
                     handle_fork_complete: 2,
                     handle_record_complete: 3,
                     handle_hangup: 1
    end
  end

  # Pipeline operations - imported into handler modules via use macro

  @doc """
  Answer the call.

  Marks the call as answered. The framework will send a 200 OK response
  and establish the media session.

  ## Examples

      invite |> answer()
      invite |> answer(codecs: [:opus, :pcmu])
  """
  @spec answer(call()) :: call()
  def answer(call) do
    Map.put(call, :__answered__, true)
  end

  @spec answer(call(), keyword()) :: call()
  def answer(call, opts) when is_list(opts) do
    call
    |> Map.put(:__answered__, true)
    |> Map.put(:__answer_opts__, opts)
  end

  @doc """
  Reject the call with a SIP status code.

  ## Parameters

  - `call` - The call to reject
  - `status_code` - SIP status code (e.g., 486 for Busy Here)

  ## Examples

      invite |> reject(486)  # Busy Here
      invite |> reject(404)  # Not Found
      invite |> reject(603)  # Decline
  """
  @spec reject(call(), integer()) :: call()
  def reject(call, status_code) when is_integer(status_code) do
    Map.put(call, :__rejected__, status_code)
  end

  @doc """
  End the call.

  Marks the call for hangup. The framework will send BYE and clean up resources.

  ## Example

      call |> hangup()
  """
  @spec hangup(call()) :: call()
  def hangup(call) do
    Map.put(call, :__hangup__, true)
  end

  @doc """
  Store a value in the call's assigns.

  Assigns are user-defined key-value storage that persists across callbacks.

  ## Parameters

  - `call` - The call
  - `key` - Key to store under (atom)
  - `value` - Value to store

  ## Examples

      call |> assign(:menu, :main)
      call |> assign(:retries, 0)
  """
  @spec assign(call(), atom(), term()) :: call()
  def assign(call, key, value) when is_atom(key) do
    assigns = Map.get(call, :assigns, %{})
    Map.put(call, :assigns, Map.put(assigns, key, value))
  end

  @doc """
  Play an audio file or sequence of files.

  ## Parameters

  - `call` - The call
  - `file_or_files` - Single filename or list of filenames
  - `opts` - Options (optional)

  ## Options

  - `:loop` - If true, loop the playback continuously

  ## Examples

      call |> play("welcome.wav")
      call |> play(["menu.wav", "press-1.wav", "press-2.wav"])
      call |> play("hold-music.wav", loop: true)
  """
  @spec play(call(), String.t() | [String.t()]) :: call()
  def play(call, file) when is_binary(file) do
    Map.put(call, :__play__, [file])
  end

  def play(call, files) when is_list(files) do
    Map.put(call, :__play__, files)
  end

  @spec play(call(), String.t() | [String.t()], keyword()) :: call()
  def play(call, file, opts) when is_binary(file) and is_list(opts) do
    call
    |> Map.put(:__play__, [file])
    |> Map.put(:__play_opts__, opts)
  end

  def play(call, files, opts) when is_list(files) and is_list(opts) do
    call
    |> Map.put(:__play__, files)
    |> Map.put(:__play_opts__, opts)
  end

  @doc """
  Start recording the call.

  ## Parameters

  - `call` - The call
  - `filepath` - Path to save the recording
  - `opts` - Options (optional)

  ## Options

  - `:max_duration` - Maximum recording length in milliseconds
  - `:beep` - If true, play a beep before recording
  - `:terminators` - List of DTMF digits that stop recording (e.g., ["#"])

  ## Examples

      call |> record("/recordings/call-123.wav")
      call |> record("/recordings/voicemail.wav", max_duration: 120_000, beep: true)
  """
  @spec record(call(), String.t()) :: call()
  def record(call, filepath) when is_binary(filepath) do
    Map.put(call, :__record__, filepath)
  end

  @spec record(call(), String.t(), keyword()) :: call()
  def record(call, filepath, opts) when is_binary(filepath) and is_list(opts) do
    call
    |> Map.put(:__record__, filepath)
    |> Map.put(:__record_opts__, opts)
  end

  @doc """
  Stop the current recording.

  ## Example

      call |> stop_record()
  """
  @spec stop_record(call()) :: call()
  def stop_record(call) do
    Map.put(call, :__stop_record__, true)
  end

  @doc """
  Start collecting DTMF digits.

  The `handle_dtmf/2` callback will be invoked with the collected digits
  or `:timeout`.

  ## Parameters

  - `call` - The call
  - `opts` - Collection options

  ## Options

  - `:max` - Maximum digits to collect
  - `:timeout` - Timeout in milliseconds
  - `:terminators` - List of digits that end collection (e.g., ["#"])

  ## Examples

      call |> collect_dtmf(max: 4, timeout: 5_000)
      call |> collect_dtmf(max: 16, terminators: ["#"], timeout: 30_000)
  """
  @spec collect_dtmf(call(), keyword()) :: call()
  def collect_dtmf(call, opts) when is_list(opts) do
    Map.put(call, :__collect_dtmf__, opts)
  end

  @doc """
  Bridge the call to a destination.

  Creates an outbound call to the destination and bridges audio.
  The `handle_bridge_complete/2` callback will be invoked with the result.

  ## Parameters

  - `call` - The call
  - `destination` - SIP URI to call
  - `opts` - Options (optional)

  ## Options

  - `:timeout` - Ring timeout in milliseconds
  - `:headers` - Custom SIP headers (map)
  - `:handler` - B-leg handler module (for advanced control)

  ## Examples

      call |> bridge("sip:bob@internal")
      call |> bridge("sip:external@carrier", timeout: 30_000)
  """
  @spec bridge(call(), String.t()) :: call()
  def bridge(call, destination) when is_binary(destination) do
    Map.put(call, :__bridge__, destination)
  end

  @spec bridge(call(), String.t(), keyword()) :: call()
  def bridge(call, destination, opts) when is_binary(destination) and is_list(opts) do
    call
    |> Map.put(:__bridge__, destination)
    |> Map.put(:__bridge_opts__, opts)
  end

  @doc """
  Fork the call to multiple destinations.

  Calls multiple destinations simultaneously. The first to answer wins
  (with `:first_answer` strategy).

  The `handle_fork_complete/2` callback will be invoked with the result.

  ## Parameters

  - `call` - The call
  - `destinations` - List of `{uri, opts}` tuples
  - `opts` - Fork options (optional)

  ## Options

  - `:strategy` - `:first_answer` (default) or `:ring_all`
  - `:timeout` - Total ring timeout in milliseconds

  ## Examples

      destinations = [
        {"sip:alice@device1", []},
        {"sip:alice@device2", []}
      ]
      call |> fork(destinations)
      call |> fork(destinations, strategy: :first_answer, timeout: 30_000)
  """
  @spec fork(call(), [{String.t(), keyword()}]) :: call()
  def fork(call, destinations) when is_list(destinations) do
    Map.put(call, :__fork__, destinations)
  end

  @spec fork(call(), [{String.t(), keyword()}], keyword()) :: call()
  def fork(call, destinations, opts) when is_list(destinations) and is_list(opts) do
    call
    |> Map.put(:__fork__, destinations)
    |> Map.put(:__fork_opts__, opts)
  end
end
