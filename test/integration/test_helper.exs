# Integration Test Helper
# This file is for integration tests that span multiple umbrella apps

# Ensure all apps are started
Application.ensure_all_started(:parrot_transport)
Application.ensure_all_started(:parrot_media)
Application.ensure_all_started(:parrot_sip)

# Load support files
Code.require_file("../../apps/parrot_sip/test/support/test_handler.ex", __DIR__)
Code.require_file("../../apps/parrot_media/test/support/test_media_handler.ex", __DIR__)

ExUnit.start()