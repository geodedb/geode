// SONNY-6447 item 7: `geode query --file` over QUIC. When the server rejects
// a chunk, the CLI retries its statements one at a time on ONE new
// connection (`retryChunkStatementByStatement`). When that connection could
// not be opened or its HELLO failed, the caller printed "Error retrying chunk
// statement-by-statement", counted one error and went on with the NEXT chunk:
// the rejected chunk's statements were silently dropped and later chunks,
// which may depend on them, were sent. Every other transport failure of the
// chunked run stops it with the summary (SONNY-6377, SONNY-6425, SONNY-6436);
// this one now does too.
//
// The server, the CLI and the wire protocol are real. A UDP forwarder sits
// between them and passes the first QUIC connection (the chunk's: the server
// rejects the chunk, which holds a statement that does not parse, without
// running any of it), then drops every later connection's packets, as a
// network path that goes away does. The retry's connect then fails.
//
// CANARY: REQ=REQ-SONNY-6447-QUIC-RETRY-CONNECT-STOPS; FEATURE="ChunkedExecution"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6447_quic_retry_connect_stops.zig; OWNER=cli; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const test_ports = @import("test_ports.zig");
const h = @import("test_sonny6377_query_no_resend.zig");

const linux = std.os.linux;
const posix = std.posix;

const exe = geode_test_bin.geode_exe;
const label = "Sonny6447Retry";

fn sysOk(rc: usize) !usize {
    return switch (posix.errno(rc)) {
        .SUCCESS => rc,
        else => error.SyscallFailed,
    };
}

fn loopback(port: u16) linux.sockaddr.in {
    return .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
}

