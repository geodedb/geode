//! SONNY-6602: MFA honesty, the dead recovery-code matcher, and the MFA
//! rate limiter.
//!
//! (1) MFA is not enforced at login: HELLO never asks for a TOTP code or a
//!     recovery code, and `SecurityManager.authenticateWithMFA` has no
//!     production caller (wiring it in is story SONNY-6604).
//!     `geode.auth.mfa_setup` nonetheless answered a TOTP secret and
//!     recovery codes, and `geode.auth.mfa_enable` answered "MFA enabled for
//!     <user>", with nothing saying that no login is protected. Both now
//!     answer a `warning` column that says so.
//! (2) `mfa.verifyRecoveryCode` matched 8-character codes only, the issued
//!     codes are 32 characters, and nothing but a test called it. It is
//!     gone; the one redemption path is `SecurityManager.authenticateWithMFA`
//!     (constant time, single use, digests at rest: SONNY-6600).
//! (4) `geode.auth.mfa_verify` checked the code first and then counted a
//!     failure in the attempt record; when that record could not be made
//!     (out of memory) the failure was not counted and the limiter failed
//!     open: unlimited guesses. The record is now made before the code is
//!     checked, and a verification that could not be counted is refused
//!     (53000) without checking the code; counting a failure in an existing
//!     record allocates nothing.
//!
//! No mocks: the real executor through the real gRPC Execute / Pull handlers
//! (the SONNY-1560 shim, as SONNY-6600's regression). The out-of-memory case
//! uses the test-only fault hook `auth_dispatch.injectMfaAttemptAllocFailures`
//! (the attempt store's allocations fail, as under memory pressure).
//!
// CANARY: REQ=REQ-SONNY-6602-MFA-HONESTY; FEATURE="MFA authentication"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6602_mfa.zig; OWNER=security; UPDATED=2026-11-15
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const auth_graph_manager = @import("auth_graph_manager");

const um = geode.user_management;
const graph_store = geode.graph_store;
const gps = geode.security.gps;
const auth_dispatch = geode.auth_dispatch;
const mfa = geode.mfa_test_support;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const Role = um.Role;

const HMAC_KEY = [_]u8{0x62} ** 32;
const user_pw = "Correct Horse Battery Staple 6602";

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
        um.setPersistentUserWriter(.{ .ctx = @ptrCast(&self.agm), .create_fn = &writerCreateUser });

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root6602", "", .Admin, null, null, false, 0);
        // Each test starts with an empty MFA store and attempt records.
        auth_dispatch.deinitMfaStore();
    }

    fn deinit(self: *World) void {
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

/// A procedure's answer: its column names and its single row (strings).
const Answer = struct {
    columns: []const []const u8,
    row: []const []const u8,

    fn get(self: Answer, column: []const u8) ?[]const u8 {
        for (self.columns, 0..) |c, i| {
            if (std.mem.eql(u8, c, column) and i < self.row.len) return self.row[i];
        }
        return null;
    }
};

fn answer(ga: std.mem.Allocator, session: []const u8, query: []const u8) !Answer {
    const resp = try fx.execute(ga, session, query);
    const sd = switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ query, e.code, e.message });
            return error.QueryFailed;
        },
        .schema => |s| s,
        else => return error.UnexpectedPayload,
    };
    var columns: std.ArrayList([]const u8) = .empty;
    for (sd.columns.items) |c| try columns.append(ga, c.name);

    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = session, .page_size = 8 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const presp = pull.response orelse return error.MissingPayload;
    const page = switch (presp.payload orelse return error.MissingPayload) {
        .page => |p| p,
        else => return error.UnexpectedPayload,
    };
    if (page.rows.items.len != 1) return error.UnexpectedRow;
    var row: std.ArrayList([]const u8) = .empty;
    for (page.rows.items[0].values.items) |v| {
        const s = switch (v.kind orelse return error.UnexpectedRow) {
            .string_val => |sv| sv.value,
            else => "",
        };
        try row.append(ga, s);
    }
    return .{ .columns = columns.items, .row = row.items };
}

fn expectWarnsNotEnforced(query: []const u8, a: Answer) !void {
    const w = a.get("warning") orelse {
        std.debug.print("SONNY-6602 (1): {s} answered no `warning` column saying MFA is not enforced at login; its columns:", .{query});
        for (a.columns) |c| std.debug.print(" {s}", .{c});
        std.debug.print("\n", .{});
        return error.NoNotEnforcedWarning;
    };
    for ([_][]const u8{ "not enforced at login", "SONNY-6604" }) |needle| {
        if (std.mem.indexOf(u8, w, needle) == null) {
            std.debug.print("SONNY-6602 (1): {s} warning \"{s}\" does not say \"{s}\"\n", .{ query, w, needle });
            return error.NoNotEnforcedWarning;
        }
    }
}

