const std = @import("std");
const calibrate = @import("monitoring/variance_calibration.zig");

// CANARY: REQ=REQ-GQL-004; FEATURE="PaginationVarianceAutoCalibration"; ASPECT=Test; STATUS=TESTED; OWNER=planner; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-075; FEATURE="CostModelVarianceAutoCalibration"; ASPECT=Test; STATUS=TESTED; OWNER=planner; UPDATED=2025-09-27

fn makeSampleLines(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !void {
    const lines = [_][]const u8{
        "{\"name\":\"bench\",\"cv\":0.12,\"p95_mean_ratio\":1.08}\n",
        "{\"name\":\"bench\",\"cv\":0.11,\"p95_mean_ratio\":1.05}\n",
        "{\"name\":\"bench\",\"cv\":0.10,\"p95_mean_ratio\":1.02}\n",
        "{\"name\":\"bench\",\"cv\":0.13,\"p95_mean_ratio\":1.04}\n",
        "{\"name\":\"bench\",\"cv\":0.09,\"p95_mean_ratio\":1.01}\n",
        "{\"name\":\"bench\",\"cv\":0.50,\"p95_mean_ratio\":2.40}\n",
        "{\"name\":\"bench\",\"cv\":0.08,\"p95_mean_ratio\":0.99}\n",
    };
    for (lines) |ln| try list.appendSlice(alloc, ln);
}

fn runCalibration(alloc: std.mem.Allocator) !calibrate.Suggestion {
    var backing = std.ArrayList(u8).empty;
    defer backing.deinit(alloc);
    try backing.ensureTotalCapacity(alloc, 1024);
    try makeSampleLines(&backing, alloc);
    var reader = std.Io.Reader.fixed(backing.items);
    return try calibrate.calibrate(&reader, alloc, 1000);
}

// Test names follow CANARY naming conventions
pub fn main() !void {}

// Pagination variance calibration test
// The trimming logic should drop nothing (len < 20) and hence pick max cv 0.50 *1.05
// This is acceptable; we assert within epsilon.
test "TestCANARY_REQ_GQL_004_PaginationVarianceAutoCalibration" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const s = try runCalibration(alloc);
    try std.testing.expectApproxEqAbs(0.50 * 1.05, s.suggested_cv_max, 0.0001);
}

// Cost model variance calibration test (ratio field)
// Max p95_mean_ratio is 2.40; expect *1.10 headroom.
test "TestCANARY_REQ_GQL_075_CostModelVarianceAutoCalibration" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const s = try runCalibration(alloc);
    try std.testing.expectApproxEqAbs(2.40 * 1.10, s.suggested_p95_mean_ratio_max, 0.0001);
}
