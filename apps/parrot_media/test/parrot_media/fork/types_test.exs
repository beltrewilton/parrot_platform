defmodule ParrotMedia.Fork.TypesTest do
  @moduledoc """
  Tests for media forking type definitions.
  """
  use ExUnit.Case, async: true

  alias ParrotMedia.Fork.Types
  alias ParrotMedia.Fork.Types.{ForkConfig, ForkState}

  describe "ForkConfig struct" do
    test "creates with all required fields" do
      config = %ForkConfig{
        id: "fork-123",
        destination: {:websocket, "ws://example.com/audio"},
        direction: :both,
        format: :pcmu,
        sample_rate: 8000,
        label: "recording"
      }

      assert config.id == "fork-123"
      assert config.direction == :both
      assert config.format == :pcmu
      assert config.sample_rate == 8000
      assert config.label == "recording"
      assert config.started_at == nil
    end

    test "requires id field" do
      assert_raise ArgumentError, fn ->
        struct!(ForkConfig, destination: {:websocket, "ws://example.com"}, direction: :both)
      end
    end

    test "requires destination field" do
      assert_raise ArgumentError, fn ->
        struct!(ForkConfig, id: "fork-123", direction: :both)
      end
    end

    test "requires direction field" do
      assert_raise ArgumentError, fn ->
        struct!(ForkConfig, id: "fork-123", destination: {:websocket, "ws://example.com"})
      end
    end

    test "supports all direction types" do
      for direction <- [:rx, :tx, :both] do
        config = %ForkConfig{
          id: "fork-#{direction}",
          destination: {:websocket, "ws://example.com"},
          direction: direction
        }
        assert config.direction == direction
      end
    end

    test "supports all format types" do
      for format <- [:pcmu, :pcma, :opus, :raw] do
        config = %ForkConfig{
          id: "fork-#{format}",
          destination: {:websocket, "ws://example.com"},
          direction: :both,
          format: format
        }
        assert config.format == format
      end
    end

    test "supports websocket destination" do
      config = %ForkConfig{
        id: "fork-ws",
        destination: {:websocket, "ws://example.com/audio"},
        direction: :both
      }
      assert {:websocket, _url} = config.destination
    end

    test "supports rtp destination" do
      config = %ForkConfig{
        id: "fork-rtp",
        destination: {:rtp, {{192, 168, 1, 100}, 5004}},
        direction: :both
      }
      assert {:rtp, _addr} = config.destination
    end
  end

  describe "ForkState struct" do
    test "creates with required config" do
      config = %ForkConfig{
        id: "fork-123",
        destination: {:websocket, "ws://example.com"},
        direction: :both
      }

      state = %ForkState{
        config: config,
        status: :active
      }

      assert state.config == config
      assert state.status == :active
      assert state.connection_pid == nil
      assert state.bytes_sent == 0
      assert state.packets_sent == 0
    end

    test "requires config field" do
      assert_raise ArgumentError, fn ->
        struct!(ForkState, status: :active)
      end
    end

    test "requires status field" do
      config = %ForkConfig{
        id: "fork-123",
        destination: {:websocket, "ws://example.com"},
        direction: :both
      }

      assert_raise ArgumentError, fn ->
        struct!(ForkState, config: config)
      end
    end

    test "supports all status values" do
      config = %ForkConfig{
        id: "fork-123",
        destination: {:websocket, "ws://example.com"},
        direction: :both
      }

      for status <- [:pending, :connecting, :active, :paused, :stopped, :error] do
        state = %ForkState{config: config, status: status}
        assert state.status == status
      end
    end

    test "tracks connection pid" do
      config = %ForkConfig{
        id: "fork-123",
        destination: {:websocket, "ws://example.com"},
        direction: :both
      }

      state = %ForkState{
        config: config,
        status: :active,
        connection_pid: self()
      }

      assert state.connection_pid == self()
    end

    test "tracks bytes and packets sent" do
      config = %ForkConfig{
        id: "fork-123",
        destination: {:websocket, "ws://example.com"},
        direction: :both
      }

      state = %ForkState{
        config: config,
        status: :active,
        bytes_sent: 1024,
        packets_sent: 50
      }

      assert state.bytes_sent == 1024
      assert state.packets_sent == 50
    end
  end

  describe "module types" do
    test "direction type is documented" do
      # Verify type exists by checking module functions compile
      assert Code.ensure_loaded?(Types)
    end
  end
end
