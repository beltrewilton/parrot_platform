import Config

# Shared Registry Configuration
# This is the ONLY place where apps know about each other
config :parrot_transport,
  registry: Parrot.Registry,
  sip_handler_key: :sip_receiver

config :parrot_sip,
  registry: Parrot.Registry,
  transport_key: :sip_transport,
  media_key_prefix: :media_session

config :parrot_media,
  registry: Parrot.Registry,
  sip_key_prefix: :sip_dialog

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

# Import environment specific config
import_config "#{config_env()}.exs"
