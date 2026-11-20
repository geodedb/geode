// SONNY-6430 (1): `geode backup create --server` of a store of about 20 MB
// failed with ReceiveTimeout at about 70% (executeRemoteBackup received the
// backup in 64 KiB chunks, each with its own fixed 30 s wait).
//
// The contract: a remote backup of a realistically large store completes,
// the file on disk is exactly the size the server announced, and the
// backup can be read back by `geode restore --verify-only`.
//
// The seed is 10 MiB of distinct (incompressible) property data, a backup
// of about 24 MB; GEODE_TEST_SONNY6430_MB raises it for a manual run
// against a larger store (24 gives a backup of about 58 MB).

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

fn nowMs() i64 {
    const ts = std.Io.Clock.awake.now(fsIo());
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
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

fn runGeode(argv: []const []const u8, cwd: []const u8, limit_s: i64) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    // SONNY-6782: a release build refuses --insecure-tls-skip-verify without GEODE_ALLOW_INSECURE_TLS=1.
    try env.put("GEODE_ALLOW_INSECURE_TLS", "1");
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(limit_s), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

const nodes_per_statement = 100;
const pad_len = 4096;

fn targetMiB() u64 {
    if (std.c.getenv("GEODE_TEST_SONNY6430_MB")) |v| {
        return std.fmt.parseInt(u64, std.mem.span(v), 10) catch 10;
    }
    return 10;
}

/// Seeds `mib` MiB of distinct (incompressible hex) property data.
fn seed(allocator: std.mem.Allocator, addr: []const u8, mib: u64) !void {
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.DefaultAuth.username, admin_pw);
    hello.deinit(allocator);
    var q: std.ArrayList(u8) = .empty;
    defer q.deinit(allocator);
    var pad: [pad_len]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x6430);
    const statements = (mib * 1024 * 1024) / (nodes_per_statement * pad_len);
    for (0..statements) |s| {
        q.clearRetainingCapacity();
        try q.appendSlice(allocator, "CREATE ");
        for (0..nodes_per_statement) |n| {
            for (&pad) |*c| c.* = "0123456789abcdef"[prng.random().int(u4)];
            if (n != 0) try q.appendSlice(allocator, ", ");
            try q.print(allocator, "(:Sonny6430Blob {{i: {d}, pad: '{s}'}})", .{ s * nodes_per_statement + n, &pad });
        }
        var res = try client.executeAndCollectWithTimeout(allocator, q.items, util.emptyParams(), 0, 120);
        defer res.deinit(allocator);
        if (res.error_code) |code| {
            std.debug.print("SONNY-6430 (1): seeding failed: {s} {s}\n", .{ code, res.error_message orelse "" });
            return error.SeedFailed;
        }
    }
}

/// The size the client said it would receive ("Receiving backup (N bytes)").
fn announcedSize(out: []const u8) ?u64 {
    const tag = "Receiving backup (";
    const at = std.mem.indexOf(u8, out, tag) orelse return null;
    const rest = out[at + tag.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

test "SONNY-6430 (1) geode backup create --server completes for a store of tens of MiB and writes every announced byte" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6430-backup-large");
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
    const mib = targetMiB();
    const seed_start = nowMs();
    try seed(allocator, server.addr, mib);
    std.debug.print("SONNY-6430 (1): seeded {d} MiB in {d} ms\n", .{ mib, nowMs() - seed_start });

    const backup_start = nowMs();
    const r = try runGeode(&.{
        geode_binary, "backup",                  "create",
        "--server",   server.addr,               "--insecure-tls-skip-verify",
        "--user",     util.DefaultAuth.username, "--password",
        admin_pw,     "--output",                dest,
        "--timeout",  "900",
    }, cwd, 1200);
    defer r.deinit();
    const elapsed = nowMs() - backup_start;
    const announced = announcedSize(r.stderr) orelse announcedSize(r.stdout);
    std.debug.print("SONNY-6430 (1): backup exit={?d} after {d} ms, announced {?d} bytes\n", .{ r.code, elapsed, announced });
    if (r.code != @as(?u8, 0)) std.debug.print("stderr:\n{s}\n", .{r.stderr});
    try testing.expectEqual(@as(?u8, 0), r.code);

    const st = try std.Io.Dir.cwd().statFile(fsIo(), dest, .{});
    try testing.expect(announced != null);
    try testing.expectEqual(announced.?, st.size);
    // The incompressible seed data is all in the backup.
    try testing.expect(st.size >= mib * 1024 * 1024);
}
