defmodule Parrot.TTS.Cache.DiskTest do
  use ExUnit.Case, async: false

  alias Parrot.TTS.Cache.Disk

  # Use a unique temp directory for each test run
  @test_cache_dir Path.join(
                    System.tmp_dir!(),
                    "parrot_tts_cache_test_#{:rand.uniform(1_000_000)}"
                  )

  setup do
    # Create a unique cache directory for this test
    cache_dir = @test_cache_dir <> "_#{:rand.uniform(1_000_000)}"
    File.rm_rf!(cache_dir)
    File.mkdir_p!(cache_dir)

    # Start the Disk cache with the test directory
    pid =
      case Disk.start_link(cache_dir: cache_dir, ttl: 3600) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    on_exit(fn ->
      # Clean up the cache directory
      File.rm_rf!(cache_dir)
      # Stop the cache if still running
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal, 1000)
      end
    end)

    {:ok, pid: pid, cache_dir: cache_dir}
  end

  describe "get/1" do
    test "returns :miss for unknown key" do
      key = "unknown_key_#{:rand.uniform(1000)}"

      assert Disk.get(key) == :miss
    end

    test "returns :miss for non-existent SHA256 hash" do
      # Valid SHA256 hash format (64 hex chars)
      key = :crypto.hash(:sha256, "a") |> Base.encode16(case: :lower)

      assert Disk.get(key) == :miss
    end
  end

  describe "put/3" do
    test "stores audio data with metadata", %{cache_dir: cache_dir} do
      key = "test_key_#{:rand.uniform(1000)}"
      audio_data = <<1, 2, 3, 4, 5>>

      metadata = %{
        format: :mp3,
        provider: :openai,
        created_at: DateTime.utc_now(),
        size_bytes: byte_size(audio_data)
      }

      assert Disk.put(key, audio_data, metadata) == :ok

      # Verify files were created
      audio_path = Path.join(cache_dir, "#{key}.audio")
      meta_path = Path.join(cache_dir, "#{key}.meta")
      assert File.exists?(audio_path)
      assert File.exists?(meta_path)
    end

    test "stores large audio binary", %{cache_dir: cache_dir} do
      key = "large_audio_key"
      # Simulate a 1MB audio file
      audio_data = :crypto.strong_rand_bytes(1024 * 1024)

      metadata = %{
        format: :wav,
        provider: :elevenlabs,
        created_at: DateTime.utc_now(),
        size_bytes: byte_size(audio_data)
      }

      assert Disk.put(key, audio_data, metadata) == :ok

      # Verify the audio file size
      audio_path = Path.join(cache_dir, "#{key}.audio")
      assert File.stat!(audio_path).size == 1024 * 1024
    end

    test "overwrites existing entry with same key" do
      key = "overwrite_key"
      audio_data1 = <<1, 2, 3>>

      metadata1 = %{
        format: :mp3,
        provider: :openai,
        created_at: DateTime.utc_now(),
        size_bytes: 3
      }

      audio_data2 = <<4, 5, 6, 7, 8>>

      metadata2 = %{
        format: :wav,
        provider: :google,
        created_at: DateTime.utc_now(),
        size_bytes: 5
      }

      assert Disk.put(key, audio_data1, metadata1) == :ok
      assert Disk.put(key, audio_data2, metadata2) == :ok

      # Should return the second version
      assert {:ok, ^audio_data2, retrieved_meta} = Disk.get(key)
      assert retrieved_meta.format == metadata2.format
      assert retrieved_meta.provider == metadata2.provider
    end

    test "handles all supported audio formats" do
      formats = [:mp3, :wav, :pcm, :ogg]

      for format <- formats do
        key = "format_test_#{format}"
        audio_data = <<0, 1, 2>>

        metadata = %{
          format: format,
          provider: :openai,
          created_at: DateTime.utc_now(),
          size_bytes: 3
        }

        assert Disk.put(key, audio_data, metadata) == :ok
        assert {:ok, ^audio_data, stored_meta} = Disk.get(key)
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

        assert Disk.put(key, audio_data, metadata) == :ok
        assert {:ok, ^audio_data, stored_meta} = Disk.get(key)
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

      assert Disk.put(key, audio_data, metadata) == :ok
      assert {:ok, ^audio_data, retrieved_meta} = Disk.get(key)
      assert retrieved_meta.format == metadata.format
      assert retrieved_meta.provider == metadata.provider
      assert retrieved_meta.size_bytes == metadata.size_bytes
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

      assert Disk.put(key, audio_data, metadata) == :ok
      assert {:ok, retrieved_data, _} = Disk.get(key)
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

      assert Disk.put(key, audio_data, metadata) == :ok
      assert {:ok, _, retrieved_meta} = Disk.get(key)
      assert retrieved_meta.format == :ogg
      assert retrieved_meta.provider == :polly
      assert DateTime.compare(retrieved_meta.created_at, now) == :eq
      assert retrieved_meta.size_bytes == 3
    end
  end

  describe "delete/1" do
    test "removes entry from cache", %{cache_dir: cache_dir} do
      key = "delete_key_#{:rand.uniform(1000)}"
      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      # Store entry
      assert Disk.put(key, audio_data, metadata) == :ok
      assert {:ok, _, _} = Disk.get(key)

      # Delete entry
      assert Disk.delete(key) == :ok

      # Entry should be gone
      assert Disk.get(key) == :miss

      # Files should be removed
      audio_path = Path.join(cache_dir, "#{key}.audio")
      meta_path = Path.join(cache_dir, "#{key}.meta")
      refute File.exists?(audio_path)
      refute File.exists?(meta_path)
    end

    test "returns :ok when deleting non-existent key (idempotent)" do
      key = "non_existent_key_#{:rand.uniform(1000)}"

      # Should not error when deleting non-existent key
      assert Disk.delete(key) == :ok

      # Multiple deletes should also work
      assert Disk.delete(key) == :ok
    end

    test "only deletes the specified key" do
      key1 = "delete_test_key_1"
      key2 = "delete_test_key_2"
      key3 = "delete_test_key_3"

      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      # Store multiple entries
      assert Disk.put(key1, audio_data, metadata) == :ok
      assert Disk.put(key2, audio_data, metadata) == :ok
      assert Disk.put(key3, audio_data, metadata) == :ok

      # Delete only key2
      assert Disk.delete(key2) == :ok

      # key1 and key3 should still exist
      assert {:ok, _, _} = Disk.get(key1)
      assert {:ok, _, _} = Disk.get(key3)

      # key2 should be gone
      assert Disk.get(key2) == :miss
    end
  end

  describe "clear/0" do
    test "removes all entries from cache", %{cache_dir: cache_dir} do
      # Store multiple entries
      for i <- 1..10 do
        key = "clear_test_key_#{i}"
        audio_data = <<i>>

        metadata = %{
          format: :mp3,
          provider: :openai,
          created_at: DateTime.utc_now(),
          size_bytes: 1
        }

        assert Disk.put(key, audio_data, metadata) == :ok
      end

      # Verify they exist
      for i <- 1..10 do
        key = "clear_test_key_#{i}"
        assert {:ok, _, _} = Disk.get(key)
      end

      # Clear the cache
      assert Disk.clear() == :ok

      # Verify all entries are gone
      for i <- 1..10 do
        key = "clear_test_key_#{i}"
        assert Disk.get(key) == :miss
      end

      # Verify cache directory is empty (no .audio or .meta files)
      files = File.ls!(cache_dir)

      cache_files =
        Enum.filter(files, fn f ->
          String.ends_with?(f, ".audio") or String.ends_with?(f, ".meta")
        end)

      assert cache_files == []
    end

    test "returns :ok when cache is already empty" do
      # Clear empty cache should succeed
      assert Disk.clear() == :ok

      # Should still work after clearing
      assert Disk.clear() == :ok
    end

    test "cache is usable after clear" do
      # Store, clear, then store again
      key1 = "before_clear"
      key2 = "after_clear"
      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      assert Disk.put(key1, audio_data, metadata) == :ok
      assert Disk.clear() == :ok
      assert Disk.get(key1) == :miss

      # Should be able to store new entries
      assert Disk.put(key2, audio_data, metadata) == :ok
      assert {:ok, ^audio_data, _} = Disk.get(key2)
    end
  end

  describe "TTL expiration" do
    test "returns :miss for expired entries" do
      # Start a cache with a very short TTL (1 second)
      cache_dir = @test_cache_dir <> "_ttl_#{:rand.uniform(1_000_000)}"
      File.mkdir_p!(cache_dir)

      # Stop the existing Disk GenServer to start a new one with different TTL
      GenServer.stop(Disk, :normal, 1000)

      {:ok, _pid} = Disk.start_link(cache_dir: cache_dir, ttl: 1)

      key = "expiring_key"
      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      assert Disk.put(key, audio_data, metadata) == :ok
      assert {:ok, _, _} = Disk.get(key)

      # Wait for TTL to expire (1500ms to ensure DateTime.diff returns >= 1 second)
      Process.sleep(1500)

      # Should return :miss after TTL expires
      assert Disk.get(key) == :miss

      File.rm_rf!(cache_dir)
    end

    test "expired entries are deleted on read", %{cache_dir: cache_dir} do
      # Stop the existing Disk GenServer to start a new one with different TTL
      GenServer.stop(Disk, :normal, 1000)

      {:ok, _pid} = Disk.start_link(cache_dir: cache_dir, ttl: 1)

      key = "lazy_delete_key"
      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      assert Disk.put(key, audio_data, metadata) == :ok

      # Verify files exist
      audio_path = Path.join(cache_dir, "#{key}.audio")
      meta_path = Path.join(cache_dir, "#{key}.meta")
      assert File.exists?(audio_path)
      assert File.exists?(meta_path)

      # Wait for TTL to expire (1500ms to ensure DateTime.diff returns >= 1 second)
      Process.sleep(1500)

      # Get should return :miss and delete the files (lazy deletion)
      assert Disk.get(key) == :miss

      # Files should be removed after lazy deletion
      refute File.exists?(audio_path)
      refute File.exists?(meta_path)
    end

    test "non-expired entries are returned normally" do
      key = "fresh_key"
      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      assert Disk.put(key, audio_data, metadata) == :ok

      # Should still be valid (TTL is 3600 seconds by default in setup)
      assert {:ok, ^audio_data, _} = Disk.get(key)
    end
  end

  describe "file storage" do
    test "audio file contains exact binary data", %{cache_dir: cache_dir} do
      key = "file_content_test"
      audio_data = :crypto.strong_rand_bytes(256)

      metadata = %{
        format: :mp3,
        provider: :openai,
        created_at: DateTime.utc_now(),
        size_bytes: 256
      }

      assert Disk.put(key, audio_data, metadata) == :ok

      audio_path = Path.join(cache_dir, "#{key}.audio")
      assert File.read!(audio_path) == audio_data
    end

    test "metadata file is readable and valid", %{cache_dir: cache_dir} do
      key = "meta_file_test"
      audio_data = <<1, 2, 3>>
      now = DateTime.utc_now()
      metadata = %{format: :wav, provider: :google, created_at: now, size_bytes: 3}

      assert Disk.put(key, audio_data, metadata) == :ok

      meta_path = Path.join(cache_dir, "#{key}.meta")
      assert File.exists?(meta_path)

      # The metadata should be deserializable
      stored_meta = meta_path |> File.read!() |> :erlang.binary_to_term()
      assert stored_meta.format == :wav
      assert stored_meta.provider == :google
    end
  end

  describe "configuration" do
    test "uses configured cache directory" do
      custom_dir = Path.join(System.tmp_dir!(), "parrot_custom_cache_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(custom_dir)

      # Stop the existing Disk GenServer
      GenServer.stop(Disk, :normal, 1000)

      {:ok, _pid} = Disk.start_link(cache_dir: custom_dir, ttl: 3600)

      key = "custom_dir_test"
      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      assert Disk.put(key, audio_data, metadata) == :ok

      # Verify files are in the custom directory
      assert File.exists?(Path.join(custom_dir, "#{key}.audio"))
      assert File.exists?(Path.join(custom_dir, "#{key}.meta"))

      File.rm_rf!(custom_dir)
    end

    test "creates cache directory if it doesn't exist" do
      new_dir = Path.join(System.tmp_dir!(), "parrot_new_cache_#{:rand.uniform(1_000_000)}")
      # Ensure it doesn't exist
      File.rm_rf!(new_dir)
      refute File.exists?(new_dir)

      # Stop the existing Disk GenServer
      GenServer.stop(Disk, :normal, 1000)

      {:ok, _pid} = Disk.start_link(cache_dir: new_dir, ttl: 3600)

      # Directory should now exist
      assert File.exists?(new_dir)
      assert File.dir?(new_dir)

      File.rm_rf!(new_dir)
    end
  end

  describe "behaviour compliance" do
    test "implements Parrot.TTS.Cache behaviour" do
      # Verify module implements the behaviour
      behaviours = Disk.module_info(:attributes)[:behaviour] || []
      assert Parrot.TTS.Cache in behaviours
    end

    test "exports all required callback functions" do
      assert function_exported?(Disk, :get, 1)
      assert function_exported?(Disk, :put, 3)
      assert function_exported?(Disk, :delete, 1)
      assert function_exported?(Disk, :clear, 0)
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

            Disk.put(key, audio_data, metadata)
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))

      # Verify all entries were stored
      for i <- 1..50 do
        key = "concurrent_key_#{i}"
        assert {:ok, <<^i>>, _} = Disk.get(key)
      end
    end

    test "handles concurrent reads and writes" do
      key = "concurrent_rw_key"
      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      # Initial write
      assert Disk.put(key, audio_data, metadata) == :ok

      # Spawn many readers and writers
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              # Reader
              case Disk.get(key) do
                {:ok, _, _} -> :read_ok
                :miss -> :read_miss
              end
            else
              # Writer
              Disk.put(key, <<i>>, metadata)
              :write_ok
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)
      # All operations should complete without errors
      assert length(results) == 100
    end

    test "handles concurrent deletes" do
      # First create multiple entries
      for i <- 1..20 do
        key = "concurrent_delete_#{i}"
        audio_data = <<i>>

        metadata = %{
          format: :mp3,
          provider: :openai,
          created_at: DateTime.utc_now(),
          size_bytes: 1
        }

        assert Disk.put(key, audio_data, metadata) == :ok
      end

      # Concurrently delete all entries
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            key = "concurrent_delete_#{i}"
            Disk.delete(key)
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))

      # Verify all entries are gone
      for i <- 1..20 do
        key = "concurrent_delete_#{i}"
        assert Disk.get(key) == :miss
      end
    end
  end

  describe "error handling" do
    test "returns error when cache directory is not writable" do
      # Create a read-only directory
      readonly_dir = Path.join(System.tmp_dir!(), "parrot_readonly_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(readonly_dir)
      File.chmod!(readonly_dir, 0o444)

      # Stop the existing Disk GenServer
      GenServer.stop(Disk, :normal, 1000)

      {:ok, _pid} = Disk.start_link(cache_dir: readonly_dir, ttl: 3600)

      key = "write_test"
      audio_data = <<1, 2, 3>>
      metadata = %{format: :mp3, provider: :openai, created_at: DateTime.utc_now(), size_bytes: 3}

      # Should return an error when trying to write
      result = Disk.put(key, audio_data, metadata)
      assert {:error, _reason} = result

      # Restore permissions and cleanup
      File.chmod!(readonly_dir, 0o755)
      File.rm_rf!(readonly_dir)
    end
  end
end
