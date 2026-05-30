#!/usr/bin/env python3
"""Regression tests for scripts/ci/check_harness_results.py.

The gate this exercises replaced an inline CI check that read top-level
``total``/``failed`` keys from the nested ``{"summary": {...}}`` results.json
schema -- meaning it always saw 0 and the harness job was permanently green.
These tests pin the corrected behaviour: fail closed on real failures, on a
crashed/aborted run (zero specs), on inconsistent counts, and on a
missing/malformed report; pass only on a complete all-green run.

Runs both standalone (``python3 scripts/test/test_check_harness_results.py``)
and under pytest -- the test functions take no fixtures and manage their own
temp files so no pytest dependency is required.
"""

from __future__ import annotations

import importlib.util
import json
import tempfile
from pathlib import Path

_GATE = Path(__file__).resolve().parents[1] / "ci" / "check_harness_results.py"
_spec = importlib.util.spec_from_file_location("check_harness_results", _GATE)
assert _spec is not None and _spec.loader is not None
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)


def _run(payload: object | None, *, raw: str | None = None) -> int:
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "results.json"
        if raw is not None:
            path.write_text(raw)
        elif payload is not None:
            path.write_text(json.dumps(payload))
            # else: leave the file absent
        return gate.main(["check", str(path)])


def test_all_pass_with_skips_returns_0() -> None:
    assert _run({"summary": {"total": 302, "passed": 300, "failed": 0, "skipped": 2}}) == 0


def test_real_failures_return_1() -> None:
    assert _run({"summary": {"total": 302, "passed": 300, "failed": 2, "skipped": 0}}) == 1


def test_crash_zero_total_returns_1() -> None:
    # The exact shape the old gate reported as "Total: 0 ... All specs passed".
    assert _run({"summary": {"total": 0, "passed": 0, "failed": 0, "skipped": 0}, "specs": []}) == 1


def test_inconsistent_counts_return_1() -> None:
    assert _run({"summary": {"total": 302, "passed": 1, "failed": 0, "skipped": 0}}) == 1


def test_missing_file_returns_1() -> None:
    assert _run(None) == 1


def test_malformed_json_returns_1() -> None:
    assert _run(None, raw="{not json") == 1


def test_flat_schema_is_tolerated() -> None:
    # Defensive: if a future runner ever drops the "summary" nesting, the gate
    # should read the flat shape instead of silently returning all-zero.
    assert _run({"total": 5, "passed": 5, "failed": 0, "skipped": 0}) == 0


if __name__ == "__main__":
    import sys

    failures = 0
    for _name, _fn in sorted(globals().items()):
        if _name.startswith("test_") and callable(_fn):
            try:
                _fn()
                print(f"PASS {_name}")
            except AssertionError as exc:
                failures += 1
                print(f"FAIL {_name}: {exc}")
    print(f"\n{('FAILED' if failures else 'OK')}: {failures} failure(s)")
    sys.exit(1 if failures else 0)
