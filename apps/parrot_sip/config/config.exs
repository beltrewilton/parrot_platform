import Config

# SIP-specific configuration
config :parrot_sip,
  default_port: 5060,
  max_forwards: 70,
  user_agent: "ParrotSIP/0.0.1"

# Use default logger for SIP app
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:file, :line]
