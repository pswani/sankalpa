#!/usr/bin/env python3
"""Regression tests for the test-run report."""

from __future__ import annotations

import json
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
