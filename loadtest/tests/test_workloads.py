#!/usr/bin/env python3
# CANARY: REQ=REQ-LOADTEST-TESTS-002; FEATURE="WorkloadTests"; ASPECT=UnitTests; STATUS=EXEMPT; OWNER=loadtest; UPDATED=2026-01-03
"""
Unit tests for Geode Workload Pattern Definitions
"""

import unittest
import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from benchmarks.workloads import (
    WorkloadType,
    WorkloadPattern,
    WORKLOAD_PATTERNS,
    get_workload,
    list_workloads,
)


class TestWorkloadType(unittest.TestCase):
    """Tests for WorkloadType enum."""

    def test_workload_types_exist(self):
        """Verify all expected workload types exist."""
        expected_types = [
            "READ_HEAVY",
            "WRITE_HEAVY",
            "MIXED",
            "ANALYTICAL",
            "TRAVERSAL",
            "BURST",
        ]
        for type_name in expected_types:
            self.assertTrue(hasattr(WorkloadType, type_name))

    def test_workload_type_values(self):
        """Verify workload type values."""
        self.assertEqual(WorkloadType.READ_HEAVY.value, "read_heavy")
        self.assertEqual(WorkloadType.WRITE_HEAVY.value, "write_heavy")
        self.assertEqual(WorkloadType.MIXED.value, "mixed")
        self.assertEqual(WorkloadType.ANALYTICAL.value, "analytical")


class TestWorkloadPattern(unittest.TestCase):
    """Tests for WorkloadPattern dataclass."""

    def test_workload_pattern_creation(self):
        """Test creating a WorkloadPattern instance."""
        pattern = WorkloadPattern(
            name="Test Workload",
            workload_type=WorkloadType.MIXED,
            description="Test description",
            read_ratio=0.5,
            write_ratio=0.5,
            query_mix={"point_lookup": 0.5, "write": 0.5},
            target_qps=100,
            duration_seconds=60,
        )
        self.assertEqual(pattern.name, "Test Workload")
        self.assertEqual(pattern.workload_type, WorkloadType.MIXED)
        self.assertEqual(pattern.read_ratio, 0.5)
        self.assertEqual(pattern.write_ratio, 0.5)
        self.assertEqual(pattern.target_qps, 100)
        self.assertEqual(pattern.duration_seconds, 60)

    def test_workload_pattern_defaults(self):
        """Test default values for WorkloadPattern."""
        pattern = WorkloadPattern(
            name="Test",
            workload_type=WorkloadType.READ_HEAVY,
            description="Test",
            read_ratio=1.0,
            write_ratio=0.0,
            query_mix={},
            target_qps=100,
            duration_seconds=60,
        )
        self.assertEqual(pattern.ramp_up_seconds, 30)
        self.assertEqual(pattern.concurrent_users, 10)


