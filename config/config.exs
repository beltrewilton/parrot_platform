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

# Import environment specific config
import_config "#{config_env()}.exs"
