//! SONNY-6609: the TOTP secret is encrypted at rest, the recovery-code
//! digests reach SecurityManager, and DROP USER reports what it could not do.
//!
//! (1) The user record's `mfa_secret` held the base32 TOTP secret in
//!     plaintext: anyone who could read the data directory (or a backup,
//!     which carries no HMAC key) could generate the user's codes. It is now
//!     sealed with AES-256-GCM under a key derived (HKDF-SHA256) from the
//!     security graph's HMAC key, with a random nonce, the user id bound as
//!     associated data. A secret stored in plaintext before is sealed when
//!     the server loads it.
//! (3) SecurityManager was hydrated with the user's secret but not its
//!     recovery codes, so `authenticateWithMFA` could not redeem a stored
//!     code.
//! (2) `geode.auth.user_delete` (DROP USER) answered "deleted <name>" for a
//!     user that does not exist; it is 42704 now (DROP USER IF EXISTS stays
//!     a no-op).
//!
//! No mocks: the real executor through the gRPC handlers, the real
//! AuthGraphManager and SecurityManager, the startup loads the server runs.
//!
// CANARY: REQ=REQ-SONNY-6609-MFA-AT-REST; FEATURE="MFA authentication"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6609_mfa_at_rest.zig; OWNER=security; UPDATED=2026-11-15
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

const HMAC_KEY = [_]u8{0x69} ** 32;
const user_pw = "Correct Horse Battery Staple 6609";

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
        self.admin = try self.sessions.createSession("root6609", "", .Admin, null, null, false, 0);
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

fn requireSeal() !void {
    if (comptime !@hasDecl(AuthGraphManager, "openMfaSecret")) {
        std.debug.print("SONNY-6609 (1): the security graph stores the TOTP secret in plaintext (no sealed form, no openMfaSecret)\n", .{});
        return error.MfaSecretNotSealed;
    }
}

fn openSecret(agm: *AuthGraphManager, uid: u64, buf: []u8) !?[]const u8 {
    if (comptime @hasDecl(AuthGraphManager, "openMfaSecret")) {
        return agm.openMfaSecret(uid, buf);
    } else return error.MfaSecretNotSealed;
}

test "SONNY-6609 (1): mfa_setup stores the secret sealed, bound to the user; it opens to the issued secret" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try installMfaPersistence(&w.agm);

    try fx.expectRuns(ga, w.admin, "CREATE USER at6609 SET PASSWORD '" ++ user_pw ++ "'");
    try fx.expectRuns(ga, w.admin, "CREATE USER bt6609 SET PASSWORD '" ++ user_pw ++ "'");
    const issued = try setup(ga, w.admin, "at6609");
    const rec = try storedUser(&w.agm, "at6609");
    const stored = rec.getMFASecret() orelse return error.EnrollmentNotStored;
    if (std.mem.indexOf(u8, stored, issued.secret) != null) {
        std.debug.print("SONNY-6609 (1): the user record holds the TOTP secret in plaintext: '{s}'\n", .{stored});
        return error.MfaSecretInPlaintext;
    }
    try requireSeal();
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(issued.secret, (try openSecret(&w.agm, rec.id, &buf)).?);
    try w.agm.verifyChain(&HMAC_KEY);
    // The sealed secret works (mfa_verify).
    try fx.expectRuns(ga, w.admin, try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_verify('at6609', '{s}')", .{try codeFor(ga, issued.secret)}));

    // Bound to the user: the same sealed value moved to another user's
    // record does not open.
    const other = try storedUser(&w.agm, "bt6609");
    try w.agm.storage.updateUser(other.id, null, null, null, null, stored);
    try testing.expectError(error.MfaSecretUndecryptable, openSecret(&w.agm, other.id, &buf));
    // Under another HMAC key it does not open either.
    w.agm.hmac_key = [_]u8{0x01} ** 32;
    defer w.agm.hmac_key = HMAC_KEY;
    try testing.expectError(error.MfaSecretUndecryptable, openSecret(&w.agm, rec.id, &buf));
}

