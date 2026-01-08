defmodule ParrotSip.Subscription.Supervisor do
  @moduledoc """
  DynamicSupervisor for SIP Subscription state machines.

  This supervisor manages `ParrotSip.Subscription` processes, allowing
  subscriptions to be started dynamically as SUBSCRIBE requests are received.

  ## Usage

  Start a new subscription:

      {:ok, pid} = ParrotSip.Subscription.Supervisor.start_child([
        id: "sub-123",
        role: :subscriber,
        dialog_pid: dialog_pid,
        event_package: "presence",
        expires: 3600
      ])

  ## Supervision Strategy

  Uses `:one_for_one` strategy with conservative restart limits.
  Subscriptions are `:temporary` - they are not restarted on crash.

  ## References

  - RFC 6665: SIP-Specific Event Notification
  """
  use DynamicSupervisor

  @doc """
  Starts the Subscription supervisor.
  """
  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @doc """
  Starts a new Subscription child process.

  ## Options

  - `:id` - Unique subscription identifier (required)
  - `:role` - `:subscriber` or `:notifier` (required)
  - `:dialog_pid` - PID of the associated dialog (required)
  - `:event_package` - Event package name (required)
  - `:expires` - Subscription duration in seconds (required)

  ## Examples

      iex> Subscription.Supervisor.start_child([
      ...>   id: "sub-123",
      ...>   role: :subscriber,
      ...>   dialog_pid: dialog_pid,
      ...>   event_package: "presence",
      ...>   expires: 3600
      ...> ])
      {:ok, pid}
  """
  @spec start_child(keyword()) :: DynamicSupervisor.on_start_child()
  def start_child(opts) do
    spec = {ParrotSip.Subscription, opts}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Returns the number of active subscription processes.
  """
  @spec num_active() :: non_neg_integer()
  def num_active do
    DynamicSupervisor.count_children(__MODULE__)[:active]
  end

  @impl true
  def init([]) do
    # Use conservative restart limits to surface bugs rather than mask them
    # If subscriptions are crashing frequently, it indicates a bug that should be fixed
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 5
    )
  end
end
