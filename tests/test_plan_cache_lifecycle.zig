const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const query_plan_cache = geode.query_plan_cache;
const graph_store = geode.graph_store;

// CANARY: REQ=REQ-PERF-PLAN-LIFECYCLE-001; FEATURE="PlanCacheLifecycle"; ASPECT=UnitTest; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
// Issue #452: Plan cache lifecycle unit tests — real plan generation, hints, cache behavior

/// Helper: parse a query and generate a plan from it
fn generatePlanForQuery(allocator: std.mem.Allocator, query: []const u8, stats: query_plan_cache.StoreStats) !struct { plan: query_plan_cache.CompiledPlan, parsed: geode.ParseResult } {
    var parsed = try geode.parseGql(query, allocator);
    var cost_model = query_plan_cache.CostModel.init();
    const plan = generateRealPlan(allocator, &cost_model, &parsed.program, stats, 0) catch |err| {
        parsed.deinit();
        return err;
    };
    return .{ .plan = plan, .parsed = parsed };
}

const generateRealPlan = query_plan_cache.generateRealPlan;

test "generateRealPlan: simple MATCH produces scan operator" {
    const allocator = testing.allocator;
    const stats = query_plan_cache.StoreStats{ .node_count = 1000, .edge_count = 500 };

    var parsed = try geode.parseGql("MATCH (n) RETURN n", allocator);
    defer parsed.deinit();
    var cost_model = query_plan_cache.CostModel.init();
    const plan = try generateRealPlan(allocator, &cost_model, &parsed.program, stats, 0);
    defer allocator.free(plan.operators);

    try testing.expect(plan.operators.len > 0);
    try testing.expect(plan.estimated_cost > 0);
    try testing.expect(plan.estimated_rows > 0);

    var has_scan = false;
    for (plan.operators) |op| {
        if (op.op_type == .scan or op.op_type == .label_scan) {
            has_scan = true;
            break;
        }
    }
    try testing.expect(has_scan);
}

test "generateRealPlan: label pattern uses label_scan" {
    const allocator = testing.allocator;
    const stats = query_plan_cache.StoreStats{ .node_count = 1000, .edge_count = 500 };

    var parsed = try geode.parseGql("MATCH (n:Person) RETURN n", allocator);
    defer parsed.deinit();
    var cost_model = query_plan_cache.CostModel.init();
    const plan = try generateRealPlan(allocator, &cost_model, &parsed.program, stats, 0);
    defer allocator.free(plan.operators);

    try testing.expectEqual(query_plan_cache.CompiledPlan.ScanStrategy.label_scan, plan.scan_strategy);
}

test "generateRealPlan: WHERE adds filter operator" {
    const allocator = testing.allocator;
    const stats = query_plan_cache.StoreStats{ .node_count = 1000, .edge_count = 500 };

    var parsed = try geode.parseGql("MATCH (n) WHERE n.age > 21 RETURN n", allocator);
    defer parsed.deinit();
    var cost_model = query_plan_cache.CostModel.init();
    const plan = try generateRealPlan(allocator, &cost_model, &parsed.program, stats, 0);
    defer allocator.free(plan.operators);

    var has_filter = false;
    for (plan.operators) |op| {
        if (op.op_type == .filter) {
            has_filter = true;
            break;
        }
    }
    try testing.expect(has_filter);
}

test "generateRealPlan: ORDER BY adds sort operator" {
    const allocator = testing.allocator;
    const stats = query_plan_cache.StoreStats{ .node_count = 1000, .edge_count = 500 };

    // SONNY-2394: `geode.parseGql` applied the legacy US001 ORDER BY policy
    // (bare identifiers only) then, so the old `ORDER BY n.name` was rejected
    // with UnexpectedToken before any plan was generated. Since SONNY-6351 it
    // accepts expression keys unless GEODE_ORDER_KEYS_EXPR=0 opts into that
    // policy. Order by a projected alias: legal under both parse policies,
    // and still an ORDER BY for generateRealPlan to lower into a sort operator.
    var parsed = try geode.parseGql("MATCH (n) RETURN n.name AS name ORDER BY name", allocator);
    defer parsed.deinit();
    var cost_model = query_plan_cache.CostModel.init();
    const plan = try generateRealPlan(allocator, &cost_model, &parsed.program, stats, 0);
    defer allocator.free(plan.operators);

    var has_sort = false;
    for (plan.operators) |op| {
        if (op.op_type == .sort) {
            has_sort = true;
            break;
        }
    }
    try testing.expect(has_sort);
}

