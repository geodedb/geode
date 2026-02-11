//! CUDA Benchmarks
//!
//! Measures GPU performance characteristics:
//! - Host-to-Device bandwidth
//! - Device-to-Host bandwidth
//! - Kernel launch overhead
//! - End-to-end throughput
//!
//! Outputs results to stdout (human-readable table) and JSON file.

const std = @import("std");
const cuda = @import("cuda");

const KB = 1024;
const MB = 1024 * 1024;
const GB = 1024 * 1024 * 1024;

// Test sizes
const sizes = [_]usize{
    64 * KB,
    256 * KB,
    1 * MB,
    4 * MB,
    16 * MB,
    64 * MB,
    256 * MB,
};

// Simple kernel PTX for launch overhead testing
const noop_kernel_ptx =
    \\.version 7.0
    \\.target sm_52
    \\.address_size 64
    \\
    \\.visible .entry noop_kernel()
    \\{
    \\    ret;
    \\}
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check CUDA availability
    var probe_result = try cuda.probe(allocator);
    defer probe_result.deinit(allocator);

    if (!probe_result.available) {
        std.debug.print("CUDA unavailable: {s}\n", .{probe_result.getErrorMessage()});
        return;
    }

    // Print device info
    if (probe_result.getBestDevice()) |dev| {
        std.debug.print("\n", .{});
        std.debug.print("========================================\n", .{});
        std.debug.print("CUDA Benchmark Suite\n", .{});
        std.debug.print("========================================\n", .{});
        std.debug.print("Device: {s}\n", .{dev.getName()});
        std.debug.print("Architecture: {s} (SM {}.{})\n", .{
            dev.getArchName(),
            dev.arch.major,
            dev.arch.minor,
        });
        std.debug.print("Memory: {d:.2} GB\n", .{@as(f64, @floatFromInt(dev.total_memory)) / GB});
        std.debug.print("SMs: {}\n", .{dev.sm_count});
        std.debug.print("Theoretical Bandwidth: {d:.1} GB/s\n", .{dev.theoreticalBandwidthGBps()});
        std.debug.print("========================================\n\n", .{});
    }

    // Create context
    var ctx = try cuda.Context.init(allocator, .{});
    defer ctx.deinit();

    // Results storage
    var results: std.ArrayList(BenchResult) = .{};
    defer results.deinit(allocator);

    // Run benchmarks
    try benchH2D(&ctx, allocator, &results);
    try benchD2H(&ctx, allocator, &results);
    try benchLaunchOverhead(&ctx, allocator, &results);
    try benchEndToEnd(&ctx, allocator, &results);

    // Output JSON
    try outputJson(&results, allocator);

    std.debug.print("\n[Results written to cuda_benchmark.json]\n", .{});
}

const BenchResult = struct {
    name: []const u8,
    size_bytes: usize,
    iterations: usize,
    mean_ms: f64,
    min_ms: f64,
    max_ms: f64,
    bandwidth_gbps: f64,
};

