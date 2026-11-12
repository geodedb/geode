// SONNY-6367 regression: the offline user CLI and the remaining auth
// procedure failures.
//
// 1. `geode user create --role`, `user update --role` and `user assign-role`
//    stored a role node and never gave it to the user (no HAS_ROLE edge), and
//    reported success: the user had no role (`none`). They now assign the
//    built-in role the way ALTER USER ... SET ROLE does
//    (`AuthGraphManager.setBuiltinRoleWriteThrough`), and refuse a role name
//    that is not built in (a custom role carries no privileges, SONNY-6292)
//    before changing anything. `user create` and `user import` with no
//    --role give the user `user`, as CREATE USER does.
// 2. `geode user list` printed `(role: user)` for every user, and `geode user
//    show` of a missing user printed made-up details and exited 0. They now
//    print the role the server resolves, and `show` of a missing user fails.
// 3. `geode user enable / disable` of a missing user, and the
//    `geode.auth.user_enable / user_disable` procedures, answered success.
// 4. `geode.auth.user_set_attribute`, `role_create` with no name,
//    `mfa_setup`, `mfa_verify`, `mfa_enable / mfa_disable` and `user_import`
//    answered 00000 with an error row; they are GQLSTATUS errors.
// 5. A user imported with `--algorithm blake2b` could never log in: the wire
//    login verified only Argon2id. It now verifies the legacy BLAKE2b format
//    too (the one geode_auth_lib accepts).
// 6. src/cli/user_storage_simple.zig and user_storage_secure.zig were dead
//    and are gone.
// 7. (tests/simple_stdio_test.sh, run as a script.)
// 8. CLAUDE.md gives the gql_conformance suite's real test count.
//
// CANARY: REQ=REQ-SONNY-6367-OFFLINE-USER-CLI; FEATURE="OfflineAuthStoreSafety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6367_offline_user_cli.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const util = @import("proto_test_util.zig");
const cli_auth = @import("cli_auth_helpers");
const auth_graph_manager = @import("auth_graph_manager");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const Role = user_mgmt.Role;
const linux = std.os.linux;

const binary_path = "./zig-out/bin/geode";
const hmac_hex = "6c" ** 32;
const HMAC_KEY = [_]u8{0x67} ** 32;

const bob_pw = "Correct Horse Battery Staple Seven";
const carol_pw = "Purple Elephant Dancing Quietly Nine";
const dan_pw = "Silver Mountain River Lantern Four";
const legacy_pw = "Amber Window Gentle Thunder Two";
const legacy_new_pw = "Copper Meadow Whisper Falcon Eight";

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

fn runOk(aa: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    const r = try runGeode(aa, args);
    if (r.code != 0) {
        std.debug.print("{s} {s} exited {d}:\n{s}\n", .{ args[1], args[2], r.code, r.output });
        return error.CommandFailed;
    }
    return r.output;
}

fn runRefused(aa: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    const r = try runGeode(aa, args);
    if (r.code == 0) {
        std.debug.print("{s} {s} {s} exited 0, want a failure:\n{s}\n", .{ args[1], args[2], args[3], r.output });
        return error.FailureReportedAsSuccess;
    }
    return r.output;
}

