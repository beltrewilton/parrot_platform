defmodule ParrotSip.ValidatorsTest do
  use ExUnit.Case, async: true

  alias ParrotSip.{Validators, Message}
  alias ParrotSip.Headers.{Via, From, To, CSeq}

  @moduletag :validators

  describe "validate_uri/1" do
    test "validates valid SIP URIs" do
      assert :ok = Validators.validate_uri("sip:alice@example.com")
      assert :ok = Validators.validate_uri("sip:bob@192.168.1.1")
      assert :ok = Validators.validate_uri("sip:user@domain.com:5060")
      assert :ok = Validators.validate_uri("sips:secure@example.com")
    end

    test "validates URIs with parameters" do
      assert :ok = Validators.validate_uri("sip:alice@example.com;transport=tcp")
      assert :ok = Validators.validate_uri("sip:bob@example.com;lr;transport=udp")
    end

    test "validates URIs with headers" do
      assert :ok = Validators.validate_uri("sip:alice@example.com?subject=hello")
      assert :ok = Validators.validate_uri("sip:bob@example.com?priority=urgent&subject=test")
    end

    test "rejects invalid URI schemes" do
      assert {:error, :invalid_uri_format} = Validators.validate_uri("http://example.com")
      assert {:error, :invalid_uri_format} = Validators.validate_uri("ftp://files.example.com")
      assert {:error, :invalid_uri_format} = Validators.validate_uri("mailto:alice@example.com")
    end

    test "rejects malformed URIs" do
      assert {:error, :invalid_uri_format} = Validators.validate_uri("not-a-uri")
      assert {:error, :invalid_uri_format} = Validators.validate_uri("sip:")
      assert {:error, :invalid_uri_format} = Validators.validate_uri("sip:@")
      assert {:error, :invalid_uri_format} = Validators.validate_uri("")
    end

    test "rejects non-string inputs" do
      assert {:error, :invalid_uri_type} = Validators.validate_uri(nil)
      assert {:error, :invalid_uri_type} = Validators.validate_uri(123)
      assert {:error, :invalid_uri_type} = Validators.validate_uri(%{})
      assert {:error, :invalid_uri_type} = Validators.validate_uri(:atom)
    end

    test "rejects URIs without host" do
      # These should be rejected by the URI parser
      assert {:error, :invalid_uri_format} = Validators.validate_uri("sip:alice@")
    end
  end

  describe "validate_sdp/1" do
    test "validates minimal valid SDP" do
      sdp = """
      v=0\r
      o=- 123 456 IN IP4 192.168.1.1\r
      s=-\r
      c=IN IP4 192.168.1.1\r
      t=0 0\r
      """

      assert :ok = Validators.validate_sdp(sdp)
    end

    test "validates SDP with media description" do
      sdp = """
      v=0\r
      o=alice 123 456 IN IP4 192.168.1.1\r
      s=Test Session\r
      c=IN IP4 192.168.1.1\r
      t=0 0\r
      m=audio 5004 RTP/AVP 0\r
      a=rtpmap:0 PCMU/8000\r
      """

      assert :ok = Validators.validate_sdp(sdp)
    end

    test "validates SDP with multiple media lines" do
      sdp = """
      v=0\r
      o=conference 123 456 IN IP4 192.168.1.1\r
      s=Audio/Video Conference\r
      c=IN IP4 192.168.1.1\r
      t=0 0\r
      m=audio 5004 RTP/AVP 0\r
      a=rtpmap:0 PCMU/8000\r
      m=video 5006 RTP/AVP 96\r
      a=rtpmap:96 H264/90000\r
      """

      assert :ok = Validators.validate_sdp(sdp)
    end

    test "rejects SDP missing required fields" do
      # Missing version
      sdp_no_v = """
      o=- 123 456 IN IP4 192.168.1.1\r
      s=-\r
      """

      assert {:error, :missing_required_sdp_fields} = Validators.validate_sdp(sdp_no_v)

      # Missing origin
      sdp_no_o = """
      v=0\r
      s=-\r
      """

      assert {:error, :missing_required_sdp_fields} = Validators.validate_sdp(sdp_no_o)

      # Missing session name
      sdp_no_s = """
      v=0\r
      o=- 123 456 IN IP4 192.168.1.1\r
      """

      assert {:error, :missing_required_sdp_fields} = Validators.validate_sdp(sdp_no_s)
    end

    test "rejects SDP with invalid format" do
      # Invalid line format (missing =)
      invalid_sdp = """
      v=0\r
      o- 123 456 IN IP4 192.168.1.1\r
      s=-\r
      """

      # This fails required field validation before format validation
      assert {:error, :missing_required_sdp_fields} = Validators.validate_sdp(invalid_sdp)
    end

    test "rejects SDP with invalid line prefixes" do
      # Invalid line prefix
      invalid_sdp = """
      v=0\r
      o=- 123 456 IN IP4 192.168.1.1\r
      s=-\r
      x=invalid line\r
      """

      assert {:error, :invalid_sdp_format} = Validators.validate_sdp(invalid_sdp)
    end

    test "rejects non-string SDP" do
      assert {:error, :invalid_sdp_type} = Validators.validate_sdp(nil)
      assert {:error, :invalid_sdp_type} = Validators.validate_sdp(123)
      assert {:error, :invalid_sdp_type} = Validators.validate_sdp(%{})
    end

    test "handles empty SDP" do
      assert {:error, :missing_required_sdp_fields} = Validators.validate_sdp("")
    end
  end

  describe "validate_method/1" do
    test "validates standard SIP methods" do
      assert :ok = Validators.validate_method(:invite)
      assert :ok = Validators.validate_method(:ack)
      assert :ok = Validators.validate_method(:bye)
      assert :ok = Validators.validate_method(:cancel)
      assert :ok = Validators.validate_method(:options)
      assert :ok = Validators.validate_method(:register)
    end

    test "validates extension methods" do
      assert :ok = Validators.validate_method(:info)
      assert :ok = Validators.validate_method(:prack)
      assert :ok = Validators.validate_method(:update)
    end

    test "rejects unsupported methods" do
      assert {:error, :unsupported_method} = Validators.validate_method(:unknown)
      assert {:error, :unsupported_method} = Validators.validate_method(:custom)
      assert {:error, :unsupported_method} = Validators.validate_method(:test)
    end

    test "rejects non-atom methods" do
      assert {:error, :invalid_method_type} = Validators.validate_method("INVITE")
      assert {:error, :invalid_method_type} = Validators.validate_method(nil)
      assert {:error, :invalid_method_type} = Validators.validate_method(123)
    end
  end

  describe "validate_message/1" do
    test "validates complete SIP request" do
      message = build_valid_request()
      assert :ok = Validators.validate_message(message)
    end

    test "validates complete SIP response" do
      message = build_valid_response()
      assert :ok = Validators.validate_message(message)
    end

    test "validates request with supported methods" do
      methods = [:invite, :ack, :bye, :cancel, :options, :register, :info, :prack, :update]

      for method <- methods do
        message = build_valid_request() |> Map.put(:method, method)
        assert :ok = Validators.validate_message(message)
      end
    end

    test "rejects request with unsupported method" do
      message = build_valid_request() |> Map.put(:method, :unknown)
      assert {:error, :unsupported_method} = Validators.validate_message(message)
    end

    test "rejects request missing required headers" do
      base_message = build_valid_request()

      # Missing Via
      message_no_via = %{base_message | via: nil}
      assert {:error, :missing_required_headers} = Validators.validate_message(message_no_via)

      # Missing From
      message_no_from = %{base_message | from: nil}
      assert {:error, :missing_required_headers} = Validators.validate_message(message_no_from)

      # Missing To
      message_no_to = %{base_message | to: nil}
      assert {:error, :missing_required_headers} = Validators.validate_message(message_no_to)

      # Missing Call-ID
      message_no_call_id = %{base_message | call_id: nil}
      assert {:error, :missing_required_headers} = Validators.validate_message(message_no_call_id)

      # Missing CSeq
      message_no_cseq = %{base_message | cseq: nil}
      assert {:error, :missing_required_headers} = Validators.validate_message(message_no_cseq)
    end

    test "rejects response missing required headers" do
      base_message = build_valid_response()

      # Missing Via
      message_no_via = %{base_message | via: nil}
      assert {:error, :missing_required_headers} = Validators.validate_message(message_no_via)

      # Missing From
      message_no_from = %{base_message | from: nil}
      assert {:error, :missing_required_headers} = Validators.validate_message(message_no_from)

      # Missing To
      message_no_to = %{base_message | to: nil}
      assert {:error, :missing_required_headers} = Validators.validate_message(message_no_to)

      # Missing Call-ID
      message_no_call_id = %{base_message | call_id: nil}
      assert {:error, :missing_required_headers} = Validators.validate_message(message_no_call_id)

      # Missing CSeq
      message_no_cseq = %{base_message | cseq: nil}
      assert {:error, :missing_required_headers} = Validators.validate_message(message_no_cseq)
    end

    test "rejects request with invalid request URI" do
      message = build_valid_request() |> Map.put(:request_uri, "http://example.com")
      assert {:error, :invalid_request_uri} = Validators.validate_message(message)

      message = build_valid_request() |> Map.put(:request_uri, nil)
      assert {:error, :invalid_request_uri} = Validators.validate_message(message)
    end

    test "rejects response with invalid status code" do
      message = build_valid_response() |> Map.put(:status_code, 999)
      assert {:error, :invalid_status_code} = Validators.validate_message(message)

      message = build_valid_response() |> Map.put(:status_code, 99)
      assert {:error, :invalid_status_code} = Validators.validate_message(message)
    end

    test "rejects non-Message structs" do
      assert {:error, :invalid_message_type} = Validators.validate_message(nil)
      assert {:error, :invalid_message_type} = Validators.validate_message(%{})
      assert {:error, :invalid_message_type} = Validators.validate_message("invalid")
    end
  end

  describe "validate_status_code/1" do
    test "validates 1xx provisional responses" do
      assert :ok = Validators.validate_status_code(100)
      assert :ok = Validators.validate_status_code(180)
      assert :ok = Validators.validate_status_code(199)
    end

    test "validates 2xx successful responses" do
      assert :ok = Validators.validate_status_code(200)
      assert :ok = Validators.validate_status_code(202)
      assert :ok = Validators.validate_status_code(299)
    end

    test "validates 3xx redirection responses" do
      assert :ok = Validators.validate_status_code(300)
      assert :ok = Validators.validate_status_code(301)
      assert :ok = Validators.validate_status_code(302)
      assert :ok = Validators.validate_status_code(399)
    end

    test "validates 4xx client error responses" do
      assert :ok = Validators.validate_status_code(400)
      assert :ok = Validators.validate_status_code(404)
      assert :ok = Validators.validate_status_code(486)
      assert :ok = Validators.validate_status_code(499)
    end

    test "validates 5xx server error responses" do
      assert :ok = Validators.validate_status_code(500)
      assert :ok = Validators.validate_status_code(503)
      assert :ok = Validators.validate_status_code(599)
    end

    test "validates 6xx global failure responses" do
      assert :ok = Validators.validate_status_code(600)
      assert :ok = Validators.validate_status_code(603)
      assert :ok = Validators.validate_status_code(699)
    end

    test "rejects invalid status codes" do
      assert {:error, :invalid_status_code} = Validators.validate_status_code(99)
      assert {:error, :invalid_status_code} = Validators.validate_status_code(700)
      assert {:error, :invalid_status_code} = Validators.validate_status_code(1000)
    end

    test "rejects non-integer status codes" do
      assert {:error, :invalid_status_code} = Validators.validate_status_code("200")
      assert {:error, :invalid_status_code} = Validators.validate_status_code(nil)
      assert {:error, :invalid_status_code} = Validators.validate_status_code(200.5)
    end
  end

  describe "edge cases and integration" do
    test "validates complex request with all headers" do
      message = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        version: "SIP/2.0",
        via: [build_via_header()],
        from: build_from_header(),
        to: build_to_header(),
        call_id: "abc123@client.example.com",
        cseq: %CSeq{number: 1, method: :invite},
        max_forwards: 70,
        contact: nil,
        route: nil,
        record_route: nil,
        content_type: "application/sdp",
        content_length: 142,
        expires: nil,
        allow: nil,
        supported: nil,
        accept: nil,
        event: nil,
        subscription_state: nil,
        refer_to: nil,
        subject: "Test call",
        other_headers: %{"X-Custom" => "value"},
        body: "v=0\r\no=alice 123 456 IN IP4 192.168.1.1\r\ns=-\r\n"
      }

      assert :ok = Validators.validate_message(message)
    end

    test "validates response with all required fields" do
      message = %Message{
        type: :response,
        method: nil,
        request_uri: nil,
        status_code: 200,
        reason_phrase: "OK",
        version: "SIP/2.0",
        via: [build_via_header()],
        from: build_from_header(),
        to: build_to_header(),
        call_id: "abc123@client.example.com",
        cseq: %CSeq{number: 1, method: :invite},
        max_forwards: nil,
        contact: nil,
        route: nil,
        record_route: nil,
        content_type: nil,
        content_length: 0,
        expires: nil,
        allow: nil,
        supported: nil,
        accept: nil,
        event: nil,
        subscription_state: nil,
        refer_to: nil,
        subject: nil,
        other_headers: nil,
        body: ""
      }

      assert :ok = Validators.validate_message(message)
    end

    test "handles other_headers correctly" do
      message =
        build_valid_request()
        |> Map.put(:other_headers, %{
          "x-custom-header" => "custom-value",
          "proxy-authorization" => "Digest username=\"alice\""
        })

      assert :ok = Validators.validate_message(message)
    end
  end

  # Helper functions

  defp build_valid_request do
    %Message{
      type: :request,
      method: :invite,
      request_uri: "sip:bob@example.com",
      version: "SIP/2.0",
      via: [build_via_header()],
      from: build_from_header(),
      to: build_to_header(),
      call_id: "test-call-id@example.com",
      cseq: %CSeq{number: 1, method: :invite},
      max_forwards: 70,
      body: ""
    }
  end

  defp build_valid_response do
    %Message{
      type: :response,
      status_code: 200,
      reason_phrase: "OK",
      version: "SIP/2.0",
      via: [build_via_header()],
      from: build_from_header(),
      to: build_to_header(),
      call_id: "test-call-id@example.com",
      cseq: %CSeq{number: 1, method: :invite},
      body: ""
    }
  end

  defp build_via_header do
    %Via{
      protocol: "SIP",
      version: "2.0",
      transport: :udp,
      host: "client.example.com",
      port: 5060,
      parameters: %{"branch" => "z9hG4bK776asdhds"}
    }
  end

  defp build_from_header do
    %From{
      display_name: "Alice",
      uri: "sip:alice@example.com",
      parameters: %{"tag" => "1928301774"}
    }
  end

  defp build_to_header do
    %To{
      display_name: nil,
      uri: "sip:bob@example.com",
      parameters: %{}
    }
  end
end
