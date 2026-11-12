// Still-red reproductions from the SONNY-2672 read-semantics batch
// (tests/test_sonny2672_read_semantics_batch.zig, same fixture and four
// sessions). Intentionally RED: this artifact is only compiled
// (`test-compile`), not run by the aggregate `zig build test`; see
// docs/KNOWN_TEST_ISSUES.md. Run it with
// `zig build test-sonny2672-read-semantics-red`. A case moves to the green
// file in the commit that fixes it.
//
// CANARY: REQ=REQ-SONNY-2672-READ-SEMANTICS-RED; FEATURE="ReadSemanticsBatch"; ASPECT=KnownRed; STATUS=IMPL; TEST=tests/test_sonny2672_read_semantics_red.zig; OWNER=engine; UPDATED=2026-11-12

const batch = @import("test_sonny2672_read_semantics_batch.zig");
const Case = batch.Case;
const overflow = batch.overflow;

// SONNY-2779: the standalone CALL ignores its RETURN clause (and so a YIELD
// alias), and MATCH ... CALL ... YIELD binds no MATCH variable and leaks.
const sonny2779 = [_]Case{
    .{ .q = "CALL db.labels() YIELD label AS l RETURN l ORDER BY l DESC LIMIT 1", .want = &.{"'Z'"}, .columns = &.{"l"} },
    .{ .q = "CALL db.labels() YIELD label AS l RETURN l AS m ORDER BY m DESC LIMIT 1", .want = &.{"'Z'"}, .columns = &.{"m"} },
    .{ .q = "MATCH (q:Q {k: 0}) CALL db.labels() YIELD label RETURN q.k AS k, label ORDER BY label DESC LIMIT 1", .want = &.{"0, 'Z'"} },
    .{ .q = "MATCH (q:Q) WHERE q.k < 2 CALL db.labels() YIELD label RETURN q.k AS k, label ORDER BY label DESC, k LIMIT 2", .want = &.{ "0, 'Z'", "1, 'Z'" }, .ordered = true },
};

// SONNY-3128: ORDER BY a property after CREATE ... RETURN is a syntax error
// even with the server's parse options.
const sonny3128 = [_]Case{
    .{ .q = "CREATE (n:W {i: 1}) RETURN n.i AS i ORDER BY n.i", .want = &.{"1"} },
};

// SONNY-2811: an error in a WITH's ORDER BY key is still hidden.
const sonny2811 = [_]Case{
    .{ .q = "MATCH (z:Z) WITH z ORDER BY z.k + " ++ overflow ++ " RETURN z.k AS k", .err = error.IntegerOverflow },
};

test "SONNY-2779 (red): CALL's RETURN clause, YIELD alias, MATCH ... CALL" {
    try batch.inEveryMode("SONNY-2779", &sonny2779);
}

test "SONNY-3128 (red): ORDER BY a property after CREATE ... RETURN" {
    try batch.inEveryMode("SONNY-3128", &sonny3128);
}

test "SONNY-2811 (red): an error in a WITH's ORDER BY key" {
    try batch.inEveryMode("SONNY-2811", &sonny2811);
}
