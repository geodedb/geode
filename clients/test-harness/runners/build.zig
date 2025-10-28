const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create executable
    const exe = b.addExecutable(.{
        .name = "zig_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add Zig client library path
    const zig_client_path = b.pathFromRoot("../../zig");
    exe.addIncludePath(.{ .cwd_relative = zig_client_path });

    b.installArtifact(exe);

    // Create run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the test runner");
    run_step.dependOn(&run_cmd.step);
}
