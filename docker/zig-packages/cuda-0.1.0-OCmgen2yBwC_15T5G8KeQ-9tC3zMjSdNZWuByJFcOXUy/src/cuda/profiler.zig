// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! CUDA Profiling and Telemetry
//!
//! This module provides performance profiling, timing, and diagnostics
//! for CUDA operations.
//!
//! ## Features
//! - Kernel execution timing
//! - Memory transfer timing
//! - Throughput calculation
//! - Performance profile generation
//! - JSON export for analysis

const std = @import("std");
const driver = @import("driver.zig");
const types = @import("types.zig");
const stream_mod = @import("stream.zig");

// ============================================================================
// Performance Profile
// ============================================================================

/// Detailed performance profile for a GPU operation
pub const PerformanceProfile = struct {
    /// Operation name/description
    operation: [128]u8 = [_]u8{0} ** 128,
    operation_len: usize = 0,

    // Memory transfer times (milliseconds)
    host_to_device_ms: f64 = 0,
    device_to_host_ms: f64 = 0,
    total_transfer_ms: f64 = 0,

    // Kernel execution time
    kernel_ms: f64 = 0,

    // Total end-to-end time
    total_ms: f64 = 0,

    // Data sizes (bytes)
    input_bytes: usize = 0,
    output_bytes: usize = 0,

    // Computed metrics
    transfer_overhead_percent: f64 = 0,
    kernel_percent: f64 = 0,
    effective_bandwidth_gbps: f64 = 0,

    /// Get operation name as slice
    pub fn getOperation(self: *const PerformanceProfile) []const u8 {
        return self.operation[0..self.operation_len];
    }

    /// Calculate derived metrics
    pub fn finalize(self: *PerformanceProfile) void {
        self.total_transfer_ms = self.host_to_device_ms + self.device_to_host_ms;

        if (self.total_ms > 0) {
            self.transfer_overhead_percent = (self.total_transfer_ms / self.total_ms) * 100.0;
            self.kernel_percent = (self.kernel_ms / self.total_ms) * 100.0;
        }

        // Calculate effective bandwidth (GB/s)
        if (self.total_transfer_ms > 0) {
            const total_bytes: f64 = @floatFromInt(self.input_bytes + self.output_bytes);
            const seconds = self.total_transfer_ms / 1000.0;
            self.effective_bandwidth_gbps = (total_bytes / (1024.0 * 1024.0 * 1024.0)) / seconds;
        }
    }

    /// Format as human-readable string
    pub fn format(self: *const PerformanceProfile, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\=== GPU Performance Profile: {s} ===
            \\Total time: {d:.2} ms
            \\
            \\Memory Transfers:
            \\  Host->Device: {d:.2} ms ({d:.1}%)
            \\  Device->Host: {d:.2} ms ({d:.1}%)
            \\  Total Transfer: {d:.2} ms ({d:.1}%)
            \\
            \\Kernel Execution: {d:.2} ms ({d:.1}%)
            \\
            \\Data Transfer:
            \\  Input: {d:.2} MB
            \\  Output: {d:.2} MB
            \\  Effective Bandwidth: {d:.2} GB/s
            \\
            \\{s}
        , .{
            self.getOperation(),
            self.total_ms,
            self.host_to_device_ms,
            if (self.total_ms > 0) (self.host_to_device_ms / self.total_ms) * 100.0 else 0.0,
            self.device_to_host_ms,
            if (self.total_ms > 0) (self.device_to_host_ms / self.total_ms) * 100.0 else 0.0,
            self.total_transfer_ms,
            self.transfer_overhead_percent,
            self.kernel_ms,
            self.kernel_percent,
            @as(f64, @floatFromInt(self.input_bytes)) / (1024.0 * 1024.0),
            @as(f64, @floatFromInt(self.output_bytes)) / (1024.0 * 1024.0),
            self.effective_bandwidth_gbps,
            self.getAnalysis(),
        });
    }

    /// Get analysis/recommendations
    fn getAnalysis(self: *const PerformanceProfile) []const u8 {
        if (self.transfer_overhead_percent > 70.0) {
            return "WARNING: HIGH TRANSFER OVERHEAD - Consider larger batch sizes or pinned memory";
        } else if (self.transfer_overhead_percent > 40.0) {
            return "NOTE: Moderate transfer overhead - Consider optimizing transfer strategy";
        } else {
            return "OK: Good compute/transfer balance";
        }
    }

    /// Export to JSON format
    pub fn toJson(self: *const PerformanceProfile, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\{{
            \\  "operation": "{s}",
            \\  "total_ms": {d:.3},
            \\  "host_to_device_ms": {d:.3},
            \\  "device_to_host_ms": {d:.3},
            \\  "kernel_ms": {d:.3},
            \\  "transfer_overhead_percent": {d:.2},
            \\  "kernel_percent": {d:.2},
            \\  "input_mb": {d:.3},
            \\  "output_mb": {d:.3},
            \\  "effective_bandwidth_gbps": {d:.3}
            \\}}
        , .{
            self.getOperation(),
            self.total_ms,
            self.host_to_device_ms,
            self.device_to_host_ms,
            self.kernel_ms,
            self.transfer_overhead_percent,
            self.kernel_percent,
            @as(f64, @floatFromInt(self.input_bytes)) / (1024.0 * 1024.0),
            @as(f64, @floatFromInt(self.output_bytes)) / (1024.0 * 1024.0),
            self.effective_bandwidth_gbps,
        });
    }
};

