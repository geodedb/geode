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

fn isNonDescendingNumeric(lines: []const u8) bool {
    // Simple scan: extract numbers for a single-column RETURN {"x":n}
    var it = std.mem.splitScalar(u8, lines, '\n');
    var last: i128 = -9_223_372_036_854_775_808; // min i64
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "{\"x\":")) |pos| {
            var i = pos + 5; // after {"x":
            var neg = false;
            if (i < ln.len and ln[i] == '-') {
                neg = true;
                i += 1;
            }
            var mant: i128 = 0;
            while (i < ln.len and ln[i] >= '0' and ln[i] <= '9') : (i += 1) {
                mant = mant * 10 + (ln[i] - '0');
            }
            if (neg) mant = -mant;
            if (mant < last) return false;
            last = mant;
        }
    }
    return true;
}

// Fuzz ORDER BY stability (deterministic seed) over random ints/decimals mapped to projection values.
// We keep it lightweight (few iterations) to avoid test time blow-up.

test "fuzz: ORDER BY numeric stability" {
    var prng = std.rand.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    const exe = "./zig-out/bin/geode";
    var iter: usize = 0;
    while (iter < 50) : (iter += 1) {
        // Build a simple RETURN of constants with ORDER BY x LIMIT to force sort path.
        var buf: [256]u8 = undefined;
        var fba = std.io.fixedBufferStream(&buf);
        const w = fba.writer();
        w.writeAll("RETURN ") catch {};
        const n = 5 + @as(usize, rnd.intRangeAtMost(usize, 0, 5));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i > 0) w.writeAll(",") catch {};
            // 50% decimals, 50% ints
            if (rnd.boolean()) {
                const iv = rnd.intRangeAtMost(i32, -20, 20);
                w.print("{d}", .{iv}) catch {};
            } else {
                const iv = rnd.intRangeAtMost(i32, -20, 20);
                const scale = rnd.intRangeAtMost(u8, 0, 2);
                if (scale > 0) {
                    var pow: i64 = 1;
                    var s: u8 = 0;
                    while (s < scale) : (s += 1) pow *= 10;
                    // produce decimal with optional trailing zeros
                    w.print("{d}.{s}", .{ iv", "0" }) catch {};
                } else {
                    w.print("{d}", .{iv}) catch {};
                }
            }
            if (i == 0) w.writeAll(" AS x") catch {};
        }
        w.writeAll(" ORDER BY x") catch {};
        const q = fba.getWritten();
        const res = try run(&.{ exe, q });
        defer std.testing.allocator.free(res.out);
        defer std.testing.allocator.free(res.err);
        try std.testing.expectEqual(@as(i32, 0), res.code);
        try std.testing.expect(isNonDescendingNumeric(res.out));
    }
}
