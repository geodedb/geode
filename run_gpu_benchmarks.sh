#!/bin/bash
# GPU Benchmark Runner - Performance Validation Phase
# CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Benchmarks; STATUS=IMPL; OWNER=engine; UPDATED=2025-10-26

echo "=== GPU Acceleration Benchmarks ==="
echo "Date: $(date)"
echo ""

echo "Note: GPU benchmarks require CUDA-capable hardware."
echo "If CUDA is unavailable, benchmarks will skip GPU tests and run CPU baseline only."
echo ""

# Check if running in Docker container (binaries in /usr/local/bin)
if [ -f "/usr/local/bin/bench_gpu_bfs" ]; then
    BIN_DIR="/usr/local/bin"
elif [ -d "zig-out/bin" ]; then
    BIN_DIR="zig-out/bin"
else
    echo "Building benchmarks..."
    zig build -Doptimize=ReleaseFast
    BIN_DIR="zig-out/bin"
fi

echo "--- Phase 1: BFS Traversal ---"
if [ -f "$BIN_DIR/bench_gpu_bfs" ]; then
    $BIN_DIR/bench_gpu_bfs
else
    echo "BFS benchmark not found in $BIN_DIR"
fi
echo ""

echo "--- Phase 2: PageRank ---"
if [ -f "$BIN_DIR/bench_gpu_pagerank" ]; then
    $BIN_DIR/bench_gpu_pagerank
else
    echo "PageRank benchmark not found in $BIN_DIR"
fi
echo ""

echo "--- Phase 3: Set Operations ---"
if [ -f "$BIN_DIR/bench_gpu_setops" ]; then
    $BIN_DIR/bench_gpu_setops
else
    echo "Set Operations benchmark not found in $BIN_DIR"
fi
echo ""

echo "--- Phase 4: Shortest Path ---"
if [ -f "$BIN_DIR/bench_gpu_shortest_path" ]; then
    $BIN_DIR/bench_gpu_shortest_path
else
    echo "Shortest Path benchmark not found in $BIN_DIR"
fi
echo ""

echo "=== Benchmarks Complete ==="
echo "Next steps:"
echo "1. Review performance results above"
echo "2. Check if speedup targets achieved (BFS ≥5x, PageRank ≥3x, UNION ≥4x, Dijkstra ≥3x)"
echo "3. Document actual speedups in cuda_todo.md"
echo "4. Run profiling if needed: nvprof or nsys for detailed kernel analysis"
