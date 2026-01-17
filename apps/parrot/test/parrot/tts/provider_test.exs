defmodule Parrot.TTS.ProviderTest do
  use ExUnit.Case, async: true

  alias Parrot.TTS.Provider

  describe "Provider behaviour" do
    test "defines synthesize/2 callback" do
      assert function_exported?(Provider, :behaviour_info, 1)
      callbacks = Provider.behaviour_info(:callbacks)
      assert {:synthesize, 2} in callbacks
    end

    test "defines list_voices/1 callback" do
      callbacks = Provider.behaviour_info(:callbacks)
      assert {:list_voices, 1} in callbacks
    end

    test "defines validate_config/1 callback" do
      callbacks = Provider.behaviour_info(:callbacks)
      assert {:validate_config, 1} in callbacks
    end
  end

  describe "mock implementation" do
    defmodule MockProvider do
      @behaviour Parrot.TTS.Provider

      @impl true
      def synthesize(_text, config) do
        format = Keyword.get(config, :format, :wav)
        audio_data = <<0, 1, 2, 3>>
        {:ok, audio_data, format}
      end

      @impl true
      def list_voices(_credentials) do
        {:ok, [
          %{id: "voice1", name: "Test Voice 1", language: "en-US"},
          %{id: "voice2", name: "Test Voice 2", language: "en-GB"}
        ]}
      end

      @impl true
      def validate_config(config) do
        if Keyword.has_key?(config, :api_key) do
          :ok
        else
          {:error, :missing_api_key}
        end
      end
    end

    test "synthesize/2 returns audio data and format" do
      text = "Hello world"
      config = [format: :mp3, voice: "test_voice"]

      assert {:ok, audio_data, :mp3} = MockProvider.synthesize(text, config)
      assert is_binary(audio_data)
    end

    test "synthesize/2 uses default format when not specified" do
      text = "Hello world"
      config = [voice: "test_voice"]

      assert {:ok, audio_data, :wav} = MockProvider.synthesize(text, config)
      assert is_binary(audio_data)
    end

    test "list_voices/1 returns list of voice maps" do
      credentials = [api_key: "test_key"]

      assert {:ok, voices} = MockProvider.list_voices(credentials)
      assert is_list(voices)
      assert length(voices) > 0

      voice = hd(voices)
      assert Map.has_key?(voice, :id)
      assert Map.has_key?(voice, :name)
      assert Map.has_key?(voice, :language)
    end

    test "validate_config/1 returns :ok for valid config" do
      config = [api_key: "test_key", voice: "test_voice"]
      assert :ok = MockProvider.validate_config(config)
    end

    test "validate_config/1 returns error for invalid config" do
      config = [voice: "test_voice"]
      assert {:error, :missing_api_key} = MockProvider.validate_config(config)
    end
  end

  describe "behaviour contract validation" do
    test "all callbacks have correct return type signatures" do
      # This test verifies the mock correctly implements expected return types
      # synthesize/2 should return {:ok, binary(), atom()} | {:error, term()}
      assert {:ok, data, format} = __MODULE__.MockProvider.synthesize("test", [])
      assert is_binary(data)
      assert is_atom(format)

      # list_voices/1 should return {:ok, [map()]} | {:error, term()}
      assert {:ok, voices} = __MODULE__.MockProvider.list_voices([])
      assert is_list(voices)
      assert Enum.all?(voices, &is_map/1)

      # validate_config/1 should return :ok | {:error, term()}
      result = __MODULE__.MockProvider.validate_config([api_key: "test"])
      assert result == :ok or match?({:error, _}, result)
    end
  end
end
