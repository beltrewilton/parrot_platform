defmodule ParrotSip.CDR do
  @moduledoc """
  Call Detail Record struct for Parrot Platform.
  Generated automatically for every INVITE dialog upon termination.
  Delivered to registered handlers for storage/processing.
  """

  alias ParrotSip.CDR.{TerminationCause, MediaInfo}

  @typedoc "Call disposition indicating the outcome of the call attempt"
  @type disposition ::
          :answered
          | :busy
          | :no_answer
          | :timeout
          | :cancelled
          | :declined
          | :not_found
          | :forbidden
          | :server_error
          | :failed
          | :redirected
          | :abandoned

  @typedoc "Call direction from the perspective of this endpoint"
  @type direction :: :inbound | :outbound

  @typedoc "Transport protocol used for SIP signaling"
  @type transport :: :udp | :tcp | :tls | :ws | :wss

  @typedoc "Call Detail Record struct"
  @type t :: %__MODULE__{
          id: String.t(),
          correlation_id: String.t(),
          call_id: String.t(),
          caller_uri: String.t(),
          caller_display_name: String.t() | nil,
          caller_tag: String.t(),
          callee_uri: String.t(),
          callee_display_name: String.t() | nil,
          callee_tag: String.t() | nil,
          disposition: disposition(),
          termination_cause: TerminationCause.t(),
          invite_received_at: DateTime.t(),
          answered_at: DateTime.t() | nil,
          ended_at: DateTime.t(),
          ring_duration_ms: non_neg_integer(),
          talk_duration_ms: non_neg_integer(),
          direction: direction(),
          transport: transport(),
          dialog_id: String.t(),
          media_info: MediaInfo.t() | nil,
          custom_fields: map()
        }

  defstruct [
    :id,
    :correlation_id,
    :call_id,
    :caller_uri,
    :caller_display_name,
    :caller_tag,
    :callee_uri,
    :callee_display_name,
    :callee_tag,
    :disposition,
    :termination_cause,
    :invite_received_at,
    :answered_at,
    :ended_at,
    :ring_duration_ms,
    :talk_duration_ms,
    :direction,
    :transport,
    :dialog_id,
    :media_info,
    custom_fields: %{}
  ]
end
