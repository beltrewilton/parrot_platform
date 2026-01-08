defmodule ParrotSip.Auth.NonceStoreTest do
  use ExUnit.Case, async: false

  alias ParrotSip.Auth.NonceStore

  @moduletag :auth

  # RFC 2617 Section 3.2.1: Nonce must be unique and should be time-limited
  # RFC 3261 Section 22: SIP authentication follows HTTP authentication (RFC 2617)

  describe "generate_nonce/0" do
    test "generates a unique nonce string" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_1)

      nonce = NonceStore.generate_nonce(pid)

      assert is_binary(nonce)
      assert String.length(nonce) > 0

      GenServer.stop(pid)
    end

    test "generates unique nonces on each call" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_2)

      nonce1 = NonceStore.generate_nonce(pid)
      nonce2 = NonceStore.generate_nonce(pid)
      nonce3 = NonceStore.generate_nonce(pid)

      assert nonce1 != nonce2
      assert nonce2 != nonce3
      assert nonce1 != nonce3

      GenServer.stop(pid)
    end

    test "stores generated nonce for later validation" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_3)

      nonce = NonceStore.generate_nonce(pid)

      # Should be valid immediately after generation
      assert NonceStore.validate_nonce(pid, nonce, "00000001") == :ok

      GenServer.stop(pid)
    end
  end

  describe "validate_nonce/3" do
    test "validates a previously generated nonce" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_4)

      nonce = NonceStore.generate_nonce(pid)

      assert NonceStore.validate_nonce(pid, nonce, "00000001") == :ok

      GenServer.stop(pid)
    end

    test "rejects unknown nonce" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_5)

      # Never generated this nonce
      assert NonceStore.validate_nonce(pid, "unknown-nonce-xyz", "00000001") == {:error, :invalid_nonce}

      GenServer.stop(pid)
    end

    test "rejects replayed nc (nonce count)" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_6)

      nonce = NonceStore.generate_nonce(pid)

      # First use with nc=00000001 should succeed
      assert NonceStore.validate_nonce(pid, nonce, "00000001") == :ok

      # Second use with same nc should be rejected (replay attack prevention)
      assert NonceStore.validate_nonce(pid, nonce, "00000001") == {:error, :replay_detected}

      GenServer.stop(pid)
    end

    test "allows incrementing nc values" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_7)

      nonce = NonceStore.generate_nonce(pid)

      # Sequential nc values should all succeed
      assert NonceStore.validate_nonce(pid, nonce, "00000001") == :ok
      assert NonceStore.validate_nonce(pid, nonce, "00000002") == :ok
      assert NonceStore.validate_nonce(pid, nonce, "00000003") == :ok

      GenServer.stop(pid)
    end

    test "rejects nc values that go backwards" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_8)

      nonce = NonceStore.generate_nonce(pid)

      # Use nc=00000005 first
      assert NonceStore.validate_nonce(pid, nonce, "00000005") == :ok

      # Lower nc value should be rejected
      assert NonceStore.validate_nonce(pid, nonce, "00000003") == {:error, :replay_detected}

      GenServer.stop(pid)
    end

    test "handles nil nc (qop not used)" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_9)

      nonce = NonceStore.generate_nonce(pid)

      # When qop is not used, nc is nil - should still validate nonce
      assert NonceStore.validate_nonce(pid, nonce, nil) == :ok

      GenServer.stop(pid)
    end
  end

  describe "nonce expiration" do
    test "returns stale error for expired nonce" do
      # Start with very short TTL for testing
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_10, ttl_seconds: 1)

      nonce = NonceStore.generate_nonce(pid)

      # Should be valid immediately
      assert NonceStore.validate_nonce(pid, nonce, "00000001") == :ok

      # Wait for expiration
      Process.sleep(1100)

      # Should now be stale (not invalid - client should retry with new nonce)
      assert NonceStore.validate_nonce(pid, nonce, "00000002") == {:error, :stale_nonce}

      GenServer.stop(pid)
    end

    test "cleanup removes expired nonces" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_11, ttl_seconds: 1, cleanup_interval: 500)

      nonce = NonceStore.generate_nonce(pid)

      # Wait for expiration and cleanup
      Process.sleep(1600)

      # After cleanup, nonce should be completely gone
      assert NonceStore.validate_nonce(pid, nonce, "00000001") == {:error, :invalid_nonce}

      GenServer.stop(pid)
    end
  end

  describe "invalidate_nonce/2" do
    test "removes a nonce from the store" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_12)

      nonce = NonceStore.generate_nonce(pid)

      # Valid before invalidation
      assert NonceStore.validate_nonce(pid, nonce, "00000001") == :ok

      # Invalidate it
      :ok = NonceStore.invalidate_nonce(pid, nonce)

      # Now should be invalid
      assert NonceStore.validate_nonce(pid, nonce, "00000002") == {:error, :invalid_nonce}

      GenServer.stop(pid)
    end
  end

  describe "get_nonce_info/2" do
    test "returns nonce metadata" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_13)

      nonce = NonceStore.generate_nonce(pid)

      {:ok, info} = NonceStore.get_nonce_info(pid, nonce)

      assert is_integer(info.created_at)
      assert info.created_at > 0
      assert info.last_nc == nil

      GenServer.stop(pid)
    end

    test "tracks last nc used" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_14)

      nonce = NonceStore.generate_nonce(pid)
      NonceStore.validate_nonce(pid, nonce, "00000003")

      {:ok, info} = NonceStore.get_nonce_info(pid, nonce)

      assert info.last_nc == 3

      GenServer.stop(pid)
    end

    test "returns error for unknown nonce" do
      {:ok, pid} = NonceStore.start_link(name: :test_nonce_store_15)

      assert NonceStore.get_nonce_info(pid, "unknown") == {:error, :not_found}

      GenServer.stop(pid)
    end
  end
end
