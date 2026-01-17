defmodule Parrot.TTS.Providers.GoogleTest do
  @moduledoc """
  Tests for the Google Cloud TTS provider implementation.

  These tests verify that the Google provider correctly:
  - Validates configuration (api_key, language_code, voice_name)
  - Synthesizes text to audio via the Google Cloud TTS API
  - Decodes base64-encoded audio responses
  - Lists available voices (static list of Neural2 voices)
  - Handles various API errors appropriately

  ## TDD Note

  These tests are written BEFORE the Google provider implementation exists.
  They will fail initially (red phase) and guide the implementation (green phase).

  ## Google Cloud TTS API Reference

  - Endpoint: POST https://texttospeech.googleapis.com/v1/text:synthesize
  - Headers: Authorization: Bearer $GOOGLE_API_KEY, Content-Type: application/json
  - Body: {"input": {"text": "..."}, "voice": {"languageCode": "en-US", "name": "en-US-Neural2-A"}, "audioConfig": {"audioEncoding": "MP3"}}
  - Response: {"audioContent": "base64-encoded-audio"}
  - Note: Audio is returned as base64 and needs to be decoded
  - Voices: en-US-Neural2-A through en-US-Neural2-J, en-US-Wavenet-A through F, etc.
  - Formats: MP3, LINEAR16, OGG_OPUS, MULAW, ALAW
  """
  use ExUnit.Case, async: true

  # The module under test
  alias Parrot.TTS.Providers.Google

  # Google Cloud TTS API constants for tests
  @google_api_url "https://texttospeech.googleapis.com/v1/text:synthesize"
  @valid_formats ~w(mp3 linear16 ogg_opus mulaw alaw)a

  # Common Neural2 voices used in tests
  @neural2_voices ~w(en-US-Neural2-A en-US-Neural2-C en-US-Neural2-D en-US-Neural2-E
                     en-US-Neural2-F en-US-Neural2-G en-US-Neural2-H en-US-Neural2-I
                     en-US-Neural2-J)

  describe "validate_config/1" do
    test "returns :ok for valid config with api_key and voice_name" do
      config = [
        api_key: "ya29.test-google-api-key",
        language_code: "en-US",
        voice_name: "en-US-Neural2-A"
      ]

      assert :ok = Google.validate_config(config)
    end

    test "returns :ok for minimal valid config with only api_key" do
      config = [api_key: "ya29.test-key"]

      assert :ok = Google.validate_config(config)
    end

    test "returns :ok for config with all supported options" do
      config = [
        api_key: "ya29.test-key",
        language_code: "en-US",
        voice_name: "en-US-Neural2-D",
        format: :mp3,
        speaking_rate: 1.0,
        pitch: 0.0
      ]

      assert :ok = Google.validate_config(config)
    end

    test "returns error for missing api_key" do
      config = [language_code: "en-US", voice_name: "en-US-Neural2-A"]

      assert {:error, :missing_api_key} = Google.validate_config(config)
    end

    test "returns error for empty api_key" do
      config = [api_key: ""]

      assert {:error, :empty_api_key} = Google.validate_config(config)
    end

    test "returns error for nil api_key" do
      config = [api_key: nil]

      assert {:error, :nil_api_key} = Google.validate_config(config)
    end

    test "returns error for non-string api_key" do
      config = [api_key: 12345]

      assert {:error, :api_key_must_be_string} = Google.validate_config(config)
    end

    test "returns error for non-string language_code" do
      config = [api_key: "ya29.test-key", language_code: 123]

      assert {:error, :language_code_must_be_string} = Google.validate_config(config)
    end

    test "returns error for non-string voice_name" do
      config = [api_key: "ya29.test-key", voice_name: 123]

      assert {:error, :voice_name_must_be_string} = Google.validate_config(config)
    end

    test "returns error for invalid format" do
      config = [api_key: "ya29.test-key", format: :invalid_format]

      assert {:error, {:invalid_format, :invalid_format}} = Google.validate_config(config)
    end

    test "accepts all valid Google formats" do
      for format <- @valid_formats do
        config = [api_key: "ya29.test-key", format: format]
        assert :ok = Google.validate_config(config), "Expected format #{format} to be valid"
      end
    end

    test "returns error for speaking_rate outside valid range (0.25-4.0)" do
      # Too slow
      config_slow = [api_key: "ya29.test-key", speaking_rate: 0.1]
      assert {:error, {:invalid_speaking_rate, 0.1}} = Google.validate_config(config_slow)

      # Too fast
      config_fast = [api_key: "ya29.test-key", speaking_rate: 5.0]
      assert {:error, {:invalid_speaking_rate, 5.0}} = Google.validate_config(config_fast)
    end

    test "accepts valid speaking_rate values" do
      for rate <- [0.25, 0.5, 1.0, 2.0, 4.0] do
        config = [api_key: "ya29.test-key", speaking_rate: rate]
        assert :ok = Google.validate_config(config), "Expected speaking_rate #{rate} to be valid"
      end
    end

    test "returns error for pitch outside valid range (-20.0 to 20.0)" do
      # Too low
      config_low = [api_key: "ya29.test-key", pitch: -25.0]
      assert {:error, {:invalid_pitch, -25.0}} = Google.validate_config(config_low)

      # Too high
      config_high = [api_key: "ya29.test-key", pitch: 25.0]
      assert {:error, {:invalid_pitch, 25.0}} = Google.validate_config(config_high)
    end

    test "accepts valid pitch values" do
      for pitch <- [-20.0, -10.0, 0.0, 10.0, 20.0] do
        config = [api_key: "ya29.test-key", pitch: pitch]
        assert :ok = Google.validate_config(config), "Expected pitch #{pitch} to be valid"
      end
    end

    test "returns error for non-keyword-list config" do
      assert {:error, :config_must_be_keyword_list} = Google.validate_config(%{api_key: "test"})
      assert {:error, :config_must_be_keyword_list} = Google.validate_config("invalid")
    end
  end

  describe "synthesize/2 - successful synthesis" do
    setup do
      # Set up Req.Test stub for this test
      stub_name = :"google_test_#{System.unique_integer([:positive])}"

      %{stub_name: stub_name}
    end

    test "returns {:ok, binary} on successful synthesis", %{stub_name: stub_name} do
      # Simulate successful Google Cloud TTS API response with base64-encoded MP3 data
      # MP3 files start with ID3 tag or sync word (0xFF 0xFB)
      fake_mp3_audio = <<0xFF, 0xFB, 0x90, 0x00>> <> :crypto.strong_rand_bytes(100)
      base64_audio = Base.encode64(fake_mp3_audio)

      Req.Test.stub(stub_name, fn conn ->
        # Verify request format
        assert conn.method == "POST"
        assert conn.request_path == "/v1/text:synthesize"

        response_body = Jason.encode!(%{"audioContent" => base64_audio})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, response_body)
      end)

      config = [
        api_key: "ya29.test-key",
        language_code: "en-US",
        voice_name: "en-US-Neural2-A",
        format: :mp3,
        # Use stub for testing
        plug: {Req.Test, stub_name}
      ]

      result = Google.synthesize("Hello, world!", config)

      assert {:ok, audio_data} = result
      assert is_binary(audio_data)
      assert byte_size(audio_data) > 0
      # Verify the audio was decoded from base64
      assert audio_data == fake_mp3_audio
    end

    test "sends correct request body to Google API", %{stub_name: stub_name} do
      test_pid = self()
      fake_audio = Base.encode64(:crypto.strong_rand_bytes(50))

      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)

        # Capture request details for assertion
        send(test_pid, {:request_body, decoded_body})

        response_body = Jason.encode!(%{"audioContent" => fake_audio})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, response_body)
      end)

      config = [
        api_key: "ya29.test-key",
        language_code: "en-US",
        voice_name: "en-US-Neural2-D",
        format: :mp3,
        speaking_rate: 1.5,
        pitch: 2.0,
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = Google.synthesize("Test text", config)

      assert_receive {:request_body, body}
      assert body["input"]["text"] == "Test text"
      assert body["voice"]["languageCode"] == "en-US"
      assert body["voice"]["name"] == "en-US-Neural2-D"
      assert body["audioConfig"]["audioEncoding"] == "MP3"
      assert body["audioConfig"]["speakingRate"] == 1.5
      assert body["audioConfig"]["pitch"] == 2.0
    end

    test "sends correct authorization header", %{stub_name: stub_name} do
      test_pid = self()
      fake_audio = Base.encode64(:crypto.strong_rand_bytes(50))

      Req.Test.stub(stub_name, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:auth_header, auth_header})

        response_body = Jason.encode!(%{"audioContent" => fake_audio})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, response_body)
      end)

      config = [
        api_key: "ya29.my-secret-api-key",
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = Google.synthesize("Hello", config)

      assert_receive {:auth_header, [auth_value]}
      assert auth_value == "Bearer ya29.my-secret-api-key"
    end

    test "uses default language_code and voice_name when not specified", %{stub_name: stub_name} do
      test_pid = self()
      fake_audio = Base.encode64(:crypto.strong_rand_bytes(50))

      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)
        send(test_pid, {:request_body, decoded_body})

        response_body = Jason.encode!(%{"audioContent" => fake_audio})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, response_body)
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = Google.synthesize("Hello", config)

      assert_receive {:request_body, body}
      # Default language_code should be "en-US"
      assert body["voice"]["languageCode"] == "en-US"
      # Default voice_name should be "en-US-Neural2-C"
      assert body["voice"]["name"] == "en-US-Neural2-C"
      # Default format should be "MP3"
      assert body["audioConfig"]["audioEncoding"] == "MP3"
    end

    test "returns different format when specified", %{stub_name: stub_name} do
      # Test with LINEAR16 (WAV) format
      fake_wav_audio = <<"RIFF", 0::32-little, "WAVE">> <> :crypto.strong_rand_bytes(100)
      base64_audio = Base.encode64(fake_wav_audio)

      Req.Test.stub(stub_name, fn conn ->
        response_body = Jason.encode!(%{"audioContent" => base64_audio})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, response_body)
      end)

      config = [
        api_key: "ya29.test-key",
        format: :linear16,
        plug: {Req.Test, stub_name}
      ]

      {:ok, audio_data} = Google.synthesize("Hello", config)

      assert is_binary(audio_data)
      # Decoded audio should start with "RIFF"
      assert <<"RIFF", _rest::binary>> = audio_data
    end

    test "decodes base64 audioContent correctly", %{stub_name: stub_name} do
      # Create a known binary pattern
      original_audio = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
      base64_audio = Base.encode64(original_audio)

      Req.Test.stub(stub_name, fn conn ->
        response_body = Jason.encode!(%{"audioContent" => base64_audio})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, response_body)
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      {:ok, audio_data} = Google.synthesize("Hello", config)

      assert audio_data == original_audio
    end
  end

  describe "synthesize/2 - API errors" do
    setup do
      stub_name = :"google_error_test_#{System.unique_integer([:positive])}"
      %{stub_name: stub_name}
    end

    test "returns {:error, :invalid_api_key} on 401 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "error" => %{
              "message" => "Request had invalid authentication credentials",
              "code" => 401,
              "status" => "UNAUTHENTICATED"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, error_body)
      end)

      config = [
        api_key: "invalid-key",
        plug: {Req.Test, stub_name}
      ]

      result = Google.synthesize("Hello", config)

      assert {:error, :invalid_api_key} = result
    end

    test "returns {:error, :forbidden} on 403 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "error" => %{
              "message" => "Cloud Text-to-Speech API has not been enabled",
              "code" => 403,
              "status" => "PERMISSION_DENIED"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, error_body)
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      result = Google.synthesize("Hello", config)

      assert {:error, :forbidden} = result
    end

    test "returns {:error, :rate_limited} on 429 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "error" => %{
              "message" => "Resource has been exhausted",
              "code" => 429,
              "status" => "RESOURCE_EXHAUSTED"
            }
          })

        conn
        |> Plug.Conn.put_resp_header("retry-after", "60")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, error_body)
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      result = Google.synthesize("Hello", config)

      assert {:error, :rate_limited} = result
    end

    test "returns {:error, :api_error} on 500 server error", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "error" => %{
              "message" => "Internal server error",
              "code" => 500,
              "status" => "INTERNAL"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, error_body)
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      result = Google.synthesize("Hello", config)

      assert {:error, :api_error} = result
    end

    test "returns {:error, :api_error} on 503 service unavailable", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"error": {"message": "Service unavailable"}}))
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      result = Google.synthesize("Hello", config)

      assert {:error, :api_error} = result
    end

    test "returns {:error, :bad_request} on 400 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "error" => %{
              "message" => "Invalid voice name",
              "code" => 400,
              "status" => "INVALID_ARGUMENT"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, error_body)
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      result = Google.synthesize("Hello", config)

      assert {:error, :bad_request} = result
    end
  end

  describe "synthesize/2 - timeout errors" do
    setup do
      stub_name = :"google_timeout_test_#{System.unique_integer([:positive])}"
      %{stub_name: stub_name}
    end

    test "returns {:error, :timeout} on connection timeout", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      result = Google.synthesize("Hello", config)

      assert {:error, :timeout} = result
    end

    test "returns {:error, :connection_refused} on connection refused", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      result = Google.synthesize("Hello", config)

      assert {:error, :connection_refused} = result
    end

    test "returns {:error, :network_error} on other transport errors", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      result = Google.synthesize("Hello", config)

      assert {:error, :network_error} = result
    end
  end

  describe "synthesize/2 - input validation" do
    test "returns {:error, :empty_text} for empty string" do
      config = [api_key: "ya29.test-key"]

      result = Google.synthesize("", config)

      assert {:error, :empty_text} = result
    end

    test "returns {:error, :invalid_text_type} for non-string input" do
      config = [api_key: "ya29.test-key"]

      assert {:error, :invalid_text_type} = Google.synthesize(123, config)
      assert {:error, :invalid_text_type} = Google.synthesize(nil, config)
      assert {:error, :invalid_text_type} = Google.synthesize(~c"list", config)
    end

    test "returns config validation error when config is invalid" do
      # Missing api_key
      config = [language_code: "en-US"]

      result = Google.synthesize("Hello", config)

      assert {:error, :missing_api_key} = result
    end

    test "handles text with special characters", %{} do
      stub_name = :"google_special_chars_#{System.unique_integer([:positive])}"
      fake_audio = Base.encode64(:crypto.strong_rand_bytes(50))

      Req.Test.stub(stub_name, fn conn ->
        response_body = Jason.encode!(%{"audioContent" => fake_audio})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, response_body)
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      # Text with special characters, unicode, and newlines
      special_text = "Hello, world! \n\t\"Quoted text\" & <special> chars: \u00e9\u00e8\u00e0"

      result = Google.synthesize(special_text, config)

      assert {:ok, _audio} = result
    end

    test "handles long text input" do
      stub_name = :"google_long_text_#{System.unique_integer([:positive])}"
      fake_audio = Base.encode64(:crypto.strong_rand_bytes(1000))

      Req.Test.stub(stub_name, fn conn ->
        response_body = Jason.encode!(%{"audioContent" => fake_audio})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, response_body)
      end)

      config = [
        api_key: "ya29.test-key",
        plug: {Req.Test, stub_name}
      ]

      # Generate long text (Google has a 5000 byte limit)
      long_text = String.duplicate("Hello world. ", 300)

      result = Google.synthesize(long_text, config)

      assert {:ok, _audio} = result
    end
  end

  describe "list_voices/1" do
    test "returns list of available Google Neural2 voices" do
      config = [api_key: "ya29.test-key"]

      result = Google.list_voices(config)

      assert {:ok, voices} = result
      assert is_list(voices)
      assert length(voices) >= 9
    end

    test "each voice has required fields (id, name, language)" do
      config = [api_key: "ya29.test-key"]

      {:ok, voices} = Google.list_voices(config)

      for voice <- voices do
        assert Map.has_key?(voice, :id)
        assert Map.has_key?(voice, :name)
        assert Map.has_key?(voice, :language)
        assert is_binary(voice.id)
        assert is_binary(voice.name)
        assert is_binary(voice.language)
      end
    end

    test "returns Neural2 voice IDs" do
      config = [api_key: "ya29.test-key"]

      {:ok, voices} = Google.list_voices(config)

      voice_ids = Enum.map(voices, & &1.id)

      # Should include at least some Neural2 voices
      for expected_voice <- @neural2_voices do
        assert expected_voice in voice_ids,
               "Expected voice '#{expected_voice}' to be in list"
      end
    end

    test "voices have language set correctly" do
      config = [api_key: "ya29.test-key"]

      {:ok, voices} = Google.list_voices(config)

      # All returned voices should have valid language codes
      for voice <- voices do
        assert voice.language =~ ~r/^[a-z]{2}-[A-Z]{2}$/,
               "Expected valid language code for voice #{voice.id}, got #{voice.language}"
      end
    end

    test "works without making API call (static list)" do
      # Even with just API key, should return static voice list
      config = [api_key: "ya29.test-key"]

      result = Google.list_voices(config)

      assert {:ok, voices} = result
      assert length(voices) >= 9
    end

    test "includes optional gender field for voices" do
      config = [api_key: "ya29.test-key"]

      {:ok, voices} = Google.list_voices(config)

      # Voices may optionally include gender
      for voice <- voices do
        if Map.has_key?(voice, :gender) do
          assert voice.gender in ["MALE", "FEMALE", "NEUTRAL"]
        end
      end
    end

    test "returns error for missing api_key" do
      # Even for static list, we should validate config
      config = []

      result = Google.list_voices(config)

      assert {:error, :missing_api_key} = result
    end
  end

  describe "implementation of Provider behaviour" do
    test "module implements Parrot.TTS.Provider behaviour" do
      behaviours = Google.__info__(:attributes)[:behaviour] || []

      assert Parrot.TTS.Provider in behaviours
    end

    test "exports synthesize/2 function" do
      Code.ensure_loaded!(Google)
      assert function_exported?(Google, :synthesize, 2)
    end

    test "exports list_voices/1 function" do
      Code.ensure_loaded!(Google)
      assert function_exported?(Google, :list_voices, 1)
    end

    test "exports validate_config/1 function" do
      Code.ensure_loaded!(Google)
      assert function_exported?(Google, :validate_config, 1)
    end
  end

  describe "module constants and configuration" do
    test "defines correct API URL constant" do
      # The module should use the correct Google Cloud TTS endpoint
      assert Google.api_url() == @google_api_url
    end

    test "defines list of valid formats" do
      valid_formats = Google.valid_formats()

      assert is_list(valid_formats)

      for format <- @valid_formats do
        assert format in valid_formats
      end
    end

    test "defines default configuration values" do
      defaults = Google.defaults()

      assert defaults[:language_code] == "en-US"
      assert defaults[:voice_name] == "en-US-Neural2-C"
      assert defaults[:format] == :mp3
      assert defaults[:speaking_rate] == 1.0
      assert defaults[:pitch] == 0.0
    end
  end
end
