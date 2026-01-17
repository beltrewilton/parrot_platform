defmodule Parrot.TTS.Cache.ETSTest do
  use ExUnit.Case, async: false

  alias Parrot.TTS.Cache.ETS

  # ETS table name as per spec
  @table_name :parrot_tts_cache

  setup do
    # The ETS cache may already be started by the application supervisor
    # In that case, just clear it for a clean test state
    pid = case ETS.start_link(name: @table_name) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end

    # Clear the cache for a clean test state
    ETS.clear()

    on_exit(fn ->
      # Only stop if we started a new process (not the app-supervised one)
      # Just clear the cache instead to avoid affecting other tests
      ETS.clear()
    end)

    {:ok, pid: pid}
  end

  describe "get/1" do
    test "returns :miss for unknown key" do
      key = "unknown_key_#{:rand.uniform(1000)}"

      assert ETS.get(key) == :miss
    end

    test "returns :miss for non-existent SHA256 hash" do
      # Valid SHA256 hash format (64 hex chars)
      key = :crypto.hash(:sha256, "a") |> Base.encode16(case: :lower)

      assert ETS.get(key) == :miss
    end
  end

  describe "put/3" do
    test "stores audio data with metadata" do
      key = "test_key_#{:rand.uniform(1000)}"
      audio_data = <<1, 2, 3, 4, 5>>
      metadata = %{
        format: :mp3,
        provider: :openai,
        created_at: DateTime.utc_now(),
        size_bytes: byte_size(audio_data)
      }

      assert ETS.put(key, audio_data, metadata) == :ok
    end

    test "stores large audio binary" do
      key = "large_audio_key"
      # Simulate a 1MB audio file
      audio_data = :crypto.strong_rand_bytes(1024 * 1024)
      metadata = %{
        format: :wav,
        provider: :elevenlabs,
        created_at: DateTime.utc_now(),
        size_bytes: byte_size(audio_data)
      }

      assert ETS.put(key, audio_data, metadata) == :ok
    end

    test "overwrites existing entry with same key" do
      key = "overwrite_key"
      audio_data1 = <<1, 2, 3>>
      metadata1 = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      audio_data2 = <<4, 5, 6, 7, 8>>
      metadata2 = %{format: :wav, provider: :google, created_at: DateTime.utc_now(), size_bytes: 5}

      assert ETS.put(key, audio_data1, metadata1) == :ok
      assert ETS.put(key, audio_data2, metadata2) == :ok

      # Should return the second version
      assert {:ok, ^audio_data2, ^metadata2} = ETS.get(key)
    end

    test "handles all supported audio formats" do
      formats = [:mp3, :wav, :pcm, :ogg]

      for format <- formats do
        key = "format_test_#{format}"
        audio_data = <<0, 1, 2>>
        metadata = %{format: format, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

        assert ETS.put(key, audio_data, metadata) == :ok
        assert {:ok, ^audio_data, stored_meta} = ETS.get(key)
        assert stored_meta.format == format
      end
    end

    test "handles all supported providers" do
      providers = [:openai, :elevenlabs, :google, :polly]

      for provider <- providers do
        key = "provider_test_#{provider}"
        audio_data = <<0, 1, 2>>
        metadata = %{
          format: :mp3,
          provider: provider,
          created_at: DateTime.utc_now(),
          size_bytes: 3
        }

        assert ETS.put(key, audio_data, metadata) == :ok
        assert {:ok, ^audio_data, stored_meta} = ETS.get(key)
        assert stored_meta.provider == provider
      end
    end
  end

  describe "get/1 after put/3" do
    test "returns {:ok, audio_data, metadata} for known key" do
      key = "known_key_#{:rand.uniform(1000)}"
      audio_data = <<10, 20, 30, 40>>
      metadata = %{
        format: :mp3,
        provider: :openai,
        created_at: DateTime.utc_now(),
        size_bytes: byte_size(audio_data)
      }

      assert ETS.put(key, audio_data, metadata) == :ok
      assert {:ok, ^audio_data, ^metadata} = ETS.get(key)
    end

    test "preserves exact binary data" do
      key = "binary_preservation_key"
      # Random binary data
      audio_data = :crypto.strong_rand_bytes(1024)
      metadata = %{
        format: :wav,
        provider: :elevenlabs,
        created_at: DateTime.utc_now(),
        size_bytes: byte_size(audio_data)
      }

      assert ETS.put(key, audio_data, metadata) == :ok
      assert {:ok, retrieved_data, _} = ETS.get(key)
      assert retrieved_data == audio_data
      assert byte_size(retrieved_data) == byte_size(audio_data)
    end

    test "preserves metadata structure" do
      key = "metadata_preservation_key"
      audio_data = <<1, 2, 3>>
      now = DateTime.utc_now()
      metadata = %{
        format: :ogg,
        provider: :polly,
        created_at: now,
        size_bytes: 3
      }

      assert ETS.put(key, audio_data, metadata) == :ok
      assert {:ok, _, retrieved_meta} = ETS.get(key)
      assert retrieved_meta.format == :ogg
      assert retrieved_meta.provider == :polly
      assert DateTime.compare(retrieved_meta.created_at, now) == :eq
      assert retrieved_meta.size_bytes == 3
    end
  end

  describe "delete/1" do
    test "removes entry from cache" do
      key = "delete_key_#{:rand.uniform(1000)}"
      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      # Store entry
      assert ETS.put(key, audio_data, metadata) == :ok
      assert {:ok, _, _} = ETS.get(key)

      # Delete entry
      assert ETS.delete(key) == :ok

      # Entry should be gone
      assert ETS.get(key) == :miss
    end

    test "returns :ok when deleting non-existent key (idempotent)" do
      key = "non_existent_key_#{:rand.uniform(1000)}"

      # Should not error when deleting non-existent key
      assert ETS.delete(key) == :ok

      # Multiple deletes should also work
      assert ETS.delete(key) == :ok
    end

    test "only deletes the specified key" do
      key1 = "delete_test_key_1"
      key2 = "delete_test_key_2"
      key3 = "delete_test_key_3"

      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      # Store multiple entries
      assert ETS.put(key1, audio_data, metadata) == :ok
      assert ETS.put(key2, audio_data, metadata) == :ok
      assert ETS.put(key3, audio_data, metadata) == :ok

      # Delete only key2
      assert ETS.delete(key2) == :ok

      # key1 and key3 should still exist
      assert {:ok, _, _} = ETS.get(key1)
      assert {:ok, _, _} = ETS.get(key3)

      # key2 should be gone
      assert ETS.get(key2) == :miss
    end
  end

  describe "clear/0" do
    test "removes all entries from cache" do
      # Store multiple entries
      for i <- 1..10 do
        key = "clear_test_key_#{i}"
        audio_data = <<i>>
        metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 1}
        assert ETS.put(key, audio_data, metadata) == :ok
      end

      # Verify they exist
      for i <- 1..10 do
        key = "clear_test_key_#{i}"
        assert {:ok, _, _} = ETS.get(key)
      end

      # Clear the cache
      assert ETS.clear() == :ok

      # Verify all entries are gone
      for i <- 1..10 do
        key = "clear_test_key_#{i}"
        assert ETS.get(key) == :miss
      end
    end

    test "returns :ok when cache is already empty" do
      # Clear empty cache should succeed
      assert ETS.clear() == :ok

      # Should still work after clearing
      assert ETS.clear() == :ok
    end

    test "cache is usable after clear" do
      # Store, clear, then store again
      key1 = "before_clear"
      key2 = "after_clear"
      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      assert ETS.put(key1, audio_data, metadata) == :ok
      assert ETS.clear() == :ok
      assert ETS.get(key1) == :miss

      # Should be able to store new entries
      assert ETS.put(key2, audio_data, metadata) == :ok
      assert {:ok, ^audio_data, ^metadata} = ETS.get(key2)
    end
  end

  describe "concurrent access" do
    test "handles multiple concurrent writes" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            key = "concurrent_key_#{i}"
            audio_data = <<i>>
            metadata = %{
              format: :mp3,
              provider: :openai,
              created_at: DateTime.utc_now(),
              size_bytes: 1
            }

            ETS.put(key, audio_data, metadata)
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      # Verify all entries were stored
      for i <- 1..50 do
        key = "concurrent_key_#{i}"
        assert {:ok, <<^i>>, _} = ETS.get(key)
      end
    end

    test "handles concurrent reads and writes" do
      key = "concurrent_rw_key"
      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      # Initial write
      assert ETS.put(key, audio_data, metadata) == :ok

      # Spawn many readers and writers
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              # Reader
              case ETS.get(key) do
                {:ok, _, _} -> :read_ok
                :miss -> :read_miss
              end
            else
              # Writer
              ETS.put(key, <<i>>, metadata)
              :write_ok
            end
          end)
        end

      results = Task.await_many(tasks)
      # All operations should complete without errors
      assert length(results) == 100
    end
  end

  describe "behaviour compliance" do
    test "implements Parrot.TTS.Cache behaviour" do
      # Verify module implements the behaviour
      behaviours = ETS.module_info(:attributes)[:behaviour] || []
      assert Parrot.TTS.Cache in behaviours
    end

    test "exports all required callback functions" do
      assert function_exported?(ETS, :get, 1)
      assert function_exported?(ETS, :put, 3)
      assert function_exported?(ETS, :delete, 1)
      assert function_exported?(ETS, :clear, 0)
    end
  end
end
