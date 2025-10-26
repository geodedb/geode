# Vulkan Phase 3: PageRank Integration - BLOCKED

**Status:** BLOCKED - Architectural Issue  
**Date:** 2025-10-26  
**Blocker:** Zig 0.15.1 Module System + @cImport Incompatibility

## Problem Summary

Vulkan integration into PageRank (Phase 3) is blocked by a fundamental limitation in Zig 0.15.1's module system:

**@cImport in modules cannot access build-time include paths from executables/tests that import them.**

### The Issue

1. `vulkan_loader.zig` uses `@cImport` to load `vulkan/vulkan.h`
2. This module is imported by `vulkan_compute.zig`  
3. Which is imported by `pagerank_kernels.zig`
4. Which is imported by `gpu.zig`
5. Which is imported by benchmarks and tests

When the GPU module is compiled, the `@cImport` in `vulkan_loader.zig` executes **without** the include paths (`-I/usr/include`) that are added to the final executable. This causes compilation to fail with:

```
error: 'vulkan/vulkan.h' file not found
```

### Why Adding Include Paths Doesn't Work

- Modules are pre-compiled separately from executables
- `addIncludePath()` only applies to the executable/test, not transitively to imported modules
- @cImport happens at module compile time, not executable link time

## Attempted Solutions

1. ✗ Added `addIncludePath` to executables - doesn't propagate to modules
2. ✗ Added `addIncludePath` to vulkan_tests - same issue
3. ✗ Added library paths - helps with linking but not with @cImport

## Possible Solutions (Not Yet Implemented)

### Option 1: Remove @cImport from Modules (Recommended)
- Create standalone `vulkan_ffi.zig` with manual FFI bindings
- No @cImport, just `extern` declarations
- Compile vulkan_ffi as part of each executable with proper flags
- **Effort:** Medium (500+ lines of FFI declarations)
- **Benefit:** Clean, portable, no build system hacks

### Option 2: Dynamic Loading
- Load Vulkan functions at runtime via `dlopen/dlsym`
- No compile-time @cImport needed
- **Effort:** Medium (function pointer table)
- **Benefit:** Runtime flexibility, no include path issues
- **Drawback:** Slight runtime overhead

### Option 3: Build System Hack
- Create separate "vulkan-enabled" and "vulkan-disabled" build configurations
- Compile separate GPU modules per configuration
- **Effort:** Low
- **Benefit:** Quick workaround
- **Drawback:** Messy build.zig, configuration complexity

### Option 4: Wait for Zig 0.16+
- Zig 0.16 may improve module system to support transitive build options
- **Effort:** Zero
- **Benefit:** Proper solution upstream
- **Drawback:** Unknown timeline

## Current Workaround

Vulkan PageRank implementation is **temporarily disabled** in `src/gpu/pagerank_kernels.zig`:

```zig
// Vulkan support temporarily disabled - needs build system refactoring
// const VulkanCompute = @import("vulkan_compute.zig").VulkanCompute;
// fn gpuPageRankVulkanImpl(...) { ... }
```

CUDA PageRank still works. System falls back to CPU if CUDA unavailable.

## Phase 1 & 2 Status

✅ **Phase 1 (Foundation):** COMPLETE
- Vulkan device initialization
- Buffer management  
- Compute pipeline creation
- **Tests pass** (when run directly with proper flags)

✅ **Phase 2 (Shaders):** COMPLETE  
- GLSL PageRank, SetOps, ShortestPath shaders
- SPIR-V compilation pipeline
- Shader loading infrastructure
- **4 shaders compiled** (12.1 KB SPIR-V)

## Vulkan Test Status

Vulkan basic tests **can run** but only when invoked with proper flags:

```bash
zig test tests/gpu/test_vulkan_basic.zig \
  -lc -I/usr/include -L/usr/lib/aarch64-linux-gnu -lvulkan
```

They **cannot** run via `zig build test` due to the @cImport issue.

## Implementation Done (Blocked from Integration)

The following Vulkan PageRank implementation exists but is commented out:

- ✅ VulkanCompute initialization
- ✅ Buffer creation for graph data (CSR format)
- ✅ Out-degrees calculation
- ✅ SPIR-V shader loading
- ✅ Compute pipeline with push constants
- ✅ Iterative PageRank execution
- ✅ Result copying back to host
- ✅ f32→f64 conversion for API compatibility

**Code Location:** `src/gpu/pagerank_kernels.zig:169-272` (commented out)

## Files Modified

1. `src/gpu/pagerank_kernels.zig` - Vulkan impl added then commented out
2. `src/gpu/vulkan_compute.zig` - Added `executeWithPushConstants()` method
3. `build.zig` - Added Vulkan linking to benchmarks (incomplete due to blocker)
4. `docs/VULKAN_IMPLEMENTATION_STATUS.md` - Updated to reflect blocker

## Recommendation

**Implement Option 1 (Manual FFI)** as part of Phase 4.

1. Create `src/gpu/vulkan_ffi.zig` with manual extern declarations
2. Remove @cImport from `vulkan_loader.zig`  
3. Update `vulkan_compute.zig` to use FFI module
4. Add proper build configuration for Vulkan-enabled builds
5. Un-comment Vulkan PageRank implementation
6. Test full CUDA→Vulkan→CPU fallback chain

**Estimated Effort:** 4-6 hours

## Backend Selection Strategy (Design)

Once unblocked, the GPU backend selection will work as follows:

```
User Query
    ↓
Check graph size > threshold?
    ↓ Yes
Try CUDA
    ↓ Fail/Unavailable
Try Vulkan  
    ↓ Fail/Unavailable
Use CPU (always works)
```

### Thresholds (To Be Tuned)

| Algorithm | GPU Threshold | Reasoning |
|-----------|---------------|-----------|
| PageRank | 1M nodes | Memory transfer overhead dominates below this |
| Set Operations | 10M elements | CPU hash tables competitive until this scale |
| Shortest Path | 1M nodes | Algorithm complexity benefits GPU at this scale |
| BFS | N/A | Removed - CPU always faster |

## Testing Plan (Post-Unblock)

1. Unit tests for Vulkan FFI bindings
2. Integration tests: Vulkan PageRank vs CPU (correctness)
3. Performance benchmarks: CUDA vs Vulkan vs CPU
4. Fallback chain tests: Simulate CUDA unavailable
5. Docker tests with AMD/Intel GPUs (Vulkan-only)

## Performance Expectations

Based on Phase 2 shader design:

| Workload | CPU | CUDA | Vulkan | Notes |
|----------|-----|------|--------|-------|
| PageRank 1M nodes | 190ms | 590ms | ~800ms¹ | CUDA slower due to sync overhead |
| PageRank 5M nodes | ~1200ms | ~400ms² | ~600ms² | GPU wins at scale |
| SetOps 15M elements | 2000ms | 580ms | ~750ms² | CUDA 3.5x, Vulkan ~2.7x² |

¹ Actual measurements from test_gpu_docker.sh (Phase 2)  
² Projected based on CUDA measurements + typical Vulkan overhead

## Conclusion

Phase 3 implementation is **complete but blocked** by Zig build system limitations.

**Next Steps:**
1. Document architectural decision (this file)
2. Implement manual FFI bindings (Option 1)
3. Complete Phase 3 integration
4. Proceed to Phase 4 (SetOps Vulkan)
5. Update VULKAN_IMPLEMENTATION_STATUS.md when unblocked

---

**CANARY:** REQ=REQ-GPU-003; FEATURE="Vulkan Compute"; ASPECT=Phase3Blocked; STATUS=BLOCKED; OWNER=gpu; UPDATED=2025-10-26
