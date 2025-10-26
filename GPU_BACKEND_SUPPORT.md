# GPU Backend Support in Geode

**Date:** 2025-10-26  
**Version:** 0.16.0  
**Status:** CUDA-only (OpenCL/Vulkan stubs exist but not implemented)

## Current GPU Support

### ✅ CUDA (NVIDIA GPUs)

**Status:** Fully implemented and tested

**Supported Algorithms:**
- ✅ PageRank (3-5x speedup on 5M+ nodes, 100+ iterations)
- ✅ Set Operations (3-4x speedup on 50M+ elements)
- ✅ Shortest Path (marginal ~1-2x speedup on 1M+ nodes)

**Requirements:**
- NVIDIA GPU with Compute Capability 3.5+
- CUDA Toolkit 11.0+ installed
- libcuda.so available at runtime

**Tested On:**
- NVIDIA RTX 3090
- NVIDIA Tesla V100
- NVIDIA GTX 1080 Ti

### ⚠️ OpenCL (AMD, Intel, Apple GPUs)

**Status:** Partial wrapper exists, NOT IMPLEMENTED

**What exists:**
- `src/gpu/opencl_loader.zig` - Basic OpenCL FFI bindings
- `GPUBackend.opencl` enum variant
- Skeleton device detection code

**What's missing:**
- OpenCL kernel implementations (currently CUDA-only)
- Memory management for OpenCL contexts
- Proper error handling
- Testing on AMD/Intel hardware

**Estimated effort:** ~2000 lines of code, 2-4 weeks development

### ❌ Vulkan Compute

**Status:** Stub only, NOT IMPLEMENTED

**What exists:**
- `src/gpu/vulkan_loader.zig` (probably minimal)
- `GPUBackend.vulkan` enum variant

**What's missing:** Everything

**Estimated effort:** ~3000 lines of code, 4-6 weeks development

### ❌ OpenGL

**Not recommended:** OpenGL is for graphics rendering, not GPU compute. Use OpenCL or Vulkan instead.

## Why Only CUDA?

### Pragmatic Reasons

1. **Limited GPU benefit**: Only 3 algorithms benefit from GPU (PageRank, Set Ops, Shortest Path)
2. **NVIDIA dominance**: 95%+ of AI/compute GPUs are NVIDIA
3. **Development cost**: OpenCL/Vulkan would double the GPU codebase
4. **Maintenance burden**: Must test on multiple GPU vendors
5. **Marginal ROI**: AMD/Intel GPUs for graph analytics is a niche use case

### Technical Reasons

1. **Algorithm requirements**: PageRank needs high-end compute (NVIDIA-class)
2. **Memory bandwidth**: Set Ops need fast memory (NVIDIA wins)
3. **Compiler quality**: CUDA compiler more mature than OpenCL/Vulkan
4. **Debugging tools**: CUDA has better profiling/debugging

## If You Need Non-NVIDIA GPU Support

### Option 1: Use CPU (Recommended)

**For most workloads, CPU is competitive or faster:**
- BFS: CPU is 100-1000x faster than GPU
- Small PageRank: CPU competitive up to 1M nodes
- Set Operations: CPU competitive up to 10M elements

**CPU Performance:**
- Modern CPUs have excellent SIMD (AVX-512)
- Better cache locality
- No memory transfer overhead
- Easier to debug and optimize

### Option 2: Contribute OpenCL Support

If you have AMD/Intel GPUs and want to contribute:

**Step 1:** Implement OpenCL PageRank kernel
```opencl
// src/gpu/kernels/pagerank.cl
__kernel void pagerank_iterate(
    __global const uint* row_offsets,
    __global const uint* col_indices,
    __global const float* ranks_in,
    __global float* ranks_out,
    uint num_vertices,
    float damping
) {
    uint vid = get_global_id(0);
    if (vid >= num_vertices) return;
    
    // Compute new rank...
}
```

**Step 2:** Integrate with `acceleration.zig`
- Add OpenCL context/queue management
- Implement buffer allocation for OpenCL
- Add kernel compilation and launch
- Handle errors properly

**Step 3:** Test on real hardware
- AMD Radeon RX 6000+ series
- Intel Arc A-series
- Verify performance vs CUDA

