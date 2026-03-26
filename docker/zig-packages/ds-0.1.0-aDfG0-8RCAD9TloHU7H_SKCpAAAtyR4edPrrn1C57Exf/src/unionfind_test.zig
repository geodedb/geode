// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const UnionFind = @import("unionfind.zig").UnionFind;

test "UnionFind - basic make and find" {
    var uf = UnionFind.init(testing.allocator);
    defer uf.deinit();

    try uf.make("A");
    try uf.make("B");

    const a_root = try uf.find("A");
    const b_root = try uf.find("B");

    try testing.expectEqualStrings("A", a_root);
    try testing.expectEqualStrings("B", b_root);
}

test "UnionFind - union operation" {
    var uf = UnionFind.init(testing.allocator);
    defer uf.deinit();

    try uf.make("A");
    try uf.make("B");

    const merged = try uf.unite("A", "B");
    try testing.expect(merged);

    const a_root = try uf.find("A");
    const b_root = try uf.find("B");

    try testing.expectEqualStrings(a_root, b_root);
}

test "UnionFind - union returns false for same set" {
    var uf = UnionFind.init(testing.allocator);
    defer uf.deinit();

    try uf.make("A");
    try uf.make("B");

    _ = try uf.unite("A", "B");
    const merged_again = try uf.unite("A", "B");

    try testing.expect(!merged_again);
}

test "UnionFind - size tracking" {
    var uf = UnionFind.init(testing.allocator);
    defer uf.deinit();

    try uf.make("A");
    try uf.make("B");
    try uf.make("C");

    try testing.expectEqual(@as(usize, 1), try uf.size("A"));
    try testing.expectEqual(@as(usize, 1), try uf.size("B"));

    _ = try uf.unite("A", "B");
    try testing.expectEqual(@as(usize, 2), try uf.size("A"));
    try testing.expectEqual(@as(usize, 2), try uf.size("B"));
    try testing.expectEqual(@as(usize, 1), try uf.size("C"));

    _ = try uf.unite("B", "C");
    try testing.expectEqual(@as(usize, 3), try uf.size("A"));
    try testing.expectEqual(@as(usize, 3), try uf.size("B"));
    try testing.expectEqual(@as(usize, 3), try uf.size("C"));
}

test "UnionFind - path compression" {
    var uf = UnionFind.init(testing.allocator);
    defer uf.deinit();

    try uf.make("A");
    try uf.make("B");
    try uf.make("C");
    try uf.make("D");

    _ = try uf.unite("A", "B");
    _ = try uf.unite("B", "C");
    _ = try uf.unite("C", "D");

    // After path compression, all should have same root
    const a_root = try uf.find("A");
    const b_root = try uf.find("B");
    const c_root = try uf.find("C");
    const d_root = try uf.find("D");

    try testing.expectEqualStrings(a_root, b_root);
    try testing.expectEqualStrings(b_root, c_root);
    try testing.expectEqualStrings(c_root, d_root);
}

test "UnionFind - multiple disjoint sets" {
    var uf = UnionFind.init(testing.allocator);
    defer uf.deinit();

    // Create two disjoint sets: {A, B, C} and {D, E}
    try uf.make("A");
    try uf.make("B");
    try uf.make("C");
    try uf.make("D");
    try uf.make("E");

    _ = try uf.unite("A", "B");
    _ = try uf.unite("B", "C");
    _ = try uf.unite("D", "E");

    const a_root = try uf.find("A");
    const c_root = try uf.find("C");
    const d_root = try uf.find("D");
    const e_root = try uf.find("E");

    // A and C should be in same set
    try testing.expectEqualStrings(a_root, c_root);

    // D and E should be in same set
    try testing.expectEqualStrings(d_root, e_root);

    // But A and D should be in different sets
    try testing.expect(!std.mem.eql(u8, a_root, d_root));
}
