#!/usr/bin/env python3
"""Evaluate Murmur's cleanup (rules + LLM prompt + guard) against a llama.cpp server.

Uses murmur-cli for everything except the model call, so this measures exactly what the app
does. Start a server first, e.g.

    llama-server -m Qwen3-4B-Instruct-2507-Q4_K_M.gguf --jinja -c 4096 --port 8080

then run

    swift build --product murmur-cli
    python3 evals/run_evals.py --server http://127.0.0.1:8080 [--all-llm] [--no-think]

Checks per case: "expect" (exact, whitespace-normalized), "must" / "must_not" (case-insensitive substrings),
"must_case" (case-sensitive substrings), "must_not_exact" (whole output).
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def cli(args, lines):
    binary = os.environ.get("MURMUR_CLI", str(ROOT / ".build/debug/murmur-cli"))
    proc = subprocess.run([binary, *args], input="\n".join(json.dumps(l) for l in lines) + "\n",
                          capture_output=True, text=True, check=True)
    return [json.loads(l) for l in proc.stdout.splitlines() if l.strip()]


def chat(server, messages, max_tokens, no_think):
    body = {"messages": messages, "temperature": 0, "max_tokens": max_tokens, "cache_prompt": True}
    if no_think:
        body["chat_template_kwargs"] = {"enable_thinking": False}
    req = urllib.request.Request(f"{server}/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    started = time.time()
    with urllib.request.urlopen(req, timeout=600) as resp:
        data = json.load(resp)
    return data["choices"][0]["message"]["content"], time.time() - started, data.get("timings", {})


def norm(text):
    return " ".join(text.split())


def score(case, output):
    failures = []
    if "expect" in case and norm(output) != norm(case["expect"]):
        failures.append(f"expected {case['expect']!r}")
    for s in case.get("must", []):
        if s.lower() not in output.lower():
            failures.append(f"missing {s!r}")
    for s in case.get("must_case", []):
        if s not in output:
            failures.append(f"missing {s!r} (case-sensitive)")
    for s in case.get("must_not", []):
        if s.lower() in output.lower():
            failures.append(f"contains {s!r}")
    for s in case.get("must_not_exact", []):
        if output.strip() == s:
            failures.append(f"is exactly {s!r}")
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default="http://127.0.0.1:8080")
    parser.add_argument("--cases", default=str(ROOT / "evals/cases.jsonl"))
    parser.add_argument("--all-llm", action="store_true", help="send every case to the LLM (cleanup mode 'always')")
    parser.add_argument("--no-think", action="store_true", help="disable thinking for hybrid models like Qwen3")
    parser.add_argument("--only", help="comma-separated case ids")
    parser.add_argument("--label", default="run")
    args = parser.parse_args()

    cases = [json.loads(l) for l in open(args.cases) if l.strip()]
    if args.only:
        wanted = set(args.only.split(","))
        cases = [c for c in cases if c["id"] in wanted]

    prepped = {p["id"]: p for p in cli(["prep"], [
        {"id": c["id"], "input": c["input"], "style": c.get("style"), "vocabulary": c.get("vocabulary")} for c in cases])}

    finish_inputs, llm_times, llm_tokens = [], [], []
    for case in cases:
        prep = prepped[case["id"]]
        item = {"id": case["id"], "input": case["input"], "style": case.get("style"),
                "vocabulary": case.get("vocabulary"), "mode": "always" if args.all_llm else "smart"}
        if prep["needs_llm"] or args.all_llm:
            words = len(prep["rules_text"].split())
            output, seconds, timings = chat(args.server, prep["messages"], words * 3 + 64, args.no_think)
            item["llm_output"] = output
            llm_times.append(seconds)
            llm_tokens.append(timings.get("predicted_n", 0))
        finish_inputs.append(item)

    results = {r["id"]: r["result"] for r in cli(["finish"], finish_inputs)}

    passed = 0
    by_category = {}
    report = []
    for case in cases:
        result = results[case["id"]]
        failures = score(case, result["text"])
        ok = not failures
        passed += ok
        cat = by_category.setdefault(case.get("category", "other"), [0, 0])
        cat[0] += ok
        cat[1] += 1
        report.append({"id": case["id"], "ok": ok, "path": result["path"], "output": result["text"],
                       "failures": failures, "note": result.get("note")})
        mark = "PASS" if ok else "FAIL"
        print(f"{mark} {case['id']:<28} [{result['path']}] {result['text']!r}")
        for f in failures:
            print(f"       {f}")
        if result.get("note"):
            print(f"       note: {result['note']}")

    print()
    print(f"{passed}/{len(cases)} passed")
    print("by category: " + ", ".join(f"{k} {v[0]}/{v[1]}" for k, v in sorted(by_category.items())))
    if llm_times:
        print(f"LLM calls: {len(llm_times)}, mean {sum(llm_times) / len(llm_times):.2f}s, "
              f"mean tokens {sum(llm_tokens) / len(llm_tokens):.0f}")

    out_dir = ROOT / "evals/results"
    out_dir.mkdir(exist_ok=True)
    (out_dir / f"{args.label}.json").write_text(json.dumps(report, indent=2))
    return 0 if passed == len(cases) else 1


if __name__ == "__main__":
    sys.exit(main())
