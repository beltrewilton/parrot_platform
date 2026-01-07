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
        use Parrot.InviteHandler

        @impl true
        def handle_invite(call) do
          call
          |> answer()
          |> play("welcome.wav")
        end

        @impl true
        def handle_play_complete("welcome.wav", call) do
          call
          |> collect_dtmf(max: 4, timeout: 5000)
        end

        @impl true
        def handle_dtmf(digits, call) when is_binary(digits) do
          call |> hangup()
        end

        def handle_dtmf(:timeout, call) do
          call |> play("timeout.wav")
        end
      end

  ## Call Map

  The `call` map is passed through all callbacks and contains call state.
  Handlers can add custom keys for application-specific state using `assign/3`.

  ## Return Values

  Most callbacks return either:
  - `map()` - Updated call map with pipeline operations
  - `{:noreply, map()}` - Updated call map with no automatic action

  The `handle_invite/1` callback must return a `map()`.
  """

  @typedoc "The call state map passed through all callbacks."
  @type call :: map()

  @typedoc "Result of a bridge attempt."
  @type bridge_result :: :answered | {:failed, term()}

  @typedoc "Result of a fork/dial attempt."
  @type fork_result :: {:answered, term()} | :no_answer

  @typedoc "Standard callback return - either updated call map or noreply tuple."
  @type callback_return :: call() | {:noreply, call()}

  # Required callback

  @doc """
  Called when an INVITE request is received.

  This is the entry point for handling an incoming call.

  ## Parameters

  - `invite` - Map containing INVITE request information

  ## Returns

  A call map that will be passed to subsequent callbacks.
  """
  @callback handle_invite(invite :: map()) :: map()

  # Optional callbacks

  @doc """
  Called when audio playback completes.

  ## Parameters

  - `filename` - The audio file that finished playing
  - `call` - Current call state

  ## Returns

  Updated call map or `{:noreply, call}` to take no automatic action.
  """
  @callback handle_play_complete(filename :: String.t(), call :: map()) :: callback_return()

  @doc """
  Called when DTMF digits are collected or a timeout occurs.

  ## Parameters

  - `digits` - The collected DTMF digits as a string, or `:timeout`
  - `call` - Current call state

  ## Returns

  Updated call map or `{:noreply, call}` to take no automatic action.
  """
  @callback handle_dtmf(digits :: String.t() | :timeout, call :: map()) :: callback_return()

  @doc "Called when a prompt (play + collect DTMF) operation completes."
  @callback handle_prompt_complete(
              filename :: String.t(),
              digits :: String.t() | :timeout,
              call :: map()
            ) :: callback_return()

  @doc """
  Called when a bridged call completes.

  ## Parameters

  - `result` - Either `:answered` or `{:failed, reason}`
  - `call` - Current call state

  ## Returns

  Updated call map or `{:noreply, call}` to take no automatic action.
  """
  @callback handle_bridge_complete(result :: bridge_result(), call :: map()) :: callback_return()

  @doc """
  Called when a forked dial attempt completes.

  ## Parameters

  - `result` - Either `{:answered, winner_info}` or `:no_answer`
  - `call` - Current call state

  ## Returns

  Updated call map or `{:noreply, call}` to take no automatic action.
  """
  @callback handle_fork_complete(result :: fork_result(), call :: map()) :: callback_return()

  @doc """
  Called when a recording completes.

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

  @doc "Called when the participant joins a conference room."
  @callback handle_conference_join(room :: String.t(), call :: map()) :: callback_return()

  @doc "Called when the participant leaves a conference room."
  @callback handle_conference_leave(
              room :: String.t(),
              reason :: :normal | :kicked | :ended | term(),
              call :: map()
            ) :: callback_return()

  @doc "Called when a media fork WebSocket connection is established."
  @callback handle_fork_media_connected(url :: String.t(), call :: map()) :: callback_return()

  @doc """
  Called when the caller hangs up.

  ## Parameters

  - `call` - Current call state

  ## Returns

  Must return `{:noreply, call}` as no further actions are possible.
  """
  @callback handle_hangup(call :: map()) :: {:noreply, map()}

  @optional_callbacks [
    handle_prompt_complete: 3,
    handle_conference_join: 2,
    handle_conference_leave: 3,
    handle_fork_media_connected: 2,
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

      @doc false
      def handle_play_complete(_filename, call), do: {:noreply, call}

      @doc false
      def handle_dtmf(_digits, call), do: {:noreply, call}

      @doc false
      def handle_prompt_complete(_filename, _digits, call), do: {:noreply, call}

      @doc false
      def handle_bridge_complete(_result, call), do: {:noreply, call}

      @doc false
      def handle_fork_complete(_result, call), do: {:noreply, call}

      @doc false
      def handle_record_complete(_filepath, _duration, call), do: {:noreply, call}

      @doc false
      def handle_conference_join(_room, call), do: {:noreply, call}

      @doc false
      def handle_conference_leave(_room, _reason, call), do: {:noreply, call}

      @doc false
      def handle_fork_media_connected(_url, call), do: {:noreply, call}

      @doc false
      def handle_hangup(call), do: {:noreply, call}

      defoverridable handle_play_complete: 2,
                     handle_dtmf: 2,
                     handle_prompt_complete: 3,
                     handle_bridge_complete: 2,
                     handle_fork_complete: 2,
                     handle_record_complete: 3,
                     handle_conference_join: 2,
                     handle_conference_leave: 3,
                     handle_fork_media_connected: 2,
                     handle_hangup: 1
    end
  end

  # Pipeline operations

  @doc "Answer the call."
  @spec answer(call()) :: call()
  def answer(call), do: Map.put(call, :__answered__, true)

  @spec answer(call(), keyword()) :: call()
  def answer(call, opts) when is_list(opts) do
    call |> Map.put(:__answered__, true) |> Map.put(:__answer_opts__, opts)
  end

  @doc "Reject the call with a SIP status code."
  @spec reject(call(), integer()) :: call()
  def reject(call, status_code) when is_integer(status_code) do
    Map.put(call, :__rejected__, status_code)
  end

  @doc "End the call."
  @spec hangup(call()) :: call()
  def hangup(call), do: Map.put(call, :__hangup__, true)

  @doc "Store a value in the call's assigns."
  @spec assign(call(), atom(), term()) :: call()
  def assign(call, key, value) when is_atom(key) do
    assigns = Map.get(call, :assigns, %{})
    Map.put(call, :assigns, Map.put(assigns, key, value))
  end

  @doc "Play an audio file or sequence of files."
  @spec play(call(), String.t() | [String.t()]) :: call()
  def play(call, file) when is_binary(file), do: Map.put(call, :__play__, [file])
  def play(call, files) when is_list(files), do: Map.put(call, :__play__, files)

  @spec play(call(), String.t() | [String.t()], keyword()) :: call()
  def play(call, file, opts) when is_binary(file) and is_list(opts) do
    call |> Map.put(:__play__, [file]) |> Map.put(:__play_opts__, opts)
  end

  def play(call, files, opts) when is_list(files) and is_list(opts) do
    call |> Map.put(:__play__, files) |> Map.put(:__play_opts__, opts)
  end

  @doc "Start recording the call."
  @spec record(call(), String.t()) :: call()
  def record(call, filepath) when is_binary(filepath), do: Map.put(call, :__record__, filepath)

  @spec record(call(), String.t(), keyword()) :: call()
  def record(call, filepath, opts) when is_binary(filepath) and is_list(opts) do
    call |> Map.put(:__record__, filepath) |> Map.put(:__record_opts__, opts)
  end

  @doc "Stop the current recording."
  @spec stop_record(call()) :: call()
  def stop_record(call), do: Map.put(call, :__stop_record__, true)

  @doc "Start collecting DTMF digits."
  @spec collect_dtmf(call(), keyword()) :: call()
  def collect_dtmf(call, opts) when is_list(opts), do: Map.put(call, :__collect_dtmf__, opts)

  @doc "Bridge the call to a destination."
  @spec bridge(call(), String.t()) :: call()
  def bridge(call, dest) when is_binary(dest), do: Map.put(call, :__bridge__, dest)

  @spec bridge(call(), String.t(), keyword()) :: call()
  def bridge(call, dest, opts) when is_binary(dest) and is_list(opts) do
    call |> Map.put(:__bridge__, dest) |> Map.put(:__bridge_opts__, opts)
  end

  @doc "Fork the call to multiple destinations."
  @spec fork(call(), [{String.t(), keyword()}]) :: call()
  def fork(call, dests) when is_list(dests), do: Map.put(call, :__fork__, dests)

  @spec fork(call(), [{String.t(), keyword()}], keyword()) :: call()
  def fork(call, dests, opts) when is_list(dests) and is_list(opts) do
    call |> Map.put(:__fork__, dests) |> Map.put(:__fork_opts__, opts)
  end
end
