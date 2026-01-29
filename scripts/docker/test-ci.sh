#!/bin/bash
# Simplified CI test script for Docker deployments

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

MODE="${1:-singleton}"

echo -e "${GREEN}=== Docker CI Test ($MODE) ===${NC}"

if [[ "$MODE" == "singleton" ]]; then
    # Wait for container to be ready
    max_wait=30
    elapsed=0
    echo -n "Waiting for geode-singleton to be ready..."
    while [[ $elapsed -lt $max_wait ]]; do
        if docker ps --format "table {{.Names}}\t{{.Status}}" | grep -q "geode-singleton.*Up"; then
            echo -e " ${GREEN}ready${NC}"
            break
        fi
        echo -n "."
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [[ $elapsed -ge $max_wait ]]; then
        echo -e " ${RED}timeout${NC}"
        exit 1
    fi

    # Run basic query test
    echo "Testing basic query..."
    if docker exec geode-singleton geodec "RETURN 1 AS x" --server 127.0.0.1:7567 2>/dev/null | grep -q '"x":1'; then
        echo -e "${GREEN}PASS: Basic query test${NC}"
    else
        echo -e "${RED}FAIL: Basic query test${NC}"
        exit 1
    fi

elif [[ "$MODE" == "distributed" ]]; then
    # Wait for cluster to be ready
    for node in geode-leader geode-follower-1 geode-follower-2; do
        max_wait=45
        elapsed=0
        echo -n "Waiting for $node to be ready..."
        while [[ $elapsed -lt $max_wait ]]; do
            if docker ps --format "table {{.Names}}\t{{.Status}}" | grep -q "$node.*Up"; then
                echo -e " ${GREEN}ready${NC}"
                break
            fi
            echo -n "."
            sleep 1
            elapsed=$((elapsed + 1))
        done

        if [[ $elapsed -ge $max_wait ]]; then
            echo -e " ${RED}timeout${NC}"
            exit 1
        fi
    done

    # Test leader
    echo "Testing leader node..."
    if docker exec geode-leader geodec "RETURN 1 AS x" --server 127.0.0.1:7567 2>/dev/null | grep -q '"x":1'; then
        echo -e "${GREEN}PASS: Leader query test${NC}"
    else
        echo -e "${RED}FAIL: Leader query test${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}Docker CI test completed successfully${NC}"
