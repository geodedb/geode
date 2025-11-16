const std = @import("std");
const MsQuic = @import("../../tools/zig-msquic/src/msquic_wrapper.zig");
const QuicStatus = MsQuic.QuicStatus;

// CANARY: REQ=REQ-ZIG-CLIENT-002; FEATURE="Zig Client v2"; ASPECT=ClientSideMsquic; STATUS=IMPL; OWNER=clients; UPDATED=2025-11-16
// Zig client using proper client-side msquic patterns from tools/zig-msquic

pub const GeodeClient = struct {
    allocator: std.mem.Allocator,
    msquic: *MsQuic.QUIC_API_TABLE,
    registration: MsQuic.HQUIC,
    configuration: MsQuic.HQUIC,
    connection: ?MsQuic.HQUIC = null,
    stream_ctx: ?*StreamContext = null,

    host: []const u8,
    port: u16,
    insecure: bool,

    const alpn_name = "geode/1".*;
    const alpn = MsQuic.QUIC_BUFFER{
        .Length = @sizeOf(@TypeOf(alpn_name)) - 1,
        .Buffer = @constCast(alpn_name[0..].ptr),
    };

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, insecure: bool) !GeodeClient {
        // Open MsQuic API
        var msquic: *MsQuic.QUIC_API_TABLE = undefined;
        const msquic_ptr: [*c]?*const anyopaque = @ptrCast(&msquic);
        if (QuicStatus.isError(MsQuic.MsQuicOpenVersion(MsQuic.QUIC_API_VERSION_2, msquic_ptr))) {
            return error.MsQuicOpenFailed;
        }
        errdefer MsQuic.MsQuicClose(msquic);

        // Create registration
        const app_name: [:0]const u8 = "geode-zig-client";
        const reg_config = MsQuic.QUIC_REGISTRATION_CONFIG{
            .AppName = @ptrCast(app_name.ptr),
            .ExecutionProfile = MsQuic.QUIC_EXECUTION_PROFILE_LOW_LATENCY,
        };
        var registration: MsQuic.HQUIC = undefined;
        if (QuicStatus.isError(msquic.RegistrationOpen.?(&reg_config, &registration))) {
            return error.RegistrationFailed;
        }
        errdefer msquic.RegistrationClose.?(registration);

        // Create configuration
        var configuration: MsQuic.HQUIC = undefined;
        var settings = std.mem.zeroes(MsQuic.QuicSettings);

        settings.IdleTimeoutMs = 30000;
        settings.IsSet.flags.IdleTimeoutMs = true;

        settings.PeerBidiStreamCount = 100;
        settings.IsSet.flags.PeerBidiStreamCount = true;

        if (QuicStatus.isError(msquic.ConfigurationOpen.?(registration, &alpn, 1, &settings, @sizeOf(@TypeOf(settings)), null, &configuration))) {
            return error.ConfigurationFailed;
        }
        errdefer msquic.ConfigurationClose.?(configuration);

        // Load client credentials
        var cred_config = std.mem.zeroes(MsQuic.QUIC_CREDENTIAL_CONFIG);
        cred_config.Flags = MsQuic.QUIC_CREDENTIAL_FLAG_CLIENT;
        if (insecure) {
            cred_config.Flags |= MsQuic.QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION;
        }

        const status = msquic.ConfigurationLoadCredential.?(configuration, &cred_config);
        if (QuicStatus.isError(status)) {
            return error.ConfigurationLoadCredentialFailed;
        }

        return GeodeClient{
            .allocator = allocator,
            .msquic = msquic,
            .registration = registration,
            .configuration = configuration,
            .host = host,
            .port = port,
            .insecure = insecure,
        };
    }

    pub fn connect(self: *GeodeClient) !void {
        // Open connection
        var conn: MsQuic.HQUIC = undefined;
        if (QuicStatus.isError(self.msquic.ConnectionOpen.?(
            self.registration,
            connectionCallback,
            self,
            &conn,
        ))) {
            return error.ConnectionOpenFailed;
        }
        self.connection = conn;
        errdefer {
            self.msquic.ConnectionShutdown.?(conn, MsQuic.QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0);
            self.connection = null;
        }

        // Open stream
        var stream_ctx = try self.allocator.create(StreamContext);
        stream_ctx.client = self;
        stream_ctx.handle = undefined;
        stream_ctx.allocator = self.allocator;
        stream_ctx.recv_buffer = .{};
        stream_ctx.mutex = .{};
        stream_ctx.connected = false;
        self.stream_ctx = stream_ctx;
        errdefer {
            self.allocator.destroy(stream_ctx);
            self.stream_ctx = null;
        }

        const stream_status = self.msquic.StreamOpen.?(
            conn,
            MsQuic.QUIC_STREAM_OPEN_FLAG_NONE,
            StreamContext.streamCallback,
            stream_ctx,
            &stream_ctx.handle,
        );
        if (QuicStatus.isError(stream_status)) {
            return error.StreamOpenFailed;
        }

        const start_status = self.msquic.StreamStart.?(stream_ctx.handle, MsQuic.QUIC_STREAM_START_FLAG_NONE);
        if (QuicStatus.isError(start_status)) {
            return error.StreamStartFailed;
        }

        // Start connection to server
        const conn_start_status = self.msquic.ConnectionStart.?(
            conn,
            self.configuration,
            MsQuic.QUIC_ADDRESS_FAMILY_UNSPEC,
            @ptrCast(self.host.ptr),
            self.port,
        );
        if (QuicStatus.isError(conn_start_status)) {
            return error.ConnectionStartFailed;
        }

        // Wait for connection to establish
        const timeout_ns: u64 = 10 * std.time.ns_per_s;
        const start = std.time.nanoTimestamp();
        while (std.time.nanoTimestamp() - start < timeout_ns) {
            stream_ctx.mutex.lock();
            const connected = stream_ctx.connected;
            stream_ctx.mutex.unlock();
            if (connected) return;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        return error.ConnectionTimeout;
    }

    pub fn sendMessage(self: *GeodeClient, message: []const u8) !void {
        const stream_ctx = self.stream_ctx orelse return error.NoStream;

        // Allocate buffer with newline
        const data = try self.allocator.alloc(u8, message.len + 1);
        defer self.allocator.free(data);
        @memcpy(data[0..message.len], message);
        data[message.len] = '\n';

        const buffer = MsQuic.QUIC_BUFFER{
            .Length = @intCast(data.len),
            .Buffer = data.ptr,
        };

        const status = self.msquic.StreamSend.?(
            stream_ctx.handle,
            &buffer,
            1,
            MsQuic.QUIC_SEND_FLAG_NONE,
            null,
        );

        if (QuicStatus.isError(status)) {
            return error.SendFailed;
        }

        // Give time for send to complete
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    pub fn receiveMessage(self: *GeodeClient) ![]u8 {
        const stream_ctx = self.stream_ctx orelse return error.NoStream;

        const timeout_ns: u64 = 30 * std.time.ns_per_s;
        const start = std.time.nanoTimestamp();

        while (std.time.nanoTimestamp() - start < timeout_ns) {
            stream_ctx.mutex.lock();

            // Look for newline in buffer
            for (stream_ctx.recv_buffer.items, 0..) |byte, i| {
                if (byte == '\n') {
                    // Found complete message
                    const msg = try self.allocator.alloc(u8, i);
                    @memcpy(msg, stream_ctx.recv_buffer.items[0..i]);

                    // Remove from buffer
                    if (i + 1 < stream_ctx.recv_buffer.items.len) {
                        std.mem.copyForwards(
                            u8,
                            stream_ctx.recv_buffer.items,
                            stream_ctx.recv_buffer.items[i + 1 ..],
                        );
                    }
                    const new_len = stream_ctx.recv_buffer.items.len - i - 1;
                    stream_ctx.recv_buffer.shrinkRetainingCapacity(new_len);

                    stream_ctx.mutex.unlock();
                    return msg;
                }
            }

            stream_ctx.mutex.unlock();
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
        if (self.stream_ctx) |ctx| {
            ctx.deinit();
            self.stream_ctx = null;
        }

        if (self.connection) |conn| {
            self.msquic.ConnectionShutdown.?(conn, MsQuic.QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0);
            self.connection = null;
        }

        self.msquic.ConfigurationClose.?(self.configuration);
        self.msquic.RegistrationClose.?(self.registration);
        MsQuic.MsQuicClose(self.msquic);
    }

    fn connectionCallback(
        connection: MsQuic.HQUIC,
        self_ptr: ?*anyopaque,
        event: [*c]MsQuic.struct_QUIC_CONNECTION_EVENT,
    ) callconv(.c) MsQuic.QUIC_STATUS {
        const self: *GeodeClient = @ptrCast(@alignCast(self_ptr));

        switch (event.*.Type) {
            MsQuic.QUIC_CONNECTION_EVENT_CONNECTED => {
                if (self.stream_ctx) |ctx| {
                    ctx.mutex.lock();
                    ctx.connected = true;
                    ctx.mutex.unlock();
                }
            },
            MsQuic.QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE => {
                if (!event.*.unnamed_0.SHUTDOWN_COMPLETE.AppCloseInProgress) {
                    self.msquic.ConnectionClose.?(connection);
                }
            },
            else => {},
        }

        return 0;
    }

    const StreamContext = struct {
        client: *GeodeClient,
        handle: MsQuic.HQUIC,
        allocator: std.mem.Allocator,
        recv_buffer: std.ArrayList(u8),
        mutex: std.Thread.Mutex = .{},
        connected: bool = false,

        pub fn deinit(self: *StreamContext) void {
            self.recv_buffer.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        fn streamCallback(
            stream: MsQuic.HQUIC,
            self_ptr: ?*anyopaque,
            event: [*c]MsQuic.struct_QUIC_STREAM_EVENT,
        ) callconv(.c) MsQuic.QUIC_STATUS {
            const self: *StreamContext = @ptrCast(@alignCast(self_ptr));

            switch (event.*.Type) {
                MsQuic.QUIC_STREAM_EVENT_RECEIVE => {
                    const buffer_count = event.*.unnamed_0.RECEIVE.BufferCount;
                    const buffers = event.*.unnamed_0.RECEIVE.Buffers;

                    self.mutex.lock();
                    defer self.mutex.unlock();

                    var i: u32 = 0;
                    while (i < buffer_count) : (i += 1) {
                        const buf = buffers[i];
                        const data = buf.Buffer[0..buf.Length];
                        self.recv_buffer.appendSlice(self.allocator, data) catch {
                            return MsQuic.QUIC_STATUS_OUT_OF_MEMORY;
                        };
                    }

                    // Tell MsQuic we consumed the data
                    const total_len = event.*.unnamed_0.RECEIVE.TotalBufferLength;
                    self.client.msquic.StreamReceiveComplete.?(stream, total_len);
                },
                MsQuic.QUIC_STREAM_EVENT_SEND_COMPLETE => {
                    // Send completed successfully
                },
                MsQuic.QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN => {
                    // Peer closed send side
                },
                MsQuic.QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE => {
                    // Stream shutdown complete
                },
                else => {},
            }

            return 0;
        }
    };
};

/// Helper function to execute a query
pub fn executeQuery(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    query: []const u8,
    params: ?std.json.Value,
    insecure: bool,
) !std.json.Parsed(std.json.Value) {
    var client = try GeodeClient.init(allocator, host, port, insecure);
    defer client.deinit();

    try client.connect();

    // Send HELLO
    try client.sendHello("geode-zig-client", "2.0.0");
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

    // Parse and return
    return try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bindings_response,
        .{},
    );
}
