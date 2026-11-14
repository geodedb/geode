// SONNY-6525 item 2: a reference to a variable nothing binds is refused in
// every clause of a statement, not only after a WITH or NEXT.
//
// ISO/IEC 39075:2024 20.12 <binding variable reference> SR 8: the incoming
// working record of the reference shall have a field of its name; a
// statement starts with an empty working record (14.1 <linear query
// statement>: the variables in scope are those its earlier statements bind).
// A reference to any other name violates a Syntax Rule, which 4.7.3 4) e)
// answers with "syntax error or access rule violation" (42000) before
// anything runs. SONNY-6496 refused such a reference after a projection
// only; before the first one it read NULL: `MATCH (n) RETURN m` answered a
// NULL row per node, `MATCH (n) WHERE m.k = 1` no rows, `CREATE (:A {k:
// m.k})` created a node without k.
//
// The accepted cases pin what is in scope: every variable of the MATCH
// (forward references inside one pattern list, OPTIONAL MATCH, a path
// variable), a pattern predicate's own variables, FOR and CALL { }
// bindings, RETURN aliases in ORDER BY, `*`.
//
// Every case in the in-memory, persisted, tenant-scoped and RLS-policy
// sessions.
//
// CANARY: REQ=REQ-SONNY-6525-STATEMENT-SCOPE; FEATURE="LinearComposition"; ASPECT=StatementScope; STATUS=TESTED; TEST=tests/test_sonny6525_statement_scope.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const out_of_scope = error.VariableNotInScope;

const cases = [_]Case{
    .{ .q = "CREATE (:U6525 {k: 1})-[:R6525]->(:U6525 {k: 2})-[:R6525]->(:U6525 {k: 3})" },

    // Refused: a name nothing before it binds.
    .{ .q = "MATCH (n:U6525) RETURN m", .err = out_of_scope },
    .{ .q = "MATCH (n:U6525) RETURN n.k AS k, m.k AS j", .err = out_of_scope },
    .{ .q = "MATCH (n:U6525) WHERE m.k = 1 RETURN n.k", .err = out_of_scope },
    .{ .q = "MATCH (n:U6525) RETURN n.k AS k ORDER BY m.k", .err = out_of_scope },
    .{ .q = "MATCH (n:U6525) RETURN count(m) AS c", .err = out_of_scope },
    .{ .q = "MATCH (n:U6525) WHERE n.k IN (MATCH (o:U6525) WHERE o.k = m.k RETURN o.k) RETURN n.k", .err = out_of_scope },
    .{ .q = "MATCH (n:U6525 {k: m.k}) RETURN n.k", .err = out_of_scope },
    .{ .q = "RETURN m", .err = out_of_scope },
    .{ .q = "FOR x IN [1] RETURN y", .err = out_of_scope },
    .{ .q = "MATCH (n:U6525) RETURN n.k AS k UNION MATCH (n:U6525) RETURN m.k AS k", .err = out_of_scope },
    // A RETURN alias is not in scope in the WHERE before it.
    .{ .q = "MATCH (n:U6525) WHERE k > 0 RETURN n.k AS k", .err = out_of_scope },
    // A parameter is `$name`; a bare name is a variable (it read the
    // parameter of that name).
    .{ .q = "MATCH (n:U6525) WHERE n.k = lo RETURN n.k AS k", .params = &.{.{ .name = "lo", .value = harness.int(1) }}, .err = out_of_scope },
    // Write clauses: refused before anything is written.
    .{ .q = "MATCH (n:U6525) SET n.x = m.k", .err = out_of_scope },
    .{ .q = "MATCH (n:U6525) SET m.x = 1", .err = out_of_scope },
    .{ .q = "MATCH (n:U6525) DETACH DELETE m", .err = out_of_scope },
    .{ .q = "CREATE (:U6525c {k: m.k})", .err = out_of_scope },
    .{ .q = "MERGE (:U6525c {k: m.k})", .err = out_of_scope },
    .{ .q = "MATCH (n:U6525) WHERE n.x IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (n:U6525) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .q = "MATCH (c:U6525c) RETURN count(*) AS c", .want = &.{"0"} },

    // Accepted: what is in scope.
    .{ .q = "MATCH (a:U6525)-[:R6525]->(b), (b)-[:R6525]->(c) RETURN a.k AS a, c.k AS c", .want = &.{"1, 3"} },
    .{ .q = "MATCH (b)-[:R6525]->(c:U6525 {k: 3}), (a:U6525)-[:R6525]->(b) RETURN a.k AS a", .want = &.{"1"} },
    .{ .q = "MATCH (a:U6525 {k: 3}) OPTIONAL MATCH (a)-[:R6525]->(b) RETURN a.k AS a, b.k AS b", .want = &.{"3, null"} },
    .{ .q = "MATCH (a:U6525) WHERE EXISTS { MATCH (a)-[:R6525]->(x) WHERE x.k > 2 } RETURN a.k AS a", .want = &.{"2"} },
    .{ .q = "MATCH (a:U6525) RETURN a.k AS k ORDER BY k DESC", .want = &.{ "3", "2", "1" }, .ordered = true },
    .{ .q = "MATCH (a:U6525) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .q = "MATCH p = (a:U6525 {k: 1})-[:R6525]->(b) RETURN length(p) AS l", .want = &.{"1"} },
    .{ .q = "FOR x IN [1, 2] RETURN x", .want = &.{ "1", "2" } },
    .{ .q = "CALL { MATCH (a:U6525) RETURN a.k AS k } RETURN k", .want = &.{ "1", "2", "3" } },
    .{ .q = "MATCH (a:U6525 {k: 1}) RETURN [y IN [10] | a.k + y] AS l", .want = &.{"[11]"} },
    .{ .q = "MATCH (a:U6525) WHERE a.k >= $lo RETURN a.k AS k", .params = &.{.{ .name = "lo", .value = harness.int(3) }}, .want = &.{"3"} },
    .{ .q = "MATCH (a:U6525 {k: 1}) RETURN a.k AS k NEXT RETURN k", .want = &.{"1"} },
    .{ .q = "MATCH (a:U6525 {k: 1}) RETURN a.k AS k UNION MATCH (a:U6525 {k: 2}) RETURN a.k AS k", .want = &.{ "1", "2" } },
    .{ .q = "MATCH (a:U6525 {k: 1})-[:R6525]->(b) RETURN b.k + a.k AS s", .want = &.{"3"} },
};

test "SONNY-6525: a variable nothing binds is refused in every clause, in every session" {
    try harness.inEveryMode("SONNY-6525 statement scope", &cases);
}
