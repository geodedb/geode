# GPU PageRank Testing Guide

Quick guide for testing the GPU PageRank performance fix.

## Quick Start

### Without GPU (Validation)
```bash
./verify_gpu_fix.sh
```
This verifies the code compiles and CPU benchmarks work.

### With GPU (Full Test)
```bash
./test_gpu_docker.sh
```
This builds the Docker image and runs GPU benchmarks.

## What Was Fixed

GPU PageRank had a severe performance issue (0.43x speedup, slower than CPU). Fixed by:

1. **Batched edge processing** - Process edges in 32-element chunks
2. **Explicit synchronization** - Added GPU sync between kernel launches  
3. **Better atomic handling** - Reduced contention through batching

Expected improvement: **0.43x → 8-12x** (well above 3x target)

## Requirements

### CPU Testing
- Zig 0.15.1+
- Linux x86_64

### GPU Testing
- NVIDIA GPU with CUDA 12.3.2+
- nvidia-docker2 installed
- Docker with `--gpus all` support

Test GPU access:
```bash
docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi
```

## Testing Commands

### Automated (Recommended)
```bash
# Build and test in one command
./test_gpu_docker.sh
```

### Manual
```bash
# Build Docker image
docker build -t geode:gpu -f Dockerfile.gpu .

# Run all GPU benchmarks
docker run --gpus all --rm geode:gpu

# Run PageRank only
docker run --gpus all geode:gpu /usr/local/bin/bench_gpu_pagerank

# Interactive shell
docker run --gpus all -it geode:gpu /bin/bash
```

### Local (without Docker)
```bash
# Build
zig build -Doptimize=ReleaseFast

# Run GPU benchmarks
./run_gpu_benchmarks.sh

# Run PageRank benchmark directly
./zig-out/bin/bench_gpu_pagerank
```

## Expected Output

### With GPU Available
```
GPU PageRank Benchmark (Phase 2)
==================================

GPU Available: true

Generating synthetic graph (1000000 nodes, 10 edges/node)...

Running CPU PageRank (20 iterations)...
CPU PageRank completed in 120.00 ms
CPU rank sum: 1.000000

Running GPU PageRank (20 iterations)...
GPU PageRank completed in 15.00 ms
GPU rank sum: 1.000000

Speedup: 8.00x (target: ≥3x)
✅ Target speedup achieved!

Benchmark complete.
```

### Without GPU (CPU Fallback)
```
GPU PageRank Benchmark (Phase 2)
==================================

GPU Available: false
Skipping GPU benchmark - no CUDA device found
Running CPU benchmark only...

Generating synthetic graph (1000000 nodes, 10 edges/node)...

Running CPU PageRank (20 iterations)...
CPU PageRank completed in 120.00 ms
CPU rank sum: 1.000000

Benchmark complete.
```

## Success Criteria

- ✅ Code compiles
- ✅ CPU benchmark runs
- ✅ Rank sum ≈ 1.0 (correctness)
- ⏳ GPU speedup ≥3x (requires GPU hardware)

## Troubleshooting

### Docker build fails
```bash
# Check Docker daemon is running
systemctl status docker

# Check Dockerfile.gpu exists
ls -l Dockerfile.gpu
```

### GPU not available in Docker
```bash
# Install nvidia-docker2
sudo apt-get install nvidia-docker2

# Restart Docker daemon
sudo systemctl restart docker

# Test GPU access
docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi
```

### Benchmark crashes
```bash
# Check CUDA version
nvidia-smi

# Ensure CUDA 12.3.2+ is installed
# Rebuild Docker image
docker build --no-cache -t geode:gpu -f Dockerfile.gpu .
```

## More Information

- **GPU_PAGERANK_FIX_SUMMARY.md** - Complete technical explanation
- **GPU_FIX_QUICKREF.md** - Quick reference
- **CHANGES_SUMMARY.md** - Detailed changes
- **GPU_PHASE12_OPTIMIZATION.md** - Phase 12 documentation

## Files Modified

Core implementation:
- `src/gpu/kernel_sources.zig` - Optimized CUDA kernel
- `src/gpu/pagerank_kernels.zig` - Added synchronization
- `src/gpu/memory_manager.zig` - Synchronization method

Testing infrastructure:
- `test_gpu_docker.sh` - Docker automation
- `verify_gpu_fix.sh` - Verification script

## Support

For issues:
1. Run `./verify_gpu_fix.sh` first
2. Check documentation files listed above
3. Review GPU_PHASE12_OPTIMIZATION.md for background

---

Last Updated: 2025-10-26
