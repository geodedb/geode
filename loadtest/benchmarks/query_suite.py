#!/usr/bin/env python3
# CANARY: REQ=REQ-LOADTEST-BENCHMARKS-001; FEATURE="BenchmarkQuerySuite"; ASPECT=Main; STATUS=IMPL; OWNER=loadtest; UPDATED=2026-01-03
"""
Geode Benchmark Query Suite

Comprehensive query benchmarks for internet-scale graph testing.
Includes read, write, traversal, and analytical query patterns.
"""

import json
import time
import random
import argparse
import statistics
from dataclasses import dataclass, field, asdict
from typing import List, Dict, Optional, Callable
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
import subprocess


@dataclass
class QueryBenchmark:
    """Definition of a benchmark query."""
    name: str
    category: str
    query: str
    params: Dict = field(default_factory=dict)
    description: str = ""
    expected_complexity: str = "O(n)"  # Estimated complexity
    warmup_runs: int = 3
    benchmark_runs: int = 10


@dataclass
class BenchmarkResult:
    """Result of running a benchmark."""
    benchmark_name: str
    category: str
    latencies_ms: List[float]
    rows_returned: List[int]
    success_count: int
    error_count: int
    errors: List[str] = field(default_factory=list)

    @property
    def avg_latency_ms(self) -> float:
        return statistics.mean(self.latencies_ms) if self.latencies_ms else 0

    @property
    def p50_latency_ms(self) -> float:
        return statistics.median(self.latencies_ms) if self.latencies_ms else 0

    @property
    def p95_latency_ms(self) -> float:
        if not self.latencies_ms:
            return 0
        sorted_latencies = sorted(self.latencies_ms)
        idx = int(len(sorted_latencies) * 0.95)
        return sorted_latencies[min(idx, len(sorted_latencies) - 1)]

    @property
    def p99_latency_ms(self) -> float:
        if not self.latencies_ms:
            return 0
        sorted_latencies = sorted(self.latencies_ms)
        idx = int(len(sorted_latencies) * 0.99)
        return sorted_latencies[min(idx, len(sorted_latencies) - 1)]

    @property
    def stddev_ms(self) -> float:
        return statistics.stdev(self.latencies_ms) if len(self.latencies_ms) > 1 else 0

    @property
    def qps(self) -> float:
        total_time_sec = sum(self.latencies_ms) / 1000
        return self.success_count / total_time_sec if total_time_sec > 0 else 0


# ============================================================================
# Benchmark Query Definitions
# ============================================================================

POINT_LOOKUPS = [
    QueryBenchmark(
        name="lookup_by_id",
        category="point_lookup",
        query="MATCH (n) WHERE id(n) = $nodeId RETURN n",
        params={"nodeId": 1},
        description="Single node lookup by ID",
        expected_complexity="O(1)"
    ),
    QueryBenchmark(
        name="lookup_by_property",
        category="point_lookup",
        query="MATCH (n:Host {ip: $ip}) RETURN n",
        params={"ip": "10.0.0.1"},
        description="Indexed property lookup",
        expected_complexity="O(log n)"
    ),
    QueryBenchmark(
        name="lookup_by_composite",
        category="point_lookup",
        query="MATCH (n:Host) WHERE n.asn = $asn AND n.type = $type RETURN n LIMIT 1",
        params={"asn": 64512, "type": "server"},
        description="Composite property lookup",
        expected_complexity="O(log n)"
    ),
]

TRAVERSAL_QUERIES = [
    QueryBenchmark(
        name="single_hop",
        category="traversal",
        query="MATCH (a:Host)-[:CONNECTS]->(b:Host) WHERE a.ip = $ip RETURN b LIMIT 100",
        params={"ip": "10.0.0.1"},
        description="Single hop traversal",
        expected_complexity="O(d)"
    ),
    QueryBenchmark(
        name="two_hop",
        category="traversal",
        query="MATCH (a:Host)-[:CONNECTS*2]->(c:Host) WHERE a.ip = $ip RETURN DISTINCT c LIMIT 100",
        params={"ip": "10.0.0.1"},
        description="Two hop traversal with deduplication",
        expected_complexity="O(d^2)"
    ),
    QueryBenchmark(
        name="variable_length_path",
        category="traversal",
        query="MATCH p = (a:Host)-[:CONNECTS*1..5]->(b:Host) WHERE a.ip = $src AND b.ip = $dst RETURN p LIMIT 10",
        params={"src": "10.0.0.1", "dst": "10.0.1.1"},
        description="Variable length path finding",
        expected_complexity="O(d^k)"
    ),
    QueryBenchmark(
        name="shortest_path",
        category="traversal",
        query="MATCH p = shortestPath((a:Host)-[:CONNECTS*]->(b:Host)) WHERE a.ip = $src AND b.ip = $dst RETURN p",
        params={"src": "10.0.0.1", "dst": "10.0.5.1"},
        description="Shortest path between nodes",
        expected_complexity="O(V + E)"
    ),
    QueryBenchmark(
        name="bidirectional_traversal",
        category="traversal",
        query="MATCH (a:Host)-[:CONNECTS]-(b:Host) WHERE a.ip = $ip RETURN b LIMIT 100",
        params={"ip": "10.0.0.1"},
        description="Bidirectional single hop",
        expected_complexity="O(d_in + d_out)"
    ),
]