// ============================================================================
// Profile Timer
// ============================================================================

/// Timer for building performance profiles
pub const ProfileTimer = struct {
    start_time: i64,
    profile: PerformanceProfile,
    h2d_start: i64 = 0,
    kernel_start: i64 = 0,
    d2h_start: i64 = 0,

    /// Start a new profile timer
    pub fn start(operation: []const u8) ProfileTimer {
        var timer = ProfileTimer{
            .start_time = std.time.microTimestamp(),
            .profile = .{},
        };

        const len = @min(operation.len, timer.profile.operation.len);
        @memcpy(timer.profile.operation[0..len], operation[0..len]);
        timer.profile.operation_len = len;

        return timer;
    }

    /// Mark start of host-to-device transfer
    pub fn markH2DStart(self: *ProfileTimer) void {
        self.h2d_start = std.time.microTimestamp();
    }

    /// Mark end of host-to-device transfer
    pub fn markH2DEnd(self: *ProfileTimer, bytes: usize) void {
        const now = std.time.microTimestamp();
        self.profile.host_to_device_ms = @as(f64, @floatFromInt(now - self.h2d_start)) / 1000.0;
        self.profile.input_bytes = bytes;
    }

    /// Mark start of kernel execution
    pub fn markKernelStart(self: *ProfileTimer) void {
        self.kernel_start = std.time.microTimestamp();
    }

    /// Mark end of kernel execution
    pub fn markKernelEnd(self: *ProfileTimer) void {
        const now = std.time.microTimestamp();
        self.profile.kernel_ms = @as(f64, @floatFromInt(now - self.kernel_start)) / 1000.0;
    }

    /// Set kernel time directly (e.g., from CUDA events)
    pub fn setKernelTime(self: *ProfileTimer, ms: f64) void {
        self.profile.kernel_ms = ms;
    }

    /// Mark start of device-to-host transfer
    pub fn markD2HStart(self: *ProfileTimer) void {
        self.d2h_start = std.time.microTimestamp();
    }

    /// Mark end of device-to-host transfer
    pub fn markD2HEnd(self: *ProfileTimer, bytes: usize) void {
        const now = std.time.microTimestamp();
        self.profile.device_to_host_ms = @as(f64, @floatFromInt(now - self.d2h_start)) / 1000.0;
        self.profile.output_bytes = bytes;
    }

    /// Finish timing and get profile
    pub fn finish(self: *ProfileTimer) PerformanceProfile {
        const end = std.time.microTimestamp();
        self.profile.total_ms = @as(f64, @floatFromInt(end - self.start_time)) / 1000.0;
        self.profile.finalize();
        return self.profile;
    }
};

// ============================================================================
// GPU Metrics
// ============================================================================

/// GPU performance metrics for a kernel execution
pub const GpuMetrics = struct {
    /// Kernel execution time (ms)
    kernel_ms: f64,
    /// Estimated occupancy (0-100%)
    occupancy_pct: f64,
    /// Effective bandwidth (GB/s)
    bandwidth_gbps: f64,
    /// Device ID
    device_id: u32,
    /// Kernel name
    kernel_name: [128]u8 = [_]u8{0} ** 128,
    kernel_name_len: usize = 0,

    pub fn getKernelName(self: *const GpuMetrics) []const u8 {
        return self.kernel_name[0..self.kernel_name_len];
    }
};

