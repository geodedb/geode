const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the Geode client library
    const client_lib = b.addStaticLibrary(.{
        .name = "geode_client_zig",
        .root_source_file = b.path("geode_client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add msquic library dependency
    client_lib.linkSystemLibrary("msquic");
    client_lib.linkLibC();

    // Add module paths for imports
    const msquic_wrapper_path = b.path("../../src/transport/msquic_wrapper.zig");
    const msquic_types_path = b.path("../../src/transport/msquic_types.zig");

    const msquic_wrapper_mod = b.createModule(.{
        .root_source_file = msquic_wrapper_path,
    });
    const msquic_types_mod = b.createModule(.{
        .root_source_file = msquic_types_path,
    });

    client_lib.root_module.addImport("msquic_wrapper", msquic_wrapper_mod);
    client_lib.root_module.addImport("msquic_types", msquic_types_mod);

    b.installArtifact(client_lib);

    // Build example programs
    const example = b.addExecutable(.{
        .name = "geode_example",
        .root_source_file = b.path("example_usage.zig"),
        .target = target,
        .optimize = optimize,
    });

    example.linkLibrary(client_lib);
    example.linkSystemLibrary("msquic");
    example.linkLibC();

    const client_mod = b.createModule(.{
        .root_source_file = b.path("geode_client.zig"),
    });
    example.root_module.addImport("geode_client", client_mod);

    b.installArtifact(example);

    // Run example
    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_example.addArgs(args);
    }

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_example.step);
}
