# CUDA Acceleration Plan — geode
Date: 2025-10-25T22:32:36.499Z
Owner: engine

## Guiding Principles
- Incremental, test-gated integration; each feature lands with kernels + planner/executor wiring + diagnostics + CANARY evidence.
- No regression of CPU path; identical results (bit‑for‑bit for numeric except tolerated FP diff < 1e-6 documented).
- Automatic capability detection (loader) chooses CUDA at runtime; explicit session override `gpu=off` falls back.
- Deterministic pagination/order semantics preserved; GPU operators must emit `ordered` metadata consistently.

## Priority Phases
### Phase 0: Infrastructure / Enablement
1. Replace stub `CudaLoader` with full dynamic loader + fallback static link path (if permitted).  
2. Implement device enumeration & capability capture (SM count, memory, warp size).  
3. Unified GPU memory manager (pinned host alloc, pooled device slabs, async copy helpers).  
4. Planner: introduce physical ops `GpuNodeScan`, `GpuExpand`, `GpuSetOp`, `GpuPageRank`, `GpuBfs`.  
5. Executor dispatch table chooses GPU variant when (a) device present, (b) estimated benefit > threshold, (c) feature not disabled.  
6. Diagnostics: add `GPUFeaturePromoted` status; Flagger marks unsupported optional kernels.  
Acceptance: `zig build test` passes existing tests; new infra tests: device enumeration (skip if none), memory alloc roundtrip, dispatch selection.

### Phase 1: Core Graph Traversal (Path Expand + BFS)
Status: IN PROGRESS (Phase0 complete; initial BFS frontier count scaffold added) — 2025-10-25T23:58:56.344Z
1. Kernel: CSR adjacency traversal (one level expand) with frontier compaction.  (TODO)
2. Kernel: Multi‑level BFS (direction‑optimized optional).  (Scaffold CPU fallback implemented in `phase1_kernels.zig` — GPU TBD)
3. Data prep: CSR copy to device with incremental refresh (dirty pages tracked).  (TODO)
4. Planner rule: Expand chains length <= 4 auto-coalesce into single GPU pipeline.  (TODO)
5. Executor: streaming of partial frontiers to host for pagination; maintain stable order via vertex id sort (tie‑break UA005/UA006).  (TODO)
6. Tests: `TestCANARY_REQ_GQL_051_GPUPhase1BfsFrontier` implemented; add `TestGPU_PathExpand_Bounded` (TODO).  
Acceptance (pending): BFS speedup ≥5x on 1M edge synthetic (ReleaseFast) benchmark `bench_gpu_bfs.zig` (benchmark scaffold TODO).

### Phase 2: Analytical (PageRank)
1. Kernel: Power iteration with dangling mass reduction + warp‑level sum.  
2. Convergence criteria & deterministic ordering of output bindings.  
3. Planner insertion: recognize PageRank function calls; replace with `GpuPageRank` when graph size > threshold.  
4. Tests: convergence on small graph; compare against CPU implementation diff <1e-6.  
5. Bench: 50 iterations on 1M edges faster than CPU ≥3x.  
Acceptance: PageRank E2E returns identical ordering & values tolerance.

### Phase 3: Set Operations & Projection
1. Kernel: Parallel UNION DISTINCT via hash set (cuckoo or robin hood) with stable emission ordering.  
2. Kernel: INTERSECT / EXCEPT using bitset or sorted merge GPU path.  
3. Planner: cost model extension for GPU set ops; threshold on cardinality.  
4. Tests: GPU vs CPU set op equivalence (unordered semantics).  
Acceptance: UNION DISTINCT speedup ≥4x for 5M rows synthetic.

### Phase 4: Shortest Path (Single‑Source Dijkstra / Delta-Stepping)
1. Kernel: Delta-stepping with bucket parallelization; support weighted edges (float64).  
2. Planner pattern match for `SHORTEST_PATH` bounded; GPU variant only if all weights non-negative.  
3. Tests: correctness on weighted graph, compare distances; tie‑break UA005/UA006 preserved.  
Acceptance: performance benchmark speedup ≥3x vs CPU baseline (>100k edges).

### Phase 5: Integration & Telemetry
1. GPU operator profiling metrics (kernel ms, occupancy, achieved bandwidth).  
2. Diagnostics frame extension: `gpu_perf` object.  
3. Flagger marks implementation-dependent behaviors (ordering stable strategy).  
4. Tests: telemetry presence when GPU path taken; JSON schema validation.

## Planner / Executor Changes
- New enum PhysicalOp additions; modify cost model to include device transfer cost (bytes / PCIe bandwidth) & kernel cost model (edges/second estimate).
- Add heuristics: prefer GPU when (edges > 50k and selectivity > 0.05) for Expand; BFS when expected depth >2.

## Memory Model
- Pooled device buffers keyed by graph id + adjacency epoch; dirty-range tracking for incremental updates.
- Pinned host staging buffers; async HtoD with overlap of kernel execution for next frontier.

## Error & Diagnostics Codes
- GPUUnavailable (informational) when requested but no device.  
- GPUMemoryExhausted (retry falls back to CPU).  
- GPUKernelTimeout (surface to client with status subclass, fallback).  
- GPUFeaturePromoted / GPUFeatureFallback (additional_statuses list).  

## Testing Matrix (Skip Logic)
- Each GPU test starts with capability check; if false -> skip (counts as pass).  
- Benchmarks guarded by `--enable-gpu-bench` flag; CI optional stage.  

## CANARY Lines (Planned)
- Place in each kernel source + planner rule & test: `CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=<Component>; STATUS=IMPL|TESTED; TEST=<Name>; UPDATED=<YYYY-MM-DD>`.

## Deliverables per Phase
1. Code (kernels .cu or embedded PTX strings via Zig build step).  
2. Planner rules + cost model updates.  
3. Tests + benches + CANARY evidence.  
4. README GPU section update (feature matrix).  
5. Variance calibration JSON (performance).  

## Out-of-Scope (Future)
- Multi-GPU sharding.  
- Unified memory / on-demand page migration.  
- Graph updates streaming into persistent device structures (Phase 2+ incremental only).  

## Acceptance Gate (Phase 1)
- All existing tests still pass.  
- New BFS & Expand tests show identical results.  
- Benchmark demonstrates required speedups.  

## Next Action
Implement Phase 0 tasks; add kernels scaffold & planner op stubs; wire detection & first tests.
