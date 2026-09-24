#!/usr/bin/env python3
"""Turns one test run into a report an LLM can act on.

Reads whatever the run left behind — the swift-testing event stream, the UI result bundle, the
release build log — and writes three things next to them:

    results.json   every test, every failure, machine-readable
    report.md      the same thing as prose, failures first
    summary.txt    one line per suite, for the console

The ordering principle throughout is that a reader should reach the failures before anything
else, and should never have to open a raw log to understand one: each failure carries its
suite, its own sentence-long name, the source location, the message, and — for a UI test — the
steps it got through and the screenshots it captured.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# ----------------------------------------------------------------- environment


def read_environment(run: Path) -> dict:
    env = {}
    path = run / "environment.txt"
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                env[key] = value
    return env


# ------------------------------------------------------------------ core suites
#
# swift-testing's event stream is one JSON object per line. Two of them matter: a "test" record
# introduces a test and carries the human-readable name and source location, and an "event"
# record reports what happened to it. Failures arrive as issueRecorded events before the
# testEnded, so issues are attached to the test id as they are seen.


def parse_core(run: Path) -> dict | None:
    stream = run / "raw" / "core-events.jsonl"
    if not stream.exists():
        return None

    known: dict[str, dict] = {}
    issues: dict[str, list] = {}
    started: dict[str, float] = {}
    ended: dict[str, float] = {}
    skipped: set[str] = set()

    for line in stream.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue

        payload = record.get("payload", {})
        if record.get("kind") == "test":
            known[payload.get("id", "")] = payload
            continue
        if record.get("kind") != "event":
            continue

        kind = payload.get("kind")
        test_id = payload.get("testID")
        instant = payload.get("instant", {}).get("absolute")
        if kind == "testStarted" and test_id and instant is not None:
            started[test_id] = instant
        elif kind == "testEnded" and test_id and instant is not None:
            ended[test_id] = instant
        elif kind == "testSkipped" and test_id:
            skipped.add(test_id)
        elif kind == "issueRecorded" and test_id:
            issue = payload.get("issue", {})
            location = issue.get("sourceLocation") or {}
            text = " ".join(
                message.get("text", "")
                for message in payload.get("messages", [])
                if message.get("symbol") in (None, "fail", "default", "details")
            ).strip()
            issues.setdefault(test_id, []).append(
                {
                    "message": text or issue.get("_backtrace", ""),
                    "file": location.get("fileID", ""),
                    "line": location.get("line"),
                    "known_issue": bool(issue.get("isKnown")),
                }
            )

    tests = []
    for test_id, payload in known.items():
        if payload.get("kind") != "function":
            continue  # suites are containers, not results
        real_issues = [i for i in issues.get(test_id, []) if not i["known_issue"]]
        if test_id in skipped:
            status = "skipped"
        elif real_issues:
            status = "failed"
        else:
            status = "passed"
        duration = None
        if test_id in started and test_id in ended:
            duration = round(ended[test_id] - started[test_id], 4)
        location = payload.get("sourceLocation") or {}
        tests.append(
            {
                "suite": suite_of(test_id, known),
                "name": payload.get("displayName") or payload.get("name", ""),
                "function": payload.get("name", ""),
                "status": status,
                "duration": duration,
                "file": location.get("fileID", ""),
                "line": location.get("line"),
                "failures": real_issues,
            }
        )

    tests.sort(key=lambda t: (t["suite"], t["name"]))
    return {"name": "Core (domain, application, storage)", "tests": tests}


def suite_of(test_id: str, known: dict) -> str:
    """The display name of the suite a test belongs to, falling back to its type name."""
    container = test_id.split("/")[0]
    payload = known.get(container)
    if payload:
        return payload.get("displayName") or payload.get("name") or container
    return container.split(".")[-1]


# -------------------------------------------------------------------- UI suites


def parse_ui(run: Path) -> dict | None:
    # One bundle per test class: each runs against its own throwaway service, because the tour
    # needs the demo fixture and the journeys need an empty practice.
    bundles = sorted((run / "raw").glob("*.xcresult")) if (run / "raw").exists() else []
    log = run / "logs" / "ui.log"
    build_log = run / "logs" / "ui-build.log"
    if not bundles:
        if log.exists():
            return parse_ui_log(run)
        # The suites were built but never ran, or never even built. Either way the report has to
        # carry an empty UI suite rather than leaving it out: a missing section reads as "there
        # were no UI tests", which is the opposite of what happened.
        if build_log.exists():
            return {"name": "UI (simulator journeys)", "tests": [], "log": "ui-build.log"}
        return None

    merged: list[dict] = []
    device = ""
    unreadable = False
    for bundle in bundles:
        suite = parse_ui_bundle(run, bundle)
        if suite is None:
            unreadable = True
            continue
        merged.extend(suite["tests"])
        device = device or suite.get("device", "")
    if unreadable and not merged:
        return parse_ui_log(run)
    merged.sort(key=lambda t: (t["suite"], t["name"]))
    return {
        "name": "UI (simulator journeys)",
        "tests": merged,
        "device": device,
        "log": "ui.log",
    }


def parse_ui_bundle(run: Path, bundle: Path) -> dict | None:
    payload = xcresult(bundle, "tests")
    if payload is None:
        # The bundle exists but cannot be read, which is what a killed or timed-out xcodebuild
        # leaves behind. The caller falls back to the log, which still knows what ran.
        return None
    tests: list[dict] = []
    if payload:
        for node in payload.get("testNodes", []):
            walk_test_nodes(node, [], tests)

    # The summary carries failure text in a flatter form. Where the node tree gave a test no
    # message — which happens when the failure was raised outside an assertion — this fills it
    # in rather than reporting a failure with nothing said about it.
    summary = xcresult(bundle, "summary") or {}
    by_name = {t["function"]: t for t in tests}
    for failure in summary.get("testFailures", []):
        target = by_name.get(failure.get("testName", ""))
        if target and not target["failures"]:
            target["failures"].append(
                {"message": failure.get("failureText", ""), "file": "", "line": None}
            )

    # The result bundle records what went wrong but not where: its failure messages carry no
    # source location. The console log has it, and the file and line are the first thing anyone
    # reading a failure wants, so the two are put back together here.
    located = log_failure_locations(run)
    for name, places in located.items():
        target = by_name.get(name) or by_name.get(name + "()")
        if not target:
            continue
        for failure, place in zip(target["failures"], places):
            if not failure["file"]:
                failure["file"] = place["file"]
                failure["line"] = place["line"]
        if not target["file"] and places:
            target["file"] = places[0]["file"]
            target["line"] = places[0]["line"]

    tests.sort(key=lambda t: (t["suite"], t["name"]))
    return {
        "name": "UI (simulator journeys)",
        "tests": tests,
        "device": ", ".join(
            d.get("deviceName", "") for d in (summary.get("devicesAndConfigurations") or [])
            for d in [d.get("device", {})]
        ).strip(", "),
    }


XCTEST_RESULT = re.compile(
    r"^Test Case '-\[(?P<suite>[\w.]+) (?P<name>\w+)\]' (?P<outcome>passed|failed)"
    r"(?: \((?P<seconds>[\d.]+) seconds\))?"
)
XCTEST_FAILURE = re.compile(
    r"^(?P<file>[^:]+\.swift):(?P<line>\d+): error: -\[[\w.]+ (?P<name>\w+)\] : (?P<message>.*)$"
)


def log_failure_locations(run: Path) -> dict[str, list]:
    """Where each XCTest failure was raised, keyed by test function name."""
    log = run / "logs" / "ui.log"
    if not log.exists():
        return {}
    found: dict[str, list] = {}
    for line in log.read_text(errors="replace").splitlines():
        match = XCTEST_FAILURE.match(line.strip())
        if match:
            found.setdefault(match.group("name"), []).append(
                {
                    "file": Path(match.group("file")).name,
                    "line": int(match.group("line")),
                    "message": match.group("message").strip(),
                }
            )
    return found


def parse_ui_log(run: Path) -> dict:
    """The UI results as the console reported them, for when the result bundle is unusable."""
    text = (run / "logs" / "ui.log").read_text(errors="replace")
    tests: dict[str, dict] = {}
    failures = log_failure_locations(run)

    for line in text.splitlines():
        match = XCTEST_RESULT.match(line.strip())
        if match:
            name = match.group("name")
            tests[name] = {
                "suite": match.group("suite").split(".")[-1],
                "name": humanise(name),
                "function": name,
                "status": match.group("outcome"),
                "duration": float(match.group("seconds")) if match.group("seconds") else None,
                "file": "",
                "line": None,
                "failures": [],
            }

    for name, found in failures.items():
        if name in tests:
            tests[name]["failures"] = found
            tests[name]["file"] = found[0]["file"]
            tests[name]["line"] = found[0]["line"]

    results = sorted(tests.values(), key=lambda t: (t["suite"], t["name"]))
    return {
        "name": "UI (simulator journeys)",
        "tests": results,
        "device": "",
        "from_log": True,
    }


def walk_test_nodes(node: dict, path: list[str], out: list[dict]) -> None:
    node_type = node.get("nodeType", "")
    name = node.get("name", "")

    if node_type == "Test Case":
        failures = []
        collect_failures(node, failures)
        result = (node.get("result") or "").lower()
        status = {"passed": "passed", "failed": "failed", "skipped": "skipped"}.get(
            result, "failed" if failures else "passed"
        )
        out.append(
            {
                "suite": path[-1] if path else "",
                "name": humanise(name),
                "function": name,
                "status": status,
                "duration": parse_duration(node.get("duration")),
                "file": failures[0]["file"] if failures else "",
                "line": failures[0]["line"] if failures else None,
                "failures": failures,
            }
        )
        return

    deeper = path + [name] if node_type in ("Test Suite", "Unit test bundle", "UI test bundle") else path
    for child in node.get("children", []) or []:
        walk_test_nodes(child, deeper, out)


FAILURE_LOCATION = re.compile(r"^(?P<file>[\w+./-]+\.swift):(?P<line>\d+):?\s*(?P<rest>.*)$", re.S)


def collect_failures(node: dict, out: list[dict]) -> None:
    for child in node.get("children", []) or []:
        if child.get("nodeType") in ("Failure Message", "Error Message"):
            text = child.get("name", "")
            match = FAILURE_LOCATION.match(text)
            if match:
                out.append(
                    {
                        "message": match.group("rest").strip(),
                        "file": match.group("file"),
                        "line": int(match.group("line")),
                    }
                )
            else:
                out.append({"message": text, "file": "", "line": None})
        else:
            collect_failures(child, out)


def parse_duration(value) -> float | None:
    """xcresulttool reports durations as text like '14s' or '1m 3s'."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return round(float(value), 4)
    total = 0.0
    for amount, unit in re.findall(r"([\d.]+)\s*(ms|m|s)", str(value)):
        total += float(amount) * {"ms": 0.001, "s": 1.0, "m": 60.0}[unit]
    return round(total, 4) if total else None


