# Membrane Element API Contract: TelephoneEventParser
#
# This file documents the public API contract for the TelephoneEventParser element.
# It is NOT the implementation - see apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex

defmodule ParrotMedia.Elements.TelephoneEventParser.Contract do
  @moduledoc """
  API Contract for TelephoneEventParser Membrane Filter Element.

  ## Element Type

  Filter - has one input pad and one output pad.

  ## Purpose

  Parses RFC 2833/4733 telephone-event RTP payloads to detect DTMF digits.
  Emits `{:dtmf, digit}` notifications to the parent pipeline when digits are detected.
  Passes all RTP buffers through unchanged.

  ## Configuration Options

      %ParrotMedia.Elements.TelephoneEventParser{
        payload_type: 101  # Required: telephone-event payload type from SDP
      }

  ## Pads

  ### Input Pad (:input)
  - Accepted format: RTP (from membrane_rtp_format)
  - Flow control: :auto

  ### Output Pad (:output)
  - Accepted format: RTP (same as input)
  - Flow control: :auto

  ## Notifications Sent to Parent

  ### `{:dtmf, digit}`

  Sent when a complete DTMF digit is detected (end_bit = 1).

  - `digit` is a single-character string: "0"-"9", "*", "#", "A"-"D"
  - Sent exactly once per digit press
  - Retransmitted end packets do not trigger additional notifications

  ## Example Pipeline Usage

      def handle_init(_ctx, opts) do
        spec = [
          child(:udp_source, %Membrane.UDP.Source{...})
          |> child(:rtp_parser, Membrane.RTP.Parser)
          |> child(:dtmf_parser, %ParrotMedia.Elements.TelephoneEventParser{
            payload_type: opts.telephone_event_pt
          })
          |> child(:audio_decoder, ...)
        ]

        {[spec: spec], %{}}
      end

      def handle_child_notification({:dtmf, digit}, :dtmf_parser, _ctx, state) do
        Logger.info("DTMF digit detected: \#{digit}")
        # Forward to call handler, collect digits, etc.
        {[], state}
      end

  ## Error Handling

  - Malformed payloads (not 4 bytes): Logged at :warning level, packet passed through
  - Unknown event codes (16+): Ignored silently, packet passed through
  - Missing payload_type config: Raises ArgumentError at init

  ## RFC Compliance

  - RFC 4733 Section 2.3: Telephone-event payload format
  - RFC 4733 Section 2.5: Event duration and end bit handling
  """

  # This is a contract/specification file, not an implementation.
  # The struct definition below documents expected options.

  @type t :: %__MODULE__{
          payload_type: pos_integer()
        }

  defstruct [:payload_type]

  @type digit :: String.t()
  # "0"-"9", "*", "#", "A"-"D"

  @type dtmf_notification :: {:dtmf, digit()}
end
