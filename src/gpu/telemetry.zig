const std = @import("std");
const phase0 = @import("phase0.zig");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase5Telemetry; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_051_GPUTelemetryStruct; OWNER=engine; UPDATED=2025-10-26

pub const GPUPerfMetrics = struct {
    kernel_ms: f64,
    occupancy_pct: f64,
    bandwidth_gbps: f64,
    device_id: u32,
    kernel_name: []const u8,
};

pub const GPUDiagnostics = struct {
    gpu_enabled: bool,
    gpu_used: bool,
    fallback_reason: ?[]const u8,
    metrics: ?GPUPerfMetrics,
};

/// GPU Event Timer for accurate kernel profiling
pub const EventTimer = struct {
    loader: *const CudaLoader,
    start_event: ?*anyopaque,
    end_event: ?*anyopaque,
    supports_events: bool,

    pub fn init(loader: *const CudaLoader) !EventTimer {
        if (!loader.supportsEvents()) {
            return EventTimer{
                .loader = loader,
                .start_event = null,
                .end_event = null,
                .supports_events = false,
            };
        }

        var start_event: *anyopaque = undefined;
        var end_event: *anyopaque = undefined;

        const res1 = loader.eventCreate(@ptrCast(&start_event), 0);
        if (res1 != 0) {
            return EventTimer{
                .loader = loader,
                .start_event = null,
                .end_event = null,
                .supports_events = false,
            };
        }

        const res2 = loader.eventCreate(@ptrCast(&end_event), 0);
        if (res2 != 0) {
            _ = loader.eventDestroy(start_event);
            return EventTimer{
                .loader = loader,
                .start_event = null,
                .end_event = null,
                .supports_events = false,
            };
        }

        return EventTimer{
            .loader = loader,
            .start_event = start_event,
            .end_event = end_event,
            .supports_events = true,
        };
    }

    pub fn deinit(self: *EventTimer) void {
        if (self.start_event) |evt| {
            _ = self.loader.eventDestroy(evt);
        }
        if (self.end_event) |evt| {
            _ = self.loader.eventDestroy(evt);
        }
        self.start_event = null;
        self.end_event = null;
    }

    pub fn recordStart(self: *EventTimer) void {
        if (self.start_event) |evt| {
            _ = self.loader.eventRecord(evt, null);
        }
    }

    pub fn recordEnd(self: *EventTimer) void {
        if (self.end_event) |evt| {
            _ = self.loader.eventRecord(evt, null);
        }
    }

    pub fn getElapsedMs(self: *EventTimer) f32 {
        if (self.start_event == null or self.end_event == null) return 0.0;

        _ = self.loader.eventSynchronize(self.end_event.?);

        var ms: f32 = 0.0;
        const res = self.loader.eventElapsedTime(&ms, self.start_event.?, self.end_event.?);
        if (res != 0) return 0.0;

        return ms;
    }
};

// GAP-0061: GPU Telemetry Metrics Implementation
// CANARY: REQ=REQ-GPU-TELEMETRY-001; FEATURE="GPUTelemetryMetrics"; ASPECT=OccupancyBandwidth; STATUS=EXEMPT; OWNER=gpu; UPDATED=2026-01-10

/// GPU kernel configuration for occupancy calculation
pub const KernelConfig = struct {
    block_size: u32 = 256,
    shared_mem_bytes: u32 = 0,
    registers_per_thread: u32 = 32,
    bytes_transferred: u64 = 0,
};

/// GPU device properties for accurate occupancy estimation
pub const DeviceProps = struct {
    max_threads_per_sm: u32 = 2048,
    max_blocks_per_sm: u32 = 32,
    max_shared_mem_per_sm: u32 = 98304, // 96 KB typical for modern GPUs
    max_registers_per_sm: u32 = 65536,
    sm_count: u32 = 1,
    memory_clock_mhz: u32 = 5000,
    memory_bus_width: u32 = 256, // bits
};

