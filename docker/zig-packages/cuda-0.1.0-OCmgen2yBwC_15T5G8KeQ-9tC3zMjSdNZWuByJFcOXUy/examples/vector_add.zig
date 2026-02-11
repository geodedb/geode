//! Vector Addition Example
//!
//! Demonstrates a complete CUDA workflow:
//! 1. Probe for CUDA availability
//! 2. Create context
//! 3. Allocate device memory
//! 4. Upload data
//! 5. Load PTX module and get kernel
//! 6. Launch kernel
//! 7. Download results
//! 8. Verify correctness

const std = @import("std");
const cuda = @import("cuda");

// PTX for vector addition kernel
// c[i] = a[i] + b[i]
const vector_add_ptx =
    \\.version 7.0
    \\.target sm_52
    \\.address_size 64
    \\
    \\.visible .entry vector_add(
    \\    .param .u64 a,
    \\    .param .u64 b,
    \\    .param .u64 c,
    \\    .param .u32 n
    \\)
    \\{
    \\    .reg .pred %p<2>;
    \\    .reg .f32 %f<4>;
    \\    .reg .b32 %r<6>;
    \\    .reg .b64 %rd<10>;
    \\
    \\    // Calculate thread index
    \\    mov.u32 %r1, %tid.x;
    \\    mov.u32 %r2, %ctaid.x;
    \\    mov.u32 %r3, %ntid.x;
    \\    mad.lo.s32 %r4, %r2, %r3, %r1;  // idx = blockIdx.x * blockDim.x + threadIdx.x
    \\
    \\    // Load n and check bounds
    \\    ld.param.u32 %r5, [n];
    \\    setp.ge.u32 %p1, %r4, %r5;
    \\    @%p1 bra $L__exit;
    \\
    \\    // Calculate byte offset
    \\    cvt.u64.u32 %rd1, %r4;
    \\    shl.b64 %rd2, %rd1, 2;  // offset = idx * 4 (sizeof float)
    \\
    \\    // Load a[idx]
    \\    ld.param.u64 %rd3, [a];
    \\    add.u64 %rd4, %rd3, %rd2;
    \\    ld.global.f32 %f1, [%rd4];
    \\
    \\    // Load b[idx]
    \\    ld.param.u64 %rd5, [b];
    \\    add.u64 %rd6, %rd5, %rd2;
    \\    ld.global.f32 %f2, [%rd6];
    \\
    \\    // c[idx] = a[idx] + b[idx]
    \\    add.f32 %f3, %f1, %f2;
    \\
    \\    // Store result
    \\    ld.param.u64 %rd7, [c];
    \\    add.u64 %rd8, %rd7, %rd2;
    \\    st.global.f32 [%rd8], %f3;
    \\
    \\$L__exit:
    \\    ret;
    \\}
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Vector Addition Example ===\n\n", .{});

    // Step 1: Check CUDA availability
    if (!cuda.isAvailable()) {
        std.debug.print("CUDA is not available on this system.\n", .{});
        std.debug.print("Run 'zig build examples && ./zig-out/bin/device_info' for details.\n", .{});
        return;
    }
    std.debug.print("[1/8] CUDA is available\n", .{});

    // Step 2: Create context
    var ctx = cuda.Context.init(allocator, .{}) catch |err| {
        std.debug.print("Failed to create CUDA context: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    const dev_info = ctx.deviceInfo();
    std.debug.print("[2/8] Created context on: {s}\n", .{dev_info.getName()});

    // Step 3: Prepare data
    const n: u32 = 1024 * 1024; // 1M elements
    const size = n * @sizeOf(f32);

    const h_a = try allocator.alloc(f32, n);
    defer allocator.free(h_a);
    const h_b = try allocator.alloc(f32, n);
    defer allocator.free(h_b);
    const h_c = try allocator.alloc(f32, n);
    defer allocator.free(h_c);

    // Initialize input arrays
    for (h_a, h_b, 0..) |*a, *b, i| {
        a.* = @floatFromInt(i);
        b.* = @floatFromInt(i * 2);
    }
    std.debug.print("[3/8] Initialized {} elements ({d:.2} MB each)\n", .{
        n,
        @as(f64, @floatFromInt(size)) / (1024 * 1024),
    });

    // Step 4: Allocate device memory
    const d_a = try ctx.createBuffer(size, .device);
    defer ctx.destroyBuffer(d_a);
    const d_b = try ctx.createBuffer(size, .device);
    defer ctx.destroyBuffer(d_b);
    const d_c = try ctx.createBuffer(size, .device);
    defer ctx.destroyBuffer(d_c);
    std.debug.print("[4/8] Allocated device memory\n", .{});

    // Step 5: Upload data
    var timer = try ctx.createTimer();
    defer timer.destroy();

    try timer.start();
    try ctx.memcpyH2D(d_a, std.mem.sliceAsBytes(h_a));
    try ctx.memcpyH2D(d_b, std.mem.sliceAsBytes(h_b));
    try timer.stop();

    const upload_time = try timer.elapsedMs();
    std.debug.print("[5/8] Uploaded data ({d:.2} ms, {d:.2} GB/s)\n", .{
        upload_time,
        (2.0 * @as(f64, @floatFromInt(size)) / (1024 * 1024 * 1024)) / (upload_time / 1000.0),
    });

    // Step 6: Load module and get kernel
    const module = try ctx.createModulePtx(vector_add_ptx);
    defer ctx.destroyModule(module);

    const kernel = try ctx.getKernel(module, "vector_add");
    std.debug.print("[6/8] Loaded kernel 'vector_add'\n", .{});

    // Step 7: Launch kernel
    const block_size: u32 = 256;
    const grid_size = (n + block_size - 1) / block_size;

    // Set up kernel arguments
    var a_ptr: u64 = d_a.ptr;
    var b_ptr: u64 = d_b.ptr;
    var c_ptr: u64 = d_c.ptr;
    var n_val: u32 = n;

    var args = cuda.KernelArgs(8){};
    args.addPtr(&a_ptr);
    args.addPtr(&b_ptr);
    args.addPtr(&c_ptr);
    args.addPtr(&n_val);

    try timer.start();
    try ctx.launch(kernel, .{
        .grid = .{ grid_size, 1, 1 },
        .block = .{ block_size, 1, 1 },
    }, args.getArgs());
    try ctx.syncAll();
    try timer.stop();

    const kernel_time = try timer.elapsedMs();
    std.debug.print("[7/8] Kernel executed ({d:.3} ms, {} blocks x {} threads)\n", .{
        kernel_time,
        grid_size,
        block_size,
    });

    // Step 8: Download results and verify
    try timer.start();
    try ctx.memcpyD2H(std.mem.sliceAsBytes(h_c), d_c);
    try timer.stop();

    const download_time = try timer.elapsedMs();

    // Verify results
    var errors: usize = 0;
    for (h_c, 0..) |c, i| {
        const expected: f32 = @as(f32, @floatFromInt(i)) + @as(f32, @floatFromInt(i * 2));
        if (@abs(c - expected) > 0.001) {
            if (errors < 5) {
                std.debug.print("  Error at {}: got {d}, expected {d}\n", .{ i, c, expected });
            }
            errors += 1;
        }
    }

    if (errors == 0) {
        std.debug.print("[8/8] Results verified - all {} elements correct!\n", .{n});
    } else {
        std.debug.print("[8/8] Verification FAILED - {} errors\n", .{errors});
    }

    // Summary
    std.debug.print("\n=== Performance Summary ===\n", .{});
    std.debug.print("  Upload:   {d:.2} ms ({d:.2} GB/s)\n", .{
        upload_time,
        (2.0 * @as(f64, @floatFromInt(size)) / (1024 * 1024 * 1024)) / (upload_time / 1000.0),
    });
    std.debug.print("  Kernel:   {d:.3} ms\n", .{kernel_time});
    std.debug.print("  Download: {d:.2} ms ({d:.2} GB/s)\n", .{
        download_time,
        (@as(f64, @floatFromInt(size)) / (1024 * 1024 * 1024)) / (download_time / 1000.0),
    });
    std.debug.print("  Total:    {d:.2} ms\n", .{upload_time + kernel_time + download_time});

    const stats = ctx.getMemoryStats();
    std.debug.print("\n=== Memory Statistics ===\n", .{});
    std.debug.print("  Device Allocations: {}\n", .{stats.device_allocs});
    std.debug.print("  Device Bytes: {d:.2} MB\n", .{
        @as(f64, @floatFromInt(stats.device_bytes_allocated)) / (1024 * 1024),
    });
    std.debug.print("  H2D Transfers: {} ({d:.2} MB)\n", .{
        stats.h2d_transfers,
        @as(f64, @floatFromInt(stats.h2d_bytes)) / (1024 * 1024),
    });
    std.debug.print("  D2H Transfers: {} ({d:.2} MB)\n", .{
        stats.d2h_transfers,
        @as(f64, @floatFromInt(stats.d2h_bytes)) / (1024 * 1024),
    });

    std.debug.print("\n", .{});
}