AGGREGATION_QUERIES = [
    QueryBenchmark(
        name="count_all_nodes",
        category="aggregation",
        query="MATCH (n) RETURN count(n) AS total",
        description="Count all nodes",
        expected_complexity="O(1) with stats"
    ),
    QueryBenchmark(
        name="count_by_label",
        category="aggregation",
        query="MATCH (n:Host) RETURN count(n) AS hosts",
        description="Count nodes by label",
        expected_complexity="O(1) with stats"
    ),
    QueryBenchmark(
        name="group_by_property",
        category="aggregation",
        query="MATCH (n:Host) RETURN n.type AS type, count(*) AS cnt ORDER BY cnt DESC",
        description="Group and count by property",
        expected_complexity="O(n)"
    ),
    QueryBenchmark(
        name="aggregate_statistics",
        category="aggregation",
        query="MATCH (n:Host) RETURN avg(n.port_count) AS avg_ports, max(n.port_count) AS max_ports, min(n.port_count) AS min_ports",
        description="Statistical aggregation",
        expected_complexity="O(n)"
    ),
    QueryBenchmark(
        name="degree_distribution",
        category="aggregation",
        query="MATCH (n:Host) RETURN outdegree(n) AS degree, count(*) AS cnt ORDER BY degree",
        description="Compute degree distribution",
        expected_complexity="O(V + E)"
    ),
]

ANALYTICAL_QUERIES = [
    QueryBenchmark(
        name="pagerank_top10",
        category="analytical",
        query="CALL algo.pageRank.stream({iterations: 20}) YIELD nodeId, score RETURN nodeId, score ORDER BY score DESC LIMIT 10",
        description="Top 10 PageRank scores",
        expected_complexity="O(V * iterations)"
    ),
    QueryBenchmark(
        name="community_detection",
        category="analytical",
        query="CALL algo.louvain.stream() YIELD nodeId, communityId RETURN communityId, count(*) AS size ORDER BY size DESC LIMIT 20",
        description="Louvain community sizes",
        expected_complexity="O(V + E)"
    ),
    QueryBenchmark(
        name="betweenness_centrality",
        category="analytical",
        query="CALL algo.betweenness.stream({sampleSize: 100}) YIELD nodeId, centrality RETURN nodeId, centrality ORDER BY centrality DESC LIMIT 10",
        description="Sampled betweenness centrality",
        expected_complexity="O(V * E) sampled"
    ),
    QueryBenchmark(
        name="triangle_count",
        category="analytical",
        query="CALL algo.triangleCount.stream() YIELD nodeId, triangles RETURN sum(triangles) / 3 AS total_triangles",
        description="Total triangle count",
        expected_complexity="O(E^1.5)"
    ),
    QueryBenchmark(
        name="connected_components",
        category="analytical",
        query="CALL algo.unionFind.stream() YIELD nodeId, componentId RETURN componentId, count(*) AS size ORDER BY size DESC LIMIT 10",
        description="Largest connected components",
        expected_complexity="O(V + E)"
    ),
]

WRITE_QUERIES = [
    QueryBenchmark(
        name="create_node",
        category="write",
        query="CREATE (n:TestNode {id: $id, timestamp: datetime()}) RETURN n",
        params={"id": 0},
        description="Create single node",
        expected_complexity="O(1)"
    ),
    QueryBenchmark(
        name="create_relationship",
        category="write",
        query="MATCH (a:Host), (b:Host) WHERE id(a) = $src AND id(b) = $dst CREATE (a)-[:TEST_CONN]->(b)",
        params={"src": 1, "dst": 2},
        description="Create relationship between existing nodes",
        expected_complexity="O(1)"
    ),
    QueryBenchmark(
        name="update_property",
        category="write",
        query="MATCH (n:Host) WHERE id(n) = $nodeId SET n.last_seen = datetime() RETURN n",
        params={"nodeId": 1},
        description="Update node property",
        expected_complexity="O(1)"
    ),
    QueryBenchmark(
        name="batch_create",
        category="write",
        query="UNWIND $nodes AS node CREATE (n:BatchNode {id: node.id, value: node.value})",
        params={"nodes": [{"id": i, "value": f"val_{i}"} for i in range(100)]},
        description="Batch create 100 nodes",
        expected_complexity="O(batch_size)"
    ),
    QueryBenchmark(
        name="delete_pattern",
        category="write",
        query="MATCH (n:TestNode) WHERE n.id < $maxId DETACH DELETE n",
        params={"maxId": 100},
        description="Delete nodes matching pattern",
        expected_complexity="O(matches)"
    ),
]

