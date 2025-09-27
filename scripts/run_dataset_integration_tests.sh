#!/bin/bash
# Run integration tests for the social network dataset across all clients
# This script loads the dataset and runs tests for each client implementation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
HOST="${GEODE_HOST:-127.0.0.1}"
PORT="${GEODE_PORT:-8443}"
DATA_DIR="${GEODE_DATA_DIR:-./test_data}"
GEODEC="./zig-out/bin/geodec"
GEODED="./zig-out/bin/geoded"

# Test results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

echo -e "${BLUE}=== Geode Dataset Integration Tests ===${NC}"
echo "Host: $HOST:$PORT"
echo "Data directory: $DATA_DIR"
echo ""

# Function to run a query and check result
run_test_query() {
    local test_name=$1
    local query=$2
    local expected_pattern=$3
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    echo -n "  Testing $test_name... "
    
    result=$($GEODEC --host "$HOST" --port "$PORT" "$query" 2>&1 || true)
    
    if echo "$result" | grep -q "$expected_pattern"; then
        echo -e "${GREEN}✓${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        echo -e "${RED}✗${NC}"
        echo "    Expected pattern: $expected_pattern"
        echo "    Got: $(echo "$result" | head -1)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# Function to load migrations
load_migrations() {
    echo -e "${YELLOW}Loading dataset migrations...${NC}"
    
    local migrations=(
        "migrations/001_social_network_schema.gql"
        "migrations/002_social_network_data.gql"
        "migrations/003_social_network_relationships.gql"
        "migrations/004_social_network_events_products.gql"
    )
    
    for migration in "${migrations[@]}"; do
        echo "  Loading $(basename "$migration")..."
        if [ -f "$migration" ]; then
            # Execute migration file
            if $GEODEC --host "$HOST" --port "$PORT" < "$migration" > /dev/null 2>&1; then
                echo -e "    ${GREEN}✓${NC} Loaded successfully"
            else
                echo -e "    ${RED}✗${NC} Failed to load"
                return 1
            fi
        else
            echo -e "    ${YELLOW}⚠${NC} File not found"
        fi
    done
    
    return 0
}

# Start server if not running
echo -e "${YELLOW}Checking Geode server...${NC}"
if ! $GEODEC --host "$HOST" --port "$PORT" "RETURN 1" > /dev/null 2>&1; then
    echo "  Starting Geode server..."
    rm -rf "$DATA_DIR"
    mkdir -p "$DATA_DIR"
    $GEODED --data_dir "$DATA_DIR" --port "$PORT" > /tmp/geode_test.log 2>&1 &
    SERVER_PID=$!
    echo "  Server PID: $SERVER_PID"
    
    # Wait for server to start
    for i in {1..10}; do
        if $GEODEC --host "$HOST" --port "$PORT" "RETURN 1" > /dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} Server ready"
            break
        fi
        sleep 1
    done
    
    # Ensure we kill the server on exit
    trap "kill $SERVER_PID 2>/dev/null || true" EXIT
else
    echo -e "  ${GREEN}✓${NC} Server already running"
fi

# Load the dataset
echo ""
if ! load_migrations; then
    echo -e "${RED}Failed to load migrations${NC}"
    exit 1
fi

# Run integration tests
echo ""
echo -e "${BLUE}Running integration tests...${NC}"

# Test 1: Basic connectivity and node count
echo -e "\n${YELLOW}1. Basic Dataset Tests${NC}"
run_test_query "Node count" \
    "MATCH (n) RETURN count(n) AS count" \
    '"count"'

run_test_query "Edge count" \
    "MATCH ()-[r]->() RETURN count(r) AS count" \
    '"count"'

run_test_query "User verification" \
    "MATCH (u:User {id: 'user-1'}) RETURN u.username, u.verified" \
    '"alice_j".*true'

# Test 2: Network Types
echo -e "\n${YELLOW}2. Network Type Tests${NC}"
run_test_query "IP private check" \
    "MATCH (u:User {id: 'user-1'}) RETURN ip_is_private(u.ip_address) AS is_private" \
    'true'

run_test_query "Subnet containment" \
    "MATCH (d:Device {id: 'device-1'}) RETURN ip_contains(d.subnet, d.ip_address) AS contained" \
    'true'

run_test_query "MAC vendor OUI" \
    "MATCH (d:Device {id: 'device-1'}) RETURN d.mac_address" \
    'a1:b2:c3:d4:e5:f6'

