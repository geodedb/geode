// EDGE-PHASE WEDGE (from-dump edge ingest) reproduction / regression.
//
// Triage (root-caused via live gdb at edge-phase wedge): the from-dump edge
// phase resolves each relationship endpoint through the QUIC bulk fast path
// `executeBulkMatchMergeEdge` -> `StorageAdapter.lookupNodeIdByLabelAndAllProps`
// for the composite key `{source, source_id}`. That resolver seeded the scan on
// the SMALLEST NON-ZERO exact-index posting and, when the UNIQUE component
// `source_id` had ZERO postings (a DANGLING endpoint — a parent_id/accepted_id
// whose taxon was not loaded, which is common across taxonomies and at partial
// loads), fell back to seeding on the low-selectivity `source` posting (shared
// by ~N nodes) and then VERIFIED all ~N candidates with a per-candidate
// `getNodeProperty`. Under the bounded node cache each verify is an engine-
// direct disk page pin, and the whole O(N) scan runs while the bulk path holds
// the per-graph rwlock SHARED — so the periodic checkpoint's EXCLUSIVE tryLock
// never observes a reader-free instant (geode_nodes_total stays 0) and 8 edge
// workers thrash the buffer pool making ~0 forward progress. The wedge.
//
// The multi-pattern EXECUTOR path (`match_operations.seekMultiNodeCandidate`,
// KNOWN BUG #2) already short-circuits an authoritative unique-key MISS without
// scanning. The bulk fast-path resolver `lookupNodeIdByLabelAndAllProps` was
// MISSED. The fix mirrors the executor: when any indexed component has an
// AUTHORITATIVE zero posting (the exact index covers the key — registered merge
// key / non-lean — and reports zero), the composite AND-match is unsatisfiable,
// so return `missing_err` immediately and examine ZERO candidates. A
// CREATE-seeded node (present in the exact index, absent from the merge index —
// GAP-0334) must still be FOUND, so a unique posting of 1 is never treated as a
// miss.
//
// These tests are wall-clock-INDEPENDENT. They assert:
//   1. A present composite key resolves to the right node (correctness).
//   2. A DANGLING unique key returns `missing_err` and examines ZERO candidates
//      (the fix: no O(N) verify scan). This FAILS before the fix (it scanned
//      every node sharing the `source` value).
//   3. A genuine non-match (unique key present but second component contradicts)
//      still returns `missing_err`, examining at most the unique candidate.
//   4. A CREATE-seeded node (exact-indexed, merge-index-absent) is still FOUND
//      (no false miss): correctness is never sacrificed for the fast-negative.
//
// CANARY: REQ=REQ-PERF-BULK-EDGE-ENDPOINT-SEEK; FEATURE="BulkEdgeEndpointSeek"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_bulk_edge_endpoint_seek.zig; OWNER=performance; UPDATED=2026-06-24

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const graph_storage_adapter = geode.graph_storage_adapter;

const N_NODES: usize = 1500;

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

    // Seed via MERGE so both `source` and `source_id` are registered merge keys
    // (the exact index stays populated even under GEODE_INDEX_MERGE_KEYS_ONLY),
    // mirroring the from-dump taxa schema: MERGE (t:Taxon {source, source_id}).
    // Every node shares source='col' (low selectivity), so `source` has an
    // ~N-long posting — exactly the trap the dangling-endpoint scan fell into.
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
};

const PropKV = graph_storage_adapter.StorageAdapter.PropKV;

fn strKV(key: []const u8, val: []const u8) PropKV {
    return .{ .key = key, .value = .{ .String = val } };
}

