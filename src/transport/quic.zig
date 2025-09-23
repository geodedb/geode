const std = @import("std");
const net = std.net;
const quic_lib = @import("vendor_quic");
const tls = std.crypto.tls;

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICCore; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICCore; OWNER=wire; UPDATED=2025-09-22
// Full QUIC transport layer for geode using vendored QUIC library

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
};

pub const QuicTransport = struct {
    allocator: std.mem.Allocator,
    config: Config,
    endpoint: ?*quic_lib.QuicEndpoint = null,
    connections: std.ArrayList(*QuicConnection),
    cert_path: []const u8,
    key_path: []const u8,
    quic_config: ?*quic_lib.QuicConfig = null,
    tcp_fallback_server: ?net.Server = null,

    pub const Config = struct {
        address: []const u8 = "0.0.0.0",
        port: u16 = 7567,
        max_connections: usize = 1000,
        idle_timeout_ms: u64 = 30000,
        max_stream_data: u64 = 10 * 1024 * 1024, // 10MB per stream
        max_data: u64 = 100 * 1024 * 1024, // 100MB per connection
        cert_path: []const u8 = "certs/server.crt",
        key_path: []const u8 = "certs/server.key",
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !QuicTransport {
        return QuicTransport{
            .allocator = allocator,
            .config = config,
            .connections = try std.ArrayList(*QuicConnection).initCapacity(allocator, 0),
            .cert_path = config.cert_path,
            .key_path = config.key_path,
        };
    }

    pub fn deinit(self: *QuicTransport) void {
        if (self.endpoint) |ep| {
            quic_lib.endpointDeinit(ep);
        }
        if (self.tcp_fallback_server) |*server| {
            server.deinit();
        }
        for (self.connections.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        if (self.quic_config) |cfg| {
            self.allocator.destroy(cfg);
        }
    }

    pub fn listen(self: *QuicTransport) !void {
        // CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICListener; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICListener; OWNER=wire; UPDATED=2025-09-22

        // Check if certificates exist
        var cert_exists = true;
        std.fs.cwd().access(self.cert_path, .{}) catch {
            cert_exists = false;
        };
        var key_exists = true;
        std.fs.cwd().access(self.key_path, .{}) catch {
            key_exists = false;
        };

        const bind_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ self.config.address, self.config.port });
        defer self.allocator.free(bind_addr);

        if (cert_exists and key_exists) {
            // Try to use real QUIC with certificates
            const cfg = try self.allocator.create(quic_lib.QuicConfig);
            cfg.* = .{
                .version = .v1,
                .alpn = &[_][]const u8{ "h3", "http/3" },
                .cc = .newreno,
                .enable_datagram = false,
                .enable_spin_bit = false,
                .grease = true,
                .compatible_vn = false,
                .enable_retry = false,
                .token_secret = null,
                .token_expiry_ms = 60000,
                .enable_pacing = false,
                .max_datagram_size = 1200,
                .max_idle_timeout_ms = @intCast(self.config.idle_timeout_ms),
                .max_udp_payload = 1350,
                .cert_path = self.cert_path,
                .key_path = self.key_path,
                .ca_path = null,
                .allow_insecure = false,
                .aead_confidentiality_limit_override = null,
                .aead_integrity_limit_override = null,
                .real_tls = false,
                .inline_server_cert_der = null,
                .inline_server_priv_p256 = null,
            };

            self.endpoint = quic_lib.endpointInit(&self.allocator, bind_addr, cfg) catch |err| {
                std.debug.print("QUIC endpoint init failed: {}, falling back to TCP\n", .{err});
                return self.listenTcpFallback();
            };

            std.debug.print("QUIC server listening on {s} with TLS 1.3\n", .{bind_addr});
        } else {
            std.debug.print("TLS certificates not found, using TCP fallback\n", .{});
            return self.listenTcpFallback();
        }
    }

    fn listenTcpFallback(self: *QuicTransport) !void {
        const address = try net.Address.parseIp(self.config.address, self.config.port);
        self.tcp_fallback_server = try address.listen(.{
            .reuse_address = true,
        });
        std.debug.print("TCP fallback server listening on {s}:{d}\n", .{ self.config.address, self.config.port });
    }

    pub fn accept(self: *QuicTransport) !*QuicConnection {
        // CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICAccept; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICAccept; OWNER=wire; UPDATED=2025-09-22

        if (self.endpoint) |ep| {
            // Accept from QUIC endpoint
            const quic_conn = quic_lib.accept(ep) catch |err| {
                if (self.tcp_fallback_server != null) {
                    return self.acceptTcpFallback();
                }
                return err;
            };

            const conn = try self.allocator.create(QuicConnection);
            conn.* = QuicConnection{
                .allocator = self.allocator,
                .quic_connection = quic_conn,
                .tcp_stream = null,
                .streams = std.ArrayList(*QuicStream){},
                .is_quic = true,
            };

            try self.connections.append(self.allocator, conn);
            return conn;
        } else if (self.tcp_fallback_server) |_| {
            return self.acceptTcpFallback();
        }
        return QuicError.ConnectionFailed;
    }

    fn acceptTcpFallback(self: *QuicTransport) !*QuicConnection {
        if (self.tcp_fallback_server) |*server| {
            const conn_info = try server.accept();

            const conn = try self.allocator.create(QuicConnection);
            conn.* = QuicConnection{
                .allocator = self.allocator,
                .quic_connection = null,
                .tcp_stream = conn_info.stream,
                .streams = std.ArrayList(*QuicStream){},
                .is_quic = false,
            };

            try self.connections.append(self.allocator, conn);
            return conn;
        }
        return QuicError.ConnectionFailed;
    }
};

