#!/usr/bin/env python3
# CANARY: REQ=REQ-LOADTEST-TESTS-005; FEATURE="QuerySuiteTests"; ASPECT=UnitTests; STATUS=EXEMPT; OWNER=loadtest; UPDATED=2026-01-03
"""
Unit tests for Geode Benchmark Query Suite
"""

import unittest
import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from benchmarks.query_suite import (
    QueryBenchmark,
    BenchmarkResult,
    POINT_LOOKUPS,
    TRAVERSAL_QUERIES,
    AGGREGATION_QUERIES,
)


class TestQueryBenchmark(unittest.TestCase):
    """Tests for QueryBenchmark dataclass."""

    def test_query_benchmark_creation(self):
        """Test creating a QueryBenchmark instance."""
        query = QueryBenchmark(
            name="test_query",
            category="point_lookup",
            query="MATCH (n) RETURN n",
            description="Test query",
            expected_complexity="O(1)",
            params={"limit": 10}
        )
        self.assertEqual(query.name, "test_query")
        self.assertEqual(query.category, "point_lookup")
        self.assertEqual(query.query, "MATCH (n) RETURN n")
        self.assertEqual(query.expected_complexity, "O(1)")
        self.assertEqual(query.params["limit"], 10)

    def test_query_benchmark_defaults(self):
        """Test default values for QueryBenchmark."""
        query = QueryBenchmark(
            name="test",
            category="traversal",
            query="MATCH (n) RETURN n"
        )
        self.assertEqual(query.expected_complexity, "O(n)")
        self.assertEqual(query.params, {})
        self.assertEqual(query.warmup_runs, 3)
        self.assertEqual(query.benchmark_runs, 10)


class TestBenchmarkResult(unittest.TestCase):
    """Tests for BenchmarkResult dataclass."""

    def test_benchmark_result_creation(self):
        """Test creating a BenchmarkResult instance."""
        result = BenchmarkResult(
            benchmark_name="test_query",
            category="point_lookup",
            latencies_ms=[10.0, 12.0, 11.0, 15.0, 13.0],
            rows_returned=[1, 1, 1, 1, 1],
            success_count=5,
            error_count=0
        )
        self.assertEqual(result.benchmark_name, "test_query")
        self.assertEqual(result.success_count, 5)
        self.assertEqual(result.error_count, 0)

    def test_avg_latency_calculation(self):
        """Test average latency calculation."""
        result = BenchmarkResult(
            benchmark_name="test",
            category="test",
            latencies_ms=[10.0, 20.0, 30.0],
            rows_returned=[1, 1, 1],
            success_count=3,
            error_count=0
        )
        self.assertAlmostEqual(result.avg_latency_ms, 20.0)

    def test_p50_latency_calculation(self):
        """Test p50 (median) latency calculation."""
        result = BenchmarkResult(
            benchmark_name="test",
            category="test",
            latencies_ms=[10.0, 20.0, 30.0, 40.0, 50.0],
            rows_returned=[1, 1, 1, 1, 1],
            success_count=5,
            error_count=0
        )
        self.assertAlmostEqual(result.p50_latency_ms, 30.0)

    def test_p95_latency_calculation(self):
        """Test p95 latency calculation."""
        result = BenchmarkResult(
            benchmark_name="test",
            category="test",
            latencies_ms=list(range(1, 101)),  # 1-100
            rows_returned=[1] * 100,
            success_count=100,
            error_count=0
        )
        self.assertGreaterEqual(result.p95_latency_ms, 95)

    def test_empty_latencies(self):
        """Test handling of empty latencies."""
        result = BenchmarkResult(
            benchmark_name="test",
            category="test",
            latencies_ms=[],
            rows_returned=[],
            success_count=0,
            error_count=0
        )
        self.assertEqual(result.avg_latency_ms, 0)
        self.assertEqual(result.p50_latency_ms, 0)
        self.assertEqual(result.p95_latency_ms, 0)
        self.assertEqual(result.qps, 0)


class TestPointLookups(unittest.TestCase):
    """Tests for predefined POINT_LOOKUPS."""

    def test_point_lookups_exist(self):
        """Verify point lookup queries are defined."""
        self.assertGreater(len(POINT_LOOKUPS), 0)

    def test_point_lookups_have_required_fields(self):
        """Verify all point lookups have required fields."""
        for query in POINT_LOOKUPS:
            self.assertIsNotNone(query.name)
            self.assertEqual(query.category, "point_lookup")
            self.assertIsNotNone(query.query)
            self.assertIn("MATCH", query.query.upper())

    def test_lookup_by_id_exists(self):
        """Verify lookup_by_id query exists."""
        names = [q.name for q in POINT_LOOKUPS]
        self.assertIn("lookup_by_id", names)


class TestTraversalQueries(unittest.TestCase):
    """Tests for predefined TRAVERSAL_QUERIES."""

    def test_traversal_queries_exist(self):
        """Verify traversal queries are defined."""
        self.assertGreater(len(TRAVERSAL_QUERIES), 0)

    def test_traversal_queries_have_required_fields(self):
        """Verify all traversal queries have required fields."""
        for query in TRAVERSAL_QUERIES:
            self.assertIsNotNone(query.name)
            self.assertEqual(query.category, "traversal")
            self.assertIsNotNone(query.query)

    def test_shortest_path_exists(self):
        """Verify shortest path query exists."""
        names = [q.name for q in TRAVERSAL_QUERIES]
        self.assertIn("shortest_path", names)


class TestAggregationQueries(unittest.TestCase):
    """Tests for predefined AGGREGATION_QUERIES."""

    def test_aggregation_queries_exist(self):
        """Verify aggregation queries are defined."""
        self.assertGreater(len(AGGREGATION_QUERIES), 0)

    def test_aggregation_queries_have_return(self):
        """Verify all aggregation queries include RETURN."""
        for query in AGGREGATION_QUERIES:
            self.assertIn("RETURN", query.query.upper())


class TestQueryGqlSyntax(unittest.TestCase):
    """Tests for query GQL syntax validity."""

    def test_queries_have_valid_keywords(self):
        """Verify queries contain valid GQL keywords."""
        valid_starts = [
            "MATCH", "CREATE", "RETURN", "WITH", "OPTIONAL",
            "CALL", "UNWIND", "MERGE", "DELETE", "SET"
        ]
        all_queries = POINT_LOOKUPS + TRAVERSAL_QUERIES + AGGREGATION_QUERIES
        for query in all_queries:
            gql = query.query.strip().upper()
            has_valid_start = any(gql.startswith(kw) for kw in valid_starts)
            self.assertTrue(
                has_valid_start,
                f"Query {query.name} doesn't start with valid keyword: {query.query[:50]}"
            )


if __name__ == "__main__":
    unittest.main()
