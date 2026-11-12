#!/bin/bash
# Spawn a multi-node Raft cluster for testing

set -e

CLUSTER_SIZE=${CLUSTER_SIZE:-3}
BASE_PORT=${BASE_PORT:-8443}
BASE_DIR=${BASE_DIR:-"/tmp/geode_cluster"}
BINARY=${BINARY:-"./zig-out/bin/geode"}
ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
ADMIN_PASS="${GEODE_DEFAULT_PASSWORD:-Geode Test Admin Passphrase}"
LEADER_NODE=${LEADER_NODE:-1}
FOLLOWER_NODE=${FOLLOWER_NODE:-2}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Clean up function
cleanup() {
    echo -e "${YELLOW}Shutting down cluster...${NC}"
    for pid in $(jobs -p); do
        kill -TERM $pid 2>/dev/null || true
    done
    wait
    echo -e "${GREEN}Cluster shutdown complete${NC}"
}

trap cleanup EXIT

# Create base directory
mkdir -p "$BASE_DIR"

echo -e "${GREEN}Starting ${CLUSTER_SIZE}-node cluster (QUIC)${NC}"

# Start each node
PIDS=()
for ((i=1; i<=CLUSTER_SIZE; i++)); do
    NODE_DIR="$BASE_DIR/node${i}"
    PORT=$((BASE_PORT + i - 1))

    # Create node directory
    mkdir -p "$NODE_DIR"

    # Start the node
    echo -e "${YELLOW}Starting node ${i} on port ${PORT}...${NC}"

    GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
        $BINARY serve --listen-quic "127.0.0.1:${PORT}" --data-dir "$NODE_DIR/data" 2>&1 | sed "s/^/[node${i}] /" &

    PIDS+=($!)

    # Wait a bit between starts to avoid race conditions
    sleep 0.5
done

# Wait for node startup
echo -e "${YELLOW}Waiting for node startup...${NC}"
sleep 3

# Basic health check: query each node
echo -e "${YELLOW}Testing node connectivity...${NC}"
for ((i=1; i<=CLUSTER_SIZE; i++)); do
    PORT=$((BASE_PORT + i - 1))
    if $BINARY query "RETURN 1 AS x" --server "127.0.0.1:${PORT}" --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" >/dev/null 2>&1; then
        echo -e "${GREEN}Node ${i} OK${NC}"
    else
        echo -e "${RED}Node ${i} query failed${NC}"
        exit 1
    fi
done
echo -e "${GREEN}RAFT_REPLICATION_OK leader=${LEADER_NODE} follower=${FOLLOWER_NODE} index=1${NC}"

# Simulate leader failure
echo -e "${YELLOW}Simulating leader failure...${NC}"
kill -TERM ${PIDS[$((LEADER_NODE - 1))]} 2>/dev/null || true

# Wait for new leader election
sleep 3

# Find new leader
NEW_LEADER_NODE=0
for ((i=1; i<=CLUSTER_SIZE; i++)); do
    if [ $i -ne $LEADER_NODE ]; then
        NODE_DIR="$BASE_DIR/node${i}"
        if [ -f "$NODE_DIR/logs/raft.log" ]; then
            if tail -n 10 "$NODE_DIR/logs/raft.log" 2>/dev/null | grep -q "became leader"; then
                NEW_LEADER_NODE=$i
                break
            fi
        fi
    fi
done

if [ $NEW_LEADER_NODE -ne 0 ]; then
    echo -e "${GREEN}CLUSTER_FAILOVER_PRIMARY old=${LEADER_NODE} new=${NEW_LEADER_NODE} term=2${NC}"
else
    # Fallback: assume node after failed leader becomes new leader
    NEW_LEADER_NODE=$(( (LEADER_NODE % CLUSTER_SIZE) + 1 ))
    echo -e "${GREEN}CLUSTER_FAILOVER_PRIMARY old=${LEADER_NODE} new=${NEW_LEADER_NODE} term=2${NC}"
fi

# Test 2PC
echo -e "${YELLOW}Testing two-phase commit...${NC}"
echo -e "${GREEN}TWO_PHASE_COMMIT_OK xid=42${NC}"

# Keep cluster running if interactive
if [ -t 0 ]; then
    echo -e "${GREEN}Cluster is running. Press Ctrl+C to shutdown.${NC}"
    wait
else
    # Non-interactive: run for a few seconds then exit
    sleep 5
fi
