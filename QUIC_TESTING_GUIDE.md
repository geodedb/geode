# QUIC Testing Guide for Geode

## Quick Verification Tests

### Test 1: Basic Build and Server Startup
```bash
make build
./zig-out/bin/geode serve --listen 127.0.0.1:3141
```

Expected output:
```
✅ QUIC listener: 127.0.0.1:3141
✅ Server ready - accepting QUIC connections
DEBUG: Created epoll fd=4 and added socket fd=3
```

### Test 2: UDP Packet Reception (Netcat)
```bash
# Terminal 1: Start server
./zig-out/bin/geode serve --listen 127.0.0.1:3141 2>&1 | grep "recvfrom got"

# Terminal 2: Send test packet
echo "test" | nc -u -w1 127.0.0.1 3141
```

Expected: Server terminal shows `DEBUG: recvfrom got 5 bytes!`

### Test 3: Geodetestlab Quick Tests
```bash
make geodetestlab-quick
```

Expected: ~78-80% pass rate (40/51 tests)

## Comprehensive QUIC Test Suite

### Running Full Test Battery
```bash
cd quic_tests
go run comprehensive_quic.go
```

Tests included:
1. Basic Connection
2. Handshake Completion
3. Stream Creation
4. Data Transmission
5. Bidirectional Streams
6. Multiple Streams
7. Connection Close
8. Reconnection
9. Concurrent Connections
10. Large Data Transfer

**Note:** Currently, tests 1-10 will fail at connection stage due to quic-go handshake issue. This is expected and under investigation.

## Debugging QUIC Issues

### Enable Debug Logging
Server already has verbose debug logging enabled. Key messages to look for:

```
DEBUG: Created epoll fd=X and added socket fd=Y  # Epoll configured correctly
DEBUG: recvfrom got N bytes!                    # Packets being received
DEBUG: recvfrom returned WouldBlock              # No packets available
```

### Check Socket Status
```bash
# While server is running
ss -ulnp | grep 3141
```

Should show geode process listening on UDP port 3141.

### Packet Capture (Requires Root)
```bash
# Terminal 1: Capture packets
sudo tcpdump -i lo -n -vv udp port 3141 -w quic_debug.pcap

# Terminal 2: Start server
./zig-out/bin/geode serve --listen 127.0.0.1:3141

# Terminal 3: Run client
go run test_quic_connection.go

# Analyze capture
sudo tcpdump -r quic_debug.pcap -vv
```

### Analyzing Failures

#### Symptom: "recvfrom returned WouldBlock" continuously
**Cause:** Packets not reaching socket
**Check:**
1. Firewall rules: `sudo iptables -L | grep 3141`
2. Socket options: Check endpoint.zig:104-117
3. Packet capture: Verify packets actually sent

#### Symptom: "Connection timeout"
**Cause:** Handshake not completing
**Check:**
1. TLS certificates present: `ls -la data/server.{crt,key}`
2. Protocol version match
3. ALPN negotiation

#### Symptom: Build failures
**Cause:** Code changes breaking compilation
**Fix:** Verify changes against original vendor/quic code

## Test File Locations

```
├── quic_tests/
│   ├── comprehensive_quic.go       # Main test suite
│   └── run_quic_tests.sh          # Test runner
├── test_quic_connection.go        # Basic connection test
├── test_quic_detailed.go          # Detailed logging test
├── test_udp_simple.go             # Raw UDP test
├── test_raw_udp.go                # Another UDP test
└── run_comprehensive_quic_tests.sh # Main test runner
```

## Known Issues

### Issue #1: QUIC Handshake Timeout
**Status:** Under Investigation
**Symptom:** quic-go clients timeout during connection
**Workaround:** None currently
**Next Steps:** Packet capture analysis

### Issue #2: Comprehensive Test Suite Incomplete
**Status:** Partial Implementation
**Symptom:** Go compilation errors in test suite
**Workaround:** Use individual test files
**Next Steps:** Complete test suite implementation

## Regression Testing

### After Code Changes
Always run these tests after making changes to QUIC code:

```bash
# 1. Build test
make build

# 2. UDP reception test
echo "test" | nc -u -w1 127.0.0.1 3141

# 3. Geodetestlab quick test
make geodetestlab-quick

# 4. Manual QUIC connection test
go run test_quic_connection.go
```

Expected results:
- Test 1: ✅ Success
- Test 2: ✅ Should see "recvfrom got 5 bytes"
- Test 3: ✅ ~78-80% pass rate
- Test 4: ❌ Currently fails (known issue)

## Test Development

### Adding New Tests

1. Create test file in `quic_tests/`
2. Follow pattern from `comprehensive_quic.go`
3. Add to `run_quic_tests.sh`
4. Document in this file

### Test Criteria

All tests should:
- Have clear pass/fail criteria
- Include timeout handling
- Clean up resources
- Log meaningful error messages
- Be idempotent (can run multiple times)

## References

- **Fix Documentation:** `QUIC_HANDSHAKE_FIXES.md`
- **Comprehensive Report:** `QUIC_COMPREHENSIVE_FIX_REPORT.md`
- **Quick Summary:** `QUIC_FIXES_SUMMARY.md`
- **Vendor Library:** `vendor/quic/`
- **RFC 9000:** QUIC Protocol Specification
- **quic-go Docs:** https://github.com/quic-go/quic-go

---

**Last Updated:** October 8, 2025
**Maintainer:** See git log for contributors
**Status:** UDP reception working, QUIC handshake under investigation
