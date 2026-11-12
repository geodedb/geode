// SONNY-6377 item 1 regression: `geode query` must never send a write again
// once the server may already have applied it.
//
// Root cause (reproduced on fix/sonny738-security-20261111, Debug build):
// `geode query --file` on a file over 16 KiB ships each 32 KiB chunk as one
// program. A chunk of 400 CREATEs takes ~38 s in a Debug server (about 13
// fdatasync calls per statement), longer than the default 30 s `--timeout`,
// so the client's read timed out (error.Timeout) while the server was still
// applying the chunk. executeChunkedQueries counted ANY Zig error from the
// transport as "the server rejected the chunk" and replayed its statements one
// by one on a new connection, so every statement landed twice:
//
//     Executing chunk 1-400 of 400 statements...
//     Error executing chunk: error.Timeout
//     Chunk 1-400 was rejected; retrying its 400 statements individually...
//     MATCH (n:GoodProbe) RETURN count(n)  ->  800
//
// (test-cli-file-chunked: 400 expected, 800 found; 800 expected, 1276 found.)
// The suspected auto-retry in executeQuicQuery is not the cause: it retries
// only error.ConnectionFailed, which executeQueryOnConnection raises only
// from the HELLO exchange, before the query is sent.
//
// The gRPC path had the same class of defect in executeGrpcQuery: any error
// other than a timeout or an incomplete response retried the whole query on
// a new connection, even after the Execute request had been sent, so a
// connection reset after the server applied a CREATE ran it up to three
// times.
//
// Contract pinned here:
//   1. A chunk whose request was sent and that got no answer is not replayed;
//      the run stops, says the statements may have been applied, and exits
//      non-zero (4 for a timeout, as a single query does). Exactly 400 nodes.
//   2. Over gRPC, a connection that fails after the Execute request was sent
//      is not retried: one Execute reaches the server, one node, exit 1.
//
// CANARY: REQ=REQ-SONNY-6377-QUERY-NO-RESEND; FEATURE="ChunkedExecution"; ASPECT=NoResendAfterSend; STATUS=TESTED; TEST=tests/test_sonny6377_query_no_resend.zig; OWNER=cli; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const linux = std.os.linux;

pub const binary_path = "./zig-out/bin/geode";
pub const admin_user = util.DefaultAuth.username;
pub const admin_pw = util.DefaultAuth.password;

fn nowMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    var req = linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&req, null);
}

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

pub const Run = struct { code: u8, output: []const u8 };

/// Run the geode binary with `args` and wait for it (`deadline_ms` at most).
/// stdout and stderr are merged into one transcript.
pub fn runGeode(aa: std.mem.Allocator, args: []const []const u8, deadline_ms: i64) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(aa);
    if (getenv("PATH")) |p| try env.put("PATH", p);
    if (getenv("HOME")) |p| try env.put("HOME", p);
    try env.put("GEODE_LOG_LEVEL", "warn");
    const child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var output: std.ArrayList(u8) = .empty;
    const pid = child.id orelse return error.NoPid;
    inline for (.{ child.stdout, child.stderr }) |maybe| {
        if (maybe) |f| {
            const flags = linux.fcntl(f.handle, std.posix.F.GETFL, 0);
            _ = linux.fcntl(f.handle, std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
        }
    }
    const t0 = nowMillis();
    var code: u8 = 255;
    while (true) {
        var buf: [4096]u8 = undefined;
        inline for (.{ child.stdout, child.stderr }) |maybe| {
            if (maybe) |f| {
                while (true) {
                    const n = linux.read(f.handle, &buf, buf.len);
                    if (@as(isize, @bitCast(n)) <= 0) break;
                    try output.appendSlice(aa, buf[0..n]);
                }
            }
        }
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid) {
            code = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 255;
            break;
        }
        if (nowMillis() - t0 > deadline_ms) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            std.debug.print("geode client never exited; transcript:\n{s}\n", .{output.items});
            return error.ClientHung;
        }
        sleepMs(20);
    }
    inline for (.{ child.stdout, child.stderr }) |maybe| {
        if (maybe) |f| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = linux.read(f.handle, &buf, buf.len);
                if (@as(isize, @bitCast(n)) <= 0) break;
                try output.appendSlice(aa, buf[0..n]);
            }
            f.close(io);
        }
    }
    return .{ .code = code, .output = output.items };
}

