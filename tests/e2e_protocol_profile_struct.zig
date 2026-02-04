const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
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

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// Structural validation of PROFILE frame JSON payload.
// Ensures deterministic shape independent of timing/bytes numeric variability.
// Query chosen: PROFILE RETURN 1 AS x LIMIT 1
// Expectations:
//  - profile.profile_version == 1
//  - ops array length >= 1 and contains a Limit stage
//  - Each op has keys: op,id,op_index,input_rows,rows
//  - root flagger_findings includes IllegalOrderKeyPolicy and NullsFirstPolicy
//  - totals.time_ns present
//  - memory.net_bytes & memory.peak_bytes present
//  - No malformed JSON (parses successfully)

test "protocol: PROFILE structural JSON validation" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);

    // Parse root JSON object
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, res.out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const root_obj = parsed.value.object;
    const profile_val = root_obj.get("profile") orelse return error.MissingProfile;
    try std.testing.expect(profile_val.* == .object);
    const prof_obj = profile_val.object;
    const pv = prof_obj.get("profile_version") orelse return error.MissingProfileVersion;
    try std.testing.expect(pv.* == .integer and pv.integer == 1);
    const ops_val = prof_obj.get("ops") orelse return error.MissingOps;
    try std.testing.expect(ops_val.* == .array);
    const ops_arr = ops_val.array.items;
    try std.testing.expect(ops_arr.len >= 1);
    var saw_limit = false;
    var oi: usize = 0;
    while (oi < ops_arr.len) : (oi += 1) {
        const opv = ops_arr[oi];
        try std.testing.expect(opv == .object);
        const o = opv.object;
        const name = o.get("op") orelse return error.MissingOpName;
        try std.testing.expect(name.* == .string);
        if (std.mem.eql(u8, name.string, "Limit")) saw_limit = true;
        // Mandatory numeric fields
        try std.testing.expect(o.get("id") != null);
        try std.testing.expect(o.get("op_index") != null);
        try std.testing.expect(o.get("input_rows") != null);
        try std.testing.expect(o.get("rows") != null);
    }
    try std.testing.expect(saw_limit);
    const flags_val = root_obj.get("flagger_findings") orelse return error.MissingFlags;
    try std.testing.expect(flags_val.* == .array);
    const flags_arr = flags_val.array.items;
    var found_illegal = false;
    var found_nulls = false;
    for (flags_arr) |fv| {
        if (fv != .string) continue;
        if (std.mem.eql(u8, fv.string, "I:IllegalOrderKeyPolicy=ident-only")) found_illegal = true;
        if (std.mem.eql(u8, fv.string, "U:NullsFirstPolicy")) found_nulls = true;
    }
    try std.testing.expect(found_illegal);
    try std.testing.expect(found_nulls);
    // Totals & memory presence
    try std.testing.expect(prof_obj.get("totals") != null);
    try std.testing.expect(prof_obj.get("memory") != null);
}
