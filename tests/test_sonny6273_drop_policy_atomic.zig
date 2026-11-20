// SONNY-6273: DROP POLICY and the HMAC chain of `__geode_security`.
//
// AuthGraphManager.dropPolicy removed the policy records and then sealed the
// chain. SONNY-3038 retried a failed seal once; a seal that failed twice
// left the records gone, the chain still covering them (verifyChain:
// RecordCountMismatch) and the statement failed, so the catalog kept the
// policy in memory while the store no longer had it. A restart before the
// next auth write refused to start (AuthChainTampered), and once something
// resealed, the policy the failed statement had kept was gone at the next
// start.
//
// The fault is injected into the AuthGraphManager's own allocator (never the
// GraphStore's, as in SONNY-1333 / SONNY-3038), at every allocation of the
// statement in turn: one allocation failing, and every allocation from that
// one on failing (a shortage that outlasts the retry). After each:
//   - the statement failed, and the record, the catalog entry and the chain
//     are as before (a DENY still denies; the next start loads the policy),
//     and the retry drops it; or
//   - it succeeded, and the record and catalog entry are gone and the chain
//     verifies (now and at the next start, which loads no such policy).
//
// CANARY: REQ=REQ-SONNY-6273-DROP-POLICY-ATOMIC; FEATURE="GPS Policy Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6273_drop_policy_atomic.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const auth_graph_manager_mod = @import("auth_graph_manager");
const policy_persistence = @import("policy_persistence");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const policy_catalog = geode.security.policy_catalog;
const execution = geode.execution;
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const HMAC_KEY = [_]u8{0x62} ** 32;
const NAME = "p6273";

// ---------------------------------------------------------------------------
// Fault injection
// ---------------------------------------------------------------------------

/// Fails `run` consecutive allocations starting with the `offset`-th after
/// `arm` (1: one transient failure; maxInt: every allocation from there on,
/// until `disarm`), and lets every other one through.
const Faults = struct {
    inner: std.mem.Allocator,
    count: usize = 0,
    fail_from: usize = std.math.maxInt(usize),
    run: usize = 0,
    failed: usize = 0,

    fn allocator(self: *Faults) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn arm(self: *Faults, offset: usize, run: usize) void {
        self.fail_from = self.count + offset;
        self.run = run;
        self.failed = 0;
    }

    fn disarm(self: *Faults) void {
        self.fail_from = std.math.maxInt(usize);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Faults = @ptrCast(@alignCast(ctx));
        if (self.count == self.fail_from and self.failed < self.run) {
            self.failed += 1;
            if (self.failed == self.run) self.count += 1;
            return null;
        }
        self.count += 1;
        return self.inner.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Faults = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Faults = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Faults = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
    }
};

// ---------------------------------------------------------------------------
// The deployment
// ---------------------------------------------------------------------------

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

const Effect = policy_catalog.Effect;