pub fn skipWithoutBinary() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
}

pub fn freshDir(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6377-{s}-{d}", .{ tag, nowMillis() });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

pub fn removeDir(dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
}

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Pull the integer out of the CLI's `{"c":N}` JSON row.
fn countFromJson(transcript: []const u8) ?i64 {
    const needle = "\"c\":";
    const at = std.mem.indexOf(u8, transcript, needle) orelse return null;
    var i = at + needle.len;
    while (i < transcript.len and transcript[i] == ' ') i += 1;
    const start = i;
    while (i < transcript.len and std.ascii.isDigit(transcript[i])) i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(i64, transcript[start..i], 10) catch null;
}

pub fn readCount(aa: std.mem.Allocator, addr: []const u8, label: []const u8) !i64 {
    const q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN count(n) AS c", .{label});
    const r = try runGeode(aa, &.{ binary_path, "query", "--server", addr, "--insecure", "--no-saved-session", "--format", "json", "-U", admin_user, "-P", admin_pw, q }, 120_000);
    if (r.code != 0) {
        std.debug.print("count read-back exited {d}:\n{s}\n", .{ r.code, r.output });
        return error.ReadBackFailed;
    }
    return countFromJson(r.output) orelse error.ReadBackNoRow;
}

/// Read the count until it has not changed for `stable_reads` reads in a
/// row (the server may still be applying a chunk the client gave up on).
fn settledCount(aa: std.mem.Allocator, addr: []const u8, label: []const u8) !i64 {
    const stable_reads: usize = 3;
    const t0 = nowMillis();
    var last: i64 = -1;
    var same: usize = 0;
    while (nowMillis() - t0 < 240_000) {
        const c = try readCount(aa, addr, label);
        if (c == last and c > 0) {
            same += 1;
            if (same + 1 >= stable_reads) return c;
        } else {
            same = 0;
        }
        last = c;
        sleepMs(2_000);
    }
    return last;
}

pub const Server = struct {
    proc: util.ServerHandle,
    addr: []const u8,
    grpc_addr: ?[]const u8 = null,

    pub fn start(allocator: std.mem.Allocator, dir: []const u8, grpc_port: ?u16) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var grpc_addr: ?[]const u8 = null;
        errdefer if (grpc_addr) |g| allocator.free(g);
        var proc = if (grpc_port) |gp| blk: {
            grpc_addr = try util.formatAddr(allocator, gp);
            break :blk try util.spawnServer(
                allocator,
                &.{ binary_path, "serve", "--listen", addr, "--data-dir", dir, "--listen-grpc", grpc_addr.? },
                util.TestEnv.grpcPlaintext(),
            );
        } else try util.spawnServer(allocator, &.{ binary_path, "serve", "--listen", addr, "--data-dir", dir }, util.TestEnv.standard());
        errdefer proc.deinit();
        try util.waitForServerReady(allocator, addr, 60_000);
        if (grpc_addr) |g| try util.waitForGrpcServerReady(allocator, g, 60_000);
        return .{ .proc = proc, .addr = addr, .grpc_addr = grpc_addr };
    }

    pub fn stop(self: *Server, allocator: std.mem.Allocator) void {
        self.proc.deinit();
        allocator.free(self.addr);
        if (self.grpc_addr) |g| allocator.free(g);
    }
};

// ---------------------------------------------------------------------------
// 1. A chunk the client timed out on is not replayed.
// ---------------------------------------------------------------------------