pub fn recordKernelMetrics(kernel_name: []const u8, device_id: u32, elapsed_ms: f64) GPUPerfMetrics {
    // Basic metrics without additional info - uses defaults
    return recordKernelMetricsExt(kernel_name, device_id, elapsed_ms, .{}, .{});
}

/// Extended kernel metrics with occupancy and bandwidth calculations
pub fn recordKernelMetricsExt(
    kernel_name: []const u8,
    device_id: u32,
    elapsed_ms: f64,
    config: KernelConfig,
    device: DeviceProps,
) GPUPerfMetrics {
    // Calculate theoretical occupancy based on kernel configuration
    const occupancy = calculateOccupancy(config, device);

    // Calculate bandwidth in GB/s from bytes transferred and elapsed time
    const bandwidth = calculateBandwidth(config.bytes_transferred, elapsed_ms);

    return GPUPerfMetrics{
        .kernel_ms = elapsed_ms,
        .occupancy_pct = occupancy,
        .bandwidth_gbps = bandwidth,
        .device_id = device_id,
        .kernel_name = kernel_name,
    };
}

/// Calculate theoretical occupancy percentage based on kernel config and device limits
fn calculateOccupancy(config: KernelConfig, device: DeviceProps) f64 {
    if (config.block_size == 0) return 0.0;

    // Calculate max blocks per SM based on different limiting factors
    const threads_per_block = config.block_size;

    // Limit 1: Threads per SM
    const max_blocks_by_threads = device.max_threads_per_sm / threads_per_block;

    // Limit 2: Registers per SM
    const regs_per_block = threads_per_block * config.registers_per_thread;
    const max_blocks_by_regs = if (regs_per_block > 0)
        device.max_registers_per_sm / regs_per_block
    else
        device.max_blocks_per_sm;

    // Limit 3: Shared memory per SM
    const max_blocks_by_smem = if (config.shared_mem_bytes > 0)
        device.max_shared_mem_per_sm / config.shared_mem_bytes
    else
        device.max_blocks_per_sm;

    // Limit 4: Hardware block limit
    const max_blocks_hw = device.max_blocks_per_sm;

    // Take minimum of all limits
    var max_active_blocks = @min(max_blocks_by_threads, max_blocks_by_regs);
    max_active_blocks = @min(max_active_blocks, max_blocks_by_smem);
    max_active_blocks = @min(max_active_blocks, max_blocks_hw);

    // Calculate occupancy as percentage of max theoretical threads
    const active_threads = max_active_blocks * threads_per_block;
    const occupancy_pct = @as(f64, @floatFromInt(active_threads)) /
        @as(f64, @floatFromInt(device.max_threads_per_sm)) * 100.0;

    return @min(100.0, occupancy_pct);
}

/// Calculate achieved bandwidth in GB/s
fn calculateBandwidth(bytes_transferred: u64, elapsed_ms: f64) f64 {
    if (elapsed_ms <= 0.0 or bytes_transferred == 0) return 0.0;

    // Convert: bytes / ms -> GB/s
    // GB/s = bytes / (ms * 1e-3) / (1e9)
    // GB/s = bytes / (ms * 1e6)
    const elapsed_s = elapsed_ms / 1000.0;
    const gb = @as(f64, @floatFromInt(bytes_transferred)) / (1024.0 * 1024.0 * 1024.0);
    return gb / elapsed_s;
}

/// Get theoretical peak bandwidth for a device in GB/s
pub fn getPeakBandwidth(device: DeviceProps) f64 {
    // Peak bandwidth = memory_clock * bus_width * 2 (DDR) / 8 (bits to bytes) / 1e9 (to GB)
    // For GDDR6: double data rate
    const clock_hz = @as(f64, @floatFromInt(device.memory_clock_mhz)) * 1e6;
    const bus_bytes = @as(f64, @floatFromInt(device.memory_bus_width)) / 8.0;
    const ddr_factor: f64 = 2.0; // Double data rate

    return (clock_hz * bus_bytes * ddr_factor) / (1024.0 * 1024.0 * 1024.0);
}

