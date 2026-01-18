defmodule Parrot.TTS.CacheTest do
  @moduledoc """
  Contract tests for the Parrot.TTS.Cache behaviour.

  These tests define and verify the contract that all TTS cache implementations
  must follow. The behaviour requires four callbacks:

  - `get/1` - Retrieves cached audio data and metadata by key
  - `put/3` - Stores audio data with metadata under a key
  - `delete/1` - Removes a cached entry by key
  - `clear/0` - Clears all cached entries

  ## Cache Key Design (FR-015)

  Cache keys are deterministic hashes of text + voice configuration, ensuring
  identical synthesis requests produce cache hits. Key generation includes:
  - Text content
  - Voice ID
  - Provider name
  - Audio format
  - Other synthesis parameters

  ## TDD Note

  These tests are written BEFORE the Cache behaviour module exists.
  They will fail initially (red phase) and guide the implementation (green phase).
  """
  use ExUnit.Case, async: true

  # The behaviour module - tests verify it defines the correct callbacks
  alias Parrot.TTS.Cache

  describe "Cache behaviour definition" do
    test "behaviour module exists" do
      assert Code.ensure_loaded?(Cache)
    end

    test "defines get/1 callback" do
      assert function_exported?(Cache, :behaviour_info, 1)
      callbacks = Cache.behaviour_info(:callbacks)
      assert {:get, 1} in callbacks
    end

    test "defines put/3 callback" do
      callbacks = Cache.behaviour_info(:callbacks)
      assert {:put, 3} in callbacks
    end

    test "defines delete/1 callback" do
      callbacks = Cache.behaviour_info(:callbacks)
      assert {:delete, 1} in callbacks
    end

    test "defines clear/0 callback" do
      callbacks = Cache.behaviour_info(:callbacks)
      assert {:clear, 0} in callbacks
    end

    test "defines exactly 4 callbacks" do
      callbacks = Cache.behaviour_info(:callbacks)
      assert length(callbacks) == 4
    end
  end

  describe "Cache behaviour contract - get/1" do
    defmodule GetMock do
      @moduledoc "Mock cache for testing get/1 contract"
      @behaviour Parrot.TTS.Cache

      @impl true
      def get("hit") do
        {:ok, <<1, 2, 3, 4>>, %{format: :mp3, duration_ms: 1000}}
      end

      def get("miss") do
        :miss
      end

      def get("empty_audio") do
        {:ok, <<>>, %{format: :mp3, duration_ms: 0}}
      end

      def get("large_audio") do
        # Simulate large cached audio (1MB)
        audio_data = :binary.copy(<<0>>, 1024 * 1024)
        {:ok, audio_data, %{format: :wav, size_bytes: 1_048_576}}
      end

      @impl true
      def put(_key, _audio_data, _metadata), do: :ok

      @impl true
      def delete(_key), do: :ok

      @impl true
      def clear(), do: :ok
    end

    test "returns {:ok, audio_data, metadata} on cache hit" do
      result = GetMock.get("hit")

      assert {:ok, audio_data, metadata} = result
      assert is_binary(audio_data)
      assert is_map(metadata)
    end

    test "returns :miss on cache miss" do
      result = GetMock.get("miss")

      assert :miss = result
    end

    test "audio_data is a binary" do
      {:ok, audio_data, _metadata} = GetMock.get("hit")

      assert is_binary(audio_data)
      assert byte_size(audio_data) > 0
    end

    test "metadata is a map" do
      {:ok, _audio_data, metadata} = GetMock.get("hit")

      assert is_map(metadata)
    end

    test "handles empty audio binary (edge case)" do
      {:ok, audio_data, metadata} = GetMock.get("empty_audio")

      assert audio_data == <<>>
      assert is_map(metadata)
    end

    test "handles large audio binaries" do
      {:ok, audio_data, metadata} = GetMock.get("large_audio")

      assert byte_size(audio_data) == 1_048_576
      assert metadata.size_bytes == 1_048_576
    end

    test "key is expected to be a string" do
      # Both calls should work without raising - keys are strings
      assert {:ok, _, _} = GetMock.get("hit")
      assert :miss = GetMock.get("miss")
    end
  end

  describe "Cache behaviour contract - put/3" do
    defmodule PutMock do
      @moduledoc "Mock cache for testing put/3 contract"
      @behaviour Parrot.TTS.Cache

      @impl true
      def get(_key), do: :miss

      @impl true
      def put("success", _audio_data, _metadata) do
        :ok
      end

      def put("disk_full", _audio_data, _metadata) do
        {:error, :disk_full}
      end

      def put("permission_denied", _audio_data, _metadata) do
        {:error, :permission_denied}
      end

      def put("invalid_key", _audio_data, _metadata) do
        {:error, :invalid_key}
      end

      def put(_key, _audio_data, _metadata) do
        :ok
      end

      @impl true
      def delete(_key), do: :ok

      @impl true
      def clear(), do: :ok
    end

    test "returns :ok on successful store" do
      audio_data = <<1, 2, 3, 4>>
      metadata = %{format: :mp3, duration_ms: 1000}

      result = PutMock.put("success", audio_data, metadata)

      assert :ok = result
    end

    test "returns {:error, :disk_full} when storage is full" do
      result = PutMock.put("disk_full", <<1, 2, 3>>, %{})

      assert {:error, :disk_full} = result
    end

    test "returns {:error, :permission_denied} for permission issues" do
      result = PutMock.put("permission_denied", <<1, 2, 3>>, %{})

      assert {:error, :permission_denied} = result
    end

    test "returns {:error, reason} on storage failure" do
      result = PutMock.put("invalid_key", <<1, 2, 3>>, %{})

      assert {:error, reason} = result
      assert is_atom(reason)
    end

    test "accepts binary audio data" do
      audio_data = :crypto.strong_rand_bytes(1024)
      metadata = %{format: :wav, size_bytes: 1024}

      result = PutMock.put("test", audio_data, metadata)

      assert :ok = result
    end

    test "accepts metadata map with various structures" do
      audio_data = <<1, 2, 3>>

      # Empty metadata
      assert :ok = PutMock.put("empty", audio_data, %{})

      # Standard metadata
      assert :ok = PutMock.put("standard", audio_data, %{
        format: :mp3,
        duration_ms: 1500,
        provider: :openai
      })

      # Nested metadata
      assert :ok = PutMock.put("nested", audio_data, %{
        format: :wav,
        encoding: %{codec: :pcm, sample_rate: 16000, bit_depth: 16},
        timestamps: %{created_at: DateTime.utc_now(), ttl_seconds: 3600}
      })
    end
  end

  describe "Cache behaviour contract - delete/1" do
    defmodule DeleteMock do
      @moduledoc "Mock cache for testing delete/1 contract"
      @behaviour Parrot.TTS.Cache

      @impl true
      def get(_key), do: :miss

      @impl true
      def put(_key, _audio_data, _metadata), do: :ok

      @impl true
      def delete(_key) do
        # Delete is idempotent - always returns :ok
        :ok
      end

      @impl true
      def clear(), do: :ok
    end

    test "returns :ok when deleting existing entry" do
      result = DeleteMock.delete("existing_key")

      assert :ok = result
    end

    test "returns :ok when deleting non-existent entry (idempotent)" do
      result = DeleteMock.delete("non_existent_key")

      assert :ok = result
    end

    test "delete is idempotent - multiple deletes return :ok" do
      assert :ok = DeleteMock.delete("key")
      assert :ok = DeleteMock.delete("key")
      assert :ok = DeleteMock.delete("key")
    end
  end

  describe "Cache behaviour contract - clear/0" do
    defmodule ClearMock do
      @moduledoc "Mock cache for testing clear/0 contract"
      @behaviour Parrot.TTS.Cache

      @impl true
      def get(_key), do: :miss

      @impl true
      def put(_key, _audio_data, _metadata), do: :ok

      @impl true
      def delete(_key), do: :ok

      @impl true
      def clear() do
        :ok
      end
    end

    test "returns :ok when clearing cache" do
      result = ClearMock.clear()

      assert :ok = result
    end

    test "clear is idempotent - can be called on empty cache" do
      # First clear
      assert :ok = ClearMock.clear()
      # Second clear on empty cache
      assert :ok = ClearMock.clear()
    end
  end

  describe "Cache behaviour contract - cache hit/miss scenarios" do
    defmodule HitMissMock do
      @moduledoc "Mock cache for testing cache hit/miss scenarios"
      @behaviour Parrot.TTS.Cache

      # Simulated in-memory cache using process dictionary (for test purposes only)
      @impl true
      def get(key) do
        case Process.get({:cache, key}) do
          nil -> :miss
          {audio_data, metadata} -> {:ok, audio_data, metadata}
        end
      end

      @impl true
      def put(key, audio_data, metadata) do
        Process.put({:cache, key}, {audio_data, metadata})
        :ok
      end

      @impl true
      def delete(key) do
        Process.delete({:cache, key})
        :ok
      end

      @impl true
      def clear() do
        # Clear all cache entries from process dictionary
        Process.get_keys()
        |> Enum.filter(fn
          {:cache, _} -> true
          _ -> false
        end)
        |> Enum.each(&Process.delete/1)
        :ok
      end
    end

    test "cache miss before put" do
      key = "test_key_#{:rand.uniform(10000)}"

      assert :miss = HitMissMock.get(key)
    end

    test "cache hit after put" do
      key = "test_key_#{:rand.uniform(10000)}"
      audio_data = <<1, 2, 3, 4>>
      metadata = %{format: :mp3}

      assert :miss = HitMissMock.get(key)
      assert :ok = HitMissMock.put(key, audio_data, metadata)
      assert {:ok, ^audio_data, ^metadata} = HitMissMock.get(key)
    end

    test "cache miss after delete" do
      key = "test_key_#{:rand.uniform(10000)}"
      audio_data = <<5, 6, 7>>
      metadata = %{format: :wav}

      assert :ok = HitMissMock.put(key, audio_data, metadata)
      assert {:ok, _, _} = HitMissMock.get(key)
      assert :ok = HitMissMock.delete(key)
      assert :miss = HitMissMock.get(key)
    end

    test "cache miss after clear" do
      key1 = "test_key_1_#{:rand.uniform(10000)}"
      key2 = "test_key_2_#{:rand.uniform(10000)}"
      audio_data = <<8, 9>>
      metadata = %{}

      assert :ok = HitMissMock.put(key1, audio_data, metadata)
      assert :ok = HitMissMock.put(key2, audio_data, metadata)
      assert {:ok, _, _} = HitMissMock.get(key1)
      assert {:ok, _, _} = HitMissMock.get(key2)

      assert :ok = HitMissMock.clear()

      assert :miss = HitMissMock.get(key1)
      assert :miss = HitMissMock.get(key2)
    end

    test "put overwrites existing entry" do
      key = "overwrite_key_#{:rand.uniform(10000)}"
      audio_data1 = <<1, 2, 3>>
      metadata1 = %{format: :mp3, version: 1}
      audio_data2 = <<4, 5, 6, 7>>
      metadata2 = %{format: :wav, version: 2}

      assert :ok = HitMissMock.put(key, audio_data1, metadata1)
      assert {:ok, ^audio_data1, ^metadata1} = HitMissMock.get(key)

      assert :ok = HitMissMock.put(key, audio_data2, metadata2)
      assert {:ok, ^audio_data2, ^metadata2} = HitMissMock.get(key)
    end
  end

  describe "contract verification helper" do
    defmodule ContractVerifier do
      @moduledoc """
      Verifies that a module implements the Parrot.TTS.Cache behaviour correctly.

      ## Usage

          assert ContractVerifier.implements_cache?(MyCacheBackend)
          assert ContractVerifier.verify_get_contract(MyCacheBackend, "key")
          assert ContractVerifier.verify_put_contract(MyCacheBackend, "key", data, meta)
      """

      @doc "Returns true if the module implements the Cache behaviour"
      def implements_cache?(module) do
        behaviours = module.__info__(:attributes)[:behaviour] || []
        Parrot.TTS.Cache in behaviours
      end

      @doc "Verifies get/1 returns correct types"
      def verify_get_contract(module, key) do
        result = module.get(key)

        case result do
          {:ok, audio_data, metadata}
              when is_binary(audio_data) and is_map(metadata) ->
            :ok

          :miss ->
            :ok

          _ ->
            {:error, {:invalid_return, result}}
        end
      end

      @doc "Verifies put/3 returns correct types"
      def verify_put_contract(module, key, audio_data, metadata) do
        result = module.put(key, audio_data, metadata)

        case result do
          :ok -> :ok
          {:error, reason} when is_atom(reason) or is_binary(reason) -> :ok
          _ -> {:error, {:invalid_return, result}}
        end
      end

      @doc "Verifies delete/1 returns correct types"
      def verify_delete_contract(module, key) do
        result = module.delete(key)

        case result do
          :ok -> :ok
          _ -> {:error, {:invalid_return, result}}
        end
      end

      @doc "Verifies clear/0 returns correct types"
      def verify_clear_contract(module) do
        result = module.clear()

        case result do
          :ok -> :ok
          _ -> {:error, {:invalid_return, result}}
        end
      end
    end

    defmodule CompliantCache do
      @moduledoc "A fully compliant cache implementation for testing the verifier"
      @behaviour Parrot.TTS.Cache

      @impl true
      def get(_key), do: :miss

      @impl true
      def put(_key, _audio_data, _metadata), do: :ok

      @impl true
      def delete(_key), do: :ok

      @impl true
      def clear(), do: :ok
    end

    test "ContractVerifier.implements_cache?/1 returns true for compliant module" do
      assert ContractVerifier.implements_cache?(CompliantCache)
    end

    test "ContractVerifier.verify_get_contract/2 passes for :miss return" do
      assert :ok = ContractVerifier.verify_get_contract(CompliantCache, "any_key")
    end

    test "ContractVerifier.verify_put_contract/4 passes for :ok return" do
      assert :ok = ContractVerifier.verify_put_contract(
        CompliantCache,
        "key",
        <<1, 2, 3>>,
        %{format: :mp3}
      )
    end

    test "ContractVerifier.verify_delete_contract/2 passes for :ok return" do
      assert :ok = ContractVerifier.verify_delete_contract(CompliantCache, "key")
    end

    test "ContractVerifier.verify_clear_contract/1 passes for :ok return" do
      assert :ok = ContractVerifier.verify_clear_contract(CompliantCache)
    end
  end

  describe "cache key determinism (FR-015)" do
    # Tests verifying that cache keys are deterministic based on text + voice config.

    defmodule CacheKeyMock do
      @moduledoc "Mock for testing cache key generation"
      @behaviour Parrot.TTS.Cache

      # Process dictionary-based mock storage
      @impl true
      def get(key) do
        case Process.get({:cache, key}) do
          nil -> :miss
          {audio_data, metadata} -> {:ok, audio_data, metadata}
        end
      end

      @impl true
      def put(key, audio_data, metadata) do
        Process.put({:cache, key}, {audio_data, metadata})
        :ok
      end

      @impl true
      def delete(key) do
        Process.delete({:cache, key})
        :ok
      end

      @impl true
      def clear() do
        Process.get_keys()
        |> Enum.filter(fn
          {:cache, _} -> true
          _ -> false
        end)
        |> Enum.each(&Process.delete/1)
        :ok
      end

      @doc "Generate deterministic cache key from text and config (example implementation)"
      def generate_key(text, config) when is_binary(text) and is_map(config) do
        # Normalize config to ensure deterministic ordering
        normalized_config = config
          |> Map.take([:voice, :provider, :format, :model])
          |> Enum.sort()
          |> Enum.into(%{})

        # Create deterministic hash
        :crypto.hash(:sha256, :erlang.term_to_binary({text, normalized_config}))
        |> Base.encode16(case: :lower)
      end
    end

    test "same text and config produce identical cache keys" do
      text = "Hello, world!"
      config = %{voice: "alloy", provider: :openai, format: :mp3}

      key1 = CacheKeyMock.generate_key(text, config)
      key2 = CacheKeyMock.generate_key(text, config)

      assert key1 == key2
    end

    test "different text produces different cache keys" do
      config = %{voice: "alloy", provider: :openai, format: :mp3}

      key1 = CacheKeyMock.generate_key("Hello", config)
      key2 = CacheKeyMock.generate_key("World", config)

      assert key1 != key2
    end

    test "different voice produces different cache keys" do
      text = "Hello, world!"

      key1 = CacheKeyMock.generate_key(text, %{voice: "alloy", provider: :openai, format: :mp3})
      key2 = CacheKeyMock.generate_key(text, %{voice: "echo", provider: :openai, format: :mp3})

      assert key1 != key2
    end

    test "different provider produces different cache keys" do
      text = "Hello, world!"

      key1 = CacheKeyMock.generate_key(text, %{voice: "default", provider: :openai, format: :mp3})
      key2 = CacheKeyMock.generate_key(text, %{voice: "default", provider: :elevenlabs, format: :mp3})

      assert key1 != key2
    end

    test "different format produces different cache keys" do
      text = "Hello, world!"
      base_config = %{voice: "alloy", provider: :openai}

      key_mp3 = CacheKeyMock.generate_key(text, Map.put(base_config, :format, :mp3))
      key_wav = CacheKeyMock.generate_key(text, Map.put(base_config, :format, :wav))

      assert key_mp3 != key_wav
    end

    test "config key ordering does not affect cache key (determinism)" do
      text = "Test text"

      # Same config, different insertion order
      config1 = %{voice: "alloy", provider: :openai, format: :mp3}
      config2 = %{format: :mp3, voice: "alloy", provider: :openai}
      config3 = %{provider: :openai, format: :mp3, voice: "alloy"}

      key1 = CacheKeyMock.generate_key(text, config1)
      key2 = CacheKeyMock.generate_key(text, config2)
      key3 = CacheKeyMock.generate_key(text, config3)

      assert key1 == key2
      assert key2 == key3
    end

    test "cache key is a valid SHA256 hex string" do
      key = CacheKeyMock.generate_key("test", %{voice: "alloy"})

      # SHA256 produces 64 hex characters
      assert String.length(key) == 64
      assert Regex.match?(~r/^[0-9a-f]+$/, key)
    end

    test "cache stores and retrieves by deterministic key" do
      text = "Hello, TTS!"
      config = %{voice: "nova", provider: :openai, format: :mp3}
      key = CacheKeyMock.generate_key(text, config)

      audio_data = <<1, 2, 3, 4, 5>>
      metadata = %{text: text, config: config, duration_ms: 500}

      assert :miss = CacheKeyMock.get(key)
      assert :ok = CacheKeyMock.put(key, audio_data, metadata)
      assert {:ok, ^audio_data, ^metadata} = CacheKeyMock.get(key)
    end
  end

  describe "full cache implementation test" do
    defmodule FullMockCache do
      @moduledoc """
      A complete mock TTS cache that demonstrates all expected behaviors.
      This serves as a reference implementation for the behaviour contract.
      Uses ETS for actual storage in tests.
      """
      @behaviour Parrot.TTS.Cache

      @table_name :full_mock_cache_test

      def init do
        if :ets.whereis(@table_name) == :undefined do
          :ets.new(@table_name, [:set, :public, :named_table])
        end
        :ok
      end

      def cleanup do
        if :ets.whereis(@table_name) != :undefined do
          :ets.delete(@table_name)
        end
        :ok
      end

      @impl true
      def get(key) when is_binary(key) do
        case :ets.lookup(@table_name, key) do
          [{^key, audio_data, metadata}] ->
            {:ok, audio_data, metadata}

          [] ->
            :miss
        end
      end

      @impl true
      def put(key, audio_data, metadata)
          when is_binary(key) and is_binary(audio_data) and is_map(metadata) do
        true = :ets.insert(@table_name, {key, audio_data, metadata})
        :ok
      rescue
        ArgumentError -> {:error, :table_not_found}
      end

      @impl true
      def delete(key) when is_binary(key) do
        :ets.delete(@table_name, key)
        :ok
      rescue
        ArgumentError -> :ok
      end

      @impl true
      def clear do
        :ets.delete_all_objects(@table_name)
        :ok
      rescue
        ArgumentError -> :ok
      end
    end

    setup do
      FullMockCache.init()
      on_exit(fn -> FullMockCache.cleanup() end)
      :ok
    end

    test "implements all required callbacks" do
      callbacks = FullMockCache.__info__(:functions)

      assert {:get, 1} in callbacks
      assert {:put, 3} in callbacks
      assert {:delete, 1} in callbacks
      assert {:clear, 0} in callbacks
    end

    test "full round-trip: put and get" do
      key = "round_trip_key"
      audio_data = <<0x52, 0x49, 0x46, 0x46, 0x24, 0x00>>
      metadata = %{
        format: :wav,
        provider: :openai,
        voice: "alloy",
        duration_ms: 1500,
        created_at: DateTime.utc_now()
      }

      # Initially miss
      assert :miss = FullMockCache.get(key)

      # Put
      assert :ok = FullMockCache.put(key, audio_data, metadata)

      # Get should return stored data
      assert {:ok, retrieved_audio, retrieved_meta} = FullMockCache.get(key)
      assert retrieved_audio == audio_data
      assert retrieved_meta.format == :wav
      assert retrieved_meta.provider == :openai
    end

    test "handles binary audio data of various sizes" do
      small = <<1, 2, 3>>
      medium = :crypto.strong_rand_bytes(10_000)
      large = :crypto.strong_rand_bytes(100_000)

      for {label, audio} <- [{"small", small}, {"medium", medium}, {"large", large}] do
        key = "size_test_#{label}"
        metadata = %{size_bytes: byte_size(audio)}

        assert :ok = FullMockCache.put(key, audio, metadata)
        assert {:ok, retrieved, _} = FullMockCache.get(key)
        assert retrieved == audio
      end
    end

    test "delete removes entry and subsequent get returns miss" do
      key = "delete_test"
      audio = <<1, 2, 3>>
      metadata = %{}

      assert :ok = FullMockCache.put(key, audio, metadata)
      assert {:ok, _, _} = FullMockCache.get(key)

      assert :ok = FullMockCache.delete(key)
      assert :miss = FullMockCache.get(key)
    end

    test "clear removes all entries" do
      for i <- 1..5 do
        key = "clear_test_#{i}"
        assert :ok = FullMockCache.put(key, <<i>>, %{index: i})
      end

      # Verify all stored
      for i <- 1..5 do
        assert {:ok, _, _} = FullMockCache.get("clear_test_#{i}")
      end

      # Clear
      assert :ok = FullMockCache.clear()

      # All should be miss
      for i <- 1..5 do
        assert :miss = FullMockCache.get("clear_test_#{i}")
      end
    end

    test "put overwrites existing key" do
      key = "overwrite_test"
      audio1 = <<1, 2, 3>>
      meta1 = %{version: 1}
      audio2 = <<4, 5, 6, 7, 8>>
      meta2 = %{version: 2}

      assert :ok = FullMockCache.put(key, audio1, meta1)
      assert {:ok, ^audio1, %{version: 1}} = FullMockCache.get(key)

      assert :ok = FullMockCache.put(key, audio2, meta2)
      assert {:ok, ^audio2, %{version: 2}} = FullMockCache.get(key)
    end
  end
end
