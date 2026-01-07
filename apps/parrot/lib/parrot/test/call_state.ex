defmodule Parrot.Test.CallState do
  @moduledoc """
  Call state structure for testing Parrot DSL handlers.

  This module provides a test-focused representation of call state that tracks
  all actions performed during a call flow. It's used by the test simulation
  infrastructure to verify handler behavior without requiring actual SIP/media
  infrastructure.

  ## Fields

  * `:id` - Unique call identifier
  * `:from` - SIP From URI
  * `:to` - SIP To URI
  * `:assigns` - User-defined state (similar to Plug.Conn.assigns)
  * `:actions` - List of actions performed (plays, bridges, etc.)
  * `:status` - Current call status (:ringing, :answered, :hangup)
  * `:handler` - The handler module being tested
  * `:pending_action` - Current action awaiting completion (e.g., play in progress)

  ## Example

      call = %Parrot.Test.CallState{
        id: "test-123",
        from: "sip:alice@example.com",
        to: "sip:100@local",
        assigns: %{menu: :main},
        actions: [{:play, "welcome.wav"}],
        status: :answered
      }

  """

  @type status :: :ringing | :answered | :rejected | :hangup

  @type action ::
          {:play, String.t()}
          | {:play, String.t(), keyword()}
          | {:bridge, String.t()}
          | {:bridge, String.t(), keyword()}
          | {:collect_dtmf, keyword()}
          | {:prompt, String.t(), keyword()}
          | {:record, String.t()}
          | {:record, String.t(), keyword()}
          | :stop_record
          | :hangup
          | :answer
          | {:reject, integer()}
          | :hold
          | :resume
          | {:mute, :tx | :rx}
          | {:unmute, :tx | :rx}
          | {:join_conference, String.t()}
          | {:join_conference, String.t(), keyword()}
          | {:fork_media, String.t()}
          | {:fork_media, String.t(), keyword()}

  @type t :: %__MODULE__{
          id: String.t(),
          from: String.t(),
          to: String.t(),
          assigns: map(),
          actions: [action()],
          status: status(),
          handler: module() | nil,
          pending_action: action() | nil
        }

  defstruct id: nil,
            from: "sip:test@example.com",
            to: "sip:100@local",
            assigns: %{},
            actions: [],
            status: :ringing,
            handler: nil,
            pending_action: nil

  @doc """
  Creates a new call state with the given options.

  ## Options

  * `:id` - Call ID (default: auto-generated UUID)
  * `:from` - From URI (default: "sip:test@example.com")
  * `:to` - To URI (default: "sip:100@local")
  * `:assigns` - Initial assigns map (default: %{})
  * `:status` - Initial status (default: :ringing)
  * `:handler` - Handler module to use

  ## Examples

      iex> call = Parrot.Test.CallState.new()
      iex> call.from
      "sip:test@example.com"

      iex> call = Parrot.Test.CallState.new(from: "sip:alice@example.com", assigns: %{menu: :main})
      iex> call.assigns
      %{menu: :main}

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    id = Keyword.get(opts, :id, generate_id())

    %__MODULE__{
      id: id,
      from: Keyword.get(opts, :from, "sip:test@example.com"),
      to: Keyword.get(opts, :to, "sip:100@local"),
      assigns: Keyword.get(opts, :assigns, %{}),
      status: Keyword.get(opts, :status, :ringing),
      handler: Keyword.get(opts, :handler),
      actions: [],
      pending_action: nil
    }
  end

  @doc """
  Records an action on the call state.

  Actions are stored in reverse order (newest first) for efficient appending.
  Use `get_actions/1` to get actions in chronological order.
  """
  @spec record_action(t(), action()) :: t()
  def record_action(%__MODULE__{} = call, action) do
    %{call | actions: [action | call.actions]}
  end

  @doc """
  Returns all actions in chronological order.
  """
  @spec get_actions(t()) :: [action()]
  def get_actions(%__MODULE__{actions: actions}) do
    Enum.reverse(actions)
  end

  @doc """
  Checks if a specific action was performed.

  Supports exact matching and pattern matching with regexes for filenames.
  """
  @spec has_action?(t(), action() | Regex.t() | {atom(), Regex.t()}) :: boolean()
  def has_action?(%__MODULE__{} = call, %Regex{} = regex) do
    # Match any play action with a filename matching the regex
    call.actions
    |> Enum.any?(fn
      {:play, filename} when is_binary(filename) -> Regex.match?(regex, filename)
      {:play, filename, _opts} when is_binary(filename) -> Regex.match?(regex, filename)
      _ -> false
    end)
  end

  def has_action?(%__MODULE__{} = call, {:play, %Regex{} = regex}) do
    has_action?(call, regex)
  end

  def has_action?(%__MODULE__{} = call, {:bridge, %Regex{} = regex}) do
    call.actions
    |> Enum.any?(fn
      {:bridge, target} when is_binary(target) -> Regex.match?(regex, target)
      {:bridge, target, _opts} when is_binary(target) -> Regex.match?(regex, target)
      _ -> false
    end)
  end

  def has_action?(%__MODULE__{actions: actions}, action) do
    Enum.member?(actions, action)
  end

  @doc """
  Updates the assigns map with a new key-value pair.
  """
  @spec put_assign(t(), atom(), any()) :: t()
  def put_assign(%__MODULE__{assigns: assigns} = call, key, value) do
    %{call | assigns: Map.put(assigns, key, value)}
  end

  @doc """
  Gets a value from the assigns map.
  """
  @spec get_assign(t(), atom(), any()) :: any()
  def get_assign(%__MODULE__{assigns: assigns}, key, default \\ nil) do
    Map.get(assigns, key, default)
  end

  @doc """
  Sets the pending action (action waiting for completion callback).
  """
  @spec set_pending_action(t(), action()) :: t()
  def set_pending_action(%__MODULE__{} = call, action) do
    %{call | pending_action: action}
  end

  @doc """
  Clears the pending action.
  """
  @spec clear_pending_action(t()) :: t()
  def clear_pending_action(%__MODULE__{} = call) do
    %{call | pending_action: nil}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