PATTERN_MATCHING = [
    QueryBenchmark(
        name="triangle_pattern",
        category="pattern",
        query="MATCH (a:Host)-[:CONNECTS]->(b:Host)-[:CONNECTS]->(c:Host)-[:CONNECTS]->(a) RETURN a, b, c LIMIT 10",
        description="Find triangles",
        expected_complexity="O(E^1.5)"
    ),
    QueryBenchmark(
        name="star_pattern",
        category="pattern",
        query="MATCH (center:Host)-[:CONNECTS]->(leaf:Host) WITH center, count(leaf) AS degree WHERE degree > 10 RETURN center, degree LIMIT 10",
        description="Find high-degree hubs",
        expected_complexity="O(V)"
    ),
    QueryBenchmark(
        name="path_with_properties",
        category="pattern",
        query="MATCH p = (a:Host)-[r:CONNECTS*1..3]->(b:Host) WHERE all(rel IN r WHERE rel.bytes > 1000) RETURN p LIMIT 10",
        params={},
        description="Path with property filters",
        expected_complexity="O(d^k)"
    ),
    QueryBenchmark(
        name="negative_pattern",
        category="pattern",
        query="MATCH (a:Host) WHERE NOT (a)-[:CONNECTS]->(:Host {type: 'malicious'}) RETURN a LIMIT 100",
        description="Negative pattern matching",
        expected_complexity="O(V * avg_degree)"
    ),
]

ALL_BENCHMARKS = (
    POINT_LOOKUPS +
    TRAVERSAL_QUERIES +
    AGGREGATION_QUERIES +
    ANALYTICAL_QUERIES +
    WRITE_QUERIES +
    PATTERN_MATCHING
)


# ============================================================================
# Benchmark Runner
# ============================================================================

class BenchmarkRunner:
    """Executes benchmark queries against Geode server."""

    def __init__(
        self,
        host: str = "localhost",
        port: int = 3141,
        geode_path: str = "./zig-out/bin/geode",
        parallel: int = 1
    ):
        self.host = host
        self.port = port
        self.geode_path = geode_path
        self.parallel = parallel

    def execute_query(self, query: str, params: Dict = None) -> tuple:
        """Execute a query and return (latency_ms, row_count, error)."""
        # Build the query with parameters substituted
        final_query = query
        if params:
            for key, value in params.items():
                if isinstance(value, str):
                    final_query = final_query.replace(f"${key}", f"'{value}'")
                elif isinstance(value, list):
                    final_query = final_query.replace(f"${key}", json.dumps(value))
                else:
                    final_query = final_query.replace(f"${key}", str(value))

        start = time.perf_counter()
        try:
            result = subprocess.run(
                [self.geode_path, "query", final_query],
                capture_output=True,
                text=True,
                timeout=60
            )
            elapsed_ms = (time.perf_counter() - start) * 1000

            if result.returncode != 0:
                return elapsed_ms, 0, result.stderr.strip()

            # Parse row count from output
            row_count = len(result.stdout.strip().split('\n')) - 1  # Subtract header
            return elapsed_ms, max(0, row_count), None

        except subprocess.TimeoutExpired:
            elapsed_ms = (time.perf_counter() - start) * 1000
            return elapsed_ms, 0, "Query timeout"
        except Exception as e:
            elapsed_ms = (time.perf_counter() - start) * 1000
            return elapsed_ms, 0, str(e)

    def run_benchmark(self, benchmark: QueryBenchmark) -> BenchmarkResult:
        """Run a single benchmark."""
        latencies = []
        row_counts = []
        errors = []
        success_count = 0
        error_count = 0

        # Warmup runs
        for _ in range(benchmark.warmup_runs):
            self.execute_query(benchmark.query, benchmark.params)

        # Benchmark runs
        for i in range(benchmark.benchmark_runs):
            # Vary parameters slightly for some benchmarks
            params = benchmark.params.copy()
            if "id" in params and benchmark.category == "write":
                params["id"] = i + random.randint(100000, 999999)

            latency, rows, error = self.execute_query(benchmark.query, params)

            if error:
                error_count += 1
                errors.append(error)
            else:
                success_count += 1
                latencies.append(latency)
                row_counts.append(rows)

        return BenchmarkResult(
            benchmark_name=benchmark.name,
            category=benchmark.category,
            latencies_ms=latencies,
            rows_returned=row_counts,
            success_count=success_count,
            error_count=error_count,
            errors=errors[:5]  # Keep first 5 errors
        )

    def run_all(self, benchmarks: List[QueryBenchmark] = None) -> List[BenchmarkResult]:
        """Run all benchmarks."""
        benchmarks = benchmarks or ALL_BENCHMARKS
        results = []

        if self.parallel > 1:
            with ThreadPoolExecutor(max_workers=self.parallel) as executor:
                futures = {executor.submit(self.run_benchmark, b): b for b in benchmarks}
                for future in as_completed(futures):
                    results.append(future.result())
        else:
            for benchmark in benchmarks:
                print(f"Running: {benchmark.name}...", end=" ", flush=True)
                result = self.run_benchmark(benchmark)
                print(f"{result.avg_latency_ms:.2f}ms (p95: {result.p95_latency_ms:.2f}ms)")
                results.append(result)

        return results


