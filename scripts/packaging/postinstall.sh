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

# Reload systemd to recognize the new service
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    echo "Enabling geode.service..."
    systemctl enable geode.service || true
    echo "Starting geode.service..."
    systemctl start geode.service || true
    echo ""
    echo "Geode service enabled and started."
    echo ""
    echo "To view the initial admin password:"
    echo "  sudo journalctl -u geode | grep GEODE_INITIAL_ADMIN_PASSWORD"
    echo ""
    echo "To check status:"
    echo "  sudo systemctl status geode"
fi

echo ""
echo "Geode installed successfully!"
echo ""
echo "Quick start (standalone):"
echo "  geode serve --listen 0.0.0.0:3141"
echo ""
echo "For more information, see /usr/share/doc/geode/QUICK_REFERENCE.md"
