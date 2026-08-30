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

// ── Residual R-A: the collapse also lives in the STORAGE lookup ─────────────
//
// The 2026-08-28 fix normalised authenticate()'s non-verdicts to
// error.AuthUnavailable and taught user_storage to report
// `error.SecurityStoreUnavailable` when the engine-direct scan cannot run
// (src/storage/user_storage.zig:483-492). But `findUserByUsernameInGraphChecked`
// (:536-558) still LAUNDERS that error into `null` whenever the in-memory label
// posting merely *existed*:
//
//     const engine_result = findUserByUsernameEngineDirect(...) catch |err| {
//         if (enumerated) return null;   // <-- :554  "no such user"
//         return err;
//     };
//
// `enumerated` is set by the mere PRESENCE of a `__geode_security:User` posting
// (:538) — it is true for an EMPTY posting, for a posting whose node bodies are
// unreadable (`loadUserRecordFromNode ... orelse continue`, :541), and for a
// partially-hydrated posting that is simply missing this principal. Those are
// exactly the degraded states the GAP-0061 engine-direct fallback was ADDED for,
// so treating them as a complete candidate list is circular: we trust the path
// we already decided not to trust, and answer "no such user".
//
// That `null` walks straight up main.zig:337 -> resolver null -> ensureUserCached
// false -> getAuthSnapshot null -> authenticate error.Unauthenticated ->
// auth_rate_limiter.shouldCountFailedAttempt == TRUE -> the per-IP brute-force
// counter increments for a principal whose credentials were never checked. Ten
// of those lock the IP for 60 s, and because the degradation persists, every
// retry re-arms it.
//
// CONTRACT PINNED HERE: when the engine-direct fallback could not RUN (adapter
// absent, or the scan itself failed) and the in-memory path produced no HIT, the
// answer is `error.SecurityStoreUnavailable` — never `null`. An in-memory hit
// still resolves (GAP-0061 healthy path), and a fallback that RAN and found
// nothing still answers `null` (a genuine unknown user must keep counting).
//
// The #829 uniformity invariant is preserved and asserted: an unavailable store
// answers IDENTICALLY for every principal it cannot resolve, so this introduces
// no username-enumeration oracle.
//
// CANARY: REQ=REQ-SEC-AUTH-UNAVAILABLE-002; FEATURE="AuthOutcomeClassification"; ASPECT=StorageLookupResidual; STATUS=TESTED; TEST=tests/test_auth_unavailable_classification.zig; OWNER=security; UPDATED=2026-08-29

const graph_store = geode.graph_store;
const user_storage = @import("user_storage");
const UserStorageBackend = user_storage.UserStorageBackend;

/// A syntactically valid stored hash; these tests never verify a password, they
/// only exercise the record LOOKUP classification.
const stub_hash = "$argon2id$v=19$m=19456,t=2,p=1$" ++ ("0" ** 32) ++ "$" ++ ("0" ** 64);

/// The engine-direct fallback needs `graph_store.getGlobalAdapter()`. This test
/// binary never calls `initGlobalStore`, so the fallback CANNOT run — the exact
/// degraded condition (`SecurityStoreUnavailable` out of
/// `findUserByUsernameEngineDirect`, user_storage.zig:484-485) that a real
/// server hits when the adapter is gone or the slot scan fails.
fn requireNoGlobalAdapter() !void {
    if (graph_store.getGlobalAdapter() != null) return error.SkipZigTest;
}

fn seedUser(backend: *UserStorageBackend, user_id: u64, username: []const u8) !void {
    _ = try backend.upsertManagedUser(.{
        .user_id = user_id,
        .username = username,
        .email = "user@localhost",
        .password_hash = stub_hash,
        .is_active = true,
    });
}

test "user_storage: a :User posting with no READABLE record plus a failed engine scan is unavailable (ENG-3954 R-A)" {
    try requireNoGlobalAdapter();

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();
    _ = &backend; // the backend owns/creates the security graph for this store

    // A `:User` node whose body carries no `id` property, so
    // `loadUserRecordFromNode` returns null and the in-memory loop `continue`s
    // past it (user_storage.zig:337-338 / :541) — the "unreadable resident node
    // body" case the fallback's own doc comment (:547-550) names. The posting
    // EXISTS (`enumerated` = true) yet yields ZERO usable candidates, so it is
    // not evidence that any principal is absent.
    _ = try store.createNodeWithGraph(&[_][]const u8{user_storage.USER_LABEL}, graph_store.SECURITY_GRAPH_NAME);

    const posting = store.getNodesByLabel(graph_store.SECURITY_GRAPH_NAME, user_storage.USER_LABEL);
    try testing.expect(posting != null); // `enumerated` becomes true ...
    try testing.expect(posting.?.len > 0); // ... on a candidate that cannot be read

    // RED at HEAD: returns null -> Unauthenticated -> COUNTED toward lockout.
    try testing.expectError(
        error.SecurityStoreUnavailable,
        UserStorageBackend.findUserByUsernameInGraphChecked(&store, "alice"),
    );
}

test "user_storage: NO :User posting at all still reports unavailable (ENG-3954 R-A guard)" {
    try requireNoGlobalAdapter();

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    // Nothing was ever hydrated, so `enumerated` stays false and the engine
    // error already propagates today. Guard: the fix must not regress this half
    // while collapsing the `enumerated` special case.
    try testing.expect(store.getNodesByLabel(graph_store.SECURITY_GRAPH_NAME, user_storage.USER_LABEL) == null);
    try testing.expectError(
        error.SecurityStoreUnavailable,
        UserStorageBackend.findUserByUsernameInGraphChecked(&store, "alice"),
    );
}

