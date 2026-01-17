#!/usr/bin/env python3
# CANARY: REQ=REQ-LOADTEST-TESTS-003; FEATURE="RegressionTests"; ASPECT=UnitTests; STATUS=EXEMPT; OWNER=loadtest; UPDATED=2026-01-03
"""
Unit tests for Geode Regression Testing Infrastructure
"""

import unittest
import tempfile
import json
import sys
from pathlib import Path
from datetime import datetime
from unittest.mock import patch, MagicMock

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from regression.runner import (
    Baseline,
    RegressionResult,
    RegressionReport,
    RegressionRunner,
)


class TestBaseline(unittest.TestCase):
    """Tests for Baseline dataclass."""

    def test_baseline_creation(self):
        """Test creating a Baseline instance."""
        baseline = Baseline(
            name="test_baseline",
            version="1.0.0",
            timestamp="2026-01-03T10:00:00",
            metrics={"latency": 10.5, "throughput": 1000.0}
        )
        self.assertEqual(baseline.name, "test_baseline")
        self.assertEqual(baseline.version, "1.0.0")
        self.assertEqual(baseline.metrics["latency"], 10.5)


class TestRegressionResult(unittest.TestCase):
    """Tests for RegressionResult dataclass."""

    def test_regression_result_creation(self):
        """Test creating a RegressionResult instance."""
        result = RegressionResult(
            benchmark_name="query",
            metric_name="query.latency",
            baseline_value=10.0,
            current_value=12.0,
            change_percent=20.0,
            threshold_percent=10.0,
            is_regression=True,
            is_improvement=False
        )
        self.assertEqual(result.benchmark_name, "query")
        self.assertTrue(result.is_regression)
        self.assertFalse(result.is_improvement)

    def test_regression_result_improvement(self):
        """Test RegressionResult for improvement case."""
        result = RegressionResult(
            benchmark_name="query",
            metric_name="query.latency",
            baseline_value=10.0,
            current_value=8.0,
            change_percent=-20.0,
            threshold_percent=10.0,
            is_regression=False,
            is_improvement=True
        )
        self.assertFalse(result.is_regression)
        self.assertTrue(result.is_improvement)


class TestRegressionReport(unittest.TestCase):
    """Tests for RegressionReport dataclass."""

    def test_regression_report_creation(self):
        """Test creating a RegressionReport instance."""
        report = RegressionReport(
            version="1.0.0",
            timestamp="2026-01-03T10:00:00",
            baseline_version="0.9.0",
            total_benchmarks=10,
            regressions=[],
            improvements=[],
            stable=[],
            overall_status="pass"
        )
        self.assertEqual(report.version, "1.0.0")
        self.assertEqual(report.overall_status, "pass")
        self.assertEqual(report.total_benchmarks, 10)


