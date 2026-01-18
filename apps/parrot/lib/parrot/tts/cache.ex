defmodule Parrot.TTS.Cache do
  @moduledoc """
  Behaviour for TTS audio cache implementations.

  This behaviour defines a contract for caching synthesized audio from TTS providers.
  Implementations can use different storage backends (in-memory ETS, disk, Redis, etc.)
  to persist audio data and avoid redundant synthesis requests.

  ## Cache Keys

  Cache keys are typically generated from text content and provider-specific settings
  (voice, language, format, etc.) to ensure cache hits for identical synthesis requests.

  ## Metadata

  Metadata stored alongside audio data may include:
  - Audio format (wav, mp3, opus, etc.)
  - Encoding parameters (codec, sample rate, bit depth)
  - Duration in milliseconds
  - Provider-specific information
  - Timestamps (creation time, expiry, TTL)

  ## Built-in Backends

  Parrot provides two reference implementations:
  - `Parrot.TTS.Cache.ETS` - In-memory cache using ETS tables (fast, non-persistent)
  - `Parrot.TTS.Cache.Disk` - File-based cache (persistent across restarts)

  ## Example

      defmodule MyCache do
        @behaviour Parrot.TTS.Cache

        @impl true
        def get(key) do
          case fetch_from_storage(key) do
            {:ok, audio_data, metadata} -> {:ok, audio_data, metadata}
            :not_found -> :miss
          end
        end

        @impl true
        def put(key, audio_data, metadata) do
          store_in_storage(key, audio_data, metadata)
          :ok
        rescue
          e -> {:error, e}
        end

        @impl true
        def delete(key) do
          remove_from_storage(key)
          :ok
        end

        @impl true
        def clear() do
          remove_all_from_storage()
          :ok
        end
      end

  ## Usage with TTS Providers

      # Configure cache backend
      config = %{cache_backend: MyCache}

      # Cache is consulted automatically by TTS client
      case Parrot.TTS.synthesize(text, config) do
        {:ok, audio_data} -> # May come from cache or fresh synthesis
        {:error, reason} -> # Handle error
      end
  """

  @doc """
  Retrieve cached audio data and metadata for the given key.

  ## Parameters

  - `key` - Cache key (typically a hash of text + synthesis parameters)

  ## Returns

  - `{:ok, audio_data, metadata}` - Cache hit with binary audio data and metadata map
  - `:miss` - Cache miss, entry not found

  ## Examples

      iex> get("abc123")
      {:ok, <<binary_audio_data>>, %{format: "wav", duration_ms: 1500}}

      iex> get("nonexistent")
      :miss
  """
  @callback get(key :: String.t()) ::
              {:ok, audio_data :: binary(), metadata :: map()}
              | :miss

  @doc """
  Store audio data and metadata in the cache with the given key.

  ## Parameters

  - `key` - Cache key (typically a hash of text + synthesis parameters)
  - `audio_data` - Binary audio data to cache
  - `metadata` - Map containing audio metadata (format, duration, encoding, etc.)

  ## Returns

  - `:ok` - Successfully stored in cache
  - `{:error, reason}` - Failed to store (disk full, permission denied, etc.)

  ## Examples

      iex> put("abc123", <<audio_binary>>, %{format: "wav", duration_ms: 1500})
      :ok

      iex> put("key", <<data>>, %{invalid: :storage})
      {:error, :disk_full}
  """
  @callback put(key :: String.t(), audio_data :: binary(), metadata :: map()) ::
              :ok
              | {:error, reason :: term()}

  @doc """
  Remove a cached entry for the given key.

  This operation is idempotent - deleting a non-existent key returns `:ok`.

  ## Parameters

  - `key` - Cache key to delete

  ## Returns

  - `:ok` - Entry deleted (or did not exist)

  ## Examples

      iex> delete("abc123")
      :ok

      iex> delete("nonexistent")
      :ok
  """
  @callback delete(key :: String.t()) :: :ok

  @doc """
  Clear all entries from the cache.

  This operation removes all cached audio data and metadata. Use with caution
  as this will force all subsequent requests to perform fresh synthesis.

  ## Returns

  - `:ok` - Cache cleared successfully

  ## Examples

      iex> clear()
      :ok
  """
  @callback clear() :: :ok
end
