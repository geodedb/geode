#!/usr/bin/env python3
"""
Unit tests for canary_lint.py CANARY marker validation.
CANARY: REQ=REQ-CI-CANARY-LINT-TEST-001; FEATURE="CANARY Lint Unit Tests"; ASPECT=UnitTesting; STATUS=TESTED; TEST=test_canary_lint.py; OWNER=governance; UPDATED=2026-01-17

These tests validate the regex patterns used for CANARY marker linting,
specifically the fixes for GAP-0225 (repo-wide lint) and GAP-0226 (STATUS=IMPLEMENTED).
"""

import unittest
import re
import sys
import os

# Add tools directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from canary_lint import CANARY_COMPLETE_PATTERN, CANARY_LOOSE_PATTERN, CANARY_EXAMPLE_PATTERN, VALID_STATUSES


class TestCanaryCompletePattern(unittest.TestCase):
    """Test the complete CANARY marker pattern."""

    def test_basic_marker(self):
        """Test a basic complete marker."""
        line = '// CANARY: REQ=REQ-GQL-001; FEATURE="Test Feature"; ASPECT=Unit; STATUS=TESTED; OWNER=test; UPDATED=2026-01-17'
        match = CANARY_COMPLETE_PATTERN.search(line)
        self.assertIsNotNone(match)
        self.assertEqual(match.group('req'), 'REQ-GQL-001')
        self.assertEqual(match.group('feature'), 'Test Feature')
        self.assertEqual(match.group('aspect'), 'Unit')
        self.assertEqual(match.group('status'), 'TESTED')
        self.assertEqual(match.group('owner'), 'test')
        self.assertEqual(match.group('updated'), '2026-01-17')

    def test_marker_with_one_test(self):
        """Test marker with single TEST field."""
        line = '// CANARY: REQ=REQ-GQL-001; FEATURE="Test"; ASPECT=Unit; STATUS=TESTED; TEST=test_file.zig; OWNER=test; UPDATED=2026-01-17'
        match = CANARY_COMPLETE_PATTERN.search(line)
        self.assertIsNotNone(match)

    def test_marker_with_multiple_tests(self):
        """Test marker with multiple TEST fields (GAP-0225 fix)."""
        line = '// CANARY: REQ=REQ-GQL-001; FEATURE="Test"; ASPECT=Unit; STATUS=TESTED; TEST=spec.yml; TEST=test_file.zig; OWNER=test; UPDATED=2026-01-17'
        match = CANARY_COMPLETE_PATTERN.search(line)
        self.assertIsNotNone(match, "Should match markers with multiple TEST fields")

    def test_marker_with_bench(self):
        """Test marker with BENCH field."""
        line = '// CANARY: REQ=REQ-PERF-001; FEATURE="Perf"; ASPECT=Bench; STATUS=BENCHED; BENCH=benchmark.zig; OWNER=perf; UPDATED=2026-01-17'
        match = CANARY_COMPLETE_PATTERN.search(line)
        self.assertIsNotNone(match)

    def test_marker_with_test_and_bench(self):
        """Test marker with both TEST and BENCH fields."""
        line = '// CANARY: REQ=REQ-PERF-001; FEATURE="Perf"; ASPECT=Bench; STATUS=BENCHED; TEST=test.zig; BENCH=bench.zig; OWNER=perf; UPDATED=2026-01-17'
        match = CANARY_COMPLETE_PATTERN.search(line)
        self.assertIsNotNone(match)

    def test_escaped_quotes_in_feature(self):
        """Test marker with escaped quotes (GAP-0225 fix for shell scripts)."""
        line = '// CANARY: REQ=REQ-GQL-001; FEATURE=\\"Test Feature\\"; ASPECT=Unit; STATUS=TESTED; OWNER=test; UPDATED=2026-01-17'
        match = CANARY_COMPLETE_PATTERN.search(line)
        self.assertIsNotNone(match, "Should match markers with escaped quotes")

    def test_missing_owner(self):
        """Test marker missing OWNER field should not match."""
        line = '// CANARY: REQ=REQ-GQL-001; FEATURE="Test"; ASPECT=Unit; STATUS=TESTED; UPDATED=2026-01-17'
        match = CANARY_COMPLETE_PATTERN.search(line)
        self.assertIsNone(match, "Should not match markers missing OWNER")

    def test_missing_updated(self):
        """Test marker missing UPDATED field should not match."""
        line = '// CANARY: REQ=REQ-GQL-001; FEATURE="Test"; ASPECT=Unit; STATUS=TESTED; OWNER=test'
        match = CANARY_COMPLETE_PATTERN.search(line)
        self.assertIsNone(match, "Should not match markers missing UPDATED")


