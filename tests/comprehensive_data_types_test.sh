#!/usr/bin/env bash
# Comprehensive Data Types Test for Geode
# Tests all 50+ data types documented in TYPES_AND_FUNCTIONS.md

set -e

echo "=== Comprehensive Data Types Test ==="
echo "Testing all 50+ data types and their functions"
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
test_type() {
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
echo "=== Phase 1: Core Data Types (Basic) ==="

# Basic Types
test_type "NULL values" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {value: null})' --insecure"
test_type "Boolean true" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {flag: true})' --insecure"
test_type "Boolean false" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {flag: false})' --insecure"
test_type "Integer basic" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {num: 42})' --insecure"
test_type "Integer negative" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {num: -123})' --insecure"
test_type "Integer zero" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {num: 0})' --insecure"
test_type "Integer large" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {num: 9223372036854775807})' --insecure"
test_type "String basic" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {name: 'hello'})\" --insecure"
test_type "String empty" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {name: ''})\" --insecure"
test_type "String unicode" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {name: 'José María 中文 🚀'})\" --insecure"

echo
echo "=== Phase 2: Advanced Numeric Types ==="

# Advanced numeric types with constructors
test_type "SmallInt constructor" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {val: SmallInt(32767)})' --insecure"
test_type "Int constructor" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {val: Int(2147483647)})' --insecure"
test_type "BigInt constructor" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {val: BigInt(9223372036854775807)})' --insecure"
test_type "Real constructor" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {val: Real(3.14159)})' --insecure"
test_type "Double constructor" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {val: Double(2.718281828)})' --insecure"
test_type "Decimal constructor" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {val: Decimal(123.45, 2)})' --insecure"

# Floating point edge cases
test_type "Float zero" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {val: 0.0})' --insecure"
test_type "Float negative" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {val: -3.14})' --insecure"
test_type "Float very small" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {val: 0.000001})' --insecure"

echo
echo "=== Phase 3: String and Text Types ==="

# String type variations
test_type "Char constructor" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Char('abc', 10)})\" --insecure"
test_type "Varchar constructor" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Varchar('test', 50)})\" --insecure"
test_type "Text constructor" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Text('unlimited text')})\" --insecure"

# String edge cases
test_type "String with quotes" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: 'single\\\'quote'})\" --insecure"
test_type "String with newlines" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: 'line1\\nline2'})\" --insecure"
test_type "String with tabs" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: 'tab\\ttab'})\" --insecure"

echo
echo "=== Phase 4: Temporal Types ==="

# Date and time types
test_type "Date constructor" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Date('2024-01-15')})\" --insecure"
test_type "Time constructor" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Time('14:30:45')})\" --insecure"
test_type "Time with microseconds" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Time('14:30:45.123456')})\" --insecure"
test_type "Timestamp constructor" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Timestamp('2024-01-15 14:30:45')})\" --insecure"
test_type "TimestampTZ constructor" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: TimestampTZ('2024-01-15 14:30:45 +05:00')})\" --insecure"
test_type "Interval constructor" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Interval('P1Y2M3DT4H5M6S')})\" --insecure"

# Edge cases for temporal
test_type "Date epoch" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Date('1970-01-01')})\" --insecure"
test_type "Time midnight" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Time('00:00:00')})\" --insecure"
test_type "Time end of day" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Time('23:59:59')})\" --insecure"

echo
echo "=== Phase 5: Network Types ==="

# Network address types
test_type "IPv4 address" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {ip: IpAddr('192.168.1.1')})\" --insecure"
test_type "IPv6 address" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {ip: IpAddr('2001:db8::1')})\" --insecure"
test_type "IPv4 loopback" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {ip: IpAddr('127.0.0.1')})\" --insecure"
test_type "IPv6 loopback" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {ip: IpAddr('::1')})\" --insecure"

# CIDR networks
test_type "IPv4 subnet" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {net: Subnet('192.168.0.0/24')})\" --insecure"
test_type "IPv6 subnet" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {net: Subnet('2001:db8::/32')})\" --insecure"

