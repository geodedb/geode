#!/usr/bin/env python3
"""
Unified test runner for all Geode client libraries.

Runs identical test specifications across Zig, Go, Rust, and Python clients
to ensure feature parity and correctness.
"""

import argparse
import asyncio
import json
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml


@dataclass
class TestResult:
    """Result of a single test execution."""

    test_name: str
    client: str
    status: str  # "passed", "failed", "skipped", "error"
    duration_ms: float
    error_message: Optional[str] = None
    details: Dict[str, Any] = field(default_factory=dict)


@dataclass
class TestSummary:
    """Summary of test run for a client."""

    client: str
    total: int = 0
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    errors: int = 0
    duration_ms: float = 0.0


class ClientRunner:
    """Base class for language-specific test runners."""

    def __init__(self, client_name: str, server: str):
        self.client_name = client_name
        self.server = server

    async def run_test(self, spec: Dict[str, Any], test: Dict[str, Any]) -> TestResult:
        """Run a single test."""
        raise NotImplementedError

    async def setup(self) -> bool:
        """Setup runner (verify binary exists, etc.)."""
        return True

    async def teardown(self):
        """Cleanup after tests."""
        pass


class PythonRunner(ClientRunner):
    """Python client test runner."""

    def __init__(self, server: str):
        super().__init__("python", server)
        self.runner_path = Path(__file__).parent / "runners" / "python_runner.py"

    async def run_test(self, spec: Dict[str, Any], test: Dict[str, Any]) -> TestResult:
        start_time = time.time()

        try:
            # Create temporary test file
            test_spec = {"tests": [test]}
            test_file = Path("/tmp") / f"test_{test['name']}.yaml"
            test_file.write_text(yaml.dump(test_spec))

            # Run Python runner using the same Python interpreter
            proc = await asyncio.create_subprocess_exec(
                sys.executable,
                str(self.runner_path),
                "--spec",
                str(test_file),
                "--server",
                self.server,
                "--json",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=test.get("timeout_ms", 30000) / 1000
            )

            duration_ms = (time.time() - start_time) * 1000

            # Parse result
            if proc.returncode == 0:
                result = json.loads(stdout.decode())
                return TestResult(
                    test_name=test["name"],
                    client="python",
                    status="passed",
                    duration_ms=duration_ms,
                    details=result,
                )
            else:
                return TestResult(
                    test_name=test["name"],
                    client="python",
                    status="failed",
                    duration_ms=duration_ms,
                    error_message=stderr.decode(),
                )

        except asyncio.TimeoutError:
            return TestResult(
                test_name=test["name"],
                client="python",
                status="error",
                duration_ms=(time.time() - start_time) * 1000,
                error_message="Test timed out",
            )
        except Exception as e:
            return TestResult(
                test_name=test["name"],
                client="python",
                status="error",
                duration_ms=(time.time() - start_time) * 1000,
                error_message=str(e),
            )

    async def setup(self) -> bool:
        """Verify Python runner exists."""
        return self.runner_path.exists()


