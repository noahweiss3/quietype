"""Baselines, deadlines and run manifests in harness.py. No model needed: quietype-cli and
llama-server are replaced by stand-ins."""

import contextlib
import hashlib
import io
import json
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import harness  # noqa: E402
import run_evals  # noqa: E402
import run_meeting_notes  # noqa: E402
from harness import HarnessError  # noqa: E402


def quietly(fn, *args):
    """Runs fn with stdout captured and no GitHub job summary; returns (result, output)."""
    out = io.StringIO()
    env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
    with mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(out):
        result = fn(*args)
    return result, out.getvalue()


class BaselineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "baselines.json"
        patcher = mock.patch.object(harness, "BASELINES", self.path)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def write(self, baselines):
        self.path.write_text(json.dumps(baselines))

    def gate(self, outcomes, entry):
        self.write({"suite": entry})
        baselines = harness.load_baselines(["suite"])
        return quietly(harness.report_scores, [("suite", outcomes)], baselines, "cases")

    def test_a_new_failure_fails_even_when_a_known_failure_now_passes(self):
        # The same pass count as the baseline, which a count-based gate would accept.
        failing, out = self.gate({"a": True, "b": False, "c": True},
                                 {"total": 3, "known_failures": ["a"]})
        self.assertEqual(failing, ["suite"])
        self.assertIn("failing, and not a known failure: b", out)
        self.assertIn("known failures that now pass: a", out)

    def test_known_failures_pass_the_gate(self):
        failing, out = self.gate({"a": False, "b": True}, {"total": 2, "known_failures": ["a"]})
        self.assertEqual(failing, [])
        self.assertIn("ok", out)

    def test_a_fixed_known_failure_is_reported_but_passes(self):
        failing, out = self.gate({"a": True, "b": True}, {"total": 2, "known_failures": ["a"]})
        self.assertEqual(failing, [])
        self.assertIn("Take them out of known_failures", out)

    def test_flaky_cases_never_gate(self):
        failing, _ = self.gate({"a": False, "b": True}, {"total": 2, "known_failures": [], "flaky": ["a"]})
        self.assertEqual(failing, [])
        failing, out = self.gate({"a": True, "b": True}, {"total": 2, "known_failures": [], "flaky": ["a"]})
        self.assertEqual(failing, [])
        self.assertNotIn("now pass", out)

    def test_a_changed_suite_size_fails(self):
        failing, out = self.gate({"a": True, "b": True}, {"total": 3, "known_failures": []})
        self.assertEqual(failing, ["suite"])
        self.assertIn("baseline out of date", out)

    def test_a_known_failure_the_suite_no_longer_has_fails(self):
        failing, out = self.gate({"a": True, "b": True}, {"total": 2, "known_failures": ["gone"]})
        self.assertEqual(failing, ["suite"])
        self.assertIn("doesn't have: gone", out)

    def test_suites_without_a_baseline_are_reported_not_gated(self):
        failing, out = quietly(harness.report_scores, [("new", {"a": False})], {}, "cases")
        self.assertEqual(failing, [])
        self.assertIn("no baseline", out)

    def test_load_requires_every_named_suite(self):
        self.write({"suite": {"total": 1, "known_failures": []}})
        with self.assertRaisesRegex(HarnessError, "no baseline for other"):
            harness.load_baselines(["suite", "other"])

    def test_load_rejects_malformed_entries(self):
        for entry in ({"min_pass": 3, "total": 4}, {"total": "4", "known_failures": []},
                      {"total": 4, "known_failures": "a"}, {"total": 4, "known_failures": ["a"], "flaky": ["a"]}):
            with self.subTest(entry=entry):
                self.write({"suite": entry})
                with self.assertRaises(HarnessError):
                    harness.load_baselines()

    def test_load_rejects_falsy_lists_and_totals_of_the_wrong_type(self):
        # Values that an "if value:" check would wave through as an empty list.
        for key in ("known_failures", "flaky"):
            for value in (None, 0, "", {}, False):
                with self.subTest(key=key, value=value):
                    self.write({"suite": {"total": 1, "known_failures": [], key: value}})
                    with self.assertRaisesRegex(HarnessError, f"suite.{key}"):
                        harness.load_baselines()
        for total in (None, 0.0, False, -1, [], 1.5):
            with self.subTest(total=total):
                self.write({"suite": {"total": total, "known_failures": []}})
                with self.assertRaisesRegex(HarnessError, "total must be a whole number"):
                    harness.load_baselines()

    def test_load_accepts_empty_lists_and_a_missing_flaky_list(self):
        self.write({"suite": {"total": 0, "known_failures": []},
                    "other": {"total": 2, "known_failures": [], "flaky": []}})
        baselines = harness.load_baselines(["suite", "other"])
        self.assertEqual(baselines["suite"], {"total": 0, "known_failures": [], "flaky": []})

    def test_update_records_failures_and_keeps_flaky_cases(self):
        self.write({"suite": {"total": 2, "known_failures": [], "flaky": ["b", "gone"]},
                    "other": {"total": 1, "known_failures": []}})
        quietly(harness.update_baselines, [("suite", {"a": False, "b": False, "c": True, "d": False})])
        self.assertEqual(json.loads(self.path.read_text()), {
            "suite": {"total": 4, "known_failures": ["a", "d"], "flaky": ["b"]},
            "other": {"total": 1, "known_failures": []},
        })


