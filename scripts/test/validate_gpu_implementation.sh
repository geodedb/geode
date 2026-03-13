#!/bin/bash
set -euo pipefail
# GPU Implementation Validation Script
# CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Validation; STATUS=EXEMPT; OWNER=engine; UPDATED=2025-10-26

echo "=== GPU Acceleration Implementation Validation ==="
echo "Date: $(date)"
echo ""

PASS=0
FAIL=0

check_file() {
    if [ -f "$1" ]; then
        echo "✅ $1"
        ((PASS++))
    else
        echo "❌ MISSING: $1"
        ((FAIL++))
    fi
}

check_canary() {
    if grep -q "CANARY.*$2" "$1" 2>/dev/null; then
        echo "✅ CANARY: $1 - $2"
        ((PASS++))
    else
        echo "⚠️  NO CANARY: $1 - $2"
        ((FAIL++))
    fi
}

echo "--- Core GPU Modules ---"
check_file "src/gpu.zig"
check_file "src/gpu/phase0.zig"
check_file "src/gpu/phase1_kernels.zig"
check_file "src/gpu/pagerank_kernels.zig"
check_file "src/gpu/gpu_setops_kernels.zig"
check_file "src/gpu/shortest_path_kernels.zig"
check_file "src/gpu/telemetry.zig"
check_file "src/gpu/cuda_loader.zig"
check_file "src/gpu/memory_manager.zig"
check_file "src/gpu/module_loader.zig"
check_file "src/gpu/kernel_sources.zig"
echo ""

echo "--- Benchmarks ---"
check_file "src/benchmarks/bench_gpu_bfs.zig"
check_file "src/benchmarks/bench_gpu_pagerank.zig"
check_file "src/benchmarks/bench_gpu_setops.zig"
check_file "src/benchmarks/bench_gpu_shortest_path.zig"
check_file "run_gpu_benchmarks.sh"
echo ""

echo "--- Documentation ---"
check_file "docs/cuda_todo.md"
check_file "docs/CUDA_ACCELERATION_SUMMARY.md"
echo ""

echo "--- CANARY Markers ---"
check_canary "src/gpu/phase0.zig" "Phase0Infra"
check_canary "src/gpu/phase1_kernels.zig" "Phase1Traversal"
check_canary "src/gpu/pagerank_kernels.zig" "Phase2PageRank"
check_canary "src/gpu/gpu_setops_kernels.zig" "Phase3SetOps"
check_canary "src/gpu/shortest_path_kernels.zig" "Phase4ShortestPath"
check_canary "src/gpu/telemetry.zig" "Phase5Telemetry"
check_canary "src/benchmarks/bench_gpu_bfs.zig" "Phase1Benchmark"
check_canary "src/benchmarks/bench_gpu_pagerank.zig" "Phase2Benchmark"
check_canary "src/benchmarks/bench_gpu_setops.zig" "Phase3Benchmark"
check_canary "src/benchmarks/bench_gpu_shortest_path.zig" "Phase4Benchmark"
echo ""

echo "--- Test Verification ---"
echo "Checking for GPU test implementations..."
if zig build test 2>&1 | grep -q "TestCANARY_REQ_GQL_051_GPUPhase0DeviceEnum"; then
    echo "✅ GPU tests found in build"
    ((PASS++))
else
    echo "⚠️  GPU tests may not be wired into build (check tests/gpu_*.zig)"
    ((FAIL++))
fi
echo ""

echo "=== Validation Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "✅ All validation checks passed!"
    echo ""
    echo "Next steps:"
    echo "1. Run: zig build bench-gpu (or ./run_gpu_benchmarks.sh)"
    echo "2. Verify performance targets achieved"
    echo "3. Document actual speedups in cuda_todo.md"
    exit 0
else
    echo "⚠️  Some validation checks failed. Review output above."
    exit 1
fi
