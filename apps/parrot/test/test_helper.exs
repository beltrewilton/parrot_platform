# Ensure ParrotMedia application is started for tests that need MediaSession
Application.ensure_all_started(:parrot_media)

ExUnit.start()
