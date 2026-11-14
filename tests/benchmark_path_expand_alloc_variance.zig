const std = @import("std");
const planner = @import("../src/planner.zig");

// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=PathExpandAllocVarianceEnvelope; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_016_PathExpandAllocVarianceEnvelope; OWNER=planner; UPDATED=2026-11-14

// Simple counting allocator wrapper
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,

    fn allocFn(ctx: *anyopaque, len: usize, alignment: u29, ret_addr: usize) callconv(.Inline) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(ctx);
        self.allocations += 1;
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }
    fn resizeFn(ctx: *anyopaque, buf: []u8, alignment: u29, new_len: usize, ret_addr: usize) callconv(.Inline) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(ctx);
        return self.parent.vtable.resize(self.parent.ptr, buf, alignment, new_len, ret_addr);
    }
    fn freeFn(ctx: *anyopaque, buf: []u8, alignment: u29, ret_addr: usize) callconv(.Inline) void {
        const self: *CountingAllocator = @ptrCast(ctx);
        self.frees += 1;
        self.parent.vtable.free(self.parent.ptr, buf, alignment, ret_addr);
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        const vtable = std.mem.Allocator.VTable{
            .alloc = allocFn,
            .resize = resizeFn,
            .free = freeFn,
        };
        return .{ .ptr = self, .vtable = &vtable };
    }
};

fn buildLinear(allocator: std.mem.Allocator, n: usize) !planner.AdjacencyList {
    var adj = planner.AdjacencyList.init(allocator);
    var i: usize = 1;
    while (i < n) : (i += 1) {
        try adj.addEdge(@intCast(i), @intCast(i + 1), @intCast(9000 + i), allocator);
    }
    return adj;
}

fn stats(values: []u64) struct { mean: f64, stddev: f64, cv: f64, p95: u64 } {
    var sum: f128 = 0;
    for (values) |v| sum += @as(f128, @floatFromInt(v));
    const mean_f = sum / @as(f128, @floatFromInt(values.len));
    var acc: f128 = 0;
    for (values) |v| {
        const diff = @as(f128, @floatFromInt(v)) - mean_f;
        acc += diff * diff;
    }
    const variance = acc / @as(f128, @floatFromInt(values.len));
    const stddev = @as(f64, @floatCast(@sqrt(variance)));
    const mean = @as(f64, @floatCast(mean_f));
    const tmp = std.heap.page_allocator.alloc(u64, values.len) catch unreachable;
    defer std.heap.page_allocator.free(tmp);
    std.mem.copy(u64, tmp, values);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    return .{ .mean = mean, .stddev = stddev, .cv = if (mean == 0) 0 else stddev / mean, .p95 = p95 };
}

test "BenchmarkCANARY_REQ_GQL_016_PathExpandAllocVarianceEnvelope" {
    var counting = CountingAllocator{ .parent = std.heap.page_allocator }; // page allocator baseline
    const alloc = counting.allocator();
    var adj = try buildLinear(alloc, 150);
    defer adj.deinit(alloc);
    const expander = planner.PathExpand{ .min_hops = 1, .max_hops = 5, .tie_break_policy = .LengthId };
    const runs = 35;
    var alloc_counts = try alloc.alloc(u64, runs);
    defer alloc.free(alloc_counts);
    const start = [_]u64{1};
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        // Reset counts per run by snapshotting difference
        const before = counting.allocations;
        const res = try expander.execute(start[0..], &adj, alloc);
        for (res) |r| alloc.free(r.edge_ids);
        alloc.free(res);
        const after = counting.allocations;
        alloc_counts[i] = @intCast(after - before);
    }
    const st = stats(alloc_counts);
    // Allocation count variance should be quite stable (hot path class) CV ≤0.18 and p95/mean ≤2.4
    if (st.cv > 0.18 or @as(f128, @floatFromInt(st.p95)) > @as(f128, @floatCast(st.mean)) * 2.40) {
        std.debug.print("VARIANCE_FAIL PathExpandAllocVarianceEnvelope cv={:.4} p95={} mean={:.2}\n", .{ st.cv, st.p95, st.mean });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK PathExpandAllocVarianceEnvelope cv={:.4} p95={} mean={:.2}\n", .{ st.cv, st.p95, st.mean });
}
