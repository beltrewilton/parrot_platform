defmodule ParrotMedia.WsAudioForker.DefaultCallback do
  @moduledoc """
  Default implementation of the `ParrotMedia.WsAudioForker.Callback` behaviour.

  This module provides a simple logging-based implementation suitable for
  development, debugging, or as a fallback when no custom handler is specified.

  ## Behavior

  - Logs connection events at appropriate levels (info, warning, error)
  - Always returns `{:ok, state}` to allow the forker to continue
  - Passes through state unchanged

  ## Log Levels

  | Event Type | Log Level |
  |------------|-----------|
  | `:connected` | `:info` |
  | `{:disconnected, _}` | `:warning` |
  | `{:reconnecting, _}` | `:info` |
  | `{:failed, _}` | `:error` |
  | `{:ws_message, _}` | `:debug` |
  | `{:backpressure_warning, _}` | `:warning` |

  ## Usage

  The default callback is used automatically when no callback is specified
  in the fork configuration:

      # Uses DefaultCallback automatically
      ParrotMedia.WsAudioForker.start_fork(%{
        fork_id: "my-fork",
        url: "wss://api.example.com/stream"
      })

      # Explicit usage
      ParrotMedia.WsAudioForker.start_fork(%{
        fork_id: "my-fork",
        url: "wss://api.example.com/stream",
        callback: ParrotMedia.WsAudioForker.DefaultCallback,
        callback_args: %{}
      })

  """

  @behaviour ParrotMedia.WsAudioForker.Callback

  require Logger

  @impl true
  def init(args) do
    {:ok, args}
  end

  @impl true
  def handle_fork_event({:fork_event, fork_id, :connected}, state) do
    Logger.info("WsAudioForker #{fork_id}: Connected to WebSocket")
    {:ok, state}
  end

  def handle_fork_event({:fork_event, fork_id, {:disconnected, reason}}, state) do
    Logger.warning(
      "WsAudioForker #{fork_id}: Disconnected from WebSocket, reason: #{inspect(reason)}"
    )

    {:ok, state}
  end

  def handle_fork_event({:fork_event, fork_id, {:reconnecting, attempt}}, state) do
    Logger.info("WsAudioForker #{fork_id}: Reconnecting, attempt #{attempt}")
    {:ok, state}
  end

  def handle_fork_event({:fork_event, fork_id, {:failed, reason}}, state) do
    Logger.error("WsAudioForker #{fork_id}: Failed permanently, reason: #{inspect(reason)}")
    {:ok, state}
  end

  def handle_fork_event({:fork_event, fork_id, {:ws_message, data}}, state) do
    Logger.debug("WsAudioForker #{fork_id}: Received message, #{byte_size(data)} bytes")
    {:ok, state}
  end

  def handle_fork_event({:fork_event, fork_id, {:backpressure_warning, drops}}, state) do
    Logger.warning("WsAudioForker #{fork_id}: Dropped #{drops} frames due to backpressure")
    {:ok, state}
  end

  def handle_fork_event({:fork_event, fork_id, event}, state) do
    Logger.debug("WsAudioForker #{fork_id}: Unhandled event #{inspect(event)}")
    {:ok, state}
  end
end
