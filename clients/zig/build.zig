const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the test executable
    const test_exe = b.addExecutable(.{
        .name = "test_connection_v2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_connection_v2.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link msquic (check environment variable first, fall back to Nix path)
    const msquic_lib = b.graph.env_map.get("MSQUIC_LIB_DIR") orelse "/opt/msquic/lib";
    test_exe.addLibraryPath(.{ .cwd_relative = msquic_lib });
    test_exe.linkSystemLibrary("msquic");
    test_exe.linkLibC();

    // Create GeodeClient module that imports zig-msquic wrapper
    const client_mod = b.createModule(.{
        .root_source_file = b.path("geode_client_v2.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add imports for the client module (zig-msquic wrapper)
    const msquic_wrapper_mod = b.createModule(.{
        .root_source_file = b.path("../../tools/zig-msquic/src/msquic_wrapper.zig"),
        .target = target,
        .optimize = optimize,
    });

    client_mod.addImport("../../tools/zig-msquic/src/msquic_wrapper.zig", msquic_wrapper_mod);

    // Add modules to the test executable
    test_exe.root_module.addImport("geode_client_v2.zig", client_mod);

    b.installArtifact(test_exe);

    // Run command
    const run_test = b.addRunArtifact(test_exe);
    run_test.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the test");
    run_step.dependOn(&run_test.step);
}
