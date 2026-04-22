#!/bin/sh
# Post-installation script for Geode
# This script runs after the package is installed

set -e

# Apply QUIC / UDP system-level tuning.
# Source-of-truth: devnw/zig/quic docs/SYSTEM_TUNING.md.
# Applies 11 kernel knobs with "only raise, never lower" semantics and persists
# them to /etc/sysctl.d/99-geode-quic.conf. Best-effort — never blocks install.
echo "Applying QUIC/UDP system tuning..."

TUNE_SH="/usr/share/geode/deployment/scripts/tune-system.sh"
TUNE_CONF_FILE="/usr/share/geode/deployment/sysctl.d/99-geode-quic.conf"

# Fall back to the build tree when the helper has not been packaged yet
# (e.g. running this script from a source checkout rather than a .deb/.rpm).
if [ ! -x "$TUNE_SH" ]; then
    for cand in "./deployment/scripts/tune-system.sh" "$(dirname "$0")/tune-system.sh"; do
        if [ -x "$cand" ]; then TUNE_SH="$cand"; break; fi
    done
fi
if [ ! -f "$TUNE_CONF_FILE" ]; then
    for cand in "./deployment/sysctl.d/99-geode-quic.conf" "$(dirname "$0")/../sysctl.d/99-geode-quic.conf"; do
        if [ -f "$cand" ]; then TUNE_CONF_FILE="$cand"; break; fi
    done
fi

if [ -x "$TUNE_SH" ] && [ -f "$TUNE_CONF_FILE" ]; then
    TUNE_CONF="$TUNE_CONF_FILE" "$TUNE_SH" apply || true
else
    echo "  Warning: tuning helper not found; skipping system tuning."
    echo "  See https://gitlab.com/devnw/zig/quic/-/blob/main/docs/SYSTEM_TUNING.md"
fi

# Ensure proper ownership of directories
echo "Setting up directory permissions..."
chown -R geode:geode /var/lib/geode
chown -R geode:geode /var/log/geode
chown -R geode:geode /etc/geode/certs

# Set proper permissions
chmod 750 /var/lib/geode
chmod 755 /var/log/geode
chmod 755 /etc/geode/certs

# Generate TLS certificates if they don't exist in /etc/geode/certs/
if [ ! -f /etc/geode/certs/server.crt ] || [ ! -f /etc/geode/certs/server.key ]; then
    # Migration: copy existing certs from data_dir if present
    if [ -f /var/lib/geode/server.crt ] && [ -f /var/lib/geode/server.key ]; then
        echo "Migrating existing certificates from /var/lib/geode/ to /etc/geode/certs/..."
        cp /var/lib/geode/server.crt /etc/geode/certs/server.crt
        cp /var/lib/geode/server.key /etc/geode/certs/server.key
        chown geode:geode /etc/geode/certs/server.key /etc/geode/certs/server.crt
        chmod 600 /etc/geode/certs/server.key
        chmod 644 /etc/geode/certs/server.crt
    else
        echo "Generating self-signed TLS certificate..."
        if command -v openssl >/dev/null 2>&1; then
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
                -keyout /etc/geode/certs/server.key \
                -out /etc/geode/certs/server.crt \
                -days 365 -subj "/CN=localhost" \
                -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" \
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