def humanise(function_name: str) -> str:
    """testUndoALoggedSession() -> 'Undo a logged session'.

    An XCTest name is the only description those tests carry, so it is worth reading as a
    sentence. Both camel-case boundaries matter: the common one after a lower-case letter, and
    the one inside a run of capitals ("ALogged" is "A Logged", not "ALogged").
    """
    bare = function_name.removesuffix("()")
    bare = bare[4:] if bare.startswith("test") else bare
    spaced = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", bare)
    spaced = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", " ", spaced)
    words = spaced.split()
    if not words:
        return function_name
    # Sentence case, leaving anything genuinely upper-case (an acronym) alone.
    rest = [w if w.isupper() and len(w) > 1 else w.lower() for w in words[1:]]
    return " ".join([words[0][:1].upper() + words[0][1:]] + rest)


def xcresult(bundle: Path, subcommand: str) -> dict | None:
    try:
        output = subprocess.run(
            [
                "xcrun", "xcresulttool", "get", "test-results", subcommand,
                "--path", str(bundle), "--format", "json",
            ],
            capture_output=True, text=True, timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if output.returncode != 0:
        return None
    try:
        return json.loads(output.stdout)
    except json.JSONDecodeError:
        return None


# ------------------------------------------------------------------ screenshots
#
# The tour names every capture ("07-log-session"), and XCTest adds its own attachments — screen
# recordings and synthesised event dumps — when a test fails. Both are worth keeping, but only
# the named captures belong in the gallery, so they are separated by name.

CAPTURE = re.compile(r"^\d{2}[a-z]?-")
UUID_SUFFIX = re.compile(r"_\d+_[0-9A-F-]{36}")


def collect_screens(run: Path) -> list[dict]:
    source = run / "raw" / "attachments"
    manifest = source / "manifest.json"
    if not manifest.exists():
        return []

    destination = run / "screens"
    destination.mkdir(exist_ok=True)
    screens = []
    try:
        entries = json.loads(manifest.read_text())
    except json.JSONDecodeError:
        return []

    for entry in entries:
        test = entry.get("testIdentifier") or entry.get("testIdentifierURL") or ""
        for attachment in entry.get("attachments", []) or []:
            name = attachment.get("suggestedHumanReadableName") or ""
            exported = attachment.get("exportedFileName")
            if not exported or not name:
                continue
            clean = UUID_SUFFIX.sub("", name)
            if not clean.lower().endswith(".png"):
                clean += ".png"
            if not CAPTURE.match(clean):
                continue
            origin = source / exported
            if not origin.exists():
                continue
            shutil.copy(origin, destination / clean)
            screens.append({"file": f"screens/{clean}", "test": str(test)})

    screens.sort(key=lambda s: s["file"])
    return screens


def link_latest_gallery(run: Path) -> None:
    """Points app/build/screens at this run's screens, for design review.

    Reviewing a gallery means opening the same path twice and seeing what changed, which a
    timestamped directory cannot offer. Only runs that actually captured screens move the link,
    so a core-only run leaves the last gallery where it was.
    """
    # Resolved, because the link is read from its own directory rather than from wherever the
    # script happened to be run.
    screens = (run / "screens").resolve()
    gallery = run.resolve().parent.parent / "screens"
    try:
        if gallery.is_symlink() or gallery.is_file():
            gallery.unlink()
        elif gallery.is_dir():
            shutil.rmtree(gallery)
        gallery.symlink_to(screens, target_is_directory=True)
    except OSError:
        # A gallery link is a convenience. Failing to make one is not worth failing a run over.
        pass


# ---------------------------------------------------------------- release build

ERROR_LINE = re.compile(r"(?:^|\s)(error|warning):\s")


def parse_release(run: Path) -> dict | None:
    log = run / "logs" / "release.log"
    if not log.exists():
        return None
    text = log.read_text(errors="replace")
    succeeded = "** BUILD SUCCEEDED **" in text
    errors = [
        line.strip()
        for line in text.splitlines()
        if ": error:" in line or line.strip().startswith("error:")
    ]
    return {
        "name": "Release build (generic iOS device, unsigned)",
        "status": "passed" if succeeded else "failed",
        "errors": dedupe(errors)[:40],
    }


def dedupe(items: list[str]) -> list[str]:
    seen, out = set(), []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def build_errors(run: Path, log_name: str) -> list[str]:
    """Compiler and linker errors from a log, for when a suite never got as far as running."""
    log = run / "logs" / log_name
    if not log.exists():
        return []
    text = log.read_text(errors="replace")
    errors = [
        line.strip()
        for line in text.splitlines()
        if ": error:" in line or line.strip().startswith("error:")
    ]
    return dedupe(errors)[:40]


# ---------------------------------------------------------------------- writing


def tally(suite: dict) -> dict:
    counts = {"passed": 0, "failed": 0, "skipped": 0}
    for test in suite["tests"]:
        counts[test["status"]] = counts.get(test["status"], 0) + 1
    counts["total"] = len(suite["tests"])
    return counts


def main(run: Path) -> int:
    environment = read_environment(run)
    suites = []
    for parse, log_name in ((parse_core, "core.log"), (parse_ui, "ui.log")):
        suite = parse(run)
        if suite is not None:
            suite.setdefault("log", log_name)
            suite["counts"] = tally(suite)
            suites.append(suite)
    release = parse_release(run)
    screens = collect_screens(run)

    # A requested suite can fail before it creates even an empty result file. Represent that as a
    # zero-test suite so the existing did-not-run handling makes the report fail instead of silently
    # omitting the suite and claiming that everything passed.
    requested_suites = (
        ("ran_core", "Core (domain, application, storage)", "core.log"),
        ("ran_ui", "UI (simulator journeys)", "ui-build.log"),
    )
    present = {suite["name"] for suite in suites}
    for flag, name, log_name in requested_suites:
        if environment.get(flag) == "1" and name not in present:
            missing = {"name": name, "tests": [], "log": log_name}
            missing["counts"] = tally(missing)
            suites.append(missing)
    if environment.get("ran_release") == "1" and release is None:
        release = {
            "name": "Release build (generic iOS device, unsigned)",
            "status": "failed",
            "errors": ["The requested Release build produced no log."],
        }

    # A suite that produced no tests at all did not pass — it failed to build or failed to
    # start, and saying "0 failures" about it would be the most misleading thing in the report.
    for suite in suites:
        if suite["counts"]["total"] == 0:
            suite["did_not_run"] = True
            suite["build_errors"] = build_errors(run, suite["log"])

    failed = [
        (suite, test)
        for suite in suites
        for test in suite["tests"]
        if test["status"] == "failed"
    ]
    broken = [s for s in suites if s.get("did_not_run")]
    release_failed = release is not None and release["status"] == "failed"
    timed_out = environment.get("ui_timed_out") == "yes"
    verdict = "failed" if (failed or broken or release_failed or timed_out) else "passed"

    results = {
        "verdict": verdict,
        "incomplete": timed_out,
        "environment": environment,
        "suites": suites,
        "release": release,
        "screens": screens,
        "totals": {
            "tests": sum(s["counts"]["total"] for s in suites),
            "failed": sum(s["counts"]["failed"] for s in suites),
            "skipped": sum(s["counts"]["skipped"] for s in suites),
        },
    }
    if screens:
        link_latest_gallery(run)

    (run / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    (run / "report.md").write_text(render(results, run))
    (run / "summary.txt").write_text(render_summary(results))
    print(render_summary(results), end="")
    return 0 if verdict == "passed" else 1


def joined(items: list[str]) -> str:
    if len(items) == 1:
        return items[0]
    return ", ".join(items[:-1]) + " and " + items[-1]


def render_summary(results: dict) -> str:
    lines = []
    for suite in results["suites"]:
        counts = suite["counts"]
        if suite.get("did_not_run"):
            lines.append(f"     {suite['name']}: DID NOT RUN (build failure)")
        else:
            lines.append(
                f"     {suite['name']}: {counts['passed']}/{counts['total']} passed"
                + (f", {counts['failed']} failed" if counts["failed"] else "")
                + (f", {counts['skipped']} skipped" if counts["skipped"] else "")
            )
    if results["release"]:
        lines.append(f"     Release build: {results['release']['status']}")
    lines.append(f"     Verdict: {results['verdict'].upper()}")
    return "\n".join(lines) + "\n"


def render(results: dict, run: Path) -> str:
    environment = results["environment"]
    out: list[str] = []
    add = out.append

    add(f"# Sankalpa test run — {results['verdict'].upper()}")
    add("")
    if results.get("incomplete"):
        add("> **This run was stopped before it finished.** The UI suites exceeded their time "
            "limit and were killed, so the results below cover only the tests that had already "
            "reported. Treat anything absent as unknown, not as passing.")
        add("")
    add(f"`{run.name}` · commit `{environment.get('git_commit', '?')}`"
        f" on `{environment.get('git_branch', '?')}`"
        + (" · **uncommitted changes present**" if environment.get("git_dirty") == "yes" else ""))
    add("")

    # A report that simply leaves out the suites this run was told not to run reads as though
    # they do not exist. Saying which were skipped is the difference between "everything
    # passed" and "everything that was asked for passed".
    skipped = [
        label
        for key, label in (
            ("ran_core", "the core suites"),
            ("ran_ui", "the UI suites"),
            ("ran_release", "the Release build"),
        )
        if environment.get(key) == "0"
    ]
    if skipped:
        add(f"This run was asked to skip {joined(skipped)}. Nothing below says anything about "
            "them, one way or the other.")
        add("")

    # ------------------------------------------------------------- what to look at
    failed = [
        (suite, test)
        for suite in results["suites"]
        for test in suite["tests"]
        if test["status"] == "failed"
    ]
    broken = [s for s in results["suites"] if s.get("did_not_run")]

    add("## Result")
    add("")
    add("| Suite | Passed | Failed | Skipped |")
    add("| --- | --- | --- | --- |")
    for suite in results["suites"]:
        counts = suite["counts"]
        if suite.get("did_not_run"):
            add(f"| {suite['name']} | — | **did not run** | — |")
        else:
            add(f"| {suite['name']} | {counts['passed']} | "
                f"{'**' + str(counts['failed']) + '**' if counts['failed'] else '0'} | "
                f"{counts['skipped']} |")
    if results["release"]:
        state = results["release"]["status"]
        add(f"| {results['release']['name']} | {'1' if state == 'passed' else '—'} | "
            f"{'**1**' if state == 'failed' else '0'} | 0 |")
    add("")

    if not failed and not broken and not (results["release"] and results["release"]["status"] == "failed"):
        add("Everything that ran, passed.")
        add("")

    # ------------------------------------------------------------------- failures
    if broken:
        add("## Suites that never ran")
        add("")
        add("A suite with no results did not pass — it failed to build or failed to start.")
        add("")
        for suite in broken:
            add(f"### {suite['name']}")
            add("")
            if suite.get("build_errors"):
                add("```")
                for error in suite["build_errors"]:
                    add(error)
                add("```")
            else:
                add("No compiler errors were found in the log; read the raw log for the cause.")
            add("")

    if failed:
        add("## Failures")
        add("")
        for suite, test in failed:
            add(f"### {test['name']}")
            add("")
            add(f"- **Suite:** {suite['name']} → {test['suite']}")
            add(f"- **Test:** `{test['function']}`")
            if test["file"]:
                add(f"- **Source:** `{test['file']}"
                    + (f":{test['line']}" if test["line"] else "") + "`")
            add("")
            for failure in test["failures"]:
                location = failure.get("file") or ""
                if location and failure.get("line"):
                    location = f"{location}:{failure['line']}"
                add(f"```\n{location + ': ' if location else ''}{failure['message']}\n```")
                add("")
            shots = [s for s in results["screens"] if test["function"].rstrip("()") in s["test"]]
            if shots:
                add("Screens this test captured before it failed: "
                    + ", ".join(f"`{s['file']}`" for s in shots))
                add("")

    if results["release"] and results["release"]["status"] == "failed":
        add("## Release build failed")
        add("")
        if results["release"]["errors"]:
            add("```")
            for error in results["release"]["errors"]:
                add(error)
            add("```")
        else:
            add("No compiler errors were matched; read `logs/release.log`.")
        add("")

    # -------------------------------------------------------------- what passed
    add("## Everything that ran")
    add("")
    for suite in results["suites"]:
        if suite.get("did_not_run"):
            continue
        add(f"### {suite['name']}")
        add("")
        if suite.get("from_log"):
            add("_Read from the console log: the result bundle was missing or unreadable, "
                "which is what an interrupted run leaves behind. Screenshots and per-step "
                "detail are not available for this suite._")
            add("")
        by_suite: dict[str, list] = {}
        for test in suite["tests"]:
            by_suite.setdefault(test["suite"], []).append(test)
        for group, tests in sorted(by_suite.items()):
            add(f"**{group}**")
            add("")
            for test in tests:
                mark = {"passed": "✓", "failed": "✗", "skipped": "–"}[test["status"]]
                seconds = (
                    f" ({test['duration']:.2f}s)"
                    if test["duration"] and test["duration"] >= 0.01
                    else ""
                )
                add(f"- {mark} {test['name']}{seconds}")
            add("")

    # ------------------------------------------------------------------ evidence
    if results["screens"]:
        add("## Screens captured")
        add("")
        add(f"{len(results['screens'])} screenshots, in `screens/`. "
            "They are the app as it actually rendered, and are worth opening when a layout, "
            "a Dark Mode colour or an accessibility text size is in question.")
        add("")
        for screen in results["screens"]:
            add(f"- `{screen['file']}`")
        add("")

    # --------------------------------------------------------------- the slowest
    timed = [
        test
        for suite in results["suites"]
        for test in suite["tests"]
        if test["duration"] and test["duration"] >= 0.01
    ]
    timed.sort(key=lambda t: -t["duration"])
    if timed:
        add("## Slowest tests")
        add("")
        for test in timed[:10]:
            add(f"- {test['duration']:.2f}s — {test['name']}")
        add("")

    add("## Environment")
    add("")
    for key in (
        "xcode_version", "xcode_build", "macos_version", "device_name", "device_type",
        "runtime", "git_commit", "git_branch", "git_dirty", "started_at", "finished_at",
    ):
        if key in environment:
            add(f"- `{key}`: {environment[key]}")
    add("")
    add("Raw logs are in `logs/`, and the unprocessed result bundle and build output in `raw/`.")
    add("")
    return "\n".join(out)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: report.py <run directory>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(Path(sys.argv[1])))
