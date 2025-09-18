defmodule ParrotSip.HandlerAdapter.ResponseHandler do
  @moduledoc """
  Functions for handling SIP responses.

  This module handles the processing of responses from user handlers,
  including formatting and sending responses through the UAS layer.
  """

  require Logger
  alias ParrotSip.{UAS, Message}

  @doc """
  Processes a response from the user handler and sends it via the UAS.

  This function takes a response tuple from the user handler, constructs a proper
  SIP response message, and sends it through the UAS layer.

  ## Parameters

    * `response` - The response tuple from the user handler
    * `uas` - The UAS object
    * `req_sip_msg` - The original request SIP message

  ## Returns

  The return value of `UAS.response/2`
  """
  def process_user_response({:respond, status, reason, headers, body}, uas, req_sip_msg) do
    Logger.debug("Processing user response: #{status} #{reason}")

    resp = UAS.make_reply(status, reason, uas, req_sip_msg)
    resp_with_headers = add_headers(resp, headers)
    resp_with_body = ParrotSip.Message.set_body(resp_with_headers, body)
    UAS.response(resp_with_body, uas)
  end

  def process_user_response({:proxy, uri}, uas, req_sip_msg) do
    Logger.info("Proxying request to #{uri}")
    proxy_request(uri, req_sip_msg, uas)
  end

  def process_user_response({:b2bua, _uri}, _uas, _req_sip_msg) do
    Logger.warning("B2BUA functionality has been removed")
    {:respond, 501, "Not Implemented", %{}, "", %{}}
  end

  def process_user_response(:noreply, _uas, _req_sip_msg) do
    Logger.debug("User handler returned :noreply.")
    :ok
  end

  def process_user_response(other, _uas, _req_sip_msg) do
    Logger.error("Unknown user response format: #{inspect(other)}")
    :ok
  end

  # Private functions

  defp add_headers(sip_msg, headers) do
    alias ParrotSip.HandlerAdapter.HeaderHandler
    HeaderHandler.add_headers(sip_msg, headers)
  end

  @doc """
  Proxies a SIP request to another URI.

  This function implements SIP proxying by forwarding the request to another URI
  and relaying the responses back to the original sender.

  For INVITE requests, it sends a provisional 100 Trying response first.

  ## Parameters

    * `uri` - The target URI to proxy the request to
    * `req_sip_msg` - The original SIP request message
    * `uas_obj` - The UAS object representing the original transaction

  ## Returns

  `:ok`
  """
  def proxy_request(uri, %Message{method: :invite} = req_sip_msg, uas_obj) do
    # Send provisional response for INVITE
    trying_resp = UAS.make_reply(100, "Trying", uas_obj, req_sip_msg)
    UAS.response(trying_resp, uas_obj)
    
    do_proxy_request(uri, req_sip_msg, uas_obj)
  end
  
  def proxy_request(uri, req_sip_msg, uas_obj) do
    do_proxy_request(uri, req_sip_msg, uas_obj)
  end
  
  defp do_proxy_request(uri, req_sip_msg, uas_obj) do
    forward_sip_msg = prepare_request_for_forwarding(req_sip_msg, uri)

    ParrotSip.UAC.request(forward_sip_msg, fn response ->
      case response do
        {:message, resp_sip_msg} ->
          forwarded_resp = prepare_response_for_forwarding(resp_sip_msg, req_sip_msg)
          UAS.response(forwarded_resp, uas_obj)

        {:stop, reason} ->
          Logger.warning("Proxy request failed: #{inspect(reason)}")
          error_resp = UAS.make_reply(500, "Proxy Error", uas_obj, req_sip_msg)
          UAS.response(error_resp, uas_obj)
      end
    end)

    :ok
  end

  @doc """
  Prepares a SIP request for forwarding to another URI.

  This function modifies a SIP request to prepare it for forwarding to a different
  destination. It:

  1. Updates the Request-URI to the target URI
  2. Decrements the Max-Forwards header to prevent infinite loops
  3. For INVITE requests, adds a Record-Route header to ensure responses are routed back
     through this proxy

  ## Parameters

    * `req_sip_msg` - The original SIP request message
    * `target_uri` - The target URI to forward the request to

  ## Returns

  The modified SIP request message ready for forwarding
  """
  def prepare_request_for_forwarding(%Message{method: :invite} = req_sip_msg, target_uri) do
    # Process basic forwarding updates
    req = prepare_basic_forwarding(req_sip_msg, target_uri)
    
    # Add Record-Route for INVITE
    local_uri = Application.get_env(:parrot_sip, :local_uri, "sip:localhost:5060")
    record_route_hdr = ParrotSip.Headers.RecordRoute.new(local_uri)

    existing_routes =
      case req.record_route do
        nil -> []
        r -> List.wrap(r)
      end

    %{req | record_route: [record_route_hdr | existing_routes]}
  end
  
  def prepare_request_for_forwarding(req_sip_msg, target_uri) do
    prepare_basic_forwarding(req_sip_msg, target_uri)
  end
  
  defp prepare_basic_forwarding(req_sip_msg, target_uri) do
    # Set the new request URI
    req1 = %{req_sip_msg | request_uri: target_uri}

    # Decrement Max-Forwards
    max_forwards_val =
      case req1.max_forwards do
        nil -> ParrotSip.Headers.MaxForwards.default()
        val -> val
      end

    new_max_forwards =
      case ParrotSip.Headers.MaxForwards.decrement(max_forwards_val) do
        nil -> 0
        v -> v
      end

    %{req1 | max_forwards: new_max_forwards}
  end

  @doc """
  Prepares a SIP response for forwarding to the original requester.

  This function takes a response received from the forwarded request and
  prepares it to be sent back to the original requester. It:

  1. Creates a new response to the original request with the same status code
  2. Copies the body from the received response
  3. Copies essential headers (Contact, Content-Type, Record-Route) from the received response

  ## Parameters

    * `resp_sip_msg` - The response received from the forwarded request
    * `orig_req_sip_msg` - The original request from the initial requester

  ## Returns

  The modified SIP response message ready to send back to the original requester
  """
  def prepare_response_for_forwarding(resp_sip_msg, orig_req_sip_msg) do
    status = resp_sip_msg.status_code
    reason = resp_sip_msg.reason_phrase || ParrotSip.Message.default_reason_phrase(status)
    base_resp = ParrotSip.Message.reply(orig_req_sip_msg, status, reason)
    resp_with_body = ParrotSip.Message.set_body(base_resp, resp_sip_msg.body)

    # Add other necessary headers
    headers_to_copy = ["contact", "content-type", "record-route"]

    Enum.reduce(headers_to_copy, resp_with_body, fn header_key, acc_resp ->
      case get_header_value(resp_sip_msg, header_key) do
        nil -> acc_resp
        value -> set_header_value(acc_resp, header_key, value)
      end
    end)
  end

  # Helper function to get header value from Message struct
  defp get_header_value(message, header_name) do
    case String.downcase(header_name) do
      "from" -> message.from
      "to" -> message.to
      "via" -> message.via
      "call-id" -> message.call_id
      "cseq" -> message.cseq
      "contact" -> message.contact
      "route" -> message.route
      "record-route" -> message.record_route
      "max-forwards" -> message.max_forwards
      "content-type" -> message.content_type
      "content-length" -> message.content_length
      "expires" -> message.expires
      "allow" -> message.allow
      "supported" -> message.supported
      "accept" -> message.accept
      "event" -> message.event
      "subscription-state" -> message.subscription_state
      "refer-to" -> message.refer_to
      "subject" -> message.subject
      _ -> Map.get(message.other_headers || %{}, header_name)
    end
  end

  # Helper function to set header value on Message struct
  defp set_header_value(message, header_name, value) do
    case String.downcase(header_name) do
      "from" -> %{message | from: value}
      "to" -> %{message | to: value}
      "via" -> %{message | via: value}
      "call-id" -> %{message | call_id: value}
      "cseq" -> %{message | cseq: value}
      "contact" -> %{message | contact: value}
      "route" -> %{message | route: value}
      "record-route" -> %{message | record_route: value}
      "max-forwards" -> %{message | max_forwards: value}
      "content-type" -> %{message | content_type: value}
      "content-length" -> %{message | content_length: value}
      "expires" -> %{message | expires: value}
      "allow" -> %{message | allow: value}
      "supported" -> %{message | supported: value}
      "accept" -> %{message | accept: value}
      "event" -> %{message | event: value}
      "subscription-state" -> %{message | subscription_state: value}
      "refer-to" -> %{message | refer_to: value}
      "subject" -> %{message | subject: value}
      _ -> 
        other = message.other_headers || %{}
        %{message | other_headers: Map.put(other, header_name, value)}
    end
  end
end
