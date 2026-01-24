# Ensure ParrotMedia application is started for tests that need MediaSession
Application.ensure_all_started(:parrot_media)

# Exclude pending_implementation tests by default - these are TDD "red" tests
# for features not yet implemented. Run with --include pending_implementation
# to verify implementation progress.
ExUnit.start(exclude: [:pending_implementation])
