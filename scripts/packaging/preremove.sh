#!/bin/sh
# Pre-removal script for Geode
# This script runs before the package is uninstalled

set -e

echo "Geode is being removed..."

# Stop and disable the systemd service if it exists
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet geode 2>/dev/null; then
        echo "Stopping geode service..."
        systemctl stop geode || true
    fi
    if systemctl is-enabled --quiet geode 2>/dev/null; then
        echo "Disabling geode service..."
        systemctl disable geode || true
    fi
fi

echo ""
echo "Note: Data in /var/lib/geode will be preserved."
echo "      Remove manually if no longer needed:"
echo "        sudo rm -rf /var/lib/geode"
echo "        sudo rm -rf /var/log/geode"
echo "        sudo rm -rf /etc/geode"
echo "        sudo userdel geode"
