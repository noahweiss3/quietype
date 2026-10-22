# Evals

Quietype uses a local LLM in two places: cleaning up dictation and writing live meeting notes.
These evals measure both. They run the app's own Swift code (the rules pass, the prompts, the
output guard and the notes writer) through `quietype-cli`, a small JSON front end over
`QuietypeCore`, and get the model's answers from llama.cpp's `llama-server`. A score therefore
reflects what the app would paste or show, not a reimplementation of it.

## Suites

| File | Size | What it covers |
| --- | --- | --- |
| `cases/cleanup.jsonl` | 35 cases | The basics: fillers and stutters, sentences that must come through untouched, common corrections, "start over", lists, formatting commands, prompt injection ("write me a poem"), per-app style, vocabulary |
| `cases/corrections.jsonl` | 46 cases | Self-corrections: taking something back ("x and y, scrap that, not y"), replacements, additions, chained and partial revisions, lists, and look-alikes that must be left alone ("I want pizza, not wings") |
| `cases/corrections-extended.jsonl` | 25 cases | Less common wordings ("strike X", "take X off", "swap X for Y", "let's say"), corrections after a filler ("three days, uh, two days"), two revisions in one sentence |
| `cases/holdout.jsonl` | 60 cases | Corrections kept out of prompt tuning, to catch a prompt that has overfitted to the suites above |
| `cases/snippets.jsonl` | 12 cases | Snippet expansion through the whole pipeline, including a correction between two snippets and near misses that must not expand |
| `meetings/*.json` | 2 meetings | Live notes for a customer renewal call and a team launch sync: decisions versus proposals, owners of action items, numbers and dates, and corrections made during the call |

## Running locally

You need a Swift 6 toolchain, Python 3.9 or later (standard library only) and llama.cpp
(`brew install llama.cpp` on a Mac).

Start a server with the model the app uses. If Quietype has downloaded it, it is already on disk;
otherwise download
[Qwen3-4B-Instruct-2507-Q4_K_M.gguf](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf)
(2.5 GB).

```sh
llama-server -m "$HOME/Library/Application Support/Quietype/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf" \
  --jinja -c 8192 -np 1 --port 8080
```

Then, from the repository root:

```sh
swift build --product quietype-cli
python3 evals/run_evals.py                            # cases/cleanup.jsonl
python3 evals/run_evals.py --all                      # every file in cases/
python3 evals/run_evals.py --cases evals/cases/holdout.jsonl --only holdout-betteryet-meeting-time
python3 evals/run_meeting_notes.py                    # every meeting in meetings/
python3 evals/run_evals.py --all --check-baseline     # what CI runs, with the line below
python3 evals/run_meeting_notes.py --check-baseline
```

`make evals` runs every suite and the meetings and reports every failure, known or not. `make
evals-check` runs the same with `--check-baseline`: it is the acceptance gate CI applies, and
passes while the only failures are the known ones in `baselines.json`.

| Option | Meaning |
| --- | --- |
| `--cases PATH` | Run this case file; repeat the option for several. The default is `cases/cleanup.jsonl`. |
| `--all` | Run every file in `cases/`: cleanup, corrections, corrections-extended, holdout, snippets, then any other file alphabetically. |
| `--only ID,ID` | Run only these cases (or, for `run_meeting_notes.py`, these meetings). An id that doesn't exist is an error. |
| `--all-llm` | Send every case to the model, like the app's "Always" cleanup mode. By default only cases the rules pass can't finish go to the model, as in the app's default mode. |
| `--no-think` | Turn off thinking, for hybrid models such as Qwen3 1.7B; the app does the same for them. |
| `--check-baseline` | Exit non-zero only when a case fails that isn't a known failure, or the baseline is out of date (see below). |
| `--update-baseline` | Record this run's failures as the known failures in `baselines.json`. |
| `--print-json` | Also print every result as a JSON line between `=== RESULTS` and `=== END` markers. |
| `--server URL` | The llama.cpp server, `http://127.0.0.1:8080` by default. |

Each run prints every case with its output and failed assertions, then a table of scores. Full
results, including the rules-pass text and the raw model answer, go to `evals/results/<suite>.json`
(not checked in). Next to each goes `<suite>.manifest.json`, which records how the result was
made: the date, the exact command, the git commit (and whether the checkout had changes), the
model file and its SHA-256, the llama.cpp build and context size from the server's `/props`, the
fixtures' SHA-256 and the failing ids. The server doesn't report whether it runs on the CPU or the
GPU, so set `QUIETYPE_EVAL_BACKEND` (for example `QUIETYPE_EVAL_BACKEND="llama.cpp Metal"`) to
record that too.

