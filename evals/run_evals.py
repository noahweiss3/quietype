#!/usr/bin/env python3
"""Scores Quietype's dictation cleanup on the eval cases, using the app's own code and a llama.cpp server.

Each case goes through the steps the app runs on a dictation. All of them except the model call
happen in quietype-cli, a small front end over the app's QuietypeCore library:

1. `quietype-cli prep`: the rules pass, and the request (system prompt, examples, style,
   vocabulary) the app would send to the model.
2. If the rules pass found something only the model handles (a correction, a list, a formatting
   command), or always with --all-llm: the request goes to the llama.cpp server at temperature 0.
   The output limit is the app's: the server counts the request's tokens the way the app does,
   and `quietype-cli budget` turns the count into max_tokens, so the formula lives only in Swift.
3. `quietype-cli finish`: the output guard (an answer that goes off-script falls back to the rules
   text), the personal dictionary and snippet expansion.

The final text is then checked against the case's assertions.

Where this differs from the app:
- The app decodes greedily on the Mac; the server is greedy too at temperature 0, but a
  different llama.cpp build or backend (the CPU in CI rather than Metal) can pick a different
  token now and then, so a case or two may differ.
- An answer cut off at the output limit fails its case. The app never gets as far as the output
  guard with one: its cleaner treats a cut-off answer as a failed cleanup, and the dictation
  falls back to the rules pass. Scoring that fallback would hide a limit that is too tight, which
  is a bug to fix.
- The app also refuses a dictation too long for its cleanup context; no case comes close.

Case files are JSON lines in evals/cases/, one case per line. evals/README.md describes the keys
and assertions; a malformed case is a harness error, never a pass.

    swift build --product quietype-cli
    python3 evals/run_evals.py                          # evals/cases/cleanup.jsonl
    python3 evals/run_evals.py --all                    # every suite in evals/cases/
    python3 evals/run_evals.py --cases evals/cases/holdout.jsonl --only holdout-betteryet-meeting-time
    python3 evals/run_evals.py --all --check-baseline   # what CI runs

Exit status: 0 when every case passes, or with --check-baseline when every failing case is a known
failure in evals/baselines.json; 1 otherwise; 2 when the harness itself fails.
"""

import argparse
import json
import sys
from pathlib import Path

from harness import (
    DEFAULT_SERVER,
    EVALS,
    HarnessError,
    LlamaServer,
    cli,
    load_baselines,
    report_scores,
    run_manifest,
    string_list,
    update_baselines,
    write_results,
)

CASES = EVALS / "cases"
# The order --all runs the suites in; any other file in evals/cases/ follows, alphabetically.
SUITE_ORDER = ["cleanup", "corrections", "corrections-extended", "holdout", "unseen", "snippets"]

ASSERTIONS = ["expect", "must", "must_any", "must_case", "must_not", "must_not_exact"]
KNOWN_KEYS = {"id", "input", "category", "intent", "style", "vocabulary", "snippets", *ASSERTIONS}
STYLES = {"standard", "chat", "email", "code"}


def suite_paths(args):
    if args.all:
        found = {p.stem: p for p in CASES.glob("*.jsonl")}
        order = [s for s in SUITE_ORDER if s in found] + sorted(set(found) - set(SUITE_ORDER))
        return [found[s] for s in order]
    return [Path(p) for p in args.cases or [CASES / "cleanup.jsonl"]]


def load_suite(path):
    """Reads one case file and rejects anything that would make a score meaningless."""
    if not path.is_file():
        raise HarnessError(f"no case file at {path}")
    cases, seen = [], set()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        where = f"{path}:{number}"
        try:
            case = json.loads(line)
        except json.JSONDecodeError as e:
            raise HarnessError(f"{where}: not valid JSON ({e})") from e
        validate_case(case, where)
        if case["id"] in seen:
            raise HarnessError(f"{where}: duplicate id {case['id']!r}")
        seen.add(case["id"])
        cases.append(case)
    return cases


