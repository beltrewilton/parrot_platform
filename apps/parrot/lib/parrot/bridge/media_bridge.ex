defmodule Parrot.Bridge.MediaBridge do
  @moduledoc """
  Manages RTP forwarding between two legs in a B2BUA call.

  MediaBridge provides a pure data structure for tracking the state of media
  bridging between two MediaSessions. It coordinates bidirectional RTP forwarding
  with support for hold/resume operations.

  ## State Machine

  The MediaBridge implements a state machine with the following states:

    * `:idle` - Initial state, bridge created but not active
    * `:bridged` - Active bidirectional RTP forwarding (A <-> B)
    * `:held_a` - Leg A is on hold (no media from A to B)
    * `:held_b` - Leg B is on hold (no media from B to A)
    * `:held_both` - Both legs on hold (no media flowing)

  ## State Transitions

      idle --[bridge]--> bridged
      bridged --[hold :leg_a]--> held_a
      bridged --[hold :leg_b]--> held_b
      bridged --[hold :both]--> held_both
      held_a --[hold :leg_b]--> held_both
      held_b --[hold :leg_a]--> held_both
      held_a --[resume :leg_a]--> bridged
      held_b --[resume :leg_b]--> bridged
      held_both --[resume :leg_a]--> held_b
      held_both --[resume :leg_b]--> held_a
      held_both --[resume :both]--> bridged
      any --[destroy]--> (terminated)

  ## Example

      {:ok, bridge} = MediaBridge.create(media_pid_a, media_pid_b)
      {:ok, bridge} = MediaBridge.bridge(bridge)
      {:ok, bridge} = MediaBridge.hold(bridge, :leg_a)
      {:ok, bridge} = MediaBridge.resume(bridge, :leg_a)
      :ok = MediaBridge.destroy(bridge)

  ## Integration with MediaSession

  When bridged, the MediaBridge coordinates RTP forwarding between the two
  MediaSessions. The actual forwarding is handled by MediaSession's forwarding
  capabilities (set_rtp_forward/2).

  Note: The MediaSession forwarding API (T08) is being implemented separately.
  This module provides the state management; actual forwarding commands will
  be added once T08 is complete.
  """

  require Logger

  @typedoc "The bridge state"
  @type state :: :idle | :bridged | :held_a | :held_b | :held_both

  @typedoc "Leg specifier for hold/resume operations"
  @type leg :: :leg_a | :leg_b | :both

  @typedoc "The MediaBridge struct"
  @type t :: %__MODULE__{
          leg_a_media: pid() | nil,
          leg_b_media: pid() | nil,
          state: state()
        }

  @enforce_keys [:leg_a_media, :leg_b_media, :state]
  defstruct [:leg_a_media, :leg_b_media, :state]

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Creates a new MediaBridge for the given media session PIDs.

  The bridge starts in `:idle` state. Call `bridge/1` to begin
  bidirectional RTP forwarding.

  ## Parameters

    * `media_pid_a` - PID of the MediaSession for leg A
    * `media_pid_b` - PID of the MediaSession for leg B

  ## Returns

    * `{:ok, bridge}` - Bridge created successfully
    * `{:error, :invalid_leg_a_media}` - leg_a_media is not a valid PID
    * `{:error, :invalid_leg_b_media}` - leg_b_media is not a valid PID
    * `{:error, :leg_a_not_alive}` - leg_a_media process is not alive
    * `{:error, :leg_b_not_alive}` - leg_b_media process is not alive

  ## Examples

      {:ok, media_a} = ParrotMedia.MediaSession.start_link(opts_a)
      {:ok, media_b} = ParrotMedia.MediaSession.start_link(opts_b)
      {:ok, bridge} = MediaBridge.create(media_a, media_b)
  """
  @spec create(pid(), pid()) :: {:ok, t()} | {:error, atom()}
  def create(media_pid_a, media_pid_b)

  def create(media_pid_a, _media_pid_b) when not is_pid(media_pid_a) do
    {:error, :invalid_leg_a_media}
  end

  def create(_media_pid_a, media_pid_b) when not is_pid(media_pid_b) do
    {:error, :invalid_leg_b_media}
  end

  def create(media_pid_a, media_pid_b) do
    cond do
      not Process.alive?(media_pid_a) ->
        {:error, :leg_a_not_alive}

      not Process.alive?(media_pid_b) ->
        {:error, :leg_b_not_alive}

      true ->
        bridge = %__MODULE__{
          leg_a_media: media_pid_a,
          leg_b_media: media_pid_b,
          state: :idle
        }

        Logger.debug(
          "[MediaBridge] Created bridge between #{inspect(media_pid_a)} and #{inspect(media_pid_b)}"
        )

        {:ok, bridge}
    end
  end

  @doc """
  Starts bidirectional RTP forwarding between the two legs.

  This transitions the bridge from `:idle` to `:bridged` state and
  sets up RTP forwarding in both directions:
    * A's RTP -> B
    * B's RTP -> A

  ## Parameters

    * `bridge` - The MediaBridge struct

  ## Returns

    * `{:ok, bridge}` - Bridge is now active
    * `{:error, :already_bridged}` - Already in bridged state
    * `{:error, :in_held_state}` - Cannot bridge while in held state

  ## Examples

      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      {:ok, active_bridge} = MediaBridge.bridge(bridge)
  """
  @spec bridge(t()) :: {:ok, t()} | {:error, atom()}
  def bridge(%__MODULE__{state: :idle} = bridge) do
    # TODO: When T08 (MediaSession.set_rtp_forward) is implemented,
    # set up bidirectional forwarding here:
    #   ParrotMedia.MediaSession.set_rtp_forward(bridge.leg_a_media, bridge.leg_b_media)
    #   ParrotMedia.MediaSession.set_rtp_forward(bridge.leg_b_media, bridge.leg_a_media)

    Logger.debug("[MediaBridge] Bridge activated between legs")
    {:ok, %{bridge | state: :bridged}}
  end

  def bridge(%__MODULE__{state: :bridged}) do
    {:error, :already_bridged}
  end

  def bridge(%__MODULE__{state: state}) when state in [:held_a, :held_b, :held_both] do
    {:error, :in_held_state}
  end

  @doc """
  Puts one or both legs on hold, pausing RTP forwarding.

  ## Parameters

    * `bridge` - The MediaBridge struct
    * `leg` - Which leg(s) to hold: `:leg_a`, `:leg_b`, or `:both`

  ## State Transitions

    * `:bridged` + `:leg_a` -> `:held_a`
    * `:bridged` + `:leg_b` -> `:held_b`
    * `:bridged` + `:both` -> `:held_both`
    * `:held_a` + `:leg_b` -> `:held_both`
    * `:held_b` + `:leg_a` -> `:held_both`
    * `:held_a` + `:leg_a` -> `:held_a` (idempotent)
    * `:held_b` + `:leg_b` -> `:held_b` (idempotent)

  ## Returns

    * `{:ok, bridge}` - Hold successful
    * `{:error, :not_bridged}` - Bridge must be active first
    * `{:error, :invalid_leg}` - Invalid leg specifier

  ## Examples

      {:ok, held} = MediaBridge.hold(bridge, :leg_a)
      {:ok, both_held} = MediaBridge.hold(held, :leg_b)
  """
  @spec hold(t(), leg()) :: {:ok, t()} | {:error, atom()}
  def hold(%__MODULE__{state: :idle}, _leg) do
    {:error, :not_bridged}
  end

  def hold(%__MODULE__{} = bridge, leg) when leg in [:leg_a, :leg_b, :both] do
    new_state = compute_hold_state(bridge.state, leg)

    # TODO: When T08 is implemented, pause forwarding:
    #   pause_forward_for_leg(bridge, leg)

    Logger.debug("[MediaBridge] Hold #{leg}: #{bridge.state} -> #{new_state}")
    {:ok, %{bridge | state: new_state}}
  end

  def hold(%__MODULE__{}, _leg) do
    {:error, :invalid_leg}
  end

  @doc """
  Resumes RTP forwarding for one or both legs.

  ## Parameters

    * `bridge` - The MediaBridge struct
    * `leg` - Which leg(s) to resume: `:leg_a`, `:leg_b`, or `:both`

  ## State Transitions

    * `:held_a` + `:leg_a` -> `:bridged`
    * `:held_b` + `:leg_b` -> `:bridged`
    * `:held_both` + `:leg_a` -> `:held_b`
    * `:held_both` + `:leg_b` -> `:held_a`
    * `:held_both` + `:both` -> `:bridged`
    * `:held_a` + `:leg_b` -> `:held_a` (no effect - leg_b not held)
    * `:held_b` + `:leg_a` -> `:held_b` (no effect - leg_a not held)

  ## Returns

    * `{:ok, bridge}` - Resume successful
    * `{:error, :not_held}` - Not in a held state
    * `{:error, :invalid_leg}` - Invalid leg specifier

  ## Examples

      {:ok, resumed} = MediaBridge.resume(held_bridge, :leg_a)
  """
  @spec resume(t(), leg()) :: {:ok, t()} | {:error, atom()}
  def resume(%__MODULE__{state: state}, _leg) when state in [:idle, :bridged] do
    {:error, :not_held}
  end

  def resume(%__MODULE__{} = bridge, leg) when leg in [:leg_a, :leg_b, :both] do
    new_state = compute_resume_state(bridge.state, leg)

    # TODO: When T08 is implemented, resume forwarding:
    #   resume_forward_for_leg(bridge, leg)

    Logger.debug("[MediaBridge] Resume #{leg}: #{bridge.state} -> #{new_state}")
    {:ok, %{bridge | state: new_state}}
  end

  def resume(%__MODULE__{}, _leg) do
    {:error, :invalid_leg}
  end

  @doc """
  Destroys the bridge and stops all forwarding.

  This cleans up any resources associated with the bridge.
  The MediaSessions themselves are NOT terminated.

  ## Parameters

    * `bridge` - The MediaBridge struct

  ## Returns

    * `:ok` - Always succeeds

  ## Examples

      :ok = MediaBridge.destroy(bridge)
  """
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{} = bridge) do
    # TODO: When T08 is implemented, stop forwarding:
    #   ParrotMedia.MediaSession.stop_forward(bridge.leg_a_media)
    #   ParrotMedia.MediaSession.stop_forward(bridge.leg_b_media)

    Logger.debug("[MediaBridge] Bridge destroyed")
    _ = bridge
    :ok
  end

  # ===========================================================================
  # Query Functions
  # ===========================================================================

  @doc """
  Returns the current state of the bridge.

  ## Examples

      :idle = MediaBridge.get_state(bridge)
      :bridged = MediaBridge.get_state(active_bridge)
      :held_a = MediaBridge.get_state(held_bridge)
  """
  @spec get_state(t()) :: state()
  def get_state(%__MODULE__{state: state}), do: state

  @doc """
  Returns true if the bridge is actively forwarding RTP in both directions.

  ## Examples

      true = MediaBridge.bridged?(active_bridge)
      false = MediaBridge.bridged?(idle_bridge)
      false = MediaBridge.bridged?(held_bridge)
  """
  @spec bridged?(t()) :: boolean()
  def bridged?(%__MODULE__{state: :bridged}), do: true
  def bridged?(%__MODULE__{}), do: false

  @doc """
  Returns true if the bridge is in any held state.

  ## Examples

      true = MediaBridge.held?(held_bridge)
      false = MediaBridge.held?(bridged_bridge)
  """
  @spec held?(t()) :: boolean()
  def held?(%__MODULE__{state: state}) when state in [:held_a, :held_b, :held_both], do: true
  def held?(%__MODULE__{}), do: false

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # Compute the new state after a hold operation
  @spec compute_hold_state(state(), leg()) :: state()
  defp compute_hold_state(:bridged, :leg_a), do: :held_a
  defp compute_hold_state(:bridged, :leg_b), do: :held_b
  defp compute_hold_state(:bridged, :both), do: :held_both
  defp compute_hold_state(:held_a, :leg_b), do: :held_both
  defp compute_hold_state(:held_a, :both), do: :held_both
  defp compute_hold_state(:held_b, :leg_a), do: :held_both
  defp compute_hold_state(:held_b, :both), do: :held_both
  # Idempotent cases
  defp compute_hold_state(:held_a, :leg_a), do: :held_a
  defp compute_hold_state(:held_b, :leg_b), do: :held_b
  defp compute_hold_state(:held_both, _), do: :held_both

  # Compute the new state after a resume operation
  @spec compute_resume_state(state(), leg()) :: state()
  defp compute_resume_state(:held_a, :leg_a), do: :bridged
  defp compute_resume_state(:held_a, :both), do: :bridged
  defp compute_resume_state(:held_b, :leg_b), do: :bridged
  defp compute_resume_state(:held_b, :both), do: :bridged
  defp compute_resume_state(:held_both, :leg_a), do: :held_b
  defp compute_resume_state(:held_both, :leg_b), do: :held_a
  defp compute_resume_state(:held_both, :both), do: :bridged
  # No effect cases (resuming a leg that's not held)
  defp compute_resume_state(:held_a, :leg_b), do: :held_a
  defp compute_resume_state(:held_b, :leg_a), do: :held_b
end
