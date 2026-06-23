// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// FIX #3 routing regression: the from-dump edge-phase query
//   MATCH (a:Taxon {source: ?, source_id: ?}), (b:Taxon {source: ?, source_id: ?})
//   MERGE (a)-[r:PARENT_OF]->(b) SET r.run_id = ?
// MUST be detected as `.match_merge_edge` and yield a correct MatchMergeEdgeSpec
// so it routes to the shard-locked deduped edge MERGE (coexists with readers)
// instead of falling through to the whole-graph EXCLUSIVE executor (the 40001).
//
// Before FIX #3 this query was rejected by every fast-path detector
// (matchEdgeSpec rejects MERGE + the post-SET + composite endpoint keys), so
// matchSingleStatement returned `.none`.
//
// CANARY: REQ=REQ-CONCURRENCY-MERGE-EDGE-FASTPATH-DETECT; FEATURE="MergeEdgeFastPathDetect"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_merge_edge_fastpath_detect.zig; OWNER=storage; UPDATED=2026-06-23

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const bulk_ingest = geode.bulk_ingest;

fn parse(arena: *std.heap.ArenaAllocator, src: []const u8) !geode.gql.ast.Program {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    return p.parseProgram();
}

test "from-dump edge MERGE (composite key + post-SET) is detected as match_merge_edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var program = try parse(&arena,
        \\MATCH (a:Taxon {source: 'col', source_id: '100'}), (b:Taxon {source: 'col', source_id: '200'})
        \\MERGE (a)-[r:PARENT_OF]->(b) SET r.run_id = 'run-1'
    );

    try testing.expectEqual(bulk_ingest.BulkPattern.match_merge_edge, bulk_ingest.matchSingleStatement(&program));

    const spec = bulk_ingest.matchMergeEdgeSpec(&program) orelse return error.SpecMissing;
    try testing.expectEqualStrings("PARENT_OF", spec.rel_type);
    try testing.expectEqualStrings("Taxon", spec.source.label);
    try testing.expectEqual(@as(usize, 2), spec.source.filters.len);
    try testing.expectEqual(@as(usize, 2), spec.target.filters.len);
    try testing.expect(spec.rel_var != null);
    try testing.expectEqualStrings("r", spec.rel_var.?);
    // The SET r.run_id = ? clause is carried for edge-prop application.
    try testing.expect(spec.set_clauses.len >= 1);
}

test "param-bound from-dump edge MERGE is detected (driver emits ? params)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var program = try parse(&arena,
        \\MATCH (a:Taxon {source: $p0, source_id: $p1}), (b:Taxon {source: $p2, source_id: $p3})
        \\MERGE (a)-[r:ACCEPTED_AS]->(b) SET r.run_id = $p4
    );
    try testing.expectEqual(bulk_ingest.BulkPattern.match_merge_edge, bulk_ingest.matchSingleStatement(&program));
    const spec = bulk_ingest.matchMergeEdgeSpec(&program) orelse return error.SpecMissing;
    try testing.expectEqualStrings("ACCEPTED_AS", spec.rel_type);
}

test "merge-edge without SET is still detected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var program = try parse(&arena,
        \\MATCH (a:Taxon {source_id: '1'}), (b:Taxon {source_id: '2'})
        \\MERGE (a)-[:PARENT_OF]->(b)
    );
    try testing.expectEqual(bulk_ingest.BulkPattern.match_merge_edge, bulk_ingest.matchSingleStatement(&program));
}

test "non-eligible MERGE shapes are NOT mis-detected (fall back to executor)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // RETURN present → must NOT fast-path (the executor must materialize).
    {
        var program = try parse(&arena,
            \\MATCH (a:Taxon {source_id: '1'}), (b:Taxon {source_id: '2'})
            \\MERGE (a)-[r:PARENT_OF]->(b) RETURN r
        );
        try testing.expect(bulk_ingest.matchSingleStatement(&program) != .match_merge_edge);
    }
    // WHERE present → not eligible.
    {
        var program = try parse(&arena,
            \\MATCH (a:Taxon {source_id: '1'}), (b:Taxon) WHERE b.source_id = '2'
            \\MERGE (a)-[:PARENT_OF]->(b)
        );
        try testing.expect(bulk_ingest.matchSingleStatement(&program) != .match_merge_edge);
    }
    // Three MATCH chains → not the two-endpoint shape.
    {
        var program = try parse(&arena,
            \\MATCH (a:Taxon {source_id: '1'}), (b:Taxon {source_id: '2'}), (c:Taxon {source_id: '3'})
            \\MERGE (a)-[:PARENT_OF]->(b)
        );
        try testing.expect(bulk_ingest.matchSingleStatement(&program) != .match_merge_edge);
    }
    // SET targets a NON-rel variable → not eligible (would need node mutation).
    {
        var program = try parse(&arena,
            \\MATCH (a:Taxon {source_id: '1'}), (b:Taxon {source_id: '2'})
            \\MERGE (a)-[r:PARENT_OF]->(b) SET a.touched = true
        );
        try testing.expect(bulk_ingest.matchSingleStatement(&program) != .match_merge_edge);
    }
}
