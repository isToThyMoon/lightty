import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "compatibility", Path(__file__).resolve().parents[1] / "check-agent-compatibility.py")
compatibility = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compatibility)


class CompatibilityReportTests(unittest.TestCase):
    def test_multiple_bundles_and_frameworks_count_each_test_once(self):
        # SwiftPM emits three nested XCTest summaries, then an empty bundle,
        # before Swift Testing. The empty bundle must not erase completed tests.
        output = """Test Suite 'MetadataTests' started at now.
Test Case '-[Module.MetadataTests testRename]' passed (0.1 seconds).
Test Case '-[Module.MetadataTests testDelete]' passed (0.1 seconds).
Executed 2 tests, with 0 failures
Executed 2 tests, with 0 failures
Executed 2 tests, with 0 failures
Executed 0 tests, with 0 failures
◇ Suite ContractTests started.
✔ Test run with 2 tests in 1 suite passed after 0.5 seconds.
"""
        result = compatibility.summarize({"status": "passed"}, output, ["MetadataTests", "ContractTests"])
        self.assertEqual(result, {"status": "passed", "tests": 4})
        result = compatibility.summarize({"status": "passed"}, output, ["RenamedSuite"])
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["missing_suites"], ["RenamedSuite"])

    def test_skips_empty_selection_and_process_failure_are_not_passes(self):
        cases = [
            ("passed", "Executed 0 tests, with 0 failures", "incomplete"),
            ("passed", "◇ Test contract() skipped: CLI is missing", "incomplete"),
            ("passed", "Test Case '-[Module.Test check]' skipped (0.0 seconds).", "incomplete"),
            ("failed", "", "failed"),
            ("timed-out", "", "timed-out"),
        ]
        for status, output, expected in cases:
            with self.subTest(status=status, output=output):
                result = compatibility.summarize({"status": status}, output, [])
                self.assertEqual(result["status"], expected)


if __name__ == "__main__":
    unittest.main()
