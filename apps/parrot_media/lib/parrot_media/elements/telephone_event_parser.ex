defmodule ParrotMedia.Elements.TelephoneEventParser do
  @moduledoc """
  RFC 2833/4733 telephone-event parser for DTMF detection.

  Parses telephone-event RTP payloads and emits {:dtmf, digit} notifications.
  """

  use Membrane.Filter

  require Logger

  # T4: Define input/output pads
  def_input_pad(:input,
    accepted_format: _any,
    flow_control: :auto
  )

  def_output_pad(:output,
    accepted_format: _any,
    flow_control: :auto
  )

  # T5: Define payload_type option
  def_options(
    payload_type: [
      spec: pos_integer(),
      description: "RTP payload type for telephone-event (typically 101)"
    ]
  )

  # T6: Implement handle_init/2
  # T42: Validate payload_type is a positive integer
  @impl true
  def handle_init(_ctx, opts) do
    payload_type = opts.payload_type

    unless is_integer(payload_type) and payload_type > 0 do
      raise ArgumentError,
            "payload_type must be a positive integer, got: #{inspect(payload_type)}"
    end

    state = %{
      payload_type: payload_type,
      current_event: nil,
      completed_events: MapSet.new()
    }

    {[], state}
  end

  # T7: Implement handle_stream_format/4
  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    {[stream_format: {:output, stream_format}], state}
  end

  # T12-T16: Full DTMF detection implementation
  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case parse_if_telephone_event(buffer, state.payload_type) do
      {:telephone_event, event_id, end_bit, timestamp} ->
        handle_telephone_event(buffer, event_id, end_bit, timestamp, state)

      :not_telephone_event ->
        {[buffer: {:output, buffer}], state}
    end
  end

  # T13: Payload type filtering - only parse matching payload types
  defp parse_if_telephone_event(buffer, expected_payload_type) do
    with %{metadata: %{rtp: %{payload_type: pt, timestamp: timestamp}}} <- buffer,
         true <- pt == expected_payload_type,
         {:ok, event_id, end_bit} <- parse_telephone_event_payload(buffer.payload) do
      {:telephone_event, event_id, end_bit, timestamp}
    else
      _ -> :not_telephone_event
    end
  end

  # T12: RFC 4733 payload parsing with binary pattern matching
  # Format: <<event_id::8, end_bit::1, reserved::1, volume::6, duration::16>>
  defp parse_telephone_event_payload(
         <<event_id::8, end_bit::1, _reserved::1, _volume::6, _duration::16>>
       ) do
    {:ok, event_id, end_bit}
  end

  # T41: Handle malformed payloads gracefully - log warning and return error
  defp parse_telephone_event_payload(payload) do
    Logger.warning(
      "Malformed telephone-event payload: expected 4 bytes, got #{byte_size(payload)} bytes"
    )

    :error
  end

  # T14-T16: Handle telephone event with state tracking and duplicate suppression
  defp handle_telephone_event(buffer, event_id, end_bit, timestamp, state) do
    event_key = {timestamp, event_id}

    case end_bit do
      1 ->
        # T15: End bit is set - check for duplicate suppression
        if MapSet.member?(state.completed_events, event_key) do
          # T16: Already completed - suppress duplicate notification
          {[buffer: {:output, buffer}], state}
        else
          # First end packet for this event - emit notification
          digit = event_id_to_digit(event_id)

          # T16: Track completed event and limit to 10 entries
          new_completed = add_completed_event(state.completed_events, event_key)

          new_state = %{
            state
            | current_event: nil,
              completed_events: new_completed
          }

          actions =
            if digit do
              [notify_parent: {:dtmf, digit}, buffer: {:output, buffer}]
            else
              # Unknown event_id - pass through without notification
              [buffer: {:output, buffer}]
            end

          {actions, new_state}
        end

      0 ->
        # T14: Intermediate packet - track current event, no notification
        new_state = %{state | current_event: event_key}
        {[buffer: {:output, buffer}], new_state}
    end
  end

  # T16: Limit completed_events to 10 entries (remove oldest first)
  defp add_completed_event(completed_events, event_key) do
    new_set = MapSet.put(completed_events, event_key)

    if MapSet.size(new_set) > 10 do
      # Remove the oldest entry (smallest timestamp)
      oldest =
        new_set
        |> MapSet.to_list()
        |> Enum.min_by(fn {ts, _id} -> ts end)

      MapSet.delete(new_set, oldest)
    else
      new_set
    end
  end

  # T8: Implement digit mapping function
  # Maps RFC 2833/4733 event IDs to DTMF digit characters
  defp event_id_to_digit(id) when id >= 0 and id <= 9, do: Integer.to_string(id)
  defp event_id_to_digit(10), do: "*"
  defp event_id_to_digit(11), do: "#"
  defp event_id_to_digit(12), do: "A"
  defp event_id_to_digit(13), do: "B"
  defp event_id_to_digit(14), do: "C"
  defp event_id_to_digit(15), do: "D"
  defp event_id_to_digit(_), do: nil
end
