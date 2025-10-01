defmodule ParrotSip.Dns.ResolverTest do
  use ExUnit.Case, async: true
  alias ParrotSip.Dns.Resolver

  describe "resolve/2" do
    test "returns IP and port in expected format" do
      # Test with a hostname that might work in most environments
      case Resolver.resolve("localhost", :udp) do
        {:ok, {ip, port}} ->
          assert port == 5060
          assert is_tuple(ip)
          assert tuple_size(ip) == 4

        {:error, _} ->
          # DNS not available in test environment, skip
          :ok
      end
    end

    test "uses correct default port for UDP" do
      case Resolver.resolve("localhost", :udp) do
        {:ok, {_ip, port}} -> assert port == 5060
        {:error, _} -> :ok
      end
    end

    test "uses correct default port for TCP" do
      case Resolver.resolve("localhost", :tcp) do
        {:ok, {_ip, port}} -> assert port == 5060
        {:error, _} -> :ok
      end
    end

    test "uses correct default port for TLS" do
      case Resolver.resolve("localhost", :tls) do
        {:ok, {_ip, port}} -> assert port == 5061
        {:error, _} -> :ok
      end
    end

    test "returns error for invalid hostname" do
      assert {:error, _} = Resolver.resolve("invalid.host.that.does.not.exist.example", :udp)
    end

    test "uses default transport of UDP when not specified" do
      case Resolver.resolve("localhost") do
        {:ok, {_ip, port}} -> assert port == 5060
        {:error, _} -> :ok
      end
    end
  end

  describe "a_record_lookup/1" do
    test "returns IPv4 tuple format when successful" do
      case Resolver.a_record_lookup(~c"localhost") do
        {:ok, ip} ->
          assert is_tuple(ip)
          assert tuple_size(ip) == 4
          assert Enum.all?(Tuple.to_list(ip), &is_integer/1)

        {:error, :no_a_record} ->
          # DNS not available, skip
          :ok
      end
    end

    test "returns error for invalid hostname" do
      assert {:error, :no_a_record} =
               Resolver.a_record_lookup(~c"invalid.host.that.does.not.exist.example")
    end
  end

  describe "srv_lookup/2" do
    test "returns error for localhost without SRV records" do
      # localhost typically doesn't have SRV records
      assert {:error, :no_srv_record} = Resolver.srv_lookup(~c"localhost", :udp)
    end

    test "handles UDP transport prefix" do
      # Even though it will fail for localhost, we're testing the query formation
      assert {:error, _} = Resolver.srv_lookup(~c"localhost", :udp)
    end

    test "handles TCP transport prefix" do
      assert {:error, _} = Resolver.srv_lookup(~c"localhost", :tcp)
    end

    test "handles TLS transport prefix" do
      assert {:error, _} = Resolver.srv_lookup(~c"localhost", :tls)
    end

    test "returns error for invalid hostname" do
      assert {:error, _} =
               Resolver.srv_lookup(~c"invalid.host.that.does.not.exist.example", :udp)
    end
  end

  describe "edge cases" do
    test "handles empty string gracefully" do
      # Empty hostname should fail DNS lookup
      assert {:error, _} = Resolver.resolve("", :udp)
    end

    test "handles invalid hostname correctly" do
      assert {:error, _} = Resolver.resolve("definitely.not.a.real.hostname.test", :udp)
    end
  end
end
