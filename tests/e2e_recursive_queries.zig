// CANARY: REQ=REQ-GQL-CTE-005; FEATURE="CTEExecution"; ASPECT=Evaluator; STATUS=TESTED; TEST=tests/e2e_recursive_queries.zig:1; OWNER=execution; UPDATED=2026-06-10
//
// GAP-0859: REAL end-to-end coverage for the recursive `WITH RECURSIVE` CTE
// fixpoint executor (`executeCTE` in src/execution/query_execution.zig).
//
// The prior version of this file drove a parallel, never-wired
// `src/planner/recursive.zig` `RecursiveQueryProcessor` API with `undefined`
// query bodies and asserted `error.NotImplemented` — it tested neither the
// real parser nor the real executor, and used pre-0.16 Zig syntax
// (`@intCast(i64, i)`, `std.ArrayList(...).init`). It was excluded from the
// aggregate build and rotted. These tests run actual GQL text through
// `geode.parseGql` + `execution.executeStatementWithContext`, the same path the
// QUIC server uses, and assert the produced rows.
//
// CONTRACT verified here (the real `executeCTE` fixpoint evaluator):
//   * The recursive term self-references the CTE working set as a bound
//     `Value.List` of `Value.Map`; the term consumes it with `UNWIND <cte> AS x`.
//   * A `WHERE` predicate in the recursive term IS applied per row (GAP-0859
//     defect: the UNWIND path previously dropped `q.where_clause`, so a
//     WHERE-bounded recursion never terminated by predicate and silently ran
//     to the iteration cap).
//   * `UNION ALL` keeps every produced row; `UNION` deduplicates against the
//     accumulated set (which terminates a cycle that toggles among already-seen
//     rows).
//   * A hard iteration cap of 100 guarantees a cyclic `UNION ALL` recursion
//     terminates (does NOT hang) even with no predicate or dedup.
//   * The main query reads the CTE result as the bound list value (`RETURN cte`).
//
// Residual / not covered here: the recursive term operates on the working-set
// LIST, not directly on graph nodes; modeling graph reachability is done by
// encoding the successor relation in the recursive term (increment / CASE).
// Driving a recursive CTE off live MATCH-ed graph edges is a separate,
// unverified path (see docs/GQL_COMPLIANCE.md).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const execution = geode.execution;
const Value = geode.protocol.Value;

// ---------------------------------------------------------------------------
// Harness: real parser + real executor, no graph store needed (recursive CTEs
// in the verified form operate over list values, not graph data).
// ---------------------------------------------------------------------------
const Harness = struct {
    arena: std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        // The catalog instance is process-global and freed by
        // cleanupCatalogInstance() with the same allocator it was created with,
        // so it must come from the long-lived test allocator, NOT the arena.
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .ctx = .{ .catalog = catalog } };
    }

    fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        self.arena.deinit();
    }

    fn run(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    // A recursive CTE binds its result as a single-cell `Value.List` of
    // `Value.Map`. `RETURN <cte>` yields exactly one row, one column, whose
    // value is that list. Pull out the list of maps for assertion.
    fn cteList(self: *Harness, query: []const u8) ![]Value {
        const res = try self.run(query);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(@as(usize, 1), res.rows[0].len);
        return switch (res.rows[0][0]) {
            .List => |l| l,
            else => error.ExpectedList,
        };
    }
};

// Extract integer values for the given map key, in list order.
fn intColumn(allocator: std.mem.Allocator, list: []const Value, key: []const u8) ![]i64 {
    var out = try std.ArrayList(i64).initCapacity(allocator, list.len);
    for (list) |el| {
        switch (el) {
            .Map => |m| {
                if (m.get(key)) |v| {
                    switch (v) {
                        .Int => |i| try out.append(allocator, i),
                        .SmallInt => |i| try out.append(allocator, i),
                        .BigInt => |i| try out.append(allocator, i),
                        else => return error.NonIntColumn,
                    }
                }
            },
            else => return error.ExpectedMap,
        }
    }
    return out.toOwnedSlice(allocator);
}

fn containsInt(haystack: []const i64, needle: i64) bool {
    for (haystack) |h| if (h == needle) return true;
    return false;
}

// ===========================================================================
// (a) Transitive closure / reachability over a 1 -> 2 -> 3 -> 4 chain.
// Reachability from node 1 (excluding self) must yield {2, 3, 4}.
// The recursive term walks the successor relation (n -> n+1) bounded by the
// chain length; the anchor is the first hop (node 2).
// ===========================================================================
test "GAP-0859 (a): recursive reachability over a 1->2->3->4 chain yields {2,3,4}" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const list = try h.cteList(
        \\WITH RECURSIVE reach AS (
        \\  RETURN 2 AS node
        \\  UNION
        \\  UNWIND reach AS r WHERE r.node < 4 RETURN r.node + 1 AS node
        \\) RETURN reach
    );

    const nodes = try intColumn(h.arena.allocator(), list, "node");
    try testing.expectEqual(@as(usize, 3), nodes.len);
    try testing.expect(containsInt(nodes, 2));
    try testing.expect(containsInt(nodes, 3));
    try testing.expect(containsInt(nodes, 4));
    // Node 1 (self / source) must NOT be in the reachable-from-1 set.
    try testing.expect(!containsInt(nodes, 1));
    // Must not over-run past the end of the chain.
    try testing.expect(!containsInt(nodes, 5));
}

