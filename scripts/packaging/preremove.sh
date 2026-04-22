#!/bin/sh
# Pre-removal script for Geode
# This script runs before the package is uninstalled.

set -e

echo "Geode is being removed..."

# Stop and disable systemd units if systemd is available. This covers the
# main geode.service plus any running per-port instances under the
# geode@.service template.
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet geode.service 2>/dev/null; then
        echo "Stopping geode.service..."
        systemctl stop geode.service || true
    fi
    if systemctl is-enabled --quiet geode.service 2>/dev/null; then
        echo "Disabling geode.service..."
        systemctl disable geode.service || true
    fi

    # Stop any running template instances (geode@<port>.service).
    for service in $(systemctl list-units 'geode@*.service' --no-legend 2>/dev/null | awk '{print $1}'); do
        echo "Stopping $service..."
        systemctl stop "$service" || true
    done
fi

echo ""
echo "Note: Data in /var/lib/geode will be preserved."
echo "      Remove manually if no longer needed:"
echo "        sudo rm -rf /var/lib/geode"
echo "        sudo rm -rf /var/log/geode"
echo "        sudo rm -rf /etc/geode"
echo "        sudo userdel geode"
echo "        sudo groupdel geode"