// -------------------------------------------------------------------
// Test 0 — INTEGER single-key resolution must still FIND a node (guards
// against the fast-negative wrongly pruning a present integer-keyed node due
// to a value-hash mismatch between write and read). Mirrors the multiplex
// `MERGE (n:L {id: <int>})` / `MATCH (p:L {id: <int>})` edge shape.
// -------------------------------------------------------------------
test "bulk edge endpoint seek: present integer single key resolves" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();
    var r1 = try h.runQuery("MERGE (n:L {id: 1})");
    r1.deinit(aa);
    var r2 = try h.runQuery("MERGE (n:L {id: 2})");
    r2.deinit(aa);

    const adapter = graph_store.getGlobalAdapter().?;
    const f1 = [_]PropKV{.{ .key = "id", .value = .{ .Int = 1 } }};
    const id1 = try adapter.lookupNodeIdByLabelAndAllProps(
        graph_store.DEFAULT_GRAPH_NAME,
        "L",
        &f1,
        error.SourceNodeNotFound,
    );
    try testing.expect(id1 != 0);
}

// -------------------------------------------------------------------
// Test 1 — present composite key resolves to the correct node.
// -------------------------------------------------------------------
test "bulk edge endpoint seek: present composite key resolves" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    const adapter = graph_store.getGlobalAdapter().?;
    // {source:'col', source_id:'sid42'} — order matches the from-dump shape
    // (low-selectivity `source` FIRST, unique `source_id` SECOND).
    const filters = [_]PropKV{ strKV("source", "col"), strKV("source_id", "sid42") };

    const id = try adapter.lookupNodeIdByLabelAndAllProps(
        graph_store.DEFAULT_GRAPH_NAME,
        "Taxon",
        &filters,
        error.SourceNodeNotFound,
    );
    try testing.expect(id != 0);
}

// -------------------------------------------------------------------
// Test 2 — DANGLING unique key: authoritative miss, ZERO candidates scanned.
// This is the wedge reproduction. Before the fix the resolver seeded on the
// low-selectivity `source` posting (N entries) and verified every one — an
// O(N) scan. After the fix the authoritative `source_id` zero-posting makes it
// return immediately, scanning ZERO candidates.
// -------------------------------------------------------------------
test "bulk edge endpoint seek: dangling unique key is authoritative miss (no O(N) scan)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    const adapter = graph_store.getGlobalAdapter().?;
    const filters = [_]PropKV{ strKV("source", "col"), strKV("source_id", "sid-does-not-exist") };

    graph_storage_adapter.resetLookupCounters();
    const res = adapter.lookupNodeIdByLabelAndAllProps(
        graph_store.DEFAULT_GRAPH_NAME,
        "Taxon",
        &filters,
        error.SourceNodeNotFound,
    );
    try testing.expectError(error.SourceNodeNotFound, res);

    // THE FIX: the dangling endpoint examined ZERO candidate nodes. Before the
    // fix this was ~N (every node sharing source='col'), i.e. the O(N)-per-edge
    // scan that wedged the edge phase under the bounded node cache.
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLookupAllPropsCandidatesScanned());
}

// -------------------------------------------------------------------
// Test 3 — unique key present but second component contradicts: still a miss,
// and the verify scans at most the single unique candidate (never the whole
// `source` posting).
// -------------------------------------------------------------------
test "bulk edge endpoint seek: contradicting second component is a bounded miss" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    const adapter = graph_store.getGlobalAdapter().?;
    // source_id sid9 exists but source 'nope' does not match it.
    const filters = [_]PropKV{ strKV("source", "nope"), strKV("source_id", "sid9") };

    graph_storage_adapter.resetLookupCounters();
    const res = adapter.lookupNodeIdByLabelAndAllProps(
        graph_store.DEFAULT_GRAPH_NAME,
        "Taxon",
        &filters,
        error.SourceNodeNotFound,
    );
    try testing.expectError(error.SourceNodeNotFound, res);
    // Seeds on the UNIQUE source_id (posting 1), verifies that one candidate,
    // rejects it on the source mismatch: at most 1 candidate examined.
    try testing.expect(graph_storage_adapter.getLookupAllPropsCandidatesScanned() <= 1);
}