/// 400 padded CREATEs: over the 16 KiB chunking threshold, inside one 32 KiB
/// chunk (the shape of test_cli_file_chunked.zig's fixture).
pub fn buildChunk(aa: std.mem.Allocator, label: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    var line: [256]u8 = undefined;
    for (0..400) |i| {
        try buf.appendSlice(aa, try std.fmt.bufPrint(
            &line,
            "CREATE (n:{s} {{i: {d}, pad: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'}});\n",
            .{ label, i },
        ));
    }
    return buf.toOwnedSlice(aa);
}

test "SONNY-6377: geode query --file does not replay a chunk whose request was sent and timed out" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try freshDir(aa, "chunk");
    defer removeDir(dir);
    var s = try Server.start(testing.allocator, dir, null);
    defer s.stop(testing.allocator);

    const label = "Sonny6377Chunk";
    const content = try buildChunk(aa, label);
    try testing.expect(content.len > 16 * 1024 and content.len < 32 * 1024);
    const path = try std.fmt.allocPrint(aa, "{s}/chunk.gql", .{dir});
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = content });

    // A 4 s deadline for a chunk the server needs far longer for (~38 s in a
    // Debug build): the client gives up while the server is applying it.
    const r = try runGeode(aa, &.{ binary_path, "query", "--server", s.addr, "--insecure", "--no-saved-session", "--format", "json", "-U", admin_user, "-P", admin_pw, "--timeout", "4", "--file", path }, 300_000);

    if (!contains(r.output, "using chunked execution")) {
        std.debug.print("fixture did not chunk:\n{s}\n", .{r.output});
        return error.FixtureDidNotChunk;
    }
    // Guard: the chunk really did outlast the client's deadline. Without it
    // this test would pass for the wrong reason on a server fast enough to
    // answer a 400-statement program in 4 s.
    if (!contains(r.output, "Timeout") and !contains(r.output, "timed out")) {
        std.debug.print("the chunk did not time out (server answered within 4 s):\n{s}\n", .{r.output});
        return error.FixtureChunkDidNotTimeOut;
    }

    const persisted = try settledCount(aa, s.addr, label);

    var violations: usize = 0;
    if (contains(r.output, "retrying its")) {
        std.debug.print("VIOLATION: a chunk whose request was sent and timed out was replayed statement by statement\n", .{});
        violations += 1;
    }
    if (persisted != 400) {
        std.debug.print("VIOLATION: {d} nodes persisted; expected 400 (each statement applied once)\n", .{persisted});
        violations += 1;
    }
    if (r.code != 4) {
        std.debug.print("VIOLATION: exited {d}; expected 4 (timeout_error, as a single query that times out)\n", .{r.code});
        violations += 1;
    }
    if (!contains(r.output, "may still be executing")) {
        std.debug.print("VIOLATION: the run did not say the chunk may still be executing on the server\n", .{});
        violations += 1;
    }
    if (violations > 0) {
        std.debug.print("transcript:\n{s}\n", .{r.output});
        return error.ChunkReplayedAfterSend;
    }
}

// ---------------------------------------------------------------------------
// 2. Over gRPC, a connection that fails after the Execute request was sent is
//    not retried.
// ---------------------------------------------------------------------------

const H2_DATA: u8 = 0x0;
const H2_HEADERS: u8 = 0x1;
const H2_END_STREAM: u8 = 0x1;
/// grpc_query_transport.execute_stream_id: the Execute RPC rides stream 3.
const execute_stream_id: u32 = 3;
const h2_preface_len: usize = 24;

fn netIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn readSome(fd: std.posix.fd_t, buf: []u8) ?usize {
    const n = std.posix.read(fd, buf) catch return null;
    if (n == 0) return null;
    return n;
}

