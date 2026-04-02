#!/usr/bin/env python3
"""Compare load test results against a baseline and report regressions.

Reads a baseline JSONL file (schema_version 2, kind=LoadTest) and a current
results JSON file (Go load test output with a ``levels`` array), then checks
for QPS drops and latency increases at each concurrency level.

Exit codes:
    0 - all concurrency levels pass
    1 - at least one regression detected
"""

from __future__ import annotations

import argparse
import json
import os
import sys


def parse_go_duration(s: str) -> float:
    """Convert a Go duration string (e.g. '52.646303ms', '6.58536369s') to ms."""
    s = s.strip()
    if s.endswith("ms"):
        return float(s[:-2])
    if s.endswith("us") or s.endswith("\u00b5s"):
        return float(s[:-2]) / 1000.0
    if s.endswith("ns"):
        return float(s[:-2]) / 1_000_000.0
    if s.endswith("s"):
        return float(s[:-1]) * 1000.0
    raise ValueError(f"cannot parse Go duration: {s!r}")


def parse_go_duration_seconds(s: str) -> float:
    """Convert a Go duration string like '5s' to seconds."""
    s = s.strip()
    if s.endswith("s") and not s.endswith("ms") and not s.endswith("ns"):
        return float(s[:-1])
    return parse_go_duration(s) / 1000.0


def load_baseline(path: str) -> dict[tuple[str, int], dict]:
    """Load baseline JSONL, returning a dict keyed by (scenario, concurrency)."""
    baseline = {}
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if rec.get("kind") != "LoadTest":
                continue
            if rec.get("schema_version") != 2:
                print(
                    f"WARNING: skipping baseline line {lineno}: "
                    f"schema_version={rec.get('schema_version')} (expected 2)",
                    file=sys.stderr,
                )
                continue
            scenario = rec.get("scenario", "ping")
            baseline[(scenario, rec["concurrency"])] = rec
    return baseline


def load_current(path: str) -> tuple[str, dict[int, dict]]:
    """Load current Go load test JSON. Returns (scenario, {concurrency: data})."""
    with open(path) as f:
        data = json.load(f)

    scenario = data.get("scenario", "ping")
    current = {}
    for level in data.get("levels", []):
        c = level["concurrency"]
        # Skip levels with no successful queries (empty latency strings)
        if not level.get("latency_p50") or not level.get("latency_p99"):
            continue
        dur_s = parse_go_duration_seconds(level["duration"])
        current[c] = {
            "concurrency": c,
            "qps": level["qps"],
            "latency_p50_ms": parse_go_duration(level["latency_p50"]),
            "latency_p99_ms": parse_go_duration(level["latency_p99"]),
            "errors": level["errors"],
            "error_rate": level.get("error_rate", 0),
            "total_queries": level["total_queries"],
            "duration_s": dur_s,
        }
    return scenario, current


def compare(
    baseline: dict[tuple[str, int], dict],
    scenario: str,
    current: dict[int, dict],
    threshold_pct: float,
) -> tuple[list[dict], bool]:
    """Compare current results against baseline.

    Returns (results, all_pass) where results is a list of comparison
    records and all_pass is False if any regression was detected.
    """
    results = []
    all_pass = True

    base_concurrencies = {c for (s, c) in baseline if s == scenario}
    concurrencies = sorted(base_concurrencies | set(current.keys()))

    for c in concurrencies:
        base = baseline.get((scenario, c))
        curr = current.get(c)

        if base is None:
            # New concurrency level not in baseline -- skip
            continue
        if curr is None:
            # Missing from current run
            results.append(
                {
                    "concurrency": c,
                    "status": "MISSING",
                    "pass": False,
                    "reason": "concurrency level absent from current results",
                }
            )
            all_pass = False
            continue

        drop_factor = 1.0 - threshold_pct / 100.0
        rise_factor = 1.0 + threshold_pct / 100.0

        qps_base = base["qps"]
        qps_curr = curr["qps"]
        p50_base = base["latency_p50_ms"]
        p50_curr = curr["latency_p50_ms"]

        qps_delta_pct = ((qps_curr - qps_base) / qps_base * 100) if qps_base else 0
        p50_delta_pct = ((p50_curr - p50_base) / p50_base * 100) if p50_base else 0

        qps_regress = qps_curr < qps_base * drop_factor
        p50_regress = p50_curr > p50_base * rise_factor

        err_base = base.get("errors", 0) / max(base.get("total_queries", 1), 1)
        err_curr = curr.get("error_rate", 0)
        err_regress = err_curr > 0.1 and err_base < 0.05

        passed = not (qps_regress or p50_regress or err_regress)
        if not passed:
            all_pass = False

        reasons = []
        if qps_regress:
            reasons.append(f"QPS dropped {qps_delta_pct:+.1f}%")
        if p50_regress:
            reasons.append(f"p50 latency rose {p50_delta_pct:+.1f}%")
        if err_regress:
            reasons.append(f"error rate {err_curr:.1%} (was {err_base:.1%})")

        rec = {
            "schema_version": 2,
            "kind": "LoadTest",
            "benchmark": f"{scenario}_c{c}",
            "scenario": scenario,
            "concurrency": c,
            "qps": qps_curr,
            "qps_baseline": qps_base,
            "qps_delta_pct": round(qps_delta_pct, 1),
            "latency_p50_ms": p50_curr,
            "latency_p50_baseline_ms": p50_base,
            "latency_p50_delta_pct": round(p50_delta_pct, 1),
            "latency_p99_ms": curr["latency_p99_ms"],
            "errors": curr["errors"],
            "total_queries": curr["total_queries"],
            "duration_s": curr["duration_s"],
            "pass": passed,
            "status": "PASS" if passed else "REGRESS",
            "threshold_pct": threshold_pct,
        }
        if reasons:
            rec["regression_reasons"] = reasons

        results.append(rec)

    return results, all_pass


