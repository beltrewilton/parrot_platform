require Logger

# Start the application before running tests
{:ok, _} = Application.ensure_all_started(:parrot_sip)

# Configure logging based on environment variables
# Priority: LOG_LEVEL > FULL_TRACE > SIP_TRACE > default (emergency)
log_level_str = System.get_env("LOG_LEVEL")
sip_trace = System.get_env("SIP_TRACE", "false") == "true"
full_trace = System.get_env("FULL_TRACE", "false") == "true"

{log_level, show_logs} =
  cond do
    log_level_str != nil ->
      level = String.to_existing_atom(log_level_str)
      IO.puts("LOG_LEVEL=#{log_level_str} - setting log level to #{level}")
      {level, true}

    full_trace ->
      IO.puts("FULL_TRACE enabled - setting log level to :debug")
      {:debug, true}

    sip_trace ->
      IO.puts("SIP_TRACE enabled - setting log level to :debug")
      {:debug, true}

    true ->
      {:emergency, false}
  end

if show_logs do
  # Configure the primary logger level
  Logger.configure(level: log_level)

  # Ensure the default handler is configured properly (Elixir 1.15+ / OTP 21+)
  :logger.update_handler_config(:default, :level, log_level)
else
  Logger.configure(level: :emergency)
  :logger.update_handler_config(:default, :level, :emergency)
end

# Exclude slow tests by default - include with mix test --include sipp
ExUnit.start(exclude: [:sipp])
