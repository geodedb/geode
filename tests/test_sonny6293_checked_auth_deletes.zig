// SONNY-6293: a security record whose node delete fails stays stored, in
// memory as in the store, and the chain still verifies.
//
// `UserStorageBackend.removePolicy`, `removeRole` and `removeUser` dropped
// the cached record and the node mapping, then called `GraphStore.deleteNode`
// and ignored whether the node went. When it did not, the node stayed in
// `__geode_security` while the record was gone from memory: the chain was
// sealed without it (the next start loaded the policy or role again, and the
// sealed record count no longer matched), and DROP POLICY reported success.
// Grant removal has used the checked delete since SONNY-1333.
//
// The failure is injected with `UserStorageBackend.fail_deletes_for_testing`
// (a test-only hook in the checked delete: the node delete is skipped, as a
// graph store that failed part way would leave it, and the existence check
// that follows reports it). The statements run through the in-process gRPC
// Execute handler with authorization on.
//
// CANARY: REQ=REQ-SONNY-6293-CHECKED-AUTH-DELETES; FEATURE="GQL Auth DDL Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6293_checked_auth_deletes.zig; OWNER=security; UPDATED=2026-11-12

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
const auth_dispatch = geode.auth_dispatch;
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const HMAC_KEY = [_]u8{0x64} ** 32;
const NAME = "p6293";

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

/// `server_init.wireAuthDDLCallbacks`'s role callbacks.
const RoleHooks = struct {
    var agm: ?*AuthGraphManager = null;

    fn create(_: ?*anyopaque, name: []const u8, description: []const u8) anyerror!u64 {
        return agm.?.createRole(&HMAC_KEY, name, description);
    }

    fn findId(_: ?*anyopaque, name: []const u8) anyerror!?u64 {
        return agm.?.findRoleIdByName(name);
    }

    fn remove(_: ?*anyopaque, role_id: u64) anyerror!void {
        try agm.?.removeRole(&HMAC_KEY, role_id);
    }
};

const Effect = policy_catalog.Effect;

