"""Malformed inputs that must stop the run with a HarnessError rather than a Python exception or a
mismatch with what quietype-cli accepts. No model or quietype-cli needed."""

import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from test_cases import with_fields  # noqa: E402
from test_meetings import GOOD as GOOD_MEETING  # noqa: E402

import run_evals  # noqa: E402
import run_meeting_notes as notes  # noqa: E402
from harness import HarnessError  # noqa: E402

MARKER = "\x1fMARK\x1f"


class TemplateServer:
    """Renders messages as ChatML, like llama-server's /apply-template for a Qwen3 model."""

    def render(self, messages):
        turns = "".join(f"<|im_start|>{m['role']}\n{m['content']}<|im_end|>\n" for m in messages)
        return turns + "<|im_start|>assistant\n"


class CaseStyleTests(unittest.TestCase):
    def test_a_style_of_the_wrong_type_is_a_harness_error(self):
        for style in (["email"], {"name": "email"}, 3, None):
            with self.subTest(style=style):
                with self.assertRaises(HarnessError) as caught:
                    run_evals.validate_case(dict(with_fields(), style=style), "cases.jsonl:1")
                self.assertIn("style must be one of", str(caught.exception))


class SegmentIdTests(unittest.TestCase):
    def validate_with_id(self, segment_id):
        meeting = copy.deepcopy(GOOD_MEETING)
        meeting["segments"][0]["id"] = segment_id
        notes.validate(meeting, "standup.json")

    def test_segment_ids_must_be_whole_numbers_like_quietype_cli_decodes(self):
        for segment_id in ("1", "a", 1.5, True, None, [1]):
            with self.subTest(segment_id=segment_id):
                with self.assertRaises(HarnessError) as caught:
                    self.validate_with_id(segment_id)
                self.assertIn("whole numbers", str(caught.exception))

    def test_accepts_large_and_zero_ids(self):
        self.validate_with_id(0)
        self.validate_with_id(10**6)

    def test_every_checked_in_meeting_uses_whole_number_ids(self):
        for meeting in notes.load_meetings(notes.EVALS / "meetings", None):
            for segment in meeting["segments"]:
                self.assertIs(type(segment["id"]), int, f"{meeting['id']}: {segment}")


class ContentMarkerTests(unittest.TestCase):
    PREP = {"messages": [{"role": "system", "content": "Clean up."}, {"role": "user", "content": "um hi"}]}

    def test_the_tail_is_what_follows_the_marker(self):
        prep = dict(self.PREP, content_marker=MARKER)
        tail = run_evals.template_tail(TemplateServer(), prep)
        self.assertEqual(tail, "<|im_end|>\n<|im_start|>assistant\n")

    def test_a_prep_without_the_marker_asks_for_a_rebuild(self):
        for prep in (self.PREP, dict(self.PREP, content_marker=""), dict(self.PREP, content_marker=None)):
            with self.subTest(prep=prep):
                with self.assertRaises(HarnessError) as caught:
                    run_evals.template_tail(TemplateServer(), prep)
                self.assertIn("swift build --product quietype-cli", str(caught.exception))

    def test_a_template_that_drops_the_marker_is_a_harness_error(self):
        class Dropping(TemplateServer):
            def render(self, messages):
                return "<|im_start|>assistant\n"

        with self.assertRaises(HarnessError) as caught:
            run_evals.template_tail(Dropping(), dict(self.PREP, content_marker=MARKER))
        self.assertIn("dropped the content marker", str(caught.exception))

    def test_no_fallback_copy_of_the_marker_is_kept(self):
        self.assertFalse(hasattr(run_evals, "CONTENT_MARKER"))


if __name__ == "__main__":
    unittest.main()
