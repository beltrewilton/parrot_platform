defmodule ParrotSip.MessageHelper do
  @moduledoc """
  Helper functions for manipulating SIP messages.

  This module provides a set of utility functions for common SIP message operations
  that aren't directly related to serialization or deserialization. These include:

  - Via header manipulation for NAT traversal
  - Route set management
  - Dialog-related header handling
  - Multipart body handling

  References:
  - RFC 3261 Section 18.2.1: Sending Responses
  - RFC 3261 Section 18.2.2: Sending Requests
  - RFC 3261 Section 12: Dialogs
  - RFC 3581: An Extension to SIP for Symmetric Response Routing
  """

  alias ParrotSip.Message

  @doc """
  Adds or updates the 'received' parameter in the top Via header.

  This is used for NAT traversal as described in RFC 3261 Section 18.2.1,
  where a server receiving a request through a NAT should record the source
  IP address in the 'received' parameter of the top Via header.

  ## Parameters
    * `message` - A ParrotSip.Message struct
    * `ip_address` - IP address to set as the 'received' parameter

  ## Returns
    * The updated message with the 'received' parameter in the top Via

  ## Examples

      iex> message = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> message = ParrotSip.Message.set_header(message, "via", "SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9")
      iex> updated = ParrotSip.MessageHelper.set_received_parameter(message, "192.168.1.1")
      iex> ParrotSip.Message.get_header(updated, "via")
      %ParrotSip.Headers.Via{
        port: 5060,
        version: "2.0",
        protocol: "SIP",
        host: "client.atlanta.com",
        parameters: %{"branch" => "z9hG4bK74bf9", "received" => "192.168.1.1"},
        transport: :udp,
        host_type: :hostname
      }
  """
  @spec set_received_parameter(Message.t(), String.t()) :: Message.t()
  def set_received_parameter(%Message{via: nil} = message, _ip_address), do: message
  def set_received_parameter(%Message{via: via} = message, ip_address) when is_struct(via, ParrotSip.Headers.Via) do
    updated_via = ParrotSip.Headers.Via.with_parameter(via, "received", ip_address)
    %{message | via: updated_via}
  end
  def set_received_parameter(%Message{via: [first_via | rest]} = message, ip_address) when is_list(message.via) do
    updated_via = ParrotSip.Headers.Via.with_parameter(first_via, "received", ip_address)
    %{message | via: [updated_via | rest]}
  end

  @doc """
  Adds or updates the 'rport' parameter in the top Via header.

  Used for symmetric response routing as described in RFC 3581,
  where a server records the source port in the 'rport' parameter
  of the top Via header when a client includes an empty 'rport'
  parameter in its request.

  ## Parameters
    * `message` - A ParrotSip.Message struct
    * `port` - Port number to set as the 'rport' parameter

  ## Returns
    * The updated message with the 'rport' parameter in the top Via

  ## Examples

      iex> message = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> message = ParrotSip.Message.set_header(message, "via", "SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9;rport")
      iex> updated = ParrotSip.MessageHelper.set_rport_parameter(message, 12345)
      iex> ParrotSip.Message.get_header(updated, "via")
      %ParrotSip.Headers.Via{
        port: 5060,
        version: "2.0",
        protocol: "SIP",
        host: "client.atlanta.com",
        parameters: %{"branch" => "z9hG4bK74bf9", "rport" => "12345"},
        transport: :udp,
        host_type: :hostname
      }
  """
  @spec set_rport_parameter(Message.t(), non_neg_integer()) :: Message.t()
  def set_rport_parameter(%Message{via: nil} = message, _port), do: message
  def set_rport_parameter(%Message{via: via} = message, port) when is_struct(via, ParrotSip.Headers.Via) do
    updated_via = ParrotSip.Headers.Via.with_parameter(via, "rport", Integer.to_string(port))
    %{message | via: updated_via}
  end
  def set_rport_parameter(%Message{via: [first_via | rest]} = message, port) when is_list(message.via) do
    updated_via = ParrotSip.Headers.Via.with_parameter(first_via, "rport", Integer.to_string(port))
    %{message | via: [updated_via | rest]}
  end

  @doc """
  Removes the top Via header from a message.

  This is used when forwarding responses, as each server
  in the response path removes the top Via header before
  forwarding the response.

  ## Parameters
    * `message` - A ParrotSip.Message struct

  ## Returns
    * The updated message with the top Via header removed

  ## Examples

      iex> message = ParrotSip.Message.new_response(200, "OK")
      iex> message = ParrotSip.Message.set_header(message, "via", ["SIP/2.0/UDP proxy.biloxi.com:5060;branch=z9hG4bK74bf9", "SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9"])
      iex> updated = ParrotSip.MessageHelper.remove_top_via(message)
      iex> ParrotSip.Message.get_header(updated, "via")
      [
        %ParrotSip.Headers.Via{
          port: 5060,
          version: "2.0",
          protocol: "SIP",
          host: "client.atlanta.com",
          parameters: %{"branch" => "z9hG4bK74bf9"},
          transport: :udp,
          host_type: :hostname
        }
      ]
  """
  @spec remove_top_via(Message.t()) :: Message.t()
  def remove_top_via(%Message{via: nil} = message), do: message
  def remove_top_via(%Message{via: _single_via} = message) when is_struct(message.via, ParrotSip.Headers.Via) do
    %{message | via: nil}
  end
  def remove_top_via(%Message{via: [_top | []]} = message) do
    %{message | via: []}
  end
  def remove_top_via(%Message{via: [_top | rest]} = message) when is_list(message.via) do
    # Always keep as list to preserve the original type
    %{message | via: rest}
  end

  @doc """
  Applies NAT traversal handling to a message based on source information.

  This function handles both the 'received' and 'rport' parameters,
  which are used for symmetric response routing through NATs.

  ## Parameters
    * `message` - A ParrotSip.Message struct
    * `source_info` - Map containing source information with host and port

  ## Returns
    * The updated message with NAT handling applied

  ## Examples

      iex> message = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> via = ParrotSip.Headers.Via.parse("SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9;rport")
      iex> message = ParrotSip.Message.set_header(message, "via", via)
      iex> source_info = %{host: "192.168.1.100", port: 12345}
      iex> updated = ParrotSip.MessageHelper.apply_nat_handling(message, source_info)
      iex> ParrotSip.Message.get_header(updated, "via")
      %ParrotSip.Headers.Via{
        port: 5060,
        version: "2.0",
        protocol: "SIP",
        host: "client.atlanta.com",
        parameters: %{"branch" => "z9hG4bK74bf9", "received" => "192.168.1.100", "rport" => "12345"},
        transport: :udp,
        host_type: :hostname
      }
  """
  @spec apply_nat_handling(Message.t(), map()) :: Message.t()
  def apply_nat_handling(%Message{via: nil} = message, _source_info), do: message
  def apply_nat_handling(%Message{via: via} = message, %{host: host, port: port}) do
    top_via = case via do
      v when is_struct(v, ParrotSip.Headers.Via) -> v
      [v | _] when is_list(via) -> v
      _ -> nil
    end
    
    if top_via do
      # Apply changes sequentially to build the final message
      message =
        if top_via.host != host do
          # Only add received parameter if the host differs
          set_received_parameter(message, host)
        else
          message
        end

      # Check if rport is present as an empty parameter
      if Map.get(top_via.parameters, "rport") == "" and top_via.port != port do
        set_rport_parameter(message, port)
      else
        message
      end
    else
      message
    end
  end

  @doc """
  Ensures a response uses the same path as the request for symmetric routing.

  This implements symmetric response routing according to RFC 3581.
  When generating a response to a request, the response should be
  sent to the source of the request if the topmost Via has a 'received'
  parameter and/or an 'rport' parameter with a value.

  ## Parameters
    * `request` - The original request Message struct
    * `response` - The response Message struct

  ## Returns
    * The updated response with routing information from the request

  ## Examples

      iex> request = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> request = ParrotSip.Message.set_header(request, "via", "SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9;received=192.168.1.100;rport=12345")
      iex> response = ParrotSip.Message.new_response(200, "OK")
      iex> response = ParrotSip.MessageHelper.symmetric_response_routing(request, response)
      iex> response.source.host
      "192.168.1.100"
      iex> response.source.port
      12345
  """
  @spec symmetric_response_routing(Message.t(), Message.t()) :: Message.t()
  def symmetric_response_routing(%Message{via: nil} = _request, response), do: response
  def symmetric_response_routing(%Message{via: via} = _request, response) do
    top_via = case via do
      v when is_struct(v, ParrotSip.Headers.Via) -> v
      [v | _] when is_list(via) -> v
      _ -> nil
    end
    
    if top_via do
      received = Map.get(top_via.parameters, "received")
      rport = Map.get(top_via.parameters, "rport")
      
      # Determine target host and port
      host = if received && received != "", do: received, else: top_via.host
      
      port =
        case rport do
          nil -> top_via.port || 5060
          "" -> top_via.port || 5060
          value ->
            case Integer.parse(value) do
              {port_num, _} -> port_num
              :error -> top_via.port || 5060
            end
        end

      # Create source for response
      source = %{
        type: top_via.transport,
        host: host,
        port: port
      }

      # Update response with routing information
      %{response | source: source}
    else
      response
    end
  end

  @doc """
  Adds a Route header to a message.

  Used when sending requests through a specific path, such as
  when using a route set from a dialog or when routing through
  specific proxies.

  ## Parameters
    * `message` - A ParrotSip.Message struct
    * `route_uri` - URI to add as a Route header
    * `prepend` - Whether to add the Route at the beginning or end (default: true)

  ## Returns
    * The updated message with the Route header added

  ## Examples

      iex> message = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> updated = ParrotSip.MessageHelper.add_route_header(message, "<sip:proxy.biloxi.com;lr>")
      iex> ParrotSip.Message.get_header(updated, "route")
      ["<sip:proxy.biloxi.com;lr>"]

      iex> message = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> message = ParrotSip.Message.set_header(message, "route", "<sip:proxy1.atlanta.com;lr>")
      iex> updated = ParrotSip.MessageHelper.add_route_header(message, "<sip:proxy2.biloxi.com;lr>")
      iex> ParrotSip.Message.get_header(updated, "route")
      ["<sip:proxy2.biloxi.com;lr>", "<sip:proxy1.atlanta.com;lr>"]

      iex> message = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> message = ParrotSip.Message.set_header(message, "route", "<sip:proxy1.atlanta.com;lr>")
      iex> updated = ParrotSip.MessageHelper.add_route_header(message, "<sip:proxy2.biloxi.com;lr>", false)
      iex> ParrotSip.Message.get_header(updated, "route")
      ["<sip:proxy1.atlanta.com;lr>", "<sip:proxy2.biloxi.com;lr>"]
  """
  @spec add_route_header(Message.t(), ParrotSip.Headers.Route.t(), boolean()) :: Message.t()
  def add_route_header(message, route, prepend \\ true)
  def add_route_header(%Message{route: nil} = message, route, _prepend) do
    %{message | route: [route]}
  end
  def add_route_header(%Message{route: current_routes} = message, route, prepend) when is_list(current_routes) do
    updated_routes = if prepend, do: [route | current_routes], else: current_routes ++ [route]
    %{message | route: updated_routes}
  end

  @doc """
  Builds a route set from Record-Route headers in a message.

  This is used in dialog creation to establish the route set
  according to RFC 3261 Section 12.1.1.

  ## Parameters
    * `message` - A ParrotSip.Message struct

  ## Returns
    * List of route URIs or nil if no Record-Route headers are present

  ## Parameters

    * `message` - A `ParrotSip.Message` struct.
    * `record_route` - A `%ParrotSip.Headers.RecordRoute{}` struct to add.

  ## Returns

    * An updated `ParrotSip.Message` with the new `Record-Route` header prepended.

  ## Examples

      iex> rr = "<sip:proxy.biloxi.com;lr>"
      iex> message = ParrotSip.Message.new_request(:invite, "sip:bob@example.com")
      iex> updated = ParrotSip.MessageHelper.add_record_route(message, rr)
      iex> length(ParrotSip.Message.get_headers(updated, "record-route"))
  """
  @spec add_record_route(Message.t(), ParrotSip.Headers.RecordRoute.t()) :: Message.t()
  def add_record_route(%Message{record_route: nil} = message, record_route) do
    %{message | record_route: [record_route]}
  end
  def add_record_route(%Message{record_route: current} = message, record_route) when is_list(current) do
    %{message | record_route: [record_route | current]}
  end

  @doc """
  Extracts a specific part from a multipart message body based on content type.

  ## Parameters
    * `message` - A ParrotSip.Message struct with a multipart body
    * `content_type` - The content type to extract, e.g., "application/sdp"

  ## Returns
    * `{:ok, part}` - The extracted part as a map with :headers and :body fields
    * `{:error, reason}` - Error if part not found or message doesn't have multipart parts


  """
  @spec extract_multipart_part(Message.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def extract_multipart_part(%Message{other_headers: other_headers}, content_type) do
    parts = Map.get(other_headers || %{}, "multipart-parts")

    if parts do
      part =
        Enum.find(parts, fn part ->
          part_content_type = Map.get(part.headers, "content-type")
          part_content_type && String.starts_with?(part_content_type, content_type)
        end)

      if part, do: {:ok, part}, else: {:error, "No part with content type: #{content_type}"}
    else
      {:error, "Message does not contain parsed multipart body"}
    end
  end

  # Private helper functions are no longer needed since we work directly with Via structs
end
