#!/usr/bin/env bash

# CANARY: REQ=REQ-CLI-ROUTE-001; FEATURE="Query Option Auto-routing"; ASPECT=CommandDispatch; STATUS=TESTED; TEST=TestCANARY_REQ_CLI_ROUTE_001_OptionRouting; OWNER=cli; UPDATED=2025-10-04

set -e

echo "=== Query Option Auto-routing Regression Tests ==="

GEODE_BIN="./zig-out/bin/geode"

# Test 1: --format flag auto-routing
echo "Test 1: --format flag auto-routing"
result=$($GEODE_BIN --format json "RETURN 'format_test' AS test" --insecure 2>/dev/null | grep '"test":"format_test"' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: --format flag should auto-route to query command"
    exit 1
fi
echo "PASS: --format flag auto-routing"

# Test 2: --server flag auto-routing
echo "Test 2: --server flag auto-routing"
result=$($GEODE_BIN --server localhost:8443 "RETURN 'server_test' AS test" --insecure 2>/dev/null | grep '"test":"server_test"' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: --server flag should auto-route to query command"
    exit 1
fi
echo "PASS: --server flag auto-routing"

# Test 3: --page-size flag auto-routing
echo "Test 3: --page-size flag auto-routing"
result=$($GEODE_BIN --page-size 100 "RETURN 'page_test' AS test" --insecure 2>/dev/null | grep '"test":"page_test"' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: --page-size flag should auto-route to query command"
    exit 1
fi
echo "PASS: --page-size flag auto-routing"

# Test 4: --json-param flag auto-routing
echo "Test 4: --json-param flag auto-routing"
result=$($GEODE_BIN --json-param test_param test_value "RETURN 'json_param_test' AS test" --insecure 2>/dev/null | grep '"test":"json_param_test"' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: --json-param flag should auto-route to query command"
    exit 1
fi
echo "PASS: --json-param flag auto-routing"

# Test 5: Multiple query flags auto-routing
echo "Test 5: Multiple query flags auto-routing"
result=$($GEODE_BIN --format json --page-size 50 "RETURN 'multi_flag_test' AS test" --insecure 2>/dev/null | grep '"test":"multi_flag_test"' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: Multiple query flags should auto-route to query command"
    exit 1
fi
echo "PASS: Multiple query flags auto-routing"

# Test 6: Query flags mixed with GQL keywords
echo "Test 6: Query flags mixed with GQL keywords"
result=$($GEODE_BIN --format table "MATCH (n) RETURN count(n) AS node_count" --insecure 2>/dev/null | grep '"node_count"' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: Query flags with MATCH keyword should work"
    exit 1
fi
echo "PASS: Query flags mixed with GQL keywords"

# Test 7: Non-query flags should not auto-route
echo "Test 7: Non-query flags should not auto-route"
result=$($GEODE_BIN --unknown-flag 2>&1 | grep "unknown option" || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: Unknown flags should show 'unknown option' error"
    exit 1
fi
echo "PASS: Non-query flags do not auto-route"

# Test 8: Global flags should not auto-route to query
echo "Test 8: Global flags should not auto-route"
# --help should show main help, not query help
result=$($GEODE_BIN --help 2>&1 | grep "Property graph database" || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: --help should show main help, not query help"
    exit 1
fi
echo "PASS: Global flags do not auto-route"

# Test 9: Query options with embedded server
echo "Test 9: Query options with embedded server"
result=$($GEODE_BIN --format json "CREATE (n:AutoRoute {test: 'embedded'}) RETURN n" --insecure 2>/dev/null | grep '"test":"embedded"' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: Query options should work with embedded server"
    exit 1
fi
echo "PASS: Query options with embedded server"

# Test 10: Flag order independence
echo "Test 10: Flag order independence"
# Test different flag orders
result1=$($GEODE_BIN --format json "RETURN 1 AS order_test" --insecure 2>/dev/null | grep '"order_test":1' || echo "FAIL")
result2=$($GEODE_BIN "RETURN 2 AS order_test" --format json --insecure 2>/dev/null | grep '"order_test":2' || echo "FAIL")
if [[ $result1 == *"FAIL"* ]] || [[ $result2 == *"FAIL"* ]]; then
    echo "FAIL: Flag order should not matter"
    exit 1
fi
echo "PASS: Flag order independence"

echo "=== All Query Option Auto-routing Tests Passed ==="
