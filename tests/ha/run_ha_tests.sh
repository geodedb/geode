#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ROOT_DIR="$SCRIPT_DIR/../.."

# Default mode and settings
MODE="ha"
KEEP_ON_FAILURE=false

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --integration) MODE="integration" ;;
        --all) MODE="all" ;;
        --keep) KEEP_ON_FAILURE=true ;;
        -h|--help) echo "Usage: $0 [--integration|--all] [--keep]"; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

cleanup() {
    EXIT_CODE=$?
    if [[ "$EXIT_CODE" -ne 0 && "$KEEP_ON_FAILURE" == "true" ]]; then
        echo -e "${RED}Tests failed. Keeping containers running for debugging due to --keep flag.${NC}"
        echo "You can inspect logs with: docker compose -f docker-compose.clients.yml logs"
        echo "When done, run: docker compose -f docker-compose.clients.yml down -v && docker compose down -v"
        return
    fi

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