Both scripts exit with 0 when everything passes, 1 when something fails (with
`--check-baseline`: when anything but a known failure fails) and 2 when the harness itself fails:
no server, `quietype-cli` not built, a malformed case file, or `quietype-cli` or the server not
answering in time.

## How a case runs

1. `quietype-cli prep` applies the rules pass and builds the request the app would send to the
   model: system prompt, examples, style and vocabulary.
2. If the rules pass left something only the model handles (a correction, a list, a formatting
   command), the request goes to the server at temperature 0, with the app's output limit. The
   server counts the tokens the app would count and `quietype-cli budget` turns that count into
   the limit, so the formula exists only in `QuietypeCore`.
3. `quietype-cli finish` runs the output guard (an answer that goes off-script, such as replying
   to the dictation or adding content, falls back to the rules text), the personal dictionary
   and snippet expansion.
4. The final text is checked against the case's assertions.

Three things differ from the app. The app decodes greedily on the Mac's GPU; the server is greedy
too at temperature 0, but a different llama.cpp build or backend can pick a different token now
and then. An answer cut off at the output limit fails its case, where the app would hand it to
the output guard: a limit that cuts off answers is a bug to fix rather than a result to score.

And the chat template is rendered by different code. `llama-server --jinja` runs the Jinja
template stored in the model file, while the app calls `llama_chat_apply_template`, llama.cpp's
built-in renderer, which recognises the template and formats it in code; for the Qwen3 models
both render ChatML. The output limit still matches because both sides count the same span of
tokens. The app renders its prompt with `CleanupPrompt.contentMarker` in place of the dictation
and counts the dictation's message plus everything the template puts after the marker: the end
of the user turn, the assistant header and, for Qwen3 1.7B, the empty think block it prefills.
The harness renders the same messages with the marker that `quietype-cli prep` reports as
`content_marker` through the server's `/apply-template` (with `--no-think` producing the same
empty think block), counts the message plus that tail with `/tokenize`, and `quietype-cli
budget` turns the count into the limit with the app's formula. A model whose Jinja and built-in
renderings differ would score with a different prompt and limit than the app uses, so compare
the two before evaluating a new model.

Meetings run through `quietype-cli notes-replay`, which drives the app's notes writer itself:
the update schedule, splitting a long backlog into several requests, the retry after a bad
answer, the final pass over the whole transcript and the fallback to finishing incrementally.
The script answers each request the writer makes and refuses what the app's runner refuses (a
prompt too long for the notes context, an answer cut off at the limit). The meeting is replayed
in meeting time, checking the schedule every 5 seconds as the app does; each update is taken to
be instant, whereas in the app a slow update delays the next one.

## Case format

One JSON object per line. `id` and `input` are required, and every case needs at least one
assertion (`expect` or one of the `must` keys). Unknown keys are an error, so a misspelled
assertion can't pass silently, and so is a field of the wrong type: each list must be a
non-empty list of distinct, non-empty strings, so `"must": "fourteenth"` is rejected rather than
checked one letter at a time.

| Key | Meaning |
| --- | --- |
| `id` | Unique within its file. |
| `category` | A grouping for the per-category tally, such as `replacement` or `keep`. |
| `input` | The transcript, as speech recognition would produce it. |
| `intent` | What the speaker meant to type. Documentation for readers; not scored. |
| `style` | `standard` (the default), `chat`, `email` or `code`: where the text is going. |
| `vocabulary` | Personal dictionary terms, as in Settings. |
| `snippets` | `[{"trigger": "my LinkedIn", "text": "https://…"}]`, as in Settings. |
| `expect` | The whole output, compared with whitespace collapsed. |
| `must` | Substrings the output must contain, ignoring case. |
| `must_any` | A list of lists: the output must contain at least one entry of each, ignoring case. Use it where a fact has several fair spellings, such as `[["fourteenth", "14"]]`. |
| `must_case` | Substrings the output must contain, matching case. |
| `must_not` | Substrings the output must not contain, ignoring case. |
| `must_not_exact` | Texts the whole output must not be, such as an answer to an injected question. |

```json
{"id": "ext-rep-my-bad", "category": "replacement", "input": "The dentist appointment is on the twelfth, my bad, the fourteenth.", "intent": "The dentist appointment is on the fourteenth.", "must": ["dentist", "fourteenth"], "must_not": ["twelfth", "my bad"]}
```

## Meeting format

Each file in `meetings/` is one meeting:

