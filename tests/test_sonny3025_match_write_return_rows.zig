// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-3025: a plain (neither aggregating nor DISTINCT) RETURN after
// MATCH ... CREATE or MATCH ... MERGE returned ONE row, the last created
// entities or the last MERGE's RETURN, instead of one row per matched row.
// ISO/IEC 39075:2024 14.11 <return statement>: the RETURN is evaluated for
// each record of the working table, which after a MATCH ... CREATE / MERGE
// has one record per matched record, extended with the elements its write
// created or bound.
//
// Run through the SONNY-2672 batch harness (in-memory, persisted,
// tenant-scoped and RLS sessions, leak-checked): the hidden and foreign rows
// of the fixture are matched by none of the statements below.
//
// CANARY: REQ=REQ-SONNY-3025-WRITE-RETURN-ROWS; FEATURE="WriteBehindAggregate"; ASPECT=PlainReturnPerRow; STATUS=TESTED; TEST=tests/test_sonny3025_match_write_return_rows.zig; OWNER=engine; UPDATED=2026-11-12

const std = @import("std");
const batch = @import("read_semantics_batch_harness.zig");

const Case = batch.Case;

const cases = [_]Case{
    // MATCH ... CREATE: matched and created variables, one row per match.
    .{ .q = "MATCH (z:Z) WHERE z.k < 3 CREATE (z)-[:T]->(m:M3 {k: z.k * 10}) RETURN z.k AS zk, m.k AS mk", .want = &.{ "0, 0", "1, 10", "2, 20" } },
    .{ .q = "MATCH (m:M3) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .q = "MATCH (z:Z) WHERE z.k >= 6 CREATE (m:M4 {k: z.k}) RETURN m.k AS k ORDER BY k DESC", .want = &.{ "7", "6" }, .ordered = true },
    .{ .q = "MATCH (q:Q) CREATE (q)-[:T]->(:M6) RETURN q.k AS k", .want = &.{ "0", "1", "2", "3" } },
    .{ .q = "MATCH (q:Q)-[:R]->(x:X) WHERE q.k < 2 CREATE (x)-[r:U {w: q.k}]->(x) RETURN x.k AS k, r.w AS w", .want = &.{ "0, 0", "1, 1" } },
    .{ .q = "MATCH (z:Z) WHERE z.k = 5 CREATE (m:M7 {k: 1}) RETURN z.k AS zk, m.k AS mk LIMIT 1", .want = &.{"5, 1"} },
    // MATCH ... MERGE: the first run creates, the second binds the same nodes.
    .{ .q = "MATCH (z:Z) WHERE z.k < 2 MERGE (m:M5 {k: z.k}) RETURN z.k AS zk, m.k AS mk", .want = &.{ "0, 0", "1, 1" } },
    .{ .q = "MATCH (z:Z) WHERE z.k < 2 MERGE (m:M5 {k: z.k}) RETURN z.k AS zk, m.k AS mk", .want = &.{ "0, 0", "1, 1" } },
    .{ .q = "MATCH (m:M5) RETURN count(*) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (z:Z) WHERE z.k < 4 MERGE (m:M8 {g: z.g}) RETURN z.k AS zk, m.g AS g ORDER BY zk", .want = &.{ "0, 0", "1, 0", "2, 0", "3, 0" }, .ordered = true },
    .{ .q = "MATCH (m:M8) RETURN count(*) AS c", .want = &.{"1"} },
    // A relationship MERGE: its relationship and endpoints are the row's.
    .{ .q = "MATCH (q:Q), (z:Z {k: 0}) WHERE q.k < 2 MERGE (q)-[r:W {w: 1}]->(z) RETURN q.k AS qk, r.w AS w, z.k AS zk", .want = &.{ "0, 1, 0", "1, 1, 0" } },
    .{ .q = "MATCH (q:Q), (z:Z {k: 0}) WHERE q.k < 2 MERGE (q)-[r:W {w: 1}]->(z) RETURN q.k AS qk, r.w AS w", .want = &.{ "0, 1", "1, 1" } },
    .{ .q = "MATCH (:Q)-[r:W]->(:Z) RETURN count(r) AS c", .want = &.{"2"} },
};

test "SONNY-3025: a plain RETURN after MATCH ... CREATE / MERGE is one row per matched row" {
    try batch.inEveryMode("SONNY-3025", &cases);
}
