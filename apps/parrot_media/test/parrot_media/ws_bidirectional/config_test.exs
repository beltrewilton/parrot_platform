defmodule ParrotMedia.WsBidirectional.ConfigTest do
  @moduledoc """
  TDD tests for WsBidirectional.Config struct validation.

  These tests are written BEFORE the implementation exists (TDD approach).
  They define the expected behavior of the Config module for bidirectional
  WebSocket audio connections.

  Key differences from WsAudioForker.Config:
  - Uses `connection_id` instead of `fork_id`
  - Has separate `inbound_format` and `outbound_format` (vs single `audio_format`)
  - Includes `sample_rate` field
  - Includes `jitter_buffer_ms` field
  """
  use ExUnit.Case, async: true

  alias ParrotMedia.WsBidirectional.Config

  describe "new/1" do
    test "creates valid config with required fields" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "bidirectional_1",
                 url: "wss://api.openai.com/v1/realtime"
               )

      assert config.connection_id == "bidirectional_1"
      assert config.url == "wss://api.openai.com/v1/realtime"
    end

    test "creates config with all fields including optional ones" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "my_connection",
                 url: "wss://api.assemblyai.com/v2/realtime",
                 headers: [{"Authorization", "Token abc123"}],
                 callback_module: MyApp.BidirectionalHandler,
                 callback_state: %{call_id: "call_123"},
                 inbound_format: :opus,
                 outbound_format: :pcmu,
                 sample_rate: 8000,
                 buffer_size: 200,
                 jitter_buffer_ms: 100,
                 connect_timeout_ms: 10_000,
                 max_retries: 3
               )

      assert config.connection_id == "my_connection"
      assert config.url == "wss://api.assemblyai.com/v2/realtime"
      assert config.headers == [{"Authorization", "Token abc123"}]
      assert config.callback_module == MyApp.BidirectionalHandler
      assert config.callback_state == %{call_id: "call_123"}
      assert config.inbound_format == :opus
      assert config.outbound_format == :pcmu
      assert config.sample_rate == 8000
      assert config.buffer_size == 200
      assert config.jitter_buffer_ms == 100
      assert config.connect_timeout_ms == 10_000
      assert config.max_retries == 3
    end

    test "returns error for missing connection_id" do
      assert {:error, :missing_connection_id} = Config.new(url: "wss://example.com/ws")
    end

    test "returns error for missing url" do
      assert {:error, :missing_url} = Config.new(connection_id: "test_conn")
    end

    test "returns error for empty connection_id" do
      assert {:error, :invalid_connection_id} =
               Config.new(
                 connection_id: "",
                 url: "wss://example.com/ws"
               )
    end

    test "returns error for nil connection_id" do
      assert {:error, :invalid_connection_id} =
               Config.new(
                 connection_id: nil,
                 url: "wss://example.com/ws"
               )
    end

    test "returns error for invalid url scheme - http" do
      assert {:error, :invalid_url_scheme} =
               Config.new(
                 connection_id: "test_conn",
                 url: "http://example.com/ws"
               )
    end

    test "returns error for invalid url scheme - https" do
      assert {:error, :invalid_url_scheme} =
               Config.new(
                 connection_id: "test_conn",
                 url: "https://example.com/ws"
               )
    end

    test "accepts ws:// url scheme" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "ws://localhost:8080/ws"
               )

      assert config.url == "ws://localhost:8080/ws"
    end

    test "accepts wss:// url scheme" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://api.openai.com/v1/realtime"
               )

      assert config.url == "wss://api.openai.com/v1/realtime"
    end

    test "returns error for empty url" do
      assert {:error, :invalid_url} =
               Config.new(
                 connection_id: "test_conn",
                 url: ""
               )
    end

    test "returns error for buffer_size below minimum (0)" do
      assert {:error, :buffer_size_out_of_range} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 buffer_size: 0
               )
    end

    test "returns error for buffer_size above maximum (501)" do
      assert {:error, :buffer_size_out_of_range} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 buffer_size: 501
               )
    end

    test "returns error for negative buffer_size" do
      assert {:error, :buffer_size_out_of_range} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 buffer_size: -1
               )
    end

    test "accepts buffer_size at minimum boundary (1)" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 buffer_size: 1
               )

      assert config.buffer_size == 1
    end

    test "accepts buffer_size at maximum boundary (500)" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 buffer_size: 500
               )

      assert config.buffer_size == 500
    end

    test "sets default empty list for headers" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws"
               )

      assert config.headers == []
    end

    test "sets default nil for callback_module" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws"
               )

      assert config.callback_module == nil
    end

    test "sets default empty map for callback_state" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws"
               )

      assert config.callback_state == %{}
    end

    test "sets default :pcm_16le for inbound_format" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws"
               )

      assert config.inbound_format == :pcm_16le
    end

    test "sets default :pcm_16le for outbound_format" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws"
               )

      assert config.outbound_format == :pcm_16le
    end

    test "sets default 16000 for sample_rate" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws"
               )

      assert config.sample_rate == 16000
    end

    test "sets default 100 for buffer_size" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws"
               )

      assert config.buffer_size == 100
    end

    test "sets default 60 for jitter_buffer_ms" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws"
               )

      assert config.jitter_buffer_ms == 60
    end

    test "sets default 5000 for connect_timeout_ms" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws"
               )

      assert config.connect_timeout_ms == 5000
    end

    test "sets default 5 for max_retries" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws"
               )

      assert config.max_retries == 5
    end

    test "validates inbound_format accepts :pcm_16le" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 inbound_format: :pcm_16le
               )

      assert config.inbound_format == :pcm_16le
    end

    test "validates inbound_format accepts :pcmu" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 inbound_format: :pcmu
               )

      assert config.inbound_format == :pcmu
    end

    test "validates inbound_format accepts :opus" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 inbound_format: :opus
               )

      assert config.inbound_format == :opus
    end

    test "rejects invalid inbound_format - mp3" do
      assert {:error, :invalid_inbound_format} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 inbound_format: :mp3
               )
    end

    test "rejects invalid inbound_format - alaw" do
      assert {:error, :invalid_inbound_format} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 inbound_format: :alaw
               )
    end

    test "validates outbound_format accepts :pcm_16le" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 outbound_format: :pcm_16le
               )

      assert config.outbound_format == :pcm_16le
    end

    test "validates outbound_format accepts :pcmu" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 outbound_format: :pcmu
               )

      assert config.outbound_format == :pcmu
    end

    test "validates outbound_format accepts :opus" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 outbound_format: :opus
               )

      assert config.outbound_format == :opus
    end

    test "rejects invalid outbound_format - wav" do
      assert {:error, :invalid_outbound_format} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 outbound_format: :wav
               )
    end

    test "validates sample_rate must be positive integer" do
      assert {:error, :invalid_sample_rate} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 sample_rate: 0
               )
    end

    test "rejects negative sample_rate" do
      assert {:error, :invalid_sample_rate} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 sample_rate: -8000
               )
    end

    test "accepts common sample rates" do
      for sample_rate <- [8000, 16000, 24000, 44100, 48000] do
        assert {:ok, config} =
                 Config.new(
                   connection_id: "test_conn",
                   url: "wss://example.com/ws",
                   sample_rate: sample_rate
                 )

        assert config.sample_rate == sample_rate
      end
    end

    test "validates jitter_buffer_ms must be positive integer" do
      assert {:error, :invalid_jitter_buffer_ms} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 jitter_buffer_ms: 0
               )
    end

    test "rejects negative jitter_buffer_ms" do
      assert {:error, :invalid_jitter_buffer_ms} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 jitter_buffer_ms: -10
               )
    end

    test "accepts custom jitter_buffer_ms value" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 jitter_buffer_ms: 120
               )

      assert config.jitter_buffer_ms == 120
    end

    test "accepts custom connect_timeout_ms value" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 connect_timeout_ms: 15_000
               )

      assert config.connect_timeout_ms == 15_000
    end

    test "accepts custom max_retries value" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 max_retries: 10
               )

      assert config.max_retries == 10
    end

    test "accepts max_retries of 0 (no retries)" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 max_retries: 0
               )

      assert config.max_retries == 0
    end

    test "accepts nil callback_module explicitly" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 callback_module: nil
               )

      assert config.callback_module == nil
    end

    test "accepts headers with valid string tuples" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 headers: [{"Authorization", "Bearer token"}, {"X-Custom", "value"}]
               )

      assert config.headers == [{"Authorization", "Bearer token"}, {"X-Custom", "value"}]
    end

    test "rejects headers with invalid format - not tuple" do
      assert {:error, :invalid_headers} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 headers: ["invalid header"]
               )
    end

    test "rejects headers with non-string key" do
      assert {:error, :invalid_headers} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 headers: [{:authorization, "Bearer token"}]
               )
    end

    test "rejects headers with non-string value" do
      assert {:error, :invalid_headers} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 headers: [{"Authorization", 123}]
               )
    end

    test "accepts custom callback_state" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 callback_state: %{session_id: "abc123", mode: :interactive}
               )

      assert config.callback_state == %{session_id: "abc123", mode: :interactive}
    end

    test "allows different inbound and outbound formats" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 inbound_format: :opus,
                 outbound_format: :pcm_16le
               )

      assert config.inbound_format == :opus
      assert config.outbound_format == :pcm_16le
    end
  end

  describe "new!/1" do
    test "returns config struct on success" do
      config =
        Config.new!(
          connection_id: "bidirectional_1",
          url: "wss://api.openai.com/v1/realtime"
        )

      assert %Config{} = config
      assert config.connection_id == "bidirectional_1"
      assert config.url == "wss://api.openai.com/v1/realtime"
    end

    test "raises ArgumentError for missing connection_id" do
      assert_raise ArgumentError, ~r/missing_connection_id/, fn ->
        Config.new!(url: "wss://example.com/ws")
      end
    end

    test "raises ArgumentError for missing url" do
      assert_raise ArgumentError, ~r/missing_url/, fn ->
        Config.new!(connection_id: "test_conn")
      end
    end

    test "raises ArgumentError for invalid connection_id" do
      assert_raise ArgumentError, ~r/invalid_connection_id/, fn ->
        Config.new!(connection_id: "", url: "wss://example.com/ws")
      end
    end

    test "raises ArgumentError for invalid url scheme" do
      assert_raise ArgumentError, ~r/invalid_url_scheme/, fn ->
        Config.new!(connection_id: "test_conn", url: "http://example.com/ws")
      end
    end

    test "raises ArgumentError for buffer_size out of range" do
      assert_raise ArgumentError, ~r/buffer_size_out_of_range/, fn ->
        Config.new!(connection_id: "test_conn", url: "wss://example.com/ws", buffer_size: 501)
      end
    end

    test "raises ArgumentError for invalid inbound_format" do
      assert_raise ArgumentError, ~r/invalid_inbound_format/, fn ->
        Config.new!(connection_id: "test_conn", url: "wss://example.com/ws", inbound_format: :mp3)
      end
    end

    test "raises ArgumentError for invalid outbound_format" do
      assert_raise ArgumentError, ~r/invalid_outbound_format/, fn ->
        Config.new!(connection_id: "test_conn", url: "wss://example.com/ws", outbound_format: :wav)
      end
    end

    test "raises ArgumentError for invalid sample_rate" do
      assert_raise ArgumentError, ~r/invalid_sample_rate/, fn ->
        Config.new!(connection_id: "test_conn", url: "wss://example.com/ws", sample_rate: 0)
      end
    end

    test "raises ArgumentError for invalid jitter_buffer_ms" do
      assert_raise ArgumentError, ~r/invalid_jitter_buffer_ms/, fn ->
        Config.new!(connection_id: "test_conn", url: "wss://example.com/ws", jitter_buffer_ms: -1)
      end
    end
  end

  describe "validate/1" do
    test "returns :ok for valid struct with all required fields" do
      config = %Config{
        connection_id: "valid_conn",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert Config.validate(config) == :ok
    end

    test "returns error for nil connection_id in existing struct" do
      config = %Config{
        connection_id: nil,
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_connection_id} = Config.validate(config)
    end

    test "returns error for empty connection_id in existing struct" do
      config = %Config{
        connection_id: "",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_connection_id} = Config.validate(config)
    end

    test "returns error for invalid url scheme in existing struct" do
      config = %Config{
        connection_id: "test_conn",
        url: "http://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_url_scheme} = Config.validate(config)
    end

    test "returns error for nil url in existing struct" do
      config = %Config{
        connection_id: "test_conn",
        url: nil,
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_url} = Config.validate(config)
    end

    test "returns error for empty url in existing struct" do
      config = %Config{
        connection_id: "test_conn",
        url: "",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_url} = Config.validate(config)
    end

    test "returns error for buffer_size below minimum in existing struct" do
      config = %Config{
        connection_id: "test_conn",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 0,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :buffer_size_out_of_range} = Config.validate(config)
    end

    test "returns error for buffer_size above maximum in existing struct" do
      config = %Config{
        connection_id: "test_conn",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 501,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :buffer_size_out_of_range} = Config.validate(config)
    end

    test "returns error for invalid inbound_format in existing struct" do
      config = %Config{
        connection_id: "test_conn",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :wav,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_inbound_format} = Config.validate(config)
    end

    test "returns error for invalid outbound_format in existing struct" do
      config = %Config{
        connection_id: "test_conn",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :mp3,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_outbound_format} = Config.validate(config)
    end

    test "returns error for invalid sample_rate in existing struct" do
      config = %Config{
        connection_id: "test_conn",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 0,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_sample_rate} = Config.validate(config)
    end

    test "returns error for invalid jitter_buffer_ms in existing struct" do
      config = %Config{
        connection_id: "test_conn",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 0,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_jitter_buffer_ms} = Config.validate(config)
    end

    test "returns error for invalid headers format in existing struct" do
      config = %Config{
        connection_id: "test_conn",
        url: "wss://example.com/ws",
        headers: ["not a tuple"],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_headers} = Config.validate(config)
    end

    test "returns :ok for valid config with ws:// url" do
      config = %Config{
        connection_id: "test_conn",
        url: "ws://localhost:8080/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :opus,
        outbound_format: :pcmu,
        sample_rate: 8000,
        buffer_size: 250,
        jitter_buffer_ms: 100,
        connect_timeout_ms: 10_000,
        max_retries: 3
      }

      assert Config.validate(config) == :ok
    end

    test "returns :ok for config with callback_module set" do
      config = %Config{
        connection_id: "test_conn",
        url: "wss://example.com/ws",
        headers: [{"Authorization", "Bearer token"}],
        callback_module: SomeModule,
        callback_state: %{key: "value"},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert Config.validate(config) == :ok
    end

    test "returns :ok for buffer_size at boundary values" do
      config_min = %Config{
        connection_id: "test_conn",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 1,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      config_max = %Config{
        connection_id: "test_conn",
        url: "wss://example.com/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 500,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert Config.validate(config_min) == :ok
      assert Config.validate(config_max) == :ok
    end

    test "returns :ok for config with multiple valid headers" do
      config = %Config{
        connection_id: "test_conn",
        url: "wss://example.com/ws",
        headers: [
          {"Authorization", "Token secret"},
          {"X-Api-Key", "key123"},
          {"Content-Type", "audio/pcm"}
        ],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert Config.validate(config) == :ok
    end
  end

  describe "struct definition" do
    test "Config struct exists with expected fields" do
      config = %Config{connection_id: "test", url: "wss://example.com"}

      assert Map.has_key?(config, :connection_id)
      assert Map.has_key?(config, :url)
      assert Map.has_key?(config, :headers)
      assert Map.has_key?(config, :callback_module)
      assert Map.has_key?(config, :callback_state)
      assert Map.has_key?(config, :inbound_format)
      assert Map.has_key?(config, :outbound_format)
      assert Map.has_key?(config, :sample_rate)
      assert Map.has_key?(config, :buffer_size)
      assert Map.has_key?(config, :jitter_buffer_ms)
      assert Map.has_key?(config, :connect_timeout_ms)
      assert Map.has_key?(config, :max_retries)
    end

    test "Config struct has correct default values" do
      config = %Config{connection_id: "test", url: "wss://example.com"}

      assert config.headers == []
      assert config.callback_module == nil
      assert config.callback_state == %{}
      assert config.inbound_format == :pcm_16le
      assert config.outbound_format == :pcm_16le
      assert config.sample_rate == 16000
      assert config.buffer_size == 100
      assert config.jitter_buffer_ms == 60
      assert config.connect_timeout_ms == 5000
      assert config.max_retries == 5
    end

    test "Config struct enforces required keys" do
      keys = Config.__struct__() |> Map.keys()
      assert :connection_id in keys
      assert :url in keys

      assert_raise ArgumentError, fn ->
        struct!(Config, %{})
      end
    end

    test "Config struct enforces connection_id as required key" do
      assert_raise ArgumentError, fn ->
        struct!(Config, %{url: "wss://example.com"})
      end
    end

    test "Config struct enforces url as required key" do
      assert_raise ArgumentError, fn ->
        struct!(Config, %{connection_id: "test"})
      end
    end
  end

  describe "edge cases" do
    test "handles url with query parameters" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime&voice=alloy"
               )

      assert config.url == "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime&voice=alloy"
    end

    test "handles url with path components" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://api.example.com/v2/realtime/audio/bidirectional"
               )

      assert config.url == "wss://api.example.com/v2/realtime/audio/bidirectional"
    end

    test "handles url with port number" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "ws://localhost:8080/ws"
               )

      assert config.url == "ws://localhost:8080/ws"
    end

    test "connection_id can contain special characters" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "call_123-bidirectional_1",
                 url: "wss://example.com/ws"
               )

      assert config.connection_id == "call_123-bidirectional_1"
    end

    test "connection_id can contain underscores and dashes" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "conn_test-uuid-12345",
                 url: "wss://example.com/ws"
               )

      assert config.connection_id == "conn_test-uuid-12345"
    end

    test "callback_state can be any term" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 callback_state: {:custom, :tuple, [1, 2, 3]}
               )

      assert config.callback_state == {:custom, :tuple, [1, 2, 3]}
    end

    test "handles large max_retries value" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 max_retries: 100
               )

      assert config.max_retries == 100
    end

    test "handles large connect_timeout_ms value" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 connect_timeout_ms: 60_000
               )

      assert config.connect_timeout_ms == 60_000
    end

    test "handles minimum valid jitter_buffer_ms" do
      assert {:ok, config} =
               Config.new(
                 connection_id: "test_conn",
                 url: "wss://example.com/ws",
                 jitter_buffer_ms: 1
               )

      assert config.jitter_buffer_ms == 1
    end
  end
end