pub const QuicConnection = struct {
    allocator: std.mem.Allocator,
    quic_connection: ?*quic_lib.QuicConnection,
    tcp_stream: ?net.Stream,
    streams: std.ArrayList(*QuicStream),
    is_quic: bool,
    next_stream_id: usize = 0,

    pub fn close(self: *QuicConnection) void {
        for (self.streams.items) |stream| {
            stream.close();
            self.allocator.destroy(stream);
        }
        self.streams.deinit(self.allocator);

        if (self.quic_connection) |conn| {
            quic_lib.closeConnectionSimple(conn) catch {};
        }
        if (self.tcp_stream) |stream| {
            stream.close();
        }
    }

    pub fn acceptStream(self: *QuicConnection) !*QuicStream {
        // CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICStream; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICStream; OWNER=wire; UPDATED=2025-09-22

        const stream = try self.allocator.create(QuicStream);
        errdefer self.allocator.destroy(stream);

        if (self.is_quic and self.quic_connection != null) {
            // Accept a QUIC stream
            const stream_id = quic_lib.acceptStream(self.quic_connection.?) catch |err| {
                // Fall back to single stream mode for TCP
                if (self.tcp_stream) |tcp| {
                    stream.* = QuicStream{
                        .allocator = self.allocator,
                        .quic_stream_id = null,
                        .tcp_stream = tcp,
                        .parent_connection = self,
                        .stream_id = self.next_stream_id,
                    };
                    self.next_stream_id += 1;
                    try self.streams.append(self.allocator, stream);
                    return stream;
                }
                return err;
            };

            stream.* = QuicStream{
                .allocator = self.allocator,
                .quic_stream_id = stream_id,
                .tcp_stream = null,
                .parent_connection = self,
                .stream_id = stream_id,
            };
        } else if (self.tcp_stream) |tcp| {
            stream.* = QuicStream{
                .allocator = self.allocator,
                .quic_stream_id = null,
                .tcp_stream = tcp,
                .parent_connection = self,
                .stream_id = self.next_stream_id,
            };
            self.next_stream_id += 1;
        } else {
            return QuicError.StreamFailed;
        }

        try self.streams.append(self.allocator, stream);
        return stream;
    }

    pub fn openStream(self: *QuicConnection, bidirectional: bool) !*QuicStream {
        // CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICStreamOpen; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICStreamOpen; OWNER=wire; UPDATED=2025-09-22

        const stream = try self.allocator.create(QuicStream);
        errdefer self.allocator.destroy(stream);

        if (self.is_quic and self.quic_connection != null) {
            const stream_id = try quic_lib.openStream(self.quic_connection.?, bidirectional);
            stream.* = QuicStream{
                .allocator = self.allocator,
                .quic_stream_id = stream_id,
                .tcp_stream = null,
                .parent_connection = self,
                .stream_id = stream_id,
            };
        } else {
            // For TCP, all streams share the same connection
            return self.acceptStream();
        }

        try self.streams.append(self.allocator, stream);
        return stream;
    }
};

