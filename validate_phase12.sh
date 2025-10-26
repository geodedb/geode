#!/bin/bash
# GPU Phase 12 Validation Script
# Compares before/after optimization performance

set -e

echo "==================================="
echo "GPU Phase 12 Optimization Validation"
echo "==================================="
echo ""

# Check if running in Docker with GPU
if [ -f "/.dockerenv" ] && command -v nvidia-smi &> /dev/null; then
    echo "✅ Running in Docker with NVIDIA GPU"
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
    echo ""
else
    echo "⚠️  Not in Docker GPU environment"
    echo "   Build with: docker build -f Dockerfile.gpu -t geode:gpu-phase12 ."
    echo "   Run with: docker run --gpus all --rm geode:gpu-phase12 ./validate_phase12.sh"
    echo ""
fi

# Build benchmarks
echo "Building GPU benchmarks..."
zig build -Doptimize=ReleaseFast > /dev/null 2>&1

if [ ! -f "zig-out/bin/bench_gpu_pagerank" ]; then
    echo "❌ Benchmarks not found. Build may have failed."
    exit 1
fi

echo "✅ Benchmarks built successfully"
echo ""

# Run PageRank benchmark
echo "================================================"
echo "1. PageRank Optimization Test"
echo "================================================"
echo ""
echo "Target: ≥3x speedup"
echo "Before: 0.43x (O(N²) algorithm)"
echo "After: Expected 8-12x (O(E) push-based)"
echo ""

zig-out/bin/bench_gpu_pagerank 2>&1 | tee /tmp/pagerank_result.log

echo ""
PAGERANK_SPEEDUP=$(grep "Speedup:" /tmp/pagerank_result.log | tail -1 | awk '{print $2}' | tr -d 'x')
if [ -z "$PAGERANK_SPEEDUP" ]; then
    echo "⚠️  Could not extract PageRank speedup"
elif (( $(echo "$PAGERANK_SPEEDUP >= 3.0" | bc -l) )); then
    echo "✅ PageRank speedup: ${PAGERANK_SPEEDUP}x (PASS)"
else
    echo "❌ PageRank speedup: ${PAGERANK_SPEEDUP}x (FAIL - below 3x target)"
fi

# Run Set Operations benchmark
echo ""
echo "================================================"
echo "2. Set Operations Optimization Test"
echo "================================================"
echo ""

zig-out/bin/bench_gpu_setops 2>&1 | tee /tmp/setops_result.log

echo ""
UNION_SPEEDUP=$(grep "UNION DISTINCT Speedup:" /tmp/setops_result.log | awk '{print $4}' | tr -d 'x')
INTERSECT_SPEEDUP=$(grep "INTERSECT Speedup:" /tmp/setops_result.log | awk '{print $3}' | tr -d 'x')

echo "UNION DISTINCT Results:"
echo "  Target: ≥4x speedup"
echo "  Before: 2.87x (GPU bitonic sort)"
echo "  After: Expected 4.5x (CPU merge sort + GPU unique)"
if [ -n "$UNION_SPEEDUP" ]; then
    if (( $(echo "$UNION_SPEEDUP >= 4.0" | bc -l) )); then
        echo "  ✅ Speedup: ${UNION_SPEEDUP}x (PASS)"
    else
        echo "  ⚠️  Speedup: ${UNION_SPEEDUP}x (Below target but improved)"
    fi
else
    echo "  ⚠️  Could not extract UNION speedup"
fi

echo ""
echo "INTERSECT Results:"
echo "  Target: ≥3x speedup"
echo "  Before: 2.26x"
echo "  After: Expected 3.2x"
if [ -n "$INTERSECT_SPEEDUP" ]; then
    if (( $(echo "$INTERSECT_SPEEDUP >= 3.0" | bc -l) )); then
        echo "  ✅ Speedup: ${INTERSECT_SPEEDUP}x (PASS)"
    else
        echo "  ⚠️  Speedup: ${INTERSECT_SPEEDUP}x (Below target)"
    fi
else
    echo "  ⚠️  Could not extract INTERSECT speedup"
fi

# Summary
echo ""
echo "================================================"
echo "Phase 12 Validation Summary"
echo "================================================"
echo ""

PASS_COUNT=0
TOTAL_COUNT=3

if [ -n "$PAGERANK_SPEEDUP" ] && (( $(echo "$PAGERANK_SPEEDUP >= 3.0" | bc -l) )); then
    PASS_COUNT=$((PASS_COUNT + 1))
fi

if [ -n "$UNION_SPEEDUP" ] && (( $(echo "$UNION_SPEEDUP >= 4.0" | bc -l) )); then
    PASS_COUNT=$((PASS_COUNT + 1))
fi

if [ -n "$INTERSECT_SPEEDUP" ] && (( $(echo "$INTERSECT_SPEEDUP >= 3.0" | bc -l) )); then
    PASS_COUNT=$((PASS_COUNT + 1))
fi

echo "Results: $PASS_COUNT/$TOTAL_COUNT benchmarks meet target"
echo ""

if [ "$PASS_COUNT" -eq "$TOTAL_COUNT" ]; then
    echo "🎉 SUCCESS: All optimizations achieved target speedup!"
    echo ""
    echo "Phase 12 Optimization: COMPLETE ✅"
    exit 0
elif [ "$PASS_COUNT" -gt 0 ]; then
    echo "⚠️  PARTIAL SUCCESS: Some optimizations achieved target"
    echo ""
    echo "Further optimization may be needed for:"
    [ -n "$PAGERANK_SPEEDUP" ] && (( $(echo "$PAGERANK_SPEEDUP < 3.0" | bc -l) )) && echo "  - PageRank (current: ${PAGERANK_SPEEDUP}x, target: 3x)"
    [ -n "$UNION_SPEEDUP" ] && (( $(echo "$UNION_SPEEDUP < 4.0" | bc -l) )) && echo "  - UNION DISTINCT (current: ${UNION_SPEEDUP}x, target: 4x)"
    [ -n "$INTERSECT_SPEEDUP" ] && (( $(echo "$INTERSECT_SPEEDUP < 3.0" | bc -l) )) && echo "  - INTERSECT (current: ${INTERSECT_SPEEDUP}x, target: 3x)"
    exit 1
else
    echo "❌ FAILED: No benchmarks achieved target speedup"
    echo ""
    echo "Possible issues:"
    echo "  - CUDA/GPU not available"
    echo "  - NVRTC compilation failed (using simplified PTX)"
    echo "  - Memory transfer overhead still dominates"
    echo "  - Further optimization needed"
    exit 2
fi
