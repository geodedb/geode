const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_storage_adapter = geode.graph_storage_adapter;

// CANARY: REQ=REQ-PERF-MERGE-004; FEATURE="Execution"; ASPECT=AdapterMergeVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_PERF_MERGE_004_AdapterMergeVarianceEnvelope; OWNER=engine; UPDATED=2026-04-08

fn execQuery(
    allocator: std.mem.Allocator,
    query: []const u8,
    ctx: geode.execution.ExecutionContext,
) !geode.execution.ExecutionResult {
    var parse_result = try geode.parse(allocator, query, .{});
    defer parse_result.deinit();
    return geode.execution.executeProgramWithContext(allocator, &parse_result.program, ctx);
}

fn meanNs(samples: []const u64) f64 {
    var sum: f128 = 0;
    for (samples) |sample| {
        sum += @as(f128, @floatFromInt(sample));
    }
    return @as(f64, @floatCast(sum / @as(f128, @floatFromInt(samples.len))));
}

test "BenchmarkCANARY_REQ_PERF_MERGE_004_AdapterMergeVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(data_dir);

    _ = try geode.graph_store.initGlobalStore(allocator, data_dir);
    defer geode.graph_store.deinitGlobalStore();

    const catalog = try geode.execution.ensureCatalogInstance(allocator);
    defer geode.execution.cleanupCatalogInstance();

    const warm_ctx = geode.execution.ExecutionContext{ .catalog = catalog };
    const warm_query = "MERGE (n:Bench {node_id: 1}) SET n.display_name = 'Warm 1'";
    var warm_result = try execQuery(allocator, warm_query, warm_ctx);
    defer warm_result.deinit(allocator);

    geode.graph_store.resetQueryReadSessionInitCount();
    geode.graph_store.resetGetNodesByLabelsCount();
    graph_storage_adapter.resetLookupCounters();

    const iterations: usize = 192;
    var samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);

    const ctx = geode.execution.ExecutionContext{ .catalog = catalog };
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const entity_id = 10_000 + i;
        const query = try std.fmt.allocPrint(
            allocator,
            "MERGE (n:Bench {{node_id: {d}}}) SET n.display_name = 'Bench {d}'",
            .{ entity_id, entity_id },
        );
        defer allocator.free(query);

        const start = std.time.nanoTimestamp();
        var result = try execQuery(allocator, query, ctx);
        const stop = std.time.nanoTimestamp();
        defer result.deinit(allocator);

        samples[i] = @intCast(stop - start);
    }

    const snapshots = geode.graph_store.getQueryReadSessionInitCount();
    try testing.expectEqual(@as(u64, 0), snapshots);
    try testing.expectEqual(@as(u64, 0), geode.graph_store.getNodesByLabelsCallCount());
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() >= iterations);

    const head_mean = meanNs(samples[0..32]);
    const tail_mean = meanNs(samples[samples.len - 32 ..]);
    const tail_to_head_ratio = tail_mean / head_mean;
    try testing.expect(tail_to_head_ratio < 3.0);

    const sorted = try allocator.dupe(u64, samples);
    defer allocator.free(sorted);
    std.sort.heap(u64, sorted, {}, comptime std.sort.asc(u64));

    const mean = meanNs(samples);
    const p95 = sorted[@min(sorted.len - 1, (sorted.len * 95) / 100)];
    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        "{{\"benchmark\":\"merge_adapter_same_label_variance\",\"mean_ns\":{d},\"p95_ns\":{d},\"tail_head_ratio\":{d:.3},\"snapshots\":{d},\"label_scans\":{d},\"exact_lookups\":{d}}}\n",
        .{
            @as(u64, @intFromFloat(mean)),
            p95,
            tail_to_head_ratio,
            snapshots,
            geode.graph_store.getNodesByLabelsCallCount(),
            graph_storage_adapter.getExactNodePropertyLookupCount(),
        },
    );
}
