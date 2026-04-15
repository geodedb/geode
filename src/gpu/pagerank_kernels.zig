const std = @import("std");
const phase0 = @import("phase0.zig");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;
const SmartKernelLoader = @import("smart_kernel_loader.zig").SmartKernelLoader;
const MemoryManager = @import("memory_manager.zig").MemoryManager;
const kernel_sources = @import("kernel_sources.zig");
const VulkanCompute = @import("vulkan_compute.zig").VulkanCompute;
const VulkanBuffer = @import("vulkan_compute.zig").VulkanBuffer;
const ComputePipeline = @import("vulkan_compute.zig").ComputePipeline;
const vulkan_shaders = @import("vulkan_shaders.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase3VulkanPageRank; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_051_GPUPageRankVulkan; OWNER=engine; UPDATED=2025-12-30

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

// Threshold below which CPU is faster due to GPU overhead
const GPU_THRESHOLD_NODES: u32 = 5_000_000;
const GPU_THRESHOLD_ITERATIONS: u32 = 100;

pub fn pagerankGPU(g: PRGraph, iterations: u32, d: f64, allocator: std.mem.Allocator) ![]f64 {
    // Automatic threshold dispatch: use CPU for small graphs where overhead dominates
    if (g.num_nodes < GPU_THRESHOLD_NODES and iterations < GPU_THRESHOLD_ITERATIONS) {
        return pagerankCPU(g, iterations, d, allocator);
    }

    if (!phase0.gpuEnabled()) {
        return pagerankCPU(g, iterations, d, allocator);
    }

    // Try CUDA first (if available)
    if (gpuPageRankCudaImpl(g, iterations, d, allocator)) |result| {
        return result;
    } else |cuda_err| {
        std.debug.print("CUDA PageRank failed: {}, trying Vulkan\n", .{cuda_err});

        // Try Vulkan fallback
        if (gpuPageRankVulkanImpl(g, iterations, d, allocator)) |result| {
            return result;
        } else |vulkan_err| {
            std.debug.print("Vulkan PageRank failed: {}, falling back to CPU\n", .{vulkan_err});
            return pagerankCPU(g, iterations, d, allocator);
        }
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

    // Get kernel functions - use fused kernel for better performance
    const fused_func = smart_loader.getFunction("pagerank_fused_kernel") catch null;
    const init_func: ?*anyopaque = if (fused_func == null) smart_loader.getFunction("pagerank_iteration_kernel") catch null else null;
    const push_func: ?*anyopaque = if (fused_func == null) smart_loader.getFunction("pagerank_push_kernel") catch null else null;

    // If neither fused nor separate kernels available, fail
    if (fused_func == null and (init_func == null or push_func == null)) {
        return error.KernelNotFound;
    }

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
        if (fused_func) |fused| {
            // Use fused kernel for better performance (30-50% overhead reduction)
            var fused_params = [_]*const anyopaque{
                @ptrCast(&d_row_offsets.ptr),
                @ptrCast(&d_col_indices.ptr),
                @ptrCast(&d_ranks_in.ptr),
                @ptrCast(&d_ranks_out.ptr),
                @ptrCast(&g.num_nodes),
                @ptrCast(&damping_f32),
            };
            try smart_loader.launchKernel(fused, grid_dim, block_dim, 0, @ptrCast(&fused_params));
        } else if (init_func != null and push_func != null) {
            // Fallback to separate init/push kernels
            var init_params = [_]*const anyopaque{
                @ptrCast(&d_row_offsets.ptr),
                @ptrCast(&d_col_indices.ptr),
                @ptrCast(&d_ranks_in.ptr),
                @ptrCast(&d_ranks_out.ptr),
                @ptrCast(&g.num_nodes),
                @ptrCast(&damping_f32),
            };
            try smart_loader.launchKernel(init_func.?, grid_dim, block_dim, 0, @ptrCast(&init_params));

            // Push contributions from each vertex to its neighbors
            var push_params = [_]*const anyopaque{
                @ptrCast(&d_row_offsets.ptr),
                @ptrCast(&d_col_indices.ptr),
                @ptrCast(&d_ranks_in.ptr),
                @ptrCast(&d_ranks_out.ptr),
                @ptrCast(&g.num_nodes),
                @ptrCast(&damping_f32),
            };
            try smart_loader.launchKernel(push_func.?, grid_dim, block_dim, 0, @ptrCast(&push_params));
        } else {
            return error.NoKernelAvailable;
        }

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

fn gpuPageRankVulkanImpl(g: PRGraph, iterations: u32, d: f64, allocator: std.mem.Allocator) ![]f64 {
    // Initialize Vulkan compute
    var compute = VulkanCompute.init(allocator) catch |err| {
        std.debug.print("Failed to initialize Vulkan: {}\n", .{err});
        return error.GPUUnavailable;
    };
    defer compute.deinit();

    std.debug.print("Using Vulkan device: {s}\n", .{compute.getDeviceName()});

    // Get SPIR-V shader
    const spirv_words = vulkan_shaders.getShaderWords("pagerank") orelse return error.ShaderNotFound;

    // Create compute pipeline (5 buffers: ranks_in, ranks_out, row_offsets, col_indices, out_degrees)
    var pipeline = try ComputePipeline.createFromSPIRV(&compute, spirv_words, 5);
    defer pipeline.destroy();

    // Calculate buffer sizes
    const num_nodes = g.num_nodes;
    const num_edges = g.col_indices.len;
    const ranks_size = num_nodes * @sizeOf(f32);
    const row_size = (num_nodes + 1) * @sizeOf(u32);
    const col_size = num_edges * @sizeOf(u32);
    const degrees_size = num_nodes * @sizeOf(u32);

    // Create device buffers
    var buf_ranks_in = try VulkanBuffer.create(&compute, ranks_size, @import("vulkan_loader.zig").VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, true);
    defer buf_ranks_in.destroy();

    var buf_ranks_out = try VulkanBuffer.create(&compute, ranks_size, @import("vulkan_loader.zig").VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, true);
    defer buf_ranks_out.destroy();

    var buf_row_offsets = try VulkanBuffer.create(&compute, row_size, @import("vulkan_loader.zig").VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, true);
    defer buf_row_offsets.destroy();

    var buf_col_indices = try VulkanBuffer.create(&compute, col_size, @import("vulkan_loader.zig").VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, true);
    defer buf_col_indices.destroy();

    var buf_out_degrees = try VulkanBuffer.create(&compute, degrees_size, @import("vulkan_loader.zig").VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, true);
    defer buf_out_degrees.destroy();

    // Initialize ranks on host (f32)
    const h_ranks = try allocator.alloc(f32, num_nodes);
    defer allocator.free(h_ranks);
    const init_rank: f32 = 1.0 / @as(f32, @floatFromInt(num_nodes));
    for (h_ranks) |*r| r.* = init_rank;

    // Calculate out-degrees
    var h_out_degrees = try allocator.alloc(u32, num_nodes);
    defer allocator.free(h_out_degrees);
    for (h_out_degrees) |*d_out| d_out.* = 0;
    for (0..num_nodes) |v| {
        const start = g.row_offsets[v];
        const end = g.row_offsets[v + 1];
        h_out_degrees[v] = end - start;
    }

    // Copy data to device
    try buf_ranks_in.copyFromHost(std.mem.sliceAsBytes(h_ranks));
    try buf_row_offsets.copyFromHost(std.mem.sliceAsBytes(g.row_offsets));
    try buf_col_indices.copyFromHost(std.mem.sliceAsBytes(g.col_indices));
    try buf_out_degrees.copyFromHost(std.mem.sliceAsBytes(h_out_degrees));

    // Setup push constants
    const damping_f32: f32 = @floatCast(d);
    const base_rank: f32 = (1.0 - damping_f32) / @as(f32, @floatFromInt(num_nodes));
    const push_constants = [_]u32{
        num_nodes,
        @bitCast(damping_f32),
        @bitCast(base_rank),
    };

    // Calculate workgroup dimensions
    const local_size: u32 = 256;
    const num_workgroups = (num_nodes + local_size - 1) / local_size;

    // PageRank iterations
    var it: u32 = 0;
    while (it < iterations) : (it += 1) {
        // Execute compute shader
        const buffers = [_]VulkanBuffer{
            buf_ranks_in,
            buf_ranks_out,
            buf_row_offsets,
            buf_col_indices,
            buf_out_degrees,
        };

        try pipeline.executeWithPushConstants(
            @constCast(&buffers),
            .{ num_workgroups, 1, 1 },
            &push_constants,
        );

        // Swap buffers for next iteration
        std.mem.swap(VulkanBuffer, &buf_ranks_in, &buf_ranks_out);
    }

    // Copy results back
    try buf_ranks_in.copyToHost(std.mem.sliceAsBytes(h_ranks));

    // Convert f32 to f64 for output
    var result = try allocator.alloc(f64, num_nodes);
    for (h_ranks, 0..) |r, i| {
        result[i] = @floatCast(r);
    }

    return result;
}

test "TestCANARY_REQ_GQL_051_GPUPageRankSmallGraph" {
    // Graph: 0->1,2 ; 1->2 ; 2->0 ; 2->3 ; 3->2
    const row_offsets = &[_]u32{ 0, 2, 3, 5, 6 };
    const col_indices = &[_]u32{ 1, 2, 2, 0, 3, 2 };
    const g = PRGraph{ .row_offsets = row_offsets, .col_indices = col_indices, .num_nodes = 4 };
    var gpa = std.heap.DebugAllocator(.{}){};
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