class TestRegressionRunner(unittest.TestCase):
    """Tests for RegressionRunner class."""

    def setUp(self):
        """Set up test fixtures."""
        self.temp_dir = tempfile.mkdtemp()
        self.baseline_dir = Path(self.temp_dir) / "baselines"
        self.results_dir = Path(self.temp_dir) / "results"
        self.runner = RegressionRunner(
            baseline_dir=self.baseline_dir,
            results_dir=self.results_dir,
            geode_path="./zig-out/bin/geode"
        )

    def test_runner_creates_directories(self):
        """Test that runner creates necessary directories."""
        self.assertTrue(self.baseline_dir.exists())
        self.assertTrue(self.results_dir.exists())

    def test_default_thresholds(self):
        """Test default threshold values."""
        self.assertEqual(self.runner.DEFAULT_THRESHOLDS["latency"], 10.0)
        self.assertEqual(self.runner.DEFAULT_THRESHOLDS["throughput"], -10.0)
        self.assertEqual(self.runner.DEFAULT_THRESHOLDS["memory"], 20.0)
        self.assertEqual(self.runner.DEFAULT_THRESHOLDS["error_rate"], 50.0)

    def test_save_and_load_baseline(self):
        """Test saving and loading a baseline."""
        baseline = Baseline(
            name="test",
            version="1.0.0",
            timestamp=datetime.now().isoformat(),
            metrics={"test.metric": 100.0}
        )
        self.runner.save_baseline(baseline, "test")

        loaded = self.runner.load_baseline("test")
        self.assertIsNotNone(loaded)
        self.assertEqual(loaded.name, "test")
        self.assertEqual(loaded.version, "1.0.0")
        self.assertEqual(loaded.metrics["test.metric"], 100.0)

    def test_load_nonexistent_baseline(self):
        """Test loading a non-existent baseline returns None."""
        loaded = self.runner.load_baseline("nonexistent")
        self.assertIsNone(loaded)

    def test_save_baseline_also_saves_latest(self):
        """Test that saving a baseline also updates 'latest'."""
        baseline = Baseline(
            name="v1",
            version="1.0.0",
            timestamp=datetime.now().isoformat(),
            metrics={"test": 1.0}
        )
        self.runner.save_baseline(baseline, "v1")

        latest = self.runner.load_baseline("latest")
        self.assertIsNotNone(latest)
        self.assertEqual(latest.name, "v1")

    def test_compare_to_baseline_no_regression(self):
        """Test comparison with no regressions."""
        baseline = Baseline(
            name="base",
            version="1.0.0",
            timestamp=datetime.now().isoformat(),
            metrics={"test.latency_ms": 100.0}
        )
        current_metrics = {"test.latency_ms": 105.0}  # 5% increase, under 10% threshold

        results = self.runner.compare_to_baseline(current_metrics, baseline)

        self.assertEqual(len(results), 1)
        self.assertFalse(results[0].is_regression)
        self.assertFalse(results[0].is_improvement)

    def test_compare_to_baseline_regression(self):
        """Test comparison detects regression."""
        baseline = Baseline(
            name="base",
            version="1.0.0",
            timestamp=datetime.now().isoformat(),
            metrics={"test.latency_ms": 100.0}
        )
        current_metrics = {"test.latency_ms": 115.0}  # 15% increase, over 10% threshold

        results = self.runner.compare_to_baseline(current_metrics, baseline)

        self.assertEqual(len(results), 1)
        self.assertTrue(results[0].is_regression)
        self.assertAlmostEqual(results[0].change_percent, 15.0, places=1)

    def test_compare_to_baseline_improvement(self):
        """Test comparison detects improvement."""
        baseline = Baseline(
            name="base",
            version="1.0.0",
            timestamp=datetime.now().isoformat(),
            metrics={"test.latency_ms": 100.0}
        )
        current_metrics = {"test.latency_ms": 85.0}  # 15% decrease

        results = self.runner.compare_to_baseline(current_metrics, baseline)

        self.assertEqual(len(results), 1)
        self.assertTrue(results[0].is_improvement)
        self.assertAlmostEqual(results[0].change_percent, -15.0, places=1)

    def test_compare_throughput_metric(self):
        """Test throughput metric comparison (inverse threshold)."""
        baseline = Baseline(
            name="base",
            version="1.0.0",
            timestamp=datetime.now().isoformat(),
            metrics={"test.nodes_per_sec": 1000.0}
        )
        # 15% decrease in throughput is a regression
        current_metrics = {"test.nodes_per_sec": 850.0}

        results = self.runner.compare_to_baseline(current_metrics, baseline)

        self.assertEqual(len(results), 1)
        self.assertTrue(results[0].is_regression)

    def test_compare_memory_metric(self):
        """Test memory metric comparison."""
        baseline = Baseline(
            name="base",
            version="1.0.0",
            timestamp=datetime.now().isoformat(),
            metrics={"memory.peak_mb": 100.0}
        )
        # 25% increase in memory is a regression (over 20% threshold)
        current_metrics = {"memory.peak_mb": 125.0}

        results = self.runner.compare_to_baseline(current_metrics, baseline)

        self.assertEqual(len(results), 1)
        self.assertTrue(results[0].is_regression)

    def test_compare_skips_zero_baseline(self):
        """Test that comparison skips metrics with zero baseline."""
        baseline = Baseline(
            name="base",
            version="1.0.0",
            timestamp=datetime.now().isoformat(),
            metrics={"test.metric": 0.0}
        )
        current_metrics = {"test.metric": 100.0}

        results = self.runner.compare_to_baseline(current_metrics, baseline)

        self.assertEqual(len(results), 0)

    def test_compare_skips_missing_metrics(self):
        """Test that comparison skips metrics not in baseline."""
        baseline = Baseline(
            name="base",
            version="1.0.0",
            timestamp=datetime.now().isoformat(),
            metrics={"existing.metric": 100.0}
        )
        current_metrics = {"new.metric": 50.0}

        results = self.runner.compare_to_baseline(current_metrics, baseline)

        self.assertEqual(len(results), 0)


class TestCIIntegration(unittest.TestCase):
    """Tests for CI integration functions."""

    def test_generate_gitlab_report_format(self):
        """Test GitLab report format generation."""
        from regression.ci_integration import generate_gitlab_report

        result = RegressionResult(
            benchmark_name="test",
            metric_name="test.latency",
            baseline_value=10.0,
            current_value=12.0,
            change_percent=20.0,
            threshold_percent=10.0,
            is_regression=True,
            is_improvement=False
        )
        report = RegressionReport(
            version="1.0.0",
            timestamp="2026-01-03",
            baseline_version="0.9.0",
            total_benchmarks=1,
            regressions=[result],
            improvements=[],
            stable=[],
            overall_status="fail"
        )

        gitlab_report = generate_gitlab_report(report)

        self.assertIn("tests", gitlab_report)
        self.assertEqual(gitlab_report["failed_count"], 1)
        self.assertEqual(gitlab_report["success_count"], 0)

    def test_generate_github_annotations(self):
        """Test GitHub annotations generation."""
        from regression.ci_integration import generate_github_annotations

        regression = RegressionResult(
            benchmark_name="test",
            metric_name="test.latency",
            baseline_value=10.0,
            current_value=12.0,
            change_percent=20.0,
            threshold_percent=10.0,
            is_regression=True,
            is_improvement=False
        )
        improvement = RegressionResult(
            benchmark_name="test2",
            metric_name="test2.latency",
            baseline_value=10.0,
            current_value=8.0,
            change_percent=-20.0,
            threshold_percent=10.0,
            is_regression=False,
            is_improvement=True
        )
        report = RegressionReport(
            version="1.0.0",
            timestamp="2026-01-03",
            baseline_version="0.9.0",
            total_benchmarks=2,
            regressions=[regression],
            improvements=[improvement],
            stable=[],
            overall_status="warning"
        )

        annotations = generate_github_annotations(report)

        self.assertEqual(len(annotations), 2)
        self.assertEqual(annotations[0]["level"], "error")
        self.assertEqual(annotations[1]["level"], "notice")


if __name__ == "__main__":
    unittest.main()