// -------------------------------------------------------------------
// Test 4 — GAP-0334: a CREATE-seeded node (present in the exact index, ABSENT
// from the 1:1 merge index) must still be FOUND. A unique posting of 1 is a
// real node, never an authoritative miss — correctness is never sacrificed.
// -------------------------------------------------------------------
test "bulk edge endpoint seek: CREATE-seeded node is found (no false miss)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();
    var c1 = try h.runQuery("CREATE (n:Taxon {source: 'col', source_id: 'cre1', name: 'a'})");
    c1.deinit(aa);

    const adapter = graph_store.getGlobalAdapter().?;
    const filters = [_]PropKV{ strKV("source", "col"), strKV("source_id", "cre1") };
    const id = try adapter.lookupNodeIdByLabelAndAllProps(
        graph_store.DEFAULT_GRAPH_NAME,
        "Taxon",
        &filters,
        error.SourceNodeNotFound,
    );
    try testing.expect(id != 0);
}

// ===================================================================
// PUBLIC-ID resolver (`lookupPublicNodeIdByLabelAndAllProps`) — the LIVE
// edge-MERGE endpoint path. It must return a GraphStore PUBLIC node id (the
// `store.nodes` key space the shard-locked edge MERGE apply uses), not an
// engine-slot id. The slot-vs-public mismatch is the pre-existing bug that made
// the from-dump edge phase commit ZERO edges.
// ===================================================================

// Test 5 — the public resolver returns an id that IS resident in `store.nodes`
// (i.e. usable by the edge MERGE apply). The slot-space resolver's id is NOT
// guaranteed to be a `store.nodes` key; this is the crux of the commit fix.
test "public edge endpoint seek: returns a store.nodes-valid public id" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    const adapter = graph_store.getGlobalAdapter().?;
    const store = graph_store.getGlobalStore(h.allocator);
    const filters = [_]PropKV{ strKV("source", "col"), strKV("source_id", "sid42") };

    const pub_id = try adapter.lookupPublicNodeIdByLabelAndAllProps(
        graph_store.DEFAULT_GRAPH_NAME,
        "Taxon",
        &filters,
        error.SourceNodeNotFound,
    );
    try testing.expect(pub_id != 0);
    // THE FIX: the returned id is a real key in the public node map — the edge
    // MERGE apply's `store.nodes.getPtr(pub_id)` will find it. (A slot-space id
    // would generally NOT be a store.nodes key, which dropped every edge.)
    try testing.expect(store.nodes.getPtr(pub_id) != null);
}

// Test 6 — public resolver: dangling unique key is an authoritative miss with
// ZERO candidate scan (the wedge fast-negative on the live path).
test "public edge endpoint seek: dangling unique key is authoritative miss" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    const adapter = graph_store.getGlobalAdapter().?;
    const filters = [_]PropKV{ strKV("source", "col"), strKV("source_id", "sid-nope") };

    graph_storage_adapter.resetLookupCounters();
    const res = adapter.lookupPublicNodeIdByLabelAndAllProps(
        graph_store.DEFAULT_GRAPH_NAME,
        "Taxon",
        &filters,
        error.SourceNodeNotFound,
    );
    try testing.expectError(error.SourceNodeNotFound, res);
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLookupAllPropsCandidatesScanned());
}

// Test 7 — public resolver: CREATE-seeded node (exact-indexed, merge-index
// absent) is still found via the GAP-0334 public-id fallback scan.
test "public edge endpoint seek: CREATE-seeded node found via public fallback" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();
    var c1 = try h.runQuery("CREATE (n:Taxon {source: 'col', source_id: 'pcre1', name: 'a'})");
    c1.deinit(aa);

    const adapter = graph_store.getGlobalAdapter().?;
    const store = graph_store.getGlobalStore(h.allocator);
    const filters = [_]PropKV{ strKV("source", "col"), strKV("source_id", "pcre1") };
    const pub_id = try adapter.lookupPublicNodeIdByLabelAndAllProps(
        graph_store.DEFAULT_GRAPH_NAME,
        "Taxon",
        &filters,
        error.SourceNodeNotFound,
    );
    try testing.expect(pub_id != 0);
    try testing.expect(store.nodes.getPtr(pub_id) != null);
}
