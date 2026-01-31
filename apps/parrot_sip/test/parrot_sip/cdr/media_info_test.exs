defmodule ParrotSip.CDR.MediaInfoTest do
  use ExUnit.Case, async: true

  alias ParrotSip.CDR.MediaInfo

  # Helper to create a standard mos_summary for tests
  defp sample_mos_summary(opts \\ []) do
    %{
      min_mos: Keyword.get(opts, :min_mos, 3.8),
      max_mos: Keyword.get(opts, :max_mos, 4.4),
      avg_mos: Keyword.get(opts, :avg_mos, 4.2),
      total_packets: Keyword.get(opts, :total_packets, 1500),
      total_lost: Keyword.get(opts, :total_lost, 20),
      overall_loss_percent: Keyword.get(opts, :overall_loss_percent, 1.3),
      status: Keyword.get(opts, :status, :good),
      quality_events: Keyword.get(opts, :quality_events, [])
    }
  end

  describe "struct creation" do
    test "creates struct with all fields" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: sample_mos_summary(),
        packets_sent: 1500,
        packets_received: 1480,
        jitter_ms: 5.5
      }

      assert media_info.codec == "PCMU"
      assert media_info.codec_payload_type == 0
      assert media_info.mos_summary.avg_mos == 4.2
      assert media_info.packets_sent == 1500
      assert media_info.packets_received == 1480
      assert media_info.jitter_ms == 5.5
    end

    test "all fields default to nil" do
      media_info = %MediaInfo{}

      assert media_info.codec == nil
      assert media_info.codec_payload_type == nil
      assert media_info.mos_summary == nil
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
      assert media_info.mos_summary == nil
      assert media_info.packets_sent == nil
      assert media_info.packets_received == nil
      assert media_info.jitter_ms == nil
    end
  end

  describe "mos_summary field" do
    test "accepts full MOS summary map" do
      mos_summary = %{
        min_mos: 3.5,
        max_mos: 4.8,
        avg_mos: 4.1,
        total_packets: 5000,
        total_lost: 25,
        overall_loss_percent: 0.5,
        status: :excellent,
        quality_events: [
          %{
            timestamp: DateTime.utc_now(),
            mos: 3.5,
            type: :degradation,
            jitter: 25.0,
            loss_percent: 2.0
          }
        ]
      }

      media_info = %MediaInfo{
        codec: "PCMU",
        mos_summary: mos_summary
      }

      assert media_info.mos_summary.min_mos == 3.5
      assert media_info.mos_summary.max_mos == 4.8
      assert media_info.mos_summary.avg_mos == 4.1
      assert media_info.mos_summary.status == :excellent
      assert length(media_info.mos_summary.quality_events) == 1
    end

    test "handles nil mos_summary gracefully" do
      media_info = %MediaInfo{
        codec: "PCMU",
        mos_summary: nil
      }

      assert media_info.mos_summary == nil
    end

    test "supports different quality statuses" do
      for status <- [:excellent, :good, :fair, :poor, :bad] do
        media_info = %MediaInfo{
          codec: "PCMU",
          mos_summary: sample_mos_summary(status: status)
        }

        assert media_info.mos_summary.status == status
      end
    end
  end

  describe "typical media scenarios" do
    test "PCMU call with quality metrics" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: sample_mos_summary(avg_mos: 4.2),
        packets_sent: 1500,
        packets_received: 1480,
        jitter_ms: 5.5
      }

      assert media_info.codec == "PCMU"
      assert media_info.codec_payload_type == 0
      assert media_info.mos_summary.avg_mos == 4.2
      assert media_info.packets_sent == 1500
      assert media_info.packets_received == 1480
      assert media_info.jitter_ms == 5.5
    end

    test "PCMA (G.711 A-law) call" do
      media_info = %MediaInfo{
        codec: "PCMA",
        codec_payload_type: 8,
        mos_summary: sample_mos_summary(avg_mos: 4.0, min_mos: 3.6, max_mos: 4.3),
        packets_sent: 3000,
        packets_received: 2985,
        jitter_ms: 8.2
      }

      assert media_info.codec == "PCMA"
      assert media_info.codec_payload_type == 8
      assert media_info.mos_summary.avg_mos == 4.0
      assert media_info.packets_sent == 3000
      assert media_info.packets_received == 2985
      assert media_info.jitter_ms == 8.2
    end

    test "Opus codec call with dynamic payload type" do
      media_info = %MediaInfo{
        codec: "opus",
        codec_payload_type: 111,
        mos_summary: sample_mos_summary(avg_mos: 4.5, status: :excellent),
        packets_sent: 2500,
        packets_received: 2490,
        jitter_ms: 3.2
      }

      assert media_info.codec == "opus"
      assert media_info.codec_payload_type == 111
      assert media_info.mos_summary.avg_mos == 4.5
      assert media_info.packets_sent == 2500
      assert media_info.packets_received == 2490
      assert media_info.jitter_ms == 3.2
    end

    test "G.729 codec call" do
      media_info = %MediaInfo{
        codec: "G729",
        codec_payload_type: 18,
        mos_summary: sample_mos_summary(avg_mos: 3.8, min_mos: 3.2, max_mos: 4.0, status: :fair),
        packets_sent: 6000,
        packets_received: 5950,
        jitter_ms: 12.5
      }

      assert media_info.codec == "G729"
      assert media_info.codec_payload_type == 18
      assert media_info.mos_summary.avg_mos == 3.8
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
      assert media_info.mos_summary == nil
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

    test "MOS at minimum (bad quality)" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: sample_mos_summary(avg_mos: 1.0, min_mos: 1.0, max_mos: 1.5, status: :bad)
      }

      assert media_info.mos_summary.avg_mos == 1.0
      assert media_info.mos_summary.status == :bad
    end

    test "MOS at maximum (perfect quality)" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary:
          sample_mos_summary(avg_mos: 5.0, min_mos: 4.8, max_mos: 5.0, status: :excellent)
      }

      assert media_info.mos_summary.avg_mos == 5.0
      assert media_info.mos_summary.status == :excellent
    end

    test "MOS typical poor quality" do
      media_info = %MediaInfo{
        codec: "G729",
        codec_payload_type: 18,
        mos_summary: sample_mos_summary(avg_mos: 2.5, min_mos: 2.0, max_mos: 3.0, status: :poor)
      }

      assert media_info.mos_summary.avg_mos == 2.5
      assert media_info.mos_summary.status == :poor
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
        mos_summary: sample_mos_summary(avg_mos: 4.1, total_packets: 180_000, total_lost: 500)
      }

      assert media_info.packets_sent == 180_000
      assert media_info.packets_received == 179_500
      assert media_info.mos_summary.total_packets == 180_000
    end

    test "codec only (no quality metrics available)" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0
      }

      assert media_info.codec == "PCMU"
      assert media_info.codec_payload_type == 0
      assert media_info.mos_summary == nil
      assert media_info.packets_sent == nil
      assert media_info.packets_received == nil
      assert media_info.jitter_ms == nil
    end

    test "quality metrics only (codec info unavailable)" do
      media_info = %MediaInfo{
        mos_summary: sample_mos_summary(avg_mos: 4.0),
        packets_sent: 1000,
        packets_received: 990,
        jitter_ms: 7.5
      }

      assert media_info.codec == nil
      assert media_info.codec_payload_type == nil
      assert media_info.mos_summary.avg_mos == 4.0
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
      updated = %MediaInfo{original | mos_summary: sample_mos_summary(avg_mos: 4.2)}

      assert updated.codec == "PCMU"
      assert updated.codec_payload_type == 0
      assert updated.mos_summary.avg_mos == 4.2
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
        %MediaInfo{codec: "PCMU", mos_summary: sample_mos_summary(avg_mos: 4.0)},
        %MediaInfo{codec: "PCMA", mos_summary: sample_mos_summary(avg_mos: 3.8)},
        %MediaInfo{codec: "opus", mos_summary: sample_mos_summary(avg_mos: 4.5)}
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
          :mos_summary,
          :packets_received,
          :packets_sent
        ]
        |> Enum.sort()

      assert keys == expected_keys
    end
  end
end