/// Forwards UDP between clients and the server on 127.0.0.1:`upstream_port`.
/// The first `allowed` client addresses (QUIC connections: each uses its own
/// socket) are forwarded; every later one's packets are dropped.
const Forwarder = struct {
    front: i32,
    port: u16,
    upstream_port: u16,
    allowed: usize,
    flows: [8]Flow = undefined,
    n_flows: usize = 0,
    dropped: [16]u16 = undefined,
    n_dropped: usize = 0,
    stop: std.atomic.Value(bool) = .init(false),

    const Flow = struct { client: linux.sockaddr.in, up: i32 };

    fn init(upstream_port: u16, allowed: usize) !Forwarder {
        const fd: i32 = @intCast(try sysOk(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)));
        errdefer _ = linux.close(fd);
        var addr = loopback(0);
        _ = try sysOk(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        _ = try sysOk(linux.getsockname(fd, @ptrCast(&addr), &len));
        return .{ .front = fd, .port = std.mem.bigToNative(u16, addr.port), .upstream_port = upstream_port, .allowed = allowed };
    }

    fn deinit(self: *Forwarder) void {
        for (self.flows[0..self.n_flows]) |f| _ = linux.close(f.up);
        _ = linux.close(self.front);
    }

    fn noteDropped(self: *Forwarder, client_port: u16) void {
        for (self.dropped[0..self.n_dropped]) |p| if (p == client_port) return;
        if (self.n_dropped < self.dropped.len) {
            self.dropped[self.n_dropped] = client_port;
            self.n_dropped += 1;
        }
    }

    fn run(self: *Forwarder) void {
        var buf: [65536]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            var fds: [9]linux.pollfd = undefined;
            fds[0] = .{ .fd = self.front, .events = linux.POLL.IN, .revents = 0 };
            for (self.flows[0..self.n_flows], 1..) |f, i| fds[i] = .{ .fd = f.up, .events = linux.POLL.IN, .revents = 0 };
            const nfds = self.n_flows + 1;
            const rc = linux.poll(&fds, nfds, 100);
            if (posix.errno(rc) != .SUCCESS or rc == 0) continue;
            if (fds[0].revents & linux.POLL.IN != 0) {
                var src: linux.sockaddr.in = undefined;
                var src_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
                const n_rc = linux.recvfrom(self.front, &buf, buf.len, 0, @ptrCast(&src), &src_len);
                if (posix.errno(n_rc) == .SUCCESS) self.fromClient(buf[0..n_rc], src);
            }
            for (self.flows[0..self.n_flows], 1..) |f, i| {
                if (fds[i].revents & linux.POLL.IN == 0) continue;
                const n_rc = linux.recvfrom(f.up, &buf, buf.len, 0, null, null);
                if (posix.errno(n_rc) != .SUCCESS) continue;
                _ = linux.sendto(self.front, &buf, n_rc, 0, @ptrCast(&f.client), @sizeOf(linux.sockaddr.in));
            }
        }
    }

    fn fromClient(self: *Forwarder, data: []const u8, src: linux.sockaddr.in) void {
        const flow = for (self.flows[0..self.n_flows]) |f| {
            if (f.client.port == src.port and f.client.addr == src.addr) break f;
        } else blk: {
            if (self.n_flows >= self.allowed or self.n_flows >= self.flows.len) {
                self.noteDropped(std.mem.bigToNative(u16, src.port));
                return;
            }
            const up_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
            if (posix.errno(up_rc) != .SUCCESS) return;
            const up: i32 = @intCast(up_rc);
            var dst = loopback(self.upstream_port);
            if (posix.errno(linux.connect(up, @ptrCast(&dst), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
                _ = linux.close(up);
                return;
            }
            self.flows[self.n_flows] = .{ .client = src, .up = up };
            self.n_flows += 1;
            break :blk self.flows[self.n_flows - 1];
        };
        _ = linux.sendto(flow.up, data.ptr, data.len, 0, null, 0);
    }
};

/// One chunk (about 32 KiB) whose last statement does not parse, then
/// CREATEs past the chunk limit (a second chunk).
fn buildFile(aa: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const pad = "p" ** 960;
    for (0..28) |i| try buf.print(aa, "CREATE (:{s} {{i: {d}, pad: '{s}'}});\n", .{ label, i, pad });
    try buf.appendSlice(aa, "CREATE (n:Sonny6447Bad {i: });\n");
    for (0..16) |i| try buf.print(aa, "CREATE (:{s} {{i: {d}, chunk: 2, pad: '{s}'}});\n", .{ label, 100 + i, pad });
    return buf.toOwnedSlice(aa);
}

test "SONNY-6447 item 7: when the QUIC retry of a rejected chunk cannot connect, the run stops with the summary; no later chunk is sent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try h.freshDir(aa, "sonny6447-retry-connect");
    defer h.removeDir(dir);
    const server_port = try test_ports.freeUdpPort();
    const addr = try util.formatAddr(aa, server_port);
    var server = try util.spawnServer(testing.allocator, &.{ exe, "serve", "--listen", addr, "--data-dir", dir }, util.TestEnv.standard());
    defer server.deinit();
    try util.waitForServerReady(testing.allocator, addr, 60_000);

    var fwd = try Forwarder.init(server_port, 1);
    defer fwd.deinit();
    const thread = try std.Thread.spawn(.{}, Forwarder.run, .{&fwd});
    defer {
        fwd.stop.store(true, .release);
        thread.join();
    }
    const via = try util.formatAddr(aa, fwd.port);

    const content = try buildFile(aa);
    try testing.expect(content.len > 32 * 1024);
    const path = try std.fmt.allocPrint(aa, "{s}/chunks.gql", .{dir});
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = content });

    const r = try h.runGeode(aa, &.{ exe, "query", "--server", via, "--insecure", "--no-saved-session", "--format", "json", "-U", h.admin_user, "-P", h.admin_pw, "--timeout", "10", "--file", path }, 600_000);

    if (!h.contains(r.output, "using chunked execution")) {
        std.debug.print("fixture did not chunk:\n{s}\n", .{r.output});
        return error.FixtureDidNotChunk;
    }
    if (!h.contains(r.output, "retrying its")) {
        std.debug.print("fixture: the chunk was not rejected and retried:\n{s}\n", .{r.output});
        return error.FixtureNoRetry;
    }

    // Nothing was written: the chunk was rejected whole, and its retry never
    // connected (read directly from the server, not through the forwarder).
    const counted = try h.runGeode(aa, &.{ exe, "query", "--server", addr, "--insecure", "--no-saved-session", "--format", "json", "-U", h.admin_user, "-P", h.admin_pw, "--timeout", "60", "MATCH (n:" ++ label ++ ") RETURN count(n) AS c" }, 120_000);

    var violations: usize = 0;
    if (std.mem.count(u8, r.output, "Executing chunk ") != 1) {
        std.debug.print("VIOLATION: the run went on to the next chunk after the retry could not connect\n", .{});
        violations += 1;
    }
    if (fwd.n_dropped > 1) {
        std.debug.print("VIOLATION: {d} connections were attempted after the retry's (expected none)\n", .{fwd.n_dropped - 1});
        violations += 1;
    }
    if (!h.contains(r.output, "Chunked execution complete")) {
        std.debug.print("VIOLATION: no chunked-execution summary was printed\n", .{});
        violations += 1;
    }
    if (!h.contains(r.output, "were not executed")) {
        std.debug.print("VIOLATION: the run did not say which statements were not executed\n", .{});
        violations += 1;
    }
    if (r.code == 0) {
        std.debug.print("VIOLATION: exited 0\n", .{});
        violations += 1;
    }
    if (!h.contains(counted.output, "\"c\":0") and !h.contains(counted.output, "\"c\": 0")) {
        std.debug.print("VIOLATION: nodes were written:\n{s}\n", .{counted.output});
        violations += 1;
    }
    if (violations > 0) {
        std.debug.print("transcript:\n{s}\n", .{r.output});
        return error.RunContinuedAfterRetryConnectFailed;
    }
}
