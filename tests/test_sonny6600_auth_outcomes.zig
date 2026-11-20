//! SONNY-6600 items 4-7: an auth check that could not run is an error, not
//! a verdict (the three-way match / mismatch / error model of SONNY-6598),
//! and a stored hash is parsed strictly.
//!
//! (4) The LSP API-key / session-token verifier (`cli/lsp/auth.zig`,
//!     `verifierFromAuthProvider`) turned every error of
//!     `AuthProvider.authenticate`, out of memory included, into `.invalid`:
//!     the client was told its token is invalid, nothing was logged.
//! (5) `NonceTracker.checkAndRecord` answered `false` ("replay") when
//!     recording the nonce could not allocate, and had already overwritten
//!     the ring slot, so the tracker's ring and set disagreed after it.
//! (6) The Argon2id PHC parser skipped a parameter without '=', ignored
//!     unknown parameters, defaulted a missing one and ignored anything
//!     after the hash.
//! (7) `AuthUnavailable` / `AuthCredentialInvalid` reaching a GQL procedure
//!     (`geode.auth.user_change_password`) fell to the generic 58000 with
//!     the error's name as the message.
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const auth_graph_manager = @import("auth_graph_manager");
const lsp_auth = @import("lsp_auth");

const auth = geode.auth;
const authn = geode.security.authn;
const nonce_tracker = geode.distributed.nonce_tracker;
const um = geode.user_management;
const graph_store = geode.graph_store;
const gps = geode.security.gps;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const Role = um.Role;

const HMAC_KEY = [_]u8{0x67} ** 32;
const user_pw = "Correct Horse Battery Staple 6600";
const new_pw = "Brand New Horse Battery Staple 6600";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn requireArgon2() !void {
    const h = auth.hashPasswordArgon2id(testing.allocator, "probe") catch return error.SkipZigTest;
    testing.allocator.free(h);
}

// ---------------------------------------------------------------------------
// (4) the LSP token verifier
// ---------------------------------------------------------------------------

test "SONNY-6600 (4): an allocation failure in the LSP API-key check is an error, never an invalid token" {
    const scopes = [_][]const u8{"lsp:read"};
    var induced: usize = 0;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        const fa_alloc = fa.allocator();
        var provider = authn.AuthProvider.init(fa_alloc);
        defer provider.deinit();
        const token = try provider.api_key_manager.createKey(66, "lsp6600", &scopes, null);
        defer fa_alloc.free(token);

        // The i-th allocation of the check (and every one after) fails.
        fa.fail_index = fa.alloc_index + i;
        const verifier = lsp_auth.verifierFromAuthProvider(&provider);
        const out = verifier.verifyFn(verifier.ctx, token);
        const failed = fa.has_induced_failure;
        if (out == .ok) {
            const ok = out.ok;
            if (ok.free_with) |fw| {
                fw.free(ok.username);
                if (ok.role) |r| fw.free(r);
            }
            if (!failed) break;
            continue;
        }
        if (out == .invalid) {
            std.debug.print("SONNY-6600 (4): allocation {d} of the LSP API-key check failed and the valid token was answered .invalid\n", .{i});
            return error.ErrorReportedAsInvalidToken;
        }
        // The error outcome.
        try testing.expect(failed);
        induced += 1;

        // And AuthState.verify reports it as something other than an
        // invalid token.
        var st = lsp_auth.AuthState{ .token = try testing.allocator.dupe(u8, token) };
        defer st.deinit(testing.allocator);
        fa.fail_index = fa.alloc_index + i;
        if (st.verify(testing.allocator, verifier)) |_| {
            // An allocation the second run did not need; fine.
        } else |err| {
            if (err == error.InvalidToken) {
                std.debug.print("SONNY-6600 (4): AuthState.verify answered InvalidToken for an allocation failure\n", .{});
                return error.ErrorReportedAsInvalidToken;
            }
            try testing.expect(!st.verified);
        }
    } else return error.CheckNeverCompleted;
    try testing.expect(induced > 0);
}

