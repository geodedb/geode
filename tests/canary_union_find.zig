const std = @import("std");
const uf_mod = @import("../src/graph/union_find.zig");

test "TestCANARY_REQ_GQL_068_UnionFind" {
    var uf = try uf_mod.UnionFind.init(std.testing.allocator, 50);
    defer uf.deinit(std.testing.allocator);
    try std.testing.expect(uf.componentCount() == 50);
    // Chain unions
    var i: u32 = 1;
    while (i < 10) : (i += 1) {
        _ = uf.unite(i - 1, i);
    }
    try std.testing.expect(uf.componentCount() == 50 - 9);
    const rep0 = uf.find(0);
    i = 0;
    while (i < 10) : (i += 1) try std.testing.expect(uf.find(i) == rep0);
    // Disjoint set unaffected
    try std.testing.expect(uf.find(20) != rep0);
}
