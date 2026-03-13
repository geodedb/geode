#!/bin/bash
set -euo pipefail

# Integration test runner for Geode
# Runs all integration test files

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${YELLOW}╔══════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║      Geode Integration Test Runner           ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════╝${NC}"

# Build tests
echo -e "\n${YELLOW}Building integration tests...${NC}"
zig build test

# Track results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
declare -a FAILED_FILES

# Find and run all test files
echo -e "\n${BLUE}Running integration tests...${NC}\n"

for test_file in tests/integration/test_*.zig; do
    if [ -f "$test_file" ]; then
        test_name=$(basename "$test_file" .zig)
        echo -n "Testing $test_name... "
        ((TOTAL_TESTS++))

        if zig test "$test_file" 2>/dev/null; then
            echo -e "${GREEN}✓ PASSED${NC}"
            ((PASSED_TESTS++))
        else
            echo -e "${RED}✗ FAILED${NC}"
            ((FAILED_TESTS++))
            FAILED_FILES+=("$test_file")
        fi
    fi
done

# Run specific feature tests
echo -e "\n${BLUE}Running feature-specific tests...${NC}\n"

# Test index operations
echo -n "Testing index operations... "
if zig test tests/integration/test_vector_index.zig 2>/dev/null && \
   zig test tests/integration/test_spatial_index.zig 2>/dev/null; then
    echo -e "${GREEN}✓ PASSED${NC}"
    ((PASSED_TESTS++))
else
    echo -e "${RED}✗ FAILED${NC}"
    ((FAILED_TESTS++))
fi
((TOTAL_TESTS++))

# Test backup/restore
echo -n "Testing backup/restore... "
if zig test tests/integration/test_backup_restore.zig 2>/dev/null; then
    echo -e "${GREEN}✓ PASSED${NC}"
    ((PASSED_TESTS++))
else
    echo -e "${RED}✗ FAILED${NC}"
    ((FAILED_TESTS++))
fi
((TOTAL_TESTS++))

# Summary
echo -e "\n${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           Integration Test Summary           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"

echo -e "\nTotal tests run: ${TOTAL_TESTS}"
echo -e "${GREEN}Passed: ${PASSED_TESTS}${NC}"
echo -e "${RED}Failed: ${FAILED_TESTS}${NC}"

if [ ${#FAILED_FILES[@]} -gt 0 ]; then
    echo -e "\n${RED}Failed test files:${NC}"
    for file in "${FAILED_FILES[@]}"; do
        echo -e "  ${RED}• $file${NC}"
    done

    echo -e "\n${YELLOW}To debug failures, run:${NC}"
    echo -e "  zig test <failed_file> --verbose"

    exit 1
else
    echo -e "\n${GREEN}✓ All integration tests passed!${NC}"
fi

echo -e "\n${GREEN}Integration testing complete!${NC}"
