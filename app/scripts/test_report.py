#!/usr/bin/env python3
"""Regression tests for the test-run report."""

from __future__ import annotations

import json
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

import report


class ReportTests(unittest.TestCase):
    def run_report(self, environment: str, logs: dict[str, str]) -> dict:
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            (run / "logs").mkdir()
            (run / "raw").mkdir()
            (run / "environment.txt").write_text(environment)
            for name, contents in logs.items():
                (run / "logs" / name).write_text(contents)

            with redirect_stdout(StringIO()):
                exit_code = report.main(run)
            results = json.loads((run / "results.json").read_text())

            self.assertEqual(exit_code, 1)
            self.assertEqual(results["verdict"], "failed")
            return results

    def test_requested_core_suite_without_results_fails_the_report(self) -> None:
        results = self.run_report(
            "ran_core=1\nran_ui=0\nran_release=0\n",
            {"core.log": "Compiler.swift:1: error: compilation stopped\n"},
        )
        self.assertTrue(results["suites"][0]["did_not_run"])

    def test_requested_ui_suite_without_results_fails_the_report(self) -> None:
        results = self.run_report(
            "ran_core=0\nran_ui=1\nran_release=0\n",
            {},
        )
        self.assertTrue(results["suites"][0]["did_not_run"])

    def test_requested_release_without_a_log_fails_the_report(self) -> None:
        results = self.run_report(
            "ran_core=0\nran_ui=0\nran_release=1\n",
            {},
        )
        self.assertEqual(results["release"]["status"], "failed")

    def test_discovered_core_test_without_completion_is_not_passed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            (run / "raw").mkdir()
            records = [
                {"kind": "test", "payload": {"id": "Example/testInterrupted()", "kind": "function", "name": "testInterrupted()"}},
                {"kind": "event", "payload": {"kind": "testStarted", "testID": "Example/testInterrupted()", "instant": {"absolute": 1}}},
            ]
            (run / "raw/core-events.jsonl").write_text("\n".join(json.dumps(r) for r in records))
            result = report.parse_core(run)
            self.assertEqual(result["tests"][0]["status"], "failed")
            self.assertIn("did not finish", result["tests"][0]["failures"][0]["message"])

    def test_readable_bundle_does_not_hide_failed_unreadable_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            (run / "raw/ScreenTour.xcresult").mkdir(parents=True)
            (run / "raw/JourneyTests.xcresult").mkdir()
            (run / "logs").mkdir()
            (run / "logs/ui.log").write_text(
                "Test Case '-[SankalpaUITests.ScreenTour testTour]' passed (1.0 seconds).\n"
                "Test Case '-[SankalpaUITests.JourneyTests testExtension]' failed (2.0 seconds).\n")
            tour = {"tests": [{"suite": "ScreenTour", "function": "testTour()", "name": "Tour", "status": "passed"}]}
            with patch.object(report, "parse_ui_bundle", side_effect=lambda _, b: tour if b.stem == "ScreenTour" else None):
                result = report.parse_ui(run)
            self.assertEqual(len(result["tests"]), 2)
            self.assertEqual(next(t for t in result["tests"] if t["suite"] == "JourneyTests")["status"], "failed")

    def test_nonzero_command_exit_cannot_be_reported_as_passed(self) -> None:
        results = self.run_report(
            "ran_core=0\nran_ui=1\nran_release=0\nui_exit_status=65\n",
            {"ui.log": "Test Case '-[SankalpaUITests.JourneyTests testExtension]' passed (2.0 seconds).\n"})
        self.assertEqual(results["totals"]["failed"], 0)
        self.assertEqual(results["command_failures"], {"ui_exit_status": "65"})

    def test_core_report_includes_conversation_xctest_results(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            (run / "raw").mkdir()
            (run / "logs").mkdir()
            (run / "raw/core-events.jsonl").write_text("")
            (run / "logs/core.log").write_text(
                "Test Case '-[SankalpaConversationTests.AGUITests testConfirmation]' passed (0.01 seconds).\n")
            suite = report.parse_core(run)
            self.assertEqual(suite["tests"][0]["suite"], "AGUITests")
            self.assertEqual(suite["tests"][0]["status"], "passed")

    def test_screenshot_manifests_from_both_native_suites_are_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            for suite, name in (("ScreenTour", "01-today"), ("JourneyTests", "50-extension-preview")):
                source = run / "raw/attachments" / suite
                source.mkdir(parents=True)
                (source / "capture.png").write_bytes(name.encode())
                (source / "manifest.json").write_text(json.dumps([{
                    "testIdentifier": suite,
                    "attachments": [{"suggestedHumanReadableName": name, "exportedFileName": "capture.png"}],
                }]))
            screens = report.collect_screens(run)
            self.assertEqual(len(screens), 2)
            self.assertEqual((run / "screens/01-today.png").read_bytes(), b"01-today")
            self.assertEqual((run / "screens/50-extension-preview.png").read_bytes(), b"50-extension-preview")


if __name__ == "__main__":
    unittest.main()
