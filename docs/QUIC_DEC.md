# QUIC Session/Stream Issues - Decision Document

**Date**: December 22, 2025
**Status**: FIXED
**Resolution**: Implemented Option 3 (Debug Vendor Library). Restored missing Client Finished polling logic in handshake_integration.zig.
**Severity**: BLOCKER

## Executive Summary

The vendor QUIC library at `vendor/quic/` has a **fundamental TLS handshake completion issue** that prevents streams from being opened. All client implementations (Python/aioquic, Go/quic-go, Rust/quiche, and Zig native) fail to complete the QUIC handshake, making the library unusable for production without significant changes.

## Current Symptoms

### Observable Behavior

```
Server: conns=1, streams=0
Client: Handshake timeout after 30 seconds
```

All clients exhibit identical behavior pattern:
1. UDP connection established
2. Initial TLS handshake begins (ClientHello/ServerHello exchange starts)
3. Key derivation starts (hkdfExpand operations visible in debug logs)
4. **Handshake never completes**
5. `isHandshakeConfirmed()` never returns `true`
6. No application streams can be opened

### Technical Root Cause

The handshake confirmation requires **both** conditions to be true:

```zig
// From vendor/quic/src/quic/conn.zig:1353
pub fn hasConfirmedAppTxKeys(self: *const Connection) bool {
    return self.peer_finished_verified and self.app_tx_keys != null;
}
```

The issue: Either `peer_finished_verified` is never set to `true` OR `app_tx_keys` is never installed. This indicates a problem in the TLS 1.3/QUIC integration layer where:

- The server never receives/processes the client's TLS Finished message correctly, OR
- The client never receives the HANDSHAKE_DONE frame from the server, OR
- Application keys are never derived despite handshake progress

## Affected Components

### Server-Side (Geode)
- `src/transport/quic.zig` - QUIC transport wrapper
- `src/server/quic_connection_handler.zig` - Connection handling (polls for streams but none arrive)
- `src/server/main.zig` - Server entry point

### Client-Side
- `clients/zig/geode_client.zig` - Zig client using vendor QUIC
- `clients/python/` - Python client using aioquic (incompatible)
- `clients/go/` - Go client using quic-go (incompatible)
- `clients/rust/` - Rust client using quiche (likely incompatible)

### Vendor Library
- `vendor/quic/src/quic/conn.zig` - Connection state machine
- `vendor/quic/src/quic/endpoint.zig` - Endpoint management
- `vendor/ztls/` - TLS 1.3 implementation

## Evidence Summary

### Test Results

| Client | Server | Result | Error |
|--------|--------|--------|-------|
| aioquic (Python) | Geode | FAILED | "Decryption key is not available" |
| Vendor Python | Vendor Reference | FAILED | Same handshake failure |
| quic-go (Go) | Geode | FAILED | "timeout: handshake did not complete" |
| quic-go (Go) | Vendor Reference | FAILED | Same timeout |
| Zig Native | Geode | FAILED | `HandshakeError` after timeout |

### Key Evidence
1. **Cross-implementation failure**: All standard QUIC clients fail identically
2. **Vendor self-test failure**: Vendor's own Python client fails against vendor's reference server
3. **RFC compliance gap**: Likely RFC 9001 (QUIC-TLS) compliance issues

## Solution Options

### Option 1: Replace Vendor QUIC Library (RECOMMENDED)

**Description**: Replace `vendor/quic/` with a battle-tested QUIC implementation.

**Candidates**:
- **quiche** (Cloudflare, Rust/C) - Most widely tested, production-ready
- **msquic** (Microsoft, C) - Excellent Windows integration, stable
- **lsquic** (LiteSpeed, C) - High performance, proven at scale

**Implementation**:
```
1. Select library (recommend quiche for cross-platform)
2. Create FFI bindings or wrapper layer
3. Refactor src/transport/quic.zig for new API
4. Update build.zig for new dependencies
5. Update all client libraries
```

**Pros**:
- Guaranteed compatibility with standard clients
- Better documentation and community support
- Regular security patches
- Known performance characteristics

**Cons**:
- Requires refactoring transport layer
- FFI complexity for non-Zig libraries
- Significant integration effort

**Effort**: 2-3 weeks
**Risk**: Low (well-tested libraries)

