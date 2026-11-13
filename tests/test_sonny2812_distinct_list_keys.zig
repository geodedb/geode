// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-2812: count(DISTINCT) and collect(DISTINCT) kept the list properties
// [1] and [1.0] apart while RETURN DISTINCT, WITH DISTINCT and GROUP BY
// merged them. ISO/IEC 39075:2024 20.9 <aggregate function>: with DISTINCT,
// a value is added to VALUES only when it is not already there (22.15
// "Grouping operations": the same equality as grouping), so the DISTINCT
// aggregates, DISTINCT and GROUP BY key a value the same way: numbers by
// their exact value, inside a list too (`distinct_set.writeGroupKeyPart`).
//
// Already fixed on this branch: the keying is the shared DistinctSet's on
// every session since the legacy executor's aggregates go through the shared
// projection (c7a8fbe1, SONNY-2734). This pins it. (A WITH projecting, or a
// GROUP BY keyed by, a list property leaks the list on every session; that
// is a separate defect, reported with SONNY-2812, and not exercised here.)
//
// Run through the SONNY-2672 batch harness (in-memory, persisted,
// tenant-scoped and RLS sessions, leak-checked). The `:L` nodes are created
// by the first cases.
//
// CANARY: REQ=REQ-SONNY-2812-DISTINCT-LIST-KEYS; FEATURE="AggregateSetQuantifier"; ASPECT=ListKeys; STATUS=TESTED; TEST=tests/test_sonny2812_distinct_list_keys.zig; OWNER=execution; UPDATED=2026-11-12

const std = @import("std");
const batch = @import("read_semantics_batch_harness.zig");

const Case = batch.Case;

const cases = [_]Case{
    .{ .q = "CREATE (:L {v: [1], g: 1})", .want = &.{} },
    .{ .q = "CREATE (:L {v: [1.0], g: 1})", .want = &.{} },
    .{ .q = "CREATE (:L {v: [2, 3], g: 1})", .want = &.{} },
    .{ .q = "CREATE (:L {v: [2.0, 3], g: 2})", .want = &.{} },
    .{ .q = "CREATE (:L {v: ['1'], g: 2})", .want = &.{} },
    // Three values: [1] = [1.0], [2, 3] = [2.0, 3], ['1'].
    .{ .q = "MATCH (n:L) RETURN count(DISTINCT n.v) AS c", .want = &.{"3"} },
    .{ .q = "MATCH (n:L) RETURN size(collect(DISTINCT n.v)) AS c", .want = &.{"3"} },
    .{ .q = "MATCH (n:L) RETURN n.g AS g, count(DISTINCT n.v) AS c GROUP BY n.g ORDER BY g", .want = &.{ "1, 2", "2, 2" }, .ordered = true },
    .{ .q = "MATCH (n:L) RETURN n.g AS g, size(collect(DISTINCT n.v)) AS c GROUP BY n.g ORDER BY g", .want = &.{ "1, 2", "2, 2" }, .ordered = true },
};

test "SONNY-2812: DISTINCT aggregates key list values as DISTINCT and GROUP BY do" {
    try batch.inEveryMode("SONNY-2812", &cases);
}