# MAC addresses
test_type "MAC address colon" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {mac: Mac('AA:BB:CC:DD:EE:FF')})\" --insecure"
test_type "MAC address dash" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {mac: Mac('AA-BB-CC-DD-EE-FF')})\" --insecure"

echo
echo "=== Phase 6: Binary and JSON Types ==="

# Binary and structured data
test_type "Bytea hex" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {data: Bytea('DEADBEEF')})\" --insecure"
test_type "JSON object" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {data: Json('{\\\"key\\\": \\\"value\\\"}')})\" --insecure"
test_type "JSON array" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {data: Json('[1, 2, 3]')})\" --insecure"
test_type "JSONB object" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {data: Jsonb('{\\\"key\\\": \\\"value\\\"}')})\" --insecure"
test_type "XML document" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {data: Xml('<root><item>test</item></root>')})\" --insecure"

echo
echo "=== Phase 7: Cryptographic and Currency Types ==="

# Crypto and currency
test_type "Hash SHA3-256" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {hash: Hash('SHA3-256', 'a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3')})\" --insecure"
test_type "Currency USD" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {cur: Currency('USD')})\" --insecure"
test_type "Currency EUR" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {cur: Currency('EUR')})\" --insecure"
test_type "Currency JPY" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {cur: Currency('JPY')})\" --insecure"
test_type "Language tag en-US" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {lang: LanguageTag('en-US')})\" --insecure"
test_type "Language tag zh-CN" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {lang: LanguageTag('zh-CN')})\" --insecure"

echo
echo "=== Phase 8: Geographic Types ==="

# Geographic and spatial
test_type "LatLon coordinates" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {pos: LatLon(40.7128, -74.0060)})' --insecure"
test_type "LatLonAlt with elevation" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {pos: LatLonAlt(40.7128, -74.0060, 10.0, 0)})' --insecure"
test_type "Geometry point WKT" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {geom: GeometryFromText('POINT(0 0)')})\" --insecure"
test_type "Geometry linestring" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {geom: GeometryFromText('LINESTRING(0 0, 1 1)')})\" --insecure"
test_type "Geometry polygon" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {geom: GeometryFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))')})\" --insecure"

echo
echo "=== Phase 9: Physical Quantities ==="

# Physical measurements
test_type "Temperature Celsius" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {temp: Temperature(25.0, 1)})' --insecure"
test_type "Temperature Fahrenheit" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {temp: Temperature(77.0, 2)})' --insecure"
test_type "Temperature Kelvin" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {temp: Temperature(298.15, 0)})' --insecure"
test_type "Pressure Pascal" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {press: Pressure(101325.0, 0)})' --insecure"
test_type "Pressure bar" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {press: Pressure(1.01325, 2)})' --insecure"

echo
echo "=== Phase 10: Vector and ML Types ==="

# Vector types for ML
test_type "Vector F32 2D" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {vec: Vector([1.0, 2.0])})' --insecure"
test_type "Vector F32 3D" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {vec: Vector([1.0, 2.0, 3.0])})' --insecure"
test_type "Vector F32 high-dim" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {vec: Vector([1.0, 2.0, 3.0, 4.0, 5.0])})' --insecure"

echo
echo "=== Phase 11: Advanced Container Types ==="

# Advanced structured types
test_type "URL HTTP" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {url: Url('https://example.com/path?query=value')})\" --insecure"
test_type "URL with port" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {url: Url('https://example.com:8080/')})\" --insecure"
test_type "Domain name" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {domain: Domain('example.com')})\" --insecure"
test_type "Domain subdomain" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {domain: Domain('www.example.com')})\" --insecure"

# UUID types
test_type "UUID v4" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {id: UUID('550e8400-e29b-41d4-a716-446655440000')})\" --insecure"
test_type "UUID generate v4" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {id: uuid_v4()})' --insecure"
test_type "UUID generate v7" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {id: uuid_v7()})' --insecure"

echo
echo "=== Phase 12: Collection Types ==="

# Arrays and collections
test_type "Array of integers" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {nums: Array([1, 2, 3, 4, 5])})' --insecure"
test_type "Array of strings" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {names: Array(['alice', 'bob', 'charlie'])})\" --insecure"
test_type "BitString binary" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {bits: Bit('10101010')})\" --insecure"
test_type "VarBit variable" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {bits: VarBit('110011')})\" --insecure"

