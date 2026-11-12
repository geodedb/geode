// SONNY-2773 regression: the expression RLS engine frees what it owns of a
// policy when the policy is deleted, replaced, or left installed at deinit.
//
// `RLSEngine.installPolicy` compiles a policy's USING / CHECK expression
// into bytecode it allocates, and `geode.rls.add_attribute_policy` copies the
// policy's strings into the engine's allocator for the engine to keep.
// `deletePolicy` and `deinit` freed neither: every successful
// `geode.rls.remove_attribute_policy`, every `UserManager.deletePolicy`, every
// expression `updatePolicy` replaced, and every engine teardown leaked them
// for the server's life. (Tests worked around it by freeing the bytecode by
// hand before `deinit`.)
//
// Now the engine records what it owns (the bytecode it compiled, and the
// strings of a policy whose installer hands them over, as
// `add_attribute_policy` does) and frees exactly that.
// A pre-compiled expression the caller pins, and strings the caller keeps
// (UserManager owns its copies, SONNY-2778), are the caller's. Every case
// runs under the leak-checking testing allocator.
//
// CANARY: REQ=REQ-SONNY-2773-RLS-POLICY-FREE; FEATURE="RLSExpressionCompilation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2773_rls_policy_free.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const geode_auth = @import("geode_auth");
const rls = @import("rls");
const rls_types = @import("rls_types");
const user_manager = @import("user_manager");
const user_storage = @import("user_storage");

const RLSEngine = rls.RLSEngine;
const graph_store = geode.graph_store;
const execution = geode.execution;
const user_mgmt = geode.user_management;

fn policy(id: u64, using_raw: ?[]const u8, check_raw: ?[]const u8) RLSEngine.Policy {
    return .{
        .id = id,
        .name = "p2773",
        .description = "SONNY-2773",
        .graph = "g2773",
        .table = "T",
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = if (using_raw) |raw| .{ .raw = raw, .parsed = null, .compiled = null, .parameters = &.{} } else null,
        .check_expr = if (check_raw) |raw| .{ .raw = raw, .parsed = null, .compiled = null, .parameters = &.{} } else null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    };
}

test "SONNY-2773: deletePolicy frees the bytecode the engine compiled (USING and CHECK)" {
    var engine = try RLSEngine.init(testing.allocator);
    defer engine.deinit();
    try engine.createPolicy(policy(1, "row.cls = 'a'", "row.cls <> 'z'"));
    try engine.createPolicy(policy(2, "row.cls = 'b'", null));
    try engine.deletePolicy(1);
    try engine.deletePolicy(2);
    try testing.expect(!engine.hasPolicies());
}

test "SONNY-2773: deinit frees the bytecode of every policy still installed" {
    var engine = try RLSEngine.init(testing.allocator);
    defer engine.deinit();
    try engine.createPolicy(policy(1, "row.cls = 'a'", "row.cls <> 'z'"));
    try engine.loadPolicy(policy(2, "row.cls = ", null)); // kept fail-closed, deny-all bytecode
    try testing.expectEqual(@as(usize, 1), engine.invalidPolicyCount());
}

test "SONNY-2773: updatePolicy frees the bytecode it replaces and keeps what the new policy still uses" {
    var engine = try RLSEngine.init(testing.allocator);
    defer engine.deinit();
    try engine.createPolicy(policy(1, "row.cls = 'a'", "row.cls <> 'z'"));
    // A new USING expression: the old USING bytecode is freed.
    try engine.updatePolicy(1, policy(1, "row.cls = 'b'", "row.cls <> 'z'"));
    // The installed policy, changed only in `enabled`, keeps its bytecode
    // (the caller copied the pointers out, as UserManager.updatePolicy does).
    var current: RLSEngine.Policy = undefined;
    {
        engine.acquirePoliciesRead();
        defer engine.releasePoliciesRead();
        current = engine.policies.get(.{ .graph = "g2773", .table = "T" }).?.items[0];
    }
    current.enabled = false;
    try engine.updatePolicy(1, current);
    // A refused update changes nothing and leaks nothing.
    try testing.expectError(error.InvalidRlsExpression, engine.updatePolicy(1, policy(1, "row.cls = ", null)));
    try engine.deletePolicy(1);
}

test "SONNY-2773: UserManager create / update / delete under the testing allocator leaks no bytecode" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var sm_arena = std.heap.ArenaAllocator.init(allocator);
    defer sm_arena.deinit();
    var security_manager = try geode_auth.SecurityManager.initEmpty(sm_arena.allocator());
    defer security_manager.deinit();
    var rls_engine = try RLSEngine.init(allocator);
    defer rls_engine.deinit();
    var backend = try user_storage.UserStorageBackend.init(allocator, &store);
    defer backend.deinit();
    var mgr = try user_manager.UserManager.init(allocator, &security_manager, &rls_engine, &backend);
    defer mgr.deinit();

    const id = try mgr.createPolicy(.{
        .name = "orders_mine",
        .description = "RLS policy",
        .graph = "g2773",
        .table = "orders",
        .operation = .select,
        .roles = &[_][]const u8{"user"},
        .using_clause = "row.cls = 'a'",
        .check_clause = "row.cls <> 'z'",
    });
    try mgr.updatePolicy(id, false, null, null); // enabled only: same bytecode
    try mgr.updatePolicy(id, null, "row.cls = 'b'", null); // new USING bytecode
    try mgr.deletePolicy(id);
    // One left for deinit.
    _ = try mgr.createPolicy(.{
        .name = "orders_left",
        .description = "RLS policy",
        .graph = "g2773",
        .table = "orders",
        .operation = .select,
        .roles = &[_][]const u8{"user"},
        .using_clause = "row.cls = 'c'",
    });
}

fn runRls(proc: []const u8, query: []const u8) !void {
    const allocator = testing.allocator;
    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();
    const call = switch (parsed.program.statements[0]) {
        .Call => |c| switch (c) {
            .Procedure => |p| p,
            else => return error.NotACall,
        },
        else => return error.NotACall,
    };
    const ctx = execution.ExecutionContext{ .catalog = try execution.ensureCatalogInstance(allocator) };
    var result = (try execution.rls_dispatch.execute(allocator, proc, call, ctx)) orelse return error.NotDispatched;
    result.deinit(allocator);
}

test "SONNY-2773: geode.rls.add_attribute_policy / remove_attribute_policy leak nothing, and deinit frees what is left" {
    const allocator = testing.allocator;
    const auth_was = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(auth_was);
    defer execution.cleanupCatalogInstance();

    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();
    rls_types.setGlobalExprRLSEngine(@ptrCast(&engine));
    defer rls_types.setGlobalExprRLSEngine(null);

    try runRls("geode.rls.add_attribute_policy", "CALL geode.rls.add_attribute_policy('g2773', 'Doc', 'dept', 'department')");
    try testing.expect(engine.hasPolicies());
    try runRls("geode.rls.remove_attribute_policy", "CALL geode.rls.remove_attribute_policy('g2773', 'Doc', 'dept', 'department')");
    try testing.expect(!engine.hasPolicies());
    // One left installed: the engine's deinit frees its strings and bytecode.
    try runRls("geode.rls.add_attribute_policy", "CALL geode.rls.add_attribute_policy('g2773', 'Doc', 'team', 'team')");
}
