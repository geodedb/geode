#!/bin/sh
# Pre-installation script for Geode
# This script runs before the package is installed.

set -e

# Create geode group and user if they don't exist.
# Using --system (no login shell, UID from system range), --no-create-home
# (the package itself installs /var/lib/geode as an owned dir), and a
# nologin shell so the account cannot be used for interactive login.
if ! getent group geode >/dev/null 2>&1; then
    echo "Creating geode group..."
    groupadd --system geode
fi

if ! getent passwd geode >/dev/null 2>&1; then
    echo "Creating geode user..."
    useradd --system --gid geode --no-create-home \
        --home-dir /var/lib/geode \
        --shell /usr/sbin/nologin \
        --comment "Geode Graph Database" geode
fi

# Stop any running geode services before upgrade so files being replaced
# are not held open. Safe on fresh installs — the service is not yet active.
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet geode.service 2>/dev/null; then
        echo "Stopping geode.service for upgrade..."
        systemctl stop geode.service || true
    fi
fi

exit 0
