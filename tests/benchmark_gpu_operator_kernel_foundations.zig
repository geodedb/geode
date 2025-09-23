const std = @import("std");
const accel = @import("../src/gpu/acceleration.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Operator Kernels"; ASPECT=Bench; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_051_GPUOperatorKernelFoundations; OWNER=accel; UPDATED=2025-09-23

fn makeChainGraph(ally: std.mem.Allocator, n: usize) ![]const []const u64 {
    var list = try ally.alloc([]const u64, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i + 1 < n) {
            list[i] = try ally.alloc(u64, 1);
            list[i][0] = @intCast(i + 1);
        } else {
            list[i] = &[_]u64{};
        }
    }
    return list;
}

test "BenchmarkCANARY_REQ_GQL_051_GPUOperatorKernelFoundations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    const sizes = [_]usize{ 1000, 1200, 1400, 1600, 1800 };
    var ratios = try ally.alloc(f64, sizes.len);
    defer ally.free(ratios);

    var i: usize = 0;
    while (i < sizes.len) : (i += 1) {
        const n = sizes[i];
        const adj = try makeChainGraph(ally, n);
        defer {
            var j: usize = 0;
            while (j < n) : (j += 1) {
                if (adj[j].len > 0 and @ptrFromInt(@intFromPtr(adj[j])) != @ptrFromInt(@intFromPtr(&[_]u64{}))) ally.free(adj[j]);
            }
            ally.free(adj);
        }
        const res = try accel.benchmarkGPU(ally, adj);
        const r = if (res.gpu_time_ms > 0) @as(f64, @floatFromInt(res.cpu_time_ms)) / @as(f64, @floatFromInt(res.gpu_time_ms)) else 0.0;
        ratios[i] = r;
        try std.testing.expect(r >= 1.0);
    }

    var sum: f64 = 0;
    for (ratios) |r| sum += r;
    const mean = sum / @as(f64, @floatFromInt(ratios.len));
    var var_acc: f64 = 0;
    for (ratios) |r| {
        const d = r - mean;
        var_acc += d * d;
    }
    const cv = if (mean == 0) 0 else @sqrt(var_acc / @as(f64, @floatFromInt(ratios.len))) / mean;
    try std.testing.expect(cv <= 0.23);
}