class CheckedInBaselineTests(unittest.TestCase):
    """baselines.json must match the fixtures, or CI fails before any model runs."""

    def test_every_suite_has_a_baseline_that_matches_its_fixtures(self):
        baselines = harness.load_baselines()
        suites = {p.stem: [c["id"] for c in run_evals.load_suite(p)] for p in run_evals.CASES.glob("*.jsonl")}
        meetings = run_meeting_notes.load_meetings(run_meeting_notes.EVALS / "meetings", None)
        report = [{"id": m["id"], "checks": run_meeting_notes.check("", m["checks"], [])} for m in meetings]
        suites[run_meeting_notes.SUITE] = list(run_meeting_notes.outcomes(report))
        self.assertEqual(set(baselines), set(suites))
        for suite, ids in suites.items():
            with self.subTest(suite=suite):
                entry = baselines[suite]
                self.assertEqual(entry["total"], len(ids))
                self.assertEqual(len(ids), len(set(ids)))
                self.assertEqual([i for i in entry["known_failures"] + entry["flaky"] if i not in ids], [])


class FakeServer(BaseHTTPRequestHandler):
    props = {}

    def do_GET(self):
        if self.path == "/slow":
            time.sleep(2)
        body = json.dumps(self.props if self.path == "/props" else {"status": "ok"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), FakeServer)
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.server = harness.LlamaServer(f"http://127.0.0.1:{self.httpd.server_address[1]}")

    def test_a_slow_request_times_out(self):
        with mock.patch.object(harness, "REQUEST_TIMEOUT", 0.3):
            started = time.time()
            with self.assertRaises(HarnessError):
                self.server._request("/slow")
            self.assertLess(time.time() - started, 1.5)

    def test_manifest_records_the_model_build_and_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            model = Path(tmp) / "model.gguf"
            model.write_bytes(b"weights")
            FakeServer.props = {"model_path": str(model), "build_info": "b11351-abc",
                                "default_generation_settings": {"n_ctx": 8192}}
            argv = ["evals/run_evals.py", "--all", "--check-baseline"]
            with mock.patch.object(sys, "argv", argv), \
                    mock.patch.dict(os.environ, {"QUIETYPE_EVAL_BACKEND": "llama.cpp CPU"}):
                manifest = harness.run_manifest(self.server)
        self.assertEqual(manifest["model"], {"file": "model.gguf", "sha256": hashlib.sha256(b"weights").hexdigest()})
        self.assertEqual(manifest["server"]["build"], "b11351-abc")
        self.assertEqual(manifest["server"]["n_ctx"], 8192)
        self.assertEqual(manifest["backend"], "llama.cpp CPU")
        self.assertTrue(manifest["command"].endswith("evals/run_evals.py --all --check-baseline"))
        self.assertRegex(manifest["date"], r"^\d{4}-\d\d-\d\dT")

    def test_manifest_without_props(self):
        FakeServer.props = []
        manifest = harness.run_manifest(self.server)
        self.assertIsNone(manifest["model"])
        self.assertIsNone(manifest["server"]["build"])

    def test_results_are_written_with_their_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "suite.jsonl"
            fixture.write_text("{}\n")
            with mock.patch.object(harness, "RESULTS", Path(tmp) / "results"):
                harness.write_results("suite", [{"id": "a", "ok": False}], False, {"date": "today"},
                                      fixtures=[fixture], failed=["a"])
                written = json.loads((Path(tmp) / "results" / "suite.manifest.json").read_text())
        self.assertEqual(written["suite"], "suite")
        self.assertEqual(written["failed"], ["a"])
        self.assertEqual(written["fixtures"][0]["sha256"], hashlib.sha256(b"{}\n").hexdigest())


class CliTests(unittest.TestCase):
    def fake_cli(self, tmp, script):
        path = Path(tmp) / "quietype-cli"
        path.write_text("#!/bin/sh\n" + script + "\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return str(path)

    def run_cli(self, script, timeout=5):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {"QUIETYPE_CLI": self.fake_cli(tmp, script)}), \
                    mock.patch.object(harness, "CLI_TIMEOUT", timeout):
                return harness.cli("prep", [{"id": "a"}])

    def test_returns_the_printed_objects(self):
        self.assertEqual(self.run_cli("cat"), [{"id": "a"}])

    def test_a_hung_command_times_out(self):
        started = time.time()
        with self.assertRaisesRegex(HarnessError, "took longer than"):
            self.run_cli("exec sleep 30", timeout=0.5)
        self.assertLess(time.time() - started, 10)

    def test_a_failing_command_is_a_harness_error(self):
        with self.assertRaisesRegex(HarnessError, "exited with 3: broken"):
            self.run_cli("echo broken >&2; exit 3")

    def test_garbage_output_is_a_harness_error(self):
        with self.assertRaisesRegex(HarnessError, "isn't JSON"):
            self.run_cli("echo 'not json'")

    def test_a_missing_binary_is_a_harness_error(self):
        with mock.patch.dict(os.environ, {"QUIETYPE_CLI": "/nonexistent/quietype-cli"}):
            with self.assertRaisesRegex(HarnessError, "not found"):
                harness.cli("prep", [])


class StringListTests(unittest.TestCase):
    def test_rejects_a_bare_string(self):
        with self.assertRaisesRegex(HarnessError, "must be a non-empty list"):
            harness.string_list("abc", "must")

    def test_allow_empty(self):
        harness.string_list([], "must_not", allow_empty=True)
        with self.assertRaises(HarnessError):
            harness.string_list([], "must_not")


if __name__ == "__main__":
    unittest.main()
