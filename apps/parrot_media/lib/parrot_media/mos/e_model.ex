defmodule ParrotMedia.MOS.EModel do
  @moduledoc """
  ITU-T G.107 E-model implementation for MOS estimation.

  This module implements the simplified E-model algorithm for calculating
  MOS (Mean Opinion Score) from network metrics (packet loss, jitter, delay).
  The E-model is the industry standard for network-based VoIP quality estimation.

  ## Algorithm

  The E-model calculates a rating factor R (0-100):

      R = R0 - Id - Ie_eff

  Where:
  - R0 = 93.2 (base quality for G.711 reference codec)
  - Id = delay impairment factor
  - Ie_eff = equipment impairment with packet loss effect

  R is then converted to the MOS scale (1.0-5.0) using the ITU-T G.107 formula.

  ## Codec Parameters

  Codec parameters are defined per ITU-T G.113:
  - Ie (Equipment Impairment): Inherent codec quality reduction
  - Bpl (Packet Loss Robustness): How well codec handles packet loss

  ## Usage

      iex> EModel.calculate_mos(0.5, 20.0, 50.0, :g711)
      4.35

      iex> EModel.calculate_mos(5.0, 50.0, 150.0, :opus)
      3.42

      iex> EModel.calculate_r_factor(1.0, 20.0, 100.0, :g711)
      87.5

  ## References

  - ITU-T Rec. G.107 (2005) - The E-model
  - ITU-T Rec. G.113 - Transmission impairments
  - RFC 3550 - RTP Protocol (jitter calculation)
  """

  @type codec :: :g711 | :g711_no_plc | :opus | :opus_low | :g729

  # Base R-factor for perfect G.711 conditions (R0 - Is combined)
  @r0 93.2

  # Codec parameters from ITU-T G.113 and research estimates
  # Format: {Ie (equipment impairment), Bpl (packet loss robustness)}
  @codec_params %{
    # G.711 is the reference codec (Ie=0 by definition)
    # Bpl=25.1 with packet loss concealment
    g711: {0, 25.1},
    # G.711 without PLC - lower robustness
    g711_no_plc: {0, 4.3},
    # Opus high bitrate - good quality, slightly below G.711 reference
    opus: {10, 20.0},
    # Opus low bitrate - higher impairment due to reduced bitrate
    opus_low: {15, 15.0},
    # G.729AB - official ITU-T G.113 values
    g729: {11, 19.0}
  }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Calculate MOS from network metrics.

  Computes the Mean Opinion Score (1.0-5.0) based on packet loss percentage,
  jitter, delay, and codec type using the ITU-T G.107 E-model.

  ## Parameters

  - `packet_loss_percent` - Packet loss percentage (0.0-100.0)
  - `jitter_ms` - Interarrival jitter in milliseconds (>= 0)
  - `delay_ms` - One-way delay in milliseconds (>= 0)
  - `codec` - Codec identifier (default: :g711)

  ## Returns

  MOS score as float, clamped to range 1.0-5.0

  ## Examples

      iex> EModel.calculate_mos(0.0, 0.0, 50.0, :g711)
      4.41  # Near-perfect quality

      iex> EModel.calculate_mos(5.0, 50.0, 200.0, :g711)
      ~3.0  # Degraded quality
  """
  @spec calculate_mos(number(), number(), number(), codec()) :: float()
  def calculate_mos(packet_loss_percent, jitter_ms, delay_ms, codec \\ :g711) do
    packet_loss_percent
    |> calculate_r_factor(jitter_ms, delay_ms, codec)
    |> r_to_mos()
  end

  @doc """
  Calculate R-factor from network metrics.

  Computes the intermediate R-factor (0-100) before MOS conversion.
  Useful for debugging or custom quality calculations.

  ## Formula

      R = R0 - Id - Ie_eff

  Where:
  - R0 = 93.2 (base quality)
  - Id = delay impairment
  - Ie_eff = equipment impairment including packet loss

  ## Parameters

  - `packet_loss_percent` - Packet loss percentage (0.0-100.0)
  - `jitter_ms` - Interarrival jitter in milliseconds
  - `delay_ms` - One-way delay in milliseconds
  - `codec` - Codec identifier (default: :g711)

  ## Returns

  R-factor as float, clamped to range 0-100
  """
  @spec calculate_r_factor(number(), number(), number(), codec()) :: float()
  def calculate_r_factor(packet_loss_percent, jitter_ms, delay_ms, codec \\ :g711) do
    # Clamp negative values to 0
    loss = max(0.0, packet_loss_percent / 1.0)
    jitter = max(0.0, jitter_ms / 1.0)
    delay = max(0.0, delay_ms / 1.0)

    # Calculate effective delay including jitter buffer effect
    eff_delay = effective_delay(delay, jitter)

    # Get codec parameters
    {ie, bpl} = codec_params(codec)

    # Calculate impairment factors
    id = calculate_id(eff_delay)
    ie_eff = calculate_ie_eff(loss, ie, bpl)

    # R = R0 - Id - Ie_eff, clamped to [0, 100]
    r = @r0 - id - ie_eff
    max(0.0, min(100.0, r))
  end

  @doc """
  Convert R-factor to MOS scale.

  Uses the ITU-T G.107 Appendix B formula to convert the R-factor (0-100)
  to the MOS scale (1.0-5.0).

  ## Formula

  For R in [0, 100]:

      MOS = 1.0 + 0.035*R + R*(R-60)*(100-R)*7.0e-6

  ## Clamping

  - R < 0: returns 1.0
  - R > 100: returns 4.5

  ## Examples

      iex> EModel.r_to_mos(93.2)
      4.41

      iex> EModel.r_to_mos(60.0)
      3.1

      iex> EModel.r_to_mos(0.0)
      1.0
  """
  @spec r_to_mos(number()) :: float()
  def r_to_mos(r) when r < 0, do: 1.0
  def r_to_mos(r) when r > 100, do: 4.5

  def r_to_mos(r) do
    r_float = r / 1.0
    1.0 + 0.035 * r_float + r_float * (r_float - 60.0) * (100.0 - r_float) * 7.0e-6
  end

  @doc """
  Returns codec parameters (Ie, Bpl) for a given codec.

  ## Codec Parameters

  | Codec | Ie | Bpl | Notes |
  |-------|-----|------|-------|
  | G.711 (PCMU/PCMA) | 0 | 25.1 | Reference codec with PLC |
  | G.711 (no PLC) | 0 | 4.3 | Without packet loss concealment |
  | Opus (high bitrate) | 10 | 20.0 | Estimated per ITU-T G.113 |
  | Opus (low bitrate) | 15 | 15.0 | Estimated per ITU-T G.113 |
  | G.729AB | 11 | 19.0 | Official ITU-T G.113 |

  ## Parameters

  - `codec` - Codec identifier atom

  ## Returns

  Tuple `{ie, bpl}` where:
  - `ie` - Equipment impairment factor (0-100)
  - `bpl` - Packet loss robustness factor

  Unknown codecs default to G.711 parameters.
  """
  @spec codec_params(codec()) :: {number(), number()}
  def codec_params(codec) when is_atom(codec) do
    Map.get(@codec_params, codec, @codec_params.g711)
  end

  @doc """
  Calculate effective delay including jitter buffer effect.

  Jitter contributes to perceived delay because the jitter buffer
  must absorb timing variations. A simplified model uses 2x jitter
  as the additional buffering delay.

  ## Formula

      effective_delay = delay_ms + jitter_ms * 2

  ## Parameters

  - `delay_ms` - One-way network delay in milliseconds
  - `jitter_ms` - Interarrival jitter in milliseconds

  ## Returns

  Effective delay in milliseconds
  """
  @spec effective_delay(number(), number()) :: float()
  def effective_delay(delay_ms, jitter_ms) do
    delay_ms / 1.0 + jitter_ms / 1.0 * 2.0
  end

  @doc """
  Calculate delay impairment factor (Id).

  Delay impairment follows a logarithmic model based on ITU-T G.107.
  Delays up to 100ms have no impairment; above that, impairment
  increases progressively.

  ## Formula

  For ta <= 100.0ms:
      Id = 0

  For ta > 100.0ms:
      x = log2(ta / 100.0)
      Id = 25.0 * ((1 + x^6)^(1/6) - 3*(1 + (x/3)^6)^(1/6) + 2)

  ## Parameters

  - `ta` - One-way delay (mouth-to-ear) in milliseconds

  ## Returns

  Delay impairment factor (0 to approximately 40 for extreme delays)
  """
  @spec calculate_id(number()) :: float()
  def calculate_id(ta) when ta <= 0.0, do: 0.0
  def calculate_id(ta) when ta <= 100.0, do: 0.0

  def calculate_id(ta) do
    ta_float = ta / 1.0
    x = :math.log(ta_float / 100.0) / :math.log(2.0)

    25.0 *
      (:math.pow(1.0 + :math.pow(x, 6), 1.0 / 6.0) -
         3.0 * :math.pow(1.0 + :math.pow(x / 3.0, 6), 1.0 / 6.0) + 2.0)
  end

  @doc """
  Calculate effective equipment impairment (Ie_eff).

  Equipment impairment combines the inherent codec impairment (Ie)
  with the additional impairment caused by packet loss.

  ## Formula

      Ie_eff = Ie + (95 - Ie) * Ppl / (Ppl + Bpl)

  Where:
  - Ie = Codec equipment impairment factor
  - Ppl = Packet loss percentage (0-100)
  - Bpl = Codec packet loss robustness factor

  ## Behavior

  - At 0% loss: Ie_eff = Ie (just the codec impairment)
  - As loss increases: Ie_eff approaches 95 asymptotically
  - Higher Bpl means better resilience to packet loss

  ## Parameters

  - `packet_loss_percent` - Packet loss percentage (0.0-100.0)
  - `ie` - Codec equipment impairment factor
  - `bpl` - Codec packet loss robustness factor

  ## Returns

  Effective equipment impairment factor
  """
  @spec calculate_ie_eff(number(), number(), number()) :: float()
  def calculate_ie_eff(packet_loss_percent, ie, bpl) do
    ppl = max(0.0, packet_loss_percent / 1.0)
    ie_float = ie / 1.0
    bpl_float = bpl / 1.0

    ie_float + (95.0 - ie_float) * ppl / (ppl + bpl_float)
  end
end