/// GPU diagnostic information
pub const GpuDiagnostics = struct {
    /// Whether GPU is enabled/available
    gpu_enabled: bool,
    /// Whether GPU was actually used
    gpu_used: bool,
    /// Reason for fallback (if any)
    fallback_reason: ?[]const u8,
    /// Performance metrics (if GPU was used)
    metrics: ?GpuMetrics,
};

// ============================================================================
// GPU Event-Based Profiling (#14)
// ============================================================================

/// GPU event-based profiler for accurate GPU timing
/// Uses CUDA events for precise GPU-side timing without CPU synchronization overhead
pub const EventProfiler = struct {
    /// CUDA driver reference
    drv: *const driver.CudaDriver,
    /// Start event
    start_event: ?types.CUevent = null,
    /// End event
    end_event: ?types.CUevent = null,
    /// Named timing regions
    regions: std.StringHashMap(TimingRegion),
    /// Allocator
    allocator: std.mem.Allocator,
    /// Whether profiling is active
    active: bool = false,

    const TimingRegion = struct {
        start_event: types.CUevent,
        end_event: types.CUevent,
        recorded: bool = false,
    };

    /// Create a new event profiler
    pub fn init(drv: *const driver.CudaDriver, allocator: std.mem.Allocator) !EventProfiler {
        if (!drv.supportsEvents()) return types.CudaError.NotSupported;

        var start_evt: types.CUevent = undefined;
        var end_evt: types.CUevent = undefined;

        if (drv.eventCreate(&start_evt, 0) != types.CUDA_SUCCESS) {
            return types.CudaError.GpuError;
        }
        errdefer _ = drv.eventDestroy(start_evt);

        if (drv.eventCreate(&end_evt, 0) != types.CUDA_SUCCESS) {
            return types.CudaError.GpuError;
        }

        return EventProfiler{
            .drv = drv,
            .start_event = start_evt,
            .end_event = end_evt,
            .regions = std.StringHashMap(TimingRegion).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up profiler
    pub fn deinit(self: *EventProfiler) void {
        // Destroy named region events
        var iter = self.regions.valueIterator();
        while (iter.next()) |region| {
            _ = self.drv.eventDestroy(region.start_event);
            _ = self.drv.eventDestroy(region.end_event);
        }
        self.regions.deinit();

        // Destroy main events
        if (self.start_event) |e| {
            _ = self.drv.eventDestroy(e);
            self.start_event = null;
        }
        if (self.end_event) |e| {
            _ = self.drv.eventDestroy(e);
            self.end_event = null;
        }
    }

    /// Start profiling (record start event on stream)
    pub fn start(self: *EventProfiler, stream: ?driver.CUstream) !void {
        if (self.start_event == null) return types.CudaError.InvalidArgument;
        const result = self.drv.eventRecord(self.start_event.?, stream);
        if (result != types.CUDA_SUCCESS) {
            return types.CudaError.GpuError;
        }
        self.active = true;
    }

    /// Stop profiling (record end event on stream)
    pub fn stop(self: *EventProfiler, stream: ?driver.CUstream) !void {
        if (self.end_event == null or !self.active) return types.CudaError.InvalidArgument;
        const result = self.drv.eventRecord(self.end_event.?, stream);
        if (result != types.CUDA_SUCCESS) {
            return types.CudaError.GpuError;
        }
    }

    /// Get elapsed time in milliseconds (synchronizes on end event)
    pub fn getElapsedMs(self: *EventProfiler) !f32 {
        if (self.start_event == null or self.end_event == null) {
            return types.CudaError.InvalidArgument;
        }

        // Wait for end event
        if (self.drv.eventSynchronize(self.end_event.?) != types.CUDA_SUCCESS) {
            return types.CudaError.SyncFailed;
        }

        var ms: f32 = 0;
        const result = self.drv.eventElapsedTime(&ms, self.start_event.?, self.end_event.?);
        if (result != types.CUDA_SUCCESS) {
            return types.CudaError.GpuError;
        }
        return ms;
    }

    /// Begin a named timing region
    pub fn beginRegion(self: *EventProfiler, name: []const u8, stream: ?driver.CUstream) !void {
        if (self.regions.get(name)) |*region| {
            _ = self.drv.eventRecord(region.start_event, stream);
        } else {
            var start_evt: types.CUevent = undefined;
            var end_evt: types.CUevent = undefined;

            if (self.drv.eventCreate(&start_evt, 0) != types.CUDA_SUCCESS) {
                return types.CudaError.GpuError;
            }
            errdefer _ = self.drv.eventDestroy(start_evt);

            if (self.drv.eventCreate(&end_evt, 0) != types.CUDA_SUCCESS) {
                return types.CudaError.GpuError;
            }

            _ = self.drv.eventRecord(start_evt, stream);

            const key = try self.allocator.dupe(u8, name);
            try self.regions.put(key, .{
                .start_event = start_evt,
                .end_event = end_evt,
                .recorded = false,
            });
        }
    }

    /// End a named timing region
    pub fn endRegion(self: *EventProfiler, name: []const u8, stream: ?driver.CUstream) !void {
        if (self.regions.getPtr(name)) |region| {
            _ = self.drv.eventRecord(region.end_event, stream);
            region.recorded = true;
        } else {
            return types.CudaError.InvalidArgument;
        }
    }

    /// Get elapsed time for a named region
    pub fn getRegionElapsedMs(self: *EventProfiler, name: []const u8) !f32 {
        if (self.regions.get(name)) |region| {
            if (!region.recorded) return types.CudaError.InvalidArgument;

            // Wait for end event
            if (self.drv.eventSynchronize(region.end_event) != types.CUDA_SUCCESS) {
                return types.CudaError.SyncFailed;
            }

            var ms: f32 = 0;
            const result = self.drv.eventElapsedTime(&ms, region.start_event, region.end_event);
            if (result != types.CUDA_SUCCESS) {
                return types.CudaError.GpuError;
            }
            return ms;
        } else {
            return types.CudaError.InvalidArgument;
        }
    }

    /// Get all region timings
    pub fn getAllRegionTimings(self: *EventProfiler, allocator: std.mem.Allocator) !std.StringHashMap(f32) {
        var timings = std.StringHashMap(f32).init(allocator);
        errdefer timings.deinit();

        var iter = self.regions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.recorded) {
                const ms = self.getRegionElapsedMs(entry.key_ptr.*) catch continue;
                try timings.put(entry.key_ptr.*, ms);
            }
        }

        return timings;
    }

    /// Reset profiler for reuse
    pub fn reset(self: *EventProfiler) void {
        self.active = false;
        // Reset recorded flags
        var iter = self.regions.valueIterator();
        while (iter.next()) |region| {
            region.recorded = false;
        }
    }
};

