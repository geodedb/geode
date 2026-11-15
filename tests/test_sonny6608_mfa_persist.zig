//! SONNY-6608: MFA enrollments are stored, MFA state changes are stored,
//! the mfa_* results own their memory, and the dead MFA types are gone.
//!
//! (3) `geode.auth.mfa_enable` / `mfa_disable` answered "MFA enabled /
//!     disabled for <user>" and changed nothing: the user's stored
//!     `mfa_enabled` is now set / cleared, in the HMAC-chained
//!     `__geode_security` graph.
//! (4) `geode.auth.mfa_setup` kept the enrollment (TOTP secret, recovery-code
//!     digests) in process memory only: a restart lost it, and a re-created
//!     user of the same name inherited it. The enrollment is now written
//!     through to `__geode_security` (the secret in the user record's
//!     `mfa_secret`, the digests in a sealed `MfaRecoveryCodes` record),
//!     loaded back at startup (`auth_startup_hydration.hydrateMfaEnrollments`),
//!     and dropped with the user. A new enrollment turns stored MFA off until
//!     a code verifies against it (`mfa_enable`).
//! (5) The mfa_setup / mfa_enable / mfa_disable results did not own the
//!     strings they answered (`owns_value_memory` unset), so every call over
//!     gRPC leaked them (and mfa_setup its recovery-code buffer). Shown with a
//!     leak-checking allocator handed to the real gRPC handlers, as
//!     production hands them the session store's allocator.
//! (6) `mfa.MfaChallenge` / `mfa.MfaResponse` had no user; they are gone.
//!
//! No mocks: the real executor through the real gRPC Execute / Pull handlers
//! (SONNY-1560 shim), the real AuthGraphManager over a GraphStore, and the
//! persistence callbacks and startup load the server installs
//! (`auth_startup_hydration`).
//!
// CANARY: REQ=REQ-SONNY-6608-MFA-PERSIST; FEATURE="MFA authentication"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6608_mfa_persist.zig; OWNER=security; UPDATED=2026-11-15
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

const HMAC_KEY = [_]u8{0x68} ** 32;
const user_pw = "Correct Horse Battery Staple 6608";

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
        self.admin = try self.sessions.createSession("root6608", "", .Admin, null, null, false, 0);
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

fn expectStoredDigests(agm: *AuthGraphManager, user_id: u64, codes: []const []const u8) !void {
    if (comptime !@hasDecl(AuthGraphManager, "mfaRecoveryDigests")) {
        std.debug.print("SONNY-6608 (4): the security graph has no MFA recovery-code record\n", .{});
        return error.NoStoredRecoveryCodes;
    } else {
        const got = (try agm.mfaRecoveryDigests(testing.allocator, user_id)) orelse {
            std.debug.print("SONNY-6608 (4): no recovery codes stored for user {d}\n", .{user_id});
            return error.NoStoredRecoveryCodes;
        };
        defer testing.allocator.free(got);
        try testing.expectEqual(codes.len, got.len);
        for (codes, got) |c, d| try testing.expectEqual(mfa.hashRecoveryCode(c), d);
    }
}

