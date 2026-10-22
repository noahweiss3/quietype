# Contributing to Quietype

Thanks for your interest in improving Quietype. Bug reports, eval cases that show a wrong cleanup, and pull requests are all welcome.

Before writing code, skim [docs/architecture.md](docs/architecture.md). It explains how the pieces fit together and where the common changes go.

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Setup

You need an Apple Silicon Mac on macOS 14 or later and **Xcode 16 or later**. The Command Line Tools alone can build the app but not run the tests, because XCTest ships with Xcode.

The package needs the Swift 6 toolchain (`swift-tools-version:6.0`) and every target compiles in the Swift 6 language mode, so strict concurrency checking is enforced: a data race the compiler can see is a build error.

```sh
git clone https://github.com/noahweiss3/quietype.git
cd quietype
make run        # builds build/Quietype.app and opens it
```

Run `make help` to see every task. The ones you'll use most:

| Command | What it does |
|---|---|
| `make build` | Debug build of every target |
| `make test` | `QuietypeCore` unit tests. Fast, no models needed |
| `make app` | Release build bundled and signed as `build/Quietype.app` |
| `make cli` | Builds `quietype-cli`, which the evals use |
| `make evals` | Runs every cleanup suite and the meeting-notes evals and prints each case, for exploring (needs a llama.cpp server, see below) |
| `make evals-check` | Runs the cleanup and meeting-notes evals against their baselines, the same check CI applies |
| `make bench` | Builds `quietype-bench` for latency measurements |
| `make evals-test` | Unit tests for the eval scripts themselves. No model needed |
| `make lint` | Checks Swift formatting with `swift format`, then lints the eval scripts with the same pinned ruff as CI (needs `pipx`) |
| `make format` | Formats the Swift code in place, the way `make lint` and CI expect it |

> **Accessibility after rebuilding.** macOS ties the Accessibility permission to the app's code signature, and an ad-hoc signature changes on every build. Either re-grant it after each rebuild, or sign with a stable identity: `QUIETYPE_SIGN_IDENTITY="Apple Development: you@example.com" make app`.

## Tests

`QuietypeCore` holds all the logic that can be tested without a Mac, and its tests run on macOS and Linux:

```sh
make test
```

On Linux, or to reproduce the Linux CI job from a Mac with Docker:

```sh
docker run --rm -v "$PWD":/src -w /src swift:6.4 swift test --scratch-path /tmp/build
```

Use Swift 6.4 or later on Linux: earlier toolchains have an XCTest bug on arm64 that can hang a test run at random.

`QuietypeKitTests` load a real cleanup model, so they skip unless you point them at one:

```sh
QUIETYPE_TEST_MODEL=~/Library/Application\ Support/Quietype/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  swift test --filter QuietypeKitTests
```

Set `QUIETYPE_TEST_MODEL_ID=qwen3-1.7b` when testing the smaller model.

Test files follow the source layout: tests for `Sources/QuietypeCore/Cleanup/Rules.swift` live in `Tests/QuietypeCoreTests/Cleanup/RulesTests.swift`, so put new tests in the file named after the source you changed. Name tests after the behaviour they pin down (`testStartOverInsideASentenceIsLeftForTheLLM`), not the method they call.

## Evals

Unit tests check the deterministic code. Whether the LLM cleans text well is measured by the eval suites in [`evals/`](evals/README.md), which run the app's own rules, prompt and guard through `quietype-cli` against a llama.cpp server.

Run them whenever you change `Rules.swift`, `CleanupPrompt.swift`, `OutputGuard.swift`, snippet handling or the meeting-notes prompt:

```sh
llama-server -m ~/Library/Application\ Support/Quietype/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf --jinja -c 8192 -np 1 --port 8080
make evals-check
```

`make evals-check` is the acceptance gate: it runs the cleanup suites and the meeting-notes evals with `--check-baseline` and fails when any case fails that isn't listed as a known failure in `evals/baselines.json`, which is what CI checks. `make evals` runs the same suites for exploring: it prints every case and exits non-zero whenever any case fails, including the known misses, so a non-zero exit there doesn't mean you broke something.

A pull request that touches the prompt, rules, guard, snippets or meeting notes should pass `make evals-check`. CI enforces this. If you fix a known failure, take its id out of `known_failures` in `evals/baselines.json` in the same pull request. When you find a dictation that Quietype cleans badly, adding it as an eval case is one of the most useful contributions you can make, even without a fix.

## Measuring latency

