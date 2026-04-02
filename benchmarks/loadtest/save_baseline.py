#!/usr/bin/env python3
"""Convert Go load test JSON output to baseline JSONL format.

Reads the Go load test report (with a ``levels`` array) and writes
one JSONL record per concurrency level with auto-calculated thresholds.

Thresholds:
    threshold_qps_min  = qps * 0.8   (20% below current)
    threshold_p50_max_ms = p50 * 1.2  (20% above current)
"""

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


def main() -> int:
    parser = argparse.ArgumentParser(description="Save load test results as new baseline")
    parser.add_argument(
        "--input",
        required=True,
        help="Path to Go load test JSON output",
    )
    parser.add_argument(
        "--output",
        default="benchmarks/loadtest/baseline.jsonl",
        help="Path to write baseline JSONL (default: benchmarks/loadtest/baseline.jsonl)",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=20.0,
        help="Threshold percentage for auto-calculated limits (default: 20)",
    )
    parser.add_argument(
        "--append",
        action="store_true",
        help="Append to existing baseline (replacing entries for same scenario)",
    )
    args = parser.parse_args()

    with open(args.input) as f:
        data = json.load(f)

    scenario = data.get("scenario", "ping")

    levels = data.get("levels", [])
    if not levels:
        print(f"ERROR: no levels found in {args.input}", file=sys.stderr)
        return 1

    drop_factor = 1.0 - args.threshold / 100.0
    rise_factor = 1.0 + args.threshold / 100.0

    records = []
    for level in levels:
        c = level["concurrency"]
        qps = level["qps"]
        # Skip levels with no successful queries (empty latency strings)
        if not level.get("latency_p50") or not level.get("latency_p99"):
            continue
        p50_ms = parse_go_duration(level["latency_p50"])
        p99_ms = parse_go_duration(level["latency_p99"])
        dur_s = parse_go_duration_seconds(level["duration"])
        errors = level["errors"]
        total = level["total_queries"]

        threshold_qps_min = round(qps * drop_factor, 1)
        threshold_p50_max = round(p50_ms * rise_factor, 1)

        # Mark as pass unless error rate exceeds 50%
        error_rate = errors / max(total, 1)
        passed = error_rate < 0.5

        rec = {
            "schema_version": 2,
            "kind": "LoadTest",
            "benchmark": f"{scenario}_c{c}",
            "scenario": scenario,
            "concurrency": c,
            "qps": qps,
            "latency_p50_ms": round(p50_ms, 1),
            "latency_p99_ms": round(p99_ms, 1),
            "errors": errors,
            "total_queries": total,
            "duration_s": dur_s,
            "pass": passed,
            "threshold_qps_min": threshold_qps_min,
            "threshold_p50_max_ms": threshold_p50_max,
        }
        records.append(rec)

    if args.append and os.path.exists(args.output):
        existing = []
        with open(args.output) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                rec = json.loads(line)
                if rec.get("scenario") != scenario:
                    existing.append(rec)
        records = existing + records

    with open(args.output, "w") as f:
        for rec in records:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")

    print(f"Saved {len(records)} baseline records to {args.output}", file=sys.stderr)
    for rec in records:
        status = "PASS" if rec["pass"] else "FAIL"
        print(
            f"  c={rec['concurrency']:<4} QPS={rec['qps']:<8.1f} "
            f"p50={rec['latency_p50_ms']:.1f}ms  "
            f"thresh: QPS>={rec['threshold_qps_min']:.1f}, p50<={rec['threshold_p50_max_ms']:.1f}ms  "
            f"[{status}]",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