fn freshDir(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6367-{s}-{d}", .{ tag, nowMillis() });
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

const Expect = struct { user: []const u8, role: ?Role };

/// Open the store in process: each listed user's role, as the server
/// resolves it at login (`role_resolver.resolveRoleFromGraph`), or the user
/// is absent (`role == null`); the chain verifies.
fn expectRoles(dir: []const u8, expected: []const Expect) !void {
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    defer {
        cli_auth.deinitAndSaveCliAuth(pa, &mgr);
        graph_store.deinitGlobalStore();
    }
    for (expected) |e| {
        const record = mgr.storage.getUserByUsername(e.user);
        if (e.role) |want| {
            const r = record orelse {
                std.debug.print("user {s} is not stored\n", .{e.user});
                return error.UserNotStored;
            };
            const got = geode.security.role_resolver.resolveRoleFromGraph(mgr.storage.store, r);
            if (got != want) std.debug.print("user {s}: role {s}, want {s}\n", .{ e.user, got.toString(), want.toString() });
            try testing.expectEqual(want, got);
        } else if (record != null) {
            std.debug.print("user {s} is stored, want it absent\n", .{e.user});
            return error.UserUnexpectedlyStored;
        }
    }
    const kr = try AuthGraphManager.resolveExistingHmacKey(pa, dir);
    try mgr.verifyChain(&kr.key);
}

fn skipWithoutBinary() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
}

fn expectContains(output: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, output, needle) == null) {
        std.debug.print("output does not contain \"{s}\":\n{s}\n", .{ needle, output });
        return error.MissingOutput;
    }
}

// ---------------------------------------------------------------------------
// 1-3. Offline roles, list / show, enable / disable
// ---------------------------------------------------------------------------

test "SONNY-6367: offline user create / update --role and assign-role give the user the built-in role; a custom or unknown role is refused and changes nothing" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try bootstrappedStore(aa, "roles");
    defer removeDir(dir);

    _ = try runOk(aa, &.{ binary_path, "user", "create", "bob", "bob@example.com", "--password", bob_pw, "--role", "readonly", "--force", "--data-dir", dir });
    // No --role: `user`, as CREATE USER gives.
    _ = try runOk(aa, &.{ binary_path, "user", "create", "carol", "carol@example.com", "--password", carol_pw, "--force", "--data-dir", dir });
    try expectRoles(dir, &.{ .{ .user = "bob", .role = .ReadOnly }, .{ .user = "carol", .role = .User } });

    _ = try runOk(aa, &.{ binary_path, "user", "update", "bob", "--role", "readwrite", "--force", "--data-dir", dir });
    _ = try runOk(aa, &.{ binary_path, "user", "assign-role", "carol", "admin", "--force", "--data-dir", dir });
    try expectRoles(dir, &.{ .{ .user = "bob", .role = .ReadWrite }, .{ .user = "carol", .role = .Admin } });

    // A role that is not built in: refused, nothing changed.
    _ = try runOk(aa, &.{ binary_path, "role", "create", "auditors", "--data-dir", dir });
    _ = try runRefused(aa, &.{ binary_path, "user", "assign-role", "bob", "auditors", "--force", "--data-dir", dir });
    _ = try runRefused(aa, &.{ binary_path, "user", "update", "bob", "--role", "nosuchrole", "--force", "--data-dir", dir });
    _ = try runRefused(aa, &.{ binary_path, "user", "create", "dan", "dan@example.com", "--password", dan_pw, "--role", "nosuchrole", "--force", "--data-dir", dir });
    // assign-role of a user that does not exist.
    _ = try runRefused(aa, &.{ binary_path, "user", "assign-role", "nobody6367", "readonly", "--force", "--data-dir", dir });
    try expectRoles(dir, &.{
        .{ .user = "bob", .role = .ReadWrite },
        .{ .user = "carol", .role = .Admin },
        .{ .user = "dan", .role = null },
        .{ .user = "nobody6367", .role = null },
    });

    // `user import` gives its --role too.
    _ = try runOk(aa, &.{ binary_path, "user", "import", "erin", "--hash", "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHQ$aGFzaGhhc2g", "--role", "readonly", "--force", "--data-dir", dir });
    try expectRoles(dir, &.{.{ .user = "erin", .role = .ReadOnly }});
}

