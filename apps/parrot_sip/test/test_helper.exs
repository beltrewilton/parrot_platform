# Suppress all logs during tests unless SIP_TRACE is enabled
unless System.get_env("SIP_TRACE") == "true" do
  Logger.configure(level: :emergency)
  # Remove console backend to completely suppress logs
  Logger.remove_backend(:console)
end

ExUnit.start()
