defmodule Parrot.TTS.Cache.ETS do
  @moduledoc """
  ETS-based cache backend for TTS audio storage.

  This implementation provides fast, in-memory caching using Erlang's ETS (Erlang Term Storage).
  The cache is non-persistent and does not survive application restarts.

  ## Features

  - High-performance in-memory storage
  - Thread-safe concurrent access (ETS public table)
  - No TTL support (entries never expire)
  - Stores audio data as binary with metadata
  - No persistence across restarts

  ## Table Configuration

  - Table name: `:parrot_tts_cache`
  - Table type: `:set` (unique keys)
  - Access: `:public` (any process can read/write)
  - Storage format: `{key, audio_data, metadata}` tuples

  ## Usage

      # Start the cache backend (typically via supervisor)
      {:ok, pid} = Parrot.TTS.Cache.ETS.start_link(name: :parrot_tts_cache)

      # Store audio
      :ok = Parrot.TTS.Cache.ETS.put("key123", <<audio_data>>, %{format: :mp3})

      # Retrieve audio
      {:ok, audio_data, metadata} = Parrot.TTS.Cache.ETS.get("key123")

      # Delete entry
      :ok = Parrot.TTS.Cache.ETS.delete("key123")

      # Clear all entries
      :ok = Parrot.TTS.Cache.ETS.clear()
  """

  @behaviour Parrot.TTS.Cache
  use GenServer

  # Default table name
  @default_table_name :parrot_tts_cache

  ## Client API

  @doc """
  Starts the ETS cache backend.

  ## Options

  - `:name` - ETS table name (default: `:parrot_tts_cache`)

  ## Examples

      {:ok, pid} = Parrot.TTS.Cache.ETS.start_link()
      {:ok, pid} = Parrot.TTS.Cache.ETS.start_link(name: :my_cache)
  """
  def start_link(opts \\ []) do
    table_name = Keyword.get(opts, :name, @default_table_name)
    GenServer.start_link(__MODULE__, table_name, name: __MODULE__)
  end

  ## Cache behaviour callbacks

  @impl Parrot.TTS.Cache
  @doc """
  Retrieve cached audio data for the given key.

  ## Examples

      iex> get("existing_key")
      {:ok, <<audio_data>>, %{format: :mp3}}

      iex> get("missing_key")
      :miss
  """
  def get(key) when is_binary(key) do
    table_name = get_table_name()

    # Check if table exists before lookup
    case :ets.whereis(table_name) do
      :undefined ->
        :miss

      _ref ->
        case :ets.lookup(table_name, key) do
          [{^key, audio_data, metadata}] -> {:ok, audio_data, metadata}
          [] -> :miss
        end
    end
  end

  @impl Parrot.TTS.Cache
  @doc """
  Store audio data with metadata in the cache.

  If an entry with the same key already exists, it will be overwritten.

  ## Examples

      iex> put("key123", <<1, 2, 3>>, %{format: :wav})
      :ok
  """
  def put(key, audio_data, metadata) when is_binary(key) and is_binary(audio_data) and is_map(metadata) do
    table_name = get_table_name()

    # Check if table exists before insert
    case :ets.whereis(table_name) do
      :undefined ->
        {:error, :cache_not_started}

      _ref ->
        :ets.insert(table_name, {key, audio_data, metadata})
        :ok
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
    table_name = get_table_name()

    # Check if table exists before delete
    case :ets.whereis(table_name) do
      :undefined -> :ok
      _ref -> :ets.delete(table_name, key); :ok
    end
  end

  @impl Parrot.TTS.Cache
  @doc """
  Clear all entries from the cache.

  ## Examples

      iex> clear()
      :ok
  """
  def clear do
    table_name = get_table_name()

    # Check if table exists before attempting to clear
    case :ets.whereis(table_name) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(table_name); :ok
    end
  end

  ## GenServer callbacks

  @impl GenServer
  def init(table_name) do
    # Create ETS table
    # :set - unique keys
    # :public - accessible by any process
    # :named_table - can reference by name
    # {:read_concurrency, true} - optimize for concurrent reads
    # {:write_concurrency, true} - optimize for concurrent writes
    _table = :ets.new(table_name, [
      :set,
      :public,
      :named_table,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    # Store table name in process state
    {:ok, table_name}
  end

  @impl GenServer
  def terminate(_reason, table_name) do
    # Clean up ETS table on termination
    if :ets.whereis(table_name) != :undefined do
      :ets.delete(table_name)
    end

    :ok
  end

  ## Private helpers

  defp get_table_name do
    # Get table name from GenServer state
    case Process.whereis(__MODULE__) do
      nil ->
        # Fallback to default if GenServer not running
        @default_table_name

      pid ->
        GenServer.call(pid, :get_table_name)
    end
  end

  @impl GenServer
  def handle_call(:get_table_name, _from, table_name) do
    {:reply, table_name, table_name}
  end
end
