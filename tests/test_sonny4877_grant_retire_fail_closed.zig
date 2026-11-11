// SONNY-4877: retiring the legacy grant-migrated Policy rows must fail closed.
//
// Earlier versions turned every (:GraphGrant) into an allow policy named
// "auto_migrated_grant_<user>_<graph>_<action>". Each startup now drops those
// rows (grant_migration.retireMigratedGrantPolicies), because a stale one keeps
// a revoked grant in force. The retirement collects names and deletes the
// stored rows, and either step can fail; wireGpsPolicyHooks logs the error and
// carries on starting. Before the fix nothing touched the live catalog until
// both had succeeded, so after a failure the legacy allow stayed enabled and
// gps.decide() still allowed the revoked principal.
//
// These tests inject allocation failures, at every allocation in turn, into
// the name collection (the `allocator` argument) and into the persistence
// delete (the allocator under the __geode_security store), and drive the real
// gps.decide() with the real PolicyCatalog, decision cache and AuthGraphManager:
//   - after a failed retirement no legacy allow authorizes anything, including
//     a decision cached before the retirement ran;
//   - a legacy deny keeps refusing while cleanup is incomplete;
//   - a later retirement that succeeds drops every row from the catalog and
//     the store, and the HMAC chain verifies.
//
// CANARY: REQ=REQ-SONNY-4877-GRANT-RETIRE-FAIL-CLOSED; FEATURE="PerGraphGrants"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny4877_grant_retire_fail_closed.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const auth_graph_manager_mod = @import("auth_graph_manager");
const policy_persistence = @import("policy_persistence");
const grant_migration = @import("grant_migration");

const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const policy_catalog = geode.security.policy_catalog;
const decision_cache = geode.security.decision_cache;
const graph_store = geode.graph_store;
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;
const PolicyCatalog = policy_catalog.PolicyCatalog;

const HMAC_KEY = [_]u8{0x48} ** 32;

/// The revoked principal: ReadOnly, so only a grant or an allow policy can
/// let it write.
const otto_roles = [_][]const u8{"ReadOnly"};

fn otto() principal_mod.Principal {
    return .{
        .user_id = null,
        .username = "otto",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &otto_roles,
        .custom_roles = &.{},
        .auth_method = .password,
        // Non-zero so decisions are cached: a cached allow must not outlive
        // the disabling of the policy that produced it.
        .auth_version = 7,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

fn decideKind(action: gps.Action, graph: []const u8) !gps.PolicyDecisionKind {
    const p = otto();
    const req = gps.DecisionRequest{ .principal = &p, .action = action, .resource = .{ .graph = graph } };
    return (try gps.decide(testing.allocator, &req)).kind;
}

/// Store and catalog a policy the way the old migration (or an operator, for
/// the deny) wrote one.
fn plant(agm: *AuthGraphManager, cat: *PolicyCatalog, name: []const u8, graph: []const u8, action: policy_catalog.Action, effect: policy_catalog.Effect) !void {
    const actions = [_]policy_catalog.Action{action};
    const spec = policy_catalog.PolicySpec{
        .name = name,
        .scope_graph = graph,
        .actions = &actions,
        .effect = effect,
        .expression_source = "current_user() = 'otto'",
        .enabled = true,
    };
    try policy_persistence.persistPolicy(agm, &HMAC_KEY, spec);
    try cat.addPolicy(spec);
}

fn countMigrated(cat: *const PolicyCatalog) usize {
    var n: usize = 0;
    for (cat.listPolicies()) |p| {
        if (std.mem.startsWith(u8, p.name, grant_migration.migrated_policy_prefix)) n += 1;
    }
    return n;
}

fn countStoredMigrated(agm: *AuthGraphManager) !usize {
    var fresh = PolicyCatalog.init(testing.allocator);
    defer fresh.deinit();
    try policy_persistence.hydrateCatalog(testing.allocator, agm, &fresh);
    return countMigrated(&fresh);
}

/// A database the old migration ran on, with otto's grants since revoked:
/// two legacy allows (write on hr, write on sales), one legacy-named deny
/// (read on ops) and one operator allow that must survive.
const World = struct {
    store: graph_store.GraphStore,
    agm: AuthGraphManager,
    cat: PolicyCatalog,
    cache: decision_cache.DecisionCache,
    prev_grant_fn: @TypeOf(geode.execution.graph_grant_check_fn),

    fn init(self: *World, store_allocator: std.mem.Allocator) !void {
        self.store = try graph_store.GraphStore.init(store_allocator);
        errdefer self.store.deinit();
        self.agm = try AuthGraphManager.init(store_allocator, &self.store);
        errdefer self.agm.deinit();
        self.cat = PolicyCatalog.init(testing.allocator);
        errdefer self.cat.deinit();
        self.cache = decision_cache.DecisionCache.init(testing.allocator, decision_cache.DEFAULT_CAPACITY);

        try plant(&self.agm, &self.cat, "auto_migrated_grant_otto_hr_write", "hr", .write, .allow);
        try plant(&self.agm, &self.cat, "auto_migrated_grant_otto_sales_write", "sales", .write, .allow);
        try plant(&self.agm, &self.cat, "auto_migrated_grant_otto_ops_read", "ops", .read, .deny);
        try plant(&self.agm, &self.cat, "otto_reads_lab", "lab", .write, .allow);

        // No live grant: otto's grants were revoked.
        self.prev_grant_fn = geode.execution.graph_grant_check_fn;
        geode.execution.graph_grant_check_fn = null;
        policy_catalog.setGlobalCatalog(&self.cat);
        decision_cache.setGlobalCache(&self.cache);
    }

    fn deinit(self: *World) void {
        decision_cache.clearGlobalCache();
        policy_catalog.clearGlobalCatalog();
        geode.execution.graph_grant_check_fn = self.prev_grant_fn;
        self.cache.deinit();
        self.cat.deinit();
        self.agm.deinit();
        self.store.deinit();
    }

    /// Before the retirement: the stale rows decide (and the allows are
    /// cached).
    fn expectStaleRowsInForce(self: *World) !void {
        _ = self;
        try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(.write, "hr"));
        try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(.write, "sales"));
        try testing.expectEqual(gps.PolicyDecisionKind.deny, try decideKind(.read, "ops"));
    }

    /// After a FAILED retirement: no legacy allow grants anything (not even
    /// from the cache), the legacy deny still refuses, and the operator's
    /// policy is untouched.
    fn expectFailClosed(self: *World) !void {
        try testing.expect(try decideKind(.write, "hr") != .allow);
        try testing.expect(try decideKind(.write, "sales") != .allow);
        try testing.expectEqual(gps.PolicyDecisionKind.deny, try decideKind(.read, "ops"));
        try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(.write, "lab"));
        for (self.cat.listPolicies()) |p| {
            if (!std.mem.startsWith(u8, p.name, grant_migration.migrated_policy_prefix)) continue;
            if (p.effect == .allow) try testing.expect(!p.enabled);
        }
    }

    /// After a SUCCESSFUL retirement: every legacy row is gone from the
    /// catalog and the store, the chain verifies, the operator's policy
    /// stays.
    fn expectRetired(self: *World) !void {
        try testing.expectEqual(@as(usize, 0), countMigrated(&self.cat));
        try testing.expectEqual(@as(usize, 1), self.cat.listPolicies().len);
        try testing.expectEqualStrings("otto_reads_lab", self.cat.listPolicies()[0].name);
        try self.agm.verifyChain(&HMAC_KEY);
        try testing.expectEqual(@as(usize, 0), try countStoredMigrated(&self.agm));
        try testing.expect(try decideKind(.write, "hr") != .allow);
        try testing.expect(try decideKind(.write, "sales") != .allow);
        try testing.expect(try decideKind(.read, "ops") != .deny);
        try testing.expectEqual(gps.PolicyDecisionKind.allow, try decideKind(.write, "lab"));
    }
};

