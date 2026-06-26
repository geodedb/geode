// P3b: multi-chain comma-MATCH hash-join regression tests.
//
// ROOT CAUSE (pre-fix)
// ====================
// `isStorageNativeQuery` rejected any MATCH with `chains.len > 1`, routing
// ALL multi-chain reads to the legacy executor.  The legacy path in the real
// server calls `snapshotUnderReadLock` for non-engine-direct reads, cloning
// the in-memory graph O(N) per query — the read-path OOM source.  It also
// produces a true cartesian before applying the WHERE filter, which for large
// label sets is O(|A| × |B|) rows of allocations before pruning.
//
// FIX (P3b)
// =========
// `isAllSimpleNodeMultiChain` returns true for all-simple-node multi-chain
// patterns.  `isStorageNativeQuery` delegates to it instead of hard-failing.
// `buildPlanIfSupported` registers one binding per chain.
// `executeMultiChainHashJoin` collects per-chain start slots engine-direct,
// finds a cross-chain equality predicate, and runs a hash-join (or a
// true-cartesian when no join key is present).  No snapshot clone is taken.
//
// OBSERVABLE: `planned_read_runtime.getPathRowsMaterialized()` is incremented
// only on the storage-native (planned) read path.  Before the fix it stays 0
// for multi-chain queries (legacy executor); after the fix it equals the
// number of result rows.
//
// CANARY: REQ=REQ-READ-MULTICHAIN-HASHJOIN-P3B; FEATURE="MultiChainHashJoin"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_multichain_hashjoin.zig; OWNER=execution; UPDATED=2026-06-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;

// ---------------------------------------------------------------------------
// Harness (mirrors test_gap0903_rls_clone_gate.zig)
// ---------------------------------------------------------------------------

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

    pub fn seedNodes(self: *Harness, count: usize, label: []const u8) !void {
        const aa = self.arena.allocator();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const q = try std.fmt.allocPrint(aa, "CREATE (:{s} {{id: {d}}})", .{ label, i });
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

// ---------------------------------------------------------------------------
// Test 1: multi-chain comma-MATCH uses hash-join (storage-native, no clone)
//
// Seeds 5 :A and 8 :B nodes, where :B ids 0-4 match :A ids 0-4 and :B ids
// 5-7 are "filler" with no matching :A.  The join query must return exactly
// 5 rows.  The storage-native path (hash-join) is proven by asserting
// getPathRowsMaterialized() > 0 — this counter is only incremented on the
// planned-read-runtime path, not by the legacy executor.
// ---------------------------------------------------------------------------
test "multi-chain comma-MATCH uses hash-join, not clone+cartesian" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // 5 :A nodes (id: 0..4), 8 :B nodes (id: 0..7, filler 5..7 won't match).
    try h.seedNodes(5, "A");
    try h.seedNodes(8, "B");

    graph_store.resetCloneNodesTotal();
    planned_read_runtime.resetPathRowsMaterialized();

    var r = try h.runQuery("MATCH (a:A),(b:B) WHERE a.id = b.id RETURN a.id, b.id");
    defer r.deinit(h.arena.allocator());

    // 5 matching pairs: (0,0), (1,1), (2,2), (3,3), (4,4).
    try testing.expectEqual(@as(usize, 5), r.rows.len);

    // No whole-graph clone.
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());

    // Storage-native path executed (getPathRowsMaterialized > 0).
    // RED before fix: multi-chain falls to legacy which does NOT increment this.
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
}

// ---------------------------------------------------------------------------
// Test 2: multi-chain true-cartesian (no WHERE join key) = full N×M product
// ---------------------------------------------------------------------------
test "multi-chain true-cartesian (no WHERE join key) = full product" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.seedNodes(3, "Cat");
    try h.seedNodes(4, "Dog");

    graph_store.resetCloneNodesTotal();
    planned_read_runtime.resetPathRowsMaterialized();

    var r = try h.runQuery("MATCH (a:Cat),(b:Dog) RETURN a.id, b.id");
    defer r.deinit(h.arena.allocator());

    // 3 × 4 = 12 pairs.
    try testing.expectEqual(@as(usize, 12), r.rows.len);
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());

    // Storage-native path executed.
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
}

// ---------------------------------------------------------------------------
// Test 3: RLS active — multi-chain routes to legacy (no hash-join, correct
// RLS-filtered result, no clone).
//
// With RLS active, query_execution.zig:1673 skips executeIfSupported entirely
// and routes to the legacy executor which applies passesRLSFilter per node.
// Denying :Y means no :Y nodes are visible → 0 (a:X),(b:Y) pairs.
// getPathRowsMaterialized() stays 0 because the legacy path does NOT call
// materializeNodeOnlyRow / materializeMultiChainRow.
// ---------------------------------------------------------------------------
test "RLS active: multi-chain routes to legacy (no hash-join, no clone, correct result)" {
    var label_engine = rls_types.RLSFilterEngine.init(testing.allocator);
    defer label_engine.deinit();
    try label_engine.addDenyPolicy("default", "Y", "");
    rls_types.setGlobalRLSFilterEngine(&label_engine);
    defer rls_types.setGlobalRLSFilterEngine(null);

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.seedNodes(3, "X");
    try h.seedNodes(3, "Y");

    h.ctx.user = "alice";
    const prev_ctx = execution.pushActiveContext(&h.ctx);
    defer execution.popActiveContext(prev_ctx);

    try testing.expect(execution.wouldEvaluateRLS());

    graph_store.resetCloneNodesTotal();
    planned_read_runtime.resetPathRowsMaterialized();

    // With :Y denied, no :Y nodes visible → 0 pairs.
    var r = try h.runQuery("MATCH (a:X),(b:Y) RETURN a.id, b.id");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 0), r.rows.len);
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());

    // Legacy path: getPathRowsMaterialized stays 0.
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
}