def format_pct(val: float) -> str:
    """Format a percentage with sign."""
    return f"{val:+.0f}%" if abs(val) >= 0.5 else "0%"


def print_report(
    results: list[dict],
    baseline_path: str,
    current_path: str,
    scenario: str,
    all_pass: bool,
) -> None:
    """Print a human-readable comparison table to stderr."""
    print(file=sys.stderr)
    print(f"Load Test Regression Report  [scenario: {scenario}]", file=sys.stderr)
    print(f"Baseline: {baseline_path}", file=sys.stderr)
    print(f"Current:  {current_path}", file=sys.stderr)
    print(file=sys.stderr)
    print(
        f"  {'Concurrency':<14}{'QPS (base -> curr)':<25}{'p50 (base -> curr)':<28}{'Status'}",
        file=sys.stderr,
    )

    regressions = 0
    for r in results:
        c = r["concurrency"]
        status = r.get("status", "UNKNOWN")

        if status == "MISSING":
            print(
                f"  c={c:<11}{'---':<25}{'---':<28}{status}",
                file=sys.stderr,
            )
            regressions += 1
            continue

        qps_b = r.get("qps_baseline", 0)
        qps_c = r.get("qps", 0)
        qps_d = r.get("qps_delta_pct", 0)
        p50_b = r.get("latency_p50_baseline_ms", 0)
        p50_c = r.get("latency_p50_ms", 0)
        p50_d = r.get("latency_p50_delta_pct", 0)

        qps_str = f"{qps_b:.1f} -> {qps_c:.1f} ({format_pct(qps_d)})"
        p50_str = f"{p50_b:.1f}ms -> {p50_c:.1f}ms ({format_pct(p50_d)})"

        print(
            f"  c={c:<11}{qps_str:<25}{p50_str:<28}{status}",
            file=sys.stderr,
        )

        if status == "REGRESS":
            regressions += 1

    print(file=sys.stderr)
    if all_pass:
        print("Result: PASS", file=sys.stderr)
    else:
        print(f"Result: FAIL ({regressions} regression{'s' if regressions != 1 else ''})", file=sys.stderr)
    print(file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare load test results against baseline")
    parser.add_argument(
        "--baseline",
        default="benchmarks/loadtest/baseline.jsonl",
        help="Path to baseline JSONL (default: benchmarks/loadtest/baseline.jsonl)",
    )
    parser.add_argument(
        "--current",
        required=True,
        help="Path to current Go load test JSON",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=20.0,
        help="Regression threshold percentage (default: 20)",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Path to write comparison JSONL output",
    )
    args = parser.parse_args()

    baseline = load_baseline(args.baseline)
    if not baseline:
        print(f"ERROR: no valid LoadTest entries in {args.baseline}", file=sys.stderr)
        return 1

    scenario, current = load_current(args.current)
    if not current:
        print(f"ERROR: no levels found in {args.current}", file=sys.stderr)
        return 1

    results, all_pass = compare(baseline, scenario, current, args.threshold)

    print_report(results, args.baseline, args.current, scenario, all_pass)

    if args.output:
        out_dir = os.path.dirname(args.output)
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        with open(args.output, "w") as f:
            for rec in results:
                f.write(json.dumps(rec, separators=(",", ":")) + "\n")
        print(f"Comparison written to {args.output}", file=sys.stderr)

    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
