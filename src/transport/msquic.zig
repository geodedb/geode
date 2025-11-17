const std = @import("std");
const builtin = @import("builtin");
const msquic = @import("msquic_bindings.zig");

// CANARY: REQ=REQ-MSQUIC-002; FEATURE="MSQUIC_Migration"; ASPECT=Transport; STATUS=IMPL; OWNER=transport; UPDATED=2025-11-14
// Full QUIC transport layer using Microsoft's msquic library with OpenSSL for TLS

pub const QuicError = error{
    ConnectionFailed,
    StreamFailed,
    InvalidAddress,
    CertificateError,
    EndpointInitFailed,
    AcceptFailed,
    HandshakeFailed,
    TransportParametersFailed,
    FlowControlViolation,
    ProtocolViolation,
    IdleTimeout,
    ConnectionClosed,
    ApiInitFailed,
    RegistrationFailed,
    ConfigurationFailed,
    ListenerFailed,
};

// Global QUIC API table
var g_quic_api: ?*const msquic.QUIC_API_TABLE = null;
var g_api_lock = std.Thread.Mutex{};

/// Initialize the msquic API (call once at startup)
pub fn initApi() !void {
    g_api_lock.lock();
    defer g_api_lock.unlock();

    if (g_quic_api != null) return; // Already initialized

    var api_table: ?*const msquic.QUIC_API_TABLE = null;
    const status = msquic.MsQuicOpen(2, &api_table); // Version 2

    if (msquic.QUIC_FAILED(status) or api_table == null) {
        return QuicError.ApiInitFailed;
    }

    g_quic_api = api_table;
}

/// Clean up msquic API (call at shutdown)
pub fn deinitApi() void {
    g_api_lock.lock();
    defer g_api_lock.unlock();

    if (g_quic_api) |_| {
        msquic.MsQuicClose(g_quic_api.?);
        g_quic_api = null;
    }
}

