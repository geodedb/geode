//! CUDA Integration Tests
//!
//! These tests require a CUDA-capable GPU to run.
//! They will skip gracefully if CUDA is not available.

const std = @import("std");
const cuda = @import("cuda");

// Sample PTX for testing (simple vector scale kernel)
const test_ptx =
    \\.version 7.0
    \\.target sm_52
    \\.address_size 64
    \\
    \\.visible .entry vector_scale(
    \\    .param .u64 data,
    \\    .param .f32 scale,
    \\    .param .u32 n
    \\)
    \\{
    \\    .reg .pred %p<2>;
    \\    .reg .f32 %f<3>;
    \\    .reg .b32 %r<5>;
    \\    .reg .b64 %rd<5>;
    \\
    \\    ld.param.u64 %rd1, [data];
    \\    ld.param.f32 %f1, [scale];
    \\    ld.param.u32 %r1, [n];
    \\
    \\    mov.u32 %r2, %tid.x;
    \\    mov.u32 %r3, %ctaid.x;
    \\    mov.u32 %r4, %ntid.x;
    \\    mad.lo.s32 %r2, %r3, %r4, %r2;
    \\
    \\    setp.ge.u32 %p1, %r2, %r1;
    \\    @%p1 bra $L__exit;
    \\
    \\    cvt.u64.u32 %rd2, %r2;
    \\    shl.b64 %rd3, %rd2, 2;
    \\    add.u64 %rd4, %rd1, %rd3;
    \\
    \\    ld.global.f32 %f2, [%rd4];
    \\    mul.f32 %f2, %f2, %f1;
    \\    st.global.f32 [%rd4], %f2;
    \\
    \\$L__exit:
    \\    ret;
    \\}
;

// ============================================================================
// Availability Tests
// ============================================================================

test "probe returns valid result" {
    const allocator = std.testing.allocator;

    var result = try cuda.probe(allocator);
    defer result.deinit(allocator);

    // Should always return a valid result
    if (result.available) {
        try std.testing.expect(result.device_count > 0);
        try std.testing.expect(result.devices.len > 0);

        // Check first device
        const dev = result.devices[0];
        try std.testing.expect(dev.available);
        try std.testing.expect(dev.arch.major >= 3); // At least Kepler
    } else {
        std.debug.print("\n[SKIP] CUDA unavailable: {s}\n", .{result.getErrorMessage()});
    }
}

test "isAvailable consistent with probe" {
    const allocator = std.testing.allocator;

    const quick_check = cuda.isAvailable();

    var result = try cuda.probe(allocator);
    defer result.deinit(allocator);

    try std.testing.expectEqual(result.available, quick_check);
}

// ============================================================================
// Context Tests
// ============================================================================

