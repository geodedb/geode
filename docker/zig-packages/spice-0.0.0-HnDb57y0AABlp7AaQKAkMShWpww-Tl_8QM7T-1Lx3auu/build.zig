const std = @import("std");

// Spice library build configuration - modified for Zig 0.15.x compatibility
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Export the spice module
    _ = b.addModule("spice", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
