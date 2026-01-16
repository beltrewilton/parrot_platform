import Config

# Media-specific configuration
config :parrot_media,
  rtp_port_range: 10000..20000,
  supported_codecs: [:opus, :alaw, :ulaw],
  default_codec: :opus

# MOS (Mean Opinion Score) configuration
# Uses ITU-T G.107 E-model for real-time call quality monitoring
config :parrot_media, :mos,
  enabled: true,
  interval_ms: 5_000,
  min_packets_per_interval: 10,
  default_delay_ms: 50.0,
  thresholds: [
    %{name: :excellent, value: 4.0, hysteresis: 0.1},
    %{name: :good, value: 3.5, hysteresis: 0.1},
    %{name: :fair, value: 3.0, hysteresis: 0.1},
    %{name: :poor, value: 1.0, hysteresis: 0.1}
  ]

# Use default logger for media app
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:file, :line]
