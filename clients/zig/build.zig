const std = @import("std");

// Symlink to the authoritative vendor_setup.zig from vendor/quic/vendor_setup.zig
const quic_vendor_setup = @import("vendor_quic_setup.zig");

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

    test_exe.linkLibC();
    test_exe.linkSystemLibrary("ssl");
    test_exe.linkSystemLibrary("crypto");
    if (target.result.os.tag == .linux) {
        test_exe.linkSystemLibrary("dl");
    }

    // Setup QUIC modules from vendored library
    const quic_modules = quic_vendor_setup.setupModules(b, "../../vendor/quic", target, optimize);
    test_exe.root_module.addImport("vendor_quic", quic_modules.quic_api);

    b.installArtifact(test_exe);

    // Run command
    const run_test = b.addRunArtifact(test_exe);
    run_test.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the test");
    run_step.dependOn(&run_test.step);
}