class TestCanaryLoosePattern(unittest.TestCase):
    """Test the loose CANARY marker pattern (used to detect formal markers)."""

    def test_formal_marker_detected(self):
        """Test that formal markers are detected."""
        line = '// CANARY: REQ=REQ-GQL-001; FEATURE="Test"'
        match = CANARY_LOOSE_PATTERN.search(line)
        self.assertIsNotNone(match)

    def test_escaped_quotes_detected(self):
        """Test that escaped quotes are detected."""
        line = '// CANARY: REQ=REQ-GQL-001; FEATURE=\\"Test\\"'
        match = CANARY_LOOSE_PATTERN.search(line)
        self.assertIsNotNone(match)

    def test_informal_marker_not_detected(self):
        """Test that informal markers (no FEATURE=) are not flagged."""
        line = '// CANARY: REQ=REQ-GQL-001; this is a comment'
        match = CANARY_LOOSE_PATTERN.search(line)
        self.assertIsNone(match)


class TestCanaryExamplePattern(unittest.TestCase):
    """Test the example pattern (used to skip documentation)."""

    def test_placeholder_req_xxx(self):
        """Test that REQ=REQ-XXX placeholder is detected."""
        line = 'CANARY: REQ=REQ-XXX; FEATURE="..."; ASPECT=...'
        match = CANARY_EXAMPLE_PATTERN.search(line)
        self.assertIsNotNone(match)

    def test_placeholder_req_gql_hash(self):
        """Test that REQ=REQ-GQL-### placeholder is detected."""
        line = 'CANARY: REQ=REQ-GQL-###; FEATURE="Name"; ASPECT=...'
        match = CANARY_EXAMPLE_PATTERN.search(line)
        self.assertIsNotNone(match)

    def test_canary_pattern_comment(self):
        """Test that 'CANARY pattern:' documentation is detected."""
        line = '# CANARY pattern: CANARY: REQ=...'
        match = CANARY_EXAMPLE_PATTERN.search(line)
        self.assertIsNotNone(match)

    def test_fstring_template(self):
        """Test that f-string templates are detected."""
        line = "f'{prefix} CANARY: REQ={req}; FEATURE=\"{feature}\"'"
        match = CANARY_EXAMPLE_PATTERN.search(line)
        self.assertIsNotNone(match)

    def test_real_marker_not_detected(self):
        """Test that real markers are not flagged as examples."""
        line = 'CANARY: REQ=REQ-GQL-001; FEATURE="RealFeature"; ASPECT=Unit'
        match = CANARY_EXAMPLE_PATTERN.search(line)
        self.assertIsNone(match)


class TestValidStatuses(unittest.TestCase):
    """Test the valid status values."""

    def test_valid_statuses(self):
        """Test that all expected statuses are valid."""
        expected = {'STUB', 'IMPL', 'TESTED', 'BENCHED', 'COMPLETE', 'EXEMPT'}
        self.assertEqual(VALID_STATUSES, expected)

    def test_implemented_not_valid(self):
        """Test that IMPLEMENTED is not a valid status (GAP-0226)."""
        self.assertNotIn('IMPLEMENTED', VALID_STATUSES)


class TestRealWorldMarkers(unittest.TestCase):
    """Test real markers from the codebase."""

    def test_test_file_marker(self):
        """Test marker format from test files."""
        line = '// CANARY: REQ=REQ-REPL-HISTORY-002; FEATURE="REPL Persistent History"; ASPECT=IntegrationTesting; STATUS=TESTED; TEST=geodetestlab/specs/shell_comprehensive_tests.yml; TEST=test_repl_history_integration; OWNER=repl; UPDATED=2025-10-05'
        match = CANARY_COMPLETE_PATTERN.search(line)
        self.assertIsNotNone(match)

    def test_shell_script_echo_marker(self):
        """Test marker format from shell script echo statements."""
        line = 'echo "CANARY: REQ=REQ-GQL-TYPE-CONV-001; FEATURE=\\"TypeConversionFunctions\\"; ASPECT=Functionality; STATUS=TESTED; TEST=TestCANARY; OWNER=eval; UPDATED=2025-01-05"'
        match = CANARY_COMPLETE_PATTERN.search(line)
        self.assertIsNotNone(match)

    def test_benchmark_file_marker(self):
        """Test marker format from benchmark files."""
        line = '// CANARY: REQ=REQ-PERF-PHASE5-003; FEATURE="EvalOptimization"; ASPECT=TESTING; STATUS=BENCHED; BENCH=benchmarks/phase5_5_string_concat.zig; OWNER=performance; UPDATED=2026-01-17'
        match = CANARY_COMPLETE_PATTERN.search(line)
        self.assertIsNotNone(match)


if __name__ == '__main__':
    unittest.main()
