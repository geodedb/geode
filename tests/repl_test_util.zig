const std = @import("std");
const geode = @import("geode");
const proto_util = @import("proto_test_util.zig");

var port_counter: std.atomic.Value(u16) = std.atomic.Value(u16).init(20000);

/// Prefer a kernel-assigned free port: the fixed 20000+ counter collides
/// with orphaned servers from a previously killed test run (two QUIC
/// servers on one UDP port split the packet stream and wedge the client).
/// Falls back to the counter only if the OS probe fails.
pub fn nextPort() u16 {
    return proto_util.getRandomPort() catch port_counter.fetchAdd(1, .monotonic);
}

pub const ServerFixture = struct {
    allocator: std.mem.Allocator,
    addr: []const u8,
    handle: proto_util.ServerHandle,

    pub fn deinit(self: *ServerFixture) void {
        self.handle.deinit();
        self.allocator.free(self.addr);
    }
};

pub fn startServer(allocator: std.mem.Allocator) !ServerFixture {
    const port = nextPort();
    const addr = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{port});
    const handle = try proto_util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        null,
    );
    return .{ .allocator = allocator, .addr = addr, .handle = handle };
}

pub fn connectSession(allocator: std.mem.Allocator, addr: []const u8) !geode.repl.repl_dispatch.ClientSession {
    // Use insecure mode for test certificates.
    geode.repl.quic_transport.setTlsConfig(.{ .insecure = true });

    var session = try geode.repl.repl_dispatch.ClientSession.init(
        allocator,
        addr,
        &geode.repl.quic_transport.transport,
    );
    errdefer session.deinit();

    try connectWithRetry(&session);
    return session;
}

// Zig 0.16: std.Thread.sleep was removed — same linux nanosleep compat shim
// shape proto_test_util.zig uses.
fn compatSleep(ns: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
}

fn connectWithRetry(session: *geode.repl.repl_dispatch.ClientSession) !void {
    var attempts: usize = 0;
    while (attempts < 20) : (attempts += 1) {
        if (attempts > 0) {
            compatSleep(50 * std.time.ns_per_ms);
        }

        session.connect() catch |err| {
            if (err == error.ConnectionRefused or err == error.WouldBlock) {
                continue;
            }
            return err;
        };

        const auth = session.helloWithAuth(
            proto_util.defaultUsername(),
            proto_util.defaultPassword(),
        ) catch |err| {
            session.disconnect();
            return err;
        };
        defer if (auth.error_message) |msg| session.allocator.free(msg);

        if (auth.success) return;
        session.disconnect();
    }
    return error.ConnectionFailed;
}
