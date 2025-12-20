import Config

# Configure the UAC
config :parrot_example_uac,
  port: String.to_integer(System.get_env("PORT") || "5070"),
  audio_file: System.get_env("AUDIO_FILE")

# Configure logging
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:file, :line]
