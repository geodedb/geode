#!/bin/sh
# Post-installation script for Geode
# This script runs after the package is installed.
#
# User/group creation and any pre-upgrade service stop happen in
# scripts/packaging/preinstall.sh; by the time this runs the geode user
# exists and files have been laid down by the package manager.

set -e

# Set ownership of data / log / config directories (files are extracted root:root).
chown -R geode:geode /var/lib/geode
chown -R geode:geode /var/log/geode
chown -R geode:geode /etc/geode

# Set proper permissions.
chmod 750 /var/lib/geode
chmod 750 /var/log/geode
chmod 755 /etc/geode/certs

# Apply QUIC / UDP system-level tuning.
# Source-of-truth: devnw/zig/quic docs/SYSTEM_TUNING.md.
# Applies 11 kernel knobs with "only raise, never lower" semantics and persists
# them to /etc/sysctl.d/99-geode-quic.conf. Best-effort — never blocks install.
TUNE_SH="/usr/share/geode/deployment/scripts/tune-system.sh"
TUNE_CONF_FILE="/usr/share/geode/deployment/sysctl.d/99-geode-quic.conf"
if [ -x "$TUNE_SH" ] && [ -f "$TUNE_CONF_FILE" ]; then
    echo "Applying QUIC/UDP system tuning..."
    TUNE_CONF="$TUNE_CONF_FILE" "$TUNE_SH" apply || true
else
    echo "Warning: QUIC tuning helper not found at $TUNE_SH; skipping."
    echo "See https://gitlab.com/devnw/zig/quic/-/blob/main/docs/SYSTEM_TUNING.md"
fi

# Provide TLS certificates if none are present in /etc/geode/certs/.
# 1) Migration: copy legacy certs from /var/lib/geode/ (older layouts).
# 2) Fallback: generate a self-signed ECDSA P-256 cert valid for 365 days.
# Operators should replace these with CA-signed certs before production use.
if [ ! -f /etc/geode/certs/server.crt ] || [ ! -f /etc/geode/certs/server.key ]; then
    if [ -f /var/lib/geode/server.crt ] && [ -f /var/lib/geode/server.key ]; then
        echo "Migrating existing certificates from /var/lib/geode/ to /etc/geode/certs/..."
        cp /var/lib/geode/server.crt /etc/geode/certs/server.crt
        cp /var/lib/geode/server.key /etc/geode/certs/server.key
        chown geode:geode /etc/geode/certs/server.key /etc/geode/certs/server.crt
        chmod 600 /etc/geode/certs/server.key
        chmod 644 /etc/geode/certs/server.crt
    elif command -v openssl >/dev/null 2>&1; then
        echo "Generating self-signed TLS certificate (replace before production)..."
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -keyout /etc/geode/certs/server.key \
            -out /etc/geode/certs/server.crt \
            -days 365 -subj "/CN=localhost" \
            -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" \
            2>/dev/null || echo "Warning: could not generate self-signed certificate."
        if [ -f /etc/geode/certs/server.key ]; then
            chown geode:geode /etc/geode/certs/server.key /etc/geode/certs/server.crt
            chmod 600 /etc/geode/certs/server.key
            chmod 644 /etc/geode/certs/server.crt
        fi
    else
        echo "Warning: OpenSSL not found and no legacy certs present."
        echo "         Geode will not start until /etc/geode/certs/server.{crt,key} exist."
    fi
fi

# Reload systemd to recognize the new service files.
#
# ENG-5008: the package no longer enables or starts geode.service on a
# fresh install. Most hosts install this package for the CLI; the
# enabled-by-default server has a history of resource starvation on
# hosts that never asked for it (constant CPU + I/O), and when the
# shipped binary cannot exec at all, an enabled unit turns a packaging
# defect into an unbounded 12-per-minute crash loop on every install.
# Running the server is one explicit command away; upgrades of hosts
# that DID opt in are restarted onto the new binary below.
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    if systemctl is-enabled --quiet geode.service 2>/dev/null; then
        # The operator enabled the server on this host; pick up the new
        # binary now rather than on the next reboot.
        echo "geode.service is enabled on this host; restarting it on the new binary..."
        systemctl restart geode.service || true
        echo ""
        echo "To check status:"
        echo "  sudo systemctl status geode"
    else
        echo ""
        echo "The geode server is NOT enabled by default. To run it as a service:"
        echo "  sudo systemctl enable --now geode.service"
        echo ""
        echo "Then to view the initial admin password:"
        echo "  sudo journalctl -u geode | grep 'Generated admin password'"
    fi
fi

echo ""
echo "Geode installed successfully!"
echo ""
echo "Quick start (standalone):"
echo "  geode serve --listen 0.0.0.0:3141"
echo ""
echo "For more information, see /usr/share/doc/geode/QUICK_REFERENCE.md"
