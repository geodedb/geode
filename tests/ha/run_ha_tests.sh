#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ROOT_DIR="$SCRIPT_DIR/../.."

# Default mode
MODE="ha"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --integration) MODE="integration" ;;
        --all) MODE="all" ;;
        -h|--help) echo "Usage: $0 [--integration|--all]"; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

cleanup() {
    echo -e "${GREEN}Cleaning up...${NC}"
    cd "$SCRIPT_DIR"
    docker compose down -v 2>/dev/null || true
    docker compose -f docker-compose.clients.yml down -v 2>/dev/null || true
}

# Trap cleanup on exit
trap cleanup EXIT

echo -e "${GREEN}Building Geode Base Image (geode:test)...${NC}"
cd "$ROOT_DIR"
docker build -t geode:test -f Dockerfile .

echo -e "${GREEN}Starting Environment...${NC}"
cd "$SCRIPT_DIR"
docker compose up -d node-1 node-2 node-3

echo "Waiting for cluster to stabilize (30s)..."
sleep 30

EXIT_CODE=0

if [[ "$MODE" == "ha" || "$MODE" == "all" ]]; then
    echo -e "${GREEN}Running HA Tests...${NC}"
    cd "$SCRIPT_DIR"
    docker compose build runner
    # Use exit-code-from to propagate the runner's exit code
    docker compose up --exit-code-from runner
    EXIT_CODE=$?
fi

if [[ "$EXIT_CODE" -eq 0 && ("$MODE" == "integration" || "$MODE" == "all") ]]; then
    echo -e "${GREEN}Running Integration Clients...${NC}"
    cd "$SCRIPT_DIR"

    echo "Building client images..."
    docker compose -f docker-compose.clients.yml build

    echo "Starting integration tests..."
    # Use exit-code-from results-collector
    docker compose -f docker-compose.clients.yml up --exit-code-from results-collector
    EXIT_CODE=$?
fi

if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}SUCCESS: All tests passed!${NC}"
else
    echo -e "${RED}FAILURE: Tests failed with exit code $EXIT_CODE${NC}"
    # Ensure we return the failure code
    exit $EXIT_CODE
fi

