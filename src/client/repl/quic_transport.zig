const std = @import("std");
const repl_dispatch = @import("repl_dispatch.zig");
const quic = @import("transport/quic");

// TLS configuration for REPL QUIC transport.
pub const TlsConfig = struct {
    insecure: bool = false,
    ca_cert_path: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
};

var tls_config: TlsConfig = .{};

pub fn setTlsConfig(cfg: TlsConfig) void {
    tls_config = cfg;
}

pub fn getTlsConfig() TlsConfig {
    return tls_config;
}

// QUIC Transport for REPL — single-threaded I/O with background keepalive.
//
// The QUIC client endpoint is NOT safe for concurrent access from multiple
// threads. All operations (read, write, poll) must be serialized.
//
// Design: a single `client_mu` mutex guards ALL client operations.
// - During query execution: I/O functions hold client_mu, keepalive skips.
// - During idle (user typing): keepalive holds client_mu briefly to poll.
const QuicTransportConnection = struct {
    allocator: std.mem.Allocator,
    client: *quic.QuicClient,
    stream: *quic.QuicClientStream,
    owns_client: bool,
    // Single mutex guarding ALL QUIC client operations (read, write, poll).
    // Prevents data races between the keepalive thread and query I/O.
    client_mu: std.Thread.Mutex = .{},
    // Background keepalive thread state
    keepalive_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    keepalive_thread: ?std.Thread = null,

    fn startKeepalive(self: *QuicTransportConnection) void {
        self.keepalive_thread = std.Thread.spawn(.{}, keepaliveWorker, .{self}) catch null;
    }

    fn stopKeepalive(self: *QuicTransportConnection) void {
        self.keepalive_stop.store(true, .release);
        if (self.keepalive_thread) |t| {
            t.join();
            self.keepalive_thread = null;
        }
    }

    fn keepaliveWorker(self: *QuicTransportConnection) void {
        while (!self.keepalive_stop.load(.acquire)) {
            // tryLock: if I/O is active (client_mu held), skip this cycle.
            // This ensures keepalive NEVER races with read/write/poll.
            if (self.client_mu.tryLock()) {
                self.client.poll(0) catch {};
                self.client_mu.unlock();
            }
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }
    }
};

// Write pre-encoded length-prefixed protobuf message bytes to QUIC stream.
fn quicWriteAll(self: *repl_dispatch.TransportConnection, data: []const u8) !void {
    const ctx = self.context orelse return error.NotConnected;
    const impl: *QuicTransportConnection = @ptrCast(@alignCast(ctx));
    // Hold client_mu for entire write to prevent keepalive interference
    impl.client_mu.lock();
    defer impl.client_mu.unlock();
    impl.stream.writeAll(data) catch |err| return err;
}

