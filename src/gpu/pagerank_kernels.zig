const std = @import("std");
const phase0 = @import("phase0.zig");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;
const SmartKernelLoader = @import("smart_kernel_loader.zig").SmartKernelLoader;
const MemoryManager = @import("memory_manager.zig").MemoryManager;
const kernel_sources = @import("kernel_sources.zig");
// Vulkan support temporarily disabled - needs build system refactoring for @cImport in modules
// const VulkanCompute = @import("vulkan_compute.zig").VulkanCompute;
// const VulkanBuffer = @import("vulkan_compute.zig").VulkanBuffer;
// const ComputePipeline = @import("vulkan_compute.zig").ComputePipeline;
// const vulkan_shaders = @import("vulkan_shaders.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase3VulkanPageRank; STATUS=WIP; TEST=TestCANARY_REQ_GQL_051_GPUPageRankVulkan; OWNER=engine; UPDATED=2025-10-26

pub const PRGraph = struct {
    row_offsets: []const u32,
    col_indices: []const u32,
    num_nodes: u32,
};

pub fn pagerankCPU(g: PRGraph, iterations: u32, d: f64, allocator: std.mem.Allocator) ![]f64 {
    var ranks = try allocator.alloc(f64, g.num_nodes);
    var new_ranks = try allocator.alloc(f64, g.num_nodes);
    for (ranks) |*r| r.* = 1.0 / @as(f64, @floatFromInt(g.num_nodes));
    var it: u32 = 0;
    while (it < iterations) : (it += 1) {
        for (new_ranks) |*nr| nr.* = 0;
        // distribute rank
        var v: u32 = 0;
        while (v < g.num_nodes) : (v += 1) {
            const start = g.row_offsets[v];
            const end = g.row_offsets[v + 1];
            const out_deg = end - start;
            if (out_deg == 0) continue;
            const share = ranks[v] / @as(f64, @floatFromInt(out_deg));
            var i: usize = start;
            while (i < end) : (i += 1) {
                const nbr = g.col_indices[i];
                new_ranks[nbr] += share;
            }
        }
        // apply damping & dangling mass redistribution
        var sum_new: f64 = 0;
        for (new_ranks) |nr| sum_new += nr;
        const leak = 1.0 - sum_new;
        const base = (1.0 - d) / @as(f64, @floatFromInt(g.num_nodes));
        var idx: usize = 0;
        while (idx < g.num_nodes) : (idx += 1) {
            ranks[idx] = base + d * (new_ranks[idx] + leak / @as(f64, @floatFromInt(g.num_nodes)));
        }
    }
    allocator.free(new_ranks);
    return ranks;
}

pub fn pagerankGPU(g: PRGraph, iterations: u32, d: f64, allocator: std.mem.Allocator) ![]f64 {
    if (!phase0.gpuEnabled()) {
        return pagerankCPU(g, iterations, d, allocator);
    }

    // Try CUDA, fallback to CPU (Vulkan temporarily disabled)
    if (gpuPageRankCudaImpl(g, iterations, d, allocator)) |result| {
        return result;
    } else |cuda_err| {
        std.debug.print("CUDA PageRank failed: {}, falling back to CPU\n", .{cuda_err});
        return pagerankCPU(g, iterations, d, allocator);
    }
}

