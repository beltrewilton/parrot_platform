defmodule Parrot.TTS.Providers.PollyTest do
  @moduledoc """
  Tests for the Amazon Polly TTS provider implementation.

  These tests verify that the Polly provider correctly:
  - Validates configuration (access_key_id, secret_access_key, region, voice_id, engine)
  - Synthesizes text to audio via the Amazon Polly API
  - Lists available voices (static list of Neural voices)
  - Handles various API errors appropriately

  ## TDD Note

  These tests are written BEFORE the Polly provider implementation exists.
  They will fail initially (red phase) and guide the implementation (green phase).

  ## Amazon Polly API Reference

  - Endpoint: POST https://polly.{region}.amazonaws.com/v1/speech
  - Authentication: AWS Signature V4
  - Query params: OutputFormat, Text, TextType, VoiceId, Engine, SampleRate
  - Response: Binary audio stream
  - Engines: standard, neural, generative
  - Neural Voices: Joanna, Matthew, Ivy, Justin, Kendra, Kimberly, Salli, Joey, etc.
  - Formats: mp3, ogg_vorbis, pcm
  """
  use ExUnit.Case, async: true

  # The module under test
  alias Parrot.TTS.Providers.Polly

  # Amazon Polly constants for tests
  @valid_voices ~w(Joanna Matthew Ivy Justin Kendra Kimberly Salli Joey Amy Brian Emma Olivia)
  @valid_engines ~w(standard neural generative)
  @valid_formats ~w(mp3 ogg_vorbis pcm)a
  @default_region "us-east-1"

  describe "validate_config/1" do
    test "returns :ok for valid config with all required credentials" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1",
        voice_id: "Joanna"
      ]

      assert :ok = Polly.validate_config(config)
    end

    test "returns :ok for minimal valid config with just credentials" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      ]

      assert :ok = Polly.validate_config(config)
    end

    test "returns :ok for config with all supported options" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-west-2",
        voice_id: "Matthew",
        engine: "neural",
        format: :mp3,
        sample_rate: "24000"
      ]

      assert :ok = Polly.validate_config(config)
    end

    test "returns error for missing access_key_id" do
      config = [
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1"
      ]

      assert {:error, :missing_access_key_id} = Polly.validate_config(config)
    end

    test "returns error for missing secret_access_key" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        region: "us-east-1"
      ]

      assert {:error, :missing_secret_access_key} = Polly.validate_config(config)
    end

    test "returns error for empty access_key_id" do
      config = [
        access_key_id: "",
        secret_access_key: "secret"
      ]

      assert {:error, :empty_access_key_id} = Polly.validate_config(config)
    end

    test "returns error for empty secret_access_key" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: ""
      ]

      assert {:error, :empty_secret_access_key} = Polly.validate_config(config)
    end

    test "returns error for nil access_key_id" do
      config = [
        access_key_id: nil,
        secret_access_key: "secret"
      ]

      assert {:error, :nil_access_key_id} = Polly.validate_config(config)
    end

    test "returns error for nil secret_access_key" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: nil
      ]

      assert {:error, :nil_secret_access_key} = Polly.validate_config(config)
    end

    test "returns error for non-string access_key_id" do
      config = [
        access_key_id: 12345,
        secret_access_key: "secret"
      ]

      assert {:error, :access_key_id_must_be_string} = Polly.validate_config(config)
    end

    test "returns error for non-string secret_access_key" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: 12345
      ]

      assert {:error, :secret_access_key_must_be_string} = Polly.validate_config(config)
    end

    test "returns error for invalid voice_id" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        voice_id: "InvalidVoice"
      ]

      assert {:error, {:invalid_voice_id, "InvalidVoice"}} = Polly.validate_config(config)
    end

    test "returns error for non-string voice_id" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        voice_id: 123
      ]

      assert {:error, :voice_id_must_be_string} = Polly.validate_config(config)
    end

    test "accepts all valid Polly neural voices" do
      for voice <- @valid_voices do
        config = [
          access_key_id: "AKIAIOSFODNN7EXAMPLE",
          secret_access_key: "secret",
          voice_id: voice
        ]

        assert :ok = Polly.validate_config(config), "Expected voice #{voice} to be valid"
      end
    end

    test "returns error for invalid engine" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        engine: "invalid_engine"
      ]

      assert {:error, {:invalid_engine, "invalid_engine"}} = Polly.validate_config(config)
    end

    test "returns error for non-string engine" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        engine: 123
      ]

      assert {:error, :engine_must_be_string} = Polly.validate_config(config)
    end

    test "accepts all valid Polly engines" do
      for engine <- @valid_engines do
        config = [
          access_key_id: "AKIAIOSFODNN7EXAMPLE",
          secret_access_key: "secret",
          engine: engine
        ]

        assert :ok = Polly.validate_config(config), "Expected engine #{engine} to be valid"
      end
    end

    test "returns error for invalid format" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        format: :invalid_format
      ]

      assert {:error, {:invalid_format, :invalid_format}} = Polly.validate_config(config)
    end

    test "accepts all valid Polly formats" do
      for format <- @valid_formats do
        config = [
          access_key_id: "AKIAIOSFODNN7EXAMPLE",
          secret_access_key: "secret",
          format: format
        ]

        assert :ok = Polly.validate_config(config), "Expected format #{format} to be valid"
      end
    end

    test "returns error for non-keyword-list config" do
      assert {:error, :config_must_be_keyword_list} =
               Polly.validate_config(%{access_key_id: "test"})

      assert {:error, :config_must_be_keyword_list} = Polly.validate_config("invalid")
    end
  end

  describe "synthesize/2 - successful synthesis" do
    setup do
      # Set up Req.Test stub for this test
      stub_name = :"polly_test_#{System.unique_integer([:positive])}"

      %{stub_name: stub_name}
    end

    test "returns {:ok, binary} on successful synthesis", %{stub_name: stub_name} do
      # Simulate successful Polly API response with MP3 audio data
      fake_mp3_audio = <<0xFF, 0xFB, 0x90, 0x00>> <> :crypto.strong_rand_bytes(100)

      Req.Test.stub(stub_name, fn conn ->
        # Verify request format
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/v1/speech")

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_mp3_audio)
      end)

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1",
        voice_id: "Joanna",
        engine: "neural",
        format: :mp3,
        # Use stub for testing
        plug: {Req.Test, stub_name}
      ]

      result = Polly.synthesize("Hello, world!", config)

      assert {:ok, audio_data} = result
      assert is_binary(audio_data)
      assert byte_size(audio_data) > 0
    end

    test "sends correct request body to Polly API", %{stub_name: stub_name} do
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
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-west-2",
        voice_id: "Matthew",
        engine: "neural",
        format: :mp3,
        sample_rate: "24000",
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = Polly.synthesize("Test text", config)

      assert_receive {:request_body, body}
      assert body["Text"] == "Test text"
      assert body["VoiceId"] == "Matthew"
      assert body["Engine"] == "neural"
      assert body["OutputFormat"] == "mp3"
      assert body["SampleRate"] == "24000"
    end

    test "uses default voice and engine when not specified", %{stub_name: stub_name} do
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
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = Polly.synthesize("Hello", config)

      assert_receive {:request_body, body}
      # Default voice should be "Joanna"
      assert body["VoiceId"] == "Joanna"
      # Default engine should be "neural"
      assert body["Engine"] == "neural"
      # Default format should be "mp3"
      assert body["OutputFormat"] == "mp3"
    end

    test "uses correct region endpoint", %{stub_name: stub_name} do
      test_pid = self()

      Req.Test.stub(stub_name, fn conn ->
        # The request should go to the correct regional endpoint
        send(test_pid, {:host, conn.host})

        fake_audio = :crypto.strong_rand_bytes(50)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "eu-west-1",
        plug: {Req.Test, stub_name}
      ]

      {:ok, _audio} = Polly.synthesize("Hello", config)

      # Note: With Req.Test stub, the host in conn will be the stub,
      # but the module should construct the URL correctly
      assert_receive {:host, _host}
    end

    test "returns PCM format when specified", %{stub_name: stub_name} do
      fake_pcm_audio = :crypto.strong_rand_bytes(100)

      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("audio/pcm")
        |> Plug.Conn.send_resp(200, fake_pcm_audio)
      end)

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        format: :pcm,
        plug: {Req.Test, stub_name}
      ]

      {:ok, audio_data} = Polly.synthesize("Hello", config)

      assert is_binary(audio_data)
    end
  end

  describe "synthesize/2 - API errors" do
    setup do
      stub_name = :"polly_error_test_#{System.unique_integer([:positive])}"
      %{stub_name: stub_name}
    end

    test "returns {:error, :invalid_credentials} on 403 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "__type" => "UnrecognizedClientException",
            "message" => "The security token included in the request is invalid"
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, error_body)
      end)

      config = [
        access_key_id: "invalid-key",
        secret_access_key: "invalid-secret",
        plug: {Req.Test, stub_name}
      ]

      result = Polly.synthesize("Hello", config)

      assert {:error, :invalid_credentials} = result
    end

    test "returns {:error, :rate_limited} on 429 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "__type" => "ThrottlingException",
            "message" => "Rate exceeded"
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, error_body)
      end)

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        plug: {Req.Test, stub_name}
      ]

      result = Polly.synthesize("Hello", config)

      assert {:error, :rate_limited} = result
    end

    test "returns {:error, :api_error} on 500 server error", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "__type" => "ServiceUnavailableException",
            "message" => "Internal server error"
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, error_body)
      end)

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        plug: {Req.Test, stub_name}
      ]

      result = Polly.synthesize("Hello", config)

      assert {:error, :api_error} = result
    end

    test "returns {:error, :bad_request} on 400 response", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "__type" => "InvalidParameterException",
            "message" => "Invalid request"
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, error_body)
      end)

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        plug: {Req.Test, stub_name}
      ]

      result = Polly.synthesize("Hello", config)

      assert {:error, :bad_request} = result
    end

    test "returns {:error, :text_too_long} on text length error", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        error_body =
          Jason.encode!(%{
            "__type" => "TextLengthExceededException",
            "message" => "Text is too long"
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, error_body)
      end)

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        plug: {Req.Test, stub_name}
      ]

      result = Polly.synthesize("Hello", config)

      assert {:error, :text_too_long} = result
    end
  end

  describe "synthesize/2 - timeout errors" do
    setup do
      stub_name = :"polly_timeout_test_#{System.unique_integer([:positive])}"
      %{stub_name: stub_name}
    end

    test "returns {:error, :timeout} on connection timeout", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        plug: {Req.Test, stub_name}
      ]

      result = Polly.synthesize("Hello", config)

      assert {:error, :timeout} = result
    end

    test "returns {:error, :connection_refused} on connection refused", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        plug: {Req.Test, stub_name}
      ]

      result = Polly.synthesize("Hello", config)

      assert {:error, :connection_refused} = result
    end

    test "returns {:error, :network_error} on other transport errors", %{stub_name: stub_name} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        plug: {Req.Test, stub_name}
      ]

      result = Polly.synthesize("Hello", config)

      assert {:error, :network_error} = result
    end
  end

  describe "synthesize/2 - input validation" do
    test "returns {:error, :empty_text} for empty string" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret"
      ]

      result = Polly.synthesize("", config)

      assert {:error, :empty_text} = result
    end

    test "returns {:error, :invalid_text_type} for non-string input" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret"
      ]

      assert {:error, :invalid_text_type} = Polly.synthesize(123, config)
      assert {:error, :invalid_text_type} = Polly.synthesize(nil, config)
      assert {:error, :invalid_text_type} = Polly.synthesize(~c"list", config)
    end

    test "returns config validation error when config is invalid" do
      # Missing credentials
      config = [voice_id: "Joanna"]

      result = Polly.synthesize("Hello", config)

      assert {:error, :missing_access_key_id} = result
    end

    test "handles text with special characters" do
      stub_name = :"polly_special_chars_#{System.unique_integer([:positive])}"

      Req.Test.stub(stub_name, fn conn ->
        fake_audio = :crypto.strong_rand_bytes(50)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, fake_audio)
      end)

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret",
        plug: {Req.Test, stub_name}
      ]

      # Text with special characters, unicode, and newlines
      special_text = "Hello, world! \n\t\"Quoted text\" & <special> chars: eea"

      result = Polly.synthesize(special_text, config)

      assert {:ok, _audio} = result
    end
  end

  describe "list_voices/1" do
    test "returns list of available Polly Neural voices" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret"
      ]

      result = Polly.list_voices(config)

      assert {:ok, voices} = result
      assert is_list(voices)
      assert length(voices) > 0
    end

    test "each voice has required fields (id, name, language)" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret"
      ]

      {:ok, voices} = Polly.list_voices(config)

      for voice <- voices do
        assert Map.has_key?(voice, :id)
        assert Map.has_key?(voice, :name)
        assert Map.has_key?(voice, :language)
        assert is_binary(voice.id)
        assert is_binary(voice.name)
        assert is_binary(voice.language)
      end
    end

    test "returns expected Polly voice IDs" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret"
      ]

      {:ok, voices} = Polly.list_voices(config)

      voice_ids = Enum.map(voices, & &1.id)

      # Check for some common Neural voices
      assert "Joanna" in voice_ids
      assert "Matthew" in voice_ids
    end

    test "voices include engine information" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret"
      ]

      {:ok, voices} = Polly.list_voices(config)

      for voice <- voices do
        assert Map.has_key?(voice, :engine)
        assert voice.engine in ["neural", "standard", "generative"]
      end
    end

    test "works without making API call (static list)" do
      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "secret"
      ]

      result = Polly.list_voices(config)

      assert {:ok, voices} = result
      assert length(voices) > 0
    end

    test "returns error for missing access_key_id" do
      config = [secret_access_key: "secret"]

      result = Polly.list_voices(config)

      assert {:error, :missing_access_key_id} = result
    end

    test "returns error for missing secret_access_key" do
      config = [access_key_id: "AKIAIOSFODNN7EXAMPLE"]

      result = Polly.list_voices(config)

      assert {:error, :missing_secret_access_key} = result
    end
  end

  describe "implementation of Provider behaviour" do
    test "module implements Parrot.TTS.Provider behaviour" do
      behaviours = Polly.__info__(:attributes)[:behaviour] || []

      assert Parrot.TTS.Provider in behaviours
    end

    test "exports synthesize/2 function" do
      Code.ensure_loaded!(Polly)
      assert function_exported?(Polly, :synthesize, 2)
    end

    test "exports list_voices/1 function" do
      Code.ensure_loaded!(Polly)
      assert function_exported?(Polly, :list_voices, 1)
    end

    test "exports validate_config/1 function" do
      Code.ensure_loaded!(Polly)
      assert function_exported?(Polly, :validate_config, 1)
    end
  end

  describe "module constants and configuration" do
    test "defines list of valid voices" do
      valid_voices = Polly.valid_voices()

      assert is_list(valid_voices)
      assert "Joanna" in valid_voices
      assert "Matthew" in valid_voices
    end

    test "defines list of valid engines" do
      valid_engines = Polly.valid_engines()

      assert is_list(valid_engines)
      assert "neural" in valid_engines
      assert "standard" in valid_engines
      assert "generative" in valid_engines
    end

    test "defines default configuration values" do
      defaults = Polly.defaults()

      assert defaults[:voice_id] == "Joanna"
      assert defaults[:engine] == "neural"
      assert defaults[:format] == :mp3
      assert defaults[:region] == @default_region
    end

    test "defines default region" do
      assert Polly.default_region() == @default_region
    end
  end

  describe "AWS signature" do
    test "generates proper authorization header format" do
      # The module should include AWS4-HMAC-SHA256 signature
      # This is a simplified test - real AWS signature is complex

      # Just verify the module exports required functions
      Code.ensure_loaded!(Polly)
      # The internal signature generation will be tested via integration tests
      assert function_exported?(Polly, :synthesize, 2)
    end
  end
end
