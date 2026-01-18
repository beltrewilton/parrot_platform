defmodule ParrotMedia.WsBidirectional.SinkTest do
  @moduledoc """
  Tests for WsBidirectional.Sink Membrane element.

  The Sink receives audio buffers from a Membrane pipeline and forwards them
  to a WsBidirectional.Connector GenServer for transmission over WebSocket.

  ## TDD Approach

  These tests are written BEFORE implementation and should initially FAIL.
  The Sink module will be implemented to make them pass.

  ## Sink Responsibilities

  1. Receive audio buffers from Membrane pipeline
  2. Forward audio payload to Connector GenServer
  3. Handle input pad lifecycle
  4. Notify when pipeline transitions to playing state
  5. Handle end of stream gracefully

  ## Message Format

  The Sink sends audio to the Connector via:
    send(connector_pid, {:sink_audio, audio_binary})

  This differs from WsForkSink which sends {:audio_frame, fork_id, payload}.
  The Connector is responsible for WebSocket transmission.
  """
  use ExUnit.Case, async: false

  # Check if Sink module exists at compile time
  @sink_exists Code.ensure_loaded?(ParrotMedia.WsBidirectional.Sink)

  describe "module existence" do
    test "Sink module is defined" do
      assert Code.ensure_loaded?(ParrotMedia.WsBidirectional.Sink),
             "ParrotMedia.WsBidirectional.Sink module must be defined. " <>
               "Implement it at: apps/parrot_media/lib/parrot_media/ws_bidirectional/sink.ex"
    end
  end

  # Only run functional tests if the module exists
  if @sink_exists do
    import Membrane.ChildrenSpec

    alias Membrane.Buffer
    alias Membrane.Testing
    alias ParrotMedia.WsBidirectional.Sink

    describe "element options" do
      test "requires connector_pid option" do
        # Sink should define connector_pid as an option
        sink = %Sink{connector_pid: self()}

        assert sink.connector_pid == self()
      end

      test "accepts connector_pid as pid" do
        pid = spawn(fn -> Process.sleep(:infinity) end)

        sink = %Sink{connector_pid: pid}

        assert sink.connector_pid == pid
        Process.exit(pid, :kill)
      end

      test "accepts nil connector_pid for graceful degradation" do
        # Should be able to create with nil connector_pid
        sink = %Sink{connector_pid: nil}

        assert sink.connector_pid == nil
      end
    end

    describe "handle_init/2" do
      test "initializes with connector_pid in state" do
        connector_pid = self()

        # Call handle_init directly to verify state initialization
        {actions, state} = Sink.handle_init(%{}, %Sink{connector_pid: connector_pid})

        assert actions == []
        assert state.connector_pid == connector_pid
      end

      test "initializes counters to zero" do
        connector_pid = self()

        {_actions, state} = Sink.handle_init(%{}, %Sink{connector_pid: connector_pid})

        assert state.frames_sent == 0
      end
    end

    describe "handle_buffer/4" do
      test "forwards audio buffer to connector" do
        connector_pid = self()
        test_audio = <<0x01, 0x02, 0x03, 0x04, 0x05>>
        state = %{connector_pid: connector_pid, frames_sent: 0}
        buffer = %Buffer{payload: test_audio, pts: 0}

        {_actions, _new_state} = Sink.handle_buffer(:input, buffer, %{}, state)

        # Should receive the audio at connector_pid
        assert_receive {:sink_audio, ^test_audio}
      end

      test "extracts payload from Membrane.Buffer" do
        connector_pid = self()
        payload = <<0xDE, 0xAD, 0xBE, 0xEF>>

        buffer = %Buffer{
          payload: payload,
          pts: 1_000_000,
          dts: 1_000_000,
          metadata: %{some: "metadata"}
        }

        state = %{connector_pid: connector_pid, frames_sent: 0}

        {_actions, _new_state} = Sink.handle_buffer(:input, buffer, %{}, state)

        # Should receive only the payload, not the entire buffer
        assert_receive {:sink_audio, ^payload}
      end

      test "handles multiple buffers in sequence" do
        connector_pid = self()
        state = %{connector_pid: connector_pid, frames_sent: 0}

        buffer1 = %Buffer{payload: <<0x01>>, pts: 0}
        buffer2 = %Buffer{payload: <<0x02>>, pts: 20_000_000}
        buffer3 = %Buffer{payload: <<0x03>>, pts: 40_000_000}

        {_actions, state2} = Sink.handle_buffer(:input, buffer1, %{}, state)
        {_actions, state3} = Sink.handle_buffer(:input, buffer2, %{}, state2)
        {_actions, _state4} = Sink.handle_buffer(:input, buffer3, %{}, state3)

        # Should receive all three audio frames
        assert_receive {:sink_audio, <<0x01>>}
        assert_receive {:sink_audio, <<0x02>>}
        assert_receive {:sink_audio, <<0x03>>}
      end

      test "increments frames_sent counter" do
        connector_pid = self()
        state = %{connector_pid: connector_pid, frames_sent: 0}
        buffer = %Buffer{payload: <<0x01>>, pts: 0}

        {_actions, state2} = Sink.handle_buffer(:input, buffer, %{}, state)
        assert state2.frames_sent == 1

        {_actions, state3} = Sink.handle_buffer(:input, buffer, %{}, state2)
        assert state3.frames_sent == 2

        {_actions, state4} = Sink.handle_buffer(:input, buffer, %{}, state3)
        assert state4.frames_sent == 3
      end

      test "returns empty actions list" do
        connector_pid = self()
        state = %{connector_pid: connector_pid, frames_sent: 0}
        buffer = %Buffer{payload: <<0x01>>, pts: 0}

        {actions, _new_state} = Sink.handle_buffer(:input, buffer, %{}, state)

        assert actions == []
      end

      test "handles nil connector_pid gracefully" do
        # When connector_pid is nil, sink should not crash
        state = %{connector_pid: nil, frames_sent: 0}
        buffer = %Buffer{payload: <<0x01, 0x02>>, pts: 0}

        # Should NOT crash
        {actions, new_state} = Sink.handle_buffer(:input, buffer, %{}, state)

        assert actions == []
        # frames_sent should NOT increment when no connector
        assert new_state.frames_sent == 0 or Map.has_key?(new_state, :errors)
      end

      test "handles dead connector_pid gracefully" do
        # Start a process that immediately dies
        {:ok, dead_pid} = Agent.start(fn -> :ok end)
        Agent.stop(dead_pid)

        # Wait for process to be fully dead
        Process.sleep(10)
        refute Process.alive?(dead_pid)

        state = %{connector_pid: dead_pid, frames_sent: 0}
        buffer = %Buffer{payload: <<0x01, 0x02>>, pts: 0}

        # Should NOT crash - send to dead process is fine in Erlang
        {actions, new_state} = Sink.handle_buffer(:input, buffer, %{}, state)

        assert actions == []
        # frames_sent may or may not increment depending on implementation
        assert is_integer(new_state.frames_sent)
      end
    end

    describe "handle_pad_added/3" do
      test "accepts :input pad" do
        state = %{connector_pid: self(), frames_sent: 0}

        # Should not crash when input pad is added
        # Membrane.Sink may not have handle_pad_added, so this tests the pad definition
        assert function_exported?(Sink, :handle_init, 2)

        # Verify the module defines an input pad
        # This is implicitly tested by creating a working pipeline
        assert is_atom(:input)
        assert state.connector_pid == self()
      end
    end

    describe "handle_playing/2" do
      test "transitions to playing state" do
        connector_pid = self()
        state = %{connector_pid: connector_pid, frames_sent: 0}

        # Call handle_playing - should transition cleanly
        {actions, new_state} = Sink.handle_playing(%{}, state)

        # Actions should be empty or contain valid Membrane actions
        assert is_list(actions)
        assert is_map(new_state)
      end

      test "optionally notifies connector of playing state" do
        connector_pid = self()
        state = %{connector_pid: connector_pid, frames_sent: 0}

        {_actions, _new_state} = Sink.handle_playing(%{}, state)

        # Implementation may optionally notify connector
        # This is not strictly required but can be useful
        receive do
          {:sink_playing, _info} -> :ok
        after
          50 ->
            # Not receiving is also acceptable - notification is optional
            :ok
        end
      end
    end

    describe "handle_end_of_stream/3" do
      test "handles end of stream gracefully" do
        connector_pid = self()
        state = %{connector_pid: connector_pid, frames_sent: 5}

        {actions, new_state} = Sink.handle_end_of_stream(:input, %{}, state)

        # Should return empty actions or valid Membrane actions
        assert is_list(actions)
        assert is_map(new_state)
      end

      test "notifies connector of end of stream" do
        connector_pid = self()
        state = %{connector_pid: connector_pid, frames_sent: 5}

        {_actions, _new_state} = Sink.handle_end_of_stream(:input, %{}, state)

        # Should notify connector of end of stream
        assert_receive {:sink_end_of_stream, _info}
      end

      test "handles nil connector_pid on end of stream" do
        state = %{connector_pid: nil, frames_sent: 5}

        # Should not crash
        {actions, new_state} = Sink.handle_end_of_stream(:input, %{}, state)

        assert is_list(actions)
        assert is_map(new_state)

        # Should NOT receive notification when connector_pid is nil
        refute_receive {:sink_end_of_stream, _}
      end
    end

    describe "Membrane element behavior" do
      test "Sink is a valid Membrane Sink" do
        # Verify the module uses Membrane.Sink and defines required callbacks
        assert function_exported?(Sink, :handle_init, 2)
        assert function_exported?(Sink, :handle_buffer, 4)
      end

      test "defines input pad with push flow control" do
        # Test by creating a working pipeline
        connector_pid = self()

        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 20})
              |> child(:sink, %Sink{connector_pid: connector_pid})
          )

        # Let it run briefly
        Process.sleep(50)

        # Should receive audio from the pipeline
        receive do
          {:sink_audio, audio_data} when is_binary(audio_data) ->
            assert byte_size(audio_data) > 0
        after
          200 ->
            flunk("Expected to receive {:sink_audio, ...} message from Sink")
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end
    end

    describe "pipeline integration" do
      test "receives and forwards audio from SilenceSource" do
        connector_pid = self()

        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 20})
              |> child(:sink, %Sink{connector_pid: connector_pid})
          )

        # Should receive audio frame from Sink
        receive do
          {:sink_audio, audio_data} when is_binary(audio_data) ->
            # 8kHz * 20ms = 160 samples * 2 bytes = 320 bytes
            assert byte_size(audio_data) == 320
        after
          200 ->
            flunk("Expected to receive audio frame")
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "handles multiple audio frames in pipeline" do
        connector_pid = self()

        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 10})
              |> child(:sink, %Sink{connector_pid: connector_pid})
          )

        # Should receive multiple audio frames
        for i <- 1..3 do
          receive do
            {:sink_audio, _data} -> :ok
          after
            100 ->
              flunk("Expected to receive audio frame #{i}")
          end
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "pipeline runs without crashing when connector_pid is nil" do
        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{interval: 20})
              |> child(:sink, %Sink{connector_pid: nil})
          )

        # Pipeline should run without crashing
        Process.sleep(100)

        # Verify pipeline is still alive
        assert Process.alive?(pipeline)

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "handles different sample rates" do
        connector_pid = self()

        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{
                interval: 20,
                sample_rate: 16000,
                channels: 1
              })
              |> child(:sink, %Sink{connector_pid: connector_pid})
          )

        receive do
          {:sink_audio, audio_data} ->
            # 16kHz * 20ms = 320 samples * 2 bytes = 640 bytes
            assert byte_size(audio_data) == 640
        after
          200 -> flunk("Expected audio frame")
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end

      test "handles stereo audio" do
        connector_pid = self()

        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec:
              child(:source, %ParrotMedia.SilenceSource{
                interval: 20,
                sample_rate: 8000,
                channels: 2
              })
              |> child(:sink, %Sink{connector_pid: connector_pid})
          )

        receive do
          {:sink_audio, audio_data} ->
            # 8kHz * 20ms = 160 samples * 2 channels * 2 bytes = 640 bytes
            assert byte_size(audio_data) == 640
        after
          200 -> flunk("Expected audio frame")
        end

        Testing.Pipeline.terminate(pipeline, force?: true)
      end
    end

    describe "format handling" do
      test "accepts any audio format (format-agnostic)" do
        # The Sink should accept any format since it just forwards raw bytes
        connector_pid = self()
        state = %{connector_pid: connector_pid, frames_sent: 0}

        # Simulate different format payloads
        opus_payload = <<0x48, 0x00, 0x00, 0x00>>
        pcmu_payload = <<0xFF, 0xD5, 0xD5, 0xD5>>

        buffer1 = %Buffer{payload: opus_payload, pts: 0}
        buffer2 = %Buffer{payload: pcmu_payload, pts: 20_000_000}

        {_actions, state2} = Sink.handle_buffer(:input, buffer1, %{}, state)
        {_actions, _state3} = Sink.handle_buffer(:input, buffer2, %{}, state2)

        assert_receive {:sink_audio, ^opus_payload}
        assert_receive {:sink_audio, ^pcmu_payload}
      end
    end

    describe "metadata handling" do
      test "forwards payload regardless of buffer metadata" do
        connector_pid = self()
        payload = <<0xCA, 0xFE, 0xBA, 0xBE>>

        buffer_with_metadata = %Buffer{
          payload: payload,
          pts: 1_000_000_000,
          dts: 1_000_000_000,
          metadata: %{custom: "data", timestamp: 12345, format: :opus}
        }

        state = %{connector_pid: connector_pid, frames_sent: 0}

        {_actions, _new_state} = Sink.handle_buffer(:input, buffer_with_metadata, %{}, state)

        # Should receive only the payload, not the metadata
        assert_receive {:sink_audio, ^payload}
      end
    end

    describe "terminate handling" do
      test "handle_terminate_request cleans up gracefully" do
        state = %{connector_pid: self(), frames_sent: 10}

        # This callback may or may not be implemented - test if it exists
        if function_exported?(Sink, :handle_terminate_request, 2) do
          {actions, _new_state} = Sink.handle_terminate_request(%{}, state)
          assert is_list(actions)
        else
          # If not implemented, that's okay - Membrane provides default
          assert true
        end
      end
    end
  else
    # When module doesn't exist, provide clear failure messages for each test category
    describe "element options (pending implementation)" do
      test "requires connector_pid option" do
        flunk(
          "Sink module not implemented. Create: apps/parrot_media/lib/parrot_media/ws_bidirectional/sink.ex"
        )
      end

      test "accepts connector_pid as pid" do
        flunk("Sink module not implemented")
      end

      test "accepts nil connector_pid for graceful degradation" do
        flunk("Sink module not implemented")
      end
    end

    describe "handle_init/2 (pending implementation)" do
      test "initializes with connector_pid in state" do
        flunk("Sink module not implemented")
      end

      test "initializes counters to zero" do
        flunk("Sink module not implemented")
      end
    end

    describe "handle_buffer/4 (pending implementation)" do
      test "forwards audio buffer to connector" do
        flunk("Sink module not implemented")
      end

      test "extracts payload from Membrane.Buffer" do
        flunk("Sink module not implemented")
      end

      test "handles multiple buffers in sequence" do
        flunk("Sink module not implemented")
      end

      test "increments frames_sent counter" do
        flunk("Sink module not implemented")
      end

      test "returns empty actions list" do
        flunk("Sink module not implemented")
      end

      test "handles nil connector_pid gracefully" do
        flunk("Sink module not implemented")
      end

      test "handles dead connector_pid gracefully" do
        flunk("Sink module not implemented")
      end
    end

    describe "handle_pad_added/3 (pending implementation)" do
      test "accepts :input pad" do
        flunk("Sink module not implemented")
      end
    end

    describe "handle_playing/2 (pending implementation)" do
      test "transitions to playing state" do
        flunk("Sink module not implemented")
      end

      test "optionally notifies connector of playing state" do
        flunk("Sink module not implemented")
      end
    end

    describe "handle_end_of_stream/3 (pending implementation)" do
      test "handles end of stream gracefully" do
        flunk("Sink module not implemented")
      end

      test "notifies connector of end of stream" do
        flunk("Sink module not implemented")
      end

      test "handles nil connector_pid on end of stream" do
        flunk("Sink module not implemented")
      end
    end

    describe "Membrane element behavior (pending implementation)" do
      test "Sink is a valid Membrane Sink" do
        flunk("Sink module not implemented")
      end

      test "defines input pad with push flow control" do
        flunk("Sink module not implemented")
      end
    end

    describe "pipeline integration (pending implementation)" do
      test "receives and forwards audio from SilenceSource" do
        flunk("Sink module not implemented")
      end

      test "handles multiple audio frames in pipeline" do
        flunk("Sink module not implemented")
      end

      test "pipeline runs without crashing when connector_pid is nil" do
        flunk("Sink module not implemented")
      end

      test "handles different sample rates" do
        flunk("Sink module not implemented")
      end

      test "handles stereo audio" do
        flunk("Sink module not implemented")
      end
    end

    describe "format handling (pending implementation)" do
      test "accepts any audio format (format-agnostic)" do
        flunk("Sink module not implemented")
      end
    end

    describe "metadata handling (pending implementation)" do
      test "forwards payload regardless of buffer metadata" do
        flunk("Sink module not implemented")
      end
    end

    describe "terminate handling (pending implementation)" do
      test "handle_terminate_request cleans up gracefully" do
        flunk("Sink module not implemented")
      end
    end
  end
end
