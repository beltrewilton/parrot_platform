defmodule ParrotSip.CDR.Serializer do
  @moduledoc """
  Serialization helpers for CDR export to JSON and CSV formats.

  Provides functions to convert CDR structs to various formats suitable for
  storage, export, or transmission.

  ## JSON Export

      {:ok, json} = ParrotSip.CDR.Serializer.to_json(cdr)

  ## CSV Export

      headers = ParrotSip.CDR.Serializer.csv_headers()
      row = ParrotSip.CDR.Serializer.to_csv_row(cdr)

  ## Map Conversion

      map = ParrotSip.CDR.Serializer.to_map(cdr)
  """

  alias ParrotSip.CDR

  @csv_headers [
    "id",
    "correlation_id",
    "call_id",
    "caller_uri",
    "callee_uri",
    "disposition",
    "direction",
    "transport",
    "invite_received_at",
    "answered_at",
    "ended_at",
    "ring_duration_ms",
    "talk_duration_ms",
    "termination_party",
    "termination_sip_code",
    "termination_reason",
    # MOS quality metrics (flattened from mos_summary)
    "mos_avg",
    "mos_min",
    "mos_max",
    "mos_status",
    "packet_loss_percent"
  ]

  @doc """
  Returns CSV column headers.

  The headers are returned in a consistent order that matches the values
  returned by `to_csv_row/1`.

  ## Example

      iex> ParrotSip.CDR.Serializer.csv_headers()
      ["id", "correlation_id", "call_id", "caller_uri", "callee_uri", ...]
  """
  @spec csv_headers() :: [String.t()]
  def csv_headers, do: @csv_headers

  @doc """
  Converts a CDR struct to a map suitable for JSON encoding.

  Atoms are converted to strings, DateTime values are converted to ISO8601
  format, and the termination_cause struct is converted to a nested map.

  ## Example

      iex> cdr = %ParrotSip.CDR{id: "123", disposition: :answered, direction: :inbound}
      iex> map = ParrotSip.CDR.Serializer.to_map(cdr)
      iex> map.disposition
      "answered"
  """
  @spec to_map(CDR.t()) :: map()
  def to_map(%CDR{} = cdr) do
    %{
      id: cdr.id,
      correlation_id: cdr.correlation_id,
      call_id: cdr.call_id,
      caller_uri: cdr.caller_uri,
      callee_uri: cdr.callee_uri,
      disposition: to_string(cdr.disposition),
      direction: to_string(cdr.direction),
      transport: format_transport(cdr.transport),
      invite_received_at: format_datetime(cdr.invite_received_at),
      answered_at: format_datetime(cdr.answered_at),
      ended_at: format_datetime(cdr.ended_at),
      ring_duration_ms: cdr.ring_duration_ms,
      talk_duration_ms: cdr.talk_duration_ms,
      termination_cause: format_termination_cause(cdr.termination_cause),
      mos_summary: format_mos_summary(cdr.media_info)
    }
  end

  @doc """
  Converts a CDR struct to a JSON string.

  Returns `{:ok, json_string}` on success or `{:error, term()}` on failure.

  ## Example

      iex> cdr = %ParrotSip.CDR{id: "123", disposition: :answered, direction: :inbound}
      iex> {:ok, json} = ParrotSip.CDR.Serializer.to_json(cdr)
      iex> is_binary(json)
      true
  """
  @spec to_json(CDR.t()) :: {:ok, String.t()} | {:error, term()}
  def to_json(%CDR{} = cdr) do
    cdr
    |> to_map()
    |> Jason.encode()
  end

  @doc """
  Converts a CDR struct to a CSV row (list of string values).

  The values are returned in the same order as the headers from `csv_headers/0`.
  All values are converted to strings, with nil values becoming empty strings.

  ## Example

      iex> cdr = %ParrotSip.CDR{id: "123", disposition: :answered, direction: :inbound}
      iex> row = ParrotSip.CDR.Serializer.to_csv_row(cdr)
      iex> hd(row)
      "123"
  """
  @spec to_csv_row(CDR.t()) :: [String.t()]
  def to_csv_row(%CDR{} = cdr) do
    [
      cdr.id || "",
      cdr.correlation_id || "",
      cdr.call_id || "",
      cdr.caller_uri || "",
      cdr.callee_uri || "",
      to_string(cdr.disposition),
      to_string(cdr.direction),
      format_transport_csv(cdr.transport),
      format_datetime_csv(cdr.invite_received_at),
      format_datetime_csv(cdr.answered_at),
      format_datetime_csv(cdr.ended_at),
      to_string(cdr.ring_duration_ms || 0),
      to_string(cdr.talk_duration_ms || 0),
      format_termination_party_csv(cdr.termination_cause),
      format_termination_sip_code_csv(cdr.termination_cause),
      format_termination_reason_csv(cdr.termination_cause),
      # MOS quality metrics (flattened)
      format_mos_avg_csv(cdr.media_info),
      format_mos_min_csv(cdr.media_info),
      format_mos_max_csv(cdr.media_info),
      format_mos_status_csv(cdr.media_info),
      format_packet_loss_percent_csv(cdr.media_info)
    ]
  end

  # ===========================================================================
  # Private Functions - DateTime formatting
  # ===========================================================================

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_datetime_csv(nil), do: ""
  defp format_datetime_csv(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ===========================================================================
  # Private Functions - Transport formatting
  # ===========================================================================

  defp format_transport(nil), do: nil
  defp format_transport(transport) when is_atom(transport), do: to_string(transport)

  defp format_transport_csv(nil), do: ""
  defp format_transport_csv(transport) when is_atom(transport), do: to_string(transport)

  # ===========================================================================
  # Private Functions - TerminationCause formatting
  # ===========================================================================

  defp format_termination_cause(nil), do: nil

  defp format_termination_cause(tc) do
    %{
      party: format_party(tc.party),
      sip_code: tc.sip_code,
      reason: tc.reason,
      method: format_method(tc.method)
    }
  end

  defp format_party(nil), do: nil
  defp format_party(party) when is_atom(party), do: to_string(party)

  defp format_method(nil), do: nil
  defp format_method(method) when is_atom(method), do: to_string(method)

  # CSV-specific termination cause formatters
  defp format_termination_party_csv(nil), do: ""
  defp format_termination_party_csv(%{party: nil}), do: ""
  defp format_termination_party_csv(%{party: party}), do: to_string(party)

  defp format_termination_sip_code_csv(nil), do: ""
  defp format_termination_sip_code_csv(%{sip_code: nil}), do: ""
  defp format_termination_sip_code_csv(%{sip_code: code}), do: to_string(code)

  defp format_termination_reason_csv(nil), do: ""
  defp format_termination_reason_csv(%{reason: nil}), do: ""
  defp format_termination_reason_csv(%{reason: reason}), do: reason

  # ===========================================================================
  # Private Functions - MOS Summary formatting (JSON)
  # ===========================================================================

  # Extract mos_summary from media_info, returning nil if not available
  defp format_mos_summary(nil), do: nil
  defp format_mos_summary(%{mos_summary: nil}), do: nil

  defp format_mos_summary(%{mos_summary: summary}) do
    %{
      "min_mos" => summary.min_mos,
      "max_mos" => summary.max_mos,
      "avg_mos" => summary.avg_mos,
      "total_packets" => summary.total_packets,
      "total_lost" => summary.total_lost,
      "overall_loss_percent" => summary.overall_loss_percent,
      "intervals_calculated" => summary.intervals_calculated,
      "duration_ms" => summary.duration_ms,
      "status" => format_mos_status(summary.status),
      "quality_events" => format_quality_events(summary.quality_events)
    }
  end

  defp format_mos_status(nil), do: nil
  defp format_mos_status(status) when is_atom(status), do: to_string(status)

  defp format_quality_events(nil), do: []
  defp format_quality_events(events) when is_list(events) do
    Enum.map(events, &format_quality_event/1)
  end

  defp format_quality_event(event) when is_map(event) do
    %{
      "timestamp" => format_datetime(event.timestamp),
      "mos_value" => event.mos_value,
      "threshold_name" => format_threshold_name(event.threshold_name),
      "direction" => format_direction(event.direction)
    }
  end

  defp format_threshold_name(nil), do: nil
  defp format_threshold_name(name) when is_atom(name), do: to_string(name)

  defp format_direction(nil), do: nil
  defp format_direction(direction) when is_atom(direction), do: to_string(direction)

  # ===========================================================================
  # Private Functions - MOS Summary CSV formatters (flattened)
  # ===========================================================================

  defp format_mos_avg_csv(nil), do: ""
  defp format_mos_avg_csv(%{mos_summary: nil}), do: ""
  defp format_mos_avg_csv(%{mos_summary: %{avg_mos: avg}}) when is_number(avg), do: to_string(avg)
  defp format_mos_avg_csv(_), do: ""

  defp format_mos_min_csv(nil), do: ""
  defp format_mos_min_csv(%{mos_summary: nil}), do: ""
  defp format_mos_min_csv(%{mos_summary: %{min_mos: min}}) when is_number(min), do: to_string(min)
  defp format_mos_min_csv(_), do: ""

  defp format_mos_max_csv(nil), do: ""
  defp format_mos_max_csv(%{mos_summary: nil}), do: ""
  defp format_mos_max_csv(%{mos_summary: %{max_mos: max}}) when is_number(max), do: to_string(max)
  defp format_mos_max_csv(_), do: ""

  defp format_mos_status_csv(nil), do: ""
  defp format_mos_status_csv(%{mos_summary: nil}), do: ""
  defp format_mos_status_csv(%{mos_summary: %{status: status}}) when is_atom(status), do: to_string(status)
  defp format_mos_status_csv(_), do: ""

  defp format_packet_loss_percent_csv(nil), do: ""
  defp format_packet_loss_percent_csv(%{mos_summary: nil}), do: ""
  defp format_packet_loss_percent_csv(%{mos_summary: %{overall_loss_percent: loss}}) when is_number(loss), do: to_string(loss)
  defp format_packet_loss_percent_csv(_), do: ""
end
