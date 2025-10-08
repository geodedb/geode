# QUIC Smoke Test Fix

**Date:** October 2025
**Status:** ✅ RESOLVED

## Problem

The QUIC smoke test (`tests/e2e_quic_explain_smoke.zig`) was failing with `FileNotFound` error:

```
1/1 e2e_quic_explain_smoke.test.quic: EXPLAIN schema then explain (smoke)...FAIL (FileNotFound)
/nix/store/0lhqddd2i6dybgidm29i9zc4simd1rm3-zig-0.15.1/lib/zig/std/process/Child.zig:324:9: 0x10640c2 in waitForSpawn (std.zig)
```

## Root Cause

The test was attempting to use the old separate `geodec` and `geoded` binaries which no longer exist:

```zig
const server = "./zig-out/bin/geoded";  // ❌ Doesn't exist
const cli = "./zig-out/bin/geodec";     // ❌ Doesn't exist
```

The geode CLI has been unified into a single binary (`./zig-out/bin/geode`) with subcommands (`serve`, `query`, etc.), but the smoke test was not updated to reflect this change.

## Solution

Updated `tests/e2e_quic_explain_smoke.zig` to use the unified `geode` binary with appropriate subcommands:

### Changes Made

**Before:**
```zig
const server = "./zig-out/bin/geoded";
var srv = Child.init(&.{
    server,
    "--listen-quic", "127.0.0.1:7567",
    "--log_json",
    "--result-format", "json",
    "--test-exit-after-first-request"
}, ally);

const cli = "./zig-out/bin/geodec";
const res = try run(&.{
    cli,
    "EXPLAIN RETURN 1 AS x",
    "--format", "json",
    "--quic",  // ❌ Flag doesn't exist (QUIC is default)
    "--server", "127.0.0.1:7567"
});
```

**After:**
```zig
const geode = "./zig-out/bin/geode";
var srv = Child.init(&.{
    geode,
    "serve",               // ✅ Use serve subcommand
    "--listen", "127.0.0.1:7567",
    "--log-level", "info"
}, ally);

const res = try run(&.{
    geode,
    "query",               // ✅ Use query subcommand
    "EXPLAIN RETURN 1 AS x",
    "--format", "json",
    "--server", "127.0.0.1:7567",
    "--insecure"          // ✅ Skip TLS cert verification for tests
});
```

### Key Changes

1. **Unified Binary**: Changed from separate `geoded`/`geodec` to single `geode` binary
2. **Subcommands**: Added `serve` and `query` subcommands
3. **Server Flags**:
   - Changed `--listen-quic` to `--listen` (QUIC is default transport)
   - Removed test-specific flags that don't exist
   - Added `--log-level info` for appropriate logging
4. **Client Flags**:
   - Removed `--quic` flag (QUIC is the default, use `--no-quic` to disable)
   - Added `--insecure` to skip certificate verification in tests
5. **Server Termination**: Updated to properly kill the server process after test completion

## Test Results

### Before Fix
```
1/1 e2e_quic_explain_smoke.test.quic: EXPLAIN schema then explain (smoke)...FAIL (FileNotFound)
make: *** [Makefile:653: quic-smoke-strict] Error 1
```

### After Fix
```
1/1 e2e_quic_explain_smoke.test.quic: EXPLAIN schema then explain (smoke)...OK
All 1 tests passed.
✓ Extended QUIC tests completed
```

## Verification

All QUIC test targets now pass successfully:

```bash
# Core vendor QUIC tests
$ make quic-test
✓ Vendor QUIC tests passed
✓ All QUIC tests passed

# Extended tests including smoke tests
$ make quic-test-extended
✓ Vendor QUIC tests passed
1/1 e2e_quic_explain_smoke.test.quic: EXPLAIN schema then explain (smoke)...OK
All 1 tests passed.
✓ Extended QUIC tests completed
```

## Related Changes

This fix aligns with the unified CLI architecture documented in `CLAUDE.md`:

```markdown
## 🔧 Unified CLI Architecture

**Complete Migration Achieved**:
- ✅ **Single Binary**: `./zig-out/bin/geode` (unified architecture)
- ✅ **Zero Subprocess Calls**: Eliminated geodec/geoded spawning
- ✅ **Test Compatibility**: --no-quic mode for integration tests
```

## Command Reference

### Unified Binary Usage

**Server:**
```bash
# Old (deprecated)
./zig-out/bin/geoded --listen-quic 127.0.0.1:7567

# New (current)
./zig-out/bin/geode serve --listen 127.0.0.1:7567
```

**Client:**
```bash
# Old (deprecated)
./zig-out/bin/geodec "RETURN 1 AS x" --quic --server 127.0.0.1:7567

# New (current)
./zig-out/bin/geode query "RETURN 1 AS x" --server 127.0.0.1:7567
# Note: QUIC is default, use --no-quic to disable
```

## Impact

- ✅ QUIC smoke tests now pass
- ✅ Extended QUIC test suite (`make quic-test-extended`) works correctly
- ✅ All QUIC tests integrated into CI/CD pipeline
- ✅ Test infrastructure aligned with unified binary architecture

## Files Modified

1. **tests/e2e_quic_explain_smoke.zig**
   - Updated to use unified `geode` binary
   - Fixed command-line arguments
   - Improved server cleanup

## Future Considerations

If additional smoke tests are added, they should use the unified binary pattern:

```zig
const geode = "./zig-out/bin/geode";

// Server
var srv = Child.init(&.{ geode, "serve", "--listen", addr, "--log-level", "info" }, ally);

// Client
const res = try run(&.{ geode, "query", query_text, "--server", addr, "--insecure" });
```

---

**Conclusion:** The smoke test failure has been resolved by updating to use the unified `geode` binary with proper subcommands. All QUIC tests now pass successfully and are integrated into the standard test suite.
