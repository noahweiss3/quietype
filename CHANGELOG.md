# Changelog

All notable changes to Quietype are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-22

The first release.

### Dictation

- Hold-to-talk and double-tap hands-free dictation on a configurable key (Right Option, Right ⌘, Right ⌃ or Fn), with Esc to cancel.
- On-device transcription with NVIDIA Parakeet on the Neural Engine via FluidAudio, transcribing finished stretches while you are still talking.
- A deterministic rules pass for fillers, stutters and "start over", and an on-device LLM pass (Qwen3 4B or 1.7B on llama.cpp) for spoken corrections, lists and formatting commands.
- Smart cleanup mode that skips the LLM when the rules pass finds nothing for it to do.
- Prompt caching, so each dictation only evaluates its own text.
- Prompt-lookup speculative decoding, verified to match plain greedy output. It can help on GPUs where batched verification is cheap; a load-time check switches it off everywhere else, including the M2 Air used for the published timings.
- An output guard that falls back to the rules text when the LLM answers the dictation instead of cleaning it.
- Per-app writing styles for chat, email and code editors.
- A personal dictionary for spellings and common mishearings, and snippets that expand a spoken trigger into stored text.
- History of recent dictations with per-stage timings, which can be turned off.
- Retry buttons when the speech or cleanup model fails to download or load.

### Meeting notes

- Live transcription of the microphone and the Mac's audio output, with echo suppression when you are not wearing headphones.
- Notes (summary, decisions, action items, open questions) kept up to date by the local LLM during the meeting and saved with the transcript as Markdown.

### Tooling

- `quietype-cli` and eval suites that run the app's real cleanup pipeline against any llama.cpp server.
- `quietype-bench` for per-stage timings of the headless pipeline.

[Unreleased]: https://github.com/noahweiss3/quietype/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/noahweiss3/quietype/releases/tag/v0.1.0
