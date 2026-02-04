const std = @import("std");

pub fn findProfileLine(out: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"PROFILE\"") != null) return line;
    }
    return null;
}

pub fn normalizeNumbers(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, line.len) catch return error.OutOfMemory;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c >= '0' and c <= '9') {
            if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '0') buf.append(allocator, '0') catch return error.OutOfMemory;
            var j = i + 1;
            while (j < line.len and ((line[j] >= '0' and line[j] <= '9') or line[j] == '.')) : (j += 1) {}
            i = j - 1;
            continue;
        }
        switch (c) {
            ' ', '\t', '\r', '\n' => continue,
            else => buf.appendAssumeCapacity(c),
        }
    }
    return buf.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Produce a concise diff string between two normalized signature strings.
/// Strategy: find first differing index; capture up to 48 chars of context
/// around that index for both expected and actual so failures are actionable
/// without dumping full gigantic JSON lines.
pub fn signatureDiff(allocator: std.mem.Allocator, expected: []const u8, actual: []const u8) ![]u8 {
    if (std.mem.eql(u8, expected, actual)) return allocator.dupe(u8, "<no-diff>") catch return error.OutOfMemory;
    var i: usize = 0;
    const min_len = @min(expected.len, actual.len);
    while (i < min_len and expected[i] == actual[i]) : (i += 1) {}
    const diff_index = i;
    const ctx_before: usize = if (diff_index > 16) diff_index - 16 else 0;
    const ctx_after_e: usize = @min(expected.len, diff_index + 32);
    const ctx_after_a: usize = @min(actual.len, diff_index + 32);
    var out = std.ArrayList(u8).initCapacity(allocator, 256) catch return error.OutOfMemory;
    const w = out.writer(allocator);
    w.print("diff_at={d}\nexpected_ctx=", .{diff_index}) catch {};
    w.writeAll(expected[ctx_before..ctx_after_e]) catch {};
    w.writeAll("\nactual_ctx=") catch {};
    w.writeAll(actual[ctx_before..ctx_after_a]) catch {};
    if (expected.len != actual.len) {
        w.print("\nlen_expected={d} len_actual={d}", .{ expected.len, actual.len }) catch {};
    }
    return out.toOwnedSlice(allocator) catch error.OutOfMemory;
}

// Extract a substring representing the planner_estimates JSON object (without trailing commas)
pub fn slicePlannerEstimates(profile_line: []const u8) ?[]const u8 {
    const key = "\"planner_estimates\"";
    const idx = std.mem.indexOf(u8, profile_line, key) orelse return null;
    const brace_idx = std.mem.indexOfPos(u8, profile_line, idx + key.len, "{") orelse return null;
    // naive brace match (depth 1) since object is flat
    var depth: i32 = 0;
    var end: usize = brace_idx;
    var i: usize = brace_idx;
    while (i < profile_line.len) : (i += 1) {
        const c = profile_line[i];
        if (c == '{') depth += 1 else if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                end = i + 1;
                break;
            }
        }
    }
    if (depth != 0) return null;
    return profile_line[brace_idx..end];
}

// Extract memory block (similar logic)
pub fn sliceMemory(profile_line: []const u8) ?[]const u8 {
    const key = "\"memory\"";
    const idx = std.mem.indexOf(u8, profile_line, key) orelse return null;
    const brace_idx = std.mem.indexOfPos(u8, profile_line, idx + key.len, "{") orelse return null;
    var depth: i32 = 0;
    var end: usize = brace_idx;
    var i: usize = brace_idx;
    while (i < profile_line.len) : (i += 1) {
        const c = profile_line[i];
        if (c == '{') depth += 1 else if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                end = i + 1;
                break;
            }
        }
    }
    if (depth != 0) return null;
    return profile_line[brace_idx..end];
}

// Unified CLI runner for tests (geodec). Accepts argv slice, returns stdout or error if exit!=0
pub fn runCli(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 21);
    _ = try child.stderr.?.readToEndAlloc(allocator, 1 << 19); // drain
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return error.NonZeroExit;
    return out;
}

// Parse op order from PROFILE line (returns slice of string slices owned by arena allocator)
pub fn parseOpNames(allocator: std.mem.Allocator, profile_line: []const u8) ![][]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, profile_line, .{});
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
    var list = std.ArrayList([]const u8).init(allocator);
    for (ops_arr) |opv| {
        if (opv != .object) return error.OpNotObject;
        const o = opv.object;
        const name_val = o.get("op") orelse return error.MissingOpName;
        if (name_val.* != .string) return error.OpNameNotString;
        // copy name into arena to ensure stable
        const dup = try allocator.dupe(u8, name_val.string);
        try list.append(dup);
    }
    return try list.toOwnedSlice();
}

// Assert that expected sequence appears in order within ops (not necessarily contiguous)
pub fn assertOpOrder(profile_line: []const u8, expected: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const ops = try parseOpNames(arena.allocator(), profile_line);
    var search_start: usize = 0;
    for (expected) |needle| {
        var found_index: ?usize = null;
        var i: usize = search_start;
        while (i < ops.len) : (i += 1) {
            if (std.mem.eql(u8, ops[i], needle)) {
                found_index = i;
                break;
            }
        }
        if (found_index == null) return error.ExpectedOpMissing;
        search_start = found_index.? + 1;
    }
}

pub const MemoryStats = struct { peak_bytes: usize = 0, net_bytes: usize = 0, total_alloc_bytes: usize = 0 };

pub fn parseMemory(profile_line: []const u8) ?MemoryStats {
    const slice = sliceMemory(profile_line) orelse return null;
    var peak: usize = 0;
    var net: usize = 0;
    var total: usize = 0;
    // crude scanning to avoid full parse again
    if (std.mem.indexOf(u8, slice, "\"peak_bytes\":")) |p| {
        peak = parseIntAfter(slice[p + 12 ..]);
    }
    if (std.mem.indexOf(u8, slice, "\"net_bytes\":")) |n| {
        net = parseIntAfter(slice[n + 11 ..]);
    }
    if (std.mem.indexOf(u8, slice, "\"total_alloc_bytes\":")) |t| {
        total = parseIntAfter(slice[t + 19 ..]);
    }
    return MemoryStats{ .peak_bytes = peak, .net_bytes = net, .total_alloc_bytes = total };
}

fn parseIntAfter(src: []const u8) usize {
    var val: usize = 0;
    var i: usize = 0;
    while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {
        val = val * 10 + @as(usize, src[i] - '0');
    }
    return val;
}
