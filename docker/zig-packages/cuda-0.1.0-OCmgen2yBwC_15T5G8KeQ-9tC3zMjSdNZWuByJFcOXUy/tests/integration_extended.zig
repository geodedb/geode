//! Extended CUDA Integration Tests
//!
//! Comprehensive test suite covering streams, events, memory operations,
//! error handling, and multi-GPU scenarios.
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
// Helper Functions
// ============================================================================

fn skipIfNoGpu() ?cuda.Context {
    if (!cuda.isAvailable()) {
        std.debug.print("\n[SKIP] CUDA unavailable\n", .{});
        return null;
    }
    return cuda.Context.init(std.testing.allocator, .{}) catch |err| {
        std.debug.print("\n[SKIP] Context creation failed: {}\n", .{err});
        return null;
    };
}

// ============================================================================
// Stream Tests - Concurrent Operations
// ============================================================================

test "multiple streams creation" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const num_streams = 4;
    var streams: [num_streams]*cuda.Stream = undefined;

    // Create multiple streams
    for (&streams) |*s| {
        s.* = ctx.createStream() catch |err| {
            std.debug.print("\n[SKIP] Stream creation failed: {}\n", .{err});
            return;
        };
    }

    // Verify all streams are distinct
    for (streams, 0..) |s, i| {
        for (streams[i + 1 ..]) |s2| {
            try std.testing.expect(s.handle != s2.handle);
        }
    }

    // Synchronize all streams
    for (streams) |s| {
        try s.synchronize();
    }
}

test "default stream operations" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const default_stream = ctx.getDefaultStream();

    // Default stream should have null handle
    try std.testing.expect(default_stream.handle == null);

    // Operations on default stream should still work
    const buffer = try ctx.createBuffer(1024, .device);
    defer ctx.destroyBuffer(buffer);

    var host_data: [256]u8 = undefined;
    @memset(&host_data, 42);

    try ctx.memcpyH2D(buffer, &host_data);

    // Sync default stream
    try default_stream.synchronize();
}

test "stream completion polling" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const stream = ctx.createStream() catch |err| {
        std.debug.print("\n[SKIP] Stream creation failed: {}\n", .{err});
        return;
    };

    // After sync, stream should be complete
    try stream.synchronize();
    try std.testing.expect(stream.isComplete());

    // Start an operation
    const buffer = try ctx.createBuffer(1024 * 1024, .device);
    defer ctx.destroyBuffer(buffer);

    const data = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(data);
    @memset(data, 0);

    try ctx.memcpyH2DAsync(buffer, data, stream);

    // After sync, should be complete
    try stream.synchronize();
    try std.testing.expect(stream.isComplete());
}

test "concurrent kernel execution on multiple streams" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    // Load module
    const module = ctx.createModulePtx(test_ptx) catch |err| {
        std.debug.print("\n[SKIP] Module load failed: {}\n", .{err});
        return;
    };
    defer ctx.destroyModule(module);

    const kernel = ctx.getKernel(module, "vector_scale") catch |err| {
        std.debug.print("\n[SKIP] Kernel lookup failed: {}\n", .{err});
        return;
    };

    // Create multiple streams
    const num_streams = 3;
    var streams: [num_streams]*cuda.Stream = undefined;
    for (&streams) |*s| {
        s.* = ctx.createStream() catch return;
    }

    // Allocate buffers for each stream
    const n: u32 = 256;
    var buffers: [num_streams]cuda.Buffer = undefined;
    for (&buffers) |*buf| {
        buf.* = try ctx.createBuffer(n * 4, .device);
    }
    defer for (buffers) |buf| ctx.destroyBuffer(buf);

    // Launch kernels on different streams
    for (streams, buffers, 0..) |stream, buffer, i| {
        var host_data: [256]f32 = undefined;
        for (&host_data, 0..) |*v, j| {
            v.* = @floatFromInt(j + i * 256);
        }

        try ctx.memcpyH2DAsync(buffer, std.mem.sliceAsBytes(&host_data), stream);

        var data_ptr: u64 = buffer.ptr;
        const scale: f32 = @floatFromInt(i + 1);
        var scale_val: f32 = scale;
        var n_val: u32 = n;

        var args = cuda.KernelArgs(8){};
        args.addPtr(&data_ptr);
        args.addPtr(&scale_val);
        args.addPtr(&n_val);

        // Launch with stream set in config
        try ctx.launch(kernel, .{
            .grid = .{ 1, 1, 1 },
            .block = .{ 256, 1, 1 },
            .stream = stream.getHandle(),
        }, args.getArgs());
    }

    // Synchronize all streams
    for (streams) |s| {
        try s.synchronize();
    }

    // Verify results
    for (buffers, 0..) |buffer, i| {
        var result_data: [256]f32 = undefined;
        try ctx.memcpyD2H(std.mem.sliceAsBytes(&result_data), buffer);

        const scale: f32 = @floatFromInt(i + 1);
        for (result_data, 0..) |actual, j| {
            const base: f32 = @floatFromInt(j + i * 256);
            const expected = base * scale;
            try std.testing.expectApproxEqRel(expected, actual, 0.001);
        }
    }
}

