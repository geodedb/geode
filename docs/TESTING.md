# Testing Documentation for Geode

## Overview

Geode maintains comprehensive test coverage across multiple testing frameworks and methodologies.

> **Note**: Test coverage numbers change with each test run. For current results, run `make geodetestlab-comprehensive` or check `docs/status.csv`. Numbers in documentation are point-in-time snapshots.

## Test Coverage Summary

### geodetestlab Integration Tests

- **Status**: See [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md) for the current canonical test baseline. A fresh `../geode-test-harness` integration run is owed; the last dated snapshot (~97%, 1644/1688) is historical.
- **Historical per-category pass rates** (from that dated snapshot — pass rate of the specs in each category at that time, not code coverage, and not a current claim): authentication/authorization, user management, role/policy management, query execution, and server operations passed all specs in their categories; CLI commands passed ~99%. Re-run the harness for current numbers.

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

# Run one named Zig regression step (every regression test has one)
zig build test-<name>

# Compile every artifact the aggregate `zig build test` runs, in all shards,
# without running them: run this before claiming the aggregate is green
zig build test-compile

# Run integration tests with large datasets
make integration-test

# Run geodetestlab tests (from repo root)
python3 scripts/test/extended_test_runner.py

# Run specific geodetestlab spec file
python3 scripts/test/extended_test_runner.py --specs geodetestlab/specs/geode_gql_compliance.yml

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
- **Test Runner**: `scripts/test/extended_test_runner.py`
- **CANARY**: GAP-0157 - Updated to correct test runner path

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

- `${server}` or `${server_address}`: Replaced with `127.0.0.1:3141`
- `${server:host}`: Replaced with `127.0.0.1`
- `${server:port}`: Replaced with `3141`
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

### Server-Backed Mode (QUIC/gRPC)

All CLI and integration tests run against an external server process. The unified `geode` binary starts the server with QUIC/TLS (and optional gRPC):

```bash
./zig-out/bin/geode serve --listen 127.0.0.1:3141
./zig-out/bin/geode query "RETURN 1 AS x" --server 127.0.0.1:3141 --insecure
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
  "columns": [{"name": "x", "type": "ANY"}],
  "rows": [{"x": 1}],
  "ordered": false,
  "order_keys": []
}
```

## CI/CD Integration

### GitLab CI

```yaml
# See .gitlab-ci.yml for full pipeline configuration
# Note: GAP-0158 - Updated from GitHub Actions to GitLab CI

# Example jobs from .gitlab-ci.yml:
test-zig-unit:
  stage: test
  image: registry.gitlab.com/devnw/ci-catalog/zig:${ZIG_VERSION}
  script:
    - zig build test --summary all

governance-status-check:
  stage: governance
  script:
    - python3 tools/status_generate.py --repo . --out /tmp/status_check.csv
    - diff docs/status.csv /tmp/status_check.csv
```

`test-zig-unit` (8 Debug shards) is the blocking unit gate on MR, branch and
default-branch pipelines; a branch push pipeline skips it while an MR is open
because the MR pipeline for the same commit runs it.

### Code coverage (kcov lane)

Coverage is a dedicated lane (`test-code-coverage` + `test-code-coverage-report`)
that runs only in a pipeline started by a schedule, the web UI or the API with
`GEODE_COVERAGE_LANE=1`. It does not run on MR, branch or tag pipelines.

```bash
# What one lane shard does (needs kcov on PATH and ptrace allowed):
mkdir -p coverage/raw
zig build test -Dtest-coverage=true -Dtest-shard-total=8 -Dtest-shard-index=0
python3 scripts/ci/kcov_coverage.py shard --shard 0 --build-rc $?
# After all shards: merge and publish only when every manifest entry has data
python3 scripts/ci/kcov_coverage.py report --total 8
```

`-Dtest-coverage=true` runs every test the shard owns under kcov, with the exact
arguments the unit shard uses. The test binaries are built with the LLVM backend
because kcov reads no line data from the self-hosted backend's DWARF. The build
also installs `zig-out/coverage/manifest-shard-<i>.tsv`, which lists every run in
the shard. The report job merges coverage only when every manifest entry produced
data. Otherwise it prints `COVERAGE INCOMPLETE` or `COVERAGE UNAVAILABLE` and fails
as an allowed failure. It never publishes a zero or stub report.

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

A Zig regression test is a named build step. Write it as
`tests/test_<ticket>_<topic>.zig` and register it in `build.zig` as
`zig build test-<name>`, passing its RUN step to `shardDep` as the neighbouring
tests do (`const run_x = b.addRunArtifact(x_tests);
shardDep(test_step, &run_x.step, 1, test_shard_loads, test_shard_index);`), so
it also runs in the sharded aggregate `zig build test` (the pre-push hook and
the CI shard jobs). `shardDep` rejects a compile step at configure time, since
a compile step is built but never run. The one exception is an intentionally
red TDD reproduction listed in [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md): it
may stay out of `shardDep`, so the aggregate stays green, until the commit that
fixes it registers it there, and until then its test artifact is added to
`test-compile` directly
(`if (g_test_compile_step) |c| c.dependOn(&x_tests.step);`). Before claiming
the aggregate is green, run `zig build test-compile`: it compiles every
aggregate artifact in all shards, including those with no named step, which a
sweep of named steps cannot see.

A named `test-*` step that stays out of the aggregate (that red reproduction,
a TSan companion, a subprocess cluster, GPU, an e2e or benchmark lane) must be
listed, with its reason, in `not_in_aggregate_steps` in `build.zig`. Every
build, `zig build -l` included, fails at configure time when a named step runs
in no aggregate shard and is not listed, or when a listed name matches no step
or a step that is in the aggregate (SONNY-2772). That list is the one place
that records which named steps the aggregate does not run.

Shell-based regression scripts go in the `tests/` directory:

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
# Enable JSON logging (unified CLI - geode serve symlink also works for backward compat)
./zig-out/bin/geode serve --log_json

# Capture server stderr
GEODE_CAPTURE_SERVER_STDERR=1 ./run_tests.sh
```

#### 3. Isolated Test Execution

```bash
# Run single Zig test
zig test src/specific_file.zig --test-filter "test name"

# Run single geodetestlab spec
python3 scripts/test/extended_test_runner.py geodetestlab/specs/specific_test.yml

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
- Spawn the `geode serve` binary as a subprocess for CLI tests (the library does not host an in-process server — see GAP-0857)

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
- Report issues at <https://gitlab.com/devnw/codepros/geode/issues>
