// GAP-ENT-0020 P7a: prop-store slab packing validated through the FULL geode
// stack (GraphStore facade -> graph_storage_adapter -> gs ShardedGraphEngine).
//
// With graph-storage's `slab_packing` default ON (P7) and geode's three
// adapter edge-prop sites switched to `putPropertyLegacyTxn` (P7a), this test
// asserts on a fresh tmpDir graph built via the production adapter path:
//   (a) props-store bytes/node (P0 metric: free_space_props.allocatedCount()
//       x page_size / N, summed over the 16 shards) is a small fraction of
//       the 8192 one-page-per-node baseline (~140-300 expected);
//   (b) full read parity: count, count-by-label, node property reads, edge
//       property reads all correct;
//   (c) clean shutdown -> reopen -> parity (recovery/load of a slab store
//       through the full geode stack, hydrate-on-read);
//   (d) edge properties stay LEGACY: every edge prop_head is a non-slab
//       page-granular chain (~1 whole page per property-carrying edge --
//       measured as the props-page DELTA when the edges are added).
//
// Uses the process-global store wired to a tmpDir data dir (the production
// open path). NEVER touches the system geode / /var/tmp/geode-* dirs.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const gs = @import("graph_storage");
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;

const GRAPH = "slabg";
const LABEL = "Taxon";

// Modest scale (Debug build, full facade path): 50K nodes x 6 small props
// (internal-id + 5 user props) + 512 property-carrying edges.
const N: usize = 50_000;
const E: usize = 512;
const SAMPLE: usize = 257; // prime stride sampling for parity reads

fn tmpDataDir(allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], sub_path });
}

fn nameFor(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "taxon-{d}", .{i}) catch unreachable;
}

/// Counts the edges in `shard`'s edge index that carry a property head, and
/// fails on a slab head: edge properties use legacy page chains. (The index
/// is an `EdgeIndexMap`, visited through `forEachLive`, with u64 heads.)
fn countLegacyEdgePropHeads(shard: anytype) !usize {
    const Ctx = struct {
        n: usize = 0,
        fn visit(self: *@This(), _: gs.EdgeId, entry: gs.edge_index_map.EdgeIndexEntry) anyerror!void {
            if (entry.prop_head == 0) return;
            self.n += 1;
            try testing.expect(!gs.prop_store.isSlabHead(entry.prop_head));
        }
    };
    var ctx: Ctx = .{};
    try shard.edge_index.forEachLive(&ctx, Ctx.visit);
    return ctx.n;
}

const ranks = [_][]const u8{ "species", "genus", "family", "order", "class" };

/// P0 metric through the geode stack: total allocated props-store pages
/// (x page_size) across all 16 shard engines of GRAPH.
fn propsStoreBytes(mg: anytype) u64 {
    var pages: u64 = 0;
    var page_size: u64 = 0;
    for (mg.engine.shards) |shard| {
        pages += shard.free_space_props.allocatedCount();
        page_size = shard.prop_store.page_size;
    }
    return pages * page_size;
}

