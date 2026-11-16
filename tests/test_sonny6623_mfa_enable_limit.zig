//! SONNY-6623 (1) and (2).
//!
//! (1) `geode.auth.mfa_enable` checked the TOTP code against the stored
//!     secret with no attempt limit, beside `mfa_verify`'s limiter: an
//!     unlimited guessing route (Admin only). Its check now goes through the
//!     same limiter: the same per-user count and lockout, the same stored
//!     transitions (SONNY-6619), and a malformed code from an enrolled user
//!     counts (it is still 22023).
//! (2) `SecurityManager.removeUserByName` collected the user's sessions into
//!     a list it allocated, and on an allocation failure left them: the
//!     sessions are now removed in place, with no allocation.
//!
// CANARY: REQ=REQ-SONNY-6623-MFA-ENABLE-LIMIT; FEATURE="MFA authentication"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6623_mfa_enable_limit.zig; OWNER=security; UPDATED=2026-11-15
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

const HMAC_KEY = [_]u8{0x23} ** 32;
const user_pw = "Correct Horse Battery Staple 6623";

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
        self.admin = try self.sessions.createSession("root6619x", "", .Admin, null, null, false, 0);
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

fn restart(agm: *AuthGraphManager) !void {
    auth_dispatch.deinitMfaStore();
    _ = try hydration.hydrateMfaEnrollments(testing.allocator, agm);
}

test "SONNY-6623 (1): mfa_enable shares mfa_verify's attempt count, lockout and stored lockout" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try installMfaPersistence(&w.agm);
    try fx.expectRuns(ga, w.admin, "CREATE USER el6623 SET PASSWORD '" ++ user_pw ++ "'");
    const issued = try setup(ga, w.admin, "el6623");
    const uid = (try storedUser(&w.agm, "el6623")).id;

    // Three wrong codes through mfa_enable, two through mfa_verify: five.
    var i: usize = 0;
    while (i < 3) : (i += 1) _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_enable('el6623', '000000')", "28000");
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('el6623', '000000')", "28000");
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('el6623', '000000')", "28000");
    const right = try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_enable('el6623', '{s}')", .{try codeFor(ga, issued.secret)});
    const resp = try fx.execute(ga, w.admin, right);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| if (!std.mem.eql(u8, e.code, "53400")) {
            std.debug.print("SONNY-6623 (1): after five failures (three through mfa_enable) a right mfa_enable code answered {s}, want 53400\n", .{e.code});
            return error.MfaEnableNotLimited;
        },
        else => {
            std.debug.print("SONNY-6623 (1): after five failures (three through mfa_enable) mfa_enable accepted a code: no shared limit\n", .{});
            return error.MfaEnableNotLimited;
        },
    }
    // The lockout is stored and survives a restart, for mfa_enable too.
    const st = (try w.agm.mfaAttempts(uid)) orelse return error.LockoutNotStored;
    try testing.expectEqual(@as(u32, 5), st.fail_count);
    try restart(&w.agm);
    _ = try fx.expectRefused(ga, w.admin, right, "53400");
    try testing.expect(!(try storedUser(&w.agm, "el6623")).mfa_enabled);
}

test "SONNY-6623 (1): a malformed mfa_enable code from an enrolled user counts (still 22023)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try installMfaPersistence(&w.agm);
    try fx.expectRuns(ga, w.admin, "CREATE USER mf6623 SET PASSWORD '" ++ user_pw ++ "'");
    // Not enrolled: malformed is 22023 and counts nothing (no secret).
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_enable('mf6623', '12345')", "22023");
    const issued = try setup(ga, w.admin, "mf6623");
    var i: usize = 0;
    while (i < 5) : (i += 1) _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_enable('mf6623', '12345')", "22023");
    // Five malformed codes from the enrolled user: locked out.
    _ = try fx.expectRefused(ga, w.admin, try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_verify('mf6623', '{s}')", .{try codeFor(ga, issued.secret)}), "53400");
}

test "SONNY-6623 (2): removing a user removes its sessions even when nothing can be allocated" {
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var sm = try geode.auth.SecurityManager.initEmpty(fa.allocator());
    defer sm.deinit();
    var phc_buf: [256]u8 = undefined;
    const phc = try cheapPhc(&phc_buf, user_pw);
    try sm.hydrateUser(1, "ses6623", "", phc, false, true, false, false, false, null, 1, null);
    try sm.hydrateUser(2, "other6623", "", phc, false, true, false, false, false, null, 1, null);
    _ = try sm.createSession(1);
    _ = try sm.createSession(1);
    _ = try sm.createSession(2);
    try testing.expectEqual(@as(usize, 3), sm.sessions.count());

    // From here on every allocation fails.
    fa.fail_index = fa.alloc_index;
    sm.removeUserByName("ses6623");
    var it = sm.sessions.valueIterator();
    var left: usize = 0;
    while (it.next()) |s| {
        if (s.user_id == 1) left += 1;
    }
    if (left != 0) {
        std.debug.print("SONNY-6623 (2): {d} session(s) of the removed user stayed (the removal allocated)\n", .{left});
        return error.SessionsOfRemovedUserStayed;
    }
    try testing.expectEqual(@as(usize, 1), sm.sessions.count());
    try testing.expect(!sm.users.contains(1));
}
