# Root test helper for umbrella project
# This is for integration tests and SIPp scenarios

# Configure logging based on environment variables before starting tests
sip_trace = System.get_env("SIP_TRACE", "false") == "true"

# If SIP trace is enabled, we need to allow info level logs to see the traces
# Otherwise use the configured log level
default_level = if sip_trace, do: "info", else: "warning"
log_level = System.get_env("LOG_LEVEL", default_level) |> String.to_existing_atom()
Logger.configure(level: log_level)

# Set test configuration for each app
Application.put_env(:parrot_sip, :test_log_level, log_level)
Application.put_env(:parrot_sip, :test_sip_trace, sip_trace)
Application.put_env(:parrot_media, :test_log_level, log_level)
Application.put_env(:parrot_transport, :test_log_level, log_level)

# Start all umbrella apps for integration testing
Application.ensure_all_started(:parrot_transport)
Application.ensure_all_started(:parrot_media)
Application.ensure_all_started(:parrot_sip)

# Exclude slow tests by default (they cause long delays)
# Run with: mix test --include sipp
# Or specifically: mix test test/sipp/
# Run integration tests with: mix test --include integration
# Run slow tests with: mix test --include slow
ExUnit.configure(exclude: [:sipp, :integration, :slow])

ExUnit.start()
