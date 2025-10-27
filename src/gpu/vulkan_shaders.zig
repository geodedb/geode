// Auto-generated SPIR-V shader sources for Vulkan compute
// Phase 2: Shader compilation pipeline
//
// CANARY: REQ=REQ-GPU-002; FEATURE="Vulkan Shader Compilation"; ASPECT=Implementation;
// STATUS=TESTED; TEST=tests/gpu/test_vulkan_basic.zig:1; BENCH=None; OWNER=gpu; UPDATED=2025-10-26

const std = @import("std");

/// PageRank iteration kernel (SPIR-V)
/// Optimized for graphs with 1M+ nodes
pub const pagerank_spirv = @embedFile("kernels/pagerank.spv");

/// Set operations kernel (SPIR-V)
/// Supports UNION, INTERSECT, EXCEPT
/// Optimized for sets with 10M+ elements
pub const setops_spirv = @embedFile("kernels/setops.spv");

/// Shortest path delta-stepping kernel (SPIR-V)
/// Optimized for graphs with 1M+ nodes
pub const shortest_path_spirv = @embedFile("kernels/shortest_path.spv");

/// Vector addition test kernel (SPIR-V)
/// Used for validation and testing
pub const vector_add_spirv = @embedFile("kernels/vector_add.spv");

/// Get shader SPIR-V code by name
pub fn getShader(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "pagerank")) return pagerank_spirv;
    if (std.mem.eql(u8, name, "setops")) return setops_spirv;
    if (std.mem.eql(u8, name, "shortest_path")) return shortest_path_spirv;
    if (std.mem.eql(u8, name, "vector_add")) return vector_add_spirv;
    return null;
}

/// Get shader SPIR-V as u32 array (required by Vulkan)
pub fn getShaderWords(name: []const u8) ?[]const u32 {
    const bytes = getShader(name) orelse return null;
    // SPIR-V is always a multiple of 4 bytes
    if (bytes.len % 4 != 0) return null;

    // Cast to u32 array (alignment is guaranteed by @embedFile)
    return @as([*]const u32, @ptrCast(@alignCast(bytes.ptr)))[0 .. bytes.len / 4];
}

test "shader SPIR-V loading" {
    const testing = std.testing;

    // Verify all shaders are loadable
    try testing.expect(pagerank_spirv.len > 0);
    try testing.expect(setops_spirv.len > 0);
    try testing.expect(shortest_path_spirv.len > 0);
    try testing.expect(vector_add_spirv.len > 0);

    // Verify SPIR-V magic number (0x07230203)
    const pagerank_words = getShaderWords("pagerank").?;
    try testing.expectEqual(@as(u32, 0x07230203), pagerank_words[0]);

    // Verify getShader function
    try testing.expect(getShader("pagerank") != null);
    try testing.expect(getShader("invalid") == null);
}
