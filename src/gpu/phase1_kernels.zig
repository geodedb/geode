const std = @import("std");
const phase0 = @import("phase0.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase1Traversal; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_GPUPhase1BfsFrontier; OWNER=engine; UPDATED=2025-10-25

// Simplified CSR representation for tests
pub const CSR = struct {
    row_offsets: []const u32,
    col_indices: []const u32,
};

pub fn bfsFrontierCount(csr: CSR, start: u32, max_depth: u32, allocator: std.mem.Allocator) !usize {
    if (!phase0.gpuEnabled()) {
        return cpuBfsFrontierCount(csr, start, max_depth, allocator);
    }
    // Placeholder GPU path: falls back to CPU; later replace with kernel launch
    return cpuBfsFrontierCount(csr, start, max_depth, allocator);
}

fn cpuBfsFrontierCount(csr: CSR, start: u32, max_depth: u32, allocator: std.mem.Allocator) !usize {
    var visited = std.AutoHashMap(u32, void).init(allocator);
    defer visited.deinit(); // visited nodes
    var frontier = try std.ArrayList(u32).initCapacity(allocator, 4);
    defer frontier.deinit(allocator);
    try frontier.append(allocator, start);
    var depth: u32 = 0;
    while (depth < max_depth and frontier.items.len > 0) : (depth += 1) {
        var next = try std.ArrayList(u32).initCapacity(allocator, 4);
        defer next.deinit(allocator);
        for (frontier.items) |v| {
            if (visited.get(v) != null) continue;
            try visited.put(v, {}); // mark visited
            const row_start = csr.row_offsets[v];
            const row_end = csr.row_offsets[v + 1];
            var i: usize = row_start;
            while (i < row_end) : (i += 1) {
                const nbr = csr.col_indices[i];
                if (visited.get(nbr) == null) try next.append(allocator, nbr);
            }
        }
        frontier.clearRetainingCapacity();
        try frontier.appendSlice(allocator, next.items);
    }
    return visited.count();
}

test "TestCANARY_REQ_GQL_051_GPUPhase1BfsFrontier" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Graph: 0->1,2 ; 1->3 ; 2->3 ; 3-> (none)
    const row_offsets = &[_]u32{0,2,3,4,4};
    const col_indices = &[_]u32{1,2,3,3};
    const csr = CSR{ .row_offsets = row_offsets, .col_indices = col_indices };
    const c = try bfsFrontierCount(csr, 0, 3, alloc);
    try std.testing.expectEqual(@as(usize, 4), c);
}
