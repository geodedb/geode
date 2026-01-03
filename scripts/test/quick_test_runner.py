#!/usr/bin/env python3
"""Quick test runner for a subset of specs to demonstrate the parallel system."""

import json
import sys
import yaml
import subprocess
import os
from pathlib import Path
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
import tempfile
import shutil

class QuickTestRunner:
    def __init__(self, specs_dir="geodetestlab/specs", binary="/home/benji/src/geode/geode/zig-out/bin/geode", log_dir="test_logs"):
        self.specs_dir = Path(specs_dir)
        self.binary = Path(binary)
        self.log_dir = Path(log_dir)
        self.current_run_dir = None
        
    def setup_run_directory(self):
        """Create timestamped directory for this test run."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.current_run_dir = self.log_dir / f"run_{timestamp}"
        self.current_run_dir.mkdir(parents=True, exist_ok=True)
        return self.current_run_dir
        
    def load_spec(self, spec_file):
        """Load and parse a test specification file."""
        try:
            with open(spec_file, 'r') as f:
                return yaml.safe_load(f)
        except Exception as e:
            return None
            
    def run_single_test(self, spec_file, test, timeout=10):
        """Run a single test case."""
        test_name = test.get("name", "unknown")
        args = test.get("args", [])
        expect = test.get("expect", {})
        
        start_time = datetime.now()
        
        try:
            # Set up environment with zig-out/bin in PATH
            env = os.environ.copy()
            bin_dir = str(self.binary.parent)
            env['PATH'] = bin_dir + os.pathsep + env.get('PATH', '')
            
            result = subprocess.run(
                [str(self.binary)] + args,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=self.binary.parent.parent.parent,  # Run from geode root
                env=env
            )
            
            execution_time = (datetime.now() - start_time).total_seconds() * 1000
            
            # Simple pass/fail logic
            expected_exit = expect.get("exit_code", 0)
            passed = result.returncode == expected_exit
            
            # Filter out JSON log lines for cleaner output checking
            stdout_lines = [line for line in result.stdout.split('\n') if not line.startswith('{')]
            stderr_lines = [line for line in result.stderr.split('\n') if not line.startswith('{')]
            filtered_stdout = '\n'.join(stdout_lines)
            filtered_stderr = '\n'.join(stderr_lines)
            
            # Check basic output requirements
            if passed and "stdout_contains" in expect:
                combined_output = filtered_stdout + filtered_stderr + result.stdout + result.stderr
                for pattern in expect["stdout_contains"]:
                    if pattern.lower() not in combined_output.lower():
                        passed = False
                        break
                        
            return {
                "spec_file": spec_file.name,
                "test_name": test_name,
                "passed": passed,
                "exit_code": result.returncode,
                "expected_exit_code": expected_exit,
                "execution_time_ms": execution_time,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "message": "PASSED" if passed else f"Failed (exit {result.returncode}, expected {expected_exit})"
            }
            
        except subprocess.TimeoutExpired:
            return {
                "spec_file": spec_file.name,
                "test_name": test_name,
                "passed": False,
                "exit_code": "timeout",
                "expected_exit_code": expect.get("exit_code", 0),
                "execution_time_ms": timeout * 1000,
                "stdout": "",
                "stderr": "",
                "message": f"Timeout after {timeout}s"
            }
        except Exception as e:
            return {
                "spec_file": spec_file.name,
                "test_name": test_name,
                "passed": False,
                "exit_code": "error",
                "expected_exit_code": expect.get("exit_code", 0),
                "execution_time_ms": 0,
                "stdout": "",
                "stderr": "",
                "message": f"Error: {str(e)}"
            }
    
    def run_spec_file(self, spec_file, timeout=10):
        """Run all tests in a single spec file."""
        spec = self.load_spec(spec_file)
        if not spec:
            return []
            
        results = []
        for test in spec.get("tests", []):
            result = self.run_single_test(spec_file, test, timeout)
            results.append(result)
            
        return results
    
    def run_tests(self, spec_files, max_workers=2, timeout=10):
        """Run tests across multiple spec files in parallel."""
        run_dir = self.setup_run_directory()
        
        all_results = []
        start_time = datetime.now()
        
        print(f"Starting test run in: {run_dir}")
        print(f"Running {len(spec_files)} spec files with {max_workers} workers...")
        
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            # Submit spec files for parallel execution
            future_to_spec = {
                executor.submit(self.run_spec_file, spec_file, timeout): spec_file 
                for spec_file in spec_files
            }
            
            for future in as_completed(future_to_spec):
                spec_file = future_to_spec[future]
                try:
                    results = future.result()
                    all_results.extend(results)
                    
                    passed = sum(1 for r in results if r["passed"])
                    failed = len(results) - passed
                    print(f"✓ {spec_file.name}: {passed} passed, {failed} failed")
                    
                except Exception as e:
                    print(f"✗ {spec_file.name}: Error - {e}")
        
        end_time = datetime.now()
        total_time = (end_time - start_time).total_seconds()
        
        # Analyze results
        passed_tests = [r for r in all_results if r["passed"]]
        failed_tests = [r for r in all_results if not r["passed"]]
        
        # Create summary
        summary = {
            "timestamp": start_time.isoformat(),
            "total_time_seconds": total_time,
            "execution_summary": {
                "total_tests": len(all_results),
                "passed": len(passed_tests),
                "failed": len(failed_tests),
                "pass_rate": (len(passed_tests) / len(all_results) * 100) if all_results else 0
            },
            "spec_files": [str(f) for f in spec_files],
            "configuration": {
                "max_workers": max_workers,
                "timeout": timeout,
                "binary": str(self.binary)
            }
        }
        
        # Save detailed results
        with open(run_dir / "detailed_results.json", "w") as f:
            json.dump(all_results, f, indent=2)
            
        # Save summary
        with open(run_dir / "summary.json", "w") as f:
            json.dump(summary, f, indent=2)
            
        # Save failures
        failures_data = {
            "failures": failed_tests,
            "failure_patterns": self.analyze_failure_patterns(failed_tests)
        }
        with open(run_dir / "failures.json", "w") as f:
            json.dump(failures_data, f, indent=2)
            
        # Print summary
        print(f"\n{'='*60}")
        print(f"TEST RUN COMPLETE")
        print(f"{'='*60}")
        print(f"Total time: {total_time:.1f}s")
        print(f"Total tests: {len(all_results)}")
        print(f"Passed: {len(passed_tests)}")
        print(f"Failed: {len(failed_tests)}")
        print(f"Pass rate: {summary['execution_summary']['pass_rate']:.1f}%")
        print(f"Logs saved to: {run_dir}")
        
        if failed_tests:
            print(f"\nTop failure patterns:")
            for pattern, count in sorted(failures_data["failure_patterns"].items(), 
                                       key=lambda x: len(x[1]), reverse=True)[:5]:
                print(f"  {pattern}: {len(count)} tests")
        
        return summary
    
    def analyze_failure_patterns(self, failed_tests):
        """Group failures by common patterns."""
        patterns = {}
        
        for test in failed_tests:
            message = test.get("message", "Unknown")
            
            # Categorize by common patterns
            if "timeout" in message.lower():
                pattern = "Timeout errors"
            elif "exit" in message.lower() and "expected" in message.lower():
                pattern = "Exit code mismatches"
            elif "syntax" in message.lower() or "parse" in message.lower():
                pattern = "Parse/syntax errors"
            elif "connection" in message.lower() or "server" in message.lower():
                pattern = "Connection/server errors"
            elif "missing" in message.lower():
                pattern = "Missing output/features"
            else:
                pattern = "Other errors"
                
            if pattern not in patterns:
                patterns[pattern] = []
            patterns[pattern].append(test)
            
        return patterns

def main():
    runner = QuickTestRunner()
    
    # Select a representative subset of specs
    key_specs = [
        "geode_basic.yml",
        "geode_auth.yml", 
        "geode_integration.yml",
        "geode_advanced.yml"
    ]
    
    spec_files = []
    for spec_name in key_specs:
        spec_path = runner.specs_dir / spec_name
        if spec_path.exists():
            spec_files.append(spec_path)
        else:
            print(f"Warning: {spec_name} not found")
    
    if not spec_files:
        print("No spec files found to run")
        return 1
        
    # Run the tests
    summary = runner.run_tests(spec_files, max_workers=2, timeout=8)
    
    return 0 if summary["execution_summary"]["failed"] == 0 else 1

if __name__ == "__main__":
    sys.exit(main())