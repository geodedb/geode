# Geode APT Repository

This document describes how to set up, maintain, and use the Geode APT repository for Debian/Ubuntu package distribution.

**Repository URL**: `https://apt.geodedb.com`

## Quick Install (Users)

```bash
# Add GPG signing key
curl -fsSL https://apt.geodedb.com/geode.gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/geode-archive-keyring.gpg

# Add repository
echo "deb [signed-by=/usr/share/keyrings/geode-archive-keyring.gpg] https://apt.geodedb.com stable main" | \
  sudo tee /etc/apt/sources.list.d/geode.list

# Install
sudo apt update
sudo apt install geode
```

## Custom Domain Setup (apt.geodedb.com)

The APT repository uses a custom domain for portability. This allows migration to any hosting provider without breaking user installations.

### DNS Configuration

Add these DNS records for `geodedb.com`:

```
# CNAME for apt subdomain pointing to GitLab Pages
apt.geodedb.com.    CNAME    devnw.gitlab.io.

# TXT record for GitLab domain verification (get value from GitLab)
_gitlab-pages-verification-code.apt.geodedb.com.    TXT    "gitlab-pages-verification-code=XXXXX"
```

### GitLab Pages Configuration

1. Go to **Settings > Pages > New Domain**
2. Enter: `apt.geodedb.com`
3. Copy the verification code and add the TXT record above
4. Click **Verify**
5. Enable **Force HTTPS** (GitLab auto-provisions Let's Encrypt certificate)

### Future Migration

If you move away from GitLab, simply update the DNS:

```
# Point to S3/CloudFront
apt.geodedb.com.    CNAME    your-bucket.s3.amazonaws.com.

# Or point to your own server
apt.geodedb.com.    A    203.0.113.50
```

Users' `/etc/apt/sources.list.d/geode.list` continues working unchanged.

## Repository Structure

The APT repository is hosted on GitLab Pages and follows the standard Debian repository layout:

```
https://apt.geodedb.com/
├── geode.gpg                     # ASCII-armored public key
├── geode-archive-keyring.gpg     # Binary GPG keyring
├── dists/
│   └── stable/
│       ├── Release               # Repository metadata
│       ├── Release.gpg           # Detached signature
│       ├── InRelease             # Inline-signed Release
│       └── main/
│           ├── binary-amd64/
│           │   ├── Packages
│           │   └── Packages.gz
│           ├── binary-arm64/
│           ├── binary-armhf/
│           └── binary-riscv64/
└── pool/
    └── main/
        └── g/
            └── geode/
                ├── geode_X.Y.Z_amd64.deb
                ├── geode_X.Y.Z_arm64.deb
                └── ...
```

## Infrastructure (Terraform)

The APT repository infrastructure is managed via Terraform in `prod-critical`:

```hcl
# Creates:
# - DigitalOcean Spaces bucket for package storage
# - Cloudflare DNS records (apt.geodedb.com)
# - Cloudflare cache rules for optimal performance
# - Vault secrets for CI/CD credential access
```

Apply changes:

```bash
cd ~/src/gl/devnw/infra/prod-critical
make plan   # Review changes
make apply  # Apply infrastructure
```

## Setting Up GPG Signing (Maintainers)

### Step 1: Generate GPG Key

```bash
cd geode/
chmod +x scripts/packaging/setup-gpg-signing.sh

# Generate key
./scripts/packaging/setup-gpg-signing.sh --export --email packages@codepros.dev
```

This generates:

- `geode-apt-signing-key.gpg` - Public key for distribution
- `geode-signing-key-ci.b64` - Base64-encoded private key for Vault

### Step 2: Store in Vault

The CI/CD uses GitLab JWT authentication to Vault. Store secrets:

```bash
# Authenticate to Vault
vault login

# Store GPG credentials
vault kv put secret/geode/apt/gpg_private_key value="$(cat geode-signing-key-ci.b64)"
vault kv put secret/geode/apt/gpg_key_id value="YOUR_KEY_ID"

# S3 credentials are managed by Terraform and stored automatically
```

### Step 3: Delete Local Key Files

```bash
shred -u geode-signing-key-ci.b64
```

Keep `geode-apt-signing-key.gpg` for backup.

## CI/CD Pipeline

The GitLab CI uses the reusable `apt-publish` component from `ci-catalog`:

```yaml
include:
  - component: gitlab.com/devnw/ci-catalog/apt-publish@v1
    inputs:
      apt_domain: apt.geodedb.com
      vault_auth_role: codepros-ci
      vault_secret_path: geode/apt
```

This creates three jobs:

1. **`apt-sign-apt-geodedb-com`** - Signs .deb packages with GPG from Vault
2. **`apt-repo-apt-geodedb-com`** - Generates repository metadata (Packages, Release, InRelease)
3. **`apt-publish-apt-geodedb-com`** - Uploads to DigitalOcean Spaces

### Credential Flow

1. GitLab generates JWT token with `id_tokens` configuration
2. Job authenticates to Vault via `/v1/auth/gitlab-jwt/login`
3. Vault returns access token scoped to `geode/apt/*`
4. Job retrieves GPG key and S3 credentials from Vault
5. Signs packages and uploads to S3

### Triggering a Release

```bash
# Create and push a semantic version tag
git tag v0.1.4
git push origin v0.1.4
```

The pipeline runs on tags matching: `v?\d+\.\d+\.\d+(-.*)?`

## Manual Repository Management

### Sign Packages Locally

```bash
# Sign packages in dist/ directory
./scripts/packaging/sign-packages.sh --from-env dist/

# Or from Vault
export VAULT_ADDR="https://vault.example.com"
export VAULT_TOKEN="your-token"
./scripts/packaging/sign-packages.sh --from-vault dist/
```

### Generate Repository Locally

```bash
# Generate unsigned repository
./scripts/packaging/generate-apt-repo.sh dist/ apt-repo/

# Generate signed repository
export GPG_KEY_ID="ABC123DEF456"
./scripts/packaging/generate-apt-repo.sh dist/ apt-repo/ --sign
```

### Upload to Custom Server

If hosting on your own server instead of GitLab Pages:

```bash
# rsync to server
rsync -avz apt-repo/ user@server:/var/www/apt/

# Or use S3
aws s3 sync apt-repo/ s3://your-bucket/apt/ --acl public-read
```

## Key Rotation

### Rotating the GPG Key

1. Generate new key:

   ```bash
   ./scripts/packaging/setup-gpg-signing.sh --export --email packages@codepros.dev
   ```

2. Update GitLab CI variables with new key

3. Update Vault (if using):

   ```bash
   vault kv put secret/geode/debian-signing \
     private_key="$(cat new-private-key.asc)" \
     ...
   ```

4. Publish both old and new public keys during transition period

5. After transition, remove old key

### Key Expiry

Keys are generated with 2-year expiry by default. Monitor expiry:

```bash
gpg --list-keys packages@codepros.dev
```

## Supported Architectures

| Architecture | Debian Name | Description |
|--------------|-------------|-------------|
| x86_64 | amd64 | 64-bit Intel/AMD |
| ARM64 | arm64 | 64-bit ARM (Apple M1/M2, AWS Graviton) |
| ARMv7 | armhf | 32-bit ARM with hardware float |
| RISC-V 64 | riscv64 | 64-bit RISC-V |

## Troubleshooting

### "GPG error: The following signatures couldn't be verified"

The signing key isn't installed or has changed:

```bash
# Remove old key
sudo rm /usr/share/keyrings/geode-archive-keyring.gpg

# Re-add current key
curl -fsSL https://apt.geodedb.com/geode.gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/geode-archive-keyring.gpg
```

### "Package not found" after release

The GitLab Pages deployment may take a few minutes. Also verify:

```bash
# Check if packages exist
curl -s https://apt.geodedb.com/dists/stable/main/binary-amd64/Packages | head -20
```

### Signing fails in CI

Check that CI variables are correctly set:

```bash
# In CI job, verify variables exist
echo "GPG_KEY_ID: ${GPG_KEY_ID:-(not set)}"
echo "GPG_PRIVATE_KEY length: ${#GPG_PRIVATE_KEY}"
```

## Security Considerations

1. **Private keys**: Never commit private keys to the repository
2. **Vault**: Use Vault with AppRole authentication in production
3. **Protected variables**: Mark all signing-related CI variables as "Protected"
4. **Key backup**: Maintain secure offline backup of the GPG private key
5. **Audit**: Monitor CI logs for unauthorized signing attempts

## Alternative: GitLab Package Registry

GitLab also supports a native Debian repository in the Package Registry:

```bash
# Add GitLab as a package source (requires access token)
echo "deb https://gitlab.com/api/v4/projects/PROJECT_ID/packages/debian stable main" | \
  sudo tee /etc/apt/sources.list.d/geode-gitlab.list
```

This is used in addition to GitLab Pages for redundancy.

## References

- [Debian Repository Format](https://wiki.debian.org/DebianRepository/Format)
- [APT Secure](https://wiki.debian.org/SecureApt)
- [GitLab Pages](https://docs.gitlab.com/ee/user/project/pages/)
- [GitLab Package Registry - Debian](https://docs.gitlab.com/ee/user/packages/debian_repository/)
- [HashiCorp Vault](https://www.vaultproject.io/docs)