class GoRunner(ClientRunner):
    """Go client test runner."""

    def __init__(self, server: str):
        super().__init__("go", server)
        self.runner_path = Path(__file__).parent / "runners" / "go_runner"

    async def run_test(self, spec: Dict[str, Any], test: Dict[str, Any]) -> TestResult:
        start_time = time.time()

        try:
            # Create temporary test file
            test_spec = {"tests": [test]}
            test_file = Path("/tmp") / f"test_{test['name']}.yaml"
            test_file.write_text(yaml.dump(test_spec))

            # Run Go runner
            proc = await asyncio.create_subprocess_exec(
                str(self.runner_path),
                "-spec",
                str(test_file),
                "-server",
                self.server,
                "-json",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=test.get("timeout_ms", 30000) / 1000
            )

            duration_ms = (time.time() - start_time) * 1000

            if proc.returncode == 0:
                result = json.loads(stdout.decode())
                return TestResult(
                    test_name=test["name"],
                    client="go",
                    status="passed",
                    duration_ms=duration_ms,
                    details=result,
                )
            else:
                return TestResult(
                    test_name=test["name"],
                    client="go",
                    status="failed",
                    duration_ms=duration_ms,
                    error_message=stderr.decode(),
                )

        except asyncio.TimeoutError:
            return TestResult(
                test_name=test["name"],
                client="go",
                status="error",
                duration_ms=(time.time() - start_time) * 1000,
                error_message="Test timed out",
            )
        except Exception as e:
            return TestResult(
                test_name=test["name"],
                client="go",
                status="error",
                duration_ms=(time.time() - start_time) * 1000,
                error_message=str(e),
            )

    async def setup(self) -> bool:
        """Build Go runner if needed."""
        runners_dir = Path(__file__).parent / "runners"
        go_file = runners_dir / "go_runner.go"

        # Check if go is available
        go_check = await asyncio.create_subprocess_exec(
            "which", "go",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await go_check.wait()

        if go_check.returncode != 0:
            print(f"Go not found - Go runner unavailable (install Go to enable)")
            return False

        if not self.runner_path.exists() and go_file.exists():
            print(f"Building Go runner...")
            # Initialize go.mod if needed
            go_mod = runners_dir / "go.mod"
            if not go_mod.exists():
                proc = await asyncio.create_subprocess_exec(
                    "go", "mod", "init",
                    "github.com/spyderorg/geode/clients/test-harness/runners",
                    cwd=str(runners_dir),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                await proc.wait()

            # Get dependencies
            proc = await asyncio.create_subprocess_exec(
                "go", "mod", "tidy",
                cwd=str(runners_dir),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.wait()

            # Build
            proc = await asyncio.create_subprocess_exec(
                "go", "build", "-o", str(self.runner_path), str(go_file),
                cwd=str(runners_dir),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.wait()
            if proc.returncode != 0:
                stderr = await proc.stderr.read() if proc.stderr else b''
                print(f"Go build failed: {stderr.decode() if stderr else 'unknown error'}")

        return self.runner_path.exists()


class RustRunner(ClientRunner):
    """Rust client test runner."""

    def __init__(self, server: str):
        super().__init__("rust", server)
        self.runner_path = (
            Path(__file__).parent / "runners" / "rust_runner" / "target" / "release" / "rust_runner"
        )

    async def run_test(self, spec: Dict[str, Any], test: Dict[str, Any]) -> TestResult:
        start_time = time.time()

        try:
            # Create temporary test file
            test_spec = {"tests": [test]}
            test_file = Path("/tmp") / f"test_{test['name']}.yaml"
            test_file.write_text(yaml.dump(test_spec))

            # Run Rust runner
            proc = await asyncio.create_subprocess_exec(
                str(self.runner_path),
                "--spec",
                str(test_file),
                "--server",
                self.server,
                "--json",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=test.get("timeout_ms", 30000) / 1000
            )

            duration_ms = (time.time() - start_time) * 1000

            if proc.returncode == 0:
                result = json.loads(stdout.decode())
                return TestResult(
                    test_name=test["name"],
                    client="rust",
                    status="passed",
                    duration_ms=duration_ms,
                    details=result,
                )
            else:
                return TestResult(
                    test_name=test["name"],
                    client="rust",
                    status="failed",
                    duration_ms=duration_ms,
                    error_message=stderr.decode(),
                )

        except asyncio.TimeoutError:
            return TestResult(
                test_name=test["name"],
                client="rust",
                status="error",
                duration_ms=(time.time() - start_time) * 1000,
                error_message="Test timed out",
            )
        except Exception as e:
            return TestResult(
                test_name=test["name"],
                client="rust",
                status="error",
                duration_ms=(time.time() - start_time) * 1000,
                error_message=str(e),
            )

    async def setup(self) -> bool:
        """Build Rust runner if needed."""
        cargo_dir = Path(__file__).parent / "runners" / "rust_runner"

        # Check if cargo is available (try PATH first, then common install location)
        cargo_cmd = "cargo"
        cargo_check = await asyncio.create_subprocess_exec(
            "which", "cargo",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await cargo_check.wait()

        if cargo_check.returncode != 0:
            # Try common Rust installation location
            home_cargo = Path.home() / ".cargo" / "bin" / "cargo"
            if home_cargo.exists():
                cargo_cmd = str(home_cargo)
            else:
                print(f"Cargo not found - Rust runner unavailable (install Rust to enable)")
                return False

        if not self.runner_path.exists() and (cargo_dir / "Cargo.toml").exists():
            print(f"Building Rust runner (this may take a minute)...")
            proc = await asyncio.create_subprocess_exec(
                cargo_cmd, "build", "--release",
                cwd=str(cargo_dir),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.wait()
            if proc.returncode != 0:
                stderr = await proc.stderr.read() if proc.stderr else b''
                print(f"Rust build failed: {stderr.decode() if stderr else 'unknown error'}")
        return self.runner_path.exists()


class ZigRunner(ClientRunner):
    """Zig client test runner."""

    def __init__(self, server: str):
        super().__init__("zig", server)
        self.runner_path = Path(__file__).parent / "runners" / "zig-out" / "bin" / "zig_runner"

    async def run_test(self, spec: Dict[str, Any], test: Dict[str, Any]) -> TestResult:
        start_time = time.time()

        try:
            # Create temporary test file
            test_spec = {"tests": [test]}
            test_file = Path("/tmp") / f"test_{test['name']}.yaml"
            test_file.write_text(yaml.dump(test_spec))

            # Run Zig runner
            proc = await asyncio.create_subprocess_exec(
                str(self.runner_path),
                "--spec",
                str(test_file),
                "--server",
                self.server,
                "--json",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=test.get("timeout_ms", 30000) / 1000
            )

            duration_ms = (time.time() - start_time) * 1000

            if proc.returncode == 0:
                result = json.loads(stdout.decode())
                return TestResult(
                    test_name=test["name"],
                    client="zig",
                    status="passed",
                    duration_ms=duration_ms,
                    details=result,
                )
            else:
                return TestResult(
                    test_name=test["name"],
                    client="zig",
                    status="failed",
                    duration_ms=duration_ms,
                    error_message=stderr.decode(),
                )

        except asyncio.TimeoutError:
            return TestResult(
                test_name=test["name"],
                client="zig",
                status="error",
                duration_ms=(time.time() - start_time) * 1000,
                error_message="Test timed out",
            )
        except Exception as e:
            return TestResult(
                test_name=test["name"],
                client="zig",
                status="error",
                duration_ms=(time.time() - start_time) * 1000,
                error_message=str(e),
            )

    async def setup(self) -> bool:
        """Build Zig runner if needed."""
        build_zig = Path(__file__).parent / "runners" / "build.zig"

        # Check if zig is available
        zig_check = await asyncio.create_subprocess_exec(
            "which", "zig",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await zig_check.wait()

        if zig_check.returncode != 0:
            print(f"Zig not found - Zig runner unavailable (install Zig to enable)")
            return False

        if not self.runner_path.exists() and build_zig.exists():
            print(f"Building Zig runner...")
            proc = await asyncio.create_subprocess_exec(
                "zig", "build",
                cwd=str(build_zig.parent),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.wait()
            if proc.returncode != 0:
                stderr = await proc.stderr.read() if proc.stderr else b''
                print(f"Zig build failed: {stderr.decode() if stderr else 'unknown error'}")
        return self.runner_path.exists()


class TestHarness:
    """Main test harness coordinator."""

    def __init__(
        self,
        server: str,
        clients: List[str],
        parallel: bool = False,
        verbose: bool = False,
        fail_fast: bool = False,
    ):
        self.server = server
        self.verbose = verbose
        self.fail_fast = fail_fast
        self.parallel = parallel

        # Initialize runners
        self.runners: Dict[str, ClientRunner] = {}
        if "python" in clients:
            self.runners["python"] = PythonRunner(server)
        if "go" in clients:
            self.runners["go"] = GoRunner(server)
        if "rust" in clients:
            self.runners["rust"] = RustRunner(server)
        if "zig" in clients:
            self.runners["zig"] = ZigRunner(server)

    async def setup(self) -> bool:
        """Setup all runners."""
        available_runners = {}
        for name, runner in self.runners.items():
            if self.verbose:
                print(f"Setting up {name} runner...")
            if await runner.setup():
                available_runners[name] = runner
            else:
                if self.verbose:
                    print(f"Skipping {name} runner (not available)")

        if not available_runners:
            print(f"ERROR: No runners available - at least one language toolchain must be installed", file=sys.stderr)
            return False

        # Replace runners dict with only available ones
        self.runners = available_runners
        return True

    async def run_spec(self, spec_path: Path) -> List[TestResult]:
        """Run a test specification file."""
        # Load spec
        with open(spec_path) as f:
            spec = yaml.safe_load(f)

        if self.verbose:
            print(f"\nRunning spec: {spec.get('name', spec_path.name)}")
            print(f"Description: {spec.get('description', 'N/A')}")
            print(f"Tests: {len(spec.get('tests', []))}")

        results = []

        # Run tests
        for test in spec.get("tests", []):
            if test.get("skip", False):
                if self.verbose:
                    print(f"  SKIP: {test['name']}")
                for client in self.runners.keys():
                    results.append(
                        TestResult(
                            test_name=test["name"],
                            client=client,
                            status="skipped",
                            duration_ms=0.0,
                        )
                    )
                continue

            if self.verbose:
                print(f"\n  Test: {test['name']}")
                print(f"    {test.get('description', '')}")

            # Run test on all clients
            if self.parallel:
                # Run clients in parallel
                tasks = [
                    runner.run_test(spec, test) for runner in self.runners.values()
                ]
                test_results = await asyncio.gather(*tasks)
                results.extend(test_results)
            else:
                # Run clients sequentially
                for name, runner in self.runners.items():
                    if self.verbose:
                        print(f"    Running {name}...", end=" ", flush=True)

                    result = await runner.run_test(spec, test)
                    results.append(result)

                    if self.verbose:
                        status_symbol = {
                            "passed": "✓",
                            "failed": "✗",
                            "error": "⚠",
                            "skipped": "-",
                        }.get(result.status, "?")
                        print(
                            f"{status_symbol} {result.status.upper()} ({result.duration_ms:.1f}ms)"
                        )
                        if result.error_message and self.verbose:
                            print(f"      Error: {result.error_message}")

                    if self.fail_fast and result.status in ("failed", "error"):
                        print(
                            f"\nFail-fast mode: Stopping after first failure in {name}",
                            file=sys.stderr,
                        )
                        return results

        return results

    def generate_summary(self, results: List[TestResult]) -> Dict[str, TestSummary]:
        """Generate summary statistics."""
        summaries = {}

        for client in self.runners.keys():
            summary = TestSummary(client=client)
            client_results = [r for r in results if r.client == client]

            summary.total = len(client_results)
            summary.passed = len([r for r in client_results if r.status == "passed"])
            summary.failed = len([r for r in client_results if r.status == "failed"])
            summary.skipped = len([r for r in client_results if r.status == "skipped"])
            summary.errors = len([r for r in client_results if r.status == "error"])
            summary.duration_ms = sum(r.duration_ms for r in client_results)

            summaries[client] = summary

        return summaries

    def print_summary(self, summaries: Dict[str, TestSummary]):
        """Print test summary."""
        print("\n" + "=" * 80)
        print("TEST SUMMARY")
        print("=" * 80)

        for client, summary in summaries.items():
            pass_rate = (
                (summary.passed / summary.total * 100) if summary.total > 0 else 0
            )
            print(f"\n{client.upper()}:")
            print(
                f"  Total: {summary.total} | Passed: {summary.passed} | Failed: {summary.failed}"
            )
            print(f"  Skipped: {summary.skipped} | Errors: {summary.errors}")
            print(f"  Pass Rate: {pass_rate:.1f}%")
            print(f"  Duration: {summary.duration_ms:.1f}ms")

        # Overall
        total = sum(s.total for s in summaries.values())
        passed = sum(s.passed for s in summaries.values())
        failed = sum(s.failed for s in summaries.values())
        errors = sum(s.errors for s in summaries.values())

        print(f"\nOVERALL:")
        print(f"  Total Tests: {total}")
        print(f"  Passed: {passed}")
        print(f"  Failed: {failed}")
        print(f"  Errors: {errors}")
        print(f"  Pass Rate: {(passed/total*100) if total > 0 else 0:.1f}%")
        print("=" * 80)

    def _prepare_report_data(self, results: List[TestResult], summaries: Dict[str, TestSummary]) -> Dict[str, Any]:
        """Prepare report data structure for JSON/HTML output."""
        return {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "server": self.server,
            "total_tests": len(results),
            "summary": {
                client: {
                    "total": summary.total,
                    "passed": summary.passed,
                    "failed": summary.failed,
                    "skipped": summary.skipped,
                    "errors": summary.errors,
                    "duration_ms": summary.duration_ms,
                }
                for client, summary in summaries.items()
            },
            "results": [
                {
                    "test": r.test_name,
                    "client": r.client,
                    "status": r.status,
                    "duration_ms": r.duration_ms,
                    "error": r.error_message,
                    "details": r.details,
                }
                for r in results
            ],
        }

    def save_json_report(self, results: List[TestResult], summaries: Dict[str, TestSummary], output_path: Path):
        """Save JSON report."""
        report = self._prepare_report_data(results, summaries)

        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, "w") as f:
            json.dump(report, f, indent=2)

        if self.verbose:
            print(f"\nJSON report saved to: {output_path}")


async def main():
    parser = argparse.ArgumentParser(
        description="Run client library tests for Geode"
    )
    parser.add_argument(
        "--server",
        default="localhost:8443",
        help="Geode server address (default: localhost:8443)",
    )
    parser.add_argument(
        "--spec", type=Path, help="Test specification file (runs all if not specified)"
    )
    parser.add_argument(
        "--clients",
        default="python,go,rust,zig",
        help="Comma-separated list of clients to test (default: all)",
    )
    parser.add_argument(
        "--parallel",
        action="store_true",
        help="Run clients in parallel (default: sequential)",
    )
    parser.add_argument(
        "--fail-fast", action="store_true", help="Stop on first failure"
    )
    parser.add_argument("--verbose", action="store_true", help="Verbose output")
    parser.add_argument(
        "--report-json", type=Path, help="Save JSON report to file"
    )
    parser.add_argument(
        "--report-html", type=Path, help="Generate HTML report to file"
    )

    args = parser.parse_args()

    # Parse clients
    clients = [c.strip() for c in args.clients.split(",")]

    # Initialize harness
    harness = TestHarness(
        server=args.server,
        clients=clients,
        parallel=args.parallel,
        verbose=args.verbose,
        fail_fast=args.fail_fast,
    )

    # Setup
    if not await harness.setup():
        sys.exit(3)

    # Find specs
    if args.spec:
        specs = [args.spec]
    else:
        spec_dir = Path(__file__).parent / "specs"
        specs = sorted(spec_dir.glob("*.yaml"))

    if not specs:
        print("ERROR: No test specifications found", file=sys.stderr)
        sys.exit(2)

    # Run tests
    all_results = []
    for spec in specs:
        results = await harness.run_spec(spec)
        all_results.extend(results)

    # Generate summary
    summaries = harness.generate_summary(all_results)
    harness.print_summary(summaries)

    # Save reports
    if args.report_json:
        harness.save_json_report(all_results, summaries, args.report_json)

    if args.report_html:
        # Import HTML report generator
        from generate_html_report import generate_html_report

        # Prepare report data
        report_data = harness._prepare_report_data(all_results, summaries)

        # Generate HTML
        generate_html_report(report_data, args.report_html)

    # Exit code
    failed = sum(s.failed + s.errors for s in summaries.values())
    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    asyncio.run(main())
