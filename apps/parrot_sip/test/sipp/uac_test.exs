defmodule SippTest.UacTest do
  @moduledoc """
  Tests where ParrotSip acts as UAC (client) and SIPp acts as UAS (server).

  This tests the outbound calling capabilities of the ParrotSip stack.
  """
  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, SipStackHelper}
  alias ParrotSip.{Message, UAC, Source}
  alias ParrotSip.Headers.{From, To, CSeq, Contact, Via}

  @moduletag :sipp

  describe "ParrotSip as UAC - basic scenarios" do
    test "INVITE - ParrotSip makes outbound call to SIPp UAS" do
      # Start SIPp in UAS mode (listening for calls)
      sipp_port = get_random_port()

      sipp_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/basic/uas_invite.xml",
            remote_host: "127.0.0.1",
            remote_port: sipp_port,
            local_port: sipp_port,
            calls: 1,
            timeout: 15_000
          )
        end)

      # Give SIPp time to start listening
      Process.sleep(500)

      # Create minimal SIP stack (we don't need a handler since we're UAC)
      handler = ParrotSip.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Build outbound INVITE
      invite_msg = build_invite("127.0.0.1", sipp_port, stack.port)

      # Track the response
      test_pid = self()

      # Send INVITE as UAC
      _uac_id =
        UAC.request(invite_msg, fn result ->
          send(test_pid, {:uac_result, result})
        end)

      # Wait for 200 OK response
      assert_receive {:uac_result, {:response, %Message{status_code: 200}}}, 5_000

      # Wait for ACK to be processed
      Process.sleep(100)

      # Verify SIPp completed successfully
      assert :ok = Task.await(sipp_task, 10_000)

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "OPTIONS - ParrotSip sends OPTIONS to SIPp UAS" do
      # Start SIPp in UAS mode (listening for OPTIONS)
      sipp_port = get_random_port()

      sipp_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/basic/uas_options.xml",
            remote_host: "127.0.0.1",
            remote_port: sipp_port,
            local_port: sipp_port,
            calls: 1,
            timeout: 10_000
          )
        end)

      # Give SIPp time to start listening
      Process.sleep(500)

      # Create minimal SIP stack
      handler = ParrotSip.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Build outbound OPTIONS
      options_msg = build_options("127.0.0.1", sipp_port, stack.port)

      # Track the response
      test_pid = self()

      # Send OPTIONS as UAC
      _uac_id =
        UAC.request(options_msg, fn result ->
          send(test_pid, {:uac_result, result})
        end)

      # Wait for 200 OK response
      assert_receive {:uac_result, {:response, %Message{status_code: 200} = response}}, 5_000

      # Verify response has expected headers
      assert Enum.member?(response.allow, "INVITE")
      assert Enum.member?(response.allow, "OPTIONS")

      assert %ParrotSip.Headers.Accept{
               type: "application",
               subtype: "sdp",
               parameters: %{},
               q_value: nil
             } = response.accept


      # Verify SIPp completed successfully
      assert :ok = Task.await(sipp_task, 5_000)

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "INVITE - multiple sequential outbound calls" do
      # Start SIPp in UAS mode
      sipp_port = get_random_port()

      sipp_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/basic/uas_invite.xml",
            remote_host: "127.0.0.1",
            remote_port: sipp_port,
            local_port: sipp_port,
            calls: 5,
            timeout: 30_000
          )
        end)

      # Give SIPp time to start listening
      Process.sleep(500)

      # Create SIP stack
      handler = ParrotSip.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Track responses
      test_pid = self()

      # Make 5 sequential calls
      for _i <- 1..5 do
        invite_msg = build_invite("127.0.0.1", sipp_port, stack.port)

        _uac_id =
          UAC.request(invite_msg, fn result ->
            send(test_pid, {:uac_result, result})
          end)

        # Wait for 200 OK for this call
        assert_receive {:uac_result, {:response, %Message{status_code: 200}}}, 5_000

        # Small delay between calls
        Process.sleep(100)
      end

      # Verify SIPp completed successfully
      assert :ok = Task.await(sipp_task, 15_000)

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp get_random_port do
    # Get a random port in the ephemeral range
    Enum.random(20_000..30_000)
  end

  defp build_invite(dest_host, dest_port, local_port) do
    call_id = "test-#{System.unique_integer([:positive])}@127.0.0.1"
    from_tag = "from-#{System.unique_integer([:positive])}"

    request_uri = "sip:test@#{dest_host}:#{dest_port}"

    sdp_body = """
    v=0
    o=- 123456 123456 IN IP4 127.0.0.1
    s=Test Call
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio 10000 RTP/AVP 0 8 101
    a=rtpmap:0 PCMU/8000
    a=rtpmap:8 PCMA/8000
    a=rtpmap:101 telephone-event/8000
    a=sendrecv
    """

    %Message{
      type: :request,
      method: :invite,
      request_uri: request_uri,
      version: "SIP/2.0",
      from: %From{
        display_name: "Alice",
        uri: "sip:alice@127.0.0.1:#{local_port}",
        parameters: %{"tag" => from_tag}
      },
      to: %To{
        display_name: nil,
        uri: "sip:test@#{dest_host}:#{dest_port}",
        parameters: %{}
      },
      call_id: call_id,
      cseq: %CSeq{number: 1, method: :invite},
      contact: [
        %Contact{
          display_name: nil,
          uri: "sip:alice@127.0.0.1:#{local_port}",
          parameters: %{}
        }
      ],
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: local_port,
          parameters: %{}
        }
      ],
      max_forwards: 70,
      content_type: "application/sdp",
      body: sdp_body,
      source: %Source{
        local: {{127, 0, 0, 1}, local_port},
        remote: {{127, 0, 0, 1}, dest_port},
        transport: :udp
      }
    }
  end

  defp build_options(dest_host, dest_port, local_port) do
    call_id = "test-#{System.unique_integer([:positive])}@127.0.0.1"
    from_tag = "from-#{System.unique_integer([:positive])}"

    request_uri = "sip:test@#{dest_host}:#{dest_port}"

    %Message{
      type: :request,
      method: :options,
      request_uri: request_uri,
      version: "SIP/2.0",
      from: %From{
        display_name: "Alice",
        uri: "sip:alice@127.0.0.1:#{local_port}",
        parameters: %{"tag" => from_tag}
      },
      to: %To{
        display_name: nil,
        uri: "sip:test@#{dest_host}:#{dest_port}",
        parameters: %{}
      },
      call_id: call_id,
      cseq: %CSeq{number: 1, method: :options},
      contact: [
        %Contact{
          display_name: nil,
          uri: "sip:alice@127.0.0.1:#{local_port}",
          parameters: %{}
        }
      ],
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: local_port,
          parameters: %{}
        }
      ],
      max_forwards: 70,
      source: %Source{
        local: {{127, 0, 0, 1}, local_port},
        remote: {{127, 0, 0, 1}, dest_port},
        transport: :udp
      }
    }
  end
end
