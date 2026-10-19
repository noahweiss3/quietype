#!/usr/bin/env python3
"""Replay meetings through Murmur's live notes (schedule + prompt + sanitizer) against a llama.cpp server.

Each meeting file can carry "checks": substrings the final notes must or must not contain, overall
and per section ("Action items", "Decisions", ...). The script exits non-zero if any check fails.

Each meeting in evals/meetings/*.json is replayed in simulated real time: murmur-cli decides when the
app would refresh the notes and with which transcript lines, this script sends each request to the
model, and murmur-cli validates the answer. Every intermediate version of the notes is printed, so
you can see what someone would have seen during the meeting.

    llama-server -m Qwen3-4B-Instruct-2507-Q4_K_M.gguf --jinja -c 8192 --port 8080
    swift build --product murmur-cli
    python3 evals/run_meeting_notes.py
"""

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_evals import ROOT, chat, cli  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default="http://127.0.0.1:8080")
    parser.add_argument("--meetings", default=str(ROOT / "evals/meetings"))
    parser.add_argument("--print-json", action="store_true")
    args = parser.parse_args()

    report = []
    for path in sorted(Path(args.meetings).glob("*.json")):
        meeting = json.loads(path.read_text())
        segments = {s["id"]: s for s in meeting["segments"]}
        plan = cli(["notes-plan"], [{"id": meeting["id"], "segments": meeting["segments"]}])[0]
        notes = ""
        snapshots = []
        carried = []  # lines from a rejected answer; the app keeps them pending for the next update
        print(f"### {meeting['title']} ({len(plan['updates'])} updates)")
        for index, update in enumerate(plan["updates"]):
            new = [segments[i] for i in update["segments"]]
            batch = new if update.get("complete") else carried + new
            known = [s for s in meeting["segments"] if s["end"] <= update["at"]]
            started = time.time()
            # Like the app: a rejected answer is asked for once more, requesting merged notes.
            for retry in (False, True):
                prep = cli(["notes-prep"], [{"id": meeting["id"], "notes": notes, "segments": batch, "known": known,
                                            "final": update["final"], "complete": update.get("complete", False),
                                            "retry": retry}])[0]
                output, seconds, _ = chat(args.server, prep["messages"], prep["max_tokens"], no_think=False)
                done = cli(["notes-finish"], [{"id": meeting["id"], "previous": notes, "output": output}])[0]
                if done["accepted"]:
                    break
            notes = done["notes"]
            carried = [] if done["accepted"] or update.get("complete") else batch
            stamp = f"{int(update['at']) // 60:02d}:{int(update['at']) % 60:02d}"
            kind = " (final, whole transcript)" if update.get("complete") else " (final)" if update["final"] else ""
            print(f"--- update {index + 1} at {stamp}{kind}, "
                  f"{len(batch)} new lines, {seconds:.1f}s, accepted={done['accepted']}")
            print(notes)
            snapshots.append({"at": update["at"], "final": update["final"], "complete": update.get("complete", False),
                              "retried": retry, "new_lines": len(batch),
                              "seconds": round(time.time() - started, 1), "accepted": done["accepted"],
                              "notes": notes, "raw": None if done["accepted"] else output})
        results = check(notes, meeting.get("checks", {}))
        for line in results:
            print(("PASS " if line["ok"] else "FAIL ") + line["check"])
        report.append({"id": meeting["id"], "title": meeting["title"], "reference": meeting.get("reference"),
                       "checks": results,
                       "transcript": [f"[{int(s['start']) // 60:02d}:{int(s['start']) % 60:02d}] "
                                      f"{'You' if s['speaker'] == 'me' else 'Others'}: {s['text']}"
                                      for s in meeting["segments"]],
                       "snapshots": snapshots})
        print()

    out_dir = ROOT / "evals/results"
    out_dir.mkdir(exist_ok=True)
    (out_dir / "meeting_notes.json").write_text(json.dumps(report, indent=2))
    if args.print_json:
        print("=== RESULTS meeting_notes ===")
        for entry in report:
            print(json.dumps(entry, ensure_ascii=False))
        print("=== END meeting_notes ===")
    accepted = all(s["accepted"] for m in report for s in m["snapshots"])
    checked = all(c["ok"] for m in report for c in m["checks"])
    print(f"checks: {sum(c['ok'] for m in report for c in m['checks'])}/{sum(len(m['checks']) for m in report)} passed")
    return 0 if accepted and checked else 1


def sections(notes):
    """Splits notes into {"Summary": "...", "Decisions": "...", ...}."""
    out, current = {}, None
    for line in notes.splitlines():
        if line.startswith("## "):
            current = line[3:].strip()
            out[current] = ""
        elif current:
            out[current] += line + "\n"
    return out


def check(notes, spec):
    results = []
    lowered = notes.lower()
    for s in spec.get("must", []):
        results.append({"check": f"notes mention {s!r}", "ok": s.lower() in lowered})
    for s in spec.get("must_not", []):
        results.append({"check": f"notes don't mention {s!r}", "ok": s.lower() not in lowered})
    parts = {k.lower(): v.lower() for k, v in sections(notes).items()}
    for name, rules in spec.get("sections", {}).items():
        body = parts.get(name.lower(), "")
        for s in rules.get("must", []):
            results.append({"check": f"{name} mention {s!r}", "ok": s.lower() in body})
        for s in rules.get("must_not", []):
            results.append({"check": f"{name} don't mention {s!r}", "ok": s.lower() not in body})
    return results


if __name__ == "__main__":
    sys.exit(main())
