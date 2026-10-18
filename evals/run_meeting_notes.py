#!/usr/bin/env python3
"""Replay meetings through Murmur's live notes (schedule + prompt + sanitizer) against a llama.cpp server.

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
        print(f"### {meeting['title']} ({len(plan['updates'])} updates)")
        for index, update in enumerate(plan["updates"]):
            batch = [segments[i] for i in update["segments"]]
            prep = cli(["notes-prep"], [{"id": meeting["id"], "notes": notes, "segments": batch, "final": update["final"]}])[0]
            started = time.time()
            output, seconds, _ = chat(args.server, prep["messages"], prep["max_tokens"], no_think=False)
            done = cli(["notes-finish"], [{"id": meeting["id"], "previous": notes, "output": output}])[0]
            notes = done["notes"]
            stamp = f"{int(update['at']) // 60:02d}:{int(update['at']) % 60:02d}"
            print(f"--- update {index + 1} at {stamp}{' (final)' if update['final'] else ''}, "
                  f"{len(batch)} new lines, {seconds:.1f}s, accepted={done['accepted']}")
            print(notes)
            snapshots.append({"at": update["at"], "final": update["final"], "new_lines": len(batch),
                              "seconds": round(time.time() - started, 1), "accepted": done["accepted"],
                              "notes": notes, "raw": None if done["accepted"] else output})
        report.append({"id": meeting["id"], "title": meeting["title"], "reference": meeting.get("reference"),
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
    return 0 if all(s["accepted"] for m in report for s in m["snapshots"]) else 1


if __name__ == "__main__":
    sys.exit(main())
