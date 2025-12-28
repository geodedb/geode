# Geode Graph Database - Production Deployment Guide

## Overview

This guide covers deploying Geode using Docker Compose with a complete production infrastructure stack including:

- **Geode Database** - Graph database with QUIC+TLS transport
- **HashiCorp Vault** - Secrets management and encryption key storage
- **MinIO** - S3-compatible object storage for backups
- **Redis** - Caching layer
- **Prometheus** - Metrics collection
- **Grafana** - Metrics visualization
- **Loki + Promtail** - Log aggregation
- **Nginx** - Reverse proxy

## Quick Start

### Prerequisites

- Docker 20.10+
- Docker Compose 1.29+
- 8GB RAM minimum (16GB recommended)
- 50GB disk space
- For GPU version: NVIDIA GPU with drivers + nvidia-docker2

### 1. Initial Setup

```bash
# Run setup script
./scripts/setup-deployment.sh

# Review and update environment variables
vi .env

# Add to /etc/hosts (for local development)
echo "127.0.0.1 geode.local grafana.geode.local prometheus.geode.local minio.geode.local vault.geode.local" | sudo tee -a /etc/hosts
```

### 2. Start the Stack

**Non-GPU deployment:**
```bash
docker-compose up -d
```

**GPU-accelerated deployment:**
```bash
docker-compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
```

### 3. Verify Services

```bash
# Check all services are running
docker-compose ps

# Check Geode logs
docker-compose logs -f geode

# Test Geode connectivity
docker-compose exec geode geode query "RETURN 1 AS health" --server 127.0.0.1:8443
```

### 4. Access Web Interfaces

- **Grafana**: https://grafana.geode.local
  - Username: `admin`
  - Password: Check `.env` file

- **Prometheus**: https://prometheus.geode.local

- **MinIO Console**: https://minio.geode.local
  - Username: Check `.env` file (`S3_ACCESS_KEY`)
  - Password: Check `.env` file (`S3_SECRET_KEY`)

- **Vault UI**: https://vault.geode.local
  - Token: Check `.env` file (`VAULT_TOKEN`)

## Configuration

### Environment Variables

All configuration is managed through `.env` file:

```bash
# Geode Configuration
GEODE_LOG_LEVEL=info           # Log level: debug, info, warn, error
GEODE_DATA_DIR=/data           # Data directory path
GEODE_LISTEN_ADDR=0.0.0.0:8443 # Listen address

# Vault Configuration
VAULT_ADDR=http://vault:8200
VAULT_TOKEN=<generated-token>

# MinIO/S3 Configuration
S3_ENDPOINT=http://minio:9000
S3_ACCESS_KEY=geode-minio-admin
S3_SECRET_KEY=<generated-password>
S3_BUCKET=geode-backups

# Redis Configuration
REDIS_PASSWORD=<generated-password>

# Grafana Configuration
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=<generated-password>
```

### TLS Certificates

#### Self-Signed Certificates (Development)

Generated automatically by setup script:
```bash
./scripts/setup-deployment.sh
```

#### Production Certificates

Replace self-signed certificates with CA-signed certificates:

```bash
# Copy your certificates
cp /path/to/server.crt certs/server.crt
cp /path/to/server.key certs/server.key

# Set proper permissions
chmod 600 certs/server.key
chmod 644 certs/server.crt

# Restart services
docker-compose restart geode nginx
```

## Vault Setup

### Initialize Vault (First Time Only)

```bash
# Initialize Vault
docker-compose exec vault vault operator init

# Save the unseal keys and root token securely!

# Unseal Vault (required after every restart)
docker-compose exec vault vault operator unseal <key-1>
docker-compose exec vault vault operator unseal <key-2>
docker-compose exec vault vault operator unseal <key-3>
```

### Configure Vault for Geode

```bash
# Login to Vault
docker-compose exec vault vault login

# Enable KV secrets engine
docker-compose exec vault vault secrets enable -path=geode kv-v2

# Store encryption keys
docker-compose exec vault vault kv put geode/encryption \
  master_key="$(openssl rand -base64 32)" \
  data_key="$(openssl rand -base64 32)"

# Create policy for Geode
cat <<EOF | docker-compose exec -T vault vault policy write geode-policy -
path "geode/*" {
  capabilities = ["read", "list"]
}
EOF

# Create token for Geode
docker-compose exec vault vault token create -policy=geode-policy
```

## MinIO Configuration

### Create Backup Buckets

```bash
# Access MinIO container
docker-compose exec minio sh

# Configure mc (MinIO client)
mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD

# Create buckets
mc mb local/geode-backups
mc mb local/geode-backups-gpu

# Set retention policy (30 days)
mc retention set --default GOVERNANCE 30d local/geode-backups
```

### Configure Lifecycle Policies

```bash
# Create lifecycle policy
cat <<EOF > /tmp/lifecycle.json
{
  "Rules": [
    {
      "Expiration": {
        "Days": 30
      },
      "ID": "DeleteOldBackups",
      "Status": "Enabled"
    }
  ]
}
EOF

# Apply policy
docker cp /tmp/lifecycle.json geode-minio:/tmp/
docker-compose exec minio sh -c "mc ilm import local/geode-backups < /tmp/lifecycle.json"
```

## Monitoring

### Grafana Dashboards

Pre-configured dashboards are available in `config/grafana/dashboards/`:

1. **Geode Overview** - Database performance metrics
2. **GPU Metrics** - GPU utilization (for GPU deployment)
3. **System Metrics** - Infrastructure health
4. **Logs Dashboard** - Centralized log viewing

