const std = @import("std");
const net = std.net;

// Simplified QUIC transport layer for geode
// This provides a TCP-based transport that simulates QUIC behavior
// The actual QUIC implementation from vendor/quic needs more compatibility work

pub const QuicError = error{
    ConnectionFailed,
    StreamFailed,
    InvalidAddress,
    CertificateError,
    EndpointInitFailed,
    AcceptFailed,
};

pub const QuicTransport = struct {
    allocator: std.mem.Allocator,
    config: Config,
    server: ?net.Server = null,
    connections: std.ArrayList(*QuicConnection),
    cert_path: []const u8,
    key_path: []const u8,

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
        if (self.server) |*server| {
            server.deinit();
        }
        for (self.connections.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
    }

    pub fn listen(self: *QuicTransport) !void {
        // Check if certificates exist
        std.fs.cwd().access(self.cert_path, .{}) catch |err| {
            std.debug.print("Certificate not found at {s}: {}\n", .{ self.cert_path, err });
            // Continue without certificates for now
        };
        std.fs.cwd().access(self.key_path, .{}) catch |err| {
            std.debug.print("Key not found at {s}: {}\n", .{ self.key_path, err });
            // Continue without certificates for now
        };

        // Parse address and create TCP listener
        // We'll use TCP to simulate QUIC behavior until the vendored library is fixed
        const address = try net.Address.parseIp(self.config.address, self.config.port);
        self.server = try address.listen(.{
            .reuse_address = true,
        });
        
        std.debug.print("QUIC-compatible server listening on {s}:{d}\n", .{ 
            self.config.address, 
            self.config.port 
        });
        std.debug.print("Note: Using TCP transport with QUIC-like semantics\n", .{});
    }

    pub fn accept(self: *QuicTransport) !*QuicConnection {
        if (self.server) |*server| {
            const conn_info = try server.accept();
            
            const conn = try self.allocator.create(QuicConnection);
            conn.* = QuicConnection{
                .allocator = self.allocator,
                .stream = conn_info.stream,
                .streams = try std.ArrayList(*QuicStream).initCapacity(self.allocator, 0),
            };
            
            try self.connections.append(self.allocator, conn);
            return conn;
        }
        return QuicError.ConnectionFailed;
    }
};

pub const QuicConnection = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    streams: std.ArrayList(*QuicStream),

    pub fn close(self: *QuicConnection) void {
        for (self.streams.items) |stream| {
            stream.close();
            self.allocator.destroy(stream);
        }
        self.streams.deinit(self.allocator);
        self.stream.close();
    }

    pub fn acceptStream(self: *QuicConnection) !*QuicStream {
        // For now, we'll use the main socket as a single stream
        const stream = try self.allocator.create(QuicStream);
        stream.* = QuicStream{
            .allocator = self.allocator,
            .stream = self.stream,
            .stream_id = self.streams.items.len,
        };
        try self.streams.append(self.allocator, stream);
        return stream;
    }

    pub fn openStream(self: *QuicConnection) !*QuicStream {
        return self.acceptStream();
    }
};

pub const QuicStream = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    stream_id: usize = 0,

    pub fn close(self: *QuicStream) void {
        _ = self;
        // Stream shares the connection's socket, so don't close it here
    }

    pub fn write(self: *QuicStream, data: []const u8) !void {
        _ = try self.stream.write(data);
    }

    pub fn writeAll(self: *QuicStream, data: []const u8) !void {
        try self.stream.writeAll(data);
    }

    pub fn read(self: *QuicStream, buf: []u8) !usize {
        return self.stream.read(buf);
    }

    pub fn readAll(self: *QuicStream, buf: []u8) !usize {
        return self.stream.readAll(buf);
    }

    pub fn readLine(self: *QuicStream, max_size: usize) ![]u8 {
        var buf = try self.allocator.alloc(u8, max_size);
        var pos: usize = 0;
        while (pos < max_size) {
            const n = try self.stream.read(buf[pos..pos + 1]);
            if (n == 0) {
                if (pos == 0) return error.EndOfStream;
                break;
            }
            if (buf[pos] == '\n') {
                return self.allocator.realloc(buf, pos + 1) catch buf[0..pos + 1];
            }
            pos += 1;
        }
        return buf[0..pos];
    }
};

// Client-side QUIC support
pub const QuicClient = struct {
    allocator: std.mem.Allocator,
    connection: ?net.Stream = null,
    server_addr: []const u8 = "",
    server_port: u16 = 7567,

    pub fn init(allocator: std.mem.Allocator) QuicClient {
        return QuicClient{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuicClient) void {
        if (self.connection) |conn| {
            conn.close();
        }
    }

    pub fn connect(self: *QuicClient, address: []const u8, port: u16) !void {
        const addr = try net.Address.parseIp(address, port);
        self.connection = try net.tcpConnectToAddress(addr);
        self.server_addr = address;
        self.server_port = port;
    }

    pub fn getStream(self: *QuicClient) !*QuicClientStream {
        if (self.connection) |conn| {
            const stream = try self.allocator.create(QuicClientStream);
            stream.* = QuicClientStream{
                .allocator = self.allocator,
                .stream = conn,
            };
            return stream;
        }
        return QuicError.ConnectionFailed;
    }
};

pub const QuicClientStream = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,

    pub fn writeAll(self: *QuicClientStream, data: []const u8) !void {
        try self.stream.writeAll(data);
    }

    pub fn readLine(self: *QuicClientStream, max_size: usize) ![]u8 {
        var buf = try self.allocator.alloc(u8, max_size);
        var pos: usize = 0;
        while (pos < max_size) {
            const n = try self.stream.read(buf[pos..pos + 1]);
            if (n == 0) break;
            if (buf[pos] == '\n') {
                return self.allocator.realloc(buf, pos + 1) catch buf[0..pos + 1];
            }
            pos += 1;
        }
        return buf[0..pos];
    }

    pub fn deinit(self: *QuicClientStream) void {
        self.allocator.destroy(self);
    }
};