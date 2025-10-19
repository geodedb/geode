# Phase 6 Completion Report: Test Isolation Issues
October 18, 2025

## Summary

Phase 6 focused on fixing test isolation issues that caused setup command failures across multiple test runs. The problem was catalog file persistence in `/tmp/` that wasn't being cleaned up between tests, causing duplicate entity errors when setup commands ran.

## Test Results

### Before Phase 6
```
TOTAL: 1525 passed, 141 failed, 37 skipped
Failure types:
  exit code: 130 tests
  setup command failed (exit 1): 8 tests
  timeout: 2 tests
  missing: 1 tests
```

### After Phase 6
```
TOTAL: 1534 passed, 132 failed, 37 skipped
Failure types:
  exit code: 129 tests
  timeout: 2 tests
  missing: 1 tests
```

### Impact
- **+9 tests passing** (1525 → 1534)
- **-9 tests failing** (141 → 132)
- **-8 setup failures** (8 → 0) ✓
- **-1 exit code failure** (130 → 129)

## Changes Made

### File: `extended_test_runner.py`

**Modified catalog cleanup paths** (lines 124-135):

**Before**:
```python
# Clear catalog file to prevent duplicate graph/index/schema errors
# But only if not a duplicate-testing test
if not skip_isolation:
    home_dir = os.path.expanduser('~')
    catalog_paths = [
        f'{home_dir}/.geode/catalog.json',
        f'{home_dir}/.geode/catalog_indexes.json',
        f'{home_dir}/.geode/catalog_schemas.json',
    ]
    for catalog_path in catalog_paths:
        try:
            os.remove(catalog_path)
        except FileNotFoundError:
            pass
```

**After**:
```python
# Clear catalog files at start of each test to ensure clean state
# This prevents setup failures on subsequent runs while still allowing
# duplicate detection between setup and main test within a single run
catalog_paths = [
    '/tmp/geode_catalog.dat',
    '/tmp/geode_fle_catalog.dat',
]
for catalog_path in catalog_paths:
    try:
        os.remove(catalog_path)
    except FileNotFoundError:
        pass
```

**Key Changes**:
1. **Removed `if not skip_isolation` condition**: Always clean catalog at test start
2. **Fixed file paths**: Changed from `~/.geode/catalog*.json` to `/tmp/geode_catalog.dat`
3. **Fixed file names**: Changed from `.json` extension to `.dat` extension

## Root Cause Analysis

### Original Problem

The test runner was attempting to clean catalog files from the wrong location:
- **Expected location**: `~/.geode/catalog.json`, `~/.geode/catalog_indexes.json`, `~/.geode/catalog_schemas.json`
- **Actual location**: `/tmp/geode_catalog.dat`, `/tmp/geode_fle_catalog.dat`

Additionally, the cleanup was conditional on `skip_isolation = False`, which meant tests with "error" or "duplicate" in their names never got catalog cleanup, leading to persistent state across test runs.

### Failure Pattern

**Setup failures occurred for 8 tests**:
1. `create-schema-if-not-exists-duplicate` - "Duplicate schema name"
2. `create-or-replace-graph-type` - "TypeAlreadyExists"
3. `create-graph-type-copy-of` - "TypeAlreadyExists"
4. `drop-graph-type-basic` - "TypeAlreadyExists"
5. `drop-property-graph-type-basic` - "TypeAlreadyExists"
6. `drop-graph-type-if-exists` - "TypeAlreadyExists"
7. `create-duplicate-schema-error` - "Duplicate schema name"
8. `create-duplicate-graph-error` - "Duplicate graph name"

**Sequence of events**:
1. First test run: Clean catalog (skip_isolation prevents this) → Setup creates entity → Test runs → Catalog persists
2. Second test run: Catalog NOT cleaned → Setup tries to create same entity → Fails with duplicate error

### Solution

**Always clean catalog at the start of each test**, regardless of `skip_isolation`:
- Ensures fresh catalog state for each test execution
- Allows duplicate detection WITHIN a single test (setup → main)
- Prevents cross-test contamination

