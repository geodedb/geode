# GPU Acceleration - README Section

Add this section to the main README.md to document GPU acceleration features.

---

## GPU Acceleration (CUDA)

Geode supports optional CUDA GPU acceleration for graph algorithms and set operations. GPU acceleration is detected automatically at runtime - no special compilation flags needed.

### Supported Operations

| Operation | Speedup Target | Use Case |
|-----------|----------------|----------|
| **BFS Traversal** | ≥5x | Multi-hop path expansion, reachability queries |
| **PageRank** | ≥3x | Graph analytics, centrality measures |
| **UNION DISTINCT** | ≥4x | Large set merging operations |
| **Shortest Path** | ≥3x | Weighted path finding (Dijkstra) |

### Requirements

- **Hardware:** NVIDIA GPU with CUDA Compute Capability 3.5+ (Maxwell or newer)
- **Software:** CUDA Toolkit 11.0+ (runtime only, no SDK needed)
- **OS:** Linux x86_64 (currently)
- **Driver:** NVIDIA display driver with CUDA support

### Usage

GPU acceleration is **automatic** when:
1. CUDA-capable GPU is detected
2. Graph/set size exceeds thresholds (e.g., 50k+ edges)
3. Session parameter `gpu=on` (default)

To disable GPU acceleration:
```sql
SET gpu = off;
```

### Checking GPU Status

```sql
-- Show GPU availability
SHOW gpu_available;

-- View GPU telemetry for last query
EXPLAIN (PROFILE) 
MATCH (a)-[*1..5]->(b)
RETURN a, b;
```

Output includes GPU diagnostics:
```json
{
  "gpu_enabled": true,
  "gpu_used": true,
  "metrics": {
    "kernel_ms": 12.34,
    "device_id": 0,
    "kernel_name": "bfs_frontier_expand"
  }
}
```

### Benchmarking

Run GPU performance benchmarks:

```bash
# All benchmarks
./run_gpu_benchmarks.sh

# Individual benchmarks
./zig-out/bin/bench_gpu_bfs          # BFS traversal
./zig-out/bin/bench_gpu_pagerank     # PageRank analytics
./zig-out/bin/bench_gpu_setops       # Set operations
./zig-out/bin/bench_gpu_shortest_path # Shortest path
```

Benchmarks automatically skip GPU tests if CUDA unavailable and run CPU baseline.

### Graceful Fallback

All GPU operations include CPU fallback:
- If GPU unavailable → CPU path (no error)
- If GPU memory exhausted → CPU fallback + warning
- If kernel fails → CPU fallback + diagnostic

### Implementation Details

- **CUDA Driver API** - Dynamic loading via dlopen (no compile-time dependency)
- **PTX Kernels** - Embedded kernel templates compiled at runtime  
- **Event Timing** - Real GPU profiling with CUDA events
- **Memory Pooling** - Amortized allocation costs for hot graphs
- **Zero Copy** - When beneficial (small transfers, UVA)

See `docs/CUDA_ACCELERATION_SUMMARY.md` for complete implementation details.

### Troubleshooting

**GPU not detected:**
1. Check NVIDIA driver: `nvidia-smi`
2. Verify CUDA libraries: `ldconfig -p | grep libcuda`
3. Check permissions: User must access `/dev/nvidia*`

**Performance below targets:**
1. Verify GPU is actually used: Check EXPLAIN PROFILE output
2. Profile kernels: `nvprof ./zig-out/bin/bench_gpu_bfs`
3. Check memory transfer overhead for small graphs
4. Consider GPU disabled for this query size

**Build issues:**
- GPU features are optional; build succeeds without CUDA
- Tests skip GPU tests when CUDA unavailable
- No special build flags needed

### Feature Matrix

| GQL Feature | CPU | GPU | Notes |
|-------------|-----|-----|-------|
| MATCH expansion | ✅ | ✅ | Auto dispatch for large graphs |
| PageRank() function | ✅ | ✅ | GPU for >50k nodes |
| UNION DISTINCT | ✅ | ✅ | GPU for >200k rows |
| SHORTEST_PATH() | ✅ | ✅ | GPU for weighted graphs >10k nodes |
| INTERSECT | ✅ | ✅ | GPU for large sets |
| CREATE/DELETE | ✅ | ❌ | CPU only (future work) |
| Aggregation | ✅ | 🔄 | Planned for Phase 7 |

✅ Available | ❌ Not supported | 🔄 Planned

### References

- Implementation: `docs/CUDA_ACCELERATION_SUMMARY.md`
- Roadmap: `docs/cuda_todo.md`
- Phase 6 Complete: `docs/PHASE6_CUDA_COMPLETE.md`
- Tests: `tests/gpu_*.zig` (31+ CANARY tests)

---
