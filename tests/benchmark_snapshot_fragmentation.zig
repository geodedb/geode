const std = @import("std");
// BenchmarkCANARY_REQ_GQL_028_SnapshotFragmentation - simulates snapshot fragmentation accumulation.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Synthetic counters: we simulate snapshot segment churn
    var dead: u64 = 0;
    var live: u64 = 0;
    var i: usize = 0;
    while (i < 50000) : (i += 1) {
        if ((i % 5) == 0) dead += 3 else live += 5;
    }
    const ratio = if (dead + live > 0) @as(f64, @floatFromInt(dead)) / @as(f64, @floatFromInt(dead + live)) else 0.0;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_028_SnapshotFragmentation\",\"dead\":{d},\"live\":{d},\"ratio\":{d:.4}}\n", .{ dead, live, ratio });
    _ = allocator;
}