// ============================================================================
// Event Tests - Synchronization and Timing
// ============================================================================

test "event creation and destruction" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    var event = cuda.Event.create(ctx.drv) catch |err| {
        std.debug.print("\n[SKIP] Event creation failed: {}\n", .{err});
        return;
    };
    defer event.destroy();

    try std.testing.expect(event.handle != null);
}

test "event record and synchronize" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const stream = ctx.createStream() catch |err| {
        std.debug.print("\n[SKIP] Stream creation failed: {}\n", .{err});
        return;
    };

    var event = cuda.Event.create(ctx.drv) catch |err| {
        std.debug.print("\n[SKIP] Event creation failed: {}\n", .{err});
        return;
    };
    defer event.destroy();

    // Record event
    try event.record(stream);

    // Synchronize on event
    try event.synchronize();
}

test "event elapsed time measurement" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const stream = ctx.createStream() catch |err| {
        std.debug.print("\n[SKIP] Stream creation failed: {}\n", .{err});
        return;
    };

    var start_event = cuda.Event.create(ctx.drv) catch |err| {
        std.debug.print("\n[SKIP] Event creation failed: {}\n", .{err});
        return;
    };
    defer start_event.destroy();

    var end_event = cuda.Event.create(ctx.drv) catch |err| {
        std.debug.print("\n[SKIP] Event creation failed: {}\n", .{err});
        return;
    };
    defer end_event.destroy();

    // Record start
    try start_event.record(stream);

    // Do some work
    const buffer = try ctx.createBuffer(4 * 1024 * 1024, .device); // 4 MB
    defer ctx.destroyBuffer(buffer);

    const data = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(data);
    @memset(data, 42);

    try ctx.memcpyH2DAsync(buffer, data, stream);

    // Record end
    try end_event.record(stream);

    // Wait for completion
    try end_event.synchronize();

    // Get elapsed time
    const elapsed = try cuda.Event.elapsedMs(&start_event, &end_event);
    std.debug.print("\n[INFO] 4MB H2D async transfer: {d:.3} ms\n", .{elapsed});

    try std.testing.expect(elapsed >= 0);
}

test "event timer wrapper" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    var timer = ctx.createTimer() catch |err| {
        std.debug.print("\n[SKIP] Timer creation failed: {}\n", .{err});
        return;
    };
    defer timer.destroy();

    // Time multiple operations
    const iterations = 5;
    var total_time: f32 = 0;

    for (0..iterations) |_| {
        const buffer = try ctx.createBuffer(1024 * 1024, .device);

        const data = try std.testing.allocator.alloc(u8, 1024 * 1024);
        @memset(data, 0);

        try timer.start();
        try ctx.memcpyH2D(buffer, data);
        try timer.stop();

        total_time += try timer.elapsedMs();

        ctx.destroyBuffer(buffer);
        std.testing.allocator.free(data);
    }

    const avg_time = total_time / @as(f32, @floatFromInt(iterations));
    std.debug.print("\n[INFO] Average 1MB H2D transfer: {d:.3} ms\n", .{avg_time});

    try std.testing.expect(avg_time >= 0);
}

// ============================================================================
// Memory Tests - Various Memory Types
// ============================================================================

test "device memory allocation sizes" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    // Test various allocation sizes
    const sizes = [_]usize{
        64, // Tiny
        1024, // 1 KB
        64 * 1024, // 64 KB
        1024 * 1024, // 1 MB
        16 * 1024 * 1024, // 16 MB
    };

    for (sizes) |size| {
        const buffer = ctx.createBuffer(size, .device) catch |err| {
            std.debug.print("\n[WARN] Allocation of {} bytes failed: {}\n", .{ size, err });
            continue;
        };
        defer ctx.destroyBuffer(buffer);

        try std.testing.expect(buffer.isValid());
        try std.testing.expect(buffer.size >= size);
    }
}

