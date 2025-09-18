#!/usr/bin/env bash
# QUIC library is now managed as a git submodule

set -euo pipefail

echo "QUIC library is now managed as a git submodule at vendor/quic"
echo ""
echo "To update the QUIC submodule:"
echo "  git submodule update --init --recursive"
echo ""
echo "To pull the latest changes from the QUIC repository:"
echo "  cd vendor/quic && git pull origin main && cd ../.."
echo "  git add vendor/quic"
echo "  git commit -m 'Update QUIC submodule'"
echo ""
echo "Current QUIC submodule status:"
cd vendor/quic 2>/dev/null && git log -1 --oneline || echo "Submodule not initialized"