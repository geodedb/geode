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

    // Link msquic and dependencies
    test_exe.linkLibC();
    test_exe.linkSystemLibrary("msquic");
    test_exe.linkSystemLibrary("ssl");
    test_exe.linkSystemLibrary("crypto");

    if (target.result.os.tag == .linux) {
        test_exe.linkSystemLibrary("dl");
    }

    // Add msquic include and lib paths (use environment variables or system defaults)
    // Use local fork headers and system library (Ubuntu libmsquic package)
    const msquic_include = b.graph.env_map.get("MSQUIC_INCLUDE_DIR") orelse "../../forks/msquic/src/inc";
    const msquic_lib = b.graph.env_map.get("MSQUIC_LIB_DIR") orelse "/usr/lib/x86_64-linux-gnu";

    test_exe.addIncludePath(.{ .cwd_relative = msquic_include });
    test_exe.addLibraryPath(.{ .cwd_relative = msquic_lib });

    // Add msquic types and wrapper modules
    const msquic_types_mod = b.createModule(.{
        .root_source_file = b.path("msquic_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const msquic_wrapper_mod = b.createModule(.{
        .root_source_file = b.path("msquic_wrapper.zig"),
        .target = target,
        .optimize = optimize,
    });

    msquic_wrapper_mod.addImport("msquic_types", msquic_types_mod);
    test_exe.root_module.addImport("msquic_wrapper", msquic_wrapper_mod);
    test_exe.root_module.addImport("msquic_types", msquic_types_mod);

    b.installArtifact(test_exe);

    // Run command
    const run_test = b.addRunArtifact(test_exe);
    run_test.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the test");
    run_step.dependOn(&run_test.step);
}