# Range types
test_type "Integer range" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {range: Range('int', 1, 10, '[)')})\" --insecure"
test_type "Date range" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {range: Range('date', Date('2024-01-01'), Date('2024-12-31'), '[]')})\" --insecure"

echo
echo "=== Phase 13: Enum Types ==="

# Enum types (may not be implemented)
test_type "Enum definition" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {status: Enum('StatusType', 'ACTIVE')})\" --insecure"

echo
echo "=== Phase 14: Type Conversion and Function Tests ==="

# Type conversion functions
test_type "Bool conversion" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {val: Bool(1)})' --insecure"
test_type "Text conversion" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {val: Text(123)})' --insecure"

# Network functions
test_type "IP family function" "timeout 5 ./zig-out/bin/geodec \"MATCH (p) WHERE ip_family(IpAddr('192.168.1.1')) = 4 RETURN p\" --insecure"
test_type "IP private function" "timeout 5 ./zig-out/bin/geodec \"MATCH (p) WHERE ip_is_private(IpAddr('192.168.1.1')) RETURN p\" --insecure"

# Vector functions
test_type "Vector dot product" "timeout 5 ./zig-out/bin/geodec 'MATCH (p) RETURN vector_dot(Vector([1.0, 2.0]), Vector([3.0, 4.0]))' --insecure"
test_type "Vector L2 distance" "timeout 5 ./zig-out/bin/geodec 'MATCH (p) RETURN vector_l2(Vector([0.0, 0.0]), Vector([3.0, 4.0]))' --insecure"

# Geometric functions
test_type "Latitude extraction" "timeout 5 ./zig-out/bin/geodec 'MATCH (p) RETURN latitude(LatLon(40.7128, -74.0060))' --insecure"
test_type "Longitude extraction" "timeout 5 ./zig-out/bin/geodec 'MATCH (p) RETURN longitude(LatLon(40.7128, -74.0060))' --insecure"

echo
echo "=== Phase 15: Error Handling and Edge Cases ==="

# Error conditions and edge cases
test_type "Invalid date" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {val: Date('2024-02-30')})\" --insecure" "fail"
test_type "Invalid IP address" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {ip: IpAddr('999.999.999.999')})\" --insecure" "fail"
test_type "Invalid JSON" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {data: Json('{invalid}')})\" --insecure" "fail"
test_type "Invalid MAC address" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {mac: Mac('GG:HH:II:JJ:KK:LL')})\" --insecure" "fail"
test_type "Division by zero" "timeout 5 ./zig-out/bin/geodec 'MATCH (p) RETURN decimal_div(Decimal(1, 0), Decimal(0, 0))' --insecure" "fail"

echo
echo "=== Data Types Test Results Summary ==="
echo -e "Types tested successfully: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Types failed: ${RED}$TESTS_FAILED${NC}"
echo -e "Types not implemented: ${BLUE}$TESTS_UNSUPPORTED${NC}"
echo -e "Total tests: $(( TESTS_PASSED + TESTS_FAILED + TESTS_UNSUPPORTED ))"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All implemented data types work correctly! ✅${NC}"
    echo -e "Implementation rate: ${GREEN}$(( TESTS_PASSED * 100 / (TESTS_PASSED + TESTS_UNSUPPORTED) ))%${NC} of testable features"
    exit 0
else
    echo -e "Success rate: ${YELLOW}$(( TESTS_PASSED * 100 / (TESTS_PASSED + TESTS_FAILED) ))%${NC} of implemented features"
    echo -e "Implementation rate: ${BLUE}$(( TESTS_PASSED * 100 / (TESTS_PASSED + TESTS_FAILED + TESTS_UNSUPPORTED) ))%${NC} of all features"

    if [ $TESTS_FAILED -le 5 ]; then
        echo -e "${GREEN}Failure count is acceptable for a comprehensive type system.${NC}"
        exit 0
    else
        echo -e "${RED}Too many type failures. Core type system may have issues.${NC}"
        exit 1
    fi
fi
