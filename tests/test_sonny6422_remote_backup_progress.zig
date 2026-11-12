// CANARY: REQ=REQ-SONNY-6422-REMOTE-BACKUP-PROGRESS; FEATURE="CLI Backup"; ASPECT=ProgressPrintedOncePerStep; STATUS=TESTED; TEST=tests/test_sonny6422_remote_backup_progress.zig; OWNER=cli; UPDATED=2026-11-12
//
// SONNY-6422 (8): `geode backup create --server` (executeRemoteBackup)
// printed "  Progress: N%" after every received chunk whose running
// percentage was a multiple of 10, so a backup received in many chunks
// printed the same line again for every chunk that left the percentage on
// that multiple ("Progress: 0%" repeated for every chunk under 1%, then
// "10%" repeated, ...), and a step the transfer jumped over was never
// printed.
//
// The contract: each 10% step is printed at most once, in increasing
// order, and the transfer ends with "Progress: 100%".

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");
const util = @import("proto_test_util.zig");

const posix = std.posix;
const geode_binary = geode_test_bin.geode_exe;
const admin_pw = util.DefaultAuth.password;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

const Server = struct {
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    child: std.process.Child,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, cwd: []const u8, data_dir: []const u8) !Server {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        var env = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();
        inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
            if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
        }
        try env.put("GEODE_ADMIN_PASSWORD", admin_pw);
        try env.put("GEODE_LSP_PORT", "0");
        const addr = try util.formatAddr(allocator, try test_ports.freeUdpPort());
        errdefer allocator.free(addr);
        const inherit = std.c.getenv("GEODE_TEST_INHERIT_SERVER_STDERR") != null;
        const child = try std.process.spawn(threaded.io(), .{
            .argv = &.{ geode_binary, "serve", "--listen", addr, "--data-dir", data_dir },
            .environ_map = &env,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = if (inherit) .inherit else .ignore,
            .stderr = if (inherit) .inherit else .ignore,
        });
        var server: Server = .{ .threaded = threaded, .env = env, .child = child, .addr = addr };
        errdefer server.stop(allocator);
        try util.waitForServerReady(allocator, addr, 60_000);
        return server;
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        if (self.child.id) |pid| {
            posix.kill(pid, .TERM) catch {};
            var waited: u32 = 0;
            while (util.processAlive(pid) and waited < 30_000) : (waited += 100) sleepMs(100);
            if (util.processAlive(pid)) posix.kill(pid, .KILL) catch {};
            _ = self.child.wait(self.threaded.io()) catch {};
        }
        self.threaded.deinit();
        self.env.deinit();
        allocator.free(self.addr);
    }
};

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

fn runGeode(argv: []const []const u8, cwd: []const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(300), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

/// Statements of `nodes_per_statement` nodes, each with a distinct ~1 KiB
/// property, so the backup is several MiB and arrives in many chunks.
const statements = 40;
const nodes_per_statement = 100;
const pad_len = 1024;

fn seed(allocator: std.mem.Allocator, addr: []const u8) !void {
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.DefaultAuth.username, admin_pw);
    hello.deinit(allocator);
    var q: std.ArrayList(u8) = .empty;
    defer q.deinit(allocator);
    var pad: [pad_len]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x6422);
    for (0..statements) |s| {
        q.clearRetainingCapacity();
        try q.appendSlice(allocator, "CREATE ");
        for (0..nodes_per_statement) |n| {
            for (&pad) |*c| c.* = "0123456789abcdef"[prng.random().int(u4)];
            if (n != 0) try q.appendSlice(allocator, ", ");
            try q.print(allocator, "(:Sonny6422Blob {{i: {d}, pad: '{s}'}})", .{ s * nodes_per_statement + n, &pad });
        }
        var res = try client.executeAndCollectWithTimeout(allocator, q.items, util.emptyParams(), 0, 60);
        defer res.deinit(allocator);
        if (res.error_code) |code| {
            std.debug.print("SONNY-6422 (8): seeding failed: {s} {s}\n", .{ code, res.error_message orelse "" });
            return error.SeedFailed;
        }
    }
}

test "SONNY-6422 (8) geode backup create --server prints each 10% progress step at most once, in order, ending at 100%" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6422-backup-progress");
    defer root.remove();
    const cwd = try std.fmt.allocPrint(allocator, "{s}/cwd", .{root.path()});
    defer allocator.free(cwd);
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root.path()});
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
    const dest = try std.fmt.allocPrint(allocator, "{s}/full.backup", .{cwd});
    defer allocator.free(dest);

    var server = try Server.start(allocator, cwd, data_dir);
    defer server.stop(allocator);
    try seed(allocator, server.addr);

    const r = try runGeode(&.{
        geode_binary, "backup",                  "create",
        "--server",   server.addr,               "--insecure-tls-skip-verify",
        "--user",     util.DefaultAuth.username, "--password",
        admin_pw,     "--output",                dest,
        "--timeout",  "240",
    }, cwd);
    defer r.deinit();
    if (r.code != @as(?u8, 0)) std.debug.print("SONNY-6422 (8): backup failed: exit={?d}\nstderr:\n{s}\n", .{ r.code, r.stderr });
    try testing.expectEqual(@as(?u8, 0), r.code);

    var seen: [11]u32 = [_]u32{0} ** 11;
    var lines: u32 = 0;
    var last: i32 = -1;
    var in_order = true;
    for ([_][]const u8{ r.stdout, r.stderr }) |stream| {
        var it = std.mem.splitScalar(u8, stream, '\n');
        while (it.next()) |line| {
            const tag = "Progress: ";
            const at = std.mem.indexOf(u8, line, tag) orelse continue;
            const rest = line[at + tag.len ..];
            const pct_end = std.mem.indexOfScalar(u8, rest, '%') orelse continue;
            const pct = std.fmt.parseInt(u32, rest[0..pct_end], 10) catch continue;
            lines += 1;
            if (pct > 100 or pct % 10 != 0) {
                in_order = false;
                continue;
            }
            seen[pct / 10] += 1;
            if (@as(i32, @intCast(pct)) <= last) in_order = false;
            last = @intCast(pct);
        }
    }
    var dupes: u32 = 0;
    for (seen) |n| {
        if (n > 1) dupes += n - 1;
    }
    const ok = dupes == 0 and in_order and seen[10] == 1;
    if (!ok) {
        std.debug.print("SONNY-6422 (8): {d} progress lines, {d} repeated, in order={}, 100% printed {d}x; per step:", .{ lines, dupes, in_order, seen[10] });
        for (seen, 0..) |n, i| std.debug.print(" {d}%:{d}", .{ i * 10, n });
        std.debug.print("\n", .{});
    }
    try testing.expect(ok);
}
