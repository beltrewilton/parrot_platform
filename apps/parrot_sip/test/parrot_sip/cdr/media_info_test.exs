defmodule ParrotSip.CDR.MediaInfoTest do
  use ExUnit.Case, async: true

  alias ParrotSip.CDR.MediaInfo

  describe "struct creation" do
    test "creates struct with all fields" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_score: 4.2,
        packets_sent: 1500,
        packets_received: 1480,
        jitter_ms: 5.5
      }

      assert media_info.codec == "PCMU"
      assert media_info.codec_payload_type == 0
      assert media_info.mos_score == 4.2
      assert media_info.packets_sent == 1500
      assert media_info.packets_received == 1480
      assert media_info.jitter_ms == 5.5
    end

    test "all fields default to nil" do
      media_info = %MediaInfo{}

      assert media_info.codec == nil
      assert media_info.codec_payload_type == nil
      assert media_info.mos_score == nil
      assert media_info.packets_sent == nil
      assert media_info.packets_received == nil
      assert media_info.jitter_ms == nil
    end

    test "creates struct with partial data" do
      media_info = %MediaInfo{
        codec: "opus",
        codec_payload_type: 111
      }

      assert media_info.codec == "opus"
      assert media_info.codec_payload_type == 111
      assert media_info.mos_score == nil
      assert media_info.packets_sent == nil
      assert media_info.packets_received == nil
      assert media_info.jitter_ms == nil
    end
  end

  describe "typical media scenarios" do
    test "PCMU call with quality metrics" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_score: 4.2,
        packets_sent: 1500,
        packets_received: 1480,
        jitter_ms: 5.5
      }

      assert media_info.codec == "PCMU"
      assert media_info.codec_payload_type == 0
      assert media_info.mos_score == 4.2
      assert media_info.packets_sent == 1500
      assert media_info.packets_received == 1480
      assert media_info.jitter_ms == 5.5
    end

    test "PCMA (G.711 A-law) call" do
      media_info = %MediaInfo{
        codec: "PCMA",
        codec_payload_type: 8,
        mos_score: 4.0,
        packets_sent: 3000,
        packets_received: 2985,
        jitter_ms: 8.2
      }

      assert media_info.codec == "PCMA"
      assert media_info.codec_payload_type == 8
      assert media_info.mos_score == 4.0
      assert media_info.packets_sent == 3000
      assert media_info.packets_received == 2985
      assert media_info.jitter_ms == 8.2
    end

    test "Opus codec call with dynamic payload type" do
      media_info = %MediaInfo{
        codec: "opus",
        codec_payload_type: 111,
        mos_score: 4.5,
        packets_sent: 2500,
        packets_received: 2490,
        jitter_ms: 3.2
      }

      assert media_info.codec == "opus"
      assert media_info.codec_payload_type == 111
      assert media_info.mos_score == 4.5
      assert media_info.packets_sent == 2500
      assert media_info.packets_received == 2490
      assert media_info.jitter_ms == 3.2
    end

    test "G.729 codec call" do
      media_info = %MediaInfo{
        codec: "G729",
        codec_payload_type: 18,
        mos_score: 3.8,
        packets_sent: 6000,
        packets_received: 5950,
        jitter_ms: 12.5
      }

      assert media_info.codec == "G729"
      assert media_info.codec_payload_type == 18
      assert media_info.mos_score == 3.8
      assert media_info.packets_sent == 6000
      assert media_info.packets_received == 5950
      assert media_info.jitter_ms == 12.5
    end

    test "telephone-event codec (DTMF)" do
      media_info = %MediaInfo{
        codec: "telephone-event",
        codec_payload_type: 101,
        packets_sent: 50,
        packets_received: 48
      }

      assert media_info.codec == "telephone-event"
      assert media_info.codec_payload_type == 101
      assert media_info.mos_score == nil
      assert media_info.packets_sent == 50
      assert media_info.packets_received == 48
      assert media_info.jitter_ms == nil
    end
  end

  describe "edge cases" do
    test "zero packet counts" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        packets_sent: 0,
        packets_received: 0
      }

      assert media_info.packets_sent == 0
      assert media_info.packets_received == 0
    end

    test "MOS score at minimum (bad quality)" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_score: 1.0
      }

      assert media_info.mos_score == 1.0
    end

    test "MOS score at maximum (perfect quality)" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_score: 5.0
      }

      assert media_info.mos_score == 5.0
    end

    test "MOS score typical poor quality" do
      media_info = %MediaInfo{
        codec: "G729",
        codec_payload_type: 18,
        mos_score: 2.5
      }

      assert media_info.mos_score == 2.5
    end

    test "zero jitter" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        jitter_ms: 0.0
      }

      assert media_info.jitter_ms == 0.0
    end

    test "high jitter (poor network conditions)" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        jitter_ms: 150.0
      }

      assert media_info.jitter_ms == 150.0
    end

    test "large packet counts (long call)" do
      # 1 hour call at 50 packets/second = 180,000 packets
      media_info = %MediaInfo{
        codec: "opus",
        codec_payload_type: 111,
        packets_sent: 180_000,
        packets_received: 179_500,
        jitter_ms: 10.3,
        mos_score: 4.1
      }

      assert media_info.packets_sent == 180_000
      assert media_info.packets_received == 179_500
    end

    test "codec only (no quality metrics available)" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0
      }

      assert media_info.codec == "PCMU"
      assert media_info.codec_payload_type == 0
      assert media_info.mos_score == nil
      assert media_info.packets_sent == nil
      assert media_info.packets_received == nil
      assert media_info.jitter_ms == nil
    end

    test "quality metrics only (codec info unavailable)" do
      media_info = %MediaInfo{
        mos_score: 4.0,
        packets_sent: 1000,
        packets_received: 990,
        jitter_ms: 7.5
      }

      assert media_info.codec == nil
      assert media_info.codec_payload_type == nil
      assert media_info.mos_score == 4.0
      assert media_info.packets_sent == 1000
      assert media_info.packets_received == 990
      assert media_info.jitter_ms == 7.5
    end
  end

  describe "struct behavior" do
    test "can be pattern matched" do
      media_info = %MediaInfo{codec: "PCMU", codec_payload_type: 0}

      assert %MediaInfo{codec: codec} = media_info
      assert codec == "PCMU"
    end

    test "can be updated with struct update syntax" do
      original = %MediaInfo{codec: "PCMU", codec_payload_type: 0}
      updated = %MediaInfo{original | mos_score: 4.2}

      assert updated.codec == "PCMU"
      assert updated.codec_payload_type == 0
      assert updated.mos_score == 4.2
    end

    test "can be compared for equality" do
      media_info1 = %MediaInfo{codec: "PCMU", codec_payload_type: 0}
      media_info2 = %MediaInfo{codec: "PCMU", codec_payload_type: 0}
      media_info3 = %MediaInfo{codec: "PCMA", codec_payload_type: 8}

      assert media_info1 == media_info2
      refute media_info1 == media_info3
    end

    test "can be used in map functions" do
      media_infos = [
        %MediaInfo{codec: "PCMU", mos_score: 4.0},
        %MediaInfo{codec: "PCMA", mos_score: 3.8},
        %MediaInfo{codec: "opus", mos_score: 4.5}
      ]

      codecs = Enum.map(media_infos, & &1.codec)
      assert codecs == ["PCMU", "PCMA", "opus"]
    end

    test "struct has expected keys" do
      media_info = %MediaInfo{}
      keys = Map.keys(media_info) |> Enum.sort()

      expected_keys =
        [
          :__struct__,
          :codec,
          :codec_payload_type,
          :jitter_ms,
          :mos_score,
          :packets_received,
          :packets_sent
        ]
        |> Enum.sort()

      assert keys == expected_keys
    end
  end
end
