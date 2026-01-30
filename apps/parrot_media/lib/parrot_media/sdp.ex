defmodule ParrotMedia.Sdp do
  @moduledoc """
  SDP (Session Description Protocol) handling for media negotiation.

  This module uses ExSDP for all SDP operations and provides a high-level API
  for building offers, processing offers/answers, and extracting media information.

  ## Supported Codecs

  - `:pcma` - G.711 A-law (payload type 8)
  - `:opus` - Opus (payload type 111)

  Note: PCMU (G.711 μ-law, payload type 0) is recognized in SDP parsing but NOT
  supported for encoding/decoding due to membrane_g711_plugin limitations.

  ## Examples

      # Build an SDP offer
      {:ok, offer} = Sdp.build_offer(
        local_ip: "192.168.1.100",
        local_port: 10000,
        supported_codecs: [:pcma, :opus],
        direction: :sendrecv
      )

      # Process an offer and generate an answer
      {:ok, answer_info} = Sdp.process_offer_and_answer(
        offer_sdp,
        local_ip: "192.168.1.200",
        local_port: 20000,
        supported_codecs: [:pcma]
      )

      # Extract information from an answer
      {:ok, remote_info} = Sdp.process_answer(answer_sdp)
  """

  alias ExSDP

  @type codec :: :pcma | :pcmu | :opus
  @type direction :: :sendrecv | :sendonly | :recvonly | :inactive
  @type ip_address :: String.t() | tuple()

  # Codec definitions: {payload_type, encoding_name, clock_rate, channels}
  @codec_defs %{
    pcma: {8, "PCMA", 8000, nil},
    pcmu: {0, "PCMU", 8000, nil},
    opus: {111, "opus", 48000, 1}
  }

  @doc """
  Builds an SDP offer.

  ## Options

  - `:local_ip` - Local IP address (string or tuple, required)
  - `:local_port` - Local RTP port (required)
  - `:supported_codecs` - List of supported codecs (defaults to [:pcma])
  - `:direction` - Media direction (defaults to :sendrecv)

  ## Returns

  - `{:ok, sdp_string}` on success
  - `{:error, reason}` on failure

  ## Examples

      {:ok, offer} = Sdp.build_offer(
        local_ip: "192.168.1.100",
        local_port: 10000,
        supported_codecs: [:pcma, :opus],
        direction: :sendrecv
      )
  """
  @spec build_offer(keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_offer(opts) do
    with {:ok, local_ip} <- get_required_option(opts, :local_ip),
         {:ok, local_port} <- get_required_option(opts, :local_port) do
      supported_codecs = Keyword.get(opts, :supported_codecs, [:pcma])
      direction = Keyword.get(opts, :direction, :sendrecv)
      # Use provided session_version or default to system time
      session_version = Keyword.get(opts, :session_version, :os.system_time(:second))

      # Normalize IP to tuple format
      ip_tuple = normalize_ip_to_tuple(local_ip)

      # Build formats and attributes from codecs
      formats = Enum.map(supported_codecs, fn codec -> codec_info(codec).payload_type end)

      attributes =
        Enum.flat_map(supported_codecs, fn codec ->
          build_codec_attributes(codec)
        end) ++ [direction]

      # Build SDP
      sdp = %ExSDP{
        version: 0,
        origin: %ExSDP.Origin{
          username: "-",
          session_id: :os.system_time(:second),
          session_version: session_version,
          network_type: "IN",
          address: ip_tuple
        },
        session_name: "Parrot Media Session",
        connection_data: %ExSDP.ConnectionData{
          network_type: "IN",
          address: ip_tuple
        },
        timing: %ExSDP.Timing{
          start_time: 0,
          stop_time: 0
        },
        media: [
          %ExSDP.Media{
            type: :audio,
            port: local_port,
            protocol: "RTP/AVP",
            fmt: formats,
            attributes: attributes
          }
        ]
      }

      {:ok, to_string(sdp)}
    end
  end

  @doc """
  Builds an SDP answer for a specific codec, preserving auxiliary payload types from offer.

  This function is useful when you've already parsed the offer and negotiated a codec,
  and just need to generate the SDP answer string. It preserves auxiliary payload types
  like telephone-event (RFC 4733 DTMF) from the offer.

  ## Options

  - `:local_ip` - Local IP address (string or tuple, required)
  - `:local_port` - Local RTP port (required)
  - `:direction` - Media direction (defaults to :sendrecv)
  - `:offer_audio_media` - Parsed audio media from offer (to extract telephone-event)

  ## Returns

  - `{:ok, sdp_answer_string}` on success
  - `{:error, reason}` on failure

  ## Examples

      # After parsing offer and negotiating codec
      {:ok, answer_sdp} = Sdp.build_answer_for_codec(:pcma,
        local_ip: "192.168.1.200",
        local_port: 20000,
        offer_audio_media: parsed_audio_media
      )
  """
  @spec build_answer_for_codec(codec(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_answer_for_codec(selected_codec, opts) do
    # Get offer's audio media to extract telephone-event
    offer_audio_media = Keyword.get(opts, :offer_audio_media)

    if offer_audio_media do
      build_answer(nil, offer_audio_media, selected_codec, opts)
    else
      # Fallback to simple offer (no telephone-event)
      build_offer(
        local_ip: Keyword.get(opts, :local_ip),
        local_port: Keyword.get(opts, :local_port),
        supported_codecs: [selected_codec],
        direction: Keyword.get(opts, :direction, :sendrecv)
      )
    end
  end

  @doc """
  Processes an SDP offer and generates an answer with all negotiated information.

  ## Options

  - `:local_ip` - Local IP address (string or tuple, required)
  - `:local_port` - Local RTP port (required)
  - `:supported_codecs` - List of supported codecs (defaults to [:pcma])
  - `:direction` - Media direction (defaults to :sendrecv)

  ## Returns

  Returns `{:ok, info}` where info is a map containing:
  - `:answer` - The SDP answer string
  - `:selected_codec` - The negotiated codec
  - `:remote_ip` - Remote IP address
  - `:remote_port` - Remote RTP port

  Returns `{:error, reason}` on failure.

  ## Examples

      {:ok, %{
        answer: "v=0\\r\\n...",
        selected_codec: :pcma,
        remote_ip: "192.168.1.100",
        remote_port: 10000
      }} = Sdp.process_offer_and_answer(offer_sdp,
        local_ip: "192.168.1.200",
        local_port: 20000,
        supported_codecs: [:pcma]
      )
  """
  @spec process_offer_and_answer(String.t(), keyword()) ::
          {:ok,
           %{
             answer: String.t(),
             selected_codec: codec(),
             remote_ip: String.t(),
             remote_port: non_neg_integer()
           }}
          | {:error, term()}
  def process_offer_and_answer(offer_sdp, opts) do
    with {:ok, parsed_offer} <- parse(offer_sdp),
         {:ok, audio_media} <- find_audio_media(parsed_offer),
         {:ok, remote_ip} <- extract_remote_ip(parsed_offer),
         remote_port = audio_media.port,
         offered_codecs = extract_codecs(parsed_offer),
         supported_codecs = Keyword.get(opts, :supported_codecs, [:pcma]),
         {:ok, selected_codec} <- negotiate_codec(offered_codecs, supported_codecs),
         {:ok, answer} <- build_answer(parsed_offer, audio_media, selected_codec, opts) do
      {:ok,
       %{
         answer: answer,
         selected_codec: selected_codec,
         remote_ip: remote_ip,
         remote_port: remote_port
       }}
    end
  end

  @doc """
  Processes an SDP answer to extract remote endpoint information.

  ## Returns

  Returns `{:ok, info}` where info is a map containing:
  - `:remote_ip` - Remote IP address
  - `:remote_port` - Remote RTP port
  - `:selected_codec` - The codec in the answer

  Returns `{:error, reason}` on failure.

  ## Examples

      {:ok, %{
        remote_ip: "192.168.1.100",
        remote_port: 10000,
        selected_codec: :pcma
      }} = Sdp.process_answer(answer_sdp)
  """
  @spec process_answer(String.t()) ::
          {:ok,
           %{
             remote_ip: String.t(),
             remote_port: non_neg_integer(),
             selected_codec: codec()
           }}
          | {:error, term()}
  def process_answer(answer_sdp) do
    with {:ok, parsed_answer} <- parse(answer_sdp),
         {:ok, audio_media} <- find_audio_media(parsed_answer),
         {:ok, remote_ip} <- extract_remote_ip(parsed_answer),
         remote_port = audio_media.port,
         codecs = extract_codecs(parsed_answer),
         selected_codec = List.first(codecs, :pcma) do
      {:ok,
       %{
         remote_ip: remote_ip,
         remote_port: remote_port,
         selected_codec: selected_codec
       }}
    end
  end

  @doc """
  Parses an SDP string using ExSDP.

  ## Examples

      {:ok, parsed_sdp} = Sdp.parse(sdp_string)
  """
  @spec parse(String.t()) :: {:ok, ExSDP.t()} | {:error, term()}
  def parse(sdp_string) when is_binary(sdp_string) do
    ExSDP.parse(sdp_string)
  end

  @doc """
  Extracts codec atoms from a parsed SDP.

  Returns a list of codec atoms in the order they appear in the SDP.

  ## Examples

      {:ok, parsed} = Sdp.parse(sdp_string)
      codecs = Sdp.extract_codecs(parsed)
      # => [:pcma, :opus]
  """
  @spec extract_codecs(ExSDP.t()) :: [codec()]
  def extract_codecs(%ExSDP{} = parsed_sdp) do
    case find_audio_media(parsed_sdp) do
      {:ok, audio_media} -> extract_codecs_from_media(audio_media)
      {:error, _} -> []
    end
  end

  @doc """
  Extracts the remote endpoint (IP and port) from a parsed SDP.

  ## Returns

  - `{:ok, {ip_string, port}}` on success
  - `{:error, reason}` on failure

  ## Examples

      {:ok, parsed} = Sdp.parse(sdp_string)
      {:ok, {"192.168.1.100", 10000}} = Sdp.extract_remote_endpoint(parsed)
  """
  @spec extract_remote_endpoint(ExSDP.t()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def extract_remote_endpoint(parsed_sdp) do
    with {:ok, audio_media} <- find_audio_media(parsed_sdp),
         {:ok, remote_ip} <- extract_remote_ip(parsed_sdp),
         remote_port = audio_media.port do
      {:ok, {remote_ip, remote_port}}
    end
  end

  @doc """
  Negotiates a codec from offered and supported codec lists.

  Returns the first codec that appears in both lists (prioritizing the offered order).

  ## Examples

      {:ok, :pcma} = Sdp.negotiate_codec([:pcma, :opus], [:opus, :pcma])
      # => {:ok, :pcma} (first common codec from offered list)
  """
  @spec negotiate_codec([codec()], [codec()]) :: {:ok, codec()} | {:error, :no_common_codec}
  def negotiate_codec(offered_codecs, supported_codecs) do
    case Enum.find(offered_codecs, fn codec -> codec in supported_codecs end) do
      nil -> {:error, :no_common_codec}
      codec -> {:ok, codec}
    end
  end

  @doc """
  Returns codec information for a given codec.

  Returns a map with:
  - `:payload_type` - RTP payload type
  - `:encoding` - Encoding name
  - `:clock_rate` - Clock rate in Hz
  - `:channels` - Number of channels (nil for mono)

  ## Examples

      Sdp.codec_info(:pcma)
      # => %{payload_type: 8, encoding: "PCMA", clock_rate: 8000, channels: nil}

      Sdp.codec_info(:opus)
      # => %{payload_type: 111, encoding: "opus", clock_rate: 48000, channels: 1}
  """
  @spec codec_info(codec()) :: %{
          payload_type: non_neg_integer(),
          encoding: String.t(),
          clock_rate: non_neg_integer(),
          channels: non_neg_integer() | nil
        }
  def codec_info(codec) do
    {pt, encoding, clock_rate, channels} = Map.fetch!(@codec_defs, codec)

    %{
      payload_type: pt,
      encoding: encoding,
      clock_rate: clock_rate,
      channels: channels
    }
  end

  # Private functions

  defp get_required_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_required_option, key}}
    end
  end

  defp normalize_ip_to_tuple(ip) when is_tuple(ip), do: ip

  defp normalize_ip_to_tuple(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, ip_tuple} -> ip_tuple
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  defp normalize_ip_to_tuple(_), do: {127, 0, 0, 1}

  defp normalize_ip_to_string(ip) when is_binary(ip), do: ip

  defp normalize_ip_to_string(ip) when is_tuple(ip) do
    ip |> Tuple.to_list() |> Enum.join(".")
  end

  defp normalize_ip_to_string(_), do: "127.0.0.1"

  defp build_codec_attributes(codec) do
    info = codec_info(codec)

    base_attrs = [
      %ExSDP.Attribute.RTPMapping{
        payload_type: info.payload_type,
        encoding: info.encoding,
        clock_rate: info.clock_rate,
        params: info.channels
      }
    ]

    # Add codec-specific attributes
    codec_specific_attrs =
      case codec do
        :opus ->
          [
            %ExSDP.Attribute.FMTP{pt: info.payload_type, stereo: false, useinbandfec: true},
            {:ptime, 20}
          ]

        _ ->
          []
      end

    base_attrs ++ codec_specific_attrs
  end

  defp build_answer(_parsed_offer, audio_media, selected_codec, opts) do
    with {:ok, local_ip} <- get_required_option(opts, :local_ip),
         {:ok, local_port} <- get_required_option(opts, :local_port) do
      direction = Keyword.get(opts, :direction, :sendrecv)
      ip_tuple = normalize_ip_to_tuple(local_ip)
      info = codec_info(selected_codec)

      # Start with the selected audio codec attributes
      base_attributes = build_codec_attributes(selected_codec)
      base_fmt = [info.payload_type]

      # Extract telephone-event from offer if present (RFC 4733)
      # This ensures DTMF support is echoed back in the answer
      # Pass the codec's clock rate to match telephone-event (per RFC 4733)
      {te_fmt, te_attributes} = extract_telephone_event_from_offer(audio_media, info.clock_rate)

      # Combine formats and attributes
      fmt = base_fmt ++ te_fmt
      attributes = base_attributes ++ te_attributes ++ [direction]

      sdp = %ExSDP{
        version: 0,
        origin: %ExSDP.Origin{
          username: "-",
          session_id: :os.system_time(:second),
          session_version: :os.system_time(:second),
          network_type: "IN",
          address: ip_tuple
        },
        session_name: "Parrot Media Session",
        connection_data: %ExSDP.ConnectionData{
          network_type: "IN",
          address: ip_tuple
        },
        timing: %ExSDP.Timing{
          start_time: 0,
          stop_time: 0
        },
        media: [
          %ExSDP.Media{
            type: :audio,
            port: local_port,
            protocol: "RTP/AVP",
            fmt: fmt,
            attributes: attributes
          }
        ]
      }

      {:ok, to_string(sdp)}
    end
  end

  # Extract telephone-event payload type and attributes from offer
  # Returns {[pt], [attributes]} or {[], []} if not present
  # Per RFC 4733, telephone-event clock rate should match the audio codec clock rate
  defp extract_telephone_event_from_offer(audio_media, target_clock_rate) do
    # Find all telephone-event rtpmaps in offer attributes
    te_rtpmaps =
      audio_media.attributes
      |> Enum.filter(fn
        %ExSDP.Attribute.RTPMapping{encoding: encoding} ->
          String.downcase(encoding) == "telephone-event"

        _ ->
          false
      end)

    # Prefer telephone-event matching the audio codec's clock rate (per RFC 4733)
    # Fall back to any telephone-event if no exact match
    te_rtpmap =
      Enum.find(te_rtpmaps, fn %ExSDP.Attribute.RTPMapping{clock_rate: cr} ->
        cr == target_clock_rate
      end) || List.first(te_rtpmaps)

    case te_rtpmap do
      %ExSDP.Attribute.RTPMapping{payload_type: pt, clock_rate: clock_rate} ->
        # Echo back the telephone-event with same PT
        rtpmap = %ExSDP.Attribute.RTPMapping{
          payload_type: pt,
          encoding: "telephone-event",
          clock_rate: clock_rate
        }

        # Find and echo back fmtp attribute if present (e.g., "0-15" for digits)
        fmtp =
          Enum.find(audio_media.attributes, fn
            %ExSDP.Attribute.FMTP{pt: fmtp_pt} -> fmtp_pt == pt
            _ -> false
          end)

        fmtp_attrs =
          case fmtp do
            %ExSDP.Attribute.FMTP{} = f -> [f]
            _ -> []
          end

        {[pt], [rtpmap | fmtp_attrs]}

      nil ->
        {[], []}
    end
  end

  defp find_audio_media(%ExSDP{media: media}) do
    case Enum.find(media, &(&1.type == :audio)) do
      nil -> {:error, :no_audio_media}
      audio_media -> {:ok, audio_media}
    end
  end

  defp extract_remote_ip(%ExSDP{connection_data: %{address: addr}}) when is_tuple(addr) do
    {:ok, normalize_ip_to_string(addr)}
  end

  defp extract_remote_ip(%ExSDP{connection_data: %{address: addr}}) when is_binary(addr) do
    {:ok, addr}
  end

  defp extract_remote_ip(%ExSDP{connection_data: %{address: addr}}) do
    {:ok, to_string(addr)}
  end

  defp extract_remote_ip(_) do
    {:error, :no_connection_data}
  end

  defp extract_codecs_from_media(audio_media) do
    # Build codec map from payload types
    static_codec_map = %{
      0 => :pcmu,
      8 => :pcma
    }

    # Extract dynamic codecs from rtpmap attributes
    dynamic_codecs =
      audio_media.attributes
      |> Enum.filter(&match?(%ExSDP.Attribute.RTPMapping{}, &1))
      |> Enum.map(fn rtpmap ->
        case String.downcase(rtpmap.encoding) do
          "opus" -> {rtpmap.payload_type, :opus}
          "pcma" -> {rtpmap.payload_type, :pcma}
          "pcmu" -> {rtpmap.payload_type, :pcmu}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    # Merge static and dynamic codecs
    codec_map = Map.merge(static_codec_map, dynamic_codecs)

    # Extract codecs from fmt list in order
    audio_media.fmt
    |> Enum.map(fn pt -> codec_map[pt] end)
    |> Enum.reject(&is_nil/1)
  end
end