def validate_case(case, where):
    """Rejects a case whose fields have the wrong shape rather than scoring it oddly: a string
    where a list belongs would otherwise be checked one character at a time."""
    def bad(message):
        raise HarnessError(f"{where}: {message}")

    if not isinstance(case, dict):
        bad("a case must be a JSON object")
    if not isinstance(case.get("id"), str) or not case["id"] or not isinstance(case.get("input"), str) \
            or not case["input"].strip():
        bad("a case needs a non-empty string id and input")
    name = case["id"]
    unknown = set(case) - KNOWN_KEYS
    if unknown:
        bad(f"unknown keys {sorted(unknown)} in {name!r}")
    for key in ("category", "intent", "expect"):
        if key in case and not isinstance(case[key], str):
            bad(f"{name!r}: {key} must be a string")
    # Checked as a string first: a list or object isn't hashable, so the membership test would raise.
    if "style" in case and (not isinstance(case["style"], str) or case["style"] not in STYLES):
        bad(f"{name!r}: style must be one of {', '.join(sorted(STYLES))}")
    snippets = case.get("snippets", [{"trigger": "-", "text": "-"}])
    if not isinstance(snippets, list) or not snippets or not all(
            isinstance(s, dict) and set(s) == {"trigger", "text"} and all(isinstance(v, str) and v for v in s.values())
            for s in snippets):
        bad(f"{name!r}: snippets must be a non-empty list of {{\"trigger\", \"text\"}} with non-empty strings")
    try:
        for key in ("vocabulary", *ASSERTIONS[1:]):
            if key in case:
                string_list(case[key], key, nested=key == "must_any")
    except HarnessError as e:
        bad(f"{name!r}: {e}")
    if not any(k in case for k in ASSERTIONS):
        bad(f"{name!r} has no assertions ({', '.join(ASSERTIONS)})")


def norm(text):
    return " ".join(text.split())


def score(case, output):
    """The case's failed assertions, as readable lines."""
    failures = []
    lowered = output.lower()
    if "expect" in case and norm(output) != norm(case["expect"]):
        failures.append(f"expected {case['expect']!r}")
    for s in case.get("must", []):
        if s.lower() not in lowered:
            failures.append(f"missing {s!r}")
    for options in case.get("must_any", []):
        if not any(s.lower() in lowered for s in options):
            failures.append(f"missing all of {options!r}")
    for s in case.get("must_case", []):
        if s not in output:
            failures.append(f"missing {s!r} (case-sensitive)")
    for s in case.get("must_not", []):
        if s.lower() in lowered:
            failures.append(f"contains {s!r}")
    for s in case.get("must_not_exact", []):
        if output.strip() == s:
            failures.append(f"is exactly {s!r}")
    return failures


# What run_suite reads from each quietype-cli answer, as (description, check) per key. Checked
# before anything is indexed, so an older or broken quietype-cli is a harness error that names the
# problem rather than a KeyError, or a case scored on half an answer.


def is_messages(value):
    return isinstance(value, list) and bool(value) and all(
        isinstance(m, dict) and isinstance(m.get("role"), str) and isinstance(m.get("content"), str)
        for m in value) and value[-1]["role"] == "user"


PREP_FIELDS = {
    "rules_text": ("a string", lambda v: isinstance(v, str)),
    "cues": ("a list of strings", lambda v: isinstance(v, list) and all(isinstance(c, str) for c in v)),
    "needs_llm": ("true or false", lambda v: isinstance(v, bool)),
    "messages": ("a non-empty list of {role, content} strings ending with the user's", is_messages),
}
BUDGET_FIELDS = {
    "max_tokens": ("a positive whole number", lambda v: isinstance(v, int) and not isinstance(v, bool) and v > 0),
}
FINISH_FIELDS = {
    "result": ("an object with a string text and path",
               lambda v: isinstance(v, dict) and isinstance(v.get("text"), str) and isinstance(v.get("path"), str)),
}


