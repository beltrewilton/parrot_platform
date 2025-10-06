require Logger

# Start the application before running tests
{:ok, _} = Application.ensure_all_started(:parrot_sip)

# Configure logging based on environment variables
# Priority: LOG_LEVEL > FULL_TRACE > SIP_TRACE > default (emergency)
log_level_str = System.get_env("LOG_LEVEL")
sip_trace = System.get_env("SIP_TRACE", "false") == "true"
full_trace = System.get_env("FULL_TRACE", "false") == "true"

{log_level, show_logs} = cond do
  log_level_str != nil ->
    level = String.to_existing_atom(log_level_str)
    IO.puts("LOG_LEVEL=#{log_level_str} - setting log level to #{level}")
    {level, true}

  full_trace ->
    IO.puts("FULL_TRACE enabled - setting log level to :debug")
    {:debug, true}

  sip_trace ->
    IO.puts("SIP_TRACE enabled - setting log level to :info")
    {:info, true}

  true ->
    {:emergency, false}
end

if show_logs do
  Logger.configure(level: log_level)
  Logger.add_backend(:console)
  Logger.configure_backend(:console,
    format: "$time $metadata[$level] $message\n",
    metadata: if(full_trace or log_level == :debug, do: [:file, :line], else: [])
  )
else
  Logger.configure(level: :emergency)
  Logger.remove_backend(:console)
end

# Exclude slow tests by default - include with mix test --include sipp
ExUnit.start(exclude: [:sipp])
