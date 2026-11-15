//! SONNY-6598: every credential verification has three outcomes: match,
//! mismatch, error. Only a mismatch is a failed login (and counts toward a
//! lockout); an error (the Argon2id KDF could not allocate, a stored hash
//! that cannot be parsed, an MFA check the server could not run) fails the
//! check with an error and is never read as "wrong password", nor as a
//! success.
//!
//! The verify functions audited, and what each did with an error:
//!
//!   * `geode_auth.verifyPasswordArgon2id`: an Argon2 KDF error and a
//!     malformed stored PHC string were `return false` (mismatch).
//!   * `user_management.verifyPassword` (the wire login's verifier):
//!     every error but FipsUnsupported became `false`.
//!   * `user_management.authenticate`: a mismatch from the above is
//!     `error.Unauthenticated`, which the transports count toward the lockout.
//!   * `SecurityManager.authenticate` (geode_auth_lib): a malformed stored
//!     hash counted a failed attempt and answered InvalidCredentials.
//!   * `geode.auth.mfa_verify` / `mfa_enable`: a TOTP check the server could
//!     not run (`mfa.verifyCode` error, e.g. MFA turned off on the server)
//!     was `catch false`: answered 28000 "invalid code", and for mfa_verify
//!     counted toward the MFA lockout.
//!
//! Allocation failures are injected with `std.testing.checkAllAllocationFailures`
//! (every allocation of the Argon2id work, one at a time) and with the
//! test-only login fault hook (`user_management.injectKdfAllocFailures`).
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const auth_graph_manager = @import("auth_graph_manager");

const auth = geode.auth;
const um = geode.user_management;
const graph_store = geode.graph_store;
const gps = geode.security.gps;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const Role = um.Role;

const HMAC_KEY = [_]u8{0x68} ** 32;
const user_pw = "Correct Horse Battery Staple 6598";
const wrong_pw = "Wrong Horse Battery Staple 6598";

