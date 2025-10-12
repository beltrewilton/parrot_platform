defmodule SippTest.TransportsTest do
  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}

  @moduletag :sipp

  describe "TCP transport" do
    test "UAC INVITE over TCP" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_tcp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/tcp/uac_invite_tcp.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 transport: :tcp,
                 calls: 1,
                 timeout: 5_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 1
      assert stats.acks == 1
      assert stats.byes == 1

      SipStackHelper.stop(stack)
    end

    test "multiple TCP calls" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_tcp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/tcp/uac_invite_tcp.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 transport: :tcp,
                 calls: 5,
                 timeout: 10_000
               )

      Process.sleep(200)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 5
      assert stats.acks == 5
      assert stats.byes == 5

      SipStackHelper.stop(stack)
    end
  end

  describe "TLS transport" do
    test "UAC INVITE over TLS" do
      handler = TestHandler.new()

      {:ok, stack} =
        SipStackHelper.start_tls(handler,
          port: 0,
          certfile: "test/sipp/fixtures/certs/server-cert.pem",
          keyfile: "test/sipp/fixtures/certs/server-key.pem",
          cacertfile: "test/sipp/fixtures/certs/ca-cert.pem"
        )

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/tls/uac_invite_tls.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 transport: :tls,
                 tls_cert: "test/sipp/fixtures/certs/client-cert.pem",
                 tls_key: "test/sipp/fixtures/certs/client-key.pem",
                 calls: 1,
                 timeout: 5_000,
                 trace_msg: true
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 1
      assert stats.acks == 1
      assert stats.byes == 1

      SipStackHelper.stop(stack)
    end

    test "multiple TLS calls" do
      handler = TestHandler.new()

      {:ok, stack} =
        SipStackHelper.start_tls(handler,
          port: 0,
          certfile: "test/sipp/fixtures/certs/server-cert.pem",
          keyfile: "test/sipp/fixtures/certs/server-key.pem",
          cacertfile: "test/sipp/fixtures/certs/ca-cert.pem"
        )

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/tls/uac_invite_tls.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 transport: :tls,
                 tls_cert: "test/sipp/fixtures/certs/client-cert.pem",
                 tls_key: "test/sipp/fixtures/certs/client-key.pem",
                 calls: 3,
                 timeout: 10_000
               )

      Process.sleep(200)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 3
      assert stats.acks == 3
      assert stats.byes == 3

      SipStackHelper.stop(stack)
    end
  end
end
