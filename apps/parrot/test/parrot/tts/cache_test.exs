defmodule Parrot.TTS.CacheTest do
  use ExUnit.Case, async: true

  describe "Cache behaviour contract" do
    test "behaviour module exists" do
      assert Code.ensure_loaded?(Parrot.TTS.Cache)
    end

    test "defines get/1 callback" do
      assert function_exported?(Parrot.TTS.Cache, :behaviour_info, 1)
      callbacks = Parrot.TTS.Cache.behaviour_info(:callbacks)
      assert {:get, 1} in callbacks
    end

    test "defines put/3 callback" do
      callbacks = Parrot.TTS.Cache.behaviour_info(:callbacks)
      assert {:put, 3} in callbacks
    end

    test "defines delete/1 callback" do
      callbacks = Parrot.TTS.Cache.behaviour_info(:callbacks)
      assert {:delete, 1} in callbacks
    end

    test "defines clear/0 callback" do
      callbacks = Parrot.TTS.Cache.behaviour_info(:callbacks)
      assert {:clear, 0} in callbacks
    end
  end

  describe "Cache behaviour implementation" do
    defmodule TestCache do
      @behaviour Parrot.TTS.Cache

      @impl true
      def get(key) do
        case :ets.lookup(:test_cache, key) do
          [{^key, audio_data, metadata}] -> {:ok, audio_data, metadata}
          [] -> :miss
        end
      end

      @impl true
      def put(key, audio_data, metadata) do
        :ets.insert(:test_cache, {key, audio_data, metadata})
        :ok
      rescue
        e -> {:error, e}
      end

      @impl true
      def delete(key) do
        :ets.delete(:test_cache, key)
        :ok
      end

      @impl true
      def clear() do
        :ets.delete_all_objects(:test_cache)
        :ok
      end
    end

    setup do
      # Create ETS table for test cache
      :ets.new(:test_cache, [:set, :public, :named_table])
      on_exit(fn -> :ets.delete(:test_cache) end)
      :ok
    end

    test "mock implementation compiles and implements all callbacks" do
      assert function_exported?(TestCache, :get, 1)
      assert function_exported?(TestCache, :put, 3)
      assert function_exported?(TestCache, :delete, 1)
      assert function_exported?(TestCache, :clear, 0)
    end

    test "get/1 returns :miss for non-existent key" do
      assert TestCache.get("non_existent") == :miss
    end

    test "put/3 stores audio data and metadata" do
      audio_data = <<1, 2, 3, 4>>
      metadata = %{format: "wav", duration_ms: 1000}

      assert TestCache.put("test_key", audio_data, metadata) == :ok
    end

    test "get/1 returns stored audio data and metadata" do
      audio_data = <<1, 2, 3, 4>>
      metadata = %{format: "wav", duration_ms: 1000}

      TestCache.put("test_key", audio_data, metadata)
      assert {:ok, ^audio_data, ^metadata} = TestCache.get("test_key")
    end

    test "delete/1 removes cached entry" do
      audio_data = <<1, 2, 3, 4>>
      metadata = %{format: "wav", duration_ms: 1000}

      TestCache.put("test_key", audio_data, metadata)
      assert {:ok, _, _} = TestCache.get("test_key")

      assert TestCache.delete("test_key") == :ok
      assert TestCache.get("test_key") == :miss
    end

    test "clear/0 removes all cached entries" do
      TestCache.put("key1", <<1>>, %{})
      TestCache.put("key2", <<2>>, %{})
      TestCache.put("key3", <<3>>, %{})

      assert {:ok, _, _} = TestCache.get("key1")
      assert {:ok, _, _} = TestCache.get("key2")
      assert {:ok, _, _} = TestCache.get("key3")

      assert TestCache.clear() == :ok

      assert TestCache.get("key1") == :miss
      assert TestCache.get("key2") == :miss
      assert TestCache.get("key3") == :miss
    end

    test "put/3 overwrites existing entry" do
      audio_data1 = <<1, 2, 3>>
      metadata1 = %{format: "wav", duration_ms: 500}
      audio_data2 = <<4, 5, 6, 7>>
      metadata2 = %{format: "mp3", duration_ms: 1000}

      TestCache.put("test_key", audio_data1, metadata1)
      assert {:ok, ^audio_data1, ^metadata1} = TestCache.get("test_key")

      TestCache.put("test_key", audio_data2, metadata2)
      assert {:ok, ^audio_data2, ^metadata2} = TestCache.get("test_key")
    end

    test "handles binary audio data correctly" do
      # Test with various binary sizes
      small_audio = <<1, 2, 3>>
      medium_audio = :crypto.strong_rand_bytes(1024)
      large_audio = :crypto.strong_rand_bytes(1024 * 100)

      TestCache.put("small", small_audio, %{size: byte_size(small_audio)})
      TestCache.put("medium", medium_audio, %{size: byte_size(medium_audio)})
      TestCache.put("large", large_audio, %{size: byte_size(large_audio)})

      assert {:ok, ^small_audio, _} = TestCache.get("small")
      assert {:ok, ^medium_audio, _} = TestCache.get("medium")
      assert {:ok, ^large_audio, _} = TestCache.get("large")
    end

    test "handles metadata with various map structures" do
      audio_data = <<1, 2, 3>>

      # Empty metadata
      TestCache.put("empty_meta", audio_data, %{})
      assert {:ok, ^audio_data, meta} = TestCache.get("empty_meta")
      assert meta == %{}

      # Nested metadata
      complex_meta = %{
        format: "wav",
        encoding: %{codec: "pcm", sample_rate: 16000},
        timestamps: %{created_at: DateTime.utc_now(), ttl_seconds: 3600}
      }
      TestCache.put("complex_meta", audio_data, complex_meta)
      assert {:ok, ^audio_data, ^complex_meta} = TestCache.get("complex_meta")
    end
  end
end
