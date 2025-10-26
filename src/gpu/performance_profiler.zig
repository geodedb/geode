// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=PerformanceProfiler; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_GPUPerformanceProfiler; OWNER=engine; UPDATED=2025-10-26

const std = @import("std");
const cuda_loader = @import("cuda_loader.zig");

/// Detailed performance profile for GPU operations
pub const PerformanceProfile = struct {
    operation: []const u8,
    
    // Memory transfer times
    host_to_device_ms: f64,
    device_to_host_ms: f64,
    total_transfer_ms: f64,
    
    // Kernel execution time
    kernel_ms: f64,
    
    // Total end-to-end time
    total_ms: f64,
    
    // Data sizes
    input_bytes: usize,
    output_bytes: usize,
    
    // Computed metrics
    transfer_overhead_percent: f64,
    kernel_percent: f64,
    effective_bandwidth_gbps: f64,
    
    pub fn init(operation: []const u8) PerformanceProfile {
        return .{
            .operation = operation,
            .host_to_device_ms = 0,
            .device_to_host_ms = 0,
            .total_transfer_ms = 0,
            .kernel_ms = 0,
            .total_ms = 0,
            .input_bytes = 0,
            .output_bytes = 0,
            .transfer_overhead_percent = 0,
            .kernel_percent = 0,
            .effective_bandwidth_gbps = 0,
        };
    }
    
    pub fn finalize(self: *PerformanceProfile) void {
        self.total_transfer_ms = self.host_to_device_ms + self.device_to_host_ms;
        
        if (self.total_ms > 0) {
            self.transfer_overhead_percent = (self.total_transfer_ms / self.total_ms) * 100.0;
            self.kernel_percent = (self.kernel_ms / self.total_ms) * 100.0;
        }
        
        // Calculate effective bandwidth (GB/s)
        if (self.total_transfer_ms > 0) {
            const total_bytes = @as(f64, @floatFromInt(self.input_bytes + self.output_bytes));
            const seconds = self.total_transfer_ms / 1000.0;
            self.effective_bandwidth_gbps = (total_bytes / (1024.0 * 1024.0 * 1024.0)) / seconds;
        }
    }
    
    pub fn print(self: PerformanceProfile) void {
        std.debug.print("\n=== GPU Performance Profile: {} ===\n", .{self.operation});
        std.debug.print("Total time: {d:.2} ms\n", .{self.total_ms});
        std.debug.print("\n", .{});
        
        std.debug.print("Memory Transfers:\n", .{});
        std.debug.print("  Host→Device: {d:.2} ms ({d:.1}%)\n", .{ 
            self.host_to_device_ms, 
            if (self.total_ms > 0) (self.host_to_device_ms / self.total_ms) * 100.0 else 0.0 
        });
        std.debug.print("  Device→Host: {d:.2} ms ({d:.1}%)\n", .{ 
            self.device_to_host_ms, 
            if (self.total_ms > 0) (self.device_to_host_ms / self.total_ms) * 100.0 else 0.0 
        });
        std.debug.print("  Total Transfer: {d:.2} ms ({d:.1}%)\n", .{ 
            self.total_transfer_ms, 
            self.transfer_overhead_percent 
        });
        std.debug.print("\n", .{});
        
        std.debug.print("Kernel Execution: {d:.2} ms ({d:.1}%)\n", .{ 
            self.kernel_ms, 
            self.kernel_percent 
        });
        std.debug.print("\n", .{});
        
        std.debug.print("Data Transfer:\n", .{});
        std.debug.print("  Input: {d:.2} MB\n", .{ 
            @as(f64, @floatFromInt(self.input_bytes)) / (1024.0 * 1024.0) 
        });
        std.debug.print("  Output: {d:.2} MB\n", .{ 
            @as(f64, @floatFromInt(self.output_bytes)) / (1024.0 * 1024.0) 
        });
        std.debug.print("  Effective Bandwidth: {d:.2} GB/s\n", .{self.effective_bandwidth_gbps});
        std.debug.print("\n", .{});
        
        // Analysis
        if (self.transfer_overhead_percent > 70.0) {
            std.debug.print("⚠️  HIGH TRANSFER OVERHEAD: {d:.1}% of time spent in memory transfers\n", .{self.transfer_overhead_percent});
            std.debug.print("   Recommendation: Increase data size or use pinned memory\n", .{});
        } else if (self.transfer_overhead_percent > 40.0) {
            std.debug.print("⚠️  MODERATE TRANSFER OVERHEAD: {d:.1}% of time spent in memory transfers\n", .{self.transfer_overhead_percent});
            std.debug.print("   Recommendation: Consider optimizing transfer strategy\n", .{});
        } else {
            std.debug.print("✅ Good balance: {d:.1}% transfer, {d:.1}% compute\n", .{ 
                self.transfer_overhead_percent, 
                self.kernel_percent 
            });
        }
        
        std.debug.print("===================================\n\n", .{});
    }
    
    /// Export to JSON format
    pub fn toJson(self: PerformanceProfile, allocator: std.mem.Allocator) ![]u8 {
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
            self.operation,
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

/// Timer for profiling GPU operations
pub const ProfileTimer = struct {
    start_time: i64,
    profile: PerformanceProfile,
    
    pub fn start(operation: []const u8) ProfileTimer {
        return .{
            .start_time = @intCast(std.time.nanoTimestamp()),
            .profile = PerformanceProfile.init(operation),
        };
    }
    
    pub fn markHostToDeviceStart(self: *ProfileTimer) void {
        _ = self;
        // Could use CUDA events here for more precision
    }
    
    pub fn markHostToDeviceEnd(self: *ProfileTimer, bytes: usize) void {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        const elapsed_ns = now - self.start_time;
        self.profile.host_to_device_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        self.profile.input_bytes = bytes;
    }
    
    pub fn markKernelStart(self: *ProfileTimer) void {
        _ = self;
        // Kernel timing should use CUDA events
    }
    
    pub fn markKernelEnd(self: *ProfileTimer, elapsed_ms: f64) void {
        self.profile.kernel_ms = elapsed_ms;
    }
    
    pub fn markDeviceToHostStart(self: *ProfileTimer) void {
        _ = self;
    }
    
    pub fn markDeviceToHostEnd(self: *ProfileTimer, bytes: usize) void {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        // Approximate - should use precise event timing
        self.profile.device_to_host_ms = @as(f64, @floatFromInt(now - self.start_time)) / 1_000_000.0 - 
                                         self.profile.host_to_device_ms - 
                                         self.profile.kernel_ms;
        self.profile.output_bytes = bytes;
    }
    
    pub fn finish(self: *ProfileTimer) PerformanceProfile {
        const end: i64 = @intCast(std.time.nanoTimestamp());
        const total_ns = end - self.start_time;
        self.profile.total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
        self.profile.finalize();
        return self.profile;
    }
};

test "ProfileTimer basic" {
    var timer = ProfileTimer.start("test_operation");
    
    // Simulate operations with busy wait instead of sleep
    const start: i64 = @intCast(std.time.nanoTimestamp());
    while (@as(i64, @intCast(std.time.nanoTimestamp())) - start < 1_000_000) {} // 1ms
    timer.markHostToDeviceEnd(1024 * 1024); // 1 MB
    
    const kernel_start: i64 = @intCast(std.time.nanoTimestamp());
    while (@as(i64, @intCast(std.time.nanoTimestamp())) - kernel_start < 5_000_000) {} // 5ms
    timer.markKernelEnd(5.0);
    
    const dth_start: i64 = @intCast(std.time.nanoTimestamp());
    while (@as(i64, @intCast(std.time.nanoTimestamp())) - dth_start < 1_000_000) {} // 1ms
    timer.markDeviceToHostEnd(512 * 1024); // 512 KB
    
    const profile = timer.finish();
    
    try std.testing.expect(profile.total_ms > 0);
    try std.testing.expect(profile.kernel_ms > 0);
}
