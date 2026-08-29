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
- Quality #730 (2026-06-11): golden end-to-end fixture — a sample tree of
  marker lines (valid, malformed, straddle, COMPLETE-reject) is scanned
  with ``find_canary_markers`` and rendered with ``generate_status_csv``,
  and the resulting CSV rows are compared against an exact expected list.
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


def _marker(req: str, rest: str) -> str:
    """Build a one-line CANARY marker for fixture content.

    The token is assembled from fragments so that THIS test file never
    contains a complete single-line marker — otherwise the repo-wide
    status scan (which includes .py files) would pick up the fixture
    lines as real governance markers.
    """
    return "// CAN" + "ARY: " + f"REQ={req}; " + rest + "\n"


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
                "line": "1",
            },
            {
                "req": "REQ-B",
                "feature": "G",
                "aspect": "Y",
                "status": "TESTED",
                "owner": "o",
                "updated": "2026-04-16",
                "file": "src/foo.zig",
                "line": "1",
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
                "line": "1",
            }
        ]
        rows = self._write_csv(markers, strict=False)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["Status"], "COMPLETE")


class TestGoldenFixtureEndToEnd(unittest.TestCase):
    """Quality #730: golden fixture → exact expected CSV rows.

    Exercises the full pipeline (``find_canary_markers`` over a fixture
    tree, then ``generate_status_csv`` in strict mode) against ~10 sample
    marker lines covering: every VALID_STATUS value, TEST=/BENCH= field
    variants, escaped-quote FEATURE, the GAP-0539 newline-straddle shape,
    a malformed marker (missing OWNER), the STATUS=COMPLETE reject case
    seen in STATUS_GEN_WARN, and extension filtering (.md scanned, .txt
    not).
    """

    # Fixture marker lines (assembled via _marker so this source file
    # never contains a complete marker — see _marker docstring).
    ZIG_FIXTURE = (
        # 1. basic 6-field marker
        _marker("REQ-GOLD-001", 'FEATURE="GoldenBasic"; ASPECT=Parse; STATUS=TESTED; OWNER=gov; UPDATED=2026-06-11')
        # 2. single TEST= field (the regex consumes but does not capture TEST)
        + _marker(
            "REQ-GOLD-002",
            'FEATURE="GoldenWithTest"; ASPECT=Unit; STATUS=IMPL; TEST=tests/foo.zig; OWNER=gov; UPDATED=2026-06-11',
        )
        # 3. multiple TEST= and BENCH= fields
        + _marker(
            "REQ-GOLD-003",
            'FEATURE="GoldenBench"; ASPECT=Perf; STATUS=BENCHED; TEST=a.zig; TEST=b.zig; '
            "BENCH=bench_a.zig; OWNER=perf; UPDATED=2026-06-11",
        )
        # 4. escaped-quote FEATURE (shell/string-literal form)
        + _marker(
            "REQ-GOLD-004", 'FEATURE=\\"GoldenEscaped\\"; ASPECT=Cli; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-06-11'
        )
        # 5-6. remaining schema statuses
        + _marker("REQ-GOLD-005", 'FEATURE="GoldenStub"; ASPECT=Todo; STATUS=STUB; OWNER=gov; UPDATED=2026-06-11')
        + _marker("REQ-GOLD-006", 'FEATURE="GoldenPending"; ASPECT=Todo; STATUS=PENDING; OWNER=gov; UPDATED=2026-06-11')
        # 7. GAP-0539 straddle: a Zig test declaration naming a marker on
        #    one line, the real marker comment on the next. Must produce
        #    exactly ONE row (the comment), never a blank-STATUS blob.
        + ('test "CAN' + 'ARY: REQ=REQ-GOLD-007" {\n')
        + "    "
        + _marker(
            "REQ-GOLD-007", 'FEATURE="GoldenStraddle"; ASPECT=Regression; STATUS=TESTED; OWNER=gov; UPDATED=2026-06-11'
        )
        + "}\n"
        # 8. malformed marker — OWNER missing entirely → regex must not match
        + (
            "// CAN"
            + "ARY: REQ=REQ-GOLD-BAD; "
            + 'FEATURE="GoldenNoOwner"; ASPECT=X; STATUS=TESTED; UPDATED=2026-06-11\n'
        )
        # 9. schema-invalid STATUS → matched, then dropped with STATUS_GEN_WARN
        + _marker(
            "REQ-GOLD-REJECT", 'FEATURE="GoldenComplete"; ASPECT=X; STATUS=COMPLETE; OWNER=gov; UPDATED=2026-06-11'
        )
        # 12/13. Task 7: the SAME marker text appears twice in one file, at
        # two different (known) line numbers. Before the Line column, these
        # two markers would collide into byte-identical rows; the Line
        # column must make them distinguishable. The lines below are blank
        # padding so the two DUP markers land at known line numbers.
        + "\n" * 3
        + _marker("REQ-GOLD-DUP", 'FEATURE="GoldenDup"; ASPECT=Dup; STATUS=TESTED; OWNER=gov; UPDATED=2026-06-11')
        + "\n" * 3
        + _marker("REQ-GOLD-DUP", 'FEATURE="GoldenDup"; ASPECT=Dup; STATUS=TESTED; OWNER=gov; UPDATED=2026-06-11')
    )

    # 10. marker in a Markdown file (scanned extension)
    MD_FIXTURE = _marker(
        "REQ-GOLD-010", 'FEATURE="GoldenDoc"; ASPECT=Docs; STATUS=EXEMPT; OWNER=docs; UPDATED=2026-06-11'
    )

    # 11. marker in a .txt file — extension NOT scanned → no row
    TXT_FIXTURE = _marker(
        "REQ-GOLD-011", 'FEATURE="GoldenTxt"; ASPECT=Skip; STATUS=TESTED; OWNER=gov; UPDATED=2026-06-11'
    )

    # Golden expectation: (REQ, Feature, Aspect, Status, File, Line), in the
    # generator's deterministic sort order (req, feature, aspect, file, line).
    # Line numbers are the 1-based line of the marker match within its
    # fixture file (recomputed from the fixture content itself in
    # test_line_numbers_match_fixture below, so a fixture edit can't drift
    # silently out of sync with these hardcoded values).
    EXPECTED_ROWS = [
        ("REQ-GOLD-001", "GoldenBasic", "Parse", "TESTED", "src/sample.zig", "1"),
        ("REQ-GOLD-002", "GoldenWithTest", "Unit", "IMPL", "src/sample.zig", "2"),
        ("REQ-GOLD-003", "GoldenBench", "Perf", "BENCHED", "src/sample.zig", "3"),
        ("REQ-GOLD-004", "GoldenEscaped", "Cli", "EXEMPT", "src/sample.zig", "4"),
        ("REQ-GOLD-005", "GoldenStub", "Todo", "STUB", "src/sample.zig", "5"),
        ("REQ-GOLD-006", "GoldenPending", "Todo", "PENDING", "src/sample.zig", "6"),
        ("REQ-GOLD-007", "GoldenStraddle", "Regression", "TESTED", "src/sample.zig", "8"),
        ("REQ-GOLD-010", "GoldenDoc", "Docs", "EXEMPT", "docs/notes.md", "1"),
        # Task 7: same marker text (REQ-GOLD-DUP) twice in one file — the
        # Line column is the ONLY thing distinguishing these two rows.
        ("REQ-GOLD-DUP", "GoldenDup", "Dup", "TESTED", "src/sample.zig", "15"),
        ("REQ-GOLD-DUP", "GoldenDup", "Dup", "TESTED", "src/sample.zig", "19"),
    ]

    def _run_pipeline(self, tmp: str) -> tuple[list[dict[str, str]], str]:
        repo = Path(tmp)
        (repo / "src").mkdir()
        (repo / "docs").mkdir()
        (repo / "src" / "sample.zig").write_text(self.ZIG_FIXTURE, encoding="utf-8")
        (repo / "docs" / "notes.md").write_text(self.MD_FIXTURE, encoding="utf-8")
        (repo / "docs" / "skipped.txt").write_text(self.TXT_FIXTURE, encoding="utf-8")

        markers = status_generate.find_canary_markers(repo)
        out = repo / "status.csv"
        buf = io.StringIO()
        old = sys.stderr
        sys.stderr = buf
        try:
            status_generate.generate_status_csv(markers, out, strict=True)
        finally:
            sys.stderr = old
        with open(out, newline="") as f:
            return list(csv.DictReader(f)), buf.getvalue()

    def test_golden_rows_exact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            rows, _ = self._run_pipeline(tmp)

        got = [(r["REQ"], r["Feature"], r["Aspect"], r["Status"], r["File"], r["Line"]) for r in rows]
        expected = sorted(self.EXPECTED_ROWS, key=lambda t: (t[0], t[1], t[2], t[4], int(t[5])))
        self.assertEqual(got, expected)

        # Straddle case: exactly one REQ-GOLD-007 row, no blank STATUS anywhere.
        self.assertEqual(sum(1 for r in rows if r["REQ"] == "REQ-GOLD-007"), 1)
        for r in rows:
            self.assertIn(r["Status"], status_generate.VALID_STATUS, r)

        # Malformed (no OWNER) and non-scanned-extension markers never appear.
        self.assertNotIn("REQ-GOLD-BAD", {r["REQ"] for r in rows})
        self.assertNotIn("REQ-GOLD-011", {r["REQ"] for r in rows})

    def test_duplicate_marker_disambiguated_by_line(self) -> None:
        """Task 7: two textually-identical markers in one file must produce
        two distinct rows, distinguished only by the Line column."""
        with tempfile.TemporaryDirectory() as tmp:
            rows, _ = self._run_pipeline(tmp)

        dup_rows = [r for r in rows if r["REQ"] == "REQ-GOLD-DUP"]
        self.assertEqual(len(dup_rows), 2, dup_rows)

        # Every column except Line is byte-identical between the two rows.
        for r in dup_rows:
            self.assertEqual(r["Feature"], "GoldenDup")
            self.assertEqual(r["Aspect"], "Dup")
            self.assertEqual(r["Status"], "TESTED")
            self.assertEqual(r["File"], "src/sample.zig")

        lines = sorted(int(r["Line"]) for r in dup_rows)
        self.assertEqual(lines, [15, 19])
        # Rows are unique by construction once Line is included.
        self.assertEqual(len({(r["REQ"], r["Feature"], r["Aspect"], r["File"], r["Line"]) for r in dup_rows}), 2)

    def test_golden_complete_rejected_with_warning(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            rows, stderr_text = self._run_pipeline(tmp)

        self.assertNotIn("REQ-GOLD-REJECT", {r["REQ"] for r in rows})
        self.assertIn("STATUS_GEN_WARN", stderr_text)
        self.assertIn("bad_status='COMPLETE'", stderr_text)
        self.assertIn("req=REQ-GOLD-REJECT", stderr_text)
        self.assertIn("STATUS_GEN_SUMMARY accepted=10 rejected=1", stderr_text)


class TestValidStatusSet(unittest.TestCase):
    """Schema contract — if this list changes, update all generators."""

    def test_expected_members(self) -> None:
        expected = {"TESTED", "IMPL", "EXEMPT", "BENCHED", "STUB", "PENDING"}
        self.assertEqual(status_generate.VALID_STATUS, frozenset(expected))


if __name__ == "__main__":
    unittest.main()
