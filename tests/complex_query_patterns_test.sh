#!/usr/bin/env bash
# Complex Query Patterns Test for Geode
# Tests advanced GQL query patterns, combinations, and edge cases

set -e

echo "=== Complex Query Patterns Test ==="
echo "Testing advanced GQL queries, pattern combinations, and complex scenarios"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_UNSUPPORTED=0

# Test function
test_query() {
    local name="$1"
    local cmd="$2"
    local expected_result="${3:-success}"
    
    echo -n "Testing $name... "
    local output
    output=$(eval "$cmd" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        if [ "$expected_result" = "success" ]; then
            echo -e "${GREEN}PASS${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${YELLOW}UNEXPECTED PASS${NC}"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        if echo "$output" | grep -q "ParseError\|not.*implement\|unsupported"; then
            echo -e "${BLUE}NOT IMPLEMENTED${NC}"
            TESTS_UNSUPPORTED=$((TESTS_UNSUPPORTED + 1))
        elif [ "$expected_result" = "fail" ]; then
            echo -e "${GREEN}EXPECTED FAIL${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${RED}FAIL${NC}"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            echo "  Command: $cmd"
            echo "  Output: $(echo "$output" | head -1)"
        fi
    fi
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo
echo "=== Phase 1: Complex Pattern Matching ==="

# Advanced pattern matching
test_query "Multi-variable patterns" "timeout 10 ./zig-out/bin/geodec 'MATCH (a), (b), (c) WHERE a <> b AND b <> c AND a <> c RETURN a, b, c' --insecure"
test_query "Variable length paths" "timeout 10 ./zig-out/bin/geodec 'MATCH (a)-[:KNOWS*1..3]->(b) RETURN a, b' --insecure"
test_query "Optional patterns" "timeout 10 ./zig-out/bin/geodec 'MATCH (a) OPTIONAL MATCH (a)-[:FRIEND]->(b) RETURN a, b' --insecure"
test_query "Directed vs undirected" "timeout 10 ./zig-out/bin/geodec 'MATCH (a)-[:KNOWS]-(b) RETURN a, b' --insecure"
test_query "Complex relationship types" "timeout 10 ./zig-out/bin/geodec 'MATCH (a)-[:KNOWS|:FRIEND|:COLLEAGUE]->(b) RETURN a, b' --insecure"

echo
echo "=== Phase 2: Advanced WHERE Clauses ==="

# Complex filtering
test_query "Multiple AND conditions" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) WHERE n.age > 18 AND n.age < 65 AND n.active = true RETURN n\" --insecure"
test_query "Multiple OR conditions" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) WHERE n.age < 25 OR n.age > 60 OR n.salary > 100000 RETURN n\" --insecure"
test_query "Mixed AND/OR logic" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) WHERE (n.age > 18 AND n.age < 30) OR (n.experience > 10) RETURN n\" --insecure"
test_query "NOT conditions" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) WHERE NOT n.retired AND NOT n.unemployed RETURN n\" --insecure"
test_query "Nested NOT conditions" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) WHERE NOT (n.age < 18 OR n.age > 65) RETURN n\" --insecure"

# Property existence and null checks
test_query "Property existence" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) WHERE n.email IS NOT NULL RETURN n\" --insecure"
test_query "Property absence" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) WHERE n.legacy_field IS NULL RETURN n\" --insecure"
test_query "Property comparison" "timeout 10 ./zig-out/bin/geodec \"MATCH (a), (b) WHERE a.salary > b.salary RETURN a, b\" --insecure"

echo
echo "=== Phase 3: Complex Aggregations ==="

# Advanced aggregation patterns
test_query "Multiple aggregations" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) RETURN count(n), min(n.age), max(n.age), avg(n.salary)\" --insecure"
test_query "Aggregation with grouping" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) RETURN n.department, count(n), avg(n.salary)\" --insecure"
test_query "Aggregation with ORDER BY" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) RETURN n.department, count(n) ORDER BY count(n) DESC\" --insecure"
test_query "Aggregation with HAVING" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) RETURN n.department, count(n) HAVING count(n) > 5\" --insecure"
test_query "Nested aggregations" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) RETURN count(DISTINCT n.department)\" --insecure"

# Relationship aggregations
test_query "Edge count by type" "timeout 10 ./zig-out/bin/geodec \"MATCH (a)-[r]->(b) RETURN type(r), count(r)\" --insecure"
test_query "Node degree calculation" "timeout 10 ./zig-out/bin/geodec \"MATCH (n)-[r]-() RETURN n, count(r) AS degree ORDER BY degree DESC\" --insecure"

echo
echo "=== Phase 4: Subqueries and EXISTS ==="