// Reachability with explicit edge transitions encoded via CASE (anchor = source
// node 1). Verifies the recursive term can compute an arbitrary successor, not
// just an arithmetic increment.
test "GAP-0859 (a'): CASE-encoded edge transitions reach the full chain {1,2,3,4}" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const list = try h.cteList(
        \\WITH RECURSIVE reach AS (
        \\  RETURN 1 AS node
        \\  UNION
        \\  UNWIND reach AS r WHERE r.node < 4
        \\    RETURN CASE r.node WHEN 1 THEN 2 WHEN 2 THEN 3 WHEN 3 THEN 4 ELSE -1 END AS node
        \\) RETURN reach
    );

    const nodes = try intColumn(h.arena.allocator(), list, "node");
    try testing.expectEqual(@as(usize, 4), nodes.len);
    inline for (.{ 1, 2, 3, 4 }) |want| try testing.expect(containsInt(nodes, want));
    try testing.expect(!containsInt(nodes, -1));
}

// ===========================================================================
// (b) Bounded-depth recursion: a WHERE predicate in the recursive term must
// terminate the fixpoint BEFORE the iteration cap.  This is the GAP-0859
// regression: pre-fix, the UNWIND execution path ignored `q.where_clause`, so
// this produced 101 rows (anchor + 100 cap iterations) instead of 5.
// ===========================================================================
test "GAP-0859 (b): WHERE-bounded recursion terminates by predicate (n=1..5)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const list = try h.cteList(
        \\WITH RECURSIVE nums AS (
        \\  RETURN 1 AS n
        \\  UNION ALL
        \\  UNWIND nums AS prev WHERE prev.n < 5 RETURN prev.n + 1 AS n
        \\) RETURN nums
    );

    const ns = try intColumn(h.arena.allocator(), list, "n");
    // Exactly 1..5 — proves the predicate (not the cap) ended the recursion.
    try testing.expectEqual(@as(usize, 5), ns.len);
    for (ns, 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(i + 1)), v);
}

// ===========================================================================
// (c) Cycle termination via the iteration cap.  A UNION ALL recursion that
// toggles 1 <-> 2 forever (no predicate, no dedup) MUST NOT hang — the hard
// cap of 100 iterations bounds it.  We assert it returns a finite, capped
// result rather than hanging the test process.
// ===========================================================================
test "GAP-0859 (c): cyclic UNION ALL recursion terminates at the iteration cap" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // anchor n=1; step: n -> 3 - n  (1->2->1->2->...). No WHERE, no dedup.
    const list = try h.cteList(
        \\WITH RECURSIVE c AS (
        \\  RETURN 1 AS n
        \\  UNION ALL
        \\  UNWIND c AS prev RETURN 3 - prev.n AS n
        \\) RETURN c
    );

    const ns = try intColumn(h.arena.allocator(), list, "n");
    // anchor (1) + 100 capped iterations = 101 rows; bounded, did not hang.
    try testing.expectEqual(@as(usize, 101), ns.len);
    // Every value is in the 2-cycle {1, 2}.
    for (ns) |v| try testing.expect(v == 1 or v == 2);
}

// ===========================================================================
// (d) UNION vs UNION ALL distinct semantics.  The SAME cyclic recursion under
// UNION (distinct) dedups against the accumulated set, so once both 1 and 2
// have been seen no new rows are produced and the fixpoint terminates with
// exactly {1, 2}.  This contrasts (c)'s 101 rows under UNION ALL.
// ===========================================================================
test "GAP-0859 (d): UNION (distinct) dedups and terminates a cycle at {1,2}" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const list = try h.cteList(
        \\WITH RECURSIVE c AS (
        \\  RETURN 1 AS n
        \\  UNION
        \\  UNWIND c AS prev RETURN 3 - prev.n AS n
        \\) RETURN c
    );

    const ns = try intColumn(h.arena.allocator(), list, "n");
    try testing.expectEqual(@as(usize, 2), ns.len);
    try testing.expect(containsInt(ns, 1));
    try testing.expect(containsInt(ns, 2));
}

// SONNY-738: UNION drops a row that is not distinct from one it has
// (ISO/IEC 39075:2024 22.12): 1.0 is not distinct from 1. The dedup compared
// representations, so 1.0 never matched the anchor's 1 (nor, a decimal, its
// own earlier copy) and the recursion ran to the cap: 101 rows.
test "SONNY-738: UNION dedups numbers by value (1.0 is a duplicate of 1)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const list = try h.cteList(
        \\WITH RECURSIVE c AS (
        \\  RETURN 1 AS n
        \\  UNION
        \\  UNWIND c AS prev RETURN 1.0 AS n
        \\) RETURN c
    );
    try testing.expectEqual(@as(usize, 1), list.len);
}

// UNION ALL keeps duplicate-valued rows from converging steps; UNION would
// collapse them. Anchor 1, increment-while-<3 step yields {1,2,3} with UNION
// ALL (no duplicates produced here, but the path keeps every emitted row).
test "GAP-0859 (d'): UNION ALL bounded recursion keeps every produced row" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const list = try h.cteList(
        \\WITH RECURSIVE d AS (
        \\  RETURN 1 AS n
        \\  UNION ALL
        \\  UNWIND d AS prev WHERE prev.n < 3 RETURN prev.n + 1 AS n
        \\) RETURN d
    );

    const ns = try intColumn(h.arena.allocator(), list, "n");
    try testing.expectEqual(@as(usize, 3), ns.len);
    for (ns, 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(i + 1)), v);
}

// ===========================================================================
// Simple (non-recursive) CTE sanity: a `WITH name AS (...)` binds its body
// result as a list value reachable from the main query.
// ===========================================================================
test "GAP-0859: simple (non-recursive) CTE binds body result as a list value" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const list = try h.cteList("WITH x AS (RETURN 7 AS n) RETURN x");
    const ns = try intColumn(h.arena.allocator(), list, "n");
    try testing.expectEqual(@as(usize, 1), ns.len);
    try testing.expectEqual(@as(i64, 7), ns[0]);
}
