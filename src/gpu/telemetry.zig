const std = @import("std");
const phase0 = @import("phase0.zig");

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

pub fn recordKernelMetrics(kernel_name: []const u8, device_id: u32, start_ms: f64, end_ms: f64) GPUPerfMetrics {
    // Phase5 scaffold: placeholder metrics; real GPU profiling TBD
    return GPUPerfMetrics{
        .kernel_ms = end_ms - start_ms,
        .occupancy_pct = 0.0,
        .bandwidth_gbps = 0.0,
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
    const metrics = recordKernelMetrics("test_bfs", 0, 100.0, 105.5);
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
