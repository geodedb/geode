const std = @import("std");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=GPUFlagger; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_051_GPUFlaggerUnsupported; OWNER=engine; UPDATED=2025-09-21

pub const GPUFeature = enum {
    path_expand,
    pagerank,
    betweenness,
    shortest_path,
};

pub const GPUFlaggerFinding = struct {
    feature: GPUFeature,
    supported: bool,
    note: []const u8,
};

pub fn detect(allocator: std.mem.Allocator) ![]GPUFlaggerFinding {
    var list = try std.ArrayList(GPUFlaggerFinding).initCapacity(allocator, 0);
    defer list.deinit(allocator);
    const cuda = @import("cuda_loader.zig");
    var loader = cuda.CudaLoader.init();
    const has_cuda = if (@import("builtin").os.tag == .linux) loader.available() else false;
    const features = [_]GPUFeature{ .path_expand, .pagerank, .betweenness, .shortest_path };
    for (features) |feat| {
        const supported = has_cuda and (feat == .path_expand or feat == .shortest_path or feat == .pagerank);
        const note = if (supported) "CUDA dynamic driver detected" else "GPU acceleration not implemented or backend unavailable";
        try list.append(allocator, .{ .feature = feat, .supported = supported, .note = note });
    }
    return try list.toOwnedSlice(allocator); // ownership transfer
}

pub fn anySupported(findings: []const GPUFlaggerFinding) bool {
    for (findings) |f| if (f.supported) return true;
    return false;
}

// Simple diagnostic code simulation
pub const GPUStatus = enum { ok, unsupported };

pub fn status() GPUStatus {
    const cuda = @import("cuda_loader.zig");
    var loader = cuda.CudaLoader.init();
    return if (@import("builtin").os.tag == .linux and loader.available()) .ok else .unsupported;
}

test "TestCANARY_REQ_GQL_051_GPUFlaggerUnsupported" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const findings = try detect(alloc);
    defer alloc.free(findings);
    try std.testing.expect(findings.len > 0);
    const has_any = anySupported(findings);
    if (status() == .ok) {
        try std.testing.expect(has_any);
    } else {
        try std.testing.expect(!has_any);
    }
}
