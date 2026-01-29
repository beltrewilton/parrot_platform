defmodule ParrotMedia.HandlerTest do
  use ExUnit.Case, async: true

  defmodule TestMediaHandler do
    @behaviour ParrotMedia.Handler

    @impl true
    def init(args), do: {:ok, args}

    # Pattern matching for different message types
    @impl true
    def handle_info({:play_files, files, [loop: true]}, state) do
      {[{:play_loop, files}], Map.put(state, :action, :looping)}
    end

    @impl true
    def handle_info({:play_files, files, opts}, state) when is_list(opts) do
      {[{:play_sequence, files}], Map.put(state, :action, :sequential)}
    end

    @impl true
    def handle_info({:fork_audio, url, [bidirectional: true]}, state) do
      {[{:fork_audio, url, bidirectional: true}], Map.put(state, :fork_mode, :bidirectional)}
    end

    @impl true
    def handle_info({:fork_audio, url, opts}, state) when is_list(opts) do
      {[{:fork_audio, url, bidirectional: false}], Map.put(state, :fork_mode, :unidirectional)}
    end

    @impl true
    def handle_info({:received_audio, data, %{source: "transcription"}}, state) do
      {[{:play, "response.wav"}], Map.put(state, :last_transcription, data)}
    end

    @impl true
    def handle_info({:received_audio, _data, %{source: source}}, state) do
      {:noreply, Map.put(state, :last_source, source)}
    end

    @impl true
    def handle_info({:stop_playback}, state) do
      {[:stop], Map.put(state, :playback, :stopped)}
    end

    @impl true
    def handle_info({:pause_playback}, state) do
      {[:pause], Map.put(state, :playback, :paused)}
    end

    @impl true
    def handle_info({:resume_playback}, state) do
      {[:resume], Map.put(state, :playback, :playing)}
    end

    @impl true
    def handle_info({:set_volume, level}, state)
        when is_float(level) and level >= 0.0 and level <= 1.0 do
      {[{:set_volume, level}], Map.put(state, :volume, level)}
    end

    @impl true
    def handle_info({:set_volume, _invalid}, state) do
      {:noreply, state}
    end

    @impl true
    def handle_info(_msg, state) do
      {:noreply, state}
    end

    # Optional callbacks
    @impl true
    def handle_codec_negotiation([:opus, :pcmu], [:pcmu, :opus], state) do
      {:ok, :opus, state}
    end

    @impl true
    def handle_codec_negotiation(offered, supported, state) do
      codec = Enum.find(offered, &(&1 in supported))

      case codec do
        nil -> {:error, :no_common_codec, state}
        c -> {:ok, c, state}
      end
    end

    @impl true
    def handle_play_complete("menu.wav", state) do
      {{:play_sequence, ["option1.wav", "option2.wav"]}, state}
    end

    @impl true
    def handle_play_complete(_file, state) do
      {:noreply, state}
    end

    @impl true
    def handle_session_start(_session_id, _opts, state) do
      {:noreply, state}
    end

    @impl true
    def handle_stream_start(_session_id, _stream_type, state) do
      {:noreply, state}
    end

    @impl true
    def handle_negotiation_complete(_session_id, _codec, _remote_info, state) do
      {:noreply, state}
    end
  end

  describe "init/1" do
    test "initializes with provided arguments" do
      assert {:ok, %{test: true}} = TestMediaHandler.init(%{test: true})
    end
  end

  describe "handle_info/2 - play_files messages" do
    test "handles play_files with loop option using pattern matching" do
      state = %{}
      files = ["file1.wav", "file2.wav"]

      assert {[{:play_loop, ^files}], new_state} =
               TestMediaHandler.handle_info({:play_files, files, [loop: true]}, state)

      assert new_state.action == :looping
    end

    test "handles play_files without loop option" do
      state = %{}
      files = ["file1.wav", "file2.wav"]

      assert {[{:play_sequence, ^files}], new_state} =
               TestMediaHandler.handle_info({:play_files, files, []}, state)

      assert new_state.action == :sequential
    end

    test "handles play_files with other options" do
      state = %{}
      files = ["file1.wav"]

      assert {[{:play_sequence, ^files}], new_state} =
               TestMediaHandler.handle_info({:play_files, files, [volume: 0.5]}, state)

      assert new_state.action == :sequential
    end
  end

  describe "handle_info/2 - fork_audio messages" do
    test "handles fork_audio with bidirectional option" do
      state = %{}
      url = "ws://transcription.service/"

      assert {[{:fork_audio, ^url, bidirectional: true}], new_state} =
               TestMediaHandler.handle_info({:fork_audio, url, [bidirectional: true]}, state)

      assert new_state.fork_mode == :bidirectional
    end

    test "handles fork_audio without bidirectional option" do
      state = %{}
      url = "ws://transcription.service/"

      assert {[{:fork_audio, ^url, bidirectional: false}], new_state} =
               TestMediaHandler.handle_info({:fork_audio, url, []}, state)

      assert new_state.fork_mode == :unidirectional
    end
  end

  describe "handle_info/2 - received_audio messages" do
    test "handles audio from transcription service with pattern matching" do
      state = %{}
      audio_data = <<1, 2, 3>>

      assert {[{:play, "response.wav"}], new_state} =
               TestMediaHandler.handle_info(
                 {:received_audio, audio_data, %{source: "transcription"}},
                 state
               )

      assert new_state.last_transcription == audio_data
    end

    test "handles audio from other sources" do
      state = %{}
      audio_data = <<1, 2, 3>>

      assert {:noreply, new_state} =
               TestMediaHandler.handle_info(
                 {:received_audio, audio_data, %{source: "other_service"}},
                 state
               )

      assert new_state.last_source == "other_service"
    end
  end

  describe "handle_info/2 - playback control messages" do
    test "handles stop_playback" do
      state = %{}

      assert {[:stop], new_state} =
               TestMediaHandler.handle_info({:stop_playback}, state)

      assert new_state.playback == :stopped
    end

    test "handles pause_playback" do
      state = %{}

      assert {[:pause], new_state} =
               TestMediaHandler.handle_info({:pause_playback}, state)

      assert new_state.playback == :paused
    end

    test "handles resume_playback" do
      state = %{}

      assert {[:resume], new_state} =
               TestMediaHandler.handle_info({:resume_playback}, state)

      assert new_state.playback == :playing
    end
  end

  describe "handle_info/2 - volume control with guards" do
    test "accepts valid volume levels" do
      state = %{}

      assert {[{:set_volume, 0.5}], new_state} =
               TestMediaHandler.handle_info({:set_volume, 0.5}, state)

      assert new_state.volume == 0.5
    end

    test "rejects invalid volume levels using pattern matching" do
      state = %{}

      # Too high
      assert {:noreply, state} ==
               TestMediaHandler.handle_info({:set_volume, 1.5}, state)

      # Too low  
      assert {:noreply, state} ==
               TestMediaHandler.handle_info({:set_volume, -0.5}, state)

      # Wrong type
      assert {:noreply, state} ==
               TestMediaHandler.handle_info({:set_volume, "loud"}, state)
    end
  end

  describe "handle_info/2 - catch-all pattern" do
    test "handles unknown messages" do
      state = %{}

      assert {:noreply, ^state} =
               TestMediaHandler.handle_info({:unknown_message}, state)
    end
  end

  describe "handle_codec_negotiation/3" do
    test "prefers opus when available in both lists" do
      state = %{}

      assert {:ok, :opus, ^state} =
               TestMediaHandler.handle_codec_negotiation([:opus, :pcmu], [:pcmu, :opus], state)
    end

    test "finds first common codec using pattern matching" do
      state = %{}

      assert {:ok, :pcma, ^state} =
               TestMediaHandler.handle_codec_negotiation([:g729, :pcma], [:pcmu, :pcma], state)
    end

    test "returns error when no common codec" do
      state = %{}

      assert {:error, :no_common_codec, ^state} =
               TestMediaHandler.handle_codec_negotiation([:opus], [:pcmu], state)
    end
  end

  describe "handle_play_complete/2" do
    test "chains playback after menu.wav" do
      state = %{}

      assert {{:play_sequence, ["option1.wav", "option2.wav"]}, ^state} =
               TestMediaHandler.handle_play_complete("menu.wav", state)
    end

    test "returns noreply for other files" do
      state = %{}

      assert {:noreply, ^state} =
               TestMediaHandler.handle_play_complete("other.wav", state)
    end
  end
end
