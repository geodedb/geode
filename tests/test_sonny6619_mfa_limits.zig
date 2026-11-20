//! SONNY-6619: the server's MFA lockout survives a restart, and
//! SecurityManager follows the MFA procedures and DROP USER.
//!
//! (2) `geode.auth.mfa_verify` kept its attempt count and lockout in process
//!     memory only: a restart cleared a lockout. The lockout is now stored in
//!     the sealed `MfaAttempts` record (SONNY-6614) and loaded at startup.
//!     Only the transitions are stored (into lockout: the fifth failure; out
//!     of it: the first success after a stored record): a failure below the
//!     limit is counted in memory, so a failed guess does not re-seal the
//!     whole chain (which rewrites every record's HMAC) and an attacker
//!     cannot make every guess cost a chain seal.
//! (3) SecurityManager's copy of a user's MFA state followed neither
//!     mfa_setup (new secret and codes, MFA off) nor mfa_enable / disable.
//! (4) DROP USER cleared the user's MFA state from SecurityManager but left
//!     the user (password hash, roles, sessions) in it; it is removed.
//!
//! No mocks: the real executor, AuthGraphManager and SecurityManager, and
//! the callbacks and startup loads the server installs.
//!
// CANARY: REQ=REQ-SONNY-6619-MFA-LIMITS; FEATURE="MFA authentication"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6619_mfa_limits.zig; OWNER=security; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const auth_graph_manager = @import("auth_graph_manager");
const hydration = @import("auth_startup_hydration");

const um = geode.user_management;
const graph_store = geode.graph_store;
const gps = geode.security.gps;
const auth_dispatch = geode.auth_dispatch;
const mfa = geode.mfa_test_support;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const Role = um.Role;

const HMAC_KEY = [_]u8{0x19} ** 32;
const user_pw = "Correct Horse Battery Staple 6619";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn realMillis() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

fn agmOf(ctx: ?*anyopaque) *AuthGraphManager {
    return @ptrCast(@alignCast(ctx.?));
}

fn writerCreateUser(ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: Role) anyerror!void {
    const agm = agmOf(ctx);
    _ = try agm.createUserWithRole(&agm.hmac_key, username, email, password_hash, role == .Admin, if (role == .Admin) null else role.toString());
}

fn writerDeleteUser(ctx: ?*anyopaque, username: []const u8) anyerror!void {
    const agm = agmOf(ctx);
    try agm.deleteUserWriteThrough(&agm.hmac_key, username);
}

fn installMfaPersistence(agm: *AuthGraphManager) !void {
    if (comptime !@hasDecl(hydration, "mfaPersistCallbacks")) {
        std.debug.print("SONNY-6608 (4): the server has no MFA persistence: geode.auth.mfa_setup / mfa_enable / mfa_disable change process memory only\n", .{});
        return error.NoMfaPersistence;
    } else {
        auth_dispatch.setMfaPersistCallbacks(hydration.mfaPersistCallbacks(agm));
    }
}

fn uninstallMfaPersistence() void {
    if (comptime @hasDecl(auth_dispatch, "setMfaPersistCallbacks")) auth_dispatch.setMfaPersistCallbacks(.{});
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
        self.auth_was = um.isAuthEnabled();
        um.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);

        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);

        um.deinitUserStore();
        um.setPersistentUserResolver(null);
        try um.initUserStore(testing.allocator);
        um.setPersistentUserWriter(.{ .ctx = @ptrCast(&self.agm), .create_fn = &writerCreateUser, .delete_fn = &writerDeleteUser });

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root6619", "", .Admin, null, null, false, 0);
        auth_dispatch.deinitMfaStore();
    }

    fn deinit(self: *World) void {
        uninstallMfaPersistence();
        auth_dispatch.deinitMfaStore();
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        um.setPersistentUserWriter(null);
        um.deinitUserStore();
        AuthGraphManager.setGlobal(null);
        self.agm.deinit();
        self.sec_store.deinit();
        gps.setInsecureAllowAll(self.allow_was);
        um.setAuthEnabled(self.auth_was);
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }
};

/// mfa_setup's answer: the secret and the recovery codes it issued.
const Issued = struct { secret: []const u8, codes: []const []const u8 };

