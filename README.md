# Murmur

Fast dictation for macOS that runs entirely on your Mac. Hold a key, talk, let go, and cleaned-up text appears wherever your cursor is.

- **Transcription:** NVIDIA Parakeet on the Neural Engine (via [FluidAudio](https://github.com/FluidInference/FluidAudio))
- **Cleanup:** a local LLM (Qwen3 4B Instruct via [llama.cpp](https://github.com/ggml-org/llama.cpp)) that removes fillers, applies "scratch that" / "no wait" / "not the wings" / "start over", and formats lists
- **Snippets:** say "my LinkedIn" and your profile URL is typed instead
- **Meeting notes:** transcribes your mic and the call's audio live, and keeps notes (summary, decisions, action items) up to date as you talk
- **Private:** no audio or text leaves the machine. The only network access is the one-time model downloads.

## How it works

```
key down ─▶ mic (16 kHz) ─▶ pause detector ─▶ Parakeet on finished stretches, while you talk
key up   ─▶ Parakeet on the last stretch ─▶ rules pass ─▶ LLM (only if needed) ─▶ guard ─▶ ⌘V
```

Most of the speed comes from avoiding work rather than doing it faster:

1. **Transcribe while you talk.** Recording is split at pauses, and finished stretches are transcribed in the background. When you release the key, only the last few seconds are left.
2. **Skip the LLM when it isn't needed.** A deterministic rules pass removes "um"/"uh", stutters and standalone "start over". The LLM runs only when the transcript contains a cue: corrections ("scratch that", "no wait", "I mean"), lists ("first… second…", "bullet point"), formatting commands ("new paragraph") or soft fillers ("you know", "like"). Plain sentences paste at transcription speed.
3. **Cache the prompt.** The system prompt and examples (~1,100 tokens) are evaluated once when the model loads. Each dictation only evaluates its own text.
4. **Speculative decoding from the input.** Cleanup output is mostly a copy of the input, so the decoder proposes upcoming tokens straight from the dictation and verifies up to 12 at once. Output is identical to normal greedy decoding (`murmur-bench --compare` checks this) but needs fewer forward passes. It only pays off when checking a small batch costs about the same as one token, which is true on Apple Silicon GPUs. So at load time Murmur times a 1-token pass against an 8-token pass and turns speculation off if batching is expensive.
5. **Guard the output.** If the LLM answers the dictation instead of cleaning it ("write me a poem" → a poem), adds many new words, or returns nothing for no reason, Murmur pastes the rules-pass text instead.

## Requirements

- Apple Silicon Mac (M1 or later), macOS 14+. 16 GB RAM recommended for the 4B cleanup model.
- Xcode 16 or later (or its Command Line Tools) to build.
- About 3 GB of disk for models: Parakeet ~0.5 GB, Qwen3 4B 2.5 GB.

## Build and run

```sh
git clone https://github.com/noahweiss3/murmur.git
cd murmur
scripts/build-app.sh
open build/Murmur.app
```

On first launch:

1. **Microphone:** allow when asked.
2. **Accessibility:** needed for the global hotkey and for pasting. Click *Grant…* in the settings window, then turn Murmur on in System Settings › Privacy & Security › Accessibility.
3. **Speech model:** Parakeet downloads and compiles automatically (about a minute the first time).
4. **Cleanup model:** click *Download Qwen3 4B Instruct* in Settings.

Copy `build/Murmur.app` to `/Applications` if you want it to persist and launch at login.

> **Rebuilding resets Accessibility.** macOS ties the permission to the app's code signature, and the default ad-hoc signature changes on every build. Either re-grant it after a rebuild, or sign with a stable identity: `MURMUR_SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh`. A free Apple Development certificate from Xcode works, as does a self-signed code-signing certificate made in Keychain Access.

The *macOS* GitHub workflow also uploads a built `Murmur.app` as an artifact. It's ad-hoc signed, so after unzipping run `xattr -cr Murmur.app` before opening.

## Using it

| Action | What happens |
|---|---|
| Hold **Right Option** | Records while held, pastes on release |
| Double-tap **Right Option** | Hands-free: records until you tap once more |
| **Esc** while recording | Cancels |
| Quick single tap | Ignored |

You can change the key in Settings (Right ⌘, Right ⌃, or Fn/🌐).

Things you can say:

- "Let's meet at 3, **no wait**, 4" → *Let's meet at 4*
- "The meeting is Monday. **Scratch that.** The meeting is Wednesday." → *The meeting is Wednesday.*
- "I want pizza and wings, **scrap that, not the wings**" → *I want pizza.*
- "Add eggs, milk, and butter. **Wait, skip the butter.**" → *Add eggs and milk.*
- "I'd like the soup, not the salad" → left alone: nothing was taken back
- "…**start over.** Hi Sarah, quick question" → *Hi Sarah, quick question*
- "We need **first** eggs, **second** milk, **third** bread" → a numbered list
- "Hi Alex **new paragraph** thanks for…" → a paragraph break
- "Are we still on **question mark**" → *Are we still on?*

Text is styled for the app you're in: casual in Slack and Messages, full sentences in Mail, and in editors and terminals identifiers are kept exactly with no trailing period.

**Snippets.** Add a trigger and its text in Settings › Snippets, e.g. `my LinkedIn` → `https://www.linkedin.com/in/you`. Say the trigger anywhere in a dictation ("here's my LinkedIn if you want to connect") and the text is pasted exactly as written. Matching ignores case, punctuation and spacing ("my linked in" works) and only matches whole words. Expansion happens after cleanup, so "send them my LinkedIn, no wait, my GitHub" expands only GitHub. A dictation that is just the trigger ("my email signature") becomes exactly the stored text.

**Meeting notes.** Choose *Start Meeting Notes* from the menu bar. Murmur records your microphone (labelled *You*) and the Mac's audio output (*Others*, via ScreenCaptureKit, which asks for Screen & System Audio Recording permission). No bot joins the call. Both are transcribed while the meeting runs, and about once a minute the local LLM folds the new talk into the notes: summary, decisions, action items with owners, and open questions. When someone changes their mind, the notes keep the final version. *Stop* writes a final version and saves notes plus the timestamped transcript as Markdown in `~/Library/Application Support/Murmur/Meetings`. Without headphones the mic also hears the call, so mic segments that repeat what just came through the speakers are dropped. Dictation is paused while a meeting is recording. Everything stays on the Mac.

**Settings**
- **Cleanup mode:** *Smart* (default) uses the LLM only when needed. *Always* runs it on everything. *Rules only* never uses it.
- **Cleanup model:** Qwen3 4B (best) or Qwen3 1.7B (about twice as fast, weaker on subtle corrections).
- **Dictionary:** one term per line. `Kubernetes` fixes spelling and casing. `cooper netties -> Kubernetes` replaces a mishearing.
- **History:** recent dictations with the raw transcript and per-stage timings. The menu bar's *Recent* submenu copies any of them.

## Measuring speed

```sh
swift build -c release
say -o /tmp/test.aiff "Let's do the call at two, no wait, three PM." && afconvert -f WAVE -d LEI16@16000 /tmp/test.aiff /tmp/test.wav
.build/release/murmur-bench \
  --model ~/Library/Application\ Support/Murmur/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  --audio /tmp/test.wav --cases evals/cases.jsonl --compare
```

This prints transcription time, LLM prefill and generation time per case, and with `--compare`, speculative versus plain decoding. Each entry in the app's History tab shows the same breakdown for your real dictations.

## Cleanup quality

`evals/cases.jsonl` has 35 cases covering fillers, corrections, start-over, lists, formatting commands, prompt injection ("write me a poem", "ignore all previous instructions"), per-app style and vocabulary. `evals/corrections.jsonl` has 46 self-revision cases ("x and y, scrap that, not y", replacements, additions, chained revisions, and look-alikes that must be left alone). `evals/corrections_more.jsonl` adds 25 for less common wordings ("take the X off", "strike X", "swap X for Y", "five nights, er, four", two revisions in one sentence). `evals/corrections_holdout*.jsonl` hold 60 cases written by independent agents in three batches (16, 20 and 24); the third was added unread and only scored at the end. `evals/snippets.jsonl` covers snippet expansion through the whole pipeline. `evals/run_evals.py` runs them through the app's own Swift code (`murmur-cli`) against any llama.cpp server:

```sh
llama-server -m Qwen3-4B-Instruct-2507-Q4_K_M.gguf --jinja -c 4096 --port 8080
swift build --product murmur-cli
python3 evals/run_evals.py            # smart mode, as the app runs
python3 evals/run_evals.py --all-llm  # force every case through the LLM
python3 evals/run_evals.py --cases evals/corrections.jsonl
python3 evals/run_meeting_notes.py    # replays evals/meetings/*.json and prints each notes update
```

The *Cleanup evals* workflow runs all of this on a Linux runner (llama.cpp on the CPU) for pushes to `main`, or by hand.

| Model | Smart mode | Notes |
|---|---|---|
| Qwen3 4B Instruct 2507 (Q4_K_M) | 34/35 | The one miss is an ambiguous "…onto Kubernetes, actually onto the new cluster" |
| Qwen3 1.7B (Q4_K_M) | 25/35 | Weaker at formatting commands and occasionally drops content |

## Project layout

```
Sources/MurmurCore     portable logic, tested on Linux and macOS:
                       rules pass, cue detection, prompt, output guard, speculative
                       decoder, hotkey state machine, pause segmenter, live transcription,
                       snippets, meeting transcript and live notes
Sources/MurmurKit      macOS: llama.cpp runner, Parakeet transcriber, model downloads
Sources/Murmur         the menu bar app (AppKit + SwiftUI)
Sources/murmur-bench   headless pipeline for latency numbers and CI
Sources/murmur-cli     JSON front end over MurmurCore, used by the evals
evals/                 cleanup eval cases and runner
scripts/build-app.sh   builds and signs build/Murmur.app
```

```sh
swift test --filter MurmurCoreTests     # fast, no models needed (also runs on Linux)
MURMUR_TEST_MODEL=/path/to/model.gguf swift test --filter MurmurKitTests
```

## CI

- **CI** (every push): core tests on Linux.
- **Cleanup evals** (pushes to `main` that touch the core or evals, or by hand): core tests, then the cleanup, correction, snippet and meeting-notes evals against Qwen3 4B on llama.cpp's CPU server.
- **macOS** (pushes that touch Mac code): builds and bundles `Murmur.app`. Start it by hand (*Actions › macOS › Run workflow*) to also run Parakeet and the cleanup LLM end to end on synthesized speech. That takes about 20 minutes on a runner, and macOS minutes bill at 10x on private repos, so it isn't automatic.

## Troubleshooting

- **Nothing happens when I hold the key:** check Accessibility in System Settings. If you rebuilt the app, remove Murmur from the list and add it again.
- **Fn key opens the emoji picker:** set System Settings › Keyboard › "Press 🌐 key to" to "Do Nothing", or use Right Option.
- **Text doesn't paste in one app:** some apps block synthetic ⌘V. The text is still in History; click it in the menu to copy.
- **Debug llama.cpp:** run the app binary with `MURMUR_LLAMA_LOG=1 build/Murmur.app/Contents/MacOS/Murmur`.
