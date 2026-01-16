defmodule ParrotSip.CDR.Disposition do
  @moduledoc """
  Maps SIP response codes to CDR disposition atoms.

  This module provides a standardized mapping from SIP response codes to
  call disposition values used in Call Detail Records (CDRs). The dispositions
  provide a human-readable categorization of call outcomes.

  ## Disposition Types

  - `:answered` - Call was answered and completed normally (2xx responses)
  - `:busy` - Callee is busy (486 Busy Here)
  - `:no_answer` - No answer from callee (480 Temporarily Unavailable / ring timeout)
  - `:timeout` - Request timeout (408 Request Timeout)
  - `:cancelled` - Call was cancelled by caller (487 Request Terminated)
  - `:declined` - Call was explicitly declined (603 Decline, 6xx codes)
  - `:not_found` - User or destination not found (404, 604)
  - `:forbidden` - Authentication/authorization failure (401, 403, 407)
  - `:server_error` - Server-side error (5xx responses)
  - `:failed` - Other client errors (other 4xx responses)
  - `:redirected` - Call was redirected (3xx responses)
  - `:abandoned` - No final response received (nil, 0, or 1xx provisional)

  ## SIP Response Code Reference

  SIP response codes are defined in RFC 3261 Section 21 and related RFCs.
  """

  @typedoc """
  Call disposition atom representing the outcome of a call.
  """
  @type t ::
          :answered
          | :busy
          | :no_answer
          | :timeout
          | :cancelled
          | :declined
          | :not_found
          | :forbidden
          | :server_error
          | :failed
          | :redirected
          | :abandoned

  @dispositions [
    :answered,
    :busy,
    :no_answer,
    :timeout,
    :cancelled,
    :declined,
    :not_found,
    :forbidden,
    :server_error,
    :failed,
    :redirected,
    :abandoned
  ]

  @disposition_strings %{
    answered: "Answered",
    busy: "Busy",
    no_answer: "No Answer",
    timeout: "Timeout",
    cancelled: "Cancelled",
    declined: "Declined",
    not_found: "Not Found",
    forbidden: "Forbidden",
    server_error: "Server Error",
    failed: "Failed",
    redirected: "Redirected",
    abandoned: "Abandoned"
  }

  # Build reverse lookup map at compile time
  @string_to_disposition @disposition_strings
                         |> Enum.flat_map(fn {atom, string} ->
                           [
                             {string, atom},
                             {String.downcase(string), atom}
                           ]
                         end)
                         |> Map.new()

  @doc """
  Returns all valid disposition atoms.

  ## Examples

      iex> ParrotSip.CDR.Disposition.all()
      [:answered, :busy, :no_answer, :timeout, :cancelled, :declined,
       :not_found, :forbidden, :server_error, :failed, :redirected, :abandoned]
  """
  @spec all() :: [t()]
  def all, do: @dispositions

  @doc """
  Maps a SIP response code to a disposition atom.

  The `was_answered` parameter indicates if the call was actually answered
  (media established). This is primarily used to distinguish successful 2xx
  responses.

  ## Parameters

  - `code` - The SIP response code (integer) or nil
  - `was_answered` - Boolean indicating if the call was answered

  ## Examples

      iex> ParrotSip.CDR.Disposition.from_sip_code(200, true)
      :answered

      iex> ParrotSip.CDR.Disposition.from_sip_code(486, false)
      :busy

      iex> ParrotSip.CDR.Disposition.from_sip_code(nil, false)
      :abandoned
  """
  @spec from_sip_code(integer() | nil, boolean()) :: t()

  # Abandoned: nil, 0, or 1xx provisional responses
  def from_sip_code(nil, _was_answered), do: :abandoned
  def from_sip_code(0, _was_answered), do: :abandoned
  def from_sip_code(code, _was_answered) when code >= 100 and code < 200, do: :abandoned

  # Answered: 2xx success responses
  def from_sip_code(code, _was_answered) when code >= 200 and code < 300, do: :answered

  # Redirected: 3xx redirection responses
  def from_sip_code(code, _was_answered) when code >= 300 and code < 400, do: :redirected

  # Specific 4xx codes with special meaning
  def from_sip_code(401, _was_answered), do: :forbidden
  def from_sip_code(403, _was_answered), do: :forbidden
  def from_sip_code(404, _was_answered), do: :not_found
  def from_sip_code(407, _was_answered), do: :forbidden
  def from_sip_code(408, _was_answered), do: :timeout
  def from_sip_code(480, _was_answered), do: :no_answer
  def from_sip_code(486, _was_answered), do: :busy
  def from_sip_code(487, _was_answered), do: :cancelled

  # Other 4xx: general client failure
  def from_sip_code(code, _was_answered) when code >= 400 and code < 500, do: :failed

  # Server errors: 5xx responses
  def from_sip_code(code, _was_answered) when code >= 500 and code < 600, do: :server_error

  # Specific 6xx codes
  def from_sip_code(600, _was_answered), do: :declined
  def from_sip_code(603, _was_answered), do: :declined
  def from_sip_code(604, _was_answered), do: :not_found
  def from_sip_code(606, _was_answered), do: :declined

  # Other 6xx: global failures, treat as declined
  def from_sip_code(code, _was_answered) when code >= 600 and code < 700, do: :declined

  @doc """
  Checks if the given value is a valid disposition atom.

  ## Examples

      iex> ParrotSip.CDR.Disposition.valid?(:answered)
      true

      iex> ParrotSip.CDR.Disposition.valid?(:invalid)
      false

      iex> ParrotSip.CDR.Disposition.valid?("answered")
      false
  """
  @spec valid?(term()) :: boolean()
  def valid?(disposition) when disposition in @dispositions, do: true
  def valid?(_), do: false

  @doc """
  Converts a disposition atom to a human-readable string.

  ## Examples

      iex> ParrotSip.CDR.Disposition.to_string(:answered)
      "Answered"

      iex> ParrotSip.CDR.Disposition.to_string(:no_answer)
      "No Answer"
  """
  @spec to_string(t()) :: String.t()
  def to_string(disposition) when is_map_key(@disposition_strings, disposition) do
    Map.fetch!(@disposition_strings, disposition)
  end

  @doc """
  Parses a human-readable string to a disposition atom.

  Accepts both title case ("Answered") and lowercase ("answered") formats.

  ## Examples

      iex> ParrotSip.CDR.Disposition.from_string("Answered")
      {:ok, :answered}

      iex> ParrotSip.CDR.Disposition.from_string("no answer")
      {:ok, :no_answer}

      iex> ParrotSip.CDR.Disposition.from_string("invalid")
      {:error, :invalid_disposition}
  """
  @spec from_string(String.t()) :: {:ok, t()} | {:error, :invalid_disposition}
  def from_string(string) when is_binary(string) do
    # Try exact match first, then lowercase
    case Map.get(@string_to_disposition, string) ||
           Map.get(@string_to_disposition, String.downcase(string)) do
      nil -> {:error, :invalid_disposition}
      disposition -> {:ok, disposition}
    end
  end
end
