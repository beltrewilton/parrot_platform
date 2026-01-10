defmodule ParrotSip.CDR.MediaInfo do
  @moduledoc """
  Optional media information captured during the call.
  Populated when media session data is available.

  ## Fields

  - `codec` - Audio codec name (e.g., "PCMU", "opus", "G729")
  - `codec_payload_type` - RTP payload type number (0 for PCMU, 8 for PCMA, etc.)
  - `mos_score` - Mean Opinion Score for call quality (1.0 = bad, 5.0 = excellent)
  - `packets_sent` - Total RTP packets sent during the call
  - `packets_received` - Total RTP packets received during the call
  - `jitter_ms` - Network jitter in milliseconds

  All fields are optional and default to nil when not available.
  """

  @type t :: %__MODULE__{
          codec: String.t() | nil,
          codec_payload_type: non_neg_integer() | nil,
          mos_score: float() | nil,
          packets_sent: non_neg_integer() | nil,
          packets_received: non_neg_integer() | nil,
          jitter_ms: float() | nil
        }

  defstruct [
    :codec,
    :codec_payload_type,
    :mos_score,
    :packets_sent,
    :packets_received,
    :jitter_ms
  ]
end
