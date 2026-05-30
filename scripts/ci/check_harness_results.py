#!/usr/bin/env python3
"""Gate a geodetestlab harness run from its reports/results.json verdict.

Background
----------
The geodetestlab runner writes the post-retry verdict as::

    {"summary": {"total": N, "passed": P, "failed": F, "skipped": S},
     "specs": [...]}

A previous inline CI gate read the *top-level* ``d['total']`` / ``d['failed']``
keys, which do not exist at that level (they are nested under ``summary``), so
they always evaluated to 0. The gate therefore printed ``Total: 0, Passed: 0,
Failed: 0`` and its ``sys.exit(1) if failed > 0`` branch never fired: the job
was permanently green regardless of real failures, and a crash that left an
empty/zero verdict was indistinguishable from a clean all-pass run. See
geode-test-harness cli.py (report_data assembly) for the schema.

This gate fails closed on any of:
  * one or more specs failed,
  * zero specs ran (the harness aborted/crashed before recording a verdict),
  * counts that do not add up (passed + failed + skipped != total),
  * a missing/unreadable/malformed results.json.

``HARNESS_EXIT`` (the exit code of ``make test``) is reported for diagnostics
only and intentionally does NOT drive the pass/fail decision: ``make test``
exits non-zero even when specs only failed on the first attempt and then
passed on retry, so the results.json verdict is authoritative.

Usage::

    HARNESS_EXIT=$? python3 check_harness_results.py reports/results.json
"""

from __future__ import annotations

import json
import os
import sys


def main(argv: list[str]) -> int:
    path = argv[1] if len(argv) > 1 else "reports/results.json"
    harness_exit = os.environ.get("HARNESS_EXIT", "0")

    try:
        with open(path) as fh:
            data = json.load(fh)
    except FileNotFoundError:
        print(f"FATAL: {path} not found — cannot verify the harness suite ran")
        return 1
    except (OSError, ValueError) as exc:
        print(f"FATAL: {path} unreadable/malformed: {exc}")
        return 1

    # Tolerate both the nested ({"summary": {...}}) and a hypothetical flat
    # ({...}) shape so a future schema tweak degrades gracefully rather than
    # silently returning zeros.
    summary = data.get("summary", data) if isinstance(data, dict) else {}
    total = summary.get("total", 0)
    passed = summary.get("passed", 0)
    failed = summary.get("failed", 0)
    skipped = summary.get("skipped", 0)

    print(f"Total: {total}, Passed: {passed}, Failed: {failed}, Skipped: {skipped} (harness exit {harness_exit})")

    problems: list[str] = []
    if failed > 0:
        problems.append(f"{failed} spec(s) failed")
    if total == 0:
        problems.append("no specs ran (harness aborted/crashed or wrote no verdict)")
    if passed + failed + skipped != total:
        problems.append(f"inconsistent counts ({passed}+{failed}+{skipped} != {total})")

    if problems:
        print("FATAL: " + "; ".join(problems))
        return 1

    print("All test harness specs passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
