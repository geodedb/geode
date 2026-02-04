const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 18);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

fn extractProfileLine(out: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"PROFILE\"") != null) return line;
    }
    return null;
}

test "protocol: flag list invariants (I: first, unique, known set)" {
    const exe = "./zig-out/bin/geode";
    // UNION DISTINCT triggers Distinct + UnionPhase flags, unordered => DistinctOutputUnordered
    const out = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 2 AS x" });
    defer testing.allocator.free(out);
    const pl = extractProfileLine(out) orelse return error.MissingProfile;
    const start = std.mem.indexOf(u8, pl, "\"flagger_findings\":") orelse return error.NoFlags;
    const slice = pl[start..];
    const open = std.mem.indexOf(u8, slice, "[") orelse return error.BadFlags;
    const close = std.mem.indexOf(u8, slice, "]") orelse return error.BadFlags2;
    const inner = slice[open + 1 .. close];
    var flags_iter = std.mem.splitScalar(u8, inner, ',');
    var seen = std.AutoHashMap([]const u8, void).init(testing.allocator);
    defer seen.deinit();
    var index: usize = 0;
    const allowed = [_][]const u8{
        "I:IllegalOrderKeyPolicy=ident-only",
        "U:NullsFirstPolicy",
        "U:NullsLastPolicy",
        "U:DistinctOutputUnordered",
        "U:OrderTiebreak=LexJSON",
        "U:UnionPhaseTimings",
    };
    while (flags_iter.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \"\n\r");
        if (part.len == 0) continue;
        // Expect I: first if present
        if (index == 0) try testing.expect(std.mem.startsWith(u8, part, "I:"));
        // uniqueness
        try testing.expect(!seen.contains(part));
        try seen.put(part, {}) catch return error.OOM;
        var ok = false;
        inline for (allowed) |a| {
            if (std.mem.eql(u8, a, part)) {
                ok = true;
                break;
            }
        }
        try testing.expect(ok);
        index += 1;
    }
    try testing.expect(index >= 3); // Expect at least Illegal + Nulls* + DistinctOutputUnordered
}
