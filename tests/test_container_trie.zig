const std = @import("std");
const geode = @import("../src/lib.zig");

const T = geode.graph.containers.trie.Trie(u32);

// CANARY test name referenced in Trie CANARY line
test "TestCANARY_REQ_GQL_068_Trie_basic_ops" {
    const ally = std.testing.allocator;
    var trie = try T.init(ally);
    defer trie.deinit();

    try std.testing.expect(trie.get("cat") == null);
    try trie.insert("cat", 1);
    try trie.insert("car", 2);
    try trie.insert("cart", 3);
    try trie.insert("dog", 9);
    try std.testing.expect(trie.get("cat").?.* == 1);
    try std.testing.expect(trie.get("car").?.* == 2);
    try std.testing.expect(trie.get("cart").?.* == 3);
    try std.testing.expect(trie.get("dog").?.* == 9);

    // overwrite
    try trie.insert("car", 22);
    try std.testing.expect(trie.get("car").?.* == 22);

    // prefix collection
    const pref = try trie.collectPrefix(ally, "ca");
    defer {
        for (pref) |s| ally.free(s);
        ally.free(pref);
    }
    var have_cat = false;
    var have_car = false;
    var have_cart = false;
    for (pref) |s| {
        if (std.mem.eql(u8, s, "cat")) have_cat = true;
        if (std.mem.eql(u8, s, "car")) have_car = true;
        if (std.mem.eql(u8, s, "cart")) have_cart = true;
    }
    try std.testing.expect(have_cat and have_car and have_cart);

    // remove internal (car) then ensure cart remains
    try std.testing.expect(trie.remove("car"));
    try std.testing.expect(trie.get("car") == null);
    try std.testing.expect(trie.get("cart") != null);

    // remove leaf (cat)
    try std.testing.expect(trie.remove("cat"));
    try std.testing.expect(trie.get("cat") == null);

    // removal of missing
    try std.testing.expect(!trie.remove("missing"));
}

test "TestCANARY_REQ_GQL_068_Trie_iterator_order" {
    const ally = std.testing.allocator;
    var trie = try T.init(ally);
    defer trie.deinit();
    const words = [_][]const u8{ "a", "ab", "b", "ba", "aa" };
    const values = [_]u32{ 1, 2, 3, 4, 5 };
    for (words, 0..) |w, i| try trie.insert(w, values[i]);
    // iterator should yield keys in lexicographic order
    var it = trie.iterator();
    var collected = std.ArrayList([]const u8).init(ally);
    defer {
        for (collected.items) |s| ally.free(s);
        collected.deinit();
    }
    while (true) {
        const nxt = it.next() orelse break;
        const dup = try ally.dupe(u8, nxt.key);
        try collected.append(dup);
    }
    try std.testing.expect(collected.items.len == 5);
    for (collected.items, 0..) |k, i| {
        if (i > 0) try std.testing.expect(std.mem.lessThan(u8, collected.items[i - 1], k));
    }
}
