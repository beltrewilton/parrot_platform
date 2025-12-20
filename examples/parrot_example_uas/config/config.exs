import Config

# Configure the UAS
config :parrot_example_uas,
  port: String.to_integer(System.get_env("PORT") || "5060"),
  audio_file: System.get_env("AUDIO_FILE")

# Configure logging
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:file, :line]
