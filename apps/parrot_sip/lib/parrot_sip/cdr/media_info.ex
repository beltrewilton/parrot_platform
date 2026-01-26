defmodule ParrotSip.CDR.MediaInfo do
  @moduledoc """
  Optional media information captured during the call.
  Populated when media session data is available.

  ## Fields

  - `codec` - Audio codec name (e.g., "PCMU", "opus", "G729")
  - `codec_payload_type` - RTP payload type number (0 for PCMU, 8 for PCMA, etc.)
  - `mos_summary` - Comprehensive MOS quality summary from the call (see mos_summary type)
  - `packets_sent` - Total RTP packets sent during the call
  - `packets_received` - Total RTP packets received during the call
  - `jitter_ms` - Network jitter in milliseconds

  All fields are optional and default to nil when not available.

  ## MOS Summary

  The `mos_summary` field contains a comprehensive quality analysis including:
  - Min/max/average MOS scores
  - Packet statistics (total packets, lost packets, loss percentage)
  - Calculation metadata (intervals calculated, duration)
  - Quality status (:complete, :insufficient_data, :one_way_audio, :unavailable)
  - Quality threshold crossing events
  """

  @type quality_event :: %{
          timestamp: DateTime.t(),
          mos_value: float(),
          threshold_name: atom(),
          direction: :rising | :falling
        }

  @type mos_summary ::
          %{
            min_mos: float(),
            max_mos: float(),
            avg_mos: float(),
            total_packets: non_neg_integer(),
            total_lost: non_neg_integer(),
            overall_loss_percent: float(),
            intervals_calculated: non_neg_integer(),
            duration_ms: non_neg_integer(),
            status: :complete | :insufficient_data | :one_way_audio | :unavailable,
            quality_events: [quality_event()]
          }
          | nil

  @type t :: %__MODULE__{
          codec: String.t() | nil,
          codec_payload_type: non_neg_integer() | nil,
          mos_summary: mos_summary(),
          packets_sent: non_neg_integer() | nil,
          packets_received: non_neg_integer() | nil,
          jitter_ms: float() | nil
        }

  defstruct [
    :codec,
    :codec_payload_type,
    :mos_summary,
    :packets_sent,
    :packets_received,
    :jitter_ms
  ]
end
