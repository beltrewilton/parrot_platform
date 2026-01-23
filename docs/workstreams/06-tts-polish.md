# Workstream: TTS Feature Polish (US3-US6)

## Worktree Setup
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git worktree add ../parrot-tts 01-dsl-refactor -b workstream/tts-polish
cd ../parrot-tts
```

## When Complete
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git checkout 01-dsl-refactor
git merge workstream/tts-polish
git worktree remove ../parrot-tts
git branch -d workstream/tts-polish
```

## Context
Text-to-speech integration with multiple providers.
Core implementation done. Continue with profiles, caching, error handling.

## Your Tasks (beads IDs)
- a71: US3 - Provider Profiles
- y56: US4 - Caching
- 61g: US5 - Error Handling
- 5uq: US6 - Custom Provider
- w0z: Polish
- o5o: Integration testing gaps
- mnl: [CODE-REVIEW] TTS Synthesizer Process Safety

## Beads Workflow
```bash
bd show a71           # View US3 details
bd update a71 --status in_progress
bd close a71 "Implemented profile switching with tests"
bd sync
```

## Architecture
- Provider behaviour: apps/parrot/lib/parrot/tts/provider.ex
- Config: apps/parrot/lib/parrot/tts/config.ex
- Synthesizer: apps/parrot/lib/parrot/tts/synthesizer.ex
- Cache: apps/parrot/lib/parrot/tts/cache/

## Feature Details
**US3:** Named profiles in config, runtime profile switching
**US4:** ETS for development, disk cache with TTL for production
**US5:** handle_tts_error/3 callback, fallback audio support
**US6:** Document provider behaviour, example custom provider

## Subagent Usage
Use subagents for each user story.
Use Req.Test.stub for API mocking - no real API calls in tests.

## Before Merging
1. Run `mix test` - all tests must pass
2. `bd sync && git add .beads && git commit -m "Sync beads"`
