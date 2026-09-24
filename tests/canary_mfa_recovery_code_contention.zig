// MFA recovery-code redemption under real contention (SONNY-2394 rewrite).
//
// The previous version of this CANARY modelled contention with an inline
// stride loop that touched no product code and could never pass (its layout
// made the contention ratio exactly 0). It now drives the real redemption path,
// `SecurityManager.authenticateWithMFA(username, password, 0, recovery_code)`,
// from N threads released together:
//
//   * same code:      N threads race to redeem ONE code -> exactly one wins,
//                     every other attempt is rejected (MFAInvalidCode), and the
//                     code is gone while every other code is untouched;
//   * distinct codes: N threads each redeem their own code -> all N win, every
//                     code is removed exactly once (none lost, none duplicated),
//                     and every winner holds its own valid session;
//   * mixed:          2 contenders per code -> exactly one winner per code.
//
// All three run under std.testing.allocator (leak + double-free checking),
// several rounds each. The fixture user's password hash uses a low Argon2id
// cost (the verifier honours the PHC-embedded m/t) so the contention window --
// not password hashing -- dominates each round.
//
// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaRecoveryCodeContention"; ASPECT=ConcurrentSingleUseRedemption; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_RecoveryCodeContentionRatioBounds; OWNER=security; UPDATED=2026-09-23

const std = @import("std");
const geode_auth = @import("geode_auth");

const SecurityManager = geode_auth.SecurityManager;

const USERNAME = "mfa-racer";
const USER_ID: geode_auth.UserId = 4242;
const PASSWORD = "Correct Horse Battery Staple Racing";
const TOTP_SECRET = "JBSWY3DPEHPK3PXP";
const THREADS: usize = 16;
const ROUNDS: usize = 8;

/// PHC string in geode's hex encoding with a LOW Argon2id cost (m=64 KiB, t=1):
/// `verifyPasswordArgon2id` honours the embedded parameters.
fn cheapPhcHash(allocator: std.mem.Allocator) ![]u8 {
    const salt = [_]u8{ 0x5a, 0x11, 0x7e, 0x02, 0x39, 0x94, 0x23, 0x4f, 0x80, 0x0c, 0xa1, 0x6e, 0x55, 0x10, 0x2b, 0x77 };
    var hash: [32]u8 = undefined;
    try std.crypto.pwhash.argon2.kdf(
        allocator,
        &hash,
        PASSWORD,
        &salt,
        .{ .t = 1, .m = 64, .p = 1 },
        .argon2id,
        std.Io.Threaded.global_single_threaded.io(),
    );
    return std.fmt.allocPrint(allocator, "$argon2id$v=19$m=64,t=1,p=1${x}${x}", .{ salt, hash });
}

fn newManagerWithCodes(allocator: std.mem.Allocator, codes: []const []const u8) !SecurityManager {
    var sm = try SecurityManager.initEmpty(allocator);
    errdefer sm.deinit();
    const phc = try cheapPhcHash(allocator);
    defer allocator.free(phc);
    try sm.hydrateUser(USER_ID, USERNAME, "racer@example.com", phc, false, true, false, false, true, TOTP_SECRET, 1, null);
    const user = sm.users.getPtr(USER_ID).?;
    user.recovery_codes = std.ArrayList([]const u8).empty;
    for (codes) |code| try user.recovery_codes.?.append(allocator, try allocator.dupe(u8, code));
    return sm;
}

fn remainingCodes(sm: *SecurityManager) []const []const u8 {
    const user = sm.users.getPtr(USER_ID).?;
    return if (user.recovery_codes) |codes| codes.items else &.{};
}

fn containsCode(codes: []const []const u8, code: []const u8) bool {
    for (codes) |c| {
        if (std.mem.eql(u8, c, code)) return true;
    }
    return false;
}

const Attempt = struct {
    sm: *SecurityManager,
    code: []const u8,
    go: *std.atomic.Value(bool),
    ready: *std.atomic.Value(usize),
    token: ?[]const u8 = null,
    err: ?anyerror = null,

    fn run(self: *Attempt) void {
        _ = self.ready.fetchAdd(1, .acq_rel);
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        if (self.sm.authenticateWithMFA(USERNAME, PASSWORD, 0, self.code)) |token| {
            self.token = token;
        } else |e| {
            self.err = e;
        }
    }
};

