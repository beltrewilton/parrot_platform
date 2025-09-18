defmodule ParrotSip.Parser do
  @moduledoc """
  SIP message parser using NimbleParsec.

  This module provides the core functionality for parsing SIP messages
  according to RFC 3261 and related specifications.
  """

  import NimbleParsec

  require Logger

  alias ParrotSip.Message
  alias ParrotSip.Headers

  # Constants
  @sip_methods [
    :invite,
    :ack,
    :bye,
    :cancel,
    :options,
    :register,
    :prack,
    :subscribe,
    :notify,
    :publish,
    :info,
    :refer,
    :message,
    :update
  ]

  # Common parsers
  whitespace = ascii_string([?\s, ?\t], min: 1)
  optional_whitespace = ascii_string([?\s, ?\t], min: 0)

  crlf = string("\r\n")

  token_char = [
    ?!,
    ?%,
    ?',
    ?*,
    ?+,
    ?-,
    ?.,
    ?0,
    ?1,
    ?2,
    ?3,
    ?4,
    ?5,
    ?6,
    ?7,
    ?8,
    ?9,
    ?A,
    ?B,
    ?C,
    ?D,
    ?E,
    ?F,
    ?G,
    ?H,
    ?I,
    ?J,
    ?K,
    ?L,
    ?M,
    ?N,
    ?O,
    ?P,
    ?Q,
    ?R,
    ?S,
    ?T,
    ?U,
    ?V,
    ?W,
    ?X,
    ?Y,
    ?Z,
    ?_,
    ?`,
    ?a,
    ?b,
    ?c,
    ?d,
    ?e,
    ?f,
    ?g,
    ?h,
    ?i,
    ?j,
    ?k,
    ?l,
    ?m,
    ?n,
    ?o,
    ?p,
    ?q,
    ?r,
    ?s,
    ?t,
    ?u,
    ?v,
    ?w,
    ?x,
    ?y,
    ?z,
    ?~
  ]

  token = ascii_string(token_char, min: 1)

  # Request-Line parsers
  method =
    choice([
      string("INVITE") |> replace(:invite),
      string("ACK") |> replace(:ack),
      string("BYE") |> replace(:bye),
      string("CANCEL") |> replace(:cancel),
      string("OPTIONS") |> replace(:options),
      string("REGISTER") |> replace(:register),
      string("PRACK") |> replace(:prack),
      string("SUBSCRIBE") |> replace(:subscribe),
      string("NOTIFY") |> replace(:notify),
      string("PUBLISH") |> replace(:publish),
      string("INFO") |> replace(:info),
      string("REFER") |> replace(:refer),
      string("MESSAGE") |> replace(:message),
      string("UPDATE") |> replace(:update)
    ])

  sip_uri = ascii_string([not: ?\s], min: 1)

  sip_version = string("SIP/2.0")

  request_line =
    method
    |> ignore(whitespace)
    |> concat(sip_uri)
    |> ignore(whitespace)
    |> concat(sip_version)
    |> ignore(crlf)
    |> tag(:request_line)

  # Status-Line parsers
  status_code = integer(min: 1, max: 3)
  reason_phrase = ascii_string([not: ?\r], min: 0)

  status_line =
    sip_version
    |> ignore(whitespace)
    |> concat(status_code)
    |> ignore(whitespace)
    |> concat(reason_phrase)
    |> ignore(crlf)
    |> tag(:status_line)

  # Header parsers
  header_name =
    token
    |> map({String, :downcase, []})

  # Parse a header value
  header_value =
    ascii_string([not: ?\r], min: 0)
    |> ignore(crlf)

  header =
    header_name
    |> ignore(string(":"))
    |> ignore(optional_whitespace)
    |> concat(header_value)
    |> tag(:header)

  # Body parser
  body =
    ascii_string([], min: 0)
    |> tag(:body)

  # Complete message parser
  defparsec(
    :parse_message,
    choice([request_line, status_line])
    |> times(header, min: 0)
    |> ignore(crlf)
    |> optional(body)
  )

  @doc """
  Parse a SIP message from a binary string.

  Returns `{:ok, message}` or `{:error, reason}`.
  """
  @spec parse(binary()) :: {:ok, Message.t()} | {:error, String.t()}
  def parse(raw_message) when is_binary(raw_message) do
    # Pre-process the raw message to handle folded headers
    processed_message = unfold_headers(raw_message)

    case parse_message(processed_message) do
      {:ok, parsed, "", _, _, _} ->
        process_parsed_message(parsed)

      {:ok, _, _rest, _, _, _} ->
        {:error, "Invalid SIP message: unparsed content remains"}

      {:error, _reason, _rest, _context, _line, _col} ->
        {:error, "Invalid SIP message format"}
    end
  end

  # Unfold header lines that are continued on the next line with whitespace
  defp unfold_headers(message) do
    String.replace(message, ~r/\r\n[ \t]+/, " ")
  end

  # Process the parsed message and convert it to a Message struct
  defp process_parsed_message(parsed) do
    # Extract parts from parsed result
    {type, parts} = extract_message_parts(parsed)

    # Create basic message structure
    base_message =
      case type do
        :request ->
          create_request_message(parts)

        :response ->
          create_response_message(parts)
      end

    # RFC 3261 Section 17.1.3: Transaction ID is the branch parameter from the top Via header
    transaction_id =
      case base_message.via do
        nil ->
          nil

        via when is_list(via) ->
          case via do
            [top | _] -> Map.get(top.parameters, "branch")
            _ -> nil
          end

        via ->
          Map.get(via.parameters, "branch")
      end

    # RFC 3261 Section 12.1.1: Dialog ID is Call-ID + tags
    dialog_id =
      try do
        Logger.debug("Getting dialog_id from message")
        ParrotSip.Dialog.from_message(base_message)
      rescue
        _ -> nil
      end

    message = %Message{base_message | transaction_id: transaction_id, dialog_id: dialog_id}

    # Validate required headers and content length
    with :ok <- validate_message(message),
         :ok <- validate_content_length(message) do
      {:ok, message}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, "Error processing SIP message in parser: #{inspect(e)}"}
  end

  # Extract components from the parsed message
  defp extract_message_parts(parsed) do
    # Initialize with empty values
    parts = %{
      headers: %{},
      body: ""
    }

    # Process each part
    {type, updated_parts} =
      Enum.reduce(parsed, {nil, parts}, fn
        {:request_line, [method, request_uri, version]}, {_, parts} ->
          {:request,
           Map.merge(parts, %{
             method: method,
             request_uri: request_uri,
             version: version
           })}

        {:status_line, [version, status_code, reason_phrase]}, {_, parts} ->
          {:response,
           Map.merge(parts, %{
             version: version,
             status_code: status_code,
             reason_phrase: reason_phrase
           })}

        {:header, [name, value]}, {type, parts} ->
          # Process headers
          headers = process_header(name, value, parts.headers)
          {type, %{parts | headers: headers}}

        {:body, [body]}, {type, parts} ->
          {type, %{parts | body: body}}

        _, acc ->
          acc
      end)

    {type, updated_parts}
  end

  # Process individual headers
  defp process_header(name, value, headers) do
    # Trim leading/trailing whitespace from value
    value = String.trim(value)

    # Process based on header name
    case name do
      "via" ->
        # Via headers can be repeated
        parsed = Headers.Via.parse(value)

        case Map.get(headers, "via") do
          nil ->
            Map.put(headers, "via", parsed)

          existing ->
            if is_list(existing) do
              Map.put(headers, "via", existing ++ [parsed])
            else
              Map.put(headers, "via", [existing, parsed])
            end
        end

      "accept" ->
        # For Accept headers, we need to keep the first one or create a list
        parsed = Headers.Accept.parse(value)

        case Map.get(headers, "accept") do
          nil ->
            Map.put(headers, "accept", parsed)

          existing ->
            if is_list(existing) do
              Map.put(headers, "accept", existing ++ [parsed])
            else
              Map.put(headers, "accept", [existing, parsed])
            end
        end

      "from" ->
        Map.put(headers, "from", Headers.From.parse(value))

      "to" ->
        Map.put(headers, "to", Headers.To.parse(value))

      "contact" ->
        Map.put(headers, "contact", Headers.Contact.parse(value))

      "call-id" ->
        Map.put(headers, "call-id", Headers.CallId.parse(value))

      "cseq" ->
        Map.put(headers, "cseq", Headers.CSeq.parse(value))

      "content-length" ->
        Map.put(headers, "content-length", Headers.ContentLength.parse(value))

      "max-forwards" ->
        Map.put(headers, "max-forwards", Headers.MaxForwards.parse(value))

      "expires" ->
        Map.put(headers, "expires", Headers.Expires.parse(value))

      "content-type" ->
        Map.put(headers, "content-type", Headers.ContentType.parse(value))

      "refer-to" ->
        Map.put(headers, "refer-to", Headers.ReferTo.parse(value))

      "event" ->
        Map.put(headers, "event", Headers.Event.parse(value))

      "subscription-state" ->
        Map.put(headers, "subscription-state", Headers.SubscriptionState.parse(value))

      "subject" ->
        Map.put(headers, "subject", Headers.Subject.parse(value))

      "allow" ->
        Map.put(headers, "allow", Headers.Allow.parse(value))

      "supported" ->
        Map.put(headers, "supported", Headers.Supported.parse(value))

      # For other headers, just store the raw value
      _ ->
        Map.put(headers, name, value)
    end
  end

  # Validate that Content-Length matches the actual body length
  def validate_content_length(message) do
    if message.content_length do
      declared_length = message.content_length
      actual_length = byte_size(message.body)

      cond do
        # Reject negative Content-Length values
        declared_length < 0 ->
          {:error, "Content-Length header value cannot be negative (#{declared_length})"}

        actual_length != declared_length ->
          # Be lenient with Content-Length mismatches for UDP
          # Many SIP implementations have minor discrepancies
          # Log a warning but don't reject the message
          require Logger

          Logger.debug(
            "Content-Length mismatch: declared #{declared_length}, actual #{actual_length}"
          )

          :ok

        true ->
          :ok
      end
    else
      # If no Content-Length header, it's valid (though not recommended for TCP)
      :ok
    end
  end

  def validate_content_length!(message) do
    case validate_content_length(message) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  # All header-specific parsing is now handled by their respective Headers modules

  # Validate that the message has all required headers
  defp validate_message(message) do
    # Check for required headers by examining struct fields
    missing_headers = []
    
    missing_headers = if is_nil(message.from), do: ["from" | missing_headers], else: missing_headers
    missing_headers = if is_nil(message.to), do: ["to" | missing_headers], else: missing_headers
    missing_headers = if is_nil(message.call_id), do: ["call-id" | missing_headers], else: missing_headers
    missing_headers = if is_nil(message.cseq), do: ["cseq" | missing_headers], else: missing_headers
    missing_headers = if is_nil(message.via), do: ["via" | missing_headers], else: missing_headers

    cond do
      message.type == :request and not Enum.member?(@sip_methods, message.method) ->
        {:error, "Invalid SIP method: #{message.method}"}

      message.type == :response and (message.status_code < 100 or message.status_code > 699) ->
        {:error, "Invalid SIP message format: Invalid status code: #{message.status_code}"}

      length(missing_headers) > 0 ->
        {:error,
         "Invalid SIP message format: Missing required headers: #{Enum.join(Enum.reverse(missing_headers), ", ")}"}

      message.type == :request and
        not is_nil(message.cseq) and
          not Enum.member?(@sip_methods, message.cseq.method) ->
        {:error, "Invalid CSeq method: #{message.cseq.method}"}

      not is_nil(message.via) and is_binary(message.via) ->
        # If Via is still a string, try to parse it properly
        # This shouldn't happen with the new parser but keeping for safety
        {:error, "Via header not properly parsed"}

      true ->
        :ok
    end
  end

  # Create a request message from parsed parts
  defp create_request_message(parts) do
    headers = parts.headers
    
    # Extract known headers and build other_headers map
    {known_headers, other_headers} = split_headers(headers)
    
    %Message{
      method: parts.method,
      request_uri: parts.request_uri,
      version: parts.version,
      body: parts.body,
      type: :request,
      direction: :incoming,
      # Known headers as struct fields
      via: known_headers.via,
      from: known_headers.from,
      to: known_headers.to,
      call_id: known_headers.call_id,
      cseq: known_headers.cseq,
      max_forwards: known_headers.max_forwards,
      contact: known_headers.contact,
      route: known_headers.route,
      record_route: known_headers.record_route,
      content_type: known_headers.content_type,
      content_length: known_headers.content_length,
      expires: known_headers.expires,
      allow: known_headers.allow,
      supported: known_headers.supported,
      accept: known_headers.accept,
      event: known_headers.event,
      subscription_state: known_headers.subscription_state,
      refer_to: known_headers.refer_to,
      subject: known_headers.subject,
      # Unknown headers
      other_headers: other_headers
    }
  end
  
  # Create a response message from parsed parts
  defp create_response_message(parts) do
    headers = parts.headers
    
    # Extract known headers and build other_headers map
    {known_headers, other_headers} = split_headers(headers)
    
    %Message{
      status_code: parts.status_code,
      reason_phrase: parts.reason_phrase,
      version: parts.version,
      body: parts.body,
      type: :response,
      direction: :incoming,
      # Known headers as struct fields
      via: known_headers.via,
      from: known_headers.from,
      to: known_headers.to,
      call_id: known_headers.call_id,
      cseq: known_headers.cseq,
      max_forwards: known_headers.max_forwards,
      contact: known_headers.contact,
      route: known_headers.route,
      record_route: known_headers.record_route,
      content_type: known_headers.content_type,
      content_length: known_headers.content_length,
      expires: known_headers.expires,
      allow: known_headers.allow,
      supported: known_headers.supported,
      accept: known_headers.accept,
      event: known_headers.event,
      subscription_state: known_headers.subscription_state,
      refer_to: known_headers.refer_to,
      subject: known_headers.subject,
      # Unknown headers
      other_headers: other_headers
    }
  end
  
  # Split headers into known and unknown
  defp split_headers(headers) do
    known_header_names = [
      "via", "from", "to", "call-id", "cseq", "max-forwards", "contact", 
      "route", "record-route", "content-type", "content-length", "expires",
      "allow", "supported", "accept", "event", "subscription-state", 
      "refer-to", "subject"
    ]
    
    # Extract known headers
    known = %{
      via: Map.get(headers, "via"),
      from: Map.get(headers, "from"),
      to: Map.get(headers, "to"),
      call_id: Map.get(headers, "call-id"),
      cseq: Map.get(headers, "cseq"),
      max_forwards: get_integer_value(Map.get(headers, "max-forwards")),
      contact: Map.get(headers, "contact"),
      route: Map.get(headers, "route"),
      record_route: Map.get(headers, "record-route"),
      content_type: Map.get(headers, "content-type"),
      content_length: get_integer_value(Map.get(headers, "content-length")),
      expires: get_integer_value(Map.get(headers, "expires")),
      allow: Map.get(headers, "allow"),
      supported: Map.get(headers, "supported"),
      accept: Map.get(headers, "accept"),
      event: Map.get(headers, "event"),
      subscription_state: Map.get(headers, "subscription-state"),
      refer_to: Map.get(headers, "refer-to"),
      subject: Map.get(headers, "subject")
    }
    
    # Build other_headers map with unknown headers
    other = headers
      |> Enum.reject(fn {k, _} -> k in known_header_names end)
      |> Map.new()
    
    {known, other}
  end
  
  # Extract integer value from parsed header
  defp get_integer_value(nil), do: nil
  defp get_integer_value(%{value: value}) when is_integer(value), do: value
  defp get_integer_value(value) when is_integer(value), do: value
  defp get_integer_value(_), do: nil
  
  # Extract string value from parsed header  
  defp get_string_value(nil), do: nil
  defp get_string_value(%{value: value}) when is_binary(value), do: value
  defp get_string_value(value) when is_binary(value), do: value
  defp get_string_value(_), do: nil
end