test "pinned memory simulation" {
    // Note: True pinned memory via createBuffer(.pinned) is not fully implemented yet
    // This test simulates pinned-like behavior using regular host allocation
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const size: usize = 1024 * 1024; // 1 MB

    // Use regular host allocation (simulating pinned)
    const host_data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(host_data);
    @memset(host_data, 42);

    // Allocate device memory
    const device_buffer = try ctx.createBuffer(size, .device);
    defer ctx.destroyBuffer(device_buffer);

    // Transfer host to device
    var timer = ctx.createTimer() catch return;
    defer timer.destroy();

    try timer.start();
    try ctx.memcpyH2D(device_buffer, host_data);
    try timer.stop();

    const transfer_time = try timer.elapsedMs();
    std.debug.print("\n[INFO] Host->Device 1MB: {d:.3} ms\n", .{transfer_time});

    // Verify
    const result_data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(result_data);
    try ctx.memcpyD2H(result_data, device_buffer);

    try std.testing.expectEqual(@as(u8, 42), result_data[0]);
    try std.testing.expectEqual(@as(u8, 42), result_data[size - 1]);
}

test "unified memory simulation" {
    // Note: Unified memory via createBuffer(.unified) is not fully implemented yet
    // This test verifies basic device memory operations work
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const size: usize = 1024 * 1024; // 1 MB

    // Use device memory (unified memory not yet implemented)
    const buffer = ctx.createBuffer(size, .device) catch |err| {
        std.debug.print("\n[SKIP] Memory allocation failed: {}\n", .{err});
        return;
    };
    defer ctx.destroyBuffer(buffer);

    try std.testing.expect(buffer.isValid());
    try std.testing.expect(buffer.size >= size);

    std.debug.print("\n[INFO] Device memory allocation successful (unified pending)\n", .{});
}

test "async memory transfers" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const size: usize = 4 * 1024 * 1024; // 4 MB

    // Allocate host memory
    const host_data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(host_data);

    // Fill with test pattern
    for (host_data, 0..) |*v, i| {
        v.* = @as(u8, @truncate(i));
    }

    // Device buffer
    const device_buffer = try ctx.createBuffer(size, .device);
    defer ctx.destroyBuffer(device_buffer);

    // Create stream
    const stream = ctx.createStream() catch return;

    // Async transfer
    var start_event = cuda.Event.create(ctx.drv) catch return;
    defer start_event.destroy();
    var end_event = cuda.Event.create(ctx.drv) catch return;
    defer end_event.destroy();

    try start_event.record(stream);
    try ctx.memcpyH2DAsync(device_buffer, host_data, stream);
    try end_event.record(stream);

    // Wait for completion
    try stream.synchronize();

    const transfer_time = try cuda.Event.elapsedMs(&start_event, &end_event);
    const bandwidth_gbps = @as(f64, @floatFromInt(size)) / (1024 * 1024 * 1024) / (transfer_time / 1000.0);
    std.debug.print("\n[INFO] Async H2D 4MB: {d:.3} ms ({d:.2} GB/s)\n", .{ transfer_time, bandwidth_gbps });

    // Read back and verify
    const result_data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(result_data);

    try ctx.memcpyD2HAsync(result_data, device_buffer, stream);
    try stream.synchronize();

    // Verify first and last bytes
    try std.testing.expectEqual(host_data[0], result_data[0]);
    try std.testing.expectEqual(host_data[size - 1], result_data[size - 1]);
}

test "device to device copy" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const size: usize = 1024 * 1024; // 1 MB

    // Allocate two device buffers
    const src_buffer = try ctx.createBuffer(size, .device);
    defer ctx.destroyBuffer(src_buffer);

    const dst_buffer = try ctx.createBuffer(size, .device);
    defer ctx.destroyBuffer(dst_buffer);

    // Initialize source buffer
    const host_data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(host_data);

    for (host_data, 0..) |*v, i| {
        v.* = @truncate(i);
    }

    try ctx.memcpyH2D(src_buffer, host_data);

    // Device to device copy
    var timer = ctx.createTimer() catch return;
    defer timer.destroy();

    try timer.start();
    try ctx.memcpyD2D(dst_buffer, src_buffer, size);
    try timer.stop();

    const transfer_time = try timer.elapsedMs();
    std.debug.print("\n[INFO] D2D 1MB: {d:.3} ms\n", .{transfer_time});

    // Verify
    const result_data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(result_data);

    try ctx.memcpyD2H(result_data, dst_buffer);

    try std.testing.expectEqualSlices(u8, host_data, result_data);
}

