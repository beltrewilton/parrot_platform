defmodule ParrotSip.CDR.MediaInfo do
  @moduledoc """
  Optional media information captured during the call.
  Populated when media session data is available.

  ## Fields

  - `codec` - Audio codec name (e.g., "PCMU", "opus", "G729")
  - `codec_payload_type` - RTP payload type number (0 for PCMU, 8 for PCMA, etc.)
  - `mos_summary` - Full MOS (Mean Opinion Score) call summary from parrot_media
  - `packets_sent` - Total RTP packets sent during the call
  - `packets_received` - Total RTP packets received during the call
  - `jitter_ms` - Network jitter in milliseconds

  All fields are optional and default to nil when not available.
  """

  @typedoc "A quality event captured during the call"
  @type quality_event :: %{
          timestamp: DateTime.t(),
          mos: float(),
          type: atom(),
          jitter: float() | nil,
          loss_percent: float() | nil
        }

  @typedoc "Full MOS summary from parrot_media CallSummary"
  @type mos_summary :: %{
          min_mos: float(),
          max_mos: float(),
          avg_mos: float(),
          total_packets: non_neg_integer(),
          total_lost: non_neg_integer(),
          overall_loss_percent: float(),
          status: atom(),
          quality_events: [quality_event()]
        }

  @type t :: %__MODULE__{
          codec: String.t() | nil,
          codec_payload_type: non_neg_integer() | nil,
          mos_summary: mos_summary() | nil,
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
