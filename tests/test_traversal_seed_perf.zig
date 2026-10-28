// Traversal-seed perf micro-benchmark (P1 close-out).
//
// Verifies that the composite-key traversal seed remains O(degree) — not
// O(graph) — even when a large number of unrelated filler nodes share the
// same label.  Two categories of assertions:
//
//   Counter assertions (deterministic):
//     getLabelScanLookupCount() == 0   — no label scan taken (O(degree) seed)
//     getExactNodePropertyLookupCount() >= 1  — index seek taken
//     rows == 64                        — correctness: exactly 64 children
//
//   Wall-clock guard (generous, catches gross regressions):
//     elapsed_ms < 200  — avoids flakiness while still catching catastrophic
//                          O(graph) regressions (label scan over 8000+ nodes
//                          in a debug build would take >> 200 ms).
//
// Filler count: 8000 nodes.  Building them via individual MERGE queries is
// acceptable (~30-50 s in debug builds); if that proves too slow in CI the
// count can be reduced to 2000 (still clearly non-trivial for a label scan)
// but 8000 is preferred to widen the performance gap.
//
// CANARY: REQ=REQ-PERF-TRAVERSAL-SEED; FEATURE="TraversalSeedPerf"; ASPECT=PerfMicrobenchmark; STATUS=TESTED; TEST=tests/test_traversal_seed_perf.zig; OWNER=performance; UPDATED=2026-06-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const graph_storage_adapter = geode.graph_storage_adapter;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn runQueryRowCount(self: *Harness, query: []const u8) !usize {
        const aa = self.arena.allocator();
        var r = try self.runQuery(query);
        defer r.deinit(aa);
        return r.rows.len;
    }

    /// Seed a parent Taxon (source, parent_id) and k children Taxons
    /// (source, 'c0'..'c{k-1}'), each connected with a PARENT_OF edge.
    pub fn seedParentChildren(self: *Harness, source: []const u8, parent_id: []const u8, k: usize) !void {
        const aa = self.arena.allocator();
        {
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (p:Taxon {{source: '{s}', source_id: '{s}'}})",
                .{ source, parent_id },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
        var i: usize = 0;
        while (i < k) : (i += 1) {
            const child_id = try std.fmt.allocPrint(aa, "c{d}", .{i});
            {
                const q = try std.fmt.allocPrint(
                    aa,
                    "MERGE (c:Taxon {{source: '{s}', source_id: '{s}'}})",
                    .{ source, child_id },
                );
                var r = try self.runQuery(q);
                r.deinit(aa);
            }
            {
                const q = try std.fmt.allocPrint(
                    aa,
                    "MATCH (p:Taxon {{source: '{s}', source_id: '{s}'}}), (c:Taxon {{source: '{s}', source_id: '{s}'}}) MERGE (p)-[:PARENT_OF]->(c)",
                    .{ source, parent_id, source, child_id },
                );
                var r = try self.runQuery(q);
                r.deinit(aa);
            }
        }
    }

    /// Seed n unrelated Taxon filler nodes (source_id: 'fN' for N in 0..n-1).
    /// These inflate the label posting list so a label scan would be clearly
    /// non-trivial; 8000 is the target (reduces to 2000 if build time is >30s).
    pub fn seedFiller(self: *Harness, source: []const u8, n: usize) !void {
        const aa = self.arena.allocator();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (n:Taxon {{source: '{s}', source_id: 'f{d}'}})",
                .{ source, i },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

// -------------------------------------------------------------------
// Perf micro-benchmark: O(degree) traversal seed over a large filler graph.
//
// Checks that `MATCH (p:Taxon {source:'col', source_id:'P'})-[:PARENT_OF]->(c:Taxon)`
// seeds from the property index (zero label-scan lookups) regardless of how
// many unrelated Taxon nodes exist in the graph.
//
// Filler count: 8000 nodes (comment: reduces label-scan vs index-seek gap
// to ~several ms for these data sizes, making the wall-clock guard meaningful
// without being flaky on a loaded CI machine).
// -------------------------------------------------------------------
test "traversal seed perf: O(degree) regardless of filler size" {
    // Filler size: 8000 unrelated Taxon nodes.
    // A full label scan over ~8065 nodes in a debug build takes > 200 ms;
    // an index seek takes < 5 ms.  The wall-clock guard is set to 200 ms.
    const filler_count: usize = 8000;
    const children_count: usize = 64;

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed the graph: one parent with 64 PARENT_OF children + 8000 filler nodes.
    try h.seedParentChildren("col", "P", children_count);
    try h.seedFiller("col", filler_count);

    // Zig 0.16 compat: std.time.Timer was removed; use POSIX MONOTONIC directly.
    const monoNowNs = struct {
        fn call() i128 {
            return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toNanoseconds();
        }
    }.call;

    // Reset counters immediately before the timed query.
    graph_storage_adapter.resetLookupCounters();

    const t0 = monoNowNs();
    const rows = try h.runQueryRowCount(
        "MATCH (p:Taxon {source:'col', source_id:'P'})-[:PARENT_OF]->(c:Taxon) RETURN c.source_id",
    );
    const elapsed_ns = monoNowNs() - t0;
    const elapsed_ms = @as(u64, @intCast(@max(0, elapsed_ns))) / std.time.ns_per_ms;

    std.debug.print(
        "\n[traversal-seed-perf] filler={d} children={d} elapsed={d}ms\n",
        .{ filler_count, children_count, elapsed_ms },
    );

    // Correctness: all 64 children returned.
    try testing.expectEqual(@as(usize, children_count), rows);

    // Core perf guarantee: zero label-scan lookups — proves O(degree) seed
    // regardless of the 8000-node filler graph.
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLabelScanLookupCount());

    // Index path taken: at least one exact-property lookup.
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() >= 1);

    // Wall-clock guard: generous 200 ms ceiling catches O(graph) regressions
    // without flapping on loaded CI machines.
    try testing.expect(elapsed_ms < 200);
}
