// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-2774: sum() over exact integers. A running total that left the i64
// range continued as a DOUBLE (an exact sum silently became approximate) on
// the shared projection (`sumAddend` / `addInt`) and on the GROUP BY fast
// path (`AggAcc`). ISO/IEC 39075:2024 20.9 <aggregate function>, General
// Rules: the result of SUM over an exact numeric type is exact (ID095), and a
// result outside the range of its declared type raises 22003 (numeric value
// out of range). Both paths now sum in an exact i128 accumulator: a total
// that fits i64 is returned exactly (whatever the intermediate sums were),
// one that does not fails with IntegerOverflow (22003).
//
// Run through the SONNY-2672 batch harness (in-memory, persisted,
// tenant-scoped and RLS sessions, leak-checked). The fixture's `:Big` nodes
// are created by the first cases.
//
// CANARY: REQ=REQ-SONNY-2774-EXACT-SUM; FEATURE="GroupedAggregates"; ASPECT=ExactIntegerSum; STATUS=TESTED; TEST=tests/test_sonny2774_exact_sum.zig; OWNER=execution; UPDATED=2026-11-12

const std = @import("std");
const batch = @import("read_semantics_batch_harness.zig");

const Case = batch.Case;
const max = "9223372036854775807";

const cases = [_]Case{
    .{ .q = "CREATE (:Big {v: " ++ max ++ ", g: 1, h: 1})", .want = &.{} },
    .{ .q = "CREATE (:Big {v: 1, g: 1, h: 2})", .want = &.{} },
    .{ .q = "CREATE (:Big {v: -2, g: 1, h: 3})", .want = &.{} },
    .{ .q = "CREATE (:Big {v: 5, g: 2, h: 4})", .want = &.{} },
    .{ .q = "CREATE (:Big {v: -" ++ max ++ ", g: 3, h: 5})", .want = &.{} },
    .{ .q = "CREATE (:Big {v: -2, g: 3, h: 6})", .want = &.{} },
    // Exact whatever the order the rows are summed in: MAX + 1 - 2.
    .{ .q = "MATCH (b:Big) WHERE b.g = 1 RETURN sum(b.v) AS s", .want = &.{"9223372036854775806"} },
    .{ .q = "MATCH (b:Big {g: 1}) RETURN sum(b.v) AS s", .want = &.{"9223372036854775806"} },
    .{ .q = "MATCH (b:Big) RETURN b.g AS g, sum(b.v) AS s GROUP BY b.g ORDER BY g", .err = error.IntegerOverflow },
    .{ .q = "MATCH (b:Big) WHERE b.g < 3 RETURN b.g AS g, sum(b.v) AS s GROUP BY b.g ORDER BY g", .want = &.{ "1, 9223372036854775806", "2, 5" }, .ordered = true },
    .{ .q = "MATCH (b:Big) WHERE b.g < 3 WITH b.g AS g, sum(b.v) AS s GROUP BY g RETURN g, s ORDER BY g", .want = &.{ "1, 9223372036854775806", "2, 5" }, .ordered = true },
    // Past i64: 22003, on every path.
    .{ .q = "MATCH (b:Big) WHERE b.g = 1 AND b.v > 0 RETURN sum(b.v) AS s", .err = error.IntegerOverflow },
    .{ .q = "MATCH (b:Big {g: 3}) RETURN sum(b.v) AS s", .err = error.IntegerOverflow },
    .{ .q = "MATCH (b:Big) WHERE b.v > 0 RETURN b.g AS g, sum(b.v) AS s GROUP BY b.g", .err = error.IntegerOverflow },
    .{ .q = "MATCH (b:Big) WHERE b.v > 0 WITH sum(b.v) AS s RETURN s", .err = error.IntegerOverflow },
    .{ .q = "MATCH (b:Big) WHERE b.v > 0 RETURN sum(DISTINCT b.v) AS s", .err = error.IntegerOverflow },
    // avg() is approximate: the exact sum is divided, no overflow.
    .{ .q = "MATCH (b:Big) WHERE b.g = 1 AND b.v > 0 RETURN avg(b.v) > 4600000000000000000 AS `big`", .want = &.{"true"} },
    .{ .q = "MATCH (b:Big) WHERE b.g = 1 RETURN avg(b.v) > 3000000000000000000 AS `big`", .want = &.{"true"} },
};

test "SONNY-2774: an exact integer sum is exact, and past i64 it is 22003" {
    try batch.inEveryMode("SONNY-2774", &cases);
}