/// Authorization on; graph g1 with one :C node; a `__geode_security` store
/// whose AuthGraphManager runs under `faults`; the policy write-through
/// wired to it; policy p6273 FOR WRITE on g1 (`effect`), stored and in the catalog; an
/// Admin session and bob (readwrite).
const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    faults: Faults,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    cat: policy_catalog.PolicyCatalog,
    admin: []const u8 = "",
    bob: []const u8 = "",
    auth_was: bool,
    allow_was: bool,
    strict_was: bool,

    fn init(self: *World, effect: Effect) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        const st = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        try st.createGraph("g1");
        _ = try st.createNodeWithGraph(&[_][]const u8{"C"}, "g1");

        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);
        self.strict_was = geode.tenancy.isStrictTenancy();
        geode.tenancy.setStrictTenancy(false);

        self.faults = .{ .inner = testing.allocator };
        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(self.faults.allocator(), &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);
        // Something else in the chain besides the policy.
        _ = try self.agm.createUser(&HMAC_KEY, "carol", "carol@example.com", "not_a_real_hash", false);

        self.cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        policy_catalog.setGlobalCatalog(&self.cat);
        PolicyHooks.agm = &self.agm;
        policy_catalog.setWriteThroughHooks(.{
            .ctx = @ptrCast(&self.agm),
            .persist = PolicyHooks.persist,
            .drop = PolicyHooks.drop,
            .alter = PolicyHooks.alter,
        });
        const actions = [_]policy_catalog.Action{.write};
        try execution.policy_ddl.create(&self.cat, .{
            .name = NAME,
            .scope_graph = "g1",
            .actions = &actions,
            .effect = effect,
            .expression_source = "true",
            .enabled = true,
        });

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root6273", "", .Admin, null, null, false, 0);
        self.bob = try self.sessions.createSession("bob", "", .ReadWrite, null, null, false, 0);
        try self.agm.verifyChain(&HMAC_KEY);
    }

    fn deinit(self: *World) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        policy_catalog.setWriteThroughHooks(null);
        PolicyHooks.agm = null;
        policy_catalog.clearGlobalCatalog();
        self.cat.deinit();
        AuthGraphManager.setGlobal(null);
        self.agm.deinit();
        self.sec_store.deinit();
        geode.tenancy.setStrictTenancy(self.strict_was);
        gps.setInsecureAllowAll(self.allow_was);
        user_mgmt.setAuthEnabled(self.auth_was);
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }

    fn ga(self: *World) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn inCatalog(self: *World) bool {
        for (self.cat.listPolicies()) |p| {
            if (std.mem.eql(u8, p.name, NAME)) return true;
        }
        return false;
    }

    fn stored(self: *World) bool {
        return self.agm.findPolicyIdByName(NAME) != null;
    }

    /// The next start: a manager loaded from the store verifies the chain
    /// and hydrates a catalog. Returns whether that catalog has the policy.
    fn nextStartLoads(self: *World) !bool {
        var fresh = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        defer fresh.deinit();
        fresh.verifyChain(&HMAC_KEY) catch |err| {
            std.debug.print("the next start does not verify the auth chain: {s}\n", .{@errorName(err)});
            return err;
        };
        var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        defer cat.deinit();
        try policy_persistence.hydrateCatalog(testing.allocator, &fresh, &cat);
        for (cat.listPolicies()) |p| {
            if (std.mem.eql(u8, p.name, NAME)) return true;
        }
        return false;
    }
};

/// A DENY WRITE on g1 refuses it (docs/security/gps-decide.md, SONNY-2781).
const BOB_WRITES = "USE GRAPH g1; CREATE (:W {v: 1})";

/// DROP POLICY with `run` consecutive allocations of the AuthGraphManager
/// failing, from every allocation of the statement in turn. Returns how many
/// offsets made the statement fail.
fn sweepDrop(effect: Effect, run: usize) !usize {
    var offset: usize = 0;
    var failures: usize = 0;
    while (true) : (offset += 1) {
        var w: World = undefined;
        try w.init(effect);
        defer w.deinit();
        const ga = w.ga();
        if (effect == .deny) _ = try fx.expectRefused(ga, w.bob, BOB_WRITES, "42501");

        w.faults.arm(offset, run);
        const code = try fx.outcome(ga, w.admin, "DROP POLICY " ++ NAME);
        const induced = w.faults.failed > 0;
        w.faults.disarm();

        const in_cat = w.inCatalog();
        const in_store = w.stored();
        w.agm.verifyChain(&HMAC_KEY) catch |err| {
            std.debug.print("{s} DROP POLICY (run {d}, offset {d}, refused={}): stored={}, catalog={}; the chain does not verify: {s}\n", .{ @tagName(effect), run, offset, code != null, in_store, in_cat, @errorName(err) });
            return err;
        };
        if (code) |c| {
            if (!induced) {
                std.debug.print("DROP POLICY refused {s} with nothing injected\n", .{c});
                return error.UnexpectedRefusal;
            }
            failures += 1;
            if (!in_store or !in_cat) {
                std.debug.print("{s} DROP POLICY (run {d}, offset {d}) failed ({s}) but stored={}, catalog={}\n", .{ @tagName(effect), run, offset, c, in_store, in_cat });
                return error.FailedDropChangedState;
            }
            try testing.expect(try w.nextStartLoads());
            // A deny whose drop failed still denies.
            if (effect == .deny) _ = try fx.expectRefused(ga, w.bob, BOB_WRITES, "42501");
            // The retry drops it.
            try fx.expectRuns(ga, w.admin, "DROP POLICY " ++ NAME);
        } else if (in_store or in_cat) {
            std.debug.print("{s} DROP POLICY (run {d}, offset {d}) succeeded but stored={}, catalog={}\n", .{ @tagName(effect), run, offset, in_store, in_cat });
            return error.SucceededDropLeftState;
        }
        try testing.expect(!w.stored());
        try testing.expect(!w.inCatalog());
        try w.agm.verifyChain(&HMAC_KEY);
        try testing.expect(!(try w.nextStartLoads()));
        if (effect == .deny) try fx.expectRuns(ga, w.bob, BOB_WRITES);
        if (!induced) break;
    }
    return failures;
}

