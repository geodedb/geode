//! SONNY-6600 items 2 and 3: MFA recovery codes and the MFA secret.
//!
//! (2) `SecurityManager.authenticateWithMFA` compared a presented recovery
//!     code with each stored one with `std.mem.eql` (returns at the first
//!     differing byte: a timing side channel), and the codes were held in
//!     plaintext. `geode.auth.mfa_setup` kept the recovery codes it issued
//!     in plaintext in the MFA store as well. Codes are now held as SHA-256
//!     digests (the auth library's `hashScratchCode`; recovery codes are
//!     160-bit random values, so no KDF is needed), a code already held in
//!     plaintext is converted the first time the user's codes are checked,
//!     and a presented code is compared with every stored digest in
//!     constant time. One-time use stays atomic (the SecurityManager lock).
//!
//! (3) `auth_dispatch.getMfaSecret` returned a slice of the MFA store after
//!     releasing the store's lock. Every geode.auth.mfa_* procedure runs
//!     under the auth DDL lock (none is read-only), so mfa_setup cannot
//!     free the secret while mfa_verify / mfa_enable use it; the race test
//!     below pins that. The secret is now copied under the store's lock and
//!     zeroed after use, so the store no longer depends on the outer lock.
//!
//! No mocks: the real SecurityManager and the real executor (gRPC execute
//! through the SONNY-1560 shim, as SONNY-6598's regression).
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const auth_graph_manager = @import("auth_graph_manager");

const auth = geode.auth;
const um = geode.user_management;
const graph_store = geode.graph_store;
const gps = geode.security.gps;
const auth_dispatch = geode.auth_dispatch;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const Role = um.Role;

const HMAC_KEY = [_]u8{0x66} ** 32;
const user_pw = "Correct Horse Battery Staple 6600";
const USER_ID: auth.UserId = 6600;
const USERNAME = "mfa6600";
const TOTP_SECRET = "JBSWY3DPEHPK3PXP";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn requireArgon2() !void {
    const h = auth.hashPasswordArgon2id(testing.allocator, "probe") catch return error.SkipZigTest;
    testing.allocator.free(h);
}