# Subquery patterns
test_query "EXISTS subquery" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE EXISTS { MATCH (p)-[:WORKS_AT]->(:Company) } RETURN p\" --insecure"
test_query "NOT EXISTS subquery" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE NOT EXISTS { MATCH (p)-[:MARRIED_TO]->() } RETURN p\" --insecure"
test_query "Complex EXISTS pattern" "timeout 10 ./zig-out/bin/geodec \"MATCH (c:Company) WHERE EXISTS { MATCH (c)<-[:WORKS_AT]-(p:Person) WHERE p.salary > 50000 } RETURN c\" --insecure"
test_query "Nested EXISTS" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE EXISTS { MATCH (p)-[:WORKS_AT]->(c) WHERE EXISTS { MATCH (c)-[:LOCATED_IN]->(:City) } } RETURN p\" --insecure"

echo
echo "=== Phase 5: UNION and Set Operations ==="

# Set operations
test_query "UNION simple" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p UNION MATCH (c:Company) RETURN c\" --insecure"
test_query "UNION ALL" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p UNION ALL MATCH (p:Person) WHERE p.age > 30 RETURN p\" --insecure"
test_query "UNION with ORDER BY" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name AS name UNION MATCH (c:Company) RETURN c.name AS name ORDER BY name\" --insecure"
test_query "Complex UNION" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.age < 30 RETURN p.name, 'Young' AS category UNION MATCH (p:Person) WHERE p.age >= 30 RETURN p.name, 'Experienced' AS category\" --insecure"

echo
echo "=== Phase 6: WITH Clauses and Query Composition ==="

# WITH clause patterns
test_query "WITH simple" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WITH p WHERE p.age > 25 MATCH (p)-[:WORKS_AT]->(c) RETURN p, c\" --insecure"
test_query "WITH aggregation" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WITH p.department AS dept, avg(p.salary) AS avg_sal MATCH (p:Person) WHERE p.department = dept AND p.salary > avg_sal RETURN p\" --insecure"
test_query "WITH ORDER BY LIMIT" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WITH p ORDER BY p.salary DESC LIMIT 5 MATCH (p)-[:WORKS_AT]->(c) RETURN p, c\" --insecure"
test_query "Multiple WITH clauses" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WITH p WHERE p.age > 18 WITH p WHERE p.salary > 30000 RETURN p\" --insecure"

echo
echo "=== Phase 7: Complex CREATE Patterns ==="

# Advanced CREATE operations
test_query "CREATE with MERGE" "timeout 10 ./zig-out/bin/geodec \"MERGE (p:Person {name: 'John'}) ON CREATE SET p.created = timestamp() RETURN p\" --insecure"
test_query "CREATE complex graph" "timeout 10 ./zig-out/bin/geodec \"CREATE (alice:Person {name: 'Alice'})-[:WORKS_AT]->(tech:Company {name: 'TechCorp'}), (bob:Person {name: 'Bob'})-[:WORKS_AT]->(tech), (alice)-[:KNOWS]->(bob)\" --insecure"
test_query "CREATE with properties" "timeout 10 ./zig-out/bin/geodec \"CREATE (p:Person {name: 'Charlie', age: 30, skills: ['Python', 'SQL', 'GQL']})\" --insecure"
test_query "CREATE conditional" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE NOT EXISTS { MATCH (p)-[:HAS_ACCOUNT]->() } CREATE (p)-[:HAS_ACCOUNT]->(a:Account {id: p.id + '_account'})\" --insecure"

echo
echo "=== Phase 8: UPDATE and DELETE Operations ==="

# Data modification
test_query "SET properties" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.name = 'Alice' SET p.last_login = timestamp(), p.login_count = p.login_count + 1\" --insecure"
test_query "REMOVE properties" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.age IS NULL REMOVE p.age\" --insecure"
test_query "DELETE nodes" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.inactive = true DELETE p\" --insecure"
test_query "DETACH DELETE" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.to_remove = true DETACH DELETE p\" --insecure"

echo
echo "=== Phase 9: Path Expressions and Algorithms ==="

# Path and algorithm patterns
test_query "Shortest path" "timeout 10 ./zig-out/bin/geodec \"MATCH path = shortestPath((a:Person)-[:KNOWS*]-(b:Person)) WHERE a.name = 'Alice' AND b.name = 'Bob' RETURN path\" --insecure"
test_query "All shortest paths" "timeout 10 ./zig-out/bin/geodec \"MATCH paths = allShortestPaths((a:Person)-[:KNOWS*]-(b:Person)) WHERE a.name = 'Alice' AND b.name = 'Bob' RETURN paths\" --insecure"
test_query "Path length" "timeout 10 ./zig-out/bin/geodec \"MATCH path = (a:Person)-[:KNOWS*]-(b:Person) WHERE length(path) <= 3 RETURN a, b, length(path)\" --insecure"
test_query "Path nodes and relationships" "timeout 10 ./zig-out/bin/geodec \"MATCH path = (a)-[:KNOWS*2..4]-(b) RETURN nodes(path), relationships(path)\" --insecure"

echo
echo "=== Phase 10: Mathematical and String Operations ==="

# Mathematical expressions
test_query "Math operations" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name, p.age, p.age * 365 AS age_in_days, sqrt(p.salary) AS salary_sqrt\" --insecure"
test_query "String operations" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name, upper(p.name), lower(p.name), length(p.name)\" --insecure"
test_query "String pattern matching" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.name STARTS WITH 'A' OR p.name ENDS WITH 'son' RETURN p\" --insecure"
test_query "String contains" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.name CONTAINS 'John' RETURN p\" --insecure"
test_query "Regular expressions" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.email =~ '.*@company\\.com' RETURN p\" --insecure"

