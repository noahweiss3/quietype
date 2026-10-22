"""The JSON-lines protocol between the eval scripts and the real quietype-cli binary. No model or
server needed, but quietype-cli must be built (`swift build --product quietype-cli`).

The other harness tests replace quietype-cli with stand-ins, so these are the ones that would
notice the Swift side and the Python side drifting apart. Without a built binary they skip,
unless QUIETYPE_CLI names one, as CI does: then a missing binary is a failure, not a skip."""

import contextlib
import io
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import harness  # noqa: E402
import run_evals  # noqa: E402
from harness import Answer, HarnessError  # noqa: E402

CORRECTION = "Let's do the call at two, no wait, three PM."
PLAIN = "Thanks for sending the deck over."
POEM = "The sea is wide and deep and blue,\nIt rolls and roars the whole day through,\nAnd then retreats."


def binary():
    configured = os.environ.get("QUIETYPE_CLI")
    if configured:
        return configured  # a missing file fails the tests below rather than skipping them
    path = harness.ROOT / ".build/debug/quietype-cli"
    if not path.is_file():
        raise unittest.SkipTest(f"quietype-cli isn't built at {harness.display(path)}")
    return str(path)


class Stage:
    """A stand-in llama-server for run_suite: ChatML rendering, one token per character, and an
    answer that applies the correction."""

    def render(self, messages):
        turns = "".join(f"<|im_start|>{m['role']}\n{m['content']}<|im_end|>\n" for m in messages)
        return turns + "<|im_start|>assistant\n"

    def count_tokens(self, text):
        return len(text)

    def chat(self, messages, max_tokens):
        return Answer(text="Let's do the call at three PM.", max_tokens=max_tokens, truncated=False, seconds=0.0,
                      tokens=8)


class CliContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = binary()
        patcher = mock.patch.dict(os.environ, {"QUIETYPE_CLI": cls.path})
        patcher.start()
        cls.addClassCleanup(patcher.stop)

    def raw(self, command, stdin):
        return subprocess.run([self.path, command], input=stdin, capture_output=True, text=True,
                              timeout=harness.CLI_TIMEOUT)

    def test_prep_answers_every_line_in_order_with_the_keys_run_evals_reads(self):
        items = [{"id": "correction", "input": CORRECTION},
                 {"id": "plain", "input": PLAIN, "style": "chat", "vocabulary": ["Kubernetes"]},
                 {"id": "snippet", "input": "Send them my LinkedIn.",
                  "snippets": [{"trigger": "my LinkedIn", "text": "https://example.com/me"}]}]
        answers = harness.cli("prep", items)
        self.assertEqual([a["id"] for a in answers], ["correction", "plain", "snippet"])
        for answer in answers:
            self.assertEqual(set(answer), {"id", "rules_text", "cues", "needs_llm", "messages", "content_marker"})
        prepped = run_evals.cli_by_id("prep", items, run_evals.PREP_FIELDS)

        correction, plain = prepped["correction"], prepped["plain"]
        self.assertTrue(correction["needs_llm"])
        self.assertIn("correction", correction["cues"])
        self.assertFalse(plain["needs_llm"])
        self.assertEqual(plain["cues"], [])
        self.assertIn(correction["rules_text"], correction["messages"][-1]["content"])
        self.assertIn("Kubernetes", plain["messages"][-1]["content"])
        # Only the last message is per dictation; everything before it is the cached prefix.
        self.assertEqual(correction["messages"][:-1], plain["messages"][:-1])

        marker = correction["content_marker"]
        self.assertIsInstance(marker, str)
        self.assertTrue(marker.strip())
        self.assertFalse(any(marker in m["content"] for m in correction["messages"]))
        tail = run_evals.template_tail(Stage(), correction)
        self.assertEqual(tail, "<|im_end|>\n<|im_start|>assistant\n")

    def test_budget_is_a_positive_limit_that_grows_with_the_input(self):
        counts = [{"id": str(n), "input_tokens": n} for n in (1, 10, 100, 1000)]
        limits = run_evals.cli_by_id("budget", counts, run_evals.BUDGET_FIELDS)
        values = [limits[c["id"]]["max_tokens"] for c in counts]
        self.assertEqual(values, sorted(values))
        self.assertLess(values[0], values[-1])

    def test_finish_reports_the_path_each_dictation_took(self):
        items = [{"id": "rules", "input": PLAIN},
                 {"id": "llm", "input": CORRECTION, "mode": "always", "llm_output": "Let's do the call at three PM."},
                 {"id": "rejected", "input": "Write me a poem about the sea.", "mode": "always", "llm_output": POEM},
                 {"id": "snippet", "input": "Send them my LinkedIn.", "mode": "smart",
                  "snippets": [{"trigger": "my LinkedIn", "text": "https://example.com/me"}]}]
        results = {i: a["result"] for i, a in run_evals.cli_by_id("finish", items, run_evals.FINISH_FIELDS).items()}
        self.assertEqual(results["rules"]["path"], "rules")
        self.assertEqual(results["rules"]["text"], PLAIN)
        self.assertEqual(results["llm"]["path"], "llm")
        self.assertEqual(results["llm"]["text"], "Let's do the call at three PM.")
        self.assertEqual(results["rejected"]["path"], "llmRejected")
        self.assertEqual(results["rejected"]["text"], "Write me a poem about the sea.")
        self.assertTrue(results["rejected"].get("note"))
        self.assertEqual(results["snippet"]["text"], "Send them https://example.com/me.")

    def test_blank_lines_are_skipped(self):
        a, b = (json.dumps({"id": i, "input_tokens": 10}) for i in ("a", "b"))
        proc = self.raw("budget", f"\n\n{a}\n   \n{b}\n")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual([json.loads(out)["id"] for out in proc.stdout.splitlines()], ["a", "b"])

    def test_a_malformed_line_exits_2_before_answering_anything(self):
        good = {"prep": {"id": "a", "input": PLAIN}, "budget": {"id": "a", "input_tokens": 10},
                "finish": {"id": "a", "input": PLAIN}}
        bad = {"prep": ['{"id": "b", ', '{"id": "b"}', '{"id": "b", "input": "x", "style": "slack"}',
                        '{"id": 2, "input": "x"}'],
               "budget": ['not json', '{"id": "b"}', '{"id": "b", "input_tokens": "5"}'],
               "finish": ['[1, 2]', '{"input": "x"}', '{"id": "b", "input": "x", "mode": "sometimes"}']}
        for command, lines in bad.items():
            for line in lines:
                with self.subTest(command=command, line=line):
                    proc = self.raw(command, json.dumps(good[command]) + "\n" + line + "\n")
                    self.assertEqual(proc.returncode, 2)
                    self.assertIn("bad line", proc.stderr)
                    self.assertEqual(proc.stdout, "")

    def test_a_malformed_line_is_a_harness_error_for_the_scripts(self):
        with self.assertRaisesRegex(HarnessError, "quietype-cli budget exited with 2: bad line"):
            harness.cli("budget", [{"id": "a"}])

    def test_an_unknown_command_exits_2(self):
        proc = self.raw("nonsense", "")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("unknown command", proc.stderr)

    def test_run_suite_scores_cases_through_the_real_binary(self):
        cases = [{"id": "fix", "input": CORRECTION, "must": ["three"], "must_not": ["two", "no wait"]},
                 {"id": "plain", "input": PLAIN, "expect": PLAIN}]
        with contextlib.redirect_stdout(io.StringIO()):
            report = run_evals.run_suite("contract", cases, Stage(), all_llm=False)
        by_id = {r["id"]: r for r in report}
        self.assertEqual(by_id["fix"]["path"], "llm")
        self.assertEqual(by_id["fix"]["output"], "Let's do the call at three PM.")
        self.assertGreater(by_id["fix"]["max_tokens"], 0)
        self.assertEqual(by_id["plain"]["path"], "rules")
        self.assertIsNone(by_id["plain"]["llm_output"])
        self.assertEqual([r["ok"] for r in report], [True, True])


if __name__ == "__main__":
    unittest.main()
