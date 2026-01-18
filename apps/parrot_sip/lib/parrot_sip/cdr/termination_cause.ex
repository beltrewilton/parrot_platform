defmodule ParrotSip.CDR.TerminationCause do
  @moduledoc """
  Describes the termination cause of a call.

  This struct captures how and why a call was terminated, including:

  - `party` - Who initiated the termination (:caller, :callee, or :system)
  - `sip_code` - The SIP response code associated with termination (e.g., 200, 486, 487)
  - `reason` - Human-readable description (e.g., "BYE", "Busy Here", "Request Terminated")
  - `method` - The SIP method that caused termination (:bye, :cancel, :error, or nil)

  ## Typical Termination Scenarios

  ### Normal Call End (BYE)

      %TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      }

  ### Call Cancelled Before Answer

      %TerminationCause{
        party: :caller,
        sip_code: 487,
        reason: "Request Terminated",
        method: :cancel
      }

  ### Callee Busy

      %TerminationCause{
        party: :callee,
        sip_code: 486,
        reason: "Busy Here",
        method: nil
      }

  ### System Error

      %TerminationCause{
        party: :system,
        sip_code: 500,
        reason: "Internal Server Error",
        method: :error
      }
  """

  @typedoc "The party that initiated termination"
  @type party :: :caller | :callee | :system

  @typedoc "The SIP method that caused termination"
  @type method :: :bye | :cancel | :error | nil

  @typedoc "Termination cause struct"
  @type t :: %__MODULE__{
          party: party() | nil,
          sip_code: non_neg_integer() | nil,
          reason: String.t() | nil,
          method: method()
        }

  defstruct [:party, :sip_code, :reason, :method]
end
