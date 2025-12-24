defmodule ParrotSip.SDP do
  @moduledoc """
  Helper module for building SDP (Session Description Protocol) offers and answers.

  This module provides a simple, safe API for constructing SDP messages
  without error-prone string concatenation.

  ## Example

      # Create an audio offer
      sdp = ParrotSip.SDP.audio_offer(
        host: "192.168.1.100",
        port: 10000,
        codecs: [:pcmu, :pcma]
      )

  The result is a string in SDP wire format ready to be included in a SIP message body.

  ## Supported Codecs

    * `:pcmu` - G.711 μ-law (payload type 0)
    * `:pcma` - G.711 A-law (payload type 8)
    * `:telephone_event` - DTMF tones (payload type 101)
  """

  @type codec :: :pcmu | :pcma | :telephone_event
  @type direction :: :sendrecv | :sendonly | :recvonly | :inactive

  @doc """
  Creates an SDP offer for an audio session.

  ## Options

    * `:host` - (required) Local IP address as string or tuple
    * `:port` - (required) Local RTP port
    * `:codecs` - List of codecs to offer (default: [:pcmu, :pcma])
    * `:session_name` - Session name (default: "ParrotSIP")
    * `:direction` - Media direction (default: :sendrecv)

  ## Returns

  A string containing the SDP offer in wire format.

  ## Examples

      # Basic audio offer
      sdp = audio_offer(host: "192.168.1.100", port: 10000)

      # Custom codecs and direction
      sdp = audio_offer(
        host: {192, 168, 1, 100},
        port: 20000,
        codecs: [:pcma, :telephone_event],
        session_name: "MyApp",
        direction: :sendonly
      )
  """
  @spec audio_offer(keyword()) :: String.t()
  def audio_offer(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    codecs = Keyword.get(opts, :codecs, [:pcmu, :pcma])
    session_name = Keyword.get(opts, :session_name, "ParrotSIP")
    direction = Keyword.get(opts, :direction, :sendrecv)

    host_str = format_host(host)

    # Generate unique session ID and version
    session_id = System.unique_integer([:positive])
    version = System.unique_integer([:positive])

    # Build payload types and rtpmap lines from codecs
    {payload_types, rtpmap_lines} = build_codec_lines(codecs)

    # Build SDP string
    """
    v=0
    o=- #{session_id} #{version} IN IP4 #{host_str}
    s=#{session_name}
    c=IN IP4 #{host_str}
    t=0 0
    m=audio #{port} RTP/AVP #{Enum.join(payload_types, " ")}
    #{Enum.join(rtpmap_lines, "\n")}
    a=#{direction}
    """
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Formats an IP address as a string
  defp format_host(host) when is_binary(host), do: host

  defp format_host({a, b, c, d})
       when is_integer(a) and is_integer(b) and is_integer(c) and
              is_integer(d) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  # Builds payload types list and rtpmap lines for the given codecs
  defp build_codec_lines(codecs) do
    {payload_types, rtpmap_lines} =
      Enum.reduce(codecs, {[], []}, fn codec, {pts, lines} ->
        case codec_info(codec) do
          {pt, rtpmap_line} ->
            {[pt | pts], [rtpmap_line | lines]}

          nil ->
            {pts, lines}
        end
      end)

    # Reverse to maintain original order
    {Enum.reverse(payload_types), Enum.reverse(rtpmap_lines)}
  end

  # Returns {payload_type, rtpmap_line} for a codec
  defp codec_info(:pcmu) do
    {0, "a=rtpmap:0 PCMU/8000"}
  end

  defp codec_info(:pcma) do
    {8, "a=rtpmap:8 PCMA/8000"}
  end

  defp codec_info(:telephone_event) do
    {101, "a=rtpmap:101 telephone-event/8000"}
  end

  defp codec_info(_), do: nil
end
