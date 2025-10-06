# Geode Nix Configuration Guide

This directory contains comprehensive Nix configurations for packaging, deploying, and managing the Geode graph database daemon.

## 🗂️ Directory Structure

```
nix/
├── README.md                     # This file
├── modules/
│   ├── geode-daemon.nix          # NixOS module for Geode service
│   ├── config-validation.nix     # Configuration validation utilities  
│   └── systemd/
│       └── geode.service         # SystemD service template
├── packages/
│   ├── geode.nix                 # Main Geode package definition
│   ├── geode-docker.nix          # Docker image package
│   └── zcap.nix                  # Legacy compatibility package
└── templates/
    ├── geode-service/            # NixOS service template
    │   ├── flake.nix
    │   └── configuration.nix
    └── geode-dev/                # Development environment template
        └── flake.nix
```

## 🚀 Quick Start

### 1. Building Geode

```bash
# Build the default package
nix build

# Build debug version
nix build .#geode-debug

# Build static version  
nix build .#geode-static

# Build Docker image
nix build .#geode-docker
```

### 2. Running Geode

```bash
# Run directly
nix run

# Run with arguments
nix run . -- serve --help

# Run debug version
nix run .#geode-debug
```

### 3. Development Environment

```bash
# Enter development shell
nix develop

# Enter CI environment  
nix develop .#ci

# Enter deployment environment
nix develop .#deploy
```

## 📦 Package Variants

### geode (default)
Production-ready build with optimizations enabled:
- Optimization: ReleaseSafe
- QUIC support: Enabled
- Sentinel allocator: Disabled

### geode-debug  
Development build with debugging support:
- Optimization: Debug
- QUIC support: Enabled
- Sentinel allocator: Enabled
- Additional debugging symbols

### geode-static
Statically linked build for containers:
- Optimization: ReleaseSafe
- QUIC support: Enabled
- Static linking where possible

### geode-docker
Complete Docker image with:
- Minimal base system
- Self-signed certificate generation
- Health checks
- Volume mounts for data/logs/config

## 🔧 NixOS Module Usage

### Basic Configuration

Add to your `configuration.nix`:

```nix
{
  imports = [ <path-to-geode>/nix/modules/geode-daemon.nix ];
  
  services.geode = {
    enable = true;
    network.quicPort = 3141;
    performance.memoryLimit = "4GB";
    monitoring.enable = true;
  };
}
```

### Advanced Configuration

```nix
services.geode = {
  enable = true;
  
  # Network settings
  network = {
    listenAddress = "0.0.0.0";
    quicPort = 3141;
  };
  
  # Performance tuning
  performance = {
    maxConnections = 2000;
    workerThreads = 8;
    memoryLimit = "8GB";
  };
  
  # Storage configuration
  storage = {
    walSegmentSize = "256MB";
    checkpointInterval = "15m";
    pageSize = 16384;
  };
  
  # Enable federation
  federation = {
    enable = true;
    role = "shard";
    peers = [
      "coordinator1.example.com:3141"
      "coordinator2.example.com:3141"
    ];
  };
  
  # S3 backups
  backup = {
    enable = true;
    s3Bucket = "my-geode-backups";
    s3Region = "us-west-2";
    schedule = "0 3 * * *"; # Daily at 3 AM
  };
  
  # Change data capture
  cdc = {
    enable = true;
    webhookUrl = "https://api.myapp.com/geode-events";
    retention = "30d";
  };
  
  # Monitoring
  monitoring = {
    enable = true;
    metricsPort = 9090;
  };
  
  # Custom environment variables
  environment = {
    GEODE_DEBUG = "1";
    CUSTOM_VAR = "value";
  };
  
  # Additional configuration
  extraConfig = '''
    # Custom settings
    custom_option = "value"
  ''';
};
```

## 🔧 Configuration Options

### Core Settings
- `enable`: Enable the Geode service
- `user`/`group`: User/group to run as (default: `geode`)
- `dataDir`: Data directory (default: `/var/lib/geode`)
- `logDir`: Log directory (default: `/var/log/geode`)

### Network Configuration
- `network.listenAddress`: IP address to bind to
- `network.quicPort`: QUIC protocol port

### Performance Settings
- `performance.maxConnections`: Maximum concurrent connections
- `performance.workerThreads`: Number of worker threads (0 = auto)
- `performance.memoryLimit`: Memory limit (e.g., "4GB")

### TLS/Security
- `tls.certFile`: TLS certificate file path
- `tls.keyFile`: TLS private key file path  
- `tls.generateSelfSigned`: Auto-generate self-signed certs

### Storage Configuration
- `storage.walSegmentSize`: WAL segment size
- `storage.checkpointInterval`: Checkpoint frequency
- `storage.pageSize`: Database page size

