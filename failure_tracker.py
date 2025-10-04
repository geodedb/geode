#!/usr/bin/env python3
"""
Geodetestlab Failure Tracker and Analysis Tool

This tool helps track test failures over time and provides analysis
of what's improving, regressing, or remaining consistent.
"""

import json
import sys
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Set, Tuple
from dataclasses import dataclass

@dataclass
class FailureComparison:
    """Comparison between two test runs."""
    previous_run: str
    current_run: str
    fixed_tests: List[str]  # Tests that were failing but now pass
    new_failures: List[str]  # Tests that were passing but now fail
    persistent_failures: List[str]  # Tests that continue to fail
    total_previous_failures: int
    total_current_failures: int
    improvement_rate: float

class FailureTracker:
    def __init__(self, log_dir: Path = Path("/home/benji/src/spyder/geode/test_logs")):
        self.log_dir = log_dir
        
    def get_run_directories(self) -> List[Path]:
        """Get all test run directories sorted by timestamp."""
        if not self.log_dir.exists():
            return []
            
        run_dirs = [d for d in self.log_dir.iterdir() if d.is_dir() and d.name.startswith("run_")]
        return sorted(run_dirs, key=lambda x: x.name)
    
    def load_run_summary(self, run_dir: Path) -> Dict:
        """Load summary data from a test run."""
        summary_file = run_dir / "summary.json"
        if not summary_file.exists():
            raise FileNotFoundError(f"Summary file not found: {summary_file}")
            
        with open(summary_file, "r") as f:
            return json.load(f)
    
    def load_run_failures(self, run_dir: Path) -> Dict:
        """Load failure data from a test run."""
        failures_file = run_dir / "failures.json"
        if not failures_file.exists():
            raise FileNotFoundError(f"Failures file not found: {failures_file}")
            
        with open(failures_file, "r") as f:
            return json.load(f)
    
    def get_failed_test_ids(self, failures_data: Dict) -> Set[str]:
        """Extract set of failed test identifiers from failures data."""
        failed_tests = set()
        for failure in failures_data.get("failures", []):
            test_id = f"{failure['spec_file']}::{failure['test_name']}"
            failed_tests.add(test_id)
        return failed_tests
    
    def compare_runs(self, prev_run_dir: Path, curr_run_dir: Path) -> FailureComparison:
        """Compare two test runs and identify changes."""
        prev_failures = self.load_run_failures(prev_run_dir)
        curr_failures = self.load_run_failures(curr_run_dir)
        
        prev_failed_tests = self.get_failed_test_ids(prev_failures)
        curr_failed_tests = self.get_failed_test_ids(curr_failures)
        
        # Calculate differences
        fixed_tests = list(prev_failed_tests - curr_failed_tests)
        new_failures = list(curr_failed_tests - prev_failed_tests)
        persistent_failures = list(prev_failed_tests & curr_failed_tests)
        
        # Calculate improvement rate
        if len(prev_failed_tests) > 0:
            improvement_rate = len(fixed_tests) / len(prev_failed_tests) * 100
        else:
            improvement_rate = 0.0
        
        return FailureComparison(
            previous_run=prev_run_dir.name,
            current_run=curr_run_dir.name,
            fixed_tests=sorted(fixed_tests),
            new_failures=sorted(new_failures),
            persistent_failures=sorted(persistent_failures),
            total_previous_failures=len(prev_failed_tests),
            total_current_failures=len(curr_failed_tests),
            improvement_rate=improvement_rate
        )
    
    def analyze_failure_trends(self, num_runs: int = 5) -> Dict:
        """Analyze failure trends across the last N runs."""
        run_dirs = self.get_run_directories()[-num_runs:]
        
        if len(run_dirs) < 2:
            return {"error": "Need at least 2 test runs for trend analysis"}
        
        trends = {
            "runs_analyzed": len(run_dirs),
            "time_range": f"{run_dirs[0].name} to {run_dirs[-1].name}",
            "failure_counts": [],
            "pass_rates": [],
            "persistent_failures": set(),
            "intermittent_failures": set(),
            "recently_fixed": [],
            "newly_failing": []
        }
        
        all_run_failures = []
        
        # Collect failure data for each run
        for run_dir in run_dirs:
            try:
                summary = self.load_run_summary(run_dir)
                failures = self.load_run_failures(run_dir)
                failed_tests = self.get_failed_test_ids(failures)
                
                execution_summary = summary.get("execution_summary", {})
                
                trends["failure_counts"].append({
                    "run": run_dir.name,
                    "total_failures": len(failed_tests),
                    "total_tests": execution_summary.get("total_tests", 0),
                    "pass_rate": execution_summary.get("pass_rate", 0.0)
                })
                
                trends["pass_rates"].append(execution_summary.get("pass_rate", 0.0))
                
                all_run_failures.append((run_dir.name, failed_tests))
                
            except Exception as e:
                print(f"Warning: Could not load data for {run_dir.name}: {e}")
        
        # Analyze persistence patterns
        if len(all_run_failures) >= 2:
            # Find tests that fail in all runs
            all_failures_sets = [failures for _, failures in all_run_failures]
            if all_failures_sets:
                trends["persistent_failures"] = set.intersection(*all_failures_sets)
            
            # Find tests that fail intermittently
            all_failures_union = set.union(*all_failures_sets) if all_failures_sets else set()
            trends["intermittent_failures"] = all_failures_union - trends["persistent_failures"]
            
            # Compare first and last runs
            if len(all_run_failures) >= 2:
                first_run_failures = all_run_failures[0][1]
                last_run_failures = all_run_failures[-1][1]
                
                trends["recently_fixed"] = list(first_run_failures - last_run_failures)
                trends["newly_failing"] = list(last_run_failures - first_run_failures)
        
        # Convert sets to lists for JSON serialization
        trends["persistent_failures"] = sorted(list(trends["persistent_failures"]))
        trends["intermittent_failures"] = sorted(list(trends["intermittent_failures"]))
        
        return trends
    
    def generate_progress_report(self) -> str:
        """Generate a comprehensive progress report."""
        run_dirs = self.get_run_directories()
        
        if not run_dirs:
            return "No test runs found."
        
        if len(run_dirs) == 1:
            return "Only one test run found. Need multiple runs for comparison."
        
        # Latest run summary
        latest_run = run_dirs[-1]
        try:
            latest_summary = self.load_run_summary(latest_run)
            latest_exec = latest_summary.get("execution_summary", {})
        except Exception as e:
            return f"Error loading latest run: {e}"
        
        report = []
        report.append("=" * 80)
        report.append("GEODETESTLAB PROGRESS REPORT")
        report.append("=" * 80)
        report.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        report.append(f"Latest run: {latest_run.name}")
        report.append("")
        
        # Current status
        report.append("CURRENT STATUS:")
        report.append(f"  Total tests: {latest_exec.get('total_tests', 0)}")
        report.append(f"  Passed: {latest_exec.get('passed', 0)}")
        report.append(f"  Failed: {latest_exec.get('failed', 0)}")
        report.append(f"  Pass rate: {latest_exec.get('pass_rate', 0):.1f}%")
        report.append("")
        
        # Compare with previous run if available
        if len(run_dirs) >= 2:
            prev_run = run_dirs[-2]
            try:
                comparison = self.compare_runs(prev_run, latest_run)
                
                report.append("RECENT CHANGES:")
                report.append(f"  Previous run: {comparison.previous_run}")
                report.append(f"  Tests fixed: {len(comparison.fixed_tests)}")
                report.append(f"  New failures: {len(comparison.new_failures)}")
                report.append(f"  Persistent failures: {len(comparison.persistent_failures)}")
                report.append(f"  Improvement rate: {comparison.improvement_rate:.1f}%")
                report.append("")
                
                if comparison.fixed_tests:
                    report.append("RECENTLY FIXED TESTS:")
                    for test in comparison.fixed_tests[:10]:  # Show top 10
                        spec, test_name = test.split("::")
                        report.append(f"  ✓ [{spec}] {test_name}")
                    if len(comparison.fixed_tests) > 10:
                        report.append(f"  ... and {len(comparison.fixed_tests) - 10} more")
                    report.append("")
                
                if comparison.new_failures:
                    report.append("NEW FAILURES:")
                    for test in comparison.new_failures[:10]:  # Show top 10
                        spec, test_name = test.split("::")
                        report.append(f"  ✗ [{spec}] {test_name}")
                    if len(comparison.new_failures) > 10:
                        report.append(f"  ... and {len(comparison.new_failures) - 10} more")
                    report.append("")
                    
            except Exception as e:
                report.append(f"Could not compare with previous run: {e}")
                report.append("")
        
        # Trend analysis
        try:
            trends = self.analyze_failure_trends()
            if "error" not in trends:
                report.append("TREND ANALYSIS (Last 5 runs):")
                report.append(f"  Runs analyzed: {trends['runs_analyzed']}")
                report.append(f"  Time range: {trends['time_range']}")
                
                if trends["pass_rates"]:
                    min_pass = min(trends["pass_rates"])
                    max_pass = max(trends["pass_rates"])
                    latest_pass = trends["pass_rates"][-1]
                    report.append(f"  Pass rate range: {min_pass:.1f}% - {max_pass:.1f}%")
                    report.append(f"  Current pass rate: {latest_pass:.1f}%")
                
                report.append(f"  Persistent failures: {len(trends['persistent_failures'])}")
                report.append(f"  Intermittent failures: {len(trends['intermittent_failures'])}")
                report.append("")
                
                if trends["recently_fixed"]:
                    report.append("TESTS FIXED IN RECENT RUNS:")
                    for test in trends["recently_fixed"][:5]:
                        spec, test_name = test.split("::")
                        report.append(f"  ✓ [{spec}] {test_name}")
                    if len(trends["recently_fixed"]) > 5:
                        report.append(f"  ... and {len(trends['recently_fixed']) - 5} more")
                    report.append("")
        
        except Exception as e:
            report.append(f"Could not generate trend analysis: {e}")
            report.append("")
        
        # Top failure patterns from latest run
        try:
            latest_failures = self.load_run_failures(latest_run)
            failure_patterns = latest_failures.get("failure_patterns", {})
            
            if failure_patterns:
                report.append("TOP FAILURE PATTERNS:")
                sorted_patterns = sorted(failure_patterns.items(), key=lambda x: len(x[1]), reverse=True)
                for pattern, failures in sorted_patterns[:10]:
                    report.append(f"  {pattern}: {len(failures)} tests")
                report.append("")
        
        except Exception as e:
            report.append(f"Could not load failure patterns: {e}")
        
        report.append("=" * 80)
        
        return "\n".join(report)
    
    def export_failure_csv(self, output_file: Path):
        """Export failure data to CSV for external analysis."""
        import csv
        
        run_dirs = self.get_run_directories()
        
        with open(output_file, "w", newline="") as csvfile:
            writer = csv.writer(csvfile)
            writer.writerow(["run_timestamp", "spec_file", "test_name", "failure_message", "execution_time_ms", "exit_code"])
            
            for run_dir in run_dirs:
                try:
                    failures = self.load_run_failures(run_dir)
                    run_timestamp = run_dir.name.replace("run_", "")
                    
                    for failure in failures.get("failures", []):
                        writer.writerow([
                            run_timestamp,
                            failure.get("spec_file", ""),
                            failure.get("test_name", ""),
                            failure.get("message", ""),
                            failure.get("execution_time_ms", 0),
                            failure.get("exit_code", "")
                        ])
                        
                except Exception as e:
                    print(f"Warning: Could not export data for {run_dir.name}: {e}")

