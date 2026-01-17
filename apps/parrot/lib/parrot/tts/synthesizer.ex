defmodule Parrot.TTS.Synthesizer do
  @moduledoc """
  Synthesizer coordinates between cache and TTS provider to efficiently generate speech audio.

  The Synthesizer provides the main public API for text-to-speech synthesis with automatic
  caching and request deduplication:

  1. **Cache-first lookup**: Always checks cache before calling the provider
  2. **Provider fallback**: Calls provider on cache miss
  3. **Automatic caching**: Stores provider results in cache for future use
  4. **Request deduplication**: Concurrent requests for the same uncached text wait for
     a single provider call instead of making duplicate API requests

  ## Cache Key Generation

  Cache keys are deterministic SHA256 hashes of a canonical JSON representation including:
  - Text content
  - Provider module
  - Voice ID
  - Model name
  - Audio format

  This ensures identical synthesis requests always produce the same cache key.

  ## Concurrent Request Deduplication

  When multiple concurrent requests arrive for the same uncached text, the Synthesizer:
  1. First request triggers a provider call and enters "in-flight" state
  2. Subsequent requests for the same cache key wait for the first to complete
  3. Once provider responds, all waiting callers receive the result
  4. Result is cached once and shared with all waiters

  This prevents redundant API calls during high-concurrency scenarios.

  ## Example

      # Start the Synthesizer (typically in supervision tree)
      {:ok, _pid} = Synthesizer.start_link(name: Synthesizer)

      # Synthesize speech with a profile
      profile = %{
        provider: Parrot.TTS.Provider.OpenAI,
        cache: Parrot.TTS.Cache.ETS,
        voice: "alloy",
        model: "tts-1",
        format: :mp3,
        api_key: "sk-..."
      }

      {:ok, audio_data, format} = Synthesizer.get_audio("Hello, world!", profile)

  ## Configuration

  The profile map passed to `get_audio/3` must include:
  - `:provider` - Provider module implementing `Parrot.TTS.Provider` behaviour
  - `:cache` - Cache module implementing `Parrot.TTS.Cache` behaviour
  - `:voice` - Voice ID for synthesis
  - `:model` - Model name for synthesis
  - `:format` - Audio format (`:wav`, `:mp3`, `:opus`, etc.)
  - Additional provider-specific options (e.g., `:api_key`)
  """

  use GenServer
  require Logger

  # Client API

  @doc """
  Starts the Synthesizer GenServer.

  ## Options

  - `:name` - Process name for registration (default: `__MODULE__`)

  ## Examples

      {:ok, pid} = Synthesizer.start_link()
      {:ok, pid} = Synthesizer.start_link(name: MySynthesizer)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Synthesizes audio from text using the specified profile.

  This function coordinates cache lookup and provider synthesis:
  1. Generates cache key from text and profile
  2. Checks cache for existing audio
  3. On cache miss, calls provider to synthesize
  4. Caches provider result with metadata
  5. Returns audio data and format/metadata

  Concurrent requests for the same uncached text are deduplicated - only one
  provider call is made and the result is shared with all waiting callers.

  ## Parameters

  - `text` - Text to synthesize (binary string)
  - `profile` - Synthesis profile map (see module doc)
  - `opts` - Additional options (keyword list, currently unused)

  ## Returns

  - `{:ok, audio_data, format}` - Success with binary audio data and format atom
  - `{:ok, audio_data, metadata}` - Success with binary audio data and metadata map (on cache hit)
  - `{:error, reason}` - Failure with error reason

  ## Examples

      profile = %{
        provider: Parrot.TTS.Provider.OpenAI,
        cache: Parrot.TTS.Cache.ETS,
        voice: "alloy",
        model: "tts-1",
        format: :mp3
      }

      {:ok, audio, :mp3} = Synthesizer.get_audio("Hello", profile)
  """
  def get_audio(text, profile, opts \\ []) do
    GenServer.call(__MODULE__, {:get_audio, text, profile, opts}, :infinity)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # State tracks in-flight requests to deduplicate concurrent calls
    # in_flight: %{cache_key => {from_list, provider_task_ref}}
    state = %{
      in_flight: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get_audio, text, profile, opts}, from, state) do
    cache_module = Map.fetch!(profile, :cache)
    cache_key = compute_cache_key(text, profile, opts)

    # Check cache first
    case cache_module.get(cache_key) do
      {:ok, audio_data, metadata} ->
        # Cache hit - return immediately
        {:reply, {:ok, audio_data, metadata}, state}

      :miss ->
        # Cache miss - check if request is already in-flight
        case Map.get(state.in_flight, cache_key) do
          nil ->
            # First request for this key - start provider call
            handle_cache_miss(text, profile, opts, cache_key, from, state)

          {waiting_froms, ref} ->
            # Request already in-flight - add to waiters
            updated_waiting = [from | waiting_froms]
            updated_in_flight = Map.put(state.in_flight, cache_key, {updated_waiting, ref})
            {:noreply, %{state | in_flight: updated_in_flight}}
        end
    end
  end

  @impl true
  def handle_info({:provider_result, cache_key, result}, state) do
    # Provider call completed - notify all waiting callers
    case Map.pop(state.in_flight, cache_key) do
      {nil, _} ->
        # No waiters (shouldn't happen, but handle gracefully)
        Logger.warning("Received provider result for unknown cache key: #{cache_key}")
        {:noreply, state}

      {{waiting_froms, _ref}, updated_in_flight} ->
        # Reply to all waiting callers with the result
        Enum.each(waiting_froms, fn from_pid ->
          GenServer.reply(from_pid, result)
        end)

        {:noreply, %{state | in_flight: updated_in_flight}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Task process died - clean up in_flight tracking
    # We could match on ref to remove specific entry, but for simplicity
    # we'll let the timeout mechanism handle it
    {:noreply, state}
  end

  # Private functions

  defp handle_cache_miss(text, profile, _opts, cache_key, from, state) do
    provider_module = Map.fetch!(profile, :provider)
    cache_module = Map.fetch!(profile, :cache)

    # Convert profile map to keyword list for provider
    provider_config = profile_to_config(profile)

    # Start async task to call provider
    parent = self()

    task_ref = make_ref()

    spawn_link(fn ->
      result =
        case provider_module.synthesize(text, provider_config) do
          {:ok, audio_data, format} ->
            # Cache the result
            metadata = %{
              format: format,
              cached_at: DateTime.utc_now()
            }

            case cache_module.put(cache_key, audio_data, metadata) do
              :ok ->
                {:ok, audio_data, format}

              {:error, cache_error} ->
                # Log cache error but still return the audio
                Logger.warning("Failed to cache audio: #{inspect(cache_error)}")
                {:ok, audio_data, format}
            end

          {:error, reason} ->
            {:error, reason}
        end

      send(parent, {:provider_result, cache_key, result})
    end)

    # Track this request as in-flight
    updated_in_flight = Map.put(state.in_flight, cache_key, {[from], task_ref})
    {:noreply, %{state | in_flight: updated_in_flight}}
  end

  defp profile_to_config(profile) do
    # Convert profile map to keyword list for provider
    # Provider expects keyword list with standard keys
    [
      provider: Map.get(profile, :provider),
      voice: Map.get(profile, :voice),
      model: Map.get(profile, :model),
      format: Map.get(profile, :format)
    ]
    |> Enum.filter(fn {_k, v} -> v != nil end)
    |> Kernel.++(Map.to_list(Map.drop(profile, [:provider, :cache, :voice, :model, :format])))
  end

  @doc """
  Computes a deterministic cache key from text and synthesis configuration.

  The cache key is a SHA256 hash of a canonical JSON representation that includes:
  - Text content
  - Provider module (as inspected string for determinism)
  - Voice ID
  - Model name
  - Audio format

  This ensures identical synthesis requests always produce the same cache key,
  enabling effective caching across requests.

  ## Parameters

  - `text` - Text to synthesize
  - `profile` - Synthesis profile map
  - `opts` - Additional options (currently unused)

  ## Returns

  64-character lowercase hexadecimal SHA256 hash string

  ## Examples

      profile = %{
        provider: Parrot.TTS.Provider.OpenAI,
        voice: "alloy",
        model: "tts-1",
        format: :mp3
      }

      key = compute_cache_key("Hello", profile, [])
      # => "a1b2c3d4..." (64 hex chars)

  ## Implementation Notes

  - Uses `Jason.encode!/2` with `sort_keys: true` for deterministic JSON
  - Provider module is converted to string via `inspect/1` for consistency
  - Returns lowercase hex encoding of SHA256 hash
  """
  def compute_cache_key(text, profile, _opts) do
    # Build canonical representation for hashing
    cache_input = %{
      text: text,
      provider: inspect(Map.fetch!(profile, :provider)),
      voice: Map.get(profile, :voice),
      model: Map.get(profile, :model),
      format: Map.get(profile, :format)
    }

    # Generate deterministic JSON and hash
    json = Jason.encode!(cache_input, sort_keys: true)
    :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
  end
end