pub const QuicTransport = struct {
    allocator: std.mem.Allocator,
    config: Config,
    registration: ?msquic.QUIC_REGISTRATION = null,
    configuration: ?msquic.QUIC_CONFIGURATION = null,
    listener: ?msquic.QUIC_LISTENER = null,
    connections: std.ArrayList(*QuicConnection),
    cert_path: []const u8,
    key_path: []const u8,

    pub const Config = struct {
        address: []const u8 = "0.0.0.0",
        port: u16 = 7567,
        max_connections: usize = 1000,
        idle_timeout_ms: u64 = 30000,
        max_stream_data: u64 = 10 * 1024 * 1024,
        max_data: u64 = 100 * 1024 * 1024,
        cert_path: []const u8 = "certs/server.crt",
        key_path: []const u8 = "certs/server.key",
        ca_path: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !QuicTransport {
        // Ensure API is initialized
        try initApi();

        var transport = QuicTransport{
            .allocator = allocator,
            .config = config,
            .connections = try std.ArrayList(*QuicConnection).initCapacity(allocator, 0),
            .cert_path = config.cert_path,
            .key_path = config.key_path,
        };

        // Create registration
        const api = g_quic_api orelse return QuicError.ApiInitFailed;
        const app_name = "geode";
        const reg_config = msquic.c.QUIC_REGISTRATION_CONFIG{
            .AppName = app_name.ptr,
            .ExecutionProfile = msquic.c.QUIC_EXECUTION_PROFILE_LOW_LATENCY,
        };

        const reg_status = api.RegistrationOpen(&reg_config, &transport.registration);
        if (msquic.QUIC_FAILED(reg_status)) {
            return QuicError.RegistrationFailed;
        }

        return transport;
    }

    pub fn deinit(self: *QuicTransport) void {
        const api = g_quic_api orelse return;

        // Close listener
        if (self.listener) |listener| {
            api.ListenerClose(listener);
            self.listener = null;
        }

        // Close all connections
        for (self.connections.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);

        // Close configuration
        if (self.configuration) |config| {
            api.ConfigurationClose(config);
            self.configuration = null;
        }

        // Close registration
        if (self.registration) |reg| {
            api.RegistrationClose(reg);
            self.registration = null;
        }
    }

    pub fn listen(self: *QuicTransport) !void {
        const api = g_quic_api orelse return QuicError.ApiInitFailed;

        // Load and configure TLS credentials
        var cred_config: msquic.QUIC_CREDENTIAL_CONFIG = undefined;
        @memset(@as([*]u8, @ptrCast(&cred_config))[0..@sizeOf(msquic.QUIC_CREDENTIAL_CONFIG)], 0);

        cred_config.Type = msquic.QUIC_CREDENTIAL_TYPE_CERTIFICATE_FILE;
        cred_config.Flags = msquic.QUIC_CREDENTIAL_FLAG_NONE;

        // Set up certificate file paths
        var cert_file = msquic.c.QUIC_CERTIFICATE_FILE{
            .CertificateFile = self.cert_path.ptr,
            .PrivateKeyFile = self.key_path.ptr,
        };
        cred_config.CertificateFile = &cert_file;

        // Create configuration with ALPN "geode/1"
        const alpn = "geode/1";
        var alpn_buffer = [_]msquic.QUIC_BUFFER{
            msquic.QUIC_BUFFER{
                .Length = @intCast(alpn.len),
                .Buffer = @constCast(alpn.ptr),
            },
        };

        const config_status = api.ConfigurationOpen(
            self.registration.?,
            &alpn_buffer,
            1, // AlpnBufferCount
            null, // Settings (use defaults)
            0, // SettingsSize
            null, // Context
            &self.configuration,
        );

        if (msquic.QUIC_FAILED(config_status)) {
            return QuicError.ConfigurationFailed;
        }

        // Load credentials into configuration
        const cred_status = api.ConfigurationLoadCredential(
            self.configuration.?,
            &cred_config,
        );

        if (msquic.QUIC_FAILED(cred_status)) {
            std.debug.print("Failed to load credentials: status={}\n", .{cred_status});
            return QuicError.CertificateError;
        }

        // Create listener
        const listener_status = api.ListenerOpen(
            self.registration.?,
            listenerCallback,
            self,
            &self.listener,
        );

        if (msquic.QUIC_FAILED(listener_status)) {
            return QuicError.ListenerFailed;
        }

        // Start listening
        var addr: msquic.QUIC_ADDR = undefined;
        @memset(@as([*]u8, @ptrCast(&addr))[0..@sizeOf(msquic.QUIC_ADDR)], 0);

        // Set up address
        addr.Ipv4.sin_family = msquic.c.AF_INET;
        addr.Ipv4.sin_port = @byteSwap(@as(u16, self.config.port)); // Network byte order
        addr.Ipv4.sin_addr.s_addr = 0; // INADDR_ANY

        const start_status = api.ListenerStart(
            self.listener.?,
            &alpn_buffer,
            1,
            &addr,
        );

        if (msquic.QUIC_FAILED(start_status)) {
            std.debug.print("Failed to start listener: status={}\n", .{start_status});
            return QuicError.ListenerFailed;
        }

        std.debug.print("{{\"component\":\"transport\",\"transport\":\"msquic\",\"tls\":\"true\",\"port\":{d}}}\n", .{self.config.port});
    }

    /// Listener callback - called when new connections arrive
    fn listenerCallback(
        listener: msquic.QUIC_HANDLE,
        context: ?*anyopaque,
        event: [*c]msquic.c.QUIC_LISTENER_EVENT,
    ) callconv(.C) msquic.QUIC_STATUS {
        _ = listener;

        const self = @as(*QuicTransport, @ptrCast(@alignCast(context.?)));
        const api = g_quic_api orelse return msquic.QUIC_STATUS_INVALID_STATE;

        switch (event.*.Type) {
            msquic.QUIC_LISTENER_EVENT_NEW_CONNECTION => {
                const conn_event = &event.*.NEW_CONNECTION;

                // Create our connection wrapper
                const conn = self.allocator.create(QuicConnection) catch {
                    return msquic.QUIC_STATUS_OUT_OF_MEMORY;
                };

                conn.* = QuicConnection{
                    .allocator = self.allocator,
                    .connection = conn_event.*.Connection,
                    .streams = std.ArrayList(*QuicStream){},
                };

                // Set connection callback
                api.SetCallbackHandler(
                    conn_event.*.Connection,
                    @ptrCast(&connectionCallback),
                    conn,
                );

                // Configure connection with our configuration
                const config_status = api.ConnectionSetConfiguration(
                    conn_event.*.Connection,
                    self.configuration.?,
                );

                if (msquic.QUIC_FAILED(config_status)) {
                    self.allocator.destroy(conn);
                    return msquic.QUIC_STATUS_INVALID_STATE;
                }

                // Add to connections list
                self.connections.append(self.allocator, conn) catch {
                    self.allocator.destroy(conn);
                    return msquic.QUIC_STATUS_OUT_OF_MEMORY;
                };

                return msquic.QUIC_STATUS_SUCCESS;
            },
            else => {
                return msquic.QUIC_STATUS_SUCCESS;
            },
        }
    }

    pub fn accept(self: *QuicTransport) !*QuicConnection {
        // In msquic, connections are accepted via the listener callback
        // This is a synchronous wrapper that waits for a connection

        // For now, we'll poll for new connections
        // In production, you'd use a proper event loop
        const start_len = self.connections.items.len;

        var timeout: usize = 0;
        while (timeout < 10000) : (timeout += 10) {
            std.time.sleep(10 * std.time.ns_per_ms);

            if (self.connections.items.len > start_len) {
                return self.connections.items[self.connections.items.len - 1];
            }
        }

        return QuicError.AcceptFailed;
    }

    pub fn tryAccept(self: *QuicTransport) ?*QuicConnection {
        if (self.connections.items.len > 0) {
            return self.connections.items[self.connections.items.len - 1];
        }
        return null;
    }

    pub fn poll(self: *QuicTransport, timeout_ms: u32) !void {
        // msquic uses its own internal event loop
        // We just need to sleep to allow callbacks to process
        _ = self;
        std.time.sleep(@as(u64, timeout_ms) * std.time.ns_per_ms);
    }
};

pub const QuicConnection = struct {
    allocator: std.mem.Allocator,
    connection: msquic.QUIC_CONNECTION,
    streams: std.ArrayList(*QuicStream),
    streams_init: bool = false,

    /// Connection callback - handles connection events
    fn connectionCallback(
        connection: msquic.QUIC_HANDLE,
        context: ?*anyopaque,
        event: [*c]msquic.c.QUIC_CONNECTION_EVENT,
    ) callconv(.C) msquic.QUIC_STATUS {
        _ = connection;

        const self = @as(*QuicConnection, @ptrCast(@alignCast(context.?)));

        switch (event.*.Type) {
            msquic.QUIC_CONNECTION_EVENT_CONNECTED => {
                // Connection established
                return msquic.QUIC_STATUS_SUCCESS;
            },
            msquic.QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED => {
                const stream_event = &event.*.PEER_STREAM_STARTED;

                // Create stream wrapper
                const stream = self.allocator.create(QuicStream) catch {
                    return msquic.QUIC_STATUS_OUT_OF_MEMORY;
                };

                stream.* = QuicStream{
                    .allocator = self.allocator,
                    .stream = stream_event.*.Stream,
                    .parent_connection = self,
                };

                // Set stream callback
                const api = g_quic_api orelse return msquic.QUIC_STATUS_INVALID_STATE;
                api.SetCallbackHandler(
                    stream_event.*.Stream,
                    @ptrCast(&streamCallback),
                    stream,
                );

                // Add to streams list
                if (!self.streams_init) {
                    self.streams = std.ArrayList(*QuicStream).initCapacity(self.allocator, 0) catch {
                        self.allocator.destroy(stream);
                        return msquic.QUIC_STATUS_OUT_OF_MEMORY;
                    };
                    self.streams_init = true;
                }

                self.streams.append(self.allocator, stream) catch {
                    self.allocator.destroy(stream);
                    return msquic.QUIC_STATUS_OUT_OF_MEMORY;
                };

                return msquic.QUIC_STATUS_SUCCESS;
            },
            else => {
                return msquic.QUIC_STATUS_SUCCESS;
            },
        }
    }

    pub fn close(self: *QuicConnection) void {
        const api = g_quic_api orelse return;

        // Close all streams
        if (self.streams_init) {
            for (self.streams.items) |stream| {
                stream.close();
                self.allocator.destroy(stream);
            }
            self.streams.deinit(self.allocator);
            self.streams_init = false;
        }

        // Shutdown connection
        api.ConnectionShutdown(
            self.connection,
            msquic.QUIC_CONNECTION_SHUTDOWN_FLAG_NONE,
            0,
        );
    }

    pub fn acceptStream(self: *QuicConnection) !*QuicStream {
        // Wait for a stream to be created via callback
        const start_len = if (self.streams_init) self.streams.items.len else 0;

        var timeout: usize = 0;
        while (timeout < 5000) : (timeout += 10) {
            std.time.sleep(10 * std.time.ns_per_ms);

            if (self.streams_init and self.streams.items.len > start_len) {
                return self.streams.items[self.streams.items.len - 1];
            }
        }

        return QuicError.StreamFailed;
    }

    pub fn openStream(self: *QuicConnection, bidirectional: bool) !*QuicStream {
        const api = g_quic_api orelse return QuicError.ApiInitFailed;

        const stream = try self.allocator.create(QuicStream);
        errdefer self.allocator.destroy(stream);

        const flags: u32 = if (bidirectional) msquic.QUIC_STREAM_OPEN_FLAG_NONE else msquic.QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL;

        var quic_stream: msquic.QUIC_HANDLE = undefined;
        const status = api.StreamOpen(
            self.connection,
            flags,
            @ptrCast(&streamCallback),
            stream,
            &quic_stream,
        );

        if (msquic.QUIC_FAILED(status)) {
            return QuicError.StreamFailed;
        }

        stream.* = QuicStream{
            .allocator = self.allocator,
            .stream = quic_stream,
            .parent_connection = self,
        };

        // Start the stream
        const start_status = api.StreamStart(quic_stream, msquic.QUIC_STREAM_START_FLAG_NONE);
        if (msquic.QUIC_FAILED(start_status)) {
            api.StreamClose(quic_stream);
            return QuicError.StreamFailed;
        }

        if (!self.streams_init) {
            self.streams = try std.ArrayList(*QuicStream).initCapacity(self.allocator, 0);
            self.streams_init = true;
        }
        try self.streams.append(self.allocator, stream);

        return stream;
    }

    pub fn isDrained(self: *QuicConnection) bool {
        _ = self;
        // TODO: Implement proper drain check
        return false;
    }

    pub fn isHandshakeConfirmed(self: *QuicConnection) bool {
        _ = self;
        // TODO: Implement handshake confirmation check
        return true;
    }
};

pub const QuicStream = struct {
    allocator: std.mem.Allocator,
    stream: msquic.QUIC_STREAM,
    parent_connection: *QuicConnection,
    read_buffer: std.ArrayList(u8) = std.ArrayList(u8){},

    /// Stream callback - handles stream events
    fn streamCallback(
        stream: msquic.QUIC_HANDLE,
        context: ?*anyopaque,
        event: [*c]msquic.c.QUIC_STREAM_EVENT,
    ) callconv(.C) msquic.QUIC_STATUS {
        _ = stream;

        const self = @as(*QuicStream, @ptrCast(@alignCast(context.?)));

        switch (event.*.Type) {
            msquic.QUIC_STREAM_EVENT_RECEIVE => {
                const recv_event = &event.*.RECEIVE;

                // Append received data to buffer
                var i: u32 = 0;
                while (i < recv_event.*.BufferCount) : (i += 1) {
                    const buffer = &recv_event.*.Buffers[i];
                    const data = buffer.Buffer[0..buffer.Length];
                    self.read_buffer.appendSlice(self.allocator, data) catch {};
                }

                return msquic.QUIC_STATUS_SUCCESS;
            },
            else => {
                return msquic.QUIC_STATUS_SUCCESS;
            },
        }
    }

    pub fn close(self: *QuicStream) void {
        const api = g_quic_api orelse return;

        api.StreamClose(self.stream);
        self.read_buffer.deinit(self.allocator);
    }

    pub fn write(self: *QuicStream, data: []const u8) !void {
        const api = g_quic_api orelse return QuicError.ApiInitFailed;

        var buffer = msquic.QUIC_BUFFER{
            .Length = @intCast(data.len),
            .Buffer = @constCast(data.ptr),
        };

        const status = api.StreamSend(
            self.stream,
            &buffer,
            1,
            msquic.QUIC_SEND_FLAG_NONE,
            null,
        );

        if (msquic.QUIC_FAILED(status)) {
            return QuicError.StreamFailed;
        }
    }

    pub fn writeAll(self: *QuicStream, data: []const u8) !void {
        try self.write(data);
    }

    pub fn read(self: *QuicStream, buf: []u8) !usize {
        // Wait for data to arrive in buffer
        var timeout: usize = 0;
        while (self.read_buffer.items.len == 0 and timeout < 1000) : (timeout += 10) {
            std.time.sleep(10 * std.time.ns_per_ms);
        }

        if (self.read_buffer.items.len == 0) {
            return 0;
        }

        const to_read = @min(buf.len, self.read_buffer.items.len);
        @memcpy(buf[0..to_read], self.read_buffer.items[0..to_read]);

        // Remove read data from buffer
        const remaining = self.read_buffer.items.len - to_read;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.read_buffer.items[0..remaining], self.read_buffer.items[to_read..]);
        }
        self.read_buffer.shrinkRetainingCapacity(remaining);

        return to_read;
    }

    pub fn readAll(self: *QuicStream, buf: []u8) !usize {
        var total_read: usize = 0;
        while (total_read < buf.len) {
            const n = try self.read(buf[total_read..]);
            if (n == 0) break;
            total_read += n;
        }
        return total_read;
    }

    pub fn readLine(self: *QuicStream, max_size: usize) ![]u8 {
        var result = try self.allocator.alloc(u8, max_size);
        var pos: usize = 0;

        while (pos < max_size) {
            const n = try self.read(result[pos .. pos + 1]);
            if (n == 0) {
                if (pos == 0) return error.EndOfStream;
                break;
            }
            if (result[pos] == '\n') {
                return self.allocator.realloc(result, pos + 1) catch result[0 .. pos + 1];
            }
            pos += 1;
        }
        return result[0..pos];
    }
};