/// A PHC string for `password` with small parameters (fast in Debug).
fn cheapPhc(buf: []u8, password: []const u8) ![]const u8 {
    const salt = [16]u8{ 6, 6, 0, 0, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var hash: [32]u8 = undefined;
    try std.crypto.pwhash.argon2.kdf(testing.allocator, &hash, password, &salt, .{ .t = 1, .m = 64, .p = 1 }, .argon2id, io());
    return std.fmt.bufPrint(buf, "$argon2id$v=19$m=64,t=1,p=1${x}${x}", .{ &salt, &hash });
}

fn newManager() !auth.SecurityManager {
    var sm = try auth.SecurityManager.initEmpty(testing.allocator);
    errdefer sm.deinit();
    var buf: [256]u8 = undefined;
    try sm.hydrateUser(USER_ID, USERNAME, "", try cheapPhc(&buf, user_pw), false, true, false, false, true, TOTP_SECRET, 1, null);
    return sm;
}

/// Whether `code` is held in plaintext anywhere in the user's stored codes.
fn heldInPlaintext(sm: *auth.SecurityManager, code: []const u8) bool {
    const user = sm.users.getPtr(USER_ID).?;
    const codes = user.recovery_codes orelse return false;
    for (codes.items) |stored| {
        if (std.mem.indexOf(u8, stored, code) != null) return true;
    }
    return false;
}

fn redeem(sm: *auth.SecurityManager, code: []const u8) !void {
    _ = try sm.authenticateWithMFA(USERNAME, user_pw, 0, code);
}

test "SONNY-6600 (2): recovery codes held in plaintext are converted to digests when checked, and each still works once" {
    try requireArgon2();
    var sm = try newManager();
    defer sm.deinit();
    // Codes stored the way they were before: plaintext.
    const user = sm.users.getPtr(USER_ID).?;
    user.recovery_codes = std.ArrayList([]const u8).empty;
    for ([_][]const u8{ "LEGACYCODEONE6600", "LEGACYCODETWO6600", "LEGACYCODETHREE6600" }) |c| {
        try user.recovery_codes.?.append(testing.allocator, try testing.allocator.dupe(u8, c));
    }

    try redeem(&sm, "LEGACYCODEONE6600");
    for ([_][]const u8{ "LEGACYCODETWO6600", "LEGACYCODETHREE6600" }) |c| {
        if (heldInPlaintext(&sm, c)) {
            std.debug.print("SONNY-6600 (2): recovery code {s} is still held in plaintext after the user's codes were checked\n", .{c});
            return error.RecoveryCodeHeldInPlaintext;
        }
    }
    // Single use, the converted codes included.
    try testing.expectError(error.MFAInvalidCode, redeem(&sm, "LEGACYCODEONE6600"));
    try redeem(&sm, "LEGACYCODETWO6600");
    try testing.expectError(error.MFAInvalidCode, redeem(&sm, "LEGACYCODETWO6600"));
    // A code differing from a stored one in its last byte, a prefix, an
    // extension: refused.
    try testing.expectError(error.MFAInvalidCode, redeem(&sm, "LEGACYCODETHREE6601"));
    try testing.expectError(error.MFAInvalidCode, redeem(&sm, "LEGACYCODETHREE660"));
    try testing.expectError(error.MFAInvalidCode, redeem(&sm, "LEGACYCODETHREE66000"));
    try redeem(&sm, "LEGACYCODETHREE6600");
    try testing.expectEqual(@as(usize, 0), sm.users.getPtr(USER_ID).?.recovery_codes.?.items.len);
}

test "SONNY-6600 (2): SecurityManager stores recovery codes as digests, never in plaintext" {
    try requireArgon2();
    if (comptime !@hasDecl(auth.SecurityManager, "setRecoveryCodes")) {
        std.debug.print("SONNY-6600 (2): SecurityManager has no way to store recovery codes but writing them into User.recovery_codes in plaintext\n", .{});
        return error.NoHashedRecoveryCodeStore;
    } else {
        var sm = try newManager();
        defer sm.deinit();
        const codes = [_][]const u8{ "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", "BCDEFGHIJKLMNOPQRSTUVWXYZ234567A" };
        try sm.setRecoveryCodes(USER_ID, &codes);
        for (codes) |c| try testing.expect(!heldInPlaintext(&sm, c));
        try testing.expectEqual(@as(usize, 2), sm.users.getPtr(USER_ID).?.recovery_codes.?.items.len);
        try redeem(&sm, codes[1]);
        try testing.expectError(error.MFAInvalidCode, redeem(&sm, codes[1]));
        try redeem(&sm, codes[0]);
        // Replacing the codes replaces them.
        try sm.setRecoveryCodes(USER_ID, &.{"CDEFGHIJKLMNOPQRSTUVWXYZ234567AB"});
        try testing.expectError(error.MFAInvalidCode, redeem(&sm, codes[0]));
        try redeem(&sm, "CDEFGHIJKLMNOPQRSTUVWXYZ234567AB");
        try testing.expectError(error.UserNotFound, sm.setRecoveryCodes(USER_ID + 1, &codes));
    }
}

const Racer = struct {
    sm: *auth.SecurityManager,
    go: *std.atomic.Value(bool),
    won: bool = false,
    err: ?anyerror = null,

    fn run(self: *Racer) void {
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        if (self.sm.authenticateWithMFA(USERNAME, user_pw, 0, "RACECODE6600")) |_| {
            self.won = true;
        } else |e| self.err = e;
    }
};

test "SONNY-6600 (2): a recovery code redeemed by concurrent logins is accepted exactly once" {
    try requireArgon2();
    for (0..4) |_| {
        var sm = try newManager();
        defer sm.deinit();
        const user = sm.users.getPtr(USER_ID).?;
        user.recovery_codes = std.ArrayList([]const u8).empty;
        try user.recovery_codes.?.append(testing.allocator, try testing.allocator.dupe(u8, "RACECODE6600"));
        try user.recovery_codes.?.append(testing.allocator, try testing.allocator.dupe(u8, "OTHERCODE6600"));

        var go = std.atomic.Value(bool).init(false);
        var racers: [8]Racer = undefined;
        var threads: [8]std.Thread = undefined;
        for (&racers, &threads) |*r, *t| {
            r.* = .{ .sm = &sm, .go = &go };
            t.* = try std.Thread.spawn(.{}, Racer.run, .{r});
        }
        go.store(true, .release);
        for (threads) |t| t.join();
        var wins: usize = 0;
        for (racers) |r| {
            if (r.won) wins += 1 else try testing.expectEqual(@as(?anyerror, error.MFAInvalidCode), r.err);
        }
        try testing.expectEqual(@as(usize, 1), wins);
        try testing.expectEqual(@as(usize, 1), sm.users.getPtr(USER_ID).?.recovery_codes.?.items.len);
    }
}

// ---------------------------------------------------------------------------
// geode.auth.mfa_* through the executor.
// ---------------------------------------------------------------------------

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
    admin2: []const u8 = "",
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
        self.admin = try self.sessions.createSession("root6600", "", .Admin, null, null, false, 0);
        self.admin2 = try self.sessions.createSession("root6600b", "", .Admin, null, null, false, 0);
    }

    fn deinit(self: *World) void {
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

/// The recovery codes an mfa_setup answered ("Recovery codes: A B ...").
fn setupCodes(ga: std.mem.Allocator, session: []const u8, user: []const u8) ![]const []const u8 {
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
    const presp = pull.response orelse return error.MissingPayload;
    const page = switch (presp.payload orelse return error.MissingPayload) {
        .page => |p| p,
        else => return error.UnexpectedPayload,
    };
    // Columns mfa_secret, recovery_codes ("Recovery codes: A B ..."),
    // warning (SONNY-6602).
    if (page.rows.items.len != 1 or page.rows.items[0].values.items.len != 3) return error.UnexpectedRow;
    const text = switch (page.rows.items[0].values.items[1].kind orelse return error.UnexpectedRow) {
        .string_val => |s| s.value,
        else => return error.UnexpectedRow,
    };
    const prefix = "Recovery codes: ";
    if (!std.mem.startsWith(u8, text, prefix)) return error.UnexpectedRow;
    var codes: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text[prefix.len..], ' ');
    while (it.next()) |c| try codes.append(ga, c);
    if (codes.items.len == 0) return error.NoRecoveryCodes;
    return codes.items;
}

