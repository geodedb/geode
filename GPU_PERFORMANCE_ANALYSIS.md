# GPU Performance Analysis & Fix Plan
Date: 2025-10-26
Owner: engine

## Executive Summary

GPU benchmarks reveal **critical correctness bugs** in the PTX simplified kernels. The PTX implementations are placeholders that don't actually execute the algorithms, causing:

1. **INTERSECT returns 0 instead of 5M** - PTX kernel doesn't implement binary search
2. **UNION returns 20M instead of 15M** - PTX unique kernel just copies all data
3. **BFS visits only 1 node** - Graph generation issue or frontier expansion incomplete
4. **Dijkstra finds 1 node vs 99996** - Delta-stepping kernel incomplete
5. **PageRank slower on GPU** - Memory transfer overhead dominates small graphs

## Root Cause Analysis

### Problem: PTX Simplified Kernels Are Stubs

The `kernel_sources.zig` file contains two versions of each kernel:

1. **CUDA C versions** (`*_kernel_cuda_c`) - Complete, correct implementations
2. **PTX simplified versions** (`*_kernel_ptx_simple`) - **PLACEHOLDER STUBS**

The code currently uses: `pub const setops_kernel_ptx = setops_kernel_ptx_simple;`

This means **PTX stubs are being executed**, not the real algorithms!

### PTX Stub Analysis

#### UNION DISTINCT - Unique Kernel (Lines 307-344)
```ptx
// Simplified: just copy all elements
ld.global.u32 %r6, [%rd5];
st.global.u32 [%rd6], %r6;
```
**Bug:** Copies all 20M input elements to output without checking for duplicates.
**Expected:** Should compare with previous element and only output if different.

#### INTERSECT Kernel (Lines 346-382)
```ptx
// Placeholder: simplified version
ld.global.u32 %r6, [%rd4];
st.global.u32 [%rd6], %r6;
```
**Bug:** Just copies elements from array A to result without checking if they exist in B.
**Expected:** Should perform binary search in sorted array B.

#### Bitonic Sort Kernel (Lines 283-305)
```ptx
// Placeholder: data already "sorted"
```
**Bug:** Does nothing - assumes data is pre-sorted.
**Expected:** Should implement bitonic sort stages with compare-exchange.

## Detailed Issue Breakdown

### Issue #1: INTERSECT Returns 0 Elements (Expected: 5M)

**Benchmark Setup:**
- Set A: [0, 1, 2, ..., 9,999,999]
- Set B: [5,000,000, 5,000,001, ..., 14,999,999]
- Expected Overlap: [5,000,000 to 9,999,999] = 5,000,000 elements

**Actual Result:** GPU returns 0 elements

**Root Cause:** The PTX intersect_kernel doesn't implement binary search. It just stores elements from A to result without checking B membership.

**Fix Required:** 
1. Option A: Compile CUDA C to PTX at runtime (requires nvcc/nvrtc)
2. Option B: Write full PTX implementation with binary search
3. Option C: **Use hash-based intersect on GPU** (simpler, faster for large sets)

### Issue #2: UNION DISTINCT Returns 20M Instead of 15M

**Benchmark Setup:**
- Set A: 10M elements [0..9,999,999]
- Set B: 10M elements [5,000,000..14,999,999]
- Expected UNION: 15M unique elements [0..14,999,999]

**Actual Result:** GPU returns 20M elements (all input)

**Root Cause:** The PTX unique_kernel doesn't compare consecutive elements. It just copies the entire sorted array.

**Fix Required:**
1. Implement proper unique logic in PTX
2. OR compile CUDA C kernel to PTX
3. OR use Thrust-style parallel unique on GPU

### Issue #3: PageRank GPU Slower (267ms vs 116ms CPU)

**Not a bug**, but **expected behavior** for small graphs:

**Analysis:**
- Graph: 1M nodes, 10 edges/node = 10M edges
- Memory transfers: ~40MB HtoD + ~4MB DtoH = 44MB total
- At PCIe Gen3 x16 (~12GB/s): Transfer time ≈ 3.7ms
- CPU baseline: 116ms
- GPU kernel: Should be ~20-30ms
- GPU total: ~30ms kernel + ~4ms transfer + overhead = ~35ms expected

**Actual:** 267ms - **MUCH SLOWER THAN EXPECTED**

**Hypothesis:** The PageRank PTX kernel may also be a stub or extremely inefficient.

### Issue #4: BFS Visits Only 1 Node (Expected: Many)

**Benchmark Setup:**
- Graph: 10M nodes, 10 edges/node = 100M edges
- Start node: 0
- Expected: Many nodes reachable

**Actual Result:** CPU and GPU both visit only 1 node

**Root Cause:** This is likely a **graph generation bug**, not a kernel bug. If the start node has no outgoing edges, BFS stops immediately.

**Fix Required:** Verify graph generation in `bench_gpu_bfs.zig` creates connected graph.

### Issue #5: Dijkstra Finds 1 Node (Expected: 99,996)

**Benchmark Setup:**
- Graph: 100K nodes, random weights
- Start: node 0
- Expected: 99,996 reachable (nearly all)

**Actual Result:** GPU finds 1 node (just start)

