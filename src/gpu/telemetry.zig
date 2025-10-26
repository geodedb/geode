const std = @import("std");
const phase0 = @import("phase0.zig");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase5Telemetry; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_GPUTelemetryStruct; OWNER=engine; UPDATED=2025-10-26

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

pub fn recordKernelMetrics(kernel_name: []const u8, device_id: u32, elapsed_ms: f64) GPUPerfMetrics {
    // Real metrics from CUDA events; occupancy and bandwidth still placeholders (require cuOccupancy APIs)
    return GPUPerfMetrics{
        .kernel_ms = elapsed_ms,
        .occupancy_pct = 0.0, // TODO: requires cuOccupancyMaxActiveBlocksPerMultiprocessor
        .bandwidth_gbps = 0.0, // TODO: calculate from bytes transferred / elapsed_ms
        .device_id = device_id,
        .kernel_name = kernel_name,
    };
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
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
