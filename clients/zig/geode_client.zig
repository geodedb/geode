const std = @import("std");
const builtin = @import("builtin");

// Import msquic from server's transport layer
// These imports are provided by the build system
const msquic_wrapper = @import("../../src/transport/msquic_wrapper");
const msquic_types = @import("../../src/transport/msquic_types");

// Re-export useful types
pub const HQUIC = msquic_types.HQUIC;
pub const QUIC_STATUS = msquic_types.QUIC_STATUS;

// CANARY: REQ=REQ-ZIG-CLIENT-001; FEATURE="Zig Client"; ASPECT=MsquicIntegration; STATUS=IMPL; OWNER=clients; UPDATED=2025-11-15
// Zig client using msquic for guaranteed server compatibility

/// GeodeClient provides a QUIC-based client for connecting to Geode servers
pub const GeodeClient = struct {
    allocator: std.mem.Allocator,
    msquic: ?*msquic_wrapper.MsQuic = null,
    connection: HQUIC = null,
    conn_ctx: ?*msquic_wrapper.ConnectionContext = null,
    stream: HQUIC = null,
    stream_ctx: ?*msquic_wrapper.StreamContext = null,
    host: []const u8,
    port: u16,
    insecure: bool,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, insecure: bool) GeodeClient {
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
            .insecure = insecure,
        };
    }

    pub fn connect(self: *GeodeClient) !void {
        // Initialize msquic
        self.msquic = try msquic_wrapper.MsQuic.init(self.allocator);
        errdefer if (self.msquic) |mq| mq.deinit();

        // Create client configuration
        try self.msquic.?.createClientConfiguration("geode/1", self.insecure);

        // Create connection context
        self.conn_ctx = try msquic_wrapper.ConnectionContext.init(self.allocator, self.msquic.?.api, null);
        errdefer if (self.conn_ctx) |ctx| ctx.deinit();

        // Open connection
        const open_status = self.msquic.?.api.ConnectionOpen(
            self.msquic.?.registration,
            msquic_wrapper.connectionCallback,
            self.conn_ctx,
            &self.connection,
        );

        if (msquic_wrapper.QUIC_FAILED(open_status)) {
            return error.ConnectionOpenFailed;
        }

        // Start connection
        var addr_buf: [256]u8 = undefined;
        const addr_z = try std.fmt.bufPrintZ(&addr_buf, "{s}", .{self.host});

        const start_status = self.msquic.?.api.ConnectionStart(
            self.connection,
            self.msquic.?.configuration,
            2, // AF_INET
            addr_z.ptr,
            self.port,
        );

        if (start_status != msquic_types.QUIC_STATUS_SUCCESS and
            start_status != msquic_types.QUIC_STATUS_PENDING)
        {
            return error.ConnectionStartFailed;
        }

        // Wait for connection to complete
        try self.waitForConnection(10); // 10 second timeout
    }

    fn waitForConnection(self: *GeodeClient, timeout_secs: u32) !void {
        const ctx = self.conn_ctx orelse return error.NoContext;
        const timeout_ns = @as(u64, timeout_secs) * std.time.ns_per_s;
        const start = std.time.nanoTimestamp();

        while (std.time.nanoTimestamp() - start < timeout_ns) {
            ctx.mutex.lock();
            const connected = ctx.connected;
            ctx.mutex.unlock();

            if (connected) return;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        return error.ConnectionTimeout;
    }

    pub fn openStream(self: *GeodeClient) !void {
        const mq = self.msquic orelse return error.NotConnected;

        // Create stream context
        self.stream_ctx = try msquic_wrapper.StreamContext.init(self.allocator);
        errdefer if (self.stream_ctx) |ctx| ctx.deinit();

        // Open bidirectional stream
        const open_status = mq.api.StreamOpen(
            self.connection,
            0, // Bidirectional
            msquic_wrapper.streamCallback,
            self.stream_ctx,
            &self.stream,
        );

        if (msquic_wrapper.QUIC_FAILED(open_status)) {
            return error.StreamOpenFailed;
        }

        // Start the stream
        const start_status = mq.api.StreamStart(
            self.stream,
            1, // QUIC_STREAM_START_FLAG_IMMEDIATE
        );

        if (msquic_wrapper.QUIC_FAILED(start_status)) {
            return error.StreamStartFailed;
        }
    }

    pub fn sendMessage(self: *GeodeClient, message: []const u8) !void {
        const mq = self.msquic orelse return error.NotConnected;
        const stream = self.stream orelse return error.NoStream;

        // Allocate buffer for message + newline
        const data = try self.allocator.alloc(u8, message.len + 1);
        defer self.allocator.free(data);

        @memcpy(data[0..message.len], message);
        data[message.len] = '\n';

        var buffer = msquic_types.QUIC_BUFFER{
            .Length = @intCast(data.len),
            .Buffer = data.ptr,
        };

        const status = mq.api.StreamSend(
            stream,
            @ptrCast(&buffer),
            1,
            0, // QUIC_SEND_FLAG_NONE
            null,
        );

        if (msquic_wrapper.QUIC_FAILED(status)) {
            return error.SendFailed;
        }

        // Give time for send to complete
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    pub fn receiveMessage(self: *GeodeClient) ![]u8 {
        const ctx = self.stream_ctx orelse return error.NoStream;

        var result = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        errdefer result.deinit(self.allocator);

        const timeout_ns: u64 = 30 * std.time.ns_per_s; // 30 second timeout
        const start = std.time.nanoTimestamp();

        while (std.time.nanoTimestamp() - start < timeout_ns) {
            ctx.mutex.lock();

            // Look for newline in receive buffer
            for (ctx.recv_buffer.items, 0..) |byte, i| {
                if (byte == '\n') {
                    // Found complete message
                    try result.appendSlice(self.allocator, ctx.recv_buffer.items[0..i]);

                    // Remove message from buffer
                    if (i + 1 < ctx.recv_buffer.items.len) {
                        std.mem.copyForwards(
                            u8,
                            ctx.recv_buffer.items,
                            ctx.recv_buffer.items[i + 1..],
                        );
                    }
                    ctx.recv_buffer.shrinkRetainingCapacity(ctx.recv_buffer.items.len - i - 1);

                    ctx.mutex.unlock();
                    return result.toOwnedSlice(self.allocator);
                }
            }

            ctx.mutex.unlock();

            // No complete message yet, wait a bit
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        return error.ReceiveTimeout;
    }

    pub fn sendHello(self: *GeodeClient, client_name: []const u8, client_version: []const u8) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"type\":\"HELLO\",\"client_name\":\"{s}\",\"client_ver\":\"{s}\",\"wanted_conformance\":\"minimum\"}}",
            .{ client_name, client_version },
        );
        defer self.allocator.free(msg);

        try self.sendMessage(msg);
    }

    pub fn sendRunGql(self: *GeodeClient, request_id: []const u8, query: []const u8, params: ?std.json.Value) !void {
        const params_json = if (params) |p|
            try std.json.Stringify.valueAlloc(self.allocator, p, .{})
        else
            try self.allocator.dupe(u8, "null");
        defer self.allocator.free(params_json);

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"type\":\"RUN_GQL\",\"request_id\":\"{s}\",\"text\":\"{s}\",\"params\":{s}}}",
            .{ request_id, query, params_json },
        );
        defer self.allocator.free(msg);

        try self.sendMessage(msg);
    }

    pub fn sendPull(self: *GeodeClient, request_id: []const u8, page_size: usize) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"type\":\"PULL\",\"request_id\":\"{s}\",\"page_size\":{d}}}",
            .{ request_id, page_size },
        );
        defer self.allocator.free(msg);

        try self.sendMessage(msg);
    }

    pub fn sendBegin(self: *GeodeClient) !void {
        try self.sendMessage("{\"type\":\"BEGIN\"}");
    }

    pub fn sendCommit(self: *GeodeClient) !void {
        try self.sendMessage("{\"type\":\"COMMIT\"}");
    }

    pub fn sendRollback(self: *GeodeClient) !void {
        try self.sendMessage("{\"type\":\"ROLLBACK\"}");
    }

    pub fn deinit(self: *GeodeClient) void {
        if (self.stream) |stream| {
            if (self.msquic) |mq| {
                mq.api.StreamClose(stream);
            }
            self.stream = null;
        }

        if (self.stream_ctx) |ctx| {
            ctx.deinit();
            self.stream_ctx = null;
        }

        if (self.connection) |conn| {
            if (self.msquic) |mq| {
                mq.api.ConnectionClose(conn);
            }
            self.connection = null;
        }

        if (self.conn_ctx) |ctx| {
            ctx.deinit();
            self.conn_ctx = null;
        }

        if (self.msquic) |mq| {
            mq.deinit();
            self.msquic = null;
        }
    }
};

/// Simple query execution helper
pub fn executeQuery(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    query: []const u8,
    params: ?std.json.Value,
    insecure: bool,
) !std.json.Parsed(std.json.Value) {
    var client = GeodeClient.init(allocator, host, port, insecure);
    defer client.deinit();

    try client.connect();
    try client.openStream();

    // Send HELLO
    try client.sendHello("geode-zig-client", "1.0.0");
    const hello_response = try client.receiveMessage();
    defer allocator.free(hello_response);

    // Send query
    const request_id = "req_1";
    try client.sendRunGql(request_id, query, params);
    const schema_response = try client.receiveMessage();
    defer allocator.free(schema_response);

    // Pull results
    try client.sendPull(request_id, 1000);
    const bindings_response = try client.receiveMessage();

    // Parse and return results
    return try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bindings_response,
        .{},
    );
}