test "SONNY-6600 (4): a token the provider does not know is still invalid" {
    var provider = authn.AuthProvider.init(testing.allocator);
    defer provider.deinit();
    const verifier = lsp_auth.verifierFromAuthProvider(&provider);
    for ([_][]const u8{ "definitely-not-a-key", "geode.AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "0" ** 64 }) |tok| {
        const out = verifier.verifyFn(verifier.ctx, tok);
        try testing.expect(out == .invalid);
        var st = lsp_auth.AuthState{ .token = try testing.allocator.dupe(u8, tok) };
        defer st.deinit(testing.allocator);
        try testing.expectError(error.InvalidToken, st.verify(testing.allocator, verifier));
    }
}

// ---------------------------------------------------------------------------
// (5) the Raft nonce tracker
// ---------------------------------------------------------------------------

test "SONNY-6600 (5): a nonce the tracker cannot record is an error, not a replay, and leaves the tracker consistent" {
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var tracker = try nonce_tracker.NonceTracker.init(fa.allocator(), 4);
    defer tracker.deinit();

    const R = @typeInfo(@TypeOf(nonce_tracker.NonceTracker.checkAndRecord)).@"fn".return_type.?;
    fa.fail_index = fa.alloc_index;
    if (comptime R == bool) {
        if (!tracker.checkAndRecord(5)) {
            std.debug.print("SONNY-6600 (5): a nonce the tracker could not record (out of memory) was answered as a replay\n", .{});
            return error.AllocationFailureReportedAsReplay;
        }
        return error.TestUnexpectedResult;
    } else {
        try testing.expectError(error.OutOfMemory, tracker.checkAndRecord(5));
        try testing.expectError(error.OutOfMemory, tracker.checkAndRecord(6));
        // Memory back: 5 was never recorded, so it is fresh, then a replay.
        fa.fail_index = std.math.maxInt(usize);
        try testing.expect(try tracker.checkAndRecord(5));
        try testing.expect(!try tracker.checkAndRecord(5));
        try testing.expect(!try tracker.checkAndRecord(0));
        // The ring still evicts in order: fill it, 5 is evicted first.
        try testing.expect(try tracker.checkAndRecord(7));
        try testing.expect(try tracker.checkAndRecord(8));
        try testing.expect(try tracker.checkAndRecord(9));
        try testing.expect(try tracker.checkAndRecord(10));
        try testing.expect(!try tracker.checkAndRecord(7));
        try testing.expect(try tracker.checkAndRecord(5));
        try testing.expectEqual(tracker.count, tracker.seen.count());
    }
}

// ---------------------------------------------------------------------------
// (6) the PHC parser
// ---------------------------------------------------------------------------

/// A PHC string for `password` with small parameters (fast in Debug).
fn phcFor(buf: []u8, password: []const u8) ![]const u8 {
    const salt = [16]u8{ 6, 6, 0, 0, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var hash: [32]u8 = undefined;
    try std.crypto.pwhash.argon2.kdf(testing.allocator, &hash, password, &salt, .{ .t = 1, .m = 64, .p = 1 }, .argon2id, io());
    return std.fmt.bufPrint(buf, "$argon2id$v=19$m=64,t=1,p=1${x}${x}", .{ &salt, &hash });
}

test "SONNY-6600 (6): a stored hash that is not exactly $argon2id$v=19$m=..,t=..,p=..$salt$hash is InvalidHashFormat" {
    try requireArgon2();
    var buf: [256]u8 = undefined;
    const phc = try phcFor(&buf, user_pw);
    try testing.expect(try auth.verifyPasswordArgon2id(testing.allocator, user_pw, phc));
    const head = "$argon2id$v=19$";
    const tail = phc[(head ++ "m=64,t=1,p=1").len..]; // "$salt$hash"

    var bad_bufs: [32][320]u8 = undefined;
    var bad: std.ArrayList([]const u8) = .empty;
    defer bad.deinit(testing.allocator);
    const params_cases = [_][]const u8{
        "m=64,t=1,p=1,x", // a parameter without '='
        "m=64,t=1,p=1,x=5", // an unknown parameter
        "m=64,t=1,p=1,", // an empty parameter
        "m=64,t=1", // p missing (it defaulted to 1)
        "t=1,p=1", // m missing (it defaulted to 19456)
        "m=64,p=1", // t missing (it defaulted to 2)
        "t=1,m=64,p=1", // out of order
        "m=64,m=64,t=1,p=1", // a duplicate
        "m=64,t=1,p=1,p=1",
        "m=064,t=1,p=1", // a leading zero
        "m=+64,t=1,p=1", // a sign
        "m=,t=1,p=1", // an empty value
        " m=64,t=1,p=1",
        "m=64,t=1,p=1=1",
        "M=64,t=1,p=1",
        "",
    };
    for (params_cases, 0..) |params, i| {
        try bad.append(testing.allocator, try std.fmt.bufPrint(&bad_bufs[i], "{s}{s}{s}", .{ head, params, tail }));
    }
    var n = params_cases.len;
    // Anything after the hash.
    for ([_][]const u8{ "$", "$extra", "$$", "x" }) |suffix| {
        try bad.append(testing.allocator, try std.fmt.bufPrint(&bad_bufs[n], "{s}{s}", .{ phc, suffix }));
        n += 1;
    }
    // A missing leading '$', a doubled separator.
    try bad.append(testing.allocator, phc[1..]);
    try bad.append(testing.allocator, try std.fmt.bufPrint(&bad_bufs[n], "${s}", .{phc}));
    n += 1;

    var accepted: usize = 0;
    for (bad.items) |s| {
        if (auth.verifyPasswordArgon2id(testing.allocator, user_pw, s)) |verdict| {
            accepted += 1;
            std.debug.print("SONNY-6600 (6): stored hash \"{s}\" was parsed (verdict {}), not refused as InvalidHashFormat\n", .{ s, verdict });
        } else |err| {
            try testing.expectEqual(error.InvalidHashFormat, err);
        }
    }
    if (accepted > 0) return error.LenientPhcParser;
}

test "SONNY-6600 (6): the stored hashes Geode writes and the fixtures' hashes still parse" {
    try requireArgon2();
    // What hashPasswordArgon2id writes.
    const written = try auth.hashPasswordArgon2id(testing.allocator, user_pw);
    defer testing.allocator.free(written);
    try testing.expect(try auth.verifyPasswordArgon2id(testing.allocator, user_pw, written));
    try testing.expect(!try auth.verifyPasswordArgon2id(testing.allocator, "wrong", written));
    // Fixtures used by the auth regressions (a mismatch, not a format error).
    for ([_][]const u8{
        "$argon2id$v=19$m=19456,t=2,p=1$00112233445566778899aabbccddeeff$00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        "$argon2id$v=19$m=64,t=1,p=1$000102030405060708090a0b0c0d0e0f$00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        // Upper-case hex (case is not checked; Geode writes lower case).
        "$argon2id$v=19$m=64,t=1,p=1$000102030405060708090A0B0C0D0E0F$00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
    }) |s| {
        try testing.expect(!try auth.verifyPasswordArgon2id(testing.allocator, user_pw, s));
    }
}

// ---------------------------------------------------------------------------
// (7) the GQLSTATUS of AuthUnavailable / AuthCredentialInvalid
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

fn expectAnswer(ga: std.mem.Allocator, session: []const u8, query: []const u8, code: []const u8, message: []const u8) !void {
    const resp = try fx.execute(ga, session, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            if (!std.mem.eql(u8, e.code, code) or !std.mem.eql(u8, e.message, message)) {
                std.debug.print("SONNY-6600 (7): {s}\n  answered {s} \"{s}\"\n  want     {s} \"{s}\"\n", .{ query, e.code, e.message, code, message });
                return error.WrongAnswer;
            }
        },
        else => {
            std.debug.print("SONNY-6600 (7): {s}: answered 00000, want {s}\n", .{ query, code });
            return error.FailureReportedAsSuccess;
        },
    }
}

test "SONNY-6600 (7): user_change_password answers AuthUnavailable / AuthCredentialInvalid with their own GQLSTATUS and the HELLO messages" {
    try requireArgon2();
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    // The HELLO path's messages (auth_rate_limiter.hello_unavailable_message,
    // hello_credential_invalid_message).
    const rl = struct {
        const hello_unavailable_message = "Authentication temporarily unavailable";
        const hello_credential_invalid_message = "Authentication unavailable: the stored credential of this account cannot be used (server-side error; contact the administrator)";
    };

    try fx.expectRuns(ga, w.admin, "CREATE USER kdf6600 SET PASSWORD '" ++ user_pw ++ "'");
    try um.createUserWithHash(testing.allocator, "badhash6600", "$argon2id$v=19$m=19456,t=2,p=1$zz112233445566778899aabbccddeeff$00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", "", .ReadWrite, false);

    // The old password's check cannot run (the KDF cannot allocate):
    // retryable, not a wrong password, not the generic 58000.
    try um.injectKdfAllocFailures("kdf6600", 1);
    defer um.injectKdfAllocFailures("kdf6600", 0) catch {};
    try expectAnswer(ga, w.admin, "CALL geode.auth.user_change_password('kdf6600', '" ++ user_pw ++ "', '" ++ new_pw ++ "')", "53000", rl.hello_unavailable_message);
    // The stored hash cannot be used: a server-side error on the account.
    try expectAnswer(ga, w.admin, "CALL geode.auth.user_change_password('badhash6600', '" ++ user_pw ++ "', '" ++ new_pw ++ "')", "58000", rl.hello_credential_invalid_message);
    // A wrong old password is still 28000, and the right one still works.
    try expectAnswer(ga, w.admin, "CALL geode.auth.user_change_password('kdf6600', 'Wrong Horse Battery Staple 6600', '" ++ new_pw ++ "')", "28000", "Authentication required");
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.user_change_password('kdf6600', '" ++ user_pw ++ "', '" ++ new_pw ++ "')");

    // The mapping itself, as every procedure gets it.
    const pu = geode.proto_util;
    try testing.expectEqualStrings("53000", pu.mapError(error.AuthUnavailable).code);
    try testing.expectEqualStrings(rl.hello_unavailable_message, pu.mapError(error.AuthUnavailable).message);
    try testing.expectEqualStrings("58000", pu.mapError(error.AuthCredentialInvalid).code);
    try testing.expectEqualStrings(rl.hello_credential_invalid_message, pu.mapError(error.AuthCredentialInvalid).message);
}