fn readExactFd(fd: std.posix.fd_t, dest: []u8) bool {
    var total: usize = 0;
    while (total < dest.len) {
        const n = std.posix.read(fd, dest[total..]) catch return false;
        if (n == 0) return false;
        total += n;
    }
    return true;
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) bool {
    var total: usize = 0;
    while (total < bytes.len) {
        const rc = linux.write(fd, bytes[total..].ptr, bytes.len - total);
        const signed: isize = @bitCast(rc);
        if (signed == -4) continue; // EINTR
        if (signed <= 0) return false;
        total += @intCast(signed);
    }
    return true;
}

/// A TCP relay in front of the real gRPC listener. It forwards the client's
/// frames to the server verbatim; once the whole Execute request (the DATA
/// frame that ends stream 3) has been forwarded, it stops passing the
/// server's answer on, gives the server time to apply the statement, and
/// resets the client's connection (SO_LINGER 0), so the client's read fails
/// with ECONNRESET after its request was applied. Not a mock: the CLI, the
/// wire protocol and the server are real; the relay injects one transport
/// fault and counts the Execute requests the server received.
pub const ResetProxy = struct {
    server: std.Io.net.Server,
    port: u16,
    upstream_port: u16,
    executes: std.atomic.Value(u32) = .init(0),
    /// SONNY-6425: Execute requests relayed in full (answered) before the
    /// relay starts resetting; 0 resets the first one.
    pass_executes: u32 = 0,
    stop_flag: std.atomic.Value(bool) = .init(false),
    accept_thread: ?std.Thread = null,
    gpa: std.mem.Allocator,

    pub fn start(gpa: std.mem.Allocator, upstream_port: u16) !*ResetProxy {
        const self = try gpa.create(ResetProxy);
        errdefer gpa.destroy(self);
        var bound: u16 = 0;
        var server: std.Io.net.Server = undefined;
        var attempts: usize = 0;
        while (attempts < 50) : (attempts += 1) {
            const p = try util.getRandomPort();
            const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch unreachable;
            server = std.Io.net.IpAddress.listen(&addr, netIo(), .{ .reuse_address = true }) catch continue;
            bound = p;
            break;
        }
        if (bound == 0) return error.NoFreeProxyPort;
        self.* = .{ .server = server, .port = bound, .upstream_port = upstream_port, .gpa = gpa };
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn stop(self: *ResetProxy) void {
        self.stop_flag.store(true, .release);
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch unreachable;
        if (std.Io.net.IpAddress.connect(&addr, netIo(), .{ .mode = .stream })) |s| {
            s.close(netIo());
        } else |_| {}
        if (self.accept_thread) |t| t.join();
        self.server.deinit(netIo());
        self.gpa.destroy(self);
    }

    fn acceptLoop(self: *ResetProxy) void {
        while (!self.stop_flag.load(.acquire)) {
            const client = self.server.accept(netIo()) catch return;
            if (self.stop_flag.load(.acquire)) {
                client.close(netIo());
                return;
            }
            // One session at a time: the CLI connects, fails, and (before
            // the fix) reconnects, strictly in sequence.
            self.session(client);
        }
    }

    const Pump = struct {
        from: std.posix.fd_t,
        to: std.posix.fd_t,
        stall: *std.atomic.Value(bool),

        fn run(self: *Pump) void {
            var buf: [16 * 1024]u8 = undefined;
            while (true) {
                const n = readSome(self.from, &buf) orelse return;
                if (self.stall.load(.acquire)) continue;
                if (!writeAllFd(self.to, buf[0..n])) return;
            }
        }
    };

    fn session(self: *ResetProxy, client: std.Io.net.Stream) void {
        var client_closed = false;
        defer if (!client_closed) client.close(netIo());
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.upstream_port) catch unreachable;
        const upstream = std.Io.net.IpAddress.connect(&addr, netIo(), .{ .mode = .stream }) catch return;
        defer upstream.close(netIo());
        const cfd = client.socket.handle;
        const ufd = upstream.socket.handle;

        var stall = std.atomic.Value(bool).init(false);
        var pump = Pump{ .from = ufd, .to = cfd, .stall = &stall };
        const s2c = std.Thread.spawn(.{}, Pump.run, .{&pump}) catch return;
        defer s2c.join();
        // Whatever ends the session, unblock the pump's read.
        defer _ = linux.shutdown(ufd, 2);

        var preface: [h2_preface_len]u8 = undefined;
        if (!readExactFd(cfd, &preface)) return;
        if (!writeAllFd(ufd, &preface)) return;

        var payload: [64 * 1024]u8 = undefined;
        while (true) {
            var header: [9]u8 = undefined;
            if (!readExactFd(cfd, &header)) return;
            const length: usize = (@as(usize, header[0]) << 16) | (@as(usize, header[1]) << 8) | @as(usize, header[2]);
            const frame_type = header[3];
            const flags = header[4];
            const stream_id: u32 = (@as(u32, header[5] & 0x7F) << 24) | (@as(u32, header[6]) << 16) | (@as(u32, header[7]) << 8) | @as(u32, header[8]);
            if (length > payload.len) return;
            if (length > 0 and !readExactFd(cfd, payload[0..length])) return;
            if (frame_type == H2_DATA and stream_id == execute_stream_id and (flags & H2_END_STREAM) != 0 and
                self.executes.load(.acquire) > self.pass_executes)
            {
                // Withhold the answer from the moment the request is complete.
                stall.store(true, .release);
            }
            if (!writeAllFd(ufd, &header)) return;
            if (length > 0 and !writeAllFd(ufd, payload[0..length])) return;
            if (frame_type == H2_HEADERS and stream_id == execute_stream_id) {
                _ = self.executes.fetchAdd(1, .monotonic);
            }
            if (stall.load(.acquire)) {
                // Let the server apply the statement, then reset the client.
                sleepMs(1_000);
                const linger = extern struct { onoff: c_int, secs: c_int }{ .onoff = 1, .secs = 0 };
                std.posix.setsockopt(cfd, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger)) catch {};
                client.close(netIo());
                client_closed = true;
                return;
            }
        }
    }
};

