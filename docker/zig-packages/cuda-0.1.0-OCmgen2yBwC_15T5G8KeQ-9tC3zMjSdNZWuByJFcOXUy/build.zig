// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Build Options
    // ========================================================================

    const feature_runtime_api = b.option(bool, "feature_runtime_api", "Enable CUDA Runtime API support (requires libcudart)") orelse false;

    _ = feature_runtime_api; // Reserved for future Runtime API support

    // ========================================================================
    // Target Info
    // ========================================================================

    const target_info = target.result;
    const is_linux = target_info.os.tag == .linux;

    // ========================================================================
    // Define CUDA Modules
    // ========================================================================
    //
    // Module organization:
    // - types: Core type definitions, constants, errors
    // - driver: Low-level CUDA driver API (libcuda.so)
    // - probe: Device detection and availability
    // - memory: GPU memory management
    // - stream: CUDA streams and events
    // - module: PTX/CUBIN loading and kernel management
    // - context: High-level compute API
    // - profiler: Performance profiling and benchmarking

    // Core type definitions and constants
    const types_mod = b.addModule("types", .{
        .root_source_file = b.path("src/cuda/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CUDA driver API dynamic loader
    const driver_mod = b.addModule("driver", .{
        .root_source_file = b.path("src/cuda/driver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    // Device probing and detection
    const probe_mod = b.addModule("probe", .{
        .root_source_file = b.path("src/cuda/probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "driver", .module = driver_mod },
        },
    });

    // GPU memory management
    const memory_mod = b.addModule("memory", .{
        .root_source_file = b.path("src/cuda/memory.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "driver", .module = driver_mod },
        },
    });

    // Stream and event management
    const stream_mod = b.addModule("stream", .{
        .root_source_file = b.path("src/cuda/stream.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "driver", .module = driver_mod },
        },
    });

    // Module and kernel management
    const module_mod = b.addModule("module", .{
        .root_source_file = b.path("src/cuda/module.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "driver", .module = driver_mod },
            .{ .name = "stream", .module = stream_mod },
        },
    });

    // Performance profiling
    const profiler_mod = b.addModule("profiler", .{
        .root_source_file = b.path("src/cuda/profiler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "driver", .module = driver_mod },
            .{ .name = "stream", .module = stream_mod },
        },
    });

    // High-level context API
    const context_mod = b.addModule("context", .{
        .root_source_file = b.path("src/cuda/context.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "driver", .module = driver_mod },
            .{ .name = "probe", .module = probe_mod },
            .{ .name = "memory", .module = memory_mod },
            .{ .name = "stream", .module = stream_mod },
            .{ .name = "module", .module = module_mod },
        },
    });

    // ========================================================================
    // Main Library Module
    // ========================================================================

    const cuda_mod = b.addModule("cuda", .{
        .root_source_file = b.path("src/cuda.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cuda/types", .module = types_mod },
            .{ .name = "cuda/driver", .module = driver_mod },
            .{ .name = "cuda/probe", .module = probe_mod },
            .{ .name = "cuda/memory", .module = memory_mod },
            .{ .name = "cuda/stream", .module = stream_mod },
            .{ .name = "cuda/module", .module = module_mod },
            .{ .name = "cuda/profiler", .module = profiler_mod },
            .{ .name = "cuda/context", .module = context_mod },
        },
    });

    // Link with system libraries on Linux
    if (is_linux) {
        cuda_mod.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }

    // ========================================================================
    // Unit Tests
    // ========================================================================

    // Create main test step
    const test_step = b.step("test", "Run all unit tests");

    // Types module tests
    const types_test_step = b.step("test-types", "Run types module tests");
    const types_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cuda/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const types_test_run = b.addRunArtifact(types_tests);
    types_test_step.dependOn(&types_test_run.step);
    test_step.dependOn(types_test_step);

    // Driver module tests
    const driver_test_step = b.step("test-driver", "Run driver module tests");
    const driver_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cuda/driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
            },
        }),
    });
    if (is_linux) {
        driver_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const driver_test_run = b.addRunArtifact(driver_tests);
    driver_test_step.dependOn(&driver_test_run.step);
    test_step.dependOn(driver_test_step);

    // Probe module tests
    const probe_test_step = b.step("test-probe", "Run probe module tests");
    const probe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cuda/probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "driver", .module = driver_mod },
            },
        }),
    });
    if (is_linux) {
        probe_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const probe_test_run = b.addRunArtifact(probe_tests);
    probe_test_step.dependOn(&probe_test_run.step);
    test_step.dependOn(probe_test_step);

    // Memory module tests
    const memory_test_step = b.step("test-memory", "Run memory module tests");
    const memory_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cuda/memory.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "driver", .module = driver_mod },
            },
        }),
    });
    if (is_linux) {
        memory_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const memory_test_run = b.addRunArtifact(memory_tests);
    memory_test_step.dependOn(&memory_test_run.step);
    test_step.dependOn(memory_test_step);

    // Stream module tests
    const stream_test_step = b.step("test-stream", "Run stream module tests");
    const stream_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cuda/stream.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "driver", .module = driver_mod },
            },
        }),
    });
    if (is_linux) {
        stream_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const stream_test_run = b.addRunArtifact(stream_tests);
    stream_test_step.dependOn(&stream_test_run.step);
    test_step.dependOn(stream_test_step);

    // Module tests
    const module_test_step = b.step("test-module", "Run module loading tests");
    const module_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cuda/module.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "driver", .module = driver_mod },
                .{ .name = "stream", .module = stream_mod },
            },
        }),
    });
    if (is_linux) {
        module_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const module_test_run = b.addRunArtifact(module_tests);
    module_test_step.dependOn(&module_test_run.step);
    test_step.dependOn(module_test_step);

    // Profiler module tests
    const profiler_test_step = b.step("test-profiler", "Run profiler module tests");
    const profiler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cuda/profiler.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "driver", .module = driver_mod },
                .{ .name = "stream", .module = stream_mod },
            },
        }),
    });
    const profiler_test_run = b.addRunArtifact(profiler_tests);
    profiler_test_step.dependOn(&profiler_test_run.step);
    test_step.dependOn(profiler_test_step);

    // Context module tests
    const context_test_step = b.step("test-context", "Run context module tests");
    const context_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cuda/context.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "driver", .module = driver_mod },
                .{ .name = "probe", .module = probe_mod },
                .{ .name = "memory", .module = memory_mod },
                .{ .name = "stream", .module = stream_mod },
                .{ .name = "module", .module = module_mod },
            },
        }),
    });
    if (is_linux) {
        context_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const context_test_run = b.addRunArtifact(context_tests);
    context_test_step.dependOn(&context_test_run.step);
    test_step.dependOn(context_test_step);

    // Main library tests
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cuda.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cuda/types", .module = types_mod },
                .{ .name = "cuda/driver", .module = driver_mod },
                .{ .name = "cuda/probe", .module = probe_mod },
                .{ .name = "cuda/memory", .module = memory_mod },
                .{ .name = "cuda/stream", .module = stream_mod },
                .{ .name = "cuda/module", .module = module_mod },
                .{ .name = "cuda/profiler", .module = profiler_mod },
                .{ .name = "cuda/context", .module = context_mod },
            },
        }),
    });
    if (is_linux) {
        lib_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const lib_test_run = b.addRunArtifact(lib_tests);
    test_step.dependOn(&lib_test_run.step);

    // ========================================================================
    // Integration Tests (GPU Optional)
    // ========================================================================

    const integration_test_step = b.step("test-integration", "Run integration tests (requires GPU)");

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cuda", .module = cuda_mod },
            },
        }),
    });
    if (is_linux) {
        integration_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const integration_test_run = b.addRunArtifact(integration_tests);
    integration_test_step.dependOn(&integration_test_run.step);

    // Extended integration tests
    const extended_integration_test_step = b.step("test-integration-extended", "Run extended integration tests (requires GPU)");

    const extended_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_extended.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cuda", .module = cuda_mod },
            },
        }),
    });
    if (is_linux) {
        extended_integration_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const extended_integration_test_run = b.addRunArtifact(extended_integration_tests);
    extended_integration_test_step.dependOn(&extended_integration_test_run.step);

    // Combined integration test step
    const test_all_integration_step = b.step("test-integration-all", "Run all integration tests (basic + extended)");
    test_all_integration_step.dependOn(integration_test_step);
    test_all_integration_step.dependOn(extended_integration_test_step);

    // ========================================================================
    // Edge Case Tests
    // ========================================================================

    const edge_case_test_step = b.step("test-edge-cases", "Run edge case and boundary tests");

    const edge_case_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/edge_cases.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cuda", .module = cuda_mod },
            },
        }),
    });
    if (is_linux) {
        edge_case_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const edge_case_test_run = b.addRunArtifact(edge_case_tests);
    edge_case_test_step.dependOn(&edge_case_test_run.step);
    test_step.dependOn(edge_case_test_step);

    // ========================================================================
    // Error Recovery Tests
    // ========================================================================

    const error_recovery_test_step = b.step("test-error-recovery", "Run error recovery tests");

    const error_recovery_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/error_recovery.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cuda", .module = cuda_mod },
            },
        }),
    });
    if (is_linux) {
        error_recovery_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const error_recovery_test_run = b.addRunArtifact(error_recovery_tests);
    error_recovery_test_step.dependOn(&error_recovery_test_run.step);
    test_step.dependOn(error_recovery_test_step);

    // ========================================================================
    // Performance Regression Tests
    // ========================================================================

    const perf_regression_test_step = b.step("test-perf-regression", "Run performance regression tests");

    const perf_regression_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/perf_regression.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Use release for accurate perf measurements
            .imports = &.{
                .{ .name = "cuda", .module = cuda_mod },
            },
        }),
    });
    if (is_linux) {
        perf_regression_tests.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    const perf_regression_test_run = b.addRunArtifact(perf_regression_tests);
    perf_regression_test_step.dependOn(&perf_regression_test_run.step);

    // ========================================================================
    // Benchmarks
    // ========================================================================

    const benchmarks_step = b.step("benchmarks", "Build benchmarks");

    const bench_exe = b.addExecutable(.{
        .name = "cuda_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "cuda", .module = cuda_mod },
            },
        }),
    });
    if (is_linux) {
        bench_exe.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    b.installArtifact(bench_exe);
    benchmarks_step.dependOn(&bench_exe.step);

    const bench_run_step = b.step("bench", "Run benchmarks");
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run_step.dependOn(&bench_run.step);

    // ========================================================================
    // Examples
    // ========================================================================

    const examples_step = b.step("examples", "Build all examples");

    // Device info example
    const device_info_exe = b.addExecutable(.{
        .name = "device_info",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/device_info.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cuda", .module = cuda_mod },
            },
        }),
    });
    if (is_linux) {
        device_info_exe.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    b.installArtifact(device_info_exe);
    examples_step.dependOn(&device_info_exe.step);

    // Vector add example
    const vector_add_exe = b.addExecutable(.{
        .name = "vector_add",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/vector_add.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cuda", .module = cuda_mod },
            },
        }),
    });
    if (is_linux) {
        vector_add_exe.root_module.linkSystemLibrary("dl", .{ .preferred_link_mode = .dynamic });
    }
    b.installArtifact(vector_add_exe);
    examples_step.dependOn(&vector_add_exe.step);

    // ========================================================================
    // Formatting
    // ========================================================================

    const fmt_step = b.step("fmt", "Format source code");
    const fmt = b.addFmt(.{
        .paths = &.{
            "src",
            "tests",
            "benchmarks",
            "examples",
            "build.zig",
        },
    });
    fmt_step.dependOn(&fmt.step);

    const fmt_check_step = b.step("fmt-check", "Check source code formatting");
    const fmt_check = b.addFmt(.{
        .paths = &.{
            "src",
            "tests",
            "benchmarks",
            "examples",
            "build.zig",
        },
        .check = true,
    });
    fmt_check_step.dependOn(&fmt_check.step);

    // ========================================================================
    // Documentation
    // ========================================================================

    // Documentation can be generated using:
    // zig build-lib src/cuda.zig -femit-docs
    // or by running: zig doc src/cuda.zig
    _ = b.step("docs", "Generate documentation (use: zig doc src/cuda.zig)");

    // ========================================================================
    // Clean
    // ========================================================================

    const clean_step = b.step("clean", "Remove build artifacts");
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
    clean_step.dependOn(&b.addRemoveDirTree(b.path(".zig-cache")).step);
}
