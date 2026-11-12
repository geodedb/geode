// SONNY-6384 item 1 regression (found during SONNY-6377).
//
// After an offline `geode user …` change on a data directory, the server's
// later writes to `__geode_security` (CREATE USER, ALTER USER over the wire)
// must survive a SIGKILL, and the next start must load the security graph.
//
// Root cause (general graph persistence, not security code): a full engine
// checkpoint records `manifest.last_checkpoint_lsn = L` and compacts the
// shard WAL to empty, and the WAL library deletes its `graph.wal.ckpt`
// sidecar, the only place the WAL's LSN survives an empty file. If the
// process then ends without closing the engine (the offline CLI always did;
// a SIGKILL after any checkpoint does too), the next open numbers the WAL
// from 0 again while recovery replays from L: every later record is skipped
// (lost) after a crash, or only a torn tail past L is replayed.
//
// CANARY: REQ=REQ-SONNY-6384-OFFLINE-CRASH-DURABILITY; FEATURE="Auth DDL Persistence"; ASPECT=OfflineChangeThenCrash; STATUS=TESTED; TEST=tests/test_sonny6384_offline_change_crash_durability.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const linux = std.os.linux;
const graph_store = geode.graph_store;

// ---------------------------------------------------------------------------
// Storage level: any graph, a checkpoint, then hard crashes
// ---------------------------------------------------------------------------

/// Every shard's WAL numbers at or past the manifest's checkpoint LSN (the
/// invariant recovery relies on), and how many shards hold no WAL bytes.
fn walAnchors(mg: anytype) struct { behind: usize, empty: usize } {
    var behind: usize = 0;
    var empty: usize = 0;
    for (mg.engine.shards) |shard| {
        if (shard.wal.inner.currentLsn() < shard.manifest.last_checkpoint_lsn) behind += 1;
        if (shard.wal.inner.file_end == 0 and shard.manifest.last_checkpoint_lsn > 0) empty += 1;
    }
    return .{ .behind = behind, .empty = empty };
}

test "SONNY-6384: a write after a checkpoint, a hard crash and a reopen survives the next hard crash (any graph)" {
    const ta = testing.allocator;
    // A hard kill frees nothing: the crash phases leak by design.
    const pa = std.heap.page_allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);
    const graph = "g6384";
    var labels = [_][]const u8{"Doc6384"};

    // 1. A node, a full checkpoint (the WAL is compacted to empty), a crash.
    {
        const store = try graph_store.initGlobalStore(pa, data_dir);
        _ = try store.createNodeWithGraph(&labels, graph);
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        try adapter.checkpointAll();
        const mg = try adapter.getOrCreateGraph(graph);
        // The state under test: a shard whose WAL is empty after a checkpoint.
        try testing.expect(walAnchors(mg).empty > 0);
        graph_store.abandonGlobalStoreForCrashSim();
    }
    // 2. Reopen: the WAL numbers from the checkpoint on. A second node, a crash.
    {
        const store = try graph_store.initGlobalStore(pa, data_dir);
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        const mg = try adapter.getOrCreateGraph(graph);
        const anchors = walAnchors(mg);
        if (anchors.behind > 0) std.debug.print("{d} shard WAL(s) number below their manifest's checkpoint LSN after the reopen\n", .{anchors.behind});
        _ = try store.createNodeWithGraph(&labels, graph);
        graph_store.abandonGlobalStoreForCrashSim();
    }
    // 3. Both nodes are there.
    {
        const store = try graph_store.initGlobalStore(ta, data_dir);
        defer graph_store.deinitGlobalStore();
        const n = store.countNodesForGraph(graph, null);
        if (n != 2) std.debug.print("after the second hard crash the graph holds {d} node(s), want 2\n", .{n});
        try testing.expectEqual(@as(usize, 2), n);
    }
}

// ---------------------------------------------------------------------------
// End to end: the offline CLI, the server, SIGKILLs
// ---------------------------------------------------------------------------

const binary_path = "./zig-out/bin/geode";
const admin_user = util.DefaultAuth.username;
const admin_pw = util.DefaultAuth.password;
const offline_pw = "Correct Horse Battery Staple Seven";
const first_pw = "Copper Meadow Whisper Falcon One";
const second_pw = "Silver Harbor Quiet Lantern Three";

fn nowMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn skipWithoutBinary() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
}

fn freshDir(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6384-{s}-{d}", .{ tag, nowMillis() });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn removeDir(dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
}

const Run = struct { code: u8, output: []const u8 };

/// Run the geode binary with `args` and wait for it (120 s at most).
fn runGeode(aa: std.mem.Allocator, args: []const []const u8) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(aa);
    if (getenv("PATH")) |p| try env.put("PATH", p);
    if (getenv("HOME")) |p| try env.put("HOME", p);
    try env.put("GEODE_DATA_DIR_LOCK_TIMEOUT_MS", "0");
    const child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var output: std.ArrayList(u8) = .empty;
    const pid = child.id orelse return error.NoPid;
    const t0 = nowMillis();
    var code: u8 = 255;
    while (true) {
        var buf: [4096]u8 = undefined;
        inline for (.{ child.stdout, child.stderr }) |maybe| {
            if (maybe) |f| {
                const n = linux.read(f.handle, &buf, buf.len);
                if (@as(isize, @bitCast(n)) > 0) try output.appendSlice(aa, buf[0..n]);
            }
        }
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid) {
            code = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 255;
            break;
        }
        if (nowMillis() - t0 > 120_000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            return error.Timeout;
        }
        var req = linux.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = linux.nanosleep(&req, null);
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

