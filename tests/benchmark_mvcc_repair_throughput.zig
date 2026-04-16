const std = @import("std");
const mvcc_adv = @import("mvcc_adv");
// CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=RepairThroughputBench; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_073_RepairThroughputBench; BENCH=BenchmarkCANARY_REQ_GQL_073_RepairThroughputBench; OWNER=txn; UPDATED=2025-09-20

test "BenchmarkCANARY_REQ_GQL_073_RepairThroughputBench" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var total: usize = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        total += try mvcc_adv.bench.simulateContention(100, 4, gpa.allocator());
    }
    try std.testing.expect(total == 1000);
}
