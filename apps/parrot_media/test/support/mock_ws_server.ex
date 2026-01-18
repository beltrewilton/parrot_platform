defmodule ParrotMedia.Test.MockWsServer do
  @moduledoc """
  A mock WebSocket server for testing the WebSocket audio forker.

  This server accepts WebSocket connections at "/ws" and reports received
  data back to the test process for verification.

  ## Usage

      # Start the server in your test setup
      {:ok, pid} = start_supervised({ParrotMedia.Test.MockWsServer, port: 4001, test_pid: self()})

      # Connect your WebSocket client to ws://localhost:4001/ws
      # All received messages will be sent to test_pid as {:ws_message, data}
  """

  use Plug.Router

  plug :match
  plug :dispatch

  get "/ws" do
    opts = conn.private[:ws_opts] || []
    conn
    |> WebSockAdapter.upgrade(ParrotMedia.Test.MockWsHandler, opts, timeout: 60_000)
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  def child_spec(opts) do
    port = Keyword.get(opts, :port, 4001)
    test_pid = Keyword.get(opts, :test_pid, self())

    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: {__MODULE__, [test_pid: test_pid]},
      options: [port: port]
    )
  end

  @doc false
  def init(opts) do
    opts
  end

  @doc false
  def call(conn, opts) do
    test_pid = Keyword.get(opts, :test_pid)
    conn = put_private(conn, :ws_opts, test_pid: test_pid)
    super(conn, opts)
  end
end