fn setup(ga: std.mem.Allocator, session: []const u8, user: []const u8) !Issued {
    const q = try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_setup('{s}')", .{user});
    const resp = try fx.execute(ga, session, q);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ q, e.code, e.message });
            return error.QueryFailed;
        },
        else => {},
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = session, .page_size = 8 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const page = switch ((pull.response orelse return error.MissingPayload).payload orelse return error.MissingPayload) {
        .page => |p| p,
        else => return error.UnexpectedPayload,
    };
    const vals = page.rows.items[0].values.items;
    const str = struct {
        fn f(v: anytype) ![]const u8 {
            return switch (v.kind orelse return error.UnexpectedRow) {
                .string_val => |s| s.value,
                else => error.UnexpectedRow,
            };
        }
    }.f;
    const secret_text = try str(vals[0]);
    const codes_text = try str(vals[1]);
    const sp = "MFA secret: ";
    const cp = "Recovery codes: ";
    if (!std.mem.startsWith(u8, secret_text, sp) or !std.mem.startsWith(u8, codes_text, cp)) return error.UnexpectedRow;
    var codes: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, codes_text[cp.len..], ' ');
    while (it.next()) |c| try codes.append(ga, c);
    return .{ .secret = secret_text[sp.len..], .codes = codes.items };
}

fn codeFor(ga: std.mem.Allocator, secret: []const u8) ![]const u8 {
    const code = try mfa.generateCodeFromBase32(ga, secret, realMillis(), 30, 6);
    return std.fmt.allocPrint(ga, "{d:0>6}", .{code});
}

fn storedUser(agm: *AuthGraphManager, name: []const u8) !@FieldType(AuthGraphManager, "storage").UserRecord {
    return agm.storage.getUserByUsername(name) orelse error.UserNotStored;
}

