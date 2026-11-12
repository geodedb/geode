// CANARY: REQ=REQ-SONNY-6293-CHECKED-AUTH-DELETE; FEATURE="Checked security record deletion"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6293_checked_auth_delete.zig; OWNER=security; UPDATED=2026-11-11
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const GraphStore = geode.graph_store.GraphStore;
const AuthGraphManager = @import("auth_graph_manager").AuthGraphManager;
const persistence = @import("policy_persistence");
const policies = geode.security.policy_catalog;
const Harness = @import("support/auth_procedure_harness.zig").Harness;
const key = [_]u8{0x63} ** 32;
const Kind = enum { role, policy };
const Fault = enum { write_fence, allocation };

fn backendFailure(kind: Kind, fault: Fault) !void {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store = try GraphStore.init(failing.allocator());
    defer store.deinit();
    var manager = try AuthGraphManager.init(testing.allocator, &store);
    defer manager.deinit();
    const id = switch (kind) {
        .role => try manager.createRole(&key, "kept-role", ""),
        .policy => try manager.createPolicy(&key, "kept_policy", "*", 1, false, "true", true),
    };
    const node_id = switch (kind) {
        .role => manager.storage.role_nodes.get(id).?,
        .policy => manager.storage.policy_nodes.get(id).?,
    };
    try manager.verifyChain(&key);

    const owns = geode.eval.enterInPredicateScope();
    defer {
        _ = geode.eval.takeDeferredLimitError(owns);
        _ = geode.eval.exitInPredicateScope(owns);
    }
    switch (fault) {
        .write_fence => geode.eval.recordLimitError(error.OutOfMemory),
        .allocation => failing.fail_index = failing.alloc_index,
    }
    const outcome = switch (kind) {
        .role => manager.storage.removeRole(id),
        .policy => manager.storage.removePolicy(id),
    };
    failing.fail_index = std.math.maxInt(usize);
    _ = geode.eval.takeDeferredLimitError(owns);
    if (fault == .allocation) try testing.expect(failing.has_induced_failure);
    try testing.expectError(error.OutOfMemory, outcome);
    try testing.expect(store.getNodePtr(node_id) != null);
    switch (kind) {
        .role => {
            try testing.expect(manager.storage.getRole(id) != null);
            try testing.expectEqual(node_id, manager.storage.role_nodes.get(id).?);
        },
        .policy => {
            try testing.expect(manager.storage.getPolicy(id) != null);
            try testing.expectEqual(node_id, manager.storage.policy_nodes.get(id).?);
        },
    }
    try manager.verifyChain(&key);
    switch (kind) {
        .role => try manager.removeRole(&key, id),
        .policy => try manager.dropPolicy(&key, "kept_policy"),
    }
    try testing.expect(store.getNodePtr(node_id) == null);
    try manager.verifyChain(&key);
}

test "SONNY-6293: failed role deletion retains cache, node and chain" {
    try backendFailure(.role, .write_fence);
}

test "SONNY-6293: failed policy deletion retains cache, node and chain" {
    try backendFailure(.policy, .write_fence);
}

test "SONNY-6293: role deletion allocation failure changes nothing" {
    try backendFailure(.role, .allocation);
}

test "SONNY-6293: policy deletion allocation failure changes nothing" {
    try backendFailure(.policy, .allocation);
}

const Hooks = struct {
    manager: *AuthGraphManager,
    inject: bool = false,

    fn from(ctx: *anyopaque) *Hooks {
        return @ptrCast(@alignCast(ctx));
    }
    fn persist(ctx: *anyopaque, spec: policies.PolicySpec) !void {
        try persistence.persistPolicy(from(ctx).manager, &key, spec);
    }
    fn drop(ctx: *anyopaque, name: []const u8) !void {
        const self = from(ctx);
        // Trip the real store write fence inside the real statement scope.
        // This injects an actual refused delete, not a database response.
        if (self.inject) geode.eval.recordLimitError(error.OutOfMemory);
        try persistence.dropPolicy(self.manager, &key, name);
    }
    fn alter(ctx: *anyopaque, name: []const u8, enabled: ?bool, rename: ?[]const u8) !void {
        try persistence.alterPolicy(from(ctx).manager, &key, name, enabled, rename);
    }
};

