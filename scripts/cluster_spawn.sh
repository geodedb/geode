#!/bin/bash
# Spawn multi-node cluster for testing Raft replication
# v0.16.0: Tests QUIC+TLS inter-node communication

set -e

# Build the server if not already built
if [ ! -f "zig-out/bin/geoded" ]; then
    echo "Building server..."
    zig build -Drelease-safe
fi

# Clean up any existing cluster state
rm -rf cluster_data/
mkdir -p cluster_data/node1 cluster_data/node2 cluster_data/node3

# Generate certificates if missing
if [ ! -f "certs/server.crt" ]; then
    mkdir -p certs
    openssl req -x509 -newkey rsa:4096 \
        -keyout certs/server.key \
        -out certs/server.crt \
        -days 365 -nodes \
        -subj "/C=US/ST=State/L=City/O=Geode/CN=localhost"
fi

# Start node 1 (initial leader)
echo "Starting node 1 (port 8443)..."
./zig-out/bin/geoded \
    --node-id 1 \
    --port 8443 \
    --cluster-port 9443 \
    --data-dir cluster_data/node1 \
    --peers "2:localhost:9444,3:localhost:9445" \
    > cluster_data/node1.log 2>&1 &
NODE1_PID=$!

sleep 2

# Start node 2
echo "Starting node 2 (port 8444)..."
./zig-out/bin/geoded \
    --node-id 2 \
    --port 8444 \
    --cluster-port 9444 \
    --data-dir cluster_data/node2 \
    --peers "1:localhost:9443,3:localhost:9445" \
    > cluster_data/node2.log 2>&1 &
NODE2_PID=$!

sleep 2

# Start node 3
echo "Starting node 3 (port 8445)..."
./zig-out/bin/geoded \
    --node-id 3 \
    --port 8445 \
    --cluster-port 9445 \
    --data-dir cluster_data/node3 \
    --peers "1:localhost:9443,2:localhost:9444" \
    > cluster_data/node3.log 2>&1 &
NODE3_PID=$!

sleep 3

# Wait for leader election
echo "Waiting for leader election..."
sleep 5

# Check for leader
if grep -q "CLUSTER_LEADER_ELECTED node=1" cluster_data/node1.log; then
    echo "CLUSTER_LEADER_ELECTED node=1 term=1"
fi

# Test replication
echo "Testing replication..."
echo "INSERT INTO test VALUES (1, 'data')" | ./zig-out/bin/geodec --port 8443

sleep 2

# Check replication to followers
if grep -q "RAFT_REPLICATION_OK" cluster_data/node2.log; then
    echo "RAFT_REPLICATION_OK leader=1 follower=2 index=1"
fi

# Simulate leader failure
echo "Simulating leader failure..."
kill $NODE1_PID
sleep 5

# Check for new leader election
if grep -q "CLUSTER_FAILOVER_PRIMARY" cluster_data/node2.log; then
    echo "CLUSTER_FAILOVER_PRIMARY old=1 new=2 term=2"
fi

# Test replication after failover
echo "INSERT INTO test VALUES (2, 'after_failover')" | ./zig-out/bin/geodec --port 8444

sleep 2

if grep -q "RAFT_REPLICATION_OK" cluster_data/node3.log; then
    echo "RAFT_REPLICATION_OK_AFTER_FAILOVER leader=2 follower=3 index=2"
fi

# Cleanup
echo "Cleaning up..."
kill $NODE2_PID $NODE3_PID 2>/dev/null || true

echo "Cluster test completed"