def main():
    import argparse
    
    parser = argparse.ArgumentParser(description="Geodetestlab Failure Tracker")
    parser.add_argument("--log-dir", type=Path,
                        default=Path("/home/benji/src/spyder/geode/test_logs"),
                        help="Directory containing test logs")
    parser.add_argument("--report", action="store_true",
                        help="Generate progress report")
    parser.add_argument("--compare", action="store_true",
                        help="Compare last two runs")
    parser.add_argument("--trends", type=int, default=5,
                        help="Analyze trends over N runs")
    parser.add_argument("--export-csv", type=Path,
                        help="Export failure data to CSV file")
    
    args = parser.parse_args()
    
    tracker = FailureTracker(args.log_dir)
    
    if args.report:
        print(tracker.generate_progress_report())
    elif args.compare:
        run_dirs = tracker.get_run_directories()
        if len(run_dirs) >= 2:
            comparison = tracker.compare_runs(run_dirs[-2], run_dirs[-1])
            print(f"Comparison: {comparison.previous_run} vs {comparison.current_run}")
            print(f"Fixed: {len(comparison.fixed_tests)}")
            print(f"New failures: {len(comparison.new_failures)}")
            print(f"Persistent: {len(comparison.persistent_failures)}")
            print(f"Improvement: {comparison.improvement_rate:.1f}%")
        else:
            print("Need at least 2 test runs for comparison")
    elif args.trends:
        trends = tracker.analyze_failure_trends(args.trends)
        print(json.dumps(trends, indent=2))
    elif args.export_csv:
        tracker.export_failure_csv(args.export_csv)
        print(f"Failure data exported to {args.export_csv}")
    else:
        print("Use --report, --compare, --trends, or --export-csv")
        return 1
    
    return 0

if __name__ == "__main__":
    sys.exit(main())