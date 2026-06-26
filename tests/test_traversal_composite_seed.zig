// GAP-ENT-0001 Bug A — Traversal composite-start seed regression test.
//
// Before fix: `MATCH (p:Taxon {source:'col', source_id:'P'})-[:PARENT_OF]->(c:Taxon)`
// has TWO inline props on the start node. `collectStartSlots` `fp:` block broke
// out at `if (props.len != 1) break :fp;`, falling to `adapter.getNodesByLabel`
// (O(graph) label scan). At 14.27M nodes this makes ANY composite-start
// traversal hang.
//
// After fix: `collectStartSlots` loops ALL inline props, picks the most
// selective indexed one (fewest postings via countCandidateNodesByLabelAndProperty),
// and seeds from that index in O(degree). `getNodesByLabel` is never called.
//
// Regression gate: after a composite-start forward traversal,
//   getLabelScanLookupCount() == 0          (no label scan taken)
//   getExactNodePropertyLookupCount() >= 1  (index seek taken)
//
// CANARY: REQ=REQ-PERF-TRAVERSAL-COMPOSITE-SEED; FEATURE="TraversalCompositeSeed"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_traversal_composite_seed.zig; OWNER=performance; UPDATED=2026-06-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const graph_storage_adapter = geode.graph_storage_adapter;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
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
// Primary test — composite-start traversal seeds the index, not a label scan.
//
// Pre-fix:  getLabelScanLookupCount() >= 1 (falls to getNodesByLabel O(graph))
// Post-fix: getLabelScanLookupCount() == 0  AND getExactNodePropertyLookupCount() >= 1
// -------------------------------------------------------------------
test "traversal composite-start seeds the index, not a label scan" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "P", 8); // parent P + 8 PARENT_OF children
    try h.seedFiller("col", 200); // 200 unrelated Taxon nodes (makes label scan observable)

    graph_storage_adapter.resetLookupCounters();
    const rows = try h.runQueryRowCount(
        "MATCH (p:Taxon {source:'col', source_id:'P'})-[:PARENT_OF]->(c:Taxon) RETURN c.source_id",
    );

    try testing.expectEqual(@as(usize, 8), rows); // correctness: exactly 8 children
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLabelScanLookupCount()); // O(degree) seed: no label scan
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() >= 1); // index seek taken
}
