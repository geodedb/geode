#!/bin/bash
# Test GPU PageRank Performance in Docker Container
# Run with: ./test_gpu_docker.sh

set -e

echo "=== GPU PageRank Docker Test ==="
echo "Building Docker image with GPU support..."

# Build the GPU Docker image
docker build -t geode:gpu-pagerank-test -f Dockerfile.gpu .

echo ""
echo "=== Running GPU Benchmarks in Container ==="
echo "Note: Requires NVIDIA Docker runtime (--gpus all)"
echo ""

# Run the container with GPU access
# The default CMD in Dockerfile.gpu runs all benchmarks
docker run --gpus all --rm geode:gpu-pagerank-test

echo ""
echo "=== Test Complete ==="
echo ""
echo "To run individual benchmarks:"
echo "  docker run --gpus all geode:gpu-pagerank-test /usr/local/bin/bench_gpu_pagerank"
echo ""
echo "To run with shell access:"
echo "  docker run --gpus all -it geode:gpu-pagerank-test /bin/bash"
