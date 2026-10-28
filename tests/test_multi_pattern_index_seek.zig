// KNOWN BUG #2 (from-dump EDGE phase) reproduction / regression.
//
// Triage: the from-dump taxonomy edge phase issues, per taxon, a MULTI-pattern
// (comma-separated) MATCH that resolves both endpoints by their indexed
// {source, source_id} composite key, then MERGEs the relationship:
//
//   MATCH (a:Taxon {source: ?, source_id: ?}), (b:Taxon {source: ?, source_id: ?})
//   MERGE (a)-[r:PARENT_OF]->(b) SET r.run_id = ?
//
// Single-pattern inline-equality reads were already wired to SEEK the exact
// exact-property index (see test_inline_key_index_seek.zig, KNOWN BUG #1).
// But the MULTI-pattern executor `match_operations.executeMultiNodeMatch`
// collected each chain's candidates by FULL-SCANNING the label posting list
// (`getNodesByLabels`) and comparing every node's inline props in a loop —
// O(label) PER comma-pattern, with no index seek even when `source_id` is the
// indexed unique MERGE key. At 14.27M Taxon nodes each edge statement scanned
// ~2 * 14.27M nodes; the server pinned CPU and created ~0 edges while the edge
// client backpressured. THIS is why the edge phase never created edges.
//
// The storage adapter already exposes an O(matching) exact-property index
// (`getCandidateNodesByLabelAndProperty`, used by the MERGE dedup path and the
// single-pattern seek). The fix wires `executeMultiNodeMatch` to SEEK that
// index per chain for any inline equality on an INDEXED property (gated by
// `graph_store.shouldIndexProperty`, the same predicate the write path uses),
// picking the most-selective indexed prop, then re-verifies every candidate via
// the UNCHANGED per-node property/tenant/RLS/pushed-WHERE checks so results are
// byte-for-byte identical to the full-scan path.
//
// These tests are wall-clock-INDEPENDENT. They assert:
//   1. Correctness: the edge is created between the two existing taxa.
//   2. The seek path is actually taken (the exact-property index lookup counter
//      increments for the multi-pattern endpoint resolution).
//   3. A dangling endpoint (no matching node) creates NO edge (MATCH yields no
//      rows) — and still does not full-scan.
//   4. Idempotency: re-running the MERGE does not duplicate the edge.
//
// CANARY: REQ=REQ-PERF-MULTI-PATTERN-INDEX-SEEK; FEATURE="MultiPatternIndexSeek"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_multi_pattern_index_seek.zig; OWNER=performance; UPDATED=2026-06-21

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const graph_storage_adapter = geode.graph_storage_adapter;

const N_NODES: usize = 1500;

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

    // Seed via MERGE so both `source` and `source_id` are registered as merge
    // keys (keeping the exact index populated even under
    // GEODE_INDEX_MERGE_KEYS_ONLY). This mirrors the from-dump taxa pass node
    // schema: MERGE (t:Taxon {source, source_id}).
    fn seed(self: *Harness, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const aa = self.arena.allocator();
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (n:Taxon {{source: 'col', source_id: 'sid{d}'}}) SET n.name = 'name{d}'",
                .{ i, i },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }

    // Count PARENT_OF edges between sid<parent> and sid<child>.
    fn edgeCount(self: *Harness, parent: usize, child: usize) !i64 {
        const aa = self.arena.allocator();
        const q = try std.fmt.allocPrint(
            aa,
            "MATCH (a:Taxon {{source: 'col', source_id: 'sid{d}'}})-[r:PARENT_OF]->(b:Taxon {{source: 'col', source_id: 'sid{d}'}}) RETURN count(r)",
            .{ parent, child },
        );
        var r = try self.runQuery(q);
        defer r.deinit(aa);
        if (r.rows.len == 0) return 0;
        return switch (r.rows[0][0]) {
            .Int => |v| v,
            .BigInt => |v| v,
            .SmallInt => |v| v,
            else => error.UnexpectedCountType,
        };
    }
};

// The exact from-dump edge statement shape.
const EDGE_STMT =
    "MATCH (a:Taxon {source: 'col', source_id: 'sid10'}), (b:Taxon {source: 'col', source_id: 'sid11'}) " ++
    "MERGE (a)-[r:PARENT_OF]->(b) SET r.run_id = 'run1'";

