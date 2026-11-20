// SONNY-2729 part 2: one label-deny engine.
//
// Two live label-deny engines existed: the transport post-filter's
// (src/server/rls_filter.zig: `RLSFilterEngine` and its own global) and the
// executor's (src/security/rls_types.zig). They were separate types with
// separate instances and globals, kept in step only by server/main.zig
// (`addDenyToEngines`, and a remove / list / count against one of them),
// so any path that changed one engine and not the other (or a process
// that installed only one) let the post-filter and the executor disagree
// about which labels a user may see.
//
// Now rls_types' engine is the only one: rls_filter's `RLSFilterEngine` and
// `LabelPolicy` are that type, and its global is rls_types' global, so the
// post-filter applies exactly the denies the executor applies.
//
// (Part 1, fail-closed post-filters on OOM, is
// tests/test_sonny2729_postfilter_fail_closed.zig.)
//
// CANARY: REQ=REQ-SONNY-2729-ONE-LABEL-DENY-ENGINE; FEATURE="RLS Query Enforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2729_one_label_deny_engine.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const rls_filter = @import("grpc_impl").rls_filter;

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

test "SONNY-2729: the post-filter's label-deny engine is the executor's engine type" {
    if (rls_filter.RLSFilterEngine != rls_types.RLSFilterEngine) {
        std.debug.print("rls_filter.RLSFilterEngine and rls_types.RLSFilterEngine are two engines\n", .{});
        return error.TwoLabelDenyEngines;
    }
    try testing.expect(rls_filter.LabelPolicy == rls_types.LabelPolicy);
    // What the post-filter needs of it.
    try testing.expect(@hasDecl(rls_types.RLSFilterEngine, "hasPoliciesForGraph"));
    try testing.expect(@hasDecl(rls_types.RLSFilterEngine, "removeOneDenyPolicy"));
}

fn nodeRows(nodes: []const *const graph_store.Node) !execution.ExecutionResult {
    const a = testing.allocator;
    const columns = try a.alloc([]const u8, 1);
    columns[0] = try a.dupe(u8, "n");
    const rows = try a.alloc([]Value, nodes.len);
    for (nodes, 0..) |node, i| {
        rows[i] = try a.alloc(Value, 1);
        rows[i][0] = .{ .Node = node };
    }
    return .{ .columns = columns, .rows = rows, .flags = .empty, .owns_value_memory = true };
}

test "SONNY-2729: the engine the executor uses is the one the post-filter applies, with one global" {
    var engine = rls_types.RLSFilterEngine.init(testing.allocator);
    defer engine.deinit();
    const prev = rls_types.getGlobalRLSFilterEngine();
    rls_types.setGlobalRLSFilterEngine(&engine);
    defer rls_types.setGlobalRLSFilterEngine(prev);

    // The post-filter's global is the executor's.
    const pf = rls_filter.getGlobalRLSFilterEngine() orelse {
        std.debug.print("the executor's label-deny engine is installed and the post-filter has none\n", .{});
        return error.PostFilterHasNoEngine;
    };
    try testing.expectEqual(@intFromPtr(&engine), @intFromPtr(pf));

    // A deny added once is applied by both.
    try engine.addDenyPolicy("default", "Secret2729", "alice");
    try testing.expect(engine.isLabelDenied("default", "Secret2729", "alice"));

    var secret_labels = [_][]const u8{"Secret2729"};
    var public_labels = [_][]const u8{"Public2729"};
    const secret = graph_store.Node{ .id = 1, .labels = &secret_labels, .properties = graph_store.CompactPropertyMap.init(testing.allocator) };
    const public = graph_store.Node{ .id = 2, .labels = &public_labels, .properties = graph_store.CompactPropertyMap.init(testing.allocator) };
    var result = try nodeRows(&.{ &secret, &public, &secret });
    defer result.deinit(testing.allocator);
    const removed = try rls_filter.applyRLSFilter(testing.allocator, &result, pf, "alice", "default");
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 1), result.rows.len);

    // A removal through the one engine stops both.
    engine.removeDenyPolicy("default", "Secret2729", "alice");
    try testing.expect(!engine.isLabelDenied("default", "Secret2729", "alice"));
    try testing.expect(!pf.hasPoliciesForGraph("default"));
}

test "SONNY-2729: a deny add is all or nothing, and undoing one leaves an identical deny added before" {
    // (SONNY-3038's guarantee, now of the one engine: there is no second
    // engine to keep in step.)
    var fail_index: usize = 0;
    var failures: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var engine = rls_types.RLSFilterEngine.init(failing.allocator());
        defer engine.deinit();
        if (engine.addDenyPolicy("g1", "Secret", "alice")) |_| {
            try testing.expect(engine.isLabelDenied("g1", "Secret", "alice"));
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(!engine.isLabelDenied("g1", "Secret", "alice"));
            try testing.expectEqual(@as(usize, 0), engine.policyCount());
            failures += 1;
        }
    }
    try testing.expect(failures > 0);

    if (comptime !@hasDecl(rls_types.RLSFilterEngine, "removeOneDenyPolicy")) {
        std.debug.print("the executor's engine cannot undo one deny (removeOneDenyPolicy is the post-filter engine's)\n", .{});
        return error.TwoLabelDenyEngines;
    }
    var engine = rls_types.RLSFilterEngine.init(testing.allocator);
    defer engine.deinit();
    try engine.addDenyPolicy("g1", "Secret", "alice");
    try engine.addDenyPolicy("g1", "Secret", "alice");
    engine.removeOneDenyPolicy("g1", "Secret", "alice");
    try testing.expect(engine.isLabelDenied("g1", "Secret", "alice"));
    try testing.expectEqual(@as(usize, 1), engine.policyCount());
}
