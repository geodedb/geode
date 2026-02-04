const std = @import("std");
const cost_explain = @import("../planner/cost_explain.zig");
const cost_seed = @import("../planner/cost_seed.zig");
const query_traits = @import("../query/query_traits.zig");

pub fn buildExplainJson(
    allocator: std.mem.Allocator,
    traits: query_traits.QueryTraits,
    union_part_count: usize,
    calibrated: bool,
) ![]u8 {
    const ops = try buildOps(allocator, traits);
    defer allocator.free(ops);

    const base = if (calibrated)
        try cost_explain.explainChainWithCalibration(allocator, ops, null, null)
    else
        try cost_explain.explainChain(allocator, ops);

    return try appendProperties(allocator, base, traits, union_part_count);
}

fn buildOps(allocator: std.mem.Allocator, traits: query_traits.QueryTraits) ![]cost_seed.OpDescriptor {
    var list = std.ArrayList(cost_seed.OpDescriptor).initCapacity(allocator, 8) catch return error.OutOfMemory;
    defer list.deinit(allocator);

    try list.append(allocator, .{ .kind = .Scan });
    try list.append(allocator, .{ .kind = .Expand });
    if (traits.has_where_eq or traits.has_filter_eq) {
        try list.append(allocator, .{ .kind = .Filter });
    }
    if (traits.has_group_by) {
        try list.append(allocator, .{ .kind = .Aggregate });
    }
    if (traits.distinct) {
        try list.append(allocator, .{ .kind = .Aggregate });
    }
    try list.append(allocator, .{ .kind = .Project });
    if (traits.ordered) {
        try list.append(allocator, .{ .kind = .Sort });
    }
    if (traits.limit != null or traits.offset != null) {
        try list.append(allocator, .{ .kind = .Limit });
    }
    if (traits.has_union) {
        try list.append(allocator, .{ .kind = .SetOp });
    }

    return list.toOwnedSlice(allocator);
}

fn appendProperties(
    allocator: std.mem.Allocator,
    base_json: []u8,
    traits: query_traits.QueryTraits,
    union_part_count: usize,
) ![]u8 {
    // Early return without freeing - caller retains ownership of base_json
    if (base_json.len == 0 or base_json[base_json.len - 1] != '}') {
        return base_json;
    }

    // From here on, we'll create a new allocation and free the original
    var props = std.ArrayList(u8).initCapacity(allocator, 128) catch return error.OutOfMemory;
    defer props.deinit(allocator);
    var w = props.writer(allocator);
    try w.writeAll(",\"properties\":{");
    try w.writeAll("\"ordered\":");
    try w.writeAll(if (traits.ordered) "true" else "false");

    if (traits.limit) |lim| {
        try w.writeAll(",\"limit\":");
        try w.print("{d}", .{lim});
    }
    if (traits.offset) |off| {
        try w.writeAll(",\"offset\":");
        try w.print("{d}", .{off});
    }
    if (traits.distinct) {
        try w.writeAll(",\"distinct\":true");
    }
    if (traits.has_union) {
        try w.writeAll(",\"union_mode\":\"");
        try w.writeAll(unionModeToString(traits.union_mode));
        try w.writeAll("\"");
        try w.writeAll(",\"union_part_count\":");
        try w.print("{d}", .{union_part_count});
    }
    try w.writeAll("}");

    const prefix_len = base_json.len - 1;
    const final_len = prefix_len + props.items.len + 1;
    var out = try allocator.alloc(u8, final_len);
    std.mem.copyForwards(u8, out[0..prefix_len], base_json[0..prefix_len]);
    std.mem.copyForwards(u8, out[prefix_len .. prefix_len + props.items.len], props.items);
    out[final_len - 1] = '}';

    // Free the original base_json now that we've copied the data
    allocator.free(base_json);

    return out;
}

fn unionModeToString(mode: query_traits.UnionMode) []const u8 {
    return switch (mode) {
        .all => "ALL",
        .distinct => "DISTINCT",
        .intersect => "INTERSECT",
        .except => "EXCEPT",
        .none => "NONE",
    };
}