class TestWorkloadPatterns(unittest.TestCase):
    """Tests for predefined WORKLOAD_PATTERNS."""

    def test_all_patterns_exist(self):
        """Verify all expected patterns are defined."""
        expected_patterns = [
            "web_app",
            "social_network",
            "fraud_detection",
            "recommendation_engine",
            "network_monitoring",
            "burst_traffic",
            "analytics_batch",
            "internet_scale_ingest",
        ]
        for pattern_name in expected_patterns:
            self.assertIn(pattern_name, WORKLOAD_PATTERNS)

    def test_web_app_pattern(self):
        """Test web_app workload pattern configuration."""
        pattern = WORKLOAD_PATTERNS["web_app"]
        self.assertEqual(pattern.name, "Web Application")
        self.assertEqual(pattern.workload_type, WorkloadType.READ_HEAVY)
        self.assertEqual(pattern.read_ratio, 0.95)
        self.assertEqual(pattern.write_ratio, 0.05)
        self.assertEqual(pattern.target_qps, 1000)
        self.assertIn("point_lookup", pattern.query_mix)

    def test_social_network_pattern(self):
        """Test social_network workload pattern configuration."""
        pattern = WORKLOAD_PATTERNS["social_network"]
        self.assertEqual(pattern.workload_type, WorkloadType.MIXED)
        self.assertEqual(pattern.read_ratio, 0.80)
        self.assertEqual(pattern.write_ratio, 0.20)
        self.assertIn("traversal", pattern.query_mix)

    def test_fraud_detection_pattern(self):
        """Test fraud_detection workload pattern configuration."""
        pattern = WORKLOAD_PATTERNS["fraud_detection"]
        self.assertEqual(pattern.workload_type, WorkloadType.ANALYTICAL)
        self.assertIn("pattern", pattern.query_mix)
        self.assertEqual(pattern.duration_seconds, 600)

    def test_network_monitoring_pattern(self):
        """Test network_monitoring workload pattern (write-heavy)."""
        pattern = WORKLOAD_PATTERNS["network_monitoring"]
        self.assertEqual(pattern.workload_type, WorkloadType.WRITE_HEAVY)
        self.assertEqual(pattern.write_ratio, 0.70)
        self.assertEqual(pattern.target_qps, 5000)

    def test_burst_traffic_pattern(self):
        """Test burst_traffic workload pattern."""
        pattern = WORKLOAD_PATTERNS["burst_traffic"]
        self.assertEqual(pattern.workload_type, WorkloadType.BURST)
        self.assertEqual(pattern.ramp_up_seconds, 10)
        self.assertEqual(pattern.concurrent_users, 200)

    def test_internet_scale_ingest_pattern(self):
        """Test internet_scale_ingest workload pattern."""
        pattern = WORKLOAD_PATTERNS["internet_scale_ingest"]
        self.assertEqual(pattern.write_ratio, 0.95)
        self.assertEqual(pattern.target_qps, 50000)
        self.assertEqual(pattern.duration_seconds, 3600)

    def test_query_mix_ratios_sum_to_one(self):
        """Verify query mix ratios sum to approximately 1.0."""
        for name, pattern in WORKLOAD_PATTERNS.items():
            total = sum(pattern.query_mix.values())
            self.assertAlmostEqual(
                total, 1.0, places=2,
                msg=f"Pattern {name} query_mix sums to {total}"
            )

    def test_read_write_ratios_sum_to_one(self):
        """Verify read/write ratios sum to 1.0."""
        for name, pattern in WORKLOAD_PATTERNS.items():
            total = pattern.read_ratio + pattern.write_ratio
            self.assertAlmostEqual(
                total, 1.0, places=2,
                msg=f"Pattern {name} read/write ratios sum to {total}"
            )


class TestGetWorkload(unittest.TestCase):
    """Tests for get_workload function."""

    def test_get_existing_workload(self):
        """Test retrieving an existing workload."""
        pattern = get_workload("web_app")
        self.assertIsInstance(pattern, WorkloadPattern)
        self.assertEqual(pattern.name, "Web Application")

    def test_get_nonexistent_workload(self):
        """Test retrieving a non-existent workload raises error."""
        with self.assertRaises(ValueError) as context:
            get_workload("nonexistent_workload")
        self.assertIn("Unknown workload", str(context.exception))
        self.assertIn("nonexistent_workload", str(context.exception))


class TestListWorkloads(unittest.TestCase):
    """Tests for list_workloads function."""

    def test_list_workloads_returns_list(self):
        """Test list_workloads returns a list."""
        workloads = list_workloads()
        self.assertIsInstance(workloads, list)

    def test_list_workloads_contains_all_patterns(self):
        """Test list_workloads contains all defined patterns."""
        workloads = list_workloads()
        self.assertEqual(len(workloads), len(WORKLOAD_PATTERNS))
        for name in WORKLOAD_PATTERNS.keys():
            self.assertIn(name, workloads)


if __name__ == "__main__":
    unittest.main()
