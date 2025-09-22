const std = @import("std");
const enumerator_mod = @import("planner_enumerator");

// Promote IMPL to TESTED after this test passes.
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanEnumerationEngine; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanEnumerationEngine; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanEnumerationVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_024_PlanEnumerationEngine" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &[_]enumerator_mod.LogicalPlan{} };
    var join_children: [2]enumerator_mod.LogicalPlan = .{ leaf, leaf };
    const root = enumerator_mod.LogicalPlan{ .op = .join, .children = join_children[0..] };

    var enumerator = enumerator_mod.PlanEnumerator.init(alloc, .{});
    var plans = std.ArrayListUnmanaged(enumerator_mod.CandidatePlan){};
    defer plans.deinit(alloc);
    try plans.ensureTotalCapacity(alloc, 16);
    defer plans.deinit(alloc);
    try enumerator.enumerateUnmanaged(root, alloc, &plans);
    try std.testing.expect(plans.items.len >= 2); // original + swapped
    // check distinct signatures
    try std.testing.expect(plans.items[0].signature != plans.items[1].signature);
}

// Variance envelope benchmark (structural enumeration time jitter)
// We keep this simple: run enumeration multiple times, capture duration stats; enforce CV and p95/mean thresholds.
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanEnumerationVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_024_PlanEnumerationEngine; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanEnumerationVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21
test "BenchmarkCANARY_REQ_GQL_024_PlanEnumerationVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Build a modest tree: join(project(scan, scan), aggregate(filter(scan))) depth ~3
    const scan_leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &[_]enumerator_mod.LogicalPlan{} };
    var proj_children: [1]enumerator_mod.LogicalPlan = .{scan_leaf};
    const project_node = enumerator_mod.LogicalPlan{ .op = .project, .children = proj_children[0..] };
    var right_filter_child: [1]enumerator_mod.LogicalPlan = .{scan_leaf};
    const filter_node = enumerator_mod.LogicalPlan{ .op = .filter, .children = right_filter_child[0..] };
    var agg_children: [1]enumerator_mod.LogicalPlan = .{filter_node};
    const agg_node = enumerator_mod.LogicalPlan{ .op = .aggregate, .children = agg_children[0..] };
    var top_join_children: [2]enumerator_mod.LogicalPlan = .{ project_node, agg_node };
    const root = enumerator_mod.LogicalPlan{ .op = .join, .children = top_join_children[0..] };

    const iterations: usize = 64;
    var samples = try alloc.alloc(u64, iterations);
    defer alloc.free(samples);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var enumerator = enumerator_mod.PlanEnumerator.init(alloc, .{ .max_plans = 512 });
        var plans_iter = std.ArrayListUnmanaged(enumerator_mod.CandidatePlan){};
        try plans_iter.ensureTotalCapacity(alloc, 32);
        const start = std.time.nanoTimestamp();
        try enumerator.enumerateUnmanaged(root, alloc, &plans_iter);
        const end = std.time.nanoTimestamp();
        samples[i] = @as(u64, @intCast(end - start));
        plans_iter.deinit(alloc);
    }

    // compute mean, variance, p95
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, @floatFromInt(iterations));
    var var_acc: f128 = 0;
    for (samples) |s| {
        const diff = @as(f128, @floatFromInt(s)) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(iterations));
    // coefficient of variation = sqrt(var) / mean
    const cv = std.math.sqrt(variance) / mean;

    // approximate p95: select the element at rank floor(0.95*n)
    var scratch = try alloc.dupe(u64, samples);
    defer alloc.free(scratch);
    const rank = (iterations * 95) / 100;
    // partial selection (naive)
    var r: usize = 0;
    while (r <= rank) : (r += 1) {
        var min_index = r;
        var j: usize = r + 1;
        while (j < iterations) : (j += 1) {
            if (scratch[j] < scratch[min_index]) min_index = j;
        }
        if (min_index != r) {
            const tmp = scratch[r];
            scratch[r] = scratch[min_index];
            scratch[min_index] = tmp;
        }
    }
    const p95 = @as(f128, @floatFromInt(scratch[rank]));
    const p95_mean = p95 / mean;

    // Thresholds: CV≤0.22, p95/mean≤2.55
    try std.testing.expect(cv <= 0.22);
    try std.testing.expect(p95_mean <= 2.55);
}