# Test 3: Geographic Types
echo -e "\n${YELLOW}3. Geographic Type Tests${NC}"
run_test_query "Distance calculation" \
    "MATCH (l1:Location {name: 'San Francisco'}), (l2:Location {name: 'New York'}) RETURN distance_haversine(l1.coordinates, l2.coordinates) AS distance" \
    'distance'

run_test_query "Spatial query" \
    "MATCH (e:Event) WHERE distance_haversine(e.location, LatLon(37.7749, -122.4194)) < 100000 RETURN count(e) AS nearby" \
    'nearby'

# Test 4: Vector Similarity
echo -e "\n${YELLOW}4. Vector Similarity Tests${NC}"
run_test_query "Vector similarity search" \
    "MATCH (p1:Post {id: 'post-1'}), (p2:Post) WHERE p1 <> p2 AND vector_cosine_similarity(p1.content_vector, p2.content_vector) > 0.5 RETURN count(p2) AS similar" \
    'similar'

# Test 5: Currency Types
echo -e "\n${YELLOW}5. Currency Type Tests${NC}"
run_test_query "Currency retrieval" \
    "MATCH (c:Company {id: 'comp-1'}) RETURN c.revenue" \
    'USD'

# Test 6: Graph Traversals
echo -e "\n${YELLOW}6. Graph Traversal Tests${NC}"
run_test_query "Follow relationships" \
    "MATCH (u:User)-[:FOLLOWS]->(u2:User {id: 'user-3'}) RETURN count(u) AS followers" \
    'followers'

run_test_query "Post engagement" \
    "MATCH (u:User {id: 'user-1'})-[:POSTED]->(p:Post) RETURN count(p) AS posts" \
    'posts'

run_test_query "Event attendance" \
    "MATCH (u:User)-[:ATTENDING]->(e:Event {id: 'event-1'}) RETURN count(u) AS attendees" \
    'attendees'

run_test_query "Company investments" \
    "MATCH (c:Company)-[:INVESTED_IN]->(c2:Company) RETURN count(c) AS investors" \
    'investors'

# Test 7: Constraints
echo -e "\n${YELLOW}7. Constraint Tests${NC}"
# This should fail due to unique constraint
if $GEODEC --host "$HOST" --port "$PORT" \
    "CREATE (:User {id: 'test-dup', email: 'alice.johnson@example.com', username: 'test'})" \
    > /dev/null 2>&1; then
    echo -e "  Testing unique constraint... ${RED}✗${NC} (constraint not enforced)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
else
    echo -e "  Testing unique constraint... ${GREEN}✓${NC}"
    PASSED_TESTS=$((PASSED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test 8: Transactions
echo -e "\n${YELLOW}8. Transaction Tests${NC}"
$GEODEC --host "$HOST" --port "$PORT" "BEGIN" > /dev/null 2>&1
$GEODEC --host "$HOST" --port "$PORT" "CREATE (:TestNode {id: 'tx-test'})" > /dev/null 2>&1
$GEODEC --host "$HOST" --port "$PORT" "ROLLBACK" > /dev/null 2>&1

run_test_query "Transaction rollback" \
    "MATCH (n:TestNode {id: 'tx-test'}) RETURN count(n) AS count" \
    '"count":0'

# Test 9: Test Go client if available
if [ -d "clients/go/gql" ]; then
    echo -e "\n${YELLOW}9. Go Client Tests${NC}"
    cd clients/go/gql
    if go test -v -run TestDataset -count=1 > /tmp/go_test_output.txt 2>&1; then
        echo -e "  Go client tests... ${GREEN}✓${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "  Go client tests... ${RED}✗${NC}"
        echo "    See /tmp/go_test_output.txt for details"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    cd - > /dev/null
fi

# Test 10: Test Zig client if available
if [ -f "clients/zig/client.zig" ]; then
    echo -e "\n${YELLOW}10. Zig Client Tests${NC}"
    if zig test clients/zig/client.zig > /tmp/zig_test_output.txt 2>&1; then
        echo -e "  Zig client tests... ${GREEN}✓${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "  Zig client tests... ${RED}✗${NC}"
        echo "    See /tmp/zig_test_output.txt for details"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
fi

# Summary
echo ""
echo -e "${BLUE}=== Test Summary ===${NC}"
echo "Total tests: $TOTAL_TESTS"
echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
echo -e "Failed: ${RED}$FAILED_TESTS${NC}"

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "\n${RED}Some tests failed.${NC}"
    exit 1
fi