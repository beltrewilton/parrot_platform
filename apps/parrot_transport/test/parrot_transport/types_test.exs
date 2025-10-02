defmodule ParrotTransport.TypesTest do
  use ExUnit.Case, async: true

  alias ParrotTransport.Types.{IncomingPacket, Source, Metadata, ListenerConfig}

  describe "IncomingPacket" do
    test "can be created with all required fields" do
      packet = %IncomingPacket{
        data: "test data",
        source: %Source{
          transport: :udp,
          remote_addr: {{127, 0, 0, 1}, 5060},
          local_addr: {{127, 0, 0, 1}, 5061}
        },
        metadata: %Metadata{
          timestamp: System.monotonic_time()
        }
      }

      assert packet.data == "test data"
      assert packet.source.transport == :udp
    end

    # Note: @enforce_keys validation happens at compile time,
    # so we don't need runtime tests for required fields
  end

  describe "Source" do
    test "can be created with all required fields" do
      source = %Source{
        transport: :tcp,
        remote_addr: {{192, 168, 1, 1}, 5060},
        local_addr: {{127, 0, 0, 1}, 5061}
      }

      assert source.transport == :tcp
      assert source.remote_addr == {{192, 168, 1, 1}, 5060}
      assert source.local_addr == {{127, 0, 0, 1}, 5061}
      assert source.connection == nil
    end

    test "supports optional connection field" do
      source = %Source{
        transport: :tcp,
        remote_addr: {{192, 168, 1, 1}, 5060},
        local_addr: {{127, 0, 0, 1}, 5061},
        connection: self()
      }

      assert source.connection == self()
    end

    # Note: @enforce_keys validation happens at compile time
  end

  describe "Metadata" do
    test "can be created with default values" do
      metadata = %Metadata{
        timestamp: System.monotonic_time()
      }

      assert is_integer(metadata.timestamp)
      assert metadata.connection_id == nil
      assert metadata.tls_info == nil
      assert metadata.extra == %{}
    end

    test "supports optional fields" do
      metadata = %Metadata{
        timestamp: 12345,
        connection_id: "conn-123",
        tls_info: %{cipher: "TLS_AES_128_GCM_SHA256"},
        extra: %{custom: "data"}
      }

      assert metadata.timestamp == 12345
      assert metadata.connection_id == "conn-123"
      assert metadata.tls_info == %{cipher: "TLS_AES_128_GCM_SHA256"}
      assert metadata.extra == %{custom: "data"}
    end
  end

  describe "ListenerConfig" do
    test "can be created with minimal config" do
      config = %ListenerConfig{
        transport: :udp,
        port: 5060
      }

      assert config.transport == :udp
      assert config.port == 5060
      assert config.ip == {0, 0, 0, 0}
      assert config.name == nil
      assert config.buffer_size == 65_536
      assert config.trace == false
    end

    # Note: @enforce_keys validation happens at compile time

    test "supports all transport types" do
      for transport <- [:udp, :tcp, :tls] do
        config = %ListenerConfig{
          transport: transport,
          port: 5060
        }

        assert config.transport == transport
      end
    end

    test "supports optional ip field" do
      config = %ListenerConfig{
        transport: :udp,
        port: 5060,
        ip: {127, 0, 0, 1}
      }

      assert config.ip == {127, 0, 0, 1}
    end

    test "supports optional name field" do
      config = %ListenerConfig{
        transport: :udp,
        port: 5060,
        name: :my_listener
      }

      assert config.name == :my_listener
    end

    test "supports TLS-specific fields" do
      config = %ListenerConfig{
        transport: :tls,
        port: 5061,
        certfile: "/path/to/cert.pem",
        keyfile: "/path/to/key.pem",
        cacertfile: "/path/to/ca.pem"
      }

      assert config.certfile == "/path/to/cert.pem"
      assert config.keyfile == "/path/to/key.pem"
      assert config.cacertfile == "/path/to/ca.pem"
    end

    test "supports TCP/TLS connection limits" do
      config = %ListenerConfig{
        transport: :tcp,
        port: 5060,
        max_connections: 5000,
        accept_pool_size: 20
      }

      assert config.max_connections == 5000
      assert config.accept_pool_size == 20
    end

    test "supports buffer_size configuration" do
      config = %ListenerConfig{
        transport: :udp,
        port: 5060,
        buffer_size: 131_072
      }

      assert config.buffer_size == 131_072
    end

    test "supports trace flag" do
      config = %ListenerConfig{
        transport: :udp,
        port: 5060,
        trace: true
      }

      assert config.trace == true
    end
  end
end
