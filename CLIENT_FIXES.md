# Client Library Fixes - November 2025

## Overview
This document tracks issues and fixes applied to the Geode client libraries to restore functionality after msquic integration changes.

## Zig Client (`clients/zig/`)

### Issue 1: Missing msquic Wrapper Submodule
**Problem**: The Zig client referenced `../../tools/zig-msquic/src/msquic_wrapper.zig` which didn't exist. The submodule was removed but the client wasn't updated.

**Root Cause**: The client was expecting a separate msquic wrapper in `tools/zig-msquic/` but this directory was empty.

**Solution**:
1. Copied msquic wrapper files from geode's server implementation to the client directory:
   - `src/transport/msquic_types.zig` → `clients/zig/msquic_types.zig`
   - `src/transport/msquic_wrapper.zig` → `clients/zig/msquic_wrapper.zig`

2. Updated `clients/zig/geode_client_v2.zig`:
   ```zig
   // Before:
   const MsQuic = @import("../../tools/zig-msquic/src/msquic_wrapper.zig");

   // After:
   const MsQuic = @import("msquic_wrapper.zig");
   ```

### Issue 2: Incomplete msquic Wrapper API
**Problem**: The wrapper was missing many types, constants, and helper functions that the client code expected.

**Missing Components**:
- `QuicStatus` helper struct with `isError()` method
- `QuicSettings` with user-friendly `IsSet.flags` interface
- Event structure definitions (`struct_QUIC_CONNECTION_EVENT`, `struct_QUIC_STREAM_EVENT`)
- Constants: credential flags, shutdown flags, send flags, address families
- Function types: `ConnectionShutdownFn`, `StreamCallbackFn`

**Solution**: Enhanced `msquic_wrapper.zig` with:
```zig
// Status helper
pub const QuicStatus = struct {
    pub fn isError(status: QUIC_STATUS) bool {
        return status != QUIC_STATUS_SUCCESS and
               status != QUIC_STATUS_PENDING and
               status != QUIC_STATUS_ASYNC_PENDING;
    }
};

// User-friendly settings with bitfield helper
pub const QuicSettings = extern struct {
    IsSet: IsSetStruct,
    // ... fields ...
    pub const IsSetStruct = extern union {
        flags: packed struct(u64) {
            IdleTimeoutMs: bool = false,
            PeerBidiStreamCount: bool = false,
            // ... more flags ...
        },
        raw: u64,
    };
};

// Event structures
pub const struct_QUIC_CONNECTION_EVENT = extern struct {
    Type: types.QUIC_CONNECTION_EVENT_TYPE,
    unnamed_0: extern union {
        SHUTDOWN_COMPLETE: extern struct {
            AppCloseInProgress: bool,
        },
        _placeholder: [64]u8,
    },
};

// Constants
pub const QUIC_CREDENTIAL_FLAG_CLIENT: u32 = 0x00000001;
pub const QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION: u32 = 0x00000004;
pub const QUIC_CONNECTION_SHUTDOWN_FLAG_NONE: u32 = 0;
pub const QUIC_STREAM_START_FLAG_NONE: u32 = 0;
pub const QUIC_SEND_FLAG_NONE: u32 = types.QUIC_SEND_FLAG_NONE;
pub const QUIC_ADDRESS_FAMILY_UNSPEC: u16 = @intCast(@intFromEnum(types.QUIC_ADDRESS_FAMILY.QUIC_ADDRESS_FAMILY_UNSPEC));
```

### Issue 3: Build Configuration Issues
**Problem**: The `build.zig` tried to reference non-existent wrapper modules and had incorrect library paths.

**Solution**: Rewrote `clients/zig/build.zig` to:
1. Link msquic and dependencies directly:
   ```zig
   test_exe.linkSystemLibrary("msquic");
   test_exe.linkSystemLibrary("ssl");
   test_exe.linkSystemLibrary("crypto");
   if (target.result.os.tag == .linux) {
       test_exe.linkSystemLibrary("dl");
   }
   ```

