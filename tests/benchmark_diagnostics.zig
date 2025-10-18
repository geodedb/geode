const std = @import("std");
const diag = @import("../src/diagnostics.zig");

// BenchmarkCANARY_REQ_GQL_010_DiagnosticsFold - measures folding cost over synthetic diagnostics list.

fn next(r: *u64) u64 {
    var x = r.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    r.* = x;
    return x * 2685821657736338717;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var timer = try std.time.Timer.start();
    const iterations: usize = 50_000; // keep under time limits

    var total_ns: u64 = 0;
    var seed: u64 = 0xDEADBEEFCAFEBABE;

    // PRNG usage (xorshift64*) to vary diagnostic patterns

    var buf = std.ArrayList(diag.Diagnostic).init(allocator);
    defer buf.deinit();

    var folded: ?diag.Diagnostic = null;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        buf.clearRetainingCapacity();
        const rem = next(&seed) % 5;
        const n: usize = @intCast(rem);
        const count = 3 + n;
        var j: usize = 0;
        while (j < count) : (j += 1) {
            const code = switch (next(&seed) % 4) {
                0 => diag.Code.us001_unordered_pagination,
                1 => diag.Code.illegal_order_key,
                2 => diag.Code.type_mismatch,
                else => diag.Code.group_by_illegal,
            };
            try buf.append(diag.Diagnostic{ .code = code, .anchor = .{ .start = 0, .end = 0 }, .message = "synthetic" });
        }
        folded = diag.foldDiagnostics(buf.items);
        std.debug.assert(folded != null);
    }
    total_ns = timer.read();

    const per_op = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations));

    // Output JSON line so CI can parse
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_010_DiagnosticsFold\",\"iterations\":{d},\"total_ns\":{d},\"ns_per_iter\":{d:.2}}\n", .{ iterations, total_ns, per_op });
}
