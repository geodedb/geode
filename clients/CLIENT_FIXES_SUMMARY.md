# Client Test Failures - Analysis and Fixes

## Test Run Date: November 4, 2025

## Overall Test Results

**Status**: All clients failing with multiple issues
- **Python**: Connection failures (Error 266 - QUIC transport error)
- **Go**: Timeouts (5+ seconds per test)
- **Rust**: Build failure (BoringSSL compilation in Nix)
- **Zig**: Runtime error (test spec parsing issue)

## Certificate Requirements

**CRITICAL**: Server MUST run with certificates (TLS required)
- Certificates exist in `clients/test-harness/certs/`
- CA: `ca.crt` (for client trust)
- Server: `server.crt` + `server.key`
- Clients must be configured to trust `ca.crt`

---

## 1. Zig Client Issues

### Issue 1a: Compilation Error (FIXED)
**Location**: `clients/test-harness/runners/zig_runner.zig:252`
**Error**: `member function expected 1 argument(s), found 0`
**Root Cause**: Changed from `initCapacity(allocator, 0)` to `init(allocator)`
**Status**: ✅ FIXED

### Issue 1b: Runtime Error (IN PROGRESS)
**Error**: `Error: 'tests' must be a list`
**Location**: Line 188-190
**Root Cause**: Test spec parsing - the YAML/JSON parser is not recognizing the `tests` field as a list
**Investigation Needed**: Check how test specs are being created by `run_tests.py` and verify YAML structure

---

## 2. Python Client Issues

### Issue 2a: QUIC Error 266
**Error**: `[{request_id}] Error: 266, reason: , frame_type: 6`
**Root Cause**: QUIC CRYPTO_ERROR (266) during TLS handshake
**Likely Cause**: Certificate validation failing or ALPN mismatch

**Current Configuration**:
- ALPN: `geode/1` ✅ (matches server)
- Server expects: `geode/1` ✅
- Certificates: Using `skip_verify=True` ⚠️

**Fix Required**:
1. Configure Python client to use proper certificates from `clients/test-harness/certs/ca.crt`
2. Update `python_runner.py` to pass certificate path to client
3. Server must be started with certificates: `server.crt` + `server.key`

### Issue 2b: JSON Parsing Errors
**Error**: `Expecting value: line 1 column 2 (char 1)`
**Context**: Only on some tests (e.g., `login-invalid-password`)
**Root Cause**: Server returning empty or malformed JSON response

---

## 3. Go Client Issues

### Issue 3a: Timeouts
**Error**: `Test timed out` after 5 seconds
**Root Cause**: Client not connecting or not receiving responses
**Investigation Needed**:
- Check if Go client is using correct ALPN (`geode/1`)
- Verify certificate configuration
- Check if QUIC connection is being established

**Expected Fix**:
1. Update Go client to use certificates from test harness
2. Verify ALPN configuration matches server
3. Check timeout values (currently 5s may be too short for some operations)

---

## 4. Rust Client Issues

### Issue 4a: BoringSSL Build Failure
**Error**: `fatal error: stdlib.h: No such file or directory`
**Root Cause**: BoringSSL (boring-sys) trying to compile in Nix environment without proper C++ stdlib
**Impact**: Rust client cannot be built at all

**Solutions**:
1. **Recommended**: Switch from `boring` to `quinn` QUIC library
   - quinn is pure Rust, no C++ dependencies
   - Better Nix compatibility
   - Reference: `vendor/quic/test-clients/quinn-client/`

2. **Alternative**: Fix Nix environment for BoringSSL (complex, not recommended)

---

## Recommended Fix Order

1. **Zig Client** (Quick win)
   - Fix test spec parsing issue
   - Test compilation fix works properly

2. **Rust Client** (High impact)
   - Switch to quinn library
   - Use quinn-client from vendor as reference

3. **Python Client** (Critical path)
   - Fix certificate configuration
   - Update test runner to use ca.crt
   - Verify QUIC Error 266 is resolved

4. **Go Client** (Dependent on Python)
   - Apply same certificate fixes as Python
   - Verify ALPN and timeouts
   - Test with working server

---

## Server Configuration Requirements

The test harness server MUST be started with:
```bash
./zig-out/bin/geode serve \
  --listen 0.0.0.0:PORT \
  --cert clients/test-harness/certs/server.crt \
  --key clients/test-harness/certs/server.key
```

## Client Configuration Requirements

All clients must:
1. Use ALPN: `geode/1`
2. Trust CA: `clients/test-harness/certs/ca.crt`
3. Connect to `localhost:PORT` with TLS enabled

---

## Reference Implementations

Working QUIC client examples in `vendor/quic/test-clients/`:
- `aioquic-client/test_client.py` - Python aioquic
- `quic-go-client/main.go` - Go quic-go
- `quinn-client/` - Rust quinn

Key configurations from working examples:
- Python aioquic: `alpn_protocols=["quic-zig/1"]`, `verify_mode=0`
- Go quic-go: `NextProtos: []string{"hq-interop"}`, `InsecureSkipVerify: true`

**Note**: Test clients use different ALPN protocols for interop testing. Geode clients must use `geode/1`.

---

## Next Steps

1. Complete Zig client fix and verify it builds
2. Switch Rust client to quinn
3. Fix Python client certificate handling
4. Fix Go client based on Python fixes
5. Run full test suite with certificates properly configured
