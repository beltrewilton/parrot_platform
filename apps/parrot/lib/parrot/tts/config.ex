defmodule Parrot.TTS.Config do
  @moduledoc """
  TTS profile and credential configuration management.

  This module provides functions to retrieve TTS configuration from application config,
  including profile settings, provider credentials, and cache configuration.

  ## Configuration Format

  The TTS configuration is expected to be set in your config files under `:parrot, :tts`:

      config :parrot, :tts,
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
        ],
        credentials: [
          openai: [api_key: {:system, "OPENAI_API_KEY"}],
          elevenlabs: [api_key: {:system, "ELEVENLABS_API_KEY"}]
        ],
        cache: [
          backend: Parrot.TTS.Cache.ETS,
          max_entries: 10_000
        ]

  ## Environment Variable Resolution

  Credentials support the `{:system, "VAR_NAME"}` tuple format for resolving
  environment variables at runtime:

      credentials: [
        openai: [api_key: {:system, "OPENAI_API_KEY"}]
      ]

  ## Default Values

  If no configuration is provided, the following defaults are used:
  - Provider: `:openai`
  - Voice: `"alloy"`
  - Model: `"tts-1"`
  - Cache backend: `Parrot.TTS.Cache.ETS`
  """

  @default_profile [
    provider: :openai,
    voice: "alloy",
    model: "tts-1"
  ]

  @default_cache_backend Parrot.TTS.Cache.ETS

  @provider_modules %{
    openai: Parrot.TTS.Providers.OpenAI,
    elevenlabs: Parrot.TTS.Providers.ElevenLabs,
    google: Parrot.TTS.Providers.Google,
    amazon: Parrot.TTS.Providers.Amazon
  }

  @doc """
  Retrieves a TTS profile by name.

  ## Parameters

  - `name` - Profile name atom, or `:default` to use the configured default profile.
    If not specified, defaults to `:default`.

  ## Returns

  - `{:ok, profile}` - Profile configuration as a keyword list
  - `{:error, {:unknown_profile, name}}` - When the requested profile doesn't exist

  ## Examples

      iex> Config.get_profile(:standard)
      {:ok, [provider: :openai, voice: "alloy", model: "tts-1"]}

      iex> Config.get_profile(:default)
      {:ok, [provider: :openai, voice: "alloy", model: "tts-1"]}

      iex> Config.get_profile()
      {:ok, [provider: :openai, voice: "alloy", model: "tts-1"]}

      iex> Config.get_profile(:nonexistent)
      {:error, {:unknown_profile, :nonexistent}}
  """
  @spec get_profile(atom()) :: {:ok, keyword()} | {:error, {:unknown_profile, atom()}}
  def get_profile(name \\ :default)

  def get_profile(:default) do
    config = get_tts_config()
    default_name = Keyword.get(config, :default_profile, :standard)
    profiles = Keyword.get(config, :profiles, [])

    case Keyword.get(profiles, default_name) do
      nil when profiles == [] ->
        # No profiles configured - return hardcoded defaults
        {:ok, @default_profile}

      nil ->
        # Profiles exist but default not found - return hardcoded defaults
        {:ok, @default_profile}

      profile ->
        {:ok, profile}
    end
  end

  def get_profile(name) when is_atom(name) do
    config = get_tts_config()
    profiles = Keyword.get(config, :profiles, [])

    case Keyword.get(profiles, name) do
      nil ->
        {:error, {:unknown_profile, name}}

      profile ->
        {:ok, profile}
    end
  end

  @doc """
  Retrieves credentials for a TTS provider.

  Environment variable tuples `{:system, "VAR_NAME"}` are resolved to their
  actual values at call time.

  ## Parameters

  - `provider` - Provider atom (e.g., `:openai`, `:elevenlabs`)

  ## Returns

  - `{:ok, credentials}` - Credentials as a keyword list with env vars resolved
  - `{:error, {:unknown_provider, provider}}` - When no credentials exist for the provider

  ## Examples

      iex> Config.get_credentials(:openai)
      {:ok, [api_key: "sk-actual-key-from-env"]}

      iex> Config.get_credentials(:unknown)
      {:error, {:unknown_provider, :unknown}}
  """
  @spec get_credentials(atom()) :: {:ok, keyword()} | {:error, {:unknown_provider, atom()}}
  def get_credentials(provider) when is_atom(provider) do
    config = get_tts_config()
    credentials = Keyword.get(config, :credentials, [])

    case Keyword.get(credentials, provider) do
      nil ->
        {:error, {:unknown_provider, provider}}

      provider_credentials ->
        {:ok, resolve_env_vars(provider_credentials)}
    end
  end

  @doc """
  Retrieves the cache configuration.

  ## Returns

  - `{:ok, cache_config}` - Cache configuration as a keyword list

  The returned config always includes a `:backend` key. If no cache configuration
  is specified, defaults to `Parrot.TTS.Cache.ETS`.

  ## Examples

      iex> Config.get_cache_config()
      {:ok, [backend: Parrot.TTS.Cache.ETS, max_entries: 10_000]}
  """
  @spec get_cache_config() :: {:ok, keyword()}
  def get_cache_config do
    config = get_tts_config()
    cache_config = Keyword.get(config, :cache, [])

    # Ensure backend is always present
    cache_config =
      if Keyword.has_key?(cache_config, :backend) do
        cache_config
      else
        Keyword.put(cache_config, :backend, @default_cache_backend)
      end

    {:ok, cache_config}
  end

  @doc """
  Maps a provider atom to its implementation module.

  ## Parameters

  - `provider` - Provider atom (e.g., `:openai`) or an existing module

  ## Returns

  - `{:ok, module}` - The provider implementation module
  - `{:error, {:unknown_provider, provider}}` - When the provider is not recognized

  ## Supported Providers

  - `:openai` -> `Parrot.TTS.Providers.OpenAI`
  - `:elevenlabs` -> `Parrot.TTS.Providers.ElevenLabs`
  - `:google` -> `Parrot.TTS.Providers.Google`
  - `:amazon` -> `Parrot.TTS.Providers.Amazon`

  If a module is passed directly (not an atom from the supported list),
  it is returned as-is, allowing for custom provider implementations.

  ## Examples

      iex> Config.get_provider_module(:openai)
      {:ok, Parrot.TTS.Providers.OpenAI}

      iex> Config.get_provider_module(MyCustomProvider)
      {:ok, MyCustomProvider}

      iex> Config.get_provider_module(:unknown)
      {:error, {:unknown_provider, :unknown}}
  """
  @spec get_provider_module(atom()) :: {:ok, module()} | {:error, {:unknown_provider, atom()}}
  def get_provider_module(provider) when is_atom(provider) do
    case Map.get(@provider_modules, provider) do
      nil ->
        # Check if it's already a module (capitalized atom)
        provider_string = Atom.to_string(provider)

        if String.starts_with?(provider_string, "Elixir.") do
          # It's already a module, return it directly
          {:ok, provider}
        else
          {:error, {:unknown_provider, provider}}
        end

      module ->
        {:ok, module}
    end
  end

  @doc """
  Resolves `{:system, "VAR"}` tuples in a keyword list or nested structure.

  This function recursively traverses keyword lists and resolves any
  `{:system, "VAR_NAME"}` tuples to their actual environment variable values.

  ## Parameters

  - `config` - A keyword list, potentially with nested keyword lists

  ## Returns

  The same structure with all `{:system, "VAR"}` tuples replaced with
  the corresponding environment variable values. Missing env vars resolve to `nil`.

  ## Examples

      iex> Config.resolve_env_vars([api_key: {:system, "MY_KEY"}])
      [api_key: "actual-value-from-env"]

      iex> Config.resolve_env_vars([nested: [key: {:system, "VAR"}]])
      [nested: [key: "resolved-value"]]
  """
  @spec resolve_env_vars(keyword()) :: keyword()
  def resolve_env_vars(config) when is_list(config) do
    Enum.map(config, fn
      {key, {:system, env_var}} when is_binary(env_var) ->
        {key, System.get_env(env_var)}

      {key, value} when is_list(value) ->
        {key, resolve_env_vars(value)}

      other ->
        other
    end)
  end

  # Private helpers

  defp get_tts_config do
    Application.get_env(:parrot, :tts, [])
  end
end
