"""Shared by the eval scripts: running quietype-cli, talking to llama.cpp's server, input
validation, baselines and run manifests."""

import hashlib
import json
import math
import os
import platform
import shlex
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVALS = ROOT / "evals"
RESULTS = EVALS / "results"
BASELINES = EVALS / "baselines.json"
DEFAULT_SERVER = "http://127.0.0.1:8080"

# Generous deadlines: a slow CPU runner takes a minute or more over a long notes request, but
# nothing legitimate takes ten.
CLI_TIMEOUT = 300  # seconds for one quietype-cli command, or for it to answer during a replay
REQUEST_TIMEOUT = 600  # seconds for one llama-server request


class HarnessError(Exception):
    """The harness itself failed (no server, no quietype-cli, a malformed case file), as opposed
    to the model doing badly on a case."""


def display(path):
    path = Path(path)
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


# Input validation


def string_list(value, what, nested=False, allow_empty=False):
    """Checks that `value` is a non-empty list of distinct non-empty strings (with `nested`, a
    non-empty list of such lists). A bare string is rejected rather than iterated per character."""
    if not isinstance(value, list) or not (value or allow_empty):
        raise HarnessError(f"{what} must be a {'' if allow_empty else 'non-empty '}list, not {json.dumps(value)}")
    if nested:
        for i, inner in enumerate(value):
            string_list(inner, f"{what}[{i}]")
        return
    for item in value:
        if not isinstance(item, str) or not item:
            raise HarnessError(f"{what} must hold non-empty strings, not {json.dumps(item)}")
    if len(set(value)) != len(value):
        raise HarnessError(f"{what} lists the same string twice")


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


# quietype-cli


def quietype_cli_path():
    path = Path(os.environ.get("QUIETYPE_CLI", ROOT / ".build/debug/quietype-cli"))
    if not path.is_file():
        raise HarnessError(f"quietype-cli not found at {path}. Build it with "
                           "`swift build --product quietype-cli`, or point QUIETYPE_CLI at it.")
    return str(path)


def parse_lines(text, source):
    try:
        return [json.loads(line) for line in text.splitlines() if line.strip()]
    except json.JSONDecodeError as e:
        raise HarnessError(f"{source} printed something that isn't JSON: {e}") from e


def cli(command, items):
    """Runs a quietype-cli JSON-lines command over `items` and returns the objects it prints."""
    try:
        proc = subprocess.run([quietype_cli_path(), command], input="".join(json.dumps(i) + "\n" for i in items),
                              capture_output=True, text=True, timeout=CLI_TIMEOUT)
    except subprocess.TimeoutExpired as e:
        raise HarnessError(f"quietype-cli {command} took longer than {CLI_TIMEOUT}s") from e
    if proc.returncode != 0:
        raise HarnessError(f"quietype-cli {command} exited with {proc.returncode}: {proc.stderr.strip()}")
    return parse_lines(proc.stdout, f"quietype-cli {command}")


class Watchdog:
    """Kills a subprocess that stays silent too long. Arm it (`with watchdog:`) only around
    waiting on the process, so time spent waiting on the model doesn't count."""

    def __init__(self, proc, seconds):
        self.proc, self.seconds, self.fired, self._timer = proc, seconds, False, None

    def _fire(self):
        self.fired = True
        self.proc.kill()

    def __enter__(self):
        self._timer = threading.Timer(self.seconds, self._fire)
        self._timer.daemon = True
        self._timer.start()
        return self

    def __exit__(self, *exc):
        self._timer.cancel()


# llama.cpp server


@dataclass
class Answer:
    text: str
    max_tokens: int
    truncated: bool  # stopped at max_tokens rather than at the end of the answer
    seconds: float
    tokens: int


