#!/bin/bash
# Geode Deployment Setup Script
# Initializes environment for Docker Compose deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Geode Deployment Setup ===${NC}\n"

# Check prerequisites
echo "Checking prerequisites..."
command -v docker >/dev/null 2>&1 || { echo -e "${RED}Docker is required but not installed${NC}"; exit 1; }
command -v docker-compose >/dev/null 2>&1 || { echo -e "${RED}Docker Compose is required but not installed${NC}"; exit 1; }

echo -e "${GREEN}✓${NC} Docker and Docker Compose found\n"

# Create directories
echo "Creating directories..."
mkdir -p "$PROJECT_ROOT"/{certs,data,logs,backups}
mkdir -p "$PROJECT_ROOT"/config/{prometheus,grafana/{provisioning/datasources,provisioning/dashboards,dashboards},loki,promtail,nginx/conf.d,vault}

echo -e "${GREEN}✓${NC} Directories created\n"

# Generate TLS certificates if they don't exist
if [ ! -f "$PROJECT_ROOT/certs/server.crt" ]; then
    echo "Generating self-signed TLS certificates..."
    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout "$PROJECT_ROOT/certs/server.key" \
        -out "$PROJECT_ROOT/certs/server.crt" \
        -days 365 \
        -subj "/C=US/ST=State/L=City/O=Geode/CN=geode.local" \
        -addext "subjectAltName=DNS:geode.local,DNS:*.geode.local,IP:127.0.0.1"

    chmod 600 "$PROJECT_ROOT/certs/server.key"
    chmod 644 "$PROJECT_ROOT/certs/server.crt"

    echo -e "${GREEN}✓${NC} TLS certificates generated\n"
else
    echo -e "${YELLOW}⚠${NC}  TLS certificates already exist\n"
fi

# Create .env file if it doesn't exist
if [ ! -f "$PROJECT_ROOT/.env" ]; then
    echo "Creating .env file..."
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"

    # Generate random passwords
    VAULT_TOKEN=$(openssl rand -hex 16)
    MINIO_PASSWORD=$(openssl rand -base64 24)
    REDIS_PASSWORD=$(openssl rand -base64 24)
    GRAFANA_PASSWORD=$(openssl rand -base64 16)

    # Update .env with generated passwords (using | as delimiter to avoid conflicts with base64 / and +)
    sed -i "s|CHANGE-ME-minio-secret-key-12345|$MINIO_PASSWORD|g" "$PROJECT_ROOT/.env"
    sed -i "s|CHANGE-ME-redis-password-12345|$REDIS_PASSWORD|g" "$PROJECT_ROOT/.env"
    sed -i "s|CHANGE-ME-grafana-admin-12345|$GRAFANA_PASSWORD|g" "$PROJECT_ROOT/.env"
    sed -i "s|geode-dev-token-CHANGE-ME|$VAULT_TOKEN|g" "$PROJECT_ROOT/.env"

    echo -e "${GREEN}✓${NC} Environment file created with generated passwords\n"
    echo -e "${YELLOW}Important: Review and update $PROJECT_ROOT/.env with your settings${NC}\n"
else
    echo -e "${YELLOW}⚠${NC}  .env file already exists\n"
fi

# Update /etc/hosts for local development
if ! grep -q "geode.local" /etc/hosts 2>/dev/null; then
    echo -e "${YELLOW}Add the following to /etc/hosts for local development:${NC}"
    echo "127.0.0.1 geode.local grafana.geode.local prometheus.geode.local minio.geode.local vault.geode.local"
    echo ""
fi

# Create MinIO bucket initialization script
cat > "$PROJECT_ROOT/scripts/init-minio.sh" <<'EOF'
#!/bin/bash
# Initialize MinIO buckets
set -e

echo "Waiting for MinIO to be ready..."
until curl -sf http://minio:9000/minio/health/live > /dev/null 2>&1; do
    sleep 2
done

echo "Creating Geode backup bucket..."
mc alias set geode http://minio:9000 ${S3_ACCESS_KEY} ${S3_SECRET_KEY}
mc mb geode/geode-backups --ignore-existing
mc mb geode/geode-backups-gpu --ignore-existing

echo "Bucket policies: using default (private access only)"
# Security: Do NOT set anonymous download access on backup buckets.
# Use IAM policies or pre-signed URLs for controlled access.

echo "MinIO initialization complete"
EOF

chmod +x "$PROJECT_ROOT/scripts/init-minio.sh"

# Display next steps
echo -e "${GREEN}=== Setup Complete ===${NC}\n"
echo "Next steps:"
echo "1. Review and update .env file with your configuration"
echo "2. Start the stack:"
echo -e "   ${YELLOW}docker-compose up -d${NC}"
echo ""
echo "3. For GPU-accelerated deployment:"
echo -e "   ${YELLOW}docker-compose -f docker-compose.yml -f docker-compose.gpu.yml up -d${NC}"
echo ""
echo "4. Access the services:"
echo "   - Grafana: https://grafana.geode.local (admin/[check .env])"
echo "   - Prometheus: https://prometheus.geode.local"
echo "   - MinIO Console: https://minio.geode.local"
echo "   - Vault: https://vault.geode.local"
echo "   - Geode QUIC: udp://geode.local:8443"
echo ""
echo "5. Initialize Vault secrets:"
echo -e "   ${YELLOW}docker-compose exec vault vault operator init${NC}"
echo ""
echo -e "${GREEN}Documentation: See DEPLOYMENT.md for detailed instructions${NC}"