# ============================================================================
# Report Generation
# ============================================================================

def generate_report(results: List[BenchmarkResult], output_format: str = "text") -> str:
    """Generate benchmark report."""
    if output_format == "json":
        return json.dumps([{
            "name": r.benchmark_name,
            "category": r.category,
            "avg_ms": r.avg_latency_ms,
            "p50_ms": r.p50_latency_ms,
            "p95_ms": r.p95_latency_ms,
            "p99_ms": r.p99_latency_ms,
            "stddev_ms": r.stddev_ms,
            "qps": r.qps,
            "success": r.success_count,
            "errors": r.error_count
        } for r in results], indent=2)

    # Text format
    lines = [
        "=" * 100,
        f"Geode Benchmark Results - {datetime.now().isoformat()}",
        "=" * 100,
        "",
        f"{'Benchmark':<35} {'Category':<15} {'Avg(ms)':<10} {'P50(ms)':<10} {'P95(ms)':<10} {'P99(ms)':<10} {'QPS':<10}",
        "-" * 100
    ]

    # Group by category
    by_category = {}
    for r in results:
        by_category.setdefault(r.category, []).append(r)

    for category, cat_results in sorted(by_category.items()):
        lines.append(f"\n## {category.upper()}")
        for r in cat_results:
            status = "✓" if r.error_count == 0 else f"✗({r.error_count})"
            lines.append(
                f"{r.benchmark_name:<35} {r.category:<15} "
                f"{r.avg_latency_ms:>8.2f}  {r.p50_latency_ms:>8.2f}  "
                f"{r.p95_latency_ms:>8.2f}  {r.p99_latency_ms:>8.2f}  "
                f"{r.qps:>8.1f}  {status}"
            )

    # Summary
    total_success = sum(r.success_count for r in results)
    total_errors = sum(r.error_count for r in results)
    avg_latency = statistics.mean(r.avg_latency_ms for r in results if r.latencies_ms)

    lines.extend([
        "",
        "=" * 100,
        "SUMMARY",
        "=" * 100,
        f"Total Benchmarks: {len(results)}",
        f"Total Queries: {total_success + total_errors}",
        f"Success Rate: {total_success / (total_success + total_errors) * 100:.1f}%",
        f"Average Latency: {avg_latency:.2f}ms",
    ])

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Geode Benchmark Query Suite")
    parser.add_argument("--host", default="localhost", help="Geode server host")
    parser.add_argument("--port", type=int, default=3141, help="Geode server port")
    parser.add_argument("--geode", default="./zig-out/bin/geode", help="Path to geode binary")
    parser.add_argument("--category", choices=["point_lookup", "traversal", "aggregation", "analytical", "write", "pattern", "all"],
                        default="all", help="Category of benchmarks to run")
    parser.add_argument("--parallel", type=int, default=1, help="Number of parallel workers")
    parser.add_argument("--runs", type=int, default=10, help="Number of benchmark runs per query")
    parser.add_argument("--warmup", type=int, default=3, help="Number of warmup runs")
    parser.add_argument("--output", choices=["text", "json"], default="text", help="Output format")
    parser.add_argument("--save", help="Save results to file")

    args = parser.parse_args()

    # Filter benchmarks by category
    if args.category == "all":
        benchmarks = ALL_BENCHMARKS
    else:
        benchmarks = [b for b in ALL_BENCHMARKS if b.category == args.category]

    # Update runs
    for b in benchmarks:
        b.benchmark_runs = args.runs
        b.warmup_runs = args.warmup

    print(f"Running {len(benchmarks)} benchmarks...")

    runner = BenchmarkRunner(
        host=args.host,
        port=args.port,
        geode_path=args.geode,
        parallel=args.parallel
    )

    results = runner.run_all(benchmarks)
    report = generate_report(results, args.output)

    print(report)

    if args.save:
        with open(args.save, "w") as f:
            f.write(report)
        print(f"\nResults saved to {args.save}")


if __name__ == "__main__":
    main()
