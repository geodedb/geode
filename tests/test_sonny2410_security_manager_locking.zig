// SONNY-2410 regression: every SecurityManager method that reads or changes
// shared state takes the manager's lock.
//
// One SecurityManager is shared by every connection thread (server_init).
// SONNY-2394 (c34b60d7) locked the three credential entry points
// (authenticate, authenticateWithMFA, updatePassword); the rest read and
// changed the users, roles, permissions, role memberships, sessions, MFA
// policy cache and audit log with no lock: a session created on one thread
// rehashed the sessions map under another's lookup, a user hydrated while
// getUserIdByUsername walked the users map, and evaluateMfaPolicies wrote
// its cache from every reader.
//
// The race below runs the mutating methods (hydrateUser, createSession,
// markStepUp, validateSession, forcePasswordReset, createRole,
// createPermission, grantPermission, assignRole, revokeRole, addMfaPolicy) against the readers (getUserIdByUsername, requireStepUp,
// requiresPasswordReset, authorize, validatePassword)
// from THREADS threads released together, several rounds, under
// std.testing.allocator (leaks, double frees). Afterwards every write is
// there exactly once.
//
// CANARY: REQ=REQ-SONNY-2410-SECURITY-MANAGER-LOCKING; FEATURE="SecurityManagerThreadSafety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2410_security_manager_locking.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode_auth = @import("geode_auth");

const SecurityManager = geode_auth.SecurityManager;
const UserId = geode_auth.UserId;

const THREADS: usize = 8;
const PER_THREAD: usize = 64;
const ROUNDS: usize = 4;
const PASSWORD = "Correct Horse Battery Staple Racing";
/// Roles 1..base_roles and permissions 1..base_roles exist before the race.
const base_roles: usize = 4;

const Worker = struct {
    sm: *SecurityManager,
    index: usize,
    go: *std.atomic.Value(bool),
    abort: *std.atomic.Value(bool),
    ready: *std.atomic.Value(usize),
    tokens: [PER_THREAD][]const u8 = undefined,
    token_count: usize = 0,
    err: ?anyerror = null,

    fn userId(self: *const Worker, i: usize) UserId {
        return @intCast(1000 + self.index * PER_THREAD + i);
    }

    fn run(self: *Worker) void {
        _ = self.ready.fetchAdd(1, .acq_rel);
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        if (self.abort.load(.acquire)) return;
        self.work() catch |e| {
            self.err = e;
        };
    }

    fn work(self: *Worker) !void {
        const sm = self.sm;
        var name_buf: [32]u8 = undefined;
        for (0..PER_THREAD) |i| {
            const id = self.userId(i);
            const name = try std.fmt.bufPrint(&name_buf, "racer-{d}", .{id});
            // Writers.
            try sm.hydrateUser(id, name, "racer@example.com", "not-a-hash", false, true, false, false, false, null, 1, null);
            const token = try sm.createSession(id);
            self.tokens[self.token_count] = token;
            self.token_count += 1;
            try sm.markStepUp(token, 60_000);
            try sm.forcePasswordReset(id);
            // The pointers createRole / createPermission answer are moved by
            // another thread's create, so they are not read here; the roles
            // assigned and granted were made before the race.
            _ = try sm.createRole(name, "racer role");
            _ = try sm.createPermission(name, "graph", .read);
            const role_id: geode_auth.RoleId = @intCast(1 + i % base_roles);
            try sm.grantPermission(role_id, @intCast(1 + (self.index + i) % base_roles));
            try sm.assignRole(id, role_id);
            if (i % 2 == 1) try sm.revokeRole(id, role_id);
            if (i % 16 == 0) try sm.addMfaPolicy(.{ .id = id, .condition = .match_any_role, .roles = &.{} });
            // Readers.
            if (sm.getUserIdByUsername(name) != id) return error.UserLost;
            _ = sm.requireStepUp(token, "geode.auth.user_create");
            if (!try sm.requiresPasswordReset(id)) return error.ResetFlagLost;
            _ = try sm.authorize(id, "graph", .read);
            try sm.validatePassword(PASSWORD);
            _ = sm.validateSession("no-such-session") catch {};
        }
    }
};

fn race(sm: *SecurityManager, workers: []Worker) !void {
    var go = std.atomic.Value(bool).init(false);
    var abort = std.atomic.Value(bool).init(false);
    var ready = std.atomic.Value(usize).init(0);
    var threads: [THREADS]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        go.store(true, .release);
        for (threads[0..spawned]) |t| t.join();
    }
    for (workers, 0..) |*w, i| {
        w.* = .{ .sm = sm, .index = i, .go = &go, .abort = &abort, .ready = &ready };
        threads[i] = std.Thread.spawn(.{}, Worker.run, .{w}) catch |err| {
            abort.store(true, .release);
            return err;
        };
        spawned += 1;
    }
    while (ready.load(.acquire) < workers.len) std.atomic.spinLoopHint();
    go.store(true, .release);
}

test "SONNY-2410: SecurityManager's mutating methods and readers race safely, and every write lands exactly once" {
    const allocator = testing.allocator;
    for (0..ROUNDS) |_| {
        var sm = try SecurityManager.initEmpty(allocator);
        defer sm.deinit();
        for (0..base_roles) |_| {
            _ = try sm.createRole("base", "made before the race");
            _ = try sm.createPermission("base", "graph", .read);
        }
        var workers: [THREADS]Worker = undefined;
        try race(&sm, &workers);

        for (&workers) |*w| {
            if (w.err) |e| {
                std.debug.print("worker {d} failed: {s}\n", .{ w.index, @errorName(e) });
                return e;
            }
        }
        try testing.expectEqual(THREADS * PER_THREAD, sm.users.count());
        try testing.expectEqual(THREADS * PER_THREAD, sm.sessions.count());
        // createRole / createPermission number from the count: one id each,
        // none handed out twice (a lost or overwritten role shows here).
        try testing.expectEqual(base_roles + THREADS * PER_THREAD, sm.roles.count());
        try testing.expectEqual(base_roles + THREADS * PER_THREAD, sm.permissions.count());
        for (1..base_roles + THREADS * PER_THREAD + 1) |rid| {
            if (sm.roles.get(@intCast(rid)) == null) {
                std.debug.print("role id {d} is missing (another role took its id)\n", .{rid});
                return error.RoleIdReused;
            }
        }
        try testing.expectEqual(THREADS * (PER_THREAD / 16), sm.mfa_policies.items.len);
        for (&workers) |*w| {
            for (w.tokens[0..w.token_count], 0..) |tok, i| {
                try testing.expectEqual(w.userId(i), try sm.validateSession(tok));
                try testing.expect(!sm.requireStepUp(tok, "geode.auth.user_create"));
            }
            for (0..PER_THREAD) |i| {
                const id = w.userId(i);
                const roles = sm.rbac.user_roles.get(id);
                const held = if (roles) |r| r.items.len else 0;
                try testing.expectEqual(@as(usize, if (i % 2 == 1) 0 else 1), held);
            }
        }
    }
}