fn gpuPageRankCudaImpl(g: PRGraph, iterations: u32, d: f64, allocator: std.mem.Allocator) ![]f64 {
    const loader = CudaLoader.init();
    if (!loader.available()) return error.GPUUnavailable;

    var mem_mgr = try MemoryManager.init(&loader, allocator);
    defer mem_mgr.deinit();

    var smart_loader = try SmartKernelLoader.init(&loader, allocator);
    defer smart_loader.deinit();

    // Load PageRank kernels (uses NVRTC if available)
    try smart_loader.loadPageRankKernels();

    // Get kernel functions
    const init_func = try smart_loader.getFunction("pagerank_iteration_kernel");
    const push_func = try smart_loader.getFunction("pagerank_push_kernel");

    // Allocate device memory for graph
    const row_size = (g.num_nodes + 1) * @sizeOf(u32);
    const col_size = g.col_indices.len * @sizeOf(u32);
    const ranks_size = g.num_nodes * @sizeOf(f32); // Use f32 on GPU for performance

    var d_row_offsets = try mem_mgr.allocDevice(row_size);
    defer mem_mgr.freeDevice(d_row_offsets);
    var d_col_indices = try mem_mgr.allocDevice(col_size);
    defer mem_mgr.freeDevice(d_col_indices);
    var d_ranks_in = try mem_mgr.allocDevice(ranks_size);
    defer mem_mgr.freeDevice(d_ranks_in);
    var d_ranks_out = try mem_mgr.allocDevice(ranks_size);
    defer mem_mgr.freeDevice(d_ranks_out);

    // Copy graph structure to device
    const row_bytes = std.mem.sliceAsBytes(g.row_offsets);
    const col_bytes = std.mem.sliceAsBytes(g.col_indices);
    try mem_mgr.copyHostToDevice(d_row_offsets, row_bytes);
    try mem_mgr.copyHostToDevice(d_col_indices, col_bytes);

    // Initialize ranks on host
    const h_ranks = try allocator.alloc(f32, g.num_nodes);
    defer allocator.free(h_ranks);
    const init_rank: f32 = 1.0 / @as(f32, @floatFromInt(g.num_nodes));
    for (h_ranks) |*r| r.* = init_rank;

    // Copy initial ranks to device
    const init_ranks_bytes = std.mem.sliceAsBytes(h_ranks);
    try mem_mgr.copyHostToDevice(d_ranks_in, init_ranks_bytes);

    // Prepare kernel parameters
    const damping_f32 = @as(f32, @floatCast(d));
    const threads_per_block: u32 = 256;
    const num_blocks = (g.num_nodes + threads_per_block - 1) / threads_per_block;
    const grid_dim = [3]u32{ num_blocks, 1, 1 };
    const block_dim = [3]u32{ threads_per_block, 1, 1 };

    // Power iteration with optimized push-based algorithm
    var it: u32 = 0;
    while (it < iterations) : (it += 1) {
        // Initialize ranks_out with base value (1-damping)/N
        var init_params = [_]*const anyopaque{
            @ptrCast(&d_row_offsets.ptr),
            @ptrCast(&d_col_indices.ptr),
            @ptrCast(&d_ranks_in.ptr),
            @ptrCast(&d_ranks_out.ptr),
            @ptrCast(&g.num_nodes),
            @ptrCast(&damping_f32),
        };
        try smart_loader.launchKernel(init_func, grid_dim, block_dim, 0, @ptrCast(&init_params));

        // Push contributions from each vertex to its neighbors
        var push_params = [_]*const anyopaque{
            @ptrCast(&d_row_offsets.ptr),
            @ptrCast(&d_col_indices.ptr),
            @ptrCast(&d_ranks_in.ptr),
            @ptrCast(&d_ranks_out.ptr),
            @ptrCast(&g.num_nodes),
            @ptrCast(&damping_f32),
        };
        try smart_loader.launchKernel(push_func, grid_dim, block_dim, 0, @ptrCast(&push_params));

        // Swap buffers for next iteration
        std.mem.swap(@TypeOf(d_ranks_in), &d_ranks_in, &d_ranks_out);
    }
    
    // Synchronize once at the end before copying results back
    try mem_mgr.synchronize();

    // Copy final ranks back to host
    const final_ranks_bytes = std.mem.sliceAsBytes(h_ranks);
    try mem_mgr.copyDeviceToHost(final_ranks_bytes, d_ranks_in);

    // Convert f32 to f64 for output
    var result = try allocator.alloc(f64, g.num_nodes);
    for (h_ranks, 0..) |r, i| {
        result[i] = @floatCast(r);
    }

    return result;
}

// Vulkan implementation temporarily disabled - needs build system refactoring
// fn gpuPageRankVulkanImpl(g: PRGraph, iterations: u32, d: f64, allocator: std.mem.Allocator) ![]f64 {
//     ... (implementation preserved in git history)
// }

test "TestCANARY_REQ_GQL_051_GPUPageRankSmallGraph" {
    // Graph: 0->1,2 ; 1->2 ; 2->0 ; 2->3 ; 3->2
    const row_offsets = &[_]u32{ 0, 2, 3, 5, 6 };
    const col_indices = &[_]u32{ 1, 2, 2, 0, 3, 2 };
    const g = PRGraph{ .row_offsets = row_offsets, .col_indices = col_indices, .num_nodes = 4 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const cpu = try pagerankCPU(g, 20, 0.85, alloc);
    defer alloc.free(cpu);
    const gpu = try pagerankGPU(g, 20, 0.85, alloc);
    defer alloc.free(gpu);
    var sum_cpu: f64 = 0;
    var sum_gpu: f64 = 0;
    var i: usize = 0;
    while (i < g.num_nodes) : (i += 1) {
        sum_cpu += cpu[i];
        sum_gpu += gpu[i];
        const diff = @abs(cpu[i] - gpu[i]);
        try std.testing.expect(diff < 1e-9);
    }
    // sum of ranks approx 1.0
    try std.testing.expect(@abs(sum_cpu - 1.0) < 1e-9);
    try std.testing.expect(@abs(sum_gpu - 1.0) < 1e-9);
}
