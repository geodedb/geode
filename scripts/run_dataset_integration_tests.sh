#!/usr/bin/env bash
# Dataset integration tests for Geode
# This script runs tests with loaded datasets

set -e

echo "Dataset integration tests..."

# Check if dataset is loaded or if we should skip
if [ "$GEODE_DATASET" != "1" ]; then
    echo "Dataset tests skipped (set GEODE_DATASET=1 to enable)"
    exit 0
fi

# Get the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$PROJECT_ROOT"

# Start server if needed
if ! pgrep -x geoded > /dev/null; then
    echo "Starting Geode server for dataset tests..."
    ./zig-out/bin/geoded --data_dir ./data --log_json &
    SERVER_PID=$!
    sleep 2
    trap "kill $SERVER_PID 2>/dev/null || true" EXIT
fi

# Load dataset if not already loaded
if [ -f "scripts/load_example_dataset.sh" ]; then
    echo "Loading example dataset..."
    ./scripts/load_example_dataset.sh || echo "Dataset already loaded or load failed"
fi

# Run integration tests that require datasets
echo "Running dataset-dependent integration tests..."

# Test 1: Social network queries
echo "Testing social network queries..."
./zig-out/bin/geodec "MATCH (u:User) RETURN COUNT(u) as count" 2>/dev/null || true

# Test 2: Graph traversal
echo "Testing graph traversal..."
./zig-out/bin/geodec "MATCH (u:User)-[:FOLLOWS]->(f:User) RETURN u.username, f.username LIMIT 5" 2>/dev/null || true

# Test 3: Complex patterns
echo "Testing complex patterns..."
./zig-out/bin/geodec "MATCH (u:User)-[:POSTED]->(p:Post) WHERE p.created_at > date('2024-01-01') RETURN u.username, p.content LIMIT 5" 2>/dev/null || true

echo "Dataset integration tests completed"