/// Skip under FIPS: Argon2id and BLAKE2b are not FIPS-approved, so no
/// password verification runs there (covered by test-auth-enforcement).
fn requireArgon2() !void {
    const h = auth.hashPasswordArgon2id(testing.allocator, "probe") catch return error.SkipZigTest;
    testing.allocator.free(h);
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// A PHC string for `password` with small parameters (fast in Debug).
fn phcFor(buf: []u8, password: []const u8) ![]const u8 {
    const salt = [16]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var hash: [32]u8 = undefined;
    try std.crypto.pwhash.argon2.kdf(testing.allocator, &hash, password, &salt, .{ .t = 1, .m = 64, .p = 1 }, .argon2id, io());
    return std.fmt.bufPrint(buf, "$argon2id$v=19$m=64,t=1,p=1${x}${x}", .{ &salt, &hash });
}

fn legacyBlake2bHex(password: []const u8) [64]u8 {
    var h = std.crypto.hash.blake2.Blake2b256.init(.{});
    h.update(password);
    h.update("geode-salt-secure-v2");
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Runs a verification; the verdict itself is checked elsewhere. Under
/// `checkAllAllocationFailures` every failed allocation must surface as
/// error.OutOfMemory: a verdict returned after an allocation failed is
/// `error.SwallowedOutOfMemoryError`.
fn argon2Verify(allocator: std.mem.Allocator, password: []const u8, phc: []const u8) anyerror!void {
    _ = try auth.verifyPasswordArgon2id(allocator, password, phc);
}

fn loginVerify(allocator: std.mem.Allocator, password: []const u8, stored: []const u8) anyerror!void {
    _ = try um.verifyPasswordWith(allocator, password, stored);
}

test "SONNY-6598: verifyPasswordArgon2id reports every allocation failure of the KDF as an error, never as a verdict" {
    try requireArgon2();
    var buf: [256]u8 = undefined;
    const phc = try phcFor(&buf, user_pw);
    // The verdicts without faults.
    try testing.expect(try auth.verifyPasswordArgon2id(testing.allocator, user_pw, phc));
    try testing.expect(!try auth.verifyPasswordArgon2id(testing.allocator, wrong_pw, phc));
    // Each allocation failing in turn: an error, for the right password and
    // for a wrong one.
    try testing.checkAllAllocationFailures(testing.allocator, argon2Verify, .{ user_pw, phc });
    try testing.checkAllAllocationFailures(testing.allocator, argon2Verify, .{ wrong_pw, phc });
    // An allocator that fails everything.
    try testing.expectError(error.OutOfMemory, auth.verifyPasswordArgon2id(std.mem.Allocator.failing, user_pw, phc));
}

test "SONNY-6598: verifyPasswordArgon2id reports a stored hash it cannot use as InvalidHashFormat, never as a mismatch" {
    try requireArgon2();
    var buf: [256]u8 = undefined;
    const phc = try phcFor(&buf, user_pw);
    const salt_and_hash = phc["$argon2id$v=19$m=64,t=1,p=1$".len..];
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    const cases = [_][]const u8{
        "",
        "plaintext",
        "$argon2id$",
        try std.fmt.bufPrint(&b1, "$argon2i$v=19$m=64,t=1,p=1${s}", .{salt_and_hash}),
        try std.fmt.bufPrint(&b2, "$argon2id$v=16$m=64,t=1,p=1${s}", .{salt_and_hash}),
        // Out-of-bounds parameters (SONNY-6374 / SONNY-6378): never run.
        try std.fmt.bufPrint(&b3, "$argon2id$v=19$m=64,t=11,p=1${s}", .{salt_and_hash}),
        "$argon2id$v=19$m=19456,t=2,p=x$00112233445566778899aabbccddeeff$00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        // A salt that is not hex, a truncated hash.
        "$argon2id$v=19$m=19456,t=2,p=1$zz112233445566778899aabbccddeeff$00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        phc[0 .. phc.len - 2],
    };
    for (cases) |bad| {
        // Whatever the password: the right one does not make a bad hash match.
        try testing.expectError(error.InvalidHashFormat, auth.verifyPasswordArgon2id(testing.allocator, user_pw, bad));
        try testing.expectError(error.InvalidHashFormat, auth.verifyPasswordArgon2id(testing.allocator, wrong_pw, bad));
    }
}

test "SONNY-6598: the login verifier reports allocation failures and unusable stored hashes as errors (Argon2id and legacy BLAKE2b)" {
    try requireArgon2();
    var buf: [256]u8 = undefined;
    const phc = try phcFor(&buf, user_pw);
    const legacy = legacyBlake2bHex(user_pw);

    try testing.expect(try um.verifyPasswordWith(testing.allocator, user_pw, phc));
    try testing.expect(!try um.verifyPasswordWith(testing.allocator, wrong_pw, phc));
    try testing.expect(try um.verifyPasswordWith(testing.allocator, user_pw, &legacy));
    try testing.expect(!try um.verifyPasswordWith(testing.allocator, wrong_pw, &legacy));

    try testing.checkAllAllocationFailures(testing.allocator, loginVerify, .{ user_pw, phc });
    try testing.checkAllAllocationFailures(testing.allocator, loginVerify, .{ wrong_pw, phc });
    // The legacy check does the Argon2id work an Argon2id check does
    // (SONNY-6369); that work failing is an error too, never a verdict.
    try testing.checkAllAllocationFailures(testing.allocator, loginVerify, .{ user_pw, @as([]const u8, &legacy) });

    // A stored hash in no format the login knows: an error.
    for ([_][]const u8{ "plaintext", legacy[0..63], "" }) |bad| {
        try testing.expectError(error.InvalidHashFormat, um.verifyPassword(user_pw, bad));
    }
}

test "SONNY-6598: authenticate answers AuthUnavailable for a KDF failure and AuthCredentialInvalid for a malformed stored hash, never Unauthenticated" {
    try requireArgon2();
    um.deinitUserStore();
    defer um.deinitUserStore();
    um.setPersistentUserResolver(null);
    try um.initUserStore(testing.allocator);
    try um.createUser(testing.allocator, "kdf6598", user_pw, "", .ReadWrite, false);
    try um.createUserWithHash(testing.allocator, "badhash6598", "$argon2id$v=19$m=19456,t=2,p=1$zz112233445566778899aabbccddeeff$00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", "", .ReadWrite, false);

    // The KDF cannot allocate: the right password is "unavailable", three
    // times over, then logs in.
    try um.injectKdfAllocFailures("kdf6598", 3);
    defer um.injectKdfAllocFailures("kdf6598", 0) catch {};
    for (0..3) |_| try testing.expectError(error.AuthUnavailable, um.authenticate("kdf6598", user_pw));
    _ = try um.authenticate("kdf6598", user_pw);
    // A wrong password is still a mismatch.
    try testing.expectError(error.Unauthenticated, um.authenticate("kdf6598", wrong_pw));

    // A malformed stored hash: a server-side credential error for any
    // password.
    try testing.expectError(error.AuthCredentialInvalid, um.authenticate("badhash6598", user_pw));
    try testing.expectError(error.AuthCredentialInvalid, um.authenticate("badhash6598", wrong_pw));
}

test "SONNY-6598: SecurityManager.authenticate does not count a stored hash it cannot use as a failed attempt" {
    try requireArgon2();
    var sm = try auth.SecurityManager.initEmpty(testing.allocator);
    defer sm.deinit();
    try sm.hydrateUser(
        77,
        "badhash6598",
        "",
        "$argon2id$v=19$m=19456,t=2,p=1$zz112233445566778899aabbccddeeff$00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        false,
        true,
        false,
        false,
        false,
        null,
        1,
        null,
    );
    for (0..6) |_| try testing.expectError(error.InvalidHashFormat, sm.authenticate("badhash6598", user_pw));
    const user = sm.users.getPtr(77) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 0), user.failed_login_attempts);
    try testing.expectEqual(@as(i64, 0), user.lockout_until);
}