class LlamaServer:
    """The few llama-server endpoints the evals use. Requests are greedy (temperature 0), like
    the app's decoder."""

    def __init__(self, url, no_think=False):
        self.url = url.rstrip("/")
        # Hybrid models such as Qwen3 1.7B: the app prefills an empty think block, which is what
        # the Qwen3 template renders with thinking turned off.
        self.template_kwargs = {"enable_thinking": False} if no_think else None

    def _request(self, path, body=None, timeout=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.url + path, data=data, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout or REQUEST_TIMEOUT) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:300]
            raise HarnessError(f"{self.url}{path} returned HTTP {e.code}: {detail}") from e
        except (urllib.error.URLError, OSError) as e:
            raise HarnessError(f"could not reach {self.url}{path}: {e}") from e
        except json.JSONDecodeError as e:
            raise HarnessError(f"{self.url}{path} returned something that isn't JSON: {e}") from e

    def check(self):
        try:
            self._request("/health", timeout=10)
        except HarnessError as e:
            raise HarnessError(f"no llama.cpp server is ready at {self.url} ({e}). "
                               "Start one first; evals/README.md has the command.") from e

    def props(self):
        """The server's /props (build, model path, context size), or {} if it doesn't have one."""
        try:
            props = self._request("/props", timeout=10)
        except HarnessError:
            return {}
        return props if isinstance(props, dict) else {}

    def _with_template_kwargs(self, body):
        if self.template_kwargs:
            body["chat_template_kwargs"] = self.template_kwargs
        return body

    def render(self, messages):
        """The prompt text the chat template makes of `messages`, ending with the assistant header."""
        return self._request("/apply-template", self._with_template_kwargs({"messages": messages}))["prompt"]

    def count_tokens(self, text, add_special=False):
        return len(self._request("/tokenize", {"content": text, "add_special": add_special})["tokens"])

    def chat(self, messages, max_tokens):
        body = self._with_template_kwargs(
            {"messages": messages, "temperature": 0, "max_tokens": max_tokens, "cache_prompt": True})
        started = time.time()
        data = self._request("/v1/chat/completions", body)
        choice = data["choices"][0]
        return Answer(text=choice["message"].get("content") or "", max_tokens=max_tokens,
                      truncated=choice.get("finish_reason") == "length",
                      seconds=time.time() - started,
                      tokens=data.get("usage", {}).get("completion_tokens", 0))


# Baselines
#
# baselines.json records, per suite, how many cases (for meetings: checks) it has and which of
# them are known to fail. --check-baseline fails on any other failure, so a newly broken case
# can't hide behind a newly fixed one. "flaky" lists cases whose result differs between
# llama.cpp backends (CI's CPU build can pick a different token than Metal): they are reported
# but never gate, and one belongs there only after it has been seen to flip.


def load_baselines(suites=None):
    """{suite: {"total", "known_failures", "flaky"}}; with `suites`, each must have an entry."""
    if not BASELINES.is_file():
        raise HarnessError(f"{display(BASELINES)} not found")
    try:
        baselines = json.loads(BASELINES.read_text())
    except json.JSONDecodeError as e:
        raise HarnessError(f"{display(BASELINES)} is not valid JSON: {e}") from e
    if not isinstance(baselines, dict):
        raise HarnessError(f"{display(BASELINES)} must be an object of suites")
    for suite, entry in baselines.items():
        where = f"{display(BASELINES)}: {suite}"
        if not isinstance(entry, dict) or set(entry) - {"total", "known_failures", "flaky"}:
            raise HarnessError(f"{where} needs total, known_failures and optionally flaky")
        if not isinstance(entry.get("total"), int) or isinstance(entry.get("total"), bool):
            raise HarnessError(f"{where}: total must be a whole number")
        for key in ("known_failures", "flaky"):
            entry.setdefault(key, [])
            if entry[key]:
                string_list(entry[key], f"{where}.{key}")
        if set(entry["known_failures"]) & set(entry["flaky"]):
            raise HarnessError(f"{where}: a case is listed as both a known failure and flaky")
    missing = [s for s in suites or [] if s not in baselines]
    if missing:
        raise HarnessError(f"no baseline for {', '.join(missing)} in {display(BASELINES)}; "
                           "run with --update-baseline to record one")
    return baselines


@dataclass
class Verdict:
    """How one suite's run compares with its baseline."""
    unexpected: list = field(default_factory=list)  # failed, and not a known failure: a regression
    fixed: list = field(default_factory=list)  # known failures that passed this time
    stale: list = field(default_factory=list)  # baseline ids the suite no longer has
    size: str = ""  # set when the suite's size differs from the baseline's total

    @property
    def ok(self):
        return not (self.unexpected or self.stale or self.size)


def compare(outcomes, baseline):
    """Compares {id: passed} with one suite's baseline entry."""
    known, flaky = baseline["known_failures"], baseline["flaky"]
    verdict = Verdict(
        unexpected=[i for i, ok in outcomes.items() if not ok and i not in known and i not in flaky],
        fixed=[i for i in known if outcomes.get(i)],
        stale=[i for i in known + flaky if i not in outcomes])
    if baseline["total"] != len(outcomes):
        verdict.size = f"has {len(outcomes)} but the baseline was recorded with {baseline['total']}"
    return verdict


def update_baselines(scores):
    """Records each (suite, {id: passed}) as its total and known failures, keeping its flaky list."""
    baselines = load_baselines() if BASELINES.is_file() else {}
    for suite, outcomes in scores:
        flaky = [i for i in baselines.get(suite, {}).get("flaky", []) if i in outcomes]
        known = [i for i, ok in outcomes.items() if not ok and i not in flaky]
        entry = {"total": len(outcomes), "known_failures": known}
        if flaky:
            entry["flaky"] = flaky
        baselines[suite] = entry
    for entry in baselines.values():
        if not entry.get("flaky"):
            entry.pop("flaky", None)
    BASELINES.write_text(json.dumps(baselines, indent=2) + "\n")
    print(f"wrote {display(BASELINES)}")


