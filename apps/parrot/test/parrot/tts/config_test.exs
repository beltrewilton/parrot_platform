defmodule Parrot.TTS.ConfigTest do
  use ExUnit.Case, async: true

  alias Parrot.TTS.Config

  describe "get_profile/1" do
    test "returns configured profile when it exists" do
      # Use test config set in config/test.exs
      Application.put_env(:parrot, :tts,
        default_profile: :standard,
        profiles: [
          standard: [
            provider: :openai,
            voice: "alloy",
            model: "tts-1"
          ],
          premium: [
            provider: :elevenlabs,
            voice: "rachel",
            model: "eleven_multilingual_v2"
          ]
        ]
      )

      on_exit(fn -> Application.delete_env(:parrot, :tts) end)

      assert {:ok, profile} = Config.get_profile(:standard)
      assert profile[:provider] == :openai
      assert profile[:voice] == "alloy"
      assert profile[:model] == "tts-1"
    end

    test "returns default profile when :default is requested" do
      Application.put_env(:parrot, :tts,
        default_profile: :standard,
        profiles: [
          standard: [
            provider: :openai,
            voice: "alloy",
            model: "tts-1"
          ]
        ]
      )

      on_exit(fn -> Application.delete_env(:parrot, :tts) end)

      assert {:ok, profile} = Config.get_profile(:default)
      assert profile[:provider] == :openai
      assert profile[:voice] == "alloy"
    end

    test "returns default profile when no name specified" do
      Application.put_env(:parrot, :tts,
        default_profile: :premium,
        profiles: [
          standard: [
            provider: :openai,
            voice: "alloy",
            model: "tts-1"
          ],
          premium: [
            provider: :elevenlabs,
            voice: "rachel",
            model: "eleven_multilingual_v2"
          ]
        ]
      )

      on_exit(fn -> Application.delete_env(:parrot, :tts) end)

      assert {:ok, profile} = Config.get_profile()
      assert profile[:provider] == :elevenlabs
      assert profile[:voice] == "rachel"
    end

    test "returns error for unknown profile" do
      Application.put_env(:parrot, :tts,
        default_profile: :standard,
        profiles: [
          standard: [provider: :openai, voice: "alloy", model: "tts-1"]
        ]
      )

      on_exit(fn -> Application.delete_env(:parrot, :tts) end)

      assert {:error, {:unknown_profile, :nonexistent}} = Config.get_profile(:nonexistent)
    end

    test "returns fallback defaults when no config exists" do
      Application.delete_env(:parrot, :tts)

      assert {:ok, profile} = Config.get_profile()
      assert profile[:provider] == :openai
      assert profile[:voice] == "alloy"
      assert profile[:model] == "tts-1"
    end

    test "returns fallback defaults when config is empty" do
      Application.put_env(:parrot, :tts, [])

      on_exit(fn -> Application.delete_env(:parrot, :tts) end)

      assert {:ok, profile} = Config.get_profile()
      assert profile[:provider] == :openai
      assert profile[:voice] == "alloy"
      assert profile[:model] == "tts-1"
    end
  end

  describe "get_credentials/1" do
    test "returns credentials for configured provider" do
      Application.put_env(:parrot, :tts,
        credentials: [
          openai: [api_key: "sk-test-key-123"]
        ]
      )

      on_exit(fn -> Application.delete_env(:parrot, :tts) end)

      assert {:ok, credentials} = Config.get_credentials(:openai)
      assert credentials[:api_key] == "sk-test-key-123"
    end

    test "resolves {:system, VAR} tuples to environment variables" do
      System.put_env("TEST_OPENAI_API_KEY", "sk-from-env-var")

      Application.put_env(:parrot, :tts,
        credentials: [
          openai: [api_key: {:system, "TEST_OPENAI_API_KEY"}]
        ]
      )

      on_exit(fn ->
        Application.delete_env(:parrot, :tts)
        System.delete_env("TEST_OPENAI_API_KEY")
      end)

      assert {:ok, credentials} = Config.get_credentials(:openai)
      assert credentials[:api_key] == "sk-from-env-var"
    end

    test "returns nil for unset environment variables" do
      # Ensure env var doesn't exist
      System.delete_env("NONEXISTENT_TTS_KEY")

      Application.put_env(:parrot, :tts,
        credentials: [
          openai: [api_key: {:system, "NONEXISTENT_TTS_KEY"}]
        ]
      )

      on_exit(fn -> Application.delete_env(:parrot, :tts) end)

      assert {:ok, credentials} = Config.get_credentials(:openai)
      assert credentials[:api_key] == nil
    end

    test "resolves multiple {:system, VAR} tuples in credentials" do
      System.put_env("TEST_API_KEY", "my-api-key")
      System.put_env("TEST_API_SECRET", "my-api-secret")

      Application.put_env(:parrot, :tts,
        credentials: [
          elevenlabs: [
            api_key: {:system, "TEST_API_KEY"},
            api_secret: {:system, "TEST_API_SECRET"},
            region: "us-west"
          ]
        ]
      )

      on_exit(fn ->
        Application.delete_env(:parrot, :tts)
        System.delete_env("TEST_API_KEY")
        System.delete_env("TEST_API_SECRET")
      end)

      assert {:ok, credentials} = Config.get_credentials(:elevenlabs)
      assert credentials[:api_key] == "my-api-key"
      assert credentials[:api_secret] == "my-api-secret"
      assert credentials[:region] == "us-west"
    end

    test "returns error for unknown provider" do
      Application.put_env(:parrot, :tts,
        credentials: [
          openai: [api_key: "test"]
        ]
      )

      on_exit(fn -> Application.delete_env(:parrot, :tts) end)

      assert {:error, {:unknown_provider, :unknown_provider}} = Config.get_credentials(:unknown_provider)
    end

    test "returns empty credentials when no credentials configured" do
      Application.put_env(:parrot, :tts,
        profiles: [standard: [provider: :openai, voice: "alloy", model: "tts-1"]]
      )

      on_exit(fn -> Application.delete_env(:parrot, :tts) end)

      assert {:error, {:unknown_provider, :openai}} = Config.get_credentials(:openai)
    end
  end

  describe "get_cache_config/0" do
    test "returns configured cache backend" do
      Application.put_env(:parrot, :tts,
        cache: [
          backend: Parrot.TTS.Cache.ETS,
          max_entries: 10_000
        ]
      )

      on_exit(fn -> Application.delete_env(:parrot, :tts) end)

      assert {:ok, cache_config} = Config.get_cache_config()
      assert cache_config[:backend] == Parrot.TTS.Cache.ETS
      assert cache_config[:max_entries] == 10_000
    end

    test "returns default cache config when not configured" do
      Application.delete_env(:parrot, :tts)

      assert {:ok, cache_config} = Config.get_cache_config()
      assert cache_config[:backend] == Parrot.TTS.Cache.ETS
    end

    test "returns empty config when cache key exists but is empty" do
      Application.put_env(:parrot, :tts, cache: [])

      on_exit(fn -> Application.delete_env(:parrot, :tts) end)

      assert {:ok, cache_config} = Config.get_cache_config()
      # Should still have default backend
      assert cache_config[:backend] == Parrot.TTS.Cache.ETS
    end
  end

  describe "get_provider_module/1" do
    test "maps :openai to Parrot.TTS.Providers.OpenAI" do
      assert {:ok, Parrot.TTS.Providers.OpenAI} = Config.get_provider_module(:openai)
    end

    test "maps :elevenlabs to Parrot.TTS.Providers.ElevenLabs" do
      assert {:ok, Parrot.TTS.Providers.ElevenLabs} = Config.get_provider_module(:elevenlabs)
    end

    test "maps :google to Parrot.TTS.Providers.Google" do
      assert {:ok, Parrot.TTS.Providers.Google} = Config.get_provider_module(:google)
    end

    test "maps :amazon to Parrot.TTS.Providers.Amazon" do
      assert {:ok, Parrot.TTS.Providers.Amazon} = Config.get_provider_module(:amazon)
    end

    test "returns error for unknown provider atom" do
      assert {:error, {:unknown_provider, :nonexistent}} = Config.get_provider_module(:nonexistent)
    end

    test "returns module directly if already a module" do
      assert {:ok, MyCustomProvider} = Config.get_provider_module(MyCustomProvider)
    end
  end

  describe "resolve_env_vars/1" do
    test "resolves {:system, VAR} in nested structures" do
      System.put_env("TEST_NESTED_VAR", "nested-value")

      input = [
        simple: "value",
        env_var: {:system, "TEST_NESTED_VAR"},
        nested: [
          inner_env: {:system, "TEST_NESTED_VAR"},
          inner_static: "static"
        ]
      ]

      on_exit(fn -> System.delete_env("TEST_NESTED_VAR") end)

      resolved = Config.resolve_env_vars(input)

      assert resolved[:simple] == "value"
      assert resolved[:env_var] == "nested-value"
      assert resolved[:nested][:inner_env] == "nested-value"
      assert resolved[:nested][:inner_static] == "static"
    end
  end
end
