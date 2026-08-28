// ENG-3954 / #874 — auth lockout misclassification, AUTHENTICATE layer.
//
// TRIAGE (current main): `authenticate()` cannot tell "I checked the
// credentials and they are wrong" from "I could not check the credentials at
// all", so the per-IP rate limiter counts server-side faults as brute-force
// attempts and locks legitimate clients out of their own server.
//
// The collapse chain, top to bottom:
//
//   src/storage/user_storage.zig:517-531  findUserByUsernameInGraph
//       returns `?UserRecord`, so EVERY failure mode — the `__geode_security`
//       graph not hydrated, quarantined, an unreadable resident node body —
//       becomes `null`, i.e. "no such user".
//   src/server/main.zig:310-330           lookupPersistentAuthUser
//       compounds it: the comment says "if the lock can't be acquired, return
//       null" but the code proceeds with `locked == false` and then maps the
//       storage `null` straight to a resolver `null`.
//   src/security/user_management.zig:1117 ensureUserCached  -> false
//   src/security/user_management.zig:1223 getAuthSnapshot   -> null
//   src/security/user_management.zig:739  authenticate      -> error.Unauthenticated
//       — byte-identical to a wrong password.
//   src/server/quic_connection_handler.zig:5753 (gRPC parity :1469)
//       `authenticate(...) catch { limiter.recordFailure(peer_ip); }`
//       A bare catch-all, so even error.OutOfMemory arms the lockout. Ten of
//       those (auth_rate_limiter.zig:51 default_max_attempts = 10, keyed on
//       peer_ip alone) lock the IP for 60 s, and the outage re-arms it on
//       every retry.
//
// CONTRACT PINNED HERE (the fix must implement it):
//   authenticate() returns a DISTINGUISHABLE `error.AuthUnavailable` whenever
//   the persistent security store could not answer, and keeps returning
//   `error.Unauthenticated` ONLY when credentials were actually checked and
//   rejected. The transports then count only the latter (see the companion
//   `shouldCountFailedAttempt` / `credentialsPresent` seam tests in
//   src/server/auth_rate_limiter.zig).
//
//   Normalising to ONE error name matters: the handlers cannot enumerate the
//   open-ended set of `anyerror` values a storage/engine layer may invent, and
//   that is exactly why the bare `catch {}` exists today.
//
// RED at HEAD: the persistent-resolver failure leaks out of authenticate() as
// whatever raw error the resolver produced (here error.SecurityGraphUnavailable)
// — a value the handler cannot classify — so the expectError(AuthUnavailable)
// assertions fail. The `unknown user` / `wrong password` / `happy path` cases
// below are GUARDS: they pass before AND after, and fail if the fix
// over-corrects by turning genuine credential rejections into "unavailable".
//
// CANARY: REQ=REQ-SEC-AUTH-UNAVAILABLE-001; FEATURE="AuthOutcomeClassification"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_auth_unavailable_classification.zig; OWNER=security; UPDATED=2026-08-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const um = geode.user_management;

/// Skip when the build cannot produce Argon2id hashes (FIPS builds): every
/// credential-checking assertion below needs a real password hash.
fn requireArgon2(allocator: std.mem.Allocator) !void {
    const h = um.hashPassword(allocator, "probe") catch return error.SkipZigTest;
    allocator.free(h);
}

const UserDef = struct {
    username: []const u8,
    password: []const u8,
    role: um.Role = .ReadWrite,
};

