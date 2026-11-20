// SONNY-6297 (error paths), SONNY-738 query-memory sweep: every
// representative statement shape is run with its N-th allocation failing,
// for N = 0, 1, ... until a run reaches no failure
// (`statement_leak_harness.sweep`), on the in-memory, persisted,
// tenant-scoped and RLS-policy sessions. Each run's result allocator and
// statement scratch arena share one fault-injecting allocator over a
// leak-checking one, so a value, a row, a column name or a scratch arena an
// error path drops fails the case, and so does an allocation failure
// answered with any error but OutOfMemory. No mocks: every run is the real
// executor.
//
// CANARY: REQ=REQ-SONNY-6297-ALLOCATION-FAILURE-SWEEP; FEATURE="ExecutionResultOwnership"; ASPECT=ErrorPathOwnership; STATUS=TESTED; TEST=tests/test_sonny6297_allocation_failure_sweep.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const h = @import("statement_leak_harness.zig");

const visible = [_][]const u8{
    "CREATE (:Z {g: 0, k: 0})",
    "CREATE (:Z {g: 1, k: 1})",
    "CREATE (:Z {g: 0, k: 2})",
    "CREATE (:A {i: 0, s: 'a0', v: ['x', 'y']})",
    "CREATE (:A {i: 1, s: 'a1', v: ['x']})",
    "CREATE (:P {k: 0, s: 'p0'})-[:R {w: 1}]->(:Q {k: 0, s: 'q0'})-[:R {w: 2}]->(:X {k: 0})",
};

const hidden = [_][]const u8{
    "CREATE (:A{H} {i: 9, s: 'h'})",
};

pub const shapes = [_][]const u8{
    // Plain projection, computed items.
    "MATCH (n:A) RETURN n.s AS s, n.i AS i",
    "MATCH (n:A) RETURN n.s || '!' AS x, toString(n.i) AS t",
    // Map, list, keys(), collect().
    "MATCH (n:A) RETURN {a: n.i, b: n.s} AS m, [n.s, n.i] AS l, keys(n) AS k",
    "MATCH (n:A) RETURN collect(n.s) AS c, count(*) AS n",
    // WITH chains, an aggregating WITH, an aggregating WITH then a WITH.
    "MATCH (n:A) WITH n.s || '?' AS x WHERE x <> 'z' RETURN x ORDER BY x",
    "MATCH (z:Z) WITH z.g AS g, sum(z.k) AS s RETURN g, s",
    "MATCH (z:Z) WITH z.g AS g, sum(z.k) AS s WITH g, s RETURN g, s",
    // OPTIONAL MATCH, a single hop, a variable-length path.
    "MATCH (n:A) OPTIONAL MATCH (n)-[:R]->(m) RETURN n.s, m",
    "MATCH (a:P)-[r:R]->(b:Q) RETURN a.s, r.w, b.s",
    "MATCH (a:P)-[:R*1..2]->(b) RETURN a.s, b.k",
    // FOR, CALL ... YIELD.
    "FOR k IN [toString(1), 'b'] RETURN k",
    "MATCH (n:A {i: 0}) CALL db.labels() YIELD label RETURN n.s, label",
    // Write steps: SET, REMOVE, MERGE.
    "MATCH (n:A {i: 0}) SET n.t = n.s || '-x' RETURN n.t",
    "MATCH (n:A {i: 0}) REMOVE n.t RETURN n.s",
    "MERGE (m:M {k: 1}) ON CREATE SET m.s = 'c' ON MATCH SET m.s = 'm' RETURN m.s",
    // SONNY-6525: a correlated IN subquery (run per row, on the row) and an
    // uncorrelated one (run once, its result kept for the statement).
    "MATCH (z:Z) WHERE z.k IN (MATCH (y:Z) WHERE y.g = z.g RETURN y.k) RETURN z.k",
    "MATCH (z:Z) WHERE z.k IN (MATCH (y:Z) WHERE y.g = 0 RETURN y.k) RETURN z.k",
    // PROFILE, EXPLAIN.
    "PROFILE MATCH (n:A) RETURN n.s",
    "EXPLAIN MATCH (n:A) RETURN n.s",
};

/// The most runs one shape may take (its allocation count bounds it).
const max_runs = 6000;

fn sweepAll(mode: h.Mode) !void {
    var s = try h.Session.init(mode);
    defer s.deinit();
    try s.seed(&visible, &hidden);
    var failures: usize = 0;
    for (shapes) |q| {
        const r = try h.sweep(&s, q, &.{}, max_runs);
        const bad = r.leaks.items.len > 0 or r.wrong_errors.items.len > 0 or !r.completed;
        if (bad) {
            failures += 1;
            std.debug.print("[{s}] {s}: {d} runs, completed={}, leaks at {any}, wrong errors {d}\n", .{ @tagName(mode), q, r.runs, r.completed, r.leaks.items[0..@min(8, r.leaks.items.len)], r.wrong_errors.items.len });
            for (r.wrong_errors.items[0..@min(4, r.wrong_errors.items.len)]) |we| std.debug.print("    failure at allocation {d} answered {s}\n", .{ we[0], @errorName(we[1]) });
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6297: every shape frees what it built when any allocation fails: in memory" {
    try sweepAll(.in_memory);
}

test "SONNY-6297: every shape frees what it built when any allocation fails: persisted" {
    try sweepAll(.persisted);
}

test "SONNY-6297: every shape frees what it built when any allocation fails: tenant-scoped" {
    try sweepAll(.tenant_scoped);
}

test "SONNY-6297: every shape frees what it built when any allocation fails: RLS policy" {
    try sweepAll(.rls_policy);
}