test "context creation and destruction" {
    if (!cuda.isAvailable()) {
        std.debug.print("\n[SKIP] CUDA unavailable\n", .{});
        return;
    }

    var ctx = cuda.Context.init(std.testing.allocator, .{}) catch |err| {
        std.debug.print("\n[SKIP] Context creation failed: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    try std.testing.expect(ctx.isValid());

    const info = ctx.deviceInfo();
    try std.testing.expect(info.available);
    std.debug.print("\n[INFO] Using device: {s} ({s})\n", .{ info.getName(), info.getArchName() });
}

test "context memory operations" {
    if (!cuda.isAvailable()) {
        std.debug.print("\n[SKIP] CUDA unavailable\n", .{});
        return;
    }

    var ctx = cuda.Context.init(std.testing.allocator, .{}) catch |err| {
        std.debug.print("\n[SKIP] Context creation failed: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    // Allocate buffer
    const buffer = try ctx.createBuffer(1024 * 4, .device); // 1024 floats
    defer ctx.destroyBuffer(buffer);

    try std.testing.expect(buffer.isValid());
    try std.testing.expect(buffer.size >= 1024 * 4);

    // Prepare test data
    var host_data: [1024]f32 = undefined;
    for (&host_data, 0..) |*v, i| {
        v.* = @floatFromInt(i);
    }

    // Upload
    try ctx.memcpyH2D(buffer, std.mem.sliceAsBytes(&host_data));

    // Download to new buffer
    var result_data: [1024]f32 = undefined;
    try ctx.memcpyD2H(std.mem.sliceAsBytes(&result_data), buffer);

    // Verify
    for (host_data, result_data) |expected, actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

// ============================================================================
// Kernel Tests
// ============================================================================

test "module load and kernel execution" {
    if (!cuda.isAvailable()) {
        std.debug.print("\n[SKIP] CUDA unavailable\n", .{});
        return;
    }

    var ctx = cuda.Context.init(std.testing.allocator, .{}) catch |err| {
        std.debug.print("\n[SKIP] Context creation failed: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    // Load PTX module
    const module = ctx.createModulePtx(test_ptx) catch |err| {
        std.debug.print("\n[SKIP] Module load failed: {}\n", .{err});
        return;
    };
    defer ctx.destroyModule(module);

    // Get kernel
    const kernel = ctx.getKernel(module, "vector_scale") catch |err| {
        std.debug.print("\n[SKIP] Kernel lookup failed: {}\n", .{err});
        return;
    };

    // Prepare data
    const n: u32 = 256;
    const scale: f32 = 2.0;

    var host_data: [256]f32 = undefined;
    for (&host_data, 0..) |*v, i| {
        v.* = @floatFromInt(i);
    }

    // Allocate and upload
    const buffer = try ctx.createBuffer(256 * 4, .device);
    defer ctx.destroyBuffer(buffer);

    try ctx.memcpyH2D(buffer, std.mem.sliceAsBytes(&host_data));

    // Launch kernel
    var data_ptr: u64 = buffer.ptr;
    var scale_val: f32 = scale;
    var n_val: u32 = n;

    var args = cuda.KernelArgs(8){};
    args.addPtr(&data_ptr);
    args.addPtr(&scale_val);
    args.addPtr(&n_val);

    try ctx.launchSync(kernel, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ 256, 1, 1 },
    }, args.getArgs());

    // Download and verify
    var result_data: [256]f32 = undefined;
    try ctx.memcpyD2H(std.mem.sliceAsBytes(&result_data), buffer);

    for (result_data, 0..) |actual, i| {
        const expected: f32 = @as(f32, @floatFromInt(i)) * scale;
        try std.testing.expectApproxEqRel(expected, actual, 0.001);
    }
}

// ============================================================================
// Stream Tests
// ============================================================================

test "stream creation and synchronization" {
    if (!cuda.isAvailable()) {
        std.debug.print("\n[SKIP] CUDA unavailable\n", .{});
        return;
    }

    var ctx = cuda.Context.init(std.testing.allocator, .{}) catch |err| {
        std.debug.print("\n[SKIP] Context creation failed: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    // Create stream
    const stream = ctx.createStream() catch |err| {
        std.debug.print("\n[SKIP] Stream creation failed: {}\n", .{err});
        return;
    };

    // Synchronize
    try stream.synchronize();
    try std.testing.expect(stream.isComplete());
}

// ============================================================================
// Timing Tests
// ============================================================================

test "event timer" {
    if (!cuda.isAvailable()) {
        std.debug.print("\n[SKIP] CUDA unavailable\n", .{});
        return;
    }

    var ctx = cuda.Context.init(std.testing.allocator, .{}) catch |err| {
        std.debug.print("\n[SKIP] Context creation failed: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    // Create timer
    var timer = ctx.createTimer() catch |err| {
        std.debug.print("\n[SKIP] Timer creation failed: {}\n", .{err});
        return;
    };
    defer timer.destroy();

    // Time a memory operation
    const buffer = try ctx.createBuffer(1024 * 1024, .device); // 1 MB
    defer ctx.destroyBuffer(buffer);

    const data = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(data);
    @memset(data, 42);

    try timer.start();
    try ctx.memcpyH2D(buffer, data);
    try timer.stop();

    const elapsed = try timer.elapsedMs();
    std.debug.print("\n[INFO] 1MB H2D transfer: {d:.3} ms\n", .{elapsed});

    try std.testing.expect(elapsed >= 0);
}

// ============================================================================
// Memory Stats Tests
// ============================================================================

test "memory statistics" {
    if (!cuda.isAvailable()) {
        std.debug.print("\n[SKIP] CUDA unavailable\n", .{});
        return;
    }

    var ctx = cuda.Context.init(std.testing.allocator, .{}) catch |err| {
        std.debug.print("\n[SKIP] Context creation failed: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    // Get initial stats
    const stats1 = ctx.getMemoryStats();
    try std.testing.expectEqual(@as(usize, 0), stats1.device_allocs);

    // Allocate some buffers
    const buf1 = try ctx.createBuffer(1024, .device);
    const buf2 = try ctx.createBuffer(2048, .device);

    const stats2 = ctx.getMemoryStats();
    try std.testing.expectEqual(@as(usize, 2), stats2.device_allocs);

    // Free and check pool reuse
    ctx.destroyBuffer(buf1);
    ctx.destroyBuffer(buf2);

    const buf3 = try ctx.createBuffer(512, .device);
    const stats3 = ctx.getMemoryStats();
    try std.testing.expect(stats3.pool_hits > 0);

    ctx.destroyBuffer(buf3);
}
