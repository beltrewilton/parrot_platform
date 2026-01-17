defmodule Parrot.TTS.SynthesizerTest do
  use ExUnit.Case, async: false

  alias Parrot.TTS.Synthesizer

  # Mock Cache implementation for testing
  defmodule MockCache do
    @behaviour Parrot.TTS.Cache

    def start_link do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def stop do
      if Process.whereis(__MODULE__) do
        Agent.stop(__MODULE__)
      end
    end

    def reset do
      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, fn _ -> %{} end)
      end
    end

    @impl true
    def get(key) do
      if Process.whereis(__MODULE__) do
        Agent.get(__MODULE__, fn cache ->
          case Map.get(cache, key) do
            nil -> :miss
            {audio_data, metadata} -> {:ok, audio_data, metadata}
          end
        end)
      else
        :miss
      end
    end

    @impl true
    def put(key, audio_data, metadata) do
      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, fn cache ->
          Map.put(cache, key, {audio_data, metadata})
        end)
        :ok
      else
        {:error, :cache_not_started}
      end
    end

    @impl true
    def delete(key) do
      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, fn cache ->
          Map.delete(cache, key)
        end)
        :ok
      else
        {:error, :cache_not_started}
      end
    end

    @impl true
    def clear do
      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, fn _ -> %{} end)
        :ok
      else
        {:error, :cache_not_started}
      end
    end
  end

  # Mock Provider implementation for testing
  defmodule MockProvider do
    @behaviour Parrot.TTS.Provider

    def start_link do
      Agent.start_link(fn -> %{call_count: 0, delay_ms: 0} end, name: __MODULE__)
    end

    def stop do
      if Process.whereis(__MODULE__) do
        Agent.stop(__MODULE__)
      end
    end

    def set_delay(ms) do
      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, fn state -> Map.put(state, :delay_ms, ms) end)
      end
    end

    def get_call_count do
      if Process.whereis(__MODULE__) do
        Agent.get(__MODULE__, fn state -> Map.get(state, :call_count, 0) end)
      else
        0
      end
    end

    def reset do
      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, fn _ -> %{call_count: 0, delay_ms: 0} end)
      end
    end

    @impl true
    def synthesize(text, config) do
      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, fn state ->
          Map.update(state, :call_count, 1, &(&1 + 1))
        end)

        delay = Agent.get(__MODULE__, fn state -> Map.get(state, :delay_ms, 0) end)
        if delay > 0, do: Process.sleep(delay)
      end

      format = Keyword.get(config, :format, :wav)
      # Generate deterministic audio data based on text
      audio_data = :crypto.hash(:md5, text)
      {:ok, audio_data, format}
    end

    @impl true
    def list_voices(_credentials) do
      {:ok, [
        %{id: "voice1", name: "Test Voice 1", language: "en-US"}
      ]}
    end

    @impl true
    def validate_config(_config) do
      :ok
    end
  end

  # Mock Profile for testing
  @test_profile %{
    provider: MockProvider,
    voice: "test_voice",
    model: "test_model",
    format: :wav,
    cache: MockCache
  }

  setup do
    # Start mock cache and provider
    {:ok, _} = MockCache.start_link()
    {:ok, _} = MockProvider.start_link()

    on_exit(fn ->
      MockCache.stop()
      MockProvider.stop()
      # Stop Synthesizer if it was started
      if Process.whereis(Synthesizer) do
        GenServer.stop(Synthesizer)
      end
    end)

    MockCache.reset()
    MockProvider.reset()

    :ok
  end

  describe "Synthesizer.get_audio/3 - cache hit" do
    test "returns cached audio without calling provider on cache hit" do
      text = "Hello world"

      # Pre-populate cache
      cache_key = compute_cache_key(text, @test_profile, [])
      cached_audio = <<1, 2, 3, 4>>
      cached_metadata = %{format: :wav, cached_at: DateTime.utc_now()}
      MockCache.put(cache_key, cached_audio, cached_metadata)

      # Get audio (should hit cache)
      assert {:ok, audio_data, metadata} = Synthesizer.get_audio(text, @test_profile, [])

      # Verify it returned cached data
      assert audio_data == cached_audio
      assert metadata == cached_metadata

      # Verify provider was NOT called
      assert MockProvider.get_call_count() == 0
    end

    test "returns cached audio for multiple requests with same text and config" do
      text = "Test message"

      # Pre-populate cache
      cache_key = compute_cache_key(text, @test_profile, [])
      cached_audio = <<5, 6, 7, 8>>
      cached_metadata = %{format: :wav}
      MockCache.put(cache_key, cached_audio, cached_metadata)

      # Make multiple requests
      assert {:ok, audio1, _} = Synthesizer.get_audio(text, @test_profile, [])
      assert {:ok, audio2, _} = Synthesizer.get_audio(text, @test_profile, [])
      assert {:ok, audio3, _} = Synthesizer.get_audio(text, @test_profile, [])

      # All should return same cached data
      assert audio1 == cached_audio
      assert audio2 == cached_audio
      assert audio3 == cached_audio

      # Provider should not be called
      assert MockProvider.get_call_count() == 0
    end
  end

  describe "Synthesizer.get_audio/3 - cache miss" do
    test "calls provider on cache miss" do
      text = "New phrase"

      # Ensure cache is empty
      MockCache.clear()

      # Get audio (should miss cache and call provider)
      assert {:ok, audio_data, format} = Synthesizer.get_audio(text, @test_profile, [])

      # Verify provider was called
      assert MockProvider.get_call_count() == 1

      # Verify we got audio data
      assert is_binary(audio_data)
      assert format == :wav
    end

    test "calls provider only once for cache miss" do
      text = "Another phrase"

      # Ensure cache is empty
      MockCache.clear()

      # Get audio
      assert {:ok, _audio_data, _format} = Synthesizer.get_audio(text, @test_profile, [])

      # Verify provider was called exactly once
      assert MockProvider.get_call_count() == 1
    end

    test "provider receives correct text and config" do
      text = "Custom message"
      custom_profile = %{@test_profile | voice: "custom_voice", format: :mp3}

      MockCache.clear()

      # Get audio with custom config
      assert {:ok, audio_data, _format} = Synthesizer.get_audio(text, custom_profile, [])

      # Verify provider was called
      assert MockProvider.get_call_count() == 1

      # Verify audio was generated (deterministic based on text)
      expected_audio = :crypto.hash(:md5, text)
      assert audio_data == expected_audio
    end
  end

  describe "Synthesizer.get_audio/3 - caching behavior" do
    test "caches result after provider call on cache miss" do
      text = "Cache this phrase"

      # Ensure cache is empty
      MockCache.clear()

      # First request - should call provider and cache result
      assert {:ok, audio_data, format} = Synthesizer.get_audio(text, @test_profile, [])
      assert MockProvider.get_call_count() == 1

      # Verify result was cached
      cache_key = compute_cache_key(text, @test_profile, [])
      assert {:ok, cached_audio, cached_metadata} = MockCache.get(cache_key)
      assert cached_audio == audio_data
      assert is_map(cached_metadata)
      assert Map.has_key?(cached_metadata, :format)
      assert cached_metadata.format == format
    end

    test "second request uses cached result instead of calling provider again" do
      text = "Cache and reuse"

      MockCache.clear()

      # First request - calls provider
      assert {:ok, audio1, _} = Synthesizer.get_audio(text, @test_profile, [])
      assert MockProvider.get_call_count() == 1

      # Second request - should use cache
      assert {:ok, audio2, _} = Synthesizer.get_audio(text, @test_profile, [])
      assert MockProvider.get_call_count() == 1  # Still 1, not 2

      # Should return same audio
      assert audio1 == audio2
    end

    test "cached metadata includes format and timestamp" do
      text = "Metadata test"

      MockCache.clear()

      # Get audio
      assert {:ok, _audio_data, _format} = Synthesizer.get_audio(text, @test_profile, [])

      # Check cached metadata
      cache_key = compute_cache_key(text, @test_profile, [])
      assert {:ok, _cached_audio, metadata} = MockCache.get(cache_key)

      assert is_map(metadata)
      assert Map.has_key?(metadata, :format)
      assert Map.has_key?(metadata, :cached_at)
      assert %DateTime{} = metadata.cached_at
    end
  end

  describe "Synthesizer cache key generation" do
    test "cache key is deterministic for same text and config" do
      text = "Same text"

      # Get cache key multiple times with same inputs
      key1 = compute_cache_key(text, @test_profile, [])
      key2 = compute_cache_key(text, @test_profile, [])
      key3 = compute_cache_key(text, @test_profile, [])

      # All keys should be identical
      assert key1 == key2
      assert key2 == key3
    end

    test "cache key differs for different text" do
      text1 = "First phrase"
      text2 = "Second phrase"

      key1 = compute_cache_key(text1, @test_profile, [])
      key2 = compute_cache_key(text2, @test_profile, [])

      # Keys should be different
      assert key1 != key2
    end

    test "cache key differs for different provider" do
      text = "Same text"

      profile1 = @test_profile
      profile2 = %{@test_profile | provider: AnotherProvider}

      key1 = compute_cache_key(text, profile1, [])
      key2 = compute_cache_key(text, profile2, [])

      # Keys should be different
      assert key1 != key2
    end

    test "cache key differs for different voice" do
      text = "Same text"

      profile1 = @test_profile
      profile2 = %{@test_profile | voice: "different_voice"}

      key1 = compute_cache_key(text, profile1, [])
      key2 = compute_cache_key(text, profile2, [])

      # Keys should be different
      assert key1 != key2
    end

    test "cache key differs for different model" do
      text = "Same text"

      profile1 = @test_profile
      profile2 = %{@test_profile | model: "different_model"}

      key1 = compute_cache_key(text, profile1, [])
      key2 = compute_cache_key(text, profile2, [])

      # Keys should be different
      assert key1 != key2
    end

    test "cache key differs for different format" do
      text = "Same text"

      profile1 = @test_profile
      profile2 = %{@test_profile | format: :mp3}

      key1 = compute_cache_key(text, profile1, [])
      key2 = compute_cache_key(text, profile2, [])

      # Keys should be different
      assert key1 != key2
    end

    test "cache key is a SHA256 hash (64 hex characters)" do
      text = "Test"

      key = compute_cache_key(text, @test_profile, [])

      # SHA256 in hex is 64 characters
      assert is_binary(key)
      assert String.length(key) == 64
      assert String.match?(key, ~r/^[0-9a-f]{64}$/)
    end
  end

  describe "Synthesizer concurrent request deduplication" do
    test "concurrent requests for same uncached phrase wait for first" do
      text = "Concurrent phrase"

      MockCache.clear()

      # Set provider to have a delay so we can test concurrent behavior
      MockProvider.set_delay(100)

      # Start multiple concurrent requests
      task1 = Task.async(fn -> Synthesizer.get_audio(text, @test_profile, []) end)
      task2 = Task.async(fn -> Synthesizer.get_audio(text, @test_profile, []) end)
      task3 = Task.async(fn -> Synthesizer.get_audio(text, @test_profile, []) end)

      # Wait for all to complete
      {:ok, audio1, _} = Task.await(task1)
      {:ok, audio2, _} = Task.await(task2)
      {:ok, audio3, _} = Task.await(task3)

      # All should get the same audio
      assert audio1 == audio2
      assert audio2 == audio3

      # Provider should only be called ONCE despite 3 concurrent requests
      assert MockProvider.get_call_count() == 1
    end

    test "concurrent requests for different phrases call provider separately" do
      MockCache.clear()
      MockProvider.set_delay(50)

      # Start concurrent requests for different text
      task1 = Task.async(fn -> Synthesizer.get_audio("First phrase", @test_profile, []) end)
      task2 = Task.async(fn -> Synthesizer.get_audio("Second phrase", @test_profile, []) end)
      task3 = Task.async(fn -> Synthesizer.get_audio("Third phrase", @test_profile, []) end)

      # Wait for all
      {:ok, audio1, _} = Task.await(task1)
      {:ok, audio2, _} = Task.await(task2)
      {:ok, audio3, _} = Task.await(task3)

      # All should get different audio (since text is different)
      assert audio1 != audio2
      assert audio2 != audio3
      assert audio1 != audio3

      # Provider should be called 3 times (one for each unique phrase)
      assert MockProvider.get_call_count() == 3
    end

    test "requests after caching do not trigger new provider calls" do
      text = "Pre-cached phrase"

      MockCache.clear()
      MockProvider.set_delay(50)

      # First request - will call provider and cache
      {:ok, audio1, _} = Synthesizer.get_audio(text, @test_profile, [])
      initial_call_count = MockProvider.get_call_count()
      assert initial_call_count == 1

      # Concurrent requests after caching - should all hit cache
      task1 = Task.async(fn -> Synthesizer.get_audio(text, @test_profile, []) end)
      task2 = Task.async(fn -> Synthesizer.get_audio(text, @test_profile, []) end)
      task3 = Task.async(fn -> Synthesizer.get_audio(text, @test_profile, []) end)

      {:ok, audio2, _} = Task.await(task1)
      {:ok, audio3, _} = Task.await(task2)
      {:ok, audio4, _} = Task.await(task3)

      # All should get same cached audio
      assert audio1 == audio2
      assert audio2 == audio3
      assert audio3 == audio4

      # Provider should still only have been called once
      assert MockProvider.get_call_count() == initial_call_count
    end
  end

  # Helper function to compute cache key
  # This mirrors what Synthesizer.compute_cache_key/3 should do
  defp compute_cache_key(text, profile, _opts) do
    # Cache key = SHA256 of JSON(text + provider + voice + model + format)
    cache_input = %{
      text: text,
      provider: inspect(profile.provider),
      voice: profile.voice,
      model: profile.model,
      format: profile.format
    }

    json = Jason.encode!(cache_input, sort_keys: true)
    :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
  end
end
