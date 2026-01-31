import Config

# Mini PBX Configuration
config :parrot_mini_pbx,
  port: String.to_integer(System.get_env("PORT") || "5060")

# SIP realm for authentication (used by Parrot.Bridge.Handler)
config :parrot, :sip_realm, "pbx.local"

# Logger configuration
config :logger,
  level: String.to_atom(System.get_env("LOG_LEVEL") || "info")

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
