# Benchmarks

How the numbers in the README's [stage timings](../README.md#how-it-works) and [eval scores](../README.md#quality) tables were made, and how to reproduce them.

## Stage timings

The timings come from `quietype-bench`, which runs the app's pipeline headless with both models loaded before anything is timed.

**What is measured.** These are per-stage timings, not a key-release-to-paste measurement. The bench feeds each clip to the app's `LiveTranscription` in 100 ms chunks without real-time pacing, then times what the app does at release:

- **Transcribe at release:** transcribing the audio not yet transcribed when the input ends. None of the clips had a long pause, so this was the whole clip each time.
- **LLM cleanup:** prefill plus generation, when the rules pass found a cue that needs the LLM.

The rules pass, dictionary, snippets and the paste itself are not timed.

**Setup.** One run per clip on a MacBook Air (M2, 16 GB), Qwen3 4B Instruct 2507 Q4_K_M, Parakeet Ultra, release build, measured 2026-10-21. The clips were made with `say`, like the one in the reproduction steps.

**Speculative decoding was off.** When the cleanup model loads, Quietype times an 8-token batch against a single token and only uses speculative decoding when the batch costs less than twice as much. On the M2 Air it didn't, so every LLM number in the table is plain greedy decoding. Speculation only helps on GPUs where batched verification is cheap; no speed-up from it is claimed here.

**Reproduce.** Follow [Measuring latency](../CONTRIBUTING.md#measuring-latency) in CONTRIBUTING.md. Include before and after numbers from the same machine in any pull request that claims a speed-up.

## Eval scores

The eval suites run the app's own rules, prompt and output guard through `quietype-cli` against a llama.cpp server. [evals/README.md](../evals/README.md) describes the suites, the case format and how each case is scored.

**Setup.** Run 2026-10-22 on a MacBook Air (M2, 16 GB): Qwen3 4B Instruct 2507 Q4_K_M served by `llama-server` built from llama.cpp b11351 (the same release the app embeds and CI uses) on Metal, smart cleanup mode, temperature 0.

**How the evals differ from the app.** A few steps run differently, most notably the chat template, which the server and the app render with different code. [evals/README.md](../evals/README.md#how-a-case-runs) lists the differences.

**Which score measures generalization.** Only the unseen suite was written against a frozen prompt by someone who hadn't seen it. The holdout cases have informed general prompt changes, so they count as regression cases; [evals/README.md](../evals/README.md#where-the-cases-come-from) explains.

**What the meeting score means.** The 33 meeting checks are substring assertions on two replayed meetings: expected names, tasks and phrases appear in the right section, abandoned proposals don't, and every live update succeeds. They catch regressions on those fixtures; they are not a general accuracy score.

**Reproduce.** Start the server with the command in [evals/README.md](../evals/README.md#running-locally), then run `make evals-check`, or `python3 evals/run_evals.py --all` and `python3 evals/run_meeting_notes.py`. Each run lists its misses, which make good first issues.