test "memory zero operations" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const size: usize = 4096;
    const buffer = try ctx.createBuffer(size, .device);
    defer ctx.destroyBuffer(buffer);

    // First, upload some data
    const init_data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(init_data);
    @memset(init_data, 0xAB);

    try ctx.memcpyH2D(buffer, init_data);

    // Verify it was uploaded
    const verify_data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(verify_data);
    try ctx.memcpyD2H(verify_data, buffer);
    try std.testing.expectEqual(@as(u8, 0xAB), verify_data[0]);

    // Zero memory
    try ctx.zeroBuffer(buffer);

    // Verify it's zeroed
    try ctx.memcpyD2H(verify_data, buffer);

    for (verify_data) |v| {
        try std.testing.expectEqual(@as(u8, 0), v);
    }
}

// ============================================================================
// Memory Pool Tests
// ============================================================================

test "memory pool reuse" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    // Allocate and free several times
    for (0..5) |_| {
        const buffer = try ctx.createBuffer(4096, .device);
        ctx.destroyBuffer(buffer);
    }

    // Check pool stats
    const stats = ctx.getMemoryStats();
    std.debug.print("\n[INFO] Pool hits: {}, device allocs: {}\n", .{ stats.pool_hits, stats.device_allocs });

    // Pool should have some hits after repeated alloc/free
    try std.testing.expect(stats.pool_hits > 0);
}

test "memory pool size classes" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    // Allocate different size classes
    const sizes = [_]usize{ 256, 512, 1024, 2048, 4096, 8192 };
    var buffers: [sizes.len]cuda.Buffer = undefined;

    for (sizes, 0..) |size, i| {
        buffers[i] = try ctx.createBuffer(size, .device);
    }

    // Free all
    for (buffers) |buf| {
        ctx.destroyBuffer(buf);
    }

    // Reallocate same sizes - should hit pool
    const stats_before = ctx.getMemoryStats();

    for (sizes, 0..) |size, i| {
        buffers[i] = try ctx.createBuffer(size, .device);
    }

    const stats_after = ctx.getMemoryStats();

    // Cleanup
    for (buffers) |buf| {
        ctx.destroyBuffer(buf);
    }

    // Should have some pool hits
    try std.testing.expect(stats_after.pool_hits > stats_before.pool_hits);
}

test "memory statistics tracking" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const initial_stats = ctx.getMemoryStats();
    const initial_allocs = initial_stats.device_allocs;

    // Allocate
    const buf1 = try ctx.createBuffer(1024, .device);
    const buf2 = try ctx.createBuffer(2048, .device);
    const buf3 = try ctx.createBuffer(4096, .device);

    const mid_stats = ctx.getMemoryStats();
    try std.testing.expectEqual(initial_allocs + 3, mid_stats.device_allocs);

    // Free one
    ctx.destroyBuffer(buf2);

    // Allocate one more
    const buf4 = try ctx.createBuffer(1024, .device);

    const final_stats = ctx.getMemoryStats();
    std.debug.print("\n[INFO] Total allocs: {}, device bytes allocated: {}\n", .{
        final_stats.device_allocs,
        final_stats.device_bytes_allocated,
    });

    ctx.destroyBuffer(buf1);
    ctx.destroyBuffer(buf3);
    ctx.destroyBuffer(buf4);
}

// ============================================================================
// Error Handling Tests
// ============================================================================

test "allocation failure on huge size" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    // Try to allocate more than available memory
    const huge_size: usize = 1024 * 1024 * 1024 * 1024; // 1 TB

    const result = ctx.createBuffer(huge_size, .device);
    if (result) |buffer| {
        ctx.destroyBuffer(buffer);
        std.debug.print("\n[WARN] Unexpected success allocating 1TB\n", .{});
    } else |err| {
        std.debug.print("\n[INFO] Expected allocation failure: {}\n", .{err});
        try std.testing.expect(err == cuda.CudaError.OutOfMemory or
            err == cuda.CudaError.InvalidArgument);
    }
}

