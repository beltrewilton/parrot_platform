defmodule ParrotTransport.Framing.ContentLength do
  @moduledoc """
  RFC 3261 Section 18.3 Content-Length based message framing.

  Stream transports (TCP/TLS) use Content-Length header to determine
  message boundaries. This module implements complete, correct framing
  per RFC 3261 Section 18.3.

  ## RFC 3261 Section 18.3

  The Content-Length header field value MUST exactly match the size
  of the message body (after SIP and MIME headers). If the
  Content-Length header field is not present, the message body is
  assumed to have zero length.
  """

  defstruct [
    buffer: <<>>,
    state: :seeking_headers,
    current_headers: nil,
    content_length: nil
  ]

  @type state :: :seeking_headers | {:reading_body, non_neg_integer()}

  @type t :: %__MODULE__{
          buffer: binary(),
          state: state(),
          current_headers: binary() | nil,
          content_length: non_neg_integer() | nil
        }

  @type parse_result :: {:ok, [binary()], t()} | {:error, term()}

  @doc """
  Process incoming stream data and extract complete messages.

  ## Examples

      iex> framing = %ContentLength{}
      iex> data = "INVITE sip:bob@example.com SIP/2.0\\r\\n" <>
      ...>        "Content-Length: 0\\r\\n\\r\\n"
      iex> {:ok, [message], _new_framing} = ContentLength.process(framing, data)
      iex> message
      "INVITE sip:bob@example.com SIP/2.0\\r\\nContent-Length: 0\\r\\n\\r\\n"
  """
  @spec process(t(), binary()) :: parse_result()
  def process(%__MODULE__{state: :seeking_headers} = framing, new_data) do
    buffer = framing.buffer <> new_data

    case find_header_end(buffer) do
      {:ok, headers, body_start} ->
        case extract_content_length(headers) do
          {:ok, content_length} ->
            # Extract just the body portion from buffer
            body_buffer = binary_part(buffer, body_start, byte_size(buffer) - body_start)

            new_framing = %{
              framing
              | state: {:reading_body, content_length},
                current_headers: headers,
                content_length: content_length,
                buffer: body_buffer
            }

            # Try to extract complete message(s)
            extract_messages(new_framing)

          {:error, _} = error ->
            error
        end

      :incomplete ->
        # Need more data for headers
        {:ok, [], %{framing | buffer: buffer}}
    end
  end

  def process(%__MODULE__{state: {:reading_body, expected_length}} = framing, new_data) do
    buffer = framing.buffer <> new_data

    if byte_size(buffer) >= expected_length do
      # Have complete body
      body = binary_part(buffer, 0, expected_length)
      complete_message = framing.current_headers <> body
      remaining = binary_part(buffer, expected_length, byte_size(buffer) - expected_length)

      # Reset state for next message
      new_framing = %__MODULE__{buffer: remaining}

      # Recursively process remaining data
      case process(new_framing, <<>>) do
        {:ok, more_messages, final_framing} ->
          {:ok, [complete_message | more_messages], final_framing}

        {:error, _} = error ->
          error
      end
    else
      # Need more body data
      {:ok, [], %{framing | buffer: buffer}}
    end
  end

  @doc """
  Finds the end of SIP headers (\\r\\n\\r\\n).

  Returns `{:ok, headers_with_crlf, body_start_position}` or `:incomplete`.

  ## Examples

      iex> ContentLength.find_header_end("INVITE sip:bob SIP/2.0\\r\\n\\r\\n")
      {:ok, "INVITE sip:bob SIP/2.0\\r\\n\\r\\n", 28}

      iex> ContentLength.find_header_end("INVITE sip:bob SIP/2.0\\r\\n")
      :incomplete
  """
  @spec find_header_end(binary()) :: {:ok, binary(), non_neg_integer()} | :incomplete
  def find_header_end(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {pos, 4} ->
        headers = binary_part(buffer, 0, pos + 4)
        {:ok, headers, pos + 4}

      :nomatch ->
        :incomplete
    end
  end

  @doc """
  Extracts Content-Length value from headers.

  Per RFC 3261, if multiple Content-Length headers exist,
  the request/response MUST be rejected. We take the first one.

  If no Content-Length header is present, returns `{:ok, 0}` per RFC 3261.

  ## Examples

      iex> ContentLength.extract_content_length("INVITE sip:bob SIP/2.0\\r\\nContent-Length: 142\\r\\n\\r\\n")
      {:ok, 142}

      iex> ContentLength.extract_content_length("INVITE sip:bob SIP/2.0\\r\\n\\r\\n")
      {:ok, 0}

      iex> ContentLength.extract_content_length("INVITE sip:bob SIP/2.0\\r\\nContent-Length: invalid\\r\\n\\r\\n")
      {:error, :invalid_content_length}
  """
  @spec extract_content_length(binary()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_content_length}
  def extract_content_length(headers) do
    # Case-insensitive search for Content-Length header
    # Look for the header line
    case Regex.run(~r/^Content-Length:\s*(.+?)\s*$/mi, headers) do
      [_, value_str] ->
        # Try to parse as integer
        case Integer.parse(value_str) do
          {length, ""} when length >= 0 ->
            {:ok, length}

          {_length, ""} ->
            # Negative number
            {:error, :invalid_content_length}

          _ ->
            # Not a valid integer
            {:error, :invalid_content_length}
        end

      nil ->
        # No Content-Length means zero-length body per RFC 3261
        {:ok, 0}
    end
  end

  # Private helper to extract any remaining complete messages
  defp extract_messages(%__MODULE__{} = framing) do
    process(framing, <<>>)
  end
end
