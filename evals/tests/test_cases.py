"""Case-file validation and scoring in run_evals.py. No model or quietype-cli needed."""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import run_evals  # noqa: E402
from harness import HarnessError  # noqa: E402

GOOD = {"id": "c1", "input": "Call me at two, no wait, three.", "must": ["three"], "must_not": ["two"]}


def with_fields(**fields):
    case = dict(GOOD)
    for key, value in fields.items():
        if value is None:
            case.pop(key, None)
        else:
            case[key] = value
    return case


class ValidateCaseTests(unittest.TestCase):
    def assert_rejected(self, case, fragment):
        with self.assertRaises(HarnessError) as caught:
            run_evals.validate_case(case, "cases.jsonl:1")
        self.assertIn(fragment, str(caught.exception))
        self.assertIn("cases.jsonl:1", str(caught.exception))

    def test_accepts_a_well_formed_case(self):
        run_evals.validate_case(with_fields(style="email", vocabulary=["Kubernetes"], must_any=[["3", "three"]],
                                            snippets=[{"trigger": "my site", "text": "https://example.com"}]),
                                "cases.jsonl:1")

    def test_accepts_a_newline_as_an_assertion(self):
        run_evals.validate_case(with_fields(must=["\n", "Eggs"]), "cases.jsonl:1")

    def test_rejects_a_string_where_a_list_belongs(self):
        for key in ("must", "must_not", "must_case", "must_not_exact", "vocabulary"):
            with self.subTest(key=key):
                self.assert_rejected(with_fields(**{key: "three"}), key)

    def test_rejects_empty_assertion_lists_and_values(self):
        self.assert_rejected(with_fields(must=[]), "must")
        self.assert_rejected(with_fields(must=[""]), "must")
        self.assert_rejected(with_fields(must_not=["two", 2]), "must_not")

    def test_rejects_duplicate_assertion_values(self):
        self.assert_rejected(with_fields(must=["three", "three"]), "same string twice")

    def test_must_any_needs_a_list_of_lists(self):
        self.assert_rejected(with_fields(must_any=["3", "three"]), "must_any[0]")
        self.assert_rejected(with_fields(must_any=[[]]), "must_any[0]")
        self.assert_rejected(with_fields(must_any=[]), "must_any")

    def test_rejects_bad_ids_and_inputs(self):
        self.assert_rejected(with_fields(id=7), "id and input")
        self.assert_rejected(with_fields(id=""), "id and input")
        self.assert_rejected(with_fields(input=None), "id and input")
        self.assert_rejected(with_fields(input="   "), "id and input")
        self.assert_rejected(["not", "an", "object"], "JSON object")

    def test_rejects_unknown_keys_and_styles(self):
        self.assert_rejected(with_fields(mustnt=["two"]), "unknown keys")
        self.assert_rejected(with_fields(style="slack"), "style")
        self.assert_rejected(with_fields(expect=["three"]), "expect must be a string")
        self.assert_rejected(with_fields(category=3), "category must be a string")

    def test_rejects_malformed_snippets(self):
        self.assert_rejected(with_fields(snippets={"trigger": "a", "text": "b"}), "snippets")
        self.assert_rejected(with_fields(snippets=[{"trigger": "a"}]), "snippets")
        self.assert_rejected(with_fields(snippets=[{"trigger": "a", "text": ""}]), "snippets")
        self.assert_rejected(with_fields(snippets=[]), "snippets")

    def test_needs_an_assertion(self):
        self.assert_rejected(with_fields(must=None, must_not=None), "no assertions")

    def test_an_empty_expect_is_an_assertion(self):
        run_evals.validate_case(with_fields(must=None, must_not=None, expect=""), "cases.jsonl:1")


class LoadSuiteTests(unittest.TestCase):
    def load(self, text):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "suite.jsonl"
            path.write_text(text)
            return run_evals.load_suite(path)

    def test_skips_blank_lines(self):
        cases = self.load('\n{"id": "a", "input": "x", "must": ["x"]}\n\n{"id": "b", "input": "y", "must": ["y"]}\n')
        self.assertEqual([c["id"] for c in cases], ["a", "b"])

    def test_rejects_duplicate_ids(self):
        with self.assertRaisesRegex(HarnessError, "duplicate id 'a'"):
            self.load('{"id": "a", "input": "x", "must": ["x"]}\n{"id": "a", "input": "y", "must": ["y"]}\n')

    def test_rejects_invalid_json_with_its_line(self):
        with self.assertRaisesRegex(HarnessError, r"suite.jsonl:2: not valid JSON"):
            self.load('{"id": "a", "input": "x", "must": ["x"]}\n{"id": \n')

    def test_rejects_a_missing_file(self):
        with self.assertRaisesRegex(HarnessError, "no case file"):
            run_evals.load_suite(Path("/nonexistent/suite.jsonl"))

    def test_every_checked_in_suite_is_valid(self):
        paths = sorted(run_evals.CASES.glob("*.jsonl"))
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(suite=path.stem):
                self.assertTrue(run_evals.load_suite(path))


class ScoreTests(unittest.TestCase):
    def test_expect_ignores_whitespace_only(self):
        case = {"expect": "Eggs\nMilk"}
        self.assertEqual(run_evals.score(case, "Eggs  Milk "), [])
        self.assertEqual(run_evals.score(case, "eggs milk"), ["expected 'Eggs\\nMilk'"])

    def test_must_and_must_not_ignore_case(self):
        case = {"must": ["Three"], "must_not": ["two"]}
        self.assertEqual(run_evals.score(case, "at THREE"), [])
        self.assertEqual(run_evals.score(case, "Two or three"), ["contains 'two'"])
        self.assertEqual(run_evals.score(case, "at four"), ["missing 'Three'"])

    def test_must_case_matches_case(self):
        case = {"must_case": ["iPhone"]}
        self.assertEqual(run_evals.score(case, "my iPhone"), [])
        self.assertEqual(run_evals.score(case, "my iphone"), ["missing 'iPhone' (case-sensitive)"])

    def test_must_any_needs_one_of_each_list(self):
        case = {"must_any": [["14", "fourteenth"], ["May"]]}
        self.assertEqual(run_evals.score(case, "May the fourteenth"), [])
        self.assertEqual(run_evals.score(case, "May 12"), ["missing all of ['14', 'fourteenth']"])

    def test_must_not_exact_compares_the_whole_output(self):
        case = {"must_not_exact": ["Banana."]}
        self.assertEqual(run_evals.score(case, "Reply with banana."), [])
        self.assertEqual(run_evals.score(case, " Banana. "), ["is exactly 'Banana.'"])


if __name__ == "__main__":
    unittest.main()
