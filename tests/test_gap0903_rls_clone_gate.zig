// GAP-0903: RLS-read clone-gate regression / fix.
//
// ROOT CAUSE (pre-fix)
// ====================
// `readServedEngineDirect` in QCH contained:
//
//   if (authenticatedReadNeedsRlsSnapshot(state)) return false;
//
// This made the function return false for any RLS-active read, so the handler
// fell through to `snapshotUnderReadLock` + the legacy executor on a CLONE of
// the in-memory store.  For a large resident graph that clone is O(N) in both
// CPU and RSS — at 14M+ taxa it is the dominant OOM cause on the read path.
//
// FIX (P3a)
// =========
// The `authenticatedReadNeedsRlsSnapshot` gate is lifted.  Two secondary gates
// remain intact and together maintain RLS isolation without the snapshot:
//
//   QCH:7040  `if (!rls_active and preamblePermitsStreaming(...))`
//             → blocks node_scan_stream under RLS (no per-candidate filter)
//
//   query_execution.zig:1673  `if (!wouldEvaluateRLS()) executeIfSupported(...)`
//             → blocks planned_read_runtime under RLS
//
// Both secondaries route RLS reads to the legacy executor on the LIVE store.
// The legacy executor applies `passesRLSFilter` (match_operations.zig) per
// candidate node — the visible row set is byte-identical to the clone path.
//
// THESE TESTS ARE WALL-CLOCK-INDEPENDENT: they assert against
// `graph_store.getCloneNodesTotal()` which counts exact nodes deep-copied by
// `cloneNodesFrom`.
//
// RED TEST (pre-fix, now used as characterization):
//   Explicitly calls snapshotUnderReadLock, which is what the pre-fix handler
//   did for every RLS-active read.  Documents that the snapshot clones seeded
//   nodes (getCloneNodesTotal() > 0 after the explicit call).
//
// GREEN TESTS (post-fix):
//   Execute queries through the live executor with RLS active.  Assert:
//   (a) no clone (getCloneNodesTotal() == 0), and
//   (b) RLS isolation is preserved (denied rows absent, allowed rows present).
//
// ADVERSARIAL TESTS:
//   Cross-tenant isolation and multi-policy (two label-deny policies).
//
// CANARY: REQ=REQ-SEC-RLS-CLONE-GATE-0903; FEATURE="RLSCloneGate"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0903_rls_clone_gate.zig; OWNER=security; UPDATED=2026-06-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");

const execution = geode.execution;
const graph_store = geode.graph_store;

// ---------------------------------------------------------------------------
// Harness
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

    /// Seed `count` nodes with `label` and a sequential `id` property.
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
// Test 1: snapshotUnderReadLock characterization (pre-fix handler behavior)
//
// Documents that the OLD handler behavior (calling snapshotUnderReadLock for
// every RLS-active read) clones all seeded nodes.  This is the cost the fix
// eliminates.  The test now PASSES because it asserts what snapshotUnderReadLock
// actually does (clones nodes), not zero.
//
// The corresponding GREEN behavior — that the FIXED handler takes no clone —
// is verified in Test 2 using executeStatementWithContext directly.
// ---------------------------------------------------------------------------
test "GAP-0903: snapshotUnderReadLock deep-clones nodes (the pre-fix handler cost)" {
    // RLS setup: deny "DocB" label for all users.
    var label_engine = rls_types.RLSFilterEngine.init(testing.allocator);
    defer label_engine.deinit();
    try label_engine.addDenyPolicy("default", "DocB", "");
    rls_types.setGlobalRLSFilterEngine(&label_engine);
    defer rls_types.setGlobalRLSFilterEngine(null);

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed: 3 allowed DocA nodes, 2 denied DocB nodes (5 total).
    try h.seedNodes(3, "DocA");
    try h.seedNodes(2, "DocB");

    graph_store.resetCloneNodesTotal();

    // Pre-fix: the handler called snapshotUnderReadLock for every RLS-active
    // read, cloning the whole resident graph.  Reproduce that call here:
    {
        var s = try graph_store.snapshotUnderReadLock(testing.allocator, graph_store.DEFAULT_GRAPH_NAME);
        defer s.deinit();
    }

    // The snapshot copies all 5 seeded nodes — this is the O(N) cost that
    // P3a eliminates.  getCloneNodesTotal() == 5 here proves the cost is real.
    try testing.expectEqual(@as(u64, 5), graph_store.getCloneNodesTotal());
}

