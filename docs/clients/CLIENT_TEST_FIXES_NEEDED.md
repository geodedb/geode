# Client Test Harness Fixes Needed

## Current Status

**Test Results**: 0/15 passing (100% failure rate)
**Primary Issue**: QUIC handshake incompatibility between aioquic (Python client) and quiche (server)

## Issues Identified

### 1. QUIC Compatibility Issue (CRITICAL)

**Problem**:
- Python client uses `aioquic` library for QUIC support
- Server uses `quiche` library (Rust/C implementation)
- Handshake fails: "ERROR: Handshake failed to complete after 200 attempts (10000ms)"
- All tests timeout after 5 seconds waiting for connection

**Root Cause**:
```
File "/nix/store/.../aioquic/asyncio/client.py", line 93, in connect
    await protocol.wait_connected()
asyncio.exceptions.CancelledError
```

The QUIC handshake between aioquic and quiche doesn't complete. While both implement QUIC v1 (RFC 9000), there appear to be subtle compatibility issues.

**Evidence**:
- Server accepts connection: "✅ Accepted QUIC connection #1"
- Server waits for handshake completion but it never arrives
- Client times out waiting for `wait_connected()`

### 2. Missing TCP Fallback in Python Client

**Problem**:
- Python client only supports QUIC (via aioquic)
- No TCP/TLS fallback implementation
- Server supports `--insecure` mode but client can't use it

**Impact**:
- Cannot run tests with `--insecure` server
- Makes testing difficult during development

### 3. Test Runner Configuration

**Fixed**: Added `--insecure` flag to test harness server start (line 137 in run_tests.py)

```python
self.process = await asyncio.create_subprocess_exec(
    str(self.geode_binary),
    "serve",
    "--listen",
    listen_addr,
    "--insecure",  # Disable QUIC for now
    ...
)
```

### 4. Missing `raw_value` Property

**Fixed**: Added `raw_value` property to Value class for test compatibility

```python
@property
def raw_value(self) -> Any:
    """Get the raw Python value for test compatibility."""
    if self.kind == ValueKind.NULL:
        return None
    elif self.kind == ValueKind.INT:
        return self.int_value
    ...
```

## Solutions Implemented

### ✅ Completed

1. **Added `raw_value` property** to `clients/python/geode_client/types.py`
   - Test runner can now access values correctly

2. **Updated test harness** to use `--insecure` flag
   - Temporarily disables QUIC until Python client TCP support is added

### 🚧 In Progress

3. **Add TCP support to Python client**
   - Need to implement TCP socket-based connection
   - Should detect server capabilities and use appropriate transport

## Solutions Needed

### Option A: Fix QUIC Compatibility (Long-term)

**Tasks**:
1. Debug aioquic/quiche handshake incompatibility
2. Check QUIC version negotiation
3. Verify TLS 1.3 configuration compatibility
4. Test with wireshark to see packet exchange
5. Consider switching Python client to use quiche Python bindings instead of aioquic

**Pros**:
- Proper QUIC support for performance
- Matches other clients (Go, Rust use quiche)

**Cons**:
- Time-consuming to debug
- May require aioquic patches or quiche Python bindings

### Option B: Implement TCP Fallback (Short-term) ✅ RECOMMENDED

**Tasks**:
1. Add `use_quic` parameter to Connection class
2. Implement TCP socket connection mode:
   ```python
   if use_quic:
       # Existing QUIC code
   else:
       # New TCP code
       reader, writer = await asyncio.open_connection(host, port)
   ```
3. Add auto-detection: try QUIC, fallback to TCP on failure
4. Update test runner to use TCP mode

**Pros**:
- Fast to implement
- Unblocks testing immediately
- Still allows QUIC support later

**Cons**:
- Doesn't solve QUIC issue
- Need to maintain two code paths

## Recommended Approach

**Phase 1** (Immediate - 2-4 hours):
1. Implement TCP support in Python client
2. Add connection mode detection
3. Update test runner to prefer TCP for now
4. Get tests passing with TCP

**Phase 2** (Future - 1-2 days):
1. Investigate aioquic/quiche compatibility
2. Consider switching to quiche Python bindings
3. Re-enable QUIC once compatibility is confirmed
4. Benchmark QUIC vs TCP performance

## Implementation Plan for Phase 1

### File: `clients/python/geode_client/client.py`

Add TCP connection support:

```python
class Connection:
    def __init__(self, ..., use_quic: bool = False):  # Default to TCP for now
        ...
        self.use_quic = use_quic
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None

    async def connect(self) -> None:
        if self.use_quic:
            # Existing QUIC code
            await self._connect_quic()
        else:
            # New TCP code
            await self._connect_tcp()

    async def _connect_tcp(self) -> None:
        """Establish TCP connection."""
        self._reader, self._writer = await asyncio.open_connection(
            self.host, self.port
        )
        # Send HELLO
        hello = {...}
        await self._write_json_tcp(hello)
        response = await self._read_json_tcp()
        ...
```

### File: `clients/test-harness/runners/python_runner.py`

Update to use TCP:

```python
class PythonTestRunner:
    def __init__(self, server: str, verbose: bool = False):
        host, port = server.split(":")
        self.client = Client(host=host, port=int(port), skip_verify=True)
        self.verbose = verbose
        self.connection: Optional[Connection] = None
        self.use_quic = False  # Disable QUIC for now
```

## Testing Strategy

1. **Unit tests**: Test TCP connection in isolation
2. **Integration tests**: Run full test suite with TCP
3. **Compatibility**: Ensure TCP mode matches QUIC semantics
4. **Performance**: Benchmark to ensure acceptable latency

## Success Criteria

- [ ] All 15 basic tests pass with TCP connection
- [ ] Connection establishment < 100ms
- [ ] Query latency < 10ms (localhost)
- [ ] Graceful error handling
- [ ] Connection pooling works with TCP

## Timeline

- **Phase 1**: 2-4 hours (implement TCP, get tests passing)
- **Phase 2**: 1-2 days (fix QUIC compatibility)
- **Total**: Can have working tests today, full QUIC support in a few days

## Related Files

- `clients/python/geode_client/client.py` - Main client implementation
- `clients/python/geode_client/types.py` - Value types (✅ fixed)
- `clients/test-harness/run_tests.py` - Test runner (✅ fixed)
- `clients/test-harness/runners/python_runner.py` - Python test adapter
- `src/cli/main.zig` - Server connection handling

## Notes

The Go and Rust clients already work properly because they use quiche for QUIC, which is compatible with the server's quiche implementation. Python is the only client using a different QUIC library (aioquic), hence the compatibility issue.

---

**Status**: Partial fixes applied, TCP implementation needed next
**Priority**: High - blocks all Python client testing
**Assignee**: Claude Code
**Updated**: 2025-10-31
