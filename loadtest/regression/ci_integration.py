#!/usr/bin/env python3
# CANARY: REQ=REQ-LOADTEST-REGRESSION-002; FEATURE="CIIntegration"; ASPECT=Pipeline; STATUS=EXEMPT; OWNER=loadtest; UPDATED=2026-01-03
"""
Geode CI/CD Integration for Regression Testing

Provides GitLab CI/GitHub Actions integration for automated performance testing.
"""

import json
import os
import sys

from .runner import RegressionReport, RegressionRunner


def generate_gitlab_report(report: RegressionReport) -> dict:
    """Generate GitLab CI compatible test report."""
    tests = []

    for r in report.regressions + report.improvements + report.stable:
        status = "failed" if r.is_regression else "passed"
        tests.append(
            {
                "name": r.metric_name,
                "classname": r.benchmark_name,
                "execution_time": 0,
                "status": status,
                "system_output": f"baseline: {r.baseline_value:.2f}, current: {r.current_value:.2f}, change: {r.change_percent:+.1f}%",
            }
        )

    return {
        "tests": tests,
        "success_count": len(report.stable) + len(report.improvements),
        "failed_count": len(report.regressions),
        "skipped_count": 0,
        "total_time": 0,
    }


def generate_github_annotations(report: RegressionReport) -> list:
    """Generate GitHub Actions annotations."""
    annotations = []

    for r in report.regressions:
        annotations.append(
            {
                "level": "error",
                "message": f"Performance regression in {r.metric_name}: {r.change_percent:+.1f}% (threshold: {r.threshold_percent}%)",
                "title": f"Regression: {r.benchmark_name}",
            }
        )

    for r in report.improvements:
        annotations.append(
            {
                "level": "notice",
                "message": f"Performance improvement in {r.metric_name}: {r.change_percent:+.1f}%",
                "title": f"Improvement: {r.benchmark_name}",
            }
        )

    return annotations


def main():
    """Run regression test in CI environment."""
    ci_env = os.environ.get("CI", "").lower() == "true"
    gitlab_ci = os.environ.get("GITLAB_CI", "").lower() == "true"
    github_actions = os.environ.get("GITHUB_ACTIONS", "").lower() == "true"

    runner = RegressionRunner()

    # Check if baseline exists
    baseline = runner.load_baseline("latest")
    if not baseline:
        print("No baseline found. Creating initial baseline...")
        runner.create_baseline()
        print("Baseline created. Run again to compare.")
        sys.exit(0)

    # Run regression test
    report = runner.run_regression_test()
    runner.print_report(report)

    # Generate CI-specific outputs
    if gitlab_ci:
        gitlab_report = generate_gitlab_report(report)
        with open("regression-report.json", "w") as f:
            json.dump(gitlab_report, f, indent=2)
        print("\nGitLab report saved to regression-report.json")

    if github_actions:
        annotations = generate_github_annotations(report)
        for ann in annotations:
            level = "error" if ann["level"] == "error" else "notice"
            print(f"::{level} title={ann['title']}::{ann['message']}")

    # Exit with appropriate code
    if report.overall_status == "fail":
        print("\n❌ Regression test FAILED")
        sys.exit(1)
    elif report.overall_status == "warning":
        print("\n⚠️ Regression test passed with warnings")
        sys.exit(0)
    else:
        print("\n✅ Regression test PASSED")
        sys.exit(0)


if __name__ == "__main__":
    main()