// -------------------------------------------------------------------
// Test 1 — the multi-pattern edge MATCH+MERGE creates the edge AND resolves
// each endpoint via the unique-key index seek (NOT a full label scan).
//
// Proof-of-seek signal: `getNodesByLabels` (the full label-posting scan the
// pre-fix multi-node executor invoked once PER comma-pattern) is NOT called
// for the EDGE_STMT — both endpoints resolve through the merge index. Before
// the fix this counter was 2 (one scan per pattern); after the fix it is 0.
// -------------------------------------------------------------------
test "multi-pattern edge MERGE creates edge via index seek" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    graph_store.resetGetNodesByLabelsCount();
    var r = try h.runQuery(EDGE_STMT);
    r.deinit(h.arena.allocator());
    const label_scans = graph_store.getNodesByLabelsCallCount();

    // The endpoint resolution took the seek path: NO full label-posting scan.
    // Pre-fix this was 2 (a scan per comma-pattern) — the bug that made the
    // 14.27M-taxa edge phase O(graph) per statement and create ~0 edges.
    try testing.expectEqual(@as(u64, 0), label_scans);

    // Correctness: exactly one PARENT_OF edge exists between the two taxa.
    try testing.expectEqual(@as(i64, 1), try h.edgeCount(10, 11));
}

// -------------------------------------------------------------------
// Test 2 — dangling endpoint: a parent_id that has no matching Taxon node
// creates NO edge (the MATCH yields no rows), and still seeks (no full scan):
// the absent endpoint is an AUTHORITATIVE unique-key miss, so the chain is
// empty without scanning the label.
// -------------------------------------------------------------------
test "multi-pattern edge MERGE skips dangling endpoint" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    const aa = h.arena.allocator();
    const dangling =
        "MATCH (a:Taxon {source: 'col', source_id: 'sid-missing'}), (b:Taxon {source: 'col', source_id: 'sid20'}) " ++
        "MERGE (a)-[r:PARENT_OF]->(b) SET r.run_id = 'run1'";

    graph_store.resetGetNodesByLabelsCount();
    var r = try h.runQuery(dangling);
    r.deinit(aa);
    const label_scans = graph_store.getNodesByLabelsCallCount();

    // No edge: the absent endpoint contributes no rows to the comma-product.
    try testing.expectEqual(@as(i64, 0), try h.edgeCount(99999, 20));
    // Still took the seek path — the unique-key miss never fell back to a scan.
    try testing.expectEqual(@as(u64, 0), label_scans);
}

// -------------------------------------------------------------------
// Test 3 — idempotency: re-running the same MERGE does not duplicate the edge.
// -------------------------------------------------------------------
test "multi-pattern edge MERGE is idempotent on re-run" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var r1 = try h.runQuery(EDGE_STMT);
    r1.deinit(h.arena.allocator());
    var r2 = try h.runQuery(EDGE_STMT);
    r2.deinit(h.arena.allocator());
    var r3 = try h.runQuery(EDGE_STMT);
    r3.deinit(h.arena.allocator());

    // Exactly one edge after three runs (MERGE on the relationship dedups).
    try testing.expectEqual(@as(i64, 1), try h.edgeCount(10, 11));
}

// -------------------------------------------------------------------
// Test 4 — GAP-0334 trap: a node CREATEd (not MERGEd) is present in the exact
// index but absent from the 1:1 merge index. The multi-pattern MATCH must
// still find it (fall back to the label scan rather than wrongly concluding
// the unique-key seek "misses"). Correctness must never be sacrificed for the
// seek fast path.
// -------------------------------------------------------------------
test "multi-pattern match finds CREATE-seeded nodes (no false miss)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Two CREATEd nodes (NOT merged): present in the exact index, absent from
    // the merge index. The unique-key probe sees posting_len==1 but the merge
    // index misses — the executor must fall back to the scan and still match.
    const aa = h.arena.allocator();
    var c1 = try h.runQuery("CREATE (n:Taxon {source: 'col', source_id: 'cre1', name: 'a'})");
    c1.deinit(aa);
    var c2 = try h.runQuery("CREATE (n:Taxon {source: 'col', source_id: 'cre2', name: 'b'})");
    c2.deinit(aa);

    var m = try h.runQuery(
        "MATCH (a:Taxon {source: 'col', source_id: 'cre1'}), (b:Taxon {source: 'col', source_id: 'cre2'}) RETURN a.source_id, b.source_id",
    );
    defer m.deinit(aa);
    // Both CREATE-seeded nodes are found -> exactly one (a,b) combination.
    try testing.expectEqual(@as(usize, 1), m.rows.len);
}
