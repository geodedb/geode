// SONNY-6525 item 4: an aggregating WITH in the middle of a chain groups by
// typed keys and reads the statement's parameters.
//
// The chain executor's intermediate aggregating WITH (`query_execution.zig`
// `executeQueryChain`) keyed its groups by `formatValue`, text that renders
// 1 and '1' (and 1 and 1.0, and every value it has no text for) alike, so
// they were one group; ISO/IEC 39075:2024 groups values that are not
// distinct (4.4.3, 22.12 <determination of distinct values>): 1 and '1'
// are distinct, and so are 'null' and the null value. It also
// evaluated the keys and aggregates without the statement's parameters, so
// `$m` read NULL. It now keys groups as every other grouping site does
// (`distinct_set.writeGroupKeyPart`) and passes the parameters.
//
// Every case in the in-memory, persisted, tenant-scoped and RLS-policy
// sessions.
//
// CANARY: REQ=REQ-SONNY-6525-WITH-GROUP-KEYS; FEATURE="ChainedWithAggregation"; ASPECT=TypedGroupKeys; STATUS=TESTED; TEST=tests/test_sonny6525_with_group_keys.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    .{ .q = "CREATE (:W6525 {g: 1, k: 1}), (:W6525 {g: '1', k: 2}), (:W6525 {g: 1, k: 4}), (:W6525 {g: 'null', k: 8}), (:W6525 {k: 16})" },

    // 1 and '1' are two groups; 'null' and NULL are two groups.
    .{ .q = "MATCH (z:W6525) WITH z.g AS g, sum(z.k) AS s WITH g, s RETURN g, s", .want = &.{ "1, 5", "'1', 2", "'null', 8", "null, 16" } },
    .{ .q = "MATCH (z:W6525) WITH z.g AS g, count(*) AS c WITH g, c WHERE c > 0 RETURN count(*) AS groups", .want = &.{"4"} },
    // A parameter in a grouping key and in an aggregate.
    .{ .q = "MATCH (z:W6525) WITH z.k * $m AS km, count(*) AS c WITH km, c RETURN km, c", .params = &.{.{ .name = "m", .value = harness.int(10) }}, .want = &.{ "10, 1", "20, 1", "40, 1", "80, 1", "160, 1" } },
    .{ .q = "MATCH (z:W6525) WITH z.g AS g, sum(z.k * $m) AS s WITH g, s WHERE g = 1 RETURN s", .params = &.{.{ .name = "m", .value = harness.int(10) }}, .want = &.{"50"} },
    // The aggregating WITH after a first part (the chain executor's
    // intermediate path).
    .{ .q = "MATCH (z:W6525) WITH z WITH z.g AS g, sum(z.k) AS s WITH g, s RETURN g, s", .want = &.{ "1, 5", "'1', 2", "'null', 8", "null, 16" } },
    .{ .q = "MATCH (z:W6525) WITH z WITH z.k * $m AS km, count(*) AS c WITH km, c RETURN km, c", .params = &.{.{ .name = "m", .value = harness.int(10) }}, .want = &.{ "10, 1", "20, 1", "40, 1", "80, 1", "160, 1" } },
    .{ .q = "MATCH (z:W6525) WITH z WITH z.g AS g, sum(z.k * $m) AS s WITH g, s WHERE g = 1 RETURN s", .params = &.{.{ .name = "m", .value = harness.int(10) }}, .want = &.{"50"} },
};

test "SONNY-6525: an intermediate aggregating WITH groups by typed keys and reads the parameters, in every session" {
    try harness.inEveryMode("SONNY-6525 WITH group keys", &cases);
}
