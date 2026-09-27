// SONNY-2798 regression: offline auth commands verify the __geode_security
// chain before they change anything.
//
// Offline commands (`geode user reset-password`, `geode auth init`, ...) load
// the security graph as it is on disk, make their change, and some re-sign
// the whole chain (`sealChain`) without checking it first. Since SONNY-2791
// no seal signs a planted policy record without a kind, but a planted record
// that carries one was signed by the next offline change and took effect at
// the next server start:
//   - an explicit allow-write GPS policy (kind gps, USING true),
//   - a superuser user record,
//   - a graph grant.
// Every offline command that changes the store (user, role, policy, grant,
// revoke, apikey, auth init) now verifies the chain first and refuses a
// tampered one, changing nothing and pointing to `geode auth reseal`. After a
// verified change the command seals it, so a sequence of offline commands, and
// the next server start, verify.
//
// Each plant gets a store of its own, sealed and then changed at rest without
// the key; every command runs as a subprocess against it.
//
// CANARY: REQ=REQ-SONNY-2798-OFFLINE-VERIFY-FIRST; FEATURE="OfflineAuthStoreSafety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2798_offline_verify.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const cli_auth = @import("cli_auth_helpers");
const auth_graph_manager = @import("auth_graph_manager");

const graph_store = geode.graph_store;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const linux = std.os.linux;

const binary_path = "./zig-out/bin/geode";
const hmac_hex = "5a" ** 32;
const strong_password = "Correct Horse Battery Staple Seven";

fn nowMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

const Run = struct { code: u8, output: []const u8 };

/// Run the geode binary with `args` and wait for it (60 s at most).
fn runGeode(aa: std.mem.Allocator, io: std.Io, args: []const []const u8) !Run {
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
        if (nowMillis() - t0 > 60_000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            return error.Timeout;
        }
        var req = linux.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = linux.nanosleep(&req, null);
    }
    // Drain what is left.
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

const Plant = enum { allow_write_policy, superuser, grant };

/// A data directory with a sealed store (the bootstrap admin), and, unless
/// `plant` is null, one record written at rest without the key.
fn makeStore(aa: std.mem.Allocator, tag: []const u8, plant: ?Plant) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny2798-{s}-{d}", .{ tag, nowMillis() });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const key_path = try std.fmt.allocPrint(aa, "{s}/.geode_hmac_key", .{dir});
    const key_file = try std.Io.Dir.cwd().createFile(io, key_path, .{ .permissions = .fromMode(0o600) });
    try key_file.writeStreamingAll(io, hmac_hex);
    key_file.close(io);

    // The CLI's own process shape: its own arena, released at "exit".
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    const kr = try AuthGraphManager.resolveHmacKey(pa, dir);
    const admin = try mgr.bootstrapDefaultAdmin(&kr.key);
    try mgr.verifyChain(&kr.key);
    if (plant) |p| switch (p) {
        .allow_write_policy => try mgr.storage.persistPolicy(.{
            .policy_id = mgr.storage.nextPolicyId(),
            .name = "planted-allow-write",
            .description = "",
            .graph = "*",
            .table = "",
            .operation = 2,
            .permissive = true,
            .enabled = true,
            .using_clause = "true",
            .check_clause = null,
            .audit_level = 0,
            .created_by = 0,
            .kind = .gps,
            .mode = .create,
        }),
        .superuser => {
            const id = mgr.next_user_id;
            try mgr.storage.persistUser(id, "mallory", "mallory@example.com", "$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA", "");
            const node = mgr.storage.user_nodes.get(id) orelse return error.PlantFailed;
            try mgr.storage.store.setNodeProperty(node, "is_superuser", .{ .Bool = true });
        },
        .grant => try mgr.storage.persistGraphGrant(987, admin.user_id, "hr", 1),
    };
    cli_auth.deinitAndSaveCliAuth(pa, &mgr);
    graph_store.deinitGlobalStore();
    return dir;
}

/// Does the store's chain verify?
fn chainVerifies(dir: []const u8) !bool {
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    const kr = try AuthGraphManager.resolveHmacKey(pa, dir);
    const ok = if (mgr.verifyChain(&kr.key)) |_| true else |_| false;
    cli_auth.deinitAndSaveCliAuth(pa, &mgr);
    graph_store.deinitGlobalStore();
    return ok;
}

