defmodule Parrot.TTS.Cache.Disk do
  @moduledoc """
  Disk-based cache backend for TTS audio storage.

  This implementation provides persistent caching using the filesystem.
  Audio files and metadata are stored as separate files, allowing cache
  entries to survive application restarts.

  ## Features

  - Persistent storage across restarts
  - TTL-based expiration with lazy deletion
  - Audio stored as binary files
  - Metadata stored in separate .meta files
  - Configurable cache directory
  - Creates cache directory if it doesn't exist

  ## File Structure

  Audio and metadata are stored as separate files:
  - Audio: `{cache_dir}/{key}.audio`
  - Metadata: `{cache_dir}/{key}.meta`

  ## TTL Expiration

  Entries expire based on TTL (time-to-live) configured at startup.
  Expiration is checked lazily on read - expired entries are deleted
  when accessed and return `:miss`.

  ## Configuration

  Options for `start_link/1`:
  - `:cache_dir` - Directory to store cache files (required)
  - `:ttl` - Time-to-live in seconds (default: 3600 = 1 hour)

  ## Usage

      # Start the cache backend
      {:ok, pid} = Parrot.TTS.Cache.Disk.start_link(
        cache_dir: "/tmp/parrot_tts_cache",
        ttl: 3600
      )

      # Store audio
      :ok = Parrot.TTS.Cache.Disk.put("key123", <<audio_data>>, %{format: :mp3})

      # Retrieve audio
      {:ok, audio_data, metadata} = Parrot.TTS.Cache.Disk.get("key123")

      # Delete entry
      :ok = Parrot.TTS.Cache.Disk.delete("key123")

      # Clear all entries
      :ok = Parrot.TTS.Cache.Disk.clear()
  """

  @behaviour Parrot.TTS.Cache
  use GenServer

  # Default TTL: 1 hour
  @default_ttl 3600

  ## Client API

  @doc """
  Starts the Disk cache backend.

  ## Options

  - `:cache_dir` - Directory to store cache files (required)
  - `:ttl` - Time-to-live in seconds (default: 3600)

  ## Examples

      {:ok, pid} = Parrot.TTS.Cache.Disk.start_link(cache_dir: "/tmp/cache")
      {:ok, pid} = Parrot.TTS.Cache.Disk.start_link(cache_dir: "/tmp/cache", ttl: 7200)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## Cache behaviour callbacks

  @impl Parrot.TTS.Cache
  @doc """
  Retrieve cached audio data for the given key.

  Returns `:miss` if the entry doesn't exist or has expired.
  Expired entries are lazily deleted on read.

  ## Examples

      iex> get("existing_key")
      {:ok, <<audio_data>>, %{format: :mp3}}

      iex> get("missing_key")
      :miss

      iex> get("expired_key")
      :miss  # and deletes the expired files
  """
  def get(key) when is_binary(key) do
    case get_config() do
      nil -> :miss
      config -> do_get(key, config)
    end
  end

  @impl Parrot.TTS.Cache
  @doc """
  Store audio data with metadata in the cache.

  If an entry with the same key already exists, it will be overwritten.
  The created_at timestamp in metadata is used for TTL expiration.

  ## Examples

      iex> put("key123", <<1, 2, 3>>, %{format: :wav})
      :ok
  """
  def put(key, audio_data, metadata)
      when is_binary(key) and is_binary(audio_data) and is_map(metadata) do
    case get_config() do
      nil -> {:error, :cache_not_started}
      config -> do_put(key, audio_data, metadata, config)
    end
  end

  @impl Parrot.TTS.Cache
  @doc """
  Delete a cached entry.

  This operation is idempotent - deleting a non-existent key returns `:ok`.

  ## Examples

      iex> delete("key123")
      :ok
  """
  def delete(key) when is_binary(key) do
    case get_config() do
      nil -> :ok
      config -> do_delete(key, config)
    end
  end

  @impl Parrot.TTS.Cache
  @doc """
  Clear all entries from the cache.

  Removes all .audio and .meta files from the cache directory.

  ## Examples

      iex> clear()
      :ok
  """
  def clear do
    case get_config() do
      nil -> :ok
      config -> do_clear(config)
    end
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    cache_dir = Keyword.fetch!(opts, :cache_dir)
    ttl = Keyword.get(opts, :ttl, @default_ttl)

    # Create cache directory if it doesn't exist
    case File.mkdir_p(cache_dir) do
      :ok ->
        state = %{
          cache_dir: cache_dir,
          ttl: ttl
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:mkdir_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:get_config, _from, state) do
    {:reply, state, state}
  end

  ## Private helpers

  defp get_config do
    case Process.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, :get_config)
    end
  end

  defp do_get(key, %{cache_dir: cache_dir, ttl: ttl}) do
    audio_path = audio_path(cache_dir, key)
    meta_path = meta_path(cache_dir, key)

    with {:ok, meta_binary} <- File.read(meta_path),
         metadata <- :erlang.binary_to_term(meta_binary),
         :ok <- check_ttl(metadata, ttl),
         {:ok, audio_data} <- File.read(audio_path) do
      {:ok, audio_data, metadata}
    else
      {:error, :enoent} ->
        :miss

      {:error, :expired} ->
        # Lazy deletion: remove expired files
        File.rm(audio_path)
        File.rm(meta_path)
        :miss

      {:error, _reason} ->
        :miss
    end
  end

  defp do_put(key, audio_data, metadata, %{cache_dir: cache_dir}) do
    audio_path = audio_path(cache_dir, key)
    meta_path = meta_path(cache_dir, key)

    # Ensure created_at is set for TTL checking
    metadata_with_timestamp = ensure_created_at(metadata)

    with :ok <- File.write(audio_path, audio_data),
         :ok <- File.write(meta_path, :erlang.term_to_binary(metadata_with_timestamp)) do
      :ok
    else
      {:error, reason} ->
        # Clean up partial writes
        File.rm(audio_path)
        File.rm(meta_path)
        {:error, {:write_error, reason}}
    end
  end

  defp do_delete(key, %{cache_dir: cache_dir}) do
    audio_path = audio_path(cache_dir, key)
    meta_path = meta_path(cache_dir, key)

    # Delete both files (ignore errors for non-existent files)
    File.rm(audio_path)
    File.rm(meta_path)
    :ok
  end

  defp do_clear(%{cache_dir: cache_dir}) do
    # List all files and delete .audio and .meta files
    case File.ls(cache_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(fn file ->
          String.ends_with?(file, ".audio") or String.ends_with?(file, ".meta")
        end)
        |> Enum.each(fn file ->
          File.rm(Path.join(cache_dir, file))
        end)

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp check_ttl(metadata, ttl) do
    case Map.get(metadata, :created_at) do
      nil ->
        # No created_at timestamp, assume valid
        :ok

      created_at ->
        now = DateTime.utc_now()
        age_seconds = DateTime.diff(now, created_at, :second)

        if age_seconds < ttl do
          :ok
        else
          {:error, :expired}
        end
    end
  end

  defp ensure_created_at(metadata) do
    case Map.get(metadata, :created_at) do
      nil -> Map.put(metadata, :created_at, DateTime.utc_now())
      _ -> metadata
    end
  end

  defp audio_path(cache_dir, key), do: Path.join(cache_dir, "#{key}.audio")
  defp meta_path(cache_dir, key), do: Path.join(cache_dir, "#{key}.meta")
end
