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
    var list = std.ArrayList(GPUFlaggerFinding).init(allocator);
    // For now everything is unsupported and flagged
    inline for (@typeInfo(GPUFeature).Enum.fields) |f| {
        try list.append(.{ .feature = @enumFromInt(f.value), .supported = false, .note = "GPU acceleration not implemented" });
    }
    return try list.toOwnedSlice();
}

pub fn anySupported(findings: []const GPUFlaggerFinding) bool {
    for (findings) |f| if (f.supported) return true;
    return false;
}

// Simple diagnostic code simulation
pub const GPUStatus = enum { ok, unsupported };

pub fn status() GPUStatus {
    return .unsupported;
}

test "TestCANARY_REQ_GQL_051_GPUFlaggerUnsupported" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const findings = try detect(alloc);
    defer alloc.free(findings);
    try std.testing.expect(findings.len > 0);
    try std.testing.expect(!anySupported(findings));
    try std.testing.expect(status() == .unsupported);
}
