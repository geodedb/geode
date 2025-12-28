# Plan: Remove `--embedded` and `--no-quic` Features

## Overview

This document outlines the plan to remove all `--embedded` and `--no-quic` features from the Geode codebase. The system will require a proper server implementation for all operations instead of supporting an embedded mode.

## Rationale

- Embedded mode adds complexity to the codebase
- Tests should use the actual server to ensure realistic testing
- Maintaining two execution paths (embedded vs server) increases maintenance burden
- Server mode is the production path and should be the only path

## Scope of Changes

### 1. Zig CLI Code (`src/cli/main.zig`)

**Files:** `src/cli/main.zig`

**Changes Required:**
- Remove `--embedded` argument parsing (~line 227-228, 250-251, 282-283, 2482-2493)
- Remove `--no-quic` argument parsing (~line 2491-2493)
- Remove `--embedded-data-dir` argument parsing (~line 2484-2490)
- Remove `embedded` field from `ClientConfig` struct (~line 282-283)
- Remove `executeEmbeddedQuery` function (~line 2680+)
- Remove embedded mode handling in query execution (~line 2653-2673)
- Remove embedded mode handling in shell command (~line 3145-3147)
- Update help text to remove embedded examples

**Behavior Change:**
- `geode query` will require `--server` flag or default to `localhost:3141`
- Remove fallback to embedded mode

### 2. Test Runner Scripts (`scripts/test/`)

**Files:**
- `scripts/test/extended_test_runner.py` - Primary test runner
- `scripts/test/parallel_test_runner.py` - Parallel test runner

**Changes Required in `extended_test_runner.py`:**
- Remove all `--embedded` injection logic (lines 230-243, 246-254, 316-343, 399-421)
- Remove `--no-quic` injection logic (lines 245-254, 325, 346-349, 406-409)
- Make server mode the default/only mode
- Tests must start a server before running or connect to existing one
- Add server lifecycle management (start before tests, stop after)

**Changes Required in `parallel_test_runner.py`:**
- Remove embedded scenario from `default_scenario_configs()` (lines 225-230)
- Remove `Scenario.client_mode == "embedded"` handling throughout
- Remove `--embedded` and `--no-quic` stripping from `process_args()` (lines 391-393)
- Update `build_scenarios()` to only support server mode
- Keep server management logic (already good)

### 3. Geodetestlab Test Specifications (`geodetestlab/specs/`)

**Files with `--embedded` references:**
- `geodetestlab/specs/geode_session_storage.yml`
- `geodetestlab/specs/gql_session_management_comprehensive.yml`
- `geodetestlab/specs/geode_keyword_fixes.yml`

**Changes Required:**
- Remove all explicit `--embedded` arguments from test args
- Update test configs to use server mode
- Add server configuration to specs that need it
- Remove `enabled: false` from server configs

### 4. Geodetestlab Framework (`geodetestlab/geodetestlab/`)

**Files:**
- `geodetestlab/geodetestlab/server/simple_manager.py`

**Changes Required:**
- Remove `_use_embedded` flag and all associated logic
- Simplify to always manage a real server
- Remove embedded fallback paths

### 5. Fixture Scripts (`geodetestlab/fixtures/`)

**Files:**
- `geodetestlab/fixtures/setup_basic_social_network.sh`
- `geodetestlab/fixtures/setup_social_network.sh`

**Changes Required:**
- Remove `--embedded` flags from all `geode query` invocations
- Update to connect to server (will need server address passed in or use default)

### 6. Documentation Updates

**Files:**
- `CLAUDE.md` - Remove `--no-quic` reference in test compatibility
- `geodetestlab/README.md` - Update scenario documentation
- `.claude/agents/integration-test-generator.md` - Remove `--no-quic` references

### 7. Shell Scripts (`scripts/`)

**Files with `--no-quic` references:**
- `scripts/focused_db_test.sh`
- `scripts/database_integration_test.sh`
- `scripts/comprehensive_graph_test.sh`
- `scripts/current_graph_capabilities_test.sh`
- `scripts/graph_data_integration_test.sh`
- `scripts/integration_test.sh`
- `tools/update_tests_unified_cli.sh`

**Changes Required:**
- Update all scripts to use `--server localhost:3141` instead of `--no-quic`
- OR update to start a local server before tests and connect to it
- Consider deprecating legacy test scripts that duplicate geodetestlab functionality

### 8. Docker Files

**Files:**
- `Dockerfile.ci`
- `Dockerfile.ci.alpine`

**Changes Required:**
- Update health check commands to use proper server connection
- Remove `--no-quic` from health check commands

### 9. CI/CD

**Files:**
- `.github/workflows/release.yml`

**Changes Required:**
- Update any `--no-quic` usages in workflow files

### 10. Other Zig Files

**Files:**
- `tests/test_unified_cli.zig`
- `tests/test_cli_integration.zig`
- `tests/test_cli_subprocess_elimination_unit_simple.zig`
- `tests/test_cli_subprocess_elimination_unit.zig`
- `tests/test_cli_subprocess_elimination.zig`
- `src/client/main.zig`

**Changes Required:**
- Search for and remove any embedded/no_quic handling
- Update tests to use server mode

## Implementation Order

### Phase 1: Core CLI Changes (MUST DO FIRST)
1. Update `src/cli/main.zig`:
   - Remove `--embedded`, `--no-quic`, `--embedded-data-dir` argument parsing
   - Remove `executeEmbeddedQuery` function and related code
   - Update default behavior to require server connection
   - Keep graceful error message when server not available

### Phase 2: Test Infrastructure
1. Update `scripts/test/parallel_test_runner.py`:
   - Remove embedded scenario
   - Update to server-only mode
2. Update `scripts/test/extended_test_runner.py`:
   - Remove embedded injection logic
   - Add server management or require external server

### Phase 3: Geodetestlab Specs
1. Update all `.yml` files in `geodetestlab/specs/`:
   - Remove `--embedded` from all test args
   - Ensure proper server configuration

### Phase 4: Fixture Scripts and Legacy Scripts
1. Update fixture scripts
2. Update or remove legacy shell scripts

### Phase 5: Documentation and CI
1. Update documentation
2. Update Docker files
3. Update CI workflows

## Testing the Changes

After each phase:
1. Build: `make build`
2. Run tests: `python3 scripts/test/parallel_test_runner.py`
3. Verify no embedded references remain: `grep -r "embedded" geodetestlab/`

## Rollback Plan

If issues arise:
1. Git revert the changes
2. Investigate the failures
3. Address root cause before re-attempting

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Tests fail without embedded mode | Server management in test runner handles this |
| Slower tests (server startup overhead) | Port pooling and parallel server instances already implemented |
| CI/CD breakage | Test in CI environment before merging |
| Developer workflow impact | Document new workflow, provide server start scripts |

## Success Criteria

- [ ] No `--embedded` flag in codebase (except in comments documenting removal)
- [ ] No `--no-quic` flag in codebase
- [ ] All tests pass using server mode only
- [ ] CI/CD pipelines pass
- [ ] Documentation updated

## Estimated Work

- Phase 1: ~2-3 hours (core CLI changes)
- Phase 2: ~2-3 hours (test infrastructure)
- Phase 3: ~1-2 hours (spec file updates - mostly mechanical)
- Phase 4: ~1 hour (scripts)
- Phase 5: ~1 hour (docs and CI)

**Total: ~7-10 hours**
