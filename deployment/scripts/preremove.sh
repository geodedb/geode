#!/bin/sh
# Pre-removal script for Geode
# This script runs before the package is removed

set -e

# Stop and disable service if systemd is available
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet geode.service; then
        echo "Stopping geode.service..."
        systemctl stop geode.service || true
    fi

    if systemctl is-enabled --quiet geode.service 2>/dev/null; then
        echo "Disabling geode.service..."
        systemctl disable geode.service || true
    fi

    # Stop any running instance services
    for service in $(systemctl list-units 'geode@*.service' --no-legend | awk '{print $1}'); do
        echo "Stopping $service..."
        systemctl stop "$service" || true
    done
fi

exit 0
