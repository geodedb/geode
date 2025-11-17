const std = @import("std");
const builtin = @import("builtin");
const msquic_impl = @import("msquic.zig");

// CANARY: REQ=REQ-MSQUIC-003; FEATURE="MSQUIC_Migration"; ASPECT=Shim; STATUS=IMPL; OWNER=transport; UPDATED=2025-11-14
// Compatibility shim that provides the old vendor_quic API using msquic implementation

// Re-export the msquic implementation with vendor_quic compatible names
pub const QuicError = msquic_impl.QuicError;
pub const QuicTransport = msquic_impl.QuicTransport;
pub const QuicConnection = msquic_impl.QuicConnection;
pub const QuicStream = msquic_impl.QuicStream;
pub const QuicClient = msquic_impl.QuicClient;
pub const QuicClientStream = msquic_impl.QuicClientStream;

// Compatibility types that were used by the old implementation
pub const QuicEndpoint = msquic_impl.QuicTransport;
pub const QuicConfig = msquic_impl.QuicTransport.Config;
pub const QuicStreamId = usize;

// Compatibility functions to match old vendor_quic API

/// Initialize endpoint (compatibility wrapper)
pub fn endpointInit(allocator: *std.mem.Allocator, bind_addr: []const u8, config: *const QuicConfig) !*QuicTransport {
    _ = bind_addr; // Parsed from config

    var transport = try allocator.create(QuicTransport);
    errdefer allocator.destroy(transport);

    transport.* = try QuicTransport.init(allocator.*, config.*);
    try transport.listen();

    return transport;
}

/// Deinitialize endpoint
pub fn endpointDeinit(endpoint: *QuicTransport) void {
    endpoint.deinit();
    endpoint.allocator.destroy(endpoint);
}

/// Accept a connection
pub fn accept(endpoint: *QuicTransport) !*QuicConnection {
    return try endpoint.accept();
}

/// Try to accept a connection (non-blocking)
pub fn tryAccept(endpoint: *QuicTransport) ?*QuicConnection {
    return endpoint.tryAccept();
}

/// Poll endpoint for events
pub fn poll(endpoint: *QuicTransport, timeout_ms: u32) !void {
    try endpoint.poll(timeout_ms);
}

/// Flush endpoint
pub fn flush(endpoint: *QuicTransport, max_send: usize) void {
    _ = endpoint;
    _ = max_send;
    // msquic handles flushing internally
}

/// Check if connection has incoming streams
pub fn hasIncomingStreams(connection: *QuicConnection) bool {
    return connection.streams_init and connection.streams.items.len > 0;
}

/// Get first stream (compatibility)
pub fn getFirstStream(connection: *QuicConnection) ?QuicStreamId {
    if (connection.streams_init and connection.streams.items.len > 0) {
        return 0; // Return first stream ID
    }
    return null;
}

/// Accept a stream
pub fn acceptStream(connection: *QuicConnection) !QuicStreamId {
    _ = try connection.acceptStream();
    return connection.streams.items.len - 1;
}

/// Open a new stream
pub fn openStream(connection: *QuicConnection, bidirectional: bool) !QuicStreamId {
    _ = try connection.openStream(bidirectional);
    return connection.streams.items.len - 1;
}

/// Write to stream
pub fn writeStream(connection: *QuicConnection, stream_id: QuicStreamId, data: []const u8) !usize {
    if (!connection.streams_init or stream_id >= connection.streams.items.len) {
        return QuicError.StreamFailed;
    }

    const stream = connection.streams.items[stream_id];
    try stream.write(data);
    return data.len;
}

/// Read from stream
pub fn readStream(connection: *QuicConnection, stream_id: QuicStreamId, buf: []u8) !usize {
    if (!connection.streams_init or stream_id >= connection.streams.items.len) {
        return QuicError.StreamFailed;
    }

    const stream = connection.streams.items[stream_id];
    return try stream.read(buf);
}

/// Close a stream
pub fn closeStream(connection: *QuicConnection, stream_id: QuicStreamId, error_code: u64) !void {
    _ = error_code;

    if (!connection.streams_init or stream_id >= connection.streams.items.len) {
        return QuicError.StreamFailed;
    }

    const stream = connection.streams.items[stream_id];
    stream.close();
}

/// Check if connection is drained
pub fn isDrained(connection: *QuicConnection) bool {
    return connection.isDrained();
}

/// Check if handshake is confirmed
pub fn isHandshakeConfirmed(connection: *QuicConnection) bool {
    return connection.isHandshakeConfirmed();
}

/// Client connect
pub fn connect(endpoint: *QuicTransport, server_addr: []const u8, sni: []const u8) !*QuicConnection {
    _ = endpoint;
    _ = server_addr;
    _ = sni;
    // TODO: Implement client connection
    return QuicError.ConnectionFailed;
}

/// Close connection (simple)
pub fn closeConnectionSimple(connection: *QuicConnection) !void {
    connection.close();
}

/// Check if handshake is complete
pub fn handshakeComplete(connection: *QuicConnection) bool {
    return connection.isHandshakeConfirmed();
}

/// Check if handshake DONE was seen
pub fn handshakeDoneSeen(connection: *QuicConnection) bool {
    return connection.isHandshakeConfirmed();
}
