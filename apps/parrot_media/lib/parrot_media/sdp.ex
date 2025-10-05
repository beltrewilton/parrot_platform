defmodule ParrotMedia.Sdp do
  @moduledoc """
  SDP (Session Description Protocol) handling for media negotiation.
  
  This module belongs to the media layer as SDP is fundamentally about
  describing media sessions, not SIP protocol.
  """
  
  @doc """
  Builds an SDP offer.
  """
  def build_offer(opts) do
    local_ip = opts[:local_ip] || "127.0.0.1"
    local_port = opts[:local_port] || 10000
    codecs = opts[:codecs] || [opus: 111, pcma: 8, pcmu: 0]

    # Build SDP using ExSDP library
    payload_types = Enum.map(codecs, fn {_, pt} -> pt end)

    # Create media description
    media = ExSDP.Media.new(:audio, local_port, "RTP/AVP", payload_types)

    # Build complete SDP
    ExSDP.new(local_ip)
    |> ExSDP.add_media(media)
    |> to_string()
  end
  
  @doc """
  Parses an SDP string.
  """
  def parse(sdp_string) when is_binary(sdp_string) do
    ExSDP.parse(sdp_string)
  end
  
  @doc """
  Generates an SDP answer from an offer.
  """
  def generate_answer(offer_sdp, opts) do
    case parse(offer_sdp) do
      {:ok, offer} ->
        # Extract offered codecs
        offered_codecs = extract_codecs(offer)
        
        # Select compatible codecs
        selected_codecs = negotiate_codecs(offered_codecs, opts[:supported_codecs] || [:opus, :pcma, :pcmu])
        
        # Build answer
        build_offer(%{
          local_ip: opts[:local_ip],
          local_port: opts[:local_port],
          codecs: selected_codecs
        })
        
      {:error, _} = error ->
        error
    end
  end
  
  @doc """
  Extracts media information from parsed SDP.
  """
  def extract_media_info(sdp) do
    case parse(sdp) do
      {:ok, parsed} ->
        media = parsed.media
        |> Enum.find(fn m -> m.type == :audio end)
        
        if media do
          {:ok, %{
            port: media.port,
            codecs: extract_codecs(parsed),
            connection: parsed.connection
          }}
        else
          {:error, :no_audio_media}
        end
        
      error -> error
    end
  end
  
  defp extract_codecs(_parsed_sdp) do
    # Simplified codec extraction
    # In real implementation, this would parse rtpmap attributes
    [:opus, :pcma, :pcmu]
  end
  
  defp negotiate_codecs(offered, supported) do
    # Find common codecs
    Enum.filter(offered, fn codec -> codec in supported end)
    |> Enum.take(3)  # Limit to 3 codecs
  end
end