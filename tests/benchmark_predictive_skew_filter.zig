const std = @import("std");
const mvcc_adv = @import("transactions/mvcc_adv/mod.zig");

// BenchmarkCANARY_REQ_GQL_073_PredictiveSkewFilter
test "BenchmarkCANARY_REQ_GQL_073_PredictiveSkewFilter" {
    var filter = mvcc_adv.skew.PredictiveSkewFilter.init(std.testing.allocator);
    defer filter.deinit();
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < 200_000) : (i += 1) {
        // 90% hot key, 10% cold churn
        if ((i % 10) != 0) {
            filter.noteAccess("hot", true);
        } else {
            var buf: [16]u8 = undefined;
            const k = try std.fmt.bufPrint(&buf, "c{d}", .{i % 97});
            filter.noteAccess(k, false);
        }
    }
    const ns = timer.read();
    std.debug.print("PredictiveSkewFilter iterations=200000 ns={} hot={}\n", .{ ns, filter.isHot("hot") });
    // Expect hotspot recognized
    try std.testing.expect(filter.isHot("hot"));
}