### Option 2: Switch to TCP Transport

**Description**: Use TCP with TLS 1.3 instead of QUIC.

**Implementation**:
```
1. Add TCP transport layer in src/transport/tcp.zig
2. Configure TLS 1.3 using std.crypto or existing ztls
3. Update server to listen on both QUIC and TCP
4. Update clients to use TCP
```

**Pros**:
- Works immediately
- Simpler implementation
- Universal client compatibility
- No external dependencies

**Cons**:
- Lose QUIC benefits (0-RTT, multiplexing, connection migration)
- Head-of-line blocking
- Less modern

**Effort**: 1 week
**Risk**: Very low

### Option 3: Debug Vendor Library

**Description**: Deep dive into vendor library to fix TLS handshake issues.

**Areas to Investigate**:
1. `vendor/ztls/` TLS 1.3 state machine
2. CRYPTO frame processing in `vendor/quic/src/quic/conn.zig`
3. Key derivation in `vendor/quic/src/quic/crypto_quic.zig`
4. Handshake callback wiring in `endpoint/handshake_integration.zig`

**Pros**:
- Keeps existing investment
- Full control over implementation

**Cons**:
- Extremely time-consuming
- Requires deep TLS 1.3 + QUIC expertise
- No guarantee of success
- May require architectural rewrite

**Effort**: 3-6 weeks minimum
**Risk**: Very high

### Option 4: Hybrid Approach

**Description**: TCP for immediate functionality, plan QUIC replacement for future.

**Phases**:
1. **Phase 1 (Week 1)**: Implement TCP transport, unblock development
2. **Phase 2 (Weeks 2-4)**: Evaluate and integrate proper QUIC library
3. **Phase 3**: Deprecate TCP once QUIC is stable

**Pros**:
- Unblocks development immediately
- Allows proper evaluation of QUIC options
- Minimizes risk while maximizing flexibility

**Cons**:
- Two migrations instead of one
- Temporary technical debt

**Effort**: 1 week TCP + 2-3 weeks QUIC later
**Risk**: Low

## Recommendation

**Primary**: Option 4 (Hybrid Approach) or Option 1 (Replace QUIC Library)

If immediate unblocking is critical, use Option 4 to get TCP working now while properly evaluating QUIC library replacements.

If time permits for a proper fix, use Option 1 with **quiche** as the replacement library due to its:
- Extensive interoperability testing
- Active maintenance by Cloudflare
- Pure Rust with stable C API
- Production use in major browsers (Chrome, Firefox)

**DO NOT** pursue Option 3 (debugging vendor library) without significant time budget and QUIC/TLS expertise.

## Related Files

### Documentation
- `vendor/quic/VENDOR_QUIC_INCOMPATIBILITY_CRITICAL.md` - Full investigation details
- `vendor/quic/1RTT_FAILURE_REPORT.md` - 1-RTT key failure analysis
- `vendor/quic/E2E_TEST_INVESTIGATION.md` - End-to-end test investigation
- `vendor/quic/CLAUDE.md` - QUIC codebase guide

### Critical Code Paths
- `vendor/quic/src/quic/conn.zig:1353` - `hasConfirmedAppTxKeys()`
- `vendor/quic/src/quic/api.zig:162` - `isHandshakeConfirmed()`
- `vendor/quic/src/quic/endpoint/handshake_integration.zig` - TLS integration

### Test Files
- `vendor/quic/tests/integration/rfc9000_section7.zig` - Handshake tests
- `vendor/quic/tests/test_conn_peer_finished.zig` - Peer finished verification

## Action Items

1. [ ] **Decision Required**: Choose solution option (1, 2, or 4)
2. [ ] **If Option 1/4**: Evaluate quiche vs msquic integration complexity
3. [ ] **If Option 2/4**: Design TCP transport interface
4. [ ] **If Option 4**: Define Phase 1 TCP scope
5. [ ] **Update geodetestlab**: Adjust test expectations based on chosen approach

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2025-12-22 | Claude | Created document, consolidated investigation findings |
| 2025-10-31 | Claude | Original investigation (VENDOR_QUIC_INCOMPATIBILITY_CRITICAL.md) |

---

*This document tracks the QUIC handshake issue affecting Geode database connectivity.*
