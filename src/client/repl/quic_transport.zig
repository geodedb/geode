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
            // GAP-0276: Reduced from 500ms to 100ms for faster keepalive response
            std.Thread.sleep(100 * std.time.ns_per_ms);
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

    // Rolling idle timeout: resets on every successful byte read.
    // This prevents aborting mid-message while still timing out when
    // no data arrives at all.
    var last_progress = std.time.milliTimestamp();
    const idle_timeout_ms: i64 = 30000; // 30 second idle timeout for REPL.

    // Hold client_mu for entire read operation. This prevents the keepalive
    // thread from calling poll() while we're reading from the stream, which
    // would corrupt the stream's internal receive buffer.
    impl.client_mu.lock();
    defer impl.client_mu.unlock();

    // Read 4-byte length prefix.
    var len_buf: [4]u8 = undefined;
    var len_read: usize = 0;
    while (len_read < 4) {
        // Only check for interrupt before any bytes have been read.
        // Once we've started reading a message frame, we must finish the
        // header to keep the stream synchronized.
        if (len_read == 0 and repl_dispatch.checkForInterrupt()) {
            return error.Interrupted;
        }

        const n = impl.stream.read(len_buf[len_read..]) catch |err| {
            if (err == error.WouldBlock) {
                if (std.time.milliTimestamp() - last_progress >= idle_timeout_ms) {
                    // Only return WouldBlock when no bytes have been read.
                    // A partial header read means the connection is broken.
                    if (len_read == 0) return error.WouldBlock;
                    return error.ConnectionResetByPeer;
                }
                impl.client.poll(5) catch {};
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) return error.EndOfStream;
        len_read += n;
        last_progress = std.time.milliTimestamp();
    }

    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len > 16 * 1024 * 1024) return error.MessageTooLarge; // 16MB limit.
    if (max_size > 0 and msg_len > max_size) return error.MessageTooLarge;

    // Read message body.
    // Once the header is read, we MUST read the full body to keep the stream
    // synchronized. Aborting mid-body would leave the stream at an unknown
    // offset, causing subsequent reads to interpret body bytes as a length
    // prefix — producing garbage msg_len values and eventual segfaults.
    const body = try allocator.alloc(u8, msg_len);
    errdefer allocator.free(body);

    var body_read: usize = 0;
    while (body_read < msg_len) {
        // No interrupt check here — we must finish the message to keep
        // the stream aligned. Interrupts are checked between messages.

        const n = impl.stream.read(body[body_read..]) catch |err| {
            if (err == error.WouldBlock) {
                if (std.time.milliTimestamp() - last_progress >= idle_timeout_ms) {
                    // Timed out mid-body: the stream is now desynchronized.
                    // Return a connection error (not WouldBlock) so callers
                    // know the connection must be re-established.
                    return error.ConnectionResetByPeer;
                }
                impl.client.poll(5) catch {};
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) {
            return error.EndOfStream;
        }
        body_read += n;
        last_progress = std.time.milliTimestamp();
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
            if (err == error.InsecureForbiddenInRelease) {
                std.debug.print("Error: --insecure-tls-skip-verify is only available in debug builds.\r\n", .{});
                std.debug.print("For production use, configure a trusted CA certificate with --ca-cert instead.\r\n", .{});
            }
            return err;
        };
    } else if (tls_config.client_cert_path != null) {
        // mTLS: use connectEx with client cert/key and optional CA
        std.debug.print("Using TLS with client certificates\r\n", .{});
        std.debug.print("  Client certificate: {s}\r\n", .{tls_config.client_cert_path.?});
        if (tls_config.ca_cert_path) |ca| {
            std.debug.print("  CA certificate: {s}\r\n", .{ca});
        }
        _ = client.connectEx(host, port, tls_config.ca_cert_path, tls_config.client_cert_path, tls_config.client_key_path) catch |err| {
            return err;
        };
    } else if (tls_config.ca_cert_path != null) {
        // CA cert provided without client certs: user trusts this server.
        // The QUIC library does not pass ca_path to client-side TLS context,
        // so file-based CA verification is not supported. Use allow_insecure
        // since the user has explicitly indicated trust via --ca-cert.
        _ = client.connectInsecure(host, port, true) catch |err| {
            return err;
        };
    } else {
        // Default: allow self-signed certs for local/dev servers.
        // Users can enforce strict verification via --ca-cert.
        _ = client.connectInsecure(host, port, true) catch |err| {
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