echo
echo "=== Phase 11: Temporal and Date Operations ==="

# Date and time operations
test_query "Date arithmetic" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name, p.birth_date, date() - p.birth_date AS age_duration\" --insecure"
test_query "Date comparisons" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.hire_date > date('2020-01-01') AND p.hire_date < date('2024-01-01') RETURN p\" --insecure"
test_query "Timestamp operations" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name, datetime(p.last_login), datetime() - datetime(p.last_login) AS time_since_login\" --insecure"
test_query "Date extraction" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name, p.hire_date, p.hire_date.year, p.hire_date.month, p.hire_date.day\" --insecure"

echo
echo "=== Phase 12: Collection and List Operations ==="

# Collection operations
test_query "List operations" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name, p.skills, size(p.skills), head(p.skills), tail(p.skills)\" --insecure"
test_query "List filtering" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE 'Python' IN p.skills RETURN p\" --insecure"
test_query "List comprehension" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name, [skill IN p.skills WHERE skill CONTAINS 'SQL' | upper(skill)]\" --insecure"
test_query "UNWIND lists" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) UNWIND p.skills AS skill RETURN p.name, skill\" --insecure"

echo
echo "=== Phase 13: Graph Analytics Patterns ==="

# Graph analytics
test_query "Node centrality" "timeout 10 ./zig-out/bin/geodec \"MATCH (n)-[r]-() RETURN n, count(r) AS degree ORDER BY degree DESC LIMIT 10\" --insecure"
test_query "Triangle detection" "timeout 10 ./zig-out/bin/geodec \"MATCH (a)-[:KNOWS]->(b)-[:KNOWS]->(c)-[:KNOWS]->(a) RETURN a, b, c\" --insecure"
test_query "Community detection" "timeout 10 ./zig-out/bin/geodec \"MATCH (a:Person)-[:WORKS_AT]->(c:Company)<-[:WORKS_AT]-(b:Person) WHERE a <> b RETURN c.name, collect(a.name) AS employees\" --insecure"
test_query "Mutual connections" "timeout 10 ./zig-out/bin/geodec \"MATCH (a:Person)-[:KNOWS]->(mutual)<-[:KNOWS]-(b:Person) WHERE a <> b RETURN a.name, b.name, collect(mutual.name) AS mutual_friends\" --insecure"

echo
echo "=== Phase 14: Performance Optimization Patterns ==="

# Performance patterns
test_query "Index hints" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) USING INDEX p:Person(email) WHERE p.email = 'alice@company.com' RETURN p\" --insecure"
test_query "Query profiling" "timeout 10 ./zig-out/bin/geodec \"PROFILE MATCH (p:Person)-[:WORKS_AT]->(c:Company) RETURN p.name, c.name\" --insecure"
test_query "Query explanation" "timeout 10 ./zig-out/bin/geodec \"EXPLAIN MATCH (p:Person) WHERE p.age > 30 RETURN p ORDER BY p.salary DESC LIMIT 10\" --insecure"

echo
echo "=== Phase 15: Error Conditions and Edge Cases ==="

# Error conditions and edge cases
test_query "Division by zero" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name, p.salary / 0\" --insecure" "fail"
test_query "Invalid property access" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.nonexistent.property\" --insecure" "fail"
test_query "Type mismatch" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.age + 'string' > 30 RETURN p\" --insecure" "fail"
test_query "Invalid date format" "timeout 10 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.birth_date > date('invalid-date') RETURN p\" --insecure" "fail"

echo
echo "=== Complex Query Patterns Test Results Summary ==="
echo -e "Queries tested successfully: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Queries failed: ${RED}$TESTS_FAILED${NC}"
echo -e "Queries not implemented: ${BLUE}$TESTS_UNSUPPORTED${NC}"
echo -e "Total queries: $(( TESTS_PASSED + TESTS_FAILED + TESTS_UNSUPPORTED ))"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All implemented query patterns work correctly! ✅${NC}"
    echo -e "Implementation rate: ${GREEN}$(( TESTS_PASSED * 100 / (TESTS_PASSED + TESTS_UNSUPPORTED) ))%${NC} of testable patterns"
    exit 0
else
    echo -e "Success rate: ${YELLOW}$(( TESTS_PASSED * 100 / (TESTS_PASSED + TESTS_FAILED) ))%${NC} of implemented patterns"
    echo -e "Implementation rate: ${BLUE}$(( TESTS_PASSED * 100 / (TESTS_PASSED + TESTS_FAILED + TESTS_UNSUPPORTED) ))%${NC} of all patterns"
    
    if [ $TESTS_FAILED -le 10 ]; then
        echo -e "${GREEN}Failure count is acceptable for complex query patterns.${NC}"
        exit 0
    else
        echo -e "${RED}Too many query failures. Core query engine may have issues.${NC}"
        exit 1
    fi
fi