test "SONNY-6602 (1): mfa_setup and mfa_enable say MFA is not enforced at login (SONNY-6604)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try fx.expectRuns(ga, w.admin, "CREATE USER hon6602 SET PASSWORD '" ++ user_pw ++ "'");

    // Every shape mfa_setup answers carries the warning next to the secret.
    for ([_][]const u8{
        "CALL geode.auth.mfa_setup('hon6602')",
        "CALL geode.auth.mfa_setup('hon6602', 'show-uri')",
        "CALL geode.auth.mfa_setup('hon6602', 'show-recovery')",
    }) |q| {
        const a = try answer(ga, w.admin, q);
        try expectWarnsNotEnforced(q, a);
        // The warning says the recovery codes cannot be redeemed.
        try testing.expect(std.mem.indexOf(u8, a.get("warning").?, "recovery code") != null);
    }

    // mfa_enable with a code that verifies: "MFA enabled", and the warning.
    const secret = blk: {
        auth_dispatch.g_mfa_store_mu.lockUncancelable(io());
        defer auth_dispatch.g_mfa_store_mu.unlock(io());
        const cred = auth_dispatch.g_mfa_store.get("hon6602") orelse return error.NotEnrolled;
        break :blk try ga.dupe(u8, cred.secret_base32);
    };
    const now = realMillis();
    const code = try mfa.generateCodeFromBase32(ga, secret, now, 30, 6);
    const q = try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_enable('hon6602', '{d:0>6}')", .{code});
    const a = try answer(ga, w.admin, q);
    try expectWarnsNotEnforced(q, a);
}

test "SONNY-6602 (2): mfa.verifyRecoveryCode (8-character codes only, 32-character codes issued, no caller) is gone" {
    if (comptime @hasDecl(mfa, "verifyRecoveryCode")) {
        std.debug.print("SONNY-6602 (2): mfa.verifyRecoveryCode still exists: it accepts only 8-character codes, the issued codes are 32 characters, and nothing redeems through it\n", .{});
        return error.DeadRecoveryCodeMatcher;
    }
    // The codes enrollment issues are the 32-character ones
    // SecurityManager.authenticateWithMFA redeems.
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    var e = try mfa.enroll(testing.allocator, "rc6602");
    defer mfa.freeEnrollment(testing.allocator, &e);
    try testing.expect(e.scratch_codes.len > 0);
    for (e.scratch_codes) |c| try testing.expectEqual(@as(usize, 32), c.len);
}

fn armFaults(n: u32) !void {
    if (comptime !@hasDecl(auth_dispatch, "injectMfaAttemptAllocFailures")) {
        std.debug.print("SONNY-6602 (4): auth_dispatch has no way to fail the MFA attempt store's allocations; recordMfaFailure logs and fails open when they fail\n", .{});
        return error.NoMfaAttemptFaultHook;
    } else {
        try auth_dispatch.injectMfaAttemptAllocFailures(n);
    }
}

fn currentCode(ga: std.mem.Allocator, user: []const u8) ![]const u8 {
    const secret = blk: {
        auth_dispatch.g_mfa_store_mu.lockUncancelable(io());
        defer auth_dispatch.g_mfa_store_mu.unlock(io());
        const cred = auth_dispatch.g_mfa_store.get(user) orelse return error.NotEnrolled;
        break :blk try ga.dupe(u8, cred.secret_base32);
    };
    const now = realMillis();
    const code = try mfa.generateCodeFromBase32(ga, secret, now, 30, 6);
    return std.fmt.allocPrint(ga, "{d:0>6}", .{code});
}

test "SONNY-6602 (4): an MFA verification that cannot be counted toward the lockout is refused, and the code is not checked" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try fx.expectRuns(ga, w.admin, "CREATE USER rl6602 SET PASSWORD '" ++ user_pw ++ "'");
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_setup('rl6602')");

    try armFaults(1000);
    // More wrong guesses than the lockout allows: each refused 53000, none
    // answered 28000 (which would mean the code was checked, uncounted).
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const code = (try fx.outcome(ga, w.admin, "CALL geode.auth.mfa_verify('rl6602', '000000')")) orelse return error.WrongCodeVerified;
        if (!std.mem.eql(u8, code, "53000")) {
            std.debug.print("SONNY-6602 (4): wrong MFA guess {d} with the attempt record unavailable answered {s}, want 53000 (refused, the code not checked)\n", .{ i + 1, code });
            return error.MfaRateLimiterFailsOpen;
        }
    }
    // A right code is refused too: no check runs that could not be counted.
    {
        const q = try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_verify('rl6602', '{s}')", .{try currentCode(ga, "rl6602")});
        _ = try fx.expectRefused(ga, w.admin, q, "53000");
    }
    try armFaults(0);

    // Memory back: the limiter counts from zero (nothing was checked) and
    // locks out after the fifth failure.
    i = 0;
    while (i < 5) : (i += 1) {
        _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('rl6602', '000000')", "28000");
    }
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('rl6602', '000000')", "53400");
}

test "SONNY-6602 (4): once a user has an attempt record, counting a failure needs no memory and still locks out" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try fx.expectRuns(ga, w.admin, "CREATE USER rm6602 SET PASSWORD '" ++ user_pw ++ "'");
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_setup('rm6602')");

    // One failure, then a success: the record is kept (reset), not dropped.
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('rm6602', '000000')", "28000");
    {
        const q = try std.fmt.allocPrint(ga, "CALL geode.auth.mfa_verify('rm6602', '{s}')", .{try currentCode(ga, "rm6602")});
        try fx.expectRuns(ga, w.admin, q);
    }

    try armFaults(1000);
    defer armFaults(0) catch {};
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('rm6602', '000000')", "28000");
    }
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('rm6602', '000000')", "53400");
}
