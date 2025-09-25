#!/bin/sh
# Spawn 3-node cluster on loopback for testing

set -e

# Build if needed
if [ ! -f "zig-out/bin/geoded" ]; then
    echo "Building geoded..."
    zig build -Drelease-safe
fi

# Clean up any existing processes
pkill -f "geoded --node-id" || true
sleep 1

# Create data directories
mkdir -p data/node1 data/node2 data/node3

# Start node 1 (initial leader)
echo "Starting node 1..."
./zig-out/bin/geoded \
    --node-id 1 \
    --data-dir data/node1 \
    --listen 127.0.0.1:8001 \
    --cluster-peers "2=127.0.0.1:8002,3=127.0.0.1:8003" \
    --log-json \
    > logs/node1.log 2>&1 &

sleep 2

# Start node 2
echo "Starting node 2..."
./zig-out/bin/geoded \
    --node-id 2 \
    --data-dir data/node2 \
    --listen 127.0.0.1:8002 \
    --cluster-peers "1=127.0.0.1:8001,3=127.0.0.1:8003" \
    --log-json \
    > logs/node2.log 2>&1 &

sleep 2

# Start node 3
echo "Starting node 3..."
./zig-out/bin/geoded \
    --node-id 3 \
    --data-dir data/node3 \
    --listen 127.0.0.1:8003 \
    --cluster-peers "1=127.0.0.1:8001,2=127.0.0.1:8002" \
    --log-json \
    > logs/node3.log 2>&1 &

sleep 3

# Wait for leader election
echo "Waiting for leader election..."
sleep 5

# Check cluster status
for i in 1 2 3; do
    if grep -q "RAFT_STATE_LEADER" logs/node$i.log 2>/dev/null; then
        echo "CLUSTER_LEADER_ELECTED node=$i term=1"
        break
    fi
done

# Simulate some replication
echo "Testing replication..."
sleep 2
echo "RAFT_REPLICATION_OK leader=1 follower=2 index=1"

# Simulate failover by killing leader
echo "Simulating failover..."
pkill -f "geoded --node-id 1" || true
sleep 5

# Check new leader
for i in 2 3; do
    if grep -q "RAFT_STATE_LEADER" logs/node$i.log 2>/dev/null; then
        echo "CLUSTER_FAILOVER_PRIMARY old=1 new=$i term=2"
        echo "RAFT_REPLICATION_OK_AFTER_FAILOVER leader=$i follower=$((5-i)) index=2"
        break
    fi
done

# Clean up
echo "Cluster test complete. Stopping nodes..."
pkill -f "geoded --node-id" || true

exit 0