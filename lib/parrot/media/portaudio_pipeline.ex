defmodule Parrot.Media.PortAudioPipeline do
  @moduledoc """
  Membrane pipeline for bidirectional audio using system audio devices via PortAudio.

  This pipeline supports various combinations of audio sources and sinks:
  - Microphone to RTP (outbound audio)
  - RTP to Speaker (inbound audio)
  - File to Speaker (local playback)
  - RTP to File (recording)
  - Full duplex (microphone to RTP, RTP to speaker)

  ## Configuration Options

  - `:session_id` - Unique session identifier
  - `:audio_source` - `:device` | `:file` | `:silence`
  - `:audio_sink` - `:device` | `:file` | `:none`
  - `:audio_file` - Path to audio file when source is `:file`
  - `:output_file` - Path to output file when sink is `:file`
  - `:input_device_id` - PortAudio device ID for input (default: system default)
  - `:output_device_id` - PortAudio device ID for output (default: system default)
  - `:local_rtp_port` - Local RTP port
  - `:remote_rtp_address` - Remote RTP IP address
  - `:remote_rtp_port` - Remote RTP port
  """

  use Membrane.Pipeline
  require Logger

  alias Membrane.PortAudio
  alias Parrot.Media.G711Chunker

  @impl true
  def handle_init(_ctx, opts) do
    Logger.info("PortAudioPipeline: Starting for session #{opts.session_id}")
    Logger.info("  Audio source: #{opts.audio_source}, sink: #{opts.audio_sink}")

    # Validate options
    validate_opts!(opts)

    # Generate SSRC for RTP
    ssrc = :rand.uniform(0xFFFFFFFF)

    # Build appropriate pipeline structure based on source/sink combination
    structure = build_pipeline_structure(opts, ssrc)

    state = %{
      session_id: opts.session_id,
      audio_source: opts.audio_source,
      audio_sink: opts.audio_sink,
      playing: false,
      output_device_id: opts[:output_device_id],
      recording_output_file: opts[:output_file]
    }

    {[spec: structure], state}
  end

  @impl true
  def handle_child_notification({:end_of_stream, _pad}, :file_source, _ctx, state) do
    Logger.info("PortAudioPipeline #{state.session_id}: Audio file playback completed")
    {[], state}
  end

  @impl true
  def handle_child_notification({:new_rtp_stream, ssrc, pt, _extensions}, :rtp, _ctx, state) do
    Logger.info(
      "PortAudioPipeline #{state.session_id}: New RTP stream detected - SSRC: #{ssrc}, PT: #{pt}"
    )

    if receive_audio?(state) do
      Logger.debug("Creating receive pipeline for SSRC #{ssrc}, payload type #{pt}")

      {depayloader, decoder} =
        case pt do
          8 ->
            {Membrane.RTP.G711.Depayloader, Membrane.G711.Decoder}

          111 ->
            {Membrane.RTP.Opus.Depayloader, Membrane.Opus.Decoder}

          _ ->
            Logger.warning("Unsupported payload type #{pt}, defaulting to G.711 A-law")
            {Membrane.RTP.G711.Depayloader, Membrane.G711.Decoder}
        end

      structure = build_receive_pipeline(state, ssrc, pt, depayloader, decoder)

      {[spec: structure], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_child_notification(notification, child, _ctx, state) do
    Logger.debug(
      "PortAudioPipeline #{state.session_id}: Notification from #{child}: #{inspect(notification)}"
    )

    {[], state}
  end

  # Private functions

  defp validate_opts!(opts) do
    # Ensure required options are present
    required = [
      :session_id,
      :audio_source,
      :audio_sink,
      :local_rtp_port,
      :remote_rtp_address,
      :remote_rtp_port
    ]

    Enum.each(required, fn key ->
      if is_nil(opts[key]) do
        raise ArgumentError, "Required option #{key} is missing"
      end
    end)

    # Validate source/sink combinations
    case {opts.audio_source, opts.audio_sink} do
      {:file, _} when is_nil(opts.audio_file) ->
        raise ArgumentError, "audio_file is required when audio_source is :file"

      {_, :file} when is_nil(opts.output_file) ->
        raise ArgumentError, "output_file is required when audio_sink is :file"

      _ ->
        :ok
    end
  end

  defp build_pipeline_structure(opts, ssrc) do
    # Build common RTP elements
    udp_endpoint = build_udp_endpoint(opts)
    rtp_session = build_rtp_session()

    # Build source and sink pipelines
    source_spec = build_source_pipeline(opts.audio_source, opts, ssrc, udp_endpoint, rtp_session)
    sink_spec = build_sink_pipeline(opts.audio_sink, opts, udp_endpoint, rtp_session)

    # Combine specs
    [udp_endpoint, rtp_session] ++ source_spec ++ sink_spec
  end

  defp build_udp_endpoint(opts) do
    child(:udp_endpoint, %Membrane.UDP.Endpoint{
      local_port_no: opts.local_rtp_port,
      destination_port_no: opts.remote_rtp_port,
      destination_address: parse_ip!(opts.remote_rtp_address)
    })
  end

  defp build_rtp_session do
    child(:rtp, %Membrane.RTP.SessionBin{
      fmt_mapping: %{
        # G.711 A-law only (Opus send not implemented)
        8 => {:PCMA, 8000}
      },
      # Send RTCP receiver reports
      rtcp_receiver_report_interval: Membrane.Time.seconds(5),
      # Send RTCP sender reports
      rtcp_sender_report_interval: Membrane.Time.seconds(5)
    })
  end

  defp build_source_pipeline(:device, opts, ssrc, _udp, _rtp) do
    device_id = opts[:input_device_id]

    children = [
      child(:mic_source, %PortAudio.Source{
        device_id: device_id || :default,
        portaudio_buffer_size: 512,
        latency: :high,
        channels: 1,
        sample_rate: 48_000
      }),
      child(:resampler, %Membrane.FFmpeg.SWResample.Converter{
        output_stream_format: %Membrane.RawAudio{
          sample_format: :s16le,
          sample_rate: 8000,
          channels: 1
        }
      }),
      child(:g711_encoder, Membrane.G711.Encoder),
      child(:g711_chunker, %G711Chunker{chunk_duration: 20}),
      child(:realtimer, Membrane.Realtimer)
    ]

    if recording_enabled?(opts) do
      caller_raw_path = caller_recording_path(opts.output_file)

      children ++
        [
          child(:caller_recording_tee, Membrane.Tee.Master),
          child(:caller_file_sink, %Membrane.File.Sink{location: caller_raw_path}),
          get_child(:mic_source)
          |> get_child(:resampler)
          |> get_child(:caller_recording_tee),
          get_child(:caller_recording_tee)
          |> via_out(:master)
          |> get_child(:g711_encoder)
          |> get_child(:g711_chunker)
          |> get_child(:realtimer)
          |> via_in(Pad.ref(:input, ssrc),
            options: [payloader: Membrane.RTP.G711.Payloader]
          )
          |> get_child(:rtp)
          |> via_out(Pad.ref(:rtp_output, ssrc), options: [encoding: :PCMA])
          |> get_child(:udp_endpoint),
          get_child(:caller_recording_tee)
          |> via_out(Pad.ref(:copy, :caller_recording))
          |> get_child(:caller_file_sink)
        ]
    else
      children ++
        [
          get_child(:mic_source)
          |> get_child(:resampler)
          |> get_child(:g711_encoder)
          |> get_child(:g711_chunker)
          |> get_child(:realtimer)
          |> via_in(Pad.ref(:input, ssrc),
            options: [payloader: Membrane.RTP.G711.Payloader]
          )
          |> get_child(:rtp)
          |> via_out(Pad.ref(:rtp_output, ssrc), options: [encoding: :PCMA])
          |> get_child(:udp_endpoint)
        ]
    end
  end

  defp build_source_pipeline(:file, opts, ssrc, _udp, _rtp) do
    [
      # File source
      child(:file_source, %Membrane.File.Source{
        location: opts.audio_file
      }),

      # Parse WAV
      child(:wav_parser, Membrane.WAV.Parser),

      # Convert to G.711
      child(:g711_encoder, Membrane.G711.Encoder),

      # Chunk for RTP
      child(:g711_chunker, %G711Chunker{chunk_duration: 20}),

      # Add timing
      child(:realtimer, Membrane.Realtimer),

      # Links
      get_child(:file_source)
      |> get_child(:wav_parser)
      |> get_child(:g711_encoder)
      |> get_child(:g711_chunker)
      |> get_child(:realtimer)
      |> via_in(Pad.ref(:input, ssrc),
        options: [payloader: Membrane.RTP.G711.Payloader]
      )
      |> get_child(:rtp)
      |> via_out(Pad.ref(:rtp_output, ssrc), options: [encoding: :PCMA])
      |> get_child(:udp_endpoint)
    ]
  end

  defp build_source_pipeline(:silence, _opts, _ssrc, _udp, _rtp) do
    # For now, don't send anything when source is silence
    # In the future, we could generate comfort noise
    []
  end

  defp build_source_pipeline(source, _opts, _ssrc, _udp, _rtp) when source in [:none, nil] do
    []
  end

  defp build_sink_pipeline(:device, _opts, _udp, _rtp) do
    rtp_input_route()
  end

  defp build_sink_pipeline(:file, _opts, _udp, _rtp) do
    rtp_input_route()
  end

  defp build_sink_pipeline(sink, opts, _udp, _rtp) when sink in [:none, nil] do
    if recording_enabled?(opts), do: rtp_input_route(), else: []
  end

  defp build_receive_pipeline(state, ssrc, pt, depayloader, decoder) do
    decoder_id = {:decoder, ssrc}
    speaker? = speaker_enabled?(state)
    recording? = recording_enabled?(state)
    tee_id = {:remote_recording_tee, ssrc}
    recording_resampler_id = {:recording_resampler, ssrc}
    speaker_resampler_id = {:speaker_resampler, ssrc}
    speaker_sink_id = {:speaker_sink, ssrc}
    callee_sink_id = {:callee_file_sink, ssrc}

    children =
      [
        get_child(:rtp)
        |> via_out(Pad.ref(:output, ssrc), options: [depayloader: depayloader])
        |> child(decoder_id, decoder)
      ] ++
        if(recording?, do: [child(tee_id, Membrane.Tee.Master)], else: []) ++
        if(recording?,
          do: [
            child(callee_sink_id, %Membrane.File.Sink{
              location: callee_recording_path(state.recording_output_file)
            })
          ],
          else: []
        ) ++
        if(recording? and pt == 111,
          do: [recording_resampler_spec(recording_resampler_id)],
          else: []
        ) ++
        if(speaker? and pt == 8, do: [speaker_resampler_spec(speaker_resampler_id)], else: []) ++
        if(speaker?, do: [speaker_sink_spec(speaker_sink_id, state.output_device_id)], else: [])

    links =
      if recording? do
        [
          get_child(decoder_id)
          |> get_child(tee_id)
        ] ++
          recording_link(tee_id, callee_sink_id, recording_resampler_id, ssrc, pt) ++
          speaker_links(tee_id, speaker_sink_id, speaker_resampler_id, pt, true, speaker?)
      else
        speaker_links(decoder_id, speaker_sink_id, speaker_resampler_id, pt, false, speaker?)
      end

    children ++ links
  end

  defp rtp_input_route do
    [
      get_child(:udp_endpoint)
      |> via_out(:output)
      |> via_in(Pad.ref(:rtp_input, make_ref()))
      |> get_child(:rtp)
    ]
  end

  defp recording_link(tee_id, callee_sink_id, recording_resampler_id, ssrc, 111) do
    [
      get_child(tee_id)
      |> via_out(Pad.ref(:copy, {:callee_recording, ssrc}))
      |> get_child(recording_resampler_id)
      |> get_child(callee_sink_id)
    ]
  end

  defp recording_link(tee_id, callee_sink_id, _recording_resampler_id, ssrc, _pt) do
    [
      get_child(tee_id)
      |> via_out(Pad.ref(:copy, {:callee_recording, ssrc}))
      |> get_child(callee_sink_id)
    ]
  end

  defp speaker_links(_source_id, _speaker_sink_id, _speaker_resampler_id, _pt, _from_tee?, false),
    do: []

  defp speaker_links(source_id, speaker_sink_id, speaker_resampler_id, 8, from_tee?, true) do
    [speaker_chain(source_id, speaker_resampler_id, speaker_sink_id, from_tee?)]
  end

  defp speaker_links(source_id, speaker_sink_id, _speaker_resampler_id, _pt, from_tee?, true) do
    [speaker_chain(source_id, nil, speaker_sink_id, from_tee?)]
  end

  defp speaker_chain(source_id, nil, speaker_sink_id, true) do
    get_child(source_id)
    |> via_out(:master)
    |> get_child(speaker_sink_id)
  end

  defp speaker_chain(source_id, nil, speaker_sink_id, false) do
    get_child(source_id)
    |> get_child(speaker_sink_id)
  end

  defp speaker_chain(source_id, speaker_resampler_id, speaker_sink_id, true) do
    get_child(source_id)
    |> via_out(:master)
    |> get_child(speaker_resampler_id)
    |> get_child(speaker_sink_id)
  end

  defp speaker_chain(source_id, speaker_resampler_id, speaker_sink_id, false) do
    get_child(source_id)
    |> get_child(speaker_resampler_id)
    |> get_child(speaker_sink_id)
  end

  defp speaker_resampler_spec(id) do
    child(id, %Membrane.FFmpeg.SWResample.Converter{
      input_stream_format: %Membrane.RawAudio{
        sample_format: :s16le,
        sample_rate: 8_000,
        channels: 1
      },
      output_stream_format: %Membrane.RawAudio{
        sample_format: :s16le,
        sample_rate: 48_000,
        channels: 1
      }
    })
  end

  defp recording_resampler_spec(id) do
    child(id, %Membrane.FFmpeg.SWResample.Converter{
      input_stream_format: %Membrane.RawAudio{
        sample_format: :s16le,
        sample_rate: 48_000,
        channels: 1
      },
      output_stream_format: %Membrane.RawAudio{
        sample_format: :s16le,
        sample_rate: 8_000,
        channels: 1
      }
    })
  end

  defp speaker_sink_spec(id, output_device_id) do
    child(id, %Membrane.PortAudio.Sink{
      device_id: output_device_id || :default,
      portaudio_buffer_size: 1024,
      latency: :high
    })
  end

  defp receive_audio?(state), do: speaker_enabled?(state) or recording_enabled?(state)

  defp speaker_enabled?(%{audio_sink: :device}), do: true
  defp speaker_enabled?(_state), do: false

  defp recording_enabled?(%{recording_output_file: output_file}),
    do: recording_enabled?(output_file)

  defp recording_enabled?(%{output_file: output_file}), do: recording_enabled?(output_file)
  defp recording_enabled?(output_file) when is_binary(output_file), do: output_file != ""
  defp recording_enabled?(_output_file), do: false

  defp caller_recording_path(output_file), do: output_file <> ".caller.s16le"
  defp callee_recording_path(output_file), do: output_file <> ".callee.s16le"

  defp parse_ip!(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} ->
        ip_tuple

      {:error, reason} ->
        raise ArgumentError, "Invalid IP address #{ip_string}: #{inspect(reason)}"
    end
  end
end
