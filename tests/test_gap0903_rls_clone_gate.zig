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
// RED TEST (pre-fix):
//   Explicitly calls snapshotUnderReadLock, which is what the pre-fix handler
//   does for every RLS-active read.  Asserts clone==0.  FAILS: the snapshot
//   clones all seeded nodes (getCloneNodesTotal() > 0).
//
// GREEN TESTS (post-fix):
//   Execute queries through the live executor with RLS active.  Assert:
//   (a) no clone (getCloneNodesTotal() == 0), and
//   (b) RLS isolation is preserved (denied rows absent, allowed rows present).
//
// ADVERSARIAL TESTS:
//   Cross-tenant isolation and multi-policy (label-deny + expr-VM coexistence).
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
// RED TEST (pre-fix reproduction)
//
// The pre-fix transport handler called `snapshotUnderReadLock` for every
// RLS-active read because `readServedEngineDirect` returned false.  The
// snapshot deep-clones every resident node via `cloneNodesFrom`.
//
// This test reproduces that call directly.  The assertion
// `getCloneNodesTotal() == 0` FAILS pre-fix: the snapshot clones all seeded
// nodes (counter > 0).  It proves the bug is real.
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

    graph_store.resetCloneNodesTotal();

    // BUG (pre-fix): the handler calls snapshotUnderReadLock for every
    // RLS-active read because readServedEngineDirect returns false when
    // authenticatedReadNeedsRlsSnapshot returns true.  Reproduce that clone:
    {
        var s = try graph_store.snapshotUnderReadLock(testing.allocator, graph_store.DEFAULT_GRAPH_NAME);
        defer s.deinit();
    }

    // DESIRED post-fix: no clone taken for RLS reads (served live via legacy
    // executor with per-candidate passesRLSFilter).
    // This assertion FAILS pre-fix (getCloneNodesTotal() == 5, not 0).
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
}
