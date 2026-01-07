defmodule Parrot.BLeg do
  @moduledoc """
  Represents the B-leg (outbound leg) of a bridged call.

  The BLeg struct tracks the state of the outbound call when bridging
  from an A-leg (incoming call) to a B-leg (outbound destination).

  ## Fields

  * `:id` - Unique identifier for this B-leg
  * `:destination` - The SIP URI of the destination
  * `:state` - Current B-leg state (`:init`, `:trying`, `:ringing`, `:early_media`, `:answered`, `:terminated`)
  * `:dialog_id` - SIP dialog ID once established
  * `:assigns` - Per-bleg state storage (map)

  ## Example

      bleg = BLeg.new(destination: "sip:bob@example.com")
      bleg = BLeg.assign(bleg, :custom_data, "value")

  """

  @type bleg_state :: :init | :trying | :ringing | :early_media | :answered | :terminated

  @type t :: %__MODULE__{
          id: String.t() | nil,
          destination: String.t() | nil,
          state: bleg_state(),
          dialog_id: String.t() | nil,
          assigns: map()
        }

  defstruct id: nil,
            destination: nil,
            state: :init,
            dialog_id: nil,
            assigns: %{}

  @doc """
  Creates a new BLeg struct from keyword options.

  ## Options

  * `:id` - Unique B-leg ID (auto-generated if not provided)
  * `:destination` - The SIP URI of the destination
  * `:state` - Initial state (defaults to `:init`)
  * `:dialog_id` - SIP dialog ID
  * `:assigns` - Initial assigns map

  ## Examples

      BLeg.new()
      BLeg.new(destination: "sip:bob@example.com")
      BLeg.new(destination: "sip:bob@example.com", assigns: %{priority: :high})

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id) || generate_id(),
      destination: Keyword.get(opts, :destination),
      state: Keyword.get(opts, :state, :init),
      dialog_id: Keyword.get(opts, :dialog_id),
      assigns: Keyword.get(opts, :assigns, %{})
    }
  end

  @doc """
  Generates a unique B-leg ID.

  ## Examples

      iex> id = Parrot.BLeg.generate_id()
      iex> is_binary(id) and String.length(id) > 0
      true
  """
  @spec generate_id() :: String.t()
  def generate_id do
    "bleg-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  @doc """
  Assigns a key-value pair to the B-leg's assigns map.

  Assigns are per-bleg state that persists for the duration of the B-leg.
  Use this to store custom data related to the outbound call.

  ## Examples

      bleg
      |> BLeg.assign(:original_caller, "sip:alice@example.com")
      |> BLeg.assign(:priority, :high)

  """
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{assigns: assigns} = bleg, key, value) when is_atom(key) do
    %{bleg | assigns: Map.put(assigns, key, value)}
  end
end
