const std = @import("std");
const patricia = @import("patricia.zig");
const rtree = @import("rtree.zig");
const hnsw = @import("hnsw.zig");
const heap = @import("../storage/heap.zig");

pub const IndexKind = enum { patricia_v4, patricia_v6, rtree, hnsw };

pub const AnyIndex = union(enum) {
    Patricia: patricia.PatriciaTrie,
    RTree: rtree.RTree,
    Hnsw: hnsw.Hnsw,
};

pub fn create(kind: IndexKind, allocator: std.mem.Allocator) AnyIndex {
    return switch (kind) {
        .patricia_v4 => .{ .Patricia = patricia.PatriciaTrie.init(allocator, .v4) },
        .patricia_v6 => .{ .Patricia = patricia.PatriciaTrie.init(allocator, .v6) },
        .rtree => .{ .RTree = rtree.RTree.init(allocator, 16) },
        .hnsw => .{ .Hnsw = hnsw.Hnsw.init(allocator, 0, 16, 32) },
    };
}

pub fn parse(name: []const u8) ?IndexKind {
    if (std.mem.eql(u8, name, "patricia_v4")) return .patricia_v4;
    if (std.mem.eql(u8, name, "patricia_v6")) return .patricia_v6;
    if (std.mem.eql(u8, name, "rtree")) return .rtree;
    if (std.mem.eql(u8, name, "hnsw")) return .hnsw;
    return null;
}

test "registry create patricia v4" {
    const idx = create(.patricia_v4, std.testing.allocator);
    if (idx != .Patricia) return error.Unexpected;
    // basic insert + lookup smoke
    const subnet: heap.Subnet = .{ .addr = .{ .v4 = .{ 192, 168, 1, 0 } }, .prefix_len = 24 };
    var trie = idx.Patricia; // copy (mutated internally)
    defer trie.deinit();
    try trie.insert(subnet, 1);
    const res = trie.longestPrefixMatch(.{ .v4 = .{ 192, 168, 1, 42 } });
    try std.testing.expect(res != null);
}