test "user_storage: a partial :User posting plus a failed engine scan is unavailable (ENG-3954 R-A)" {
    try requireNoGlobalAdapter();

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    // "bob" hydrated; "alice" is durable in the ENGINE only — which is precisely
    // what the engine-direct fallback exists to read, and precisely what we
    // cannot read right now.
    try seedUser(&backend, 1, "bob");

    const posting = store.getNodesByLabel(graph_store.SECURITY_GRAPH_NAME, user_storage.USER_LABEL);
    try testing.expect(posting != null);
    try testing.expect(posting.?.len > 0); // non-empty, yet still incomplete

    try testing.expectError(
        error.SecurityStoreUnavailable,
        UserStorageBackend.findUserByUsernameInGraphChecked(&store, "alice"),
    );

    // #829 uniformity: while the store cannot answer, EVERY unresolvable
    // principal must get the identical answer — no enumeration oracle.
    try testing.expectError(
        error.SecurityStoreUnavailable,
        UserStorageBackend.findUserByUsernameInGraphChecked(&store, "mallory"),
    );
}

test "user_storage: an in-memory hit still resolves without the engine (ENG-3954 R-A guard)" {
    try requireNoGlobalAdapter();

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    try seedUser(&backend, 1, "bob");

    // GAP-0061's healthy path must not regress into "unavailable".
    const record = (try UserStorageBackend.findUserByUsernameInGraphChecked(&store, "bob")) orelse
        return error.InMemoryHitLost;
    try testing.expectEqualStrings("bob", record.getUsername());
}

test "user_storage: the legacy option-returning lookup still yields null for non-auth callers (ENG-3954 R-A guard)" {
    try requireNoGlobalAdapter();

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    try seedUser(&backend, 1, "bob");

    // Bootstrap / password-reset tooling only cares about presence and must keep
    // compiling against the `?UserRecord` shape (user_storage.zig:564).
    try testing.expect(UserStorageBackend.findUserByUsernameInGraph(&store, "alice") == null);
    try testing.expect(UserStorageBackend.findUserByUsernameInGraph(&store, "bob") != null);
}

// ── End-to-end composition: the storage verdict must reach authenticate() ──
//
// The glue below is the EXACT body of the production resolver
// (src/server/main.zig:331-338): call findUserByUsernameInGraphChecked and
// propagate its error instead of laundering it. It is not a stand-in for the
// logic under test — the classification decision is made inside the real
// user_storage function this resolver calls.

const StoreBackedResolver = struct {
    store: *graph_store.GraphStore,

    fn lookup(ctx: ?*anyopaque, allocator: std.mem.Allocator, username: []const u8) anyerror!?um.User {
        const self: *StoreBackedResolver = @ptrCast(@alignCast(ctx orelse return null));
        const record = try UserStorageBackend.findUserByUsernameInGraphChecked(self.store, username) orelse return null;
        return .{
            .username = try allocator.dupe(u8, record.getUsername()),
            .password_hash = try allocator.dupe(u8, record.getPasswordHash()),
            .email = try allocator.dupe(u8, ""),
            .role = .ReadWrite,
            .created_at = 0,
            .last_login = null,
            .active = record.is_active,
            .password_reset_required = false,
            .auth_version = @max(@as(u64, 1), record.auth_version),
        };
    }

    fn hasUsers(ctx: ?*anyopaque) anyerror!bool {
        const self: *StoreBackedResolver = @ptrCast(@alignCast(ctx orelse return false));
        return UserStorageBackend.hasUserRecordsInGraph(self.store);
    }

    fn authVersion(ctx: ?*anyopaque, username: []const u8) anyerror!?u64 {
        const self: *StoreBackedResolver = @ptrCast(@alignCast(ctx orelse return null));
        const record = try UserStorageBackend.findUserByUsernameInGraphChecked(self.store, username) orelse return null;
        return @max(@as(u64, 1), record.auth_version);
    }
};

test "authenticate reports AuthUnavailable when the storage lookup could not answer (ENG-3954 R-A)" {
    try requireArgon2(testing.allocator);
    try requireNoGlobalAdapter();

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    // Degraded security graph: the in-memory posting holds only "bob", the
    // principals we are asked about live in the ENGINE, and the engine cannot
    // be scanned.
    try seedUser(&backend, 1, "bob");

    um.deinitUserStore();
    defer um.deinitUserStore();
    try um.initUserStore(testing.allocator);

    var resolver = StoreBackedResolver{ .store = &store };
    um.setPersistentUserResolver(.{
        .ctx = &resolver,
        .lookup_fn = StoreBackedResolver.lookup,
        .has_users_fn = StoreBackedResolver.hasUsers,
        .auth_version_fn = StoreBackedResolver.authVersion,
    });

    // RED at HEAD: the storage layer answers `null`, authenticate() calls that a
    // checked-and-rejected credential (error.Unauthenticated), and
    // auth_rate_limiter.shouldCountFailedAttempt counts it toward the lockout.
    try testing.expectError(error.AuthUnavailable, um.authenticate("alice", "Password1!"));

    // #829 uniformity across principals under unavailability.
    try testing.expectError(error.AuthUnavailable, um.authenticate("mallory", "whatever"));
}
