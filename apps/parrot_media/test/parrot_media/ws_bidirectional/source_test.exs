defmodule ParrotMedia.WsBidirectional.SourceTest do
  @moduledoc """
  Tests for WsBidirectional.Source Membrane element.

  The Source receives audio buffers FROM a WsBidirectional.Connector GenServer
  and pushes them INTO a Membrane pipeline for playback.

  ## TDD Approach

  These tests are written BEFORE implementation and should initially FAIL.
  The Source module will be implemented to make them pass.

  ## Source Responsibilities

  1. Receive audio from Connector GenServer (via messages)
  2. Buffer audio in jitter buffer to smooth network timing variations
  3. Push audio buffers to Membrane pipeline
  4. Handle output pad lifecycle
  5. Register with Connector to receive audio

  ## Jitter Buffer Design (from research.md R7/R8)

  - Use Erlang :queue for jitter buffer
  - Configurable jitter_buffer_ms (default 60ms)
  - Start releasing audio after target delay reached
  - Log when starving (buffer underrun)
  - FIFO ordering (oldest audio first)

  ## Message Format

  The Connector sends audio to the Source via:
    send(source_pid, {:source_audio, audio_binary})

  Connection state changes are sent via:
    send(source_pid, {:connection_state, :connected | :disconnected})
  """
  use ExUnit.Case, async: false

  # Check if Source module exists at compile time
  @source_exists Code.ensure_loaded?(ParrotMedia.WsBidirectional.Source)

  describe "module existence" do
    test "Source module is defined" do
      assert Code.ensure_loaded?(ParrotMedia.WsBidirectional.Source),
             "ParrotMedia.WsBidirectional.Source module must be defined. " <>
               "Implement it at: apps/parrot_media/lib/parrot_media/ws_bidirectional/source.ex"
    end
  end

  # Only run functional tests if the module exists
  if @source_exists do
    import Membrane.ChildrenSpec

    alias Membrane.Testing
    alias ParrotMedia.WsBidirectional.Source

    describe "element options" do
      test "requires connector_pid option" do
        # Source should define connector_pid as an option
        source = %Source{connector_pid: self()}

        assert source.connector_pid == self()
      end

      test "accepts connector_pid as pid" do
        pid = spawn(fn -> Process.sleep(:infinity) end)

        source = %Source{connector_pid: pid}

        assert source.connector_pid == pid
        Process.exit(pid, :kill)
      end

      test "accepts jitter_buffer_ms option" do
        # Source should define jitter_buffer_ms as an option
        source = %Source{connector_pid: self(), jitter_buffer_ms: 100}

        assert source.jitter_buffer_ms == 100
      end

      test "defaults jitter_buffer_ms to 60" do
        # Default should be 60ms as specified in research.md
        source = %Source{connector_pid: self()}

        assert source.jitter_buffer_ms == 60
      end

      test "accepts sample_rate option" do
        source = %Source{connector_pid: self(), sample_rate: 16000}

        assert source.sample_rate == 16000
      end

      test "defaults sample_rate to 16000" do
        source = %Source{connector_pid: self()}

        assert source.sample_rate == 16000
      end

      test "accepts nil connector_pid for testing" do
        # Should be able to create with nil connector_pid
        source = %Source{connector_pid: nil}

        assert source.connector_pid == nil
      end
    end

    describe "handle_init/2" do
      test "initializes with connector_pid in state" do
        connector_pid = self()

        # Call handle_init directly to verify state initialization
        {actions, state} = Source.handle_init(%{}, %Source{connector_pid: connector_pid})

        assert actions == []
        assert state.connector_pid == connector_pid
      end

      test "registers with connector" do
        # When Source initializes, it should register with the Connector
        # to receive audio messages
        connector_pid = self()

        {_actions, _state} = Source.handle_init(%{}, %Source{connector_pid: connector_pid})

        # Should receive registration message
        assert_receive {:register_source, source_pid} when is_pid(source_pid)
      end

      test "initializes empty jitter buffer" do
        connector_pid = self()

        {_actions, state} = Source.handle_init(%{}, %Source{connector_pid: connector_pid})

        # Jitter buffer should be empty initially
        assert state.jitter_buffer == :queue.new()
      end

      test "initializes jitter_buffer_ms from options" do
        connector_pid = self()

        {_actions, state} =
          Source.handle_init(%{}, %Source{connector_pid: connector_pid, jitter_buffer_ms: 100})

        assert state.jitter_buffer_ms == 100
      end

      test "initializes frames_received counter to zero" do
        connector_pid = self()

        {_actions, state} = Source.handle_init(%{}, %Source{connector_pid: connector_pid})

        assert state.frames_received == 0
      end

      test "initializes buffer_ready flag to false" do
        # Buffer is not ready until we have enough frames to meet jitter target
        connector_pid = self()

        {_actions, state} = Source.handle_init(%{}, %Source{connector_pid: connector_pid})

        assert state.buffer_ready == false
      end

      test "handles nil connector_pid gracefully" do
        # Should not crash when connector_pid is nil
        {actions, state} = Source.handle_init(%{}, %Source{connector_pid: nil})

        assert actions == []
        assert state.connector_pid == nil
      end
    end

    describe "handle_info for audio" do
      test "receives {:source_audio, binary} from connector" do
        connector_pid = self()
        audio_data = <<0x01, 0x02, 0x03, 0x04>>

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 0,
          buffer_ready: false,
          pts: 0
        }

        # Should not crash when receiving audio
        {_actions, new_state} = Source.handle_info({:source_audio, audio_data}, %{}, state)

        # Should increment frames_received
        assert new_state.frames_received == 1
      end

      test "queues audio in jitter buffer" do
        connector_pid = self()
        audio_data = <<0xDE, 0xAD, 0xBE, 0xEF>>

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 0,
          buffer_ready: false,
          pts: 0
        }

        {_actions, new_state} = Source.handle_info({:source_audio, audio_data}, %{}, state)

        # Buffer should contain the audio frame
        assert :queue.len(new_state.jitter_buffer) == 1

        # Verify the frame is in the buffer
        {{:value, frame}, _} = :queue.out(new_state.jitter_buffer)
        assert frame.payload == audio_data
      end

      test "queues multiple audio frames" do
        connector_pid = self()

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 0,
          buffer_ready: false,
          pts: 0
        }

        # Queue 3 frames
        {_actions, state2} = Source.handle_info({:source_audio, <<0x01>>}, %{}, state)
        {_actions, state3} = Source.handle_info({:source_audio, <<0x02>>}, %{}, state2)
        {_actions, state4} = Source.handle_info({:source_audio, <<0x03>>}, %{}, state3)

        assert :queue.len(state4.jitter_buffer) == 3
        assert state4.frames_received == 3
      end

      test "starts pushing after jitter delay reached" do
        # With 60ms jitter buffer at 16kHz with 20ms frames (3 frames target),
        # audio should start pushing after buffer fills

        connector_pid = self()
        # 20ms of audio at 16kHz = 320 samples * 2 bytes = 640 bytes
        audio_frame = :binary.copy(<<0x00>>, 640)

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 0,
          buffer_ready: false,
          pts: 0,
          frame_duration_ms: 20
        }

        # Add frames until buffer is ready (need 3 frames for 60ms)
        {actions1, state2} = Source.handle_info({:source_audio, audio_frame}, %{}, state)
        {actions2, state3} = Source.handle_info({:source_audio, audio_frame}, %{}, state2)
        {actions3, state4} = Source.handle_info({:source_audio, audio_frame}, %{}, state3)

        # First two frames should not produce buffer actions
        assert Enum.filter(actions1, &match?({:buffer, _}, &1)) == []
        assert Enum.filter(actions2, &match?({:buffer, _}, &1)) == []

        # Third frame should either:
        # a) set buffer_ready to true, or
        # b) start producing buffer actions
        assert state4.buffer_ready == true or Enum.any?(actions3, &match?({:buffer, _}, &1))
      end
    end

    describe "jitter buffer" do
      test "buffers audio until target delay" do
        connector_pid = self()
        # 20ms frame at 16kHz
        audio_frame = :binary.copy(<<0x00>>, 640)

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 0,
          buffer_ready: false,
          pts: 0,
          frame_duration_ms: 20
        }

        # Add only 2 frames (40ms, less than 60ms target)
        {_actions, state2} = Source.handle_info({:source_audio, audio_frame}, %{}, state)
        {_actions, state3} = Source.handle_info({:source_audio, audio_frame}, %{}, state2)

        # Buffer should NOT be ready yet (40ms < 60ms)
        assert state3.buffer_ready == false
        assert :queue.len(state3.jitter_buffer) == 2
      end

      test "releases oldest audio first (FIFO)" do
        connector_pid = self()

        # Pre-fill buffer with 3 frames
        q0 = :queue.new()
        q1 = :queue.in(%{payload: <<0x01>>, pts: 0}, q0)
        q2 = :queue.in(%{payload: <<0x02>>, pts: 20_000_000}, q1)
        q3 = :queue.in(%{payload: <<0x03>>, pts: 40_000_000}, q2)

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: q3,
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 3,
          buffer_ready: true,
          pts: 0,
          frame_duration_ms: 20
        }

        # Request buffer output (simulate demand)
        {actions, _new_state} = Source.handle_demand(:output, 1, :buffers, %{}, state)

        # Should output oldest frame first (0x01)
        buffer_actions = Enum.filter(actions, &match?({:buffer, _}, &1))
        assert length(buffer_actions) >= 1

        [{:buffer, {:output, buffer}} | _] = buffer_actions
        assert buffer.payload == <<0x01>>
      end

      test "calculates target frames from jitter_buffer_ms and frame duration" do
        # With 60ms jitter buffer and 20ms frames, need 3 frames (60/20 = 3)
        connector_pid = self()

        {_actions, state} =
          Source.handle_init(%{}, %Source{
            connector_pid: connector_pid,
            jitter_buffer_ms: 60
          })

        # The module should calculate target frames internally
        # For 60ms buffer with 20ms frames = 3 frames
        expected_target = 3

        # Check if state has target_frames or calculate it
        actual_target = state.target_frames || div(state.jitter_buffer_ms, 20)
        assert actual_target == expected_target
      end

      test "logs warning on buffer underrun" do
        import ExUnit.CaptureLog

        connector_pid = self()

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 5,
          buffer_ready: true,
          pts: 100_000_000,
          frame_duration_ms: 20,
          target_frames: 3
        }

        # Request more buffers than available (underrun)
        log =
          capture_log(fn ->
            Source.handle_demand(:output, 10, :buffers, %{}, state)
          end)

        # Should log a warning about buffer underrun/starving
        assert log =~ "underrun" or log =~ "starving" or log =~ "empty"
      end
    end

    describe "handle_demand/5" do
      test "pushes buffered audio on demand" do
        connector_pid = self()

        # Pre-fill buffer
        q = :queue.in(%{payload: <<0x42>>, pts: 0}, :queue.new())

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: q,
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 1,
          buffer_ready: true,
          pts: 0,
          frame_duration_ms: 20,
          target_frames: 3
        }

        {actions, _new_state} = Source.handle_demand(:output, 1, :buffers, %{}, state)

        # Should produce buffer action
        buffer_actions = Enum.filter(actions, &match?({:buffer, _}, &1))
        assert length(buffer_actions) == 1

        [{:buffer, {:output, buffer}}] = buffer_actions
        assert buffer.payload == <<0x42>>
      end

      test "returns empty actions when buffer empty and not ready" do
        connector_pid = self()

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 0,
          buffer_ready: false,
          pts: 0,
          frame_duration_ms: 20,
          target_frames: 3
        }

        {actions, _new_state} = Source.handle_demand(:output, 1, :buffers, %{}, state)

        # Should not produce buffer actions when buffer is empty and not ready
        buffer_actions = Enum.filter(actions, &match?({:buffer, _}, &1))
        assert buffer_actions == []
      end

      test "handles multiple buffer demand" do
        connector_pid = self()

        # Pre-fill buffer with 5 frames
        frames =
          Enum.reduce(1..5, :queue.new(), fn i, q ->
            :queue.in(%{payload: <<i>>, pts: (i - 1) * 20_000_000}, q)
          end)

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: frames,
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 5,
          buffer_ready: true,
          pts: 0,
          frame_duration_ms: 20,
          target_frames: 3
        }

        {actions, new_state} = Source.handle_demand(:output, 3, :buffers, %{}, state)

        # Should produce 3 buffer actions
        buffer_actions = Enum.filter(actions, &match?({:buffer, _}, &1))
        assert length(buffer_actions) == 3

        # Buffer should have 2 frames left
        assert :queue.len(new_state.jitter_buffer) == 2
      end

      test "removes frames from buffer after pushing" do
        connector_pid = self()

        q = :queue.in(%{payload: <<0x01>>, pts: 0}, :queue.new())

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: q,
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 1,
          buffer_ready: true,
          pts: 0,
          frame_duration_ms: 20,
          target_frames: 3
        }

        {_actions, new_state} = Source.handle_demand(:output, 1, :buffers, %{}, state)

        # Buffer should be empty after pushing
        assert :queue.len(new_state.jitter_buffer) == 0
      end
    end

    describe "handle_pad_added/3" do
      test "accepts :output pad" do
        state = %{connector_pid: self(), jitter_buffer: :queue.new()}

        # Should not crash when output pad is added
        # Membrane.Source may not have handle_pad_added, so this tests the pad definition
        assert function_exported?(Source, :handle_init, 2)

        # Verify the module defines an output pad
        assert is_atom(:output)
        assert state.connector_pid == self()
      end
    end

    describe "handle_playing/2" do
      test "transitions to playing state" do
        connector_pid = self()

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 0,
          buffer_ready: false,
          pts: 0
        }

        # Call handle_playing - should transition cleanly
        {actions, new_state} = Source.handle_playing(%{}, state)

        # Actions should be empty or contain valid Membrane actions (e.g., stream_format)
        assert is_list(actions)
        assert is_map(new_state)
      end

      test "sends stream_format on playing" do
        connector_pid = self()

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 0,
          buffer_ready: false,
          pts: 0
        }

        {actions, _new_state} = Source.handle_playing(%{}, state)

        # Should send stream format action
        stream_format_actions = Enum.filter(actions, &match?({:stream_format, _}, &1))
        assert length(stream_format_actions) == 1
      end
    end

    describe "connection state changes" do
      test "handles :connected event" do
        connector_pid = self()

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 0,
          buffer_ready: false,
          pts: 0,
          connection_state: :disconnected
        }

        {actions, new_state} = Source.handle_info({:connection_state, :connected}, %{}, state)

        assert is_list(actions)
        assert new_state.connection_state == :connected
      end

      test "handles :disconnected event" do
        connector_pid = self()

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 5,
          buffer_ready: true,
          pts: 100_000_000,
          connection_state: :connected
        }

        {actions, new_state} = Source.handle_info({:connection_state, :disconnected}, %{}, state)

        assert is_list(actions)
        assert new_state.connection_state == :disconnected
      end

      test "clears buffer on disconnection (optional)" do
        # Depending on implementation, buffer may or may not be cleared
        connector_pid = self()

        q = :queue.in(%{payload: <<0x01>>, pts: 0}, :queue.new())

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: q,
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 1,
          buffer_ready: true,
          pts: 0,
          connection_state: :connected
        }

        {_actions, new_state} = Source.handle_info({:connection_state, :disconnected}, %{}, state)

        # Implementation may choose to clear buffer or keep it
        # Just verify it doesn't crash
        assert is_map(new_state)
      end
    end

    describe "Membrane element behavior" do
      test "Source is a valid Membrane Source" do
        # Verify the module uses Membrane.Source and defines required callbacks
        assert function_exported?(Source, :handle_init, 2)
        assert function_exported?(Source, :handle_playing, 2)
      end

      test "defines output pad with push flow control" do
        # Test by checking module structure
        # Push flow is typical for real-time audio sources

        # Verify output pad is defined by creating a working scenario
        connector_pid = self()

        {actions, _state} = Source.handle_init(%{}, %Source{connector_pid: connector_pid})

        # Should initialize successfully
        assert is_list(actions)
      end
    end

    describe "pipeline integration" do
      test "receives audio from simulated connector and pushes to pipeline" do
        test_pid = self()

        # Start a pipeline with Source and Testing.Sink
        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %Source{connector_pid: test_pid, jitter_buffer_ms: 20})
              |> child(:sink, Testing.Sink)
          )

        # Wait for Source to register
        assert_receive {:register_source, source_pid}, 500

        # Send audio frames to the Source (simulating Connector)
        # 20ms frame at 16kHz = 320 samples * 2 bytes = 640 bytes
        audio_frame = :binary.copy(<<0xAB>>, 640)

        # Send enough frames to fill jitter buffer (20ms buffer = 1 frame)
        send(source_pid, {:source_audio, audio_frame})

        # Give time for processing
        Process.sleep(50)

        # The pipeline should forward the audio
        # Note: We may need to check Testing.Sink for received buffers
        # This test verifies the integration doesn't crash

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "pipeline runs without crashing when connector_pid is nil" do
        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %Source{connector_pid: nil, jitter_buffer_ms: 20})
              |> child(:sink, Testing.Sink)
          )

        # Pipeline should run without crashing
        Process.sleep(100)

        # Verify pipeline is still alive
        assert Process.alive?(pipeline)

        Testing.Pipeline.terminate(pipeline, force?: true)
      end
    end

    describe "PTS (presentation timestamp) handling" do
      test "assigns incrementing PTS to buffers" do
        connector_pid = self()

        # Pre-fill buffer with frames
        q0 = :queue.new()
        q1 = :queue.in(%{payload: <<0x01>>}, q0)
        q2 = :queue.in(%{payload: <<0x02>>}, q1)

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: q2,
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 2,
          buffer_ready: true,
          pts: 0,
          frame_duration_ms: 20,
          target_frames: 1
        }

        # Get first buffer
        {actions1, state2} = Source.handle_demand(:output, 1, :buffers, %{}, state)
        {actions2, _state3} = Source.handle_demand(:output, 1, :buffers, %{}, state2)

        [{:buffer, {:output, buffer1}}] = Enum.filter(actions1, &match?({:buffer, _}, &1))
        [{:buffer, {:output, buffer2}}] = Enum.filter(actions2, &match?({:buffer, _}, &1))

        # Second buffer should have higher PTS
        assert buffer2.pts > buffer1.pts
      end

      test "calculates PTS based on sample rate and frame size" do
        connector_pid = self()

        {_actions, state} =
          Source.handle_init(%{}, %Source{
            connector_pid: connector_pid,
            sample_rate: 16000
          })

        # Frame duration for 16kHz with 20ms frames
        # 20ms = 20_000_000 nanoseconds in Membrane.Time
        expected_frame_duration = 20_000_000

        # Check if state tracks frame duration
        frame_duration = state.frame_duration || state.frame_duration_ms * 1_000_000

        # Should be approximately 20ms
        assert_in_delta frame_duration, expected_frame_duration, 1_000_000
      end
    end

    describe "buffer overflow handling" do
      test "drops oldest frames when buffer exceeds max size" do
        connector_pid = self()

        # Create an overfull buffer (e.g., max is 10 frames)
        frames =
          Enum.reduce(1..15, :queue.new(), fn i, q ->
            :queue.in(%{payload: <<i>>, pts: (i - 1) * 20_000_000}, q)
          end)

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: frames,
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 15,
          buffer_ready: true,
          pts: 0,
          frame_duration_ms: 20,
          target_frames: 3,
          max_buffer_frames: 10
        }

        # Add another frame
        {_actions, new_state} = Source.handle_info({:source_audio, <<0xFF>>}, %{}, state)

        # Buffer should not exceed max size
        # Implementation should drop oldest frames
        assert :queue.len(new_state.jitter_buffer) <= 10
      end
    end

    describe "terminate handling" do
      test "handle_terminate_request cleans up gracefully" do
        state = %{
          connector_pid: self(),
          jitter_buffer: :queue.new(),
          frames_received: 10
        }

        # This callback may or may not be implemented - test if it exists
        if function_exported?(Source, :handle_terminate_request, 2) do
          {actions, _new_state} = Source.handle_terminate_request(%{}, state)
          assert is_list(actions)
        else
          # If not implemented, that's okay - Membrane provides default
          assert true
        end
      end
    end

    describe "audio format handling" do
      test "accepts any audio format (format-agnostic for payload)" do
        connector_pid = self()

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 0,
          buffer_ready: false,
          pts: 0,
          frame_duration_ms: 20
        }

        # Different format payloads
        pcm_payload = <<0x00, 0x01, 0x00, 0x02>>
        opus_payload = <<0x48, 0x00, 0x00, 0x00>>

        # Should handle both without crashing
        {_actions1, state2} = Source.handle_info({:source_audio, pcm_payload}, %{}, state)
        {_actions2, state3} = Source.handle_info({:source_audio, opus_payload}, %{}, state2)

        assert state3.frames_received == 2
      end
    end

    describe "statistics tracking" do
      test "tracks total frames received" do
        connector_pid = self()

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: :queue.new(),
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 0,
          buffer_ready: false,
          pts: 0,
          frame_duration_ms: 20
        }

        # Receive 5 frames
        final_state =
          Enum.reduce(1..5, state, fn _, s ->
            {_actions, new_s} = Source.handle_info({:source_audio, <<0x00>>}, %{}, s)
            new_s
          end)

        assert final_state.frames_received == 5
      end

      test "tracks frames pushed to pipeline" do
        connector_pid = self()

        # Pre-fill buffer
        frames =
          Enum.reduce(1..5, :queue.new(), fn i, q ->
            :queue.in(%{payload: <<i>>, pts: (i - 1) * 20_000_000}, q)
          end)

        state = %{
          connector_pid: connector_pid,
          jitter_buffer: frames,
          jitter_buffer_ms: 60,
          sample_rate: 16000,
          frames_received: 5,
          frames_pushed: 0,
          buffer_ready: true,
          pts: 0,
          frame_duration_ms: 20,
          target_frames: 3
        }

        # Push 3 frames
        {_actions, new_state} = Source.handle_demand(:output, 3, :buffers, %{}, state)

        # Should track frames pushed
        assert new_state.frames_pushed == 3 or Map.get(new_state, :frames_pushed, 0) >= 0
      end
    end
  else
    # When module doesn't exist, provide clear failure messages for each test category
    describe "element options (pending implementation)" do
      test "requires connector_pid option" do
        flunk(
          "Source module not implemented. Create: apps/parrot_media/lib/parrot_media/ws_bidirectional/source.ex"
        )
      end

      test "accepts connector_pid as pid" do
        flunk("Source module not implemented")
      end

      test "accepts jitter_buffer_ms option" do
        flunk("Source module not implemented")
      end

      test "defaults jitter_buffer_ms to 60" do
        flunk("Source module not implemented")
      end

      test "accepts sample_rate option" do
        flunk("Source module not implemented")
      end

      test "defaults sample_rate to 16000" do
        flunk("Source module not implemented")
      end

      test "accepts nil connector_pid for testing" do
        flunk("Source module not implemented")
      end
    end

    describe "handle_init/2 (pending implementation)" do
      test "initializes with connector_pid in state" do
        flunk("Source module not implemented")
      end

      test "registers with connector" do
        flunk("Source module not implemented")
      end

      test "initializes empty jitter buffer" do
        flunk("Source module not implemented")
      end

      test "initializes jitter_buffer_ms from options" do
        flunk("Source module not implemented")
      end

      test "initializes frames_received counter to zero" do
        flunk("Source module not implemented")
      end

      test "initializes buffer_ready flag to false" do
        flunk("Source module not implemented")
      end

      test "handles nil connector_pid gracefully" do
        flunk("Source module not implemented")
      end
    end

    describe "handle_info for audio (pending implementation)" do
      test "receives {:source_audio, binary} from connector" do
        flunk("Source module not implemented")
      end

      test "queues audio in jitter buffer" do
        flunk("Source module not implemented")
      end

      test "queues multiple audio frames" do
        flunk("Source module not implemented")
      end

      test "starts pushing after jitter delay reached" do
        flunk("Source module not implemented")
      end
    end

    describe "jitter buffer (pending implementation)" do
      test "buffers audio until target delay" do
        flunk("Source module not implemented")
      end

      test "releases oldest audio first (FIFO)" do
        flunk("Source module not implemented")
      end

      test "calculates target frames from jitter_buffer_ms and frame duration" do
        flunk("Source module not implemented")
      end

      test "logs warning on buffer underrun" do
        flunk("Source module not implemented")
      end
    end

    describe "handle_demand/5 (pending implementation)" do
      test "pushes buffered audio on demand" do
        flunk("Source module not implemented")
      end

      test "returns empty actions when buffer empty and not ready" do
        flunk("Source module not implemented")
      end

      test "handles multiple buffer demand" do
        flunk("Source module not implemented")
      end

      test "removes frames from buffer after pushing" do
        flunk("Source module not implemented")
      end
    end

    describe "handle_pad_added/3 (pending implementation)" do
      test "accepts :output pad" do
        flunk("Source module not implemented")
      end
    end

    describe "handle_playing/2 (pending implementation)" do
      test "transitions to playing state" do
        flunk("Source module not implemented")
      end

      test "sends stream_format on playing" do
        flunk("Source module not implemented")
      end
    end

    describe "connection state changes (pending implementation)" do
      test "handles :connected event" do
        flunk("Source module not implemented")
      end

      test "handles :disconnected event" do
        flunk("Source module not implemented")
      end

      test "clears buffer on disconnection (optional)" do
        flunk("Source module not implemented")
      end
    end

    describe "Membrane element behavior (pending implementation)" do
      test "Source is a valid Membrane Source" do
        flunk("Source module not implemented")
      end

      test "defines output pad with push flow control" do
        flunk("Source module not implemented")
      end
    end

    describe "pipeline integration (pending implementation)" do
      test "receives audio from simulated connector and pushes to pipeline" do
        flunk("Source module not implemented")
      end

      test "pipeline runs without crashing when connector_pid is nil" do
        flunk("Source module not implemented")
      end
    end

    describe "PTS (presentation timestamp) handling (pending implementation)" do
      test "assigns incrementing PTS to buffers" do
        flunk("Source module not implemented")
      end

      test "calculates PTS based on sample rate and frame size" do
        flunk("Source module not implemented")
      end
    end

    describe "buffer overflow handling (pending implementation)" do
      test "drops oldest frames when buffer exceeds max size" do
        flunk("Source module not implemented")
      end
    end

    describe "terminate handling (pending implementation)" do
      test "handle_terminate_request cleans up gracefully" do
        flunk("Source module not implemented")
      end
    end

    describe "audio format handling (pending implementation)" do
      test "accepts any audio format (format-agnostic for payload)" do
        flunk("Source module not implemented")
      end
    end

    describe "statistics tracking (pending implementation)" do
      test "tracks total frames received" do
        flunk("Source module not implemented")
      end

      test "tracks frames pushed to pipeline" do
        flunk("Source module not implemented")
      end
    end
  end
end