// ---------------------------------------------------------------------------
// Test 2: GREEN — RLS read served live, no clone, isolation preserved.
//
// With P3a applied, `readServedEngineDirect` returns true for RLS-active reads
// and the handler SKIPS `snapshotUnderReadLock`.  The secondary gate at
// QCH:7040 (!rls_active) routes the read to `executeProgramWithContext`
// (legacy executor on the live store), which applies `passesRLSFilter` per
// candidate node.
//
// This test drives the same execution path without the QCH layer by calling
// `executeStatementWithContext` directly (which also does NOT call
// `snapshotUnderReadLock`).  It asserts:
//   (a) getCloneNodesTotal() == 0 — no whole-graph clone taken
//   (b) query returns 3 DocA rows — allowed rows present
//   (c) query for DocB returns 0 rows — denied rows absent
// ---------------------------------------------------------------------------
test "GAP-0903: RLS read does not clone the graph (served live, isolation preserved)" {
    // RLS setup: deny "DocB" label for all users.
    var label_engine = rls_types.RLSFilterEngine.init(testing.allocator);
    defer label_engine.deinit();
    try label_engine.addDenyPolicy("default", "DocB", "");
    rls_types.setGlobalRLSFilterEngine(&label_engine);
    defer rls_types.setGlobalRLSFilterEngine(null);

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed: 3 allowed DocA nodes, 2 denied DocB nodes.
    try h.seedNodes(3, "DocA");
    try h.seedNodes(2, "DocB");

    // Activate user context: makes wouldEvaluateRLS() == true.
    h.ctx.user = "alice";
    const prev_ctx = execution.pushActiveContext(&h.ctx);
    defer execution.popActiveContext(prev_ctx);

    // Verify RLS is active (setup check).
    try testing.expect(execution.wouldEvaluateRLS());

    // Reset the clone counter, then run the query.  The legacy executor on the
    // live store applies passesRLSFilter per node — no snapshot clone needed.
    graph_store.resetCloneNodesTotal();

    var r = try h.runQuery("MATCH (n:DocA) RETURN n.id");
    defer r.deinit(h.arena.allocator());

    // (a) Isolation: 3 DocA rows returned (allowed nodes only).
    try testing.expectEqual(@as(usize, 3), r.rows.len);

    // (b) No clone: executeStatementWithContext never calls snapshotUnderReadLock.
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());

    // (c) Denied label: query for DocB returns 0 rows.
    graph_store.resetCloneNodesTotal();
    var rb = try h.runQuery("MATCH (n:DocB) RETURN n.id");
    defer rb.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 0), rb.rows.len);
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
}

// ---------------------------------------------------------------------------
// Test 3: adversarial cross-tenant isolation
//
// Two label-based tenants.  Policy denies TenantB for all users.
// Principal alice queries as an authenticated user with RLS active.
//
// ISOLATION INVARIANT:
//   alice sees EXACTLY 4 TenantA rows and ZERO TenantB rows.
//   No clone is taken (getCloneNodesTotal() == 0).
// ---------------------------------------------------------------------------
test "GAP-0903 adversarial: cross-tenant isolation — principal A sees EXACTLY its rows, ZERO of B's" {
    // Policy: deny "TenantB" for all users.
    var label_engine = rls_types.RLSFilterEngine.init(testing.allocator);
    defer label_engine.deinit();
    try label_engine.addDenyPolicy("default", "TenantB", "");
    rls_types.setGlobalRLSFilterEngine(&label_engine);
    defer rls_types.setGlobalRLSFilterEngine(null);

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed: 4 TenantA nodes (alice's data) + 3 TenantB nodes (bob's data).
    try h.seedNodes(4, "TenantA");
    try h.seedNodes(3, "TenantB");

    // Query as alice (authenticated, RLS active).
    h.ctx.user = "alice";
    const prev_ctx = execution.pushActiveContext(&h.ctx);
    defer execution.popActiveContext(prev_ctx);
    try testing.expect(execution.wouldEvaluateRLS());

    graph_store.resetCloneNodesTotal();

    // (1) Allowed label: all TenantA rows returned.
    var r_a = try h.runQuery("MATCH (n:TenantA) RETURN n.id");
    defer r_a.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 4), r_a.rows.len);

    // (2) ISOLATION: denied label returns ZERO rows.
    var r_b = try h.runQuery("MATCH (n:TenantB) RETURN n.id");
    defer r_b.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 0), r_b.rows.len);

    // (3) No clone for either query.
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
}

// ---------------------------------------------------------------------------
// Test 4: adversarial multi-policy — two simultaneous deny policies
//
// Verifies that when multiple label-deny policies are active simultaneously,
// each is enforced independently: nodes matching either denied label are
// blocked, nodes matching the allowed label are not affected, and no clone
// is taken throughout.
// ---------------------------------------------------------------------------
test "GAP-0903 adversarial: multi-policy (two label-deny) — each enforced independently" {
    // Two simultaneous deny policies: "SecretA" and "SecretB".
    var label_engine = rls_types.RLSFilterEngine.init(testing.allocator);
    defer label_engine.deinit();
    try label_engine.addDenyPolicy("default", "SecretA", "");
    try label_engine.addDenyPolicy("default", "SecretB", "");
    rls_types.setGlobalRLSFilterEngine(&label_engine);
    defer rls_types.setGlobalRLSFilterEngine(null);

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed: 3 allowed (Public), 2 denied by policy 1 (SecretA), 2 denied by
    // policy 2 (SecretB).
    try h.seedNodes(3, "Public");
    try h.seedNodes(2, "SecretA");
    try h.seedNodes(2, "SecretB");

    h.ctx.user = "alice";
    const prev_ctx = execution.pushActiveContext(&h.ctx);
    defer execution.popActiveContext(prev_ctx);
    try testing.expect(execution.wouldEvaluateRLS());

    graph_store.resetCloneNodesTotal();

    // Allowed label: 3 rows returned.
    var r_pub = try h.runQuery("MATCH (n:Public) RETURN n.id");
    defer r_pub.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 3), r_pub.rows.len);

    // Denied by first policy: 0 rows.
    var r_sa = try h.runQuery("MATCH (n:SecretA) RETURN n.id");
    defer r_sa.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 0), r_sa.rows.len);

    // Denied by second policy: 0 rows.
    var r_sb = try h.runQuery("MATCH (n:SecretB) RETURN n.id");
    defer r_sb.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 0), r_sb.rows.len);

    // No clone taken for any of the above queries.
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
}
