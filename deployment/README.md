# Geode Deployment Files

This directory contains deployment configuration files for Geode Graph Database.

## Directory Structure

```
deployment/
├── systemd/           # Systemd service files
│   ├── geode.service      # Main service (single instance)
│   ├── geode@.service     # Template for multiple instances
│   └── geode-auth.service # Authentication management service
├── config/            # Configuration files
│   └── geode.conf         # Default configuration
└── scripts/           # Package installation scripts
    ├── preinstall.sh      # Pre-installation script
    ├── postinstall.sh     # Post-installation script
    ├── preremove.sh       # Pre-removal script
    └── postremove.sh      # Post-removal script
```

## Systemd Service Files

### Single Instance Mode

The main `geode.service` file runs a single Geode instance:

```bash
# Enable and start the service
sudo systemctl enable geode
sudo systemctl start geode

# Check status
sudo systemctl status geode

# View logs
sudo journalctl -u geode -f

# Stop the service
sudo systemctl stop geode
```

### Multiple Instance Mode

The `geode@.service` template allows running multiple Geode instances on different ports:

```bash
# Start instance on port 8443
sudo systemctl start geode@8443

# Start instance on port 8444
sudo systemctl start geode@8444

# Start instance on port 8445
sudo systemctl start geode@8445

# Check status of specific instance
sudo systemctl status geode@8443

# Stop specific instance
sudo systemctl stop geode@8443
```

Each instance:

- Uses a separate data directory: `/var/lib/geode/<port>`
- Listens on the specified port
- Has isolated logs: `geode-<port>`

### Authentication Service

The `geode-auth.service` manages authentication:

```bash
# Run authentication management
sudo systemctl start geode-auth

# Check status
sudo systemctl status geode-auth
```

## Configuration

### Default Configuration File

The default configuration is in `config/geode.conf`. Key settings:

```toml
[server]
listen = "0.0.0.0:8443"
data_dir = "/var/lib/geode"
log_level = "info"

[tls]
cert_dir = "/etc/geode/certs"
cert_file = "server.crt"
key_file = "server.key"

[security]
auth_enabled = true
audit_enabled = true
tde_enabled = true
rls_enabled = true
```

### Directory Locations

- **Data**: `/var/lib/geode`
- **Logs**: `/var/log/geode`
- **Config**: `/etc/geode/geode.conf`
- **Certificates**: `/etc/geode/certs/`
- **Binary**: `/usr/bin/geode`

## Manual Installation

If not using a package manager:

1. **Copy binaries**:

   ```bash
   sudo cp zig-out/bin/geode /usr/bin/
   sudo cp zig-out/bin/geode-auth /usr/bin/
   sudo chmod +x /usr/bin/geode /usr/bin/geode-auth
   ```

2. **Create user and directories**:

   ```bash
   sudo groupadd --system geode
   sudo useradd --system --gid geode --create-home \
       --home-dir /var/lib/geode --shell /bin/false geode

   sudo mkdir -p /var/log/geode /etc/geode/certs
   sudo chown -R geode:geode /var/lib/geode /var/log/geode /etc/geode/certs
   sudo chmod 750 /var/lib/geode
   sudo chmod 755 /etc/geode/certs
   sudo chmod 755 /var/log/geode
   ```

3. **Generate TLS certificates**:

   ```bash
   sudo openssl req -x509 -newkey rsa:4096 -nodes \
       -keyout /etc/geode/certs/server.key \
       -out /etc/geode/certs/server.crt \
       -days 365 -subj "/CN=localhost"

   sudo chown geode:geode /etc/geode/certs/server.*
   sudo chmod 600 /etc/geode/certs/server.key
   sudo chmod 644 /etc/geode/certs/server.crt
   ```

4. **Install systemd service**:

   ```bash
   sudo cp deployment/systemd/geode.service /lib/systemd/system/
   sudo cp deployment/systemd/geode@.service /lib/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable geode
   ```

5. **Install configuration**:

   ```bash
   sudo cp deployment/config/geode.conf /etc/geode/
   sudo chown root:geode /etc/geode/geode.conf
   sudo chmod 640 /etc/geode/geode.conf
   ```

