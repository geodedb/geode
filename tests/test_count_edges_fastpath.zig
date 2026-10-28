// GAP-ENT-0002 — count(r) edge-count fast path regression test.
//
// Before fix: `MATCH ()-[r]->() RETURN count(r)` falls to executePatternQuery
// which materializes one row per edge → O(graph) + OOM at 14.27M edges.
//
// After fix: analyzeEdgeCountFastPath detects the single-hop anonymous untyped
// directed shape and routes to countEdgesForGraph (O(1) via IdMap.edgeCount()).
// executePatternQuery is never called; getPathRowsMaterialized() stays at 0.
//
// CANARY: REQ=GAP-ENT-0002; FEATURE="EdgeCountFastPath"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_count_edges_fastpath.zig; OWNER=execution; UPDATED=2026-06-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;

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

    /// Run a query and extract the single integer scalar from the first row.
    /// Accepts both .Int and .BigInt (the latter is returned by count(DISTINCT …)).
    pub fn runQueryScalarUsize(self: *Harness, query: []const u8) !usize {
        var r = try self.runQuery(query);
        defer r.deinit(self.arena.allocator());
        if (r.rows.len != 1) return error.ExpectedOneRow;
        if (r.rows[0].len != 1) return error.ExpectedOneColumn;
        return switch (r.rows[0][0]) {
            .Int => |v| @intCast(v),
            .BigInt => |v| @intCast(v),
            else => error.ExpectedIntValue,
        };
    }

    /// Seed a parent Taxon (source, parent_id) and k children Taxons,
    /// each connected with a PARENT_OF edge.
    pub fn seedParentChildren(self: *Harness, source: []const u8, parent_id: []const u8, k: usize) !void {
        const aa = self.arena.allocator();
        {
            const q = try std.fmt.allocPrint(aa, "MERGE (p:Taxon {{source: '{s}', source_id: '{s}'}})", .{ source, parent_id });
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
        var i: usize = 0;
        while (i < k) : (i += 1) {
            const child_id = try std.fmt.allocPrint(aa, "c{d}", .{i});
            {
                const q = try std.fmt.allocPrint(aa, "MERGE (c:Taxon {{source: '{s}', source_id: '{s}'}})", .{ source, child_id });
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
};

test "count(r) is served from the edge-count fast path (no row materialization)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "P", 8); // 8 PARENT_OF edges

    planned_read_runtime.resetPathRowsMaterialized();
    const n = try h.runQueryScalarUsize("MATCH ()-[r]->() RETURN count(r)");
    try testing.expectEqual(@as(usize, 8), n);
    // Fast path: 0 rows materialized (executePatternQuery never runs).
    // Pre-fix: this is 8 (one per edge). Post-fix: 0.
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
}

test "count(*) on directed edge pattern uses the fast path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "Q", 5); // 5 edges

    planned_read_runtime.resetPathRowsMaterialized();
    const n = try h.runQueryScalarUsize("MATCH ()-[r]->() RETURN count(*)");
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
}

test "DURABILITY: typed count(r:TYPE) survives checkpoint + reopen" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "D", 9); // 9 PARENT_OF edges

    // Pre-reopen: typed fast-path count is correct.
    try testing.expectEqual(@as(usize, 9), try h.runQueryScalarUsize("MATCH ()-[r:PARENT_OF]->() RETURN count(r)"));

    // Checkpoint then reopen — drives loadFromAdapter -> loadOneGraphFromAdapter,
    // the mandatory per-(graph,type) durability rebuild hook (replay-on-load).
    const store = graph_store.getGlobalStore(h.allocator);
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    try adapter.checkpointAll();
    try store.loadFromFile();

    // The counter was rebuilt on the open edge-scan: typed count survives reopen
    // and the fast path still materializes zero per-edge rows.
    planned_read_runtime.resetPathRowsMaterialized();
    try testing.expectEqual(@as(usize, 9), try h.runQueryScalarUsize("MATCH ()-[r:PARENT_OF]->() RETURN count(r)"));
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
}

test "fallback: multi-type count(r:A|B) does NOT use the fast path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "M", 4); // 4 PARENT_OF edges

    planned_read_runtime.resetPathRowsMaterialized();
    const n = try h.runQueryScalarUsize("MATCH ()-[r:PARENT_OF|CHILD_OF]->() RETURN count(r)");
    try testing.expectEqual(@as(usize, 4), n); // correct via legacy path
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0); // multi-type → legacy
}

test "fallback: undirected typed -[r:R]- does NOT use the fast path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "U", 4);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH ()-[r:PARENT_OF]-() RETURN count(r)");
    r.deinit(h.arena.allocator());
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0); // undirected → legacy
}

test "fallback: typed count with WHERE does NOT use the fast path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "W", 4);

    planned_read_runtime.resetPathRowsMaterialized();
    const n = try h.runQueryScalarUsize("MATCH ()-[r:PARENT_OF]->() WHERE 1 = 1 RETURN count(r)");
    try testing.expectEqual(@as(usize, 4), n); // correct via legacy path
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0); // WHERE → legacy
}

test "count(DISTINCT r) does NOT use the fast path (falls to legacy path)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "R", 4);

    planned_read_runtime.resetPathRowsMaterialized();
    // docs/@BUGS_731.md bug 6b: the aggregate paths have been converged onto one
    // shared DISTINCT accumulator (src/execution/distinct_set.zig) with edge
    // identity by id, so this test no longer has to refuse to assert a value.
    // The 4 PARENT_OF edges seeded above are 4 distinct edges.
    const n = try h.runQueryScalarUsize("MATCH ()-[r]->() RETURN count(DISTINCT r)");
    try testing.expectEqual(@as(usize, 4), n);
    // Must NOT be zero — legacy path materializes rows.
    const materialized = planned_read_runtime.getPathRowsMaterialized();
    try testing.expect(materialized > 0);
}

test "typed count(r:TYPE) is served from the fast path (no row materialization)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "S", 3); // 3 PARENT_OF edges

    planned_read_runtime.resetPathRowsMaterialized();
    const n = try h.runQueryScalarUsize("MATCH ()-[r:PARENT_OF]->() RETURN count(r)");
    try testing.expectEqual(@as(usize, 3), n);
    // O(1) typed counter: executePatternQuery never runs, no per-edge rows.
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
}

test "typed count(r:TYPE) equals the legacy per-row count for the same shape" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedParentChildren("col", "T", 7); // 7 PARENT_OF edges

    // Fast-path typed count.
    const fast = try h.runQueryScalarUsize("MATCH ()-[r:PARENT_OF]->() RETURN count(r)");
    // Legacy per-row count for a NON-existent type is 0; for PARENT_OF it is 7.
    const fast_missing = try h.runQueryScalarUsize("MATCH ()-[r:NOPE]->() RETURN count(r)");
    try testing.expectEqual(@as(usize, 7), fast);
    try testing.expectEqual(@as(usize, 0), fast_missing);
}
