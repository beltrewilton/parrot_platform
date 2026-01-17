defmodule Parrot.TTS.Providers.ElevenLabsTest do
  @moduledoc """
  Tests for the ElevenLabs TTS provider implementation.

  These tests verify that the ElevenLabs provider correctly:
  - Validates configuration (api_key, voice_id, model_id)
  - Synthesizes text to audio via the ElevenLabs API
  - Lists available voices (static list of popular voices)
  - Handles various API errors appropriately

  ## ElevenLabs TTS API Reference

  - Endpoint: POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}
  - Headers: xi-api-key: $ELEVENLABS_API_KEY, Content-Type: application/json
  - Body: {"text": "text", "model_id": "eleven_monolingual_v1", "voice_settings": {...}}
  - Response: Binary audio data (mp3 by default)
  - Models: eleven_monolingual_v1, eleven_multilingual_v1, eleven_multilingual_v2, eleven_turbo_v2
  - Formats: mp3_44100_128, mp3_44100_64, pcm_16000, pcm_22050, pcm_24000, pcm_44100
  """
  use ExUnit.Case, async: true

  alias Parrot.TTS.Providers.ElevenLabs

  # ElevenLabs API constants for tests
  @elevenlabs_api_base "https://api.elevenlabs.io"
  @valid_models ~w(eleven_monolingual_v1 eleven_multilingual_v1 eleven_multilingual_v2 eleven_turbo_v2)
  @valid_formats ~w(mp3_44100_128 mp3_44100_64 pcm_16000 pcm_22050 pcm_24000 pcm_44100)a

  # Popular voices used in ElevenLabs
  @popular_voices ~w(rachel domi bella antoni elli josh arnold adam sam)

  describe "validate_config/1" do
    test "returns :ok for valid config with api_key and voice_id" do
      config = [
        api_key: "test-api-key-12345",
        voice_id: "21m00Tcm4TlvDq8ikWAM"
      ]

      assert :ok = ElevenLabs.validate_config(config)
    end

    test "returns :ok for minimal valid config with only api_key" do
      config = [api_key: "test-api-key"]

      assert :ok = ElevenLabs.validate_config(config)
    end

    test "returns :ok for config with all supported options" do
      config = [
        api_key: "test-api-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        model_id: "eleven_multilingual_v2",
        output_format: :mp3_44100_128,
        stability: 0.5,
        similarity_boost: 0.75
      ]

      assert :ok = ElevenLabs.validate_config(config)
    end

    test "returns error for missing api_key" do
      config = [voice_id: "21m00Tcm4TlvDq8ikWAM"]

      assert {:error, :missing_api_key} = ElevenLabs.validate_config(config)
    end

    test "returns error for empty api_key" do
      config = [api_key: ""]

      assert {:error, :empty_api_key} = ElevenLabs.validate_config(config)
    end

    test "returns error for nil api_key" do
      config = [api_key: nil]

      assert {:error, :nil_api_key} = ElevenLabs.validate_config(config)
    end

    test "returns error for non-string api_key" do
      config = [api_key: 12345]

      assert {:error, :api_key_must_be_string} = ElevenLabs.validate_config(config)
    end

    test "returns error for non-string voice_id" do
      config = [api_key: "test-key", voice_id: 123]

      assert {:error, :voice_id_must_be_string} = ElevenLabs.validate_config(config)
    end

    test "returns error for invalid model_id" do
      config = [api_key: "test-key", model_id: "invalid_model"]

      assert {:error, {:invalid_model_id, "invalid_model"}} = ElevenLabs.validate_config(config)
    end

    test "returns error for non-string model_id" do
      config = [api_key: "test-key", model_id: 123]

      assert {:error, :model_id_must_be_string} = ElevenLabs.validate_config(config)
    end

    test "accepts all valid ElevenLabs models" do
      for model <- @valid_models do
        config = [api_key: "test-key", model_id: model]
        assert :ok = ElevenLabs.validate_config(config), "Expected model #{model} to be valid"
      end
    end

    test "returns error for invalid output_format" do
      config = [api_key: "test-key", output_format: :invalid_format]

      assert {:error, {:invalid_output_format, :invalid_format}} = ElevenLabs.validate_config(config)
    end

    test "accepts all valid ElevenLabs output formats" do
      for format <- @valid_formats do
        config = [api_key: "test-key", output_format: format]
        assert :ok = ElevenLabs.validate_config(config), "Expected format #{format} to be valid"
      end
    end

    test "returns error for stability outside valid range (0.0-1.0)" do
      # Too low
      config_low = [api_key: "test-key", stability: -0.1]
      assert {:error, {:invalid_stability, -0.1}} = ElevenLabs.validate_config(config_low)

      # Too high
      config_high = [api_key: "test-key", stability: 1.5]
      assert {:error, {:invalid_stability, 1.5}} = ElevenLabs.validate_config(config_high)
    end

    test "accepts valid stability values" do
      for stability <- [0.0, 0.25, 0.5, 0.75, 1.0] do
        config = [api_key: "test-key", stability: stability]
        assert :ok = ElevenLabs.validate_config(config), "Expected stability #{stability} to be valid"
      end
    end

    test "returns error for similarity_boost outside valid range (0.0-1.0)" do
      # Too low
      config_low = [api_key: "test-key", similarity_boost: -0.1]
      assert {:error, {:invalid_similarity_boost, -0.1}} = ElevenLabs.validate_config(config_low)

      # Too high
      config_high = [api_key: "test-key", similarity_boost: 1.5]
      assert {:error, {:invalid_similarity_boost, 1.5}} = ElevenLabs.validate_config(config_high)
    end

    test "accepts valid similarity_boost values" do
      for boost <- [0.0, 0.25, 0.5, 0.75, 1.0] do
        config = [api_key: "test-key", similarity_boost: boost]
        assert :ok = ElevenLabs.validate_config(config), "Expected similarity_boost #{boost} to be valid"
      end
    end

    test "returns error for non-keyword-list config" do
      assert {:error, :config_must_be_keyword_list} = ElevenLabs.validate_config(%{api_key: "test"})
      assert {:error, :config_must_be_keyword_list} = ElevenLabs.validate_config("invalid")
    end
  end

  describe "synthesize/2 - successful synthesis" do
    setup do
      stub_name = :"elevenlabs_test_#{System.unique_integer([:positive])}"
      %{stub_name: stub_name}
    end

    test "returns {:ok, binary} on successful synthesis", %{stub_name: stub_name} do
      # Simulate successful ElevenLabs API response with MP3 audio data
      fake_mp3_audio = <<0xFF, 0xFB, 0x90, 0x00>> <> :crypto.strong_rand_bytes(100)

      Req.Test.stub(stub_name, fn conn ->
        # Verify request format
        assert conn.method == "POST"
        assert String.starts_with?(conn.request_path, "/v1/text-to-speech/")

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_mp3_audio)
      end)

      config = [
        api_key: "test-api-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        model_id: "eleven_monolingual_v1",
        plug: {Req.Test, stub_name}
      ]

      result = ElevenLabs.synthesize("Hello, world!", config)

      assert {:ok, audio_data} = result
      assert is_binary(audio_data)
      assert byte_size(audio_data) > 0
    end

    test "sends correct request body to ElevenLabs API", %{stub_name: stub_name} do
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
        api_key: "test-api-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        model_id: "eleven_multilingual_v2",
        stability: 0.5,
        similarity_boost: 0.8,
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = ElevenLabs.synthesize("Test text", config)

      assert_receive {:request_body, body}
      assert body["text"] == "Test text"
      assert body["model_id"] == "eleven_multilingual_v2"
      assert body["voice_settings"]["stability"] == 0.5
      assert body["voice_settings"]["similarity_boost"] == 0.8
    end

    test "sends correct api key header", %{stub_name: stub_name} do
      test_pid = self()

      Req.Test.stub(stub_name, fn conn ->
        api_key_header = Plug.Conn.get_req_header(conn, "xi-api-key")
        send(test_pid, {:api_key_header, api_key_header})

        fake_audio = :crypto.strong_rand_bytes(50)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        api_key: "my-secret-elevenlabs-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = ElevenLabs.synthesize("Hello", config)

      assert_receive {:api_key_header, [key_value]}
      assert key_value == "my-secret-elevenlabs-key"
    end

    test "uses default voice_id and model_id when not specified", %{stub_name: stub_name} do
      test_pid = self()

      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)
        send(test_pid, {:request_body, decoded_body})
        send(test_pid, {:path, conn.request_path})

        fake_audio = :crypto.strong_rand_bytes(50)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        api_key: "test-key",
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = ElevenLabs.synthesize("Hello", config)

      assert_receive {:request_body, body}
      assert_receive {:path, path}

      # Default model should be eleven_monolingual_v1
      assert body["model_id"] == "eleven_monolingual_v1"
      # Default voice_id should be "rachel" voice ID
      assert String.contains?(path, "/v1/text-to-speech/")
    end

    test "uses output_format query parameter when specified", %{stub_name: stub_name} do
      test_pid = self()

      Req.Test.stub(stub_name, fn conn ->
        send(test_pid, {:query_string, conn.query_string})

        fake_audio = :crypto.strong_rand_bytes(50)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        api_key: "test-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        output_format: :pcm_16000,
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = ElevenLabs.synthesize("Hello", config)

      assert_receive {:query_string, query_string}
      assert String.contains?(query_string, "output_format=pcm_16000")
    end
  end

  describe "synthesize/2 - API errors" do
    setup do
      stub_name = :"elevenlabs_error_test_#{System.unique_integer([:positive])}"
      %{stub_name: stub_name}
    end

    test "returns {:error, :invalid_api_key} on 401 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "detail" => %{
              "status" => "invalid_api_key",
              "message" => "Invalid API key"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, error_body)
      end)

      config = [
        api_key: "invalid-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        plug: {Req.Test, stub_name}
      ]

      result = ElevenLabs.synthesize("Hello", config)

      assert {:error, :invalid_api_key} = result
    end

    test "returns {:error, :rate_limited} on 429 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "detail" => %{
              "status" => "rate_limit_exceeded",
              "message" => "Rate limit exceeded"
            }
          })

        conn
        |> Plug.Conn.put_resp_header("retry-after", "60")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, error_body)
      end)

      config = [
        api_key: "test-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        plug: {Req.Test, stub_name}
      ]

      result = ElevenLabs.synthesize("Hello", config)

      assert {:error, :rate_limited} = result
    end

    test "returns {:error, :api_error} on 500 server error", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "detail" => %{
              "status" => "server_error",
              "message" => "Internal server error"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, error_body)
      end)

      config = [
        api_key: "test-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        plug: {Req.Test, stub_name}
      ]

      result = ElevenLabs.synthesize("Hello", config)

      assert {:error, :api_error} = result
    end

    test "returns {:error, :bad_request} on 400 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "detail" => %{
              "status" => "bad_request",
              "message" => "Invalid request body"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, error_body)
      end)

      config = [
        api_key: "test-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        plug: {Req.Test, stub_name}
      ]

      result = ElevenLabs.synthesize("Hello", config)

      assert {:error, :bad_request} = result
    end

    test "returns {:error, :quota_exceeded} on 402 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "detail" => %{
              "status" => "quota_exceeded",
              "message" => "Quota exceeded for today"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(402, error_body)
      end)

      config = [
        api_key: "test-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        plug: {Req.Test, stub_name}
      ]

      result = ElevenLabs.synthesize("Hello", config)

      assert {:error, :quota_exceeded} = result
    end

    test "returns {:error, :voice_not_found} on 404 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "detail" => %{
              "status" => "voice_not_found",
              "message" => "Voice not found"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, error_body)
      end)

      config = [
        api_key: "test-key",
        voice_id: "nonexistent-voice-id",
        plug: {Req.Test, stub_name}
      ]

      result = ElevenLabs.synthesize("Hello", config)

      assert {:error, :voice_not_found} = result
    end
  end

  describe "synthesize/2 - timeout errors" do
    setup do
      stub_name = :"elevenlabs_timeout_test_#{System.unique_integer([:positive])}"
      %{stub_name: stub_name}
    end

    test "returns {:error, :timeout} on connection timeout", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      config = [
        api_key: "test-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        plug: {Req.Test, stub_name}
      ]

      result = ElevenLabs.synthesize("Hello", config)

      assert {:error, :timeout} = result
    end

    test "returns {:error, :connection_refused} on connection refused", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      config = [
        api_key: "test-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        plug: {Req.Test, stub_name}
      ]

      result = ElevenLabs.synthesize("Hello", config)

      assert {:error, :connection_refused} = result
    end

    test "returns {:error, :network_error} on other transport errors", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      config = [
        api_key: "test-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        plug: {Req.Test, stub_name}
      ]

      result = ElevenLabs.synthesize("Hello", config)

      assert {:error, :network_error} = result
    end
  end

  describe "synthesize/2 - input validation" do
    test "returns {:error, :empty_text} for empty string" do
      config = [api_key: "test-key"]

      result = ElevenLabs.synthesize("", config)

      assert {:error, :empty_text} = result
    end

    test "returns {:error, :invalid_text_type} for non-string input" do
      config = [api_key: "test-key"]

      assert {:error, :invalid_text_type} = ElevenLabs.synthesize(123, config)
      assert {:error, :invalid_text_type} = ElevenLabs.synthesize(nil, config)
      assert {:error, :invalid_text_type} = ElevenLabs.synthesize(~c"list", config)
    end

    test "returns config validation error when config is invalid" do
      config = [voice_id: "21m00Tcm4TlvDq8ikWAM"]

      result = ElevenLabs.synthesize("Hello", config)

      assert {:error, :missing_api_key} = result
    end

    test "handles text with special characters", %{} do
      stub_name = :"elevenlabs_special_chars_#{System.unique_integer([:positive])}"

      Req.Test.stub(stub_name, fn conn ->
        fake_audio = :crypto.strong_rand_bytes(50)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        api_key: "test-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        plug: {Req.Test, stub_name}
      ]

      special_text = "Hello, world! \n\t\"Quoted text\" & <special> chars: \u00e9\u00e8\u00e0"

      result = ElevenLabs.synthesize(special_text, config)

      assert {:ok, _audio} = result
    end

    test "handles long text input" do
      stub_name = :"elevenlabs_long_text_#{System.unique_integer([:positive])}"

      Req.Test.stub(stub_name, fn conn ->
        fake_audio = :crypto.strong_rand_bytes(1000)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        api_key: "test-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        plug: {Req.Test, stub_name}
      ]

      long_text = String.duplicate("Hello world. ", 300)

      result = ElevenLabs.synthesize(long_text, config)

      assert {:ok, _audio} = result
    end
  end

  describe "list_voices/1" do
    test "returns list of available ElevenLabs voices" do
      config = [api_key: "test-key"]

      result = ElevenLabs.list_voices(config)

      assert {:ok, voices} = result
      assert is_list(voices)
      assert length(voices) >= 9
    end

    test "each voice has required fields (id, name, language)" do
      config = [api_key: "test-key"]

      {:ok, voices} = ElevenLabs.list_voices(config)

      for voice <- voices do
        assert Map.has_key?(voice, :id)
        assert Map.has_key?(voice, :name)
        assert Map.has_key?(voice, :language)
        assert is_binary(voice.id)
        assert is_binary(voice.name)
        assert is_binary(voice.language)
      end
    end

    test "returns all expected popular voice names" do
      config = [api_key: "test-key"]

      {:ok, voices} = ElevenLabs.list_voices(config)

      voice_names = Enum.map(voices, &String.downcase(&1.name))

      for expected_voice <- @popular_voices do
        assert expected_voice in voice_names,
               "Expected voice '#{expected_voice}' to be in list"
      end
    end

    test "works without making API call (static list)" do
      config = [api_key: "test-key"]

      result = ElevenLabs.list_voices(config)

      assert {:ok, voices} = result
      assert length(voices) >= 9
    end

    test "includes optional description field for voices" do
      config = [api_key: "test-key"]

      {:ok, voices} = ElevenLabs.list_voices(config)

      for voice <- voices do
        if Map.has_key?(voice, :description) do
          assert is_binary(voice.description)
        end
      end
    end

    test "returns error for missing api_key" do
      config = []

      result = ElevenLabs.list_voices(config)

      assert {:error, :missing_api_key} = result
    end
  end

  describe "implementation of Provider behaviour" do
    test "module implements Parrot.TTS.Provider behaviour" do
      behaviours = ElevenLabs.__info__(:attributes)[:behaviour] || []

      assert Parrot.TTS.Provider in behaviours
    end

    test "exports synthesize/2 function" do
      Code.ensure_loaded!(ElevenLabs)
      assert function_exported?(ElevenLabs, :synthesize, 2)
    end

    test "exports list_voices/1 function" do
      Code.ensure_loaded!(ElevenLabs)
      assert function_exported?(ElevenLabs, :list_voices, 1)
    end

    test "exports validate_config/1 function" do
      Code.ensure_loaded!(ElevenLabs)
      assert function_exported?(ElevenLabs, :validate_config, 1)
    end
  end

  describe "module constants and configuration" do
    test "defines correct API base URL constant" do
      assert ElevenLabs.api_base_url() == @elevenlabs_api_base
    end

    test "defines list of valid models" do
      valid_models = ElevenLabs.valid_models()

      assert is_list(valid_models)

      for model <- @valid_models do
        assert model in valid_models
      end
    end

    test "defines list of valid output formats" do
      valid_formats = ElevenLabs.valid_output_formats()

      assert is_list(valid_formats)

      for format <- @valid_formats do
        assert format in valid_formats
      end
    end

    test "defines default configuration values" do
      defaults = ElevenLabs.defaults()

      assert defaults[:model_id] == "eleven_monolingual_v1"
      assert defaults[:output_format] == :mp3_44100_128
      assert defaults[:stability] == 0.5
      assert defaults[:similarity_boost] == 0.75
    end
  end
end