## Package Installation

### Debian/Ubuntu (.deb)

```bash
# Download and install
wget https://gitlab.com/devnw/codepros/geode/geode/releases/download/v0.x.x/geode_0.x.x_Linux_x86_64.deb
sudo dpkg -i geode_0.x.x_Linux_x86_64.deb

# Start service
sudo systemctl start geode
```

### RHEL/Fedora (.rpm)

```bash
# Download and install
wget https://gitlab.com/devnw/codepros/geode/geode/releases/download/v0.x.x/geode_0.x.x_Linux_x86_64.rpm
sudo rpm -i geode_0.x.x_Linux_x86_64.rpm

# Start service
sudo systemctl start geode
```

### Alpine (.apk)

```bash
# Download and install
wget https://gitlab.com/devnw/codepros/geode/geode/releases/download/v0.x.x/geode_0.x.x_Linux_x86_64.apk
sudo apk add --allow-untrusted geode_0.x.x_Linux_x86_64.apk

# Start service (using OpenRC)
sudo rc-service geode start
sudo rc-update add geode
```

### Homebrew (macOS/Linux)

```bash
# Install from tap
brew install geodedb/geode/geode

# Start service (macOS)
brew services start geode

# Start service (Linux)
sudo systemctl start geode
```

## Docker Deployment

```bash
# Pull image
docker pull ghcr.io/codeprosorg/geode:latest

# Run with persistent storage
docker run -d \
  --name geode \
  -p 8443:8443/udp \
  -v geode-data:/data \
  -v geode-certs:/certs \
  ghcr.io/codeprosorg/geode:latest

# View logs
docker logs -f geode
```

## Distributed Deployment

For distributed setup, edit `/etc/geode/geode.conf`:

```toml
[distributed]
enabled = true
federation_nodes = "node1.example.com:8443,node2.example.com:8443,node3.example.com:8443"
```

Then start services on each node:

```bash
# On each node
sudo systemctl start geode
```

## QUIC Performance Optimizations

Geode uses QUIC+TLS for all network communication. For optimal throughput on high-bandwidth connections, configure the following system-level optimizations.

### UDP Buffer Sizes

QUIC transfers can be limited by UDP receive and send buffer sizes. Increase the maximum buffer size to ~7MB:

**Linux:**

```bash
# Apply immediately
sudo sysctl -w net.core.rmem_max=7340032
sudo sysctl -w net.core.wmem_max=7340032

# Persist across reboots (add to /etc/sysctl.d/99-geode-quic.conf)
cat << 'EOF' | sudo tee /etc/sysctl.d/99-geode-quic.conf
# Geode QUIC Performance Optimizations
net.core.rmem_max=7340032
net.core.wmem_max=7340032
EOF
sudo sysctl --system
```

**BSD/macOS:**

```bash
# Apply immediately (requires ~15% padding, so 7MB becomes ~8MB)
sudo sysctl -w kern.ipc.maxsockbuf=8441037

# Persist across reboots (add to /etc/sysctl.conf on BSD)
echo "kern.ipc.maxsockbuf=8441037" | sudo tee -a /etc/sysctl.conf
```

### Generic Segmentation Offload (GSO)

GSO allows the kernel to batch UDP packets, reducing syscall overhead. It's automatically enabled by quic-go on Linux kernel 4.18+.

- **No configuration required** - GSO is enabled automatically
- **To disable** (not recommended): Set environment variable `QUIC_GO_DISABLE_GSO=true`
- **Troubleshooting**: If you encounter GSO-related issues, check your kernel version (`uname -r`) and ensure it's 4.18+

### Path MTU Discovery (DPLPMTUD)

Path MTU Discovery probes the network path to find the optimal packet size, reducing per-packet overhead.

- **Enabled by default** in all Geode clients
- Sends fewer than 10 probe packets over a connection's lifetime
- Particularly beneficial on paths supporting MTUs larger than the minimum 1200 bytes
- Can be disabled per-connection if needed (see client documentation)

### Docker Deployments

When running Geode in Docker, pass sysctl settings:

```bash
# Single container
docker run --sysctl net.core.rmem_max=7340032 \
           --sysctl net.core.wmem_max=7340032 \
           geode:latest

# Or configure host sysctls (applies to all containers)
sudo sysctl -w net.core.rmem_max=7340032
sudo sysctl -w net.core.wmem_max=7340032
```

For docker-compose, the sysctls are already configured in the default `docker-compose.yml`.

## Security Hardening

### TLS Certificates

Replace self-signed certificates with proper CA-signed certificates:

```bash
# Copy your certificates
sudo cp your-cert.crt /etc/geode/certs/server.crt
sudo cp your-key.key /etc/geode/certs/server.key

# Set ownership and permissions
sudo chown geode:geode /etc/geode/certs/server.*
sudo chmod 600 /etc/geode/certs/server.key
sudo chmod 644 /etc/geode/certs/server.crt

# Restart service
sudo systemctl restart geode
```

### Firewall Configuration

```bash
# Allow QUIC port (UDP 8443)
sudo ufw allow 8443/udp

# Allow metrics port (TCP 9090)
sudo ufw allow 9090/tcp
```

### SELinux Configuration

For RHEL/CentOS with SELinux:

```bash
# Allow geode to bind to ports
sudo semanage port -a -t geode_port_t -p udp 8443
sudo semanage port -a -t geode_port_t -p tcp 9090

# Apply context to directories
sudo semanage fcontext -a -t geode_var_lib_t "/var/lib/geode(/.*)?"
sudo restorecon -R /var/lib/geode
```

## Monitoring

### Systemd Status

```bash
# Service status
systemctl status geode

# Resource usage
systemd-cgtop geode.service
```

### Journald Logs

```bash
# View all logs
sudo journalctl -u geode

# Follow logs
sudo journalctl -u geode -f

# Logs since boot
sudo journalctl -u geode -b

# Logs from last hour
sudo journalctl -u geode --since "1 hour ago"
```

### Metrics

Geode exposes metrics on port 9090:

```bash
# View metrics
curl http://localhost:9090/metrics
```

## Backup and Restore

### Backup

```bash
# Stop service
sudo systemctl stop geode

# Backup data directory
sudo tar -czf geode-backup-$(date +%Y%m%d).tar.gz /var/lib/geode

# Start service
sudo systemctl start geode
```

### Restore

```bash
# Stop service
sudo systemctl stop geode

# Restore from backup
sudo tar -xzf geode-backup-20250101.tar.gz -C /

# Fix permissions
sudo chown -R geode:geode /var/lib/geode

# Start service
sudo systemctl start geode
```

## Troubleshooting

### Service won't start

```bash
# Check logs
sudo journalctl -u geode -n 50 --no-pager

# Verify permissions
sudo ls -la /var/lib/geode
sudo ls -la /etc/geode/certs

# Verify configuration
/usr/bin/geode --version
sudo -u geode /usr/bin/geode serve --data-dir /var/lib/geode --log-level debug
```

### Port already in use

```bash
# Check what's using the port
sudo lsof -i :8443

# Or use ss
sudo ss -lunp | grep 8443
```

### Permission denied

```bash
# Verify geode user exists
id geode

# Verify directory ownership
sudo chown -R geode:geode /var/lib/geode /var/log/geode

# Verify SELinux context (if applicable)
ls -Z /var/lib/geode
```

## Uninstallation

### Package Removal

```bash
# Debian/Ubuntu
sudo apt remove geode

# RHEL/Fedora
sudo rpm -e geode

# Alpine
sudo apk del geode

# Homebrew
brew uninstall geode
```

### Complete Cleanup

To remove all data and configuration:

```bash
sudo systemctl stop geode
sudo systemctl disable geode
sudo rm -rf /var/lib/geode /var/log/geode /etc/geode
sudo userdel geode
sudo groupdel geode
```

## Support

- Documentation: <https://gitlab.com/devnw/codepros/geode/geode/tree/main/docs>
- Issues: <https://gitlab.com/devnw/codepros/geode/geode/issues>
- Discussions: <https://gitlab.com/devnw/codepros/geode/geode/discussions>
