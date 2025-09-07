const std = @import("std");

pub const Profile = struct {
    version: []const u8 = "skeleton",
    features: Features,
};

pub const Features = struct {
    order_by: bool = true,
    order_by_nulls_policy: bool = true,
    group_by_phase1: bool = true,
    having_parsed: bool = true,
    set_ops_skeleton: bool = true,
    temporals_structured: bool = true,
    session_offset_flag: bool = true,
};

pub fn writeConformanceJson(w: anytype, prof: Profile) !void {
    try w.writeByte('{');
    try w.print("\"version\":\"{s}\",", .{prof.version});
    try w.writeAll("\"features\":{");
    try w.print("\"order_by\":{},", .{prof.features.order_by});
    try w.print("\"order_by_nulls_policy\":{},", .{prof.features.order_by_nulls_policy});
    try w.print("\"group_by_phase1\":{},", .{prof.features.group_by_phase1});
    try w.print("\"having_parsed\":{},", .{prof.features.having_parsed});
    try w.print("\"set_ops_skeleton\":{},", .{prof.features.set_ops_skeleton});
    try w.print("\"temporals_structured\":{},", .{prof.features.temporals_structured});
    try w.print("\"session_offset_flag\":{}", .{prof.features.session_offset_flag});
    try w.writeAll("}}");
}

test "conformance json outputs expected keys" {
    var buf = std.ArrayList(u8).initCapacity(std.testing.allocator, 0) catch @panic("OOM");
    defer buf.deinit(std.testing.allocator);
    const prof = Profile{ .features = .{} };
    try writeConformanceJson(buf.writer(std.testing.allocator), prof);
    const s = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "\"version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"features\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"group_by_phase1\"") != null);
}