| Key | Meaning |
| --- | --- |
| `id`, `title` | A unique id, and a name for the report. |
| `segments` | The transcript: `[{"id", "speaker", "start", "end", "text"}]`, with `id` a whole number unique within the meeting, `speaker` `me` (the note-taker's microphone) or `others` (the call's audio) and times in seconds from the start. Segments are listed in order of `start`, and each needs `0 <= start < end` and some text; the two speakers' segments may overlap. |
| `reference` | What good notes would contain, for people reading the results. Not scored. |
| `checks.must`, `checks.must_not` | Substrings the final notes must or must not contain, ignoring case. |
| `checks.sections` | The same per section of the notes: `{"Action items": {"must": [...], "must_not": [...]}}`. A section that is missing fails its checks. |

Every notes update during the meeting must also succeed; that counts as one more check per
meeting. A meeting needs at least one check of its own.

## Adding a case

1. Choose the file: `cleanup` for general behaviour, `corrections` or `corrections-extended` for a
   self-correction, `snippets` for snippets. Leave `holdout` alone while working on the prompt:
   when a holdout case fails, fix the general pattern and add a similar case to another suite.
2. Write the `input` as the speaker would say it and the `intent` as they meant it. Assert what
   matters: the corrected fact with `must` or `must_any`, the abandoned one with `must_not`, and
   the words that have to survive. Prefer short substrings that hold under fair formatting
   choices ("4" rather than "4 PM").
3. Run it alone: `python3 evals/run_evals.py --cases evals/cases/corrections.jsonl --only <id>`.
4. A suite's size is part of its baseline, so rerun the suite in full with `--update-baseline`
   and commit `baselines.json` with the case. If the new case fails, it is recorded as a known
   failure; say so in the pull request.

## Baselines and CI

`.github/workflows/evals.yml` runs every suite and the meetings on a Linux runner's CPU, with the
same Swift toolchain as the rest of CI, for pull requests and pushes to `main` that touch
`evals/`, `QuietypeCore`, `quietype-cli` or the package's dependencies. Scores show on the run's
summary page, and the results and their manifests are uploaded as an artifact.

`baselines.json` records, per suite, its size (`total`) and the ids of the cases it is known to
fail (`known_failures`). For meetings the unit is a check, with ids such as `beta-launch-sync:
Decisions mention 'Thursday'`. With `--check-baseline` a run fails when:

- a case fails that isn't a known failure, even if another case started passing at the same time;
- the suite's size differs from `total`, or a listed id no longer exists.

A known failure that now passes is reported but doesn't fail the run; take it out of
`known_failures` (or rerun with `--update-baseline`) so that it can't regress unnoticed.

A suite may also list `flaky` ids: cases whose result differs between llama.cpp backends, since
the CPU build in CI can choose a different token than Metal now and then. They are reported but
never fail the run. Add a case there only after seeing it flip between backends with nothing else
changed; `--update-baseline` keeps the list as it is.

The harness has model-free tests of its own, which CI runs on every pull request with a lint of
the scripts: `make evals-test`, and `make lint`, which runs [ruff](https://docs.astral.sh/ruff/)
0.17.1, the version CI pins, through [pipx](https://pipx.pypa.io/) (`brew install pipx` on a
Mac, or `python3 -m pip install --user pipx`). Without pipx, `uvx ruff@0.17.1 check evals` runs
the same version.

## Current results

Qwen3 4B Instruct 2507 Q4_K_M on llama.cpp b11351 (Metal, MacBook Air M2), default (smart) cleanup mode, run 2026-10-21:

| Suite | Passed | Known failures |
| --- | --- | --- |
| cleanup | 35/35 | none |
| corrections | 45/46 | `keep-reported-speech` |
| corrections-extended | 22/25 | `ext-part-rephrase-mid`, `ext-keep-my-bad-apology`, `ext-list-take-off` |
| holdout | 52/60 | `holdout-minus-olives`, `holdout-rm-groceries-walnuts`, `holdout-partial-restart-mom`, `holdout-fast-bloodwork`, `holdout-garage-tools`, `holdout-shelf-boards`, `holdout-sitter-bedtime`, `holdout-brake-job` |
| snippets | 12/12 | none |
| meetings | 33/33 checks | none |

The failures fall into four groups: take-backs the model leaves in ("minus the olives", "cross
out the water"), wordings the rules pass doesn't yet send to the model ("that should be", "I
retract that"), restarts where the model also drops the greeting before them ("Hi Mom, I wanted
to ask if you, um, let me rephrase that"), and ordinary text read as a correction ("she said
scratch that", "my bad" as an apology).
