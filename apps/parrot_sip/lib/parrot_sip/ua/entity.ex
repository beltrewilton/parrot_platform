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
          # Internal references (not exposed in docs)
          ua_pid: pid(),
          uas: term() | nil,
          trans: term() | nil,
          request: map() | nil
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
    :request
  ]

  @doc """
  Generate a unique entity ID.
  """
  def generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