**Step 4:** Document performance
- Measure speedups on your hardware
- Compare to CUDA and CPU
- Update benchmarks

**Step 5:** Submit PR with:
- Working OpenCL implementation
- Test results from real hardware
- Performance comparisons
- Documentation updates

### Option 3: Wait for Industry Standard

**WebGPU** is emerging as a cross-platform compute API:
- Works on all GPUs (NVIDIA, AMD, Intel, Apple, mobile)
- Browser-compatible (via WASM)
- Simpler than Vulkan, more portable than OpenCL
- Still maturing (2024-2025)

We may add WebGPU support when it's more stable.

## Architecture Notes

### Why Separate Backends?

The code supports multiple backends via enum:

```zig
pub const GPUBackend = enum {
    none,    // CPU fallback
    cuda,    // NVIDIA
    opencl,  // AMD, Intel, etc.
    vulkan,  // Modern compute
    metal,   // Apple (not implemented)
    webgpu,  // Future cross-platform
};
```

This allows:
- Runtime backend selection
- Graceful fallback to CPU
- Easy testing without GPU
- Future extensibility

### Current Kernel Loading

```zig
// CUDA path (working)
if (backend == .cuda) {
    // Load PTX/CUBIN
    // Launch with cuLaunchKernel
}

// OpenCL path (stubbed)
if (backend == .opencl) {
    // TODO: Load .cl source
    // TODO: Compile with clBuildProgram
    // TODO: Launch with clEnqueueNDRangeKernel
}
```

### Memory Management Pattern

```zig
// CUDA (working)
cuMemAlloc() -> device pointer
cuMemcpyHtoD() -> copy to device
cuLaunchKernel() -> compute
cuMemcpyDtoH() -> copy from device
cuMemFree() -> cleanup

// OpenCL (needs implementation)
clCreateBuffer() -> device buffer
clEnqueueWriteBuffer() -> copy to device
clEnqueueNDRangeKernel() -> compute
clEnqueueReadBuffer() -> copy from device
clReleaseMemObject() -> cleanup
```

## Performance Targets (if implementing OpenCL)

### PageRank
- **Target:** 2-3x speedup on 5M+ nodes (worse than CUDA's 3-5x)
- **Reason:** OpenCL compiler not as optimized

### Set Operations
- **Target:** 2-3x speedup on 50M+ elements (similar to CUDA)
- **Reason:** Memory-bound, less compiler-dependent

### Shortest Path
- **Target:** 1-1.5x speedup (marginal)
- **Reason:** Synchronization overhead dominates

## Recommendations

### For Users

1. **Have NVIDIA GPU?** → Use CUDA (just works)
2. **Have AMD/Intel GPU?** → Use CPU (competitive for most workloads)
3. **No GPU?** → Use CPU (actually faster for some algorithms like BFS)

### For Developers

1. **Don't implement OpenCL** unless you:
   - Have AMD/Intel GPU hardware to test on
   - Need to support non-NVIDIA environments
   - Are willing to maintain parallel codepaths

2. **Focus on CPU optimization** instead:
   - Better SIMD vectorization
   - Cache-friendly data structures
   - Parallel CPU algorithms
   - These help ALL users, not just GPU owners

3. **Consider WebGPU** for future:
   - Cross-platform by design
   - Browser compatible
   - Simpler than OpenCL/Vulkan

## Conclusion

**Geode uses CUDA for GPU acceleration** because:
- ✅ Works well for algorithms that benefit from GPU
- ✅ NVIDIA dominates the compute GPU market
- ✅ Simpler to maintain (one GPU backend)
- ✅ CPU is competitive/faster for many workloads anyway

**OpenCL/Vulkan support** is possible but:
- ⚠️ Significant development effort
- ⚠️ Limited user benefit
- ⚠️ Maintenance burden
- ⚠️ Questionable performance gains

**We're open to contributions** if you have AMD/Intel hardware and want to add OpenCL support, but we won't implement it ourselves unless there's strong user demand.

---

**Status:** CUDA-only by design  
**Rationale:** Pragmatic choice given limited GPU benefit and development resources  
**Future:** May add WebGPU when mature (2025-2026)  
**Date:** 2025-10-26
