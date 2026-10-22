"""Malformed inputs that must stop the run with a HarnessError rather than a Python exception or a
mismatch with what quietype-cli accepts. No model or quietype-cli needed."""

import contextlib
import copy
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from test_cases import with_fields  # noqa: E402
from test_meetings import GOOD as GOOD_MEETING  # noqa: E402

import run_evals  # noqa: E402
import run_meeting_notes as notes  # noqa: E402
from harness import Answer, HarnessError  # noqa: E402

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


class ChatServer(TemplateServer):
    """A stand-in llama-server that counts characters as tokens and answers with `reply`."""

    reply = "Call me at three."

    def count_tokens(self, text):
        return len(text)

    def chat(self, messages, max_tokens):
        return Answer(text=self.reply, max_tokens=max_tokens, truncated=False, seconds=0.0, tokens=4)


class CliAnswerTests(unittest.TestCase):
    """What run_suite does with quietype-cli answers that don't match what it asked for."""

    CASES = [with_fields(id="c1"), with_fields(id="c2", input="Thanks for the deck.", must=["deck"])]

    @staticmethod
    def prep(item):
        return {"id": item["id"], "rules_text": item["input"], "cues": ["correction"], "needs_llm": True,
                "content_marker": MARKER,
                "messages": [{"role": "system", "content": "Clean up."}, {"role": "user", "content": item["input"]}]}

    def fake_cli(self, broken_command=None, broken=None):
        """quietype-cli as a function; `broken` rewrites the answers of `broken_command`."""
        def answer(command, items):
            if command == "prep":
                answers = [self.prep(i) for i in items]
            elif command == "budget":
                answers = [{"id": i["id"], "max_tokens": 64} for i in items]
            else:
                answers = [{"id": i["id"], "result": {"text": i.get("llm_output", i["input"]), "path": "llm"}}
                           for i in items]
            return broken(answers) if command == broken_command else answers
        return answer

    def run_suite(self, cli):
        with mock.patch.object(run_evals, "cli", cli), contextlib.redirect_stdout(io.StringIO()):
            return run_evals.run_suite("suite", self.CASES, ChatServer(), all_llm=False)

    def assert_harness_error(self, command, broken, fragment):
        with self.assertRaises(HarnessError) as caught:
            self.run_suite(self.fake_cli(command, broken))
        self.assertIn(f"quietype-cli {command}", str(caught.exception))
        self.assertIn(fragment, str(caught.exception))

    def test_well_formed_answers_are_scored(self):
        report = self.run_suite(self.fake_cli())
        self.assertEqual([(r["id"], r["output"], r["max_tokens"]) for r in report],
                         [("c1", "Call me at three.", 64), ("c2", "Call me at three.", 64)])
        self.assertEqual([r["ok"] for r in report], [True, False])

    def test_a_missing_answer_is_a_harness_error(self):
        for command in ("prep", "budget", "finish"):
            with self.subTest(command=command):
                self.assert_harness_error(command, lambda answers: answers[:1], "no result for c2")

    def test_an_answer_nobody_asked_for_is_a_harness_error(self):
        for command in ("prep", "budget", "finish"):
            with self.subTest(command=command):
                self.assert_harness_error(command, lambda answers: answers + [dict(answers[0], id="c9")],
                                          "answered 'c9'")

    def test_a_duplicate_answer_is_a_harness_error(self):
        for command in ("prep", "budget", "finish"):
            with self.subTest(command=command):
                self.assert_harness_error(command, lambda answers: answers + answers[:1], "answered 'c1' twice")

    def test_an_answer_without_an_id_is_a_harness_error(self):
        for bad in ([], "c1", {"id": 1}, {"rules_text": "x"}):
            with self.subTest(bad=bad):
                self.assert_harness_error("prep", lambda answers, bad=bad: answers + [bad], "without an id")

    def test_prep_fields_of_the_wrong_shape_are_harness_errors(self):
        for key, value in (("rules_text", None), ("cues", "correction"), ("cues", [1]), ("needs_llm", "yes"),
                           ("needs_llm", 1), ("messages", []), ("messages", [{"role": "user"}]),
                           ("messages", [{"role": "user", "content": "x"}, {"role": "assistant", "content": "y"}])):
            with self.subTest(key=key, value=value):
                self.assert_harness_error(
                    "prep", lambda answers, key=key, value=value: [dict(answers[0], **{key: value})] + answers[1:],
                    f"{key} for 'c1' must be")
        self.assert_harness_error("prep", lambda answers: [{k: v for k, v in answers[0].items() if k != "cues"}]
                                  + answers[1:], "cues for 'c1' must be")

    def test_a_budget_that_isnt_a_positive_whole_number_is_a_harness_error(self):
        for value in (None, 0, -5, 64.0, "64", True):
            with self.subTest(value=value):
                self.assert_harness_error(
                    "budget", lambda answers, value=value: [dict(answers[0], max_tokens=value)] + answers[1:],
                    "max_tokens for 'c1' must be")

    def test_a_finish_result_without_text_or_path_is_a_harness_error(self):
        for result in (None, "Call me at three.", {"text": "x"}, {"path": "llm"}, {"text": None, "path": "llm"}):
            with self.subTest(result=result):
                self.assert_harness_error(
                    "finish", lambda answers, result=result: [dict(answers[0], result=result)] + answers[1:],
                    "result for 'c1' must be")


if __name__ == "__main__":
    unittest.main()