def report_scores(scores, baselines, unit):
    """Prints a table of (suite, {id: passed}) against `baselines`, appends it to the GitHub job
    summary when there is one, and returns the suites that fail their baseline."""
    verdicts = {s: compare(outcomes, baselines[s]) for s, outcomes in scores if s in baselines}
    failing = [s for s, v in verdicts.items() if not v.ok]

    def status(suite):
        v = verdicts.get(suite)
        if v is None:
            return "no baseline"
        if v.unexpected:
            return f"{len(v.unexpected)} new failure{'s' if len(v.unexpected) > 1 else ''}"
        if v.stale or v.size:
            return "baseline out of date"
        return "ok"

    rows = []
    for suite, outcomes in scores:
        known = baselines.get(suite, {}).get("known_failures")
        rows.append((suite, f"{sum(outcomes.values())}/{len(outcomes)}", "-" if known is None else str(len(known)),
                     status(suite)))
    width = max(len(r[0]) for r in rows)
    print(f"\n{'suite':<{width}}  {'passed':>9}  {'known failures':>14}  status")
    for suite, passed, known, state in rows:
        print(f"{suite:<{width}}  {passed:>9}  {known:>14}  {state}")

    notes = []
    for suite, v in verdicts.items():
        if v.unexpected:
            notes.append(f"{suite}: failing, and not a known failure: {', '.join(v.unexpected)}")
        if v.stale:
            notes.append(f"{suite}: baselines.json lists {unit} the suite doesn't have: {', '.join(v.stale)}")
        if v.size:
            notes.append(f"{suite}: the suite {v.size} {unit}")
        if v.fixed:
            notes.append(f"{suite}: known failures that now pass: {', '.join(v.fixed)}. Take them out of "
                         f"known_failures in {display(BASELINES)} (or rerun with --update-baseline).")
    if any(v.stale or v.size for v in verdicts.values()):
        notes.append("After adding or removing cases, rerun the suite with --update-baseline and commit "
                     f"{display(BASELINES)} with them.")
    for note in notes:
        print(note)

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        lines = [f"| Suite | Passed ({unit}) | Known failures | Status |", "| --- | --- | --- | --- |"]
        lines += [f"| {' | '.join(row)} |" for row in rows]
        lines += [""] + [f"- {note}" for note in notes]
        with open(summary, "a") as f:
            f.write("\n".join(lines) + "\n\n")
    return failing


# Results and run manifests


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def git_revision():
    """{"commit", "dirty"} for the checkout, or None outside a git checkout."""
    def git(*args):
        return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, timeout=30)

    try:
        head = git("rev-parse", "HEAD")
        if head.returncode == 0:
            dirty = git("status", "--porcelain", "--untracked-files=no")
            return {"commit": head.stdout.strip(),
                    "dirty": bool(dirty.stdout.strip()) if dirty.returncode == 0 else None}
    except (OSError, subprocess.TimeoutExpired):
        pass
    sha = os.environ.get("GITHUB_SHA")
    return {"commit": sha, "dirty": None} if sha else None


def run_manifest(server):
    """What a result depends on besides the fixtures: when and how the run was made, the source
    revision, the model and the llama.cpp build."""
    props = server.props()
    model_path = props.get("model_path")
    model = None
    if isinstance(model_path, str) and model_path:
        model = {"file": Path(model_path).name, "sha256": None}
        if Path(model_path).is_file():  # the server is on this machine
            model["sha256"] = sha256_file(model_path)
    settings = props.get("default_generation_settings")
    return {
        "date": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "command": shlex.join([Path(sys.executable).name, *sys.argv]),
        "git": git_revision(),
        "model": model,
        "server": {"url": server.url, "build": props.get("build_info"),
                   "n_ctx": settings.get("n_ctx") if isinstance(settings, dict) else None},
        # Set by whoever starts the server, e.g. "llama.cpp b11351 CPU (AVX2)": the server
        # doesn't report whether it runs on the CPU or the GPU.
        "backend": os.environ.get("QUIETYPE_EVAL_BACKEND"),
        "host": {"platform": platform.platform(), "python": platform.python_version()},
    }


def write_results(name, report, print_json, manifest=None, fixtures=(), failed=()):
    """Writes results/<name>.json and, with a manifest, results/<name>.manifest.json."""
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / f"{name}.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    if manifest is not None:
        entry = dict(manifest, suite=name,
                     fixtures=[{"path": display(p), "sha256": sha256_file(p)} for p in fixtures],
                     failed=list(failed))
        (RESULTS / f"{name}.manifest.json").write_text(json.dumps(entry, indent=2, ensure_ascii=False) + "\n")
    if print_json:
        # One object per line between markers, so results can be read back out of a CI log.
        print(f"=== RESULTS {name} ===")
        for entry in report:
            print(json.dumps(entry, ensure_ascii=False))
        print(f"=== END {name} ===")