2. Use local fork headers and system library:
   ```zig
   const msquic_include = b.graph.env_map.get("MSQUIC_INCLUDE_DIR") orelse "../../forks/msquic/src/inc";
   const msquic_lib = b.graph.env_map.get("MSQUIC_LIB_DIR") orelse "/usr/lib/x86_64-linux-gnu";
   ```

3. Create proper module dependencies:
   ```zig
   const msquic_types_mod = b.createModule(.{
       .root_source_file = b.path("msquic_types.zig"),
       .target = target,
       .optimize = optimize,
   });

   const msquic_wrapper_mod = b.createModule(.{
       .root_source_file = b.path("msquic_wrapper.zig"),
       .target = target,
       .optimize = optimize,
   });

   msquic_wrapper_mod.addImport("msquic_types", msquic_types_mod);
   test_exe.root_module.addImport("msquic_wrapper", msquic_wrapper_mod);
   ```

### Issue 4: Type Compatibility Issues
**Problem**: Multiple type mismatches between client code and wrapper API:
- Callback signatures used `[*c]` pointers instead of `*const` pointers
- Single pointers passed where many pointers (`[*]`) were expected
- Enum values used where integer types were expected

**Solutions**:
1. Fixed callback signatures:
   ```zig
   // Before:
   fn connectionCallback(
       connection: MsQuic.HQUIC,
       self_ptr: ?*anyopaque,
       event: [*c]MsQuic.struct_QUIC_CONNECTION_EVENT,
   ) callconv(.c) MsQuic.QUIC_STATUS

   // After:
   fn connectionCallback(
       connection: MsQuic.HQUIC,
       self_ptr: ?*anyopaque,
       event: *const MsQuic.struct_QUIC_CONNECTION_EVENT,
   ) callconv(.c) MsQuic.QUIC_STATUS
   ```

2. Fixed buffer passing:
   ```zig
   // Before:
   msquic.StreamSend.?(stream, &buffer, 1, flags, null)

   // After:
   const buffer_array = [_]MsQuic.QUIC_BUFFER{buffer};
   msquic.StreamSend.?(stream, &buffer_array, 1, flags, null)
   ```

3. Cast settings structures:
   ```zig
   const settings_ptr: *const MsQuic.QUIC_SETTINGS = @ptrCast(&settings);
   msquic.ConfigurationOpen.?(registration, &alpn_array, 1, settings_ptr, ...)
   ```

### Issue 5: API Table Optional Function Pointers
**Problem**: The client code used `.?` on function pointers, but they weren't marked as optional in the API table.

**Solution**: Made all function pointers in `QUIC_API_TABLE` optional:
```zig
pub const QUIC_API_TABLE = extern struct {
    RegistrationOpen: ?RegistrationOpenFn,
    RegistrationClose: ?RegistrationCloseFn,
    ConfigurationOpen: ?ConfigurationOpenFn,
    ConnectionOpen: ?ConnectionOpenFn,
    ConnectionShutdown: ?ConnectionShutdownFn,
    StreamOpen: ?StreamOpenFn,
    StreamSend: ?StreamSendFn,
    // ... etc ...
};
```

### Build Result
✅ **Status**: FIXED
- Binary: `clients/zig/zig-out/bin/test_connection_v2` (8.3M)
- Build command: `cd clients/zig && zig build`
- All compilation errors resolved

## Rust Client (`clients/rust/`)

### Issue 1: Connection Timeouts
**Problem**: All Rust client tests timeout after 5-10 seconds. The client appears to hang during connection or query execution.

**Symptoms**:
```
Running rust... ⚠ ERROR (10007.1ms)
  Error: Test timed out
```

**Observations**:
- Python and Go clients complete the same tests in ~50-400ms
- Rust client consistently times out on every test
- No error messages, just timeout
- Build completes successfully with warnings about unused fields

**Potential Causes**:
1. QUIC connection not establishing properly
2. TLS handshake hanging
3. Stream setup or send/receive logic blocking indefinitely
4. Missing async/await handling

