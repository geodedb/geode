const std = @import("std");
const testing = std.testing;
const bm25 = @import("src/fts/bm25.zig");

// CANARY: REQ=REQ-GQL-FTS-001; FEATURE="BM25 skeleton"; ASPECT=SEARCH; STATUS=TESTED; TEST=tests/unit_bm25_skeleton.zig:1; OWNER=search; UPDATED=2025-09-26

test "BM25 skeleton basic monotonicity" {
    const p = bm25.Params{};
    const s1 = bm25.score(1, 100, 100, 10, 1000, p);
    const s2 = bm25.score(2, 100, 100, 10, 1000, p);
    try testing.expect(s2 > s1);
}