```sh
make bench
say -o /tmp/test.aiff "Let's do the call at two, no wait, three PM."
afconvert -f WAVE -d LEI16@16000 /tmp/test.aiff /tmp/test.wav
.build/release/quietype-bench \
  --model ~/Library/Application\ Support/Quietype/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  --audio /tmp/test.wav --cases evals/cases/cleanup.jsonl --compare
```

This prints timings per stage, not a key-release-to-paste latency. For each audio file the bench feeds the samples to the app's `LiveTranscription` in 100 ms chunks without waiting in real time, then reports how long transcribing the remaining audio took once the input ended (`tail transcribed in`). For each input it reports the cleanup path and, when the LLM ran, its total time split into prefill and generation. The rules pass, dictionary, snippets and paste aren't timed. `--compare` also runs plain greedy decoding and fails if speculative decoding changed the output. The table in the README came from one run of four clips made with `say` like the one above. Include before and after numbers in any pull request that claims a speed-up. [docs/benchmarks.md](docs/benchmarks.md) describes how the README's numbers were made.

## Environment variables

None of these are needed for normal use. They change how the app, the tests or the evals run.

| Variable | Read by | What it does |
|---|---|---|
| `QUIETYPE_SIGN_IDENTITY` | `scripts/build-app.sh` (`make app`, `make run`) | Code-signing identity for `build/Quietype.app`. Defaults to `-`, an ad-hoc signature, which changes on every build. |
| `QUIETYPE_LLAMA_LOG` | The app, `quietype-bench`, `QuietypeKitTests` | When set to anything, llama.cpp's own logs go to stderr instead of being silenced. |
| `QUIETYPE_GPU_LAYERS` | The app, `quietype-bench`, `QuietypeKitTests` | How many layers of the cleanup model llama.cpp offloads to the GPU (meeting notes share the same model). Defaults to all of them; `0` keeps it on the CPU, which CI uses because the runner's virtual GPU is slower. |
| `QUIETYPE_TEST_MODEL` | `QuietypeKitTests` | Path to a cleanup model GGUF. The model-backed tests skip when it isn't set. |
| `QUIETYPE_TEST_MODEL_ID` | `QuietypeKitTests` | Which cleanup model `QUIETYPE_TEST_MODEL` is (`qwen3-4b-instruct-2507` by default, or `qwen3-1.7b`). It picks the matching chat prefill, so it must match the file. |
| `QUIETYPE_CLI` | The eval scripts | Path to the `quietype-cli` binary. Defaults to `.build/debug/quietype-cli`. |
| `QUIETYPE_EVAL_BACKEND` | The eval scripts | A free-text label, such as `llama.cpp Metal`, recorded in each result's manifest, because the server doesn't report whether it runs on the CPU or the GPU. |

## Code guidelines

- **Keep `QuietypeCore` portable.** No AppKit, AVFoundation or model code there. If new logic needs hardware or a model, define a small protocol in `QuietypeCore` and implement it in `QuietypeKit` or the app, the way `SpeechTranscriber`, `TextCleaner` and `TextGenerator` work. That keeps it testable with fakes on Linux.
- **Deterministic before generative.** If a rule can handle something reliably, put it in `Rules`. Reserve the LLM for what needs judgement, and make sure the guard can catch it going wrong.
- **Comments explain why.** Doc-comment public types and anything non-obvious with the reasoning behind it. Don't narrate what the code already says.
- **Match the surrounding style.** Four-space indentation, Swift API Design Guidelines naming, `// MARK:` sections in longer files. `.editorconfig` covers whitespace.
- **Run `make format` before you commit.** It applies `swift format` with the repo's `.swift-format` (120 columns), and CI fails on any file it would change.

## Pull requests

1. Fork, then branch from `main`.
2. Keep each pull request to one change. Refactors and behaviour changes go in separate pull requests.
3. Write commit subjects as `area: what changed`, in the imperative and lowercase, for example `rules: treat "strike that" as a retraction` or `notes: retry with a shorter answer`.
4. Run `make test`, plus `make evals-check` if you touched cleanup or notes behaviour, and fill in the pull request template.

CI runs the core tests on Linux and macOS, builds the app, and runs the evals when cleanup code changes.

## Reporting bugs

Open an issue with the bug template. For a bad cleanup, the most useful thing to include is the History entry (Settings › History), which has the raw transcript, the cleaned text and which path it took (rules, LLM, or LLM rejected).

For security issues, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