**Investigation Needed**:
- Check if the Rust client's quiche integration is compatible with geode's QUIC implementation
- Verify TLS certificate handling
- Add debug logging to identify where the hang occurs
- Test basic connectivity outside the test harness

### Build Warnings
The Rust build shows several warnings about unused fields:
```rust
warning: fields `socket`, `peer_addr`, and `page_size` are never read
   --> clients/rust/src/client.rs:114:5
    |
114 |     socket: UdpSocket,
115 |     peer_addr: SocketAddr,
116 |     page_size: usize,

warning: field `max_size` is never read
  --> clients/rust/src/pool.rs:14:5
   |
14 |     max_size: usize,

warning: fields `decimal_scale` and `time_value` are never read
  --> clients/rust/src/types.rs:53:5
   |
53 |     decimal_scale: String,
58 |     time_value: Option<NaiveTime>,
```

## Zig Test Runner (`clients/test-harness/runners/zig_runner_new.zig`)

### Issue 1: YAML Parser Cannot Handle Commas in Values
**Problem**: The Zig test runner's YAML parser fails when parsing query strings that contain commas (like multiple column selections).

**Error Pattern**:
```
Error: [YAML DEBUG] Expected ':' after key ', 'Hello' AS greeting, true AS flag' at pos=134, line=4, col=1
[YAML DEBUG] Found character: '\n' (0xa)
error: UnexpectedToken
```

**Root Cause**: The YAML parser in `src/util/yaml.zig` incorrectly treats commas within quoted strings as key-value separators, breaking on multi-column RETURN statements.

**Affected Tests**: Any test with queries containing commas:
- `RETURN 1 AS x, 'Hello' AS greeting, true AS flag`
- `RETURN $name AS name, $age AS age`
- `RETURN NULL AS null_value, 1 AS not_null`
- `RETURN [1, 2, 3, 4, 5] AS numbers`

**Examples of Failing Queries**:
1. Multiple columns: `RETURN 1 AS x, 'Hello' AS greeting`
2. Parameters: `RETURN $name AS name, $age AS age`
3. Arithmetic: `RETURN 10 - 3 AS diff, 4 * 5 AS product`
4. Arrays: `RETURN [1, 2, 3, 4, 5] AS numbers`
5. Functions: `SELECT auth.login('testuser', 'testpass123') AS session`

**Solution Needed**: Fix the YAML parser to properly handle:
1. Quoted strings (single and double quotes)
2. Nested structures (arrays, objects)
3. Commas within values vs key-value separators
4. Multi-line values

**Workaround**: For now, the Zig test runner fails on most tests. The actual Zig client library (geode_client_v2.zig) builds successfully and should work when called directly.

## Python Client (`clients/python/`)

### Status: ✅ WORKING
- All tests passing consistently
- Response times: 390-570ms per test
- No known issues

## Go Client (`clients/go/`)

### Status: ✅ WORKING
- All tests passing consistently
- Response times: 36-120ms per test (fastest client)
- No known issues

## Test Results Summary (Partial)

Based on test harness run (in progress):

| Client | Status | Pass Rate | Avg Response Time | Issues |
|--------|--------|-----------|-------------------|---------|
| Python | ✅ Working | 100% | ~410ms | None |
| Go | ✅ Working | 100% | ~50ms | None |
| Rust | ⚠️ Broken | 0% | N/A (timeout) | Connection hangs |
| Zig (runner) | ⚠️ Broken | 0% | ~165ms | Connection errors (YAML parser fixed!) |
| Zig (library) | ✅ Built | N/A | N/A | Needs msquic integration testing |

**Latest Test Run (November 18, 2025 - Post-YAML Fixes)**:
- Zig Runner: 0/51 tests passing (all fail with `error.StreamOpenFailed`)
- YAML Parser: ✅ Working correctly - no parse errors
- Issue: Zig client cannot establish QUIC connections to the server

