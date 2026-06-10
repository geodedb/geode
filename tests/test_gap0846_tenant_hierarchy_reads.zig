// CANARY: REQ=REQ-GAP-0846-TENANT-HIERARCHY-READS; FEATURE="TenantHierarchyReadEnforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0846_tenant_hierarchy_reads.zig:1; OWNER=security; UPDATED=2026-06-09
//
// Regression tests for GAP-0846: "Tenant hierarchy not consulted in live read
// paths".
//
// Background
// ----------
// GAP-0838 re-keyed `rls_core.HierarchyManager` on the string `tenant_id` and
// GAP-0839 added the `CALL geode.tenant.create(child, parent)` production seam
// that populates it. But the LIVE query read path (`match_operations.zig`) only
// ever did an EXACT `std.mem.eql(node.tenant_id, session_tenant)` comparison, so
// a parent-scoped session could NOT see its descendants' rows even though the
// documented hierarchy semantics (`HierarchyManager.canAccessTenant`) grant
// ancestor-or-self access. The hierarchy was "registry-populated but never
// consulted".
//
// Documented hierarchy semantics (preserved from the original u64 impl, see
// rls_core.zig:canAccessTenant): an accessor can access a target iff the
// accessor's path is a prefix of the target's path — i.e. the accessor is an
// ANCESTOR-OR-SELF of the target. So:
//   * parent  -> child   : ALLOWED (parent reads descendant rows)
//   * child   -> parent  : DENIED  (descendant does NOT read ancestor rows)
//   * sibling -> sibling : DENIED  (no common-prefix relationship)
//   * self    -> self    : ALLOWED (exact match — the fast path)
//
// Storage-level label-index decision (the load-bearing design choice)
// -------------------------------------------------------------------
// `store.getNodesByLabels(..., tenant)` and `store.getEdgesByType(..., tenant, ..)`
// filter by EXACT tenant_id INSIDE the index walk. If we passed the session's
// tenant straight through, a hierarchy-GRANTED descendant row would be dropped
// at the storage layer and never reach the per-row filter — a silent
// under-fetch. The fix (`match_operations.storageTenantFilter`) passes `null`
// (scan all candidates) to those storage primitives ONLY when a hierarchy is
// provisioned AND the session tenant participates in it; the now-hierarchy-aware
// per-row `passesTenantFilter` then does the ancestor-or-self filtering. When no
// hierarchy exists, the exact-match storage filter is preserved verbatim
// (GAP-0509 isolation + zero overhead). The count fast-path bails to the regular
// row executor under an active hierarchy so the count includes descendant rows.
//
// These tests drive the REAL parse -> execute pipeline
// (`execution.executeStatementWithContext`) against the global store with a
// live, populated expr-RLS engine — no mocks.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");

const graph_store = geode.graph_store;
const execution = geode.execution;
const tenancy = geode.tenancy;
const query_arena = geode.query_arena;

