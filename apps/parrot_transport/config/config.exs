import Config

# Transport-specific configuration
config :parrot_transport,
  default_port: 5060,
  trace: false

# Use default logger for transport app
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:file, :line]

# Reduce logging noise during tests
if Mix.env() == :test do
  config :logger, level: :warning
end