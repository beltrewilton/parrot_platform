defmodule Parrot.Leg do
  @moduledoc """
  Represents a call leg in a B2BUA (Back-to-Back User Agent) session.

  A leg represents one side of a call - either the inbound (A-leg) or outbound
  (B-leg) direction. Each leg maintains its own SIP dialog, media session,
  and state throughout the call lifecycle.

  ## Fields

  * `:id` - Unique leg identifier (auto-generated or custom)
  * `:direction` - `:inbound` for A-leg, `:outbound` for B-leg
  * `:state` - Current leg state (see State Transitions below)
  * `:dialog_id` - Associated SIP dialog reference
  * `:media_pid` - MediaSession PID for this leg
  * `:remote_uri` - SIP URI of the remote party
  * `:local_uri` - Our SIP URI
  * `:sdp` - Current SDP (offer/answer)
  * `:created_at` - When the leg was created
  * `:answered_at` - When the leg was answered (nil until answered)
  * `:metadata` - User-defined key-value storage

  ## State Transitions

  The leg follows a strict state machine:

      init -> trying         (INVITE sent/received)
      trying -> ringing      (180 Ringing received)
      trying -> early_media  (183 Session Progress with SDP)
      trying -> answered     (200 OK received)
      ringing -> early_media (183 with SDP after ringing)
      ringing -> answered    (200 OK received)
      early_media -> answered (200 OK received)
      answered -> held       (hold requested)
      held -> answered       (resume requested)
      any -> terminated      (BYE or error)

  ## Examples

      # Create an inbound leg (A-leg)
      a_leg = Leg.new(direction: :inbound, remote_uri: "sip:alice@example.com")

      # Transition through states
      {:ok, leg} = Leg.transition(a_leg, :trying)
      {:ok, leg} = Leg.transition(leg, :ringing)
      {:ok, leg} = Leg.transition(leg, :answered)

      # Check state
      Leg.answered?(leg)  #=> true

      # Store custom metadata
      leg = Leg.assign(leg, :call_queue, "support")

  ## RFC References

  - RFC 3261 Section 16 - B2BUA patterns
  - RFC 5765 - B2BUA requirements
  """

  @type leg_id :: atom() | String.t()
  @type direction :: :inbound | :outbound
  @type state :: :init | :trying | :ringing | :early_media | :answered | :held | :terminated

  @type t :: %__MODULE__{
          id: leg_id() | nil,
          direction: direction() | nil,
          state: state(),
          dialog_id: String.t() | nil,
          media_pid: pid() | nil,
          remote_uri: String.t() | nil,
          local_uri: String.t() | nil,
          sdp: String.t() | nil,
          created_at: DateTime.t(),
          answered_at: DateTime.t() | nil,
          metadata: map()
        }

  defstruct id: nil,
            direction: nil,
            state: :init,
            dialog_id: nil,
            media_pid: nil,
            remote_uri: nil,
            local_uri: nil,
            sdp: nil,
            created_at: nil,
            answered_at: nil,
            metadata: %{}

  # Valid state transitions: from_state => [valid_target_states]
  @valid_transitions %{
    init: [:trying, :terminated],
    trying: [:ringing, :early_media, :answered, :terminated],
    ringing: [:early_media, :answered, :terminated],
    early_media: [:answered, :terminated],
    answered: [:answered, :held, :terminated],
    held: [:answered, :terminated],
    terminated: []
  }

  defmodule InvalidTransitionError do
    @moduledoc """
    Exception raised when attempting an invalid state transition.
    """
    defexception [:from_state, :to_state, :leg_id]

    @impl true
    def message(%{from_state: from, to_state: to, leg_id: id}) do
      "Invalid leg state transition from #{inspect(from)} to #{inspect(to)} for leg #{inspect(id)}"
    end
  end

  # ============================================================================
  # Constructor
  # ============================================================================

  @doc """
  Creates a new Leg struct with the given options.

  ## Options

  * `:id` - Custom leg ID (auto-generated if not provided)
  * `:direction` - `:inbound` or `:outbound`
  * `:state` - Initial state (defaults to `:init`)
  * `:dialog_id` - Associated SIP dialog ID
  * `:media_pid` - MediaSession PID
  * `:remote_uri` - Remote party's SIP URI
  * `:local_uri` - Local SIP URI
  * `:sdp` - Initial SDP
  * `:metadata` - Initial metadata map

  ## Examples

      Leg.new()
      Leg.new(direction: :inbound, remote_uri: "sip:alice@example.com")
      Leg.new(id: "custom-leg", direction: :outbound)

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id) || generate_id(),
      direction: Keyword.get(opts, :direction),
      state: Keyword.get(opts, :state, :init),
      dialog_id: Keyword.get(opts, :dialog_id),
      media_pid: Keyword.get(opts, :media_pid),
      remote_uri: Keyword.get(opts, :remote_uri),
      local_uri: Keyword.get(opts, :local_uri),
      sdp: Keyword.get(opts, :sdp),
      created_at: DateTime.utc_now(),
      answered_at: nil,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Generates a unique leg ID.

  ## Examples

      iex> id = Parrot.Leg.generate_id()
      iex> String.starts_with?(id, "leg-")
      true

  """
  @spec generate_id() :: String.t()
  def generate_id do
    "leg-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # ============================================================================
  # State Transitions
  # ============================================================================

  @doc """
  Attempts to transition the leg to a new state.

  Returns `{:ok, updated_leg}` if the transition is valid, or
  `{:error, :invalid_transition}` if not.

  When transitioning to `:answered`, the `answered_at` timestamp is set.

  ## Examples

      leg = Leg.new(state: :init)
      {:ok, leg} = Leg.transition(leg, :trying)
      {:ok, leg} = Leg.transition(leg, :answered)

      leg = Leg.new(state: :init)
      {:error, :invalid_transition} = Leg.transition(leg, :answered)

  """
  @spec transition(t(), state()) :: {:ok, t()} | {:error, :invalid_transition}
  def transition(%__MODULE__{state: current_state} = leg, target_state) do
    if valid_transition?(current_state, target_state) do
      {:ok, apply_transition(leg, target_state)}
    else
      {:error, :invalid_transition}
    end
  end

  @doc """
  Transitions the leg to a new state, raising on invalid transitions.

  Returns the updated leg or raises `Parrot.Leg.InvalidTransitionError`.

  ## Examples

      leg = Leg.new(state: :init)
      leg = Leg.transition!(leg, :trying)  # Returns updated leg

      leg = Leg.new(state: :init)
      Leg.transition!(leg, :answered)  # Raises InvalidTransitionError

  """
  @spec transition!(t(), state()) :: t()
  def transition!(%__MODULE__{} = leg, target_state) do
    case transition(leg, target_state) do
      {:ok, updated_leg} ->
        updated_leg

      {:error, :invalid_transition} ->
        raise InvalidTransitionError,
          from_state: leg.state,
          to_state: target_state,
          leg_id: leg.id
    end
  end

  @doc """
  Checks if a transition from the leg's current state to the target state is valid.

  ## Examples

      leg = Leg.new(state: :init)
      Leg.can_transition?(leg, :trying)     #=> true
      Leg.can_transition?(leg, :answered)   #=> false

  """
  @spec can_transition?(t(), state()) :: boolean()
  def can_transition?(%__MODULE__{state: current_state}, target_state) do
    valid_transition?(current_state, target_state)
  end

  @spec valid_transition?(state(), state()) :: boolean()
  defp valid_transition?(from_state, to_state) do
    to_state in Map.get(@valid_transitions, from_state, [])
  end

  @spec apply_transition(t(), state()) :: t()
  defp apply_transition(leg, :answered) do
    %{leg | state: :answered, answered_at: DateTime.utc_now()}
  end

  defp apply_transition(leg, target_state) do
    %{leg | state: target_state}
  end

  # ============================================================================
  # State Predicates
  # ============================================================================

  @doc "Returns true if the leg is in the `:init` state."
  @spec init?(t()) :: boolean()
  def init?(%__MODULE__{state: :init}), do: true
  def init?(%__MODULE__{}), do: false

  @doc "Returns true if the leg is in the `:trying` state."
  @spec trying?(t()) :: boolean()
  def trying?(%__MODULE__{state: :trying}), do: true
  def trying?(%__MODULE__{}), do: false

  @doc "Returns true if the leg is in the `:ringing` state."
  @spec ringing?(t()) :: boolean()
  def ringing?(%__MODULE__{state: :ringing}), do: true
  def ringing?(%__MODULE__{}), do: false

  @doc "Returns true if the leg is in the `:early_media` state."
  @spec early_media?(t()) :: boolean()
  def early_media?(%__MODULE__{state: :early_media}), do: true
  def early_media?(%__MODULE__{}), do: false

  @doc "Returns true if the leg is in the `:answered` state."
  @spec answered?(t()) :: boolean()
  def answered?(%__MODULE__{state: :answered}), do: true
  def answered?(%__MODULE__{}), do: false

  @doc "Returns true if the leg is in the `:held` state."
  @spec held?(t()) :: boolean()
  def held?(%__MODULE__{state: :held}), do: true
  def held?(%__MODULE__{}), do: false

  @doc "Returns true if the leg is in the `:terminated` state."
  @spec terminated?(t()) :: boolean()
  def terminated?(%__MODULE__{state: :terminated}), do: true
  def terminated?(%__MODULE__{}), do: false

  # ============================================================================
  # Direction Predicates
  # ============================================================================

  @doc "Returns true if the leg is an inbound leg (A-leg)."
  @spec inbound?(t()) :: boolean()
  def inbound?(%__MODULE__{direction: :inbound}), do: true
  def inbound?(%__MODULE__{}), do: false

  @doc "Returns true if the leg is an outbound leg (B-leg)."
  @spec outbound?(t()) :: boolean()
  def outbound?(%__MODULE__{direction: :outbound}), do: true
  def outbound?(%__MODULE__{}), do: false

  # ============================================================================
  # Compound State Predicates
  # ============================================================================

  @doc """
  Returns true if the leg is in an active (non-terminated) state.

  Active states: `:init`, `:trying`, `:ringing`, `:early_media`, `:answered`, `:held`

  ## Examples

      Leg.active?(Leg.new(state: :trying))     #=> true
      Leg.active?(Leg.new(state: :terminated)) #=> false

  """
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{state: :terminated}), do: false
  def active?(%__MODULE__{}), do: true

  @doc """
  Returns true if the leg has an established connection (answered or held).

  Connected states: `:answered`, `:held`

  ## Examples

      Leg.connected?(Leg.new(state: :answered)) #=> true
      Leg.connected?(Leg.new(state: :held))     #=> true
      Leg.connected?(Leg.new(state: :ringing))  #=> false

  """
  @spec connected?(t()) :: boolean()
  def connected?(%__MODULE__{state: :answered}), do: true
  def connected?(%__MODULE__{state: :held}), do: true
  def connected?(%__MODULE__{}), do: false

  # ============================================================================
  # Field Setters
  # ============================================================================

  @doc """
  Sets the dialog_id for the leg.

  ## Examples

      leg = Leg.new()
      leg = Leg.set_dialog_id(leg, "dialog-abc-123")

  """
  @spec set_dialog_id(t(), String.t()) :: t()
  def set_dialog_id(%__MODULE__{} = leg, dialog_id) when is_binary(dialog_id) do
    %{leg | dialog_id: dialog_id}
  end

  @doc """
  Sets the media_pid for the leg.

  ## Examples

      leg = Leg.new()
      leg = Leg.set_media_pid(leg, media_session_pid)

  """
  @spec set_media_pid(t(), pid()) :: t()
  def set_media_pid(%__MODULE__{} = leg, media_pid) when is_pid(media_pid) do
    %{leg | media_pid: media_pid}
  end

  @doc """
  Sets the SDP for the leg.

  ## Examples

      leg = Leg.new()
      leg = Leg.set_sdp(leg, "v=0\\r\\no=- 123 456 IN IP4 192.168.1.1\\r\\n")

  """
  @spec set_sdp(t(), String.t()) :: t()
  def set_sdp(%__MODULE__{} = leg, sdp) when is_binary(sdp) do
    %{leg | sdp: sdp}
  end

  # ============================================================================
  # Metadata (Assigns)
  # ============================================================================

  @doc """
  Assigns a key-value pair to the leg's metadata.

  Metadata is per-leg state that persists for the duration of the leg.
  Use this to store custom data related to the call leg.

  ## Examples

      leg
      |> Leg.assign(:original_caller, "sip:alice@example.com")
      |> Leg.assign(:priority, :high)
      |> Leg.assign(:department, "sales")

  """
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{metadata: metadata} = leg, key, value) when is_atom(key) do
    %{leg | metadata: Map.put(metadata, key, value)}
  end

  # ============================================================================
  # Duration Calculation
  # ============================================================================

  @doc """
  Returns the call duration in seconds since the leg was answered.

  Returns `nil` if the leg has not been answered yet (no `answered_at` timestamp).

  ## Examples

      leg = Leg.new(state: :trying)
      Leg.duration(leg)  #=> nil

      {:ok, leg} = Leg.transition(leg, :answered)
      Process.sleep(1000)
      Leg.duration(leg)  #=> ~1 (approximately 1 second)

  """
  @spec duration(t()) :: non_neg_integer() | nil
  def duration(%__MODULE__{answered_at: nil}), do: nil

  def duration(%__MODULE__{answered_at: answered_at}) do
    DateTime.diff(DateTime.utc_now(), answered_at, :second)
  end
end