fn permission(h: *Harness, effect: policies.Effect) !void {
    const ctx = geode.execution.ExecutionContext{
        .catalog = h.catalog,
        .user = "bob",
        .role = if (effect == .allow) .ReadOnly else .ReadWrite,
    };
    if (effect == .allow) {
        try geode.execution.checkPermission(ctx, .Write);
    } else {
        try testing.expectError(error.Unauthorized, geode.execution.checkPermission(ctx, .Write));
    }
}

fn statementFailure(effect: policies.Effect) !void {
    var h = try Harness.init();
    defer h.deinit();
    var manager = try AuthGraphManager.init(testing.allocator, geode.graph_store.getGlobalStore(testing.allocator));
    var manager_live = true;
    defer if (manager_live) manager.deinit();
    var catalog = policies.PolicyCatalog.init(testing.allocator);
    defer catalog.deinit();
    policies.setGlobalCatalog(&catalog);
    defer policies.clearGlobalCatalog();
    var hooks = Hooks{ .manager = &manager };
    policies.setWriteThroughHooks(.{ .ctx = &hooks, .persist = Hooks.persist, .drop = Hooks.drop, .alter = Hooks.alter });
    defer policies.setWriteThroughHooks(null);
    const spec = policies.PolicySpec{ .name = "kept_policy", .scope_graph = "*", .actions = &.{.write}, .effect = effect, .expression_source = "true", .enabled = true };
    try catalog.addPolicyStrict(spec);
    try persistence.persistPolicy(&manager, &key, spec);
    const id = manager.findPolicyIdByName(spec.name).?;
    try manager.verifyChain(&key);
    try permission(&h, effect);

    hooks.inject = true;
    try testing.expectError(error.OutOfMemory, h.run("DROP POLICY kept_policy", .Admin, "operator"));
    try testing.expect(manager.storage.getPolicy(id) != null);
    try testing.expect(manager.storage.policy_nodes.contains(id));
    try testing.expectEqual(@as(usize, 1), catalog.listPolicies().len);
    try manager.verifyChain(&key);
    try permission(&h, effect);

    // Reopen the actual durable store: the failed drop must not be resurrected
    // into a different policy/chain state at startup.
    try geode.graph_store.getGlobalStore(testing.allocator).saveToFile();
    manager.deinit();
    manager_live = false;
    geode.execution.cleanupCatalogInstance();
    geode.graph_store.deinitGlobalStore();
    const store = try geode.graph_store.initGlobalStore(testing.allocator, h.data_dir);
    h.catalog = try geode.execution.ensureCatalogInstance(testing.allocator);
    manager = try AuthGraphManager.init(testing.allocator, store);
    manager_live = true;
    try manager.verifyChain(&key);
    catalog.deinit();
    catalog = policies.PolicyCatalog.init(testing.allocator);
    try persistence.hydrateCatalog(testing.allocator, &manager, &catalog);
    try testing.expectEqual(@as(usize, 1), catalog.listPolicies().len);
    try testing.expectEqual(effect, catalog.listPolicies()[0].effect);
    try permission(&h, effect);

    hooks.inject = false;
    var result = try h.run("DROP POLICY kept_policy", .Admin, "operator");
    result.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 0), catalog.listPolicies().len);
    try testing.expect(manager.findPolicyIdByName(spec.name) == null);
    try manager.verifyChain(&key);
}

test "SONNY-6293: failed DROP keeps an allow policy enforced across durable reopen" {
    try statementFailure(.allow);
}

test "SONNY-6293: failed DROP keeps a deny policy enforced across durable reopen" {
    try statementFailure(.deny);
}
