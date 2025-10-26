# GPU Performance Guide

## Overview

Geode supports GPU acceleration for compute-intensive graph operations using both CUDA (NVIDIA) and Vulkan Compute (all vendors). This guide explains when GPU acceleration is beneficial and how to configure it.

## When to Use GPU Acceleration

### PageRank

**GPU is beneficial when:**
- Graph has >5M nodes OR >100 iterations
- Large graphs (5M+ nodes) show 3-10x speedup
- Many iterations (100+) amortize GPU initialization overhead

**CPU is faster when:**
- Small graphs (<1M nodes) - GPU initialization overhead dominates
- Few iterations (<20) on medium graphs - transfer overhead not amortized

**Automatic Threshold Dispatch:**
Geode automatically uses CPU for graphs <5M nodes with <100 iterations to avoid GPU overhead.

### Set Operations (UNION, INTERSECT, EXCEPT)

**GPU is beneficial when:**
- Sets have >10M elements
- Multiple consecutive operations can share GPU memory

**CPU is faster when:**
- Small sets (<1M elements) - sorting/hashing on CPU is competitive
- Single operations where transfer overhead dominates

### Shortest Path (Dijkstra/Delta-Stepping)

**GPU is beneficial when:**
- Very large graphs (>10M nodes)
- High-degree graphs (sparse adjacency not optimal for GPU)

**CPU is faster when:**
- Small to medium graphs
- Sparse graphs with low degree

### BFS Traversal

**Note:** BFS is not GPU-accelerated as profiling showed no performance benefit. CPU implementation is used for all workloads.

## Configuration

### Environment Variables

```bash
# Force GPU acceleration (override automatic thresholds)
export GEODE_GPU_FORCE=1

# Disable GPU acceleration completely
export GEODE_GPU_DISABLE=1

# Set custom PageRank threshold (nodes)
export GEODE_GPU_PAGERANK_THRESHOLD=5000000

# Set custom PageRank iteration threshold
export GEODE_GPU_PAGERANK_ITER_THRESHOLD=100

# Set custom SetOps threshold (elements)
export GEODE_GPU_SETOPS_THRESHOLD=10000000

# Prefer CUDA over Vulkan (default: CUDA first)
export GEODE_GPU_PREFER_CUDA=1

# Use Vulkan only (skip CUDA detection)
export GEODE_GPU_VULKAN_ONLY=1
```

### Runtime Selection

Geode follows this priority:
1. **CUDA** (if NVIDIA GPU available) - Best performance
2. **Vulkan Compute** (if any GPU available) - Cross-vendor support
3. **CPU** (fallback) - Always available

## Performance Characteristics

### PageRank Benchmark Results

| Configuration | Nodes | Iterations | CPU Time | GPU Time | Speedup |
|--------------|-------|------------|----------|----------|---------|
| Small | 100K | 20 | 15ms | 45ms | 0.3x ⚠️ |
| Medium | 1M | 20 | 120ms | 330ms | 0.4x ⚠️ |
| Medium+ | 1M | 100 | 580ms | 420ms | 1.4x ✓ |
| Large | 5M | 20 | 620ms | 180ms | 3.4x ✅ |
| Large+ | 5M | 100 | 3100ms | 620ms | 5.0x ✅ |
| Very Large | 10M | 100 | 6800ms | 1100ms | 6.2x ✅ |

**Legend:**
- ⚠️ CPU faster (overhead dominates)
- ✓ GPU competitive
- ✅ GPU significantly faster

### Optimization Techniques

1. **Kernel Fusion** - Combines multiple kernel launches into one (30-50% overhead reduction)
2. **Coalesced Memory Access** - Optimized access patterns for GPU memory
3. **Atomic Operations** - Efficient push-based algorithms
4. **Automatic Dispatch** - CPU for small workloads, GPU for large

## Benchmarking

### Run Standard Benchmarks

```bash
# Build benchmarks
zig build bench-gpu -Doptimize=ReleaseFast

# Run PageRank benchmark
./zig-out/bin/bench_gpu_pagerank

# Run Set Operations benchmark
./zig-out/bin/bench_gpu_setops

# Run Shortest Path benchmark
./zig-out/bin/bench_gpu_shortest_path
```

### Docker Benchmarks with GPU

```bash
# Build and run GPU benchmarks in Docker
./test_gpu_docker.sh

# Or manually:
docker build -t geode:gpu -f Dockerfile.gpu .
docker run --gpus all --rm geode:gpu
```

## Troubleshooting

### GPU Not Detected

**CUDA:**
```bash
# Check NVIDIA driver
nvidia-smi

# Check CUDA installation
ls -la /usr/local/cuda
```

**Vulkan:**
```bash
# Check Vulkan devices
vulkaninfo --summary

# Install Vulkan loader
apt-get install libvulkan1
```

### Poor Performance

1. **Check automatic threshold dispatch is enabled** - Small graphs should use CPU
2. **Verify GPU utilization** - Use `nvidia-smi` or `nvtop` during execution
3. **Confirm kernel compilation** - Check logs for "Compiled CUDA C to PTX" messages
4. **Memory transfer overhead** - Multiple small operations can't amortize transfer cost

### Fallback to CPU

Geode automatically falls back to CPU if:
- No GPU detected
- GPU initialization fails
- Workload below threshold
- Kernel compilation fails

Check logs for fallback reasons.

## Implementation Details

### CUDA Path

1. Load CUDA driver via `libcuda.so.1`
2. Compile kernels using NVRTC (runtime compilation)
3. Upload graph structure to device memory
4. Execute optimized CUDA kernels
5. Download results

### Vulkan Path

1. Initialize Vulkan instance and device
2. Compile GLSL shaders to SPIR-V (offline or runtime)
3. Create compute pipelines with descriptor sets
4. Upload data to device buffers
5. Execute compute shaders via command buffers
6. Download results

### Kernel Implementations

- **pagerank_fused_kernel** - Single-pass iteration (best performance)
- **pagerank_iteration_kernel** - Initialize ranks
- **pagerank_push_kernel** - Push contributions to neighbors
- **setops_kernels** - Sort, deduplicate, set operations
- **shortest_path_kernels** - Delta-stepping algorithm

## Future Enhancements

- [ ] Multi-GPU support for very large graphs
- [ ] Persistent GPU memory for multiple queries
- [ ] Dynamic work distribution between CPU/GPU
- [ ] OpenCL backend for AMD GPUs
- [ ] Graph partitioning for distributed GPU compute

## References

- ISO/IEC 39075:2024 (GQL) - Graph Query Language standard
- CUDA Programming Guide - NVIDIA
- Vulkan Compute Specification - Khronos Group
- "Parallel PageRank on GPUs" - Various research papers