**Root Cause:** Similar to BFS - either graph generation issue OR delta-stepping kernel incomplete.

## Solution Strategy

### Immediate Fix (Phase 11): Compile CUDA C to PTX at Build Time

**Approach:** Use `nvcc` (if available) or `nvrtc` library to compile CUDA C kernels to PTX.

**Steps:**
1. Check for nvcc/nvrtc availability at build time
2. If available: Compile CUDA C → PTX and embed in binary
3. If unavailable: Keep simplified PTX as graceful fallback
4. Add runtime detection: Try real PTX first, fallback to simplified

**Build Script Addition:**
```zig
// In build.zig
const nvcc_available = checkNvccAvailable();
if (nvcc_available) {
    compileKernelsToPTX();
}
```

### Alternative Fix: Implement Full PTX Algorithms

**For INTERSECT:** Binary search in PTX (complex but doable)
**For UNIQUE:** Compare with previous element (simple)
**For SORT:** Full bitonic sort implementation (complex)

### Performance Optimization (Phase 12)

**After correctness fixes:**

1. **PageRank:** 
   - Use async memory transfers (overlap transfer + compute)
   - Increase graph size to 10M nodes for benchmark
   - Profile kernel execution vs transfer time

2. **Set Operations:**
   - Use hash-based intersect instead of binary search
   - Parallel radix sort instead of bitonic sort
   - Pinned host memory for faster transfers

3. **BFS/Dijkstra:**
   - Fix graph generation to ensure connectivity
   - Implement frontier compaction on GPU
   - Use shared memory for hot data

## Recommended Action Plan

### Phase 11A: Fix Correctness (HIGH PRIORITY)

1. **Implement Runtime PTX Compilation**
   - Add nvrtc support to CudaLoader
   - Compile CUDA C kernels at first use
   - Cache compiled PTX in memory

2. **Fix Graph Generation**
   - Ensure BFS benchmark generates connected graph
   - Verify Dijkstra graph has edges from start node
   - Add connectivity validation

3. **Validate Results**
   - Run benchmarks with fixed kernels
   - Verify GPU results match CPU exactly
   - Add result validation to all benchmarks

### Phase 11B: Optimize Performance (MEDIUM PRIORITY)

4. **Profile GPU Execution**
   - Add detailed telemetry for each kernel
   - Measure HtoD, kernel, DtoH separately
   - Identify bottlenecks

5. **Optimize Memory Transfers**
   - Use pinned host memory
   - Async transfers with streams
   - Overlap compute and transfer

6. **Optimize Kernels**
   - Tune block sizes for occupancy
   - Use shared memory for reductions
   - Implement warp-level primitives

### Phase 11C: Planner Integration (LOW PRIORITY)

7. **Cost Model Integration**
   - Add GPU cost model to planner
   - Automatic CPU/GPU dispatch
   - Heuristics based on graph size

## Expected Outcomes

### After Correctness Fixes:
- ✅ INTERSECT returns 5M elements (matches CPU)
- ✅ UNION DISTINCT returns 15M elements (matches CPU)
- ✅ BFS visits many nodes (matches CPU)
- ✅ Dijkstra finds 99,996 nodes (matches CPU)
- ⏳ PageRank still slow (needs optimization)

### After Performance Optimization:
- ✅ PageRank: 3-5x speedup over CPU
- ✅ UNION DISTINCT: 4-6x speedup
- ✅ INTERSECT: 3-4x speedup
- ✅ BFS: 5-10x speedup
- ✅ Dijkstra: 5-10x speedup (already achieving this!)

## Implementation Priority

1. **CRITICAL:** Runtime PTX compilation (fixes all kernel correctness)
2. **HIGH:** Fix graph generation (fixes BFS/Dijkstra)
3. **HIGH:** Validate all results match CPU
4. **MEDIUM:** Profile and optimize memory transfers
5. **MEDIUM:** Optimize kernel performance
6. **LOW:** Planner integration

## Files to Modify

1. `src/gpu/cuda_loader.zig` - Add nvrtc API loading
2. `src/gpu/kernel_sources.zig` - Add runtime compilation
3. `src/gpu/module_loader.zig` - Support compiled PTX
4. `src/benchmarks/bench_gpu_bfs.zig` - Fix graph generation
5. `src/benchmarks/bench_gpu_shortest_path.zig` - Fix graph generation
6. All GPU kernel files - Add result validation

## Testing Strategy

### Unit Tests (Per Kernel):
- Small input (100 elements) - verify correctness
- Medium input (10K elements) - verify correctness + performance
- Large input (1M elements) - verify performance targets

### Integration Tests:
- End-to-end GPU query execution
- CPU/GPU result equivalence
- Fallback behavior when GPU unavailable

### Benchmarks:
- Run on multiple graph sizes
- Profile each component separately
- Generate performance report

## Conclusion

The GPU implementation is **architecturally sound** but has **critical kernel correctness bugs** due to simplified PTX placeholders. The fix is straightforward: compile CUDA C kernels to real PTX using nvrtc. Performance optimization can follow once correctness is established.

**Next Action:** Implement Phase 11A - Runtime PTX Compilation
