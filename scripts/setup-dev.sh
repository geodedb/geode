#!/usr/bin/env bash
# Development environment setup script for Geode
# This script installs pre-commit hooks and verifies dependencies

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== Geode Development Environment Setup ==="
echo ""

# Check for required tools
echo "Checking required tools..."

check_command() {
    if command -v "$1" &> /dev/null; then
        echo -e "${GREEN}✓${NC} $1 found: $($1 --version 2>&1 | head -1)"
        return 0
    else
        echo -e "${RED}✗${NC} $1 not found"
        return 1
    fi
}

# Required tools
MISSING_REQUIRED=0
check_command zig || MISSING_REQUIRED=1
check_command git || MISSING_REQUIRED=1

if [ $MISSING_REQUIRED -eq 1 ]; then
    echo ""
    echo -e "${RED}Error: Missing required tools. Please install them first.${NC}"
    echo "  - Zig (zvm): curl -fsSL https://zig.sh/install.sh | bash"
    exit 1
fi

# Optional but recommended tools
echo ""
echo "Checking optional tools..."
check_command python3 || echo "  (optional, needed for test runner and pre-commit)"
check_command pip3 || check_command pip || echo "  (optional, needed to install pre-commit)"
check_command shellcheck || echo "  (optional, for shell script linting)"
check_command docker || echo "  (optional, for containerized testing)"

# Initialize git submodules
echo ""
echo "Initializing git submodules..."
cd "$PROJECT_ROOT"
git submodule update --init --recursive

# Install pre-commit if available
echo ""
echo "Setting up pre-commit hooks..."
if command -v pip3 &> /dev/null; then
    PIP_CMD="pip3"
elif command -v pip &> /dev/null; then
    PIP_CMD="pip"
else
    echo -e "${YELLOW}Warning: pip not found. Skipping pre-commit installation.${NC}"
    echo "To install pre-commit manually:"
    echo "  pip install pre-commit"
    echo "  pre-commit install"
    echo "  pre-commit install --hook-type commit-msg"
    PIP_CMD=""
fi

if [ -n "${PIP_CMD:-}" ]; then
    # Check if pre-commit is already installed
    if ! command -v pre-commit &> /dev/null; then
        echo "Installing pre-commit..."
        $PIP_CMD install --user pre-commit
    else
        echo -e "${GREEN}✓${NC} pre-commit already installed"
    fi

    # Install the hooks
    if command -v pre-commit &> /dev/null; then
        echo "Installing pre-commit hooks..."
        pre-commit install
        pre-commit install --hook-type commit-msg
        pre-commit install --hook-type pre-push
        echo -e "${GREEN}✓${NC} Pre-commit hooks installed"
    fi
fi

# Generate TLS certificates if needed
echo ""
echo "Checking TLS certificates..."
if [ ! -f "$PROJECT_ROOT/certs/server.pem" ]; then
    echo "Generating TLS certificates..."
    make -C "$PROJECT_ROOT" cert-gen 2>/dev/null || echo "  (will be generated on first build)"
else
    echo -e "${GREEN}✓${NC} TLS certificates already exist"
fi

# Build the project
echo ""
echo "Building Geode..."
make -C "$PROJECT_ROOT" build

# Run quick tests
echo ""
echo "Running quick tests..."
make -C "$PROJECT_ROOT" test || echo -e "${YELLOW}Warning: Some tests failed${NC}"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Quick commands:"
echo "  make build       - Build the project"
echo "  make test        - Run tests"
echo "  make fmt         - Format code"
echo "  make help        - Show all available targets"
echo ""
echo "Pre-commit will automatically run on:"
echo "  - git commit: formatting, linting, compilation checks"
echo "  - git push: cross-compilation, full tests"
echo ""
echo "To run pre-commit manually:"
echo "  pre-commit run --all-files"
echo ""