// CANARY: REQ=REQ-SONNY-4877-GRANT-RETIRE-FAIL-CLOSED; FEATURE="PerGraphGrants"; ASPECT=NameCollectionAllocFailure; STATUS=TESTED; TEST=tests/test_sonny4877_grant_retire_fail_closed.zig; OWNER=security; UPDATED=2026-11-11
test "sonny4877: an allocation failure collecting legacy names leaves no legacy allow in force; a retry completes" {
    var fail_index: usize = 0;
    var failures: usize = 0;
    while (true) : (fail_index += 1) {
        var w: World = undefined;
        try w.init(testing.allocator);
        defer w.deinit();
        try w.expectStaleRowsInForce();

        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        if (grant_migration.retireMigratedGrantPolicies(fa.allocator(), &w.agm, &HMAC_KEY, &w.cat)) |retired| {
            try testing.expectEqual(@as(u32, 3), retired);
            try w.expectRetired();
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try w.expectFailClosed();
            // The next startup (or any retry) completes the cleanup.
            _ = try grant_migration.retireMigratedGrantPolicies(testing.allocator, &w.agm, &HMAC_KEY, &w.cat);
            try w.expectRetired();
        }
    }
    try testing.expect(failures > 0);
}

// CANARY: REQ=REQ-SONNY-4877-GRANT-RETIRE-FAIL-CLOSED; FEATURE="PerGraphGrants"; ASPECT=PersistenceDeleteFailure; STATUS=TESTED; TEST=tests/test_sonny4877_grant_retire_fail_closed.zig; OWNER=security; UPDATED=2026-11-11
test "sonny4877: a failure deleting stored legacy rows leaves no legacy allow in force; a retry completes with a valid chain" {
    var offset: usize = 0;
    var failures: usize = 0;
    while (true) : (offset += 1) {
        // The store's allocator fails the offset-th allocation made during
        // the retirement (none before it).
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var w: World = undefined;
        try w.init(fa.allocator());
        defer w.deinit();
        try w.expectStaleRowsInForce();

        fa.fail_index = fa.alloc_index + offset;
        const result = grant_migration.retireMigratedGrantPolicies(testing.allocator, &w.agm, &HMAC_KEY, &w.cat);
        fa.fail_index = std.math.maxInt(usize);
        if (result) |retired| {
            try testing.expectEqual(@as(u32, 3), retired);
            try w.expectRetired();
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try w.expectFailClosed();
            _ = try grant_migration.retireMigratedGrantPolicies(testing.allocator, &w.agm, &HMAC_KEY, &w.cat);
            try w.expectRetired();
        }
    }
    try testing.expect(failures > 0);
}
