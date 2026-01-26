defmodule ParrotSip.CDR.MediaInfoTest do
  use ExUnit.Case, async: true

  alias ParrotSip.CDR.MediaInfo

  # Helper to build a complete MOS summary for tests
  defp build_mos_summary(overrides \\ %{}) do
    defaults = %{
      min_mos: 3.8,
      max_mos: 4.4,
      avg_mos: 4.2,
      total_packets: 1500,
      total_lost: 20,
      overall_loss_percent: 1.33,
      intervals_calculated: 30,
      duration_ms: 60_000,
      status: :complete,
      quality_events: []
    }

    Map.merge(defaults, overrides)
  end

  describe "struct creation" do
    test "creates struct with all fields" do
      mos_summary = build_mos_summary()

      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: mos_summary,
        packets_sent: 1500,
        packets_received: 1480,
        jitter_ms: 5.5
      }

      assert media_info.codec == "PCMU"
      assert media_info.codec_payload_type == 0
      assert media_info.mos_summary == mos_summary
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

  describe "typical media scenarios" do
    test "PCMU call with quality metrics" do
      mos_summary = build_mos_summary(%{avg_mos: 4.2, min_mos: 4.0, max_mos: 4.4})

      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: mos_summary,
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
      mos_summary = build_mos_summary(%{avg_mos: 4.0, min_mos: 3.8, max_mos: 4.2})

      media_info = %MediaInfo{
        codec: "PCMA",
        codec_payload_type: 8,
        mos_summary: mos_summary,
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
      mos_summary = build_mos_summary(%{avg_mos: 4.5, min_mos: 4.3, max_mos: 4.5})

      media_info = %MediaInfo{
        codec: "opus",
        codec_payload_type: 111,
        mos_summary: mos_summary,
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
      mos_summary = build_mos_summary(%{avg_mos: 3.8, min_mos: 3.5, max_mos: 4.0})

      media_info = %MediaInfo{
        codec: "G729",
        codec_payload_type: 18,
        mos_summary: mos_summary,
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

    test "MOS summary with minimum avg score (bad quality)" do
      mos_summary = build_mos_summary(%{avg_mos: 1.0, min_mos: 1.0, max_mos: 1.5})

      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: mos_summary
      }

      assert media_info.mos_summary.avg_mos == 1.0
    end

    test "MOS summary with maximum avg score (perfect quality)" do
      mos_summary = build_mos_summary(%{avg_mos: 5.0, min_mos: 4.8, max_mos: 5.0})

      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: mos_summary
      }

      assert media_info.mos_summary.avg_mos == 5.0
    end

    test "MOS summary with typical poor quality" do
      mos_summary = build_mos_summary(%{avg_mos: 2.5, min_mos: 2.0, max_mos: 3.0})

      media_info = %MediaInfo{
        codec: "G729",
        codec_payload_type: 18,
        mos_summary: mos_summary
      }

      assert media_info.mos_summary.avg_mos == 2.5
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
      mos_summary = build_mos_summary(%{avg_mos: 4.1, duration_ms: 3_600_000})

      media_info = %MediaInfo{
        codec: "opus",
        codec_payload_type: 111,
        packets_sent: 180_000,
        packets_received: 179_500,
        jitter_ms: 10.3,
        mos_summary: mos_summary
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
      assert media_info.mos_summary == nil
      assert media_info.packets_sent == nil
      assert media_info.packets_received == nil
      assert media_info.jitter_ms == nil
    end

    test "quality metrics only (codec info unavailable)" do
      mos_summary = build_mos_summary(%{avg_mos: 4.0})

      media_info = %MediaInfo{
        mos_summary: mos_summary,
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

  describe "mos_summary structure" do
    test "complete MOS summary with all fields" do
      quality_events = [
        %{
          timestamp: ~U[2026-01-20 10:00:30Z],
          mos_value: 3.4,
          threshold_name: :fair,
          direction: :falling
        },
        %{
          timestamp: ~U[2026-01-20 10:01:00Z],
          mos_value: 3.6,
          threshold_name: :fair,
          direction: :rising
        }
      ]

      mos_summary = %{
        min_mos: 3.4,
        max_mos: 4.5,
        avg_mos: 4.1,
        total_packets: 3000,
        total_lost: 50,
        overall_loss_percent: 1.67,
        intervals_calculated: 60,
        duration_ms: 120_000,
        status: :complete,
        quality_events: quality_events
      }

      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: mos_summary
      }

      assert media_info.mos_summary.min_mos == 3.4
      assert media_info.mos_summary.max_mos == 4.5
      assert media_info.mos_summary.avg_mos == 4.1
      assert media_info.mos_summary.total_packets == 3000
      assert media_info.mos_summary.total_lost == 50
      assert media_info.mos_summary.overall_loss_percent == 1.67
      assert media_info.mos_summary.intervals_calculated == 60
      assert media_info.mos_summary.duration_ms == 120_000
      assert media_info.mos_summary.status == :complete
      assert length(media_info.mos_summary.quality_events) == 2
    end

    test "MOS summary with insufficient_data status" do
      mos_summary = %{
        min_mos: 0.0,
        max_mos: 0.0,
        avg_mos: 0.0,
        total_packets: 5,
        total_lost: 0,
        overall_loss_percent: 0.0,
        intervals_calculated: 0,
        duration_ms: 500,
        status: :insufficient_data,
        quality_events: []
      }

      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: mos_summary
      }

      assert media_info.mos_summary.status == :insufficient_data
      assert media_info.mos_summary.intervals_calculated == 0
    end

    test "MOS summary with one_way_audio status" do
      mos_summary = %{
        min_mos: 0.0,
        max_mos: 0.0,
        avg_mos: 0.0,
        total_packets: 0,
        total_lost: 0,
        overall_loss_percent: 0.0,
        intervals_calculated: 0,
        duration_ms: 30_000,
        status: :one_way_audio,
        quality_events: []
      }

      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: mos_summary
      }

      assert media_info.mos_summary.status == :one_way_audio
      assert media_info.mos_summary.total_packets == 0
    end

    test "MOS summary with unavailable status" do
      mos_summary = %{
        min_mos: 0.0,
        max_mos: 0.0,
        avg_mos: 0.0,
        total_packets: 0,
        total_lost: 0,
        overall_loss_percent: 0.0,
        intervals_calculated: 0,
        duration_ms: 0,
        status: :unavailable,
        quality_events: []
      }

      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: mos_summary
      }

      assert media_info.mos_summary.status == :unavailable
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
      mos_summary = build_mos_summary(%{avg_mos: 4.2})
      updated = %MediaInfo{original | mos_summary: mos_summary}

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
        %MediaInfo{codec: "PCMU", mos_summary: build_mos_summary(%{avg_mos: 4.0})},
        %MediaInfo{codec: "PCMA", mos_summary: build_mos_summary(%{avg_mos: 3.8})},
        %MediaInfo{codec: "opus", mos_summary: build_mos_summary(%{avg_mos: 4.5})}
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
