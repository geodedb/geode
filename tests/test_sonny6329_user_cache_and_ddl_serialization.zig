// SONNY-6329: three auth findings from the SONNY-2756 report.
//
// (1) `UserStorageBackend.getUserByUsername` walked the auth manager's user
//     cache with no lock. `graphGrantCheck` (via `findUserIdByName`) does it
//     on every policy decision the decision cache misses, while CREATE /
//     DROP / ALTER USER on other connections change the map. The cache now
//     has a leaf reader-writer lock (`user_cache_lock`): a lookup holds it
//     shared, a writer exclusively for the map change.
// (2) A compound policy change (catalog change, write-through to
//     `__geode_security`, undo) was not serialized across connections: a
//     CREATE POLICY x and a DROP POLICY x could interleave and leave the
//     catalog and the security graph disagreeing, with two write-throughs in
//     the auth manager's unlocked maps at once. Every auth / policy change
//     now holds `auth_ddl_lock` for the whole operation.
// (3) `geode serve --no-auth` set a field nothing read and logged that
//     authentication was disabled while it stayed on. It now fails.
//
// The deterministic proofs hold the new lock in the test thread and show the
// other side waits; the stress runs race the real auth manager and policy
// DDL under std.testing.allocator and compare memory with the store.
//
// CANARY: REQ=REQ-SONNY-6329-USER-CACHE-LOCK; FEATURE="GQL Auth DDL Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6329_user_cache_and_ddl_serialization.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");
const auth_graph_manager_mod = @import("auth_graph_manager");
const policy_persistence = @import("policy_persistence");
const cli_args = @import("cli_args");

const graph_store = geode.graph_store;
const policy_catalog = geode.security.policy_catalog;
const execution = geode.execution;
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const HMAC_KEY = [_]u8{0x63} ** 32;
const lock_io = std.Io.Threaded.global_single_threaded.io();

fn sleepMs(ms: u64) void {
    lock_io.sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

/// `server_init.wireGpsPolicyHooks`'s write-through hooks.
const PolicyHooks = struct {
    var agm: ?*AuthGraphManager = null;

    fn persist(_: *anyopaque, spec: policy_catalog.PolicySpec) anyerror!void {
        const am = agm orelse return;
        try policy_persistence.persistPolicy(am, &am.hmac_key, spec);
    }

    fn drop(_: *anyopaque, name: []const u8) anyerror!void {
        const am = agm orelse return;
        try policy_persistence.dropPolicy(am, &am.hmac_key, name);
    }

    fn alter(_: *anyopaque, name: []const u8, set_enabled: ?bool, rename_to: ?[]const u8) anyerror!void {
        const am = agm orelse return;
        try policy_persistence.alterPolicy(am, &am.hmac_key, name, set_enabled, rename_to);
    }
};

/// A `__geode_security` store with its auth manager (user alice), a policy
/// catalog and the policy write-through wired to it.
const World = struct {
    h: harness.Harness,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    cat: policy_catalog.PolicyCatalog,
    alice_id: u64 = 0,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        _ = graph_store.getGlobalStore(testing.allocator);
        try graph_store.getGlobalStore(testing.allocator).createGraph("g1");
        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);
        self.alice_id = try self.agm.createUser(&HMAC_KEY, "alice", "alice@example.com", "not_a_real_hash", false);

        self.cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        policy_catalog.setGlobalCatalog(&self.cat);
        PolicyHooks.agm = &self.agm;
        policy_catalog.setWriteThroughHooks(.{
            .ctx = @ptrCast(&self.agm),
            .persist = PolicyHooks.persist,
            .drop = PolicyHooks.drop,
            .alter = PolicyHooks.alter,
        });
    }

    fn deinit(self: *World) void {
        policy_catalog.setWriteThroughHooks(null);
        PolicyHooks.agm = null;
        policy_catalog.clearGlobalCatalog();
        self.cat.deinit();
        AuthGraphManager.setGlobal(null);
        self.agm.deinit();
        self.sec_store.deinit();
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }

    fn createPolicy(self: *World, name: []const u8) !void {
        const actions = [_]policy_catalog.Action{.write};
        try execution.policy_ddl.create(&self.cat, .{
            .name = name,
            .scope_graph = "g1",
            .actions = &actions,
            .effect = .deny,
            .expression_source = "true",
            .enabled = true,
        });
    }

    /// The next start: a manager loaded from the store verifies the chain
    /// and hydrates a catalog. Returns whether that catalog has `name`.
    fn nextStartLoads(self: *World, name: []const u8) !bool {
        var fresh = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        defer fresh.deinit();
        try fresh.verifyChain(&HMAC_KEY);
        var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        defer cat.deinit();
        try policy_persistence.hydrateCatalog(testing.allocator, &fresh, &cat);
        return cat.contains(name);
    }
};

// ---------------------------------------------------------------------------
// (1) The user cache
// ---------------------------------------------------------------------------

const Lookup = struct {
    agm: *AuthGraphManager,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    found: ?u64 = null,

    fn run(self: *Lookup) void {
        self.found = self.agm.findUserIdByName("alice") catch null;
        self.done.store(true, .release);
    }
};

test "SONNY-6329: a user lookup waits while a writer holds the user cache, then sees the user (deterministic)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    var lookup: Lookup = .{ .agm = &w.agm };
    w.agm.storage.user_cache_lock.lockUncancelable(lock_io);
    const t = try std.Thread.spawn(.{}, Lookup.run, .{&lookup});
    sleepMs(100);
    const waited = !lookup.done.load(.acquire);
    w.agm.storage.user_cache_lock.unlock(lock_io);
    t.join();
    try testing.expect(waited);
    try testing.expectEqual(@as(?u64, w.alice_id), lookup.found);
}

