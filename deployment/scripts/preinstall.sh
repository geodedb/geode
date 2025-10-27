#!/bin/sh
# Pre-installation script for Geode
# This script runs before the package is installed

set -e

# Create geode user and group if they don't exist
if ! getent group geode >/dev/null 2>&1; then
    echo "Creating geode group..."
    groupadd --system geode
fi

if ! getent passwd geode >/dev/null 2>&1; then
    echo "Creating geode user..."
    useradd --system --gid geode --create-home --home-dir /var/lib/geode \
        --shell /bin/false --comment "Geode Graph Database" geode
fi

# Stop any running geode services before upgrade
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet geode.service; then
        echo "Stopping geode.service..."
        systemctl stop geode.service || true
    fi
fi

exit 0
