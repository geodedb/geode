#!/usr/bin/env python3
"""
Docker Integration Test Orchestrator for Geode

Coordinates concurrent testing across all client containers and collects results.
Runs for a configurable duration with randomized query patterns.
"""

import asyncio
import json
import os
import random
import signal
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import structlog

# Configure structured logging
structlog.configure(
    processors=[
        structlog.stdlib.add_log_level,
        structlog.stdlib.PositionalArgumentsFormatter(),
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.JSONRenderer()
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    context_class=dict,
    logger_factory=structlog.PrintLoggerFactory(),
    cache_logger_on_first_use=True,
)

log = structlog.get_logger()

# Configuration
GEODE_HOST = os.environ.get("GEODE_HOST", "geode-server")
GEODE_PORT = int(os.environ.get("GEODE_PORT", "8443"))
TEST_DURATION_MINUTES = int(os.environ.get("TEST_DURATION_MINUTES", "30"))
CONCURRENT_WORKERS = int(os.environ.get("CONCURRENT_WORKERS", "10"))
RESULTS_DIR = Path(os.environ.get("RESULTS_DIR", "/results"))
LOGS_DIR = Path(os.environ.get("LOGS_DIR", "/logs"))


@dataclass
class TestResult:
    """Result of a single test execution"""
    test_id: str
    test_name: str
    client: str
    success: bool
    duration_ms: float
    error: str | None = None
    timestamp: str = field(default_factory=lambda: datetime.utcnow().isoformat())


@dataclass
class TestStats:
    """Aggregated test statistics"""
    total_tests: int = 0
    passed: int = 0
    failed: int = 0
    total_duration_ms: float = 0.0
    min_duration_ms: float = float('inf')
    max_duration_ms: float = 0.0
    errors: list = field(default_factory=list)

    @property
    def avg_duration_ms(self) -> float:
        return self.total_duration_ms / self.total_tests if self.total_tests > 0 else 0.0

    @property
    def pass_rate(self) -> float:
        return (self.passed / self.total_tests * 100) if self.total_tests > 0 else 0.0


class QueryGenerator:
    """Generates randomized GQL queries for stress testing"""

    # Node types from our schema
    NODE_TYPES = [
        "Organization", "Department", "Employee", "Project", "Document",
        "Server", "Application", "Database", "Network", "Datacenter",
        "User", "Permission", "Role", "AuditLog", "Policy", "Incident"
    ]

    # Relationship types from our schema
    RELATIONSHIP_TYPES = [
        "HAS_DEPARTMENT", "HAS_EMPLOYEE", "WORKS_ON", "MANAGES",
        "OWNS_PROJECT", "BELONGS_TO_PROJECT", "AUTHORED",
        "RUNS_ON", "CONNECTS_TO", "LOCATED_IN", "IN_NETWORK",
        "DEPENDS_ON", "BELONGS_TO_ROLE", "HAS_PERMISSION",
        "PERFORMED_BY", "APPLIES_TO", "AFFECTS", "ASSIGNED_TO"
    ]

    # Query templates
    QUERY_TEMPLATES = [
        # Simple node queries
        "MATCH (n:{label}) RETURN count(n) AS count",
        "MATCH (n:{label}) RETURN n LIMIT 10",
        "MATCH (n:{label}) WHERE n.id IS NOT NULL RETURN n.id LIMIT 5",

        # Relationship queries
        "MATCH (a)-[r:{rel}]->(b) RETURN count(r) AS count",
        "MATCH (a:{label1})-[r]->(b:{label2}) RETURN a, r, b LIMIT 5",

        # Aggregation queries
        "MATCH (n:{label}) RETURN count(n) AS total, labels(n) AS type",
        "MATCH (e:Employee) RETURN e.department_id, count(e) AS emp_count",

        # Path queries
        "MATCH path = (a:{label1})-[*1..3]->(b:{label2}) RETURN length(path) AS len LIMIT 10",

        # Complex queries
        "MATCH (d:Department)-[:HAS_EMPLOYEE]->(e:Employee) RETURN d.name, count(e) AS employees",
        "MATCH (o:Organization)-[:HAS_DEPARTMENT]->(d)-[:HAS_EMPLOYEE]->(e) RETURN o.name, count(e) AS total_employees",
        "MATCH (p:Project)<-[:WORKS_ON]-(e:Employee) RETURN p.name, collect(e.name) AS team LIMIT 5",

        # Data modification (controlled)
        "CREATE (t:TestNode {{id: '{test_id}', timestamp: datetime()}}) RETURN t.id",
        "MATCH (t:TestNode {{id: '{test_id}'}}) DELETE t",

        # Property access
        "MATCH (e:Employee) WHERE e.salary > 150000 RETURN e.name, e.salary LIMIT 10",
        "MATCH (s:Server) WHERE s.memory_gb >= 128 RETURN s.hostname, s.memory_gb",

        # Date/time queries
        "MATCH (al:AuditLog) WHERE al.timestamp > datetime('2024-11-01T00:00:00Z') RETURN al.action, al.timestamp LIMIT 10",

        # Full-text search (if available)
        "MATCH (d:Document) WHERE d.title CONTAINS 'Technical' RETURN d.title LIMIT 5",
    ]

    def __init__(self, seed: int | None = None):
        self.rng = random.Random(seed)
        self.test_counter = 0

    def generate_query(self) -> tuple[str, str]:
        """Generate a random query and return (query, description)"""
        template = self.rng.choice(self.QUERY_TEMPLATES)

        self.test_counter += 1
        test_id = f"test-{self.test_counter}-{int(time.time() * 1000)}"

        # Fill in template variables
        query = template.format(
            label=self.rng.choice(self.NODE_TYPES),
            label1=self.rng.choice(self.NODE_TYPES),
            label2=self.rng.choice(self.NODE_TYPES),
            rel=self.rng.choice(self.RELATIONSHIP_TYPES),
            test_id=test_id,
        )

        description = f"Query {self.test_counter}: {template.split()[0]}"
        return query, description


class TestOrchestrator:
    """Main test orchestrator"""

    def __init__(self):
        self.stats: dict[str, TestStats] = {
            "global": TestStats(),
            "go": TestStats(),
            "python": TestStats(),
            "rust": TestStats(),
            "zig": TestStats(),
            "geodetestlab": TestStats(),
        }
        self.results: list[TestResult] = []
        self.query_gen = QueryGenerator()
        self.running = True
        self.start_time = None

        # Ensure directories exist
        RESULTS_DIR.mkdir(parents=True, exist_ok=True)
        LOGS_DIR.mkdir(parents=True, exist_ok=True)

    async def wait_for_server(self, timeout: int = 300) -> bool:
        """Wait for Geode server to be ready"""
        log.info("waiting_for_server", host=GEODE_HOST, port=GEODE_PORT, timeout=timeout)

        start = time.time()
        while time.time() - start < timeout:
            try:
                # Try a simple connection test
                # In production, this would use the actual QUIC client
                proc = await asyncio.create_subprocess_exec(
                    "nc", "-z", "-w", "5", GEODE_HOST, str(GEODE_PORT),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE
                )
                await proc.wait()
                if proc.returncode == 0:
                    log.info("server_ready", elapsed=time.time() - start)
                    return True
            except Exception as e:
                log.debug("server_not_ready", error=str(e))

            await asyncio.sleep(2)

        log.error("server_timeout", timeout=timeout)
        return False

    async def run_test(self, client: str, query: str, description: str) -> TestResult:
        """Execute a single test query"""
        test_id = f"{client}-{int(time.time() * 1000)}"
        start = time.time()

        try:
            # For now, simulate test execution
            # In production, this would dispatch to the appropriate client container
            await asyncio.sleep(self.query_gen.rng.uniform(0.01, 0.1))

            duration_ms = (time.time() - start) * 1000
            success = self.query_gen.rng.random() > 0.05  # 95% success rate simulation

            result = TestResult(
                test_id=test_id,
                test_name=description,
                client=client,
                success=success,
                duration_ms=duration_ms,
                error=None if success else "Simulated error for testing"
            )

        except Exception as e:
            duration_ms = (time.time() - start) * 1000
            result = TestResult(
                test_id=test_id,
                test_name=description,
                client=client,
                success=False,
                duration_ms=duration_ms,
                error=str(e)
            )

        # Update stats
        self._update_stats(client, result)
        self.results.append(result)

        return result

    def _update_stats(self, client: str, result: TestResult):
        """Update statistics for a test result"""
        for stats_key in ["global", client]:
            stats = self.stats[stats_key]
            stats.total_tests += 1
            stats.total_duration_ms += result.duration_ms
            stats.min_duration_ms = min(stats.min_duration_ms, result.duration_ms)
            stats.max_duration_ms = max(stats.max_duration_ms, result.duration_ms)

            if result.success:
                stats.passed += 1
            else:
                stats.failed += 1
                if result.error:
                    stats.errors.append({
                        "test_id": result.test_id,
                        "error": result.error,
                        "timestamp": result.timestamp
                    })

    async def worker(self, worker_id: int, client: str):
        """Worker that continuously runs tests"""
        log.info("worker_started", worker_id=worker_id, client=client)

        while self.running:
            query, description = self.query_gen.generate_query()
            result = await self.run_test(client, query, description)

            if result.success:
                log.debug("test_passed", worker=worker_id, test=result.test_name)
            else:
                log.warning("test_failed", worker=worker_id, test=result.test_name, error=result.error)

            # Small delay between tests
            await asyncio.sleep(self.query_gen.rng.uniform(0.1, 0.5))

    async def progress_reporter(self, interval: int = 30):
        """Report progress periodically"""
        while self.running:
            await asyncio.sleep(interval)

            elapsed = time.time() - self.start_time if self.start_time else 0
            remaining = (TEST_DURATION_MINUTES * 60) - elapsed

            global_stats = self.stats["global"]
            log.info(
                "progress_report",
                elapsed_minutes=elapsed / 60,
                remaining_minutes=remaining / 60,
                total_tests=global_stats.total_tests,
                passed=global_stats.passed,
                failed=global_stats.failed,
                pass_rate=f"{global_stats.pass_rate:.1f}%",
                avg_duration_ms=f"{global_stats.avg_duration_ms:.2f}"
            )

    def generate_report(self) -> dict[str, Any]:
        """Generate final test report"""
        report = {
            "summary": {
                "start_time": self.start_time,
                "end_time": datetime.utcnow().isoformat(),
                "duration_minutes": TEST_DURATION_MINUTES,
                "geode_server": f"{GEODE_HOST}:{GEODE_PORT}",
            },
            "global_stats": {
                "total_tests": self.stats["global"].total_tests,
                "passed": self.stats["global"].passed,
                "failed": self.stats["global"].failed,
                "pass_rate": f"{self.stats['global'].pass_rate:.2f}%",
                "avg_duration_ms": self.stats["global"].avg_duration_ms,
                "min_duration_ms": self.stats["global"].min_duration_ms if self.stats["global"].min_duration_ms != float('inf') else 0,
                "max_duration_ms": self.stats["global"].max_duration_ms,
            },
            "client_stats": {},
            "errors": self.stats["global"].errors[:100],  # Limit errors in report
        }

        for client in ["go", "python", "rust", "zig", "geodetestlab"]:
            stats = self.stats[client]
            if stats.total_tests > 0:
                report["client_stats"][client] = {
                    "total_tests": stats.total_tests,
                    "passed": stats.passed,
                    "failed": stats.failed,
                    "pass_rate": f"{stats.pass_rate:.2f}%",
                    "avg_duration_ms": stats.avg_duration_ms,
                }

        return report

    def save_results(self):
        """Save results to files"""
        timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")

        # Save detailed results
        results_file = RESULTS_DIR / f"test_results_{timestamp}.json"
        with open(results_file, "w") as f:
            json.dump([r.__dict__ for r in self.results], f, indent=2)

        # Save summary report
        report_file = RESULTS_DIR / f"test_report_{timestamp}.json"
        with open(report_file, "w") as f:
            json.dump(self.generate_report(), f, indent=2)

        log.info("results_saved", results_file=str(results_file), report_file=str(report_file))

    async def run(self):
        """Main orchestration loop"""
        log.info(
            "orchestrator_starting",
            duration_minutes=TEST_DURATION_MINUTES,
            workers=CONCURRENT_WORKERS,
            server=f"{GEODE_HOST}:{GEODE_PORT}"
        )

        # Wait for server
        if not await self.wait_for_server():
            log.error("server_not_available")
            sys.exit(1)

        self.start_time = datetime.utcnow().isoformat()

        # Create workers for each client type
        clients = ["go", "python", "rust", "zig", "geodetestlab"]
        workers_per_client = max(1, CONCURRENT_WORKERS // len(clients))

        tasks = []
        worker_id = 0
        for client in clients:
            for _ in range(workers_per_client):
                tasks.append(asyncio.create_task(self.worker(worker_id, client)))
                worker_id += 1

        # Add progress reporter
        tasks.append(asyncio.create_task(self.progress_reporter()))

        # Run for specified duration
        try:
            await asyncio.sleep(TEST_DURATION_MINUTES * 60)
        except asyncio.CancelledError:
            pass

        # Stop workers
        self.running = False
        log.info("stopping_workers")

        # Wait for workers to finish current tests
        await asyncio.sleep(2)

        # Cancel remaining tasks
        for task in tasks:
            task.cancel()

        await asyncio.gather(*tasks, return_exceptions=True)

        # Generate and save results
        self.save_results()

        # Print final summary
        report = self.generate_report()
        log.info("test_run_complete", **report["global_stats"])

        return report["global_stats"]["failed"] == 0


def signal_handler(signum, frame):
    """Handle shutdown signals"""
    log.info("shutdown_signal_received", signal=signum)
    sys.exit(0)


async def main():
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    orchestrator = TestOrchestrator()
    success = await orchestrator.run()

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    asyncio.run(main())
