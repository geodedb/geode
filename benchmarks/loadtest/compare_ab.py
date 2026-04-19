#!/usr/bin/env python3
"""A/B loadtest comparator for perf-gate.sh (M0.8).

Reads two multi-scenario loadtest JSONs produced by the perf-gate
script (``{"scenarios": [<scenario_doc>, ...]}`` where each
``scenario_doc`` is the Go loadtest output). Emits either markdown rows
or an exit-coded pass/fail.

Block thresholds (mirrors scripts/perf-gate.sh and the plan):

  * QPS drop  >= 5%  on any level -> block (exit 1)
  * p99 rise  >= 10% on any level -> block (exit 1)

Warn band (3-5% QPS drop / 7-10% p99 rise): rendered non-blocking.

Companion to ``benchmarks/loadtest/compare.py`` (baseline-driven). This
tool is A/B-oriented and is invoked by ``scripts/perf-gate.sh`` during
the ``after`` phase.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections.abc import Iterable

_DUR_RE = re.compile(r"^\s*(?P<v>[0-9.]+)\s*(?P<u>ms|us|\u00b5s|ns|s)\s*$")


def parse_duration_ms(s: str) -> float:
    """Parse a Go-style duration string (e.g. ``10ms``, ``500us``) to ms."""
    m = _DUR_RE.match(s)
    if not m:
        raise ValueError(f"cannot parse duration: {s!r}")
    v = float(m.group("v"))
    u = m.group("u")
    return {
        "ms": v,
        "us": v / 1000.0,
        "\u00b5s": v / 1000.0,
        "ns": v / 1_000_000.0,
        "s": v * 1000.0,
    }[u]


def load(path: str) -> dict[tuple[str, int], dict]:
    """Load a multi-scenario loadtest JSON into a (scenario, c) -> row map."""
    with open(path) as f:
        data = json.load(f)
    out: dict[tuple[str, int], dict] = {}
    # Single-scenario files (bare Go loadtest output) are also accepted.
    scenarios = data.get("scenarios") or [data]
    for sdoc in scenarios:
        scenario = sdoc.get("scenario", "?")
        for lvl in sdoc.get("levels", []):
            if not lvl.get("latency_p99"):
                continue
            out[(scenario, lvl["concurrency"])] = {
                "qps": lvl["qps"],
                "p99_ms": parse_duration_ms(lvl["latency_p99"]),
                "error_rate": lvl.get("error_rate", 0.0),
            }
    return out


def compare(before: dict, after: dict) -> Iterable[dict]:
    """Yield per-(scenario, concurrency) comparison rows."""
    keys = sorted(set(before) | set(after))
    for scenario, c in keys:
        b = before.get((scenario, c))
        a = after.get((scenario, c))
        if b is None or a is None:
            continue
        dq = (a["qps"] - b["qps"]) / b["qps"] * 100 if b["qps"] else 0
        dp = (a["p99_ms"] - b["p99_ms"]) / b["p99_ms"] * 100 if b["p99_ms"] else 0
        block = dq <= -5.0 or dp >= 10.0
        warn = (not block) and (dq <= -3.0 or dp >= 7.0)
        yield {
            "scenario": scenario,
            "concurrency": c,
            "qps_before": b["qps"],
            "qps_after": a["qps"],
            "qps_delta_pct": dq,
            "p99_before_ms": b["p99_ms"],
            "p99_after_ms": a["p99_ms"],
            "p99_delta_pct": dp,
            "err_before": b["error_rate"],
            "err_after": a["error_rate"],
            "block": block,
            "warn": warn,
        }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--before", required=True, help="before-phase loadtest JSON")
    ap.add_argument("--after", required=True, help="after-phase loadtest JSON")
    ap.add_argument(
        "--format",
        choices=("markdown-rows", "exit-code"),
        default="markdown-rows",
        help="markdown-rows: print table rows to stdout; exit-code: quiet, just set exit status",
    )
    args = ap.parse_args()

    before = load(args.before)
    after = load(args.after)
    rows = list(compare(before, after))

    any_block = False
    if args.format == "markdown-rows":
        for r in rows:
            status = "BLOCK" if r["block"] else ("warn" if r["warn"] else "")
            print(
                f"| {r['scenario']} | {r['concurrency']} | "
                f"{r['qps_before']:.1f} | {r['qps_after']:.1f} | "
                f"{r['qps_delta_pct']:+.1f}% | "
                f"{r['p99_before_ms']:.2f}ms | {r['p99_after_ms']:.2f}ms | "
                f"{r['p99_delta_pct']:+.1f}% | "
                f"{r['err_before']:.1%} | {r['err_after']:.1%} | {status} |"
            )
            if r["block"]:
                any_block = True
    else:
        for r in rows:
            if r["block"]:
                any_block = True
                sys.stderr.write(
                    f"BLOCK {r['scenario']} c={r['concurrency']} "
                    f"\u0394QPS {r['qps_delta_pct']:+.1f}% "
                    f"\u0394p99 {r['p99_delta_pct']:+.1f}%\n"
                )
    return 1 if any_block else 0


if __name__ == "__main__":
    raise SystemExit(main())
