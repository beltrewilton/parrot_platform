Code.require_file("support/sipp_runner.ex", __DIR__)
Code.require_file("support/test_handler.ex", __DIR__)
Code.require_file("support/sip_stack_helper.ex", __DIR__)

defmodule SippTest.TransportsTest do
  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}

  @moduletag :sipp

  describe "TCP transport" do
    test "UAC INVITE over TCP" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack with TCP
      {:ok, stack} = SipStackHelper.start_tcp(handler, port: 0)

      # Use random local port for TCP to avoid port conflicts
      local_port = :rand.uniform(10000) + 50000

      # Run SIPp UAC INVITE over TCP
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/tcp/uac_invite_tcp.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 transport: :tcp,
                 local_port: local_port,
                 calls: 1,
                 timeout: 5_000
               )

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 1
      assert stats.acks == 1
      assert stats.byes == 1

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "multiple TCP calls" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack with TCP
      {:ok, stack} = SipStackHelper.start_tcp(handler, port: 0)

      # Use random local port for TCP to avoid port conflicts
      local_port = :rand.uniform(10000) + 50000

      # Run multiple calls
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/tcp/uac_invite_tcp.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 transport: :tcp,
                 local_port: local_port,
                 calls: 5,
                 timeout: 10_000
               )

      # Verify stats
      Process.sleep(200)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 5
      assert stats.acks == 5
      assert stats.byes == 5

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end

  describe "TLS transport" do
    test "UAC INVITE over TLS" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack with TLS
      {:ok, stack} = SipStackHelper.start_tls(handler,
        port: 0,
        certfile: "test/sipp/fixtures/certs/server-cert.pem",
        keyfile: "test/sipp/fixtures/certs/server-key.pem",
        cacertfile: "test/sipp/fixtures/certs/ca-cert.pem"
      )

      # Use random local port for TLS to avoid port conflicts
      local_port = :rand.uniform(10000) + 50000

      # Run SIPp UAC INVITE over TLS
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/tls/uac_invite_tls.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 transport: :tls,
                 local_port: local_port,
                 tls_cert: "test/sipp/fixtures/certs/client-cert.pem",
                 tls_key: "test/sipp/fixtures/certs/client-key.pem",
                 calls: 1,
                 timeout: 5_000
               )

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 1
      assert stats.acks == 1
      assert stats.byes == 1

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "multiple TLS calls" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack with TLS
      {:ok, stack} = SipStackHelper.start_tls(handler,
        port: 0,
        certfile: "test/sipp/fixtures/certs/server-cert.pem",
        keyfile: "test/sipp/fixtures/certs/server-key.pem",
        cacertfile: "test/sipp/fixtures/certs/ca-cert.pem"
      )

      # Use random local port for TLS to avoid port conflicts
      local_port = :rand.uniform(10000) + 50000

      # Run multiple TLS calls
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/tls/uac_invite_tls.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 transport: :tls,
                 local_port: local_port,
                 tls_cert: "test/sipp/fixtures/certs/client-cert.pem",
                 tls_key: "test/sipp/fixtures/certs/client-key.pem",
                 calls: 3,
                 timeout: 10_000
               )

      # Verify stats
      Process.sleep(200)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 3
      assert stats.acks == 3
      assert stats.byes == 3

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end
end
