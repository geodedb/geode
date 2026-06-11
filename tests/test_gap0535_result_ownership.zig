//! GAP-0535: ExecutionResult value-memory ownership.
//!
//! Before this fix, bare-RETURN projection results were built with
//! `owns_value_memory = false`, so `ExecutionResult.deinit` never freed row
//! values. Allocated values (e.g. the fresh buffer `UPPER('x')` returns)
//! leaked under any strict allocator — the server only stayed leak-free
//! because it executes under a per-request arena (GAP-0755), and the
//! GAP-0868 test had to hide the same leak behind an arena.
//!
//! After the fix, `executeReturnClauseWithEnv` produces rows the result fully
//! OWNS (provably-allocating calls are adopted; everything else — string
//! literals borrowed from the AST, env/param values, store-derived values —
//! is deep-duplicated) and sets `owns_value_memory = true`. The UNION /
//! INTERSECT / EXCEPT combiners were taught to deep-copy values out of owned
//! part results (previously a shallow copy that would have dangled) and to
//! free the values of dropped rows.
//!
//! Every test runs std.testing.allocator end-to-end (parse →
//! executeStatementWithContext → deinit); the zig test runner fails on any
//! leak, which is the regression assertion.
//!
// CANARY: REQ=REQ-EXEC-RESULT-OWNERSHIP-001; FEATURE="ExecutionResultOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0535_result_ownership.zig; OWNER=execution; UPDATED=2026-06-11
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const Value = geode.value_types.Value;

/// Parse + execute a single statement through the full execution path — the
/// same entry the QUIC/gRPC servers use (`executeStatementWithContext`).
/// Identical harness shape to tests/test_gap0866_ts_scalar_eval.zig.
fn runQuery(allocator: std.mem.Allocator, query: []const u8) !execution.ExecutionResult {
    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();

    const catalog = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();
    defer geode.graph_store.deinitGlobalStore();

    const ctx = execution.ExecutionContext{ .catalog = catalog };
    return execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
}

fn expectStrCell(result: execution.ExecutionResult, row: usize, col: usize, expected: []const u8) !void {
    try testing.expect(result.rows.len > row);
    try testing.expect(result.rows[row].len > col);
    try testing.expect(result.rows[row][col] == .Str);
    try testing.expectEqualStrings(expected, result.rows[row][col].Str);
}

test "GAP-0535: RETURN UPPER('x') is leak-free under a strict allocator" {
    var result = try runQuery(testing.allocator, "RETURN UPPER('x') AS u");
    defer result.deinit(testing.allocator);

    try testing.expect(result.owns_value_memory);
    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectStrCell(result, 0, 0, "X");
}

test "GAP-0535: string literal projection is duplicated, not borrowed from the AST" {
    // The AST (and its 'lit' string) is freed inside runQuery before the
    // result is inspected — only an owned duplicate survives that.
    var result = try runQuery(testing.allocator, "RETURN 'lit' AS l");
    defer result.deinit(testing.allocator);

    try testing.expect(result.owns_value_memory);
    try expectStrCell(result, 0, 0, "lit");
}

test "GAP-0535: mixed row (owned call result, duplicated literal, scalar)" {
    var result = try runQuery(testing.allocator, "RETURN UPPER('a') AS u, 'lit' AS l, 1 AS n");
    defer result.deinit(testing.allocator);

    try testing.expect(result.owns_value_memory);
    try testing.expectEqual(@as(usize, 3), result.columns.len);
    try expectStrCell(result, 0, 0, "A");
    try expectStrCell(result, 0, 1, "lit");
    try testing.expect(result.rows[0][2] == .Int);
    try testing.expectEqual(@as(i64, 1), result.rows[0][2].Int);
}

test "GAP-0535: lower()/tolower() projection is adopted as owned" {
    var result = try runQuery(testing.allocator, "RETURN LOWER('ABC') AS l");
    defer result.deinit(testing.allocator);

    try testing.expect(result.owns_value_memory);
    try expectStrCell(result, 0, 0, "abc");
}

test "GAP-0535: UNION ALL of owned arms deep-copies part values (no dangle, no leak)" {
    var result = try runQuery(
        testing.allocator,
        "RETURN UPPER('a') AS x UNION ALL RETURN UPPER('b') AS x",
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.rows.len);
    try expectStrCell(result, 0, 0, "A");
    try expectStrCell(result, 1, 0, "B");
}

test "GAP-0535: UNION DISTINCT frees the dropped duplicate's owned values" {
    var result = try runQuery(
        testing.allocator,
        "RETURN UPPER('a') AS x UNION RETURN UPPER('a') AS x",
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectStrCell(result, 0, 0, "A");
}

// NOTE: standalone `A INTERSECT B` / `A EXCEPT B` statements are NOT wired
// into executeStatementWithContext (pre-existing `error.NotImplemented`,
// independent of GAP-0535) — the executable surface is the parenthesized
// union-tail form (`(A UNION B) EXCEPT C`, REQ-GQL-085), which is what these
// tests drive through executeUnionWithContext's intersect/except arms.

test "GAP-0535: EXCEPT (union-tail) drops owned rows without leaking them" {
    var result = try runQuery(
        testing.allocator,
        "(RETURN UPPER('a') AS x UNION ALL RETURN UPPER('b') AS x) EXCEPT RETURN UPPER('b') AS x",
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectStrCell(result, 0, 0, "A");
}

test "GAP-0535: INTERSECT (union-tail) keeps matching owned rows leak-free" {
    var result = try runQuery(
        testing.allocator,
        "(RETURN UPPER('a') AS x UNION ALL RETURN UPPER('b') AS x) INTERSECT RETURN UPPER('a') AS x",
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectStrCell(result, 0, 0, "A");
}
