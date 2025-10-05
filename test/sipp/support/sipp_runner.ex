defmodule SippTest.SippRunner do
  @moduledoc """
  Helper module for running SIPp scenarios from ExUnit tests.

  This module provides a clean interface for executing SIPp with various
  configurations and automatically handles common test scenarios.

  ## Usage

      # Basic scenario execution
      :ok = SippRunner.run_scenario(
        scenario_file: "test/sipp/scenarios/basic/uac_invite.xml",
        remote_host: "127.0.0.1",
        remote_port: 5060,
        calls: 1
      )

      # With custom options
      :ok = SippRunner.run_scenario(
        scenario_file: "test/sipp/scenarios/stress/load_test.xml",
        remote_host: "127.0.0.1",
        remote_port: 5060,
        calls: 1000,
        rate: 10,
        timeout: 30_000,
        trace_screen: true
      )

      # TLS scenario
      :ok = SippRunner.run_scenario(
        scenario_file: "test/sipp/scenarios/tls/tls_invite.xml",
        remote_host: "127.0.0.1",
        remote_port: 5061,
        transport: :tls,
        tls_cert: "test/sipp/fixtures/certs/client-cert.pem",
        tls_key: "test/sipp/fixtures/certs/client-key.pem"
      )
  """

  require Logger

  @type transport :: :udp | :tcp | :tls | :websocket

  @type run_opts :: [
          scenario_file: String.t(),
          remote_host: String.t(),
          remote_port: integer(),
          local_port: integer() | nil,
          calls: integer(),
          rate: integer() | nil,
          timeout: integer(),
          transport: transport(),
          trace_screen: boolean(),
          trace_msg: boolean(),
          trace_err: boolean(),
          pcap_file: String.t() | nil,
          stats_file: String.t() | nil,
          error_file: String.t() | nil,
          screen_file: String.t() | nil,
          tls_cert: String.t() | nil,
          tls_key: String.t() | nil,
          additional_args: [String.t()]
        ]

  @default_timeout 10_000
  @default_calls 1

  @doc """
  Runs a SIPp scenario with the given options.

  ## Options

    * `:scenario_file` - Path to SIPp XML scenario file (required)
    * `:remote_host` - Remote host to send SIP messages to (required)
    * `:remote_port` - Remote port (required)
    * `:local_port` - Local port to bind to (optional, defaults to random)
    * `:calls` - Number of calls to make (default: 1)
    * `:rate` - Call rate in calls per second (optional)
    * `:timeout` - Test timeout in milliseconds (default: 10000)
    * `:transport` - Transport protocol: :udp, :tcp, :tls, :websocket (default: :udp)
    * `:trace_screen` - Enable screen tracing (default: false)
    * `:trace_msg` - Enable message tracing (default: false)
    * `:trace_err` - Enable error tracing (default: false)
    * `:pcap_file` - Path to save PCAP file (optional)
    * `:stats_file` - Path to save statistics file (optional)
    * `:error_file` - Path to save error file (optional)
    * `:screen_file` - Path to save screen output (optional)
    * `:tls_cert` - Path to TLS certificate file (required for TLS)
    * `:tls_key` - Path to TLS private key file (required for TLS)
    * `:additional_args` - Additional SIPp command line arguments (optional)

  ## Returns

    * `:ok` - Scenario completed successfully
    * `{:error, :not_installed}` - SIPp not found in PATH
    * `{:error, {:sipp_failed, status, output}}` - SIPp execution failed

  ## Examples

      # Simple UDP scenario
      :ok = run_scenario(
        scenario_file: "scenarios/basic/uac_invite.xml",
        remote_host: "127.0.0.1",
        remote_port: 5060
      )

      # TCP scenario with tracing
      :ok = run_scenario(
        scenario_file: "scenarios/tcp/tcp_invite.xml",
        remote_host: "127.0.0.1",
        remote_port: 5060,
        transport: :tcp,
        trace_msg: true,
        trace_err: true
      )

      # Load test with rate limiting
      :ok = run_scenario(
        scenario_file: "scenarios/stress/load_test.xml",
        remote_host: "127.0.0.1",
        remote_port: 5060,
        calls: 1000,
        rate: 50,
        timeout: 30_000
      )
  """
  @spec run_scenario(run_opts()) :: :ok | {:error, term()}
  def run_scenario(opts) do
    scenario_file = Keyword.fetch!(opts, :scenario_file)
    remote_host = Keyword.fetch!(opts, :remote_host)
    remote_port = Keyword.fetch!(opts, :remote_port)

    local_port = Keyword.get(opts, :local_port)
    calls = Keyword.get(opts, :calls, @default_calls)
    rate = Keyword.get(opts, :rate)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    transport = Keyword.get(opts, :transport, :udp)
    trace_screen = Keyword.get(opts, :trace_screen, false)
    trace_msg = Keyword.get(opts, :trace_msg, false)
    trace_err = Keyword.get(opts, :trace_err, false)
    pcap_file = Keyword.get(opts, :pcap_file)
    stats_file = Keyword.get(opts, :stats_file)
    error_file = Keyword.get(opts, :error_file)
    screen_file = Keyword.get(opts, :screen_file)
    tls_cert = Keyword.get(opts, :tls_cert)
    tls_key = Keyword.get(opts, :tls_key)
    additional_args = Keyword.get(opts, :additional_args, [])

    case System.find_executable("sipp") do
      nil ->
        {:error, :not_installed}

      sipp_path ->
        run_sipp(
          sipp_path,
          scenario_file,
          remote_host,
          remote_port,
          local_port,
          calls,
          rate,
          timeout,
          transport,
          trace_screen,
          trace_msg,
          trace_err,
          pcap_file,
          stats_file,
          error_file,
          screen_file,
          tls_cert,
          tls_key,
          additional_args
        )
    end
  end

  @doc """
  Checks if SIPp is installed and available in PATH.

  ## Returns

    * `{:ok, path}` - SIPp found at path
    * `:error` - SIPp not found
  """
  @spec check_installation() :: {:ok, String.t()} | :error
  def check_installation do
    case System.find_executable("sipp") do
      nil -> :error
      path -> {:ok, path}
    end
  end

  @doc """
  Gets SIPp version information.

  ## Returns

    * `{:ok, version}` - Version string
    * `{:error, reason}` - Failed to get version
  """
  @spec get_version() :: {:ok, String.t()} | {:error, term()}
  def get_version do
    case System.find_executable("sipp") do
      nil ->
        {:error, :not_installed}

      sipp_path ->
        case System.cmd(sipp_path, ["-v"], stderr_to_stdout: true) do
          {output, 0} ->
            version =
              output
              |> String.split("\n")
              |> Enum.find(&String.contains?(&1, "SIPp"))
              |> case do
                nil -> "unknown"
                line -> String.trim(line)
              end

            {:ok, version}

          {_output, status} ->
            {:error, {:version_check_failed, status}}
        end
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp run_sipp(
         sipp_path,
         scenario_file,
         remote_host,
         remote_port,
         local_port,
         calls,
         rate,
         timeout,
         transport,
         trace_screen,
         trace_msg,
         trace_err,
         pcap_file,
         stats_file,
         error_file,
         screen_file,
         tls_cert,
         tls_key,
         additional_args
       ) do
    # Build SIPp command arguments
    args = [
      # Scenario file
      "-sf",
      scenario_file,
      # Remote target
      remote_host <> ":" <> to_string(remote_port),
      # Number of calls
      "-m",
      to_string(calls),
      # Exit on call failure
      "-fd",
      "1"
    ]

    # Add local port if specified
    args =
      if local_port do
        args ++ ["-p", to_string(local_port)]
      else
        args
      end

    # Add call rate if specified
    args =
      if rate do
        args ++ ["-r", to_string(rate), "-rp", "1000"]
      else
        args
      end

    # Add transport
    args =
      case transport do
        :tcp -> args ++ ["-t", "t1"]
        :tls -> args ++ ["-t", "l1"]
        :websocket -> args ++ ["-t", "c1"]
        :udp -> args ++ ["-t", "u1"]
      end

    # Add SiPP timeout (convert from milliseconds to seconds)
    # SiPP's -timeout is the maximum time for test execution in seconds
    # Set it to 80% of the Task timeout so SiPP can exit cleanly with a proper error code
    # rather than being killed by Task.shutdown. Minimum 10 seconds for basic scenarios.
    sipp_timeout_secs = max(10, div(timeout * 80, 100_000))  # 80% of Task timeout, in seconds, min 10
    args = args ++ ["-timeout", to_string(sipp_timeout_secs), "-timeout_error"]

    # Add TLS options if specified
    args =
      if transport == :tls && tls_cert && tls_key do
        args ++ ["-tls_cert", tls_cert, "-tls_key", tls_key]
      else
        args
      end

    # Add tracing options
    args =
      cond do
        trace_screen -> args ++ ["-trace_screen"]
        trace_msg -> args ++ ["-trace_msg"]
        trace_err -> args ++ ["-trace_err"]
        true -> args
      end

    # Add file outputs
    args = if pcap_file, do: args ++ ["-trace_rtt"], else: args
    args = if stats_file, do: args ++ ["-trace_stat", "-stf", stats_file], else: args
    args = if error_file, do: args ++ ["-trace_err", "-error_file", error_file], else: args
    args = if screen_file, do: args ++ ["-trace_screen", "-screen_file", screen_file], else: args

    # Add any additional arguments
    args = args ++ additional_args

    Logger.debug("Running SIPp: #{sipp_path} #{Enum.join(args, " ")}")

    # Run SIPp with timeout
    task =
      Task.async(fn ->
        System.cmd(sipp_path, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        Logger.debug("SIPp completed successfully")
        :ok

      {:ok, {output, status}} ->
        Logger.error("SIPp failed with status #{status}:\n#{output}")
        {:error, {:sipp_failed, status, output}}

      nil ->
        Logger.error("SIPp timed out after #{timeout}ms")
        {:error, {:timeout, timeout}}
    end
  end
end
