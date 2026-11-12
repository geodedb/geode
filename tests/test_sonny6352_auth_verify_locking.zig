// SONNY-6352 (items 1 and 2): two readers of the auth manager's record maps
// ran without the lock the auth DDL writers hold.
//
// (1) `AuthGraphManager.runVerifyRound` (the periodic HMAC chain check) ->
//     `verifyChain` reads the role, policy and permission caches and
//     `graph_grant_nodes`. It held the global store write lock but not
//     `auth_ddl_lock`, under which CREATE / DROP ROLE, CREATE / DROP POLICY,
//     GRANT and REVOKE change those maps (SONNY-6329): a verification could
//     iterate a map being rehashed, or see a record without its seal and
//     report tampering. It now takes `auth_ddl_lock` BEFORE the store lock.
// (2) `canUserAccessGraph` (LSP / schema visibility) iterated
//     `graph_grant_nodes` while GRANT / REVOKE changed it. It now holds
//     `auth_ddl_lock` for the scan.
//
// The deterministic proofs hold `auth_ddl_lock` in the test thread (as an
// auth change in progress does) and show the reader waits for it; the stress
// races the readers against GRANT / REVOKE write-throughs.
//
// CANARY: REQ=REQ-SONNY-6352-AUTH-READERS-LOCKED; FEATURE="GQL Auth DDL Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6352_auth_verify_locking.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");
const auth_graph_manager_mod = @import("auth_graph_manager");

const graph_store = geode.graph_store;
const mgs = geode.multi_graph_security;
const auth_ddl_lock = geode.security.auth_ddl_lock;
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const HMAC_KEY = [_]u8{0x52} ** 32;
const lock_io = std.Io.Threaded.global_single_threaded.io();

fn sleepMs(ms: u64) void {
    lock_io.sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

const World = struct {
    h: harness.Harness,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    pol: mgs.GraphRBACPolicy,
    alice_id: u64 = 0,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        _ = graph_store.getGlobalStore(testing.allocator);
        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        self.alice_id = try self.agm.createUser(&HMAC_KEY, "alice", "alice@example.com", "not_a_real_hash", false);
        self.pol = mgs.GraphRBACPolicy.init(testing.allocator);
        try self.agm.grantGraphPermissionsWriteThrough(&HMAC_KEY, &self.pol, self.alice_id, "g1", &.{0});
    }

    fn deinit(self: *World) void {
        self.pol.deinit();
        self.agm.deinit();
        self.sec_store.deinit();
        self.h.deinit();
    }
};

const Reader = struct {
    agm: *AuthGraphManager,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    can_access: bool = false,

    fn verify(self: *Reader) void {
        self.agm.runVerifyRound();
        self.done.store(true, .release);
    }

    fn access(self: *Reader) void {
        self.can_access = self.agm.canUserAccessGraph("alice", "g1");
        self.done.store(true, .release);
    }
};

test "SONNY-6352: the periodic chain verification waits for an auth change in progress (deterministic)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    var r: Reader = .{ .agm = &w.agm };
    const guard = auth_ddl_lock.acquire();
    const t = try std.Thread.spawn(.{}, Reader.verify, .{&r});
    sleepMs(150);
    const waited = !r.done.load(.acquire);
    guard.release();
    t.join();
    try testing.expect(waited);
    try testing.expect(r.done.load(.acquire));
}

test "SONNY-6352: canUserAccessGraph waits for an auth change in progress, then answers (deterministic)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    var r: Reader = .{ .agm = &w.agm };
    const guard = auth_ddl_lock.acquire();
    const t = try std.Thread.spawn(.{}, Reader.access, .{&r});
    sleepMs(150);
    const waited = !r.done.load(.acquire);
    guard.release();
    t.join();
    try testing.expect(waited);
    try testing.expect(r.can_access);
}

/// GRANT / REVOKE write-throughs (each under auth_ddl_lock, as
/// `auth_dispatch.execute` runs them) racing the two readers.
const Race = struct {
    w: *World,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    verified: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn writer(self: *Race) void {
        defer self.stop.store(true, .release);
        var i: usize = 0;
        while (i < 40) : (i += 1) {
            var buf: [16]u8 = undefined;
            const graph = std.fmt.bufPrint(&buf, "g{d}", .{i % 7 + 2}) catch unreachable;
            {
                const g = auth_ddl_lock.acquire();
                defer g.release();
                self.w.agm.grantGraphPermissionsWriteThrough(&HMAC_KEY, &self.w.pol, self.w.alice_id, graph, &.{ 0, 1 }) catch return;
            }
            {
                const g = auth_ddl_lock.acquire();
                defer g.release();
                _ = self.w.agm.revokeGraphPermissionWriteThrough(&HMAC_KEY, &self.w.pol, self.w.alice_id, graph, 1) catch return;
            }
        }
    }

    fn verifier(self: *Race) void {
        while (!self.stop.load(.acquire)) {
            self.w.agm.runVerifyRound();
            _ = self.verified.fetchAdd(1, .monotonic);
        }
    }

    fn accessor(self: *Race) void {
        while (!self.stop.load(.acquire)) {
            // alice's g1 grant is never touched by the writer.
            if (!self.w.agm.canUserAccessGraph("alice", "g1")) @panic("alice lost g1 while GRANT/REVOKE ran on other graphs");
        }
    }
};

test "SONNY-6352: chain verification and canUserAccessGraph racing GRANT / REVOKE (stress)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    var race: Race = .{ .w = &w };
    const v = try std.Thread.spawn(.{}, Race.verifier, .{&race});
    const a = try std.Thread.spawn(.{}, Race.accessor, .{&race});
    const wt = try std.Thread.spawn(.{}, Race.writer, .{&race});
    wt.join();
    v.join();
    a.join();
    try testing.expect(race.verified.load(.monotonic) > 0);
    try w.agm.verifyChain(&HMAC_KEY);
}
