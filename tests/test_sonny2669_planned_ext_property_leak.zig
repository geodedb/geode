// SONNY-2669 regression: reads of an extended property (BYTEA, JSON) free
// the evaluated copy, on the planned read (persisted) and on the legacy
// executor (in-memory, tenant-scoped, RLS-policy), each statement on its own
// leak-checking allocator with and without a query scratch arena: RETURN
// n.<ext>, a WHERE and an inline property map on it, an ORDER BY beside it,
// and a HAVING whose hidden collect() holds it (the ticket's widened scope:
// `HavingFilter.passesGroup` never freed its slot values).
//
// The member read of an extended value is lent from the statement's scratch
// arena (SONNY-6449, `eval.lentValueAllocator`) and predicates run on a
// per-row arena (SONNY-2670, SONNY-2656), so these cases pass on this branch
// and pin it.
//
// CANARY: REQ=REQ-SONNY-2669-PLANNED-EXT-PROPERTY-LEAK; FEATURE="PlannedReadStorageReads"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2669_planned_ext_property_leak.zig; OWNER=engine; UPDATED=2026-11-13

const h = @import("statement_leak_harness.zig");

const visible = [_][]const u8{
    "CREATE (:E {s: 'e0', b: Bytea('\\\\x0102ff'), j: Json('{\"a\": 1}')})",
    "CREATE (:E {s: 'e1', b: Bytea('\\\\x0103ff'), j: Json('{\"a\": 2}')})",
    "CREATE (:P {k: 0})-[:R]->(:E {s: 'e2', b: Bytea('\\\\x01'), j: Json('{\"a\": 3}')})",
};

const hidden = [_][]const u8{
    "CREATE (:E{H} {s: 'h', b: Bytea('\\\\xff'), j: Json('{\"a\": 1}')})",
};

const cases = [_]h.Case{
    .{ .q = "MATCH (n:E) RETURN n.b AS b", .want = &.{ "<Bytea>", "<Bytea>", "<Bytea>" } },
    .{ .q = "MATCH (n:E) RETURN n.j AS j", .want = &.{ "<Json>", "<Json>", "<Json>" } },
    .{ .q = "MATCH (n:E) RETURN n.s, n.b ORDER BY n.s", .ordered = true, .want = &.{ "'e0', <Bytea>", "'e1', <Bytea>", "'e2', <Bytea>" } },
    .{ .q = "MATCH (n:E) WHERE n.b IS NOT NULL RETURN n.s", .want = &.{ "'e0'", "'e1'", "'e2'" } },
    .{ .q = "MATCH (n:E) WHERE n.j = Json('{\"a\": 1}') RETURN n.s", .want = &.{"'e0'"} },
    .{ .q = "MATCH (n:E {j: Json('{\"a\": 2}')}) RETURN n.s", .want = &.{"'e1'"} },
    .{ .q = "MATCH (a:P)-[:R]->(n:E) RETURN n.b AS b, n.s AS s", .want = &.{"<Bytea>, 'e2'"} },
    .{ .q = "MATCH (n:E) RETURN n.s AS s, count(*) AS c GROUP BY n.s HAVING size(collect(n.b)) > 0", .want = &.{ "'e0', 1", "'e1', 1", "'e2', 1" } },
    .{ .q = "MATCH (n:E) WITH n.b AS b RETURN count(b) AS c", .want = &.{"3"} },
};

test "SONNY-2669: extended property reads free their evaluated copies, planned and legacy" {
    try h.inEveryMode("SONNY-2669", &visible, &hidden, &cases);
}
