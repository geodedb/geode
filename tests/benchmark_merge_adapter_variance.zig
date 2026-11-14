const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const graph_storage_adapter = geode.graph_storage_adapter;

// CANARY: REQ=REQ-PERF-MERGE-004; FEATURE="Execution"; ASPECT=AdapterMergeVarianceEnvelope; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_PERF_MERGE_004_AdapterMergeVarianceEnvelope; OWNER=engine; UPDATED=2026-11-14

fn execQuery(
    allocator: std.mem.Allocator,
    query: []const u8,
    ctx: geode.execution.ExecutionContext,
) !geode.execution.ExecutionResult {
    var parse_result = try geode.parse(allocator, query, .{});
    defer parse_result.deinit();
    return geode.execution.executeProgramWithContext(allocator, &parse_result.program, ctx);
}

fn seedNodeWithNodeId(
    store: *geode.graph_store.GraphStore,
    label: []const u8,
    external_id: i64,
) !u64 {
    const node_id = try store.createNodeWithGraph(&[_][]const u8{label}, "default");
    try store.setNodeProperty(node_id, "node_id", .{ .Int = external_id });
    return node_id;
}

fn seedNoiseChain(
    store: *geode.graph_store.GraphStore,
    label: []const u8,
    external_id_base: i64,
    edge_count: usize,
) !void {
    if (edge_count == 0) return;

    var prev_node = try seedNodeWithNodeId(store, label, external_id_base);
    var i: usize = 0;
    while (i < edge_count) : (i += 1) {
        const next_node = try seedNodeWithNodeId(store, label, external_id_base + @as(i64, @intCast(i)) + 1);
        _ = try store.createEdgeWithGraph(prev_node, next_node, "NOISE", "default");
        prev_node = next_node;
    }
}

fn meanNs(samples: []const u64) f64 {
    var sum: f128 = 0;
    for (samples) |sample| {
        sum += @as(f128, @floatFromInt(sample));
    }
    return @as(f64, @floatCast(sum / @as(f128, @floatFromInt(samples.len))));
}

test "BenchmarkCANARY_REQ_PERF_MERGE_004_AdapterMergeVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
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
    const stderr = std.Io.getStdErr().writer();
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

// CANARY: REQ=REQ-PERF-MERGE-007; FEATURE="Execution"; ASPECT=RelationshipMergeAdjacencyEnvelope; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_PERF_MERGE_007_RelationshipMergeAdjacencyEnvelope; OWNER=engine; UPDATED=2026-11-14
test "BenchmarkCANARY_REQ_PERF_MERGE_007_RelationshipMergeAdjacencyEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const store = try geode.graph_store.initGlobalStore(allocator, data_dir);
    defer geode.graph_store.deinitGlobalStore();

    const catalog = try geode.execution.ensureCatalogInstance(allocator);
    defer geode.execution.cleanupCatalogInstance();

    _ = try seedNodeWithNodeId(store, "User", 1);
    _ = try seedNodeWithNodeId(store, "User", 2);
    try seedNoiseChain(store, "User", 10_000, 64);

    const ctx = geode.execution.ExecutionContext{ .catalog = catalog };
    var warm_result = try execQuery(allocator, "MERGE (a:User {node_id: 1})-[:KNOWS]->(b:User {node_id: 2})", ctx);
    defer warm_result.deinit(allocator);

    geode.graph_store.resetQueryReadSessionInitCount();
    geode.graph_store.resetGetNodesByLabelsCount();
    graph_storage_adapter.resetLookupCounters();

    const iterations: usize = 48;
    var low_noise = try allocator.alloc(u64, iterations);
    defer allocator.free(low_noise);
    var high_noise = try allocator.alloc(u64, iterations);
    defer allocator.free(high_noise);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        var result = try execQuery(allocator, "MERGE (a:User {node_id: 1})-[:KNOWS]->(b:User {node_id: 2})", ctx);
        const stop = std.time.nanoTimestamp();
        defer result.deinit(allocator);
        low_noise[i] = @intCast(stop - start);
    }

    try seedNoiseChain(store, "User", 20_000, 4096);

    i = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        var result = try execQuery(allocator, "MERGE (a:User {node_id: 1})-[:KNOWS]->(b:User {node_id: 2})", ctx);
        const stop = std.time.nanoTimestamp();
        defer result.deinit(allocator);
        high_noise[i] = @intCast(stop - start);
    }

    const snapshots = geode.graph_store.getQueryReadSessionInitCount();
    const label_scans = geode.graph_store.getNodesByLabelsCallCount();
    const exact_lookups = graph_storage_adapter.getExactNodePropertyLookupCount();
    try testing.expectEqual(@as(u64, 0), snapshots);
    try testing.expectEqual(@as(u64, 0), label_scans);
    try testing.expect(exact_lookups >= iterations * 2);

    const low_mean = meanNs(low_noise);
    const high_mean = meanNs(high_noise);
    const noise_ratio = high_mean / low_mean;
    try testing.expect(noise_ratio < 3.0);

    const stderr = std.Io.getStdErr().writer();
    try stderr.print(
        "{{\"benchmark\":\"relationship_merge_adjacency_envelope\",\"low_noise_mean_ns\":{d},\"high_noise_mean_ns\":{d},\"high_low_ratio\":{d:.3},\"snapshots\":{d},\"label_scans\":{d},\"exact_lookups\":{d},\"edge_count\":{d}}}\n",
        .{
            @as(u64, @intFromFloat(low_mean)),
            @as(u64, @intFromFloat(high_mean)),
            noise_ratio,
            snapshots,
            label_scans,
            exact_lookups,
            geode.graph_store.getCurrentGlobalStore().?.getEdgeCount(),
        },
    );
}
