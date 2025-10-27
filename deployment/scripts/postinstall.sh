#!/bin/sh
# Post-installation script for Geode
# This script runs after the package is installed

set -e

# Ensure proper ownership of directories
echo "Setting up directory permissions..."
chown -R geode:geode /var/lib/geode
chown -R geode:geode /var/log/geode
chown -R geode:geode /etc/geode/certs

# Set proper permissions
chmod 750 /var/lib/geode
chmod 755 /var/log/geode
chmod 750 /etc/geode/certs

# Generate TLS certificates if they don't exist
if [ ! -f /etc/geode/certs/server.crt ] || [ ! -f /etc/geode/certs/server.key ]; then
    echo "Generating self-signed TLS certificate..."
    if command -v openssl >/dev/null 2>&1; then
        openssl req -x509 -newkey rsa:4096 -nodes \
            -keyout /etc/geode/certs/server.key \
            -out /etc/geode/certs/server.crt \
            -days 365 -subj "/CN=localhost" \
            2>/dev/null || echo "Warning: Could not generate certificate"

        if [ -f /etc/geode/certs/server.key ]; then
            chown geode:geode /etc/geode/certs/server.key /etc/geode/certs/server.crt
            chmod 600 /etc/geode/certs/server.key
            chmod 644 /etc/geode/certs/server.crt
        fi
    else
        echo "Warning: OpenSSL not found. Please generate TLS certificates manually."
    fi
fi

# Reload systemd daemon if systemd is available
if command -v systemctl >/dev/null 2>&1; then
    echo "Reloading systemd daemon..."
    systemctl daemon-reload

    # Enable service on installation
    echo "Enabling geode.service..."
    systemctl enable geode.service || true

    echo ""
    echo "Installation complete!"
    echo ""
    echo "To start Geode:"
    echo "  sudo systemctl start geode"
    echo ""
    echo "To check status:"
    echo "  sudo systemctl status geode"
    echo ""
    echo "To view logs:"
    echo "  sudo journalctl -u geode -f"
    echo ""
else
    echo ""
    echo "Installation complete!"
    echo ""
    echo "To start Geode manually:"
    echo "  sudo -u geode /usr/bin/geode serve --data-dir /var/lib/geode --log-level info"
    echo ""
fi

exit 0
