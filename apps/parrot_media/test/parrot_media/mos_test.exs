defmodule ParrotMedia.MOSTest do
  @moduledoc """
  Tests for the public ParrotMedia.MOS API.

  The MOS module provides the main entry points for:
  - Querying current scores and call summaries
  - Registering handlers
  - Checking configuration
  """
  use ExUnit.Case, async: false

  alias ParrotMedia.MOS
  alias ParrotMedia.MOS.Calculator
  alias ParrotMedia.MOS.Config
  alias ParrotMedia.MOS.Score

  # ===========================================================================
  # Setup
  # ===========================================================================

  setup do
    session_id = "mos-api-test-#{:erlang.unique_integer([:positive])}"

    # Store original config
    original_config = Application.get_env(:parrot_media, :mos)

    # Enable MOS for tests
    Application.put_env(:parrot_media, :mos, %{
      enabled: true,
      interval_ms: 50,
      min_packets_per_interval: 1,
      default_delay_ms: 50.0,
      thresholds: [
        %{name: :excellent, value: 4.0, hysteresis: 0.1},
        %{name: :good, value: 3.5, hysteresis: 0.1}
      ]
    })

    on_exit(fn ->
      # Restore original config
      if original_config do
        Application.put_env(:parrot_media, :mos, original_config)
      else
        Application.delete_env(:parrot_media, :mos)
      end

      # Clean up any remaining calculators
      case Registry.lookup(ParrotMedia.MOS.Registry, session_id) do
        [{pid, _}] when is_pid(pid) ->
          if Process.alive?(pid), do: Calculator.stop(pid)

        _ ->
          :ok
      end
    end)

    {:ok, session_id: session_id}
  end

  # ===========================================================================
  # enabled?/0 Tests
  # ===========================================================================

  describe "enabled?/0" do
    test "returns true when MOS is enabled" do
      Application.put_env(:parrot_media, :mos, %{enabled: true})
      assert MOS.enabled?() == true
    end

    test "returns false when MOS is disabled" do
      Application.put_env(:parrot_media, :mos, %{enabled: false})
      assert MOS.enabled?() == false
    end

    test "returns true by default when config is missing" do
      Application.delete_env(:parrot_media, :mos)
      assert MOS.enabled?() == true
    end
  end

  # ===========================================================================
  # current_score/1 Tests
  # ===========================================================================

  describe "current_score/1" do
    test "returns {:ok, score} when score exists", ctx do
      # Start a calculator and add metrics
      {:ok, _pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
        )

      # Add good quality metrics
      for _ <- 1..5 do
        Calculator.add_metrics(via(ctx.session_id), %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      # Wait for interval
      Process.sleep(100)

      # Get current score via public API
      assert {:ok, %Score{} = score} = MOS.current_score(ctx.session_id)
      assert score.value >= 4.0
    end

    test "returns {:error, :not_found} when no calculator exists" do
      assert {:error, :not_found} = MOS.current_score("nonexistent-session")
    end

    test "returns {:ok, nil} when no scores calculated yet", ctx do
      # Start a calculator but don't add metrics
      {:ok, _pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 10_000, min_packets_per_interval: 100)
        )

      # Query immediately before any interval completes
      assert {:ok, nil} = MOS.current_score(ctx.session_id)
    end
  end

  # ===========================================================================
  # call_summary/1 Tests
  # ===========================================================================

  describe "call_summary/1" do
    test "returns {:ok, summary} with call data", ctx do
      # Start a calculator and add metrics
      {:ok, _pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
        )

      # Add good quality metrics
      for _ <- 1..10 do
        Calculator.add_metrics(via(ctx.session_id), %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      # Wait for interval
      Process.sleep(100)

      # Get call summary via public API
      assert {:ok, summary} = MOS.call_summary(ctx.session_id)
      assert summary.session_id == ctx.session_id
      assert summary.intervals_calculated >= 1
      assert summary.avg_mos >= 4.0
    end

    test "returns {:error, :not_found} when no calculator exists" do
      assert {:error, :not_found} = MOS.call_summary("nonexistent-session")
    end

    test "returns summary with insufficient_data when no intervals", ctx do
      # Start a calculator but don't wait for interval
      {:ok, _pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 10_000, min_packets_per_interval: 100)
        )

      assert {:ok, summary} = MOS.call_summary(ctx.session_id)
      assert summary.status == :insufficient_data
      assert summary.intervals_calculated == 0
    end
  end

  # ===========================================================================
  # register_handler/2 Tests
  # ===========================================================================

  describe "register_handler/2 with pid" do
    test "registers current process to receive messages", ctx do
      # Start a calculator
      {:ok, _pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
        )

      # Register this process as handler
      assert :ok = MOS.register_handler(ctx.session_id, self())

      # Add metrics to trigger score calculation
      for _ <- 1..5 do
        Calculator.add_metrics(via(ctx.session_id), %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      # Wait for interval
      Process.sleep(100)

      # Should receive MOS score message
      assert_receive {:mos_score, %{session_id: session_id, score: %Score{}}}, 200
      assert session_id == ctx.session_id
    end

    test "returns {:error, :not_found} when no calculator exists" do
      assert {:error, :not_found} = MOS.register_handler("nonexistent-session", self())
    end
  end

  describe "register_handler/2 with handler module" do
    defmodule TestHandler do
      @behaviour ParrotMedia.MOS.Handler

      @impl true
      def init(opts) do
        # Send message to test process when initialized
        if pid = opts[:test_pid] do
          send(pid, {:handler_init, opts})
        end

        {:ok, opts}
      end

      @impl true
      def handle_mos_score(session_id, score, state) do
        if pid = state[:test_pid] do
          send(pid, {:handler_score, session_id, score})
        end

        {:ok, state}
      end

      @impl true
      def handle_threshold_crossed(session_id, event, state) do
        if pid = state[:test_pid] do
          send(pid, {:handler_threshold, session_id, event})
        end

        {:ok, state}
      end

      @impl true
      def handle_call_summary(session_id, summary, state) do
        if pid = state[:test_pid] do
          send(pid, {:handler_summary, session_id, summary})
        end

        {:ok, state}
      end
    end

    test "registers handler module with opts", ctx do
      # Start a calculator
      {:ok, _pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
        )

      # Register handler module
      assert :ok = MOS.register_handler(ctx.session_id, {TestHandler, %{test_pid: self()}})

      # Should receive init confirmation
      assert_receive {:handler_init, %{test_pid: _}}, 200

      # Add metrics
      for _ <- 1..5 do
        Calculator.add_metrics(via(ctx.session_id), %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      # Wait for interval
      Process.sleep(100)

      # Should receive score through handler
      assert_receive {:handler_score, session_id, %Score{}}, 200
      assert session_id == ctx.session_id
    end
  end

  # ===========================================================================
  # config/0 Tests
  # ===========================================================================

  describe "config/0" do
    test "returns current MOS configuration" do
      Application.put_env(:parrot_media, :mos, %{
        enabled: true,
        interval_ms: 3000,
        min_packets_per_interval: 5
      })

      config = MOS.config()

      assert config[:enabled] == true
      assert config[:interval_ms] == 3000
      assert config[:min_packets_per_interval] == 5
    end

    test "returns defaults when no config set" do
      Application.delete_env(:parrot_media, :mos)

      config = MOS.config()

      assert config[:enabled] == true
      assert config[:interval_ms] == 5_000
      assert config[:min_packets_per_interval] == 10
    end
  end

  # ===========================================================================
  # config/1 Tests
  # ===========================================================================

  describe "config/1" do
    test "returns specific config key" do
      Application.put_env(:parrot_media, :mos, %{
        enabled: true,
        interval_ms: 7000
      })

      assert MOS.config(:interval_ms) == 7000
      assert MOS.config(:enabled) == true
    end

    test "returns nil for unknown key" do
      Application.put_env(:parrot_media, :mos, %{enabled: true})

      assert MOS.config(:unknown_key) == nil
    end
  end

  # ===========================================================================
  # thresholds/0 Tests
  # ===========================================================================

  describe "thresholds/0" do
    test "returns configured thresholds as Threshold structs" do
      Application.put_env(:parrot_media, :mos, %{
        enabled: true,
        thresholds: [
          %{name: :excellent, value: 4.0, hysteresis: 0.1},
          %{name: :good, value: 3.5, hysteresis: 0.1}
        ]
      })

      thresholds = MOS.thresholds()

      assert length(thresholds) == 2
      assert Enum.all?(thresholds, &match?(%ParrotMedia.MOS.Threshold{}, &1))
    end

    test "returns empty list when no thresholds configured" do
      Application.put_env(:parrot_media, :mos, %{enabled: true, thresholds: []})

      assert MOS.thresholds() == []
    end
  end

  # ===========================================================================
  # Helper Functions
  # ===========================================================================

  defp via(session_id) do
    {:via, Registry, {ParrotMedia.MOS.Registry, session_id}}
  end
end