fn runOk(aa: std.mem.Allocator, args: []const []const u8) !void {
    const r = try runGeode(aa, args);
    if (r.code != 0) {
        std.debug.print("{s} {s} exited {d}:\n{s}\n", .{ args[1], args[2], r.code, r.output });
        return error.CommandFailed;
    }
}

const Server = struct {
    proc: util.ServerHandle,
    addr: []const u8,

    fn start(allocator: std.mem.Allocator, dir: []const u8) !Server {
        const addr = try util.formatAddr(allocator, try util.getRandomPort());
        errdefer allocator.free(addr);
        var proc = try util.spawnServer(allocator, &.{ binary_path, "serve", "--listen", addr, "--data-dir", dir }, util.TestEnv.standard());
        errdefer proc.deinit();
        try util.waitForServerReady(allocator, addr, 60_000);
        return .{ .proc = proc, .addr = addr };
    }

    /// SIGKILL: no shutdown flush. What the server acknowledged must already
    /// be durable.
    fn kill(self: *Server, allocator: std.mem.Allocator) void {
        self.proc.deinit();
        allocator.free(self.addr);
    }
};

fn quicLogin(allocator: std.mem.Allocator, addr: []const u8, user: []const u8, pw: []const u8) !bool {
    var c = try util.QuicProtoClient.connect(allocator, addr);
    defer c.deinit();
    var h = try c.hello(allocator, user, pw);
    defer h.deinit(allocator);
    return h.success;
}

fn quicExec(allocator: std.mem.Allocator, addr: []const u8, user: []const u8, pw: []const u8, q: []const u8) !void {
    var c = try util.QuicProtoClient.connect(allocator, addr);
    defer c.deinit();
    var h = try c.hello(allocator, user, pw);
    defer h.deinit(allocator);
    if (!h.success) return error.LoginFailed;
    var r = try c.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 100, 60);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("`{s}` as {s}: {s} {?s}\n", .{ q, user, code, r.error_message });
        return error.QueryFailed;
    }
}

test "SONNY-6384: security-graph writes after an offline user change survive a SIGKILL and the graph loads" {
    try skipWithoutBinary();
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try freshDir(aa, "crash");
    defer removeDir(dir);

    // 1. A server bootstraps the store (admin, HMAC key), then dies.
    {
        var s = try Server.start(allocator, dir);
        s.kill(allocator);
    }
    // 2. An offline change.
    try runOk(aa, &.{ binary_path, "user", "create", "off6384", "off6384@example.com", "--password", offline_pw, "--role", "readwrite", "--force", "--data-dir", dir });
    // 3. The server writes the security graph over the wire, then dies.
    {
        var s = try Server.start(allocator, dir);
        defer s.kill(allocator);
        try testing.expect(try quicLogin(allocator, s.addr, "off6384", offline_pw));
        try quicExec(allocator, s.addr, admin_user, admin_pw, "CREATE USER wire6384 SET PASSWORD '" ++ first_pw ++ "' ROLE readwrite");
        try quicExec(allocator, s.addr, admin_user, admin_pw, "ALTER USER off6384 SET PASSWORD '" ++ second_pw ++ "'");
    }
    // 4. Everything acknowledged is there, and the graph loaded.
    var violations: usize = 0;
    {
        var s = try Server.start(allocator, dir);
        defer s.kill(allocator);
        if (!try quicLogin(allocator, s.addr, admin_user, admin_pw)) {
            std.debug.print("after the SIGKILL the admin cannot log in (the security graph did not load)\n", .{});
            violations += 1;
        }
        if (!try quicLogin(allocator, s.addr, "wire6384", first_pw)) {
            std.debug.print("after the SIGKILL the user created over the wire is gone\n", .{});
            violations += 1;
        }
        if (!try quicLogin(allocator, s.addr, "off6384", second_pw)) {
            std.debug.print("after the SIGKILL the ALTER USER password change is gone\n", .{});
            violations += 1;
        }
        if (try quicLogin(allocator, s.addr, "off6384", offline_pw)) {
            std.debug.print("after the SIGKILL the offline user's old password still logs in\n", .{});
            violations += 1;
        }
        // One more write on the recovered store, another crash, another start.
        try quicExec(allocator, s.addr, admin_user, admin_pw, "ALTER USER wire6384 SET PASSWORD '" ++ second_pw ++ "'");
    }
    {
        var s = try Server.start(allocator, dir);
        defer s.kill(allocator);
        if (!try quicLogin(allocator, s.addr, "wire6384", second_pw)) {
            std.debug.print("after the second SIGKILL the second ALTER USER is gone\n", .{});
            violations += 1;
        }
    }
    // The offline chain check still passes.
    const verify = try runGeode(aa, &.{ binary_path, "auth", "verify", "--data-dir", dir });
    if (verify.code != 0) {
        std.debug.print("geode auth verify exited {d}:\n{s}\n", .{ verify.code, verify.output });
        violations += 1;
    }
    if (violations > 0) return error.SecurityWriteNotDurable;
}
