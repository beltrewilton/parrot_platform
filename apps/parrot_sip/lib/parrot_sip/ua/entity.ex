defmodule ParrotSip.UA.Entity do
  @moduledoc """
  Represents a SIP dialog/call leg.

  Following OpenSIPS terminology:
  - `:server` entity - created from received INVITE (UAS role)
  - `:client` entity - created by sending INVITE (UAC role)

  The entity tracks the state of a single call leg and contains
  the information needed to send responses or in-dialog requests.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          type: :server | :client,
          state: :trying | :early | :confirmed | :terminated,
          remote_uri: String.t(),
          local_uri: String.t(),
          call_id: String.t(),
          local_tag: String.t(),
          remote_tag: String.t() | nil,
          # CSeq tracking per RFC 3261 Section 12.2.1.1
          local_seq: pos_integer(),
          # Timestamp for garbage collection
          created_at: integer() | nil,
          # Internal references (not exposed in docs)
          ua_pid: pid(),
          uas: term() | nil,
          trans: term() | nil,
          request: map() | nil,
          # SDP answer handler callback for delayed offer scenarios
          # RFC 3261 Section 13.2.2.4: If 2xx contains offer, ACK MUST carry answer
          sdp_answer_handler: (binary(), keyword() -> {:ok, binary()} | {:error, term()}) | nil
        }

  defstruct [
    :id,
    :type,
    :state,
    :remote_uri,
    :local_uri,
    :call_id,
    :local_tag,
    :remote_tag,
    :ua_pid,
    :uas,
    :trans,
    :request,
    # CSeq tracking - initialized from INVITE's CSeq (keyword entries must be last)
    local_seq: 1,
    # Created timestamp for GC
    created_at: nil,
    # SDP answer handler for delayed offer scenarios (RFC 3261 Section 13.2.2.4)
    sdp_answer_handler: nil
  ]

  @doc """
  Generate a unique entity ID.
  """
  def generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