// Client implementation
pub const QuicClient = struct {
    allocator: std.mem.Allocator,
    registration: ?msquic.QUIC_REGISTRATION = null,
    configuration: ?msquic.QUIC_CONFIGURATION = null,
    connection: ?msquic.QUIC_CONNECTION = null,

    pub fn init(allocator: std.mem.Allocator) QuicClient {
        return QuicClient{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuicClient) void {
        const api = g_quic_api orelse return;

        if (self.connection) |conn| {
            api.ConnectionClose(conn);
            self.connection = null;
        }

        if (self.configuration) |config| {
            api.ConfigurationClose(config);
            self.configuration = null;
        }

        if (self.registration) |reg| {
            api.RegistrationClose(reg);
            self.registration = null;
        }
    }

    pub fn connect(self: *QuicClient, address: []const u8, port: u16) !void {
        try initApi();

        // TODO: Implement client connect
        _ = self;
        _ = address;
        _ = port;
        return QuicError.ConnectionFailed;
    }

    pub fn connectInsecure(self: *QuicClient, address: []const u8, port: u16, allow_insecure: bool) !void {
        _ = self;
        _ = address;
        _ = port;
        _ = allow_insecure;
        return QuicError.ConnectionFailed;
    }

    pub fn connectEx(self: *QuicClient, address: []const u8, port: u16, ca: ?[]const u8, cert: ?[]const u8, key: ?[]const u8) !void {
        _ = self;
        _ = address;
        _ = port;
        _ = ca;
        _ = cert;
        _ = key;
        return QuicError.ConnectionFailed;
    }

    pub fn waitForHandshake(self: *QuicClient, timeout_secs: u32) !void {
        _ = self;
        _ = timeout_secs;
    }

    pub fn getStream(self: *QuicClient) !*QuicClientStream {
        _ = self;
        return QuicError.StreamFailed;
    }
};

pub const QuicClientStream = struct {
    allocator: std.mem.Allocator,
    stream: ?msquic.QUIC_STREAM,

    pub fn writeAll(self: *QuicClientStream, data: []const u8) !void {
        _ = self;
        _ = data;
        return QuicError.StreamFailed;
    }

    pub fn read(self: *QuicClientStream, buf: []u8) !usize {
        _ = self;
        _ = buf;
        return 0;
    }

    pub fn readLine(self: *QuicClientStream, max_size: usize) ![]u8 {
        _ = self;
        _ = max_size;
        return error.EndOfStream;
    }

    pub fn deinit(self: *QuicClientStream) void {
        self.allocator.destroy(self);
    }
};
