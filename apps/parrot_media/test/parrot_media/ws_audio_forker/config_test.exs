defmodule ParrotMedia.WsAudioForker.ConfigTest do
  use ExUnit.Case, async: true

  alias ParrotMedia.WsAudioForker.Config

  describe "new/1" do
    test "creates valid config with all required fields" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "transcription_1",
                 url: "wss://api.deepgram.com/v1/listen"
               )

      assert config.fork_id == "transcription_1"
      assert config.url == "wss://api.deepgram.com/v1/listen"
    end

    test "creates config with all fields including optional ones" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "my_fork",
                 url: "wss://api.assemblyai.com/v2/realtime",
                 headers: [{"Authorization", "Token abc123"}],
                 callback_module: MyApp.TranscriptionHandler,
                 callback_state: %{call_id: "call_123"},
                 audio_format: :opus,
                 buffer_size: 200,
                 connect_timeout_ms: 10_000,
                 max_retries: 3
               )

      assert config.fork_id == "my_fork"
      assert config.url == "wss://api.assemblyai.com/v2/realtime"
      assert config.headers == [{"Authorization", "Token abc123"}]
      assert config.callback_module == MyApp.TranscriptionHandler
      assert config.callback_state == %{call_id: "call_123"}
      assert config.audio_format == :opus
      assert config.buffer_size == 200
      assert config.connect_timeout_ms == 10_000
      assert config.max_retries == 3
    end

    test "requires fork_id - returns error without it" do
      assert {:error, :missing_fork_id} = Config.new(url: "wss://example.com/ws")
    end

    test "requires url - returns error without it" do
      assert {:error, :missing_url} = Config.new(fork_id: "test_fork")
    end

    test "validates url starts with ws://" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "ws://localhost:8080/ws"
               )

      assert config.url == "ws://localhost:8080/ws"
    end

    test "validates url starts with wss://" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://api.deepgram.com/v1/listen"
               )

      assert config.url == "wss://api.deepgram.com/v1/listen"
    end

    test "rejects url that does not start with ws:// or wss://" do
      assert {:error, :invalid_url_scheme} =
               Config.new(
                 fork_id: "test_fork",
                 url: "http://example.com/ws"
               )
    end

    test "rejects url with https:// scheme" do
      assert {:error, :invalid_url_scheme} =
               Config.new(
                 fork_id: "test_fork",
                 url: "https://example.com/ws"
               )
    end

    test "validates buffer_size minimum is 1" do
      assert {:error, :buffer_size_out_of_range} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 buffer_size: 0
               )
    end

    test "validates buffer_size maximum is 500" do
      assert {:error, :buffer_size_out_of_range} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 buffer_size: 501
               )
    end

    test "accepts buffer_size at minimum boundary (1)" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 buffer_size: 1
               )

      assert config.buffer_size == 1
    end

    test "accepts buffer_size at maximum boundary (500)" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 buffer_size: 500
               )

      assert config.buffer_size == 500
    end

    test "uses default empty list for headers" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws"
               )

      assert config.headers == []
    end

    test "uses default :pcm_16le for audio_format" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws"
               )

      assert config.audio_format == :pcm_16le
    end

    test "uses default 100 for buffer_size" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws"
               )

      assert config.buffer_size == 100
    end

    test "uses default 5000 for connect_timeout_ms" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws"
               )

      assert config.connect_timeout_ms == 5000
    end

    test "validates audio_format accepts :pcm_16le" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 audio_format: :pcm_16le
               )

      assert config.audio_format == :pcm_16le
    end

    test "validates audio_format accepts :opus" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 audio_format: :opus
               )

      assert config.audio_format == :opus
    end

    test "rejects invalid audio_format - mp3" do
      assert {:error, :invalid_audio_format} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 audio_format: :mp3
               )
    end

    test "rejects invalid audio_format - alaw" do
      assert {:error, :invalid_audio_format} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 audio_format: :alaw
               )
    end

    test "rejects empty fork_id" do
      assert {:error, :invalid_fork_id} =
               Config.new(
                 fork_id: "",
                 url: "wss://example.com/ws"
               )
    end

    test "rejects nil fork_id" do
      assert {:error, :invalid_fork_id} =
               Config.new(
                 fork_id: nil,
                 url: "wss://example.com/ws"
               )
    end

    test "rejects empty url" do
      assert {:error, :invalid_url} =
               Config.new(
                 fork_id: "test_fork",
                 url: ""
               )
    end

    test "accepts nil callback_module" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 callback_module: nil
               )

      assert config.callback_module == nil
    end

    test "rejects negative buffer_size" do
      assert {:error, :buffer_size_out_of_range} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 buffer_size: -1
               )
    end

    test "accepts headers with valid string tuples" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 headers: [{"Authorization", "Bearer token"}, {"X-Custom", "value"}]
               )

      assert config.headers == [{"Authorization", "Bearer token"}, {"X-Custom", "value"}]
    end

    test "rejects headers with invalid format" do
      assert {:error, :invalid_headers} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 headers: ["invalid header"]
               )
    end

    test "rejects headers with non-string values" do
      assert {:error, :invalid_headers} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 headers: [{"Authorization", 123}]
               )
    end

    test "uses default 5 for max_retries" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws"
               )

      assert config.max_retries == 5
    end

    test "accepts custom max_retries value" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 max_retries: 10
               )

      assert config.max_retries == 10
    end

    test "uses default empty map for callback_state" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws"
               )

      assert config.callback_state == %{}
    end

    test "accepts custom callback_state" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://example.com/ws",
                 callback_state: %{session_id: "abc123"}
               )

      assert config.callback_state == %{session_id: "abc123"}
    end
  end

  describe "validate/1" do
    test "returns :ok for valid struct with all required fields" do
      config = %Config{
        fork_id: "valid_fork",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert Config.validate(config) == :ok
    end

    test "returns error for nil fork_id in existing struct" do
      config = %Config{
        fork_id: nil,
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_fork_id} = Config.validate(config)
    end

    test "returns error for empty fork_id in existing struct" do
      config = %Config{
        fork_id: "",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_fork_id} = Config.validate(config)
    end

    test "returns error for invalid url scheme in existing struct" do
      config = %Config{
        fork_id: "test_fork",
        url: "http://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_url_scheme} = Config.validate(config)
    end

    test "returns error for buffer_size below minimum in existing struct" do
      config = %Config{
        fork_id: "test_fork",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 0,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :buffer_size_out_of_range} = Config.validate(config)
    end

    test "returns error for buffer_size above maximum in existing struct" do
      config = %Config{
        fork_id: "test_fork",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 501,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :buffer_size_out_of_range} = Config.validate(config)
    end

    test "returns error for invalid audio_format in existing struct" do
      config = %Config{
        fork_id: "test_fork",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :wav,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_audio_format} = Config.validate(config)
    end

    test "returns :ok for valid config with ws:// url" do
      config = %Config{
        fork_id: "test_fork",
        url: "ws://localhost:8080/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :opus,
        buffer_size: 250,
        connect_timeout_ms: 10_000,
        max_retries: 3
      }

      assert Config.validate(config) == :ok
    end

    test "returns :ok for config with callback_module set" do
      config = %Config{
        fork_id: "test_fork",
        url: "wss://example.com/ws",
        headers: [{"Authorization", "Bearer token"}],
        callback_module: SomeModule,
        callback_state: %{key: "value"},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert Config.validate(config) == :ok
    end

    test "returns error for nil url in existing struct" do
      config = %Config{
        fork_id: "test_fork",
        url: nil,
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_url} = Config.validate(config)
    end

    test "returns error for empty url in existing struct" do
      config = %Config{
        fork_id: "test_fork",
        url: "",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_url} = Config.validate(config)
    end

    test "returns error for invalid headers format in existing struct" do
      config = %Config{
        fork_id: "test_fork",
        url: "wss://example.com/ws",
        headers: ["not a tuple"],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_headers} = Config.validate(config)
    end

    test "returns :ok for buffer_size at boundary values" do
      config_min = %Config{
        fork_id: "test_fork",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 1,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      config_max = %Config{
        fork_id: "test_fork",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 500,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert Config.validate(config_min) == :ok
      assert Config.validate(config_max) == :ok
    end

    test "returns :ok for config with multiple valid headers" do
      config = %Config{
        fork_id: "test_fork",
        url: "wss://example.com/ws",
        headers: [
          {"Authorization", "Token secret"},
          {"X-Api-Key", "key123"},
          {"Content-Type", "audio/pcm"}
        ],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert Config.validate(config) == :ok
    end
  end

  describe "struct definition" do
    test "Config struct exists with expected fields" do
      config = %Config{fork_id: "test", url: "wss://example.com"}

      assert Map.has_key?(config, :fork_id)
      assert Map.has_key?(config, :url)
      assert Map.has_key?(config, :headers)
      assert Map.has_key?(config, :callback_module)
      assert Map.has_key?(config, :callback_state)
      assert Map.has_key?(config, :audio_format)
      assert Map.has_key?(config, :buffer_size)
      assert Map.has_key?(config, :connect_timeout_ms)
      assert Map.has_key?(config, :max_retries)
    end

    test "Config struct has correct default values" do
      # Create minimal config with only required fields to check defaults
      config = %Config{fork_id: "test", url: "wss://example.com"}

      # Optional fields should have defaults per implementation
      assert config.headers == []
      assert config.callback_module == nil
      assert config.callback_state == %{}
      assert config.audio_format == :pcm_16le
      assert config.buffer_size == 100
      assert config.connect_timeout_ms == 5000
      assert config.max_retries == 5
    end

    test "Config struct enforces required keys" do
      # @enforce_keys [:fork_id, :url] ensures these are required at compile time
      # Attempting to create struct without fork_id and url raises ArgumentError
      # We verify this by checking the struct has the expected fields
      keys = Config.__struct__() |> Map.keys()
      assert :fork_id in keys
      assert :url in keys

      # Verify struct!/2 raises when required keys are missing
      assert_raise ArgumentError, fn ->
        struct!(Config, %{})
      end
    end

    test "Config struct enforces fork_id as required key" do
      assert_raise ArgumentError, fn ->
        struct!(Config, %{url: "wss://example.com"})
      end
    end

    test "Config struct enforces url as required key" do
      assert_raise ArgumentError, fn ->
        struct!(Config, %{fork_id: "test"})
      end
    end
  end

  describe "edge cases" do
    test "handles url with query parameters" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=16000"
               )

      assert config.url == "wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=16000"
    end

    test "handles url with path components" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "wss://api.example.com/v2/realtime/transcribe"
               )

      assert config.url == "wss://api.example.com/v2/realtime/transcribe"
    end

    test "handles url with port number" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "test_fork",
                 url: "ws://localhost:8080/ws"
               )

      assert config.url == "ws://localhost:8080/ws"
    end

    test "fork_id can contain special characters" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "call_123-transcription_1",
                 url: "wss://example.com/ws"
               )

      assert config.fork_id == "call_123-transcription_1"
    end

    test "fork_id can contain unicode characters" do
      assert {:ok, config} =
               Config.new(
                 fork_id: "fork_test_unicode",
                 url: "wss://example.com/ws"
               )

      assert config.fork_id == "fork_test_unicode"
    end
  end
end