// ---------------------------------------------------------------------------
// MFA: geode.auth.mfa_verify / mfa_enable through the executor.
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
        um.setPersistentUserWriter(.{
            .ctx = @ptrCast(&self.agm),
            .create_fn = &writerCreateUser,
        });

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root6598", "", .Admin, null, null, false, 0);
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

test "SONNY-6598: an MFA check the server cannot run is an error, not an invalid code, and does not count toward the MFA lockout" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    try fx.expectRuns(ga, w.admin, "CREATE USER mfa6598 SET PASSWORD '" ++ user_pw ++ "'");

    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_setup('mfa6598')");

    // MFA turned off on the server after enrollment: the TOTP check cannot
    // run. 0A000 (feature disabled), not 28000 (the code does not verify),
    // more times than the MFA lockout allows.
    flags.mfa.disableForTests();
    for (0..6) |_| try expectCode(ga, w.admin, "CALL geode.auth.mfa_verify('mfa6598', '000000')", "0A000");
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_enable('mfa6598', '000000')", "0A000");

    // Back on: a wrong code is a wrong code (28000), not a lockout (53400).
    flags.mfa.enableForTests();
    try expectCode(ga, w.admin, "CALL geode.auth.mfa_verify('mfa6598', '000000')", "28000");
}

test "SONNY-6598: only a mismatch of the __geode_security chain is a tampering verdict" {
    for ([_]anyerror{ error.MissingChainRoot, error.RecordCountMismatch, error.RecordHmacMismatch, error.ChainHashMismatch }) |err| {
        try testing.expect(AuthGraphManager.isChainTamperVerdict(err));
    }
    // A verification that could not run: no verdict (startup refuses with
    // AuthChainUnverifiable, the CLI says so, the periodic check retries).
    for ([_]anyerror{ error.OutOfMemory, error.InputOutput, error.SecurityGraphUnavailable }) |err| {
        try testing.expect(!AuthGraphManager.isChainTamperVerdict(err));
    }
}
