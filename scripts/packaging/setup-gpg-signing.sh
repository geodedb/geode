#!/bin/bash
# Geode Debian Package Signing Setup
# Generates GPG key and optionally stores in HashiCorp Vault
#
# Usage:
#   ./setup-gpg-signing.sh                    # Generate key only
#   ./setup-gpg-signing.sh --vault            # Generate and store in Vault
#   ./setup-gpg-signing.sh --vault --export   # Also export for GitLab CI
#
# Prerequisites:
#   - gpg installed
#   - vault CLI installed (if using --vault)
#   - VAULT_ADDR and VAULT_TOKEN env vars set (if using --vault)

set -euo pipefail

# Configuration
KEY_NAME="Geode Package Signing Key"
KEY_EMAIL="${GPG_KEY_EMAIL:-packages@codepros.dev}"
KEY_COMMENT="Geode APT Repository Signing Key"
KEY_EXPIRE="2y"
KEY_TYPE="RSA"
KEY_LENGTH="4096"
VAULT_PATH="${VAULT_SECRET_PATH:-secret/geode/debian-signing}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

USE_VAULT=false
EXPORT_CI=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --vault)
            USE_VAULT=true
            shift
            ;;
        --export)
            EXPORT_CI=true
            shift
            ;;
        --email)
            KEY_EMAIL="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--vault] [--export] [--email EMAIL]"
            echo ""
            echo "Options:"
            echo "  --vault   Store private key in HashiCorp Vault"
            echo "  --export  Export base64-encoded key for GitLab CI variable"
            echo "  --email   Email address for the GPG key (default: packages@codepros.dev)"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if key already exists
if gpg --list-keys "$KEY_EMAIL" &>/dev/null; then
    log_warn "GPG key for $KEY_EMAIL already exists"
    read -p "Do you want to use the existing key? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log_info "Exiting. Delete the existing key first if you want to regenerate."
        exit 1
    fi
    KEY_ID=$(gpg --list-keys --keyid-format long "$KEY_EMAIL" | grep pub | head -1 | awk '{print $2}' | cut -d'/' -f2)
else
    log_info "Generating new GPG key for Debian package signing..."

    # Generate key using batch mode
    cat > /tmp/gpg-key-params <<EOF
%echo Generating Geode signing key
Key-Type: $KEY_TYPE
Key-Length: $KEY_LENGTH
Subkey-Type: $KEY_TYPE
Subkey-Length: $KEY_LENGTH
Name-Real: $KEY_NAME
Name-Comment: $KEY_COMMENT
Name-Email: $KEY_EMAIL
Expire-Date: $KEY_EXPIRE
%no-protection
%commit
%echo Key generation complete
EOF

    gpg --batch --generate-key /tmp/gpg-key-params
    rm -f /tmp/gpg-key-params

    KEY_ID=$(gpg --list-keys --keyid-format long "$KEY_EMAIL" | grep pub | head -1 | awk '{print $2}' | cut -d'/' -f2)
    log_info "Generated GPG key with ID: $KEY_ID"
fi

# Export public key
PUBLIC_KEY_FILE="geode-apt-signing-key.gpg"
gpg --armor --export "$KEY_EMAIL" > "$PUBLIC_KEY_FILE"
log_info "Public key exported to: $PUBLIC_KEY_FILE"

# Export fingerprint
FINGERPRINT=$(gpg --fingerprint "$KEY_EMAIL" | grep -A1 "pub" | tail -1 | tr -d ' ')
log_info "Key fingerprint: $FINGERPRINT"

if $USE_VAULT; then
    log_info "Storing private key in Vault at: $VAULT_PATH"

    if [[ -z "${VAULT_ADDR:-}" ]]; then
        log_error "VAULT_ADDR environment variable not set"
        exit 1
    fi

    if [[ -z "${VAULT_TOKEN:-}" ]]; then
        log_error "VAULT_TOKEN environment variable not set"
        exit 1
    fi

    # Export private key
    PRIVATE_KEY=$(gpg --armor --export-secret-keys "$KEY_EMAIL")

    # Store in Vault
    vault kv put "$VAULT_PATH" \
        private_key="$PRIVATE_KEY" \
        public_key="$(cat $PUBLIC_KEY_FILE)" \
        key_id="$KEY_ID" \
        fingerprint="$FINGERPRINT" \
        email="$KEY_EMAIL"

    log_info "Private key stored in Vault successfully"
fi

if $EXPORT_CI; then
    # Export base64-encoded private key for GitLab CI
    CI_VAR_FILE="geode-signing-key-ci.b64"
    gpg --armor --export-secret-keys "$KEY_EMAIL" | base64 -w0 > "$CI_VAR_FILE"

    log_info "Base64-encoded private key for CI saved to: $CI_VAR_FILE"
    echo ""
    echo "=========================================="
    echo "GitLab CI/CD Setup Instructions:"
    echo "=========================================="
    echo ""
    echo "1. Go to GitLab > Settings > CI/CD > Variables"
    echo ""
    echo "2. Add these variables:"
    echo "   - GPG_PRIVATE_KEY: (paste contents of $CI_VAR_FILE)"
    echo "     Type: Variable, Protected: Yes, Masked: Yes"
    echo ""
    echo "   - GPG_KEY_ID: $KEY_ID"
    echo "     Type: Variable, Protected: Yes"
    echo ""
    echo "3. Delete the local file after adding to GitLab:"
    echo "   shred -u $CI_VAR_FILE"
    echo ""
fi

echo ""
echo "=========================================="
echo "APT Repository Setup Instructions:"
echo "=========================================="
echo ""
echo "Users should add your repository with:"
echo ""
echo "  # Download and add the GPG key"
echo "  curl -fsSL https://YOUR_DOMAIN/geode-apt-signing-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/geode-archive-keyring.gpg"
echo ""
echo "  # Add the repository"
echo "  echo \"deb [signed-by=/usr/share/keyrings/geode-archive-keyring.gpg] https://YOUR_DOMAIN/apt stable main\" | sudo tee /etc/apt/sources.list.d/geode.list"
echo ""
echo "  # Update and install"
echo "  sudo apt update"
echo "  sudo apt install geode"
echo ""
echo "=========================================="
echo ""
log_info "GPG signing setup complete!"
echo ""
echo "Key ID:      $KEY_ID"
echo "Fingerprint: $FINGERPRINT"
echo "Email:       $KEY_EMAIL"
echo "Public key:  $PUBLIC_KEY_FILE"
