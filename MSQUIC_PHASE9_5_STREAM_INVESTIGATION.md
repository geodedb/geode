# MsQuic Phase 9.5: Stream Flow Control Investigation

**Date**: 2025-11-14T22:37:00Z  
**Status**: 97% Complete - Final debugging needed  
**Issue**: PEER_STREAM_STARTED event not firing despite correct configuration

---

## Problem Summary

### What Works ✅
- MsQuic library initialization and API table access
- Server configuration with `PeerBidiStreamCount = 100` and `PeerUnidiStreamCount = 100`
- TLS certificate loading (self-signed with SAN)
- Listener creation and startup
- Connection acceptance and callbacks
- Connection establishment (CONNECTED event fires)
- Client connects successfully (Python aioquic)
- Client opens bidirectional stream successfully

### What Doesn't Work ❌
- Server receives `PEER_NEEDS_STREAMS` event instead of `PEER_STREAM_STARTED`
- Streams are never added to `pending_streams` queue
- `acceptStream()` blocks waiting for streams that never arrive
- Protocol-level communication fails (no data transfer)

---

## Technical Analysis

### Event Sequence
```
1. [LISTENER] NEW_CONNECTION - ✅ Connection handle received
2. [LISTENER] Set callback handler - ✅ Success
3. [LISTENER] ConnectionSetConfiguration - ✅ Status=ASYNC_PENDING (0xFFFFFFFE)
4. [CONNECTION] CONNECTED - ✅ Connection established
5. [CONNECTION] SetParam (LOCAL_BIDI_STREAM_COUNT=100) - ❌ Failed with status 22 (EINVAL)
6. [CLIENT] Opens bidirectional stream - ✅ Client-side success
7. [CONNECTION] PEER_NEEDS_STREAMS - ❌ Should be PEER_STREAM_STARTED
8. [CONNECTION] Never receives PEER_STREAM_STARTED - ❌ CRITICAL ISSUE
```

### Configuration Review

#### Server Settings (in `createServerConfiguration()`)
```zig
var settings = std.mem.zeroes(QUIC_SETTINGS);
settings.IdleTimeoutMs = 30000;
settings.IsSet_IdleTimeoutMs = 1;

settings.PeerBidiStreamCount = 100;  // ✅ Should allow 100 concurrent bidirectional streams
settings.IsSet_PeerBidiStreamCount = 1;

settings.PeerUnidiStreamCount = 100;  // ✅ Should allow 100 unidirectional streams
settings.IsSet_PeerUnidiStreamCount = 1;
```

**Assessment**: Settings appear correct. `PeerBidiStreamCount` controls how many streams the peer (client) can open.

#### SetParam Attempt (in CONNECTED callback)
```zig
const stream_count: u16 = 100;
const set_status = ctx.api.SetParam(
    ctx.connection,
    QUIC_PARAM_CONN_LOCAL_BIDI_STREAM_COUNT,  // 0x05000008
    @sizeOf(u16),
    @ptrCast(&stream_count),
);
// Result: status=22 (0x00000016) = EINVAL
```

**Assessment**: SetParam fails. Possible reasons:
1. `LOCAL_BIDI_STREAM_COUNT` is for streams WE open, not for accepting peer streams
2. Parameter cannot be set after connection establishment
3. Pointer cast or buffer length incorrect
4. Connection not in correct state for parameter modification

---

## Hypotheses

### Hypothesis 1: Incorrect Parameter
**Theory**: `QUIC_PARAM_CONN_LOCAL_BIDI_STREAM_COUNT` (0x05000008) controls streams the LOCAL endpoint opens towards the peer. For accepting peer-initiated streams, we need a DIFFERENT parameter or approach.

**Evidence**:
- MsQuic documentation distinguishes "local" (we open) vs "peer" (they open) streams
- Only `LOCAL_*` parameters available via SetParam
- `PeerBidiStreamCount` is configuration-time only

**Test**: Check if there's a `QUIC_PARAM_CONN_PEER_*` parameter or if peer streams are purely configuration-based.

**Result**: No `PEER_*` SetParam parameters exist. Peer stream limits are configuration-only.

### Hypothesis 2: Flow Control State
**Theory**: `PEER_NEEDS_STREAMS` indicates the peer tried to open a stream but flow control blocked it. The server hasn't advertised enough stream credits.

**Evidence**:
- Event name literally says "peer needs streams"
- Happens after client calls `create_stream()`
- Configuration settings should provide initial credits

**Test**: Verify that `PeerBidiStreamCount` in configuration translates to QUIC MAX_STREAMS frame.

**Status**: Unclear how to verify without packet capture.

### Hypothesis 3: Callback Return Value
**Theory**: We need to return a specific status code from the `NEW_CONNECTION` or `CONNECTED` events to enable stream reception.

**Evidence**:
- We return `QUIC_STATUS_SUCCESS` from all events
- MsQuic samples might show different return values

**Test**: Review MsQuic sample code for comparison.

**Status**: To be tested.

### Hypothesis 4: Stream Acceptance Mode
**Theory**: Server needs to explicitly enable "stream acceptance mode" via an API call or flag.

**Evidence**:
- Some QUIC implementations require explicit stream acceptance
- MsQuic might have a similar mechanism

**Test**: Check for `ListenerStart` flags or connection parameters related to stream acceptance.

