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
    "termination_reason"
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
      termination_cause: format_termination_cause(cdr.termination_cause)
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
      format_termination_reason_csv(cdr.termination_cause)
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
end
