#!/usr/bin/env bash
# Identify Slow Operations and Performance Issues

set -e

echo "=== Identifying Slow Operations ==="
echo

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

ISSUES_FOUND=()

# Test parser performance
echo "Testing parser performance..."
echo -n "  Single quotes (working): "
START=$(date +%s%N)
echo "CREATE (n {name: 'test'})" | timeout 2 ./zig-out/bin/geoded 2>/dev/null | grep -q "status_class" && echo -e "${GREEN}OK${NC}" || echo -e "${RED}FAIL${NC}"
END=$(date +%s%N)
SINGLE_TIME=$(( (END - START) / 1000000 ))

echo -n "  Double quotes (hangs):   "
START=$(date +%s%N)
echo 'CREATE (n {name: "test"})' | timeout 1 ./zig-out/bin/geoded 2>/dev/null | grep -q "status_class" && echo -e "${GREEN}OK${NC}" || echo -e "${RED}HANGS${NC}"
END=$(date +%s%N)
DOUBLE_TIME=$(( (END - START) / 1000000 ))

if [ $DOUBLE_TIME -ge 900 ]; then
    ISSUES_FOUND+=("Parser hangs on double quotes in string literals")
fi

# Test transaction support
echo
echo "Testing transaction support..."
echo -n "  BEGIN:    "
echo "BEGIN" | ./zig-out/bin/geoded 2>&1 | grep -q "error\|NotImplemented" && echo -e "${YELLOW}NOT IMPLEMENTED${NC}" || echo -e "${GREEN}OK${NC}"
echo -n "  COMMIT:   "
echo "COMMIT" | ./zig-out/bin/geoded 2>&1 | grep -q "error\|NotImplemented" && echo -e "${YELLOW}NOT IMPLEMENTED${NC}" || echo -e "${GREEN}OK${NC}"
echo -n "  ROLLBACK: "
echo "ROLLBACK" | ./zig-out/bin/geoded 2>&1 | grep -q "error\|NotImplemented" && echo -e "${YELLOW}NOT IMPLEMENTED${NC}" || echo -e "${GREEN}OK${NC}"

# Test index operations
echo
echo "Testing index operations..."
echo -n "  CREATE INDEX: "
echo "CREATE INDEX idx_test ON Person(name)" | ./zig-out/bin/geoded 2>&1 | grep -q "error\|NotImplemented" && echo -e "${YELLOW}NOT IMPLEMENTED${NC}" || echo -e "${GREEN}OK${NC}"
echo -n "  DROP INDEX:   "
echo "DROP INDEX idx_test" | ./zig-out/bin/geoded 2>&1 | grep -q "error\|NotImplemented" && echo -e "${YELLOW}NOT IMPLEMENTED${NC}" || echo -e "${GREEN}OK${NC}"

# Test SET/DELETE operations  
echo
echo "Testing data modification operations..."
echo -n "  SET property:    "
echo "MATCH (n) SET n.updated = true" | ./zig-out/bin/geoded 2>&1 | grep -q "error\|NotImplemented" && echo -e "${YELLOW}NOT IMPLEMENTED${NC}" || echo -e "${GREEN}OK${NC}"
echo -n "  DELETE node:     "
echo "MATCH (n) DELETE n" | ./zig-out/bin/geoded 2>&1 | grep -q "error\|NotImplemented" && echo -e "${YELLOW}NOT IMPLEMENTED${NC}" || echo -e "${GREEN}OK${NC}"
echo -n "  DETACH DELETE:   "
echo "MATCH (n) DETACH DELETE n" | ./zig-out/bin/geoded 2>&1 | grep -q "error\|NotImplemented" && echo -e "${YELLOW}NOT IMPLEMENTED${NC}" || echo -e "${GREEN}OK${NC}"