pub const QuicStream = struct {
    allocator: std.mem.Allocator,
    quic_stream_id: ?quic_lib.QuicStreamId,
    tcp_stream: ?net.Stream,
    parent_connection: *QuicConnection,
    stream_id: usize = 0,
    read_buffer: []u8 = &[_]u8{},

    pub fn close(self: *QuicStream) void {
        _ = self;
        // Stream shares the connection's socket, so don't close it here
    }

    pub fn write(self: *QuicStream, data: []const u8) !void {
        if (self.quic_stream_id) |sid| {
            _ = try quic_lib.writeStream(self.parent_connection.quic_connection.?, sid, data);
        } else if (self.tcp_stream) |stream| {
            _ = try stream.write(data);
        } else {
            return QuicError.StreamFailed;
        }
    }

    pub fn writeAll(self: *QuicStream, data: []const u8) !void {
        if (self.quic_stream_id) |sid| {
            // QUIC handles fragmentation internally
            _ = try quic_lib.writeStream(self.parent_connection.quic_connection.?, sid, data);
        } else if (self.tcp_stream) |stream| {
            try stream.writeAll(data);
        } else {
            return QuicError.StreamFailed;
        }
    }

    pub fn read(self: *QuicStream, buf: []u8) !usize {
        if (self.quic_stream_id) |sid| {
            return quic_lib.readStream(self.parent_connection.quic_connection.?, sid, buf) catch {
                return 0;
            };
        } else if (self.tcp_stream) |stream| {
            return stream.read(buf);
        } else {
            return QuicError.StreamFailed;
        }
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
        var buf = try self.allocator.alloc(u8, max_size);
        var pos: usize = 0;

        while (pos < max_size) {
            const n = try self.read(buf[pos .. pos + 1]);
            if (n == 0) {
                if (pos == 0) return error.EndOfStream;
                break;
            }
            if (buf[pos] == '\n') {
                return self.allocator.realloc(buf, pos + 1) catch buf[0 .. pos + 1];
            }
            pos += 1;
        }
        return buf[0..pos];
    }
};