test "invalid kernel name" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const module = ctx.createModulePtx(test_ptx) catch |err| {
        std.debug.print("\n[SKIP] Module load failed: {}\n", .{err});
        return;
    };
    defer ctx.destroyModule(module);

    // Try to get non-existent kernel
    const result = ctx.getKernel(module, "non_existent_kernel");
    if (result) |_| {
        std.debug.print("\n[WARN] Unexpected success finding non-existent kernel\n", .{});
    } else |err| {
        std.debug.print("\n[INFO] Expected kernel lookup failure: {}\n", .{err});
        try std.testing.expect(err == cuda.CudaError.FunctionNotFound);
    }
}

test "invalid PTX module" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const invalid_ptx = "this is not valid PTX code";

    const result = ctx.createModulePtx(invalid_ptx);
    if (result) |module| {
        ctx.destroyModule(module);
        std.debug.print("\n[WARN] Unexpected success loading invalid PTX\n", .{});
    } else |err| {
        std.debug.print("\n[INFO] Expected PTX load failure: {}\n", .{err});
    }
}

test "zero-size allocation handling" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    // Zero-size allocation should either succeed with minimal buffer or fail gracefully
    const result = ctx.createBuffer(0, .device);
    if (result) |buffer| {
        ctx.destroyBuffer(buffer);
        std.debug.print("\n[INFO] Zero-size allocation succeeded\n", .{});
    } else |err| {
        std.debug.print("\n[INFO] Zero-size allocation failed as expected: {}\n", .{err});
    }
}

// ============================================================================
// Multi-GPU Tests
// ============================================================================

test "device enumeration" {
    const allocator = std.testing.allocator;

    var probe_result = try cuda.probe(allocator);
    defer probe_result.deinit(allocator);

    if (!probe_result.available) {
        std.debug.print("\n[SKIP] CUDA unavailable\n", .{});
        return;
    }

    std.debug.print("\n[INFO] Found {} CUDA device(s):\n", .{probe_result.device_count});

    for (probe_result.devices, 0..) |dev, i| {
        std.debug.print("  Device {}: {s} (SM {}.{})\n", .{
            i,
            dev.getName(),
            dev.arch.major,
            dev.arch.minor,
        });
    }

    try std.testing.expect(probe_result.device_count > 0);
}

test "multi-device context creation" {
    const allocator = std.testing.allocator;

    var probe_result = try cuda.probe(allocator);
    defer probe_result.deinit(allocator);

    if (!probe_result.available) {
        std.debug.print("\n[SKIP] CUDA unavailable\n", .{});
        return;
    }

    if (probe_result.device_count < 2) {
        std.debug.print("\n[SKIP] Multi-GPU test requires 2+ devices (found {})\n", .{
            probe_result.device_count,
        });
        return;
    }

    // Create contexts on different devices
    var ctx0 = cuda.Context.init(allocator, .{ .device_index = 0 }) catch |err| {
        std.debug.print("\n[SKIP] Context creation on device 0 failed: {}\n", .{err});
        return;
    };
    defer ctx0.deinit();

    var ctx1 = cuda.Context.init(allocator, .{ .device_index = 1 }) catch |err| {
        std.debug.print("\n[SKIP] Context creation on device 1 failed: {}\n", .{err});
        return;
    };
    defer ctx1.deinit();

    std.debug.print("\n[INFO] Successfully created contexts on 2 devices\n", .{});

    // Allocate memory on each device
    const buf0 = try ctx0.createBuffer(1024, .device);
    defer ctx0.destroyBuffer(buf0);

    const buf1 = try ctx1.createBuffer(1024, .device);
    defer ctx1.destroyBuffer(buf1);

    std.debug.print("[INFO] Allocated memory on both devices\n", .{});
}

// ============================================================================
// Kernel Launch Configuration Tests
// ============================================================================

