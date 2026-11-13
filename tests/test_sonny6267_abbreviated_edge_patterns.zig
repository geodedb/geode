// SONNY-6267: `MATCH (a)<--(b)` failed with UnexpectedToken while `-->` and
// the bracketed forms parsed. Decided against ISO/IEC 39075:2024:
//
// - 16.7 <abbreviated edge pattern> is one of seven tokens: <left arrow>
//   `<-`, <tilde> `~`, <right arrow> `->`, <left arrow tilde> `<~`, <tilde
//   right arrow> `~>`, <left minus right> `<->` and <minus sign> `-`. Each
//   is "effectively replaced" by the empty full edge pattern of the same
//   orientation (16.7 SR: `<-` is `<-[ ]-`, `-` is `-[ ]-`, `<->` is
//   `<-[ ]->`). Features G044 (`-`, `<-`, `->`) and G045 (the others).
// - `<--` is not one of them, and 16.7 SR forbids it: a token that exposes a
//   minus sign on the right (`<-`, `]-`, `-`) must not be juxtaposed with one
//   that exposes it on the left (`-`, `->`, `-[`) without a separator (NOTE
//   238: the two minus signs would be a <simple comment introducer>, 21.4).
//   So `<--` is refused, with a message naming the GQL spellings.
// - The tilde forms match undirected edges, which Geode does not store
//   (Feature GH02); they stay refused with SONNY-6433's message.
//
// Geode stores directed edges only, so "left or right" (`<->`, `<-[ ]->`)
// and "any direction" (`-`, `-[ ]-`) both match an edge in either direction.
//
// The fixture (read_semantics_batch_harness.zig): (:Y {k})-[:R]->(:Q {k})
// -[:R {w: k}]->(:X {k}) for k = 0..3 and (:Q {k: 0})-[:S]->(:Q {k: 1}), so
// Q 0 has one incoming and two outgoing edges its reader sees in every
// session.
//
// CANARY: REQ=REQ-SONNY-6267-ABBREVIATED-EDGE-PATTERNS; FEATURE="PathPatterns"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6267_abbreviated_edge_patterns.zig; OWNER=parser; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    // G044: <left arrow>, <right arrow>, <minus sign>.
    .{ .q = "MATCH (a:Q {k: 0})<-(b) RETURN b.k AS k", .want = &.{"0"} },
    .{ .q = "MATCH (a:Q {k: 0})->(b) RETURN count(*) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (a:Q {k: 0})-(b) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .q = "MATCH (y:Y {k: 1})-(q)-(x:X) RETURN x.k AS k", .want = &.{"1"} },
    // G045: <left minus right>, and its full form <full edge left or right>.
    .{ .q = "MATCH (a:Q {k: 0})<->(b) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .q = "MATCH (a:Q {k: 0})<-[r]->(b) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .q = "MATCH (a:Q {k: 0})<-[:R]->(b) RETURN count(*) AS c", .want = &.{"2"} },
    // As a pattern predicate.
    .{ .q = "MATCH (q:Q) WHERE EXISTS { (q)-(:Y) } RETURN count(*) AS c", .want = &.{"4"} },
    // Not GQL (16.7 SR, NOTE 238): refused.
    .{ .q = "MATCH (a)<--(b) RETURN count(*) AS c", .err = error.UnexpectedToken },
    // Undirected edges (GH02): refused.
    .{ .q = "MATCH (a)~(b) RETURN count(*) AS c", .err = error.UndirectedEdgeNotSupported },
    .{ .q = "MATCH (a)<~(b) RETURN count(*) AS c", .err = error.UndirectedEdgeNotSupported },
};

test "SONNY-6267: the ISO abbreviated edge patterns parse and match; <-- is refused" {
    try harness.inEveryMode("SONNY-6267 abbreviated edge patterns", &cases);
}