/// `args`, copied into `aa` (an argv must outlive the call that built it).
fn argvOf(aa: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    return aa.dupe([]const u8, args);
}

/// The offline commands that change the store, as run against `dir`. The
/// user commands pass --force past the live-server probe: this test process
/// keeps files of the store it built open, and the probe would refuse for
/// that reason first.
fn commands(aa: std.mem.Allocator, dir: []const u8) ![]const []const []const u8 {
    var list: std.ArrayList([]const []const u8) = .empty;
    try list.append(aa, try argvOf(aa, &.{ binary_path, "user", "create", "bob", "bob@example.com", "--password", strong_password, "--force", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "user", "reset-password", "geode", "--new-password", strong_password, "--force", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "user", "disable", "geode", "--force", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "user", "assign-role", "geode", "reader", "--force", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "user", "delete", "bob", "--force", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "role", "create", "auditor", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "role", "delete", "auditor", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "policy", "create", "orders-rls", "--table", "orders", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "policy", "delete", "orders-rls", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "grant", "read", "--to", "geode", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "revoke", "read", "--from", "geode", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "apikey", "create", "--user", "geode", "--data-dir", dir }));
    try list.append(aa, try argvOf(aa, &.{ binary_path, "auth", "init", "--data-dir", dir }));
    return list.items;
}

fn binaryPresent() bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, binary_path, .{}) catch return false;
    return true;
}

test "SONNY-2798: every offline command refuses a store with a planted record, and signs nothing" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (!binaryPresent()) return error.GeodeBinaryMissing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const io_fs = std.Io.Threaded.global_single_threaded.io();

    var failures: usize = 0;
    for ([_]Plant{ .allow_write_policy, .superuser, .grant }) |plant| {
        const dir = try makeStore(aa, @tagName(plant), plant);
        defer std.Io.Dir.cwd().deleteTree(io_fs, dir) catch {};
        // The plant broke the chain.
        try testing.expect(!try chainVerifies(dir));

        for (try commands(aa, dir)) |argv| {
            const run = try runGeode(aa, io, argv);
            const refused = run.code != 0 and
                std.mem.indexOf(u8, run.output, "refusing to run") != null and
                std.mem.indexOf(u8, run.output, "does not verify") != null;
            if (!refused) {
                std.debug.print("{s}: '{s} {s}' was not refused (exit {d}):\n{s}\n", .{ @tagName(plant), argv[1], argv[2], run.code, run.output });
                failures += 1;
            }
        }
        // No command signed the plant: the chain still fails.
        if (try chainVerifies(dir)) {
            std.debug.print("{s}: an offline command signed the planted record\n", .{@tagName(plant)});
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-2798: on an intact store offline changes go through and are sealed, so the next one verifies" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (!binaryPresent()) return error.GeodeBinaryMissing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const io_fs = std.Io.Threaded.global_single_threaded.io();

    const dir = try makeStore(aa, "intact", null);
    defer std.Io.Dir.cwd().deleteTree(io_fs, dir) catch {};
    const sequence = [_][]const []const u8{
        try argvOf(aa, &.{ binary_path, "user", "create", "carol", "carol@example.com", "--password", strong_password, "--force", "--data-dir", dir }),
        try argvOf(aa, &.{ binary_path, "role", "create", "auditor", "--data-dir", dir }),
        try argvOf(aa, &.{ binary_path, "policy", "create", "orders-rls", "--table", "orders", "--data-dir", dir }),
        try argvOf(aa, &.{ binary_path, "grant", "read", "--to", "carol", "--data-dir", dir }),
    };
    for (sequence) |argv| {
        const run = try runGeode(aa, io, argv);
        if (run.code != 0) {
            std.debug.print("'{s} {s}' failed (exit {d}):\n{s}\n", .{ argv[1], argv[2], run.code, run.output });
            return error.OfflineChangeRefused;
        }
        // Each change was sealed: the chain verifies after it.
        try testing.expect(try chainVerifies(dir));
    }
}