fn benchH2D(
    ctx: *cuda.Context,
    allocator: std.mem.Allocator,
    results: *std.ArrayList(BenchResult),
) !void {
    std.debug.print("Host-to-Device Transfer Bandwidth\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});
    std.debug.print("{s:<12} | {s:>10} | {s:>10} | {s:>10} | {s:>10}\n", .{
        "Size", "Mean (ms)", "Min (ms)", "Max (ms)", "BW (GB/s)",
    });
    std.debug.print("-" ** 60 ++ "\n", .{});

    for (sizes) |size| {
        const iterations: usize = if (size <= MB) 100 else if (size <= 16 * MB) 50 else 20;

        // Allocate host and device memory
        const host_data = try allocator.alloc(u8, size);
        defer allocator.free(host_data);
        @memset(host_data, 0xAB);

        const buffer = try ctx.createBuffer(size, .device);
        defer ctx.destroyBuffer(buffer);

        // Warmup
        try ctx.memcpyH2D(buffer, host_data);
        try ctx.syncAll();

        // Timed runs
        var timer = try ctx.createTimer();
        defer timer.destroy();

        var total: f64 = 0;
        var min: f64 = std.math.floatMax(f64);
        var max: f64 = 0;

        for (0..iterations) |_| {
            try timer.start();
            try ctx.memcpyH2D(buffer, host_data);
            try timer.stop();
            const elapsed = try timer.elapsedMs();

            total += elapsed;
            min = @min(min, elapsed);
            max = @max(max, elapsed);
        }

        const mean = total / @as(f64, @floatFromInt(iterations));
        const bw = (@as(f64, @floatFromInt(size)) / GB) / (mean / 1000.0);

        std.debug.print("{d:>10} KB | {d:>10.3} | {d:>10.3} | {d:>10.3} | {d:>10.2}\n", .{
            size / KB,
            mean,
            min,
            max,
            bw,
        });

        try results.append(allocator, .{
            .name = "H2D",
            .size_bytes = size,
            .iterations = iterations,
            .mean_ms = mean,
            .min_ms = min,
            .max_ms = max,
            .bandwidth_gbps = bw,
        });
    }
    std.debug.print("\n", .{});
}

fn benchD2H(
    ctx: *cuda.Context,
    allocator: std.mem.Allocator,
    results: *std.ArrayList(BenchResult),
) !void {
    std.debug.print("Device-to-Host Transfer Bandwidth\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});
    std.debug.print("{s:<12} | {s:>10} | {s:>10} | {s:>10} | {s:>10}\n", .{
        "Size", "Mean (ms)", "Min (ms)", "Max (ms)", "BW (GB/s)",
    });
    std.debug.print("-" ** 60 ++ "\n", .{});

    for (sizes) |size| {
        const iterations: usize = if (size <= MB) 100 else if (size <= 16 * MB) 50 else 20;

        // Allocate
        const host_data = try allocator.alloc(u8, size);
        defer allocator.free(host_data);

        const buffer = try ctx.createBuffer(size, .device);
        defer ctx.destroyBuffer(buffer);

        // Fill device memory
        try ctx.zeroBuffer(buffer);
        try ctx.syncAll();

        // Warmup
        try ctx.memcpyD2H(host_data, buffer);

        // Timed runs
        var timer = try ctx.createTimer();
        defer timer.destroy();

        var total: f64 = 0;
        var min: f64 = std.math.floatMax(f64);
        var max: f64 = 0;

        for (0..iterations) |_| {
            try timer.start();
            try ctx.memcpyD2H(host_data, buffer);
            try timer.stop();
            const elapsed = try timer.elapsedMs();

            total += elapsed;
            min = @min(min, elapsed);
            max = @max(max, elapsed);
        }

        const mean = total / @as(f64, @floatFromInt(iterations));
        const bw = (@as(f64, @floatFromInt(size)) / GB) / (mean / 1000.0);

        std.debug.print("{d:>10} KB | {d:>10.3} | {d:>10.3} | {d:>10.3} | {d:>10.2}\n", .{
            size / KB,
            mean,
            min,
            max,
            bw,
        });

        try results.append(allocator, .{
            .name = "D2H",
            .size_bytes = size,
            .iterations = iterations,
            .mean_ms = mean,
            .min_ms = min,
            .max_ms = max,
            .bandwidth_gbps = bw,
        });
    }
    std.debug.print("\n", .{});
}

fn benchLaunchOverhead(
    ctx: *cuda.Context,
    allocator: std.mem.Allocator,
    results: *std.ArrayList(BenchResult),
) !void {
    std.debug.print("Kernel Launch Overhead\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});

    // Load noop kernel
    const module = ctx.createModulePtx(noop_kernel_ptx) catch |err| {
        std.debug.print("Could not load test kernel: {}\n\n", .{err});
        return;
    };
    defer ctx.destroyModule(module);

    const kernel = ctx.getKernel(module, "noop_kernel") catch |err| {
        std.debug.print("Could not find test kernel: {}\n\n", .{err});
        return;
    };

    const iterations: usize = 10000;

    // Warmup
    for (0..100) |_| {
        try ctx.launch(kernel, .{ .grid = .{ 1, 1, 1 }, .block = .{ 1, 1, 1 } }, null);
    }
    try ctx.syncAll();

    // Timed runs
    var timer = try ctx.createTimer();
    defer timer.destroy();

    var total: f64 = 0;
    var min: f64 = std.math.floatMax(f64);
    var max: f64 = 0;

    for (0..iterations) |_| {
        try timer.start();
        try ctx.launch(kernel, .{ .grid = .{ 1, 1, 1 }, .block = .{ 1, 1, 1 } }, null);
        try timer.stop();
        const elapsed = try timer.elapsedMs();

        total += elapsed;
        min = @min(min, elapsed);
        max = @max(max, elapsed);
    }
    try ctx.syncAll();

    const mean = total / @as(f64, @floatFromInt(iterations));

    std.debug.print("Iterations: {}\n", .{iterations});
    std.debug.print("Mean launch time: {d:.3} us\n", .{mean * 1000.0});
    std.debug.print("Min launch time: {d:.3} us\n", .{min * 1000.0});
    std.debug.print("Max launch time: {d:.3} us\n", .{max * 1000.0});
    std.debug.print("\n", .{});

    try results.append(allocator, .{
        .name = "LaunchOverhead",
        .size_bytes = 0,
        .iterations = iterations,
        .mean_ms = mean,
        .min_ms = min,
        .max_ms = max,
        .bandwidth_gbps = 0,
    });
}

fn benchEndToEnd(
    ctx: *cuda.Context,
    allocator: std.mem.Allocator,
    results: *std.ArrayList(BenchResult),
) !void {
    std.debug.print("End-to-End (H2D + Kernel + D2H)\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});
    std.debug.print("{s:<12} | {s:>10} | {s:>10} | {s:>10} | {s:>10}\n", .{
        "Size", "Mean (ms)", "Min (ms)", "Max (ms)", "BW (GB/s)",
    });
    std.debug.print("-" ** 60 ++ "\n", .{});

    // Load noop kernel for timing
    const module = ctx.createModulePtx(noop_kernel_ptx) catch {
        std.debug.print("Could not load test kernel\n\n", .{});
        return;
    };
    defer ctx.destroyModule(module);

    const kernel = ctx.getKernel(module, "noop_kernel") catch {
        std.debug.print("Could not find test kernel\n\n", .{});
        return;
    };

    for (sizes[0..5]) |size| { // Limit to smaller sizes
        const iterations: usize = if (size <= MB) 50 else 20;

        // Allocate
        const host_in = try allocator.alloc(u8, size);
        defer allocator.free(host_in);
        const host_out = try allocator.alloc(u8, size);
        defer allocator.free(host_out);
        @memset(host_in, 0xCD);

        const buffer = try ctx.createBuffer(size, .device);
        defer ctx.destroyBuffer(buffer);

        // Warmup
        try ctx.memcpyH2D(buffer, host_in);
        try ctx.launch(kernel, .{ .grid = .{ 1, 1, 1 }, .block = .{ 256, 1, 1 } }, null);
        try ctx.memcpyD2H(host_out, buffer);
        try ctx.syncAll();

        // Timed runs
        var timer = try ctx.createTimer();
        defer timer.destroy();

        var total: f64 = 0;
        var min: f64 = std.math.floatMax(f64);
        var max: f64 = 0;

        for (0..iterations) |_| {
            try timer.start();
            try ctx.memcpyH2D(buffer, host_in);
            try ctx.launch(kernel, .{ .grid = .{ 1, 1, 1 }, .block = .{ 256, 1, 1 } }, null);
            try ctx.memcpyD2H(host_out, buffer);
            try timer.stop();
            const elapsed = try timer.elapsedMs();

            total += elapsed;
            min = @min(min, elapsed);
            max = @max(max, elapsed);
        }

        const mean = total / @as(f64, @floatFromInt(iterations));
        // Bidirectional bandwidth
        const bw = (2.0 * @as(f64, @floatFromInt(size)) / GB) / (mean / 1000.0);

        std.debug.print("{d:>10} KB | {d:>10.3} | {d:>10.3} | {d:>10.3} | {d:>10.2}\n", .{
            size / KB,
            mean,
            min,
            max,
            bw,
        });

        try results.append(allocator, .{
            .name = "EndToEnd",
            .size_bytes = size,
            .iterations = iterations,
            .mean_ms = mean,
            .min_ms = min,
            .max_ms = max,
            .bandwidth_gbps = bw,
        });
    }
    std.debug.print("\n", .{});
}

fn outputJson(results: *std.ArrayList(BenchResult), allocator: std.mem.Allocator) !void {
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    const writer = json.writer(allocator);
    try writer.writeAll("{\n  \"benchmarks\": [\n");

    for (results.items, 0..) |r, i| {
        if (i > 0) try writer.writeAll(",\n");
        try writer.print(
            \\    {{
            \\      "name": "{s}",
            \\      "size_bytes": {},
            \\      "iterations": {},
            \\      "mean_ms": {d:.6},
            \\      "min_ms": {d:.6},
            \\      "max_ms": {d:.6},
            \\      "bandwidth_gbps": {d:.6}
            \\    }}
        , .{ r.name, r.size_bytes, r.iterations, r.mean_ms, r.min_ms, r.max_ms, r.bandwidth_gbps });
    }

    try writer.writeAll("\n  ]\n}\n");

    // Write to file
    const file = try std.fs.cwd().createFile("cuda_benchmark.json", .{});
    defer file.close();
    try file.writeAll(json.items);
}