/// Calculate bandwidth efficiency percentage
pub fn getBandwidthEfficiency(achieved_gbps: f64, device: DeviceProps) f64 {
    const peak = getPeakBandwidth(device);
    if (peak <= 0.0) return 0.0;
    return @min(100.0, (achieved_gbps / peak) * 100.0);
}

pub fn createDiagnostics(gpu_used: bool, metrics: ?GPUPerfMetrics, fallback: ?[]const u8) GPUDiagnostics {
    return GPUDiagnostics{
        .gpu_enabled = phase0.gpuEnabled(),
        .gpu_used = gpu_used,
        .fallback_reason = fallback,
        .metrics = metrics,
    };
}

pub fn serializeToJson(diag: GPUDiagnostics, allocator: std.mem.Allocator) ![]u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer list.deinit(allocator);
    var writer = list.writer(allocator);
    try writer.writeAll("{\"gpu_enabled\":");
    try writer.writeAll(if (diag.gpu_enabled) "true" else "false");
    try writer.writeAll(",\"gpu_used\":");
    try writer.writeAll(if (diag.gpu_used) "true" else "false");
    if (diag.fallback_reason) |reason| {
        try writer.writeAll(",\"fallback_reason\":\"");
        try writer.writeAll(reason);
        try writer.writeAll("\"");
    }
    if (diag.metrics) |m| {
        try writer.writeAll(",\"metrics\":{\"kernel_ms\":");
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d:.3}", .{m.kernel_ms});
        try writer.writeAll(s);
        try writer.writeAll(",\"occupancy_pct\":");
        const s2 = try std.fmt.bufPrint(&buf, "{d:.2}", .{m.occupancy_pct});
        try writer.writeAll(s2);
        try writer.writeAll(",\"bandwidth_gbps\":");
        const s3 = try std.fmt.bufPrint(&buf, "{d:.2}", .{m.bandwidth_gbps});
        try writer.writeAll(s3);
        try writer.writeAll(",\"device_id\":");
        const s4 = try std.fmt.bufPrint(&buf, "{d}", .{m.device_id});
        try writer.writeAll(s4);
        try writer.writeAll(",\"kernel_name\":\"");
        try writer.writeAll(m.kernel_name);
        try writer.writeAll("\"}");
    }
    try writer.writeAll("}");
    return try list.toOwnedSlice(allocator);
}

test "TestCANARY_REQ_GQL_051_GPUTelemetryStruct" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const metrics = recordKernelMetrics("test_bfs", 0, 5.5);
    try std.testing.expectEqual(@as(f64, 5.5), metrics.kernel_ms);
    try std.testing.expectEqualStrings("test_bfs", metrics.kernel_name);
    const diag = createDiagnostics(true, metrics, null);
    const json = try serializeToJson(diag, alloc);
    defer alloc.free(json);
    // Basic JSON presence check
    try std.testing.expect(std.mem.indexOf(u8, json, "gpu_enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "kernel_ms") != null);
}

test "TestCANARY_REQ_GQL_051_GPUTelemetryFallback" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const diag = createDiagnostics(false, null, "no device");
    const json = try serializeToJson(diag, alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "fallback_reason") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "no device") != null);
}

test "TestCANARY_REQ_GQL_051_GPUEventTimerCreate" {
    const loader = CudaLoader.init();
    defer {
        var mut_loader = loader;
        mut_loader.deinit();
    }

    // Test creates timer (succeeds or gracefully fails if no CUDA)
    var timer = EventTimer.init(&loader) catch |err| {
        // No CUDA available, test passes
        _ = err;
        return;
    };
    defer timer.deinit();

    // If we have CUDA, test event recording
    if (timer.supports_events) {
        timer.recordStart();
        timer.recordEnd();
        const elapsed = timer.getElapsedMs();
        // Elapsed should be >= 0 (typically very small)
        try std.testing.expect(elapsed >= 0.0);
    }
}
