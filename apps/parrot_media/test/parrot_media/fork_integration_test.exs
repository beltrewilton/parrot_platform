defmodule ParrotMedia.ForkIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :slow

  alias ParrotMedia.{MediaSession, ForkConfig}

  # Test handler that supports fork_media action
  defmodule ForkTestHandler do
    @behaviour ParrotMedia.Handler

    @impl true
    def init(args) do
      {:ok, Map.merge(%{forks: []}, args)}
    end

    @impl true
    def handle_session_start(_id, _opts, state) do
      {:ok, state}
    end

    @impl true
    def handle_stream_start(_id, _dir, state) do
      {:noreply, state}
    end

    @impl true
    def handle_codec_negotiation(offered, supported, state) do
      common = Enum.find(supported, fn codec -> codec in offered end)

      if common do
        {:ok, common, state}
      else
        {:error, :no_common_codec, state}
      end
    end

    @impl true
    def handle_negotiation_complete(_local, _remote, _codec, state) do
      {:ok, state}
    end

    @impl true
    def handle_info({:fork_media, destination, opts}, state) do
      fork_config =
        ForkConfig.new(
          id: Keyword.get(opts, :fork_id, "fork_#{System.unique_integer([:positive])}"),
          destination_address: destination,
          destination_port: Keyword.fetch!(opts, :port)
        )

      {[{:fork_media, fork_config}],
       Map.update(state, :forks, [fork_config], &[fork_config | &1])}
    end

    @impl true
    def handle_info({:stop_fork, fork_id}, state) do
      {[{:stop_fork, fork_id}],
       Map.update(state, :forks, [], &Enum.reject(&1, fn f -> f.id == fork_id end))}
    end

    @impl true
    def handle_info(_msg, state) do
      {:noreply, state}
    end
  end

  describe "MediaSession with fork_media action" do
    test "processes :fork_media action from handler" do
      session_id = "fork_test_#{:rand.uniform(10000)}"

      {:ok, session} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog_#{:rand.uniform(10000)}",
          role: :uas,
          media_handler: ForkTestHandler,
          handler_args: %{}
        )

      # Send fork_media message
      send(session, {:fork_media, "192.168.1.100", port: 5000, fork_id: "my_fork"})

      # Allow processing time
      Process.sleep(100)

      # Verify handler state was updated
      {_state_name, data} = :sys.get_state(session)
      assert length(data.handler_state.forks) == 1
      [fork] = data.handler_state.forks
      assert fork.id == "my_fork"
      assert fork.destination_port == 5000

      GenServer.stop(session)
    end

    test "processes :stop_fork action" do
      session_id = "fork_stop_test_#{:rand.uniform(10000)}"

      {:ok, session} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog_#{:rand.uniform(10000)}",
          role: :uas,
          media_handler: ForkTestHandler,
          handler_args: %{
            forks: [
              %ForkConfig{
                id: "existing_fork",
                destination_address: {127, 0, 0, 1},
                destination_port: 5000,
                transport: :rtp,
                enabled: true
              }
            ]
          }
        )

      # Send stop_fork message
      send(session, {:stop_fork, "existing_fork"})

      # Allow processing time
      Process.sleep(100)

      # Verify fork was removed from handler state
      {_state_name, data} = :sys.get_state(session)
      assert data.handler_state.forks == []

      GenServer.stop(session)
    end
  end

  describe "ForkConfig creation" do
    test "creates valid fork config with required fields" do
      config =
        ForkConfig.new(
          id: "test_fork",
          destination_address: {192, 168, 1, 100},
          destination_port: 5000
        )

      assert config.id == "test_fork"
      assert config.destination_address == {192, 168, 1, 100}
      assert config.destination_port == 5000
      assert config.transport == :rtp
      assert config.enabled == true
    end
  end
end
