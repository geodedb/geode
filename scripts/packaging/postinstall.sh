#!/bin/sh
# Post-installation script for Geode
# This script runs after the package is installed

set -e

# Create geode system user if it doesn't exist
if ! getent passwd geode >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --shell /usr/sbin/nologin geode
fi

# Set ownership of data directories
chown -R geode:geode /var/lib/geode
chown -R geode:geode /var/log/geode
chown -R geode:geode /etc/geode

# Set proper permissions
chmod 750 /var/lib/geode
chmod 750 /var/log/geode
chmod 700 /etc/geode/certs

echo "Geode installed successfully!"
echo ""
echo "Quick start:"
echo "  geode serve --listen 0.0.0.0:8443"
echo ""
echo "For more information, see /usr/share/doc/geode/QUICK_REFERENCE.md"
