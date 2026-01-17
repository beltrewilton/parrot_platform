defmodule Parrot.TTS.Providers.OpenAITest do
  @moduledoc """
  Tests for the OpenAI TTS provider implementation.

  These tests verify that the OpenAI provider correctly:
  - Validates configuration (api_key, voice, model)
  - Synthesizes text to audio via the OpenAI API
  - Lists available voices (static list for OpenAI)
  - Handles various API errors appropriately

  ## TDD Note

  These tests are written BEFORE the OpenAI provider implementation exists.
  They will fail initially (red phase) and guide the implementation (green phase).

  ## OpenAI TTS API Reference

  - Endpoint: POST https://api.openai.com/v1/audio/speech
  - Headers: Authorization: Bearer $OPENAI_API_KEY, Content-Type: application/json
  - Body: {"model": "tts-1", "input": "text", "voice": "alloy", "response_format": "mp3"}
  - Response: Binary audio data in the specified format
  - Voices: alloy, echo, fable, onyx, nova, shimmer
  - Models: tts-1 (speed), tts-1-hd (quality)
  - Formats: mp3, opus, aac, flac, wav, pcm
  """
  use ExUnit.Case, async: true

  # The module under test - will not exist until implementation phase
  alias Parrot.TTS.Providers.OpenAI

  # OpenAI API constants for tests
  @openai_api_url "https://api.openai.com/v1/audio/speech"
  @valid_voices ~w(alloy echo fable onyx nova shimmer)
  @valid_models ~w(tts-1 tts-1-hd)
  @valid_formats ~w(mp3 opus aac flac wav pcm)a

  describe "validate_config/1" do
    test "returns :ok for valid config with api_key, voice, and model" do
      config = [
        api_key: "sk-test-12345678901234567890123456789012",
        voice: "alloy",
        model: "tts-1"
      ]

      assert :ok = OpenAI.validate_config(config)
    end

    test "returns :ok for minimal valid config with only api_key" do
      config = [api_key: "sk-test-key"]

      assert :ok = OpenAI.validate_config(config)
    end

    test "returns :ok for config with all supported options" do
      config = [
        api_key: "sk-test-key",
        voice: "nova",
        model: "tts-1-hd",
        format: :mp3,
        speed: 1.0
      ]

      assert :ok = OpenAI.validate_config(config)
    end

    test "returns error for missing api_key" do
      config = [voice: "alloy", model: "tts-1"]

      assert {:error, :missing_api_key} = OpenAI.validate_config(config)
    end

    test "returns error for empty api_key" do
      config = [api_key: ""]

      assert {:error, :empty_api_key} = OpenAI.validate_config(config)
    end

    test "returns error for nil api_key" do
      config = [api_key: nil]

      assert {:error, :nil_api_key} = OpenAI.validate_config(config)
    end

    test "returns error for non-string api_key" do
      config = [api_key: 12345]

      assert {:error, :api_key_must_be_string} = OpenAI.validate_config(config)
    end

    test "returns error for invalid voice" do
      config = [api_key: "sk-test-key", voice: "invalid_voice"]

      assert {:error, {:invalid_voice, "invalid_voice"}} = OpenAI.validate_config(config)
    end

    test "returns error for non-string voice" do
      config = [api_key: "sk-test-key", voice: 123]

      assert {:error, :voice_must_be_string} = OpenAI.validate_config(config)
    end

    test "accepts all valid OpenAI voices" do
      for voice <- @valid_voices do
        config = [api_key: "sk-test-key", voice: voice]
        assert :ok = OpenAI.validate_config(config), "Expected voice #{voice} to be valid"
      end
    end

    test "returns error for invalid model" do
      config = [api_key: "sk-test-key", model: "invalid-model"]

      assert {:error, {:invalid_model, "invalid-model"}} = OpenAI.validate_config(config)
    end

    test "returns error for non-string model" do
      config = [api_key: "sk-test-key", model: 123]

      assert {:error, :model_must_be_string} = OpenAI.validate_config(config)
    end

    test "accepts all valid OpenAI models" do
      for model <- @valid_models do
        config = [api_key: "sk-test-key", model: model]
        assert :ok = OpenAI.validate_config(config), "Expected model #{model} to be valid"
      end
    end

    test "returns error for invalid format" do
      config = [api_key: "sk-test-key", format: :invalid_format]

      assert {:error, {:invalid_format, :invalid_format}} = OpenAI.validate_config(config)
    end

    test "accepts all valid OpenAI formats" do
      for format <- @valid_formats do
        config = [api_key: "sk-test-key", format: format]
        assert :ok = OpenAI.validate_config(config), "Expected format #{format} to be valid"
      end
    end

    test "returns error for speed outside valid range (0.25-4.0)" do
      # Too slow
      config_slow = [api_key: "sk-test-key", speed: 0.1]
      assert {:error, {:invalid_speed, 0.1}} = OpenAI.validate_config(config_slow)

      # Too fast
      config_fast = [api_key: "sk-test-key", speed: 5.0]
      assert {:error, {:invalid_speed, 5.0}} = OpenAI.validate_config(config_fast)
    end

    test "accepts valid speed values" do
      for speed <- [0.25, 0.5, 1.0, 2.0, 4.0] do
        config = [api_key: "sk-test-key", speed: speed]
        assert :ok = OpenAI.validate_config(config), "Expected speed #{speed} to be valid"
      end
    end

    test "returns error for non-keyword-list config" do
      assert {:error, :config_must_be_keyword_list} = OpenAI.validate_config(%{api_key: "test"})
      assert {:error, :config_must_be_keyword_list} = OpenAI.validate_config("invalid")
    end
  end

  describe "synthesize/2 - successful synthesis" do
    setup do
      # Set up Req.Test stub for this test
      stub_name = :"openai_test_#{System.unique_integer([:positive])}"

      %{stub_name: stub_name}
    end

    test "returns {:ok, binary, :mp3} on successful synthesis", %{stub_name: stub_name} do
      # Simulate successful OpenAI API response with MP3 audio data
      # MP3 files start with ID3 tag or sync word (0xFF 0xFB)
      fake_mp3_audio = <<0xFF, 0xFB, 0x90, 0x00>> <> :crypto.strong_rand_bytes(100)

      Req.Test.stub(stub_name, fn conn ->
        # Verify request format
        assert conn.method == "POST"
        assert conn.request_path == "/v1/audio/speech"

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_mp3_audio)
      end)

      config = [
        api_key: "sk-test-key",
        voice: "alloy",
        model: "tts-1",
        format: :mp3,
        # Use stub for testing
        plug: {Req.Test, stub_name}
      ]

      result = OpenAI.synthesize("Hello, world!", config)

      assert {:ok, audio_data} = result
      assert is_binary(audio_data)
      assert byte_size(audio_data) > 0
    end

    test "sends correct request body to OpenAI API", %{stub_name: stub_name} do
      test_pid = self()

      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)

        # Capture request details for assertion
        send(test_pid, {:request_body, decoded_body})

        fake_audio = :crypto.strong_rand_bytes(50)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        api_key: "sk-test-key",
        voice: "nova",
        model: "tts-1-hd",
        format: :mp3,
        speed: 1.5,
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = OpenAI.synthesize("Test text", config)

      assert_receive {:request_body, body}
      assert body["input"] == "Test text"
      assert body["voice"] == "nova"
      assert body["model"] == "tts-1-hd"
      assert body["response_format"] == "mp3"
      assert body["speed"] == 1.5
    end

    test "sends correct authorization header", %{stub_name: stub_name} do
      test_pid = self()

      Req.Test.stub(stub_name, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:auth_header, auth_header})

        fake_audio = :crypto.strong_rand_bytes(50)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        api_key: "sk-my-secret-api-key",
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = OpenAI.synthesize("Hello", config)

      assert_receive {:auth_header, [auth_value]}
      assert auth_value == "Bearer sk-my-secret-api-key"
    end

    test "uses default voice and model when not specified", %{stub_name: stub_name} do
      test_pid = self()

      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)
        send(test_pid, {:request_body, decoded_body})

        fake_audio = :crypto.strong_rand_bytes(50)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        api_key: "sk-test-key",
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = OpenAI.synthesize("Hello", config)

      assert_receive {:request_body, body}
      # Default voice should be "alloy"
      assert body["voice"] == "alloy"
      # Default model should be "tts-1"
      assert body["model"] == "tts-1"
      # Default format should be "mp3"
      assert body["response_format"] == "mp3"
    end

    test "returns different format when specified", %{stub_name: stub_name} do
      # Test with WAV format
      fake_wav_audio = <<"RIFF", 0::32-little, "WAVE">> <> :crypto.strong_rand_bytes(100)

      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("audio/wav")
        |> Plug.Conn.send_resp(200, fake_wav_audio)
      end)

      config = [
        api_key: "sk-test-key",
        format: :wav,
        plug: {Req.Test, stub_name}
      ]

      {:ok, audio_data} = OpenAI.synthesize("Hello", config)

      assert is_binary(audio_data)
      # WAV files start with "RIFF"
      assert <<"RIFF", _rest::binary>> = audio_data
    end
  end

  describe "synthesize/2 - API errors" do
    setup do
      stub_name = :"openai_error_test_#{System.unique_integer([:positive])}"
      %{stub_name: stub_name}
    end

    test "returns {:error, :invalid_api_key} on 401 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "error" => %{
              "message" => "Incorrect API key provided",
              "type" => "invalid_request_error",
              "code" => "invalid_api_key"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, error_body)
      end)

      config = [
        api_key: "sk-invalid-key",
        plug: {Req.Test, stub_name}
      ]

      result = OpenAI.synthesize("Hello", config)

      assert {:error, :invalid_api_key} = result
    end

    test "returns {:error, :rate_limited} on 429 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "error" => %{
              "message" => "Rate limit exceeded",
              "type" => "rate_limit_error"
            }
          })

        conn
        |> Plug.Conn.put_resp_header("retry-after", "60")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, error_body)
      end)

      config = [
        api_key: "sk-test-key",
        plug: {Req.Test, stub_name}
      ]

      result = OpenAI.synthesize("Hello", config)

      assert {:error, :rate_limited} = result
    end

    test "returns {:error, :api_error} on 500 server error", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "error" => %{
              "message" => "Internal server error",
              "type" => "server_error"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, error_body)
      end)

      config = [
        api_key: "sk-test-key",
        plug: {Req.Test, stub_name}
      ]

      result = OpenAI.synthesize("Hello", config)

      assert {:error, :api_error} = result
    end

    test "returns {:error, :api_error} on 503 service unavailable", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"error": {"message": "Service unavailable"}}))
      end)

      config = [
        api_key: "sk-test-key",
        plug: {Req.Test, stub_name}
      ]

      result = OpenAI.synthesize("Hello", config)

      assert {:error, :api_error} = result
    end

    test "returns {:error, :bad_request} on 400 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "error" => %{
              "message" => "Invalid request body",
              "type" => "invalid_request_error"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, error_body)
      end)

      config = [
        api_key: "sk-test-key",
        plug: {Req.Test, stub_name}
      ]

      result = OpenAI.synthesize("Hello", config)

      assert {:error, :bad_request} = result
    end

    test "returns {:error, :insufficient_quota} on 402 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "error" => %{
              "message" =>
                "You exceeded your current quota, please check your plan and billing details",
              "type" => "insufficient_quota"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(402, error_body)
      end)

      config = [
        api_key: "sk-test-key",
        plug: {Req.Test, stub_name}
      ]

      result = OpenAI.synthesize("Hello", config)

      assert {:error, :insufficient_quota} = result
    end
  end

  describe "synthesize/2 - timeout errors" do
    setup do
      stub_name = :"openai_timeout_test_#{System.unique_integer([:positive])}"
      %{stub_name: stub_name}
    end

    test "returns {:error, :timeout} on connection timeout", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      config = [
        api_key: "sk-test-key",
        plug: {Req.Test, stub_name}
      ]

      result = OpenAI.synthesize("Hello", config)

      assert {:error, :timeout} = result
    end

    test "returns {:error, :connection_refused} on connection refused", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      config = [
        api_key: "sk-test-key",
        plug: {Req.Test, stub_name}
      ]

      result = OpenAI.synthesize("Hello", config)

      assert {:error, :connection_refused} = result
    end

    test "returns {:error, :network_error} on other transport errors", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      config = [
        api_key: "sk-test-key",
        plug: {Req.Test, stub_name}
      ]

      result = OpenAI.synthesize("Hello", config)

      assert {:error, :network_error} = result
    end
  end

  describe "synthesize/2 - input validation" do
    test "returns {:error, :empty_text} for empty string" do
      config = [api_key: "sk-test-key"]

      result = OpenAI.synthesize("", config)

      assert {:error, :empty_text} = result
    end

    test "returns {:error, :invalid_text_type} for non-string input" do
      config = [api_key: "sk-test-key"]

      assert {:error, :invalid_text_type} = OpenAI.synthesize(123, config)
      assert {:error, :invalid_text_type} = OpenAI.synthesize(nil, config)
      assert {:error, :invalid_text_type} = OpenAI.synthesize(~c"list", config)
    end

    test "returns config validation error when config is invalid" do
      # Missing api_key
      config = [voice: "alloy"]

      result = OpenAI.synthesize("Hello", config)

      assert {:error, :missing_api_key} = result
    end

    test "handles text with special characters" do
      stub_name = :"openai_special_chars_#{System.unique_integer([:positive])}"

      Req.Test.stub(stub_name, fn conn ->
        fake_audio = :crypto.strong_rand_bytes(50)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        api_key: "sk-test-key",
        plug: {Req.Test, stub_name}
      ]

      # Text with special characters, unicode, and newlines
      special_text = "Hello, world! \n\t\"Quoted text\" & <special> chars: \u00e9\u00e8\u00e0"

      result = OpenAI.synthesize(special_text, config)

      assert {:ok, _audio} = result
    end

    test "handles long text input" do
      stub_name = :"openai_long_text_#{System.unique_integer([:positive])}"

      Req.Test.stub(stub_name, fn conn ->
        fake_audio = :crypto.strong_rand_bytes(1000)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        api_key: "sk-test-key",
        plug: {Req.Test, stub_name}
      ]

      # Generate 4KB of text (OpenAI has a 4096 char limit)
      long_text = String.duplicate("Hello world. ", 300)

      result = OpenAI.synthesize(long_text, config)

      assert {:ok, _audio} = result
    end
  end

  describe "list_voices/1" do
    test "returns list of available OpenAI voices" do
      config = [api_key: "sk-test-key"]

      result = OpenAI.list_voices(config)

      assert {:ok, voices} = result
      assert is_list(voices)
      assert length(voices) == 6
    end

    test "each voice has required fields (id, name, language)" do
      config = [api_key: "sk-test-key"]

      {:ok, voices} = OpenAI.list_voices(config)

      for voice <- voices do
        assert Map.has_key?(voice, :id)
        assert Map.has_key?(voice, :name)
        assert Map.has_key?(voice, :language)
        assert is_binary(voice.id)
        assert is_binary(voice.name)
        assert is_binary(voice.language)
      end
    end

    test "returns all expected OpenAI voice IDs" do
      config = [api_key: "sk-test-key"]

      {:ok, voices} = OpenAI.list_voices(config)

      voice_ids = Enum.map(voices, & &1.id)

      for expected_voice <- @valid_voices do
        assert expected_voice in voice_ids,
               "Expected voice '#{expected_voice}' to be in list"
      end
    end

    test "voices have language set to en-US (OpenAI voices are English)" do
      config = [api_key: "sk-test-key"]

      {:ok, voices} = OpenAI.list_voices(config)

      for voice <- voices do
        # OpenAI TTS voices are primarily English (though they can speak other languages)
        assert voice.language == "en-US"
      end
    end

    test "works without making API call (static list)" do
      # Even with invalid API key, should return static voice list
      # because OpenAI voice list is known and doesn't require API call
      config = [api_key: "sk-test-key"]

      result = OpenAI.list_voices(config)

      assert {:ok, voices} = result
      assert length(voices) == 6
    end

    test "includes optional description field for voices" do
      config = [api_key: "sk-test-key"]

      {:ok, voices} = OpenAI.list_voices(config)

      # Voices may optionally include descriptions
      # At minimum, verify the structure is correct
      for voice <- voices do
        if Map.has_key?(voice, :description) do
          assert is_binary(voice.description)
        end
      end
    end

    test "returns error for missing api_key" do
      # Even for static list, we should validate config
      config = []

      result = OpenAI.list_voices(config)

      assert {:error, :missing_api_key} = result
    end
  end

  describe "implementation of Provider behaviour" do
    test "module implements Parrot.TTS.Provider behaviour" do
      behaviours = OpenAI.__info__(:attributes)[:behaviour] || []

      assert Parrot.TTS.Provider in behaviours
    end

    test "exports synthesize/2 function" do
      Code.ensure_loaded!(OpenAI)
      assert function_exported?(OpenAI, :synthesize, 2)
    end

    test "exports list_voices/1 function" do
      Code.ensure_loaded!(OpenAI)
      assert function_exported?(OpenAI, :list_voices, 1)
    end

    test "exports validate_config/1 function" do
      Code.ensure_loaded!(OpenAI)
      assert function_exported?(OpenAI, :validate_config, 1)
    end
  end

  describe "module constants and configuration" do
    test "defines correct API URL constant" do
      # The module should use the correct OpenAI TTS endpoint
      assert OpenAI.api_url() == @openai_api_url
    end

    test "defines list of valid voices" do
      valid_voices = OpenAI.valid_voices()

      assert is_list(valid_voices)
      assert length(valid_voices) == 6

      for voice <- @valid_voices do
        assert voice in valid_voices
      end
    end

    test "defines list of valid models" do
      valid_models = OpenAI.valid_models()

      assert is_list(valid_models)
      assert "tts-1" in valid_models
      assert "tts-1-hd" in valid_models
    end

    test "defines default configuration values" do
      defaults = OpenAI.defaults()

      assert defaults[:voice] == "alloy"
      assert defaults[:model] == "tts-1"
      assert defaults[:format] == :mp3
      assert defaults[:speed] == 1.0
    end
  end
end
