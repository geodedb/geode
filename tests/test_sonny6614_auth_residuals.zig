//! SONNY-6614: SecurityManager residuals of the MFA work.
//!
//! (1) `hydrateSecurityManagerFromGraph` (server_init) had no errdefer: an
//!     allocation failure part way leaked the SecurityManager and every
//!     record it had copied (a role's name and description duped before a
//!     `roles.put` that failed went nowhere), and a role-membership entry
//!     made by `getOrPut` was left with an undefined value when its list
//!     could not be allocated. The load moved to the named module
//!     `auth_startup_hydration` (`hydrateSecurityManager`) so this drives
//!     the code the server runs, under every allocation failure.
//! (2) DROP USER (`geode.auth.user_delete`) left the user's MFA state (TOTP
//!     secret, recovery codes, enabled flag) in SecurityManager.
//!
//! No mocks: the real AuthGraphManager, SecurityManager and executor.
//!
// CANARY: REQ=REQ-SONNY-6614-SM-RESIDUALS; FEATURE="MFA authentication"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6614_auth_residuals.zig; OWNER=security; UPDATED=2026-11-15
const std = @import("std");
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

const HMAC_KEY = [_]u8{0x14} ** 32;
const user_pw = "Correct Horse Battery Staple 6614";

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
        self.admin = try self.sessions.createSession("root6614", "", .Admin, null, null, false, 0);
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

/// A security graph with what the SecurityManager load copies: built-in and
/// custom roles, users holding them, an MFA enrollment with recovery codes.
fn populate(agm: *AuthGraphManager) !void {
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    _ = try agm.createRole(&HMAC_KEY, "auditors6614", "custom role");
    var phc_buf: [256]u8 = undefined;
    const phc = try cheapPhc(&phc_buf, user_pw);
    _ = try agm.createUserWithRole(&HMAC_KEY, "u1_6614", "u1@example.com", phc, false, "readonly");
    _ = try agm.createUserWithRole(&HMAC_KEY, "u2_6614", "u2@example.com", phc, true, null);
    var d: [3][32]u8 = undefined;
    for (&d, 0..) |*x, i| x.* = mfa.hashRecoveryCode(&[_]u8{ 'C', @intCast('0' + i) });
    try agm.enrollMfaWriteThrough(&HMAC_KEY, "u1_6614", "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP", &d);
}

test "SONNY-6614 (1): the SecurityManager load frees everything under every allocation failure" {
    if (comptime !@hasDecl(hydration, "hydrateSecurityManager")) {
        std.debug.print("SONNY-6614 (1): the SecurityManager load is server_init's private hydrateSecurityManagerFromGraph, with no errdefer\n", .{});
        return error.SecurityManagerLoadNotTestable;
    } else {
        var sec_store = try graph_store.GraphStore.init(testing.allocator);
        defer sec_store.deinit();
        var agm = try AuthGraphManager.init(testing.allocator, &sec_store);
        defer agm.deinit();
        agm.hmac_key = HMAC_KEY;
        try populate(&agm);

        var fail_index: usize = 0;
        var failures: usize = 0;
        while (fail_index < 100_000) : (fail_index += 1) {
            var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
            var loaded = hydration.hydrateSecurityManager(fa.allocator(), &agm, HMAC_KEY) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                failures += 1;
                continue;
            };
            defer loaded.sm.deinit();
            try testing.expect(!fa.has_induced_failure);
            try testing.expectEqual(@as(usize, 2), loaded.user_count);
            try testing.expect(loaded.sm.users.get((agm.storage.getUserByUsername("u1_6614") orelse return error.NoUser).id).?.recovery_codes.?.items.len == 3);
            break;
        }
        try testing.expect(failures > 10);
    }
}

test "SONNY-6614 (2): DROP USER clears the user's MFA state from SecurityManager" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try installMfaPersistence(&w.agm);
    try fx.expectRuns(ga, w.admin, "CREATE USER dm6614 SET PASSWORD '" ++ user_pw ++ "'");
    const issued = try setup(ga, w.admin, "dm6614");
    try fx.expectRuns(ga, w.admin, try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_enable('dm6614', '{s}')", .{try codeFor(ga, issued.secret)}));
    const uid = (try storedUser(&w.agm, "dm6614")).id;

    if (comptime !@hasDecl(hydration, "hydrateSecurityManager") or !@hasDecl(auth_dispatch, "setSecurityManagerHooks")) {
        std.debug.print("SONNY-6614 (2): geode.auth.user_delete has no way to reach SecurityManager; a dropped user's MFA state stays in it\n", .{});
        return error.SecurityManagerKeepsDroppedMfa;
    } else {
        var loaded = try hydration.hydrateSecurityManager(testing.allocator, &w.agm, HMAC_KEY);
        defer loaded.sm.deinit();
        const sm = &loaded.sm;
        auth_dispatch.setSecurityManagerHooks(hydration.securityManagerHooks(sm));
        defer auth_dispatch.setSecurityManagerHooks(.{});
        try testing.expect(sm.users.get(uid).?.mfa_secret != null);

        try fx.expectRuns(ga, w.admin, "DROP USER dm6614");
        if (sm.users.get(uid)) |u| {
            if (u.mfa_enabled or u.mfa_secret != null or (u.recovery_codes != null and u.recovery_codes.?.items.len > 0)) {
                std.debug.print("SONNY-6614 (2): after DROP USER SecurityManager still holds the user's MFA state (enabled={}, secret={}, codes={d})\n", .{ u.mfa_enabled, u.mfa_secret != null, if (u.recovery_codes) |c| c.items.len else 0 });
                return error.SecurityManagerKeepsDroppedMfa;
            }
        }
        // A recovery code of the dropped user is not redeemed.
        if (sm.authenticateWithMFA("dm6614", user_pw, 0, issued.codes[0])) |_| {
            return error.DroppedUsersRecoveryCodeRedeemed;
        } else |_| {}
    }
}