### Issue 2: YAML Parser Treating Commas as Delimiters (FIXED)
**Problem**: The YAML parser in `src/util/yaml.zig` was treating commas as delimiters even in block-style (non-flow) contexts. This caused queries like `RETURN 1 AS x, 'Hello' AS greeting` to be parsed incorrectly, stopping at the first comma.

**Root Cause**: The test harness uses Python's `yaml.dump()` to create temporary test files (see `run_tests.py:687`), which generates unquoted YAML values:
```yaml
query: RETURN 1 AS x, 'Hello' AS greeting, true AS flag  # No quotes!
```

The Zig YAML parser's `parseScalar` function (line 325) was treating commas as delimiters in all contexts:
```zig
// Before:
if (ch == '\n' or ch == '\r' or ch == '#' or ch == ',' or ch == ']' or ch == '}') break;
```

According to YAML spec, commas should only be delimiters inside flow collections `[...]` and `{...}`, not in regular block-style scalars.

**Solution**: Added a `in_flow_context` parameter to `parseScalar()` to distinguish between flow and block contexts:

1. Updated `parseScalar` signature:
   ```zig
   fn parseScalar(self: *Parser, in_flow_context: bool) Error!Value
   ```

2. Modified delimiter logic (line 327-328):
   ```zig
   if (ch == '\n' or ch == '\r' or ch == '#') break;
   if (in_flow_context and (ch == ',' or ch == ']' or ch == '}')) break;
   ```

3. Updated call sites:
   - Block context: `parseScalar(false)` in `parseMap` and `parseValue`
   - Flow context handled separately by `parseFlowValue()`

4. Also added line-end skipping after inline values in `parseMap` (lines 255-260) to prevent trailing content from being misinterpreted as keys.

**Result**: ✅ YAML parsing now works correctly for unquoted scalars with commas
- Parser successfully handles queries like `RETURN 1 AS x, 'Hello' AS greeting, true AS flag`
- Error changed from YAML parse failure to client connection issues (expected when server not running)
- Files: `src/util/yaml.zig` lines 241, 267, 325-328

### Issue 3: YAML Parser Not Handling Multi-Line Scalars (FIXED)
**Problem**: The YAML parser stopped at newlines even when the next line was a continuation with more indentation. This caused queries that span multiple lines to be parsed incorrectly.

**Example Failing Query**:
```yaml
query: RETURN true AND false AS and_result, true OR false AS or_result, NOT true
      AS not_result
```

**Error Pattern**:
```
Error: [YAML DEBUG] Expected ':' after key 'AS not_result' at pos=171, line=5, col=1
error: UnexpectedToken
```

**Root Cause**: When `parseScalar` encountered a newline (line 327), it stopped immediately without checking if the next line was a continuation. According to YAML spec, lines with more indentation than the base level should be treated as continuations of the same scalar value, separated by a space.

**Solution**: Enhanced `parseScalar` to detect and handle multi-line scalar continuations:

1. Updated `parseScalar` signature to include indentation level:
   ```zig
   fn parseScalar(self: *Parser, in_flow_context: bool, indent_level: usize) Error!Value
   ```

2. Added multi-line continuation logic (lines 325-391):
   ```zig
   // Use ArrayList to accumulate multi-line content
   var parts = try std.ArrayList(u8).initCapacity(self.allocator, 128);
   defer parts.deinit(self.allocator);

   while (self.pos < self.input.len) {
       // Parse current line
       const line_content = std.mem.trimRight(u8, self.input[line_start..self.pos], " \t");
       try parts.appendSlice(self.allocator, line_content);

       // Check if next line is a continuation (has more indentation)
       if (!in_flow_context and self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) {
           const next_indent = self.getCurrentIndent();
           if (next_indent > indent_level) {
               // It's a continuation - add space separator and continue
               try parts.append(self.allocator, ' ');
               continue;
           } else {
               // Not a continuation - stop
               break;
           }
       }
   }
   ```

3. Updated call sites to pass indentation level:
   - Line 88: `parseScalar(false, indent_level)` in `parseValue`
   - Line 241: `parseScalar(false, indent_level)` in `parseMap`