test "SONNY-6367: offline user list / show print the stored role, show and enable / disable of a missing user fail" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try bootstrappedStore(aa, "list");
    defer removeDir(dir);

    _ = try runOk(aa, &.{ binary_path, "user", "create", "bob", "bob@example.com", "--password", bob_pw, "--role", "readonly", "--force", "--data-dir", dir });
    _ = try runOk(aa, &.{ binary_path, "user", "create", "carol", "carol@example.com", "--password", carol_pw, "--role", "readwrite", "--force", "--data-dir", dir });

    const list = try runOk(aa, &.{ binary_path, "user", "list", "--data-dir", dir });
    try expectContains(list, "- bob (role: readonly)");
    try expectContains(list, "- carol (role: readwrite)");

    const show = try runOk(aa, &.{ binary_path, "user", "show", "carol", "--data-dir", dir });
    try expectContains(show, "Role: readwrite");
    _ = try runRefused(aa, &.{ binary_path, "user", "show", "nobody6367", "--data-dir", dir });

    _ = try runRefused(aa, &.{ binary_path, "user", "enable", "nobody6367", "--force", "--data-dir", dir });
    _ = try runRefused(aa, &.{ binary_path, "user", "disable", "nobody6367", "--force", "--data-dir", dir });
    // An existing user still works.
    _ = try runOk(aa, &.{ binary_path, "user", "disable", "bob", "--force", "--data-dir", dir });
    const shown = try runOk(aa, &.{ binary_path, "user", "show", "bob", "--data-dir", dir });
    try expectContains(shown, "Status: disabled");
}

// ---------------------------------------------------------------------------
// 5. A BLAKE2b import logs in over the wire
// ---------------------------------------------------------------------------

/// The legacy BLAKE2b format geode_auth_lib verifies: lowercase hex of
/// BLAKE2b-256(password ++ "geode-salt-secure-v2").
fn legacyBlake2bHex(password: []const u8) [64]u8 {
    var h = std.crypto.hash.blake2.Blake2b256.init(.{});
    h.update(password);
    h.update("geode-salt-secure-v2");
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

test "SONNY-6367: a user imported with --algorithm blake2b logs in over QUIC with its password, and a wrong password is refused" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try bootstrappedStore(aa, "blake2b");
    defer removeDir(dir);

    const hex = legacyBlake2bHex(legacy_pw);
    _ = try runOk(aa, &.{ binary_path, "user", "import", "legacy", "--hash", &hex, "--algorithm", "blake2b", "--role", "readwrite", "--force", "--data-dir", dir });

    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(allocator, &.{ binary_path, "serve", "--listen", addr, "--data-dir", dir }, util.TestEnv.standard());
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    {
        var wrong = try util.QuicProtoClient.connect(allocator, addr);
        defer wrong.deinit();
        var h = try wrong.hello(allocator, "legacy", legacy_new_pw);
        defer h.deinit(allocator);
        try testing.expect(!h.success);
    }
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var h = try client.hello(allocator, "legacy", legacy_pw);
    defer h.deinit(allocator);
    if (!h.success) std.debug.print("HELLO as the BLAKE2b-imported user refused: {s}\n", .{h.error_message});
    try testing.expect(h.success);

    // Changing the password stores an Argon2id hash; the new one logs in.
    var r = try client.executeAndCollect(allocator, "ALTER USER legacy SET PASSWORD '" ++ legacy_new_pw ++ "'", util.emptyParams(), 10);
    defer r.deinit(allocator);
    if (r.error_code) |c| {
        std.debug.print("ALTER USER legacy SET PASSWORD: {s} {?s}\n", .{ c, r.error_message });
        return error.QueryRefused;
    }
    var again = try util.QuicProtoClient.connect(allocator, addr);
    defer again.deinit();
    var h2 = try again.hello(allocator, "legacy", legacy_new_pw);
    defer h2.deinit(allocator);
    try testing.expect(h2.success);
}

