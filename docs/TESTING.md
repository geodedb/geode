# Testing Documentation for Geode

## Overview

Geode maintains comprehensive test coverage across multiple testing frameworks and methodologies. As of v0.19.0-dev, the project achieves **99.4% test coverage** (179/180 tests passing) in the geodetestlab integration test suite.

## Test Coverage Summary

### geodetestlab Integration Tests
- **Total Tests**: 180
- **Passing**: 179 (99.4%)
- **Coverage by Category**:
  - Authentication & Authorization: 100%
  - User Management: 100%
  - Role & Policy Management: 100%
  - Query Execution: 100%
  - Server Operations: 100%
  - CLI Commands: 99%

### Regression Test Suites
- `comprehensive_regression_test.sh`: 34 scenarios
- `limit_skip_regression_test.sh`: 23 scenarios
- `property_ordering_regression_test.sh`: 10 scenarios
- `count_aggregation_regression_test.sh`: 8 scenarios

## Running Tests

### Quick Test Commands
```bash
# Run all Zig unit tests
make test

# Run integration tests with large datasets
make integration-test

# Run geodetestlab tests
cd geodetestlab && python test_runner.py

# Run extended test runner for detailed analysis
python extended_test_runner.py

# Run specific regression test suites
./tests/comprehensive_regression_test.sh
./tests/limit_skip_regression_test.sh
```

### Dataset Integration Testing
```bash
# Load example datasets
make load-dataset

# Run dataset integration tests
make dataset-integration-test
```

Available test datasets:
- **Social Network**: 10,000+ users, posts, groups, events
- **IoT Network**: 25,000+ devices, sensors, telemetry data
- **Financial Network**: 50,000 accounts, 250,000 transactions
- **Geographic Data**: 100 cities, 25,000 POIs

## Testing Frameworks

### 1. Zig Unit Tests (`zig test`)
Located throughout the codebase with test blocks in source files:
```zig
test "example test" {
    try std.testing.expect(1 == 1);
}
```

### 2. geodetestlab Framework
Python-based integration testing framework using YAML specifications:
- **Location**: `geodetestlab/specs/*.yml`
- **Test Runner**: `geodetestlab/test_runner.py`
- **Extended Runner**: `extended_test_runner.py`

#### Test Specification Format
```yaml
name: "test-suite-name"
tests:
  - name: "test-case-name"
    args: ["command", "subcommand", "--flag", "value"]
    expect:
      exit_code: 0
      stdout_contains: ["expected output"]
      stderr_contains: ["expected error"]
      stdout_regex: ["pattern.*to.*match"]
      stdout_json_assert: [...]
```

#### Variable Substitution
Tests support variable substitution for dynamic values:
- `${server}` or `${server_address}`: Replaced with `127.0.0.1:8443`
- `${server:host}`: Replaced with `127.0.0.1`
- `${server:port}`: Replaced with `8443`
- `${secret:api_token}`: Replaced with test token
- `${secret:user_password}`: Replaced with test password

### 3. Shell-based Regression Tests
Comprehensive bash scripts testing specific features:
- Located in `tests/` directory
- Self-contained with setup and teardown
- Return exit codes for CI integration

### 4. Fuzz Testing
```bash
# Run fuzz tests
make fuzz
```
- Located in `fuzz/` directory
- Uses deterministic seeds for reproducibility
- Tests parser, planner, and storage components

### 5. Benchmark Tests
```bash
# Run benchmarks
make bench
```
- Performance regression testing
- Located in `benchmark/` directory
- Tracks execution time and memory usage

## Test Infrastructure Features

### Embedded Server Mode
The CLI includes an embedded server for testing without external dependencies:
```bash
# Query with embedded server (--process flag)
./zig-out/bin/geode query "RETURN 1 AS x" --process

# Runs query in embedded mode without needing external server
```

### Authentication Testing
Tests cover various authentication scenarios:
- Valid/invalid credentials
- Token-based authentication
- MFA verification
- Permission checks
- Role-based access control

### Exit Code Standards
Consistent exit codes across all commands:
- `0`: Success
- `1`: General error
- `2`: Usage error (invalid arguments)
- `3`: Authentication/permission error

### JSON Output Validation
Tests validate structured JSON output for machine-readable results:
```json
{
  "status_class": "00000",
  "status": "00000",
  "result": {
    "columns": [{"name": "x", "type": "INTEGER"}],
    "rows": [{"x": 1}]
  }
}
```

