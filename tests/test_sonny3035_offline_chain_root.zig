// SONNY-3035 regression: offline auth commands verify against the chain root
// whenever one exists, and write nothing before verification passes.
//
// SONNY-2798 made offline commands verify the `__geode_security` HMAC chain
// before a change. Two holes (rounds 9-11 review, L1 and L2):
// - L1: a store with zero records skipped verification even when a chain
//   root existed. Removing every record at rest (the root stays) and running
//   `geode auth init` bootstrapped a new admin into the store and sealed it.
// - L2: verification looked the HMAC key up with `resolveHmacKey`, which
//   writes a new random `.geode_hmac_key` when there is none; the new key
//   then failed to verify, and the refusal said nothing was changed.
//
// Now an empty store is one with no records and no chain root, and the key is
// looked up without generating one (`resolveExistingHmacKey`).
//
// CANARY: REQ=REQ-SONNY-3035-OFFLINE-CHAIN-ROOT; FEATURE="OfflineAuthStoreSafety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3035_offline_chain_root.zig; OWNER=security; UPDATED=2026-09-27

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const cli_auth = @import("cli_auth_helpers");
const auth_graph_manager = @import("auth_graph_manager");

const graph_store = geode.graph_store;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const linux = std.os.linux;

const binary_path = geode_test_bin.geode_exe;
const hmac_hex = "6b" ** 32;

fn nowMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

const Run = struct { code: u8, output: []const u8 };

/// Run the geode binary with `args` (no key in the environment) and wait for
/// it (60 s at most).
fn runGeode(aa: std.mem.Allocator, io: std.Io, args: []const []const u8) !Run {
    var env = std.process.Environ.Map.init(aa);
    if (getenv("PATH")) |p| try env.put("PATH", p);
    if (getenv("HOME")) |p| try env.put("HOME", p);
    try env.put("GEODE_DATA_DIR_LOCK_TIMEOUT_MS", "0");
    try env.put("GEODE_ADMIN_PASSWORD", "Correct Horse Battery Staple Seven");
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
        if (nowMillis() - t0 > 60_000) {
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

const Change = enum { remove_all_records, remove_key };

/// A data directory with a sealed store (the bootstrap admin and its role),
/// then changed at rest: every record removed (the chain root stays), or the
/// key file removed.
fn makeStore(aa: std.mem.Allocator, tag: []const u8, change: Change) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny3035-{s}-{d}", .{ tag, nowMillis() });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const key_path = try std.fmt.allocPrint(aa, "{s}/.geode_hmac_key", .{dir});
    const key_file = try std.Io.Dir.cwd().createFile(io, key_path, .{ .permissions = .fromMode(0o600) });
    try key_file.writeStreamingAll(io, hmac_hex);
    key_file.close(io);

    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    const kr = try AuthGraphManager.resolveHmacKey(pa, dir);
    _ = try mgr.bootstrapDefaultAdmin(&kr.key);
    try mgr.verifyChain(&kr.key);
    try testing.expect(mgr.storage.loadChainRoot() != null);
    switch (change) {
        .remove_all_records => {
            var users: std.ArrayList(u64) = .empty;
            var uit = mgr.storage.user_cache.keyIterator();
            while (uit.next()) |id| try users.append(pa, id.*);
            for (users.items) |id| try mgr.storage.removeUser(id);
            var roles: std.ArrayList(u64) = .empty;
            var rit = mgr.storage.role_cache.keyIterator();
            while (rit.next()) |id| try roles.append(pa, id.*);
            for (roles.items) |id| try mgr.storage.removeRole(id);
            try testing.expectEqual(@as(u64, 0), mgr.countAuthRecords());
        },
        .remove_key => try std.Io.Dir.cwd().deleteFile(io, key_path),
    }
    cli_auth.deinitAndSaveCliAuth(pa, &mgr);
    graph_store.deinitGlobalStore();
    return dir;
}

fn keyFilePresent(aa: std.mem.Allocator, dir: []const u8) !bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const key_path = try std.fmt.allocPrint(aa, "{s}/.geode_hmac_key", .{dir});
    std.Io.Dir.cwd().access(io, key_path, .{}) catch return false;
    return true;
}

fn binaryPresent() bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, binary_path, .{}) catch return false;
    return true;
}

test "SONNY-3035: a store whose records were all removed at rest keeps its chain root, and does not verify: offline changes are refused and auth init bootstraps nothing (L1)" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (!binaryPresent()) return error.GeodeBinaryMissing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const io_fs = std.Io.Threaded.global_single_threaded.io();

    const dir = try makeStore(aa, "emptied", .remove_all_records);
    defer std.Io.Dir.cwd().deleteTree(io_fs, dir) catch {};

    // In process: the check an offline command runs first refuses.
    {
        var process = std.heap.ArenaAllocator.init(testing.allocator);
        defer process.deinit();
        const pa = process.allocator();
        var mgr = try cli_auth.initCliAuthManager(pa, dir);
        const got = cli_auth.verifyChainBeforeChange(pa, &mgr);
        cli_auth.deinitAndSaveCliAuth(pa, &mgr);
        graph_store.deinitGlobalStore();
        try testing.expectError(error.AuthChainTampered, got);
    }

    // The CLI: auth init refuses, and so does a user change.
    const init = try runGeode(aa, io, &.{ binary_path, "auth", "init", "--data-dir", dir });
    if (init.code == 0 or std.mem.indexOf(u8, init.output, "does not verify") == null) {
        std.debug.print("auth init was not refused (exit {d}):\n{s}\n", .{ init.code, init.output });
        return error.AuthInitNotRefused;
    }
    const create = try runGeode(aa, io, &.{ binary_path, "user", "create", "eve", "eve@example.com", "--password", "Correct Horse Battery Staple Seven", "--force", "--data-dir", dir });
    if (create.code == 0 or std.mem.indexOf(u8, create.output, "does not verify") == null) {
        std.debug.print("user create was not refused (exit {d}):\n{s}\n", .{ create.code, create.output });
        return error.UserCreateNotRefused;
    }
}

test "SONNY-3035: verification with no key available writes no key file, and refuses (L2)" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (!binaryPresent()) return error.GeodeBinaryMissing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const io_fs = std.Io.Threaded.global_single_threaded.io();

    const dir = try makeStore(aa, "nokey", .remove_key);
    defer std.Io.Dir.cwd().deleteTree(io_fs, dir) catch {};
    try testing.expect(!try keyFilePresent(aa, dir));

    {
        var process = std.heap.ArenaAllocator.init(testing.allocator);
        defer process.deinit();
        const pa = process.allocator();
        var mgr = try cli_auth.initCliAuthManager(pa, dir);
        const got = cli_auth.verifyChainBeforeChange(pa, &mgr);
        cli_auth.deinitAndSaveCliAuth(pa, &mgr);
        graph_store.deinitGlobalStore();
        try testing.expectError(error.HmacKeyUnavailable, got);
    }
    try testing.expect(!try keyFilePresent(aa, dir));

    const create = try runGeode(aa, io, &.{ binary_path, "user", "create", "eve", "eve@example.com", "--password", "Correct Horse Battery Staple Seven", "--force", "--data-dir", dir });
    try testing.expect(create.code != 0);
    const verify = try runGeode(aa, io, &.{ binary_path, "auth", "verify", "--data-dir", dir });
    try testing.expect(verify.code != 0);
    try testing.expect(!try keyFilePresent(aa, dir));
}