test "various block sizes" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const module = ctx.createModulePtx(test_ptx) catch |err| {
        std.debug.print("\n[SKIP] Module load failed: {}\n", .{err});
        return;
    };
    defer ctx.destroyModule(module);

    const kernel = ctx.getKernel(module, "vector_scale") catch |err| {
        std.debug.print("\n[SKIP] Kernel lookup failed: {}\n", .{err});
        return;
    };

    // Test various block sizes
    const block_sizes = [_]u32{ 32, 64, 128, 256, 512, 1024 };

    for (block_sizes) |block_size| {
        const n: u32 = block_size * 4; // 4 blocks worth
        const scale: f32 = 2.0;

        const host_data = try std.testing.allocator.alloc(f32, n);
        defer std.testing.allocator.free(host_data);

        for (host_data, 0..) |*v, i| {
            v.* = @floatFromInt(i);
        }

        const buffer = try ctx.createBuffer(n * 4, .device);
        defer ctx.destroyBuffer(buffer);

        try ctx.memcpyH2D(buffer, std.mem.sliceAsBytes(host_data));

        var data_ptr: u64 = buffer.ptr;
        var scale_val: f32 = scale;
        var n_val: u32 = n;

        var args = cuda.KernelArgs(8){};
        args.addPtr(&data_ptr);
        args.addPtr(&scale_val);
        args.addPtr(&n_val);

        const grid_size = (n + block_size - 1) / block_size;

        try ctx.launchSync(kernel, .{
            .grid = .{ grid_size, 1, 1 },
            .block = .{ block_size, 1, 1 },
        }, args.getArgs());

        const result_data = try std.testing.allocator.alloc(f32, n);
        defer std.testing.allocator.free(result_data);

        try ctx.memcpyD2H(std.mem.sliceAsBytes(result_data), buffer);

        // Verify first and last elements
        try std.testing.expectApproxEqRel(@as(f32, 0), result_data[0], 0.001);
        const last_expected: f32 = @as(f32, @floatFromInt(n - 1)) * scale;
        try std.testing.expectApproxEqRel(last_expected, result_data[n - 1], 0.001);
    }

    std.debug.print("\n[INFO] All block sizes tested successfully\n", .{});
}

test "large grid configuration" {
    // Note: The test kernel uses 1D thread indexing (only uses threadIdx.x/blockIdx.x)
    // This test verifies large 1D grid configurations work correctly
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const module = ctx.createModulePtx(test_ptx) catch |err| {
        std.debug.print("\n[SKIP] Module load failed: {}\n", .{err});
        return;
    };
    defer ctx.destroyModule(module);

    const kernel = ctx.getKernel(module, "vector_scale") catch |err| {
        std.debug.print("\n[SKIP] Kernel lookup failed: {}\n", .{err});
        return;
    };

    // Large 1D grid configuration
    const n: u32 = 64 * 64;
    const scale: f32 = 2.0;

    var host_data: [64 * 64]f32 = undefined;
    for (&host_data, 0..) |*v, i| {
        v.* = @floatFromInt(i);
    }

    const buffer = try ctx.createBuffer(n * 4, .device);
    defer ctx.destroyBuffer(buffer);

    try ctx.memcpyH2D(buffer, std.mem.sliceAsBytes(&host_data));

    var data_ptr: u64 = buffer.ptr;
    var scale_val: f32 = scale;
    var n_val: u32 = n;

    var args = cuda.KernelArgs(8){};
    args.addPtr(&data_ptr);
    args.addPtr(&scale_val);
    args.addPtr(&n_val);

    // Launch with multiple blocks to process all elements
    const block_size: u32 = 256;
    const grid_size: u32 = (n + block_size - 1) / block_size;
    try ctx.launchSync(kernel, .{
        .grid = .{ grid_size, 1, 1 },
        .block = .{ block_size, 1, 1 },
    }, args.getArgs());

    var result_data: [64 * 64]f32 = undefined;
    try ctx.memcpyD2H(std.mem.sliceAsBytes(&result_data), buffer);

    // Verify
    for (result_data, 0..) |actual, i| {
        const expected: f32 = @as(f32, @floatFromInt(i)) * scale;
        try std.testing.expectApproxEqRel(expected, actual, 0.001);
    }

    std.debug.print("\n[INFO] Large grid configuration test passed\n", .{});
}

// ============================================================================
// Resource Cleanup Tests
// ============================================================================

test "repeated allocation and deallocation" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const iterations = 100;
    const size: usize = 1024 * 1024; // 1 MB

    for (0..iterations) |_| {
        const buffer = try ctx.createBuffer(size, .device);
        ctx.destroyBuffer(buffer);
    }

    // Memory should be properly recycled
    const stats = ctx.getMemoryStats();
    std.debug.print("\n[INFO] After {} iterations: {} allocs, {} pool hits\n", .{
        iterations,
        stats.device_allocs,
        stats.pool_hits,
    });

    // Pool should be helping after repeated allocations
    try std.testing.expect(stats.pool_hits > 0);
}