test "SONNY-6377: geode query over gRPC does not resend a query whose connection failed after it was sent" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try freshDir(aa, "grpc");
    defer removeDir(dir);
    const grpc_port = try util.getRandomPort();
    var s = try Server.start(testing.allocator, dir, grpc_port);
    defer s.stop(testing.allocator);

    const proxy = try ResetProxy.start(testing.allocator, grpc_port);
    defer proxy.stop();
    const proxy_addr = try std.fmt.allocPrint(aa, "127.0.0.1:{d}", .{proxy.port});

    const label = "Sonny6377Grpc";
    const q = try std.fmt.allocPrint(aa, "CREATE (:{s} {{n: 1}})", .{label});
    const r = try runGeode(aa, &.{ binary_path, "query", "--grpc", "--server", proxy_addr, "--insecure", "--no-saved-session", "--format", "json", "-U", admin_user, "-P", admin_pw, q }, 120_000);

    const executes = proxy.executes.load(.acquire);
    if (executes == 0) {
        std.debug.print("the query never reached the server through the relay:\n{s}\n", .{r.output});
        return error.FixtureNoExecute;
    }
    const persisted = try readCount(aa, s.addr, label);

    var violations: usize = 0;
    if (executes != 1) {
        std.debug.print("VIOLATION: the server received the Execute request {d} times; expected 1\n", .{executes});
        violations += 1;
    }
    if (persisted != 1) {
        std.debug.print("VIOLATION: {d} nodes persisted; expected 1\n", .{persisted});
        violations += 1;
    }
    if (r.code != 1) {
        std.debug.print("VIOLATION: exited {d}; expected 1 (general_error)\n", .{r.code});
        violations += 1;
    }
    if (!contains(r.output, "may or may not have executed")) {
        std.debug.print("VIOLATION: the client did not say the statement may have executed\n", .{});
        violations += 1;
    }
    if (violations > 0) {
        std.debug.print("transcript:\n{s}\n", .{r.output});
        return error.QueryResentAfterSend;
    }
}