// ---------------------------------------------------------------------------
// Harness — global store + catalog + a populated, globally-published expr-RLS
// engine whose HierarchyManager we provision.
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
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    engine: *rls.RLSEngine,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        // GAP-0846 read path keys off the legacy permissive default; ensure the
        // process-wide strict flag is reset so a prior test does not bleed in.
        tenancy.setStrictTenancy(false);

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);

        const engine = try allocator.create(rls.RLSEngine);
        errdefer allocator.destroy(engine);
        engine.* = try rls.RLSEngine.init(allocator);
        rls_types.setGlobalExprRLSEngine(@ptrCast(engine));

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .engine = engine,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        rls_types.setGlobalExprRLSEngine(null);
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn ctxForTenant(self: *const Harness, tenant_id: ?[]const u8) execution.ExecutionContext {
        var c = self.ctx;
        c.tenant_id = tenant_id;
        return c;
    }

    /// Provision a tenant in the hierarchy (production seam is the same call
    /// `CALL geode.tenant.create` uses).
    fn addTenant(self: *Harness, tenant_id: []const u8, parent: ?[]const u8) !void {
        try self.engine.hierarchy_manager.addTenant(tenant_id, parent);
    }

    /// Summary of a read query — only what the assertions need. The full
    /// ExecutionResult holds Node values whose interior strings are arena-backed
    /// (see runMatch); we copy the scalars out before tearing the arena down.
    const MatchSummary = struct {
        row_count: usize,
        first_int: ?i64,
    };

    /// Run a read query under a tenant-scoped context through the real executor.
    ///
    /// Production runs every query against a per-request arena allocator (the
    /// QUIC/gRPC handler passes its arena as the executor `allocator`), so the
    /// legacy `match_operations` executor's per-row scratch (env arrays, owned
    /// node interiors) is reclaimed in bulk when the arena is torn down — those
    /// sites do not individually free. This harness mirrors that exactly: run
    /// the query against a fresh arena allocator, copy out the scalar
    /// assertions, then tear the arena down. This keeps the test leak-free under
    /// the GPA leak checker WITHOUT changing any production code path. (Using
    /// the raw GPA here would surface a long-standing, production-masked
    /// arena-reclaimed allocation in the legacy executor, unrelated to GAP-0846.)
    fn runMatch(self: *const Harness, allocator: std.mem.Allocator, query: []const u8, tenant: ?[]const u8) !MatchSummary {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();

        const prev_scratch = query_arena.pushScratchAllocator(aa);
        defer query_arena.popScratchAllocator(prev_scratch);

        const ctx = self.ctxForTenant(tenant);
        var res = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
        defer res.deinit(aa);

        const first_int: ?i64 = if (res.rows.len > 0 and res.rows[0].len > 0)
            switch (res.rows[0][0]) {
                .Int => |i| i,
                else => null,
            }
        else
            null;
        return .{ .row_count = res.rows.len, .first_int = first_int };
    }
};

// ---------------------------------------------------------------------------
// 1. Direct choke-point semantics — canAccessTenant drives parent/child/sibling.
// ---------------------------------------------------------------------------

test "GAP-0846 (semantics): canAccessTenant grants ancestor-or-self, denies sibling/descendant-up" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // org -> { unit_a -> eng_a1, unit_b }
    try h.addTenant("org", null);
    try h.addTenant("unit_a", "org");
    try h.addTenant("unit_b", "org");
    try h.addTenant("eng_a1", "unit_a");

    const hm = &h.engine.hierarchy_manager;

    // Parent reaches descendants and self.
    try testing.expect(try hm.canAccessTenant("org", "org"));
    try testing.expect(try hm.canAccessTenant("org", "unit_a"));
    try testing.expect(try hm.canAccessTenant("org", "eng_a1"));
    try testing.expect(try hm.canAccessTenant("unit_a", "eng_a1"));

    // Descendant does NOT reach ancestor.
    try testing.expect(!(try hm.canAccessTenant("eng_a1", "unit_a")));
    try testing.expect(!(try hm.canAccessTenant("unit_a", "org")));

    // Siblings do not reach each other.
    try testing.expect(!(try hm.canAccessTenant("unit_a", "unit_b")));
    try testing.expect(!(try hm.canAccessTenant("unit_b", "unit_a")));

    // canAccessTenantSafe turns unknown tenants into a deny, not an error.
    try testing.expect(!hm.canAccessTenantSafe("org", "ghost_tenant"));
    try testing.expect(!hm.canAccessTenantSafe("ghost", "org"));
}

// ---------------------------------------------------------------------------
// 2. Live read path: parent sees descendant rows (full-scan + label-indexed).
// ---------------------------------------------------------------------------

test "GAP-0846 (read): parent-scoped MATCH sees its own + descendant rows; sibling stays isolated" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // org -> { unit_a -> eng_a1, unit_b (sibling) }
    try h.addTenant("org", null);
    try h.addTenant("unit_a", "org");
    try h.addTenant("unit_b", "org");
    try h.addTenant("eng_a1", "unit_a");

    const store = graph_store.getGlobalStore(allocator);
    const labels = [_][]const u8{"Widget"};
    // 1 org-owned, 1 unit_a-owned, 1 eng_a1-owned (descendant of unit_a), 2 unit_b (sibling).
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "org");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "unit_a");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "eng_a1");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "unit_b");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "unit_b");

    // --- Label-indexed path: MATCH (n:Widget) RETURN n ---
    // org (root) sees everything reachable: org + unit_a + eng_a1 + unit_b*2 = 5.
    try testing.expectEqual(@as(usize, 5), (try h.runMatch(allocator, "MATCH (n:Widget) RETURN n", "org")).row_count);
    // unit_a sees itself + descendant eng_a1 = 2 (NOT org above it, NOT sibling unit_b).
    try testing.expectEqual(@as(usize, 2), (try h.runMatch(allocator, "MATCH (n:Widget) RETURN n", "unit_a")).row_count);
    // sibling unit_b sees ONLY its own 2 rows (cross-tenant leak regression).
    try testing.expectEqual(@as(usize, 2), (try h.runMatch(allocator, "MATCH (n:Widget) RETURN n", "unit_b")).row_count);
    // leaf eng_a1 sees ONLY its own 1 row (descendant cannot read ancestor).
    try testing.expectEqual(@as(usize, 1), (try h.runMatch(allocator, "MATCH (n:Widget) RETURN n", "eng_a1")).row_count);
}

