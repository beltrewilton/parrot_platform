defmodule SippTest.ClientTest do
  @moduledoc """
  Tests where ParrotSip acts as client and SIPp acts as server.

  This tests the outbound calling capabilities of the ParrotSip stack.
  """
  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, SipStackHelper}
  alias ParrotSip.{Message, Source}
  alias ParrotSip.Transaction.Client
  alias ParrotSip.Headers.{From, To, CSeq, Contact, Via}

  @moduletag :sipp

  describe "ParrotSip as UAC - basic INVITE scenarios" do
    test "INVITE - ParrotSip makes outbound call to SIPp UAS" do
      # Start SIPp in UAS mode (listening for calls)
      # Note: Using uas_bye.xml which expects ParrotSip to send BYE (no fallback BYE from SIPp)
      sipp_port = get_random_port()

      sipp_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/basic/uas_bye.xml",
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
      handler = SippTest.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Build outbound INVITE
      invite_msg = build_invite("127.0.0.1", sipp_port, stack.port)

      # Track the response
      test_pid = self()

      # Send INVITE as UAC
      _uac_id =
        Client.request(invite_msg, fn result ->
          send(test_pid, {:uac_result, result})
        end)

      # Wait for 200 OK response
      assert_receive {:uac_result, {:response, %Message{status_code: 200} = response}}, 5_000

      # Send ACK for the 200 OK (required by RFC 3261)
      ack = Message.build_ack(invite_msg, response)
      :ok = Client.send_ack(ack, {"127.0.0.1", sipp_port})

      # Extract dialog information from response for BYE
      to_tag = response.to.parameters["tag"]
      from_tag = invite_msg.from.parameters["tag"]
      call_id = invite_msg.call_id

      # Send BYE to properly terminate the call
      bye_msg = build_bye("127.0.0.1", sipp_port, stack.port, call_id, from_tag, to_tag)

      _bye_uac_id =
        Client.request(bye_msg, fn result ->
          send(test_pid, {:bye_result, result})
        end)

      # Wait for 200 OK for BYE
      assert_receive {:bye_result, {:response, %Message{status_code: 200}}}, 5_000

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
      handler = SippTest.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Build outbound OPTIONS
      options_msg = build_options("127.0.0.1", sipp_port, stack.port)

      # Track the response
      test_pid = self()

      # Send OPTIONS as UAC
      _uac_id =
        Client.request(options_msg, fn result ->
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
      # Note: Using uas_bye.xml which expects ParrotSip to send BYE
      sipp_port = get_random_port()

      sipp_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/basic/uas_bye.xml",
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
      handler = SippTest.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Track responses
      test_pid = self()

      # Make 5 sequential calls with proper termination
      for _i <- 1..5 do
        invite_msg = build_invite("127.0.0.1", sipp_port, stack.port)

        _uac_id =
          Client.request(invite_msg, fn result ->
            send(test_pid, {:uac_result, result})
          end)

        # Wait for 200 OK for this call
        assert_receive {:uac_result, {:response, %Message{status_code: 200} = response}}, 5_000

        # Send ACK for the 200 OK (required by RFC 3261)
        ack = Message.build_ack(invite_msg, response)
        :ok = Client.send_ack(ack, {"127.0.0.1", sipp_port})

        # Extract dialog information and send BYE to properly terminate
        to_tag = response.to.parameters["tag"]
        from_tag = invite_msg.from.parameters["tag"]
        call_id = invite_msg.call_id

        bye_msg = build_bye("127.0.0.1", sipp_port, stack.port, call_id, from_tag, to_tag)

        _bye_uac_id =
          Client.request(bye_msg, fn result ->
            send(test_pid, {:bye_result, result})
          end)

        # Wait for 200 OK for BYE
        assert_receive {:bye_result, {:response, %Message{status_code: 200}}}, 5_000

        # Small delay between calls
        Process.sleep(100)
      end

      # Verify SIPp completed successfully
      assert :ok = Task.await(sipp_task, 15_000)

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end

  describe "ParrotSip as UAC - re-INVITE scenarios" do
    test "re-INVITE - ParrotSip sends re-INVITE to hold call" do
      # Start SIPp in UAS mode (will receive INVITE + re-INVITE)
      sipp_port = get_random_port()

      sipp_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/reinvite/uas_reinvite_hold.xml",
            remote_host: "127.0.0.1",
            remote_port: sipp_port,
            local_port: sipp_port,
            calls: 1,
            timeout: 15_000
          )
        end)

      # Give SIPp time to start listening
      Process.sleep(500)

      # Create SIP stack
      handler = SippTest.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)
      test_pid = self()

      # Send initial INVITE
      invite_msg = build_invite("127.0.0.1", sipp_port, stack.port)

      _uac_id =
        Client.request(invite_msg, fn result ->
          send(test_pid, {:uac_result, result})
        end)

      # Wait for 200 OK
      assert_receive {:uac_result, {:response, %Message{status_code: 200} = response}}, 5_000

      # Send ACK for the 200 OK (required by RFC 3261)
      ack = Message.build_ack(invite_msg, response)
      :ok = Client.send_ack(ack, {"127.0.0.1", sipp_port})

      # Extract dialog information from response
      to_tag = response.to.parameters["tag"]
      from_tag = invite_msg.from.parameters["tag"]
      call_id = invite_msg.call_id

      # Build re-INVITE with hold (sendonly)
      reinvite_msg =
        build_reinvite_hold(
          "127.0.0.1",
          sipp_port,
          stack.port,
          call_id,
          from_tag,
          to_tag
        )

      # Send re-INVITE
      _reinvite_uac_id =
        Client.request(reinvite_msg, fn result ->
          send(test_pid, {:reinvite_result, result})
        end)

      # Wait for 200 OK for re-INVITE
      assert_receive {:reinvite_result,
                      {:response, %Message{status_code: 200} = reinvite_response}},
                     5_000

      # Send ACK for the re-INVITE 200 OK (required by RFC 3261)
      reinvite_ack = Message.build_ack(reinvite_msg, reinvite_response)
      :ok = Client.send_ack(reinvite_ack, {"127.0.0.1", sipp_port})

      # Send BYE
      bye_msg = build_bye("127.0.0.1", sipp_port, stack.port, call_id, from_tag, to_tag)

      _bye_uac_id =
        Client.request(bye_msg, fn result ->
          send(test_pid, {:bye_result, result})
        end)

      # Wait for 200 OK for BYE
      assert_receive {:bye_result, {:response, %Message{status_code: 200}}}, 5_000

      # Wait for processing
      Process.sleep(100)

      # Verify SIPp completed successfully
      assert :ok = Task.await(sipp_task, 10_000)

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end

  describe "ParrotSip as UAC - BYE scenarios" do
    test "BYE - ParrotSip terminates call" do
      # Start SIPp in UAS mode
      sipp_port = get_random_port()

      sipp_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/basic/uas_bye.xml",
            remote_host: "127.0.0.1",
            remote_port: sipp_port,
            local_port: sipp_port,
            calls: 1,
            timeout: 10_000
          )
        end)

      # Give SIPp time to start listening
      Process.sleep(500)

      # Create SIP stack
      handler = SippTest.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)
      test_pid = self()

      # Send initial INVITE
      invite_msg = build_invite("127.0.0.1", sipp_port, stack.port)

      _uac_id =
        Client.request(invite_msg, fn result ->
          send(test_pid, {:uac_result, result})
        end)

      # Wait for 200 OK
      assert_receive {:uac_result, {:response, %Message{status_code: 200} = response}}, 5_000

      # Send ACK for the 200 OK (required by RFC 3261)
      ack = Message.build_ack(invite_msg, response)
      :ok = Client.send_ack(ack, {"127.0.0.1", sipp_port})

      # Extract dialog information
      to_tag = response.to.parameters["tag"]
      from_tag = invite_msg.from.parameters["tag"]
      call_id = invite_msg.call_id

      # Send BYE
      bye_msg = build_bye("127.0.0.1", sipp_port, stack.port, call_id, from_tag, to_tag)

      _bye_uac_id =
        Client.request(bye_msg, fn result ->
          send(test_pid, {:bye_result, result})
        end)

      # Wait for 200 OK for BYE
      assert_receive {:bye_result, {:response, %Message{status_code: 200}}}, 5_000

      # Verify SIPp completed successfully
      assert :ok = Task.await(sipp_task, 5_000)

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "BYE - multiple sequential calls with BYE" do
      # Start SIPp in UAS mode
      sipp_port = get_random_port()

      sipp_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/basic/uas_bye.xml",
            remote_host: "127.0.0.1",
            remote_port: sipp_port,
            local_port: sipp_port,
            calls: 3,
            timeout: 15_000
          )
        end)

      # Give SIPp time to start listening
      Process.sleep(500)

      # Create SIP stack
      handler = SippTest.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)
      test_pid = self()

      # Make 3 calls, each with BYE
      for _i <- 1..3 do
        invite_msg = build_invite("127.0.0.1", sipp_port, stack.port)

        _uac_id =
          Client.request(invite_msg, fn result ->
            send(test_pid, {:uac_result, result})
          end)

        # Wait for 200 OK
        assert_receive {:uac_result, {:response, %Message{status_code: 200} = response}}, 5_000

        # Send ACK for the 200 OK (required by RFC 3261)
        ack = Message.build_ack(invite_msg, response)
        :ok = Client.send_ack(ack, {"127.0.0.1", sipp_port})

        # Extract dialog information
        to_tag = response.to.parameters["tag"]
        from_tag = invite_msg.from.parameters["tag"]
        call_id = invite_msg.call_id

        # Send BYE
        bye_msg = build_bye("127.0.0.1", sipp_port, stack.port, call_id, from_tag, to_tag)

        _bye_uac_id =
          Client.request(bye_msg, fn result ->
            send(test_pid, {:bye_result, result})
          end)

        # Wait for 200 OK for BYE
        assert_receive {:bye_result, {:response, %Message{status_code: 200}}}, 5_000

        # Small delay between calls
        Process.sleep(100)
      end

      # Verify SIPp completed successfully
      assert :ok = Task.await(sipp_task, 10_000)

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end

  describe "ParrotSip as UAC - CANCEL scenarios" do
    test "CANCEL - ParrotSip cancels in-progress call" do
      # Start SIPp in UAS mode (will send 180 Ringing, then wait for CANCEL)
      sipp_port = get_random_port()

      sipp_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/cancel/uas_cancel.xml",
            remote_host: "127.0.0.1",
            remote_port: sipp_port,
            local_port: sipp_port,
            calls: 1,
            timeout: 10_000
          )
        end)

      # Give SIPp time to start listening
      Process.sleep(500)

      # Create SIP stack
      handler = SippTest.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)
      test_pid = self()

      # Send initial INVITE
      invite_msg = build_invite("127.0.0.1", sipp_port, stack.port)

      uac_id =
        Client.request(invite_msg, fn result ->
          send(test_pid, {:uac_result, result})
        end)

      # Wait for 180 Ringing
      assert_receive {:uac_result, {:response, %Message{status_code: 180}}}, 5_000

      # Wait for SIPP's pause to complete (100ms in scenario)
      Process.sleep(150)

      # Send CANCEL
      :ok = Client.cancel(uac_id)

      # Should receive final responses (200 for CANCEL or 487 for INVITE)
      # Drain any provisional responses and get the final one
      final_code = receive_final_response(5_000)
      assert final_code in [200, 487]

      # Verify SIPp completed successfully
      assert :ok = Task.await(sipp_task, 5_000)

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end

  describe "ParrotSip as UAC - REGISTER scenarios" do
    test "REGISTER - ParrotSip registers with server" do
      # Start SIPp in UAS mode (registrar)
      sipp_port = get_random_port()

      sipp_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/basic/uas_register.xml",
            remote_host: "127.0.0.1",
            remote_port: sipp_port,
            local_port: sipp_port,
            calls: 1,
            timeout: 10_000
          )
        end)

      # Give SIPp time to start listening
      Process.sleep(500)

      # Create SIP stack
      handler = SippTest.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)
      test_pid = self()

      # Build REGISTER message
      register_msg = build_register("127.0.0.1", sipp_port, stack.port)

      # Send REGISTER
      _uac_id =
        Client.request(register_msg, fn result ->
          send(test_pid, {:register_result, result})
        end)

      # Wait for 200 OK
      assert_receive {:register_result, {:response, %Message{status_code: 200} = response}},
                     5_000

      # Verify response has Contact and Expires headers
      assert response.contact != nil
      assert response.expires != nil

      # Verify SIPp completed successfully
      assert :ok = Task.await(sipp_task, 5_000)

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "REGISTER - multiple sequential registrations" do
      # Start SIPp in UAS mode
      sipp_port = get_random_port()

      sipp_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/basic/uas_register.xml",
            remote_host: "127.0.0.1",
            remote_port: sipp_port,
            local_port: sipp_port,
            calls: 3,
            timeout: 10_000
          )
        end)

      # Give SIPp time to start listening
      Process.sleep(500)

      # Create SIP stack
      handler = SippTest.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)
      test_pid = self()

      # Register 3 times
      for _i <- 1..3 do
        register_msg = build_register("127.0.0.1", sipp_port, stack.port)

        _uac_id =
          Client.request(register_msg, fn result ->
            send(test_pid, {:register_result, result})
          end)

        # Wait for 200 OK
        assert_receive {:register_result, {:response, %Message{status_code: 200}}}, 5_000

        Process.sleep(50)
      end

      # Verify SIPp completed successfully
      assert :ok = Task.await(sipp_task, 5_000)

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

  defp build_reinvite_hold(dest_host, dest_port, local_port, call_id, from_tag, to_tag) do
    request_uri = "sip:test@#{dest_host}:#{dest_port}"

    sdp_body = """
    v=0
    o=- 123456 123457 IN IP4 127.0.0.1
    s=Test Call - Hold
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio 10000 RTP/AVP 0 8 101
    a=rtpmap:0 PCMU/8000
    a=rtpmap:8 PCMA/8000
    a=rtpmap:101 telephone-event/8000
    a=sendonly
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
        parameters: %{"tag" => to_tag}
      },
      call_id: call_id,
      cseq: %CSeq{number: 2, method: :invite},
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

  defp build_bye(dest_host, dest_port, local_port, call_id, from_tag, to_tag) do
    request_uri = "sip:test@#{dest_host}:#{dest_port}"

    %Message{
      type: :request,
      method: :bye,
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
        parameters: %{"tag" => to_tag}
      },
      call_id: call_id,
      cseq: %CSeq{number: 3, method: :bye},
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

  defp build_register(dest_host, dest_port, local_port) do
    call_id = "test-#{System.unique_integer([:positive])}@127.0.0.1"
    from_tag = "from-#{System.unique_integer([:positive])}"

    request_uri = "sip:#{dest_host}:#{dest_port}"

    %Message{
      type: :request,
      method: :register,
      request_uri: request_uri,
      version: "SIP/2.0",
      from: %From{
        display_name: "Alice",
        uri: "sip:alice@#{dest_host}:#{dest_port}",
        parameters: %{"tag" => from_tag}
      },
      to: %To{
        display_name: "Alice",
        uri: "sip:alice@#{dest_host}:#{dest_port}",
        parameters: %{}
      },
      call_id: call_id,
      cseq: %CSeq{number: 1, method: :register},
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
      expires: 3600,
      source: %Source{
        local: {{127, 0, 0, 1}, local_port},
        remote: {{127, 0, 0, 1}, dest_port},
        transport: :udp
      }
    }
  end

  # Helper to drain provisional responses and return final response code
  defp receive_final_response(timeout) do
    receive do
      {:uac_result, {:response, %Message{status_code: code}}} when code >= 200 ->
        code

      {:uac_result, {:response, %Message{status_code: _code}}} ->
        # Provisional response, keep waiting
        receive_final_response(timeout)
    after
      timeout ->
        flunk("Timeout waiting for final response")
    end
  end
end
