//! Device Information Example
//!
//! Demonstrates how to probe for CUDA devices and display their capabilities.
//! This example works even on systems without CUDA - it will show why
//! CUDA is unavailable.

const std = @import("std");
const cuda = @import("cuda");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("================================================================================\n", .{});
    std.debug.print("                        CUDA Device Information\n", .{});
    std.debug.print("================================================================================\n\n", .{});

    // Probe for CUDA
    var result = try cuda.probe(allocator);
    defer result.deinit(allocator);

    // Show diagnostics
    std.debug.print("Probe Diagnostics:\n", .{});
    std.debug.print("  Platform Supported: {}\n", .{result.diagnostics.platform_supported});
    std.debug.print("  Library Found: {}\n", .{result.diagnostics.library_found});
    std.debug.print("  Driver Initialized: {}\n", .{result.diagnostics.driver_initialized});
    std.debug.print("  Kernel Module Detected: {}\n", .{result.diagnostics.kernel_module_detected});
    std.debug.print("  Devices Enumerated: {}\n", .{result.diagnostics.devices_enumerated});
    std.debug.print("  Probe Time: {} us\n", .{result.diagnostics.probe_time_us});
    std.debug.print("\n", .{});

    if (!result.available) {
        std.debug.print("CUDA Not Available\n", .{});
        std.debug.print("  Reason: {s}\n", .{@tagName(result.unavailable_reason)});
        std.debug.print("  Details: {s}\n", .{result.getErrorMessage()});
        std.debug.print("\n", .{});
        std.debug.print("Possible solutions:\n", .{});
        std.debug.print("  - Ensure NVIDIA drivers are installed\n", .{});
        std.debug.print("  - Load the NVIDIA kernel module: sudo modprobe nvidia\n", .{});
        std.debug.print("  - Check if you have a CUDA-capable GPU\n", .{});
        std.debug.print("  - Verify CUDA toolkit installation\n", .{});
        return;
    }

    // Show driver version
    std.debug.print("CUDA Driver Version: {}.{}\n", .{
        @divTrunc(result.driver_version, 1000),
        @divTrunc(@mod(result.driver_version, 1000), 10),
    });
    std.debug.print("Devices Found: {}\n\n", .{result.device_count});

    // Show each device
    for (result.devices, 0..) |dev, i| {
        if (!dev.available) continue;

        std.debug.print("Device {}: {s}\n", .{ i, dev.getName() });
        std.debug.print("--------------------------------------------------------------------------------\n", .{});
        std.debug.print("  Architecture: {s} (SM {}.{})\n", .{
            dev.getArchName(),
            dev.arch.major,
            dev.arch.minor,
        });
        std.debug.print("  Compute Capability: {s}\n", .{dev.arch.computeString()});
        std.debug.print("\n", .{});

        std.debug.print("  Memory:\n", .{});
        std.debug.print("    Total: {d:.2} GB\n", .{
            @as(f64, @floatFromInt(dev.total_memory)) / (1024 * 1024 * 1024),
        });
        std.debug.print("    L2 Cache: {} KB\n", .{dev.l2_cache_size / 1024});
        std.debug.print("    Bus Width: {} bits\n", .{dev.memory_bus_width});
        std.debug.print("    Theoretical Bandwidth: {d:.1} GB/s\n", .{dev.theoreticalBandwidthGBps()});
        std.debug.print("\n", .{});

        std.debug.print("  Compute:\n", .{});
        std.debug.print("    Streaming Multiprocessors: {}\n", .{dev.sm_count});
        std.debug.print("    Max Threads/Block: {}\n", .{dev.max_threads_per_block});
        std.debug.print("    Max Shared Memory/Block: {} KB\n", .{dev.max_shared_memory / 1024});
        std.debug.print("    Warp Size: {}\n", .{dev.warp_size});
        std.debug.print("    Clock Rate: {} MHz\n", .{dev.clock_rate_khz / 1000});
        std.debug.print("\n", .{});

        std.debug.print("  Features:\n", .{});
        std.debug.print("    ECC Enabled: {}\n", .{dev.ecc_enabled});
        std.debug.print("    Integrated: {}\n", .{dev.integrated});
        std.debug.print("    Concurrent Kernels: {}\n", .{dev.concurrent_kernels});
        std.debug.print("    Unified Memory: {}\n", .{dev.arch.supportsUnifiedMemory()});
        std.debug.print("    Dynamic Parallelism: {}\n", .{dev.arch.supportsDynamicParallelism()});
        std.debug.print("    Tensor Cores: {}\n", .{dev.arch.supportsTensorCores()});
        std.debug.print("    Async Copy: {}\n", .{dev.arch.supportsAsyncCopy()});
        std.debug.print("    Blackwell Features: {}\n", .{dev.arch.supportsBlackwellFeatures()});
        std.debug.print("\n", .{});
    }

    // Show best device
    if (result.getBestDevice()) |best| {
        std.debug.print("Best Device: Device {} ({s})\n", .{ best.id, best.getName() });
    }

    std.debug.print("================================================================================\n", .{});
}