test "SONNY-6609 (1): a secret stored in plaintext is sealed when the server loads it" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try installMfaPersistence(&w.agm);
    try fx.expectRuns(ga, w.admin, "CREATE USER up6609 SET PASSWORD '" ++ user_pw ++ "'");

    // As a store written before SONNY-6609 holds it: plaintext, sealed into
    // the chain.
    const legacy = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP";
    const uid = (try storedUser(&w.agm, "up6609")).id;
    try w.agm.storage.updateUser(uid, null, null, null, true, legacy);
    try w.agm.sealChain(&HMAC_KEY);
    try w.agm.verifyChain(&HMAC_KEY);

    auth_dispatch.deinitMfaStore();
    try testing.expectEqual(@as(usize, 1), try hydration.hydrateMfaEnrollments(testing.allocator, &w.agm));
    const rec = try storedUser(&w.agm, "up6609");
    if (std.mem.eql(u8, rec.getMFASecret().?, legacy)) {
        std.debug.print("SONNY-6609 (1): loading left the plaintext secret in the user record\n", .{});
        return error.PlaintextSecretNotUpgraded;
    }
    try testing.expect(rec.mfa_enabled); // the upgrade changes nothing else
    try w.agm.verifyChain(&HMAC_KEY);
    try requireSeal();
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(legacy, (try openSecret(&w.agm, uid, &buf)).?);
    {
        auth_dispatch.g_mfa_store_mu.lockUncancelable(io());
        defer auth_dispatch.g_mfa_store_mu.unlock(io());
        try testing.expectEqualStrings(legacy, auth_dispatch.g_mfa_store.get("up6609").?.secret_base32);
    }
    // A second load finds nothing to upgrade and leaves the record as is.
    const sealed_once = try ga.dupe(u8, rec.getMFASecret().?);
    auth_dispatch.deinitMfaStore();
    _ = try hydration.hydrateMfaEnrollments(testing.allocator, &w.agm);
    try testing.expectEqualStrings(sealed_once, (try storedUser(&w.agm, "up6609")).getMFASecret().?);
}

fn cheapPhc(buf: []u8, password: []const u8) ![]const u8 {
    const salt = [16]u8{ 6, 6, 0, 9, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var hash: [32]u8 = undefined;
    try std.crypto.pwhash.argon2.kdf(testing.allocator, &hash, password, &salt, .{ .t = 1, .m = 64, .p = 1 }, .argon2id, io());
    return std.fmt.bufPrint(buf, "$argon2id$v=19$m=64,t=1,p=1${x}${x}", .{ &salt, &hash });
}

test "SONNY-6609 (3): SecurityManager is loaded with the stored secret and recovery codes; a stored code is redeemed once" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try installMfaPersistence(&w.agm);
    try fx.expectRuns(ga, w.admin, "CREATE USER sm6609 SET PASSWORD '" ++ user_pw ++ "'");
    const issued = try setup(ga, w.admin, "sm6609");
    try fx.expectRuns(ga, w.admin, try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_enable('sm6609', '{s}')", .{try codeFor(ga, issued.secret)}));
    const rec = try storedUser(&w.agm, "sm6609");

    // SecurityManager as the server builds it at startup: the user, then
    // its MFA state from the security graph.
    var sm = try geode.auth.SecurityManager.initEmpty(testing.allocator);
    defer sm.deinit();
    var phc_buf: [256]u8 = undefined;
    try sm.hydrateUser(rec.id, "sm6609", "", try cheapPhc(&phc_buf, user_pw), false, true, false, false, rec.mfa_enabled, null, 1, null);
    if (comptime !@hasDecl(hydration, "hydrateSecurityManagerMfa")) {
        std.debug.print("SONNY-6609 (3): SecurityManager gets no stored recovery code\n", .{});
        return error.RecoveryCodesNotInSecurityManager;
    } else {
        try testing.expectEqual(@as(usize, 1), try hydration.hydrateSecurityManagerMfa(testing.allocator, &w.agm, &sm));
    }
    // The session token belongs to the SecurityManager.
    _ = try sm.authenticateWithMFA("sm6609", user_pw, 0, issued.codes[2]);
    try testing.expectError(error.MFAInvalidCode, sm.authenticateWithMFA("sm6609", user_pw, 0, issued.codes[2]));
    // And the TOTP secret is the issued one, opened.
    const code = try mfa.generateCodeFromBase32(ga, issued.secret, realMillis(), 30, 6);
    _ = try sm.authenticateWithMFA("sm6609", user_pw, code, null);
}

test "SONNY-6609 (2): DROP USER of a user that does not exist is an error; IF EXISTS stays a no-op" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const err = try fx.expectRefused(ga, w.admin, "DROP USER nobody6609", "42704");
    _ = err;
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.user_delete('nobody6609')", "42704");
    try fx.expectRuns(ga, w.admin, "DROP USER IF EXISTS nobody6609");
    try fx.expectRuns(ga, w.admin, "CREATE USER dr6609 SET PASSWORD '" ++ user_pw ++ "'");
    try fx.expectRuns(ga, w.admin, "DROP USER dr6609");
    _ = try fx.expectRefused(ga, w.admin, "DROP USER dr6609", "42704");
}
