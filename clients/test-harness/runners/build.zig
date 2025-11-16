const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the test runner executable
    const runner = b.addExecutable(.{
        .name = "zig_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig_runner_new.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link msquic
    runner.addLibraryPath(.{ .cwd_relative = "/nix/store/wdyb7p8h2fpbrgli3i1czdxsib9bhfm5-libmsquic-2.5.4/lib" });
    runner.linkSystemLibrary("msquic");
    runner.linkLibC();

    // Create msquic modules
    const msquic_types_mod = b.createModule(.{
        .root_source_file = b.path("../../../src/transport/msquic_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const msquic_wrapper_mod = b.createModule(.{
        .root_source_file = b.path("../../../src/transport/msquic_wrapper.zig"),
        .target = target,
        .optimize = optimize,
    });
    msquic_wrapper_mod.addImport("msquic_types.zig", msquic_types_mod);

    // Create GeodeClient module with msquic dependencies
    const client_mod = b.createModule(.{
        .root_source_file = b.path("../../zig/geode_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_mod.addImport("../../src/transport/msquic_wrapper", msquic_wrapper_mod);
    client_mod.addImport("../../src/transport/msquic_types", msquic_types_mod);

    // Create YAML parser module
    const yaml_mod = b.createModule(.{
        .root_source_file = b.path("../../../src/util/yaml.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add modules to the runner
    runner.root_module.addImport("../../zig/geode_client", client_mod);
    runner.root_module.addImport("yaml", yaml_mod);

    b.installArtifact(runner);

    // Run command
    const run_runner = b.addRunArtifact(runner);
    run_runner.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_runner.addArgs(args);
    }

    const run_step = b.step("run", "Run the test runner");
    run_step.dependOn(&run_runner.step);
}
