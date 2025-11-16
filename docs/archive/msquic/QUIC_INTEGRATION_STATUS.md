# QUIC/TLS Integration - Current Status & Next Steps

**Date**: October 31, 2025
**Status**: Partial Fix Applied, Architecture Issue Identified

## Summary

Successfully identified and partially fixed the QUIC stream acceptance issue in the Geode server. However, discovered a fundamental architecture problem that needs to be resolved before full client integration can work.

## What We Fixed

### 1. Server Stream Acceptance Pattern ✅
**Problem**: Server was checking for streams with `hasIncomingStreams()` before calling `acceptStream()`
**Solution**: Changed to call `acceptStream()` directly in a retry loop (matching vendor/quic/cmd/quic-server.zig pattern)

**Commit**: `fix(server): improve acceptStream() pattern for QUIC connections`

### 2. Client Configuration ✅
**Problem**: Clients were using wrong port (8443 instead of 3141) and ALPN protocol
**Solution**: Updated all clients to use port 3141 and ALPN "geode/1"

**Files Updated**:
- `clients/python/geode_client/client.py`
- `clients/rust/src/lib.rs`, examples, README
- `vendor/quic/clients/python/test_client.py`

## Critical Issue Discovered ⚠️

### Thread-Based Connection Handling is Incompatible with QUIC

**Root Cause**: The current Geode server architecture spawns a separate thread for each connection handler:

```zig
// src/cli/main.zig:1058
const thread = std.Thread.spawn(.{}, handleQuicConnectionThread, .{ allocator, &quic_server, conn }) catch |err| {
    ...
};
thread.detach();
```

**Why This Fails**:
1. Connection handler thread waits for `handshakeComplete()` (line 604-621)
2. But handshake can only complete if the main loop continues polling the endpoint
3. Once thread is spawned, main loop goes back to accept() and stops polling
4. Handshake packets never get processed
5. Thread times out after 10 seconds

**Working Pattern** (from vendor/quic/cmd/quic-server.zig):
- Single-threaded event loop
- Continuously polls endpoint
- Tracks active connections in an ArrayList
- Processes ALL connections in each iteration
- No separate threads

## Required Architectural Changes

### Option 1: Single-Threaded Event Loop (RECOMMENDED)

Restructure the server to match `vendor/quic/cmd/quic-server.zig`:

```zig
// Pseudo-code for required change
while (true) {
    // Poll endpoint to drive all connections
    transport.poll(20) catch {};

    // Accept new connections
    while (transport.tryAccept()) |conn| {
        active_conns.append(conn);
    }

    // Process each active connection
    for (active_conns.items) |conn| {
        // Check if drained/closed
        if (conn.isDrained()) {
            // Remove and destroy
            continue;
        }

        // Try to accept a stream
        if (conn.acceptStream()) |stream_id| {
            // Read/write on this stream
            // Handle messages
        } else |err| {
            // No stream yet, continue to next connection
            continue;
        }
    }
}
```

**Benefits**:
- Matches working example
- All connections share main poll loop
- Handshakes complete properly
- Simpler concurrency model

**Challenges**:
- Requires restructuring connection handler
- Need to track connection state (which messages processed, etc.)
- May need buffering for partial messages

### Option 2: Thread Pool with Shared Endpoint Polling

Keep threads but have a dedicated polling thread:

```zig
// Main thread: Accept and delegate
// Polling thread: Continuously poll endpoint
// Handler threads: Wait for events from polling thread
```

**Benefits**:
- Can keep existing multi-threaded handler code
- Better CPU utilization

**Challenges**:
- More complex synchronization
- Need message passing between threads
- Harder to debug

## Immediate Next Steps

1. **Prototype Single-Threaded Event Loop** (4-6 hours)
   - Create a simplified version based on quic-server.zig
   - Test with single connection first
   - Verify handshake completes and streams work

2. **Port Connection Handler Logic** (2-3 hours)
   - Move message processing from thread to main loop
   - Add connection state tracking
   - Handle partial reads/writes

3. **Test with CLI Client** (1 hour)
   - Verify `geode query --server 127.0.0.1:3141 "RETURN 1"` works
   - Test multiple concurrent connections

4. **Update Client Libraries** (2-3 hours)
   - Ensure Python client follows aioquic patterns
   - Ensure Rust client follows quinn patterns
   - Test all clients

## Technical Details

### Current Code Locations

**Server Connection Handling**:
- Main loop: `src/cli/main.zig:1040-1070`
- Thread spawn: `src/cli/main.zig:1058`
- Handler function: `src/cli/main.zig:587-800+`

**QUIC Transport**:
- QuicServer implementation: `src/transport/quic.zig:214-350`
- acceptStream(): `src/transport/quic.zig:381-406`

**Working Examples**:
- Server: `vendor/quic/cmd/quic-server.zig`
- Client: `vendor/quic/cmd/quic-client.zig`

### Key API Functions

From `vendor/quic` library:
- `api.poll(endpoint, timeout_ms)` - Drive I/O and timers
- `api.tryAccept(endpoint)` - Get new connection (non-blocking)
- `api.acceptStream(conn)` - Get incoming stream ID
- `api.readStream(conn, stream_id, buf)` - Read from stream
- `api.writeStream(conn, stream_id, data)` - Write to stream
- `api.isDrained(conn)` - Check if connection is closed
- `api.handshakeComplete(conn)` - Check handshake state
- `api.handshakeDoneSeen(conn)` - Check HANDSHAKE_DONE frame

## Testing Strategy

### Phase 1: Minimal Working Server
- Single connection
- Echo "HELLO" message
- Verify end-to-end works

### Phase 2: Multiple Connections
- 5-10 concurrent connections
- Verify all complete successfully
- Check for resource leaks

### Phase 3: Full Protocol
- HELLO handshake
- RUN_GQL messages
- SCHEMA/DATA frames
- Error handling

### Phase 4: Client Libraries
- Python client with real queries
- Rust client with real queries
- Go client (if exists)

## Success Criteria

✅ Server accepts connections without spawning threads
✅ Handshake completes in < 1 second
✅ Streams are accepted and data flows
✅ `geode query --server` works
✅ Python client executes queries
✅ Rust client executes queries
✅ Multiple concurrent connections work
✅ No resource leaks or crashes

## Conclusion

The configuration fixes were successful, but the threaded connection handling architecture is fundamentally incompatible with QUIC's event-driven model. The server must be restructured to use a single-threaded event loop with continuous polling, matching the pattern in `vendor/quic/cmd/quic-server.zig`.

This is a significant but well-understood architectural change. The working example provides a clear blueprint, and the required changes are localized to the server's connection handling code.

---

*Last Updated*: 2025-10-31 15:15:00 UTC
*Author*: Claude Code
*Next Action*: Implement single-threaded event loop based on quic-server.zig
*Estimated Time*: 6-10 hours for complete working implementation
