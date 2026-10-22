"""Meeting-fixture validation, notes checks and the replay deadline in run_meeting_notes.py. No
model needed; quietype-cli is replaced by a stand-in script."""

import copy
import json
import os
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import harness  # noqa: E402
import run_meeting_notes as notes  # noqa: E402
from harness import HarnessError  # noqa: E402

GOOD = {
    "id": "standup",
    "title": "Standup",
    "segments": [
        {"id": 1, "speaker": "others", "start": 0.0, "end": 4.5, "text": "We ship on Thursday."},
        {"id": 2, "speaker": "me", "start": 4.0, "end": 6.0, "text": "I'll write the release notes."},
    ],
    "checks": {"must": ["Thursday"], "must_not": [],
               "sections": {"Action items": {"must": ["release notes"], "must_not": []}}},
}


def meeting_with(change):
    meeting = copy.deepcopy(GOOD)
    change(meeting)
    return meeting


class ValidateTests(unittest.TestCase):
    def assert_rejected(self, change, fragment):
        with self.assertRaises(HarnessError) as caught:
            notes.validate(meeting_with(change), "standup.json")
        self.assertIn(fragment, str(caught.exception))

    def test_accepts_a_well_formed_meeting(self):
        notes.validate(copy.deepcopy(GOOD), "standup.json")

    def test_every_checked_in_meeting_is_valid(self):
        self.assertTrue(notes.load_meetings(notes.EVALS / "meetings", None))

    def test_rejects_bad_segment_times(self):
        def times(start, end):
            return lambda m: m["segments"][0].update(start=start, end=end)

        self.assert_rejected(times(5.0, 4.0), "0 <= start < end")
        self.assert_rejected(times(4.5, 4.5), "0 <= start < end")
        self.assert_rejected(times(-1, 4.0), "0 <= start < end")
        self.assert_rejected(times("0", 4.0), "0 <= start < end")
        self.assert_rejected(times(False, 4.0), "0 <= start < end")
        self.assert_rejected(times(0, float("nan")), "0 <= start < end")

    def test_rejects_segments_out_of_order(self):
        self.assert_rejected(lambda m: m["segments"].reverse(), "order of their start times")

    def test_rejects_malformed_segments(self):
        self.assert_rejected(lambda m: m["segments"][0].update(speaker="them"), "speaker")
        self.assert_rejected(lambda m: m["segments"][0].pop("text"), "exactly")
        self.assert_rejected(lambda m: m["segments"][0].update(text=""), "needs some text")
        self.assert_rejected(lambda m: m["segments"][1].update(id=1), "unique")
        self.assert_rejected(lambda m: m.update(segments=[]), "non-empty list of segments")
        self.assert_rejected(lambda m: m.update(segments=["hello"]), "exactly")

    def test_rejects_a_string_where_a_list_belongs(self):
        self.assert_rejected(lambda m: m["checks"].update(must="Thursday"), "checks.must")
        self.assert_rejected(lambda m: m["checks"]["sections"]["Action items"].update(must="notes"),
                             "checks.sections.Action items.must")

    def test_rejects_empty_check_strings_and_empty_sections(self):
        self.assert_rejected(lambda m: m["checks"].update(must=[""]), "non-empty strings")
        self.assert_rejected(lambda m: m["checks"]["sections"].update(Decisions={}), "has no checks")
        self.assert_rejected(lambda m: m["checks"]["sections"].update(Decisions={"should": ["x"]}), "may only")

    def test_needs_checks(self):
        self.assert_rejected(lambda m: m.pop("checks"), "needs checks")
        self.assert_rejected(lambda m: m.update(checks={"must": []}), "at least one check")
        self.assert_rejected(lambda m: m.update(id=""), "id")


class CheckTests(unittest.TestCase):
    NOTES = "## Summary\nShip on Thursday.\n## Action items\n- Me: release notes\n"

    def test_scores_overall_and_section_checks(self):
        results = notes.check(self.NOTES, GOOD["checks"], [{"ok": True}, {"ok": True}])
        self.assertEqual([(r["id"], r["ok"]) for r in results], [
            ("every notes update succeeded", True),
            ("notes mention 'Thursday'", True),
            ("Action items mention 'release notes'", True),
        ])
        self.assertEqual(results[0]["check"], "all 2 notes updates succeeded")

    def test_a_missing_section_fails_its_checks(self):
        results = notes.check("## Summary\nShip on Thursday.\n", GOOD["checks"], [{"ok": False}])
        self.assertEqual([r["ok"] for r in results], [False, True, False])
        self.assertEqual(results[2]["check"], "Action items mention 'release notes' (no Action items section)")

    def test_ids_depend_only_on_the_fixture(self):
        a = notes.check(self.NOTES, GOOD["checks"], [{"ok": True}])
        b = notes.check("", GOOD["checks"], [{"ok": False}] * 5)
        self.assertEqual([r["id"] for r in a], [r["id"] for r in b])
        outcomes = notes.outcomes([{"id": "standup", "checks": b}])
        self.assertEqual(list(outcomes)[0], "standup: every notes update succeeded")

    def test_sections_are_split_by_heading(self):
        self.assertEqual(notes.sections("intro\n## Decisions\nA\n## Action Items\n- B\n"),
                         {"decisions": "A\n", "action items": "- B\n"})


class ReplayDeadlineTests(unittest.TestCase):
    def fake_cli(self, tmp, script):
        path = Path(tmp) / "quietype-cli"
        path.write_text("#!/bin/sh\n" + script + "\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return str(path)

    def test_a_silent_quietype_cli_is_killed(self):
        with tempfile.TemporaryDirectory() as tmp:
            cli = self.fake_cli(tmp, "exec sleep 30")
            with mock.patch.dict(os.environ, {"QUIETYPE_CLI": cli}), mock.patch.object(harness, "CLI_TIMEOUT", 0.5):
                started = time.time()
                with self.assertRaisesRegex(HarnessError, "without answering"):
                    notes.replay(copy.deepcopy(GOOD), server=None)
                self.assertLess(time.time() - started, 10)

    def test_a_replay_that_finishes_returns_its_notes(self):
        events = [{"event": "update", "at": 6, "final": True, "ok": True, "notes": "## Summary\nok\n"},
                  {"event": "done", "notes": "## Summary\nok\n"}]
        script = "read line\n" + "\n".join(f"printf '%s\\n' '{json.dumps(e)}'" for e in events)
        with tempfile.TemporaryDirectory() as tmp:
            cli = self.fake_cli(tmp, script)
            with mock.patch.dict(os.environ, {"QUIETYPE_CLI": cli}), mock.patch("builtins.print"):
                updates, final = notes.replay(copy.deepcopy(GOOD), server=None)
        self.assertEqual(len(updates), 1)
        self.assertEqual(final, "## Summary\nok\n")

    def test_garbage_output_is_a_harness_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            cli = self.fake_cli(tmp, "read line\necho 'not json'")
            with mock.patch.dict(os.environ, {"QUIETYPE_CLI": cli}):
                with self.assertRaisesRegex(HarnessError, "isn't JSON"):
                    notes.replay(copy.deepcopy(GOOD), server=None)


if __name__ == "__main__":
    unittest.main()
