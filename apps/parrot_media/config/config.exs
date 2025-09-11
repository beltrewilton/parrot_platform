import Config

# Media-specific configuration
config :parrot_media,
  rtp_port_range: 10000..20000,
  supported_codecs: [:opus, :alaw, :ulaw],
  default_codec: :opus

# Use default logger for media app
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:file, :line]