test "stream and event cleanup" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    for (0..50) |_| {
        const stream = ctx.createStream() catch continue;
        _ = stream;

        var event = cuda.Event.create(ctx.drv) catch continue;
        event.destroy();
    }

    std.debug.print("\n[INFO] Stream/Event cleanup test passed\n", .{});
}

test "module and kernel cleanup" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    for (0..10) |_| {
        const module = ctx.createModulePtx(test_ptx) catch continue;
        _ = ctx.getKernel(module, "vector_scale") catch {
            ctx.destroyModule(module);
            continue;
        };
        ctx.destroyModule(module);
    }

    std.debug.print("\n[INFO] Module/Kernel cleanup test passed\n", .{});
}

// ============================================================================
// Stress Tests
// ============================================================================

test "high-frequency small allocations" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    const num_buffers = 100;
    var buffers: [num_buffers]cuda.Buffer = undefined;
    var valid_count: usize = 0;

    // Allocate many small buffers
    for (&buffers) |*buf| {
        buf.* = ctx.createBuffer(256, .device) catch {
            break;
        };
        valid_count += 1;
    }

    std.debug.print("\n[INFO] Allocated {} small buffers\n", .{valid_count});

    // Free all
    for (buffers[0..valid_count]) |buf| {
        ctx.destroyBuffer(buf);
    }

    // Reallocate - should benefit from pool
    const stats_before = ctx.getMemoryStats();

    for (buffers[0..valid_count]) |*buf| {
        buf.* = ctx.createBuffer(256, .device) catch break;
    }

    const stats_after = ctx.getMemoryStats();
    std.debug.print("[INFO] Pool hits improved: {} -> {}\n", .{
        stats_before.pool_hits,
        stats_after.pool_hits,
    });

    // Cleanup
    for (buffers[0..valid_count]) |buf| {
        ctx.destroyBuffer(buf);
    }
}

test "large data transfer" {
    var ctx = skipIfNoGpu() orelse return;
    defer ctx.deinit();

    // Allocate up to 256 MB
    const max_size: usize = 256 * 1024 * 1024;

    const buffer = ctx.createBuffer(max_size, .device) catch |err| {
        std.debug.print("\n[SKIP] Large allocation failed: {}\n", .{err});
        return;
    };
    defer ctx.destroyBuffer(buffer);

    const host_data = std.testing.allocator.alloc(u8, max_size) catch |err| {
        std.debug.print("\n[SKIP] Host allocation failed: {}\n", .{err});
        return;
    };
    defer std.testing.allocator.free(host_data);

    // Initialize with pattern
    for (host_data, 0..) |*v, i| {
        v.* = @truncate(i);
    }

    var timer = ctx.createTimer() catch return;
    defer timer.destroy();

    // Upload
    try timer.start();
    try ctx.memcpyH2D(buffer, host_data);
    try timer.stop();

    const upload_time = try timer.elapsedMs();
    const upload_bandwidth = @as(f64, @floatFromInt(max_size)) / (1024 * 1024 * 1024) / (upload_time / 1000.0);

    // Download
    const result_data = try std.testing.allocator.alloc(u8, max_size);
    defer std.testing.allocator.free(result_data);

    try timer.start();
    try ctx.memcpyD2H(result_data, buffer);
    try timer.stop();

    const download_time = try timer.elapsedMs();
    const download_bandwidth = @as(f64, @floatFromInt(max_size)) / (1024 * 1024 * 1024) / (download_time / 1000.0);

    std.debug.print("\n[INFO] Large transfer ({d:.0} MB):\n", .{@as(f64, @floatFromInt(max_size)) / (1024 * 1024)});
    std.debug.print("  Upload: {d:.2} GB/s ({d:.2} ms)\n", .{ upload_bandwidth, upload_time });
    std.debug.print("  Download: {d:.2} GB/s ({d:.2} ms)\n", .{ download_bandwidth, download_time });

    // Verify first and last bytes
    try std.testing.expectEqual(host_data[0], result_data[0]);
    try std.testing.expectEqual(host_data[max_size - 1], result_data[max_size - 1]);
}
