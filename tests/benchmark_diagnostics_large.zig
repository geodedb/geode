const std = @import("std");
const diag = @import("../src/diagnostics.zig");

// BenchmarkCANARY_REQ_GQL_010_DiagnosticsFoldLarge - large scale folding benchmark (stress test scenario).
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var timer = try std.time.Timer.start();
    const iterations: usize = 5_000; // fewer iterations but much larger arrays
    const width: usize = 256; // wide diagnostic batches

    var arr = try allocator.alloc(diag.Diagnostic, width);
    defer allocator.free(arr);

    var seed: u64 = 0x1234_5678_ABCD_EF00;
    inline for (.{}) |_| {} // placeholder for potential compile-time config

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var j: usize = 0;
        while (j < width) : (j += 1) {
            const kind = (seed ^ (seed >> 13) ^ (seed << 7)) % 4;
            seed +%= 0x9E3779B97F4A7C15;
            arr[j] = diag.Diagnostic{ .code = switch (kind) {
                0 => diag.Code.us001_unordered_pagination,
                1 => diag.Code.illegal_order_key,
                2 => diag.Code.type_mismatch,
                else => diag.Code.group_by_illegal,
            }, .anchor = .{ .start = 0, .end = 0 }, .message = "synthetic" };
        }
        const folded = diag.foldDiagnostics(arr);
        std.debug.assert(folded != null);
    }
    const elapsed = timer.read();
    const per_iter = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_010_DiagnosticsFoldLarge\",\"iterations\":{d},\"total_ns\":{d},\"ns_per_iter\":{d:.2}}\n", .{ iterations, elapsed, per_iter });
}
