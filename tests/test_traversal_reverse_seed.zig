// GAP-ENT-0001 Bug B — Traversal reverse-seed regression test.
//
// Before fix: `MATCH (p:Taxon)-[:PARENT_OF]->(c:Taxon {source:'col', source_id:'c0'})`
// always seeds from chain.head (or hops[0].left = p). The head node p has NO
// indexed inline props, so `collectStartSlots` falls to `adapter.getNodesByLabel`
// — an O(graph) label scan on p. The terminal c, which carries indexed props
// {source, source_id}, is never seeded.
//
// After fix (Bug B): `executePatternQuery` probes both endpoints' selectivity
// (estimatePatternSelectivity). For a single directed hop where the tail is
// strictly more selective than the head, the planner flips: it seeds from c
// (O(1) index seek) and expands backwards (iterateIncomingEdges) to find p.
// `getNodesByLabel` is never called.
//
// Regression gate: after a reverse single-hop traversal with a bound tail,
//   getLabelScanLookupCount() == 0          (no label scan taken)
//   getExactNodePropertyLookupCount() >= 1  (index seek on c taken)
//
// CANARY: REQ=REQ-PERF-TRAVERSAL-REVERSE-SEED; FEATURE="TraversalReverseSeed"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_traversal_reverse_seed.zig; OWNER=performance; UPDATED=2026-06-26

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

    /// Run a query and return its row count. Used to verify traversal results
    /// without keeping row data alive.
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
        // Create parent node
        {
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (p:Taxon {{source: '{s}', source_id: '{s}'}})",
                .{ source, parent_id },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
        // Create each child and the edge
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

    /// Seed n unrelated Taxon filler nodes (source, 'filler0'..'filler{n-1}').
    /// These inflate the label posting list so a label-scan is observably slower
    /// and the counter fires if the bug path is taken.
    pub fn seedFiller(self: *Harness, source: []const u8, n: usize) !void {
        const aa = self.arena.allocator();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (n:Taxon {{source: '{s}', source_id: 'filler{d}'}})",
                .{ source, i },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

// -------------------------------------------------------------------
// Primary test — reverse traversal seeds the bound terminal endpoint, not a label scan.
//
// Pre-fix:  getLabelScanLookupCount() >= 1 (falls to getNodesByLabel O(graph) on p)
// Post-fix: getLabelScanLookupCount() == 0  AND getExactNodePropertyLookupCount() >= 1
// -------------------------------------------------------------------
test "reverse traversal seeds the bound endpoint, not a label scan" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "P", 8);
    try h.seedFiller("col", 200);

    graph_storage_adapter.resetLookupCounters();
    const rows = try h.runQueryRowCount(
        "MATCH (p:Taxon)-[:PARENT_OF]->(c:Taxon {source:'col', source_id:'c0'}) RETURN p.source_id",
    );

    try testing.expectEqual(@as(usize, 1), rows);
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLabelScanLookupCount());
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() >= 1);
}

// -------------------------------------------------------------------
// P1 forward non-regression guard — composite-start traversal still uses the index.
//
// Ensures the Bug B fix does not regress the Bug A fix: when the HEAD node is
// the more-selective endpoint, seeding is still done from the head via its indexed
// composite props (not a label scan on p or c).
// -------------------------------------------------------------------
test "forward traversal (P1) still seeds the composite-start index, not a label scan" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "P", 8);
    try h.seedFiller("col", 200);

    graph_storage_adapter.resetLookupCounters();
    const rows = try h.runQueryRowCount(
        "MATCH (p:Taxon {source:'col', source_id:'P'})-[:PARENT_OF]->(c:Taxon) RETURN c.source_id",
    );

    try testing.expectEqual(@as(usize, 8), rows);
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLabelScanLookupCount());
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() >= 1);
}
