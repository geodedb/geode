#!/bin/bash
# Test script for Geode Docker deployments

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
MODE="${1:-singleton}"
VERBOSE="${2:-false}"

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Helper functions
log_test() {
    echo -e "${YELLOW}TEST:${NC} $1"
    ((TOTAL_TESTS++))
}

log_pass() {
    echo -e "${GREEN}PASS:${NC} $1"
    ((PASSED_TESTS++))
}

log_fail() {
    echo -e "${RED}FAIL:${NC} $1"
    ((FAILED_TESTS++))
}

# Function to run a query
run_query() {
    local server=$1
    local query=$2
    local container="${3:-geode}"

    if [[ "$VERBOSE" == "true" ]]; then
        docker exec "$container" geode query "$query" --server "$server" 2>&1
    else
        docker exec "$container" geode query "$query" --server "$server" 2>&1 | grep -v debug
    fi
}

# Basic connectivity test
test_basic_connectivity() {
    log_test "Basic connectivity"

    local servers=()
    if [[ "$MODE" == "singleton" ]]; then
        servers=("127.0.0.1:7567")
    else
        servers=("geode-leader:7567" "geode-follower-1:7567" "geode-follower-2:7567")
    fi

    for server in "${servers[@]}"; do
        local container="${server%%:*}"
        if [[ "$MODE" == "singleton" ]]; then
            container="geode"
        fi

        if run_query "$server" "RETURN 1 AS x" "$container" | grep -q '"x":1'; then
            log_pass "Connected to $server"
        else
            log_fail "Failed to connect to $server"
            return 1
        fi
    done
}

# Test ORDER BY and LIMIT
test_order_limit() {
    log_test "ORDER BY and LIMIT"

    local container="geode"
    if [[ "$MODE" == "distributed" ]]; then
        container="geode-leader"
    fi

    local result=$(run_query "127.0.0.1:7567" "RETURN 1 AS x ORDER BY x LIMIT 1" "$container")
    if echo "$result" | grep -q '"ordered":true' && echo "$result" | grep -q '"order_keys":\["x"\]'; then
        log_pass "ORDER BY with LIMIT"
    else
        log_fail "ORDER BY with LIMIT"
        [[ "$VERBOSE" == "true" ]] && echo "$result"
    fi
}

# Test invalid queries
test_invalid_queries() {
    log_test "Invalid query handling"

    local container="geode"
    if [[ "$MODE" == "distributed" ]]; then
        container="geode-leader"
    fi

    # Test LIMIT without ORDER (should fail)
    if run_query "127.0.0.1:7567" "RETURN 1 LIMIT 10 OFFSET 5" "$container" 2>&1 | grep -q "US001"; then
        log_pass "Correctly rejected LIMIT without ORDER"
    else
        log_fail "Failed to reject LIMIT without ORDER"
    fi
}

# Test transactions
test_transactions() {
    log_test "Transaction support"

    local container="geode"
    if [[ "$MODE" == "distributed" ]]; then
        container="geode-leader"
    fi

    # Create a simple transaction test script
    cat > /tmp/txn_test.gql << 'EOF'
BEGIN;
RETURN 1 AS x;
COMMIT;
EOF

    docker cp /tmp/txn_test.gql "$container":/tmp/txn_test.gql

    if docker exec "$container" sh -c "geode query < /tmp/txn_test.gql --server 127.0.0.1:7567" 2>&1 | grep -q '"x":1'; then
        log_pass "Transaction execution"
    else
        log_fail "Transaction execution"
    fi

    rm -f /tmp/txn_test.gql
}

# Test graph operations
test_graph_operations() {
    log_test "Graph operations"

    local container="geode"
    if [[ "$MODE" == "distributed" ]]; then
        container="geode-leader"
    fi

    # Test CREATE
    local create_result=$(run_query "127.0.0.1:7567" "CREATE (:Person {name: 'Alice', age: 30})" "$container" 2>&1)
    if [[ $? -eq 0 ]]; then
        log_pass "CREATE node"
    else
        log_fail "CREATE node"
        [[ "$VERBOSE" == "true" ]] && echo "$create_result"
    fi

    # Test MATCH
    local match_result=$(run_query "127.0.0.1:7567" "MATCH (p:Person) RETURN p.name AS name" "$container" 2>&1)
    if echo "$match_result" | grep -q "Alice"; then
        log_pass "MATCH query"
    else
        log_fail "MATCH query"
        [[ "$VERBOSE" == "true" ]] && echo "$match_result"
    fi
}

# Test distributed features (if applicable)
test_distributed_features() {
    if [[ "$MODE" != "distributed" ]]; then
        return
    fi

    log_test "Distributed features"

    # Test write to leader, read from follower
    run_query "geode-leader:7567" "CREATE (:Test {id: 1})" "geode-leader" >/dev/null 2>&1
    sleep 2 # Allow replication

    local follower_result=$(run_query "geode-follower-1:7567" "MATCH (t:Test) RETURN t.id AS id" "geode-follower-1" 2>&1)
    if echo "$follower_result" | grep -q '"id":1'; then
        log_pass "Replication to follower"
    else
        log_fail "Replication to follower"
        [[ "$VERBOSE" == "true" ]] && echo "$follower_result"
    fi
}

# Performance test
test_performance() {
    log_test "Basic performance"

    local container="geode"
    if [[ "$MODE" == "distributed" ]]; then
        container="geode-leader"
    fi

    # Run a simple benchmark
    local start=$(date +%s%N)
    for i in {1..100}; do
        run_query "127.0.0.1:7567" "RETURN $i AS x" "$container" >/dev/null 2>&1
    done
    local end=$(date +%s%N)

    local duration=$(( (end - start) / 1000000 ))
    local qps=$(( 100000 / duration ))

    echo "  100 queries in ${duration}ms (~${qps} QPS)"

    if [[ $duration -lt 10000 ]]; then
        log_pass "Performance test (${duration}ms for 100 queries)"
    else
        log_fail "Performance test (${duration}ms for 100 queries, expected < 10000ms)"
    fi
}

# Main test execution
main() {
    echo -e "${GREEN}=== Geode Docker Tests ($MODE mode) ===${NC}"
    echo ""

    # Check if containers are running
    if [[ "$MODE" == "singleton" ]]; then
        if ! docker ps | grep -q "geode-singleton"; then
            echo -e "${RED}Geode singleton container is not running${NC}"
            echo "Run: ./scripts/docker/deploy.sh -m singleton -a up"
            exit 1
        fi
    else
        if ! docker ps | grep -q "geode-leader"; then
            echo -e "${RED}Geode distributed cluster is not running${NC}"
            echo "Run: ./scripts/docker/deploy.sh -m distributed -a up"
            exit 1
        fi
    fi

    # Run tests
    test_basic_connectivity
    test_order_limit
    test_invalid_queries
    test_transactions
    # test_graph_operations  # Uncomment when graph operations are fully implemented
    test_distributed_features
    test_performance

    # Summary
    echo ""
    echo -e "${GREEN}=== Test Summary ===${NC}"
    echo "Total tests: $TOTAL_TESTS"
    echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
    echo -e "${RED}Failed: $FAILED_TESTS${NC}"

    if [[ $FAILED_TESTS -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed${NC}"
        exit 1
    fi
}

# Run main function
main
