// SONNY-6450 regression (item 6): a stored property chain that holds the same
// key twice leaked when it was read.
//
// `getAllNodeProperties` / `getAllEdgeProperties` decode each entry of a
// node's or an edge's property chain into a map through `putDecodedProperty`,
// which copied the key and called `put`. For a key the map already held, `put`
// kept the map's key and overwrote the value: the new key copy and the
// earlier value (a string's or an extended value's bytes) were never freed.
// The later entry's value is the one kept, as before; the earlier value is
// freed, and so is everything else on every path, under the leak-checking
// allocator. A later null (the REMOVE tombstone, SONNY-6433) still removes
// the key.
//
// (Items 3-5 of the ticket, a decrypted member read copied again by the
// projection, `executeReturnClauseWithNodes`'s row values and the WITH
// stage's ORDER BY keys, are covered by
// tests/test_sonny6449_projection_value_ownership.zig.)
//
// CANARY: REQ=REQ-SONNY-6450-DUPLICATE-STORED-KEY; FEATURE="EngineDirectNodeOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6450_ownership_residuals.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");

const gsa = geode.graph_storage_adapter;
const PropertyMap = std.StringHashMap(gs.PropertyValue);

fn freeMap(map: *PropertyMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        testing.allocator.free(entry.key_ptr.*);
        gsa.freeOwnedStorageProperty(testing.allocator, entry.value_ptr.*);
    }
    map.deinit();
}

/// Decode the entries of a chain, in order, as the adapter reads one.
fn readChain(map: *PropertyMap, entries: []const struct { []const u8, gs.PropertyValue }) !void {
    for (entries) |entry| {
        const encoded = try gs.property.encode(testing.allocator, entry[1]);
        defer testing.allocator.free(encoded);
        try gsa.putDecodedProperty(testing.allocator, map, entry[0], encoded);
    }
}

test "SONNY-6450 (6): a key twice in a stored property chain keeps the later value and frees the earlier one" {
    var map = PropertyMap.init(testing.allocator);
    defer freeMap(&map);
    try readChain(&map, &.{
        .{ "name", .{ .string = "first" } },
        .{ "other", .{ .int = 7 } },
        .{ "name", .{ .string = "second" } },
        .{ "blob", .{ .ext = .{ .type_tag = 3, .data = "one" } } },
        .{ "blob", .{ .ext = .{ .type_tag = 3, .data = "two" } } },
    });
    try testing.expectEqual(@as(u32, 3), map.count());
    try testing.expectEqualStrings("second", map.get("name").?.string);
    try testing.expectEqualStrings("two", map.get("blob").?.ext.data);
    try testing.expectEqual(@as(i64, 7), map.get("other").?.int);
}

test "SONNY-6450 (6): a scalar replaced by a string, a string by a scalar, and a tombstone after both" {
    var map = PropertyMap.init(testing.allocator);
    defer freeMap(&map);
    try readChain(&map, &.{
        .{ "a", .{ .int = 1 } },
        .{ "a", .{ .string = "now a string" } },
        .{ "b", .{ .string = "was a string" } },
        .{ "b", .{ .bool = true } },
        .{ "c", .{ .string = "removed" } },
        .{ "c", .null },
    });
    try testing.expectEqual(@as(u32, 2), map.count());
    try testing.expectEqualStrings("now a string", map.get("a").?.string);
    try testing.expect(map.get("b").?.bool);
    try testing.expect(map.get("c") == null);
}

test "SONNY-6450 (6): a duplicate key read under allocation failure leaks nothing" {
    // Every allocation of the read fails once, in turn: the map is left as it
    // was before the failing entry, and everything is freed.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        var map = PropertyMap.init(fa);
        const entries = [_]struct { []const u8, gs.PropertyValue }{
            .{ "name", .{ .string = "first" } },
            .{ "name", .{ .string = "second" } },
        };
        var failed = false;
        for (entries) |entry| {
            const encoded = try gs.property.encode(testing.allocator, entry[1]);
            defer testing.allocator.free(encoded);
            gsa.putDecodedProperty(fa, &map, entry[0], encoded) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                failed = true;
                break;
            };
        }
        var it = map.iterator();
        while (it.next()) |entry| {
            fa.free(entry.key_ptr.*);
            gsa.freeOwnedStorageProperty(fa, entry.value_ptr.*);
        }
        map.deinit();
        try testing.expectEqual(failing.allocations, failing.deallocations);
        if (!failed) break;
    }
}