### Federation (Optional)
- `federation.enable`: Enable federation mode
- `federation.role`: Role (`coordinator` or `shard`)
- `federation.peers`: List of peer addresses

### Backup (Optional)
- `backup.enable`: Enable S3 backups
- `backup.s3Bucket`: S3 bucket name
- `backup.s3Region`: S3 region
- `backup.schedule`: Backup schedule (cron format)

### CDC (Optional)
- `cdc.enable`: Enable Change Data Capture
- `cdc.webhookUrl`: Webhook URL for events
- `cdc.retention`: Event retention period

### Monitoring (Optional)
- `monitoring.enable`: Enable Prometheus metrics
- `monitoring.metricsPort`: Metrics endpoint port

## 🐳 Docker Usage

### Building the Image

```bash
# Build Docker image
nix build .#geode-docker

# Load into Docker
docker load < result

# Or use docker-compose
docker-compose up -d
```

### Running the Container

```bash
# Basic run
docker run -d \
  --name geode \
  -p 3141:3141/udp \
  -v geode-data:/var/lib/geode \
  -v geode-logs:/var/log/geode \
  geode:latest

# With custom config
docker run -d \
  --name geode \
  -p 3141:3141/udp \
  -v ./geode.conf:/etc/geode/geode.conf:ro \
  -v geode-data:/var/lib/geode \
  geode:latest

# Interactive shell
docker run -it geode:latest shell

# Run backup
docker run --rm \
  -v geode-data:/var/lib/geode \
  geode:latest backup --s3-bucket=my-backups
```

### Docker Compose

Use the generated `docker-compose.yml`:

```bash
nix run .#generate-docker-compose > docker-compose.yml
docker-compose up -d
```

## ☸️ Kubernetes Deployment

### Generate Manifests

```bash
# Generate Kubernetes manifests
nix run .#generate-k8s-manifests > geode-k8s.yml

# Apply to cluster
kubectl apply -f geode-k8s.yml
```

### Helm Chart (Future)

```bash
# Install via Helm (when available)
helm repo add geode https://charts.spyderorg.github.io/geode
helm install my-geode geode/geode
```

## 🛠️ Development

### Development Shell

The development shell provides:
- Zig compiler (0.15.1+)
- Go toolchain  
- QUIC libraries
- Debugging tools (gdb, valgrind)
- Network analysis tools (tcpdump, wireshark)
- Container tools (docker, podman)
- Monitoring tools (prometheus, grafana)

```bash
# Enter development environment
nix develop

# Available commands shown in shell hook
# Build, test, format, etc.
```

### Testing the Module

```bash
# Test NixOS module evaluation
nix flake check

# Build test configuration
nix build .#checks.nixos-module-test
```

### CI/CD Integration

```bash
# Minimal CI environment
nix develop .#ci

# Run tests in CI
nix flake check --all-systems
```

## 🔐 Security Considerations

### TLS Certificates
- Use `tls.generateSelfSigned = false` in production
- Provide proper certificates via `tls.certFile` and `tls.keyFile`
- Consider using Let's Encrypt or internal CA

### User Permissions
- Service runs as unprivileged `geode` user
- Strict systemd security settings applied
- File permissions properly configured

### Network Security
- Firewall rules automatically configured
- Only required ports opened
- Consider using VPN or private networks for federation

### Data Protection
- Regular backups to S3 (if enabled)
- WAL encryption supported
- Audit logging available

## 🔍 Monitoring and Observability

### Prometheus Metrics
When `monitoring.enable = true`:
- Metrics available at `http://localhost:9090/metrics`
- Includes database, network, and system metrics
- Compatible with Grafana dashboards

### Logging
- JSON-structured logs (configurable)
- Centralized in `logDir`
- Log rotation automatically configured
- Supports external log aggregation

### Health Checks
- Built-in health check endpoint
- Docker health checks configured
- Kubernetes readiness/liveness probes

## 🎯 Templates

### Service Template
Creates a complete NixOS configuration for Geode:

```bash
nix flake init -t github:spyderorg/geode#geode-service
```

### Development Template  
Sets up a development environment:

```bash
nix flake init -t github:spyderorg/geode#geode-dev
```

## 📚 Additional Resources

- [Geode Documentation](../docs/)
- [GQL Reference](../docs/TYPES_AND_FUNCTIONS.md)
- [Configuration Examples](../examples/)
- [Migration Guide](../migrations/)

## 🤝 Contributing

1. Test your changes: `nix flake check`
2. Format Nix code: `nix fmt`
3. Update documentation
4. Submit pull request

## 📄 License

MIT License - see [LICENSE](../LICENSE) for details.