// SONNY-6496 item 1: after a WITH (and a NEXT, which runs as a WITH chain)
// only the variables it projects are in scope. ISO/IEC 39075:2024 20.12
// <binding variable reference> SR 8: the incoming working record shall have
// a field of the referenced name; the RETURN before a NEXT, and a WITH,
// define the record the statement after it starts from (9.2 GR 4, 14.10,
// 14.11). A reference to a variable that is not in scope violates a Syntax
// Rule, and 4.7.3 4) e) raises "syntax error or access rule violation"
// (42000) for it before anything runs. Geode read such a variable as NULL:
// `MATCH (n) WITH n.k AS k RETURN n.t` answered NULL rows, `... WITH n.k AS
// k SET n.x = 1` set nothing and answered success, and `WHERE n.t = 'a'`
// after the WITH silently dropped every row.
//
// Checked once, by the statement walk every entry point and transport runs
// before executing (`param_check` / `scope_check`), so the in-memory,
// persisted (planned read), tenant-scoped and RLS-policy sessions all refuse
// the same statements. The accepted cases pin what stays in scope: the
// projected names, `WITH *`, variables a later MATCH, FOR, CALL ... YIELD or
// UNWIND binds, parameters, list-comprehension, quantifier and
// pattern-comprehension locals, and ORDER BY after RETURN reading a variable
// the RETURN does not project (14.10 SR 4 c) i) 2) A) III) 1)).
//
// CANARY: REQ=REQ-SONNY-6496-WITH-SCOPE; FEATURE="LinearComposition"; ASPECT=ProjectionScope; STATUS=TESTED; TEST=tests/test_sonny6496_with_scope.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const out_of_scope = error.VariableNotInScope;

const cases = [_]Case{
    .{ .q = "CREATE (:S6496 {k: 1, t: 'a'}), (:S6496 {k: 2, t: 'b'})" },

    // Refused: a variable the WITH (or the RETURN before NEXT) does not
    // project, in every clause after it.
    .{ .q = "MATCH (n:S6496) WITH n.k AS k RETURN n.t", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k RETURN k, n.t AS t", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k WHERE n.t = 'a' RETURN k", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k RETURN k ORDER BY n.t", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k RETURN count(n) AS c", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k RETURN k, collect(n.t) AS ts", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k MATCH (m:S6496) WHERE m.k = n.k RETURN m.t", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k MATCH (m:S6496 {t: n.t}) RETURN m.k", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k WITH k RETURN n", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k WHERE k IN (MATCH (m:S6496) WHERE m.t = n.t RETURN m.k) RETURN k", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k RETURN [x IN [1, 2] | n.t] AS l", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k FOR x IN [n.k] RETURN x", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k WHERE n:S6496 RETURN k", .err = out_of_scope },
    .{ .q = "WITH 1 AS a RETURN b", .err = out_of_scope },
    .{ .q = "WITH 1 AS a WITH a AS b RETURN a", .err = out_of_scope },
    // NEXT: the RETURN before it is the WITH.
    .{ .q = "MATCH (n:S6496) RETURN n.k AS k NEXT RETURN n.t", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) RETURN n.k AS k NEXT MATCH (m:S6496) WHERE m.t = n.t RETURN m.k", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) RETURN n.k AS k, n.t AS t NEXT YIELD k AS j RETURN t", .err = out_of_scope },
    // Write clauses after the WITH: refused before anything is written.
    .{ .q = "MATCH (n:S6496) WITH n.k AS k SET n.x = 1 RETURN k", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k REMOVE n.t RETURN k", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k DETACH DELETE n", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k CREATE (:S6496c {t: n.t})", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k MERGE (:S6496c {t: n.t})", .err = out_of_scope },
    .{ .q = "MATCH (n:S6496) WHERE n.x IS NOT NULL OR n.t IS NULL RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (n:S6496) RETURN count(*) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (c:S6496c) RETURN count(*) AS c", .want = &.{"0"} },

    // Accepted: what is in scope after the WITH.
    .{ .q = "MATCH (n:S6496) WITH n.k AS k RETURN k", .want = &.{ "1", "2" } },
    .{ .q = "MATCH (n:S6496) WITH n RETURN n.t AS t ORDER BY n.k", .want = &.{ "'a'", "'b'" }, .ordered = true },
    .{ .q = "MATCH (n:S6496) WITH * RETURN n.t AS t", .want = &.{ "'a'", "'b'" } },
    .{ .q = "MATCH (n:S6496) WITH * WHERE n.k > 1 RETURN n.t AS t ORDER BY n.k", .want = &.{"'b'"} },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k, n.t AS t RETURN t ORDER BY k DESC", .want = &.{ "'b'", "'a'" }, .ordered = true },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k MATCH (n:S6496) WHERE n.k = k RETURN n.t AS t", .want = &.{ "'a'", "'b'" } },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k WHERE k > $min RETURN k", .params = &.{.{ .name = "min", .value = .{ .Int = 1 } }}, .want = &.{"2"} },
    .{ .q = "MATCH (n:S6496) WITH collect(n.k) AS ks RETURN [x IN ks WHERE x > 1 | x * 10] AS l", .want = &.{"[20]"} },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k RETURN all(x IN [k] WHERE x > 0) AS q", .want = &.{ "true", "true" } },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k FOR x IN [k, k * 10] RETURN x", .want = &.{ "1", "10", "2", "20" } },
    .{ .q = "MATCH (n:S6496) WITH count(*) AS c RETURN c", .want = &.{"2"} },
    .{ .q = "MATCH (n:S6496) WITH n.k AS k WITH k + 1 AS j RETURN j", .want = &.{ "2", "3" } },
    .{ .q = "MATCH (n:S6496) RETURN n.k AS k ORDER BY n.t DESC", .want = &.{ "2", "1" }, .ordered = true },
    .{ .q = "MATCH (n:S6496) RETURN n.k AS k, n.t AS t NEXT YIELD k AS j RETURN j", .want = &.{ "1", "2" } },
    .{ .q = "MATCH (n:S6496) RETURN n.k AS k NEXT MATCH (m:S6496) WHERE m.k = k RETURN m.t AS t", .want = &.{ "'a'", "'b'" } },
    .{ .q = "WITH 1 AS a WITH a AS b RETURN b", .want = &.{"1"} },
    .{ .q = "MATCH (n:S6496) WITH n, n.k AS k RETURN n.t AS t, k", .want = &.{ "'a', 1", "'b', 2" } },
};

test "SONNY-6496: after WITH and NEXT only the projected variables are in scope, in every session" {
    try harness.inEveryMode("SONNY-6496 WITH scope", &cases);
}