test "GAP-ENT-0020 P7a: slab-packed node props + legacy edge props through the geode adapter (parity + reopen)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    var seed_ids = try allocator.alloc(u64, N);
    defer allocator.free(seed_ids);
    var edge_ids: [E]u64 = undefined;

    var bytes_per_node: f64 = 0;
    var edge_pages_delta: u64 = 0;

    // --- Phase 1: build the graph through the production facade/adapter. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);

        var nb: [32]u8 = undefined;
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
            seed_ids[i] = id;
            // 5 small user props per node (taxonomy-shaped), batched: exercises
            // the adapter's batch node-property path (slab-eligible putPropertyTxn).
            const entries = [_]GraphStore.BatchPropertyEntry{
                .{ .key = "name", .value = .{ .String = nameFor(&nb, i) } },
                .{ .key = "rank", .value = .{ .String = ranks[i % ranks.len] } },
                .{ .key = "kingdom", .value = .{ .String = "Animalia" } },
                .{ .key = "src_id", .value = .{ .Int = @intCast(i) } },
                .{ .key = "valid", .value = .{ .Bool = (i % 2) == 0 } },
            };
            try store.setNodePropertiesBatch(id, &entries);
        }
        // A few single-property writes: exercises the adapter's single
        // setNodeProperty path (slab-eligible putPropertyTxn at :4114).
        i = 0;
        while (i < 64) : (i += 1) {
            try store.setNodeProperty(seed_ids[i], "checked", .{ .Bool = true });
        }

        // ---- (a) P0 metric BEFORE any edges: pure node-prop footprint. ----
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        const mg = adapter.engines.get(GRAPH) orelse return error.GraphNotFound;
        const node_props_bytes = propsStoreBytes(mg);
        bytes_per_node = @as(f64, @floatFromInt(node_props_bytes)) / @as(f64, @floatFromInt(N));
        std.debug.print(
            "\n[GAP-ENT-0020 P7a] geode-stack props-store: nodes={d} bytes={d} " ++
                "=> {d:.1} bytes/node (legacy baseline 8192.0)\n",
            .{ N, node_props_bytes, bytes_per_node },
        );
        // Slab headline: a small fraction of the one-page-per-node baseline...
        try testing.expect(bytes_per_node < 1024.0);
        // ...but also non-trivial: the props really landed in the engine
        // (6 props/node cannot fit in less than ~64 B/node).
        try testing.expect(bytes_per_node > 64.0);

        // ---- Edges WITH properties (legacy chains via putPropertyLegacyTxn). ----
        i = 0;
        while (i < E) : (i += 1) {
            const from = seed_ids[i];
            const to = seed_ids[(i + 1) % N];
            const eid = try store.createEdgeWithGraph(from, to, "CHILD_OF", GRAPH);
            edge_ids[i] = eid;
            if (i % 2 == 0) {
                // Adapter setEdgePropertiesBatch path (P7a site :5326).
                const eentries = [_]GraphStore.BatchPropertyEntry{
                    .{ .key = "weight", .value = .{ .Int = @intCast(i) } },
                    .{ .key = "kind", .value = .{ .String = "direct" } },
                };
                try store.setEdgePropertiesBatch(eid, &eentries);
            } else {
                // Adapter setEdgeProperty path (P7a sites :5195/:5243).
                try store.setEdgeProperty(eid, "weight", .{ .Int = @intCast(i) });
                try store.setEdgeProperty(eid, "kind", .{ .String = "inferred" });
            }
        }

        // ---- (d) edge props are LEGACY: page-granular delta + no slab heads. ----
        const with_edges_bytes = propsStoreBytes(mg);
        const page_size: u64 = mg.engine.shards[0].prop_store.page_size;
        edge_pages_delta = (with_edges_bytes - node_props_bytes) / page_size;
        std.debug.print(
            "[GAP-ENT-0020 P7a] edge-prop pages delta: {d} pages for {d} edges " ++
                "(legacy = ~1 page/edge; slab would be ~{d})\n",
            .{ edge_pages_delta, E, E / 100 },
        );
        // Each property-carrying edge owns >= ~1 whole legacy page. If edges
        // had been slab-packed, 512 edges x ~30 B would fit in a handful of
        // shared pages (< E/4).
        try testing.expect(edge_pages_delta >= E * 3 / 4);
        // Every edge-index prop_head is set and is NOT a slab head.
        var edges_with_props: usize = 0;
        for (mg.engine.shards) |shard| edges_with_props += try countLegacyEdgePropHeads(shard);
        try testing.expectEqual(E, edges_with_props);

        // ---- (b) read parity BEFORE shutdown. ----
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expectEqual(N, try store.countNodesForGraph(GRAPH, null));
        var s: usize = 0;
        while (s < N) : (s += SAMPLE) {
            const got = try store.getNodePropertyValue(seed_ids[s], "name");
            try testing.expectEqualStrings(nameFor(&nb, s), got.String);
            const rank = try store.getNodePropertyValue(seed_ids[s], "rank");
            try testing.expectEqualStrings(ranks[s % ranks.len], rank.String);
            const sid = try store.getNodePropertyValue(seed_ids[s], "src_id");
            try testing.expectEqual(@as(i64, @intCast(s)), sid.Int);
        }
        i = 0;
        while (i < E) : (i += 17) {
            const edge = (try store.getEdgePtrHydratedChecked(edge_ids[i])) orelse return error.EdgeNotFound;
            const w = edge.properties.get("weight") orelse return error.PropertyNotFound;
            try testing.expectEqual(@as(i64, @intCast(i)), w.Int);
            const k = edge.properties.get("kind") orelse return error.PropertyNotFound;
            try testing.expectEqualStrings(if (i % 2 == 0) "direct" else "inferred", k.String);
        }

        // ---- (c) clean shutdown (full checkpoint). ----
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // --- Phase 2: reopen -> full parity (slab store recovered through geode). ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);

        const store = graph_store.getGlobalStore(allocator);

        // Counts (triggers hydration of the reopened slab-backed graph).
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expectEqual(N, try store.countNodesForGraph(GRAPH, null));

        // Node property parity: hydrate-on-miss reads through the adapter's
        // slab-aware engine readers.
        var nb: [32]u8 = undefined;
        var s: usize = 0;
        while (s < N) : (s += SAMPLE) {
            const got = try store.getNodePropertyValue(seed_ids[s], "name");
            try testing.expectEqualStrings(nameFor(&nb, s), got.String);
            const rank = try store.getNodePropertyValue(seed_ids[s], "rank");
            try testing.expectEqualStrings(ranks[s % ranks.len], rank.String);
            const sid = try store.getNodePropertyValue(seed_ids[s], "src_id");
            try testing.expectEqual(@as(i64, @intCast(s)), sid.Int);
            const valid = try store.getNodePropertyValue(seed_ids[s], "valid");
            try testing.expectEqual((s % 2) == 0, valid.Bool);
        }
        // The single-set path parity too.
        const chk = try store.getNodePropertyValue(seed_ids[3], "checked");
        try testing.expectEqual(true, chk.Bool);

        // Edge property parity after reopen (legacy chains read back).
        var i: usize = 0;
        while (i < E) : (i += 17) {
            const edge = (try store.getEdgePtrHydratedChecked(edge_ids[i])) orelse return error.EdgeNotFound;
            const w = edge.properties.get("weight") orelse return error.PropertyNotFound;
            try testing.expectEqual(@as(i64, @intCast(i)), w.Int);
        }

        // (d) after reopen: edge heads still legacy in the recovered engine.
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        const mg = adapter.engines.get(GRAPH) orelse return error.GraphNotFound;
        var edges_with_props: usize = 0;
        for (mg.engine.shards) |shard| edges_with_props += try countLegacyEdgePropHeads(shard);
        try testing.expectEqual(E, edges_with_props);

        // A post-reopen write still works on both paths (slab node put +
        // legacy edge put through the switched sites).
        try store.setNodeProperty(seed_ids[0], "name", .{ .String = "renamed-0" });
        const renamed = try store.getNodePropertyValue(seed_ids[0], "name");
        try testing.expectEqualStrings("renamed-0", renamed.String);
        try store.setEdgeProperty(edge_ids[0], "weight", .{ .Int = 424242 });
        const edge = (try store.getEdgePtrHydratedChecked(edge_ids[0])) orelse return error.EdgeNotFound;
        const w2 = edge.properties.get("weight") orelse return error.PropertyNotFound;
        try testing.expectEqual(@as(i64, 424242), w2.Int);

        graph_store.deinitGlobalStore();
    }
}
