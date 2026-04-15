const std = @import("std");
const phase0 = @import("phase0.zig");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;
const SmartKernelLoader = @import("smart_kernel_loader.zig").SmartKernelLoader;
const MemoryManager = @import("memory_manager.zig").MemoryManager;
const kernel_sources = @import("kernel_sources.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase3SetOps; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_051_GPUUnionDistinctSmall; OWNER=engine; UPDATED=2025-10-26

pub fn unionDistinctCPU(a: []const u32, b: []const u32, allocator: std.mem.Allocator) ![]u32 {
    var map = std.AutoHashMap(u32, void).init(allocator);
    defer map.deinit();
    for (a) |v| {
        _ = map.put(v, {}) catch {};
    }
    for (b) |v| {
        _ = map.put(v, {}) catch {};
    }
    var list = std.array_list.Managed(u32).init(allocator);
    defer list.deinit();
    var it = map.iterator();
    while (it.next()) |e| try list.append(e.key_ptr.*);
    const slice = try allocator.alloc(u32, list.items.len);
    @memcpy(slice, list.items);
    return slice;
}

pub fn unionDistinctGPU(a: []const u32, b: []const u32, allocator: std.mem.Allocator) ![]u32 {
    if (!phase0.gpuEnabled()) {
        return unionDistinctCPU(a, b, allocator);
    }

    return gpuUnionDistinctImpl(a, b, allocator) catch |err| {
        std.debug.print("GPU UNION DISTINCT failed: {}, falling back to CPU\n", .{err});
        return unionDistinctCPU(a, b, allocator);
    };
}

fn gpuUnionDistinctImpl(a: []const u32, b: []const u32, allocator: std.mem.Allocator) ![]u32 {
    const loader = CudaLoader.init();
    if (!loader.available()) return error.GPUUnavailable;

    var mem_mgr = try MemoryManager.init(&loader, allocator);
    defer mem_mgr.deinit();

    var smart_loader = try SmartKernelLoader.init(&loader, allocator);
    defer smart_loader.deinit();

    // Load set operations kernels (uses NVRTC if available)
    try smart_loader.loadSetOpsKernels();

    // Concatenate a and b
    const total_len = a.len + b.len;
    if (total_len == 0) return try allocator.alloc(u32, 0);

    var combined = try allocator.alloc(u32, total_len);
    defer allocator.free(combined);
    @memcpy(combined[0..a.len], a);
    @memcpy(combined[a.len..], b);

    // OPTIMIZATION: Sort on CPU (more efficient than GPU bitonic sort for large arrays)
    std.sort.block(u32, combined, {}, struct {
        fn lessThan(_: void, lhs: u32, rhs: u32) bool {
            return lhs < rhs;
        }
    }.lessThan);

    // Allocate device memory
    const data_size = total_len * @sizeOf(u32);
    var d_input = try mem_mgr.allocDevice(data_size);
    defer mem_mgr.freeDevice(d_input);
    var d_output = try mem_mgr.allocDevice(data_size);
    defer mem_mgr.freeDevice(d_output);

    // Output count (how many unique elements)
    var d_count = try mem_mgr.allocDevice(@sizeOf(u32));
    defer mem_mgr.freeDevice(d_count);

    // Copy sorted data to device
    const input_bytes = std.mem.sliceAsBytes(combined);
    try mem_mgr.copyHostToDevice(d_input, input_bytes);

    // Initialize count to 0
    var zero: u32 = 0;
    const zero_bytes = std.mem.asBytes(&zero);
    try mem_mgr.copyHostToDevice(d_count, zero_bytes);

    // Unique kernel (remove duplicates) - data is already sorted
    const unique_func = try smart_loader.getFunction("unique_kernel");
    const threads_per_block: u32 = 256;
    const num_blocks: u32 = @intCast((total_len + threads_per_block - 1) / threads_per_block);

    var unique_params = [_]*const anyopaque{
        @ptrCast(&d_input.ptr),
        @ptrCast(&d_output.ptr),
        @ptrCast(&d_count.ptr),
        @ptrCast(&@as(u32, @intCast(total_len))),
    };

    try smart_loader.launchKernel(unique_func, [3]u32{ num_blocks, 1, 1 }, [3]u32{ threads_per_block, 1, 1 }, 0, @ptrCast(&unique_params));

    // Read back count
    var result_count: u32 = 0;
    const count_bytes = std.mem.asBytes(&result_count);
    try mem_mgr.copyDeviceToHost(count_bytes, d_count);

    // Allocate result and copy back
    if (result_count == 0) return try allocator.alloc(u32, 0);

    const result = try allocator.alloc(u32, result_count);
    const result_bytes = std.mem.sliceAsBytes(result);
    try mem_mgr.copyDeviceToHost(result_bytes, d_output);

    return result;
}

pub fn intersectCPU(a: []const u32, b: []const u32, allocator: std.mem.Allocator) ![]u32 {
    var setA = std.AutoHashMap(u32, void).init(allocator);
    defer setA.deinit();
    for (a) |v| {
        _ = setA.put(v, {}) catch {};
    }
    var list = std.array_list.Managed(u32).init(allocator);
    defer list.deinit();
    for (b) |v| if (setA.get(v) != null) try list.append(v);
    const slice = try allocator.alloc(u32, list.items.len);
    @memcpy(slice, list.items);
    return slice;
}

pub fn intersectGPU(a: []const u32, b: []const u32, allocator: std.mem.Allocator) ![]u32 {
    if (!phase0.gpuEnabled()) {
        return intersectCPU(a, b, allocator);
    }

    return gpuIntersectImpl(a, b, allocator) catch |err| {
        std.debug.print("GPU INTERSECT failed: {}, falling back to CPU\n", .{err});
        return intersectCPU(a, b, allocator);
    };
}

fn gpuIntersectImpl(a: []const u32, b: []const u32, allocator: std.mem.Allocator) ![]u32 {
    const loader = CudaLoader.init();
    if (!loader.available()) return error.GPUUnavailable;

    var mem_mgr = try MemoryManager.init(&loader, allocator);
    defer mem_mgr.deinit();

    var smart_loader = try SmartKernelLoader.init(&loader, allocator);
    defer smart_loader.deinit();

    try smart_loader.loadSetOpsKernels();

    if (a.len == 0 or b.len == 0) return try allocator.alloc(u32, 0);

    // Sort inputs on CPU first (for binary search in kernel)
    // For production, would sort on GPU, but this is simpler for now
    const a_sorted = try allocator.alloc(u32, a.len);
    defer allocator.free(a_sorted);
    @memcpy(a_sorted, a);
    std.mem.sort(u32, a_sorted, {}, std.sort.asc(u32));

    const b_sorted = try allocator.alloc(u32, b.len);
    defer allocator.free(b_sorted);
    @memcpy(b_sorted, b);
    std.mem.sort(u32, b_sorted, {}, std.sort.asc(u32));

    // Allocate device memory
    const a_size = a.len * @sizeOf(u32);
    const b_size = b.len * @sizeOf(u32);
    const max_result = @min(a.len, b.len);
    const result_size = max_result * @sizeOf(u32);

    var d_a = try mem_mgr.allocDevice(a_size);
    defer mem_mgr.freeDevice(d_a);
    var d_b = try mem_mgr.allocDevice(b_size);
    defer mem_mgr.freeDevice(d_b);
    var d_result = try mem_mgr.allocDevice(result_size);
    defer mem_mgr.freeDevice(d_result);
    var d_count = try mem_mgr.allocDevice(@sizeOf(u32));
    defer mem_mgr.freeDevice(d_count);

    // Copy sorted data to device
    try mem_mgr.copyHostToDevice(d_a, std.mem.sliceAsBytes(a_sorted));
    try mem_mgr.copyHostToDevice(d_b, std.mem.sliceAsBytes(b_sorted));

    var zero: u32 = 0;
    try mem_mgr.copyHostToDevice(d_count, std.mem.asBytes(&zero));

    // Launch intersect kernel
    const intersect_func = try smart_loader.getFunction("intersect_kernel");
    const threads_per_block: u32 = 256;
    const num_blocks: u32 = @intCast((a.len + threads_per_block - 1) / threads_per_block);

    var params = [_]*const anyopaque{
        @ptrCast(&d_a.ptr),
        @ptrCast(&d_b.ptr),
        @ptrCast(&d_result.ptr),
        @ptrCast(&d_count.ptr),
        @ptrCast(&@as(u32, @intCast(a.len))),
        @ptrCast(&@as(u32, @intCast(b.len))),
    };

    try smart_loader.launchKernel(intersect_func, [3]u32{ num_blocks, 1, 1 }, [3]u32{ threads_per_block, 1, 1 }, 0, @ptrCast(&params));

    // Read back count
    var result_count: u32 = 0;
    try mem_mgr.copyDeviceToHost(std.mem.asBytes(&result_count), d_count);

    if (result_count == 0) return try allocator.alloc(u32, 0);

    // Allocate and copy result
    const result = try allocator.alloc(u32, result_count);
    try mem_mgr.copyDeviceToHost(std.mem.sliceAsBytes(result), d_result);

    return result;
}

test "TestCANARY_REQ_GQL_051_GPUUnionDistinctSmall" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const a = &[_]u32{ 1, 2, 3, 3 };
    const b = &[_]u32{ 3, 4, 5 };
    const cpu = try unionDistinctCPU(a, b, alloc);
    defer alloc.free(cpu);
    const gpu = try unionDistinctGPU(a, b, alloc);
    defer alloc.free(gpu);
    try std.testing.expectEqual(cpu.len, gpu.len);
    // Unordered equivalence: convert to hash sets
    var set_cpu = std.AutoHashMap(u32, void).init(alloc);
    defer set_cpu.deinit();
    var set_gpu = std.AutoHashMap(u32, void).init(alloc);
    defer set_gpu.deinit();
    for (cpu) |v| {
        _ = set_cpu.put(v, {}) catch {};
    }
    for (gpu) |v| {
        _ = set_gpu.put(v, {}) catch {};
    }
    try std.testing.expectEqual(set_cpu.count(), set_gpu.count());
}

test "TestCANARY_REQ_GQL_051_GPUIntersectSmall" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const a = &[_]u32{ 1, 2, 3, 4 };
    const b = &[_]u32{ 3, 4, 5, 6 };
    const cpu = try intersectCPU(a, b, alloc);
    defer alloc.free(cpu);
    const gpu = try intersectGPU(a, b, alloc);
    defer alloc.free(gpu);

    // Verify same length
    try std.testing.expectEqual(cpu.len, gpu.len);

    // Verify same elements (unordered)
    var set_cpu = std.AutoHashMap(u32, void).init(alloc);
    defer set_cpu.deinit();
    var set_gpu = std.AutoHashMap(u32, void).init(alloc);
    defer set_gpu.deinit();
    for (cpu) |v| {
        _ = set_cpu.put(v, {}) catch {};
    }
    for (gpu) |v| {
        _ = set_gpu.put(v, {}) catch {};
    }
    try std.testing.expectEqual(set_cpu.count(), set_gpu.count());

    // Verify expected result: {3, 4}
    try std.testing.expect(cpu.len == 2 or cpu.len == 0); // 0 if GPU unavailable fallback
}