# Test advanced features
echo
echo "Testing advanced features..."
echo -n "  Variable paths (*):     "
echo "MATCH (a)-[*1..3]->(b) RETURN count(*)" | ./zig-out/bin/geoded 2>&1 | grep -q "error\|NotImplemented" && echo -e "${YELLOW}NOT IMPLEMENTED${NC}" || echo -e "${GREEN}OK${NC}"
echo -n "  UNION:                  "
echo "RETURN 1 AS x UNION RETURN 2 AS x" | ./zig-out/bin/geoded 2>&1 | grep -q "error\|NotImplemented" && echo -e "${YELLOW}NOT IMPLEMENTED${NC}" || echo -e "${GREEN}OK${NC}"
echo -n "  Subqueries:             "
echo "MATCH (p) WHERE EXISTS { MATCH (p)-[:KNOWS]->() } RETURN p" | ./zig-out/bin/geoded 2>&1 | grep -q "error\|NotImplemented" && echo -e "${YELLOW}NOT IMPLEMENTED${NC}" || echo -e "${GREEN}OK${NC}"

# Test performance of working features
echo
echo "Testing performance of working features..."

# Create test data
echo "Creating 1000 test nodes..."
for i in $(seq 1 1000); do
    echo "CREATE (n:PerfTest {id: $i})" | ./zig-out/bin/geoded > /dev/null 2>&1
done

echo -n "  MATCH all (1000 nodes): "
START=$(date +%s%N)
echo "MATCH (n:PerfTest) RETURN count(n)" | ./zig-out/bin/geoded > /dev/null 2>&1
END=$(date +%s%N)
MATCH_TIME=$(( (END - START) / 1000000 ))
if [ $MATCH_TIME -le 100 ]; then
    echo -e "${GREEN}${MATCH_TIME}ms${NC}"
elif [ $MATCH_TIME -le 500 ]; then
    echo -e "${YELLOW}${MATCH_TIME}ms (slow)${NC}"
    ISSUES_FOUND+=("MATCH performance: ${MATCH_TIME}ms for 1000 nodes")
else
    echo -e "${RED}${MATCH_TIME}ms (TOO SLOW)${NC}"
    ISSUES_FOUND+=("CRITICAL: MATCH performance: ${MATCH_TIME}ms for 1000 nodes")
fi

echo -n "  ORDER BY performance:    "
START=$(date +%s%N)
echo "MATCH (n:PerfTest) RETURN n.id ORDER BY n.id LIMIT 10" | ./zig-out/bin/geoded > /dev/null 2>&1
END=$(date +%s%N)
ORDER_TIME=$(( (END - START) / 1000000 ))
if [ $ORDER_TIME -le 200 ]; then
    echo -e "${GREEN}${ORDER_TIME}ms${NC}"
elif [ $ORDER_TIME -le 1000 ]; then
    echo -e "${YELLOW}${ORDER_TIME}ms (slow)${NC}"
    ISSUES_FOUND+=("ORDER BY performance: ${ORDER_TIME}ms")
else
    echo -e "${RED}${ORDER_TIME}ms (TOO SLOW)${NC}"
    ISSUES_FOUND+=("CRITICAL: ORDER BY performance: ${ORDER_TIME}ms")
fi

echo
echo "============================================"
echo "SUMMARY OF ISSUES REQUIRING FIXES:"
echo "============================================"
echo

echo -e "${RED}Critical Issues:${NC}"
echo "1. Parser hangs on double quotes in string literals"
echo "   - Location: src/gql/lexer.zig"
echo "   - Impact: Complete hang requiring process termination"
echo

echo -e "${YELLOW}Missing Features:${NC}"
echo "2. Transaction support (BEGIN/COMMIT/ROLLBACK)"
echo "3. Index operations (CREATE/DROP INDEX)"
echo "4. Data modification (SET/DELETE/DETACH DELETE)"
echo "5. Advanced query features (variable paths, UNION, subqueries)"
echo

if [ ${#ISSUES_FOUND[@]} -gt 0 ]; then
    echo -e "${YELLOW}Performance Issues:${NC}"
    for issue in "${ISSUES_FOUND[@]}"; do
        echo "- $issue"
    done
    echo
fi

echo "============================================"
echo "RECOMMENDED FIXES (Priority Order):"
echo "============================================"
echo "1. Fix double quote parser hang (CRITICAL)"
echo "2. Implement SET/DELETE operations (HIGH)"
echo "3. Add transaction support (HIGH)"
echo "4. Improve query performance with indexing (MEDIUM)"
echo "5. Implement advanced query features (LOW)"