### Custom Alerts

Add Prometheus alerting rules in `config/prometheus/alerts/`:

```yaml
# config/prometheus/alerts/geode.yml
groups:
  - name: geode_alerts
    interval: 30s
    rules:
      - alert: GeodeHighMemoryUsage
        expr: geode_memory_usage_percent > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Geode high memory usage"
          description: "Memory usage is {{ $value }}%"

      - alert: GeodeDown
        expr: up{job="geode"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Geode is down"
          description: "Geode database is not responding"
```

## Backup and Recovery

### Automated Backups

Geode automatically backs up to MinIO/S3 when configured:

```bash
# Trigger manual backup
docker-compose exec geode geode backup --dest s3://geode-backups/manual-$(date +%Y%m%d)

# List backups
docker-compose exec minio mc ls local/geode-backups
```

### Restore from Backup

```bash
# Stop Geode
docker-compose stop geode

# Restore data
docker-compose exec geode geode restore --source s3://geode-backups/backup-20231215

# Start Geode
docker-compose start geode
```

### Volume Backups

```bash
# Backup volumes
docker run --rm \
  -v geode_geode-data:/data \
  -v $(pwd)/backups:/backup \
  alpine tar czf /backup/geode-data-$(date +%Y%m%d).tar.gz -C /data .

# Restore volumes
docker run --rm \
  -v geode_geode-data:/data \
  -v $(pwd)/backups:/backup \
  alpine tar xzf /backup/geode-data-20231215.tar.gz -C /data
```

## Scaling

### Horizontal Scaling

```bash
# Scale Geode instances
docker-compose up -d --scale geode=3

# Update nginx upstream configuration
# Edit config/nginx/conf.d/geode.conf to add load balancing
```

### Resource Limits

Update `docker-compose.yml` to set resource limits:

```yaml
services:
  geode:
    deploy:
      resources:
        limits:
          cpus: '4.0'
          memory: 8G
        reservations:
          cpus: '2.0'
          memory: 4G
```

## GPU Deployment

### Requirements

```bash
# Install NVIDIA Container Toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-docker.list

sudo apt-get update
sudo apt-get install -y nvidia-docker2
sudo systemctl restart docker

# Verify GPU is available
docker run --rm --gpus all nvidia/cuda:12.3.0-base-ubuntu22.04 nvidia-smi
```

### Deploy GPU Stack

```bash
# Start GPU-accelerated deployment
docker-compose -f docker-compose.yml -f docker-compose.gpu.yml up -d

# Verify GPU metrics
curl http://localhost:9400/metrics | grep dcgm
```

## Troubleshooting

### Check Service Health

```bash
# View all service statuses
docker-compose ps

# Check specific service logs
docker-compose logs -f geode
docker-compose logs -f vault
docker-compose logs -f prometheus

# Check resource usage
docker stats
```

### Common Issues

#### Geode Won't Start

```bash
# Check logs
docker-compose logs geode

# Verify certificates
ls -l certs/

# Test connectivity
docker-compose exec geode ping vault
```

#### Vault Sealed

```bash
# Unseal Vault
docker-compose exec vault vault operator unseal
```

#### MinIO Access Denied

```bash
# Check credentials in .env
cat .env | grep S3_

# Verify MinIO is running
docker-compose ps minio
```

#### GPU Not Detected

```bash
# Verify NVIDIA runtime
docker run --rm --gpus all nvidia/cuda:12.3.0-base-ubuntu22.04 nvidia-smi

# Check Docker daemon configuration
cat /etc/docker/daemon.json
```

## Maintenance

### Update Services

```bash
# Pull latest images
docker-compose pull

# Recreate containers with new images
docker-compose up -d

# Clean up old images
docker image prune -a
```

### Clean Up Logs

```bash
# Rotate logs
docker-compose exec promtail logrotate /etc/logrotate.d/geode

# Clean old Loki data
docker-compose exec loki find /loki/chunks -mtime +30 -delete
```

### Database Maintenance

```bash
# Vacuum database
docker-compose exec geode geode admin vacuum

# Analyze statistics
docker-compose exec geode geode admin analyze

# Check integrity
docker-compose exec geode geode admin check
```

## Security Best Practices

1. **Change default passwords** in `.env` file
2. **Use production TLS certificates** from a trusted CA
3. **Enable Vault auto-unseal** with cloud KMS
4. **Configure firewall rules** to restrict access
5. **Enable audit logging** in Vault and Geode
6. **Regularly update images** for security patches
7. **Use secrets rotation** for credentials
8. **Enable network encryption** between services
9. **Implement backup encryption** for S3 backups
10. **Use RBAC** for Grafana and Prometheus

## Production Checklist

- [ ] Updated `.env` with production credentials
- [ ] Installed production TLS certificates
- [ ] Initialized and configured Vault
- [ ] Configured MinIO with lifecycle policies
- [ ] Set up Grafana dashboards and alerts
- [ ] Tested backup and restore procedures
- [ ] Configured firewall rules
- [ ] Set up monitoring and alerting
- [ ] Documented disaster recovery procedures
- [ ] Tested failover scenarios
- [ ] Enabled audit logging
- [ ] Configured log rotation
- [ ] Set up automated backups
- [ ] Performed security hardening
- [ ] Load tested the deployment

## Support

For issues and questions:
- Documentation: `./docs/`
- Issues: GitHub Issues
- Community: Discord/Slack

---

*Last Updated: November 16, 2025*
*Version: 1.0.0*