const CacheStress = struct {
    agm: *AuthGraphManager,
    alice_id: u64,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wrong: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    lookups: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn reader(self: *CacheStress) void {
        while (!self.stop.load(.acquire)) {
            const id = self.agm.findUserIdByName("alice") catch null;
            if (id != self.alice_id) _ = self.wrong.fetchAdd(1, .monotonic);
            _ = self.lookups.fetchAdd(1, .monotonic);
        }
    }

    fn writer(self: *CacheStress) void {
        defer self.stop.store(true, .release);
        var ids: [48]u64 = undefined;
        var round: usize = 0;
        while (round < 3) : (round += 1) {
            // Enough users to grow (rehash) the map, then all removed.
            for (&ids, 0..) |*id, i| {
                var buf: [32]u8 = undefined;
                const name = std.fmt.bufPrint(&buf, "tmp{d}_{d}", .{ round, i }) catch unreachable;
                id.* = self.agm.createUser(&HMAC_KEY, name, "tmp@example.com", "not_a_real_hash", false) catch return;
            }
            for (ids) |id| self.agm.removeUser(&HMAC_KEY, id) catch return;
        }
    }
};

test "SONNY-6329: user lookups racing CREATE/DROP USER in the auth manager always find the user (stress)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    var s: CacheStress = .{ .agm = &w.agm, .alice_id = w.alice_id };
    var readers: [3]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, CacheStress.reader, .{&s});
    const wt = try std.Thread.spawn(.{}, CacheStress.writer, .{&s});
    wt.join();
    for (readers) |t| t.join();
    if (s.wrong.load(.monotonic) != 0) {
        std.debug.print("{d} of {d} lookups did not find alice\n", .{ s.wrong.load(.monotonic), s.lookups.load(.monotonic) });
        return error.LookupRacedWriter;
    }
    try w.agm.verifyChain(&HMAC_KEY);
}

// ---------------------------------------------------------------------------
// (2) Policy DDL serialization
// ---------------------------------------------------------------------------

const Dropper = struct {
    w: *World,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,

    fn run(self: *Dropper) void {
        _ = execution.policy_ddl.drop(&self.w.cat, "p6329", false) catch |e| {
            self.err = e;
        };
        self.done.store(true, .release);
    }
};

test "SONNY-6329: a DROP POLICY waits for an auth change in progress on another connection (deterministic)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.createPolicy("p6329");

    var d: Dropper = .{ .w = &w };
    const guard = geode.security.auth_ddl_lock.acquire();
    const t = try std.Thread.spawn(.{}, Dropper.run, .{&d});
    sleepMs(100);
    const waited = !d.done.load(.acquire);
    const still_there = w.cat.contains("p6329") and w.agm.findPolicyIdByName("p6329") != null;
    guard.release();
    t.join();
    try testing.expect(waited);
    try testing.expect(still_there);
    try testing.expectEqual(@as(?anyerror, null), d.err);
    try testing.expect(!w.cat.contains("p6329"));
    try testing.expect(w.agm.findPolicyIdByName("p6329") == null);
}

const DdlRace = struct {
    w: *World,
    seed: u64,

    fn run(self: *DdlRace) void {
        var prng = std.Random.DefaultPrng.init(self.seed);
        const r = prng.random();
        var i: usize = 0;
        while (i < 60) : (i += 1) {
            if (r.boolean()) {
                self.w.createPolicy("race6329") catch {};
            } else {
                _ = execution.policy_ddl.drop(&self.w.cat, "race6329", true) catch {};
            }
        }
    }
};

test "SONNY-6329: CREATE and DROP POLICY of one name racing on four connections leave the catalog and __geode_security agreeing (stress)" {
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        var w: World = undefined;
        try w.init();
        defer w.deinit();

        var racers: [4]DdlRace = undefined;
        var threads: [4]std.Thread = undefined;
        for (&racers, &threads, 0..) |*rc, *t, i| {
            rc.* = .{ .w = &w, .seed = round * 16 + i + 1 };
            t.* = try std.Thread.spawn(.{}, DdlRace.run, .{rc});
        }
        for (threads) |t| t.join();

        const in_cat = w.cat.contains("race6329");
        const stored = w.agm.findPolicyIdByName("race6329") != null;
        try w.agm.verifyChain(&HMAC_KEY);
        const loads = try w.nextStartLoads("race6329");
        if (in_cat != stored or stored != loads) {
            std.debug.print("round {d}: catalog={}, stored={}, next start loads={}\n", .{ round, in_cat, stored, loads });
            return error.CatalogAndStoreDisagree;
        }
    }
}

// ---------------------------------------------------------------------------
// (3) geode serve --no-auth
// ---------------------------------------------------------------------------

test "SONNY-6329: geode serve --no-auth fails instead of claiming authentication is off" {
    const args = [_][]const u8{ "geode", "--no-auth" };
    if (cli_args.parseArgsFromSlice(testing.allocator, &args)) |maybe| {
        if (maybe) |cfg| {
            var c = cfg;
            c.deinit(testing.allocator);
        }
        std.debug.print("--no-auth was accepted\n", .{});
        return error.NoAuthAccepted;
    } else |err| {
        try testing.expectEqual(error.NoAuthUnsupported, err);
    }
}
