defmodule ParrotSip.Message do
  @moduledoc """
  Represents a SIP message (request or response).

  This module provides a struct and functions for working with SIP messages as defined
  in RFC 3261 and related specifications. It provides a pure functional implementation
  that models both SIP requests and responses, along with utility functions for
  manipulation, analysis, and conversion.

  References:
  - RFC 3261 Section 7: SIP Messages
  - RFC 3261 Section 8.1: UAC Behavior
  - RFC 3261 Section 8.2: UAS Behavior
  - RFC 3261 Section 20: Header Fields
  """

  require Logger

  alias ParrotSip.Headers.{CSeq, From, To, Via, CallId, Contact}
  alias ParrotSip.Method

  defstruct [
    # Atom like :invite, :register
    :method,
    # URI for requests
    :request_uri,
    # Integer for responses
    :status_code,
    # String for responses
    :reason_phrase,
    # String, typically "SIP/2.0"
    :version,
    # Binary string
    :body,
    # Source information for transport
    :source,
    # :request or :response
    :type,
    # :incoming or :outgoing
    :direction,
    # transaction_id
    :transaction_id,
    # dialog_id
    :dialog_id,

    # Core headers as struct fields (RFC 3261 mandatory/common)
    # [Via.t()] - Always a list for consistency, may be empty
    :via,
    # From.t()
    :from,
    # To.t()
    :to,
    # String.t() | CallId.t()
    :call_id,
    # CSeq.t()
    :cseq,
    # integer()
    :max_forwards,
    # Contact.t() | [Contact.t()] | nil
    :contact,
    # [Route.t()] | nil
    :route,
    # [RecordRoute.t()] | nil
    :record_route,

    # Common optional headers
    # ContentType.t() | nil
    :content_type,
    # integer()
    :content_length,
    # integer() | nil
    :expires,
    # [String.t()] | nil
    :allow,
    # [String.t()] | nil
    :supported,
    # Accept.t() | nil
    :accept,
    # Event.t() | nil
    :event,
    # SubscriptionState.t() | nil
    :subscription_state,
    # ReferTo.t() | nil
    :refer_to,
    # String.t() | nil
    :subject,

    # Catch-all for unknown/extension headers
    # map() - for headers we don't have parsers for
    :other_headers
  ]

  @type t :: %__MODULE__{
          method: Method.t() | nil,
          request_uri: String.t() | nil,
          status_code: integer() | nil,
          reason_phrase: String.t() | nil,
          version: String.t(),
          body: String.t(),
          source: map() | nil,
          type: :request | :response | nil,
          direction: :incoming | :outgoing | nil,
          transaction_id: String.t() | nil,
          dialog_id: String.t() | nil,

          # Header fields
          via: [Via.t()],
          from: From.t() | nil,
          to: To.t() | nil,
          call_id: String.t() | CallId.t() | nil,
          cseq: CSeq.t() | nil,
          max_forwards: integer() | nil,
          contact: Contact.t() | [Contact.t()] | nil,
          route: [ParrotSip.Headers.Route.t()] | nil,
          record_route: [ParrotSip.Headers.RecordRoute.t()] | nil,
          content_type: ParrotSip.Headers.ContentType.t() | nil,
          content_length: integer() | nil,
          expires: integer() | nil,
          allow: [String.t()] | nil,
          supported: [String.t()] | nil,
          accept: ParrotSip.Headers.Accept.t() | nil,
          event: ParrotSip.Headers.Event.t() | nil,
          subscription_state: ParrotSip.Headers.SubscriptionState.t() | nil,
          refer_to: ParrotSip.Headers.ReferTo.t() | nil,
          subject: String.t() | nil,
          other_headers: map()
        }

  @default_reason_phrases %{
    100 => "Trying",
    180 => "Ringing",
    181 => "Call Is Being Forwarded",
    182 => "Queued",
    183 => "Session Progress",
    199 => "Early Dialog Terminated",
    200 => "OK",
    202 => "Accepted",
    204 => "No Notification",
    300 => "Multiple Choices",
    301 => "Moved Permanently",
    302 => "Moved Temporarily",
    305 => "Use Proxy",
    380 => "Alternative Service",
    400 => "Bad Request",
    401 => "Unauthorized",
    402 => "Payment Required",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    406 => "Not Acceptable",
    407 => "Proxy Authentication Required",
    408 => "Request Timeout",
    409 => "Conflict",
    410 => "Gone",
    412 => "Conditional Request Failed",
    413 => "Request Entity Too Large",
    414 => "Request-URI Too Long",
    415 => "Unsupported Media Type",
    416 => "Unsupported URI Scheme",
    417 => "Unknown Resource-Priority",
    420 => "Bad Extension",
    421 => "Extension Required",
    422 => "Session Interval Too Small",
    423 => "Interval Too Brief",
    424 => "Bad Location Information",
    428 => "Use Identity Header",
    429 => "Provide Referrer Identity",
    430 => "Flow Failed",
    433 => "Anonymity Disallowed",
    436 => "Bad Identity-Info",
    437 => "Unsupported Certificate",
    438 => "Invalid Identity Header",
    439 => "First Hop Lacks Outbound Support",
    440 => "Max-Breadth Exceeded",
    470 => "Consent Needed",
    480 => "Temporarily Unavailable",
    481 => "Call/Transaction Does Not Exist",
    482 => "Loop Detected",
    483 => "Too Many Hops",
    484 => "Address Incomplete",
    485 => "Ambiguous",
    486 => "Busy Here",
    487 => "Request Terminated",
    488 => "Not Acceptable Here",
    489 => "Bad Event",
    491 => "Request Pending",
    493 => "Undecipherable",
    494 => "Security Agreement Required",
    500 => "Server Internal Error",
    501 => "Not Implemented",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Server Time-out",
    505 => "Version Not Supported",
    513 => "Message Too Large",
    580 => "Precondition Failure",
    600 => "Busy Everywhere",
    603 => "Decline",
    604 => "Does Not Exist Anywhere",
    606 => "Not Acceptable",
    607 => "Unwanted",
    608 => "Rejected"
  }

  @doc """
  Returns the default reason phrase for a given SIP status code.
  """
  @spec default_reason_phrase(integer()) :: String.t()
  def default_reason_phrase(status_code) do
    Map.get(@default_reason_phrases, status_code, "Unknown")
  end

  @doc """
  Creates a new request message with the specified method, request URI, and headers.

  This function is the main entry point for creating SIP request messages.

  ## Parameters
  - method: The SIP method (atom) for the request
  - request_uri: The request target URI
  - headers: Optional map of initial headers

  ## Examples

      iex> ParrotSip.Message.new_request(:invite, "sip:alice@example.com")
      %ParrotSip.Message{
        method: :invite,
        request_uri: "sip:alice@example.com",
        version: "SIP/2.0",
        headers: %{},
        body: "",
        type: :request,
        direction: :outgoing
      }
  """
  @spec new_request(Method.t(), String.t(), keyword()) :: t()
  def new_request(method, request_uri, opts \\ []) do
    %__MODULE__{
      method: method,
      request_uri: request_uri,
      version: "SIP/2.0",
      body: "",
      type: :request,
      direction: :outgoing,
      dialog_id: Keyword.get(opts, :dialog_id, nil),
      transaction_id: Keyword.get(opts, :transaction_id, nil),
      via: [],
      other_headers: %{}
    }
  end

  @doc """
  Creates a new response message with the specified status code, reason phrase, and headers.

  ## Parameters
  - status_code: The SIP response status code (100-699)
  - reason_phrase: The reason phrase for the response
  - headers: Optional map of initial headers

  ## Examples

      iex> ParrotSip.Message.new_response(200, "OK")
      %ParrotSip.Message{
        status_code: 200,
        reason_phrase: "OK",
        version: "SIP/2.0",
        headers: %{},
        body: "",
        type: :response,
        direction: :outgoing
      }
  """
  @spec new_response(integer(), String.t(), keyword()) :: t()
  def new_response(status_code, reason_phrase, opts) do
    %__MODULE__{
      status_code: status_code,
      reason_phrase: reason_phrase,
      version: "SIP/2.0",
      body: "",
      type: :response,
      direction: :outgoing,
      dialog_id: Keyword.get(opts, :dialog_id, nil),
      transaction_id: Keyword.get(opts, :transaction_id, nil),
      via: [],
      other_headers: %{}
    }
  end

  @doc """
  Creates a new response message with standard reason phrase based on status code.

  If no reason phrase is provided, a standard one will be used based on the status code.

  ## Examples

      iex> ParrotSip.Message.new_response(200)
      %ParrotSip.Message{
        status_code: 200,
        reason_phrase: "OK",
        version: "SIP/2.0",
        headers: %{},
        body: "",
        type: :response,
        direction: :outgoing
      }
  """
  @spec new_response(integer()) :: t()
  def new_response(status_code) do
    reason_phrase = Map.get(@default_reason_phrases, status_code, "Unknown")
    new_response(status_code, reason_phrase, [])
  end

  @spec new_response(integer(), String.t()) :: t()
  def new_response(status_code, reason_phrase) when is_binary(reason_phrase) do
    new_response(status_code, reason_phrase, [])
  end

  @spec new_response(integer(), keyword()) :: t()
  def new_response(status_code, opts) when is_list(opts) do
    reason_phrase = Map.get(@default_reason_phrases, status_code, "Unknown")
    new_response(status_code, reason_phrase, opts)
  end

  # Additional function variants for backward compatibility
  @spec new_request(Method.t(), String.t(), map(), keyword()) :: t()
  def new_request(method, request_uri, _headers, opts) when is_list(opts) do
    new_request(method, request_uri, opts)
  end

  @spec new_response(integer(), String.t(), map(), keyword()) :: t()
  def new_response(status_code, reason_phrase, _headers, opts) when is_list(opts) do
    new_response(status_code, reason_phrase, opts)
  end

  @doc """
  Creates a response from a request, copying necessary headers and setting
  the status code and reason phrase.

  This function follows the requirements in RFC 3261 Section 8.2.6 for
  copying headers from requests to responses.

  ## Parameters
  - request: The SIP request message
  - status_code: The response status code
  - reason_phrase: The reason phrase for the response

  ## Examples

      iex> request = ParrotSip.Message.new_request(:invite, "sip:alice@example.com")
      iex> response = ParrotSip.Message.reply(request, 200, "OK")
      iex> response.status_code
      200
  """
  @spec reply(t(), integer(), String.t()) :: t()
  def reply(request, status_code, reason_phrase) when request.type == :request do
    %__MODULE__{
      method: request.method,
      request_uri: request.request_uri,
      status_code: status_code,
      reason_phrase: reason_phrase,
      version: request.version,
      body: Map.get(request, :body, ""),
      source: request.source,
      type: :response,
      direction: :outgoing,
      dialog_id: Map.get(request, :dialog_id),
      transaction_id: Map.get(request, :transaction_id),
      # Copy header fields from request
      via: request.via,
      from: request.from,
      to: request.to,
      call_id: request.call_id,
      cseq: request.cseq,
      contact: request.contact,
      route: request.route,
      record_route: request.record_route,
      other_headers: Map.get(request, :other_headers, %{})
    }
  end

  @doc """
  Creates a response from a request with standard reason phrase based on status code.

  ## Examples

      iex> request = ParrotSip.Message.new_request(:invite, "sip:alice@example.com")
      iex> response = ParrotSip.Message.reply(request, 200)
      iex> response.reason_phrase
      "OK"
  """
  @spec reply(t(), integer()) :: t()
  def reply(request, status_code) when request.type == :request do
    reason_phrase = Map.get(@default_reason_phrases, status_code, "Unknown")
    reply(request, status_code, reason_phrase)
  end

  @doc """
  Sets a header in other_headers map for unknown/extension headers.
  For known headers, use the specific put_* functions instead.
  """
  @spec put_header(t(), String.t(), any()) :: t()
  def put_header(%__MODULE__{} = message, name, value) do
    downcased = String.downcase(name)
    other_headers = Map.put(message.other_headers || %{}, downcased, value)
    %{message | other_headers: other_headers}
  end

  @spec get_header(t(), String.t()) :: any()
  def get_header(%__MODULE__{via: via}, "via") when is_list(via), do: via
  def get_header(%__MODULE__{via: via}, "via"), do: via
  def get_header(%__MODULE__{from: from}, "from"), do: from
  def get_header(%__MODULE__{to: to}, "to"), do: to
  def get_header(%__MODULE__{call_id: call_id}, "call-id"), do: call_id
  def get_header(%__MODULE__{cseq: cseq}, "cseq"), do: cseq
  def get_header(%__MODULE__{contact: contact}, "contact"), do: contact
  def get_header(%__MODULE__{route: routes}, "route") when is_list(routes), do: routes
  def get_header(%__MODULE__{route: route}, "route") when not is_nil(route), do: [route]
  def get_header(%__MODULE__{route: nil}, "route"), do: nil

  def get_header(%__MODULE__{record_route: routes}, "record-route") when is_list(routes),
    do: routes

  def get_header(%__MODULE__{record_route: route}, "record-route") when not is_nil(route),
    do: [route]

  def get_header(%__MODULE__{record_route: nil}, "record-route"), do: nil
  def get_header(%__MODULE__{max_forwards: max_forwards}, "max-forwards"), do: max_forwards
  def get_header(%__MODULE__{content_type: content_type}, "content-type"), do: content_type

  def get_header(%__MODULE__{content_length: content_length}, "content-length"),
    do: content_length

  def get_header(%__MODULE__{expires: expires}, "expires"), do: expires
  def get_header(%__MODULE__{allow: allow}, "allow"), do: allow
  def get_header(%__MODULE__{supported: supported}, "supported"), do: supported
  def get_header(%__MODULE__{accept: accept}, "accept"), do: accept
  def get_header(%__MODULE__{event: event}, "event"), do: event

  def get_header(%__MODULE__{subscription_state: subscription_state}, "subscription-state"),
    do: subscription_state

  def get_header(%__MODULE__{refer_to: refer_to}, "refer-to"), do: refer_to
  def get_header(%__MODULE__{subject: subject}, "subject"), do: subject

  def get_header(%__MODULE__{other_headers: other_headers}, header_name) do
    header_name = String.downcase(header_name)
    Map.get(other_headers || %{}, header_name)
  end

  # New setter functions for pattern matching convenience
  @spec put_via(t(), Via.t() | [Via.t()]) :: t()
  def put_via(%__MODULE__{} = msg, via), do: %{msg | via: via}

  @spec put_from(t(), From.t()) :: t()
  def put_from(%__MODULE__{} = msg, from), do: %{msg | from: from}

  @spec put_to(t(), To.t()) :: t()
  def put_to(%__MODULE__{} = msg, to), do: %{msg | to: to}

  @spec put_call_id(t(), String.t() | CallId.t()) :: t()
  def put_call_id(%__MODULE__{} = msg, call_id), do: %{msg | call_id: call_id}

  @spec put_cseq(t(), CSeq.t()) :: t()
  def put_cseq(%__MODULE__{} = msg, cseq), do: %{msg | cseq: cseq}

  @spec put_contact(t(), Contact.t() | [Contact.t()] | nil) :: t()
  def put_contact(%__MODULE__{} = msg, contact), do: %{msg | contact: contact}

  @spec put_max_forwards(t(), integer()) :: t()
  def put_max_forwards(%__MODULE__{} = msg, max_forwards), do: %{msg | max_forwards: max_forwards}

  @spec put_route(t(), [ParrotSip.Headers.Route.t()]) :: t()
  def put_route(%__MODULE__{} = msg, route), do: %{msg | route: route}

  @spec put_record_route(t(), [ParrotSip.Headers.RecordRoute.t()]) :: t()
  def put_record_route(%__MODULE__{} = msg, record_route), do: %{msg | record_route: record_route}

  @spec put_content_type(t(), ParrotSip.Headers.ContentType.t()) :: t()
  def put_content_type(%__MODULE__{} = msg, content_type), do: %{msg | content_type: content_type}

  @spec put_expires(t(), integer()) :: t()
  def put_expires(%__MODULE__{} = msg, expires), do: %{msg | expires: expires}

  # Helper to add to list headers (Via, Route, Record-Route)
  @spec add_via(t(), Via.t()) :: t()
  def add_via(%__MODULE__{via: []} = msg, via), do: %{msg | via: [via]}

  def add_via(%__MODULE__{via: vias} = msg, via) when is_list(vias),
    do: %{msg | via: [via | vias]}

  @doc """
  Sets the body of the message and updates the content_length field.

  This function automatically calculates and sets the content_length field
  based on the body's length.

  ## Examples

      iex> message = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> message = ParrotSip.Message.set_body(message, "Hello, world!")
      iex> message.body
      "Hello, world!"
      iex> message.content_length
      13
  """
  @spec set_body(t(), String.t()) :: t()
  def set_body(message, body) do
    %{message | body: body, content_length: byte_size(body)}
  end

  @doc """
  Check if a message is a request.
  """
  @spec is_request?(t()) :: boolean()
  def is_request?(message), do: message.type == :request

  @doc """
  Check if a message is a response.
  """
  @spec is_response?(t()) :: boolean()
  def is_response?(message), do: message.type == :response

  @doc """
  Convert the message to a string representation.
  """
  @spec to_s(t()) :: String.t()
  def to_s(message) do
    start_line =
      if is_request?(message) do
        "#{method_to_string(message.method)} #{message.request_uri} #{message.version}\r\n"
      else
        "#{message.version} #{message.status_code} #{message.reason_phrase}\r\n"
      end

    headers_str = headers_to_string(message)

    start_line <> headers_str <> "\r\n" <> (message.body || "")
  end

  defp method_to_string(method) when is_atom(method) do
    Method.to_string(method)
  end

  defp headers_to_string(message) do
    # RFC 3261 Section 7.3.1: Header Field Order
    # Build headers in correct order from struct fields
    headers = []

    # Via must be first
    headers = if message.via, do: headers ++ [{"Via", message.via}], else: headers

    # Then other headers in order
    headers = if message.route, do: headers ++ [{"Route", message.route}], else: headers

    headers =
      if message.record_route,
        do: headers ++ [{"Record-Route", message.record_route}],
        else: headers

    headers =
      if message.max_forwards,
        do: headers ++ [{"Max-Forwards", message.max_forwards}],
        else: headers

    headers = if message.from, do: headers ++ [{"From", message.from}], else: headers
    headers = if message.to, do: headers ++ [{"To", message.to}], else: headers
    headers = if message.call_id, do: headers ++ [{"Call-Id", message.call_id}], else: headers
    headers = if message.cseq, do: headers ++ [{"Cseq", message.cseq}], else: headers
    headers = if message.contact, do: headers ++ [{"Contact", message.contact}], else: headers
    headers = if message.expires, do: headers ++ [{"Expires", message.expires}], else: headers

    headers =
      if message.content_type,
        do: headers ++ [{"Content-Type", message.content_type}],
        else: headers

    headers =
      if message.content_length,
        do: headers ++ [{"Content-Length", message.content_length}],
        else: headers

    headers = if message.allow, do: headers ++ [{"Allow", message.allow}], else: headers

    headers =
      if message.supported, do: headers ++ [{"Supported", message.supported}], else: headers

    headers = if message.accept, do: headers ++ [{"Accept", message.accept}], else: headers
    headers = if message.event, do: headers ++ [{"Event", message.event}], else: headers

    headers =
      if message.subscription_state,
        do: headers ++ [{"Subscription-State", message.subscription_state}],
        else: headers

    headers = if message.refer_to, do: headers ++ [{"Refer-To", message.refer_to}], else: headers
    headers = if message.subject, do: headers ++ [{"Subject", message.subject}], else: headers

    # Add other headers
    other_headers =
      Map.to_list(message.other_headers || %{})
      |> Enum.map(fn {k, v} ->
        {String.split(k, "-") |> Enum.map(&String.capitalize/1) |> Enum.join("-"), v}
      end)

    headers = headers ++ other_headers

    headers
    |> Enum.map(fn {name, value} -> format_header(name, value) end)
    |> Enum.join("")
  end

  defp format_header(name, value) do
    header_name =
      name
      |> to_string()
      |> String.split("-")
      |> Enum.map(&String.capitalize/1)
      |> Enum.join("-")

    "#{header_name}: #{format_header_value(name, value)}\r\n"
  end

  defp format_header_value(_name, value) when is_binary(value), do: value
  defp format_header_value(_name, value) when is_integer(value), do: Integer.to_string(value)

  defp format_header_value(_name, value) when is_list(value) do
    # For lists, check if all elements are structs with format function
    if Enum.all?(value, &(is_struct(&1) && function_exported?(&1.__struct__, :format, 1))) do
      # Check if the module has a format_list function
      first_struct = List.first(value)

      if first_struct && function_exported?(first_struct.__struct__, :format_list, 1) do
        first_struct.__struct__.format_list(value)
      else
        # Default: format each and join with comma
        value
        |> Enum.map(& &1.__struct__.format(&1))
        |> Enum.join(", ")
      end
    else
      inspect(value)
    end
  end

  defp format_header_value(_name, value) do
    # Try to call format function on header module
    if is_struct(value) && function_exported?(value.__struct__, :format, 1) do
      value.__struct__.format(value)
    else
      # Fall back to inspect for unhandled types
      inspect(value)
    end
  end

  # Simplified accessor patterns - most are removed in favor of direct field access
  # Only keeping those that are truly helpful

  @doc """
  Gets the top Via header from a message.
  For pattern matching, prefer accessing message.via directly.
  """
  @spec top_via(t()) :: Via.t() | nil
  def top_via(%__MODULE__{via: nil}), do: nil
  def top_via(%__MODULE__{via: via}) when is_struct(via, Via), do: via
  def top_via(%__MODULE__{via: [via | _]}) when is_struct(via, Via), do: via
  def top_via(_), do: nil

  @doc """
  Gets all Via headers from a message as a list.
  For pattern matching, prefer accessing message.via directly.
  """
  @spec all_vias(t()) :: [Via.t()]
  def all_vias(%__MODULE__{via: nil}), do: []
  def all_vias(%__MODULE__{via: vias}) when is_list(vias), do: vias
  def all_vias(%__MODULE__{via: via}) when is_struct(via, Via), do: [via]
  def all_vias(_), do: []

  @doc """
  Gets a dialog ID from a message.

  ## Examples

      iex> message = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> from = %ParrotSip.Headers.From{parameters: %{"tag" => "123"}}
      iex> to = %ParrotSip.Headers.To{parameters: %{"tag" => "456"}}
      iex> message = message |> ParrotSip.Message.set_header("From", from)
      iex> message = message |> ParrotSip.Message.set_header("To", to)
      iex> message = message |> ParrotSip.Message.set_header("Call-ID", "abc@example.com")
      iex> dialog_id = ParrotSip.Message.dialog_id(message)
      iex> dialog_id.call_id
      "abc@example.com"
  """
  @spec dialog_id(t()) :: map()
  def dialog_id(message) do
    Logger.debug("Getting dialog_id from message")
    ParrotSip.Dialog.from_message(message)
  end

  @doc """
  Determines if a message is within a dialog.

  A message is within a dialog if it has a To tag and a From tag.

  ## Examples

      iex> message = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> from = %ParrotSip.Headers.From{parameters: %{"tag" => "123"}}
      iex> to = %ParrotSip.Headers.To{parameters: %{"tag" => "456"}}
      iex> message = message |> ParrotSip.Message.put_from(from)
      iex> message = message |> ParrotSip.Message.put_to(to)
      iex> ParrotSip.Message.in_dialog?(message)
      true
  """
  @spec in_dialog?(t()) :: boolean()
  def in_dialog?(%__MODULE__{
        from: %From{parameters: %{"tag" => from_tag}},
        to: %To{parameters: %{"tag" => to_tag}}
      })
      when not is_nil(from_tag) and not is_nil(to_tag),
      do: true

  def in_dialog?(_), do: false

  @doc """
  Gets the status class of a response message (1xx, 2xx, etc.).

  ## Examples

      iex> message = ParrotSip.Message.new_response(200, "OK")
      iex> ParrotSip.Message.status_class(message)
      2
  """
  @spec status_class(t()) :: integer() | nil
  def status_class(%__MODULE__{type: :response, status_code: status_code})
      when is_integer(status_code) do
    div(status_code, 100)
  end

  def status_class(_), do: nil

  @doc """
  Checks if a response message is provisional (1xx).

  ## Examples

      iex> message = ParrotSip.Message.new_response(180, "Ringing")
      iex> ParrotSip.Message.is_provisional?(message)
      true
  """
  @spec is_provisional?(t()) :: boolean()
  def is_provisional?(%__MODULE__{type: :response, status_code: code})
      when code >= 100 and code < 200,
      do: true

  def is_provisional?(_), do: false

  @doc """
  Checks if a response message is successful (2xx).

  ## Examples

      iex> message = ParrotSip.Message.new_response(200, "OK")
      iex> ParrotSip.Message.is_success?(message)
      true
  """
  @spec is_success?(t()) :: boolean()
  def is_success?(%__MODULE__{type: :response, status_code: code})
      when code >= 200 and code < 300,
      do: true

  def is_success?(_), do: false

  @doc """
  Checks if a response message is a redirection (3xx).

  ## Examples

      iex> message = ParrotSip.Message.new_response(302, "Moved Temporarily")
      iex> ParrotSip.Message.is_redirect?(message)
      true
  """
  @spec is_redirect?(t()) :: boolean()
  def is_redirect?(%__MODULE__{type: :response, status_code: code})
      when code >= 300 and code < 400,
      do: true

  def is_redirect?(_), do: false

  @doc """
  Checks if a response message is a client error (4xx).

  ## Examples

      iex> message = ParrotSip.Message.new_response(404, "Not Found")
      iex> ParrotSip.Message.is_client_error?(message)
      true
  """
  @spec is_client_error?(t()) :: boolean()
  def is_client_error?(%__MODULE__{type: :response, status_code: code})
      when code >= 400 and code < 500,
      do: true

  def is_client_error?(_), do: false

  @doc """
  Checks if a response message is a server error (5xx).

  ## Examples

      iex> message = ParrotSip.Message.new_response(500, "Server Internal Error")
      iex> ParrotSip.Message.is_server_error?(message)
      true
  """
  @spec is_server_error?(t()) :: boolean()
  def is_server_error?(%__MODULE__{type: :response, status_code: code})
      when code >= 500 and code < 600,
      do: true

  def is_server_error?(_), do: false

  @doc """
  Checks if a response message is a global error (6xx).

  ## Examples

      iex> message = ParrotSip.Message.new_response(603, "Decline")
      iex> ParrotSip.Message.is_global_error?(message)
      true
  """
  @spec is_global_error?(t()) :: boolean()
  def is_global_error?(%__MODULE__{type: :response, status_code: code})
      when code >= 600 and code < 700,
      do: true

  def is_global_error?(_), do: false

  @doc """
  Checks if a response message is a failure (4xx, 5xx, or 6xx).

  ## Examples

      iex> message = ParrotSip.Message.new_response(404, "Not Found")
      iex> ParrotSip.Message.is_failure?(message)
      true
  """
  @spec is_failure?(t()) :: boolean()
  def is_failure?(%__MODULE__{type: :response, status_code: code})
      when code >= 400 and code < 700,
      do: true

  def is_failure?(_), do: false

  @doc """
  Converts a message to binary format for transmission.

  ## Examples

      iex> message = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> binary = ParrotSip.Message.to_binary(message)
      iex> String.starts_with?(binary, "INVITE sip:bob@example.com SIP/2.0")
      true
  """
  @spec to_binary(t()) :: binary()
  def to_binary(message) do
    to_s(message)
  end

  # Legacy accessor functions for backward compatibility
  @doc """
  Returns the From header of the message.
  """
  @spec from(t()) :: From.t() | nil
  def from(%__MODULE__{from: from}), do: from

  @doc """
  Returns the To header of the message.
  """
  @spec to(t()) :: To.t() | nil
  def to(%__MODULE__{to: to}), do: to

  @doc """
  Returns the Call-ID header of the message.
  """
  @spec call_id(t()) :: String.t() | nil
  def call_id(%__MODULE__{call_id: call_id}), do: call_id

  @doc """
  Returns the CSeq header of the message.
  """
  @spec cseq(t()) :: CSeq.t() | nil
  def cseq(%__MODULE__{cseq: cseq}), do: cseq

  @doc """
  Sets a header in the message.
  For now, this stores values in other_headers for unknown headers.
  """
  @spec set_header(t(), String.t(), any()) :: t()
  def set_header(%__MODULE__{} = message, header_name, value) do
    header_name = String.downcase(header_name)

    case header_name do
      "from" ->
        %{message | from: value}

      "to" ->
        %{message | to: value}

      "call-id" ->
        %{message | call_id: value}

      "cseq" ->
        %{message | cseq: value}

      "via" ->
        # If value is a string, parse it to a Via struct
        via_value =
          cond do
            is_binary(value) ->
              # Parse the via string into a Via struct
              try do
                ParrotSip.Headers.Via.parse(value)
              rescue
                # Keep as string if parsing fails
                _ -> value
              end

            is_struct(value, Via) ->
              value

            is_list(value) ->
              # Parse each string in the list
              Enum.map(value, fn
                v when is_binary(v) ->
                  try do
                    ParrotSip.Headers.Via.parse(v)
                  rescue
                    _ -> v
                  end

                v ->
                  v
              end)

            true ->
              value
          end

        %{message | via: via_value}

      "contact" ->
        %{message | contact: value}

      "content-type" ->
        %{message | content_type: value}

      "content-length" ->
        %{message | content_length: value}

      "route" ->
        # Route should be stored as a list for get_header compatibility
        route_list = if is_list(value), do: value, else: [value]
        %{message | route: route_list}

      "record-route" ->
        # Record-Route should be stored as a list
        record_route_list = if is_list(value), do: value, else: [value]
        %{message | record_route: record_route_list}

      _ ->
        other_headers = Map.put(message.other_headers || %{}, header_name, value)
        %{message | other_headers: other_headers}
    end
  end

  @doc """
  Returns the branch parameter from the top Via header.
  """
  @spec branch(t()) :: String.t() | nil
  def branch(%__MODULE__{via: nil}), do: nil
  def branch(%__MODULE__{via: %Via{parameters: %{"branch" => branch}}}), do: branch
  def branch(%__MODULE__{via: [%Via{parameters: %{"branch" => branch}} | _]}), do: branch
  def branch(%__MODULE__{via: %Via{}}), do: nil
  def branch(%__MODULE__{via: [%Via{} | _]}), do: nil
  def branch(_), do: nil

  @doc """
  Returns multiple headers of the same name from the message.
  For backward compatibility with tests expecting get_headers/2.
  """
  @spec get_headers(t(), String.t()) :: [any()]
  def get_headers(%__MODULE__{via: nil}, "via"), do: []
  def get_headers(%__MODULE__{via: headers}, "via") when is_list(headers), do: headers
  def get_headers(%__MODULE__{via: header}, "via"), do: [header]

  def get_headers(%__MODULE__{route: nil}, "route"), do: []
  def get_headers(%__MODULE__{route: headers}, "route") when is_list(headers), do: headers
  def get_headers(%__MODULE__{route: header}, "route"), do: [header]

  def get_headers(%__MODULE__{record_route: nil}, "record-route"), do: []

  def get_headers(%__MODULE__{record_route: headers}, "record-route") when is_list(headers),
    do: headers

  def get_headers(%__MODULE__{record_route: header}, "record-route"), do: [header]

  def get_headers(%__MODULE__{} = message, header_name) do
    header_name = String.downcase(header_name)

    case get_header(message, header_name) do
      nil -> []
      header -> [header]
    end
  end
end