## CI/CD Integration

### GitHub Actions
```yaml
- name: Run Tests
  run: |
    make test
    make integration-test
    python extended_test_runner.py
```

### Docker Testing
```bash
# Run tests in Docker
make docker-test

# Full CI pipeline in Docker
make docker-ci
```

### Nix Testing
```bash
# Validate all Nix configurations
nix flake check

# Run tests in Nix environment
nix develop -c make test
```

## Test Development Guidelines

### Adding New Tests

#### 1. Unit Tests
Add test blocks to relevant source files:
```zig
test "feature description" {
    // Setup
    const allocator = std.testing.allocator;
    
    // Execute
    const result = try myFunction();
    
    // Verify
    try std.testing.expectEqual(expected, result);
}
```

#### 2. Integration Tests
Create YAML specifications in `geodetestlab/specs/`:
```yaml
name: "new-feature"
tests:
  - name: "basic-functionality"
    args: ["new-command", "--option"]
    expect:
      exit_code: 0
      stdout_contains: ["Success"]
```

#### 3. Regression Tests
Add shell scripts to `tests/` directory:
```bash
#!/bin/bash
set -e

# Test setup
./setup_test_env.sh

# Run test
result=$(./geode command)

# Verify
if [[ "$result" != "expected" ]]; then
    echo "FAIL: Unexpected result"
    exit 1
fi

echo "PASS"
```

### Test Naming Conventions
- Unit tests: `test "component_name: specific behavior"`
- Integration tests: `feature-category_specific-test`
- Regression tests: `feature_regression_test.sh`
- Canary tests: `TestCANARY_REQ_GQL_XXX_description`

### CANARY System Integration
Tests linked to requirements use CANARY markers:
```zig
// CANARY: REQ=REQ-GQL-001; FEATURE="BasicQuery"; ASPECT=Testing; STATUS=TESTED; TEST=TestBasicQuery; OWNER=test; UPDATED=2025-10-02
test "TestCANARY_REQ_GQL_001_BasicQuery" {
    // Test implementation
}
```

## Test Maintenance

### Regular Verification
```bash
# Quick verification during development
make verify-fast

# Full verification before commits
make verify-all

# Update governance tracking
make status-generate
```

### Debugging Failed Tests

#### 1. Enable Verbose Output
```bash
# Verbose test runner
python extended_test_runner.py --verbose

# Debug CLI commands
GEODE_DEBUG=1 ./geode command
```

#### 2. Check Server Logs
```bash
# Enable JSON logging
./geoded --log_json

# Capture server stderr
GEODE_CAPTURE_SERVER_STDERR=1 ./run_tests.sh
```

#### 3. Isolated Test Execution
```bash
# Run single Zig test
zig test src/specific_file.zig --test-filter "test name"

# Run single geodetestlab spec
python test_runner.py specs/specific_test.yml

# Run single regression test
./tests/specific_regression_test.sh
```

## Test Performance

### Resource Limits
- Maximum RAM per test: 512 MiB
- Test timeout: 30 seconds (E2E), 5 seconds (unit)
- Deterministic behavior required (fixed seeds)

### Optimization Tips
- Use `make verify-fast` during development
- Run fuzz and bench tests separately
- Parallelize independent test suites
- Use embedded server mode for CLI tests

## Known Test Limitations

### Current Issues
1. **Double Quote String Literals**: Parser hangs with double quotes in GQL queries
   - Workaround: Use single quotes `'string'` instead of `"string"`

### Platform-Specific Notes
- **Windows**: Requires Wine for cross-platform testing
- **ARM64**: Requires QEMU for cross-compilation testing
- **macOS**: Some Linux-specific tests may be skipped

## Contributing to Tests

### Before Submitting PRs
1. Ensure all tests pass: `make test`
2. Add tests for new features
3. Update regression tests for bug fixes
4. Verify governance tracking: `make status-generate`
5. Run full verification: `make verify-all`

### Test Review Checklist
- [ ] Tests are deterministic
- [ ] Tests clean up after themselves
- [ ] Tests have descriptive names
- [ ] Tests cover edge cases
- [ ] Tests include CANARY markers if applicable
- [ ] Tests follow naming conventions
- [ ] Tests pass in CI environment

## Support

For test-related issues:
- Check [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- Review test output carefully for specific errors
- Use `--verbose` or debug flags for detailed output
- Report issues at https://github.com/spyderorg/geode/issues