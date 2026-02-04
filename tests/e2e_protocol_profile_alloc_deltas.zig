const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

fn run(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 21);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 18);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

test "protocol: per-stage allocation deltas and op ordering" {
    const exe = "./zig-out/bin/geode";
    // DISTINCT + ORDER + OFFSET + LIMIT to exercise multiple phases.
    const out = try run(&.{ exe, "PROFILE RETURN a AS x DISTINCT ORDER BY x OFFSET 1 LIMIT 2", "--param", "a", "[5,4,4,3,2,1]" });
    defer testing.allocator.free(out);
    const line = util.findProfileLine(out) orelse return error.MissingProfile;
    // Parse JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const result_val = root.get("result") orelse return error.MissingResult;
    try testing.expect(result_val.* == .object);
    const result_obj = result_val.object;
    const json_val = result_obj.get("json") orelse return error.MissingJson;
    try testing.expect(json_val.* == .object);
    const prof_obj = json_val.object;
    const ops_val = prof_obj.get("ops") orelse return error.MissingOps;
    try testing.expect(ops_val.* == .array);
    const ops = ops_val.array.items;
    // Collect ordering indices
    var idx_nodescan: ?usize = null;
    var idx_expand: ?usize = null;
    var idx_project: ?usize = null;
    var idx_distinct: ?usize = null;
    var idx_sort: ?usize = null;
    var idx_offset: ?usize = null;
    var idx_limit: ?usize = null;
    var sum_alloc: usize = 0;
    for (ops, 0..) |opv, i| {
        try testing.expect(opv == .object);
        const o = opv.object;
        const name_val = o.get("op") orelse return error.MissingOpName;
        try testing.expect(name_val.* == .string);
        const name = name_val.string;
        const alloc_field = o.get("bytes_alloc") orelse return error.MissingBytesAlloc;
        try testing.expect(alloc_field.* == .integer);
        const alloc_amt: usize = @intCast(alloc_field.integer);
        sum_alloc += alloc_amt;
        // No stage should have negative or huge improbable alloc (basic guard)
        try testing.expect(alloc_amt < 1 << 40);
        if (std.mem.eql(u8, name, "NodeScan")) {
            idx_nodescan = i;
        } else if (std.mem.eql(u8, name, "Expand")) {
            idx_expand = i;
        } else if (std.mem.eql(u8, name, "Project")) {
            idx_project = i;
        } else if (std.mem.eql(u8, name, "Distinct")) {
            idx_distinct = i;
        } else if (std.mem.eql(u8, name, "Sort")) {
            idx_sort = i;
        } else if (std.mem.eql(u8, name, "Offset")) {
            idx_offset = i;
        } else if (std.mem.eql(u8, name, "Limit")) {
            idx_limit = i;
        }
    }
    // Required ops appear
    try testing.expect(idx_nodescan != null);
    try testing.expect(idx_expand != null);
    try testing.expect(idx_project != null);
    try testing.expect(idx_distinct != null); // DISTINCT specified
    try testing.expect(idx_sort != null);
    try testing.expect(idx_offset != null);
    try testing.expect(idx_limit != null);
    // Ordering monotonic via helper (subset sequence)
    try util.assertOpOrder(line, &.{ "NodeScan", "Expand", "Project", "Distinct", "Sort", "Offset", "Limit" });
    // Peak/memory relationship: sum of per-stage allocations should not exceed peak_bytes by more than modest fragmentation slack.
    const mem_val = prof_obj.get("memory") orelse return error.MissingMemory;
    try testing.expect(mem_val.* == .object);
    const mem_obj = mem_val.object;
    const peak_val = mem_obj.get("peak_bytes") orelse return error.MissingPeak;
    try testing.expect(peak_val.* == .integer);
    const peak: usize = @intCast(peak_val.integer);
    // Allow sum_alloc to be <= peak * 2 (loose upper bound for now until fragmentation attribution refined).
    if (peak > 0) try testing.expect(sum_alloc <= peak * 2);
}
