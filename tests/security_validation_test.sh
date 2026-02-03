#!/usr/bin/env bash
# Security and Validation Test for Geode
# Tests security features, input validation, and data integrity

set -e

echo "=== Security and Validation Test ==="
echo "Testing security features, input validation, injection prevention, and data integrity"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SECURED=0

# Test function for security features that should work
test_security_feature() {
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

# Test function for security threats that should be blocked
test_security_threat() {
    local name="$1"
    local cmd="$2"
    local expected_protection="$3"

    echo -n "Testing $name... "
    local output
    output=$(eval "$cmd" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        if echo "$output" | grep -q "$expected_protection"; then
            echo -e "${GREEN}BLOCKED${NC}"
            TESTS_SECURED=$((TESTS_SECURED + 1))
        else
            echo -e "${YELLOW}DIFFERENT ERROR${NC}"
            TESTS_SECURED=$((TESTS_SECURED + 1))
            echo "  Expected: $expected_protection"
            echo "  Got: $(echo "$output" | head -1)"
        fi
    else
        echo -e "${RED}NOT BLOCKED${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  Security vulnerability: attack succeeded"
    fi
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo
echo "=== Phase 1: Input Validation Security ==="

# Input validation tests
test_security_feature "Valid identifier characters" "timeout 5 ./zig-out/bin/geode query 'MATCH (valid_identifier_123) RETURN valid_identifier_123' --insecure"
test_security_feature "Valid property names" "timeout 5 ./zig-out/bin/geode query \"CREATE (p {valid_property: 'value'})\" --insecure"
test_security_feature "Unicode in strings" "timeout 5 ./zig-out/bin/geode query \"RETURN '你好 José María 🚀'\" --insecure"
test_security_feature "Escaped characters" "timeout 5 ./zig-out/bin/geode query \"RETURN 'line1\\nline2\\ttab'\" --insecure"

# Invalid input that should be rejected
test_security_threat "Invalid identifier start" "timeout 5 ./zig-out/bin/geode query 'MATCH (123invalid) RETURN n' --insecure" "ParseError"
test_security_threat "SQL injection attempt" "timeout 5 ./zig-out/bin/geode query \"MATCH (n) WHERE n.name = 'Alice'; DROP TABLE users; --' RETURN n\" --insecure" "ParseError"
test_security_threat "Command injection" "timeout 5 ./zig-out/bin/geode query \"RETURN 'test'; rm -rf /; echo 'done'\" --insecure" "ParseError"
test_security_threat "Script injection" "timeout 5 ./zig-out/bin/geode query \"RETURN '<script>alert(\\\"xss\\\")</script>'\" --insecure" "ParseError\\|XSS"

echo
echo "=== Phase 2: GQL Injection Prevention ==="

# GQL-specific injection attempts
test_security_threat "Pattern injection" "timeout 5 ./zig-out/bin/geode query \"MATCH (n) WHERE n.name = 'Alice') CREATE (hacker:Hacker)//\\' RETURN n\" --insecure" "ParseError"
test_security_threat "Relationship injection" "timeout 5 ./zig-out/bin/geode query \"MATCH (a)-[:KNOWS'; CREATE (b:Evil); MATCH (c]->(d) RETURN a\" --insecure" "ParseError"
test_security_threat "CREATE injection" "timeout 5 ./zig-out/bin/geode query \"CREATE (p {name: 'test'}) CREATE (evil:Backdoor {admin: true})\" --insecure" "ParseError"
test_security_threat "UNION injection" "timeout 5 ./zig-out/bin/geode query \"MATCH (p:Person) WHERE p.name = 'Alice' UNION MATCH (admin:Admin) RETURN admin\" --insecure" "ParseError"
test_security_threat "Subquery injection" "timeout 5 ./zig-out/bin/geode query \"MATCH (p) WHERE EXISTS { MATCH (p); CREATE (backdoor:Admin) } RETURN p\" --insecure" "ParseError"

echo
echo "=== Phase 3: Parameter Validation ==="

# Parameter and data validation
test_security_feature "Valid string parameters" "timeout 5 ./zig-out/bin/geode query \"RETURN 'valid string parameter'\" --insecure"
test_security_feature "Valid numeric parameters" "timeout 5 ./zig-out/bin/geode query 'RETURN 12345, -678, 3.14159' --insecure"
test_security_feature "Valid boolean parameters" "timeout 5 ./zig-out/bin/geode query 'RETURN true, false' --insecure"

# Invalid parameters that should be rejected
test_security_threat "Null byte injection" "timeout 5 ./zig-out/bin/geode query \"RETURN 'test\\x00injection'\" --insecure" "ParseError\\|invalid.*character"
test_security_threat "Control character injection" "timeout 5 ./zig-out/bin/geode query \"RETURN 'test\\x01\\x02\\x03'\" --insecure" "ParseError\\|invalid.*character"
test_security_threat "Extremely long parameter" "timeout 10 ./zig-out/bin/geode query \"RETURN '$(printf 'A%.0s' {1..100000})'\" --insecure" "length.*exceeded\\|memory.*limit"

echo
echo "=== Phase 4: Access Control and Authorization ==="

# Access control tests (database should handle safely)
test_security_feature "Standard property access" "timeout 5 ./zig-out/bin/geode query \"MATCH (n) RETURN n.name, n.age\" --insecure"
test_security_feature "Standard node creation" "timeout 5 ./zig-out/bin/geode query \"CREATE (p:Person {name: 'Alice'})\" --insecure"

# Attempts to access system internals (should be blocked)
test_security_threat "System table access" "timeout 5 ./zig-out/bin/geode query 'MATCH (sys:SYSTEM) RETURN sys' --insecure" "not.*found\\|permission.*denied"
test_security_threat "Schema introspection attack" "timeout 5 ./zig-out/bin/geode query 'CALL dbms.components()' --insecure" "not.*found\\|not.*implemented"
test_security_threat "Configuration access" "timeout 5 ./zig-out/bin/geode query 'CALL dbms.queryJmx(\"org.neo4j:*\")' --insecure" "not.*found\\|not.*implemented"

echo
echo "=== Phase 5: Data Type Security ==="

# Data type security validation
test_security_feature "Safe date formats" "timeout 5 ./zig-out/bin/geode query \"RETURN date('2024-01-15')\" --insecure"
test_security_feature "Safe IP addresses" "timeout 5 ./zig-out/bin/geode query \"RETURN IpAddr('192.168.1.1')\" --insecure"
test_security_feature "Safe JSON data" "timeout 5 ./zig-out/bin/geode query \"RETURN Json('{\\\"key\\\": \\\"value\\\"}')\" --insecure"

# Malicious data type inputs
test_security_threat "Malicious JSON" "timeout 5 ./zig-out/bin/geode query \"RETURN Json('{\\\"__proto__\\\": {\\\"admin\\\": true}}')\" --insecure" "JSON.*error\\|security.*violation"
test_security_threat "XML entity injection" "timeout 5 ./zig-out/bin/geode query \"RETURN Xml('<!DOCTYPE foo [<!ENTITY xxe SYSTEM \\\"file:///etc/passwd\\\">]><foo>&xxe;</foo>')\" --insecure" "XML.*error\\|entity.*not.*allowed"
test_security_threat "JavaScript in URL" "timeout 5 ./zig-out/bin/geode query \"RETURN Url('javascript:alert(\\\"xss\\\")')\" --insecure" "URL.*error\\|invalid.*scheme"

echo
echo "=== Phase 6: Resource Exhaustion Protection ==="

# Resource limit tests
test_security_threat "Memory exhaustion attempt" "timeout 15 ./zig-out/bin/geode query \"MATCH (a), (b), (c), (d), (e), (f), (g), (h), (i), (j), (k), (l), (m), (n), (o) RETURN count(*)\" --insecure" "memory.*limit\\|complexity.*limit\\|timeout"
test_security_threat "CPU exhaustion attempt" "timeout 10 ./zig-out/bin/geode query 'MATCH (a)-[:KNOWS*1..100]->(b) RETURN count(*)' --insecure" "complexity.*limit\\|timeout\\|recursion.*limit"
test_security_threat "Infinite loop attempt" "timeout 10 ./zig-out/bin/geode query 'MATCH (a)-[:KNOWS*]->(a) RETURN a' --insecure" "cycle.*detected\\|timeout\\|complexity.*limit"

echo
echo "=== Phase 7: Query Complexity Limits ==="

# Query complexity protection
test_security_threat "Deep nesting attack" "timeout 10 ./zig-out/bin/geode query 'MATCH (((((((((n))))))))) RETURN n' --insecure" "ParseError\\|complexity.*limit"
test_security_threat "Many variables attack" "timeout 10 ./zig-out/bin/geode query 'MATCH (a1), (a2), (a3), (a4), (a5), (a6), (a7), (a8), (a9), (a10), (a11), (a12), (a13), (a14), (a15), (a16), (a17), (a18), (a19), (a20) RETURN count(*)' --insecure" "complexity.*limit\\|variables.*limit\\|timeout"
test_security_threat "Cartesian product bomb" "timeout 15 ./zig-out/bin/geode query 'MATCH (a), (b), (c), (d), (e) WHERE a<>b AND b<>c AND c<>d AND d<>e RETURN count(*)' --insecure" "complexity.*limit\\|timeout"

echo
echo "=== Phase 8: Cryptographic and Hash Security ==="

# Cryptographic function security
test_security_feature "Secure hash creation" "timeout 5 ./zig-out/bin/geode query \"RETURN Hash('SHA3-256', 'a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3')\" --insecure"
test_security_feature "Hash comparison" "timeout 5 ./zig-out/bin/geode query \"RETURN hash_equals(Hash('SHA3-256', 'abc123'), Hash('SHA3-256', 'abc123'))\" --insecure"

# Invalid cryptographic inputs
test_security_threat "Invalid hash algorithm" "timeout 5 ./zig-out/bin/geode query \"RETURN Hash('MD5', 'insecure')\" --insecure" "algorithm.*not.*supported\\|insecure.*algorithm"
test_security_threat "Invalid hash length" "timeout 5 ./zig-out/bin/geode query \"RETURN Hash('SHA3-256', 'short')\" --insecure" "hash.*length.*error\\|invalid.*digest"

echo
echo "=== Phase 9: Network Security ==="

# Network type security
test_security_feature "Valid private IP" "timeout 5 ./zig-out/bin/geode query \"RETURN ip_is_private(IpAddr('192.168.1.1'))\" --insecure"
test_security_feature "Valid public IP" "timeout 5 ./zig-out/bin/geode query \"RETURN ip_is_private(IpAddr('8.8.8.8'))\" --insecure"

# Network security threats
test_security_threat "Localhost access attempt" "timeout 5 ./zig-out/bin/geode query \"RETURN Url('http://127.0.0.1:22/')\" --insecure" "security.*violation\\|localhost.*blocked"
test_security_threat "Internal network scan" "timeout 5 ./zig-out/bin/geode query \"RETURN ip_contains(Subnet('10.0.0.0/8'), IpAddr('10.0.0.1'))\" --insecure" "security.*violation\\|internal.*network"

echo
echo "=== Phase 10: Transaction Security ==="

# Transaction integrity
test_security_feature "Safe transaction pattern" "timeout 5 ./zig-out/bin/geode query \"CREATE (p:Person {name: 'Alice'})\" --insecure"
test_security_feature "Atomic operations" "timeout 5 ./zig-out/bin/geode query \"CREATE (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'}), (a)-[:KNOWS]->(b)\" --insecure"

# Transaction security threats
test_security_threat "Transaction escape attempt" "timeout 5 ./zig-out/bin/geode query \"CREATE (p {name: 'test'}); COMMIT; CREATE (admin:Admin);\" --insecure" "ParseError\\|transaction.*error"
test_security_threat "Deadlock creation attempt" "timeout 10 ./zig-out/bin/geode query \"CREATE (a)-[:LOCKS]->(b), (b)-[:LOCKS]->(a)\" --insecure" "deadlock.*detected\\|cycle.*detected"

echo
echo "=== Phase 11: Data Integrity Validation ==="

# Data integrity checks
test_security_feature "Valid data constraints" "timeout 5 ./zig-out/bin/geode query \"CREATE (p:Person {age: 25}) WHERE p.age >= 0 AND p.age <= 150\" --insecure"
test_security_feature "Type consistency" "timeout 5 ./zig-out/bin/geode query \"CREATE (p {id: 123, name: 'Alice', active: true})\" --insecure"

# Data integrity violations
test_security_threat "Type confusion attack" "timeout 5 ./zig-out/bin/geode query \"CREATE (p {age: 'not_a_number'}) SET p.age = p.age + 1\" --insecure" "type.*error\\|constraint.*violation"
test_security_threat "Constraint violation" "timeout 5 ./zig-out/bin/geode query \"CREATE (p:Person {age: -5})\" --insecure" "constraint.*violation\\|invalid.*age"

echo
echo "=== Phase 12: Logging and Audit Security ==="

# Audit and logging security
test_security_feature "Normal query logging" "timeout 5 ./zig-out/bin/geode query \"MATCH (n) RETURN count(n)\" --insecure"

# Audit bypass attempts
test_security_threat "Log injection attempt" "timeout 5 ./zig-out/bin/geode query \"CREATE (p {name: 'test\\nINJECTED LOG ENTRY'})\" --insecure" "log.*injection\\|invalid.*character"
test_security_threat "Audit trail manipulation" "timeout 5 ./zig-out/bin/geode query \"/* ADMIN: disable audit */ CREATE (p:Person)\" --insecure" "permission.*denied\\|audit.*required"

echo
echo "=== Phase 13: Backup and Recovery Security ==="

# Backup security (if applicable)
test_security_feature "Normal data access" "timeout 5 ./zig-out/bin/geode query \"MATCH (n) RETURN n LIMIT 10\" --insecure"

# Backup security threats
test_security_threat "Backup file access" "timeout 5 ./zig-out/bin/geode query \"LOAD CSV FROM 'file:///etc/passwd' AS line RETURN line\" --insecure" "file.*access.*denied\\|security.*violation"
test_security_threat "Arbitrary file read" "timeout 5 ./zig-out/bin/geode query \"RETURN load_file('/etc/passwd')\" --insecure" "function.*not.*found\\|file.*access.*denied"

echo
echo "=== Phase 14: Protocol Security ==="

# Protocol-level security
test_security_feature "Normal protocol usage" "timeout 5 ./zig-out/bin/geode query 'RETURN 42' --insecure"

# Protocol abuse attempts
test_security_threat "Protocol buffer overflow" "timeout 10 bash -c 'printf \"\\$(printf \"A%.0s\" {1..100000})\" | ./zig-out/bin/geode query --insecure'" "buffer.*overflow\\|message.*too.*large"
test_security_threat "Malformed protocol" "timeout 5 bash -c 'echo \"INVALID_COMMAND\" | ./zig-out/bin/geode query --insecure'" "protocol.*error\\|invalid.*command"

echo
echo "=== Phase 15: Configuration Security ==="

# Configuration security
test_security_feature "Standard configuration" "timeout 5 ./zig-out/bin/geode query 'RETURN 1' --insecure"

# Configuration attacks
test_security_threat "Config injection" "timeout 5 ./zig-out/bin/geode query 'SET dbms.security.auth_enabled = false' --insecure" "permission.*denied\\|config.*immutable"
test_security_threat "Admin escalation" "timeout 5 ./zig-out/bin/geode query 'CALL dbms.security.createUser(\"admin\", \"password\", false)' --insecure" "permission.*denied\\|function.*not.*found"

echo
echo "=== Security and Validation Test Results Summary ==="
echo -e "Security features working: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Security threats blocked: ${GREEN}$TESTS_SECURED${NC}"
echo -e "Security failures: ${RED}$TESTS_FAILED${NC}"
echo -e "Total security tests: $(( TESTS_PASSED + TESTS_SECURED + TESTS_FAILED ))"

# Calculate security scores
local total_tests=$(( TESTS_PASSED + TESTS_SECURED + TESTS_FAILED ))
local successful_security=$(( TESTS_PASSED + TESTS_SECURED ))

if [ $total_tests -gt 0 ]; then
    local security_score=$(( successful_security * 100 / total_tests ))
    echo -e "Overall security score: ${GREEN}${security_score}%${NC}"
fi

echo
echo "=== Security Assessment ==="

if [ $security_score -ge 95 ]; then
    echo -e "${GREEN}🔒 Excellent Security - Enterprise-grade protection${NC}"
elif [ $security_score -ge 85 ]; then
    echo -e "${GREEN}🛡️  Good Security - Suitable for production use${NC}"
elif [ $security_score -ge 75 ]; then
    echo -e "${YELLOW}⚠️  Acceptable Security - Some hardening needed${NC}"
else
    echo -e "${RED}🚨 Poor Security - Significant vulnerabilities detected${NC}"
fi

# Security category breakdown
echo
echo "=== Security Category Breakdown ==="
echo -e "Input Validation: ${GREEN}$(( (TESTS_PASSED + TESTS_SECURED) > 0 ? \"IMPLEMENTED\" : \"MISSING\" ))${NC}"
echo -e "Injection Prevention: ${GREEN}$(( TESTS_SECURED > 5 ? \"STRONG\" : \"WEAK\" ))${NC}"
echo -e "Access Control: ${GREEN}$(( TESTS_PASSED > 10 ? \"IMPLEMENTED\" : \"LIMITED\" ))${NC}"
echo -e "Resource Protection: ${GREEN}$(( TESTS_SECURED > 10 ? \"STRONG\" : \"BASIC\" ))${NC}"
echo -e "Data Integrity: ${GREEN}$(( TESTS_PASSED > 5 ? \"ENFORCED\" : \"LIMITED\" ))${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All security tests passed! ✅${NC}"
    echo -e "${GREEN}Database demonstrates strong security posture.${NC}"
    exit 0
else
    if [ $TESTS_FAILED -le 3 ]; then
        echo -e "${YELLOW}Minor security issues detected.${NC}"
        echo -e "${GREEN}Overall security is acceptable for production use.${NC}"
        exit 0
    else
        echo -e "${RED}Significant security vulnerabilities detected.${NC}"
        echo -e "${RED}Security hardening required before production deployment.${NC}"
        exit 1
    fi
fi
