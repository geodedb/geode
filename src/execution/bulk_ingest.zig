// bulk_ingest.zig — Task 10 / 11 of the enterprise-ingest-throughput plan.
//
// Pattern detection for the msft-graph hot-path CREATE / MATCH+CREATE forms
// so the QUIC connection handler can short-circuit `executeProgramWithContext`
// and call a direct adapter primitive (`bulkInsertNode`) for the simple shape:
//
//     CREATE (n:User { node_id: 'abc-123', name: 'Alice', ... })
//
// The detector is a pure AST predicate — it does NOT allocate, mutate, or
// take any locks.  Callers (`src/server/quic_connection_handler.zig`) invoke
// it after parse, before the write-lock branch, to decide whether to route
// the statement through the fast path or the regular executor.
//
// Task 12 (a separate dispatch) will flesh out the `match_create_edge`
// variant for the edges_*.jsonl files.  For now that variant is declared
// here so callers can exhaustively match, but the matcher always returns
// `.none` for MATCH+CREATE edge shapes — the real detection logic is
// deferred.

const std = @import("std");
const ast = @import("../gql/ast.zig");

/// The set of bulk-ingest shapes we know how to fast-path.  `none` means
/// the statement is not in a fast-path form; callers must fall back to the
/// regular executor.
pub const BulkPattern = enum {
    /// Single top-level `CREATE (n:L {k: literal_or_param, ...})` with no
    /// RETURN, no WHERE/FILTER, and all property values restricted to
    /// literals or parameters.  Dispatched to
    /// `graph_storage_adapter.bulkInsertNode`.
    simple_node_create,

    /// Single top-level `MATCH (a:L1 {...}),(b:L2 {...}) CREATE (a)-[:T]->(b)`
    /// form — the edges_*.jsonl hot-path from msft-graph.  Declared here so
    /// callers can exhaustively switch on `BulkPattern`; the matcher in
    /// `matchSingleStatement` always returns `.none` for this shape today
    /// (Task 12 will add the dispatch + detection together).
    match_create_edge,

    /// Not a bulk-ingest shape; use the regular executor.
    none,
};

/// Inspect `program` and return the bulk-ingest shape we can fast-path, or
/// `.none` if no fast path applies.
///
/// Matching rules for `.simple_node_create`:
///   * Exactly ONE statement in the program, which must be a `CreateStatement`.
///   * The CREATE pattern contains exactly one chain with one node pattern
///     (no relationship hops).
///   * The node pattern has exactly one label (matches the 9,350 msft-graph
///     node-file CREATEs: `(:User {...})`, `(:Device {...})`, etc.).
///   * No RETURN clause (no post-materialisation cost).
///   * Every property value is a literal scalar or a bound parameter — no
///     arithmetic, no function calls, no list/map, no subqueries.
///
/// Any of these preconditions failing drops the statement back to the full
/// executor.  The detector is O(number of properties) and does not allocate.
pub fn matchSingleStatement(program: *const ast.Program) BulkPattern {
    // Exactly one statement in the program.
    if (program.statements.len != 1) return .none;
    const stmt = &program.statements[0];

    switch (stmt.*) {
        .Create => |create_stmt| return classifyCreate(create_stmt),
        else => return .none,
    }
}

fn classifyCreate(c: ast.CreateStatement) BulkPattern {
    // No RETURN — RETURN materialisation is part of the regular executor.
    if (c.return_clause != null) return .none;

    // Exactly one chain in the CREATE pattern.
    if (c.pattern.chains.len != 1) return .none;
    const chain = c.pattern.chains[0];

    // The chain must be a single standalone node (`head` set, `hops.len == 0`).
    if (chain.hops.len != 0) return .none;
    const np = chain.head orelse return .none;

    // Exactly one label.
    if (np.labels.len != 1) return .none;

    // All property values must be scalar (literal or parameter).
    if (np.props) |props| {
        for (props) |p| {
            if (!isScalarPropExpr(p.value.*)) return .none;
        }
    }

    return .simple_node_create;
}

/// True when `e` is a literal or bound parameter — safe to evaluate without
/// the full expression evaluator.  Rejects anything that would require
/// walking the evaluator (arithmetic, function calls, aggregates, etc.).
fn isScalarPropExpr(e: ast.Expr) bool {
    return switch (e) {
        // Plain scalar literals.
        .String,
        .Int,
        .Decimal,
        .Bool,
        .Null,
        .Date,
        .DateTime,
        .Time,
        .LocalDateTime,
        // Typed scalar-literal constructors.
        .SmallIntLit,
        .BigIntLit,
        .RealLit,
        .DoubleLit,
        .CharLit,
        .VarcharLit,
        .TextLit,
        .ByteaLit,
        .JsonLit,
        .JsonbLit,
        .XmlLit,
        .UrlLit,
        .DomainLit,
        .UuidLit,
        .EnumLit,
        .BitLit,
        .VarBitLit,
        // Bound parameter reference (`$name`) — resolved from the
        // `ExecutionContext.query_param_names` array by the caller.
        .Param,
        => true,

        // Everything else (arithmetic, function calls, list literals,
        // map literals, property access, subqueries, CASE, unary
        // negation, ...) must go through the regular executor.
        else => false,
    };
}

// ----------------------------------------------------------------------
// Tests (unit-level smoke — full suite lives in tests/bulk_ingest/).
// ----------------------------------------------------------------------

const testing = std.testing;

test "matchSingleStatement rejects empty program" {
    const program = ast.Program{ .statements = &.{} };
    try testing.expectEqual(BulkPattern.none, matchSingleStatement(&program));
}

test "matchSingleStatement rejects non-Create statement" {
    const stmt = ast.Statement{ .Rollback = {} };
    var stmts = [_]ast.Statement{stmt};
    const program = ast.Program{ .statements = &stmts };
    try testing.expectEqual(BulkPattern.none, matchSingleStatement(&program));
}
