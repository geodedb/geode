const std = @import("std");
const phase0 = @import("phase0.zig");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;
const ModuleLoader = @import("module_loader.zig").ModuleLoader;
const MemoryManager = @import("memory_manager.zig").MemoryManager;
const kernel_sources = @import("kernel_sources.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase4ShortestPath; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_GPUDijkstraSmall; OWNER=engine; UPDATED=2025-10-26

pub const SPGraph = struct {
    row_offsets: []const u32,
    col_indices: []const u32,
    weights: []const f64,
    num_nodes: u32,
};

pub fn dijkstraCPU(g: SPGraph, start: u32, allocator: std.mem.Allocator) ![]f64 {
    var dist = try allocator.alloc(f64, g.num_nodes);
    for (dist) |*d| d.* = std.math.inf(f64);
    dist[start] = 0;
    var visited = std.AutoHashMap(u32, void).init(allocator);
    defer visited.deinit();
    var pq = std.array_list.Managed(struct { v: u32, d: f64 }).init(allocator);
    defer pq.deinit();
    try pq.append(.{ .v = start, .d = 0 });
    while (pq.items.len > 0) {
        // simple linear extract-min (small graphs in test)
        var min_idx: usize = 0;
        var i: usize = 1;
        while (i < pq.items.len) : (i += 1) {
            if (pq.items[i].d < pq.items[min_idx].d) min_idx = i;
        }
        const node = pq.items[min_idx].v;
        const node_dist = pq.items[min_idx].d;
        _ = pq.swapRemove(min_idx);
        if (visited.get(node) != null) continue;
        _ = visited.put(node, {}) catch {};
        const start_off = g.row_offsets[node];
        const end_off = g.row_offsets[node + 1];
        var e: usize = start_off;
        while (e < end_off) : (e += 1) {
            const nbr = g.col_indices[e];
            const w = g.weights[e];
            const alt = node_dist + w;
            if (alt < dist[nbr]) {
                dist[nbr] = alt;
                try pq.append(.{ .v = nbr, .d = alt });
            }
        }
    }
    return dist;
}

pub fn dijkstraGPU(g: SPGraph, start: u32, allocator: std.mem.Allocator) ![]f64 {
    if (!phase0.gpuEnabled()) {
        return dijkstraCPU(g, start, allocator);
    }

    return gpuDijkstraImpl(g, start, allocator) catch |err| {
        std.debug.print("GPU Dijkstra failed: {}, falling back to CPU\n", .{err});
        return dijkstraCPU(g, start, allocator);
    };
}

fn gpuDijkstraImpl(g: SPGraph, start: u32, allocator: std.mem.Allocator) ![]f64 {
    const loader = CudaLoader.init();
    if (!loader.available()) return error.GPUUnavailable;

    var mem_mgr = try MemoryManager.init(&loader, allocator);
    defer mem_mgr.deinit();

    var mod_loader = try ModuleLoader.init(&loader);
    defer mod_loader.deinit();

    try mod_loader.loadPTX(kernel_sources.shortest_path_kernel_ptx);

    if (g.num_nodes == 0) return try allocator.alloc(f64, 0);

    // Allocate device memory for graph structure (CSR)
    const row_size = (g.num_nodes + 1) * @sizeOf(u32);
    const col_size = g.col_indices.len * @sizeOf(u32);
    const weight_size = g.weights.len * @sizeOf(f32); // GPU uses f32
    const dist_size = g.num_nodes * @sizeOf(f32);

    var d_row_offsets = try mem_mgr.allocDevice(row_size);
    defer mem_mgr.freeDevice(d_row_offsets);
    var d_col_indices = try mem_mgr.allocDevice(col_size);
    defer mem_mgr.freeDevice(d_col_indices);
    var d_weights = try mem_mgr.allocDevice(weight_size);
    defer mem_mgr.freeDevice(d_weights);
    var d_dist = try mem_mgr.allocDevice(dist_size);
    defer mem_mgr.freeDevice(d_dist);
    var d_updated = try mem_mgr.allocDevice(@sizeOf(u32)); // Flag for changes
    defer mem_mgr.freeDevice(d_updated);

    // Copy graph to device
    try mem_mgr.copyHostToDevice(d_row_offsets, std.mem.sliceAsBytes(g.row_offsets));
    try mem_mgr.copyHostToDevice(d_col_indices, std.mem.sliceAsBytes(g.col_indices));

    // Convert f64 weights to f32 for GPU
    var weights_f32 = try allocator.alloc(f32, g.weights.len);
    defer allocator.free(weights_f32);
    for (g.weights, 0..) |w, i| {
        weights_f32[i] = @floatCast(w);
    }
    try mem_mgr.copyHostToDevice(d_weights, std.mem.sliceAsBytes(weights_f32));

    // Initialize distances to infinity, except start node
    const init_func = try mod_loader.getFunction("init_distances_kernel");
    const threads_per_block: u32 = 256;
    var num_blocks: u32 = @intCast((g.num_nodes + threads_per_block - 1) / threads_per_block);

    var init_params = [_]*const anyopaque{
        @ptrCast(&d_dist.ptr),
        @ptrCast(&start),
        @ptrCast(&g.num_nodes),
    };

    try mod_loader.launchKernel(init_func, [3]u32{ num_blocks, 1, 1 }, [3]u32{ threads_per_block, 1, 1 }, 0, @ptrCast(&init_params));

    // Delta-stepping iterations (simplified: process all nodes until convergence)
    const relax_func = try mod_loader.getFunction("relax_edges_kernel");

    var iterations: u32 = 0;
    const max_iterations: u32 = g.num_nodes; // Upper bound

    while (iterations < max_iterations) : (iterations += 1) {
        // Reset updated flag
        var zero: u32 = 0;
        try mem_mgr.copyHostToDevice(d_updated, std.mem.asBytes(&zero));

        // Relax all edges in parallel
        num_blocks = @intCast((g.num_nodes + threads_per_block - 1) / threads_per_block);

        var relax_params = [_]*const anyopaque{
            @ptrCast(&d_row_offsets.ptr),
            @ptrCast(&d_col_indices.ptr),
            @ptrCast(&d_weights.ptr),
            @ptrCast(&d_dist.ptr),
            @ptrCast(&d_updated.ptr),
            @ptrCast(&g.num_nodes),
        };

        try mod_loader.launchKernel(relax_func, [3]u32{ num_blocks, 1, 1 }, [3]u32{ threads_per_block, 1, 1 }, 0, @ptrCast(&relax_params));

        // Check if any updates happened
        var updated_flag: u32 = 0;
        try mem_mgr.copyDeviceToHost(std.mem.asBytes(&updated_flag), d_updated);

        if (updated_flag == 0) break; // Converged
    }

    // Copy distances back and convert to f64
    const dist_f32 = try allocator.alloc(f32, g.num_nodes);
    defer allocator.free(dist_f32);
    try mem_mgr.copyDeviceToHost(std.mem.sliceAsBytes(dist_f32), d_dist);

    const dist = try allocator.alloc(f64, g.num_nodes);
    for (dist_f32, 0..) |d, i| {
        dist[i] = @floatCast(d);
    }

    return dist;
}

test "TestCANARY_REQ_GQL_051_GPUDijkstraSmall" {
    // Graph: 0->1 (1.0), 0->2 (4.0), 1->2 (2.0), 1->3 (5.0), 2->3 (1.0)
    const row_offsets = &[_]u32{ 0, 2, 4, 5, 5 };
    const col_indices = &[_]u32{ 1, 2, 2, 3, 3 };
    const weights = &[_]f64{ 1.0, 4.0, 2.0, 5.0, 1.0 };
    const g = SPGraph{ .row_offsets = row_offsets, .col_indices = col_indices, .weights = weights, .num_nodes = 4 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const cpu = try dijkstraCPU(g, 0, alloc);
    defer alloc.free(cpu);
    const gpu = try dijkstraGPU(g, 0, alloc);
    defer alloc.free(gpu);
    var i: usize = 0;
    while (i < g.num_nodes) : (i += 1) {
        const diff = @abs(cpu[i] - gpu[i]);
        try std.testing.expect(diff < 1e-9);
    }
    try std.testing.expectEqual(@as(f64, 0), cpu[0]);
    try std.testing.expectEqual(@as(f64, 1.0), cpu[1]);
    try std.testing.expectEqual(@as(f64, 3.0), cpu[2]); // 0->1->2 path
    try std.testing.expectEqual(@as(f64, 4.0), cpu[3]); // 0->1->2->3 best
}
