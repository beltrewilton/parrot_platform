require Logger

# Suppress all logs during tests unless SIP_TRACE is enabled
if System.get_env("FULL_TRACE") == "true" do
  IO.puts("FULL_TRACE enabled - setting log level to :debug")
  Logger.configure(level: :debug)
  Logger.add_backend(:console)
  Logger.configure_backend(:console, 
    format: "$time $metadata[$level] $message\n",
    metadata: [:file, :line]
  )
else
  Logger.configure(level: :emergency)
  # Remove console backend to completely suppress logs
  Logger.remove_backend(:console)
end

ExUnit.start()
