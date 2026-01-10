defmodule ParrotMedia.MOS.IntervalTest do
  use ExUnit.Case, async: true

  alias ParrotMedia.MOS.Interval
  alias ParrotMedia.MOS.Config

  describe "new/0" do
    test "creates new interval with current timestamp" do
      before = DateTime.utc_now()
      interval = Interval.new()
      after_time = DateTime.utc_now()

      assert %Interval{} = interval
      assert DateTime.compare(interval.start_time, before) in [:gt, :eq]
      assert DateTime.compare(interval.start_time, after_time) in [:lt, :eq]
    end

    test "initializes with zero values for counters" do
      interval = Interval.new()

      assert interval.duration_ms == 0
      assert interval.packets_received == 0
      assert interval.packets_expected == 0
      assert interval.packets_lost == 0
      assert interval.packet_loss_percent == 0.0
    end

    test "initializes with empty lists for samples" do
      interval = Interval.new()

      assert interval.jitter_samples == []
      assert interval.delay_samples == []
    end

    test "initializes with zero values for averages" do
      interval = Interval.new()

      assert interval.jitter_ms == 0.0
      assert interval.delay_ms == 0.0
    end

    test "has nil end_time initially" do
      interval = Interval.new()

      assert interval.end_time == nil
    end
  end

  describe "new/1" do
    test "creates interval with provided start time" do
      start_time = ~U[2026-01-10 12:00:00Z]
      interval = Interval.new(start_time)

      assert interval.start_time == start_time
    end

    test "allows custom start time for testing" do
      custom_time = DateTime.add(DateTime.utc_now(), -60, :second)
      interval = Interval.new(custom_time)

      assert interval.start_time == custom_time
    end
  end

  describe "add_metrics/2" do
    test "adds single metrics sample to interval" do
      interval = Interval.new()

      metrics = %{
        packets_received: 50,
        packets_expected: 50,
        jitter_ms: 12.5,
        delay_ms: 45.0
      }

      updated = Interval.add_metrics(interval, metrics)

      assert updated.packets_received == 50
      assert updated.packets_expected == 50
      assert updated.jitter_samples == [12.5]
      assert updated.delay_samples == [45.0]
    end

    test "accumulates multiple metrics samples" do
      interval = Interval.new()

      metrics1 = %{packets_received: 50, packets_expected: 50, jitter_ms: 10.0, delay_ms: 40.0}
      metrics2 = %{packets_received: 48, packets_expected: 50, jitter_ms: 15.0, delay_ms: 50.0}
      metrics3 = %{packets_received: 49, packets_expected: 50, jitter_ms: 12.0, delay_ms: 45.0}

      updated =
        interval
        |> Interval.add_metrics(metrics1)
        |> Interval.add_metrics(metrics2)
        |> Interval.add_metrics(metrics3)

      assert updated.packets_received == 50 + 48 + 49
      assert updated.packets_expected == 50 + 50 + 50
      # Samples are prepended for O(1) performance, so newest is first
      assert updated.jitter_samples == [12.0, 15.0, 10.0]
      assert updated.delay_samples == [45.0, 50.0, 40.0]
    end

    test "handles zero packets in sample" do
      interval = Interval.new()

      metrics = %{packets_received: 0, packets_expected: 0, jitter_ms: 0.0, delay_ms: 0.0}
      updated = Interval.add_metrics(interval, metrics)

      assert updated.packets_received == 0
      assert updated.packets_expected == 0
    end

    test "handles partial metrics - only packet counts" do
      interval = Interval.new()

      metrics = %{packets_received: 50, packets_expected: 50}
      updated = Interval.add_metrics(interval, metrics)

      assert updated.packets_received == 50
      assert updated.packets_expected == 50
      # No jitter/delay samples added
      assert updated.jitter_samples == []
      assert updated.delay_samples == []
    end

    test "handles partial metrics - only jitter" do
      interval = Interval.new()

      metrics = %{jitter_ms: 15.0}
      updated = Interval.add_metrics(interval, metrics)

      assert updated.jitter_samples == [15.0]
      assert updated.delay_samples == []
      assert updated.packets_received == 0
    end

    test "handles partial metrics - only delay" do
      interval = Interval.new()

      metrics = %{delay_ms: 50.0}
      updated = Interval.add_metrics(interval, metrics)

      assert updated.delay_samples == [50.0]
      assert updated.jitter_samples == []
    end

    test "preserves existing data when adding new metrics" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 100,
        packets_expected: 100,
        jitter_samples: [10.0],
        delay_samples: [40.0]
      }

      metrics = %{packets_received: 50, packets_expected: 50, jitter_ms: 20.0, delay_ms: 60.0}
      updated = Interval.add_metrics(interval, metrics)

      assert updated.packets_received == 150
      assert updated.packets_expected == 150
      # New sample is prepended to existing samples for O(1) performance
      assert updated.jitter_samples == [20.0, 10.0]
      assert updated.delay_samples == [60.0, 40.0]
    end
  end

  describe "complete/1" do
    test "sets end_time to current time" do
      start = DateTime.add(DateTime.utc_now(), -5, :second)
      interval = %Interval{start_time: start, packets_received: 100, packets_expected: 100}

      before = DateTime.utc_now()
      completed = Interval.complete(interval)
      after_time = DateTime.utc_now()

      assert %DateTime{} = completed.end_time
      assert DateTime.compare(completed.end_time, before) in [:gt, :eq]
      assert DateTime.compare(completed.end_time, after_time) in [:lt, :eq]
    end

    test "calculates duration_ms from start to end time" do
      start = DateTime.add(DateTime.utc_now(), -5, :second)
      interval = %Interval{start_time: start, packets_received: 100, packets_expected: 100}

      completed = Interval.complete(interval)

      # Duration should be approximately 5 seconds (5000ms) give or take
      assert completed.duration_ms >= 4900
      assert completed.duration_ms <= 5200
    end

    test "calculates packets_lost from expected minus received" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 95,
        packets_expected: 100
      }

      completed = Interval.complete(interval)

      assert completed.packets_lost == 5
    end

    test "calculates packet_loss_percent correctly" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 90,
        packets_expected: 100
      }

      completed = Interval.complete(interval)

      assert completed.packet_loss_percent == 10.0
    end

    test "calculates average jitter from samples" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 100,
        packets_expected: 100,
        jitter_samples: [10.0, 20.0, 30.0]
      }

      completed = Interval.complete(interval)

      assert completed.jitter_ms == 20.0
    end

    test "calculates average delay from samples" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 100,
        packets_expected: 100,
        delay_samples: [40.0, 50.0, 60.0]
      }

      completed = Interval.complete(interval)

      assert completed.delay_ms == 50.0
    end

    test "handles empty jitter samples - returns 0.0" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 100,
        packets_expected: 100,
        jitter_samples: []
      }

      completed = Interval.complete(interval)

      assert completed.jitter_ms == 0.0
    end

    test "handles empty delay samples - returns 0.0" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 100,
        packets_expected: 100,
        delay_samples: []
      }

      completed = Interval.complete(interval)

      assert completed.delay_ms == 0.0
    end

    test "allows custom end_time for testing" do
      start = ~U[2026-01-10 12:00:00Z]
      end_time = ~U[2026-01-10 12:00:05Z]

      interval = %Interval{
        start_time: start,
        packets_received: 100,
        packets_expected: 100
      }

      completed = Interval.complete(interval, end_time)

      assert completed.end_time == end_time
      assert completed.duration_ms == 5000
    end
  end

  describe "packet_loss_percent/1" do
    test "returns 0.0 when no packets lost" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 100,
        packets_expected: 100
      }

      assert Interval.packet_loss_percent(interval) == 0.0
    end

    test "returns correct percentage for partial loss" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 95,
        packets_expected: 100
      }

      assert Interval.packet_loss_percent(interval) == 5.0
    end

    test "returns 100.0 when all packets lost" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 0,
        packets_expected: 100
      }

      assert Interval.packet_loss_percent(interval) == 100.0
    end

    test "returns 0.0 when no packets expected (prevents division by zero)" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 0,
        packets_expected: 0
      }

      assert Interval.packet_loss_percent(interval) == 0.0
    end

    test "handles floating point precision correctly" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 97,
        packets_expected: 100
      }

      assert Interval.packet_loss_percent(interval) == 3.0
    end

    test "calculates correct percentage for high packet counts" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 9500,
        packets_expected: 10000
      }

      assert Interval.packet_loss_percent(interval) == 5.0
    end
  end

  describe "average_jitter/1" do
    test "returns 0.0 for empty samples" do
      interval = %Interval{start_time: DateTime.utc_now(), jitter_samples: []}

      assert Interval.average_jitter(interval) == 0.0
    end

    test "returns single sample value" do
      interval = %Interval{start_time: DateTime.utc_now(), jitter_samples: [15.0]}

      assert Interval.average_jitter(interval) == 15.0
    end

    test "calculates average of multiple samples" do
      interval = %Interval{start_time: DateTime.utc_now(), jitter_samples: [10.0, 20.0, 30.0]}

      assert Interval.average_jitter(interval) == 20.0
    end

    test "handles odd number of samples" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        jitter_samples: [5.0, 10.0, 15.0, 20.0, 25.0]
      }

      assert Interval.average_jitter(interval) == 15.0
    end

    test "handles fractional averages" do
      interval = %Interval{start_time: DateTime.utc_now(), jitter_samples: [10.0, 15.0]}

      assert Interval.average_jitter(interval) == 12.5
    end
  end

  describe "average_delay/1" do
    test "returns 0.0 for empty samples" do
      interval = %Interval{start_time: DateTime.utc_now(), delay_samples: []}

      assert Interval.average_delay(interval) == 0.0
    end

    test "returns single sample value" do
      interval = %Interval{start_time: DateTime.utc_now(), delay_samples: [50.0]}

      assert Interval.average_delay(interval) == 50.0
    end

    test "calculates average of multiple samples" do
      interval = %Interval{start_time: DateTime.utc_now(), delay_samples: [40.0, 50.0, 60.0]}

      assert Interval.average_delay(interval) == 50.0
    end

    test "handles fractional averages" do
      interval = %Interval{start_time: DateTime.utc_now(), delay_samples: [45.0, 55.0]}

      assert Interval.average_delay(interval) == 50.0
    end
  end

  describe "sufficient_data?/1" do
    test "returns true when packets_received >= min_packets_per_interval" do
      # Default min_packets_per_interval is 10
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 10,
        packets_expected: 10
      }

      assert Interval.sufficient_data?(interval) == true
    end

    test "returns false when packets_received < min_packets_per_interval" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 9,
        packets_expected: 10
      }

      assert Interval.sufficient_data?(interval) == false
    end

    test "returns true when packets_received well above threshold" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 100,
        packets_expected: 100
      }

      assert Interval.sufficient_data?(interval) == true
    end

    test "returns false when no packets received" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 0,
        packets_expected: 100
      }

      assert Interval.sufficient_data?(interval) == false
    end

    test "accepts custom min_packets threshold" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 15,
        packets_expected: 20
      }

      # With higher threshold
      assert Interval.sufficient_data?(interval, min_packets: 20) == false
      # With lower threshold
      assert Interval.sufficient_data?(interval, min_packets: 15) == true
    end

    test "uses config default when no threshold provided" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: Config.get(:min_packets_per_interval),
        packets_expected: 100
      }

      assert Interval.sufficient_data?(interval) == true
    end
  end

  describe "edge cases" do
    test "empty interval - no metrics added" do
      interval = Interval.new()
      completed = Interval.complete(interval)

      assert completed.packets_received == 0
      assert completed.packets_expected == 0
      assert completed.packets_lost == 0
      assert completed.packet_loss_percent == 0.0
      assert completed.jitter_ms == 0.0
      assert completed.delay_ms == 0.0
    end

    test "all packets lost scenario" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 0,
        packets_expected: 100,
        jitter_samples: [],
        delay_samples: []
      }

      completed = Interval.complete(interval)

      assert completed.packets_lost == 100
      assert completed.packet_loss_percent == 100.0
    end

    test "very high jitter values" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 100,
        packets_expected: 100,
        jitter_samples: [100.0, 200.0, 300.0]
      }

      completed = Interval.complete(interval)

      assert completed.jitter_ms == 200.0
    end

    test "very high delay values" do
      interval = %Interval{
        start_time: DateTime.utc_now(),
        packets_received: 100,
        packets_expected: 100,
        delay_samples: [500.0, 600.0, 700.0]
      }

      completed = Interval.complete(interval)

      assert completed.delay_ms == 600.0
    end

    test "handles single packet" do
      interval = Interval.new()

      metrics = %{packets_received: 1, packets_expected: 1, jitter_ms: 5.0, delay_ms: 30.0}
      updated = Interval.add_metrics(interval, metrics)
      completed = Interval.complete(updated)

      assert completed.packets_received == 1
      assert completed.packets_expected == 1
      assert completed.packet_loss_percent == 0.0
      assert completed.jitter_ms == 5.0
      assert completed.delay_ms == 30.0
    end

    test "handles typical VoIP interval - 5 seconds at 20ms ptime (250 packets)" do
      interval = Interval.new()

      # Simulate receiving 250 packets with varying jitter and delay
      metrics = %{
        packets_received: 248,
        packets_expected: 250,
        jitter_ms: 8.5,
        delay_ms: 45.0
      }

      updated = Interval.add_metrics(interval, metrics)
      completed = Interval.complete(updated)

      assert completed.packets_received == 248
      assert completed.packets_expected == 250
      assert completed.packets_lost == 2
      # 2/250 = 0.8%
      assert_in_delta completed.packet_loss_percent, 0.8, 0.01
      assert completed.jitter_ms == 8.5
      assert completed.delay_ms == 45.0
    end
  end

  describe "struct definition" do
    test "Interval struct exists with expected fields" do
      interval = %Interval{start_time: DateTime.utc_now()}

      assert Map.has_key?(interval, :start_time)
      assert Map.has_key?(interval, :end_time)
      assert Map.has_key?(interval, :duration_ms)
      assert Map.has_key?(interval, :packets_received)
      assert Map.has_key?(interval, :packets_expected)
      assert Map.has_key?(interval, :packets_lost)
      assert Map.has_key?(interval, :packet_loss_percent)
      assert Map.has_key?(interval, :jitter_samples)
      assert Map.has_key?(interval, :jitter_ms)
      assert Map.has_key?(interval, :delay_samples)
      assert Map.has_key?(interval, :delay_ms)
    end

    test "Interval struct enforces start_time as required key" do
      assert_raise ArgumentError, fn ->
        struct!(Interval, %{})
      end
    end

    test "Interval struct has correct default values" do
      interval = %Interval{start_time: DateTime.utc_now()}

      assert interval.end_time == nil
      assert interval.duration_ms == 0
      assert interval.packets_received == 0
      assert interval.packets_expected == 0
      assert interval.packets_lost == 0
      assert interval.packet_loss_percent == 0.0
      assert interval.jitter_samples == []
      assert interval.jitter_ms == 0.0
      assert interval.delay_samples == []
      assert interval.delay_ms == 0.0
    end
  end
end
