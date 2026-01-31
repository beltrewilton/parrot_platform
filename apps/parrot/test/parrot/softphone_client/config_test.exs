defmodule Parrot.SoftphoneClient.ConfigTest do
  use ExUnit.Case, async: true

  alias Parrot.SoftphoneClient.Config

  describe "validate/1" do
    test "validates config with required fields" do
      config = %{username: "alice", domain: "example.com"}
      assert {:ok, validated} = Config.validate(config)
      assert validated.username == "alice"
      assert validated.domain == "example.com"
    end

    test "applies default values" do
      config = %{username: "alice", domain: "example.com"}
      assert {:ok, validated} = Config.validate(config)

      assert validated.display_name == nil
      assert validated.auth_username == nil
      assert validated.auth_password == nil
      assert validated.registrar == nil
      assert validated.register_expires == 3600
      assert validated.auto_register == true
      assert validated.transport == :udp
      assert validated.local_ip == nil
      assert validated.local_port == 0
      assert validated.outbound_proxy == nil
      assert validated.supported_codecs == [:pcma, :opus]
    end

    test "preserves provided values over defaults" do
      config = %{
        username: "alice",
        domain: "example.com",
        display_name: "Alice Smith",
        auth_username: "alice_auth",
        auth_password: "secret123",
        registrar: "sip:registrar.example.com",
        register_expires: 1800,
        auto_register: false,
        transport: :tcp,
        local_ip: "192.168.1.100",
        local_port: 5080,
        outbound_proxy: "sip:proxy.example.com",
        supported_codecs: [:opus]
      }

      assert {:ok, validated} = Config.validate(config)

      assert validated.display_name == "Alice Smith"
      assert validated.auth_username == "alice_auth"
      assert validated.auth_password == "secret123"
      assert validated.registrar == "sip:registrar.example.com"
      assert validated.register_expires == 1800
      assert validated.auto_register == false
      assert validated.transport == :tcp
      assert validated.local_ip == "192.168.1.100"
      assert validated.local_port == 5080
      assert validated.outbound_proxy == "sip:proxy.example.com"
      assert validated.supported_codecs == [:opus]
    end

    test "returns error when config is not a map" do
      assert {:error, :config_must_be_map} = Config.validate(username: "alice")
      assert {:error, :config_must_be_map} = Config.validate("invalid")
    end
  end

  describe "validation - required fields" do
    test "returns error when username is missing" do
      assert {:error, {:missing_required, [:username]}} =
               Config.validate(%{domain: "example.com"})
    end

    test "returns error when domain is missing" do
      assert {:error, {:missing_required, [:domain]}} =
               Config.validate(%{username: "alice"})
    end

    test "returns error when multiple required fields are missing" do
      assert {:error, {:missing_required, missing}} = Config.validate(%{})
      assert :username in missing
      assert :domain in missing
    end

    test "returns error when username is empty string" do
      assert {:error, {:missing_required, [:username]}} =
               Config.validate(%{username: "", domain: "example.com"})
    end

    test "returns error when domain is empty string" do
      assert {:error, {:missing_required, [:domain]}} =
               Config.validate(%{username: "alice", domain: ""})
    end
  end

  describe "validation - transport" do
    test "accepts :udp transport" do
      assert {:ok, config} =
               Config.validate(%{username: "alice", domain: "example.com", transport: :udp})

      assert config.transport == :udp
    end

    test "accepts :tcp transport" do
      assert {:ok, config} =
               Config.validate(%{username: "alice", domain: "example.com", transport: :tcp})

      assert config.transport == :tcp
    end

    test "accepts :tls transport" do
      assert {:ok, config} =
               Config.validate(%{username: "alice", domain: "example.com", transport: :tls})

      assert config.transport == :tls
    end

    test "accepts :ws transport" do
      assert {:ok, config} =
               Config.validate(%{username: "alice", domain: "example.com", transport: :ws})

      assert config.transport == :ws
    end

    test "rejects invalid transport" do
      assert {:error, {:invalid_transport, :http}} =
               Config.validate(%{username: "alice", domain: "example.com", transport: :http})
    end
  end

  describe "validation - register_expires" do
    test "accepts expires >= 60" do
      assert {:ok, config} =
               Config.validate(%{username: "alice", domain: "example.com", register_expires: 60})

      assert config.register_expires == 60
    end

    test "rejects expires < 60" do
      assert {:error, {:invalid_expires, _}} =
               Config.validate(%{username: "alice", domain: "example.com", register_expires: 30})
    end
  end

  describe "aor/1" do
    test "returns correct SIP URI" do
      config = %{username: "alice", domain: "example.com"}
      assert Config.aor(config) == "sip:alice@example.com"
    end

    test "handles special characters in username" do
      config = %{username: "alice.smith", domain: "pbx.example.com"}
      assert Config.aor(config) == "sip:alice.smith@pbx.example.com"
    end
  end

  describe "registrar/1" do
    test "returns explicit registrar when set" do
      config = %{username: "alice", domain: "example.com", registrar: "sip:reg.example.com:5080"}
      assert Config.registrar(config) == "sip:reg.example.com:5080"
    end

    test "returns sip:domain when registrar not set" do
      config = %{username: "alice", domain: "example.com"}
      assert Config.registrar(config) == "sip:example.com"
    end

    test "returns sip:domain when registrar is empty string" do
      config = %{username: "alice", domain: "example.com", registrar: ""}
      assert Config.registrar(config) == "sip:example.com"
    end

    test "returns sip:domain when registrar is nil" do
      config = %{username: "alice", domain: "example.com", registrar: nil}
      assert Config.registrar(config) == "sip:example.com"
    end
  end

  describe "auth_username/1" do
    test "returns explicit auth_username when set" do
      config = %{username: "alice", domain: "example.com", auth_username: "alice_special"}
      assert Config.auth_username(config) == "alice_special"
    end

    test "returns username when auth_username not set" do
      config = %{username: "alice", domain: "example.com"}
      assert Config.auth_username(config) == "alice"
    end

    test "returns username when auth_username is nil" do
      config = %{username: "alice", domain: "example.com", auth_username: nil}
      assert Config.auth_username(config) == "alice"
    end
  end
end
