#!/bin/sh
# Post-removal script for Geode
# This script runs after the package is uninstalled.

set -e

# Reload systemd to reflect removal of service files.
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

# We deliberately do NOT remove the geode user/group or data directories.
# This preserves user data across reinstalls. To completely remove Geode:
#   sudo rm -rf /var/lib/geode /var/log/geode /etc/geode
#   sudo userdel geode
#   sudo groupdel geode

echo ""
echo "Geode has been removed."
echo ""
echo "Note: User data has been preserved in /var/lib/geode."
echo "      To completely remove all Geode data:"
echo "        sudo rm -rf /var/lib/geode /var/log/geode /etc/geode"
echo "        sudo userdel geode"
echo "        sudo groupdel geode"
echo ""
