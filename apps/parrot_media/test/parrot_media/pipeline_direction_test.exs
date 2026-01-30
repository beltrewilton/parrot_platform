defmodule ParrotMedia.PipelineDirectionTest do
  @moduledoc """
  Tests for pipeline direction changes (hold/resume support).

  Directions:
  - :sendrecv - Normal bidirectional audio
  - :sendonly - We send, remote on hold (mute local playback)
  - :recvonly - We receive, we're on hold (send silence)
  - :inactive - Completely muted

  These tests verify that pipelines can change direction without
  restarting, enabling glitch-free hold/resume transitions.
  """

  use ExUnit.Case, async: true

  alias Membrane.Testing.Pipeline

  @moduletag :pipeline_direction

  describe "AlawPipeline direction changes" do
    test "accepts set_direction message" do
      # Start a minimal AlawPipeline
      {:ok, pipeline_pid} =
        start_alaw_pipeline()

      # Should accept set_direction without crashing
      send(pipeline_pid, {:set_direction, :sendonly})
      Process.sleep(50)

      # Pipeline should still be alive
      assert Process.alive?(pipeline_pid)

      Pipeline.terminate(pipeline_pid)
    end

    test "tracks direction in state" do
      {:ok, pipeline_pid} = start_alaw_pipeline()

      # Set direction to sendonly
      send(pipeline_pid, {:set_direction, :sendonly})
      Process.sleep(50)

      # Query direction
      send(pipeline_pid, {:get_direction, self()})
      assert_receive {:direction, :sendonly}, 1000

      Pipeline.terminate(pipeline_pid)
    end

    test "sendonly direction is stored" do
      {:ok, pipeline_pid} = start_alaw_pipeline()

      send(pipeline_pid, {:set_direction, :sendonly})
      Process.sleep(50)

      send(pipeline_pid, {:get_direction, self()})
      assert_receive {:direction, :sendonly}, 1000

      Pipeline.terminate(pipeline_pid)
    end

    test "recvonly direction is stored" do
      {:ok, pipeline_pid} = start_alaw_pipeline()

      send(pipeline_pid, {:set_direction, :recvonly})
      Process.sleep(50)

      send(pipeline_pid, {:get_direction, self()})
      assert_receive {:direction, :recvonly}, 1000

      Pipeline.terminate(pipeline_pid)
    end

    test "inactive direction is stored" do
      {:ok, pipeline_pid} = start_alaw_pipeline()

      send(pipeline_pid, {:set_direction, :inactive})
      Process.sleep(50)

      send(pipeline_pid, {:get_direction, self()})
      assert_receive {:direction, :inactive}, 1000

      Pipeline.terminate(pipeline_pid)
    end

    test "sendrecv direction is stored" do
      {:ok, pipeline_pid} = start_alaw_pipeline()

      # First change to something else
      send(pipeline_pid, {:set_direction, :inactive})
      Process.sleep(50)

      # Then back to sendrecv
      send(pipeline_pid, {:set_direction, :sendrecv})
      Process.sleep(50)

      send(pipeline_pid, {:get_direction, self()})
      assert_receive {:direction, :sendrecv}, 1000

      Pipeline.terminate(pipeline_pid)
    end

    test "default direction is sendrecv" do
      {:ok, pipeline_pid} = start_alaw_pipeline()

      send(pipeline_pid, {:get_direction, self()})
      assert_receive {:direction, :sendrecv}, 1000

      Pipeline.terminate(pipeline_pid)
    end
  end

  describe "OpusPipeline direction changes" do
    test "accepts set_direction message" do
      {:ok, pipeline_pid} = start_opus_pipeline()

      send(pipeline_pid, {:set_direction, :sendonly})
      Process.sleep(50)

      assert Process.alive?(pipeline_pid)

      Pipeline.terminate(pipeline_pid)
    end

    test "tracks direction in state" do
      {:ok, pipeline_pid} = start_opus_pipeline()

      send(pipeline_pid, {:set_direction, :recvonly})
      Process.sleep(50)

      send(pipeline_pid, {:get_direction, self()})
      assert_receive {:direction, :recvonly}, 1000

      Pipeline.terminate(pipeline_pid)
    end

    test "default direction is sendrecv" do
      {:ok, pipeline_pid} = start_opus_pipeline()

      send(pipeline_pid, {:get_direction, self()})
      assert_receive {:direction, :sendrecv}, 1000

      Pipeline.terminate(pipeline_pid)
    end

    test "direction transitions work correctly" do
      {:ok, pipeline_pid} = start_opus_pipeline()

      # Cycle through all directions
      for direction <- [:sendonly, :recvonly, :inactive, :sendrecv] do
        send(pipeline_pid, {:set_direction, direction})
        Process.sleep(50)

        send(pipeline_pid, {:get_direction, self()})
        assert_receive {:direction, ^direction}, 1000
      end

      Pipeline.terminate(pipeline_pid)
    end
  end

  # ===========================================================================
  # Helper Functions
  # ===========================================================================

  defp start_alaw_pipeline do
    opts = %{
      session_id: "test_direction_alaw_#{:rand.uniform(100_000)}",
      audio_file: nil,
      remote_rtp_address: {127, 0, 0, 1},
      remote_rtp_port: 20000 + :rand.uniform(10000),
      local_rtp_port: 30000 + :rand.uniform(10000),
      media_handler: nil,
      handler_state: nil
    }

    case Membrane.Pipeline.start_link(ParrotMedia.AlawPipeline, opts) do
      # Membrane.Pipeline.start_link returns {ok, supervisor_pid, pipeline_pid}
      {:ok, _supervisor_pid, pipeline_pid} -> {:ok, pipeline_pid}
      {:ok, pipeline_pid} -> {:ok, pipeline_pid}
      error -> error
    end
  end

  defp start_opus_pipeline do
    opts = %{
      session_id: "test_direction_opus_#{:rand.uniform(100_000)}",
      audio_file: nil,
      remote_rtp_address: {127, 0, 0, 1},
      remote_rtp_port: 20000 + :rand.uniform(10000),
      local_rtp_port: 30000 + :rand.uniform(10000),
      media_handler: nil,
      handler_state: nil
    }

    case Membrane.Pipeline.start_link(ParrotMedia.OpusPipeline, opts) do
      # Membrane.Pipeline.start_link returns {ok, supervisor_pid, pipeline_pid}
      {:ok, _supervisor_pid, pipeline_pid} -> {:ok, pipeline_pid}
      {:ok, pipeline_pid} -> {:ok, pipeline_pid}
      error -> error
    end
  end
end
