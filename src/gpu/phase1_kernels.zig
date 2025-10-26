const std = @import("std");
const phase0 = @import("phase0.zig");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;
const ModuleLoader = @import("module_loader.zig").ModuleLoader;
const MemoryManager = @import("memory_manager.zig").MemoryManager;
const kernel_sources = @import("kernel_sources.zig");
const telemetry = @import("telemetry.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase1Traversal; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_GPUPhase1BfsFrontier; OWNER=engine; UPDATED=2025-10-26

// Simplified CSR representation for tests
pub const CSR = struct {
    row_offsets: []const u32,
    col_indices: []const u32,
};

pub const BFSResult = struct {
    count: usize,
    diagnostics: ?telemetry.GPUDiagnostics,
};

pub fn bfsFrontierCount(csr: CSR, start: u32, max_depth: u32, allocator: std.mem.Allocator) !usize {
    if (!phase0.gpuEnabled()) {
        return cpuBfsFrontierCount(csr, start, max_depth, allocator);
    }
    
    // Try GPU path, fallback to CPU on error
    return gpuBfsFrontierCount(csr, start, max_depth, allocator) catch |err| {
        // Log fallback (in production, use proper logging)
        std.debug.print("GPU BFS failed: {}, falling back to CPU\n", .{err});
        return cpuBfsFrontierCount(csr, start, max_depth, allocator);
    };
}

pub fn bfsFrontierCountWithTelemetry(csr: CSR, start: u32, max_depth: u32, allocator: std.mem.Allocator) !BFSResult {
    if (!phase0.gpuEnabled()) {
        const count = try cpuBfsFrontierCount(csr, start, max_depth, allocator);
        const diag = telemetry.createDiagnostics(false, null, "GPU not enabled");
        return BFSResult{ .count = count, .diagnostics = diag };
    }
    
    // Try GPU path with telemetry
    return gpuBfsFrontierCountWithTelemetry(csr, start, max_depth, allocator) catch |err| {
        const count = try cpuBfsFrontierCount(csr, start, max_depth, allocator);
        var buf: [128]u8 = undefined;
        const reason = std.fmt.bufPrint(&buf, "GPU error: {}", .{err}) catch "GPU error";
        const diag = telemetry.createDiagnostics(false, null, reason);
        return BFSResult{ .count = count, .diagnostics = diag };
    };
}

fn gpuBfsFrontierCount(csr: CSR, start: u32, max_depth: u32, allocator: std.mem.Allocator) !usize {
    const loader = CudaLoader.init();
    if (!loader.available()) return error.GPUUnavailable;
    
    var mem_mgr = try MemoryManager.init(&loader, allocator);
    defer mem_mgr.deinit();
    
    var mod_loader = try ModuleLoader.init(&loader);
    defer mod_loader.deinit();
    
    // Load PTX module
    try mod_loader.loadPTX(kernel_sources.bfs_kernel_ptx);
    
    // Get kernel function
    const kernel_func = try mod_loader.getFunction("bfs_expand_kernel");
    
    const num_vertices = csr.row_offsets.len - 1;
    
    // Allocate device memory for CSR
    const row_size = csr.row_offsets.len * @sizeOf(u32);
    const col_size = csr.col_indices.len * @sizeOf(u32);
    const visited_size = num_vertices * @sizeOf(u8);
    
    var d_row_offsets = try mem_mgr.allocDevice(row_size);
    defer mem_mgr.freeDevice(d_row_offsets);
    var d_col_indices = try mem_mgr.allocDevice(col_size);
    defer mem_mgr.freeDevice(d_col_indices);
    var d_visited = try mem_mgr.allocDevice(visited_size);
    defer mem_mgr.freeDevice(d_visited);
    
    // Copy CSR to device
    const row_bytes = std.mem.sliceAsBytes(csr.row_offsets);
    const col_bytes = std.mem.sliceAsBytes(csr.col_indices);
    try mem_mgr.copyHostToDevice(d_row_offsets, row_bytes);
    try mem_mgr.copyHostToDevice(d_col_indices, col_bytes);
    
    // Initialize visited array to 0
    const visited_init = try allocator.alloc(u8, num_vertices);
    defer allocator.free(visited_init);
    @memset(visited_init, 0);
    try mem_mgr.copyHostToDevice(d_visited, visited_init);
    
    // BFS execution with frontiers
    const max_frontier_size = num_vertices;
    var h_frontier_in = try allocator.alloc(u32, max_frontier_size);
    defer allocator.free(h_frontier_in);
    var h_frontier_out = try allocator.alloc(u32, max_frontier_size);
    defer allocator.free(h_frontier_out);
    
    h_frontier_in[0] = start;
    var current_frontier_size: u32 = 1;
    var total_visited: usize = 0;
    
    var depth: u32 = 0;
    while (depth < max_depth and current_frontier_size > 0) : (depth += 1) {
        total_visited += current_frontier_size;
        
        const frontier_in_size = current_frontier_size * @sizeOf(u32);
        const frontier_out_size = max_frontier_size * @sizeOf(u32);
        const frontier_out_count_size = @sizeOf(u32);
        
        var d_frontier_in = try mem_mgr.allocDevice(frontier_in_size);
        defer mem_mgr.freeDevice(d_frontier_in);
        var d_frontier_out = try mem_mgr.allocDevice(frontier_out_size);
        defer mem_mgr.freeDevice(d_frontier_out);
        var d_frontier_out_count = try mem_mgr.allocDevice(frontier_out_count_size);
        defer mem_mgr.freeDevice(d_frontier_out_count);
        
        // Copy frontier to device
        const frontier_in_bytes = std.mem.sliceAsBytes(h_frontier_in[0..current_frontier_size]);
        try mem_mgr.copyHostToDevice(d_frontier_in, frontier_in_bytes);
        
        // Initialize out count to 0
        var out_count_init: u32 = 0;
        const out_count_bytes = std.mem.asBytes(&out_count_init);
        try mem_mgr.copyHostToDevice(d_frontier_out_count, out_count_bytes);
        
        // Prepare kernel parameters (array of pointers)
        const num_vertices_u32: u32 = @intCast(num_vertices);
        var params = [_]*const anyopaque{
            @ptrCast(&d_frontier_in.ptr),
            @ptrCast(&current_frontier_size),
            @ptrCast(&d_frontier_out.ptr),
            @ptrCast(&d_frontier_out_count.ptr),
            @ptrCast(&d_row_offsets.ptr),
            @ptrCast(&d_col_indices.ptr),
            @ptrCast(&d_visited.ptr),
            @ptrCast(&num_vertices_u32),
        };
        
        // Launch kernel
        const threads_per_block: u32 = 256;
        const num_blocks = (current_frontier_size + threads_per_block - 1) / threads_per_block;
        const grid_dim = [3]u32{ num_blocks, 1, 1 };
        const block_dim = [3]u32{ threads_per_block, 1, 1 };
        
        try mod_loader.launchKernel(kernel_func, grid_dim, block_dim, 0, @ptrCast(&params));
        
        // Copy results back
        var next_frontier_size: u32 = 0;
        const next_size_bytes = std.mem.asBytes(&next_frontier_size);
        try mem_mgr.copyDeviceToHost(next_size_bytes, d_frontier_out_count);
        
        if (next_frontier_size == 0 or next_frontier_size > max_frontier_size) break;
        
        const next_frontier_bytes = std.mem.sliceAsBytes(h_frontier_out[0..next_frontier_size]);
        try mem_mgr.copyDeviceToHost(next_frontier_bytes, d_frontier_out);
        
        // Swap frontiers
        std.mem.swap([]u32, &h_frontier_in, &h_frontier_out);
        current_frontier_size = next_frontier_size;
    }
    
    return total_visited;
}

fn gpuBfsFrontierCountWithTelemetry(csr: CSR, start: u32, max_depth: u32, allocator: std.mem.Allocator) !BFSResult {
    const loader = CudaLoader.init();
    if (!loader.available()) return error.GPUUnavailable;
    
    // Create event timer for profiling
    var timer = try telemetry.EventTimer.init(&loader);
    defer timer.deinit();
    
    timer.recordStart();
    
    var mem_mgr = try MemoryManager.init(&loader, allocator);
    defer mem_mgr.deinit();
    
    var mod_loader = try ModuleLoader.init(&loader);
    defer mod_loader.deinit();
    
    // Load PTX module
    try mod_loader.loadPTX(kernel_sources.bfs_kernel_ptx);
    
    // Get kernel function
    const kernel_func = try mod_loader.getFunction("bfs_expand_kernel");
    
    const num_vertices = csr.row_offsets.len - 1;
    
    // Allocate device memory for CSR
    const row_size = csr.row_offsets.len * @sizeOf(u32);
    const col_size = csr.col_indices.len * @sizeOf(u32);
    const visited_size = num_vertices * @sizeOf(u8);
    
    var d_row_offsets = try mem_mgr.allocDevice(row_size);
    defer mem_mgr.freeDevice(d_row_offsets);
    var d_col_indices = try mem_mgr.allocDevice(col_size);
    defer mem_mgr.freeDevice(d_col_indices);
    var d_visited = try mem_mgr.allocDevice(visited_size);
    defer mem_mgr.freeDevice(d_visited);
    
    // Copy CSR to device
    const row_bytes = std.mem.sliceAsBytes(csr.row_offsets);
    const col_bytes = std.mem.sliceAsBytes(csr.col_indices);
    try mem_mgr.copyHostToDevice(d_row_offsets, row_bytes);
    try mem_mgr.copyHostToDevice(d_col_indices, col_bytes);
    
    // Initialize visited array to 0
    const visited_init = try allocator.alloc(u8, num_vertices);
    defer allocator.free(visited_init);
    @memset(visited_init, 0);
    try mem_mgr.copyHostToDevice(d_visited, visited_init);
    
    // BFS execution with frontiers
    const max_frontier_size = num_vertices;
    var h_frontier_in = try allocator.alloc(u32, max_frontier_size);
    defer allocator.free(h_frontier_in);
    var h_frontier_out = try allocator.alloc(u32, max_frontier_size);
    defer allocator.free(h_frontier_out);
    
    h_frontier_in[0] = start;
    var current_frontier_size: u32 = 1;
    var total_visited: usize = 0;
    
    var depth: u32 = 0;
    while (depth < max_depth and current_frontier_size > 0) : (depth += 1) {
        total_visited += current_frontier_size;
        
        const frontier_in_size = current_frontier_size * @sizeOf(u32);
        const frontier_out_size = max_frontier_size * @sizeOf(u32);
        const frontier_out_count_size = @sizeOf(u32);
        
        var d_frontier_in = try mem_mgr.allocDevice(frontier_in_size);
        defer mem_mgr.freeDevice(d_frontier_in);
        var d_frontier_out = try mem_mgr.allocDevice(frontier_out_size);
        defer mem_mgr.freeDevice(d_frontier_out);
        var d_frontier_out_count = try mem_mgr.allocDevice(frontier_out_count_size);
        defer mem_mgr.freeDevice(d_frontier_out_count);
        
        // Copy frontier to device
        const frontier_in_bytes = std.mem.sliceAsBytes(h_frontier_in[0..current_frontier_size]);
        try mem_mgr.copyHostToDevice(d_frontier_in, frontier_in_bytes);
        
        // Initialize out count to 0
        var out_count_init: u32 = 0;
        const out_count_bytes = std.mem.asBytes(&out_count_init);
        try mem_mgr.copyHostToDevice(d_frontier_out_count, out_count_bytes);
        
        // Prepare kernel parameters (array of pointers)
        const num_vertices_u32: u32 = @intCast(num_vertices);
        var params = [_]*const anyopaque{
            @ptrCast(&d_frontier_in.ptr),
            @ptrCast(&current_frontier_size),
            @ptrCast(&d_frontier_out.ptr),
            @ptrCast(&d_frontier_out_count.ptr),
            @ptrCast(&d_row_offsets.ptr),
            @ptrCast(&d_col_indices.ptr),
            @ptrCast(&d_visited.ptr),
            @ptrCast(&num_vertices_u32),
        };
        
        // Launch kernel
        const threads_per_block: u32 = 256;
        const num_blocks = (current_frontier_size + threads_per_block - 1) / threads_per_block;
        const grid_dim = [3]u32{ num_blocks, 1, 1 };
        const block_dim = [3]u32{ threads_per_block, 1, 1 };
        
        try mod_loader.launchKernel(kernel_func, grid_dim, block_dim, 0, @ptrCast(&params));
        
        // Copy results back
        var next_frontier_size: u32 = 0;
        const next_size_bytes = std.mem.asBytes(&next_frontier_size);
        try mem_mgr.copyDeviceToHost(next_size_bytes, d_frontier_out_count);
        
        if (next_frontier_size == 0 or next_frontier_size > max_frontier_size) break;
        
        const next_frontier_bytes = std.mem.sliceAsBytes(h_frontier_out[0..next_frontier_size]);
        try mem_mgr.copyDeviceToHost(next_frontier_bytes, d_frontier_out);
        
        // Swap frontiers
        std.mem.swap([]u32, &h_frontier_in, &h_frontier_out);
        current_frontier_size = next_frontier_size;
    }
    
    timer.recordEnd();
    const elapsed_ms = timer.getElapsedMs();
    
    const metrics = telemetry.recordKernelMetrics("bfs_expand", 0, elapsed_ms);
    const diag = telemetry.createDiagnostics(true, metrics, null);
    
    return BFSResult{ .count = total_visited, .diagnostics = diag };
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Graph: 0->1,2 ; 1->3 ; 2->3 ; 3-> (none)
    const row_offsets = &[_]u32{0,2,3,4,4};
    const col_indices = &[_]u32{1,2,3,3};
    const csr = CSR{ .row_offsets = row_offsets, .col_indices = col_indices };
    const c = try bfsFrontierCount(csr, 0, 3, alloc);
    try std.testing.expectEqual(@as(usize, 4), c);
}

test "TestCANARY_REQ_GQL_051_GPUPhase1BfsTelemetry" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Same graph
    const row_offsets = &[_]u32{0,2,3,4,4};
    const col_indices = &[_]u32{1,2,3,3};
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
