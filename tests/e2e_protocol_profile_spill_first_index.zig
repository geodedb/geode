const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn runWithEnv(args: []const []const u8, spill_distinct: bool, spill_sort: bool) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var child = Child.init(args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = try std.process.getEnvMap(allocator);
    defer child.env_map.deinit();
    if (spill_distinct) try child.env_map.put("GEODE_FORCE_DISTINCT_SPILL", "1");
    if (spill_sort) try child.env_map.put("GEODE_FORCE_SORT_SPILL", "1");
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

fn findProfileLine(out: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| if (std.mem.indexOf(u8, line, "\"type\":\"PROFILE\"") != null) return line;
    return null;
}

fn parseProfile(line: []const u8) !struct { distinct_index: ?usize, sort_index: ?usize, first_spill: usize, spill_reason_forced: bool } {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const result_val = root.get("result") orelse return error.MissingResult;
    if (result_val.* != .object) return error.BadResult;
    const json_val = result_val.object.get("json") orelse return error.MissingJson;
    if (json_val.* != .object) return error.BadJson;
    const prof_obj = json_val.object;
    const ops_val = prof_obj.get("ops") orelse return error.MissingOps;
    if (ops_val.* != .array) return error.BadOps;
    const ops_arr = ops_val.array.items;
    var distinct_index: ?usize = null;
    var sort_index: ?usize = null;
    var i: usize = 0;
    while (i < ops_arr.len) : (i += 1) {
        const ov = ops_arr[i];
        if (ov != .object) continue;
        const o = ov.object;
        if (o.get("op")) |name_v| if (name_v.* == .string) {
            if (std.mem.eql(u8, name_v.string, "Distinct")) distinct_index = i;
            if (std.mem.eql(u8, name_v.string, "Sort")) sort_index = i;
        };
    }
    const fsp_val = prof_obj.get("first_spill_op_index") orelse return error.MissingFirstSpillIndex;
    if (fsp_val.* != .integer) return error.BadFirstSpillIndex;
    const reason_val = prof_obj.get("spill_reason");
    const spill_forced = reason_val != null and reason_val.* == .string and std.mem.eql(u8, reason_val.string, "forced");
    return .{ .distinct_index = distinct_index, .sort_index = sort_index, .first_spill = @intCast(fsp_val.integer), .spill_reason_forced = spill_forced };
}

test "profile: first_spill_op_index prefers earlier Distinct over Sort when both spill" {
    const exe = "./zig-out/bin/geodec";
    const q = "PROFILE RETURN DISTINCT 1 AS x, 1 AS y ORDER BY x LIMIT 5";
    const res = try runWithEnv(&.{ exe, q }, true, true);
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    const line = findProfileLine(res.out) orelse return error.NoProfile;
    const prof = try parseProfile(line);
    try std.testing.expect(prof.distinct_index != null);
    try std.testing.expect(prof.sort_index != null);
    // Distinct should appear before Sort in pipeline
    try std.testing.expect(prof.distinct_index.? < prof.sort_index.?);
    // first_spill_op_index must equal distinct index
    try std.testing.expectEqual(prof.distinct_index.?, prof.first_spill);
    try std.testing.expect(prof.spill_reason_forced);
}

test "profile: first_spill_op_index is Sort when only sort spills" {
    const exe = "./zig-out/bin/geodec";
    const q = "PROFILE RETURN 1 AS x ORDER BY x LIMIT 5";
    const res = try runWithEnv(&.{ exe, q }, false, true);
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    const line = findProfileLine(res.out) orelse return error.NoProfile;
    const prof = try parseProfile(line);
    try std.testing.expect(prof.distinct_index == null); // no distinct op present
    try std.testing.expect(prof.sort_index != null);
    try std.testing.expectEqual(prof.sort_index.?, prof.first_spill);
    try std.testing.expect(prof.spill_reason_forced);
}
