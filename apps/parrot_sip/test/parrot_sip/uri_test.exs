defmodule ParrotSip.UriTest do
  use ExUnit.Case, async: true
  alias ParrotSip.Uri

  describe "parse/1" do
    test "parses basic SIP URI" do
      assert {:ok, uri} = Uri.parse("sip:alice@atlanta.com")
      assert uri.scheme == "sip"
      assert uri.user == "alice"
      assert uri.host == "atlanta.com"
      assert uri.port == nil
    end

    test "parses SIPS URI" do
      assert {:ok, uri} = Uri.parse("sips:alice@atlanta.com")
      assert uri.scheme == "sips"
      assert uri.user == "alice"
      assert uri.host == "atlanta.com"
    end

    test "parses URI with port" do
      assert {:ok, uri} = Uri.parse("sip:alice@atlanta.com:5090")
      assert uri.port == 5090
    end

    test "parses URI with password" do
      assert {:ok, uri} = Uri.parse("sip:alice:secret@atlanta.com")
      assert uri.user == "alice"
      assert uri.password == "secret"
    end

    test "parses URI with parameters" do
      assert {:ok, uri} = Uri.parse("sip:alice@atlanta.com;transport=tcp")
      assert uri.parameters["transport"] == "tcp"
    end

    test "parses URI with headers" do
      assert {:ok, uri} = Uri.parse("sip:alice@atlanta.com?subject=hello")
      assert uri.headers["subject"] == "hello"
    end

    test "parses URI without user" do
      assert {:ok, uri} = Uri.parse("sip:atlanta.com")
      assert uri.user == nil
      assert uri.host == "atlanta.com"
    end

    test "parses URI with IPv4 address" do
      assert {:ok, uri} = Uri.parse("sip:alice@192.168.1.1")
      assert uri.host == "192.168.1.1"
      assert uri.host_type == :ipv4
    end

    test "parses URI with IPv6 address" do
      assert {:ok, uri} = Uri.parse("sip:alice@[2001:db8::1]")
      assert uri.host == "2001:db8::1"
      assert uri.host_type == :ipv6
    end

    test "returns error for invalid URI" do
      assert {:error, _reason} = Uri.parse("not a valid uri")
    end
  end

  describe "parse!/1" do
    test "returns URI struct for valid input" do
      uri = Uri.parse!("sip:alice@atlanta.com")
      assert %Uri{} = uri
      assert uri.user == "alice"
    end

    test "raises ArgumentError for invalid input" do
      assert_raise ArgumentError, fn ->
        Uri.parse!("not a valid uri")
      end
    end
  end

  describe "new/6" do
    test "creates a new URI struct" do
      uri = Uri.new("sip", "alice", "atlanta.com")
      assert uri.scheme == "sip"
      assert uri.user == "alice"
      assert uri.host == "atlanta.com"
      assert uri.port == nil
      assert uri.parameters == %{}
      assert uri.headers == %{}
    end

    test "creates URI with port" do
      uri = Uri.new("sip", "alice", "atlanta.com", 5090)
      assert uri.port == 5090
    end

    test "creates URI with parameters" do
      uri = Uri.new("sip", "alice", "atlanta.com", nil, %{"transport" => "tcp"})
      assert uri.parameters["transport"] == "tcp"
    end

    test "creates URI with headers" do
      uri = Uri.new("sip", "alice", "atlanta.com", nil, %{}, %{"subject" => "test"})
      assert uri.headers["subject"] == "test"
    end

    test "determines host type correctly" do
      uri_hostname = Uri.new("sip", "alice", "atlanta.com")
      assert uri_hostname.host_type == :hostname

      uri_ipv4 = Uri.new("sip", "alice", "192.168.1.1")
      assert uri_ipv4.host_type == :ipv4
    end
  end

  describe "to_string/1" do
    test "converts basic URI to string" do
      uri = Uri.new("sip", "alice", "atlanta.com")
      assert Uri.to_string(uri) == "sip:alice@atlanta.com"
    end

    test "converts URI with port to string" do
      uri = Uri.new("sip", "alice", "atlanta.com", 5090)
      assert Uri.to_string(uri) == "sip:alice@atlanta.com:5090"
    end

    test "converts URI without user to string" do
      uri = %Uri{
        scheme: "sip",
        user: nil,
        host: "atlanta.com",
        port: nil,
        host_type: :hostname,
        parameters: %{},
        headers: %{}
      }

      assert Uri.to_string(uri) == "sip:atlanta.com"
    end

    test "converts URI with password to string" do
      uri = %Uri{
        scheme: "sip",
        user: "alice",
        password: "secret",
        host: "atlanta.com",
        port: nil,
        host_type: :hostname,
        parameters: %{},
        headers: %{}
      }

      assert Uri.to_string(uri) == "sip:alice:secret@atlanta.com"
    end

    test "converts URI with parameters to string" do
      uri = Uri.new("sip", "alice", "atlanta.com", nil, %{"transport" => "tcp"})
      assert Uri.to_string(uri) == "sip:alice@atlanta.com;transport=tcp"
    end

    test "converts URI with IPv6 to string" do
      uri = %Uri{
        scheme: "sip",
        user: "alice",
        host: "2001:db8::1",
        port: nil,
        host_type: :ipv6,
        parameters: %{},
        headers: %{}
      }

      assert Uri.to_string(uri) == "sip:alice@[2001:db8::1]"
    end

    test "round-trip parse and to_string" do
      original = "sip:alice@atlanta.com:5060"
      assert {:ok, uri} = Uri.parse(original)
      assert Uri.to_string(uri) == original
    end
  end

  describe "decoded_user/1" do
    test "returns nil for URI without user" do
      uri = Uri.new("sip", nil, "atlanta.com")
      assert Uri.decoded_user(uri) == nil
    end

    test "returns user as-is if not encoded" do
      uri = Uri.new("sip", "alice", "atlanta.com")
      assert Uri.decoded_user(uri) == "alice"
    end

    test "decodes percent-encoded user" do
      uri = %Uri{
        scheme: "sip",
        user: "alice%20bob",
        host: "atlanta.com",
        port: nil,
        host_type: :hostname,
        parameters: %{},
        headers: %{}
      }

      assert Uri.decoded_user(uri) == "alice bob"
    end
  end

  describe "equal?/2" do
    test "returns true for identical URIs" do
      uri1 = Uri.new("sip", "alice", "atlanta.com")
      uri2 = Uri.new("sip", "alice", "atlanta.com")
      assert Uri.equal?(uri1, uri2)
    end

    test "returns false for different schemes" do
      uri1 = Uri.new("sip", "alice", "atlanta.com")
      uri2 = Uri.new("sips", "alice", "atlanta.com")
      refute Uri.equal?(uri1, uri2)
    end

    test "returns false for different users" do
      uri1 = Uri.new("sip", "alice", "atlanta.com")
      uri2 = Uri.new("sip", "bob", "atlanta.com")
      refute Uri.equal?(uri1, uri2)
    end

    test "returns true for case-insensitive host comparison" do
      uri1 = Uri.new("sip", "alice", "atlanta.com")
      uri2 = Uri.new("sip", "alice", "ATLANTA.COM")
      assert Uri.equal?(uri1, uri2)
    end

    test "returns true when port matches default" do
      uri1 = Uri.new("sip", "alice", "atlanta.com", nil)
      uri2 = Uri.new("sip", "alice", "atlanta.com", 5060)
      assert Uri.equal?(uri1, uri2)
    end

    test "returns true when SIPS port matches default" do
      uri1 = Uri.new("sips", "alice", "atlanta.com", nil)
      uri2 = Uri.new("sips", "alice", "atlanta.com", 5061)
      assert Uri.equal?(uri1, uri2)
    end

    test "returns false for different ports" do
      uri1 = Uri.new("sip", "alice", "atlanta.com", 5060)
      uri2 = Uri.new("sip", "alice", "atlanta.com", 5090)
      refute Uri.equal?(uri1, uri2)
    end

    test "compares key URI parameters" do
      uri1 = Uri.new("sip", "alice", "atlanta.com", nil, %{"transport" => "tcp"})
      uri2 = Uri.new("sip", "alice", "atlanta.com", nil, %{"transport" => "tcp"})
      assert Uri.equal?(uri1, uri2)

      uri3 = Uri.new("sip", "alice", "atlanta.com", nil, %{"transport" => "udp"})
      refute Uri.equal?(uri1, uri3)
    end

    test "ignores non-key parameters in comparison" do
      uri1 = Uri.new("sip", "alice", "atlanta.com", nil, %{"custom" => "value1"})
      uri2 = Uri.new("sip", "alice", "atlanta.com", nil, %{"custom" => "value2"})
      # Non-key parameters are ignored
      assert Uri.equal?(uri1, uri2)
    end
  end

  describe "is_sips?/1" do
    test "returns true for SIPS URI" do
      uri = Uri.new("sips", "alice", "atlanta.com")
      assert Uri.is_sips?(uri)
    end

    test "returns false for SIP URI" do
      uri = Uri.new("sip", "alice", "atlanta.com")
      refute Uri.is_sips?(uri)
    end
  end

  describe "with_port/2" do
    test "adds port to URI" do
      uri = Uri.new("sip", "alice", "atlanta.com")
      updated = Uri.with_port(uri, 5090)
      assert updated.port == 5090
    end

    test "updates existing port" do
      uri = Uri.new("sip", "alice", "atlanta.com", 5060)
      updated = Uri.with_port(uri, 5090)
      assert updated.port == 5090
    end
  end

  describe "with_parameter/3" do
    test "adds parameter to URI" do
      uri = Uri.new("sip", "alice", "atlanta.com")
      updated = Uri.with_parameter(uri, "transport", "tcp")
      assert updated.parameters["transport"] == "tcp"
    end

    test "updates existing parameter" do
      uri = Uri.new("sip", "alice", "atlanta.com", nil, %{"transport" => "udp"})
      updated = Uri.with_parameter(uri, "transport", "tcp")
      assert updated.parameters["transport"] == "tcp"
    end

    test "preserves other parameters" do
      uri = Uri.new("sip", "alice", "atlanta.com", nil, %{"transport" => "udp", "lr" => ""})
      updated = Uri.with_parameter(uri, "transport", "tcp")
      assert updated.parameters["transport"] == "tcp"
      assert updated.parameters["lr"] == ""
    end
  end

  describe "with_parameters/2" do
    test "replaces all parameters" do
      uri = Uri.new("sip", "alice", "atlanta.com", nil, %{"transport" => "udp"})
      updated = Uri.with_parameters(uri, %{"method" => "REGISTER"})
      assert updated.parameters == %{"method" => "REGISTER"}
    end

    test "can clear all parameters" do
      uri = Uri.new("sip", "alice", "atlanta.com", nil, %{"transport" => "udp"})
      updated = Uri.with_parameters(uri, %{})
      assert updated.parameters == %{}
    end
  end
end
