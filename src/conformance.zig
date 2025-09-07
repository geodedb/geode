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
    var buf: [8192]u8 = undefined;
    var adapter = w.adaptToNewApi(&buf);
    var jw = std.json.Stringify{
        .writer = &adapter.new_interface,
        .options = .{},
    };
    try jw.beginObject();
    try jw.objectField("version");
    try jw.write(prof.version);
    try jw.objectField("features");
    try jw.beginObject();
    try jw.objectField("order_by");
    try jw.write(prof.features.order_by);
    try jw.objectField("order_by_nulls_policy");
    try jw.write(prof.features.order_by_nulls_policy);
    try jw.objectField("group_by_phase1");
    try jw.write(prof.features.group_by_phase1);
    try jw.objectField("having_parsed");
    try jw.write(prof.features.having_parsed);
    try jw.objectField("set_ops_skeleton");
    try jw.write(prof.features.set_ops_skeleton);
    try jw.objectField("temporals_structured");
    try jw.write(prof.features.temporals_structured);
    try jw.objectField("session_offset_flag");
    try jw.write(prof.features.session_offset_flag);
    try jw.endObject();
    try jw.endObject();
}

test "conformance json outputs expected keys" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const prof = Profile{ .features = .{} };
    try writeConformanceJson(buf.writer(), prof);
    const s = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "\"version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"features\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"group_by_phase1\"") != null);
}
