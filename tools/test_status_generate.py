#!/usr/bin/env python3
"""
Unit tests for status_generate.py.
CANARY: REQ=REQ-CI-STATUS-GEN-TEST-001; FEATURE="StatusGenerateUnitTests"; ASPECT=UnitTesting; STATUS=TESTED; TEST=test_status_generate.py; OWNER=governance; UPDATED=2026-04-16

Regressions covered:

- GAP-0539: the CANARY regex must not straddle a newline (Zig test
  declaration `test "CANARY: REQ=REQ-X"` followed on the next line by the
  real marker).  Without the fix, req/feature/aspect/status captures
  would roll into a single multi-line blob, producing ~16 rows with a
  blank STATUS column.
- GAP-0539: non-schema STATUS values (e.g. `COMPLETE`) must be dropped
  with a warning rather than silently written to status.csv.
"""

import csv
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import status_generate  # noqa: E402


class TestCanaryRegexNoNewlineStraddle(unittest.TestCase):
    """GAP-0539: regex must not span multiple lines."""

    def test_zig_test_line_then_real_marker(self) -> None:
        """Zig `test \"CANARY: ...\" { ... }` must not absorb the marker below."""
        content = (
            'test "CANARY: REQ=REQ-GQL-FINANCIAL-NETWORK" {\n'
            "    // CANARY: REQ=REQ-GQL-FINANCIAL-NETWORK; "
            'FEATURE="FinancialNetwork"; ASPECT=Integration; STATUS=TESTED; '
            "TEST=foo; OWNER=team; UPDATED=2025-10-02\n"
        )
        matches = list(status_generate.CANARY_PATTERN.finditer(content))
        self.assertEqual(len(matches), 1, matches)
        m = matches[0]
        self.assertEqual(m.group("req"), "REQ-GQL-FINANCIAL-NETWORK")
        self.assertEqual(m.group("feature"), "FinancialNetwork")
        self.assertEqual(m.group("status"), "TESTED")

    def test_plain_marker_still_parses(self) -> None:
        """Regression: the basic 6-field marker must still work."""
        content = '// CANARY: REQ=REQ-A; FEATURE="F"; ASPECT=X; STATUS=IMPL; OWNER=o; UPDATED=2026-04-16\n'
        matches = list(status_generate.CANARY_PATTERN.finditer(content))
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0].group("status"), "IMPL")


class TestStrictStatusFilter(unittest.TestCase):
    """GAP-0539: non-schema STATUS values are dropped under strict mode."""

    def _write_csv(self, markers: list[dict[str, str]], strict: bool = True) -> list[dict[str, str]]:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "status.csv"
            status_generate.generate_status_csv(markers, out, strict=strict)
            with open(out, newline="") as f:
                return list(csv.DictReader(f))

    def test_drops_complete_status_strict(self) -> None:
        markers = [
            {
                "req": "REQ-A",
                "feature": "F",
                "aspect": "X",
                "status": "COMPLETE",
                "owner": "o",
                "updated": "2026-04-16",
                "file": "docs/foo.md",
            },
            {
                "req": "REQ-B",
                "feature": "G",
                "aspect": "Y",
                "status": "TESTED",
                "owner": "o",
                "updated": "2026-04-16",
                "file": "src/foo.zig",
            },
        ]
        # Capture stderr to confirm the warning is emitted.
        buf = io.StringIO()
        old = sys.stderr
        sys.stderr = buf
        try:
            rows = self._write_csv(markers, strict=True)
        finally:
            sys.stderr = old
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["REQ"], "REQ-B")
        self.assertIn("STATUS_GEN_WARN", buf.getvalue())
        self.assertIn("bad_status='COMPLETE'", buf.getvalue())

    def test_keeps_complete_status_non_strict(self) -> None:
        markers = [
            {
                "req": "REQ-A",
                "feature": "F",
                "aspect": "X",
                "status": "COMPLETE",
                "owner": "o",
                "updated": "2026-04-16",
                "file": "docs/foo.md",
            }
        ]
        rows = self._write_csv(markers, strict=False)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["Status"], "COMPLETE")


class TestValidStatusSet(unittest.TestCase):
    """Schema contract — if this list changes, update all generators."""

    def test_expected_members(self) -> None:
        expected = {"TESTED", "IMPL", "EXEMPT", "BENCHED", "STUB", "PENDING"}
        self.assertEqual(status_generate.VALID_STATUS, frozenset(expected))


if __name__ == "__main__":
    unittest.main()
