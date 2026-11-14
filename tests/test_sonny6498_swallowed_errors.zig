// SONNY-6498 item 3: an expression that fails to evaluate fails the
// statement, on every executor path. ISO/IEC 39075:2024 19.1 GR 1 (and the
// statement's exception semantics, 4.7.3): an exception condition raised
// while a <value expression> is evaluated is the statement's; it is not the
// null value, a skipped row or a kept row. The legacy executor's paths caught
// it at about forty sites: an inline property map that failed matched
// nothing (`MATCH (n {k: 1/0})` answered no rows), a WHERE on a relationship
// or variable-length pattern was false, an aggregate skipped the row whose
// argument failed (and the chained-part aggregate folded integers only), a
// grouping key or a non-aggregated item was NULL.
//
// Three exceptions (division by zero 22012, integer overflow 22003, a type
// error in a function argument) through every shape that reached such a
// site, in the in-memory, persisted, tenant-scoped and RLS-policy sessions.
// Sites whose swallowing stays (a pushdown pre-filter or a seek-key
// precomputation that falls back to the full predicate) are covered by the
// shapes that reach them: the error surfaces from the predicate itself.
//
// CANARY: REQ=REQ-SONNY-6498-EVAL-ERRORS-RAISE; FEATURE="ExpressionEvaluation"; ASPECT=ErrorsFailStatement; STATUS=TESTED; TEST=tests/test_sonny6498_swallowed_errors.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

/// One exception: an expression raising it over a row (`n` is a :S6498
/// node with k = 1 or 2 and g = 'a' or 'b'), one with no variable, and the
/// error.
const Failure = struct { row: []const u8, lit: []const u8, err: anyerror };

const failures = [_]Failure{
    .{ .row = "n.k / 0", .lit = "1 / 0", .err = error.DivisionByZero },
    .{ .row = "n.k + 9223372036854775807", .lit = "9223372036854775807 + 1", .err = error.IntegerOverflow },
    .{ .row = "vector_l2([1.0, n.g], [1.0, 2.0])", .lit = "vector_l2([1.0, 'x'], [1.0, 2.0])", .err = error.TypeMismatch },
};

/// Every shape, `@R` the row expression, `@L` the literal one.
const shapes = [_][]const u8{
    // The projection and WHERE of a node pattern (the shared projection).
    "MATCH (n:S6498) RETURN @R AS x",
    "MATCH (n:S6498) WHERE @R > 0 RETURN n.k AS k",
    // An inline property map with no variable.
    "MATCH (n:S6498 {k: @L}) RETURN n.k AS k",
    "MATCH (n:S6498 {k: @L})-[:R6498]->(t:S6498T) RETURN t.k AS k",
    // A single hop: WHERE and RETURN.
    "MATCH (n:S6498)-[r:R6498]->(t:S6498T) WHERE @R > 0 RETURN t.k AS k",
    "MATCH (n:S6498)-[r:R6498]->(t:S6498T) RETURN @R AS x",
    // A variable-length path.
    "MATCH (n:S6498)-[:R6498*1..2]->(t) WHERE @R > 0 RETURN t.k AS k",
    // A comma pattern: an aggregate's argument, a grouping key, a property
    // map that reads another pattern's variable.
    "MATCH (n:S6498), (t:S6498T) RETURN sum(@R) AS s",
    "MATCH (n:S6498), (t:S6498T) RETURN @R AS g, count(*) AS c GROUP BY g",
    "MATCH (n:S6498), (t:S6498T {k: @R}) RETURN t.k AS k",
    // OPTIONAL MATCH's own WHERE.
    "MATCH (n:S6498) OPTIONAL MATCH (n)-[:R6498]->(t) WHERE @R > 0 RETURN t",
    // Chains: a final aggregate, an aggregating WITH after the first part,
    // its grouping key, and an aggregate over a hop in the last part.
    "MATCH (n:S6498) WITH n MATCH (t:S6498T) RETURN sum(@R) AS s",
    "MATCH (n:S6498) WITH n WITH n.g AS g, sum(@R) AS s RETURN g, s",
    "MATCH (n:S6498) WITH n WITH @R AS g, count(*) AS c RETURN g, c",
    "MATCH (n:S6498) WITH n WITH n, n.k AS k MATCH (t:S6498T) RETURN count(@R) AS c",
    // shortestPath with an inline property map.
    "MATCH p = shortestPath((n:S6498 {k: @L})-[*]-(t:S6498T)) RETURN length(p) AS l",
};

fn subst(comptime s: []const u8, comptime from: []const u8, comptime to: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var i: usize = 0;
        while (i < s.len) {
            if (std.mem.startsWith(u8, s[i..], from)) {
                out = out ++ to;
                i += from.len;
            } else {
                out = out ++ s[i .. i + 1];
                i += 1;
            }
        }
        return out;
    }
}

/// What the same shapes answer when nothing fails (the planned read
/// filtered a comma pattern's chain with no variable bound, so a property
/// value that read another chain's variable matched nothing).
const valid = [_]Case{
    .{ .q = "MATCH (n:S6498), (t:S6498T {k: n.k}) RETURN t.k AS k", .want = &.{"1"} },
    .{ .q = "MATCH (n:S6498) WITH n WITH n.g AS g, sum(n.k * 1.5) AS s RETURN g, s > 1.0 AS big", .want = &.{ "'a', true", "'b', true" } },
    .{ .q = "MATCH (n:S6498) WITH n WITH n.g AS g, max(n.g) AS m RETURN g, m", .want = &.{ "'a', 'a'", "'b', 'b'" } },
};

const cases = blk: {
    @setEvalBranchQuota(100_000);
    var out: [1 + valid.len + shapes.len * failures.len]Case = undefined;
    out[0] = .{ .q = "CREATE (:S6498 {k: 1, g: 'a'})-[:R6498 {w: 1}]->(:S6498T {k: 1}), (:S6498 {k: 2, g: 'b'})" };
    for (valid, out[1 .. 1 + valid.len]) |v, *o| o.* = v;
    var i: usize = 1 + valid.len;
    for (shapes) |shape| for (failures) |f| {
        out[i] = .{ .q = subst(subst(shape, "@R", f.row), "@L", f.lit), .err = f.err };
        i += 1;
    };
    break :blk out;
};

test "SONNY-6498: an expression that fails fails the statement, on every executor path and session" {
    try harness.inEveryMode("SONNY-6498 swallowed evaluation errors", &cases);
}