/// Authorization on; graph g1 with a :C node; a `__geode_security` store
/// and its auth manager; the policy and role write-throughs wired to it;
/// policy p6293 FOR WRITE on g1; an Admin session and bob (readwrite).
const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    cat: policy_catalog.PolicyCatalog,
    admin: []const u8 = "",
    bob: []const u8 = "",
    carol_id: u64 = 0,
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

        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);
        self.carol_id = try self.agm.createUser(&HMAC_KEY, "carol", "carol@example.com", "not_a_real_hash", false);

        self.cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        policy_catalog.setGlobalCatalog(&self.cat);
        PolicyHooks.agm = &self.agm;
        policy_catalog.setWriteThroughHooks(.{
            .ctx = @ptrCast(&self.agm),
            .persist = PolicyHooks.persist,
            .drop = PolicyHooks.drop,
            .alter = PolicyHooks.alter,
        });
        RoleHooks.agm = &self.agm;
        auth_dispatch.setRolePersistCallbacks(.{
            .create_fn = &RoleHooks.create,
            .find_id_fn = &RoleHooks.findId,
            .remove_fn = &RoleHooks.remove,
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
        self.admin = try self.sessions.createSession("root6293", "", .Admin, null, null, false, 0);
        self.bob = try self.sessions.createSession("bob", "", .ReadWrite, null, null, false, 0);
        try self.agm.verifyChain(&HMAC_KEY);
    }

    fn deinit(self: *World) void {
        Faults.set(0);
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        auth_dispatch.setRolePersistCallbacks(.{});
        auth_dispatch.deinitCustomRoleStore();
        RoleHooks.agm = null;
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

    /// The next start: a manager loaded from the store verifies the chain.
    fn nextStart(self: *World) !AuthGraphManager {
        var fresh = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        errdefer fresh.deinit();
        fresh.verifyChain(&HMAC_KEY) catch |err| {
            std.debug.print("the next start does not verify the auth chain: {s}\n", .{@errorName(err)});
            return err;
        };
        return fresh;
    }

    fn nextStartLoadsPolicy(self: *World) !bool {
        var fresh = try self.nextStart();
        defer fresh.deinit();
        var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        defer cat.deinit();
        try policy_persistence.hydrateCatalog(testing.allocator, &fresh, &cat);
        return cat.contains(NAME);
    }
};

/// The test-only delete fault of the auth store's checked delete.
const Faults = struct {
    fn set(n: u32) void {
        @FieldType(AuthGraphManager, "storage").fail_deletes_for_testing.store(n, .release);
    }
};

const BOB_WRITES = "USE GRAPH g1; CREATE (:W {v: 1})";

fn dropPolicyFails(effect: Effect) !void {
    var w: World = undefined;
    try w.init(effect);
    defer w.deinit();
    const ga = w.ga();
    if (effect == .deny) _ = try fx.expectRefused(ga, w.bob, BOB_WRITES, "42501");

    Faults.set(1);
    const code = try fx.outcome(ga, w.admin, "DROP POLICY " ++ NAME);
    Faults.set(0);
    const stored = w.agm.findPolicyIdByName(NAME) != null;
    const in_cat = w.cat.contains(NAME);
    w.agm.verifyChain(&HMAC_KEY) catch |err| {
        std.debug.print("{s} DROP POLICY with a failed node delete (answered {?s}): stored={}, catalog={}; chain: {s}\n", .{ @tagName(effect), code, stored, in_cat, @errorName(err) });
        return err;
    };
    if (code == null) {
        std.debug.print("{s} DROP POLICY whose node delete failed reported success (stored={}, catalog={})\n", .{ @tagName(effect), stored, in_cat });
        return error.FailedDeleteReportedSuccess;
    }
    try testing.expectEqualStrings("58030", code.?);
    try testing.expect(stored);
    try testing.expect(in_cat);
    try testing.expect(try w.nextStartLoadsPolicy());
    // A deny whose drop failed still denies.
    if (effect == .deny) _ = try fx.expectRefused(ga, w.bob, BOB_WRITES, "42501");

    // The retry drops it.
    try fx.expectRuns(ga, w.admin, "DROP POLICY " ++ NAME);
    try testing.expect(w.agm.findPolicyIdByName(NAME) == null);
    try testing.expect(!w.cat.contains(NAME));
    try w.agm.verifyChain(&HMAC_KEY);
    try testing.expect(!(try w.nextStartLoadsPolicy()));
    if (effect == .deny) try fx.expectRuns(ga, w.bob, BOB_WRITES);
}

test "SONNY-6293: a DENY policy whose node delete fails: DROP POLICY answers 58030, the policy stays stored and enforced, the chain verifies, the retry drops it" {
    try dropPolicyFails(.deny);
}

test "SONNY-6293: an ALLOW policy whose node delete fails: DROP POLICY answers 58030, the policy stays stored and in the catalog, the chain verifies" {
    try dropPolicyFails(.allow);
}

test "SONNY-6293: a role whose node delete fails stays stored and the chain verifies; the retry drops it" {
    var w: World = undefined;
    try w.init(.allow);
    defer w.deinit();
    const ga = w.ga();
    try fx.expectRuns(ga, w.admin, "CREATE ROLE auditor6293");
    try testing.expect((try w.agm.findRoleIdByName("auditor6293")) != null);

    Faults.set(1);
    const code = try fx.outcome(ga, w.admin, "DROP ROLE auditor6293");
    Faults.set(0);
    const stored = (try w.agm.findRoleIdByName("auditor6293")) != null;
    w.agm.verifyChain(&HMAC_KEY) catch |err| {
        std.debug.print("DROP ROLE with a failed node delete (answered {?s}): stored={}; chain: {s}\n", .{ code, stored, @errorName(err) });
        return err;
    };
    try testing.expectEqualStrings("58030", code orelse return error.FailedDeleteReportedSuccess);
    try testing.expect(stored);
    {
        var fresh = try w.nextStart();
        defer fresh.deinit();
        try testing.expect((try fresh.findRoleIdByName("auditor6293")) != null);
    }

    try fx.expectRuns(ga, w.admin, "DROP ROLE auditor6293");
    try testing.expect((try w.agm.findRoleIdByName("auditor6293")) == null);
    try w.agm.verifyChain(&HMAC_KEY);
    var fresh = try w.nextStart();
    defer fresh.deinit();
    try testing.expect((try fresh.findRoleIdByName("auditor6293")) == null);
}

test "SONNY-6293: a user whose node delete fails stays stored and the chain verifies" {
    var w: World = undefined;
    try w.init(.allow);
    defer w.deinit();

    Faults.set(1);
    const result = w.agm.removeUser(&HMAC_KEY, w.carol_id);
    Faults.set(0);
    try testing.expectError(error.SecurityRecordDeleteFailed, result);
    try testing.expect(w.agm.storage.getUser(w.carol_id) != null);
    try w.agm.verifyChain(&HMAC_KEY);
    {
        var fresh = try w.nextStart();
        defer fresh.deinit();
        try testing.expect((try fresh.findUserIdByName("carol")) != null);
    }
    try w.agm.removeUser(&HMAC_KEY, w.carol_id);
    try testing.expect(w.agm.storage.getUser(w.carol_id) == null);
    try w.agm.verifyChain(&HMAC_KEY);
}