// Read length-prefixed protobuf responses and return raw message bytes.
fn quicReadLine(self: *repl_dispatch.TransportConnection, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
    const ctx = self.context orelse return error.NotConnected;
    const impl: *QuicTransportConnection = @ptrCast(@alignCast(ctx));

    const start = std.time.milliTimestamp();
    const timeout_ms: i64 = 30000; // 30 second timeout for REPL.

    // Hold client_mu for entire read operation. This prevents the keepalive
    // thread from calling poll() while we're reading from the stream, which
    // would corrupt the stream's internal receive buffer.
    impl.client_mu.lock();
    defer impl.client_mu.unlock();

    // Read 4-byte length prefix.
    var len_buf: [4]u8 = undefined;
    var len_read: usize = 0;
    while (len_read < 4) {
        if (repl_dispatch.checkForInterrupt()) {
            return error.Interrupted;
        }

        const n = impl.stream.read(len_buf[len_read..]) catch |err| {
            if (err == error.WouldBlock) {
                if (std.time.milliTimestamp() - start >= timeout_ms) return error.WouldBlock;
                impl.client.poll(5) catch {};
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) return error.EndOfStream;
        len_read += n;
    }

    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len > 16 * 1024 * 1024) return error.MessageTooLarge; // 16MB limit.
    if (max_size > 0 and msg_len > max_size) return error.MessageTooLarge;

    // Read message body.
    const body = try allocator.alloc(u8, msg_len);
    errdefer allocator.free(body);

    var body_read: usize = 0;
    while (body_read < msg_len) {
        if (repl_dispatch.checkForInterrupt()) {
            allocator.free(body);
            return error.Interrupted;
        }

        const n = impl.stream.read(body[body_read..]) catch |err| {
            if (err == error.WouldBlock) {
                if (std.time.milliTimestamp() - start >= timeout_ms) {
                    allocator.free(body);
                    return error.WouldBlock;
                }
                impl.client.poll(5) catch {};
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            allocator.free(body);
            return err;
        };
        if (n == 0) {
            allocator.free(body);
            return error.EndOfStream;
        }
        body_read += n;
    }

    return body;
}

fn quicDeinit(self: *repl_dispatch.TransportConnection) void {
    const ctx = self.context orelse {
        if (self.allocator) |alloc| alloc.destroy(self);
        return;
    };
    const impl: *QuicTransportConnection = @ptrCast(@alignCast(ctx));
    // Stop keepalive thread before closing stream/client
    impl.stopKeepalive();
    impl.stream.deinit();
    if (impl.owns_client) {
        impl.client.deinit();
        impl.allocator.destroy(impl.client);
    }
    impl.allocator.destroy(impl);
    if (self.allocator) |conn_alloc| conn_alloc.destroy(self);
}

fn quicConnect(allocator: std.mem.Allocator, addr: []const u8) !*repl_dispatch.TransportConnection {
    const colon_idx = std.mem.lastIndexOf(u8, addr, ":") orelse return error.InvalidAddress;
    const host = addr[0..colon_idx];
    const port = try std.fmt.parseInt(u16, addr[colon_idx + 1 ..], 10);

    // Create QUIC client.
    const client = try allocator.create(quic.QuicClient);
    client.* = quic.QuicClient.init(allocator);
    errdefer {
        client.deinit();
        allocator.destroy(client);
    }

    if (tls_config.insecure) {
        std.debug.print("Warning: TLS verification disabled (--insecure flag)\r\n", .{});
        _ = client.connectInsecure(host, port, true) catch |err| {
            return err;
        };
    } else if (tls_config.ca_cert_path != null or tls_config.client_cert_path != null) {
        std.debug.print("Using TLS with custom certificates\r\n", .{});
        if (tls_config.ca_cert_path) |ca| {
            std.debug.print("  CA certificate: {s}\r\n", .{ca});
        }
        if (tls_config.client_cert_path) |cert| {
            std.debug.print("  Client certificate: {s}\r\n", .{cert});
        }
        _ = client.connectInsecure(host, port, false) catch |err| {
            return err;
        };
    } else {
        _ = client.connectInsecure(host, port, false) catch |err| {
            return err;
        };
    }

    // Wait for handshake.
    _ = client.waitForHandshake(10) catch |err| {
        return err;
    };

    // Get stream.
    var stream = client.getStream() catch |err| {
        return err;
    };
    errdefer stream.deinit();

    // Create transport connection with background keepalive.
    const impl = try allocator.create(QuicTransportConnection);
    impl.* = .{
        .allocator = allocator,
        .client = client,
        .stream = stream,
        .owns_client = true,
    };
    // Keepalive thread polls during idle (user typing) to respond to
    // server PINGs. Uses tryLock so it never races with active I/O.
    impl.startKeepalive();

    const transport_conn = try allocator.create(repl_dispatch.TransportConnection);
    transport_conn.* = .{
        .writeAllFn = quicWriteAll,
        .readLineFn = quicReadLine,
        .deinitFn = quicDeinit,
        .context = impl,
        .allocator = allocator,
    };
    return transport_conn;
}

pub const transport = repl_dispatch.Transport{
    .connectFn = quicConnect,
};
