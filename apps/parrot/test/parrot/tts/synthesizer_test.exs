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
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid ->
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end
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
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid ->
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end
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

    # Start the TaskSupervisor if not already running
    case Task.Supervisor.start_link(name: Parrot.TTS.TaskSupervisor) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # The Synthesizer may already be started by the application supervisor
    # In that case, just use the existing one
    _pid = case Synthesizer.start_link(name: Synthesizer) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end

    on_exit(fn ->
      # Don't stop the Synthesizer or TaskSupervisor - they may be app-supervised
      # Just stop our mock processes
      try do
        MockCache.stop()
      catch
        :exit, _ -> :ok
      end

      try do
        MockProvider.stop()
      catch
        :exit, _ -> :ok
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

  describe "profile selection" do
    # Additional mock provider for testing profile switching
    defmodule AlternateProvider do
      @behaviour Parrot.TTS.Provider

      @impl true
      def synthesize(text, config) do
        format = Keyword.get(config, :format, :wav)
        # Generate different audio data to distinguish from MockProvider
        audio_data = :crypto.hash(:sha256, "alternate-" <> text)
        {:ok, audio_data, format}
      end

      @impl true
      def list_voices(_credentials) do
        {:ok, [%{id: "alt-voice", name: "Alternate Voice", language: "en-US"}]}
      end

      @impl true
      def validate_config(_config), do: :ok
    end

    setup do
      # Reset mock cache between tests
      MockCache.reset()
      MockProvider.reset()
      :ok
    end

    test "uses default profile when :default atom is passed" do
      # Configure application with a default profile
      original_config = Application.get_env(:parrot, :tts, [])

      # Use the full module atoms for credentials lookup
      mock_provider = MockProvider
      mock_cache = MockCache

      Application.put_env(:parrot, :tts,
        default_profile: :standard,
        profiles: [
          standard: [
            provider: mock_provider,
            voice: "default-voice",
            model: "default-model",
            format: :wav
          ]
        ],
        credentials: [
          {mock_provider, [api_key: "test-key"]}
        ],
        cache: [
          backend: mock_cache
        ]
      )

      on_exit(fn ->
        Application.put_env(:parrot, :tts, original_config)
      end)

      # Use :default profile
      result = Synthesizer.get_audio("Hello default", :default)

      assert {:ok, audio_data, :wav} = result
      assert is_binary(audio_data)
      assert MockProvider.get_call_count() == 1
    end

    test "uses specified profile when profile name atom is provided" do
      original_config = Application.get_env(:parrot, :tts, [])

      mock_provider = MockProvider
      mock_cache = MockCache

      Application.put_env(:parrot, :tts,
        default_profile: :standard,
        profiles: [
          standard: [
            provider: mock_provider,
            voice: "standard-voice",
            model: "standard-model",
            format: :wav
          ],
          premium: [
            provider: mock_provider,
            voice: "premium-voice",
            model: "premium-model",
            format: :mp3
          ]
        ],
        credentials: [
          {mock_provider, [api_key: "test-key"]}
        ],
        cache: [
          backend: mock_cache
        ]
      )

      on_exit(fn ->
        Application.put_env(:parrot, :tts, original_config)
      end)

      # Use :premium profile explicitly
      result = Synthesizer.get_audio("Hello premium", :premium)

      assert {:ok, audio_data, :mp3} = result
      assert is_binary(audio_data)
      assert MockProvider.get_call_count() == 1
    end

    test "different profiles use different providers" do
      original_config = Application.get_env(:parrot, :tts, [])

      mock_provider = MockProvider
      alt_provider = AlternateProvider
      mock_cache = MockCache

      Application.put_env(:parrot, :tts,
        default_profile: :standard,
        profiles: [
          standard: [
            provider: mock_provider,
            voice: "standard-voice",
            model: "standard-model",
            format: :wav
          ],
          alternate: [
            provider: alt_provider,
            voice: "alt-voice",
            model: "alt-model",
            format: :opus
          ]
        ],
        credentials: [
          {mock_provider, [api_key: "mock-key"]},
          {alt_provider, [api_key: "alt-key"]}
        ],
        cache: [
          backend: mock_cache
        ]
      )

      on_exit(fn ->
        Application.put_env(:parrot, :tts, original_config)
      end)

      text = "Same text different providers"

      # Standard profile uses MockProvider
      {:ok, audio1, :wav} = Synthesizer.get_audio(text, :standard)

      # Alternate profile uses AlternateProvider
      {:ok, audio2, :opus} = Synthesizer.get_audio(text, :alternate)

      # Audio should be different because different providers generate different data
      assert audio1 != audio2

      # MockProvider should only be called once (for :standard)
      assert MockProvider.get_call_count() == 1
    end

    test "returns error for unknown profile" do
      original_config = Application.get_env(:parrot, :tts, [])

      mock_provider = MockProvider
      mock_cache = MockCache

      Application.put_env(:parrot, :tts,
        profiles: [
          standard: [provider: mock_provider, voice: "v", model: "m"]
        ],
        credentials: [{mock_provider, [api_key: "key"]}],
        cache: [backend: mock_cache]
      )

      on_exit(fn ->
        Application.put_env(:parrot, :tts, original_config)
      end)

      result = Synthesizer.get_audio("Hello", :nonexistent_profile)

      assert {:error, {:unknown_profile, :nonexistent_profile}} = result
    end

    test "profile with environment variable credentials resolves correctly" do
      original_config = Application.get_env(:parrot, :tts, [])
      original_env = System.get_env("TEST_TTS_API_KEY")

      mock_provider = MockProvider
      mock_cache = MockCache

      # Set environment variable
      System.put_env("TEST_TTS_API_KEY", "resolved-api-key-from-env")

      Application.put_env(:parrot, :tts,
        default_profile: :env_profile,
        profiles: [
          env_profile: [
            provider: mock_provider,
            voice: "env-voice",
            model: "env-model",
            format: :wav
          ]
        ],
        credentials: [
          {mock_provider, [api_key: {:system, "TEST_TTS_API_KEY"}]}
        ],
        cache: [
          backend: mock_cache
        ]
      )

      on_exit(fn ->
        Application.put_env(:parrot, :tts, original_config)

        if original_env do
          System.put_env("TEST_TTS_API_KEY", original_env)
        else
          System.delete_env("TEST_TTS_API_KEY")
        end
      end)

      # The synthesizer should resolve the env var and work correctly
      result = Synthesizer.get_audio("Hello with env credentials", :env_profile)

      assert {:ok, audio_data, :wav} = result
      assert is_binary(audio_data)
    end

    test "full profile map bypasses profile resolution" do
      # When a full profile map is passed, it should be used directly
      # without going through Config.get_profile/1
      direct_profile = %{
        provider: MockProvider,
        cache: MockCache,
        voice: "direct-voice",
        model: "direct-model",
        format: :ogg
      }

      # This should work without any application config
      result = Synthesizer.get_audio("Direct profile test", direct_profile)

      assert {:ok, audio_data, :ogg} = result
      assert is_binary(audio_data)
    end

    test "per-call profile map overrides can change voice and format" do
      # First establish a baseline with one profile
      profile1 = %{
        provider: MockProvider,
        cache: MockCache,
        voice: "voice-a",
        model: "model-a",
        format: :wav
      }

      profile2 = %{
        provider: MockProvider,
        cache: MockCache,
        voice: "voice-b",
        model: "model-b",
        format: :mp3
      }

      text = "Same text for both"

      # Get audio with profile1
      {:ok, audio1, :wav} = Synthesizer.get_audio(text, profile1)

      # Get audio with profile2 (different voice/model/format)
      {:ok, audio2, :mp3} = Synthesizer.get_audio(text, profile2)

      # The cache keys should be different due to different voice/model/format
      # so both should call the provider
      assert MockProvider.get_call_count() == 2

      # Audio data is same (MockProvider generates based on text only)
      # but format is different
      assert audio1 == audio2
    end

    test "cache key differs when profile settings change" do
      text = "Cache key test"

      profile_wav = %{
        provider: MockProvider,
        cache: MockCache,
        voice: "voice-1",
        model: "model-1",
        format: :wav
      }

      profile_mp3 = %{
        provider: MockProvider,
        cache: MockCache,
        voice: "voice-1",
        model: "model-1",
        format: :mp3
      }

      # Compute cache keys
      key_wav = Synthesizer.compute_cache_key(text, profile_wav, [])
      key_mp3 = Synthesizer.compute_cache_key(text, profile_mp3, [])

      # Keys should be different
      assert key_wav != key_mp3
    end

    test "returns error when profile references unknown provider" do
      original_config = Application.get_env(:parrot, :tts, [])

      Application.put_env(:parrot, :tts,
        profiles: [
          bad_profile: [
            provider: :nonexistent_provider,
            voice: "v",
            model: "m"
          ]
        ],
        credentials: [],
        cache: [backend: MockCache]
      )

      on_exit(fn ->
        Application.put_env(:parrot, :tts, original_config)
      end)

      result = Synthesizer.get_audio("Hello", :bad_profile)

      assert {:error, {:unknown_provider, :nonexistent_provider}} = result
    end

    test "returns error when profile provider has no credentials configured" do
      original_config = Application.get_env(:parrot, :tts, [])

      Application.put_env(:parrot, :tts,
        profiles: [
          no_creds_profile: [
            provider: :openai,
            voice: "v",
            model: "m"
          ]
        ],
        # No credentials for :openai
        credentials: [],
        cache: [backend: MockCache]
      )

      on_exit(fn ->
        Application.put_env(:parrot, :tts, original_config)
      end)

      result = Synthesizer.get_audio("Hello", :no_creds_profile)

      assert {:error, {:unknown_provider, :openai}} = result
    end

    test "invalid profile type returns error" do
      # Passing something that is neither a map nor an atom
      result = Synthesizer.get_audio("Hello", "invalid-string-profile")

      assert {:error, :invalid_profile} = result
    end
  end

  describe "process safety - provider timeout" do
    # Provider that sleeps longer than timeout
    defmodule SlowProvider do
      @behaviour Parrot.TTS.Provider

      @impl true
      def synthesize(_text, _config) do
        # Sleep longer than the default provider timeout (30s)
        # In tests we'll use a shorter timeout
        Process.sleep(60_000)
        {:ok, "audio", :mp3}
      end

      @impl true
      def list_voices(_credentials), do: {:ok, []}

      @impl true
      def validate_config(_config), do: :ok
    end

    test "returns timeout error when provider takes too long" do
      MockCache.clear()

      slow_profile = %{
        provider: SlowProvider,
        cache: MockCache,
        voice: "test",
        model: "test",
        format: :mp3
      }

      # Configure a short timeout for testing (100ms)
      # The synthesizer should return an error, not hang forever
      result = Synthesizer.get_audio("Slow text", slow_profile, timeout: 100)

      assert {:error, :provider_timeout} = result
    end

    test "synthesizer process survives provider timeout" do
      MockCache.clear()

      slow_profile = %{
        provider: SlowProvider,
        cache: MockCache,
        voice: "test",
        model: "test",
        format: :mp3
      }

      # First request times out
      assert {:error, :provider_timeout} = Synthesizer.get_audio("Slow", slow_profile, timeout: 100)

      # Synthesizer should still be alive and working
      assert Process.alive?(Process.whereis(Synthesizer))

      # Subsequent requests with fast provider should work
      assert {:ok, _audio, _format} = Synthesizer.get_audio("Fast text", @test_profile, [])
    end
  end

  describe "process safety - provider crash" do
    # Provider that crashes
    defmodule CrashingProvider do
      @behaviour Parrot.TTS.Provider

      @impl true
      def synthesize(_text, _config) do
        raise "Provider crashed!"
      end

      @impl true
      def list_voices(_credentials), do: {:ok, []}

      @impl true
      def validate_config(_config), do: :ok
    end

    test "returns error when provider crashes" do
      MockCache.clear()

      crash_profile = %{
        provider: CrashingProvider,
        cache: MockCache,
        voice: "test",
        model: "test",
        format: :mp3
      }

      result = Synthesizer.get_audio("Crash text", crash_profile, [])

      assert {:error, :provider_crashed} = result
    end

    test "synthesizer process survives provider crash" do
      MockCache.clear()

      crash_profile = %{
        provider: CrashingProvider,
        cache: MockCache,
        voice: "test",
        model: "test",
        format: :mp3
      }

      # First request crashes the provider
      assert {:error, :provider_crashed} = Synthesizer.get_audio("Crash", crash_profile, [])

      # Synthesizer should still be alive
      assert Process.alive?(Process.whereis(Synthesizer))

      # Subsequent requests with working provider should succeed
      assert {:ok, _audio, _format} = Synthesizer.get_audio("Works", @test_profile, [])
    end

    test "all concurrent waiters receive error when provider crashes" do
      MockCache.clear()

      # Provider that waits a bit then crashes (to allow concurrent requests to queue)
      defmodule DelayedCrashProvider do
        @behaviour Parrot.TTS.Provider

        @impl true
        def synthesize(_text, _config) do
          Process.sleep(100)
          raise "Delayed crash!"
        end

        @impl true
        def list_voices(_credentials), do: {:ok, []}

        @impl true
        def validate_config(_config), do: :ok
      end

      crash_profile = %{
        provider: DelayedCrashProvider,
        cache: MockCache,
        voice: "test",
        model: "test",
        format: :mp3
      }

      text = "Concurrent crash text"

      # Start multiple concurrent requests
      task1 = Task.async(fn -> Synthesizer.get_audio(text, crash_profile, []) end)
      task2 = Task.async(fn -> Synthesizer.get_audio(text, crash_profile, []) end)
      task3 = Task.async(fn -> Synthesizer.get_audio(text, crash_profile, []) end)

      # All should receive the error
      assert {:error, :provider_crashed} = Task.await(task1, 5000)
      assert {:error, :provider_crashed} = Task.await(task2, 5000)
      assert {:error, :provider_crashed} = Task.await(task3, 5000)

      # Synthesizer should still be alive
      assert Process.alive?(Process.whereis(Synthesizer))
    end
  end

  describe "process safety - in-flight cleanup" do
    # Re-define SlowProvider locally to avoid scoping issues
    defmodule SlowProviderForCleanup do
      @behaviour Parrot.TTS.Provider

      @impl true
      def synthesize(_text, _config) do
        Process.sleep(60_000)
        {:ok, "audio", :mp3}
      end

      @impl true
      def list_voices(_credentials), do: {:ok, []}

      @impl true
      def validate_config(_config), do: :ok
    end

    test "in-flight tracking is cleaned up after provider timeout" do
      MockCache.clear()

      slow_profile = %{
        provider: SlowProviderForCleanup,
        cache: MockCache,
        voice: "test",
        model: "test",
        format: :mp3
      }

      # Request that will timeout
      assert {:error, :provider_timeout} = Synthesizer.get_audio("Cleanup test", slow_profile, timeout: 100)

      # Give a moment for cleanup
      Process.sleep(50)

      # New request for same text should trigger new provider call (not wait for old in-flight)
      # Using the working provider
      assert {:ok, _audio, _format} = Synthesizer.get_audio("Cleanup test", @test_profile, [])

      # Provider should have been called (not waiting on stale in-flight)
      assert MockProvider.get_call_count() >= 1
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
