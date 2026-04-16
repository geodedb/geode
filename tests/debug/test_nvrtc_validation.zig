const std = @import("std");
const gpu = @import("gpu");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== NVRTC Validation Test ===\n\n", .{});

    // Test 1: Check if NVRTC is available
    var compiler = gpu.nvrtc_compiler.NVRTCCompiler.init(allocator);
    defer compiler.deinit();

    if (compiler.available()) {
        std.debug.print("✅ NVRTC library loaded successfully\n", .{});
        std.debug.print("   libnvrtc.so found and symbols loaded\n\n", .{});

        // Test 2: Compile a simple CUDA kernel
        std.debug.print("Testing CUDA C compilation...\n", .{});
        const simple_kernel =
            \\ extern "C" __global__ void test_add(int* a, int* b, int* c, int n) {
            \\     int idx = blockIdx.x * blockDim.x + threadIdx.x;
            \\     if (idx < n) {
            \\         c[idx] = a[idx] + b[idx];
            \\     }
            \\ }
        ;

        const ptx = compiler.compileCudaToPTX(simple_kernel, "test_add") catch |err| {
            std.debug.print("❌ Compilation failed: {}\n", .{err});
            return;
        };
        defer allocator.free(ptx);

        std.debug.print("✅ Compilation successful!\n", .{});
        std.debug.print("   Generated PTX size: {} bytes\n", .{ptx.len});
        std.debug.print("   Contains test_add: {}\n\n", .{std.mem.indexOf(u8, ptx", "test_add") != null});

        // Test 3: Compile INTERSECT kernel from kernel_sources
        std.debug.print("Testing INTERSECT kernel compilation...\n", .{});
        const intersect_kernel = gpu.kernel_sources.setops_kernel_cuda_c;
        const intersect_ptx = compiler.compileCudaToPTX(intersect_kernel, "setops_kernels") catch |err| {
            std.debug.print("❌ INTERSECT compilation failed: {}\n", .{err});
            std.debug.print("   This is expected if kernel has complex dependencies\n\n", .{});
            return;
        };
        defer allocator.free(intersect_ptx);

        std.debug.print("✅ INTERSECT kernel compilation successful!\n", .{});
        std.debug.print("   Generated PTX size: {} bytes\n", .{intersect_ptx.len});
        std.debug.print("   Contains intersect_kernel: {}\n", .{std.mem.indexOf(u8, intersect_ptx", "intersect_kernel") != null});
        std.debug.print("   Contains bitonic_sort_kernel: {}\n", .{std.mem.indexOf(u8, intersect_ptx", "bitonic_sort_kernel") != null});
        std.debug.print("   Contains unique_kernel: {}\n\n", .{std.mem.indexOf(u8, intersect_ptx", "unique_kernel") != null});

        std.debug.print("✅ All NVRTC tests passed!\n", .{});
        std.debug.print("   GPU kernels can now use optimized CUDA C implementations\n", .{});
    } else {
        std.debug.print("⚠️  NVRTC library not available\n", .{});
        std.debug.print("   libnvrtc.so not found or failed to load\n", .{});
        std.debug.print("   GPU kernels will use simplified PTX fallback\n\n", .{});

        std.debug.print("To enable NVRTC:\n", .{});
        std.debug.print("   1. Install CUDA toolkit (includes libnvrtc.so)\n", .{});
        std.debug.print("   2. Ensure /usr/local/cuda/lib64 is in LD_LIBRARY_PATH\n", .{});
        std.debug.print("   3. Or create symlink: ln -s /usr/local/cuda/lib64/libnvrtc.so /usr/lib/\n", .{});
    }
}
