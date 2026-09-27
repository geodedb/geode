// SONNY-3036 regression: the RLS engine's policy map never points into a
// deleted policy's strings.
//
// RLSEngine keys its policy map by (graph, table), and a new entry's key
// borrowed the first policy's `graph` and `table` (SONNY-2746).
// `UserManager.deletePolicy` removed the policy from the engine and then
// freed its strings (SONNY-2778), but the entry, and its key, stayed: the
// next lookup for that graph and table hashed and compared freed memory. The
// one-command-per-process CLI cannot reach it; a library caller can.
//
// Now the map owns copies of its keys, and a graph and table left without a
// policy lose their entry. Leak-checked with the testing allocator.
//
// CANARY: REQ=REQ-SONNY-3036-RLS-POLICY-KEYS; FEATURE="RLSExpressionCompilation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3036_rls_policy_keys.zig; OWNER=security; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const geode_auth = @import("geode_auth");
const rls = @import("rls");
const user_manager = @import("user_manager");
const user_storage = @import("user_storage");

const graph_store = geode.graph_store;

fn policyEntries(engine: *rls.RLSEngine) usize {
    return engine.policies.count();
}

/// The policies filed under (graph, table), or null when there is no entry.
fn entryLen(engine: *rls.RLSEngine, graph: []const u8, table: []const u8) ?usize {
    var it = engine.policies.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.graph, graph) and std.mem.eql(u8, entry.key_ptr.table, table)) {
            return entry.value_ptr.items.len;
        }
    }
    return null;
}

test "SONNY-3036: deleting a policy leaves the RLS engine's map no key into its freed strings (use-after-free, leak-checked)" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var sm_arena = std.heap.ArenaAllocator.init(allocator);
    defer sm_arena.deinit();
    var security_manager = try geode_auth.SecurityManager.initEmpty(sm_arena.allocator());
    defer security_manager.deinit();
    var rls_engine = try rls.RLSEngine.init(allocator);
    defer rls_engine.deinit();
    var backend = try user_storage.UserStorageBackend.init(allocator, &store);
    defer backend.deinit();
    var mgr = try user_manager.UserManager.init(allocator, &security_manager, &rls_engine, &backend);
    defer mgr.deinit();

    const request = user_manager.UserManager.CreatePolicyRequest{
        .name = "first",
        .description = "RLS policy",
        .graph = "g3036",
        .table = "orders",
        .operation = .select,
        .roles = &[_][]const u8{"user"},
    };

    // The only policy of its graph and table: deleting it removes the entry.
    const only = try mgr.createPolicy(request);
    try testing.expectEqual(@as(usize, 1), policyEntries(&rls_engine));
    try mgr.deletePolicy(only);
    try testing.expectEqual(@as(usize, 0), policyEntries(&rls_engine));

    // Two policies share an entry. Deleting the first, whose strings the
    // entry's key used to borrow, leaves a key that still reads right.
    const first = try mgr.createPolicy(request);
    var second_request = request;
    second_request.name = "second";
    const second = try mgr.createPolicy(second_request);
    try testing.expectEqual(@as(?usize, 2), entryLen(&rls_engine, "g3036", "orders"));
    try mgr.deletePolicy(first);
    try testing.expectEqual(@as(?usize, 1), entryLen(&rls_engine, "g3036", "orders"));

    // A third policy of the same graph and table joins that entry.
    var third_request = request;
    third_request.name = "third";
    const third = try mgr.createPolicy(third_request);
    try testing.expectEqual(@as(usize, 1), policyEntries(&rls_engine));
    try testing.expectEqual(@as(?usize, 2), entryLen(&rls_engine, "g3036", "orders"));

    try mgr.deletePolicy(second);
    try mgr.deletePolicy(third);
    try testing.expectEqual(@as(usize, 0), policyEntries(&rls_engine));
    // The testing allocator reports any key copy or list left behind.
}
