// GPU Acceleration Module - Unified Interface
// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=UnifiedModule; STATUS=EXEMPT; OWNER=engine; UPDATED=2025-10-26

pub const phase0 = @import("gpu/phase0.zig");
pub const phase1_kernels = @import("gpu/phase1_kernels.zig");
pub const pagerank_kernels = @import("gpu/pagerank_kernels.zig");
pub const gpu_setops_kernels = @import("gpu/gpu_setops_kernels.zig");
pub const shortest_path_kernels = @import("gpu/shortest_path_kernels.zig");
pub const telemetry = @import("gpu/telemetry.zig");
pub const cuda_loader = @import("gpu/cuda_loader.zig");
pub const memory_manager = @import("gpu/memory_manager.zig");
pub const module_loader = @import("gpu/module_loader.zig");
pub const kernel_sources = @import("gpu/kernel_sources.zig");
pub const performance_profiler = @import("gpu/performance_profiler.zig");
pub const nvrtc_compiler = @import("gpu/nvrtc_compiler.zig");
pub const smart_kernel_loader = @import("gpu/smart_kernel_loader.zig");
