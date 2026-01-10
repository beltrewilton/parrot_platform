defmodule ParrotMedia.Test.MockWsHandler do
  @behaviour WebSock

  @impl true
  def init(opts) do
    test_pid = Keyword.get(opts, :test_pid)
    {:ok, %{test_pid: test_pid, received: [], connected_at: System.monotonic_time()}}
  end

  @impl true
  def handle_in({data, [opcode: :binary]}, state) do
    new_state = %{state | received: [data | state.received]}
    if state.test_pid, do: send(state.test_pid, {:ws_frame, data})
    {:ok, new_state}
  end

  def handle_in({data, [opcode: :text]}, state) do
    if state.test_pid, do: send(state.test_pid, {:ws_text, data})
    {:ok, state}
  end

  @impl true
  def handle_info({:send_text, text}, state) do
    {:push, {:text, text}, state}
  end

  def handle_info({:send_binary, data}, state) do
    {:push, {:binary, data}, state}
  end

  def handle_info(:disconnect, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.test_pid do
      send(state.test_pid, {:ws_closed, Enum.reverse(state.received)})
    end
    :ok
  end
end
