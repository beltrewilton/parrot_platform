import Config

# Configure logging for tests based on environment variables
# Usage:
#   mix test                        # Default: warnings and errors only
#   LOG_LEVEL=debug mix test        # Show debug logs
#   LOG_LEVEL=info mix test         # Show info and above
#   LOG_LEVEL=error mix test        # Errors only (quietest)
#   SIP_TRACE=true mix test         # Show full SIP messages
#   LOG_LEVEL=error SIP_TRACE=true mix test  # Minimal logs but show SIP messages

# Configure default SIP trace setting for tests
sip_trace = System.get_env("SIP_TRACE", "false") == "true"

# If SIP trace is enabled, we need to allow info level logs to see the traces
# Otherwise use the configured log level
default_level = if sip_trace, do: "info", else: "error"
log_level = System.get_env("LOG_LEVEL", default_level) |> String.to_existing_atom()

# Be very aggressive about suppressing logs during tests
if sip_trace do
  config :logger, level: log_level

  config :logger, :console,
    level: log_level,
    format: "$time $metadata[$level] $message\n"
else
  # Suppress logs during tests but keep handlers available
  # so they can be re-enabled at runtime with LOG_LEVEL or SIP_TRACE
  config :logger, level: :emergency
end

# Configure each umbrella app separately
config :parrot_sip,
  test_sip_trace: sip_trace,
  test_log_level: log_level

config :parrot_media,
  test_log_level: log_level

config :parrot_transport,
  test_log_level: log_level

# SIPp test configuration for integration tests
config :ex_unit,
  sipp_test_timeout: 10_000,
  sipp_test_retries: 3,
  sipp_scenarios_path: Path.join([File.cwd!(), "test", "sipp", "scenarios"]),
  sipp_error_log: "/tmp/sipp_error.log"
