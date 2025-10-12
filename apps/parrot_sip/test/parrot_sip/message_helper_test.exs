defmodule ParrotSip.MessageHelperTest do
  use ExUnit.Case, async: true
  doctest ParrotSip.MessageHelper

  alias ParrotSip.Message
  alias ParrotSip.MessageHelper

  describe "set_received_parameter/2" do
    test "adds received parameter to Via header" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse("SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9")
        ]
      }

      updated = MessageHelper.set_received_parameter(message, "192.168.1.1")

      # Direct access to via field - get first via from list
      via_string = ParrotSip.Headers.Via.format(hd(updated.via))
      assert via_string =~ "received=192.168.1.1"
    end

    test "replaces existing received parameter" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse(
            "SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9;received=10.0.0.1"
          )
        ]
      }

      updated = MessageHelper.set_received_parameter(message, "192.168.1.1")

      via_string = ParrotSip.Headers.Via.format(hd(updated.via))
      assert via_string =~ "received=192.168.1.1"
      refute via_string =~ "received=10.0.0.1"
    end

    test "returns message unchanged when no Via header" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: []
      }

      updated = MessageHelper.set_received_parameter(message, "192.168.1.1")

      assert updated == message
    end
  end

  describe "set_rport_parameter/2" do
    test "adds rport parameter with value to Via header" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse("SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9")
        ]
      }

      updated = MessageHelper.set_rport_parameter(message, 12345)

      via_string = ParrotSip.Headers.Via.format(hd(updated.via))
      assert via_string =~ "rport=12345"
    end

    test "replaces empty rport parameter" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse(
            "SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9;rport"
          )
        ]
      }

      updated = MessageHelper.set_rport_parameter(message, 12345)

      via_string = ParrotSip.Headers.Via.format(hd(updated.via))
      assert via_string =~ "rport=12345"
      refute via_string =~ "rport;"
    end

    test "replaces existing rport parameter value" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse(
            "SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9;rport=9999"
          )
        ]
      }

      updated = MessageHelper.set_rport_parameter(message, 12345)

      via_string = ParrotSip.Headers.Via.format(hd(updated.via))
      assert via_string =~ "rport=12345"
      refute via_string =~ "rport=9999"
    end
  end

  describe "remove_top_via/1" do
    test "removes the top Via header when only one is present" do
      message = %Message{
        status_code: 200,
        reason_phrase: "OK",
        type: :response,
        via: [
          ParrotSip.Headers.Via.parse("SIP/2.0/UDP server.biloxi.com:5060;branch=z9hG4bK74bf9")
        ]
      }

      updated = MessageHelper.remove_top_via(message)
      assert updated.via == []
    end

    test "removes only the top Via header when multiple are present" do
      message = %Message{
        status_code: 200,
        reason_phrase: "OK",
        type: :response,
        via: [
          ParrotSip.Headers.Via.parse("SIP/2.0/UDP server.biloxi.com:5060;branch=z9hG4bK74bf9"),
          ParrotSip.Headers.Via.parse("SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf8")
        ]
      }

      updated = MessageHelper.remove_top_via(message)

      # Direct access to via field - should only have one element now in the list
      assert [via] = updated.via
      assert via.host == "client.atlanta.com"
    end

    test "returns message unchanged when no Via headers" do
      message = %Message{
        status_code: 200,
        reason_phrase: "OK",
        type: :response,
        via: []
      }

      updated = MessageHelper.remove_top_via(message)

      assert updated == message
    end
  end

  describe "apply_nat_handling/2" do
    test "adds both received and rport parameters when needed" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse(
            "SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9;rport"
          )
        ]
      }

      source_info = %{host: "192.168.1.100", port: 12345}

      updated = MessageHelper.apply_nat_handling(message, source_info)

      assert hd(updated.via).parameters["received"] == "192.168.1.100"
      assert hd(updated.via).parameters["rport"] == "12345"
    end

    test "only adds received parameter when host differs" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse("SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9")
        ]
      }

      source_info = %{host: "192.168.1.100", port: 5060}

      updated = MessageHelper.apply_nat_handling(message, source_info)

      assert hd(updated.via).parameters["received"] == "192.168.1.100"
    end

    test "only adds rport parameter when empty rport present and port differs" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse("SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK74bf9;rport")
        ]
      }

      source_info = %{host: "192.168.1.100", port: 12345}

      updated = MessageHelper.apply_nat_handling(message, source_info)

      assert hd(updated.via).parameters["rport"] == "12345"
    end
  end

  describe "symmetric_response_routing/2" do
    test "sets response source based on received and rport in request" do
      request = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse(
            "SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9;received=192.168.1.100;rport=12345"
          )
        ]
      }

      response = %Message{status_code: 200, reason_phrase: "OK", type: :response}

      routed_response = MessageHelper.symmetric_response_routing(request, response)

      assert routed_response.source.type == :udp
      assert routed_response.source.host == "192.168.1.100"
      assert routed_response.source.port == 12345
    end

    test "falls back to Via host/port when no received/rport" do
      request = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse("SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9")
        ]
      }

      response = %Message{status_code: 200, reason_phrase: "OK", type: :response}

      routed_response = MessageHelper.symmetric_response_routing(request, response)

      assert routed_response.source.type == :udp
      assert routed_response.source.host == "client.atlanta.com"
      assert routed_response.source.port == 5060
    end

    test "uses received but falls back to Via port when no rport value" do
      request = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse(
            "SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9;received=192.168.1.100;rport"
          )
        ]
      }

      response = Message.new_response(200, "OK", %{}, [])

      routed_response = MessageHelper.symmetric_response_routing(request, response)

      assert routed_response.source.host == "192.168.1.100"
      assert routed_response.source.port == 5060
    end

    test "extracts transport type from Via" do
      request = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        via: [
          ParrotSip.Headers.Via.parse("SIP/2.0/TLS client.atlanta.com:5061;branch=z9hG4bK74bf9")
        ]
      }

      response = %Message{status_code: 200, reason_phrase: "OK", type: :response}

      routed_response = MessageHelper.symmetric_response_routing(request, response)

      assert routed_response.source.type == :tls
    end
  end

  describe "add_route_header/3" do
    test "adds a route header when none exists" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        route: nil
      }

      updated =
        MessageHelper.add_route_header(message, %ParrotSip.Headers.Route{
          uri: "sip:proxy.biloxi.com;lr"
        })

      assert updated.route == [%ParrotSip.Headers.Route{uri: "sip:proxy.biloxi.com;lr"}]
    end

    test "prepends route when one already exists" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        route: [%ParrotSip.Headers.Route{uri: "sip:proxy1.atlanta.com;lr"}]
      }

      updated =
        MessageHelper.add_route_header(message, %ParrotSip.Headers.Route{
          uri: "sip:proxy2.biloxi.com;lr"
        })

      assert is_list(updated.route)
      assert length(updated.route) == 2
      assert hd(updated.route) == %ParrotSip.Headers.Route{uri: "sip:proxy2.biloxi.com;lr"}
    end

    test "appends route when prepend is false" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        route: [%ParrotSip.Headers.Route{uri: "sip:proxy1.atlanta.com;lr"}]
      }

      updated =
        MessageHelper.add_route_header(
          message,
          %ParrotSip.Headers.Route{uri: "sip:proxy2.biloxi.com;lr"},
          false
        )

      assert is_list(updated.route)
      assert length(updated.route) == 2
      assert List.last(updated.route) == %ParrotSip.Headers.Route{uri: "sip:proxy2.biloxi.com;lr"}
    end
  end

  describe "add_record_route/2" do
    test "adds a record-route header when none exists" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        record_route: nil
      }

      updated =
        MessageHelper.add_record_route(message, %ParrotSip.Headers.RecordRoute{
          uri: "sip:proxy.biloxi.com;lr"
        })

      assert updated.record_route == [
               %ParrotSip.Headers.RecordRoute{uri: "sip:proxy.biloxi.com;lr"}
             ]
    end

    test "prepends record-route when one already exists" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        record_route: [%ParrotSip.Headers.RecordRoute{uri: "sip:proxy1.atlanta.com;lr"}]
      }

      updated =
        MessageHelper.add_record_route(message, %ParrotSip.Headers.RecordRoute{
          uri: "sip:proxy2.biloxi.com;lr"
        })

      assert is_list(updated.record_route)
      assert length(updated.record_route) == 2

      assert hd(updated.record_route) == %ParrotSip.Headers.RecordRoute{
               uri: "sip:proxy2.biloxi.com;lr"
             }
    end
  end

  describe "extract_multipart_part/2" do
    test "extracts a part from multipart body by content type" do
      # Create a message with multipart parts in headers
      sdp_part = %{
        headers: %{"content-type" => "application/sdp"},
        body: "v=0\r\no=alice 2890844526 2890844526 IN IP4 alice.atlanta.com\r\n"
      }

      isup_part = %{
        headers: %{"content-type" => "application/isup"},
        body: "ISUP data here"
      }

      message = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        content_type: %ParrotSip.Headers.ContentType{
          type: "multipart",
          subtype: "mixed",
          parameters: %{"boundary" => "boundary1"}
        },
        other_headers: %{
          "multipart-parts" => [sdp_part, isup_part]
        }
      }

      # Extract SDP part
      {:ok, part} = MessageHelper.extract_multipart_part(message, "application/sdp")
      assert part.body =~ "v=0"
      assert get_in(part, [:headers, "content-type"]) == "application/sdp"

      # Extract ISUP part
      {:ok, part} = MessageHelper.extract_multipart_part(message, "application/isup")
      assert part.body =~ "ISUP data here"
    end

    test "returns error when no part with matching content type" do
      message = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        content_type: %ParrotSip.Headers.ContentType{
          type: "multipart",
          subtype: "mixed",
          parameters: %{"boundary" => "boundary1"}
        },
        other_headers: %{
          "multipart-parts" => [
            %{
              headers: %{"content-type" => "application/sdp"},
              body: "v=0\r\n"
            }
          ]
        }
      }

      {:error, reason} = MessageHelper.extract_multipart_part(message, "application/isup")
      assert reason =~ "No part with content type"
    end

    test "returns error when message has no multipart parts" do
      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        type: :request,
        other_headers: %{}
      }

      {:error, reason} = MessageHelper.extract_multipart_part(message, "application/sdp")
      assert reason =~ "does not contain parsed multipart body"
    end
  end
end