4. Fixed Zig 0.15 API compatibility:
   - Changed `ArrayList(u8).init` to `ArrayList(u8).initCapacity`
   - Added allocator parameter to `appendSlice` and `append` calls
   - Added allocator parameter to `deinit` call

**Result**: ✅ YAML parser now correctly handles multi-line scalar values
- Parser successfully handles queries like:
  ```yaml
  query: RETURN true AND false AS and_result, true OR false AS or_result, NOT true
        AS not_result
  ```
- Continuation lines are joined with space separators
- No more YAML parse errors for multi-line queries
- Test result changes from YAML parse error to connection error (expected behavior)
- Files modified: `src/util/yaml.zig` lines 88, 241, 267, 325-391

### Issue 4: Zig Client Connection Failures (INVESTIGATING)
**Problem**: After fixing the YAML parser, the Zig client can parse all test specifications correctly but fails to connect to the Geode server. All tests fail with `error.StreamOpenFailed`.

**Test Results** (November 18, 2025):
- Total Tests: 51
- Passed: 0
- Failed: 49
- Skipped: 2
- Pass Rate: 0.0%
- Average failure time: ~165ms

**Symptoms**:
- No YAML parse errors (✅ parser working correctly)
- All tests fail with `error.StreamOpenFailed`
- Fast failure times (~165ms) suggest connection timeouts
- Python and Go clients work fine with the same server

**Potential Causes**:
1. QUIC connection initialization failure in Zig client
2. TLS certificate validation issues
3. msquic API usage errors in the Zig wrapper
4. Missing or incorrect ALPN (Application-Layer Protocol Negotiation) setup
5. Connection callback not properly handling events

**Investigation Needed**:
1. Add debug logging to the Zig client to see where connection fails
2. Verify msquic is properly initialized
3. Check TLS certificate handling
4. Compare Zig client's QUIC setup with working Python/Go clients
5. Test Zig client's binary directly (bypass test harness)

**Status**: ⚠️ BLOCKED - Cannot test Zig client functionality until connection issues are resolved

## Next Steps

### Immediate Priorities
1. **✅ COMPLETED: Fix Zig Test Runner YAML Parser**
   - Location: `src/util/yaml.zig`
   - Issues Fixed:
     - Issue 2: Comma handling in block context
     - Issue 3: Multi-line scalar handling
   - Status: Both issues resolved, parser now handles all test cases correctly
   - Result: 0 YAML parse errors in test run of 51 tests

2. **⚠️ IN PROGRESS: Diagnose Zig Client Connection Failures (Issue 4)**
   - Current Status: YAML parser fixed, all tests fail with `error.StreamOpenFailed`
   - Location: `clients/zig/geode_client_v2.zig`
   - Next Actions:
     - Add debug logging to identify where connection fails
     - Verify msquic initialization
     - Check TLS/ALPN configuration
     - Compare with working Python/Go clients
   - Priority: HIGH - Blocks all Zig client testing

3. **Fix Rust Client Connection Timeouts**
   - Location: `clients/rust/src/client.rs`
   - Issue: Connection or query execution hangs (100% timeout rate)
   - Priority: HIGH - Blocks all Rust client testing
   - Investigation: Add debug logging, test basic connectivity, check quiche integration

### Follow-up Tasks
4. Clean up Rust build warnings (unused fields)
5. Add integration tests that bypass the YAML test runner
6. Document client compatibility matrix
7. Add troubleshooting guide for each client

## Test Commands
```bash
# Build Zig client
cd clients/zig && zig build

# Run test harness (requires server)
cd clients/test-harness
make setup
.venv/bin/python3 run_tests.py --verbose --report-json reports/test_results.json

# Test specific client
.venv/bin/python3 run_tests.py --clients python --verbose
.venv/bin/python3 run_tests.py --clients go --verbose
.venv/bin/python3 run_tests.py --clients rust --verbose

# Bypass test runner - test Zig client directly
cd clients/zig
./zig-out/bin/test_connection_v2
```
