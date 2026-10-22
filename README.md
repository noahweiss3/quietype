<div align="center">

<img src="docs/assets/logo.svg" width="128" height="128" alt="Quietype app icon">

# Quietype

**Dictation for macOS that keeps quiet.**

Hold a key, talk, let go. Clean text appears wherever your cursor is.<br>
Speech recognition and LLM cleanup both run on your Mac, so nothing you say is sent anywhere.

[![Latest release](https://img.shields.io/github/v/release/noahweiss3/quietype)](https://github.com/noahweiss3/quietype/releases/latest)
[![CI](https://github.com/noahweiss3/quietype/actions/workflows/ci.yml/badge.svg)](https://github.com/noahweiss3/quietype/actions/workflows/ci.yml)
[![Cleanup evals](https://github.com/noahweiss3/quietype/actions/workflows/evals.yml/badge.svg)](https://github.com/noahweiss3/quietype/actions/workflows/evals.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2B-black)
![Swift 6 toolchain](https://img.shields.io/badge/Swift-6%20toolchain-F05138?logo=swift&logoColor=white)

[Features](#features) · [Install](#install) · [Usage](#usage) · [How it works](#how-it-works) · [Quality](#quality) · [Contributing](#contributing)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/demo-dark.svg">
  <img src="docs/assets/demo-light.svg" width="100%" alt="Illustration: hold Right Option, say a sentence with a correction, let go, and Quietype pastes the cleaned-up text">
</picture>

<sub>An illustration of the workflow, not a screen recording.</sub>

</div>

| You say | Quietype types |
|---|---|
| "Um, so I think we should, uh, push the launch to next week." | So I think we should push the launch to next week. |
| "Let's do the call at 2, **no wait**, 3 PM." | Let's do the call at 3 PM. |
| "I want pizza and wings, **scrap that, not the wings**." | I want pizza. |
| "Groceries: **first** eggs, **second** milk, **third** bread. **Scratch the bread.** Fourth coffee." | Groceries:<br>1. Eggs<br>2. Milk<br>3. Coffee |
| "Are we still on for lunch **question mark**" | Are we still on for lunch? |
| "Send them **my LinkedIn**, **no wait**, my GitHub." | Send them https://github.com/jlee. |

<sub>Each row is a case from the [eval suites](evals/README.md) and the output Quietype produced for it with the default Qwen3 4B model.</sub>

## Features

- **Fully on-device.** NVIDIA Parakeet transcribes on the Neural Engine and a Qwen3 model cleans up text with llama.cpp on the GPU. Quietype never sends your audio or text anywhere; it only goes online to download models.
- **Fast where it matters.** Speech is transcribed while you are still talking, so letting go of the key usually only waits for the stretch since your last pause. Plain sentences skip the LLM entirely and paste at transcription speed.
- **Understands how people actually talk.** Removes fillers and stutters, and applies spoken corrections: "no wait", "scratch that", "I mean", "not the wings", "start over".
- **Formats as you speak.** Numbered and bulleted lists, "new paragraph", spoken punctuation.
- **Writes for the app you're in.** No stray period in editors and terminals. When the LLM runs (in Smart mode, only for dictations that need it), it also keeps chat casual in Slack and Messages, writes full sentences in Mail, and leaves identifiers exactly as spoken in code.
- **Snippets.** Say a trigger like "my LinkedIn" or "my email signature" anywhere in a sentence and the stored text is pasted verbatim.
- **Personal dictionary.** Teach it names and jargon, or map a mishearing (`cooper netties -> Kubernetes`).
- **Live meeting notes.** Transcribes your microphone and the call's audio, with no bot joining the call, and keeps a running summary, decisions, action items and open questions as you talk.
- **Measured, not guessed.** Cleanup behaviour is pinned by unit tests and by eval suites that run the app's real pipeline against a local LLM in CI.

## Install

**Requirements:** an Apple Silicon Mac (M1 or later) on macOS 14 or later, and about 3 GB of disk for models. 16 GB of RAM is recommended for the default 4B cleanup model; the 1.7B model works with 8 GB.

### Download the latest release

1. Download `Quietype-<version>.zip` from the [latest release](https://github.com/noahweiss3/quietype/releases/latest). To check the download, get the `.sha256` file next to it and run `shasum -a 256 -c Quietype-<version>.zip.sha256`.
2. Unzip it and move `Quietype.app` to `/Applications`.
3. Open it. The app is ad-hoc signed, not notarized, so the first time macOS refuses to open it: go to System Settings › Privacy & Security, click *Open Anyway* next to the message about Quietype, and confirm.

### Build from source

Building needs Xcode 16 or later.

```sh
git clone https://github.com/noahweiss3/quietype.git
cd quietype
make run
```

`make run` builds `build/Quietype.app` and opens it. Move it to `/Applications` to keep it and launch it at login.

### First launch

Quietype lives in the menu bar. The first time it runs:

1. **Microphone:** allow it when asked.
2. **Accessibility:** needed for the global hotkey and for pasting. Click *Grant…* in Settings, then enable Quietype in System Settings › Privacy & Security › Accessibility.
3. **Speech model:** Parakeet downloads and compiles automatically, which takes about a minute the first time.
4. **Cleanup model:** click *Download Qwen3 4B Instruct (recommended)* in Settings (2.5 GB).

> [!NOTE]
> macOS ties the Accessibility permission to the app's code signature, and an ad-hoc signature changes with every build. After installing a new release or rebuilding, grant it again. When building yourself, a stable identity avoids that: `QUIETYPE_SIGN_IDENTITY="Apple Development: you@example.com" make app`.

## Usage

| Action | Result |
|---|---|
| Hold **Right Option** | Records while held, pastes on release |
| Double-tap **Right Option** | Hands-free: records until you tap once more |
| **Esc** while recording | Cancels |

The key can be changed to Right ⌘, Right ⌃ or Fn/🌐 in Settings.

**More things you can say**

- "The meeting is on Monday. **Scratch that.** The meeting is on Wednesday." → *The meeting is on Wednesday.*
- "Hey Sarah, so the thing is. **Start over.** Hi Sarah, quick question about the budget." → *Hi Sarah, quick question about the budget.*
- "Hi Alex, **new paragraph**, thanks for the quick turnaround on this." → a paragraph break after the greeting
- "To set it up, **first** install the CLI, **second** run the login command, and **third** deploy the project." → a numbered list
- "I want pizza, not wings." → left alone, because nothing was taken back

**Snippets.** Add a trigger and its text in Settings › Snippets, for example `my LinkedIn` → `https://www.linkedin.com/in/you`. Matching ignores case, punctuation and spacing ("my linked in" works) but only matches whole words. Snippets expand after cleanup, so "send them my LinkedIn, no wait, my GitHub" pastes only the GitHub link.

**Meeting notes.** Choose *Start Meeting Notes* from the menu bar. Quietype records your microphone (*You*) and the Mac's audio output (*Others*, through ScreenCaptureKit, which asks for Screen & System Audio Recording permission). About once a minute the local LLM folds the new conversation into the notes, and when someone changes their mind the notes keep the final version. *Stop* saves the notes and a timestamped transcript as Markdown. Without headphones the microphone also hears the call, so microphone segments that repeat what just played through the speakers are dropped. Dictation is paused while a meeting is recording.

**Settings**

- **Cleanup mode:** *Smart* (default) runs the LLM only when the transcript needs it. *Always* runs it on every dictation. *Rules only* never uses the LLM for dictation (meeting notes still load it).
- **Cleanup model:** Qwen3 4B Instruct (best quality) or Qwen3 1.7B (smaller and faster, weaker on subtle corrections).
- **Speculative decoding:** on by default. It never changes the output, and Quietype only uses it on Macs where it measures a speed-up (see [How it works](#how-it-works)); Settings says when it is inactive.
- **Speech model:** Parakeet Ultra (most accurate, 25 languages), Parakeet v2 (English) or Phonon-2 (English, fastest, macOS 15+). Cleanup rules and prompts are written for English.
- **Dictionary:** one term per line. `Kubernetes` fixes spelling and casing; `cooper netties -> Kubernetes` replaces a mishearing.
- **History:** recent dictations with the raw transcript, the cleaned text and per-stage timings. On by default; turn off *Keep history* to stop saving new dictations.

## How it works

```mermaid
flowchart LR
    A["🎙️ Key down"] --> B["Record 16 kHz"]
    B --> C["Split at pauses,<br/>transcribe while talking"]
    C --> D["Key up:<br/>transcribe last stretch"]
    D --> E["Rules pass"]
    E -->|"no cues"| H
    E -->|"correction, list,<br/>formatting cue"| F["Local LLM"]
    F --> G{"Output guard"}
    G -->|"accepted"| H["Dictionary, app style,<br/>snippets"]
    G -->|"rejected: rules text<br/>+ fallback corrections"| H
    H --> I["⌘V"]
```

Most of the speed comes from avoiding work rather than doing it faster:

1. **Transcribe while you talk.** The recording is split at pauses and finished stretches are transcribed in the background, so at release only the stretch since your last pause is left, however long you spoke.
2. **Skip the LLM when it isn't needed.** A deterministic rules pass removes fillers, stutters and standalone "start over". The LLM runs only when the transcript contains a cue: a correction ("scratch that", "no wait", "I mean"), a list ("first… second…", "bullet point"), a formatting command ("new paragraph", "comma") or a filler the rules can't safely remove ("you know", "like").
3. **Cache the prompt.** The system prompt and few-shot examples are evaluated once when the model loads. Each dictation evaluates only its own text.
4. **Guard the output.** A heuristic guard catches the common ways the LLM goes wrong: answering the dictation instead of cleaning it ("write me a poem" → a poem), adding many words that weren't said, or dropping nearly everything. Quietype then pastes the rules-pass text instead.
5. **Speculative decoding.** The decoder can draft upcoming tokens from the dictation itself and verify several at once, with output identical to plain greedy decoding. Quietype measures at load whether that pays off on your GPU; on the M2 Air below it didn't, so it was off.

**Stage timings** from `quietype-bench`, with both models loaded before timing:

| Dictation | Audio | Path | Transcribe at release | LLM cleanup |
|---|---:|---|---:|---:|
| "Thanks for sending the deck over, I will take a look…" | 5.0 s | rules only | 73 ms | – |
| "Um, so I think we should, uh, push the launch to next week." | 3.8 s | rules only | 59 ms | – |
| "Let's do the call at 2, no wait, 3 PM." | 2.8 s | LLM | 57 ms | 565 ms |
| "…three things. First, a venue. Second, catering…" | 9.7 s | LLM, list | 95 ms | 1,654 ms |

<sub>One run per clip on a MacBook Air (M2, 16 GB). [What is and isn't timed, and how to reproduce](docs/benchmarks.md#stage-timings).</sub>

The full design, module boundaries and extension points are in [docs/architecture.md](docs/architecture.md).

## Quality

Cleanup quality is measured by eval suites that run the app's own rules, prompt and guard (through `quietype-cli`) against a llama.cpp server. CI runs them on every change to the cleanup code and fails if any case fails that isn't a recorded known failure in [`evals/baselines.json`](evals/baselines.json).

| Suite | Cases | What it covers | Qwen3 4B |
|---|---:|---|---:|
| [Cleanup](evals/cases/cleanup.jsonl) | 35 | Fillers, corrections, "start over", lists, formatting commands, prompt injection, per-app style, vocabulary | **35/35** |
| [Corrections](evals/cases/corrections.jsonl) | 46 | Taking things back, replacements, additions, chained revisions, and look-alikes that must be left alone | **45/46** |
| [Corrections, extended](evals/cases/corrections-extended.jsonl) | 25 | Less common wordings ("strike X", "swap X for Y"), corrections after a filler, two revisions in one sentence | **22/25** |
| [Holdout](evals/cases/holdout.jsonl) | 60 | Corrections written without seeing the prompt; now regression cases (see below) | **52/60** |
| [Unseen](evals/cases/unseen.jsonl) | 30 | Dictations written by someone who hadn't seen the prompt, against a frozen prompt | **23/30** |
| [Snippets](evals/cases/snippets.jsonl) | 12 | Snippet expansion through the whole pipeline, including corrections between snippets | **12/12** |
| [Meeting notes](evals/meetings) | 33 checks | Two replayed meetings, checked with fixture assertions: expected names, tasks and phrases appear in the right section (and abandoned proposals don't), and every live update succeeds | **33/33** |

<sub>Run 2026-10-22 on a MacBook Air (M2, 16 GB) at temperature 0. [Setup, caveats and how to reproduce](docs/benchmarks.md#eval-scores).</sub>

The cleanup, corrections and snippets suites were written alongside the rules and the prompt. The holdout cases were written without seeing the prompt and their text never went into it, but misses on earlier rounds of them informed general prompt changes, so they now serve as regression cases. The unseen suite is the clean measure: its cases were written against a frozen prompt by someone who hadn't seen it. [evals/README.md](evals/README.md#where-the-cases-come-from) has the details, the case format and how to run everything yourself.

## Privacy

- Audio is processed in memory and never written to disk or sent anywhere.
- The only network traffic is downloading the speech and cleanup models.
- Quietype stores, in `~/Library/Application Support/Quietype/`:
  - `history.json`: your last 100 dictations (raw and cleaned text, the app you dictated into, timings), in plain JSON. Turn off *Settings › History › Keep history* and new dictations aren't saved. If it can't be read, it is kept beside it as `history.unreadable-<date>-<time>.json` and a new history is started. *Settings › History › Clear History* deletes the history and those kept copies.
  - `Meetings/`: notes and transcripts you chose to record, as Markdown.
  - `Models/`: the cleanup models.
- Settings, your personal dictionary and your snippets (including their text) are stored in plain form in UserDefaults, domain `com.noahweiss.quietype`.
- Speech models are kept in FluidAudio's cache, `~/Library/Application Support/FluidAudio/`.
- Pasting goes through the clipboard: Quietype puts the text there, sends ⌘V, then restores what was on the clipboard before.

## Limitations

- **English only for cleanup.** Speech recognition can use other languages with Parakeet Ultra, but the rules and prompts are written for English.
- **Echo suppression is a heuristic.** Without headphones, a microphone segment is dropped when it overlaps call audio in time and repeats most of its words in order. It can miss an echo the microphone picked up differently, or drop something you said over the other person that repeats their words.
- **Everyone on the call is "Others".** Meeting transcripts tell your microphone apart from the Mac's audio output, not one remote speaker from another.
- **Per-app styles go by app.** Styles are chosen by the frontmost app's bundle ID, so Slack or Gmail in a browser tab gets the browser's style (the default), not the chat or email one.

## Troubleshooting

<details>
<summary><b>Nothing happens when I hold the key</b></summary>

Check that Quietype is enabled in System Settings › Privacy & Security › Accessibility. If you rebuilt the app, remove Quietype from the list and add it again.
</details>

<details>
<summary><b>The Fn key opens the emoji picker</b></summary>

Set System Settings › Keyboard › "Press 🌐 key to" to "Do Nothing", or use Right Option.
</details>

<details>
<summary><b>Text doesn't paste in one app</b></summary>

Some apps block synthetic ⌘V. The text is still in History; click it in the menu bar's *Recent* submenu to copy it.
</details>

<details>
<summary><b>Debugging the cleanup model</b></summary>

Run the app binary directly to see llama.cpp's logs: `QUIETYPE_LLAMA_LOG=1 build/Quietype.app/Contents/MacOS/Quietype`.
</details>

## Contributing

Contributions are welcome, and eval cases that show Quietype getting something wrong are especially useful. Start with [CONTRIBUTING.md](CONTRIBUTING.md) for setup, tests and evals, and [docs/architecture.md](docs/architecture.md) for how the code fits together.

```
Sources/
  QuietypeCore/     portable logic, tested on macOS and Linux: rules, prompt, guard,
                    speculative decoding, segmentation, snippets, meeting notes
  QuietypeKit/      macOS adapters: Parakeet transcriber, llama.cpp runner, model downloads
  Quietype/         the menu bar app (AppKit + SwiftUI)
  quietype-cli/     JSON front end over QuietypeCore, used by the evals
  quietype-bench/   headless pipeline that prints per-stage timings
Tests/              unit tests, mirroring Sources/
evals/              cleanup and meeting-notes eval suites and runners
docs/               architecture and benchmark methodology
scripts/            app bundling and signing
```

## Acknowledgements

Quietype is built on [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) and [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0). It downloads speech models based on [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0) through FluidAudio and [Qwen3](https://huggingface.co/Qwen) cleanup models (Apache 2.0) as GGUF files from [Unsloth](https://huggingface.co/unsloth). Each model is subject to its own license. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) has the full notices and credits each model.

## License

Quietype is released under the [MIT License](LICENSE).