/// A persistent resolver that can be switched between "healthy" and
/// "the security store cannot answer".
///
/// `available == false` models the real failure modes enumerated in the header
/// (unhydrated / quarantined `__geode_security`, store lock not acquired,
/// unreadable node body). At HEAD those all collapse to `null`; the fix must
/// make them an ERROR here and `error.AuthUnavailable` out of authenticate().
const FlakyResolver = struct {
    users: []const UserDef,
    available: bool = true,
    /// Independent switch for the auth-version probe: models a store that went
    /// down AFTER the user was already cached.
    version_available: bool = true,
    lookup_calls: usize = 0,

    fn lookup(ctx: ?*anyopaque, allocator: std.mem.Allocator, username: []const u8) anyerror!?um.User {
        const self: *FlakyResolver = @ptrCast(@alignCast(ctx orelse return null));
        self.lookup_calls += 1;
        if (!self.available) return error.SecurityGraphUnavailable;
        for (self.users) |entry| {
            if (!std.mem.eql(u8, entry.username, username)) continue;
            return .{
                .username = try allocator.dupe(u8, entry.username),
                .password_hash = try um.hashPassword(allocator, entry.password),
                .email = try allocator.dupe(u8, ""),
                .role = entry.role,
                .created_at = 0,
                .last_login = null,
                .active = true,
                .password_reset_required = false,
                .auth_version = 1,
            };
        }
        // A genuine miss: the store WAS readable and the user is not there.
        return null;
    }

    fn hasUsers(ctx: ?*anyopaque) anyerror!bool {
        const self: *FlakyResolver = @ptrCast(@alignCast(ctx orelse return false));
        if (!self.available) return error.SecurityGraphUnavailable;
        return self.users.len > 0;
    }

    fn authVersion(ctx: ?*anyopaque, username: []const u8) anyerror!?u64 {
        const self: *FlakyResolver = @ptrCast(@alignCast(ctx orelse return null));
        if (!self.version_available) return error.SecurityGraphUnavailable;
        for (self.users) |entry| {
            if (std.mem.eql(u8, entry.username, username)) return 1;
        }
        return null;
    }

    fn install(self: *FlakyResolver) void {
        um.setPersistentUserResolver(.{
            .ctx = self,
            .lookup_fn = FlakyResolver.lookup,
            .has_users_fn = FlakyResolver.hasUsers,
            .auth_version_fn = FlakyResolver.authVersion,
        });
    }
};

const default_users = [_]UserDef{
    .{ .username = "alice", .password = "Password1!", .role = .Admin },
};

// ── Regression: "could not check" must NOT look like "wrong password" ──

test "authenticate reports AuthUnavailable when the security store cannot answer (ENG-3954)" {
    try requireArgon2(testing.allocator);
    um.deinitUserStore();
    defer um.deinitUserStore();
    try um.initUserStore(testing.allocator);

    var resolver = FlakyResolver{ .users = &default_users, .available = false };
    resolver.install();

    // alice exists and her password is correct — the ONLY reason this fails is
    // that the security store is unreachable. Reporting Unauthenticated here is
    // what feeds the lockout counter and bricks the client.
    try testing.expectError(error.AuthUnavailable, um.authenticate("alice", "Password1!"));

    // Same for a principal that does not exist: while the store is down we
    // cannot know whether it exists, so the answer is still "unavailable".
    try testing.expectError(error.AuthUnavailable, um.authenticate("mallory", "whatever"));
}

test "authenticate reports AuthUnavailable when the store fails after the user is cached (ENG-3954)" {
    try requireArgon2(testing.allocator);
    um.deinitUserStore();
    defer um.deinitUserStore();
    try um.initUserStore(testing.allocator);

    var resolver = FlakyResolver{ .users = &default_users };
    resolver.install();

    // Warm the cache with a healthy store.
    const ok = try um.authenticate("alice", "Password1!");
    try testing.expectEqual(um.Role.Admin, ok.role);

    // Now the store goes away mid-session (checkpoint quarantine, lock
    // contention, engine reopen). The staleness probe can no longer verify the
    // cached entry — that is "could not check", not "wrong password".
    resolver.available = false;
    resolver.version_available = false;
    try testing.expectError(error.AuthUnavailable, um.authenticate("alice", "Password1!"));
}

// ── Guards: real credential decisions must stay exactly as they are ────

test "authenticate still reports Unauthenticated for an unknown user (ENG-3954 guard)" {
    try requireArgon2(testing.allocator);
    um.deinitUserStore();
    defer um.deinitUserStore();
    try um.initUserStore(testing.allocator);

    var resolver = FlakyResolver{ .users = &default_users };
    resolver.install();

    // The store answered; the principal genuinely is not there. Checked and
    // rejected => this one MUST count against the rate limiter.
    try testing.expectError(error.Unauthenticated, um.authenticate("nobody", "Password1!"));
}

test "authenticate still reports Unauthenticated for a wrong password (ENG-3954 guard)" {
    try requireArgon2(testing.allocator);
    um.deinitUserStore();
    defer um.deinitUserStore();
    try um.initUserStore(testing.allocator);

    var resolver = FlakyResolver{ .users = &default_users };
    resolver.install();

    try testing.expectError(error.Unauthenticated, um.authenticate("alice", "WrongPassword!"));
}

test "authenticate still succeeds with correct credentials (ENG-3954 guard)" {
    try requireArgon2(testing.allocator);
    um.deinitUserStore();
    defer um.deinitUserStore();
    try um.initUserStore(testing.allocator);

    var resolver = FlakyResolver{ .users = &default_users };
    resolver.install();

    const result = try um.authenticate("alice", "Password1!");
    try testing.expectEqual(um.Role.Admin, result.role);
}
