defmodule Parrot.TTS.MockProvider do
  @moduledoc """
  Mock TTS provider for testing purposes.

  This provider implements the `Parrot.TTS.Provider` behaviour with deterministic,
  predictable behavior for use in unit and integration tests.

  ## Features

  - Returns deterministic fake audio data based on input text
  - Provides a fixed set of mock voices
  - Simple validation that only checks for required `:api_key` field

  ## Usage

  ```elixir
  # In tests:
  profile = %{
    provider: Parrot.TTS.MockProvider,
    voice: "mock-voice-1",
    model: "mock-model",
    format: :wav
  }

  config = [api_key: "test-key", format: :wav]

  {:ok, audio_data, :wav} = Parrot.TTS.MockProvider.synthesize("Hello", config)
  # Returns: "MOCK_AUDIO:Hello"
  ```

  ## Mock Audio Format

  The mock audio data is a simple string with the format:
  `"MOCK_AUDIO:" <> text`

  This makes it easy to verify in tests that the correct text was synthesized,
  while still providing binary data that can be processed by the system.
  """

  @behaviour Parrot.TTS.Provider

  @impl true
  def synthesize(text, config) do
    # Return deterministic fake audio data based on text
    audio_data = "MOCK_AUDIO:" <> text
    format = Keyword.get(config, :format, :wav)
    {:ok, audio_data, format}
  end

  @impl true
  def list_voices(_config) do
    {:ok,
     [
       %{id: "mock-voice-1", name: "Mock Voice 1", language: "en-US", gender: "neutral"},
       %{id: "mock-voice-2", name: "Mock Voice 2", language: "en-US", gender: "female"}
     ]}
  end

  @impl true
  def validate_config(config) do
    if Keyword.has_key?(config, :api_key) do
      :ok
    else
      {:error, {:missing_field, :api_key}}
    end
  end
end