test "SONNY-6608 (3)(4): mfa_setup is stored (secret, recovery-code digests, MFA off), mfa_enable / mfa_disable change the stored flag, the chain verifies" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try installMfaPersistence(&w.agm);

    try fx.expectRuns(ga, w.admin, "CREATE USER st6608 SET PASSWORD '" ++ user_pw ++ "'");
    const issued = try setup(ga, w.admin, "st6608");

    var rec = try storedUser(&w.agm, "st6608");
    if (rec.getMFASecret() == null or !std.mem.eql(u8, rec.getMFASecret().?, issued.secret)) {
        std.debug.print("SONNY-6608 (4): the stored user record holds MFA secret '{s}', want the one mfa_setup issued\n", .{rec.getMFASecret() orelse ""});
        return error.EnrollmentNotStored;
    }
    try testing.expect(!rec.mfa_enabled);
    try expectStoredDigests(&w.agm, rec.id, issued.codes);
    // No plaintext recovery code anywhere in the security graph's record.
    try w.agm.verifyChain(&HMAC_KEY);

    // mfa_enable with a code that verifies: stored on.
    try fx.expectRuns(ga, w.admin, try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_enable('st6608', '{s}')", .{try codeFor(ga, issued.secret)}));
    rec = try storedUser(&w.agm, "st6608");
    if (!rec.mfa_enabled) {
        std.debug.print("SONNY-6608 (3): mfa_enable answered success and the stored mfa_enabled is still false\n", .{});
        return error.MfaEnableNotStored;
    }
    try w.agm.verifyChain(&HMAC_KEY);

    // A new enrollment turns it off until a code verifies against it.
    const again = try setup(ga, w.admin, "st6608");
    rec = try storedUser(&w.agm, "st6608");
    try testing.expect(!rec.mfa_enabled);
    try testing.expectEqualStrings(again.secret, rec.getMFASecret().?);
    try expectStoredDigests(&w.agm, rec.id, again.codes);

    try fx.expectRuns(ga, w.admin, try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_enable('st6608', '{s}')", .{try codeFor(ga, again.secret)}));
    try testing.expect((try storedUser(&w.agm, "st6608")).mfa_enabled);
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_disable('st6608')");
    if ((try storedUser(&w.agm, "st6608")).mfa_enabled) {
        std.debug.print("SONNY-6608 (3): mfa_disable answered success and the stored mfa_enabled is still true\n", .{});
        return error.MfaDisableNotStored;
    }
    try w.agm.verifyChain(&HMAC_KEY);
}

test "SONNY-6608 (4): a reload of the security graph loads the enrollments back; DROP USER drops the enrollment" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try installMfaPersistence(&w.agm);

    try fx.expectRuns(ga, w.admin, "CREATE USER hy6608 SET PASSWORD '" ++ user_pw ++ "'");
    const issued = try setup(ga, w.admin, "hy6608");
    try fx.expectRuns(ga, w.admin, try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_enable('hy6608', '{s}')", .{try codeFor(ga, issued.secret)}));

    // "Restart": the process state goes, the security graph is opened again.
    auth_dispatch.deinitMfaStore();
    uninstallMfaPersistence();
    AuthGraphManager.setGlobal(null);
    w.agm.deinit();
    w.agm = try AuthGraphManager.init(testing.allocator, &w.sec_store);
    w.agm.hmac_key = HMAC_KEY;
    AuthGraphManager.setGlobal(&w.agm);
    try w.agm.verifyChain(&HMAC_KEY);
    try installMfaPersistence(&w.agm);
    if (comptime !@hasDecl(hydration, "hydrateMfaEnrollments")) {
        return error.NoMfaHydration;
    } else {
        try testing.expectEqual(@as(usize, 1), try hydration.hydrateMfaEnrollments(testing.allocator, &w.agm));
    }

    {
        auth_dispatch.g_mfa_store_mu.lockUncancelable(io());
        defer auth_dispatch.g_mfa_store_mu.unlock(io());
        const cred = auth_dispatch.g_mfa_store.get("hy6608") orelse return error.EnrollmentNotLoaded;
        try testing.expectEqualStrings(issued.secret, cred.secret_base32);
        try testing.expectEqual(issued.codes.len, cred.recovery_codes.len);
        for (issued.codes, cred.recovery_codes) |c, d| try testing.expectEqual(mfa.hashRecoveryCode(c), d);
    }
    // The loaded secret verifies codes.
    try fx.expectRuns(ga, w.admin, try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_verify('hy6608', '{s}')", .{try codeFor(ga, issued.secret)}));

    // DROP USER: the stored record and the loaded enrollment go; a user made
    // again under the name is not enrolled.
    const uid = (try storedUser(&w.agm, "hy6608")).id;
    try fx.expectRuns(ga, w.admin, "DROP USER hy6608");
    if (comptime @hasDecl(AuthGraphManager, "mfaRecoveryDigests")) {
        try testing.expect((try w.agm.mfaRecoveryDigests(testing.allocator, uid)) == null);
    }
    try w.agm.verifyChain(&HMAC_KEY);
    try fx.expectRuns(ga, w.admin, "CREATE USER hy6608 SET PASSWORD '" ++ user_pw ++ "'");
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('hy6608', '000000')", "55000");
}

// ---------------------------------------------------------------------------
// (5) The mfa_* results over gRPC, under a leak-checking allocator.
// ---------------------------------------------------------------------------

fn execRaw(a: std.mem.Allocator, ga: std.mem.Allocator, session: []const u8, query: []const u8) !?[]const u8 {
    const req = try fx.encodeProto(a, schema.ExecuteRequest{ .session_id = session, .query = query, .params = .empty });
    defer a.free(req);
    const bytes = try grpc.handleExecute(req, a, null);
    defer a.free(bytes);
    const resp = try fx.decodeProto(schema.ExecutionResponse, ga, bytes);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| return try ga.dupe(u8, e.code),
        else => {},
    }
    const preq = try fx.encodeProto(a, schema.PullRequest{ .session_id = session, .page_size = 8 });
    defer a.free(preq);
    const pbytes = try grpc.handlePull(preq, a);
    a.free(pbytes);
    return null;
}

test "SONNY-6608 (5): mfa_setup / mfa_enable / mfa_disable over gRPC leak nothing" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try fx.expectRuns(ga, w.admin, "CREATE USER lk6608 SET PASSWORD '" ++ user_pw ++ "'");

    var dbg: std.heap.DebugAllocator(.{}) = .init;
    {
        const a = dbg.allocator();
        // The handlers get the session store's allocator, as in production
        // (grpc_zig hands each handler GrpcServer.allocator, SONNY-6602).
        var store = grpc.SessionStore.init(a, .{});
        grpc.setSessionStore(&store);
        defer {
            grpc.setSessionStore(&w.sessions);
            store.deinit();
        }
        const sid = try store.createSession("root6608lk", "", .Admin, null, null, false, 0);
        for ([_][]const u8{
            "CALL geode.auth.mfa_setup('lk6608')",
            "CALL geode.auth.mfa_setup('lk6608', 'show-uri')",
            "CALL geode.auth.mfa_setup('lk6608', 'show-recovery')",
            "CALL geode.auth.mfa_disable('lk6608')",
        }) |q| {
            if (try execRaw(a, ga, sid, q)) |code| {
                std.debug.print("{s}: {s}\n", .{ q, code });
                return error.QueryFailed;
            }
        }
        // mfa_enable with a code that verifies.
        const secret = blk: {
            auth_dispatch.g_mfa_store_mu.lockUncancelable(io());
            defer auth_dispatch.g_mfa_store_mu.unlock(io());
            break :blk try ga.dupe(u8, (auth_dispatch.g_mfa_store.get("lk6608") orelse return error.NotEnrolled).secret_base32);
        };
        const q = try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_enable('lk6608', '{s}')", .{try codeFor(ga, secret)});
        if (try execRaw(a, ga, sid, q)) |code| {
            std.debug.print("{s}: {s}\n", .{ q, code });
            return error.QueryFailed;
        }
    }
    if (dbg.deinit() == .leak) {
        std.debug.print("SONNY-6608 (5): the mfa_* procedures over gRPC leaked (see the traces above)\n", .{});
        return error.MfaResultLeaked;
    }
}

test "SONNY-6608 (6): mfa.MfaChallenge and mfa.MfaResponse (no user) are gone" {
    inline for (.{ "MfaChallenge", "MfaResponse" }) |name| {
        if (comptime @hasDecl(mfa, name)) {
            std.debug.print("SONNY-6608 (6): mfa.{s} still exists and nothing uses it\n", .{name});
            return error.DeadMfaType;
        }
    }
}
