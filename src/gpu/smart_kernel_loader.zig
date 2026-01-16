const std = @import("std");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;
const ModuleLoader = @import("module_loader.zig").ModuleLoader;
const NVRTCCompiler = @import("nvrtc_compiler.zig").NVRTCCompiler;
const kernel_sources = @import("kernel_sources.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=SmartKernelLoader; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_051_SmartKernelLoader; OWNER=engine; UPDATED=2025-10-26

/// SmartKernelLoader tries to compile CUDA C to PTX using NVRTC,
/// and falls back to simplified PTX if NVRTC is unavailable.
pub const SmartKernelLoader = struct {
    loader: *const CudaLoader,
    mod_loader: ModuleLoader,
    nvrtc_compiler: ?NVRTCCompiler,
    allocator: std.mem.Allocator,
    ptx_cache: std.StringHashMap([]u8),

    pub fn init(loader: *const CudaLoader, allocator: std.mem.Allocator) !SmartKernelLoader {
        const mod_loader = try ModuleLoader.init(loader);
        const nvrtc_compiler = NVRTCCompiler.init(allocator);

        return SmartKernelLoader{
            .loader = loader,
            .mod_loader = mod_loader,
            .nvrtc_compiler = if (nvrtc_compiler.available()) nvrtc_compiler else null,
            .allocator = allocator,
            .ptx_cache = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *SmartKernelLoader) void {
        // Free cached PTX
        var it = self.ptx_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.ptx_cache.deinit();

        if (self.nvrtc_compiler) |*compiler| {
            compiler.deinit();
        }
        self.mod_loader.deinit();
    }

    /// Load kernel module with smart fallback: try NVRTC first, then simplified PTX
    pub fn loadKernelModule(self: *SmartKernelLoader, kernel_type: KernelType) !void {
        // Try NVRTC compilation first
        if (self.nvrtc_compiler) |*compiler| {
            const cuda_source = switch (kernel_type) {
                .bfs => kernel_sources.bfs_kernel_cuda_c,
                .pagerank => kernel_sources.pagerank_kernel_cuda_c,
                .setops => kernel_sources.setops_kernel_cuda_c,
                .shortest_path => kernel_sources.shortest_path_kernel_cuda_c,
            };

            const kernel_name = switch (kernel_type) {
                .bfs => "bfs_kernels",
                .pagerank => "pagerank_kernels",
                .setops => "setops_kernels",
                .shortest_path => "shortest_path_kernels",
            };

            // Check cache first
            if (self.ptx_cache.get(kernel_name)) |cached_ptx| {
                try self.mod_loader.loadPTX(cached_ptx);
                return;
            }

            // Try to compile
            if (compiler.compileCudaToPTX(cuda_source, kernel_name)) |ptx| {
                // Cache the compiled PTX
                try self.ptx_cache.put(kernel_name, ptx);
                try self.mod_loader.loadPTX(ptx);
                std.debug.print("[SmartKernelLoader] Compiled CUDA C to PTX for {s}\n", .{kernel_name});
                return;
            } else |_| {
                std.debug.print("[SmartKernelLoader] NVRTC compilation failed for {s}, falling back to simplified PTX\n", .{kernel_name});
            }
        }

        // Fall back to simplified PTX
        const ptx_source = switch (kernel_type) {
            .bfs => kernel_sources.bfs_kernel_ptx,
            .pagerank => kernel_sources.pagerank_kernel_ptx,
            .setops => kernel_sources.setops_kernel_ptx,
            .shortest_path => kernel_sources.shortest_path_kernel_ptx,
        };

        try self.mod_loader.loadPTX(ptx_source);
        std.debug.print("[SmartKernelLoader] Using simplified PTX fallback for kernel type {}\n", .{kernel_type});
    }

    pub fn getFunction(self: *SmartKernelLoader, name: [:0]const u8) !*anyopaque {
        return self.mod_loader.getFunction(name);
    }

    pub fn launchKernel(
        self: *SmartKernelLoader,
        func: *anyopaque,
        grid_dim: [3]u32,
        block_dim: [3]u32,
        shared_mem: u32,
        params: *anyopaque,
    ) !void {
        return self.mod_loader.launchKernel(func, grid_dim, block_dim, shared_mem, params);
    }

    // Convenience methods for loading specific kernel types
    pub fn loadBFSKernels(self: *SmartKernelLoader) !void {
        return self.loadKernelModule(.bfs);
    }

    pub fn loadPageRankKernels(self: *SmartKernelLoader) !void {
        return self.loadKernelModule(.pagerank);
    }

    pub fn loadSetOpsKernels(self: *SmartKernelLoader) !void {
        return self.loadKernelModule(.setops);
    }

    pub fn loadShortestPathKernels(self: *SmartKernelLoader) !void {
        return self.loadKernelModule(.shortest_path);
    }
};

pub const KernelType = enum {
    bfs,
    pagerank,
    setops,
    shortest_path,
};

test "TestCANARY_REQ_GQL_051_SmartKernelLoaderInit" {
    const loader = CudaLoader.init();
    if (!loader.available()) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var smart_loader = try SmartKernelLoader.init(&loader, allocator);
    defer smart_loader.deinit();
}
