#!/bin/sh
set -e
# Post-removal script for Geode
# This script runs after the package is uninstalled

# Reload systemd to reflect removal of service files
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

echo "Geode has been removed."
