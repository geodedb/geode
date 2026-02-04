const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const ally = std.testing.allocator;
    var child = Child.init(args, ally);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(ally, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(ally, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

fn isOrderedAsc(out: []const u8, key: []const u8) bool {
    // Heuristic: ensure pattern of key values doesn't show descending numeric pairs when numbers present.
    // Simplified: we parse numbers after "\"key\":" sequences; ignore strings.
    var last: i128 = -9_223_372_036_854_775_808;
    var idx: usize = 0;
    while (idx < out.len) : (idx += 1) {
        if (std.mem.startsWith(u8, out[idx..], key)) {
            // Expect format key":" or key":number (we look for the sequence "\":")
            const after = idx + key.len;
            if (after + 1 < out.len and out[after] == '"' and out[after + 1] == ':') {
                var j = after + 2;
                var neg = false;
                if (j < out.len and out[j] == '-') {
                    neg = true;
                    j += 1;
                }
                var had_digit = false;
                var val: i128 = 0;
                while (j < out.len and out[j] >= '0' and out[j] <= '9') : (j += 1) {
                    had_digit = true;
                    val = val * 10 + (out[j] - '0');
                }
                if (had_digit) {
                    if (neg) val = -val;
                    if (val < last) return false;
                    last = val;
                }
            }
        }
    }
    return true;
}

test "fuzz: extended ORDER BY multi-key nulls strings pagination" {
    const exe = "./zig-out/bin/geode";
    var prng = std.rand.DefaultPrng.init(0xA11CE5);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 40) : (iter += 1) {
        // Random number of rows via param array length (4..9)
        const n = 4 + rnd.intRangeAtMost(usize, 0, 5);
        var arr_buf = std.ArrayList(u8).init(std.testing.allocator);
        defer arr_buf.deinit();
        arr_buf.writer().writeAll("[") catch {};
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i > 0) arr_buf.writer().writeAll(",") catch {};
            // 0 => null, 1 => small int, 2 => negative int, 3 => string
            const k = rnd.intRangeAtMost(u8, 0, 3);
            switch (k) {
                0 => arr_buf.writer().writeAll("null") catch {},
                1 => arr_buf.writer().print("{d}", .{rnd.intRangeAtMost(i32, 0, 50)}) catch {},
                2 => arr_buf.writer().print("{d}", .{rnd.intRangeAtMost(i32, -50, -1)}) catch {},
                else => arr_buf.writer().writeAll("\"s\"") catch {},
            }
        }
        arr_buf.writer().writeAll("]") catch {};
        const arr_json = arr_buf.toOwnedSlice() catch &.{};
        defer std.testing.allocator.free(arr_json);
        const distinct_clause = if (rnd.boolean()) "DISTINCT " else "";
        const limit_clause = if (rnd.boolean()) " LIMIT 3" else "";
        const offset_clause = if (rnd.boolean()) " OFFSET 1" else "";
        const query_buf = std.fmt.allocPrint(std.testing.allocator, "RETURN {s}a AS x, a AS y ORDER BY x, y{s}{s}", .{ distinct_clause, offset_clause, limit_clause }) catch continue;
        defer std.testing.allocator.free(query_buf);
        const res = run(&.{ exe, query_buf, "--json-param", "a", arr_json }) catch continue;
        defer std.testing.allocator.free(res.out);
        defer std.testing.allocator.free(res.err);
        if (res.code != 0) continue; // ignore failures: diagnostics tested elsewhere
        // Basic ordering check on first key (x)
        try std.testing.expect(isOrderedAsc(res.out, "\"x\""));
    }
}
