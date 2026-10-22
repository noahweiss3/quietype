#!/usr/bin/env python3
"""Replays recorded meetings through Quietype's live meeting notes and checks the final notes.

`quietype-cli notes-replay` runs the app's own notes writer from QuietypeCore on each meeting in
evals/meetings/: the update schedule, the prompts, splitting a long backlog into several
requests, the retry after a bad answer, the final pass over the whole transcript (and finishing
incrementally when that pass fails), and the check that an answer is complete notes. Whenever
the writer needs the model, this script sends the request to a llama.cpp server and hands the
answer back. It refuses what the app refuses: a prompt too long for the notes context, and an
answer cut off at the output limit.

The meeting is replayed in meeting time. As in the app, the schedule is checked every 5 seconds
and backs off after a failed update; a segment counts as heard once it ends, and the meeting
ends with its last segment. Every version of the notes is printed, so you can see what someone
would have seen during the call. One simplification: an update takes no meeting time. In the
app a slow update delays the next check, so a slow machine makes fewer, larger updates.

Each meeting's "checks" list substrings the final notes must or must not contain, overall and
per section. Every notes update must also succeed. evals/README.md describes the file format.

    swift build --product quietype-cli
    python3 evals/run_meeting_notes.py
    python3 evals/run_meeting_notes.py --only acme-renewal-call
    python3 evals/run_meeting_notes.py --check-baseline     # what CI runs

Exit status: 0 when every check passes, or with --check-baseline when every failing check is a
known failure in evals/baselines.json; 1 otherwise; 2 when the harness itself fails.
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import harness
from harness import (
    DEFAULT_SERVER,
    EVALS,
    HarnessError,
    LlamaServer,
    Watchdog,
    is_number,
    load_baselines,
    quietype_cli_path,
    report_scores,
    run_manifest,
    string_list,
    update_baselines,
    write_results,
)

SUITE = "meetings"
MEETING_KEYS = {"id", "title", "segments", "reference", "checks"}
SEGMENT_KEYS = {"id", "speaker", "start", "end", "text"}
CHECK_KEYS = {"must", "must_not", "sections"}
# LlamaGenerator refuses a prompt unless prompt + max_tokens + this margin fits the context.
CONTEXT_MARGIN = 16


def load_meetings(directory, only):
    paths = sorted(Path(directory).glob("*.json"))
    if not paths:
        raise HarnessError(f"no meeting fixtures (*.json) in {directory}")
    meetings, seen = [], set()
    for path in paths:
        try:
            meeting = json.loads(path.read_text())
        except json.JSONDecodeError as e:
            raise HarnessError(f"{path}: not valid JSON ({e})") from e
        validate(meeting, path)
        if meeting["id"] in seen:
            raise HarnessError(f"{path}: duplicate meeting id {meeting['id']!r}")
        seen.add(meeting["id"])
        meeting["path"] = path
        meetings.append(meeting)
    if only:
        wanted = [i.strip() for i in only.split(",") if i.strip()]
        unknown = [i for i in wanted if i not in seen]
        if unknown:
            raise HarnessError(f"no meeting fixture with id {', '.join(unknown)} in {directory}")
        meetings = [m for m in meetings if m["id"] in wanted]
    return meetings


def validate(meeting, path):
    def bad(message):
        raise HarnessError(f"{path}: {message}")

    if not isinstance(meeting, dict) or not isinstance(meeting.get("id"), str) or not meeting["id"]:
        bad("a meeting needs a non-empty string id")
    if set(meeting) - MEETING_KEYS:
        bad(f"unknown keys {sorted(set(meeting) - MEETING_KEYS)}")
    if "title" in meeting and not isinstance(meeting["title"], str):
        bad("title must be a string")
    segments = meeting.get("segments")
    if not isinstance(segments, list) or not segments:
        bad("a meeting needs a non-empty list of segments")
    previous_start = 0
    for segment in segments:
        if not isinstance(segment, dict) or set(segment) != SEGMENT_KEYS or segment["speaker"] not in ("me", "others"):
            bad(f"each segment needs exactly {sorted(SEGMENT_KEYS)}, with speaker 'me' or 'others': {segment}")
        # quietype-cli decodes ids as Swift Ints.
        if not isinstance(segment["id"], int) or isinstance(segment["id"], bool):
            bad(f"segment ids must be whole numbers: {segment}")
        if not isinstance(segment["text"], str) or not segment["text"].strip():
            bad(f"each segment needs some text: {segment}")
        # The replay hears a segment when it ends and ends the meeting with the last one, so
        # times must be real and the segments in the order they started.
        start, end = segment["start"], segment["end"]
        if not is_number(start) or not is_number(end) or not 0 <= start < end:
            bad(f"a segment needs times with 0 <= start < end, in seconds: {segment}")
        if start < previous_start:
            bad(f"segments must be in order of their start times: {segment}")
        previous_start = start
    if len({s["id"] for s in segments}) != len(segments):
        bad("segment ids must be unique")
    checks = meeting.get("checks")
    if not isinstance(checks, dict):
        bad("a meeting needs checks")
    if set(checks) - CHECK_KEYS:
        bad(f"unknown keys in checks: {sorted(set(checks) - CHECK_KEYS)}")
    def strings(value, what):
        try:
            string_list(value, what, allow_empty=True)
        except HarnessError as e:
            bad(str(e))

    for key in ("must", "must_not"):
        if key in checks:
            strings(checks[key], f"checks.{key}")
    sections_spec = checks.get("sections", {})
    if not isinstance(sections_spec, dict):
        bad("checks.sections must map section names to checks")
    for name, rules in sections_spec.items():
        if not name.strip() or not isinstance(rules, dict) or set(rules) - {"must", "must_not"}:
            bad(f"checks.sections.{name} may only have must and must_not")
        for key, value in rules.items():
            strings(value, f"checks.sections.{name}.{key}")
        if not any(rules.values()):
            bad(f"checks.sections.{name} has no checks")
    if not checks.get("must") and not checks.get("must_not") and not sections_spec:
        bad("a meeting needs at least one check")


def clock(seconds):
    return f"{int(seconds) // 60:02d}:{int(seconds) % 60:02d}"


def answer(server, request):
    """Gets the model's answer to one notes request, or the error the app's runner would raise."""
    record = {"prompt_tokens": server.count_tokens(server.render(request["messages"]), add_special=True)}
    if record["prompt_tokens"] + request["max_tokens"] + CONTEXT_MARGIN >= request["context_tokens"]:
        record["outcome"] = "prompt too long"
        reply = {"error": f"the prompt is too long for the notes context ({record['prompt_tokens']} tokens)"}
        return record, reply
    result = server.chat(request["messages"], request["max_tokens"])
    record.update(seconds=round(result.seconds, 1), output_tokens=result.tokens, answer=result.text)
    if result.truncated:
        record["outcome"] = "cut off"
        return record, {"error": f"the answer hit the {request['max_tokens']}-token limit before it finished"}
    record["outcome"] = "answered"
    return record, {"output": result.text}


def replay(meeting, server):
    """Runs one meeting through `quietype-cli notes-replay`; returns its updates and final notes."""
    proc = subprocess.Popen([quietype_cli_path(), "notes-replay"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            text=True, bufsize=1)
    # Armed only while waiting on quietype-cli, so the model's time doesn't count against it.
    watchdog = Watchdog(proc, harness.CLI_TIMEOUT)

    def send(obj):
        with watchdog:
            proc.stdin.write(json.dumps(obj) + "\n")
            proc.stdin.flush()

    updates, requests, done = [], [], None
    try:
        send({"id": meeting["id"], "segments": meeting["segments"]})
        while True:
            with watchdog:
                line = proc.stdout.readline()
            if not line:
                break
            try:
                event = json.loads(line)
            except json.JSONDecodeError as e:
                raise HarnessError(f"quietype-cli notes-replay printed something that isn't JSON: {e}") from e
            if event.get("event") == "generate":
                record, reply = answer(server, event)
                requests.append(record)
                send(reply)
            elif event.get("event") == "update":
                event["requests"], requests = requests, []
                updates.append(event)
                print_update(len(updates), event)
            elif event.get("event") == "done":
                done = event
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass  # it already exited; the status below says why
        try:
            status = proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            status = proc.wait()
    if watchdog.fired:
        raise HarnessError(f"quietype-cli notes-replay went {harness.CLI_TIMEOUT}s without answering "
                           f"on {meeting['id']}")
    if status != 0 or done is None:
        raise HarnessError(f"quietype-cli notes-replay failed on {meeting['id']} (exit status {status})")
    return updates, done["notes"]


def print_update(number, update):
    kind = " (final)" if update["final"] else ""
    seconds = sum(r.get("seconds", 0) for r in update["requests"])
    status = "ok" if update["ok"] else f"FAILED: {update.get('error') or 'no notes'}"
    outcomes = ", ".join(r["outcome"] for r in update["requests"]) or "no requests"
    print(f"--- update {number} at {clock(update['at'])}{kind}: {outcomes}, {seconds:.1f}s, {status}")
    print(update["notes"] or "(no notes yet)")


def sections(notes):
    """Splits notes into {"summary": "...", "decisions": "...", ...}, keyed in lower case."""
    out, current = {}, None
    for line in notes.splitlines():
        if line.startswith("## "):
            current = line[3:].strip().lower()
            out[current] = ""
        elif current:
            out[current] += line + "\n"
    return out


def check(notes, spec, updates):
    """The meeting's check results. Each has an id that depends only on the fixture, which
    baselines.json uses to name known failures, and a label for the report."""
    results = []

    def add(check_id, ok, label=None):
        results.append({"id": check_id, "check": label or check_id, "ok": ok})

    add("every notes update succeeded", all(u["ok"] for u in updates), f"all {len(updates)} notes updates succeeded")
    lowered = notes.lower()
    for s in spec.get("must", []):
        add(f"notes mention {s!r}", s.lower() in lowered)
    for s in spec.get("must_not", []):
        add(f"notes don't mention {s!r}", s.lower() not in lowered)
    parts = sections(notes)
    for name, rules in spec.get("sections", {}).items():
        body = parts.get(name.lower())
        missing = "" if body is not None else f" (no {name} section)"
        for s in rules.get("must", []):
            check_id = f"{name} mention {s!r}"
            add(check_id, body is not None and s.lower() in body.lower(), check_id + missing)
        for s in rules.get("must_not", []):
            check_id = f"{name} don't mention {s!r}"
            add(check_id, body is not None and s.lower() not in body.lower(), check_id + missing)
    return results


def outcomes(report):
    """{"meeting-id: check id": passed} over every meeting, the identities baselines.json uses."""
    return {f"{m['id']}: {c['id']}": c["ok"] for m in report for c in m["checks"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--server", default=DEFAULT_SERVER, help=f"llama.cpp server URL (default {DEFAULT_SERVER})")
    parser.add_argument("--meetings", default=str(EVALS / "meetings"), help="directory of meeting fixtures")
    parser.add_argument("--only", help="comma-separated meeting ids to run")
    parser.add_argument("--no-think", action="store_true",
                        help="turn off thinking, for hybrid models such as Qwen3 1.7B (the app does the same)")
    parser.add_argument("--check-baseline", action="store_true",
                        help="exit non-zero only if a check fails that evals/baselines.json doesn't list as a "
                             "known failure, or the baseline is out of date")
    parser.add_argument("--update-baseline", action="store_true",
                        help="record this run's failures as the known failures in evals/baselines.json")
    parser.add_argument("--print-json", action="store_true", help="also print every result as a JSON line")
    args = parser.parse_args()
    if args.only and (args.check_baseline or args.update_baseline):
        parser.error("baselines are for every meeting; drop --only")

    meetings = load_meetings(args.meetings, args.only)
    baselines = load_baselines([SUITE]) if args.check_baseline else {}
    server = LlamaServer(args.server, no_think=args.no_think)
    server.check()
    manifest = run_manifest(server)

    report = []
    for meeting in meetings:
        print(f"### {meeting.get('title', meeting['id'])} ({len(meeting['segments'])} segments)")
        started = time.time()
        updates, notes = replay(meeting, server)
        results = check(notes, meeting["checks"], updates)
        for line in results:
            print(("PASS " if line["ok"] else "FAIL ") + line["check"])
        print(f"{meeting['id']}: {sum(r['ok'] for r in results)}/{len(results)} checks passed, "
              f"{time.time() - started:.0f}s\n")
        report.append({"id": meeting["id"], "title": meeting.get("title"), "reference": meeting.get("reference"),
                       "checks": results, "notes": notes,
                       "transcript": [f"[{clock(s['start'])}] {'You' if s['speaker'] == 'me' else 'Others'}: "
                                      f"{s['text']}" for s in meeting["segments"]],
                       "updates": updates})

    scores = [(SUITE, outcomes(report))]
    write_results(SUITE, report, args.print_json, manifest, fixtures=[m["path"] for m in meetings],
                  failed=[i for i, ok in scores[0][1].items() if not ok])
    if not baselines and not args.only:
        try:
            baselines = load_baselines()  # for the table only
        except HarnessError:
            pass
    failing = report_scores(scores, baselines, "checks")
    if args.update_baseline:
        update_baselines(scores)
    if args.check_baseline:
        return 1 if failing else 0
    return 0 if all(scores[0][1].values()) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except HarnessError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(2)