test "SONNY-6600 (2): geode.auth.mfa_setup does not keep the recovery codes it issues in plaintext" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();

    try fx.expectRuns(ga, w.admin, "CREATE USER " ++ USERNAME ++ " SET PASSWORD '" ++ user_pw ++ "'");
    const codes = try setupCodes(ga, w.admin, USERNAME);

    auth_dispatch.g_mfa_store_mu.lockUncancelable(io());
    defer auth_dispatch.g_mfa_store_mu.unlock(io());
    const cred = auth_dispatch.g_mfa_store.get(USERNAME) orelse return error.NotEnrolled;
    try testing.expectEqual(codes.len, cred.recovery_codes.len);
    for (cred.recovery_codes, 0..) |stored, i| {
        const Stored = @TypeOf(stored);
        if (comptime Stored == []u8) {
            if (std.mem.eql(u8, stored, codes[i])) {
                std.debug.print("SONNY-6600 (2): the MFA store holds issued recovery code {d} in plaintext\n", .{i});
                return error.RecoveryCodeHeldInPlaintext;
            }
        } else {
            try testing.expectEqual(geode.mfa_test_support.hashRecoveryCode(codes[i]), stored);
        }
    }
}

test "SONNY-6600 (3): the MFA store outlives the request allocator of the first mfa_* call" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try fx.expectRuns(w.arena.allocator(), w.admin, "CREATE USER " ++ USERNAME ++ " SET PASSWORD '" ++ user_pw ++ "'");
    if (comptime @hasDecl(auth_dispatch, "deinitMfaStore")) auth_dispatch.deinitMfaStore();

    // The first enrollment of the process arrives with a request-scoped
    // allocator that is gone when the request is answered.
    {
        var request_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer request_arena.deinit();
        try fx.expectRuns(request_arena.allocator(), w.admin2, "CALL geode.auth.mfa_setup('" ++ USERNAME ++ "')");
        // The session keeps its last result, allocated by the request:
        // release it with the request (the session is not used again).
        const entry = w.sessions.getEntry(w.admin2) orelse return error.NoSession;
        entry.state.resetResult();
    }
    // Later requests use the store: it must not live in that allocator.
    const ga = w.arena.allocator();
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_setup('" ++ USERNAME ++ "')");
    const resp = try fx.execute(ga, w.admin, "CALL geode.auth.mfa_enable('" ++ USERNAME ++ "', '000000')");
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| try testing.expectEqualStrings("28000", e.code),
        else => {},
    }
}

const Verifier = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    stop: *std.atomic.Value(bool),
    runs: usize = 0,
    bad: ?[]const u8 = null,

    fn run(self: *Verifier) void {
        while (!self.stop.load(.acquire)) {
            // SONNY-6623: mfa_enable is under the MFA attempt limiter now;
            // this race is about the secret read, not the lockout.
            auth_dispatch.resetMfaAttemptsForTests(USERNAME) catch {};
            const resp = fx.execute(self.ga, self.session, "CALL geode.auth.mfa_enable('" ++ USERNAME ++ "', '000000')") catch |e| {
                self.bad = @errorName(e);
                return;
            };
            self.runs += 1;
            const payload = resp.payload orelse {
                self.bad = "no payload";
                return;
            };
            switch (payload) {
                // 28000: the code does not verify against the secret read.
                .@"error" => |e| if (!std.mem.eql(u8, e.code, "28000")) {
                    self.bad = e.code;
                    return;
                },
                // '000000' can verify against a secret (1 in ~330,000).
                else => {},
            }
        }
    }
};

test "SONNY-6600 (3): an MFA check racing re-enrollment of the same user reads a whole secret" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try fx.expectRuns(ga, w.admin, "CREATE USER " ++ USERNAME ++ " SET PASSWORD '" ++ user_pw ++ "'");
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_setup('" ++ USERNAME ++ "')");

    var stop = std.atomic.Value(bool).init(false);
    var v: Verifier = .{ .ga = ga, .session = w.admin2, .stop = &stop };
    const t = try std.Thread.spawn(.{}, Verifier.run, .{&v});
    var setups: usize = 0;
    while (setups < 200 and v.bad == null) : (setups += 1) {
        fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_setup('" ++ USERNAME ++ "')") catch |e| {
            stop.store(true, .release);
            t.join();
            return e;
        };
    }
    stop.store(true, .release);
    t.join();
    if (v.bad) |code| {
        std.debug.print("SONNY-6600 (3): mfa_enable racing mfa_setup answered {s} after {d} checks (a secret freed or replaced mid-check)\n", .{ code, v.runs });
        return error.MfaSecretReadWhileReplaced;
    }
    try testing.expect(v.runs > 0);
}
