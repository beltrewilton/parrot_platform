defmodule ParrotMedia.MOS.Event do
  @moduledoc """
  Represents a MOS quality event, typically a threshold crossing.

  Events are created when the MOS score crosses a configured quality
  threshold, indicating a change in call quality.

  ## Fields

  - `:type` - Event type, currently only `:threshold_crossed`
  - `:session_id` - The media session identifier
  - `:mos` - The MOS score that triggered the event (1.0-5.0)
  - `:threshold` - The threshold that was crossed (atom like :excellent, :good, :fair)
  - `:direction` - Direction of the crossing (:rising or :falling)
  - `:timestamp` - When the event occurred

  ## Example

      {:ok, event} = Event.new(
        type: :threshold_crossed,
        session_id: "call-123",
        mos: 3.4,
        threshold: :good,
        direction: :falling,
        timestamp: DateTime.utc_now()
      )
  """

  @type t :: %__MODULE__{
          type: :threshold_crossed,
          session_id: String.t(),
          mos: float(),
          threshold: atom(),
          direction: :rising | :falling,
          timestamp: DateTime.t()
        }

  @enforce_keys [:type, :session_id, :mos, :threshold, :direction, :timestamp]
  defstruct [:type, :session_id, :mos, :threshold, :direction, :timestamp]

  @valid_types [:threshold_crossed]
  @valid_directions [:rising, :falling]

  @doc """
  Creates a new Event from keyword options.

  ## Required Fields

  - `:type` - Must be `:threshold_crossed`
  - `:session_id` - Non-nil string session identifier
  - `:mos` - MOS score (1.0-5.0)
  - `:threshold` - Threshold name (atom)
  - `:direction` - `:rising` or `:falling`
  - `:timestamp` - DateTime when event occurred

  ## Returns

  - `{:ok, event}` on success
  - `{:error, reason}` on validation failure

  ## Examples

      iex> Event.new(type: :threshold_crossed, session_id: "call-123", mos: 3.4, threshold: :good, direction: :falling, timestamp: DateTime.utc_now())
      {:ok, %Event{...}}

      iex> Event.new(type: :invalid, session_id: "call-123", mos: 3.4, threshold: :good, direction: :down, timestamp: DateTime.utc_now())
      {:error, :invalid_type}
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with {:ok, type} <- validate_type(opts),
         {:ok, session_id} <- validate_session_id(opts),
         {:ok, mos} <- validate_mos(opts),
         {:ok, threshold} <- validate_threshold(opts),
         {:ok, direction} <- validate_direction(opts),
         {:ok, timestamp} <- validate_timestamp(opts) do
      event = %__MODULE__{
        type: type,
        session_id: session_id,
        mos: mos,
        threshold: threshold,
        direction: direction,
        timestamp: timestamp
      }

      {:ok, event}
    end
  end

  @doc """
  Creates a threshold crossing event with automatic timestamp.

  Convenience function that sets `type: :threshold_crossed` and
  provides a default timestamp of `DateTime.utc_now()`.

  ## Required Fields

  - `:session_id` - Session identifier
  - `:mos` - MOS score (1.0-5.0)
  - `:threshold` - Threshold name
  - `:direction` - `:rising` or `:falling`

  ## Optional Fields

  - `:timestamp` - Defaults to `DateTime.utc_now()`

  ## Examples

      iex> Event.threshold_crossed(session_id: "call-123", mos: 3.4, threshold: :good, direction: :falling)
      {:ok, %Event{type: :threshold_crossed, ...}}
  """
  @spec threshold_crossed(keyword()) :: {:ok, t()} | {:error, atom()}
  def threshold_crossed(opts) when is_list(opts) do
    opts =
      opts
      |> Keyword.put(:type, :threshold_crossed)
      |> Keyword.put_new_lazy(:timestamp, &DateTime.utc_now/0)

    new(opts)
  end

  # ===========================================================================
  # Private Validation Functions
  # ===========================================================================

  defp validate_type(opts) do
    case Keyword.fetch(opts, :type) do
      {:ok, nil} ->
        {:error, :missing_type}

      {:ok, type} when type in @valid_types ->
        {:ok, type}

      {:ok, _invalid} ->
        {:error, :invalid_type}

      :error ->
        {:error, :missing_type}
    end
  end

  defp validate_session_id(opts) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, nil} ->
        {:error, :missing_session_id}

      {:ok, session_id} when is_binary(session_id) ->
        {:ok, session_id}

      :error ->
        {:error, :missing_session_id}
    end
  end

  defp validate_mos(opts) do
    case Keyword.fetch(opts, :mos) do
      {:ok, nil} ->
        {:error, :missing_mos}

      {:ok, mos} when is_number(mos) and mos >= 1.0 and mos <= 5.0 ->
        {:ok, mos}

      {:ok, _mos} ->
        {:error, :mos_out_of_range}

      :error ->
        {:error, :missing_mos}
    end
  end

  defp validate_threshold(opts) do
    case Keyword.fetch(opts, :threshold) do
      {:ok, nil} ->
        {:error, :missing_threshold}

      {:ok, threshold} when is_atom(threshold) ->
        {:ok, threshold}

      :error ->
        {:error, :missing_threshold}
    end
  end

  defp validate_direction(opts) do
    case Keyword.fetch(opts, :direction) do
      {:ok, nil} ->
        {:error, :missing_direction}

      {:ok, direction} when direction in @valid_directions ->
        {:ok, direction}

      {:ok, _invalid} ->
        {:error, :invalid_direction}

      :error ->
        {:error, :missing_direction}
    end
  end

  defp validate_timestamp(opts) do
    case Keyword.fetch(opts, :timestamp) do
      {:ok, nil} ->
        {:error, :missing_timestamp}

      {:ok, %DateTime{} = timestamp} ->
        {:ok, timestamp}

      :error ->
        {:error, :missing_timestamp}
    end
  end
end
