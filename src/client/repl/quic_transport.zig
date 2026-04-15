const std = @import("std");
const repl_dispatch = @import("repl_dispatch.zig");
const pooled = @import("transport/thread_pool");
const zig_quic_bridge = @import("../zig_quic_bridge.zig");
const zig_client = zig_quic_bridge.zig_client;

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
    client: *zig_client.GeodeClient,
    owns_client: bool,
    // Single mutex guarding ALL QUIC client operations (read, write, poll).
    // Prevents data races between the keepalive thread and query I/O.
    client_mu: std.Thread.Mutex = .{},
    // Background keepalive thread state
    keepalive_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    keepalive_pool: ?*pooled.ThreadPool = null,

    fn startKeepalive(self: *QuicTransportConnection) void {
        const pool = pooled.ThreadPool.init(self.allocator, .{
            .num_threads = 1,
            .queue_capacity = 4,
        }) catch return;
        errdefer pool.deinit();
        pool.submitBlocking(.{
            .context = @ptrCast(self),
            .callback = runKeepaliveWorker,
        }) catch {
            pool.deinit();
            return;
        };
        self.keepalive_pool = pool;
    }

    fn stopKeepalive(self: *QuicTransportConnection) void {
        self.keepalive_stop.store(true, .release);
        if (self.keepalive_pool) |pool| {
            pool.deinit();
            self.keepalive_pool = null;
        }
    }

    fn keepaliveWorker(self: *QuicTransportConnection) void {
        while (!self.keepalive_stop.load(.acquire)) {
            // tryLock: if I/O is active (client_mu held), skip this cycle.
            // This ensures keepalive NEVER races with read/write/poll.
            if (self.client_mu.tryLock()) {
                self.client.pollTransport(0);
                self.client_mu.unlock();
            }
            // GAP-0276: Reduced from 500ms to 100ms for faster keepalive response
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    fn runKeepaliveWorker(ctx: *anyopaque) void {
        const self: *QuicTransportConnection = @ptrCast(@alignCast(ctx));
        self.keepaliveWorker();
    }
};

// Write pre-encoded length-prefixed protobuf message bytes to QUIC stream.
fn quicWriteAll(self: *repl_dispatch.TransportConnection, data: []const u8) !void {
    const ctx = self.context orelse return error.NotConnected;
    const impl: *QuicTransportConnection = @ptrCast(@alignCast(ctx));
    // Hold client_mu for entire write to prevent keepalive interference
    impl.client_mu.lock();
    defer impl.client_mu.unlock();
    try impl.client.sendRawFramed(data);
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

    while (true) {
        if (repl_dispatch.checkForInterrupt()) {
            return error.Interrupted;
        }

        impl.client_mu.lock();
        const result = impl.client.receiveRawFrame(allocator, 50);
        impl.client_mu.unlock();

        const body = result catch |err| {
            if (err == error.ReceiveTimeout) {
                if (std.time.milliTimestamp() - last_progress >= idle_timeout_ms) {
                    return error.WouldBlock;
                }
                continue;
            }
            if (err == error.ResponseTooLarge) {
                return error.MessageTooLarge;
            }
            return error.ConnectionResetByPeer;
        };
        errdefer allocator.free(body);

        if (max_size > 0 and body.len > max_size) return error.MessageTooLarge;
        last_progress = std.time.milliTimestamp();
        return body;
    }
}

fn quicDeinit(self: *repl_dispatch.TransportConnection) void {
    const ctx = self.context orelse {
        if (self.allocator) |alloc| alloc.destroy(self);
        return;
    };
    const impl: *QuicTransportConnection = @ptrCast(@alignCast(ctx));
    // Stop keepalive thread before closing stream/client
    impl.stopKeepalive();
    impl.client.closeStream();
    if (impl.owns_client) {
        impl.client.deinit();
        impl.allocator.destroy(impl.client);
    }
    impl.allocator.destroy(impl);
    if (self.allocator) |conn_alloc| conn_alloc.destroy(self);
}

fn quicConnect(allocator: std.mem.Allocator, addr: []const u8) !*repl_dispatch.TransportConnection {
    const parsed = try zig_quic_bridge.parseHostPort(addr, 3141);

    // Create QUIC client via the shared Zig client library.
    const client = try allocator.create(zig_client.GeodeClient);
    client.* = try zig_quic_bridge.initClient(
        allocator,
        parsed.host,
        parsed.port,
        .{
            .insecure = tls_config.insecure,
            .ca_cert_path = tls_config.ca_cert_path,
            .client_cert_path = tls_config.client_cert_path,
            .client_key_path = tls_config.client_key_path,
        },
        null,
        null,
    );
    errdefer {
        client.deinit();
        allocator.destroy(client);
    }
    try client.connect();

    // Create transport connection with background keepalive.
    const impl = try allocator.create(QuicTransportConnection);
    errdefer {
        impl.stopKeepalive();
        allocator.destroy(impl);
    }
    impl.* = .{
        .allocator = allocator,
        .client = client,
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
