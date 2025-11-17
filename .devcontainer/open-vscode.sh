#!/bin/bash
# Open Geode development environment in VSCode

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Opening Geode in VSCode Dev Container...${NC}"

# Check if Docker is running
if ! docker info &>/dev/null; then
    echo "❌ Docker is not running. Please start Docker first."
    exit 1
fi

# Check if VSCode is installed
if ! command -v code &>/dev/null; then
    echo "❌ VSCode (code command) is not found in PATH."
    echo "Please install VSCode or ensure 'code' is in your PATH."
    exit 1
fi

# Check if Dev Containers extension is installed
if ! code --list-extensions | grep -q "ms-vscode-remote.remote-containers"; then
    echo "⚠️  Dev Containers extension not found."
    echo "Installing Dev Containers extension..."
    code --install-extension ms-vscode-remote.remote-containers
fi

# Get the repository root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo -e "${GREEN}📂 Opening: ${REPO_ROOT}${NC}"
echo -e "${GREEN}🐳 VSCode will open in Dev Container mode${NC}"
echo ""
echo "VSCode will:"
echo "  1. Build/start the Docker container if needed"
echo "  2. Install extensions inside the container"
echo "  3. Mount all AI assistant configs (Copilot, Claude, etc.)"
echo "  4. Open the workspace at /workspace"
echo ""

# Open in VSCode with dev container
code --folder-uri "vscode-remote://dev-container+${REPO_ROOT//\//%2F}/.devcontainer/devcontainer.json/workspace"

echo -e "${GREEN}✅ VSCode is opening...${NC}"
echo "If this is the first time, it may take a few minutes to build the container."
