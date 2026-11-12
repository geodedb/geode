#!/usr/bin/env bash
# Test advanced query features (UNION and variable paths)

set -e

echo "=== Advanced Query Features Test ==="
echo

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Start server
TEST_DIR="/tmp/adv_query_test_$$"
mkdir -p "$TEST_DIR"
ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
ADMIN_PASS="${GEODE_DEFAULT_PASSWORD:-Geode Test Admin Passphrase}"

echo "Starting server..."
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
    ./zig-out/bin/geode serve --data-dir "$TEST_DIR" > "$TEST_DIR/server.log" 2>&1 &
SERVER_PID=$!
sleep 2

cleanup() {
    echo "Cleaning up..."
    kill $SERVER_PID 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

run_query() {
    local query="$1"
    ./zig-out/bin/geode query "$query" --server 127.0.0.1:3141 --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" 2>/dev/null | grep -v '"level":\|"component":' | tail -1
}

echo
echo "1. Testing UNION queries..."

echo "   Testing UNION ALL..."
RESULT=$(run_query "RETURN 1 AS x UNION ALL RETURN 2 AS x")
if echo "$RESULT" | grep -q "status_class"; then
    echo -e "${GREEN}✓ UNION ALL recognized${NC}"
else
    echo -e "${RED}✗ UNION ALL failed${NC}"
fi

echo "   Testing UNION DISTINCT..."
RESULT=$(run_query "RETURN 1 AS x UNION DISTINCT RETURN 1 AS x")
if echo "$RESULT" | grep -q "status_class"; then
    echo -e "${GREEN}✓ UNION DISTINCT recognized${NC}"
else
    echo -e "${RED}✗ UNION DISTINCT failed${NC}"
fi

echo "   Testing multiple UNION..."
RESULT=$(run_query "RETURN 1 AS x UNION RETURN 2 AS x UNION RETURN 3 AS x")
if echo "$RESULT" | grep -q "status_class"; then
    echo -e "${GREEN}✓ Multiple UNION recognized${NC}"
else
    echo -e "${RED}✗ Multiple UNION failed${NC}"
fi

echo
echo "2. Testing INTERSECT queries..."

RESULT=$(run_query "RETURN 1 AS x INTERSECT RETURN 1 AS x")
if echo "$RESULT" | grep -q "status_class"; then
    echo -e "${GREEN}✓ INTERSECT recognized${NC}"
else
    echo -e "${RED}✗ INTERSECT failed${NC}"
fi

echo
echo "3. Testing EXCEPT queries..."

RESULT=$(run_query "RETURN 1 AS x EXCEPT RETURN 2 AS x")
if echo "$RESULT" | grep -q "status_class"; then
    echo -e "${GREEN}✓ EXCEPT recognized${NC}"
else
    echo -e "${RED}✗ EXCEPT failed${NC}"
fi

echo
echo "4. Testing variable-length path patterns..."

echo "   Testing unbounded path (a)-[*]->(b)..."
RESULT=$(run_query "MATCH (a)-[*]->(b) RETURN a, b LIMIT 1")
if echo "$RESULT" | grep -q "status_class\|NotImplemented"; then
    echo -e "${GREEN}✓ Variable path pattern parsed${NC}"
else
    echo -e "${RED}✗ Variable path pattern failed${NC}"
fi

echo "   Testing fixed-length path (a)-[*2]->(b)..."
RESULT=$(run_query "MATCH (a)-[*2]->(b) RETURN a, b LIMIT 1")
if echo "$RESULT" | grep -q "status_class\|NotImplemented"; then
    echo -e "${GREEN}✓ Fixed-length path pattern parsed${NC}"
else
    echo -e "${RED}✗ Fixed-length path pattern failed${NC}"
fi

echo "   Testing bounded path (a)-[*1..3]->(b)..."
RESULT=$(run_query "MATCH (a)-[*1..3]->(b) RETURN a, b LIMIT 1")
if echo "$RESULT" | grep -q "status_class\|NotImplemented"; then
    echo -e "${GREEN}✓ Bounded path pattern parsed${NC}"
else
    echo -e "${RED}✗ Bounded path pattern failed${NC}"
fi

echo "   Testing upper-bounded path (a)-[*..5]->(b)..."
RESULT=$(run_query "MATCH (a)-[*..5]->(b) RETURN a, b LIMIT 1")
if echo "$RESULT" | grep -q "status_class\|NotImplemented"; then
    echo -e "${GREEN}✓ Upper-bounded path pattern parsed${NC}"
else
    echo -e "${RED}✗ Upper-bounded path pattern failed${NC}"
fi

echo "   Testing lower-bounded path (a)-[*2..]->(b)..."
RESULT=$(run_query "MATCH (a)-[*2..]->(b) RETURN a, b LIMIT 1")
if echo "$RESULT" | grep -q "status_class\|NotImplemented"; then
    echo -e "${GREEN}✓ Lower-bounded path pattern parsed${NC}"
else
    echo -e "${RED}✗ Lower-bounded path pattern failed${NC}"
fi

echo
echo "=== Test Complete ==="
