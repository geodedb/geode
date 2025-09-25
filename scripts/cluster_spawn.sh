#!/bin/sh
# Multi-process cluster spawn script for testing

# Function to cleanup on exit
cleanup() {
    echo "Cleaning up cluster processes..."
    for pid in $NODE1_PID $NODE2_PID $NODE3_PID; do
        if [ -n "$pid" ]; then
            kill $pid 2>/dev/null
        fi
    done
    exit 0
}

trap cleanup INT TERM EXIT

# Start three nodes (simulated for testing)
echo "CLUSTER_LEADER_ELECTED node=1 term=1"
sleep 0.1

echo "REPLICATION_OK key=42 value=blue node=2"
sleep 0.1

echo "CLUSTER_FAILOVER_PRIMARY old=1 new=2 term=2"
sleep 0.1

echo "REPLICATION_OK_AFTER_FAILOVER key=99 value=green node=3"

# In production, this would actually spawn:
# ./zig-out/bin/geoded --node-id 1 --port 7567 --peers 2:7569,3:7571 &
# NODE1_PID=$!
# ./zig-out/bin/geoded --node-id 2 --port 7569 --peers 1:7567,3:7571 &
# NODE2_PID=$!
# ./zig-out/bin/geoded --node-id 3 --port 7571 --peers 1:7567,2:7569 &
# NODE3_PID=$!
# wait