test "SONNY-6273: a DROP POLICY with one allocation failing, at every allocation, fails with nothing changed or succeeds with a valid chain" {
    _ = try sweepDrop(.allow, 1);
    _ = try sweepDrop(.deny, 1);
}

test "SONNY-6273: a DROP POLICY whose allocations keep failing (the seal's retry too) never leaves the record gone and the chain stale" {
    try testing.expect(try sweepDrop(.allow, std.math.maxInt(usize)) > 0);
    try testing.expect(try sweepDrop(.deny, std.math.maxInt(usize)) > 0);
}

test "SONNY-6273: a dropped policy stored twice: every failure point leaves both records or neither" {
    var offset: usize = 0;
    while (true) : (offset += 1) {
        var w: World = undefined;
        try w.init(.deny);
        defer w.deinit();
        // A second stored GPS record of the name (written before names were
        // unique, or by another writer).
        const id = w.agm.storage.nextPolicyId();
        try w.agm.storage.persistPolicy(.{
            .policy_id = id,
            .name = NAME,
            .description = "",
            .graph = "g1",
            .table = "",
            .operation = 2, // write
            .permissive = false,
            .enabled = true,
            .using_clause = "true",
            .check_clause = null,
            .audit_level = 0,
            .created_by = 0,
            .kind = .gps,
            .mode = .create,
        });
        try w.agm.sealChain(&HMAC_KEY);

        w.faults.arm(offset, std.math.maxInt(usize));
        const code = try fx.outcome(w.ga(), w.admin, "DROP POLICY " ++ NAME);
        const induced = w.faults.failed > 0;
        w.faults.disarm();

        var left: usize = 0;
        var it = w.agm.storage.policyIterator();
        while (it.next()) |r| {
            if (std.mem.eql(u8, r.getName(), NAME)) left += 1;
        }
        try w.agm.verifyChain(&HMAC_KEY);
        if (code != null) {
            try testing.expect(induced);
            try testing.expectEqual(@as(usize, 2), left);
            try testing.expect(w.inCatalog());
        } else {
            try testing.expectEqual(@as(usize, 0), left);
            try testing.expect(!w.inCatalog());
        }
        if (!induced) break;
    }
}

/// SONNY-6273 (follow-up): the next `n` chain-root writes fail part way
/// (`UserStorageBackend.fail_chain_root_writes_for_testing`: the chain hash
/// written, the record count not).
fn failChainRootWrites(n: u32) void {
    @FieldType(AuthGraphManager, "storage").fail_chain_root_writes_for_testing.store(n, .release);
}

test "SONNY-6273: a DROP POLICY whose chain-root write fails, and both reseals too, puts the records back: the chain verifies and the next start loads the policy" {
    defer failChainRootWrites(0);
    for ([_]Effect{ .allow, .deny }) |effect| {
        var w: World = undefined;
        try w.init(effect);
        defer w.deinit();
        const ga = w.ga();
        if (effect == .deny) _ = try fx.expectRefused(ga, w.bob, BOB_WRITES, "42501");

        // The drop's own seal and its two reseals.
        failChainRootWrites(3);
        const code = try fx.outcome(ga, w.admin, "DROP POLICY " ++ NAME);
        failChainRootWrites(0);
        if (code == null) {
            std.debug.print("SONNY-6273: DROP POLICY succeeded although its chain root was never stored\n", .{});
            return error.DropSucceededUnsealed;
        }
        if (!w.stored() or !w.inCatalog()) {
            std.debug.print("SONNY-6273: DROP POLICY failed ({s}) with its chain root unstored, but stored={}, catalog={}\n", .{ code.?, w.stored(), w.inCatalog() });
            return error.FailedDropChangedState;
        }
        w.agm.verifyChain(&HMAC_KEY) catch |err| {
            std.debug.print("SONNY-6273: after a DROP POLICY whose chain root was never stored the chain does not verify: {s} (the next start fails with AuthChainTampered)\n", .{@errorName(err)});
            return err;
        };
        try testing.expect(try w.nextStartLoads());
        if (effect == .deny) _ = try fx.expectRefused(ga, w.bob, BOB_WRITES, "42501");
        // The retry drops it.
        try fx.expectRuns(ga, w.admin, "DROP POLICY " ++ NAME);
        try testing.expect(!w.stored());
        try w.agm.verifyChain(&HMAC_KEY);
        try testing.expect(!(try w.nextStartLoads()));
    }
}