// ---------------------------------------------------------------------------
// 3. Full-scan (unlabeled) path is hierarchy-aware too.
// ---------------------------------------------------------------------------

test "GAP-0846 (read): unlabeled full-scan MATCH honours hierarchy" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.addTenant("org", null);
    try h.addTenant("unit_a", "org");
    try h.addTenant("unit_b", "org");

    const store = graph_store.getGlobalStore(allocator);
    const labels = [_][]const u8{"Doc"};
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "org");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "unit_a");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "unit_b");

    // unlabeled scan from org: 3 (all reachable).
    try testing.expectEqual(@as(usize, 3), (try h.runMatch(allocator, "MATCH (n) RETURN n", "org")).row_count);
    // unlabeled scan from unit_a: 1 (only itself; org is an ancestor, unit_b a sibling).
    try testing.expectEqual(@as(usize, 1), (try h.runMatch(allocator, "MATCH (n) RETURN n", "unit_a")).row_count);
}

// ---------------------------------------------------------------------------
// 4. count() fast-path is hierarchy-aware (parent count includes descendants).
// ---------------------------------------------------------------------------

test "GAP-0846 (count): count(n) reflects hierarchy-granted descendant rows" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.addTenant("org", null);
    try h.addTenant("unit_a", "org");
    try h.addTenant("unit_b", "org");

    const store = graph_store.getGlobalStore(allocator);
    const labels = [_][]const u8{"Item"};
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "org");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "unit_a");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "unit_a");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "unit_b");

    {
        // org count: org(1) + unit_a(2) + unit_b(1) = 4.
        const r = try h.runMatch(allocator, "MATCH (n:Item) RETURN count(n)", "org");
        try testing.expectEqual(@as(usize, 1), r.row_count);
        try testing.expectEqual(@as(i64, 4), r.first_int.?);
    }
    {
        // unit_a count: only its own 2 (cannot see org ancestor or unit_b sibling).
        const r = try h.runMatch(allocator, "MATCH (n:Item) RETURN count(n)", "unit_a");
        try testing.expectEqual(@as(usize, 1), r.row_count);
        try testing.expectEqual(@as(i64, 2), r.first_int.?);
    }
}

// ---------------------------------------------------------------------------
// 5. GAP-0509 fast path preserved: with NO hierarchy provisioned, exact-match
//    isolation is unchanged (a tenant sees ONLY its own rows, never a sibling's).
// ---------------------------------------------------------------------------

test "GAP-0846 (no-hierarchy): exact-match isolation preserved when hierarchy is empty" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // NOTE: deliberately do NOT call addTenant — hierarchy stays empty, so the
    // exact-match fast path must hold (GAP-0509 regression guard).
    try testing.expectEqual(@as(usize, 0), h.engine.hierarchy_manager.count());

    const store = graph_store.getGlobalStore(allocator);
    const labels = [_][]const u8{"Secret"};
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_alpha");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_alpha");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_beta");

    try testing.expectEqual(@as(usize, 2), (try h.runMatch(allocator, "MATCH (n:Secret) RETURN n", "tenant_alpha")).row_count);
    try testing.expectEqual(@as(usize, 1), (try h.runMatch(allocator, "MATCH (n:Secret) RETURN n", "tenant_beta")).row_count);
}

