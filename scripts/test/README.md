# Test Scripts

This directory contains test runners and utility scripts for the Geode test suite.

## Test Runners

### Core Module

- `test_runner_core.py` - Shared logic: surrogate-pair fixing, variable substitution,
  test isolation (label/index/schema/graph name suffixing), expectation validation
  (exit_code, stdout_contains, stderr_contains, regex, JSON assertions), server
  lifecycle management, secret resolution, timeout resolution, and shared constants

### Main Test Runners

- `extended_test_runner.py` - Comprehensive sequential test runner (uses `test_runner_core`)
- `parallel_test_runner.py` - Parallel test execution with configurable workers (uses `test_runner_core`)

### Analysis Scripts

- `analyze_failures.py` - Analyze test failures
- `analyze_missing_features.py` - Identify missing feature implementations
- `failure_tracker.py` - Track test failures over time
- `find_failing_tests.py` - Identify failing tests
- `quick_failure_analysis.py` - Quick failure analysis
- `quick_test_overview.py` - Quick test status overview
- `count_tests_quick.py` - Count tests quickly

### Debug Scripts

- `debug_subprocess.py` - Debug subprocess issues
- `debug_test.py` - General test debugging

### Feature-Specific Test Scripts

- `run_encryption_tests.py` - Test encryption features
- `run_geode_tests.py` - Run Geode-specific tests
- `test_auth.py` - Authentication tests
- `test_auth_quick.py` - Quick auth tests
- `test_batch_update_runner.py` - Batch update tests
- `test_cli_fixes.py` - CLI fix verification
- `test_geode_server.py` - Server tests
- `test_geodetestlab_check.py` - Geodetestlab validation
- `test_intersect_fix.py` - INTERSECT operation tests
- `test_json_extraction_unit.py` - JSON extraction unit tests
- `test_json_matching.py` - JSON matching tests
- `test_multiple_operations.py` - Multiple operation tests
- `test_single_create_schema.py` - Single schema creation tests
- `test_specific_features.py` - Specific feature tests
- `test_specific_suite.py` - Specific suite tests
- `test_system_features.py` - System feature tests
- `test_union_property_access_direct.py` - Union property access tests
- `simple_test.py` - Simple test execution

### Shell Scripts

- `debug_string_parsing.sh` - Debug string parsing issues
- `demo_repl.sh` - REPL demonstration
- `quick_validation_test.sh` - Quick validation
- `run_all_regression_tests.sh` - Run all regression tests
- `run_comprehensive_quic_tests.sh` - Comprehensive QUIC tests
- `run_gpu_benchmarks.sh` - GPU benchmark execution
- `test_*.sh` - Various feature-specific test scripts
- `validate_*.sh` - Validation scripts
- `verify_*.sh` - Verification scripts

## Usage

### From Repository Root

```bash
# Run comprehensive tests
python3 scripts/test/extended_test_runner.py

# Run parallel tests
python3 scripts/test/parallel_test_runner.py --max-workers 4

# Quick test overview
python3 scripts/test/quick_test_overview.py

# Analyze failures
python3 scripts/test/analyze_failures.py
```

### Using Make Targets

```bash
# Run comprehensive geodetestlab tests
make geodetestlab-comprehensive

# Run parallel tests with custom settings
make geodetestlab-parallel WORKERS=8 TIMEOUT=300
```

## Test Data Directories

Test data and fixtures are located in:

- `tests/data_test_geode_auth/` - Authentication test data
- `tests/quic_tests/` - QUIC protocol tests
- `tests/debug/` - Debug Zig test files

## Adding New Tests

1. Create test file in appropriate location:
   - Python test runners: `scripts/test/`
   - Shell test scripts: `scripts/test/`
   - Zig debug files: `tests/debug/`

2. Update Makefile if adding a new test target

3. Document in this README
