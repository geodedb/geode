#!/usr/bin/env bash
# Error Handling and Edge Cases Test for Geode
# Tests error conditions, boundary cases, and robustness

set -e

echo "=== Error Handling and Edge Cases Test ==="
echo "Testing error conditions, boundary cases, and database robustness"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_ERROR_HANDLED=0

# Test function for expected errors
test_error() {
    local name="$1"
    local cmd="$2"
    local expected_error="$3"
    
    echo -n "Testing $name... "
    local output
    output=$(eval "$cmd" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        if echo "$output" | grep -q "$expected_error"; then
            echo -e "${GREEN}CORRECTLY HANDLED${NC}"
            TESTS_ERROR_HANDLED=$((TESTS_ERROR_HANDLED + 1))
        else
            echo -e "${YELLOW}WRONG ERROR${NC}"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            echo "  Expected: $expected_error"
            echo "  Got: $(echo "$output" | head -1)"
        fi
    else
        echo -e "${RED}SHOULD HAVE FAILED${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Test function for edge cases that should work
test_edge_case() {
    local name="$1"
    local cmd="$2"
    
    echo -n "Testing $name... "
    if eval "$cmd" > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo
echo "=== Phase 1: Syntax Error Handling ==="

# Invalid syntax should produce parse errors
test_error "Missing RETURN" "timeout 5 ./zig-out/bin/geodec 'MATCH (n)' --no-quic" "ParseError"
test_error "Invalid identifier" "timeout 5 ./zig-out/bin/geodec 'MATCH (123abc) RETURN n' --no-quic" "ParseError"
test_error "Unclosed parentheses" "timeout 5 ./zig-out/bin/geodec 'MATCH (n RETURN n' --no-quic" "ParseError"
test_error "Invalid relationship" "timeout 5 ./zig-out/bin/geodec 'MATCH (a)-->(b) RETURN a, b' --no-quic" "ParseError"
test_error "Invalid property syntax" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) WHERE n. = 5 RETURN n' --no-quic" "ParseError"
test_error "Missing semicolon (multi-statement)" "timeout 5 ./zig-out/bin/geodec 'CREATE (a) CREATE (b)' --no-quic" "ParseError"

echo
echo "=== Phase 2: Type Mismatch Errors ==="

# Type mismatches should be caught
test_error "String + Number" "timeout 5 ./zig-out/bin/geodec \"RETURN 'hello' + 5\" --no-quic" "TypeError\\|type.*error"
test_error "Boolean arithmetic" "timeout 5 ./zig-out/bin/geodec 'RETURN true * 5' --no-quic" "TypeError\\|type.*error"
test_error "Invalid comparison" "timeout 5 ./zig-out/bin/geodec \"RETURN 'abc' > 123\" --no-quic" "TypeError\\|type.*error"
test_error "Function wrong argument type" "timeout 5 ./zig-out/bin/geodec \"RETURN sqrt('invalid')\" --no-quic" "TypeError\\|type.*error"

echo
echo "=== Phase 3: Mathematical Error Conditions ==="

# Mathematical errors
test_error "Division by zero" "timeout 5 ./zig-out/bin/geodec 'RETURN 10 / 0' --no-quic" "division.*zero\\|DIV_ZERO"
test_error "Square root negative" "timeout 5 ./zig-out/bin/geodec 'RETURN sqrt(-1)' --no-quic" "domain.*error\\|MATH_DOMAIN"
test_error "Logarithm of zero" "timeout 5 ./zig-out/bin/geodec 'RETURN log(0)' --no-quic" "domain.*error\\|MATH_DOMAIN"
test_error "Integer overflow" "timeout 5 ./zig-out/bin/geodec 'RETURN 9223372036854775807 + 1' --no-quic" "overflow"

echo
echo "=== Phase 4: Date and Time Error Conditions ==="

# Invalid date/time formats
test_error "Invalid date format" "timeout 5 ./zig-out/bin/geodec \"RETURN date('2024-13-45')\" --no-quic" "date.*error\\|invalid.*date"
test_error "Invalid time format" "timeout 5 ./zig-out/bin/geodec \"RETURN time('25:99:99')\" --no-quic" "time.*error\\|invalid.*time"
test_error "February 30th" "timeout 5 ./zig-out/bin/geodec \"RETURN date('2024-02-30')\" --no-quic" "date.*error\\|invalid.*date"
test_error "Invalid timestamp" "timeout 5 ./zig-out/bin/geodec \"RETURN timestamp('invalid-timestamp')\" --no-quic" "timestamp.*error"

echo
echo "=== Phase 5: Network Type Error Conditions ==="

# Invalid network addresses
test_error "Invalid IP address" "timeout 5 ./zig-out/bin/geodec \"RETURN IpAddr('999.999.999.999')\" --no-quic" "IP.*error\\|invalid.*IP"
test_error "Invalid IPv6" "timeout 5 ./zig-out/bin/geodec \"RETURN IpAddr('gggg::hhhh')\" --no-quic" "IP.*error\\|invalid.*IP"
test_error "Invalid CIDR" "timeout 5 ./zig-out/bin/geodec \"RETURN Subnet('192.168.1.1/99')\" --no-quic" "CIDR.*error\\|invalid.*subnet"
test_error "Invalid MAC address" "timeout 5 ./zig-out/bin/geodec \"RETURN Mac('GG:HH:II:JJ:KK:LL')\" --no-quic" "MAC.*error\\|invalid.*MAC"

echo
echo "=== Phase 6: JSON and Data Format Errors ==="

# Invalid structured data
test_error "Invalid JSON syntax" "timeout 5 ./zig-out/bin/geodec \"RETURN Json('{invalid json}')\" --no-quic" "JSON.*error\\|invalid.*JSON"
test_error "Invalid XML" "timeout 5 ./zig-out/bin/geodec \"RETURN Xml('<unclosed><tag>')\" --no-quic" "XML.*error\\|invalid.*XML"
test_error "Invalid URL" "timeout 5 ./zig-out/bin/geodec \"RETURN Url('not-a-url')\" --no-quic" "URL.*error\\|invalid.*URL"
test_error "Invalid UUID" "timeout 5 ./zig-out/bin/geodec \"RETURN UUID('not-a-uuid')\" --no-quic" "UUID.*error\\|invalid.*UUID"

echo
echo "=== Phase 7: Constraint Violation Errors ==="

# Constraint violations
test_error "String too long for CHAR" "timeout 5 ./zig-out/bin/geodec \"RETURN Char('this string is way too long', 5)\" --no-quic" "CHAR_LEN\\|length.*exceeded"
test_error "VARCHAR length exceeded" "timeout 5 ./zig-out/bin/geodec \"RETURN Varchar('very long string', 3)\" --no-quic" "CHAR_LEN\\|length.*exceeded"
test_error "Invalid currency code" "timeout 5 ./zig-out/bin/geodec \"RETURN Currency('INVALID')\" --no-quic" "currency.*error\\|invalid.*currency"

echo
echo "=== Phase 8: Query Semantic Errors ==="

# Semantic errors in queries
test_error "Undefined variable" "timeout 5 ./zig-out/bin/geodec 'MATCH (a) RETURN b' --no-quic" "undefined\\|not.*defined"
test_error "Aggregation without GROUP BY" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n.name, count(n)' --no-quic" "aggregation.*error\\|group.*by"
test_error "Invalid ORDER BY" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n.name ORDER BY undefined_var' --no-quic" "undefined\\|not.*defined"
test_error "LIMIT without ORDER BY" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n LIMIT 5 OFFSET 10' --no-quic" "US001\\|unordered.*pagination"

echo
echo "=== Phase 9: Graph Structure Errors ==="

# Graph structure issues
test_error "Self-referential CREATE" "timeout 5 ./zig-out/bin/geodec 'CREATE (a)-[:KNOWS]->(a)-[:KNOWS]->(a)' --no-quic" "cycle\\|self.*reference" "fail"
test_error "Dangling relationship" "timeout 5 ./zig-out/bin/geodec 'CREATE ()-[:ORPHAN]->()' --no-quic" "ParseError" "fail"

echo
echo "=== Phase 10: Boundary Value Testing ==="

# Boundary values that should work
test_edge_case "Empty string" "timeout 5 ./zig-out/bin/geodec \"RETURN ''\" --no-quic"
test_edge_case "Zero value" "timeout 5 ./zig-out/bin/geodec 'RETURN 0' --no-quic"
test_edge_case "Negative number" "timeout 5 ./zig-out/bin/geodec 'RETURN -999' --no-quic"
test_edge_case "Very small float" "timeout 5 ./zig-out/bin/geodec 'RETURN 0.000000001' --no-quic"
test_edge_case "Boolean false" "timeout 5 ./zig-out/bin/geodec 'RETURN false' --no-quic"
test_edge_case "NULL value" "timeout 5 ./zig-out/bin/geodec 'RETURN null' --no-quic"

echo
echo "=== Phase 11: Large Data Edge Cases ==="

# Large data that should work
test_edge_case "Long string" "timeout 10 ./zig-out/bin/geodec \"RETURN 'abcdefghijklmnopqrstuvwxyz0123456789'\" --no-quic"
test_edge_case "Large number" "timeout 5 ./zig-out/bin/geodec 'RETURN 999999999999999' --no-quic"
test_edge_case "Many properties" "timeout 10 ./zig-out/bin/geodec \"CREATE (p {a:1, b:2, c:3, d:4, e:5, f:6, g:7, h:8, i:9, j:10})\" --no-quic"

echo
echo "=== Phase 12: Unicode and Character Edge Cases ==="

# Unicode and special characters
test_edge_case "Unicode characters" "timeout 5 ./zig-out/bin/geodec \"RETURN '你好世界 🌍 José María'\" --no-quic"
test_edge_case "Special characters" "timeout 5 ./zig-out/bin/geodec \"RETURN '!@#\$%^&*()_+-=[]{}|;:,.<>?'\" --no-quic"
test_edge_case "Newlines in strings" "timeout 5 ./zig-out/bin/geodec \"RETURN 'line1\\nline2\\ttab'\" --no-quic"
test_edge_case "Escaped quotes" "timeout 5 ./zig-out/bin/geodec \"RETURN 'don\\'t'\" --no-quic"

echo
echo "=== Phase 13: Performance Edge Cases ==="

# Performance boundary testing
test_edge_case "Large LIMIT" "timeout 10 ./zig-out/bin/geodec 'MATCH (n) RETURN n ORDER BY n LIMIT 999999' --no-quic"
test_edge_case "Complex WHERE clause" "timeout 10 ./zig-out/bin/geodec \"MATCH (n) WHERE n.a > 0 AND n.b < 100 AND n.c = 'test' AND n.d IS NOT NULL RETURN n\" --no-quic"
test_edge_case "Deep property access" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) RETURN n.level1.level2.level3\" --no-quic"

echo
edge_case "Concurrent patterns" "timeout 15 bash -c 'for i in {1..3}; do ./zig-out/bin/geodec \"CREATE (p\$i:Person {id: \$i})\" --no-quic > /dev/null 2>&1 & done; wait'"

echo
echo "=== Phase 14: Resource Exhaustion Testing ==="

# Resource limits (should handle gracefully)
test_error "Extremely long string" "timeout 10 ./zig-out/bin/geodec \"RETURN '$(printf 'a%.0s' {1..100000})'\" --no-quic" "length.*exceeded\\|memory.*limit\\|timeout"
test_error "Deep recursion" "timeout 10 ./zig-out/bin/geodec 'MATCH (a)-[:KNOWS*50..100]->(b) RETURN a, b' --no-quic" "recursion.*limit\\|timeout\\|complexity"
test_error "Many variables" "timeout 10 ./zig-out/bin/geodec 'MATCH (a1), (a2), (a3), (a4), (a5), (a6), (a7), (a8), (a9), (a10), (a11), (a12), (a13), (a14), (a15) RETURN a1' --no-quic" "complexity\\|variables.*limit\\|timeout"

echo
echo "=== Phase 15: Injection and Security Edge Cases ==="

# SQL/GQL injection attempts (should be safely handled)
test_edge_case "Quoted property names" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.\\\`weird name\\\` = 'test' RETURN n\" --no-quic"
test_edge_case "Property with spaces" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {\\\`full name\\\`: 'John Doe'})\" --no-quic"
test_edge_case "Semicolon in string" "timeout 5 ./zig-out/bin/geodec \"RETURN 'text; with; semicolons'\" --no-quic"
test_edge_case "Comment-like strings" "timeout 5 ./zig-out/bin/geodec \"RETURN '// this looks like a comment'\" --no-quic"

echo
echo "=== Phase 16: Database State Edge Cases ==="

# Edge cases with database state
test_edge_case "Query empty database" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN count(n)' --no-quic"
test_edge_case "Aggregation on empty result" "timeout 5 ./zig-out/bin/geodec 'MATCH (n:NonExistent) RETURN count(n), avg(n.value)' --no-quic"
test_edge_case "Order by non-existent property" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n ORDER BY n.nonexistent_property' --no-quic"

echo
echo "=== Error Handling and Edge Cases Test Results Summary ==="
echo -e "Errors correctly handled: ${GREEN}$TESTS_ERROR_HANDLED${NC}"
echo -e "Edge cases passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Unexpected failures: ${RED}$TESTS_FAILED${NC}"
echo -e "Total tests: $(( TESTS_ERROR_HANDLED + TESTS_PASSED + TESTS_FAILED ))"

# Calculate scores
local total_tests=$(( TESTS_ERROR_HANDLED + TESTS_PASSED + TESTS_FAILED ))
local successful_tests=$(( TESTS_ERROR_HANDLED + TESTS_PASSED ))

if [ $total_tests -gt 0 ]; then
    local robustness_score=$(( successful_tests * 100 / total_tests ))
    echo -e "Database robustness score: ${GREEN}${robustness_score}%${NC}"
fi

echo
echo "=== Robustness Assessment ==="

if [ $robustness_score -ge 90 ]; then
    echo -e "${GREEN}Excellent robustness! Database handles errors and edge cases very well.${NC}"
elif [ $robustness_score -ge 80 ]; then
    echo -e "${GREEN}Good robustness. Database handles most error conditions correctly.${NC}"
elif [ $robustness_score -ge 70 ]; then
    echo -e "${YELLOW}Acceptable robustness. Some error handling could be improved.${NC}"
else
    echo -e "${RED}Poor robustness. Significant error handling issues detected.${NC}"
fi

if [ $TESTS_FAILED -le 5 ]; then
    echo -e "${GREEN}Error handling is within acceptable limits.${NC}"
    exit 0
else
    echo -e "${RED}Too many error handling failures. Database stability may be compromised.${NC}"
    exit 1
fi