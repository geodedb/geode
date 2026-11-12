# Nix Deployment Guide for Geode

This guide covers deploying and managing Geode using Nix, NixOS, and related tooling.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Package Variants](#package-variants)
- [NixOS Module](#nixos-module)
- [Docker Integration](#docker-integration)
- [Kubernetes Deployment](#kubernetes-deployment)
- [Development Environment](#development-environment)
- [Configuration Management](#configuration-management)
- [Security Considerations](#security-considerations)
- [Monitoring and Observability](#monitoring-and-observability)
- [Troubleshooting](#troubleshooting)

## Overview

Geode provides comprehensive Nix configuration for:

- **Package Management**: Multiple build variants (release, debug, static, docker)
- **NixOS Integration**: Full systemd service with 50+ configuration options
- **Container Support**: Docker images with security hardening
- **Development Tools**: Complete development environments
- **Infrastructure as Code**: Kubernetes and Docker Compose generation

### Architecture

```
Nix Configuration Structure
├── flake.nix                    # Main flake with all outputs
├── nix/
│   ├── packages/               # Package definitions
│   │   ├── geode.nix          # Main Geode package
│   │   ├── geode-docker.nix   # Docker image
│   │   └── zcap.nix           # Legacy compatibility
│   ├── modules/               # NixOS modules
│   │   ├── geode-daemon.nix   # Main service module
│   │   └── config-validation.nix # Configuration utilities
│   └── templates/             # Deployment templates
│       ├── geode-service/     # NixOS service template
│       └── geode-dev/         # Development template
```

## Quick Start

### 1. Building Geode

```bash
# Clone the repository
git clone https://gitlab.com/devnw/codepros/geode/geode.git
cd geode

# Build default package
nix build

# Build specific variants
nix build .#geode-debug     # Debug build
nix build .#geode-static    # Static build
nix build .#geode-docker    # Docker image
```

### 2. Running Geode

```bash
# Run directly with Nix
nix run

# Run with custom arguments
nix run . -- serve --help

# Run debug version
nix run .#geode-debug -- serve --log-level=debug
```

### 3. Development Environment

```bash
# Enter development shell
nix develop

# Available commands shown in shell:
# - make build, make test, make release
# - zig build, zig test
# - docker, docker-compose
# - prometheus, grafana
```

## Package Variants

### geode (default)

Production-ready optimized build:

```nix
# Build configuration
{
  optimize = "ReleaseSafe";
  enableQuic = true;
  enableSentinel = false;
  enableTests = true;
}
```

**Use cases**: Production deployments, containers, distribution

### geode-debug

Development build with debugging support:

```nix
# Build configuration  
{
  optimize = "Debug";
  enableQuic = true;
  enableSentinel = true;  # Memory debugging
  enableTests = true;
}
```

**Use cases**: Development, debugging, testing

### geode-static

Statically linked build for containers:

```nix
# Build configuration
{
  optimize = "ReleaseSafe";
  enableQuic = true;
  linkage = "static";  # Where possible
}
```

**Use cases**: Minimal containers, embedded systems

### geode-docker

Complete Docker image with runtime:

```nix
# Image features
{
  baseImage = "minimal";
  includeCA = true;
  autoGenerateCerts = true;
  healthChecks = true;
  securityHardening = true;
}
```

**Use cases**: Container orchestration, cloud deployments

## NixOS Module

### Basic Configuration

Add to your `configuration.nix`:

```nix
{
  # Import the Geode module
  imports = [
    (fetchGit {
      url = "https://gitlab.com/devnw/codepros/geode/geode";
      ref = "main";
    } + "/nix/modules/geode-daemon.nix")
  ];

  # Enable and configure Geode
  services.geode = {
    enable = true;

    # Basic network settings
    network = {
      listenAddress = "0.0.0.0";
      quicPort = 3141;
    };

    # Performance settings
    performance = {
      maxConnections = 1000;
      memoryLimit = "4GB";
    };

    # Enable monitoring
    monitoring.enable = true;
  };
}
```

### Production Configuration

```nix
services.geode = {
  enable = true;

  # Network configuration
  network = {
    listenAddress = "0.0.0.0";
    quicPort = 3141;
  };

  # Performance tuning for production
  performance = {
    maxConnections = 5000;
    workerThreads = 16;        # Or 0 for auto-detect
    memoryLimit = "16GB";
  };

  # Storage configuration
  storage = {
    walSegmentSize = "512MB";   # Larger segments for production
    checkpointInterval = "30m"; # Less frequent checkpoints
    pageSize = 16384;          # Larger pages for better performance
  };

  # TLS with real certificates
  tls = {
    generateSelfSigned = false;
    certFile = "/etc/ssl/certs/geode.crt";
    keyFile = "/etc/ssl/private/geode.key";
  };

  # Federation for distributed setup
  federation = {
    enable = true;
    role = "shard";           # or "coordinator"
    peers = [
      "coordinator1.prod.com:3141"
      "coordinator2.prod.com:3141"
    ];
  };

  # No backup option: geode has no S3 / object-storage backup (backups are
  # local files written by `geode backup create`; SONNY-6290). Schedule that
  # command yourself and copy the file with your own tool.

  # Change Data Capture
  cdc = {
    enable = true;
    webhookUrl = "https://api.prod.com/geode-events";
    retention = "30d";
  };

  # Monitoring and metrics
  monitoring = {
    enable = true;
    metricsPort = 9090;
  };

  # Logging configuration
  logging = {
    level = "info";           # Use "warn" or "error" for production
    json = true;              # Structured logging
  };

  # Environment variables
  environment = {
    GEODE_ENVIRONMENT = "production";
    RUST_LOG = "info";
  };

  # Additional configuration
  extraConfig = ''
    # Custom production settings
    query_timeout = "300s"
    connection_timeout = "60s"

    # Advanced tuning
    buffer_pool_size = "8GB"
    wal_buffer_size = "256MB"
  '';
};

# Additional production settings
systemd.services.geode = {
  # Resource limits
  serviceConfig = {
    MemoryMax = "20GB";       # Hard memory limit
    CPUQuota = "800%";        # 8 CPU cores max
    IOWeight = 500;           # I/O priority
  };

  # Restart policy
  startLimitBurst = 3;
  startLimitIntervalSec = 60;
};

# Monitoring integration
services.prometheus.scrapeConfigs = [
  {
    job_name = "geode";
    static_configs = [
      { targets = [ "localhost:9090" ]; }
    ];
    scrape_interval = "15s";
    metrics_path = "/metrics";
  }
];

# Log aggregation
services.promtail = {
  enable = true;
  configuration = {
    clients = [
      { url = "https://logs.prod.com/loki/api/v1/push"; }
    ];
    scrape_configs = [
      {
        job_name = "geode";
        static_configs = [
          {
            targets = [ "localhost" ];
            labels = {
              job = "geode";
              __path__ = "/var/log/geode/*.log";
            };
          }
        ];
      }
    ];
  };
};
```

### High Availability Configuration

```nix
# Multi-node cluster setup
services.geode = {
  enable = true;

  federation = {
    enable = true;
    role = "coordinator";     # Primary coordinator
    peers = [
      "geode-shard-1.internal:3141"
      "geode-shard-2.internal:3141"
      "geode-shard-3.internal:3141"
    ];
  };

  # Load balancing
  network = {
    listenAddress = "0.0.0.0";
    quicPort = 3141;
  };

  # Shared storage (if using NFS/distributed storage)
  dataDir = "/shared/geode/coordinator";

  # High availability settings
  extraConfig = ''
    # Cluster settings
    cluster_heartbeat_interval = "5s"
    cluster_election_timeout = "30s"
    cluster_replication_factor = 3

    # Consistency settings
    consistency_level = "quorum"
    read_preference = "primary_preferred"
  '';
};

# Load balancer configuration (HAProxy example)
services.haproxy = {
  enable = true;
  config = ''
    global
        daemon

    defaults
        mode tcp
        timeout connect 5000ms
        timeout client 50000ms
        timeout server 50000ms

    frontend geode_frontend
        bind *:3141
        default_backend geode_servers

    backend geode_servers
        balance roundrobin
        server coord1 geode-coord-1.internal:3141 check
        server coord2 geode-coord-2.internal:3141 check
        server coord3 geode-coord-3.internal:3141 check
  '';
};
```

## Docker Integration

### Building Docker Images

```bash
# Build Docker image with Nix
nix build .#geode-docker

# Load into Docker
docker load < result

# Tag and push (optional)
docker tag geode:latest myregistry.com/geode:latest
docker push myregistry.com/geode:latest
```

### Running Docker Containers

```bash
# Basic container run
docker run -d \
  --name geode \
  --restart unless-stopped \
  -p 3141:3141/udp \
  -v geode-data:/var/lib/geode \
  -v geode-logs:/var/log/geode \
  geode:latest serve

# With custom configuration
docker run -d \
  --name geode \
  -p 3141:3141/udp \
  -v ./geode.conf:/etc/geode/geode.conf:ro \
  -v geode-data:/var/lib/geode \
  -v geode-logs:/var/log/geode \
  -e GEODE_LOG_LEVEL=debug \
  geode:latest serve

# Interactive shell
docker run -it --rm geode:latest shell

# Health check
docker run --rm geode:latest health-check
```

### Docker Compose

Generate Docker Compose configuration:

```bash
# Generate compose file
nix eval --raw .#generators.dockerCompose > docker-compose.yml

# Or use template
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  geode:
    image: geode:latest
    container_name: geode-server
    restart: unless-stopped
    ports:
      - "3141:3141/udp"   # QUIC
      - "9090:9090"       # Metrics
    volumes:
      - geode-data:/var/lib/geode
      - geode-logs:/var/log/geode
      - ./config:/etc/geode:ro
    environment:
      - GEODE_LOG_LEVEL=info
      - GEODE_JSON_LOGS=true
    healthcheck:
      test: ["CMD", "geode", "health-check"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: '2.0'
        reservations:
          memory: 2G
          cpus: '1.0'

  prometheus:
    image: prom/prometheus:latest
    container_name: geode-prometheus
    restart: unless-stopped
    ports:
      - "9091:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'

  grafana:
    image: grafana/grafana:latest
    container_name: geode-grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin123
      - GF_USERS_ALLOW_SIGN_UP=false

volumes:
  geode-data:
  geode-logs:
  prometheus-data:
  grafana-data:
EOF

# Start services
docker-compose up -d

# View logs
docker-compose logs -f geode
```

## Kubernetes Deployment

### Generate Kubernetes Manifests

```bash
# Generate complete manifests
nix eval --raw .#generators.kubernetesDeployment > geode-k8s.yml
```

### Example Kubernetes Configuration

```yaml
# geode-namespace.yml
apiVersion: v1
kind: Namespace
metadata:
  name: geode
  labels:
    app: geode

---
# geode-configmap.yml
apiVersion: v1
kind: ConfigMap
metadata:
  name: geode-config
  namespace: geode
data:
  geode.conf: |
    data_dir = "/var/lib/geode"
    log_dir = "/var/log/geode"
    listen_quic = "0.0.0.0:3141"
    log_level = "info"
    log_json = true
    max_connections = 2000
    worker_threads = 0
    memory_limit = "4GB"

---
# geode-pvc.yml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: geode-data-pvc
  namespace: geode
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: fast-ssd

---
# geode-deployment.yml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: geode
  namespace: geode
  labels:
    app: geode
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: geode
  template:
    metadata:
      labels:
        app: geode
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: geode
        image: geode:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 3141
          name: quic
          protocol: UDP
        - containerPort: 9090
          name: metrics
          protocol: TCP
        env:
        - name: GEODE_CONFIG
          value: "/etc/geode/geode.conf"
        - name: GEODE_LOG_LEVEL
          value: "info"
        - name: GEODE_JSON_LOGS
          value: "true"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        volumeMounts:
        - name: geode-data
          mountPath: /var/lib/geode
        - name: geode-config
          mountPath: /etc/geode
          readOnly: true
        - name: geode-logs
          mountPath: /var/log/geode
        livenessProbe:
          exec:
            command:
            - geode
            - health-check
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
        readinessProbe:
          exec:
            command:
            - geode
            - health-check
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 2
        resources:
          requests:
            memory: "2Gi"
            cpu: "1000m"
          limits:
            memory: "8Gi"
            cpu: "4000m"
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          capabilities:
            drop:
            - ALL
      volumes:
      - name: geode-data
        persistentVolumeClaim:
          claimName: geode-data-pvc
      - name: geode-config
        configMap:
          name: geode-config
      - name: geode-logs
        emptyDir: {}
      terminationGracePeriodSeconds: 30

---
# geode-service.yml
apiVersion: v1
kind: Service
metadata:
  name: geode-service
  namespace: geode
  labels:
    app: geode
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
spec:
  type: LoadBalancer
  selector:
    app: geode
  ports:
  - name: quic
    port: 3141
    targetPort: 3141
    protocol: UDP
  - name: metrics
    port: 9090
    targetPort: 9090
    protocol: TCP

---
# geode-hpa.yml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: geode-hpa
  namespace: geode
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: geode
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

### Deploy to Kubernetes

```bash
# Apply all manifests
kubectl apply -f geode-k8s.yml

# Check deployment status
kubectl get pods -n geode
kubectl get services -n geode

# View logs
kubectl logs -n geode -l app=geode -f

# Port forward for testing
kubectl port-forward -n geode svc/geode-service 3141:3141

# Scale deployment
kubectl scale deployment geode -n geode --replicas=5
```

## Development Environment

### Standard Development Shell

```bash
# Enter development environment
nix develop

# Shell provides:
# - Zig 0.15.1+ compiler
# - Go toolchain for clients
# - QUIC libraries
# - Debugging tools (gdb, valgrind, strace)
# - Network tools (tcpdump, wireshark, netcat)
# - Container tools (docker, podman)
# - Monitoring tools (prometheus, grafana)
# - Documentation tools (mdbook, plantuml)
```

### Specialized Development Shells

```bash
# Minimal CI environment
nix develop .#ci
# Provides: zig, git, openssl, pkg-config

# Deployment environment  
nix develop .#deploy
# Provides: geode package, systemd, docker, kubectl, terraform
```

### Custom Development Environment

```nix
# In your project's flake.nix
{
  inputs.geode.url = "github:codeprosorg/geode";

  outputs = { self, nixpkgs, geode, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      devShells.default = pkgs.mkShell {
        inputsFrom = [ geode.devShells.x86_64-linux.default ];

        packages = with pkgs; [
          # Your additional tools
          jq
          curl
          postgresql
        ];

        shellHook = ''
          echo "🚀 Custom Geode Development Environment"

          # Set up local database
          export GEODE_DATA_DIR=./dev-data
          mkdir -p $GEODE_DATA_DIR

          # Custom aliases
          alias gd="geode --data-dir=$GEODE_DATA_DIR"
          alias gs="geode serve --data-dir=$GEODE_DATA_DIR"
        '';
      };
    };
}
```

## Configuration Management

### Configuration Validation

The Nix module includes comprehensive validation:

```nix
# Memory size validation
services.geode.performance.memoryLimit = "4GB";  # ✓ Valid
services.geode.performance.memoryLimit = "4000"; # ✗ Invalid

# Duration validation  
services.geode.storage.checkpointInterval = "10m"; # ✓ Valid
services.geode.storage.checkpointInterval = "600"; # ✗ Invalid

# Network address validation
services.geode.network.listenAddress = "0.0.0.0";     # ✓ Valid
services.geode.network.listenAddress = "localhost";   # ✓ Valid
services.geode.network.listenAddress = "invalid.ip";  # ✗ Invalid

# Port validation
services.geode.network.quicPort = 3141;  # ✓ Valid
services.geode.network.quicPort = 70000; # ✗ Invalid
```

### Configuration Templates

Generate configurations for different environments:

```bash
# Generate production config
nix eval --raw .#generators.geodeConfig.production

# Generate development config
nix eval --raw .#generators.geodeConfig.development

# Generate Docker Compose
nix eval --raw .#generators.dockerCompose

# Generate Kubernetes manifests
nix eval --raw .#generators.kubernetesDeployment
```

### Environment-Specific Configurations

```nix
# Development
services.geode = {
  enable = true;
  logging.level = "debug";
  performance.memoryLimit = "1GB";
  tls.generateSelfSigned = true;
  monitoring.enable = true;
};

# Staging
services.geode = {
  enable = true;
  logging.level = "info";
  performance.memoryLimit = "4GB";
  tls.generateSelfSigned = false;
  backup.enable = true;
  monitoring.enable = true;
};

# Production
services.geode = {
  enable = true;
  logging.level = "warn";
  performance.memoryLimit = "16GB";
  tls.generateSelfSigned = false;
  federation.enable = true;
  backup.enable = true;
  cdc.enable = true;
  monitoring.enable = true;
};
```

## Security Considerations

### NixOS Security Features

The Geode NixOS module implements comprehensive security:

```nix
# SystemD security settings (automatically applied)
systemd.services.geode.serviceConfig = {
  # Privilege restrictions
  NoNewPrivileges = true;
  PrivateTmp = true;
  ProtectSystem = "strict";
  ProtectHome = true;

  # Kernel protections
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectControlGroups = true;

  # Resource restrictions
  RestrictRealtime = true;
  RestrictSUIDSGID = true;
  RemoveIPC = true;

  # File system access
  ReadWritePaths = [ "/var/lib/geode" "/var/log/geode" ];
  ReadOnlyPaths = [ "/etc/geode" ];
};
```

### TLS Configuration

```nix
# Self-signed certificates (development)
services.geode.tls = {
  generateSelfSigned = true;
  certFile = "/etc/geode/server.crt";
  keyFile = "/etc/geode/server.key";
};

# Production certificates
services.geode.tls = {
  generateSelfSigned = false;
  certFile = "/etc/ssl/certs/geode.crt";
  keyFile = "/etc/ssl/private/geode.key";
};

# Let's Encrypt integration
security.acme = {
  acceptTerms = true;
  defaults.email = "admin@example.com";
  certs."geode.example.com" = {
    domain = "geode.example.com";
    dnsProvider = "cloudflare";
    credentialsFile = "/etc/nixos/cloudflare-credentials";
  };
};

services.geode.tls = {
  generateSelfSigned = false;
  certFile = "/var/lib/acme/geode.example.com/cert.pem";
  keyFile = "/var/lib/acme/geode.example.com/key.pem";
};
```

### Firewall Configuration

```nix
# Automatic firewall rules (applied by module)
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ 3141 9090 ];  # QUIC, Metrics
  allowedUDPPorts = [ 3141 ];       # QUIC
};

# Custom firewall rules
networking.firewall.extraCommands = ''
  # Rate limiting
  iptables -A INPUT -p udp --dport 3141 -m limit --limit 1000/sec -j ACCEPT
  iptables -A INPUT -p udp --dport 3141 -j DROP

  # Geo-blocking (example)
  iptables -A INPUT -p udp --dport 3141 -m geoip --src-cc CN,RU -j DROP
'';
```

### User and Permission Management

```nix
# Geode user configuration (automatically created)
users.users.geode = {
  isSystemUser = true;
  group = "geode";
  home = "/var/lib/geode";
  createHome = true;
  shell = pkgs.bash;
};

users.groups.geode = {};

# Additional security users
users.users.geode-backup = {
  isSystemUser = true;
  group = "geode-backup";
  # For backup operations only
};

# Sudo rules for administration
security.sudo.extraRules = [
  {
    users = [ "admin" ];
    commands = [
      {
        command = "/run/current-system/sw/bin/systemctl restart geode";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/systemctl status geode";
        options = [ "NOPASSWD" ];
      }
    ];
  }
];
```

## Monitoring and Observability

### Prometheus Integration

```nix
# Prometheus server configuration
services.prometheus = {
  enable = true;
  port = 9091;

  scrapeConfigs = [
    {
      job_name = "geode";
      static_configs = [
        {
          targets = [ "localhost:9090" ];
          labels = {
            instance = "geode-primary";
            environment = "production";
          };
        }
      ];
      scrape_interval = "15s";
      scrape_timeout = "10s";
      metrics_path = "/metrics";
    }

    {
      job_name = "geode-federation";
      static_configs = [
        { targets = [ "geode-shard-1:9090" ]; }
        { targets = [ "geode-shard-2:9090" ]; }
        { targets = [ "geode-shard-3:9090" ]; }
      ];
      scrape_interval = "30s";
    }
  ];

  rules = [
    ''
      groups:
      - name: geode
        rules:
        - alert: GeodeDown
          expr: up{job="geode"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Geode instance is down"
            description: "Geode instance {{ $labels.instance }} has been down for more than 5 minutes."

        - alert: GeodeHighMemoryUsage
          expr: (geode_memory_used_bytes / geode_memory_limit_bytes) * 100 > 90
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "Geode high memory usage"
            description: "Geode instance {{ $labels.instance }} is using {{ $value }}% of available memory."

        - alert: GeodeHighConnectionCount
          expr: geode_active_connections > geode_max_connections * 0.9
          for: 1m
          labels:
            severity: warning
          annotations:
            summary: "Geode high connection count"
            description: "Geode instance {{ $labels.instance }} has {{ $value }} active connections."
    ''
  ];
};
```

### Grafana Dashboard

```nix
services.grafana = {
  enable = true;
  settings = {
    server = {
      http_addr = "127.0.0.1";
      http_port = 3000;
      domain = "grafana.example.com";
    };

    security = {
      admin_user = "admin";
      admin_password = "$__file{/etc/grafana/admin_password}";
    };

    auth.anonymous = {
      enabled = true;
      org_role = "Viewer";
    };
  };

  provision = {
    enable = true;

    datasources.settings.datasources = [
      {
        name = "Prometheus";
        type = "prometheus";
        access = "proxy";
        url = "http://localhost:9091";
        isDefault = true;
      }
    ];

    dashboards.settings.providers = [
      {
        name = "geode";
        type = "file";
        options.path = "/etc/grafana/dashboards";
      }
    ];
  };
};

# Grafana dashboard configuration
environment.etc."grafana/dashboards/geode.json" = {
  text = builtins.toJSON {
    dashboard = {
      title = "Geode Database";
      panels = [
        {
          title = "Active Connections";
          type = "stat";
          targets = [
            {
              expr = "geode_active_connections";
              legendFormat = "{{ instance }}";
            }
          ];
        }
        {
          title = "Memory Usage";
          type = "graph";
          targets = [
            {
              expr = "geode_memory_used_bytes";
              legendFormat = "Used Memory";
            }
            {
              expr = "geode_memory_limit_bytes";
              legendFormat = "Memory Limit";
            }
          ];
        }
        {
          title = "Query Rate";
          type = "graph";
          targets = [
            {
              expr = "rate(geode_queries_total[5m])";
              legendFormat = "Queries/sec";
            }
          ];
        }
      ];
    };
  };
};
```

### Log Management

```nix
# Centralized logging with Loki
services.loki = {
  enable = true;
  configuration = {
    server.http_listen_port = 3100;

    auth_enabled = false;

    ingester = {
      lifecycler = {
        address = "127.0.0.1";
        ring = {
          kvstore.store = "inmemory";
          replication_factor = 1;
        };
      };
      chunk_idle_period = "1h";
      max_chunk_age = "1h";
      chunk_target_size = 1048576;
      chunk_retain_period = "30s";
    };

    schema_config = {
      configs = [
        {
          from = "2024-01-01";
          store = "boltdb-shipper";
          object_store = "filesystem";
          schema = "v11";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];
    };

    storage_config = {
      boltdb_shipper = {
        active_index_directory = "/var/lib/loki/boltdb-shipper-active";
        cache_location = "/var/lib/loki/boltdb-shipper-cache";
        shared_store = "filesystem";
      };

      filesystem = {
        directory = "/var/lib/loki/chunks";
      };
    };

    limits_config = {
      reject_old_samples = true;
      reject_old_samples_max_age = "168h";
    };
  };
};

# Promtail for log collection
services.promtail = {
  enable = true;
  configuration = {
    server = {
      http_listen_port = 3031;
      grpc_listen_port = 3032;
    };

    clients = [
      { url = "http://localhost:3100/loki/api/v1/push"; }
    ];

    scrape_configs = [
      {
        job_name = "geode";
        static_configs = [
          {
            targets = [ "localhost" ];
            labels = {
              job = "geode";
              __path__ = "/var/log/geode/*.log";
            };
          }
        ];

        pipeline_stages = [
          {
            json = {
              expressions = {
                timestamp = "timestamp";
                level = "level";
                message = "message";
                module = "module";
              };
            };
          }
          {
            timestamp = {
              source = "timestamp";
              format = "RFC3339";
            };
          }
          {
            labels = {
              level = "";
              module = "";
            };
          }
        ];
      }

      {
        job_name = "systemd";
        journal = {
          json = false;
          max_age = "12h";
          labels = {
            job = "systemd-journal";
            host = "geode-server";
          };
        };

        relabel_configs = [
          {
            source_labels = [ "__journal__systemd_unit" ];
            target_label = "unit";
          }
          {
            source_labels = [ "__journal__hostname" ];
            target_label = "hostname";
          }
        ];
      }
    ];
  };
};
```

### Alerting

```nix
# Alertmanager configuration
services.prometheus.alertmanager = {
  enable = true;

  configuration = {
    global = {
      smtp_smarthost = "localhost:587";
      smtp_from = "alerts@example.com";
    };

    route = {
      group_by = [ "alertname" ];
      group_wait = "10s";
      group_interval = "10s";
      repeat_interval = "1h";
      receiver = "web.hook";

      routes = [
        {
          match = {
            severity = "critical";
          };
          receiver = "critical";
          repeat_interval = "5m";
        }
      ];
    };

    receivers = [
      {
        name = "web.hook";
        webhook_configs = [
          {
            url = "http://localhost:5001/webhook";
            send_resolved = true;
          }
        ];
      }

      {
        name = "critical";
        email_configs = [
          {
            to = "admin@example.com";
            subject = "🚨 Critical Alert: {{ range .Alerts }}{{ .Annotations.summary }}{{ end }}";
            body = ''
              {{ range .Alerts }}
              Alert: {{ .Annotations.summary }}
              Description: {{ .Annotations.description }}
              Instance: {{ .Labels.instance }}
              Severity: {{ .Labels.severity }}
              {{ end }}
            '';
          }
        ];

        slack_configs = [
          {
            api_url = "https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK";
            channel = "#alerts";
            title = "Geode Alert";
            text = "{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}";
          }
        ];
      }
    ];
  };
};
```

## Troubleshooting

### Common Issues

#### 1. Build Failures

```bash
# Check Zig version
zig version  # Should be 0.15.1+

# Clean build cache
rm -rf zig-cache zig-out
nix build --rebuild

# Check for missing dependencies
nix flake check
```

#### 2. Service Start Failures

```bash
# Check systemd status
systemctl status geode
journalctl -u geode -f

# Check configuration
geode --config=/etc/geode/geode.conf --validate-config

# Check permissions
ls -la /var/lib/geode /var/log/geode /etc/geode
```

#### 3. Network Issues

```bash
# Check if QUIC port is open
ss -tulpn | grep 3141
netstat -ulpn | grep 3141

# Test connectivity
nc -u localhost 3141

# Check firewall
iptables -L -n | grep 3141
```

#### 4. Memory Issues

```bash
# Check memory usage
free -h
ps aux | grep geode

# Check systemd limits
systemctl show geode | grep Memory

# Monitor memory usage
watch -n 1 'ps -o pid,ppid,comm,rss,vsz $(pgrep geode)'
```

#### 5. Docker Issues

```bash
# Check container logs
docker logs geode -f

# Check container resource usage
docker stats geode

# Inspect container
docker inspect geode

# Enter container for debugging
docker exec -it geode /bin/bash
```

### Debug Mode

Enable debug mode for troubleshooting:

```nix
services.geode = {
  enable = true;
  logging.level = "debug";

  environment = {
    GEODE_DEBUG = "1";
    RUST_LOG = "debug";
    RUST_BACKTRACE = "1";
  };

  extraArgs = [
    "--debug"
    "--verbose"
  ];
};
```

### Performance Tuning

```nix
services.geode = {
  enable = true;

  performance = {
    maxConnections = 5000;
    workerThreads = 16;           # Set to number of CPU cores
    memoryLimit = "16GB";         # 70-80% of available RAM
  };

  storage = {
    walSegmentSize = "1GB";       # Larger for high-write workloads
    checkpointInterval = "1h";    # Less frequent for performance
    pageSize = 32768;            # Larger pages for analytical workloads
  };

  extraConfig = ''
    # Performance tuning
    buffer_pool_size = "12GB"     # 75% of memory limit
    wal_buffer_size = "512MB"
    max_wal_size = "4GB"

    # Connection pooling
    connection_pool_size = 100
    connection_timeout = "30s"

    # Query optimization
    query_cache_size = "1GB"
    query_timeout = "300s"

    # I/O optimization
    io_threads = 8
    sync_method = "fsync"
    wal_sync_method = "fdatasync"
  '';
};

# System-level optimizations
boot.kernel.sysctl = {
  # Network tuning
  "net.core.rmem_max" = 134217728;
  "net.core.wmem_max" = 134217728;
  "net.ipv4.udp_mem" = "102400 873800 16777216";

  # File system tuning
  "vm.dirty_ratio" = 15;
  "vm.dirty_background_ratio" = 5;
  "vm.swappiness" = 1;

  # Process limits
  "fs.file-max" = 2097152;
  "kernel.pid_max" = 4194304;
};
```

### Monitoring Health

```bash
# Health check script
#!/bin/bash
set -e

echo "🔍 Geode Health Check"
echo "===================="

# Service status
if systemctl is-active --quiet geode; then
  echo "✅ Service: Running"
else
  echo "❌ Service: Not running"
  exit 1
fi

# Port connectivity
if nc -z -u localhost 3141; then
  echo "✅ Network: Port 3141 accessible"
else
  echo "❌ Network: Port 3141 not accessible"
  exit 1
fi

# Database connectivity
if geode health-check; then
  echo "✅ Database: Responsive"
else
  echo "❌ Database: Not responsive"
  exit 1
fi

# Resource usage
MEM_USAGE=$(ps -o %mem --no-headers -p $(pgrep geode) | tr -d ' ')
if (( $(echo "$MEM_USAGE < 90" | bc -l) )); then
  echo "✅ Memory: ${MEM_USAGE}% usage"
else
  echo "⚠️  Memory: ${MEM_USAGE}% usage (high)"
fi

# Disk space
DISK_USAGE=$(df /var/lib/geode | tail -1 | awk '{print $5}' | sed 's/%//')
if (( DISK_USAGE < 90 )); then
  echo "✅ Disk: ${DISK_USAGE}% usage"
else
  echo "⚠️  Disk: ${DISK_USAGE}% usage (high)"
fi

echo "🎉 Health check completed successfully"
```

This comprehensive documentation provides everything needed to deploy, configure, and manage Geode using Nix in various environments from development to production.
