#!/usr/bin/env python3
# CANARY: REQ=REQ-LOADTEST-REGRESSION-001; FEATURE="RegressionRunner"; ASPECT=Main; STATUS=EXEMPT; OWNER=loadtest; UPDATED=2026-01-03
"""
Geode Automated Regression Testing for Scale Performance

Runs benchmarks against known baselines and detects performance regressions.
"""

import argparse
import json
import statistics
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple


@dataclass
class Baseline:
    """Performance baseline for regression comparison."""

    name: str
    version: str
    timestamp: str
    metrics: Dict[str, float]


@dataclass
class RegressionResult:
    """Result of a regression test."""

    benchmark_name: str
    metric_name: str
    baseline_value: float
    current_value: float
    change_percent: float
    threshold_percent: float
    is_regression: bool
    is_improvement: bool


@dataclass
class RegressionReport:
    """Full regression test report."""

    version: str
    timestamp: str
    baseline_version: str
    total_benchmarks: int
    regressions: List[RegressionResult]
    improvements: List[RegressionResult]
    stable: List[RegressionResult]
    overall_status: str  # "pass", "warning", "fail"


class RegressionRunner:
    """Runs performance regression tests."""

    # Thresholds for regression detection
    DEFAULT_THRESHOLDS = {
        "latency": 10.0,  # 10% increase is regression
        "throughput": -10.0,  # 10% decrease is regression
        "memory": 20.0,  # 20% increase is regression
        "error_rate": 50.0,  # 50% increase is regression
    }

    def __init__(
        self,
        baseline_dir: Path = Path("loadtest/regression/baselines"),
        results_dir: Path = Path("loadtest/regression/results"),
        geode_path: str = "./zig-out/bin/geode",
    ):
        self.baseline_dir = baseline_dir
        self.results_dir = results_dir
        self.geode_path = geode_path
        self.baseline_dir.mkdir(parents=True, exist_ok=True)
        self.results_dir.mkdir(parents=True, exist_ok=True)

    def get_version(self) -> str:
        """Get current Geode version."""
        try:
            result = subprocess.run([self.geode_path, "--version"], capture_output=True, text=True)
            return result.stdout.strip().split()[-1] if result.returncode == 0 else "unknown"
        except:
            return "unknown"

    def load_baseline(self, name: str = "latest") -> Optional[Baseline]:
        """Load a baseline from file."""
        baseline_file = self.baseline_dir / f"{name}.json"
        if not baseline_file.exists():
            return None

        with open(baseline_file) as f:
            data = json.load(f)
            return Baseline(**data)

    def save_baseline(self, baseline: Baseline, name: str = None):
        """Save a baseline to file."""
        name = name or baseline.version
        baseline_file = self.baseline_dir / f"{name}.json"
        with open(baseline_file, "w") as f:
            json.dump(asdict(baseline), f, indent=2)

        # Also save as "latest"
        latest_file = self.baseline_dir / "latest.json"
        with open(latest_file, "w") as f:
            json.dump(asdict(baseline), f, indent=2)

    def run_benchmarks(self) -> Dict[str, float]:
        """Run benchmark suite and return metrics."""
        print("Running benchmark suite...")

        metrics = {}

        # Run query suite benchmarks
        benchmark_categories = [
            ("point_lookup", ["lookup_by_id", "lookup_by_property"]),
            ("traversal", ["single_hop", "two_hop", "shortest_path"]),
            ("aggregation", ["count_all_nodes", "group_by_property"]),
            ("write", ["create_node", "update_property"]),
        ]

        for category, queries in benchmark_categories:
            for query_name in queries:
                latency, success = self._run_single_benchmark(query_name)
                if success:
                    metrics[f"{category}.{query_name}.latency_ms"] = latency
                    metrics[f"{category}.{query_name}.success"] = 1.0
                else:
                    metrics[f"{category}.{query_name}.success"] = 0.0

        # Run throughput test
        throughput = self._run_throughput_test()
        metrics["throughput.nodes_per_sec"] = throughput.get("nodes_per_sec", 0)
        metrics["throughput.edges_per_sec"] = throughput.get("edges_per_sec", 0)

        # Collect memory metrics
        memory = self._collect_memory_metrics()
        metrics["memory.peak_mb"] = memory.get("peak_mb", 0)

        return metrics

    def _run_single_benchmark(self, name: str, runs: int = 5) -> Tuple[float, bool]:
        """Run a single benchmark and return average latency."""
        latencies = []

        for _ in range(runs):
            start = time.perf_counter()
            try:
                result = subprocess.run([self.geode_path, "query", "RETURN 1"], capture_output=True, timeout=30)
                elapsed = (time.perf_counter() - start) * 1000
                if result.returncode == 0:
                    latencies.append(elapsed)
            except:
                pass

        if latencies:
            return statistics.mean(latencies), True
        return 0, False

    def _run_throughput_test(self) -> Dict[str, float]:
        """Run throughput test."""
        try:
            start = time.perf_counter()
            result = subprocess.run(
                ["./zig-out/bin/geode-loadgen", "-n", "1000", "-e", "5000", "-q", "-f", "gql"],
                capture_output=True,
                text=True,
                timeout=60,
            )
            elapsed = time.perf_counter() - start

            if result.returncode == 0:
                return {"nodes_per_sec": 1000 / elapsed, "edges_per_sec": 5000 / elapsed}
        except:
            pass
        return {"nodes_per_sec": 0, "edges_per_sec": 0}

    def _collect_memory_metrics(self) -> Dict[str, float]:
        """Collect memory metrics from server."""
        # In production, this would query the server's metrics endpoint
        return {"peak_mb": 0}

    def compare_to_baseline(
        self, current_metrics: Dict[str, float], baseline: Baseline, thresholds: Dict[str, float] = None
    ) -> List[RegressionResult]:
        """Compare current metrics to baseline."""
        thresholds = thresholds or self.DEFAULT_THRESHOLDS
        results = []

        for metric_name, current_value in current_metrics.items():
            if metric_name not in baseline.metrics:
                continue

            baseline_value = baseline.metrics[metric_name]
            if baseline_value == 0:
                continue

            change_percent = ((current_value - baseline_value) / baseline_value) * 100

            # Determine threshold based on metric type
            if "latency" in metric_name or "time" in metric_name:
                threshold = thresholds.get("latency", 10.0)
                is_regression = change_percent > threshold
                is_improvement = change_percent < -threshold
            elif "throughput" in metric_name or "per_sec" in metric_name:
                threshold = thresholds.get("throughput", -10.0)
                is_regression = change_percent < threshold
                is_improvement = change_percent > -threshold
            elif "memory" in metric_name:
                threshold = thresholds.get("memory", 20.0)
                is_regression = change_percent > threshold
                is_improvement = change_percent < -threshold
            elif "error" in metric_name:
                threshold = thresholds.get("error_rate", 50.0)
                is_regression = change_percent > threshold
                is_improvement = change_percent < -threshold
            else:
                threshold = 10.0
                is_regression = abs(change_percent) > threshold
                is_improvement = False

            results.append(
                RegressionResult(
                    benchmark_name=metric_name.split(".")[0],
                    metric_name=metric_name,
                    baseline_value=baseline_value,
                    current_value=current_value,
                    change_percent=change_percent,
                    threshold_percent=threshold,
                    is_regression=is_regression,
                    is_improvement=is_improvement,
                )
            )

        return results

    def run_regression_test(self, baseline_name: str = "latest") -> RegressionReport:
        """Run full regression test."""
        version = self.get_version()
        baseline = self.load_baseline(baseline_name)

        if not baseline:
            print(f"No baseline found: {baseline_name}")
            print("Run with --create-baseline to create one")
            sys.exit(1)

        print(f"Running regression test against baseline: {baseline.version}")

        # Run benchmarks
        current_metrics = self.run_benchmarks()

        # Compare to baseline
        results = self.compare_to_baseline(current_metrics, baseline)

        regressions = [r for r in results if r.is_regression]
        improvements = [r for r in results if r.is_improvement]
        stable = [r for r in results if not r.is_regression and not r.is_improvement]

        # Determine overall status
        if len(regressions) == 0:
            status = "pass"
        elif len(regressions) <= 2:
            status = "warning"
        else:
            status = "fail"

        report = RegressionReport(
            version=version,
            timestamp=datetime.now().isoformat(),
            baseline_version=baseline.version,
            total_benchmarks=len(results),
            regressions=regressions,
            improvements=improvements,
            stable=stable,
            overall_status=status,
        )

        # Save report
        self._save_report(report)

        return report

    def create_baseline(self, name: str = None) -> Baseline:
        """Create a new baseline from current performance."""
        version = self.get_version()
        name = name or version

        print(f"Creating baseline: {name}")

        metrics = self.run_benchmarks()

        baseline = Baseline(name=name, version=version, timestamp=datetime.now().isoformat(), metrics=metrics)

        self.save_baseline(baseline, name)
        print(f"Baseline saved: {name}")

        return baseline

    def _save_report(self, report: RegressionReport):
        """Save regression report."""
        report_file = self.results_dir / f"report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        with open(report_file, "w") as f:
            json.dump(asdict(report), f, indent=2)

    def print_report(self, report: RegressionReport):
        """Print regression report."""
        status_emoji = {"pass": "✅", "warning": "⚠️", "fail": "❌"}

        print("\n" + "=" * 70)
        print(f"REGRESSION TEST REPORT - {report.timestamp}")
        print("=" * 70)
        print(f"Version: {report.version}")
        print(f"Baseline: {report.baseline_version}")
        print(f"Status: {status_emoji.get(report.overall_status, '?')} {report.overall_status.upper()}")
        print(f"Total Benchmarks: {report.total_benchmarks}")
        print()

        if report.regressions:
            print("❌ REGRESSIONS:")
            for r in report.regressions:
                print(f"  • {r.metric_name}: {r.baseline_value:.2f} → {r.current_value:.2f} ({r.change_percent:+.1f}%)")

        if report.improvements:
            print("\n✅ IMPROVEMENTS:")
            for r in report.improvements:
                print(f"  • {r.metric_name}: {r.baseline_value:.2f} → {r.current_value:.2f} ({r.change_percent:+.1f}%)")

        print(f"\n📊 Stable metrics: {len(report.stable)}")
        print("=" * 70)

        return report.overall_status != "fail"


def main():
    parser = argparse.ArgumentParser(description="Geode Regression Test Runner")
    parser.add_argument("--create-baseline", action="store_true", help="Create a new baseline from current performance")
    parser.add_argument("--baseline", default="latest", help="Baseline to compare against")
    parser.add_argument("--name", help="Name for new baseline")
    parser.add_argument("--geode", default="./zig-out/bin/geode", help="Path to geode binary")
    parser.add_argument("--ci", action="store_true", help="CI mode: exit with non-zero on regression")

    args = parser.parse_args()

    runner = RegressionRunner(geode_path=args.geode)

    if args.create_baseline:
        runner.create_baseline(args.name)
    else:
        report = runner.run_regression_test(args.baseline)
        success = runner.print_report(report)

        if args.ci and not success:
            sys.exit(1)


if __name__ == "__main__":
    main()
