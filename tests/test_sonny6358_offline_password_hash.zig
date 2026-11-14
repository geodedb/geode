// SONNY-6358 regression: the offline `geode user create` and `geode user
// update --password` store an Argon2id hash, never the password, and leave a
// __geode_security chain that verifies, so the server starts and logs the
// user in with the password.
//
// They wrote the supplied password into the record's `password_hash` field
// as it was (src/cli/user_mgmt_cli.zig, the create and update paths), so the
// credential sat in the clear in the security graph and no login could ever
// succeed (the server verifies an Argon2id PHC string). On a store with no
// auth records yet, the change was not sealed at all: the server then
// refused to start (chain root missing).
//
// Each case runs the real `geode` binary as a subprocess against its own data
// directory, reads the stored record back in process, verifies the chain
// with the store's key, and then starts `geode serve` on the directory and
// logs in over QUIC.
//
// CANARY: REQ=REQ-SONNY-6358-OFFLINE-PASSWORD-HASH; FEATURE="OfflineAuthStoreSafety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6358_offline_password_hash.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const cli_auth = @import("cli_auth_helpers");
const auth_graph_manager = @import("auth_graph_manager");
const geode_auth = @import("geode_auth");
const util = @import("proto_test_util.zig");

const graph_store = geode.graph_store;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const linux = std.os.linux;

const binary_path = @import("geode_test_bin").geode_exe;
const hmac_hex = "6b" ** 32;

/// Policy-compliant passphrases, one per user and step.
const bob_first = "Correct Horse Battery Staple Seven";
const bob_second = "Purple Elephant Dancing Quietly Nine";
const carol_pw = "Silver Mountain River Lantern Four";
const dave_first = "Amber Window Gentle Thunder Two";
const dave_second = "Copper Meadow Whisper Falcon Eight";
const erin_pw = "Velvet Harbor Midnight Compass Six";

fn nowMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
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

fn freshDir(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6358-{s}-{d}", .{ tag, nowMillis() });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn removeDir(dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
}

/// A data directory with a key file and a sealed store (the bootstrap admin).
fn bootstrappedStore(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try freshDir(aa, tag);
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
    cli_auth.deinitAndSaveCliAuth(pa, &mgr);
    graph_store.deinitGlobalStore();
    return dir;
}

/// Open the store in process: each user's stored `password_hash` is an
/// Argon2id PHC string (not the password) that verifies the password, and
/// the chain verifies with the store's key.
fn expectStoredHashesAndChain(dir: []const u8, users: []const [2][]const u8) !void {
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    defer {
        cli_auth.deinitAndSaveCliAuth(pa, &mgr);
        graph_store.deinitGlobalStore();
    }
    for (users) |u| {
        const record = mgr.storage.getUserByUsername(u[0]) orelse {
            std.debug.print("user {s} is not stored\n", .{u[0]});
            return error.UserNotStored;
        };
        const stored = record.getPasswordHash();
        if (std.mem.indexOf(u8, stored, u[1]) != null) {
            std.debug.print("user {s}: the password is stored in the clear\n", .{u[0]});
            return error.PlaintextPasswordStored;
        }
        if (!std.mem.startsWith(u8, stored, "$argon2id$")) {
            std.debug.print("user {s}: stored password_hash is not an Argon2id PHC string\n", .{u[0]});
            return error.NotArgon2id;
        }
        try testing.expect(try geode_auth.verifyPasswordArgon2id(pa, u[1], stored));
    }
    const kr = try AuthGraphManager.resolveExistingHmacKey(pa, dir);
    mgr.verifyChain(&kr.key) catch |err| {
        std.debug.print("the chain does not verify after the offline change: {s}\n", .{@errorName(err)});
        return err;
    };
}

/// Start `geode serve` on `dir` and log each user in over QUIC with its
/// password.
fn expectServerLogins(dir: []const u8, users: []const [2][]const u8) !void {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(allocator, &.{ binary_path, "serve", "--listen", addr, "--data-dir", dir }, util.TestEnv.standard());
    defer server.deinit();
    util.waitForServerReady(allocator, addr, 30000) catch |err| {
        std.debug.print("the server did not start on the store the offline CLI changed: {s}\n", .{@errorName(err)});
        return err;
    };
    for (users) |u| {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var h = try client.hello(allocator, u[0], u[1]);
        defer h.deinit(allocator);
        if (!h.success) std.debug.print("HELLO as {s} refused: {s}\n", .{ u[0], h.error_message });
        try testing.expect(h.success);
    }
}

fn skipWithoutBinary() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
}

test "SONNY-6358: offline user create / update --password store an Argon2id hash, the chain verifies, and the server logs the users in" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try bootstrappedStore(aa, "sealed");
    defer removeDir(dir);

    // `user create` of a new user, then `user update --password` of it.
    try runOk(aa, &.{ binary_path, "user", "create", "bob", "bob@example.com", "--password", bob_first, "--force", "--data-dir", dir });
    try runOk(aa, &.{ binary_path, "user", "update", "bob", "--password", bob_second, "--force", "--data-dir", dir });
    // `user update --password` of a user that does not exist creates it.
    try runOk(aa, &.{ binary_path, "user", "update", "carol", "--password", carol_pw, "--email", "carol@example.com", "--force", "--data-dir", dir });
    // `user create` of a user that exists sets its password.
    try runOk(aa, &.{ binary_path, "user", "create", "dave", "dave@example.com", "--password", dave_first, "--force", "--data-dir", dir });
    try runOk(aa, &.{ binary_path, "user", "create", "dave", "dave@example.com", "--password", dave_second, "--force", "--data-dir", dir });

    const users = [_][2][]const u8{
        .{ "bob", bob_second },
        .{ "carol", carol_pw },
        .{ "dave", dave_second },
    };
    try expectStoredHashesAndChain(dir, &users);
    try expectServerLogins(dir, &users);
}

test "SONNY-6358: offline user create on a store with no auth records seals the chain, and the server starts and logs the user in" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try freshDir(aa, "empty");
    defer removeDir(dir);

    try runOk(aa, &.{ binary_path, "user", "create", "erin", "erin@example.com", "--password", erin_pw, "--force", "--data-dir", dir });

    const users = [_][2][]const u8{.{ "erin", erin_pw }};
    try expectStoredHashesAndChain(dir, &users);
    try expectServerLogins(dir, &users);
}
