#!/bin/bash
# Sign Debian/RPM packages using GPG key from Vault or CI variable
#
# Usage:
#   ./sign-packages.sh [--from-vault|--from-env] <dist_directory>
#
# Environment variables:
#   From Vault:
#     VAULT_ADDR          - Vault server address
#     VAULT_TOKEN         - Vault authentication token (or use VAULT_ROLE_ID/VAULT_SECRET_ID)
#     VAULT_SECRET_PATH   - Path to secret (default: secret/geode/debian-signing)
#
#   From CI Variable:
#     GPG_PRIVATE_KEY     - Base64-encoded GPG private key
#     GPG_KEY_ID          - GPG key ID for signing

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default values
SOURCE="env"  # env or vault
VAULT_SECRET_PATH="${VAULT_SECRET_PATH:-secret/geode/debian-signing}"
DIST_DIR=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --from-vault)
            SOURCE="vault"
            shift
            ;;
        --from-env)
            SOURCE="env"
            shift
            ;;
        --help)
            echo "Usage: $0 [--from-vault|--from-env] <dist_directory>"
            exit 0
            ;;
        *)
            DIST_DIR="$1"
            shift
            ;;
    esac
done

if [[ -z "$DIST_DIR" ]]; then
    log_error "dist_directory argument required"
    exit 1
fi

if [[ ! -d "$DIST_DIR" ]]; then
    log_error "Directory does not exist: $DIST_DIR"
    exit 1
fi

# Temporary GPG home for CI isolation
export GNUPGHOME=$(mktemp -d)
trap "rm -rf $GNUPGHOME" EXIT

log_info "Using isolated GPG home: $GNUPGHOME"

# Import GPG key based on source
if [[ "$SOURCE" == "vault" ]]; then
    log_info "Retrieving GPG key from Vault..."

    if [[ -z "${VAULT_ADDR:-}" ]]; then
        log_error "VAULT_ADDR not set"
        exit 1
    fi

    # Authenticate with Vault (AppRole or Token)
    if [[ -n "${VAULT_TOKEN:-}" ]]; then
        log_info "Using VAULT_TOKEN for authentication"
    elif [[ -n "${VAULT_ROLE_ID:-}" && -n "${VAULT_SECRET_ID:-}" ]]; then
        log_info "Authenticating with AppRole..."
        VAULT_TOKEN=$(vault write -field=token auth/approle/login \
            role_id="$VAULT_ROLE_ID" \
            secret_id="$VAULT_SECRET_ID")
        export VAULT_TOKEN
    else
        log_error "No Vault authentication method available"
        exit 1
    fi

    # Retrieve the private key
    PRIVATE_KEY=$(vault kv get -field=private_key "$VAULT_SECRET_PATH")
    GPG_KEY_ID=$(vault kv get -field=key_id "$VAULT_SECRET_PATH")

    # Import into GPG
    echo "$PRIVATE_KEY" | gpg --batch --import
    log_info "Imported GPG key from Vault: $GPG_KEY_ID"

else
    log_info "Using GPG key from environment variable..."

    if [[ -z "${GPG_PRIVATE_KEY:-}" ]]; then
        log_error "GPG_PRIVATE_KEY not set"
        exit 1
    fi

    if [[ -z "${GPG_KEY_ID:-}" ]]; then
        log_error "GPG_KEY_ID not set"
        exit 1
    fi

    # Decode and import
    echo "$GPG_PRIVATE_KEY" | base64 -d | gpg --batch --import
    log_info "Imported GPG key from environment: $GPG_KEY_ID"
fi

# Configure GPG for non-interactive signing
cat > "$GNUPGHOME/gpg.conf" <<EOF
batch
yes
pinentry-mode loopback
EOF

# Trust the key
echo "${GPG_KEY_ID}:6:" | gpg --import-ownertrust

log_info "Signing packages in: $DIST_DIR"

# Sign Debian packages (.deb)
DEB_COUNT=0
for deb in "$DIST_DIR"/*.deb; do
    [[ -f "$deb" ]] || continue
    log_info "Signing: $(basename "$deb")"

    # Create detached signature
    gpg --armor --detach-sign --default-key "$GPG_KEY_ID" "$deb"

    # Also create inline signed control file for APT
    dpkg-deb --info "$deb" 2>/dev/null | gpg --clearsign --default-key "$GPG_KEY_ID" > "${deb}.sig" 2>/dev/null || true

    ((DEB_COUNT++)) || true
done

log_info "Signed $DEB_COUNT Debian packages"

# Sign RPM packages (.rpm) if rpm-sign is available
RPM_COUNT=0
if command -v rpmsign &>/dev/null; then
    for rpm in "$DIST_DIR"/*.rpm; do
        [[ -f "$rpm" ]] || continue
        log_info "Signing: $(basename "$rpm")"

        # RPM expects the key in specific format
        rpmsign --define "_gpg_name $GPG_KEY_ID" --addsign "$rpm" 2>/dev/null || {
            # Fall back to detached signature
            gpg --armor --detach-sign --default-key "$GPG_KEY_ID" "$rpm"
        }

        ((RPM_COUNT++)) || true
    done
    log_info "Signed $RPM_COUNT RPM packages"
else
    log_warn "rpmsign not available, creating detached signatures for RPMs"
    for rpm in "$DIST_DIR"/*.rpm; do
        [[ -f "$rpm" ]] || continue
        gpg --armor --detach-sign --default-key "$GPG_KEY_ID" "$rpm"
        ((RPM_COUNT++)) || true
    done
fi

# Sign checksums file
if [[ -f "$DIST_DIR/checksums.txt" ]]; then
    log_info "Signing checksums.txt"
    gpg --armor --detach-sign --default-key "$GPG_KEY_ID" "$DIST_DIR/checksums.txt"
fi

# Export public key for distribution
PUBLIC_KEY_FILE="$DIST_DIR/geode-apt-signing-key.gpg"
gpg --armor --export "$GPG_KEY_ID" > "$PUBLIC_KEY_FILE"
log_info "Exported public key to: $PUBLIC_KEY_FILE"

# Create APT-compatible keyring
gpg --export "$GPG_KEY_ID" > "$DIST_DIR/geode-archive-keyring.gpg"
log_info "Created APT keyring: geode-archive-keyring.gpg"

echo ""
log_info "Package signing complete!"
echo ""
echo "Signed files:"
find "$DIST_DIR" -name "*.asc" -o -name "*.sig" | sort
echo ""
echo "Public keys:"
echo "  - $PUBLIC_KEY_FILE (ASCII armored)"
echo "  - $DIST_DIR/geode-archive-keyring.gpg (binary)"
