#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ROOT_DIR="$SCRIPT_DIR/../.."

echo -e "${GREEN}Building Geode Base Image (geode:test)...${NC}"
# Build the main geode image tagged as geode:test from the root
# We assume this script is run from tests/ha, so we go up two levels
cd "$ROOT_DIR"
docker build -t geode:test -f Dockerfile .

echo -e "${GREEN}Building Runner Image...${NC}"
# Build runner from tests/ha context
# We need to be in root for context if we want to copy things,
# but docker compose builds from tests/ha usually.
# Let's rely on docker compose build which uses context: . in tests/ha
# But our docker compose references . for runner context.
# So we need to ensure we run compose from tests/ha
cd "$SCRIPT_DIR"

docker compose build runner

echo -e "${GREEN}Starting Environment...${NC}"
docker compose up -d node-1 node-2 node-3

echo "Waiting for cluster to stabilize (30s)..."
sleep 30

echo -e "${GREEN}Running Tests...${NC}"
docker compose up --abort-on-container-exit runner

EXIT_CODE=$?

echo -e "${GREEN}Cleaning up...${NC}"
docker compose down -v

if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}SUCCESS: All HA tests passed!${NC}"
else
    echo -e "${RED}FAILURE: Tests failed with exit code $EXIT_CODE${NC}"
fi

exit $EXIT_CODE
