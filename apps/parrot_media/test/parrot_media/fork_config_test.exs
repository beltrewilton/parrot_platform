defmodule ParrotMedia.ForkConfigTest do
  use ExUnit.Case, async: true

  alias ParrotMedia.ForkConfig

  describe "new/1" do
    test "creates a valid ForkConfig with required fields" do
      config =
        ForkConfig.new(
          id: "fork_1",
          destination_address: {192, 168, 1, 100},
          destination_port: 5000
        )

      assert config.id == "fork_1"
      assert config.destination_address == {192, 168, 1, 100}
      assert config.destination_port == 5000
      assert config.transport == :rtp
      assert config.enabled == true
    end

    test "creates ForkConfig with string IP address" do
      config =
        ForkConfig.new(
          id: "fork_2",
          destination_address: "10.0.0.1",
          destination_port: 6000
        )

      assert config.destination_address == {10, 0, 0, 1}
    end

    test "raises error when id is missing" do
      assert_raise KeyError, fn ->
        ForkConfig.new(
          destination_address: {192, 168, 1, 100},
          destination_port: 5000
        )
      end
    end

    test "raises error when destination_address is missing" do
      assert_raise KeyError, fn ->
        ForkConfig.new(
          id: "fork_1",
          destination_port: 5000
        )
      end
    end

    test "raises error when destination_port is missing" do
      assert_raise KeyError, fn ->
        ForkConfig.new(
          id: "fork_1",
          destination_address: {192, 168, 1, 100}
        )
      end
    end

    test "accepts optional transport parameter" do
      config =
        ForkConfig.new(
          id: "fork_1",
          destination_address: {192, 168, 1, 100},
          destination_port: 5000,
          transport: :rtp
        )

      assert config.transport == :rtp
    end

    test "accepts optional enabled parameter" do
      config =
        ForkConfig.new(
          id: "fork_1",
          destination_address: {192, 168, 1, 100},
          destination_port: 5000,
          enabled: false
        )

      assert config.enabled == false
    end
  end

  describe "validate/1" do
    test "returns :ok for valid config" do
      config =
        ForkConfig.new(
          id: "fork_1",
          destination_address: {192, 168, 1, 100},
          destination_port: 5000
        )

      assert ForkConfig.validate(config) == :ok
    end

    test "returns error for invalid port (too low)" do
      config = %ForkConfig{
        id: "fork_1",
        destination_address: {192, 168, 1, 100},
        destination_port: 0,
        transport: :rtp,
        enabled: true
      }

      assert {:error, :invalid_port} = ForkConfig.validate(config)
    end

    test "returns error for invalid port (too high)" do
      config = %ForkConfig{
        id: "fork_1",
        destination_address: {192, 168, 1, 100},
        destination_port: 65536,
        transport: :rtp,
        enabled: true
      }

      assert {:error, :invalid_port} = ForkConfig.validate(config)
    end

    test "returns error for nil id" do
      config = %ForkConfig{
        id: nil,
        destination_address: {192, 168, 1, 100},
        destination_port: 5000,
        transport: :rtp,
        enabled: true
      }

      assert {:error, :invalid_id} = ForkConfig.validate(config)
    end

    test "returns error for unsupported transport" do
      config = %ForkConfig{
        id: "fork_1",
        destination_address: {192, 168, 1, 100},
        destination_port: 5000,
        transport: :websocket,
        enabled: true
      }

      assert {:error, :unsupported_transport} = ForkConfig.validate(config)
    end
  end

  describe "parse_address/1" do
    test "parses string IP address to tuple" do
      assert ForkConfig.parse_address("192.168.1.1") == {192, 168, 1, 1}
    end

    test "returns tuple address unchanged" do
      assert ForkConfig.parse_address({10, 0, 0, 1}) == {10, 0, 0, 1}
    end

    test "parses localhost" do
      assert ForkConfig.parse_address("127.0.0.1") == {127, 0, 0, 1}
    end
  end
end
