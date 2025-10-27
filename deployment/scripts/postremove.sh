#!/bin/sh
# Post-removal script for Geode
# This script runs after the package is removed

set -e

# Reload systemd daemon if systemd is available
if command -v systemctl >/dev/null 2>&1; then
    echo "Reloading systemd daemon..."
    systemctl daemon-reload || true
fi

# Note: We do NOT remove the geode user, group, or data directories
# This preserves user data in case of reinstallation
# To completely remove Geode and all data:
#   sudo userdel geode
#   sudo groupdel geode
#   sudo rm -rf /var/lib/geode /var/log/geode /etc/geode

echo ""
echo "Geode has been removed."
echo ""
echo "Note: User data has been preserved in /var/lib/geode"
echo "To completely remove all Geode data:"
echo "  sudo rm -rf /var/lib/geode /var/log/geode /etc/geode"
echo "  sudo userdel geode"
echo "  sudo groupdel geode"
echo ""

exit 0
