defmodule ParrotMedia.Elements.DirectionGate do
  @moduledoc """
  A Membrane Filter that controls audio flow based on media direction.

  The DirectionGate is used to implement hold/resume functionality by
  selectively muting audio paths based on the SDP direction attribute.

  ## Directions (per RFC 3264)

  - `:sendrecv` - Normal bidirectional audio (default)
  - `:sendonly` - We send audio, remote is on hold (mute receive path)
  - `:recvonly` - We receive audio, we're on hold (mute send path)
  - `:inactive` - Completely muted (both paths)

  ## Roles

  Each gate operates in one of two roles:
  - `:send` - Controls outbound audio (inserted in send pipeline)
  - `:receive` - Controls inbound audio (inserted in receive pipeline)

  ## Direction Change

  To change direction, send `{:set_direction, direction}` message to the element
  via `Pipeline.message_child/3` or `notify_child` action.

  ## Example Usage

  In a pipeline spec:

      child(:send_gate, %DirectionGate{role: :send, initial_direction: :sendrecv})
      child(:receive_gate, %DirectionGate{role: :receive, initial_direction: :sendrecv})

  To change direction:

      Pipeline.message_child(pipeline, :send_gate, {:set_direction, :recvonly})
      Pipeline.message_child(pipeline, :receive_gate, {:set_direction, :recvonly})
  """

  use Membrane.Filter

  require Logger

  @type direction :: :sendrecv | :sendonly | :recvonly | :inactive
  @type role :: :send | :receive

  def_input_pad(:input,
    accepted_format: _any,
    flow_control: :auto
  )

  def_output_pad(:output,
    accepted_format: _any,
    flow_control: :auto
  )

  def_options(
    role: [
      spec: role(),
      description: "Gate role - :send for outbound audio, :receive for inbound audio"
    ],
    initial_direction: [
      spec: direction(),
      default: :sendrecv,
      description: "Initial media direction"
    ]
  )

  @doc """
  Determines if audio should pass through based on role and direction.

  ## Truth Table

  | Role     | Direction | Pass? | Reason                                |
  |----------|-----------|-------|---------------------------------------|
  | :send    | :sendrecv | true  | Normal bidirectional                  |
  | :send    | :sendonly | true  | We're sending, remote on hold         |
  | :send    | :recvonly | false | We're on hold, don't send             |
  | :send    | :inactive | false | All paths muted                       |
  | :receive | :sendrecv | true  | Normal bidirectional                  |
  | :receive | :sendonly | false | Remote on hold, don't play their audio|
  | :receive | :recvonly | true  | We're on hold, but still receive      |
  | :receive | :inactive | false | All paths muted                       |
  """
  @spec should_pass?(role(), direction()) :: boolean()
  def should_pass?(:send, :sendrecv), do: true
  def should_pass?(:send, :sendonly), do: true
  def should_pass?(:send, :recvonly), do: false
  def should_pass?(:send, :inactive), do: false

  def should_pass?(:receive, :sendrecv), do: true
  def should_pass?(:receive, :sendonly), do: false
  def should_pass?(:receive, :recvonly), do: true
  def should_pass?(:receive, :inactive), do: false

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      role: opts.role,
      direction: opts.initial_direction
    }

    Logger.debug(
      "DirectionGate: Initialized with role=#{opts.role}, direction=#{opts.initial_direction}"
    )

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    if should_pass?(state.role, state.direction) do
      # Pass through the buffer unchanged
      {[buffer: {:output, buffer}], state}
    else
      # Drop the buffer (muted)
      {[], state}
    end
  end

  # Handle direction change from pipeline
  @impl true
  def handle_parent_notification({:set_direction, direction}, _ctx, state)
      when direction in [:sendrecv, :sendonly, :recvonly, :inactive] do
    Logger.info(
      "DirectionGate (#{state.role}): Direction changed from #{state.direction} to #{direction}"
    )

    {[], %{state | direction: direction}}
  end

  def handle_parent_notification(msg, _ctx, state) do
    Logger.debug("DirectionGate: Received unknown notification: #{inspect(msg)}")
    {[], state}
  end
end