// ---------------------------------------------------------------------------
// 6. GAP-0846 FOLLOW-UP (cross-tenant leak): the relaxed `storageTenantFilter`
//    label-index scan MUST be re-filtered per-row at EVERY label-indexed site,
//    not just `executeMatchQueryImpl`. These tests drive the OTHER executors
//    (multi-pattern, relationship, multi-chain, CALL/CREATE match) that previously
//    fetched all tenants' rows and applied only `passesRLSFilter`.
//
//    Each was PROVEN red against the pre-follow-up code: a sibling tenant saw
//    other siblings' rows. The multi-pattern test in particular returned 4 rows
//    (cartesian P×Q over the leaked set) instead of 1 for `unit_a` under the
//    org->{unit_a,unit_b} hierarchy.
// ---------------------------------------------------------------------------

test "GAP-0846 follow-up (multi-pattern leak): MATCH (a:P),(b:Q) is sibling-isolated" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // org -> { unit_a, unit_b }
    try h.addTenant("org", null);
    try h.addTenant("unit_a", "org");
    try h.addTenant("unit_b", "org");

    const store = graph_store.getGlobalStore(allocator);
    const p_labels = [_][]const u8{"P"};
    const q_labels = [_][]const u8{"Q"};

    // unit_a: 1 P + 1 Q ; unit_b (sibling): 1 P + 1 Q.
    _ = try store.createNodeWithGraphAndTenant(&p_labels, "default", "unit_a");
    _ = try store.createNodeWithGraphAndTenant(&q_labels, "default", "unit_a");
    _ = try store.createNodeWithGraphAndTenant(&p_labels, "default", "unit_b");
    _ = try store.createNodeWithGraphAndTenant(&q_labels, "default", "unit_b");

    // unit_a: exactly its own P×Q = 1×1 = 1 row.
    // PRE-FIX (executeMultiNodeMatch leaked): unit_a saw both P's and both Q's,
    // so the cartesian product was 2×2 = 4 — the proven cross-tenant leak.
    try testing.expectEqual(
        @as(usize, 1),
        (try h.runMatch(allocator, "MATCH (a:P), (b:Q) RETURN a, b", "unit_a")).row_count,
    );
    // sibling unit_b: symmetric — only its own product = 1.
    try testing.expectEqual(
        @as(usize, 1),
        (try h.runMatch(allocator, "MATCH (a:P), (b:Q) RETURN a, b", "unit_b")).row_count,
    );
    // parent org: sees both children's P (2) × both children's Q (2) = 4.
    try testing.expectEqual(
        @as(usize, 4),
        (try h.runMatch(allocator, "MATCH (a:P), (b:Q) RETURN a, b", "org")).row_count,
    );
}

test "GAP-0846 follow-up (relationship leak): MATCH (a)-[r:T]->(b) is sibling-isolated" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.addTenant("org", null);
    try h.addTenant("unit_a", "org");
    try h.addTenant("unit_b", "org");

    const store = graph_store.getGlobalStore(allocator);
    const a_labels = [_][]const u8{"A"};
    const b_labels = [_][]const u8{"B"};

    // unit_a: A -[T]-> B (1 edge).
    const a1 = try store.createNodeWithGraphAndTenant(&a_labels, "default", "unit_a");
    const b1 = try store.createNodeWithGraphAndTenant(&b_labels, "default", "unit_a");
    _ = try store.createEdgeWithGraphAndTenant(a1, b1, "T", "default", "unit_a");

    // unit_b (sibling): A -[T]-> B (1 edge).
    const a2 = try store.createNodeWithGraphAndTenant(&a_labels, "default", "unit_b");
    const b2 = try store.createNodeWithGraphAndTenant(&b_labels, "default", "unit_b");
    _ = try store.createEdgeWithGraphAndTenant(a2, b2, "T", "default", "unit_b");

    // Left-label-anchored relationship scan (executeMultiChainRelationshipMatch
    // left_labels site + passesTenantFilterEdge + right endpoint check).
    // unit_a: exactly its own 1 edge; PRE-FIX the left anchor leaked unit_b's A.
    try testing.expectEqual(
        @as(usize, 1),
        (try h.runMatch(allocator, "MATCH (a:A)-[r:T]->(b:B) RETURN a, r, b", "unit_a")).row_count,
    );
    try testing.expectEqual(
        @as(usize, 1),
        (try h.runMatch(allocator, "MATCH (a:A)-[r:T]->(b:B) RETURN a, r, b", "unit_b")).row_count,
    );
    // parent org: both edges reachable.
    try testing.expectEqual(
        @as(usize, 2),
        (try h.runMatch(allocator, "MATCH (a:A)-[r:T]->(b:B) RETURN a, r, b", "org")).row_count,
    );

    // Right-label-only anchored scan (the right_labels site at ~2835 which
    // PRE-FIX fetched the anchor with NO tenant filter at all): anchor on B.
    try testing.expectEqual(
        @as(usize, 1),
        (try h.runMatch(allocator, "MATCH (a)-[r:T]->(b:B) RETURN a, r, b", "unit_a")).row_count,
    );
    try testing.expectEqual(
        @as(usize, 1),
        (try h.runMatch(allocator, "MATCH (a)-[r:T]->(b:B) RETURN a, r, b", "unit_b")).row_count,
    );

    // Edge-type-only scan (getEdgesByType site at ~2894 — already safe, regression guard).
    try testing.expectEqual(
        @as(usize, 1),
        (try h.runMatch(allocator, "MATCH (a)-[r:T]->(b) RETURN a, r, b", "unit_a")).row_count,
    );
}