test "SONNY-6367: user_management.verifyPassword accepts the legacy BLAKE2b format and refuses a wrong password or a malformed hash" {
    const hex = legacyBlake2bHex(legacy_pw);
    try testing.expect(try user_mgmt.verifyPassword(legacy_pw, &hex));
    try testing.expect(!try user_mgmt.verifyPassword(legacy_new_pw, &hex));
    // Uppercase hex of the same digest is the same hash.
    var upper: [64]u8 = undefined;
    _ = std.ascii.upperString(&upper, &hex);
    try testing.expect(try user_mgmt.verifyPassword(legacy_pw, &upper));
    // 63 hex digits, a non-hex digit: no hash format, refused.
    try testing.expect(!try user_mgmt.verifyPassword(legacy_pw, hex[0..63]));
    var bad = hex;
    bad[10] = 'z';
    try testing.expect(!try user_mgmt.verifyPassword(legacy_pw, &bad));
}

// ---------------------------------------------------------------------------
// 3-4. Procedure failures are GQLSTATUS errors
// ---------------------------------------------------------------------------

fn agmOf(ctx: ?*anyopaque) *AuthGraphManager {
    return @ptrCast(@alignCast(ctx.?));
}

/// `server_init.writerCreateUser`.
fn writerCreateUser(ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: Role) anyerror!void {
    const agm = agmOf(ctx);
    _ = try agm.createUserWithRole(&agm.hmac_key, username, email, password_hash, role == .Admin, if (role == .Admin) null else role.toString());
}

const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    admin: []const u8 = "",
    auth_was: bool,
    allow_was: bool,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        _ = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);

        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);

        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        user_mgmt.setPersistentUserWriter(.{
            .ctx = @ptrCast(&self.agm),
            .create_fn = &writerCreateUser,
        });

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root6367", "", .Admin, null, null, false, 0);
    }

    fn deinit(self: *World) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        user_mgmt.setPersistentUserWriter(null);
        user_mgmt.deinitUserStore();
        AuthGraphManager.setGlobal(null);
        self.agm.deinit();
        self.sec_store.deinit();
        gps.setInsecureAllowAll(self.allow_was);
        user_mgmt.setAuthEnabled(self.auth_was);
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }
};

fn expectCode(ga: std.mem.Allocator, session: []const u8, query: []const u8, want: []const u8) !void {
    const resp = try fx.execute(ga, session, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            if (!std.mem.eql(u8, e.code, want)) std.debug.print("{s}: {s} {s}, want {s}\n", .{ query, e.code, e.message, want });
            try testing.expectEqualStrings(want, e.code);
        },
        else => {
            std.debug.print("{s}: answered 00000, want {s}\n", .{ query, want });
            return error.FailureReportedAsSuccess;
        },
    }
}

test "SONNY-6367: user_enable / user_disable / user_set_attribute / role_create / user_import failures are GQLSTATUS errors" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    try fx.expectRuns(ga, w.admin, "CREATE USER carol6367 SET PASSWORD '" ++ carol_pw ++ "'");

    // A user that does not exist: 42704 for an Admin.
    try expectCode(ga, w.admin, "CALL geode.auth.user_enable('nobody6367')", "42704");
    try expectCode(ga, w.admin, "CALL geode.auth.user_disable('nobody6367')", "42704");
    try expectCode(ga, w.admin, "CALL geode.auth.user_set_attribute('nobody6367', 'dept', 'eng')", "42704");
    // Missing arguments: 22023.
    try expectCode(ga, w.admin, "CALL geode.auth.user_set_attribute('', 'dept', 'eng')", "22023");
    try expectCode(ga, w.admin, "CALL geode.auth.role_create('', 'no name')", "22023");
    try expectCode(ga, w.admin, "CALL geode.auth.user_import('', 'abc', 'argon2id')", "22023");
    try expectCode(ga, w.admin, "CALL geode.auth.user_import('frank6367', '', 'argon2id')", "22023");
    try expectCode(ga, w.admin, "CALL geode.auth.user_import('frank6367', 'abc', 'md5')", "22023");
    // Import over an existing user: 42710.
    try expectCode(ga, w.admin, "CALL geode.auth.user_import('carol6367', 'abc', 'argon2id')", "42710");
    // What works still works.
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.user_disable('carol6367')");
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.user_set_attribute('carol6367', 'dept', 'eng')");
}