/// Scoped profiler that automatically records start/end
pub const ScopedProfiler = struct {
    profiler: *EventProfiler,
    region_name: []const u8,
    stream: ?driver.CUstream,

    pub fn init(profiler: *EventProfiler, name: []const u8, stream: ?driver.CUstream) !ScopedProfiler {
        try profiler.beginRegion(name, stream);
        return ScopedProfiler{
            .profiler = profiler,
            .region_name = name,
            .stream = stream,
        };
    }

    pub fn end(self: *ScopedProfiler) void {
        self.profiler.endRegion(self.region_name, self.stream) catch {};
    }
};

// ============================================================================
// Benchmark Harness
// ============================================================================

/// Benchmark result for a single run
pub const BenchmarkResult = struct {
    /// Operation name
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: usize = 0,
    /// Number of iterations
    iterations: usize,
    /// Total time (ms)
    total_ms: f64,
    /// Mean time per iteration (ms)
    mean_ms: f64,
    /// Minimum time (ms)
    min_ms: f64,
    /// Maximum time (ms)
    max_ms: f64,
    /// Standard deviation (ms)
    std_dev_ms: f64,
    /// Throughput (operations/sec)
    throughput: f64,
    /// Data size per iteration (bytes)
    data_size: usize,
    /// Bandwidth (GB/s)
    bandwidth_gbps: f64,

    pub fn getName(self: *const BenchmarkResult) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Format as table row
    pub fn formatRow(self: *const BenchmarkResult, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\{s:<30} | {d:>8} | {d:>10.3} | {d:>10.3} | {d:>10.3} | {d:>10.2}
        , .{
            self.getName(),
            self.iterations,
            self.mean_ms,
            self.min_ms,
            self.max_ms,
            self.bandwidth_gbps,
        });
    }

    /// Export to JSON
    pub fn toJson(self: *const BenchmarkResult, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\{{
            \\  "name": "{s}",
            \\  "iterations": {},
            \\  "total_ms": {d:.3},
            \\  "mean_ms": {d:.3},
            \\  "min_ms": {d:.3},
            \\  "max_ms": {d:.3},
            \\  "std_dev_ms": {d:.3},
            \\  "throughput": {d:.2},
            \\  "data_size": {},
            \\  "bandwidth_gbps": {d:.3}
            \\}}
        , .{
            self.getName(),
            self.iterations,
            self.total_ms,
            self.mean_ms,
            self.min_ms,
            self.max_ms,
            self.std_dev_ms,
            self.throughput,
            self.data_size,
            self.bandwidth_gbps,
        });
    }
};

