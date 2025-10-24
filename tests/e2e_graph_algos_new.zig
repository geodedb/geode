const std = @import("std");
const alg = @import("geode").graph_algos_stub;

test "communityDetect deterministic labels" {
    const allocator = std.testing.allocator;
    var g = alg.GraphHandle.init(3);
    const r = try alg.communityDetect(allocator, &g, .Louvain, 10, 1.0);
    try std.testing.expect(r.count == 3);
    try std.testing.expect(r.labels.len == 3);
}

test "validateReturnOnlyUsage rejects non-RETURN" {
    try std.testing.expectError(error.GRAPH_ALG_USAGE_ERROR, alg.validateReturnOnlyUsage("MATCH"));
}