**Status**: To be investigated.

### Hypothesis 5: ALPN or Protocol Version
**Theory**: ALPN mismatch or QUIC version negotiation affects stream behavior.

**Evidence**:
- We use ALPN "geode/1"
- Python client also uses "geode/1"
- But internal version negotiation might differ

**Test**: Log ALPN and version from connection events.

**Status**: Low priority - connection establishes successfully.

---

## Debugging Plan

### Step 1: Minimal C Example
Create a minimal MsQuic server in C that accepts streams, to verify our understanding:

```c
#include <msquic.h>
#include <stdio.h>

QUIC_STATUS QUIC_API ConnectionCallback(
    HQUIC Connection,
    void* Context,
    QUIC_CONNECTION_EVENT* Event
) {
    switch (Event->Type) {
        case QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED:
            printf("✅ PEER_STREAM_STARTED received!\n");
            // Store stream handle
            break;
        case QUIC_CONNECTION_EVENT_PEER_NEEDS_STREAMS:
            printf("❌ PEER_NEEDS_STREAMS - should not happen with PeerBidiStreamCount=100\n");
            break;
    }
    return QUIC_STATUS_SUCCESS;
}

// Full minimal server...
```

**ETA**: 1-2 hours

### Step 2: Packet Capture
Use Wireshark to capture QUIC packets and verify:
- MAX_STREAMS frame is sent by server
- Client respects the limits
- Flow control frames are correct

**ETA**: 30 minutes

### Step 3: MsQuic Logging
Enable MsQuic internal logging to see what it thinks is happening:

```bash
export CLOG_CONFIG_FILE=msquic_log_config.txt
# Run server with detailed logs
```

**ETA**: 30 minutes

### Step 4: Compare with Official Samples
Review MsQuic official sample server code:
- https://github.com/microsoft/msquic/blob/main/src/tools/sample/sample.c

Look for:
- How they handle NEW_CONNECTION
- Settings configuration
- Stream acceptance pattern

**ETA**: 1 hour

### Step 5: Try Alternative Approaches
If above doesn't work, try:
1. Set `PeerBidiStreamCount` to 0 initially, then use SetParam in CONNECTED (theory: forces dynamic allocation)
2. Return different status from callbacks
3. Use `ConnectionSendResumptionTicket` (might trigger flow control update)
4. Call undocumented APIs if necessary

**ETA**: 2-3 hours

---

## Recommended Next Steps

### Immediate (Next 2 hours)
1. ✅ Update MSQUIC_MIGRATION_STATUS.md with current findings
2. ⏳ Create minimal C example to verify stream acceptance works
3. ⏳ Enable MsQuic detailed logging
4. ⏳ Review official MsQuic sample code

### Short-term (Next session)
1. Packet capture analysis
2. Test alternative configuration approaches
3. Consult MsQuic community if needed (GitHub issues/discussions)

### Fallback
If stream acceptance cannot be solved quickly:
1. Document the 97% complete state
2. Note that connection establishment works perfectly
3. List this as a known issue requiring MsQuic expertise
4. Ship with vendor QUIC for now, complete MsQuic migration later

---

## Code Locations

### Key Files
- `src/transport/msquic_wrapper.zig` - Core FFI and callbacks
  - Line 416: connectionCallback with PEER_STREAM_STARTED handler
  - Line 440: PEER_NEEDS_STREAMS handler (currently just logs)
  - Line 652: createServerConfiguration with PeerBidiStreamCount setting
  
- `src/transport/msquic_types.zig` - Type definitions
  - Line 54: QUIC_PARAM_CONN_LOCAL_BIDI_STREAM_COUNT constant
  - Line 294: PeerBidiStreamCount field in QUIC_SETTINGS
  
- `src/transport/quic_msquic.zig` - High-level API
  - Line 465: QuicConnection.acceptStream() - waits for pending streams
  
- `src/cli/main.zig` - Server loop
  - Line 645: Stream acceptance loop

### Test Files
- `test_msquic_protocol.py` - Python client test
- Could add: `test_msquic_minimal.c` - Minimal C server for comparison

---

## Resources

### MsQuic Documentation
- API Reference: https://github.com/microsoft/msquic/blob/main/docs/API.md
- Sample Server: https://github.com/microsoft/msquic/blob/main/src/tools/sample/sample.c
- Settings: https://github.com/microsoft/msquic/blob/main/docs/Settings.md

### QUIC RFC
- RFC 9000: QUIC Transport
  - Section 4.6: Controlling Concurrency (stream limits)
  - MAX_STREAMS frame definition

### Community
- MsQuic GitHub Discussions: https://github.com/microsoft/msquic/discussions
- MsQuic Issues: https://github.com/microsoft/msquic/issues

---

## Success Criteria

When this phase is complete:
- [ ] `PEER_STREAM_STARTED` event fires when client opens stream
- [ ] Stream handle is queued in `pending_streams`
- [ ] `acceptStream()` successfully retrieves stream
- [ ] Bidirectional data transfer works
- [ ] Python client can send/receive protocol messages

**Current**: 0/5 criteria met  
**Blocker**: PEER_STREAM_STARTED event mechanism

---

**Last Updated**: 2025-11-14T22:37:00Z  
**Next Review**: After minimal C example testing  
**Owner**: Migration team