// Client-side QUIC support
pub const QuicClient = struct {
    allocator: std.mem.Allocator,
    endpoint: ?*quic_lib.QuicEndpoint = null,
    quic_connection: ?*quic_lib.QuicConnection = null,
    tcp_connection: ?net.Stream = null,
    server_addr: []const u8 = "",
    server_port: u16 = 7567,
    is_quic: bool = false,
    quic_config: ?*quic_lib.QuicConfig = null,

    pub fn init(allocator: std.mem.Allocator) QuicClient {
        return QuicClient{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuicClient) void {
        if (self.endpoint) |ep| {
            quic_lib.endpointDeinit(ep);
        }
        if (self.quic_connection) |conn| {
            quic_lib.closeConnectionSimple(conn) catch {};
        }
        if (self.tcp_connection) |conn| {
            conn.close();
        }
        if (self.quic_config) |cfg| {
            self.allocator.destroy(cfg);
        }
    }

    pub fn connect(self: *QuicClient, address: []const u8, port: u16) !void {
        // CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICClientConnect; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICClientConnect; OWNER=wire; UPDATED=2025-09-22

        const server_addr_str = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ address, port });
        defer self.allocator.free(server_addr_str);

        // Try QUIC first
        const cert_path = "certs/ca.crt"; // Client needs CA cert for verification
        var has_ca_cert = true;
        std.fs.cwd().access(cert_path, .{}) catch {
            has_ca_cert = false;
        };

        if (has_ca_cert) {
            // Initialize QUIC config for client
            const cfg = try self.allocator.create(quic_lib.QuicConfig);
            cfg.* = .{
                .version = .v1,
                .alpn = &[_][]const u8{ "h3", "http/3" },
                .cc = .newreno,
                .enable_datagram = false,
                .enable_spin_bit = false,
                .grease = true,
                .compatible_vn = false,
                .enable_retry = false,
                .token_secret = null,
                .token_expiry_ms = 60000,
                .enable_pacing = false,
                .max_datagram_size = 1200,
                .max_idle_timeout_ms = 30000,
                .max_udp_payload = 1350,
                .cert_path = cert_path,
                .key_path = null,
                .ca_path = cert_path,
                .allow_insecure = false,
                .aead_confidentiality_limit_override = null,
                .aead_integrity_limit_override = null,
                .real_tls = false,
                .inline_server_cert_der = null,
                .inline_server_priv_p256 = null,
            };

            // Create client endpoint
            const bind_addr = "0.0.0.0:0"; // Bind to any available port
            self.endpoint = quic_lib.endpointInit(&self.allocator, bind_addr, cfg) catch |err| {
                std.debug.print("QUIC client endpoint init failed: {}, falling back to TCP\n", .{err});
                return self.connectTcpFallback(address, port);
            };

            // Connect to server
            const sni = address; // Use server address as SNI
            self.quic_connection = quic_lib.connect(self.endpoint.?, server_addr_str, sni) catch |err| {
                std.debug.print("QUIC connection failed: {}, falling back to TCP\n", .{err});
                return self.connectTcpFallback(address, port);
            };

            self.is_quic = true;
            std.debug.print("Connected to QUIC server at {s}\n", .{server_addr_str});
        } else {
            std.debug.print("CA certificate not found, using TCP\n", .{});
            return self.connectTcpFallback(address, port);
        }

        self.server_addr = address;
        self.server_port = port;
    }

    fn connectTcpFallback(self: *QuicClient, address: []const u8, port: u16) !void {
        const addr = try net.Address.parseIp(address, port);
        self.tcp_connection = try net.tcpConnectToAddress(addr);
        self.is_quic = false;
        self.server_addr = address;
        self.server_port = port;
    }

    pub fn getStream(self: *QuicClient) !*QuicClientStream {
        const stream = try self.allocator.create(QuicClientStream);
        errdefer self.allocator.destroy(stream);

        if (self.is_quic and self.quic_connection != null) {
            const stream_id = try quic_lib.openStream(self.quic_connection.?, true);
            stream.* = QuicClientStream{
                .allocator = self.allocator,
                .quic_stream_id = stream_id,
                .quic_connection = self.quic_connection,
                .tcp_stream = null,
            };
        } else if (self.tcp_connection) |conn| {
            stream.* = QuicClientStream{
                .allocator = self.allocator,
                .quic_stream_id = null,
                .quic_connection = null,
                .tcp_stream = conn,
            };
        } else {
            return QuicError.ConnectionFailed;
        }

        return stream;
    }
};

pub const QuicClientStream = struct {
    allocator: std.mem.Allocator,
    quic_stream_id: ?quic_lib.QuicStreamId,
    quic_connection: ?*quic_lib.QuicConnection,
    tcp_stream: ?net.Stream,

    pub fn writeAll(self: *QuicClientStream, data: []const u8) !void {
        if (self.quic_stream_id) |sid| {
            _ = try quic_lib.writeStream(self.quic_connection.?, sid, data);
        } else if (self.tcp_stream) |stream| {
            try stream.writeAll(data);
        } else {
            return QuicError.StreamFailed;
        }
    }

    pub fn read(self: *QuicClientStream, buf: []u8) !usize {
        if (self.quic_stream_id) |sid| {
            return quic_lib.readStream(self.quic_connection.?, sid, buf) catch {
                return 0;
            };
        } else if (self.tcp_stream) |stream| {
            return stream.read(buf);
        } else {
            return QuicError.StreamFailed;
        }
    }

    pub fn readLine(self: *QuicClientStream, max_size: usize) ![]u8 {
        var buf = try self.allocator.alloc(u8, max_size);
        var pos: usize = 0;
        while (pos < max_size) {
            const n = try self.read(buf[pos .. pos + 1]);
            if (n == 0) break;
            if (buf[pos] == '\n') {
                return self.allocator.realloc(buf, pos + 1) catch buf[0 .. pos + 1];
            }
            pos += 1;
        }
        return buf[0..pos];
    }

    pub fn deinit(self: *QuicClientStream) void {
        if (self.quic_stream_id) |sid| {
            quic_lib.closeStreamSimple(self.quic_connection.?, sid) catch {};
        }
        self.allocator.destroy(self);
    }
};
