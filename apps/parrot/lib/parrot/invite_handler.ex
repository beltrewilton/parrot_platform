defmodule Parrot.InviteHandler do
  @moduledoc """
  Behaviour for handling incoming INVITE requests in Parrot VoIP applications.

  The InviteHandler provides a declarative, pipeline-based API for building
  call handling logic. Implement this behaviour to define how your application
  responds to incoming calls, DTMF input, and various call events.

  ## Usage

  Use `use Parrot.InviteHandler` in your module to get default implementations
  of all callbacks and import `Parrot.Call` functions for building pipelines:

      defmodule MyApp.IVRHandler do
        use Parrot.InviteHandler

        def handle_invite(invite) do
          invite
          |> answer()
          |> assign(:menu, :main)
          |> play("welcome.wav")
        end

        def handle_dtmf("1", %{assigns: %{menu: :main}} = call) do
          call
          |> assign(:menu, :sales)
          |> bridge("sip:sales@internal")
        end

        def handle_dtmf("2", %{assigns: %{menu: :main}} = call) do
          call
          |> assign(:menu, :support)
          |> bridge("sip:support@internal")
        end

        def handle_dtmf(_digit, call) do
          call |> play("invalid-option.wav")
        end
      end

  ## Callbacks

  All callbacks receive a `Parrot.Call` struct and should return either:
  - A `Parrot.Call` struct with operations queued (for most handlers)
  - `{:noreply, call}` for event handlers that don't queue operations

  ### Required Callbacks

  - `handle_invite/1` - Called when an INVITE is received. Must be implemented.

  ### Optional Callbacks (with defaults)

  All other callbacks have default implementations that return `{:noreply, call}`.
  Override only the ones you need:

  - `handle_play_complete/2` - Called when audio playback finishes
  - `handle_dtmf/2` - Called when DTMF digits are received or timeout occurs
  - `handle_prompt_complete/3` - Called when play+collect completes
  - `handle_bridge_complete/2` - Called when a bridge attempt completes
  - `handle_fork_complete/2` - Called when a fork attempt completes
  - `handle_record_complete/3` - Called when recording finishes
  - `handle_conference_join/2` - Called when joining a conference
  - `handle_conference_leave/3` - Called when leaving a conference
  - `handle_fork_media_connected/2` - Called when media fork establishes
  - `handle_hangup/1` - Called when the call ends
  """

  alias Parrot.Call

  @doc """
  Called when an INVITE request is received.

  This is the entry point for call handling. Return a `Call` struct with
  operations queued to define how the call should be processed.

  ## Example

      def handle_invite(invite) do
        invite
        |> answer()
        |> play("welcome.wav")
      end
  """
  @callback handle_invite(call :: Call.t()) :: Call.t()

  @doc """
  Called when audio playback completes.

  ## Arguments

  - `filename` - The file that finished playing
  - `call` - The current call state

  ## Return

  Return `{:noreply, call}` or a `Call` struct with new operations.
  """
  @callback handle_play_complete(filename :: String.t(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when DTMF digits are received or collection times out.

  ## Arguments

  - `digits_or_timeout` - The collected digits as a string, or `:timeout`
  - `call` - The current call state

  ## Example

      def handle_dtmf("1", call), do: call |> play("option-one.wav")
      def handle_dtmf(:timeout, call), do: call |> play("goodbye.wav") |> hangup()
  """
  @callback handle_dtmf(digits_or_timeout :: String.t() | :timeout, call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when a prompt (play + collect) completes.

  ## Arguments

  - `filename` - The prompt file that was played
  - `digits` - The collected DTMF digits
  - `call` - The current call state
  """
  @callback handle_prompt_complete(filename :: String.t(), digits :: String.t(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when a bridge attempt completes.

  ## Arguments

  - `result` - The bridge result:
    - `:answered` - B-leg answered
    - `{:failed, reason}` - Bridge failed with reason (`:busy`, `:no_answer`, etc.)
  - `call` - The current call state
  """
  @callback handle_bridge_complete(result :: :answered | {:failed, atom()}, call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when a fork attempt completes.

  ## Arguments

  - `result` - The fork result:
    - `{:answered, destination}` - Which destination answered
    - `{:failed, reason}` - All destinations failed
  - `call` - The current call state
  """
  @callback handle_fork_complete(
              result :: {:answered, String.t()} | {:failed, atom()},
              call :: Call.t()
            ) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when recording completes.

  ## Arguments

  - `filename` - The recording file path
  - `duration` - Recording duration in milliseconds
  - `call` - The current call state
  """
  @callback handle_record_complete(
              filename :: String.t(),
              duration :: non_neg_integer(),
              call :: Call.t()
            ) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when the call joins a conference.

  ## Arguments

  - `room` - The conference room identifier
  - `call` - The current call state
  """
  @callback handle_conference_join(room :: String.t(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when the call leaves a conference.

  ## Arguments

  - `room` - The conference room identifier
  - `reason` - Why the call left (`:normal`, `:kicked`, etc.)
  - `call` - The current call state
  """
  @callback handle_conference_leave(room :: String.t(), reason :: atom(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when a media fork connection is established.

  ## Arguments

  - `url` - The URL of the connected media service
  - `call` - The current call state
  """
  @callback handle_fork_media_connected(url :: String.t(), call :: Call.t()) ::
              {:noreply, Call.t()} | Call.t()

  @doc """
  Called when the call ends.

  Use this for cleanup logic like updating presence or logging.

  ## Arguments

  - `call` - The final call state
  """
  @callback handle_hangup(call :: Call.t()) :: {:noreply, Call.t()} | Call.t()

  @doc """
  Provides default implementations and imports Call functions.

  When you `use Parrot.InviteHandler`, you get:

  1. Default implementations of all callbacks (returning `{:noreply, call}`)
  2. Import of all `Parrot.Call` functions for pipeline operations
  3. The `@behaviour Parrot.InviteHandler` annotation

  Override any callback by defining it in your module.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Parrot.InviteHandler

      import Parrot.Call,
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
          prompt: 3,
          bridge: 2,
          bridge: 3,
          fork: 2,
          fork: 3,
          fork_media: 2,
          fork_media: 3,
          stop_fork_media: 2
        ]

      @impl Parrot.InviteHandler
      def handle_play_complete(_filename, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_dtmf(_digits_or_timeout, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_prompt_complete(_filename, _digits, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_bridge_complete(_result, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_fork_complete(_result, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_record_complete(_filename, _duration, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_conference_join(_room, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_conference_leave(_room, _reason, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_fork_media_connected(_url, call) do
        {:noreply, call}
      end

      @impl Parrot.InviteHandler
      def handle_hangup(call) do
        {:noreply, call}
      end

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
end
