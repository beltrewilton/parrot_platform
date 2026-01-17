# Contract: TTS Cache Behaviour

**Module**: `Parrot.TTS.Cache`
**Type**: Elixir Behaviour

## Callbacks

### get/1

Retrieve cached audio by key.

```elixir
@callback get(key :: String.t()) ::
  {:ok, audio_data :: binary(), metadata :: map()} |
  :miss
```

**Parameters**:
- `key` - Cache key (SHA256 hash, 64-char hex string)

**Returns**:
- `{:ok, binary, map}` - Cached audio data and metadata
- `:miss` - Key not found in cache

**Metadata map**:
```elixir
%{
  format: :mp3 | :wav | :pcm | :ogg,
  provider: :openai | :elevenlabs | :google | :polly,
  created_at: DateTime.t(),
  size_bytes: non_neg_integer()
}
```

---

### put/3

Store audio in cache.

```elixir
@callback put(key :: String.t(), audio_data :: binary(), metadata :: map()) ::
  :ok |
  {:error, reason :: term()}
```

**Parameters**:
- `key` - Cache key
- `audio_data` - Audio binary data
- `metadata` - Metadata map (same structure as get/1)

**Returns**:
- `:ok` - Successfully stored
- `{:error, term}` - Storage failed

**Error reasons**:
- `{:storage_full, current_size}` - Cache capacity exceeded
- `{:write_error, reason}` - Disk write failed (disk backend)

---

### delete/1

Remove entry from cache.

```elixir
@callback delete(key :: String.t()) :: :ok
```

**Parameters**:
- `key` - Cache key to delete

**Returns**:
- `:ok` - Always succeeds (idempotent)

---

### clear/0

Remove all entries from cache.

```elixir
@callback clear() :: :ok
```

**Returns**:
- `:ok` - Cache cleared

---

## Implementation Notes

### ETS Backend

- Uses named ETS table `:parrot_tts_cache`
- No persistence across restarts
- Optional max_entries limit with LRU eviction
- No TTL support (entries never expire)

### Disk Backend

- Stores files in configured directory
- Filename is cache key + format extension
- Supports TTL with lazy deletion
- Metadata stored in separate `.meta` files

---

## Implementation Example

```elixir
defmodule MyApp.TTS.RedisCache do
  @behaviour Parrot.TTS.Cache

  @impl true
  def get(key) do
    case Redix.command(:tts_cache, ["GET", key]) do
      {:ok, nil} -> :miss
      {:ok, data} ->
        {audio, meta} = :erlang.binary_to_term(data)
        {:ok, audio, meta}
    end
  end

  @impl true
  def put(key, audio_data, metadata) do
    data = :erlang.term_to_binary({audio_data, metadata})
    case Redix.command(:tts_cache, ["SET", key, data]) do
      {:ok, "OK"} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    Redix.command(:tts_cache, ["DEL", key])
    :ok
  end

  @impl true
  def clear() do
    Redix.command(:tts_cache, ["FLUSHDB"])
    :ok
  end
end
```