/// Run a benchmark function multiple times
pub fn benchmark(
    name: []const u8,
    iterations: usize,
    data_size: usize,
    func: *const fn () void,
) BenchmarkResult {
    var result = BenchmarkResult{
        .iterations = iterations,
        .data_size = data_size,
        .min_ms = std.math.floatMax(f64),
        .max_ms = 0,
        .total_ms = 0,
        .mean_ms = 0,
        .std_dev_ms = 0,
        .throughput = 0,
        .bandwidth_gbps = 0,
    };

    const len = @min(name.len, result.name.len);
    @memcpy(result.name[0..len], name[0..len]);
    result.name_len = len;

    var times: std.ArrayList(f64) = .{};
    defer times.deinit(std.heap.page_allocator);

    // Warmup
    func();

    // Timed runs
    var total: f64 = 0;
    for (0..iterations) |_| {
        const start = std.time.microTimestamp();
        func();
        const end = std.time.microTimestamp();
        const elapsed: f64 = @as(f64, @floatFromInt(end - start)) / 1000.0;

        times.append(std.heap.page_allocator, elapsed) catch {};
        total += elapsed;
        result.min_ms = @min(result.min_ms, elapsed);
        result.max_ms = @max(result.max_ms, elapsed);
    }

    result.total_ms = total;
    result.mean_ms = total / @as(f64, @floatFromInt(iterations));
    result.throughput = @as(f64, @floatFromInt(iterations)) / (total / 1000.0);

    // Calculate bandwidth
    if (data_size > 0 and result.mean_ms > 0) {
        const bytes_per_sec = @as(f64, @floatFromInt(data_size)) / (result.mean_ms / 1000.0);
        result.bandwidth_gbps = bytes_per_sec / (1024.0 * 1024.0 * 1024.0);
    }

    // Calculate std dev
    if (times.items.len > 1) {
        var sum_sq: f64 = 0;
        for (times.items) |t| {
            const diff = t - result.mean_ms;
            sum_sq += diff * diff;
        }
        result.std_dev_ms = @sqrt(sum_sq / @as(f64, @floatFromInt(times.items.len - 1)));
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "PerformanceProfile finalize" {
    var profile = PerformanceProfile{
        .host_to_device_ms = 1.0,
        .device_to_host_ms = 0.5,
        .kernel_ms = 5.0,
        .total_ms = 6.5,
        .input_bytes = 1024 * 1024,
        .output_bytes = 1024 * 1024,
    };

    profile.finalize();

    try std.testing.expect(profile.total_transfer_ms > 0);
    try std.testing.expect(profile.transfer_overhead_percent > 0);
    try std.testing.expect(profile.kernel_percent > 0);
}

test "ProfileTimer basic usage" {
    var timer = ProfileTimer.start("test_operation");

    timer.markH2DStart();
    // Simulate work
    std.Thread.sleep(1_000_000); // 1ms
    timer.markH2DEnd(1024);

    timer.markKernelStart();
    std.Thread.sleep(1_000_000); // 1ms
    timer.markKernelEnd();

    timer.markD2HStart();
    std.Thread.sleep(1_000_000); // 1ms
    timer.markD2HEnd(1024);

    const profile = timer.finish();

    try std.testing.expect(profile.total_ms > 0);
    try std.testing.expect(profile.host_to_device_ms > 0);
    try std.testing.expect(profile.kernel_ms > 0);
    try std.testing.expect(profile.device_to_host_ms > 0);
}

test "BenchmarkResult JSON export" {
    var result = BenchmarkResult{
        .iterations = 100,
        .total_ms = 1000,
        .mean_ms = 10,
        .min_ms = 8,
        .max_ms = 15,
        .std_dev_ms = 2,
        .throughput = 100,
        .data_size = 1024 * 1024,
        .bandwidth_gbps = 1.5,
    };
    @memcpy(result.name[0..4], "test");
    result.name_len = 4;

    const json = try result.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"iterations\": 100") != null);
}