fn cheapPhc(buf: []u8, password: []const u8) ![]const u8 {
    const salt = [16]u8{ 6, 6, 0, 9, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var hash: [32]u8 = undefined;
    try std.crypto.pwhash.argon2.kdf(testing.allocator, &hash, password, &salt, .{ .t = 1, .m = 64, .p = 1 }, .argon2id, io());
    return std.fmt.bufPrint(buf, "$argon2id$v=19$m=64,t=1,p=1${x}${x}", .{ &salt, &hash });
}

fn requireAttempts() !void {
    if (comptime !@hasDecl(AuthGraphManager, "setMfaAttemptsWriteThrough")) {
        std.debug.print("SONNY-6619 (2): the server keeps its MFA lockout in process memory only\n", .{});
        return error.ServerLockoutNotStored;
    }
}

/// Reload what a restart reloads: the MFA store and attempt records.
fn restart(agm: *AuthGraphManager) !void {
    auth_dispatch.deinitMfaStore();
    _ = try hydration.hydrateMfaEnrollments(testing.allocator, agm);
}

test "SONNY-6619 (2): the server's MFA lockout is stored and survives a restart; a failure below the limit is not stored" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try installMfaPersistence(&w.agm);
    try fx.expectRuns(ga, w.admin, "CREATE USER lo6619 SET PASSWORD '" ++ user_pw ++ "'");
    const issued = try setup(ga, w.admin, "lo6619");
    const uid = (try storedUser(&w.agm, "lo6619")).id;

    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('lo6619', '000000')", "28000");
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('lo6619', '000000')", "28000");
    // Below the limit: counted in memory, not stored (no chain seal per guess).
    try testing.expect((try w.agm.mfaAttempts(uid)) == null);
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('lo6619', '000000')", "28000");
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('lo6619', '000000')", "28000");
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('lo6619', '000000')", "28000");
    try requireAttempts();
    const st = (try w.agm.mfaAttempts(uid)) orelse {
        std.debug.print("SONNY-6619 (2): the fifth failure locked the user out in memory only (no stored record)\n", .{});
        return error.ServerLockoutNotStored;
    };
    try testing.expectEqual(@as(u32, 5), st.fail_count);
    try testing.expect(st.lockout_until_ms > @as(i64, @intCast(realMillis())));
    try w.agm.verifyChain(&HMAC_KEY);

    // A restart keeps the lockout: a right code is refused.
    try restart(&w.agm);
    const right = try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_verify('lo6619', '{s}')", .{try codeFor(ga, issued.secret)});
    _ = try fx.expectRefused(ga, w.admin, right, "53400");

    // The lockout over (stored as expired), a right code verifies and the
    // stored record is reset.
    try w.agm.storage.setMfaAttempts(uid, .{ .fail_count = 5, .lockout_until_ms = 1 });
    try w.agm.sealChain(&HMAC_KEY);
    try restart(&w.agm);
    try fx.expectRuns(ga, w.admin, try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_verify('lo6619', '{s}')", .{try codeFor(ga, issued.secret)}));
    const after = (try w.agm.mfaAttempts(uid)) orelse return error.RecordGone;
    try testing.expectEqual(@as(u32, 0), after.fail_count);
    try testing.expectEqual(@as(i64, 0), after.lockout_until_ms);
    try w.agm.verifyChain(&HMAC_KEY);
}

fn buildSm(w: *World) !hydration.LoadedSecurityManager {
    return hydration.hydrateSecurityManager(testing.allocator, &w.agm, HMAC_KEY);
}

test "SONNY-6619 (3): SecurityManager follows mfa_setup, mfa_enable and mfa_disable" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try installMfaPersistence(&w.agm);
    try fx.expectRuns(ga, w.admin, "CREATE USER sf6619 SET PASSWORD '" ++ user_pw ++ "'");
    const uid = (try storedUser(&w.agm, "sf6619")).id;

    var loaded = try buildSm(&w);
    defer loaded.sm.deinit();
    const sm = &loaded.sm;
    auth_dispatch.setSecurityManagerHooks(hydration.securityManagerHooks(sm));
    defer auth_dispatch.setSecurityManagerHooks(.{});
    // SecurityManager authenticates with its own password hash; make it one
    // it can check quickly.
    {
        var phc_buf: [256]u8 = undefined;
        const u = sm.users.getPtr(uid).?;
        testing.allocator.free(u.password_hash);
        u.password_hash = try testing.allocator.dupe(u8, try cheapPhc(&phc_buf, user_pw));
    }

    const issued = try setup(ga, w.admin, "sf6619");
    {
        const u = sm.users.get(uid).?;
        if (u.mfa_secret == null or !std.mem.eql(u8, u.mfa_secret.?, issued.secret)) {
            std.debug.print("SONNY-6619 (3): after mfa_setup SecurityManager holds secret {?s}, want the issued one\n", .{u.mfa_secret});
            return error.SecurityManagerStale;
        }
        try testing.expect(!u.mfa_enabled);
        try testing.expectEqual(issued.codes.len, u.recovery_codes.?.items.len);
    }
    try fx.expectRuns(ga, w.admin, try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_enable('sf6619', '{s}')", .{try codeFor(ga, issued.secret)}));
    try testing.expect(sm.users.get(uid).?.mfa_enabled);
    _ = try sm.authenticateWithMFA("sf6619", user_pw, 0, issued.codes[0]);
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_disable('sf6619')");
    try testing.expect(!sm.users.get(uid).?.mfa_enabled);
}

test "SONNY-6619 (4): DROP USER removes the user from SecurityManager" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    try fx.expectRuns(ga, w.admin, "CREATE USER rm6619 SET PASSWORD '" ++ user_pw ++ "' ROLE readwrite");
    const uid = (try storedUser(&w.agm, "rm6619")).id;
    var loaded = try buildSm(&w);
    defer loaded.sm.deinit();
    const sm = &loaded.sm;
    auth_dispatch.setSecurityManagerHooks(hydration.securityManagerHooks(sm));
    defer auth_dispatch.setSecurityManagerHooks(.{});
    try testing.expect(sm.users.contains(uid));

    try fx.expectRuns(ga, w.admin, "DROP USER rm6619");
    if (sm.users.contains(uid) or sm.rbac.user_roles.contains(uid)) {
        std.debug.print("SONNY-6619 (4): after DROP USER SecurityManager still holds the user (users={}, roles={})\n", .{ sm.users.contains(uid), sm.rbac.user_roles.contains(uid) });
        return error.DroppedUserInSecurityManager;
    }
}
