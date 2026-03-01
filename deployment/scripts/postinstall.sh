#!/bin/sh
# Post-installation script for Geode
# This script runs after the package is installed

set -e

# Configure QUIC performance optimizations
# These settings significantly improve QUIC/UDP throughput for high-bandwidth connections
echo "Configuring QUIC performance optimizations..."

# Increase UDP buffer sizes for high-throughput QUIC transfers
# Default values are too small for high-bandwidth connections
RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
WMEM_MAX=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")

# Only update if current values are below recommended (7MB = 7340032 bytes)
if [ "$RMEM_MAX" -lt 7340032 ] 2>/dev/null; then
    echo "  Increasing net.core.rmem_max to 7340032 (7MB)..."
    sysctl -w net.core.rmem_max=7340032 >/dev/null 2>&1 || true
fi

if [ "$WMEM_MAX" -lt 7340032 ] 2>/dev/null; then
    echo "  Increasing net.core.wmem_max to 7340032 (7MB)..."
    sysctl -w net.core.wmem_max=7340032 >/dev/null 2>&1 || true
fi

# Persist sysctl settings if /etc/sysctl.d exists
if [ -d /etc/sysctl.d ]; then
    SYSCTL_CONF="/etc/sysctl.d/99-geode-quic.conf"
    if [ ! -f "$SYSCTL_CONF" ]; then
        echo "  Creating $SYSCTL_CONF for persistent settings..."
        cat > "$SYSCTL_CONF" << 'EOF'
# Geode QUIC Performance Optimizations
# Increase UDP buffer sizes for high-throughput QUIC transfers
# These settings allow quic-go to use larger buffers, improving performance
# on high-bandwidth connections.

# Maximum receive socket buffer size (7MB)
net.core.rmem_max=7340032

# Maximum send socket buffer size (7MB)
net.core.wmem_max=7340032
EOF
        echo "  QUIC performance settings will persist across reboots."
    fi
fi

# Note: Generic Segmentation Offload (GSO) is automatically enabled by quic-go
# on Linux kernel 4.18+. To disable GSO (not recommended), set:
# Environment="QUIC_GO_DISABLE_GSO=true" in the systemd service file.

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

    # Enable and start service on installation
    echo "Enabling geode.service..."
    systemctl enable geode.service || true
    echo "Starting geode.service..."
    systemctl start geode.service || true

    echo ""
    echo "Installation complete! Geode service enabled and started."
    echo ""
    echo "To view the initial admin password:"
    echo "  sudo journalctl -u geode | grep 'Generated admin password'"
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