test "SONNY-6367: mfa_setup / mfa_verify / mfa_enable / mfa_disable failures are GQLSTATUS errors" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    try fx.expectRuns(ga, w.admin, "CREATE USER mfa6367 SET PASSWORD '" ++ carol_pw ++ "'");
    try fx.expectRuns(ga, w.admin, "CREATE USER mfb6367 SET PASSWORD '" ++ bob_pw ++ "'");

    // A user that does not exist.
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_setup('nobody6367')", "42704");
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_verify('nobody6367', '123456')", "42704");
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_enable('nobody6367', '123456')", "42704");
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_disable('nobody6367')", "42704");

    // Not enrolled: 55000.
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_verify('mfb6367', '123456')", "55000");
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_enable('mfb6367', '123456')", "55000");

    // A missing or malformed code: 22023.
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_enable('mfa6367')", "22023");
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_enable('mfa6367', '12345')", "22023");
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_enable('mfa6367', 'abcdef')", "22023");
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_disable('mfa6367', '12')", "22023");

    // Enrolled, a code that does not verify: 28000.
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_setup('mfa6367')");
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_enable('mfa6367', '000000')", "28000");
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_verify('mfa6367', '000000')", "28000");
    // Locked out after the fifth failure: 53400.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try expectCode(ga, w.admin, "CALL geode.auth.mfa_verify('mfa6367', '000000')", "28000");
    }
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_verify('mfa6367', '000000')", "53400");

    // Disable without a code still works (admin recovery).
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_disable('mfa6367')");
}

// ---------------------------------------------------------------------------
// 6, 8. Dead code, the documented suite count
// ---------------------------------------------------------------------------

fn readFileAlloc(aa: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = try f.readPositionalAll(io, &buf, off);
        if (n == 0) break;
        try out.appendSlice(aa, buf[0..n]);
        off += n;
        if (n < buf.len) break;
    }
    return out.items;
}

test "SONNY-6367: the dead offline user stores are gone" {
    const io = std.Io.Threaded.global_single_threaded.io();
    for ([_][]const u8{ "src/cli/user_storage_simple.zig", "src/cli/user_storage_secure.zig" }) |path| {
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
            std.debug.print("{s} is still in the tree; nothing imports it\n", .{path});
            return error.DeadCodePresent;
        } else |_| {}
    }
}

test "SONNY-6367: CLAUDE.md gives the gql_conformance suite's real test count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const suite = readFileAlloc(aa, "tests/gql_conformance.zig") catch return error.SkipZigTest;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, suite, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "test \"")) count += 1;
    }
    const want = try std.fmt.allocPrint(aa, "{d}/{d}", .{ count, count });

    const doc = readFileAlloc(aa, "CLAUDE.md") catch return error.SkipZigTest;
    var mentions: usize = 0;
    var doc_lines = std.mem.splitScalar(u8, doc, '\n');
    while (doc_lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "gql_conformance") orelse continue;
        // The count follows the suite's name on the line.
        const rest = line[at..];
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (!std.ascii.isDigit(rest[i])) continue;
            var j = i;
            while (j < rest.len and (std.ascii.isDigit(rest[j]) or rest[j] == '/')) j += 1;
            const token = rest[i..j];
            if (std.mem.indexOfScalar(u8, token, '/') != null) {
                mentions += 1;
                if (!std.mem.eql(u8, token, want)) {
                    std.debug.print("CLAUDE.md says gql_conformance {s}; the suite has {d} tests\n  {s}\n", .{ token, count, line });
                    return error.DocumentedCountWrong;
                }
                break;
            }
            i = j;
        }
    }
    try testing.expect(mentions > 0);
}