**Correct file locations**:
- `/tmp/geode_catalog.dat` - Main catalog storage
- `/tmp/geode_fle_catalog.dat` - FLE (Field-Level Encryption) catalog

## Technical Notes

### Discovery Process

1. **Initial hypothesis**: `skip_isolation` logic was preventing catalog cleanup
2. **Manual testing**: Created schemas/graphs, couldn't find catalog files in `~/.geode/`
3. **File search**: Found actual catalog files in `/tmp/` with `.dat` extension
4. **Root cause**: Test runner cleaning wrong files at wrong location

### Catalog File Locations

The geode database stores catalog information in `/tmp/` for embedded/query mode:
- `/tmp/geode_catalog.dat` - Schema, graph type, and index definitions
- `/tmp/geode_fle_catalog.dat` - Field-level encryption catalog

These files persist across process invocations, which is why catalog state accumulated across tests.

### Skip Isolation Behavior

**Before fix**: `skip_isolation = True` → No catalog cleanup at all
**After fix**: Catalog always cleaned at test start

This doesn't break duplicate detection because:
- Clean catalog → Run setup (creates entity) → Run main test (attempts duplicate) → Duplicate detected ✓

The key is that catalog cleanup happens BEFORE the test, not BETWEEN setup and main.

## Comparison to Previous Phases

### Phase 4: Index Operation Errors
- **Problem**: Test isolation inconsistency between setup and main
- **Solution**: Modified test runner to skip isolation in setup commands
- **Result**: +1 index test, -3 schema/graph tests (net -2)
- **Side effect**: Created 8 setup failures

### Phase 6: Test Isolation Issues
- **Problem**: Catalog files persisting across tests in wrong location
- **Solution**: Fixed catalog file paths and always clean at test start
- **Result**: +9 tests (fixed the 8 setup failures from Phase 4 + 1 additional)
- **Recovery**: Fully recovered from Phase 4 regression and added net gain

## Verification

### Setup Failures Eliminated
```bash
$ python3 extended_test_runner.py 2>&1 | grep "setup command failed"
# No output - all setup failures resolved ✓
```

### Index Duplicate Test Still Passes
```bash
$ python3 extended_test_runner.py 2>&1 | grep "index-error-duplicate"
✓ [geode_index_comprehensive.yml] index-error-duplicate-index-name
```

### Overall Improvement
- **Phase 4 end**: 1525 passed, 141 failed
- **Phase 6 end**: 1534 passed, 132 failed
- **Net gain**: +9 passing tests

## Remaining Work

### Next Phase

- **Phase 7**: Timeout optimizations (2 tests)
  - `connection-timeout` - QUIC connection timeout
  - `connection-refused` - QUIC connection refused

### Outstanding Failures

**Exit code failures** (129 tests):
- Various functional tests requiring features not yet implemented
- Server-mode tests running in embedded mode
- Tests expecting specific error behaviors

**Timeout tests** (2 tests):
- QUIC transport tests expecting timeouts/connection failures
- May require network configuration or feature implementation

**Missing test** (1 test):
- `check-index-usage` - Missing output or functionality

## Recommendations

1. **Catalog Cleanup Strategy**: The current approach of cleaning `/tmp/geode_catalog.dat` files works well. Consider documenting this for future test development.

2. **Skip Isolation Review**: Now that catalog cleanup happens regardless of `skip_isolation`, review if the flag is still needed or if it can be simplified/removed.

3. **Catalog File Location**: Consider making catalog file location configurable or using a test-specific directory to avoid potential conflicts.

## Conclusion

Phase 6 successfully resolved all 8 setup command failures by fixing the catalog cleanup logic to:
1. Use the correct file paths (`/tmp/geode_catalog.dat` instead of `~/.geode/catalog.json`)
2. Always clean catalog at test start (removed `if not skip_isolation` condition)

This fix fully recovered from the Phase 4 regression (-2 tests) and provided a net gain (+9 tests), bringing the total passing tests from 1525 to 1534.

**Phase 6 Status**: ✅ **Complete - All Setup Failures Resolved**
- Setup failures: 8 → 0 (100% reduction)
- Test count: 1534 passed, 132 failed (+9 from Phase 4)
- No regressions introduced
