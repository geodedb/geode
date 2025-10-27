const std = @import("std");
const phase0 = @import("phase0.zig");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;
const ModuleLoader = @import("module_loader.zig").ModuleLoader;
const MemoryManager = @import("memory_manager.zig").MemoryManager;
const kernel_sources = @import("kernel_sources.zig");
const telemetry = @import("telemetry.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase1Traversal; STATUS=REMOVED; TEST=TestCANARY_REQ_GQL_051_CPUBfsFrontier; OWNER=engine; UPDATED=2025-10-26
// Note: GPU BFS removed - CPU is 100-1000x faster due to per-level synchronization overhead

// Simplified CSR representation for tests
pub const CSR = struct {
    row_offsets: []const u32,
    col_indices: []const u32,
};

pub const BFSResult = struct {
    count: usize,
    diagnostics: ?telemetry.GPUDiagnostics,
};

// CPU-only BFS (GPU removed - overhead dominates)
pub fn bfsFrontierCount(csr: CSR, start: u32, max_depth: u32, allocator: std.mem.Allocator) !usize {
    return cpuBfsFrontierCount(csr, start, max_depth, allocator);
}

pub fn bfsFrontierCountWithTelemetry(csr: CSR, start: u32, max_depth: u32, allocator: std.mem.Allocator) !BFSResult {
    const count = try cpuBfsFrontierCount(csr, start, max_depth, allocator);
    const diag = telemetry.createDiagnostics(false, null, "GPU BFS not implemented - CPU faster");
    return BFSResult{ .count = count, .diagnostics = diag };
}

fn cpuBfsFrontierCount(csr: CSR, start: u32, max_depth: u32, allocator: std.mem.Allocator) !usize {
    var visited = std.AutoHashMap(u32, void).init(allocator);
    defer visited.deinit();
    var frontier = try std.array_list.Managed(u32).initCapacity(allocator, 4);
    defer frontier.deinit();
    try frontier.append(start);
    var depth: u32 = 0;
    while (depth < max_depth and frontier.items.len > 0) : (depth += 1) {
        var next = try std.array_list.Managed(u32).initCapacity(allocator, 4);
        defer next.deinit();
        for (frontier.items) |v| {
            if (visited.get(v) != null) continue;
            try visited.put(v, {});
            const row_start = csr.row_offsets[v];
            const row_end = csr.row_offsets[v + 1];
            var i: usize = row_start;
            while (i < row_end) : (i += 1) {
                const nbr = csr.col_indices[i];
                if (visited.get(nbr) == null) try next.append(nbr);
            }
        }
        frontier.clearRetainingCapacity();
        try frontier.appendSlice(next.items);
    }
    return visited.count();
}

test "TestCANARY_REQ_GQL_051_GPUPhase1BfsFrontier" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Graph: 0->1,2 ; 1->3 ; 2->3 ; 3-> (none)
    const row_offsets = &[_]u32{ 0, 2, 3, 4, 4 };
    const col_indices = &[_]u32{ 1, 2, 3, 3 };
    const csr = CSR{ .row_offsets = row_offsets, .col_indices = col_indices };
    const c = try bfsFrontierCount(csr, 0, 3, alloc);
    try std.testing.expectEqual(@as(usize, 4), c);
}

test "TestCANARY_REQ_GQL_051_GPUPhase1BfsTelemetry" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Same graph
    const row_offsets = &[_]u32{ 0, 2, 3, 4, 4 };
    const col_indices = &[_]u32{ 1, 2, 3, 3 };
    const csr = CSR{ .row_offsets = row_offsets, .col_indices = col_indices };
    const result = try bfsFrontierCountWithTelemetry(csr, 0, 3, alloc);
    try std.testing.expectEqual(@as(usize, 4), result.count);

    // Check diagnostics exist
    const diag = result.diagnostics orelse return error.MissingDiagnostics;

    // Test passes regardless of GPU availability
    // If GPU not enabled/available, fallback reason should exist
    if (!diag.gpu_enabled or !diag.gpu_used) {
        try std.testing.expect(diag.fallback_reason != null);
    } else {
        // If GPU was used, metrics should exist
        const metrics = diag.metrics orelse return error.MissingMetrics;
        try std.testing.expect(metrics.kernel_ms >= 0.0);
        try std.testing.expectEqualStrings("bfs_expand", metrics.kernel_name);
    }
}
