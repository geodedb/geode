// SONNY-2818 regression: a client parameter map that repeats a key leaked
// memory.
//
// proto_util.protoValueToValue decodes a client's map parameter entry by
// entry and stored each with `map.put(key, val)`. Zig's `put` keeps the key
// already stored, so for a repeated key the new copy of the key and the value
// it replaced were never freed. The merged-tree security review's probe TM-P1
// (P46): a map with 64 entries under one 1 KiB key left 64,575 bytes
// allocated after freeParamBindings. QUIC decodes with the process allocator,
// so any authenticated client grew the server's memory by about the size of
// each request: a remote memory-growth DoS. 076a7ba1 fixed the same bug on
// the peer path (value_convert.zig, since removed: SONNY-6563).
//
// The decoder now stores each entry with getOrPut and, for a repeated key,
// frees the duplicate key and the value it replaces (the last value still
// wins). Every case runs on the testing allocator, so a leak fails it.
//
// CANARY: REQ=REQ-SONNY-2818-PARAM-MAP-DUP-KEYS; FEATURE="WireParameters"; ASPECT=DuplicateMapKeys; STATUS=TESTED; TEST=tests/test_sonny2818_param_map_dup_keys.zig; OWNER=security; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");

const proto_util = geode.proto_util;

fn text(v: []const u8) schema.Value {
    return .{ .kind = .{ .string_val = .{ .value = v, .kind = .TEXT } } };
}

fn param(value: schema.Value) schema.Param {
    return .{ .name = "p", .value = value };
}

test "SONNY-2818: the probe's map (64 entries under one 1 KiB key) decodes to its last value and frees everything" {
    const key = try testing.allocator.alloc(u8, 1024);
    defer testing.allocator.free(key);
    @memset(key, 'k');
    var values: [64][8]u8 = undefined;
    var entries = std.ArrayList(schema.MapEntry).empty;
    defer entries.deinit(testing.allocator);
    for (&values, 0..) |*buf, i| {
        const v = try std.fmt.bufPrint(buf, "v{d}", .{i});
        try entries.append(testing.allocator, .{ .key = key, .value = text(v) });
    }

    const params = [_]schema.Param{param(.{ .kind = .{ .map_val = .{ .entries = entries } } })};
    const bindings = try proto_util.parseParams(testing.allocator, &params);
    defer proto_util.freeParamBindings(testing.allocator, bindings);
    const map = bindings.values[0].Map;
    try testing.expectEqual(@as(u32, 1), map.count());
    try testing.expectEqualStrings("v63", map.get(key).?.Text);
}

test "SONNY-2818: a repeated key frees the replaced value in full, in nested maps and lists" {
    // The replaced value is itself a map with a repeated key, and a list.
    var inner = std.ArrayList(schema.MapEntry).empty;
    defer inner.deinit(testing.allocator);
    try inner.append(testing.allocator, .{ .key = "x", .value = text("first") });
    try inner.append(testing.allocator, .{ .key = "x", .value = text("second") });
    var items = std.ArrayList(schema.Value).empty;
    defer items.deinit(testing.allocator);
    try items.append(testing.allocator, text("item"));
    try items.append(testing.allocator, .{ .kind = .{ .map_val = .{ .entries = inner } } });

    var outer = std.ArrayList(schema.MapEntry).empty;
    defer outer.deinit(testing.allocator);
    try outer.append(testing.allocator, .{ .key = "a", .value = .{ .kind = .{ .map_val = .{ .entries = inner } } } });
    try outer.append(testing.allocator, .{ .key = "a", .value = .{ .kind = .{ .list_val = .{ .values = items } } } });
    try outer.append(testing.allocator, .{ .key = "a", .value = .{ .kind = .{ .map_val = .{ .entries = inner } } } });
    try outer.append(testing.allocator, .{ .key = "b", .value = text("kept") });

    // The map as a parameter, and inside a list parameter.
    var wrapped = std.ArrayList(schema.Value).empty;
    defer wrapped.deinit(testing.allocator);
    try wrapped.append(testing.allocator, .{ .kind = .{ .map_val = .{ .entries = outer } } });
    const params = [_]schema.Param{
        param(.{ .kind = .{ .map_val = .{ .entries = outer } } }),
        param(.{ .kind = .{ .list_val = .{ .values = wrapped } } }),
    };
    const bindings = try proto_util.parseParams(testing.allocator, &params);
    defer proto_util.freeParamBindings(testing.allocator, bindings);
    for ([_]geode.value_types.Value{ bindings.values[0], bindings.values[1].List[0] }) |value| {
        const map = value.Map;
        try testing.expectEqual(@as(u32, 2), map.count());
        try testing.expectEqualStrings("kept", map.get("b").?.Text);
        const last = map.get("a").?.Map;
        try testing.expectEqual(@as(u32, 1), last.count());
        try testing.expectEqualStrings("second", last.get("x").?.Text);
    }
}

test "SONNY-2818: a map refused after a repeated key frees what it decoded" {
    var entries = std.ArrayList(schema.MapEntry).empty;
    defer entries.deinit(testing.allocator);
    try entries.append(testing.allocator, .{ .key = "a", .value = text("first") });
    try entries.append(testing.allocator, .{ .key = "a", .value = text("second") });
    try entries.append(testing.allocator, .{ .key = "b", .value = .{ .kind = .{ .int_val = .{ .value = 40000, .kind = .SMALLINT } } } });
    const params = [_]schema.Param{param(.{ .kind = .{ .map_val = .{ .entries = entries } } })};
    try testing.expectError(error.InvalidParams, proto_util.parseParams(testing.allocator, &params));
}