/// Release `codes.len` threads together, thread i redeeming codes[i].
fn race(sm: *SecurityManager, attempts: []Attempt, codes: []const []const u8) !void {
    var go = std.atomic.Value(bool).init(false);
    var ready = std.atomic.Value(usize).init(0);
    var threads: [THREADS]std.Thread = undefined;
    for (attempts, codes, 0..) |*a, code, i| {
        a.* = .{ .sm = sm, .code = code, .go = &go, .ready = &ready };
        threads[i] = try std.Thread.spawn(.{}, Attempt.run, .{a});
    }
    while (ready.load(.acquire) < attempts.len) std.atomic.spinLoopHint();
    go.store(true, .release);
    for (threads[0..attempts.len]) |t| t.join();
}

/// Every winner got a distinct token for the racer's session; every loser was
/// rejected with MFAInvalidCode (never anything else, never a crash).
fn expectOutcome(sm: *SecurityManager, attempts: []const Attempt, want_wins: usize) !void {
    var wins: usize = 0;
    for (attempts, 0..) |a, i| {
        if (a.token) |tok| {
            wins += 1;
            try std.testing.expectEqual(USER_ID, try sm.validateSession(tok));
            for (attempts[i + 1 ..]) |b| {
                if (b.token) |other| try std.testing.expect(!std.mem.eql(u8, tok, other));
            }
        } else {
            try std.testing.expectEqual(@as(?anyerror, error.MFAInvalidCode), a.err);
        }
    }
    try std.testing.expectEqual(want_wins, wins);
}

test "TestCANARY_REQ_GQL_MFA_CORE_001_RecoveryCodeContentionRatioBounds" {
    const allocator = std.testing.allocator;

    // 1) N threads race to redeem the SAME code.
    for (0..ROUNDS) |_| {
        const bystanders = [_][]const u8{ "keep-0001", "keep-0002", "keep-0003" };
        var sm = try newManagerWithCodes(allocator, &.{ "keep-0001", "shared-1", "keep-0002", "keep-0003" });
        defer sm.deinit();
        const same = [_][]const u8{"shared-1"} ** THREADS;
        var attempts: [THREADS]Attempt = undefined;
        try race(&sm, &attempts, &same);
        try expectOutcome(&sm, &attempts, 1);
        const left = remainingCodes(&sm);
        try std.testing.expect(!containsCode(left, "shared-1"));
        try std.testing.expectEqual(bystanders.len, left.len);
        for (bystanders) |b| try std.testing.expect(containsCode(left, b));
    }

    // 2) N threads each redeem a DISTINCT code.
    for (0..ROUNDS) |_| {
        var names: [THREADS][16]u8 = undefined;
        var codes: [THREADS][]const u8 = undefined;
        for (&names, &codes, 0..) |*buf, *code, i| code.* = try std.fmt.bufPrint(buf, "distinct-{d:0>4}", .{i});
        var sm = try newManagerWithCodes(allocator, &codes);
        defer sm.deinit();
        var attempts: [THREADS]Attempt = undefined;
        try race(&sm, &attempts, &codes);
        try expectOutcome(&sm, &attempts, THREADS);
        try std.testing.expectEqual(@as(usize, 0), remainingCodes(&sm).len);
    }

    // 3) Mixed: two contenders per code -> exactly one winner per code.
    for (0..ROUNDS) |_| {
        const half = THREADS / 2;
        var names: [half][16]u8 = undefined;
        var unique: [half][]const u8 = undefined;
        for (&names, &unique, 0..) |*buf, *code, i| code.* = try std.fmt.bufPrint(buf, "paired-{d:0>4}", .{i});
        var codes: [THREADS][]const u8 = undefined;
        for (&codes, 0..) |*code, i| code.* = unique[i % half];
        var sm = try newManagerWithCodes(allocator, &unique);
        defer sm.deinit();
        var attempts: [THREADS]Attempt = undefined;
        try race(&sm, &attempts, &codes);
        try expectOutcome(&sm, &attempts, half);
        try std.testing.expectEqual(@as(usize, 0), remainingCodes(&sm).len);
        for (unique) |code| {
            var winners: usize = 0;
            for (attempts, codes) |a, c| {
                if (a.token != null and std.mem.eql(u8, c, code)) winners += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), winners);
        }
    }
}