test "GAP-0846 follow-up (multi-chain leak): two relationship chains are sibling-isolated" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.addTenant("org", null);
    try h.addTenant("unit_a", "org");
    try h.addTenant("unit_b", "org");

    const store = graph_store.getGlobalStore(allocator);
    const c_labels = [_][]const u8{"C"};
    const d_labels = [_][]const u8{"D"};

    // unit_a: C -[E]-> D.
    const c1 = try store.createNodeWithGraphAndTenant(&c_labels, "default", "unit_a");
    const d1 = try store.createNodeWithGraphAndTenant(&d_labels, "default", "unit_a");
    _ = try store.createEdgeWithGraphAndTenant(c1, d1, "E", "default", "unit_a");

    // unit_b (sibling): C -[E]-> D.
    const c2 = try store.createNodeWithGraphAndTenant(&c_labels, "default", "unit_b");
    const d2 = try store.createNodeWithGraphAndTenant(&d_labels, "default", "unit_b");
    _ = try store.createEdgeWithGraphAndTenant(c2, d2, "E", "default", "unit_b");

    // Two independent chains -> executeMultiChainRelationshipMatch first chain
    // plus the multi-chain init label-index sites. unit_a: 1×1 = 1.
    try testing.expectEqual(
        @as(usize, 1),
        (try h.runMatch(allocator, "MATCH (c1:C)-[:E]->(d1:D), (c2:C)-[:E]->(d2:D) RETURN c1, d2", "unit_a")).row_count,
    );
    try testing.expectEqual(
        @as(usize, 1),
        (try h.runMatch(allocator, "MATCH (c1:C)-[:E]->(d1:D), (c2:C)-[:E]->(d2:D) RETURN c1, d2", "unit_b")).row_count,
    );
}

test "GAP-0846 follow-up (CREATE match leak): MATCH ... CREATE source is sibling-isolated" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.addTenant("org", null);
    try h.addTenant("unit_a", "org");
    try h.addTenant("unit_b", "org");

    const store = graph_store.getGlobalStore(allocator);
    const src_labels = [_][]const u8{"Src"};

    // unit_a: 1 Src ; unit_b (sibling): 2 Src.
    _ = try store.createNodeWithGraphAndTenant(&src_labels, "default", "unit_a");
    _ = try store.createNodeWithGraphAndTenant(&src_labels, "default", "unit_b");
    _ = try store.createNodeWithGraphAndTenant(&src_labels, "default", "unit_b");

    // Direct exercise of executeMatchCreateQuery (site ~1455): the matched source
    // set drives the per-match CREATE, so the number of RETURN'd created rows
    // equals the number of matched sources. unit_a must match exactly its own 1
    // Src; PRE-FIX the label-index match leaked unit_b's 2 siblings -> 3 CREATE
    // rows. We assert exactly 1 row (1 source -> 1 created node returned).
    try testing.expectEqual(
        @as(usize, 1),
        (try h.runMatch(allocator, "MATCH (s:Src) CREATE (t:SrcCopy) RETURN t", "unit_a")).row_count,
    );
}
