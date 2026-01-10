defmodule ParrotMedia.WsForkSinkTest do
  @moduledoc """
  Tests for WsForkSink Membrane element.

  WsForkSink is a Membrane Sink element that bridges the Membrane pipeline
  to a WsAudioForker GenServer. It receives audio buffers from the pipeline
  and forwards them to the forker via message passing.

  These tests follow TDD - they are written FIRST and should FAIL until
  WsForkSink is implemented (T021).

  Message format expected from WsForkSink to forker:
    {:audio_frame, fork_id, payload} - for identified forks
    {:audio_frame, payload}          - simple form without fork_id

  The implementation should:
  1. Accept forker_pid and fork_id as options
  2. Be a Membrane Sink with push flow control
  3. Forward buffer payloads to forker_pid via messages
  4. Handle nil/dead forker_pid gracefully (log, don't crash)
  5. Accept any audio format (format-agnostic)
  """
  use ExUnit.Case, async: false

  # Check if WsForkSink module exists at compile time
  @ws_fork_sink_exists Code.ensure_loaded?(ParrotMedia.WsForkSink)

  describe "module existence" do
    test "WsForkSink module is defined" do
      # This test will fail until WsForkSink is implemented
      assert Code.ensure_loaded?(ParrotMedia.WsForkSink),
             "ParrotMedia.WsForkSink module must be defined. " <>
               "Implement it at: apps/parrot_media/lib/parrot_media/ws_fork_sink.ex"
    end
  end

  # Only run these tests if the module exists (compile-time check)
  if @ws_fork_sink_exists do
    import Membrane.ChildrenSpec

    alias Membrane.Buffer
    alias Membrane.Testing
    alias ParrotMedia.WsForkSink

    describe "struct options" do
      test "requires forker_pid option" do
        # WsForkSink should define forker_pid as a required option
        sink = %WsForkSink{
          forker_pid: self(),
          fork_id: "test_fork_1"
        }

        assert sink.forker_pid == self()
        assert sink.fork_id == "test_fork_1"
      end

      test "accepts nil forker_pid for graceful degradation" do
        # Should be able to create with nil forker_pid
        sink = %WsForkSink{
          forker_pid: nil,
          fork_id: "test_fork_2"
        }

        assert sink.forker_pid == nil
        assert sink.fork_id == "test_fork_2"
      end

      test "has optional fork_id with default" do
        # fork_id should have a default value (nil or auto-generated)
        sink = %WsForkSink{
          forker_pid: self()
        }

        assert sink.forker_pid == self()
        # fork_id should default to nil or some value
        assert sink.fork_id == nil or is_binary(sink.fork_id)
      end
    end

    describe "Membrane element behavior" do
      test "WsForkSink is a valid Membrane Sink" do
        # Verify the module uses Membrane.Sink and defines required callbacks
        assert function_exported?(WsForkSink, :handle_init, 2)
        assert function_exported?(WsForkSink, :handle_buffer, 4)
      end

      test "defines input pad with push flow control" do
        # WsForkSink should accept push flow control for real-time audio
        # This is verified by successfully creating a pipeline with it
        forker_pid = self()

        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 20})
              |> child(:sink, %WsForkSink{
                forker_pid: forker_pid,
                fork_id: "flow_control_test"
              })
          )

        # Let it run briefly
        Process.sleep(50)

        Testing.Pipeline.terminate(pipeline, force?: true)
      end
    end

    describe "buffer forwarding to forker" do
      test "forwards audio buffers to forker_pid as {:audio_frame, data}" do
        forker_pid = self()

        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 20})
              |> child(:sink, %WsForkSink{
                forker_pid: forker_pid,
                fork_id: "forward_test"
              })
          )

        # Should receive audio frame message from WsForkSink
        # Accept either format: with or without fork_id
        receive do
          {:audio_frame, _fork_id, audio_data} when is_binary(audio_data) ->
            assert byte_size(audio_data) > 0

          {:audio_frame, audio_data} when is_binary(audio_data) ->
            assert byte_size(audio_data) > 0
        after
          200 ->
            flunk("Expected to receive {:audio_frame, ...} message from WsForkSink")
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "includes fork_id in messages when configured" do
        forker_pid = self()
        fork_id = "my_unique_fork_id"

        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 20})
              |> child(:sink, %WsForkSink{
                forker_pid: forker_pid,
                fork_id: fork_id
              })
          )

        # Should receive audio frame with fork_id
        receive do
          {:audio_frame, ^fork_id, _audio_data} ->
            :ok

          {:audio_frame, received_fork_id, _audio_data} ->
            flunk("Expected fork_id #{inspect(fork_id)}, got #{inspect(received_fork_id)}")

          {:audio_frame, _audio_data} ->
            # Also acceptable - some implementations may not include fork_id in message
            :ok
        after
          200 ->
            flunk("Expected to receive {:audio_frame, ...} message")
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "handles multiple sequential buffers" do
        forker_pid = self()

        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 10})
              |> child(:sink, %WsForkSink{
                forker_pid: forker_pid,
                fork_id: "sequential_test"
              })
          )

        # Should receive multiple audio frames
        for i <- 1..3 do
          receive do
            {:audio_frame, _, _data} -> :ok
            {:audio_frame, _data} -> :ok
          after
            100 ->
              flunk("Expected to receive audio frame #{i}")
          end
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "forwards buffers with correct payload data" do
        forker_pid = self()

        # Use SilenceSource which has push flow control
        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 20})
              |> child(:sink, %WsForkSink{
                forker_pid: forker_pid,
                fork_id: "payload_test"
              })
          )

        # Should receive audio data with proper size (8kHz * 20ms = 160 samples * 2 bytes = 320 bytes)
        receive do
          {:audio_frame, _fork_id, received_data} ->
            assert byte_size(received_data) == 320
            assert is_binary(received_data)

          {:audio_frame, received_data} ->
            assert byte_size(received_data) == 320
            assert is_binary(received_data)
        after
          200 ->
            flunk("Expected to receive audio frame with test payload")
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "handle_buffer forwards exact payload via callback" do
        # Direct callback test for exact payload verification
        forker_pid = self()
        test_audio = <<1, 2, 3, 4, 5, 6, 7, 8>>
        state = %{forker_pid: forker_pid, fork_id: "test", frames_sent: 0, errors: 0}
        buffer = %Buffer{payload: test_audio, pts: 0}

        {_actions, _new_state} = WsForkSink.handle_buffer(:input, buffer, %{}, state)

        assert_receive {:audio_frame, "test", ^test_audio}
      end
    end

    describe "error handling" do
      test "handles forker_pid being nil gracefully" do
        # When forker_pid is nil, sink should not crash
        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 20})
              |> child(:sink, %WsForkSink{
                forker_pid: nil,
                fork_id: "nil_forker_test"
              })
          )

        # Pipeline should run without crashing
        Process.sleep(100)

        # Verify pipeline is still alive
        assert Process.alive?(pipeline)

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "handles dead forker_pid gracefully" do
        # Start a process that will die
        {:ok, dead_pid} = Agent.start(fn -> :ok end)
        Agent.stop(dead_pid)

        # Wait for process to fully terminate
        Process.sleep(10)
        refute Process.alive?(dead_pid)

        # Pipeline should handle dead forker gracefully
        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 20})
              |> child(:sink, %WsForkSink{
                forker_pid: dead_pid,
                fork_id: "dead_forker_test"
              })
          )

        # Pipeline should run without crashing even with dead forker
        Process.sleep(100)

        # Verify pipeline is still alive
        assert Process.alive?(pipeline)

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "continues processing when forker becomes unavailable mid-stream" do
        # Direct callback test for forker death handling
        # Start a process that will die during processing
        {:ok, dying_pid} = Agent.start(fn -> :ok end)

        state = %{forker_pid: dying_pid, fork_id: "dying_forker_test", frames_sent: 0, errors: 0}
        buffer1 = %Buffer{payload: <<1, 2, 3, 4>>, pts: 0}

        # First buffer should succeed
        {actions, state2} = WsForkSink.handle_buffer(:input, buffer1, %{}, state)
        assert actions == []
        assert state2.frames_sent == 1

        # Kill the forker
        Agent.stop(dying_pid)
        Process.sleep(10)

        # Second buffer should NOT crash the sink
        buffer2 = %Buffer{payload: <<5, 6, 7, 8>>, pts: 20_000_000}
        {actions2, state3} = WsForkSink.handle_buffer(:input, buffer2, %{}, state2)

        # Sink continues to work (send doesn't fail even to dead process)
        assert actions2 == []
        assert state3.frames_sent == 2
      end
    end

    describe "audio format handling" do
      test "accepts RawAudio stream format" do
        forker_pid = self()

        # SilenceSource outputs RawAudio format with push flow control
        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 20})
              |> child(:sink, %WsForkSink{
                forker_pid: forker_pid,
                fork_id: "raw_audio_test"
              })
          )

        receive do
          {:audio_frame, _, _data} -> :ok
          {:audio_frame, _data} -> :ok
        after
          200 -> flunk("Expected audio frame")
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "accepts any format (format-agnostic sink)" do
        # WsForkSink should accept any format since it just forwards raw bytes
        # We test this via callback since SilenceSource only outputs RawAudio
        forker_pid = self()
        state = %{forker_pid: forker_pid, fork_id: "g711_test", frames_sent: 0, errors: 0}
        buffer = %Buffer{payload: <<1, 2, 3, 4>>, pts: 0}

        # Simulate receiving a G711 buffer - the sink doesn't care about format
        {actions, new_state} = WsForkSink.handle_buffer(:input, buffer, %{}, state)

        assert actions == []
        assert new_state.frames_sent == 1
        assert_receive {:audio_frame, "g711_test", <<1, 2, 3, 4>>}
      end

      test "handles different sample rates" do
        forker_pid = self()

        # Test with 16kHz audio
        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{
                interval: 20,
                sample_rate: 16000,
                channels: 1
              })
              |> child(:sink, %WsForkSink{
                forker_pid: forker_pid,
                fork_id: "16khz_test"
              })
          )

        receive do
          {:audio_frame, _, audio_data} ->
            # 16kHz * 20ms = 320 samples * 2 bytes = 640 bytes
            assert byte_size(audio_data) == 640

          {:audio_frame, audio_data} ->
            assert byte_size(audio_data) == 640
        after
          200 -> flunk("Expected audio frame")
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "handles stereo audio" do
        forker_pid = self()

        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{
                interval: 20,
                sample_rate: 8000,
                channels: 2
              })
              |> child(:sink, %WsForkSink{
                forker_pid: forker_pid,
                fork_id: "stereo_test"
              })
          )

        receive do
          {:audio_frame, _, audio_data} ->
            # 8kHz * 20ms = 160 samples * 2 channels * 2 bytes = 640 bytes
            assert byte_size(audio_data) == 640

          {:audio_frame, audio_data} ->
            assert byte_size(audio_data) == 640
        after
          200 -> flunk("Expected audio frame")
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end
    end

    describe "end of stream handling" do
      test "handles end of stream gracefully" do
        forker_pid = self()

        # Use SilenceSource with push flow control
        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 20})
              |> child(:sink, %WsForkSink{
                forker_pid: forker_pid,
                fork_id: "eos_test"
              })
          )

        # Should receive at least one frame
        receive do
          {:audio_frame, _, _data} -> :ok
          {:audio_frame, _data} -> :ok
        after
          200 -> flunk("Expected audio frame")
        end

        # Pipeline should terminate cleanly
        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "handle_end_of_stream notifies forker via callback" do
        # Direct callback test for EOS behavior
        forker_pid = self()
        state = %{forker_pid: forker_pid, fork_id: "eos_notify_test", frames_sent: 5, errors: 0}

        {actions, returned_state} = WsForkSink.handle_end_of_stream(:input, %{}, state)

        assert actions == []
        assert returned_state == state
        assert_receive {:fork_end_of_stream, "eos_notify_test"}
      end

      test "handle_end_of_stream handles nil forker_pid" do
        # Should not crash when forker_pid is nil
        state = %{forker_pid: nil, fork_id: "nil_eos_test", frames_sent: 0, errors: 0}

        {actions, returned_state} = WsForkSink.handle_end_of_stream(:input, %{}, state)

        assert actions == []
        assert returned_state == state
        # No message sent when forker_pid is nil
        refute_receive {:fork_end_of_stream, _}
      end
    end

    describe "metadata handling" do
      test "forwards buffer payload regardless of metadata" do
        # Direct callback test for metadata handling
        forker_pid = self()

        buffer_with_metadata = %Buffer{
          payload: <<1, 2, 3, 4>>,
          pts: 1_000_000_000,
          dts: 1_000_000_000,
          metadata: %{custom: "data", timestamp: 12345}
        }

        state = %{forker_pid: forker_pid, fork_id: "metadata_test", frames_sent: 0, errors: 0}

        {actions, new_state} = WsForkSink.handle_buffer(:input, buffer_with_metadata, %{}, state)

        assert actions == []
        assert new_state.frames_sent == 1

        # Should receive only the payload, not the metadata
        assert_receive {:audio_frame, "metadata_test", <<1, 2, 3, 4>>}
      end
    end
  else
    # When module doesn't exist, provide clear failure messages for each test category
    describe "struct options (pending implementation)" do
      test "requires forker_pid option" do
        flunk(
          "WsForkSink module not implemented. Create: apps/parrot_media/lib/parrot_media/ws_fork_sink.ex"
        )
      end

      test "accepts nil forker_pid for graceful degradation" do
        flunk("WsForkSink module not implemented")
      end

      test "has optional fork_id with default" do
        flunk("WsForkSink module not implemented")
      end
    end

    describe "Membrane element behavior (pending implementation)" do
      test "WsForkSink is a valid Membrane Sink" do
        flunk("WsForkSink module not implemented")
      end

      test "defines input pad with push flow control" do
        flunk("WsForkSink module not implemented")
      end
    end

    describe "buffer forwarding to forker (pending implementation)" do
      test "forwards audio buffers to forker_pid as {:audio_frame, data}" do
        flunk("WsForkSink module not implemented")
      end

      test "includes fork_id in messages when configured" do
        flunk("WsForkSink module not implemented")
      end

      test "handles multiple sequential buffers" do
        flunk("WsForkSink module not implemented")
      end

      test "forwards buffers with correct payload data" do
        flunk("WsForkSink module not implemented")
      end
    end

    describe "error handling (pending implementation)" do
      test "handles forker_pid being nil gracefully" do
        flunk("WsForkSink module not implemented")
      end

      test "handles dead forker_pid gracefully" do
        flunk("WsForkSink module not implemented")
      end

      test "continues processing when forker becomes unavailable mid-stream" do
        flunk("WsForkSink module not implemented")
      end
    end

    describe "audio format handling (pending implementation)" do
      test "accepts RawAudio stream format" do
        flunk("WsForkSink module not implemented")
      end

      test "accepts any format (format-agnostic sink)" do
        flunk("WsForkSink module not implemented")
      end

      test "handles different sample rates" do
        flunk("WsForkSink module not implemented")
      end

      test "handles stereo audio" do
        flunk("WsForkSink module not implemented")
      end
    end

    describe "end of stream handling (pending implementation)" do
      test "handles end of stream gracefully" do
        flunk("WsForkSink module not implemented")
      end

      test "optionally notifies forker of end of stream" do
        flunk("WsForkSink module not implemented")
      end
    end

    describe "metadata handling (pending implementation)" do
      test "forwards buffer payload regardless of metadata" do
        flunk("WsForkSink module not implemented")
      end
    end
  end
end