test "generateRealPlan: LIMIT adds limit operator" {
    const allocator = testing.allocator;
    const stats = query_plan_cache.StoreStats{ .node_count = 1000, .edge_count = 500 };

    var parsed = try geode.parseGql("MATCH (n) RETURN n LIMIT 10", allocator);
    defer parsed.deinit();
    var cost_model = query_plan_cache.CostModel.init();
    const plan = try generateRealPlan(allocator, &cost_model, &parsed.program, stats, 0);
    defer allocator.free(plan.operators);

    var has_limit = false;
    for (plan.operators) |op| {
        if (op.op_type == .limit) {
            has_limit = true;
            break;
        }
    }
    try testing.expect(has_limit);
}

test "generateRealPlan: relationship pattern adds path_expand" {
    const allocator = testing.allocator;
    const stats = query_plan_cache.StoreStats{ .node_count = 1000, .edge_count = 500 };

    var parsed = try geode.parseGql("MATCH (a)-[r]->(b) RETURN a, b", allocator);
    defer parsed.deinit();
    var cost_model = query_plan_cache.CostModel.init();
    const plan = try generateRealPlan(allocator, &cost_model, &parsed.program, stats, 0);
    defer allocator.free(plan.operators);

    var has_path = false;
    for (plan.operators) |op| {
        if (op.op_type == .path_expand) {
            has_path = true;
            break;
        }
    }
    try testing.expect(has_path);
}

test "generateRealPlan: cost increases with store size" {
    const allocator = testing.allocator;
    const query = "MATCH (n) RETURN n";

    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();

    const small_stats = query_plan_cache.StoreStats{ .node_count = 100, .edge_count = 50 };
    const large_stats = query_plan_cache.StoreStats{ .node_count = 100000, .edge_count = 50000 };

    var cm1 = query_plan_cache.CostModel.init();
    const small_plan = try generateRealPlan(allocator, &cm1, &parsed.program, small_stats, 0);
    defer allocator.free(small_plan.operators);

    var cm2 = query_plan_cache.CostModel.init();
    const large_plan = try generateRealPlan(allocator, &cm2, &parsed.program, large_stats, 0);
    defer allocator.free(large_plan.operators);

    try testing.expect(large_plan.estimated_cost > small_plan.estimated_cost);
    try testing.expect(large_plan.estimated_rows > small_plan.estimated_rows);
}

test "CompiledPlan: ScanStrategy enum values" {
    try testing.expectEqual(@as(u2, 0), @intFromEnum(query_plan_cache.CompiledPlan.ScanStrategy.full_scan));
    try testing.expectEqual(@as(u2, 1), @intFromEnum(query_plan_cache.CompiledPlan.ScanStrategy.index_scan));
    try testing.expectEqual(@as(u2, 2), @intFromEnum(query_plan_cache.CompiledPlan.ScanStrategy.label_scan));
}

test "OptimizerHints: default values" {
    const hints = query_plan_cache.OptimizerHints{};
    try testing.expectEqual(@as(?[]const u8, null), hints.use_index);
    try testing.expectEqual(query_plan_cache.CompiledPlan.ScanStrategy.full_scan, hints.scan_strategy);
    try testing.expectEqual(@as(u64, 0), hints.estimated_rows);
    try testing.expectEqual(@as(u64, 0), hints.schema_epoch);
}

test "StoreStats: graph_store integration" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const labels: []const []const u8 = &.{"Person"};
    _ = try store.createNodeWithGraph(@constCast(labels), "default");
    const labels2: []const []const u8 = &.{"Company"};
    _ = try store.createNodeWithGraph(@constCast(labels2), "default");

    const stats = query_plan_cache.StoreStats{
        .node_count = @intCast(store.getNodeCount()),
        .edge_count = @intCast(store.getEdgeCount()),
    };

    try testing.expectEqual(@as(u64, 2), stats.node_count);
    try testing.expectEqual(@as(u64, 0), stats.edge_count);
}

test "schema epoch: bump and check" {
    const initial = graph_store.getSchemaEpoch();
    graph_store.bumpSchemaEpoch();
    const after = graph_store.getSchemaEpoch();
    try testing.expectEqual(initial + 1, after);
}