def cli_by_id(command, items, fields):
    """Runs a quietype-cli command over `items` and returns its answers keyed by id, after checking
    that there is exactly one answer per item and that each has `fields` in the expected shape."""
    sent = {item["id"] for item in items}
    answers = {}
    for answer in cli(command, items):
        if not isinstance(answer, dict) or not isinstance(answer.get("id"), str):
            raise HarnessError(f"quietype-cli {command} printed an answer without an id: {json.dumps(answer)[:200]}")
        name = answer["id"]
        if name not in sent:
            raise HarnessError(f"quietype-cli {command} answered {name!r}, which it wasn't asked about")
        if name in answers:
            raise HarnessError(f"quietype-cli {command} answered {name!r} twice")
        for key, (shape, valid) in fields.items():
            if key not in answer or not valid(answer[key]):
                raise HarnessError(f"quietype-cli {command}: {key} for {name!r} must be {shape}, "
                                   f"not {json.dumps(answer.get(key))[:200]}")
        answers[name] = answer
    missing = [item["id"] for item in items if item["id"] not in answers]
    if missing:
        raise HarnessError(f"quietype-cli {command} returned no result for {', '.join(missing)}")
    return answers


def template_tail(server, prep):
    """What the chat template puts after the per-dictation text: the end of the user turn and the
    assistant header. The app counts these tokens as part of each dictation."""
    marker = prep.get("content_marker")
    if not isinstance(marker, str) or not marker:
        raise HarnessError("quietype-cli prep didn't print content_marker, so it is older than this script. "
                           "Rebuild it with `swift build --product quietype-cli`.")
    rendered = server.render(prep["messages"][:-1] + [{"role": "user", "content": marker}])
    if marker not in rendered:
        raise HarnessError("the server's chat template dropped the content marker; can't count tokens like the app")
    return rendered.split(marker, 1)[1]


def ask_model(server, cases, prepped):
    """Sends the cases that need the model, with the app's output limit. Returns {id: Answer}."""
    if not cases:
        return {}
    tail = template_tail(server, prepped[cases[0]["id"]])
    counts = [{"id": c["id"], "input_tokens": server.count_tokens(prepped[c["id"]]["messages"][-1]["content"] + tail)}
              for c in cases]
    limits = cli_by_id("budget", counts, BUDGET_FIELDS)
    return {c["id"]: server.chat(prepped[c["id"]]["messages"], limits[c["id"]]["max_tokens"]) for c in cases}


