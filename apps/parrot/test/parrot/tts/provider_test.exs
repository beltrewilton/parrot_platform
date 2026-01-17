defmodule Parrot.TTS.ProviderTest do
  @moduledoc """
  Contract tests for the Parrot.TTS.Provider behaviour.

  These tests define and verify the contract that all TTS provider implementations
  must follow. The behaviour requires three callbacks:

  - `synthesize/2` - Converts text to audio binary
  - `list_voices/1` - Lists available voices for the provider
  - `validate_config/1` - Validates provider configuration

  ## TDD Note

  These tests are written BEFORE the Provider behaviour module exists.
  They will fail initially (red phase) and guide the implementation (green phase).
  """
  use ExUnit.Case, async: true

  # The behaviour module doesn't exist yet - tests will fail initially
  # This alias will work once the module is created
  alias Parrot.TTS.Provider

  describe "Provider behaviour definition" do
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

    test "defines exactly 3 callbacks" do
      callbacks = Provider.behaviour_info(:callbacks)
      assert length(callbacks) == 3
    end
  end

  describe "Provider behaviour contract - synthesize/2" do
    defmodule SynthesizeMock do
      @moduledoc "Mock provider for testing synthesize/2 contract"
      @behaviour Parrot.TTS.Provider

      @impl true
      def synthesize("success", _config) do
        # Simulates successful synthesis - returns raw audio binary
        audio_binary = <<0x52, 0x49, 0x46, 0x46>>
        {:ok, audio_binary}
      end

      def synthesize("error", _config) do
        {:error, :synthesis_failed}
      end

      def synthesize("empty", _config) do
        # Empty text should return empty audio (or error, depending on impl)
        {:ok, <<>>}
      end

      def synthesize("timeout", _config) do
        {:error, :timeout}
      end

      def synthesize("invalid_key", _config) do
        {:error, :invalid_api_key}
      end

      def synthesize("rate_limited", _config) do
        {:error, :rate_limited}
      end

      @impl true
      def list_voices(_config), do: {:ok, []}

      @impl true
      def validate_config(_config), do: :ok
    end

    test "returns {:ok, binary()} on successful synthesis" do
      result = SynthesizeMock.synthesize("success", [])

      assert {:ok, audio_binary} = result
      assert is_binary(audio_binary)
    end

    test "returns {:error, reason} on synthesis failure" do
      result = SynthesizeMock.synthesize("error", [])

      assert {:error, reason} = result
      assert reason == :synthesis_failed
    end

    test "handles empty text input" do
      result = SynthesizeMock.synthesize("empty", [])

      # Empty text can either return empty binary or error
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "returns {:error, :timeout} when provider times out" do
      result = SynthesizeMock.synthesize("timeout", [])

      assert {:error, :timeout} = result
    end

    test "returns {:error, :invalid_api_key} for authentication failures" do
      result = SynthesizeMock.synthesize("invalid_key", [])

      assert {:error, :invalid_api_key} = result
    end

    test "returns {:error, :rate_limited} when rate limited" do
      result = SynthesizeMock.synthesize("rate_limited", [])

      assert {:error, :rate_limited} = result
    end

    test "accepts config keyword list with standard options" do
      config = [
        api_key: "test_key",
        voice: "alloy",
        model: "tts-1",
        format: :mp3
      ]

      # Should not raise - config format is valid
      result = SynthesizeMock.synthesize("success", config)
      assert {:ok, _} = result
    end
  end

  describe "Provider behaviour contract - list_voices/1" do
    defmodule ListVoicesMock do
      @moduledoc "Mock provider for testing list_voices/1 contract"
      @behaviour Parrot.TTS.Provider

      @impl true
      def synthesize(_text, _config), do: {:ok, <<>>}

      @impl true
      def list_voices([success: true]) do
        {:ok,
         [
           %{id: "voice-1", name: "Voice One", language: "en-US"},
           %{id: "voice-2", name: "Voice Two", language: "en-GB"},
           %{id: "voice-3", name: "Voice Three", language: "es-ES"}
         ]}
      end

      def list_voices([empty: true]) do
        {:ok, []}
      end

      def list_voices([error: true]) do
        {:error, :api_error}
      end

      def list_voices([invalid_key: true]) do
        {:error, :invalid_api_key}
      end

      def list_voices(_config) do
        {:ok, [%{id: "default", name: "Default Voice", language: "en-US"}]}
      end

      @impl true
      def validate_config(_config), do: :ok
    end

    test "returns {:ok, list()} with available voices" do
      result = ListVoicesMock.list_voices(success: true)

      assert {:ok, voices} = result
      assert is_list(voices)
      assert length(voices) == 3
    end

    test "each voice has :id, :name, and :language keys" do
      {:ok, voices} = ListVoicesMock.list_voices(success: true)

      for voice <- voices do
        assert Map.has_key?(voice, :id)
        assert Map.has_key?(voice, :name)
        assert Map.has_key?(voice, :language)
        assert is_binary(voice.id)
        assert is_binary(voice.name)
        assert is_binary(voice.language)
      end
    end

    test "returns {:ok, []} when no voices available" do
      result = ListVoicesMock.list_voices(empty: true)

      assert {:ok, []} = result
    end

    test "returns {:error, reason} on API failure" do
      result = ListVoicesMock.list_voices(error: true)

      assert {:error, :api_error} = result
    end

    test "returns {:error, :invalid_api_key} for authentication failures" do
      result = ListVoicesMock.list_voices(invalid_key: true)

      assert {:error, :invalid_api_key} = result
    end
  end

  describe "Provider behaviour contract - validate_config/1" do
    defmodule ValidateConfigMock do
      @moduledoc "Mock provider for testing validate_config/1 contract"
      @behaviour Parrot.TTS.Provider

      @impl true
      def synthesize(_text, _config), do: {:ok, <<>>}

      @impl true
      def list_voices(_config), do: {:ok, []}

      @impl true
      def validate_config(config) do
        cond do
          not Keyword.has_key?(config, :api_key) ->
            {:error, :missing_api_key}

          Keyword.get(config, :api_key) == "" ->
            {:error, :empty_api_key}

          Keyword.get(config, :api_key) == nil ->
            {:error, :nil_api_key}

          Keyword.has_key?(config, :voice) and not is_binary(Keyword.get(config, :voice)) ->
            {:error, :invalid_voice_type}

          Keyword.has_key?(config, :format) and
              Keyword.get(config, :format) not in [:mp3, :wav, :pcm, :ogg] ->
            {:error, :unsupported_format}

          true ->
            :ok
        end
      end
    end

    test "returns :ok for valid configuration" do
      config = [api_key: "sk-test-12345"]

      assert :ok = ValidateConfigMock.validate_config(config)
    end

    test "returns :ok for complete configuration with all options" do
      config = [
        api_key: "sk-test-12345",
        voice: "alloy",
        model: "tts-1",
        format: :mp3
      ]

      assert :ok = ValidateConfigMock.validate_config(config)
    end

    test "returns {:error, :missing_api_key} when api_key is missing" do
      config = [voice: "alloy"]

      assert {:error, :missing_api_key} = ValidateConfigMock.validate_config(config)
    end

    test "returns {:error, :empty_api_key} when api_key is empty string" do
      config = [api_key: ""]

      assert {:error, :empty_api_key} = ValidateConfigMock.validate_config(config)
    end

    test "returns {:error, :nil_api_key} when api_key is nil" do
      config = [api_key: nil]

      assert {:error, :nil_api_key} = ValidateConfigMock.validate_config(config)
    end

    test "returns {:error, :invalid_voice_type} when voice is not a string" do
      config = [api_key: "test", voice: 123]

      assert {:error, :invalid_voice_type} = ValidateConfigMock.validate_config(config)
    end

    test "returns {:error, :unsupported_format} for unknown audio formats" do
      config = [api_key: "test", format: :flac]

      assert {:error, :unsupported_format} = ValidateConfigMock.validate_config(config)
    end

    test "accepts all supported audio formats" do
      for format <- [:mp3, :wav, :pcm, :ogg] do
        config = [api_key: "test", format: format]
        assert :ok = ValidateConfigMock.validate_config(config)
      end
    end
  end

  describe "contract verification helper" do
    @doc """
    Helper module to verify that a module correctly implements the Provider behaviour.
    This can be used to test custom provider implementations.
    """
    defmodule ContractVerifier do
      @moduledoc """
      Verifies that a module implements the Parrot.TTS.Provider behaviour correctly.

      ## Usage

          assert ContractVerifier.implements_provider?(MyCustomProvider)
          assert ContractVerifier.verify_synthesize_contract(MyCustomProvider, config)
          assert ContractVerifier.verify_list_voices_contract(MyCustomProvider, config)
          assert ContractVerifier.verify_validate_config_contract(MyCustomProvider)
      """

      @doc "Returns true if the module implements the Provider behaviour"
      def implements_provider?(module) do
        behaviours = module.__info__(:attributes)[:behaviour] || []
        Parrot.TTS.Provider in behaviours
      end

      @doc "Verifies synthesize/2 returns correct types"
      def verify_synthesize_contract(module, text, config) do
        result = module.synthesize(text, config)

        case result do
          {:ok, binary} when is_binary(binary) -> :ok
          {:error, reason} when is_atom(reason) or is_binary(reason) -> :ok
          _ -> {:error, {:invalid_return, result}}
        end
      end

      @doc "Verifies list_voices/1 returns correct types"
      def verify_list_voices_contract(module, config) do
        result = module.list_voices(config)

        case result do
          {:ok, voices} when is_list(voices) ->
            if Enum.all?(voices, &valid_voice?/1) do
              :ok
            else
              {:error, :invalid_voice_format}
            end

          {:error, reason} when is_atom(reason) or is_binary(reason) ->
            :ok

          _ ->
            {:error, {:invalid_return, result}}
        end
      end

      @doc "Verifies validate_config/1 returns correct types"
      def verify_validate_config_contract(module, config) do
        result = module.validate_config(config)

        case result do
          :ok -> :ok
          {:error, reason} when is_atom(reason) or is_binary(reason) -> :ok
          _ -> {:error, {:invalid_return, result}}
        end
      end

      defp valid_voice?(voice) when is_map(voice) do
        Map.has_key?(voice, :id) and
          Map.has_key?(voice, :name) and
          Map.has_key?(voice, :language)
      end

      defp valid_voice?(_), do: false
    end

    # Test the verifier itself with our mock
    defmodule CompliantProvider do
      @moduledoc "A fully compliant provider implementation for testing the verifier"
      @behaviour Parrot.TTS.Provider

      @impl true
      def synthesize(_text, _config), do: {:ok, <<1, 2, 3>>}

      @impl true
      def list_voices(_config) do
        {:ok, [%{id: "v1", name: "Voice", language: "en-US"}]}
      end

      @impl true
      def validate_config(_config), do: :ok
    end

    test "ContractVerifier.implements_provider?/1 returns true for compliant module" do
      assert ContractVerifier.implements_provider?(CompliantProvider)
    end

    test "ContractVerifier.verify_synthesize_contract/3 passes for valid returns" do
      assert :ok = ContractVerifier.verify_synthesize_contract(CompliantProvider, "test", [])
    end

    test "ContractVerifier.verify_list_voices_contract/2 passes for valid returns" do
      assert :ok = ContractVerifier.verify_list_voices_contract(CompliantProvider, [])
    end

    test "ContractVerifier.verify_validate_config_contract/2 passes for valid returns" do
      assert :ok = ContractVerifier.verify_validate_config_contract(CompliantProvider, [])
    end
  end

  describe "full provider implementation test" do
    defmodule FullMockProvider do
      @moduledoc """
      A complete mock TTS provider that demonstrates all expected behaviors.
      This serves as a reference implementation for the behaviour contract.
      """
      @behaviour Parrot.TTS.Provider

      # Simulated audio data (WAV header)
      @wav_header <<0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45>>

      @impl true
      def synthesize(text, config) when is_binary(text) do
        # Validate we have required config
        case validate_config(config) do
          :ok ->
            # Simulate synthesis - in real impl, this would call the TTS API
            audio = @wav_header <> <<0::size(byte_size(text) * 8)>>
            {:ok, audio}

          error ->
            error
        end
      end

      def synthesize(_text, _config) do
        {:error, :invalid_text_type}
      end

      @impl true
      def list_voices(config) do
        case Keyword.get(config, :api_key) do
          nil ->
            {:error, :missing_api_key}

          _key ->
            {:ok,
             [
               %{id: "alloy", name: "Alloy", language: "en-US", gender: "neutral"},
               %{id: "echo", name: "Echo", language: "en-US", gender: "male"},
               %{id: "fable", name: "Fable", language: "en-US", gender: "female"},
               %{id: "onyx", name: "Onyx", language: "en-US", gender: "male"},
               %{id: "nova", name: "Nova", language: "en-US", gender: "female"},
               %{id: "shimmer", name: "Shimmer", language: "en-US", gender: "female"}
             ]}
        end
      end

      @impl true
      def validate_config(config) do
        cond do
          not Keyword.keyword?(config) ->
            {:error, :config_must_be_keyword_list}

          not Keyword.has_key?(config, :api_key) ->
            {:error, :missing_api_key}

          not is_binary(Keyword.get(config, :api_key)) ->
            {:error, :api_key_must_be_string}

          true ->
            :ok
        end
      end
    end

    test "implements all required callbacks" do
      callbacks = FullMockProvider.__info__(:functions)

      assert {:synthesize, 2} in callbacks
      assert {:list_voices, 1} in callbacks
      assert {:validate_config, 1} in callbacks
    end

    test "synthesize/2 produces audio binary for valid input" do
      config = [api_key: "test-key-12345"]

      {:ok, audio} = FullMockProvider.synthesize("Hello, world!", config)

      assert is_binary(audio)
      # Should start with WAV RIFF header
      assert <<0x52, 0x49, 0x46, 0x46, _rest::binary>> = audio
    end

    test "synthesize/2 fails for invalid config" do
      config = [voice: "alloy"]

      assert {:error, :missing_api_key} = FullMockProvider.synthesize("Hello", config)
    end

    test "synthesize/2 rejects non-string text" do
      config = [api_key: "test-key"]

      assert {:error, :invalid_text_type} = FullMockProvider.synthesize(123, config)
    end

    test "list_voices/1 returns all available voices with metadata" do
      config = [api_key: "test-key"]

      {:ok, voices} = FullMockProvider.list_voices(config)

      assert length(voices) == 6

      for voice <- voices do
        assert is_binary(voice.id)
        assert is_binary(voice.name)
        assert is_binary(voice.language)
      end
    end

    test "list_voices/1 fails without api_key" do
      assert {:error, :missing_api_key} = FullMockProvider.list_voices([])
    end

    test "validate_config/1 accepts valid config" do
      config = [api_key: "sk-12345", voice: "alloy", model: "tts-1"]

      assert :ok = FullMockProvider.validate_config(config)
    end

    test "validate_config/1 rejects non-keyword-list config" do
      assert {:error, :config_must_be_keyword_list} = FullMockProvider.validate_config(%{})
    end

    test "validate_config/1 rejects non-string api_key" do
      config = [api_key: 12345]

      assert {:error, :api_key_must_be_string} = FullMockProvider.validate_config(config)
    end
  end
end
