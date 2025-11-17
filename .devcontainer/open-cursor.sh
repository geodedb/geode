#!/bin/bash
# Open Geode development environment in Cursor

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Opening Geode in Cursor Dev Container...${NC}"

# Check if Docker is running
if ! docker info &>/dev/null; then
    echo "❌ Docker is not running. Please start Docker first."
    exit 1
fi

# Check if Cursor is installed
if ! command -v cursor &>/dev/null; then
    echo "❌ Cursor (cursor command) is not found in PATH."
    echo "Please install Cursor or ensure 'cursor' is in your PATH."
    exit 1
fi

# Get the repository root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo -e "${GREEN}📂 Opening: ${REPO_ROOT}${NC}"
echo -e "${GREEN}🐳 Cursor will open in Dev Container mode${NC}"
echo ""
echo "Cursor will:"
echo "  1. Build/start the Docker container if needed"
echo "  2. Install extensions inside the container"
echo "  3. Mount all AI assistant configs (Cursor AI, Copilot, Claude, etc.)"
echo "  4. Open the workspace at /workspace"
echo ""

# Open in Cursor
cd "$REPO_ROOT"
cursor .

echo -e "${GREEN}✅ Cursor is opening...${NC}"
echo "If this is the first time, it may take a few minutes to build the container."
echo ""
echo "In Cursor:"
echo "  1. Press Cmd/Ctrl+Shift+P"
echo "  2. Select 'Dev Containers: Reopen in Container'"
echo "  3. Wait for the container to build and start"