def run_suite(name, cases, server, all_llm):
    prepped = cli_by_id("prep", [
        {k: c[k] for k in ("id", "input", "style", "vocabulary", "snippets") if k in c} for c in cases], PREP_FIELDS)
    # Like the app: the model only sees a dictation the rules pass left something in.
    needs_model = [c for c in cases if (all_llm or prepped[c["id"]]["needs_llm"]) and prepped[c["id"]]["rules_text"]]
    answers = ask_model(server, needs_model, prepped)

    finish = []
    for case in cases:
        item = {k: case[k] for k in ("id", "input", "style", "vocabulary", "snippets") if k in case}
        item["mode"] = "always" if all_llm else "smart"
        if case["id"] in answers:
            item["llm_output"] = answers[case["id"]].text
        finish.append(item)
    results = {i: answer["result"] for i, answer in cli_by_id("finish", finish, FINISH_FIELDS).items()}

    print(f"### {name} ({len(cases)} cases)")
    report, by_category = [], {}
    for case in cases:
        result, prep, answer = results[case["id"]], prepped[case["id"]], answers.get(case["id"])
        failures = score(case, result["text"])
        if answer and answer.truncated:
            failures.insert(0, f"the model's answer was cut off at the app's limit of {answer.max_tokens} tokens")
        ok = not failures
        tally = by_category.setdefault(case.get("category", "other"), [0, 0])
        tally[0] += ok
        tally[1] += 1
        report.append({"suite": name, "id": case["id"], "category": case.get("category"), "style": case.get("style"),
                       "input": case["input"], "intent": case.get("intent", case.get("expect")),
                       "rules_text": prep["rules_text"], "cues": prep["cues"],
                       "llm_output": answer.text if answer else None,
                       "max_tokens": answer.max_tokens if answer else None,
                       "ok": ok, "path": result["path"], "output": result["text"], "failures": failures,
                       "note": result.get("note")})
        print(f"{'PASS' if ok else 'FAIL'} {case['id']:<34} [{result['path']}] {result['text']!r}")
        for f in failures:
            print(f"       {f}")
        if result.get("note"):
            print(f"       note: {result['note']}")

    passed = sum(r["ok"] for r in report)
    print(f"\n{name}: {passed}/{len(cases)} passed")
    print("by category: " + ", ".join(f"{k} {v[0]}/{v[1]}" for k, v in sorted(by_category.items())))
    if answers:
        seconds = [a.seconds for a in answers.values()]
        tokens = [a.tokens for a in answers.values()]
        print(f"model calls: {len(answers)}, mean {sum(seconds) / len(seconds):.2f}s, "
              f"mean {sum(tokens) / len(tokens):.0f} tokens")
    print()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--server", default=DEFAULT_SERVER, help=f"llama.cpp server URL (default {DEFAULT_SERVER})")
    parser.add_argument("--cases", action="append", metavar="PATH",
                        help="a case file to run; repeat for several (default evals/cases/cleanup.jsonl)")
    parser.add_argument("--all", action="store_true", help="run every case file in evals/cases/")
    parser.add_argument("--only", help="comma-separated case ids to run")
    parser.add_argument("--all-llm", action="store_true",
                        help="send every case to the model (the app's 'always' cleanup mode)")
    parser.add_argument("--no-think", action="store_true",
                        help="turn off thinking, for hybrid models such as Qwen3 1.7B (the app does the same)")
    parser.add_argument("--check-baseline", action="store_true",
                        help="exit non-zero only if a case fails that evals/baselines.json doesn't list as a "
                             "known failure, or the baseline is out of date")
    parser.add_argument("--update-baseline", action="store_true",
                        help="record this run's failures as the known failures in evals/baselines.json")
    parser.add_argument("--print-json", action="store_true", help="also print every result as a JSON line")
    args = parser.parse_args()
    if args.all and args.cases:
        parser.error("use either --all or --cases")
    if args.only and (args.check_baseline or args.update_baseline):
        parser.error("baselines are for whole suites; drop --only")

    suites, paths = [], {}
    for path in suite_paths(args):
        cases = load_suite(path)
        if path.stem in paths:
            raise HarnessError(f"two case files are named {path.stem}")
        suites.append((path.stem, cases))
        paths[path.stem] = path
    if args.only:
        wanted = [i.strip() for i in args.only.split(",") if i.strip()]
        known = {c["id"] for _, cases in suites for c in cases}
        unknown = [i for i in wanted if i not in known]
        if unknown:
            raise HarnessError(f"--only names cases that aren't in the selected files: {', '.join(unknown)}")
        suites = [(name, [c for c in cases if c["id"] in wanted]) for name, cases in suites]
        suites = [(name, cases) for name, cases in suites if cases]
    if not suites or not any(cases for _, cases in suites):
        raise HarnessError("no cases selected")
    # Checked before the (slow) run, so a missing baseline fails fast.
    baselines = load_baselines([name for name, _ in suites]) if args.check_baseline else {}

    server = LlamaServer(args.server, no_think=args.no_think)
    server.check()
    manifest = run_manifest(server)

    scores = []
    for name, cases in suites:
        report = run_suite(name, cases, server, args.all_llm)
        outcomes = {r["id"]: r["ok"] for r in report}
        write_results(name, report, args.print_json, manifest, fixtures=[paths[name]],
                      failed=[i for i, ok in outcomes.items() if not ok])
        scores.append((name, outcomes))

    if not baselines and not args.only:
        try:
            baselines = load_baselines()  # for the table only
        except HarnessError:
            pass
    failing = report_scores(scores, baselines, "cases")
    if args.update_baseline:
        update_baselines(scores)

    if args.check_baseline:
        return 1 if failing else 0
    return 0 if all(all(outcomes.values()) for _, outcomes in scores) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except HarnessError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(2)
