# Docker image definition for Geode
{ lib
, pkgs
, dockerTools
, geode
, buildEnv
, coreutils
, bash
, openssl
, ca-certificates
}:

let
  # Create a minimal environment with required tools
  geodeBinEnv = buildEnv {
    name = "geode-bin-env";
    paths = [
      geode
      coreutils
      bash
      openssl
      ca-certificates
    ];
  };

  # Create user and group setup script
  userSetupScript = pkgs.writeScript "setup-user" ''
    #!${bash}/bin/bash
    set -e
    
    # Create geode user and group
    ${coreutils}/bin/mkdir -p /etc
    echo "geode:x:1000:1000:Geode Database User:/var/lib/geode:/bin/bash" >> /etc/passwd
    echo "geode:x:1000:" >> /etc/group
    
    # Create necessary directories
    ${coreutils}/bin/mkdir -p /var/lib/geode /var/log/geode /etc/geode
    ${coreutils}/bin/chown -R 1000:1000 /var/lib/geode /var/log/geode
    ${coreutils}/bin/chmod 755 /var/lib/geode /var/log/geode
  '';

  # Default configuration file
  defaultConfig = pkgs.writeText "geode.conf" ''
    # Geode Docker Configuration
    data_dir = "/var/lib/geode"
    log_dir = "/var/log/geode"
    listen_quic = "0.0.0.0:8443"
    tls_cert = "/etc/geode/server.crt"
    tls_key = "/etc/geode/server.key"
    log_level = "info"
    log_json = true
    max_connections = 1000
    worker_threads = 0
  '';

  # Entry point script
  entrypoint = pkgs.writeScript "docker-entrypoint" ''
    #!${bash}/bin/bash
    set -e
    
    # Initialize if this is the first run
    if [ ! -f /var/lib/geode/.initialized ]; then
      echo "🔺 Initializing Geode database..."
      
      # Generate self-signed certificates if they don't exist
      if [ ! -f /etc/geode/server.crt ] || [ ! -f /etc/geode/server.key ]; then
        echo "Generating self-signed TLS certificates..."
        ${openssl}/bin/openssl req -x509 -newkey rsa:4096 \
          -keyout /etc/geode/server.key \
          -out /etc/geode/server.crt \
          -days 365 -nodes \
          -subj "/CN=geode-server"
        chmod 600 /etc/geode/server.key
        chmod 644 /etc/geode/server.crt
      fi
      
      # Mark as initialized
      touch /var/lib/geode/.initialized
      echo "✅ Geode initialization complete"
    fi
    
    # Handle different commands
    case "$1" in
      "serve"|"server"|"daemon")
        echo "🚀 Starting Geode server..."
        exec ${geode}/bin/geode serve \
          --config=/etc/geode/geode.conf \
          --data-dir=/var/lib/geode \
          "''${@:2}"
        ;;
      "shell"|"cli")
        echo "🔍 Starting Geode shell..."
        exec ${geode}/bin/geode shell "''${@:2}"
        ;;
      "backup")
        echo "💾 Running Geode backup..."
        exec ${geode}/bin/geode backup "''${@:2}"
        ;;
      "restore")
        echo "📥 Running Geode restore..."
        exec ${geode}/bin/geode restore "''${@:2}"
        ;;
      "migrate")
        echo "🔄 Running Geode migrations..."
        exec ${geode}/bin/geode migrate "''${@:2}"
        ;;
      "version"|"--version")
        exec ${geode}/bin/geode --version
        ;;
      "help"|"--help")
        exec ${geode}/bin/geode --help
        ;;
      *)
        # Pass through to geode binary
        exec ${geode}/bin/geode "$@"
        ;;
    esac
  '';

in
dockerTools.buildImage {
  name = "geode";
  tag = "latest";
  
  # Use a minimal base with just what we need
  copyToRoot = pkgs.buildEnv {
    name = "geode-container-root";
    paths = [
      geodeBinEnv
      defaultConfig
      userSetupScript
      entrypoint
      
      # Essential system files
      (pkgs.runCommand "container-etc" {} ''
        mkdir -p $out/etc
        echo "root:x:0:0:root:/root:/bin/bash" > $out/etc/passwd
        echo "geode:x:1000:1000:Geode User:/var/lib/geode:/bin/bash" >> $out/etc/passwd
        echo "root:x:0:" > $out/etc/group
        echo "geode:x:1000:" >> $out/etc/group
        
        mkdir -p $out/var/lib/geode $out/var/log/geode $out/etc/geode
        cp ${defaultConfig} $out/etc/geode/geode.conf
      '')
    ];
    pathsToLink = [ "/bin" "/etc" "/var" "/share" ];
  };
  
  # Run setup script during image build
  runAsRoot = ''
    #!${pkgs.runtimeShell}
    
    # Create necessary directories
    mkdir -p /var/lib/geode /var/log/geode /etc/geode /tmp
    
    # Set ownership and permissions
    chown -R 1000:1000 /var/lib/geode /var/log/geode
    chmod 755 /var/lib/geode /var/log/geode
    chmod 755 /etc/geode
    
    # Copy default configuration
    cp ${defaultConfig} /etc/geode/geode.conf
    
    # Make entrypoint executable
    chmod +x ${entrypoint}
  '';
  
  config = {
    # Run as geode user
    User = "1000:1000";
    
    # Entry point
    Entrypoint = [ "${entrypoint}" ];
    Cmd = [ "serve" ];
    
    # Expose ports
    ExposedPorts = {
      "8443/tcp" = {};
      "8443/udp" = {}; # QUIC
      "9090/tcp" = {}; # Metrics (if enabled)
    };
    
    # Environment variables
    Env = [
      "GEODE_CONFIG=/etc/geode/geode.conf"
      "GEODE_DATA_DIR=/var/lib/geode"
      "GEODE_LOG_DIR=/var/log/geode"
      "PATH=${geodeBinEnv}/bin"
    ];
    
    # Working directory
    WorkingDir = "/var/lib/geode";
    
    # Volume mounts
    Volumes = {
      "/var/lib/geode" = {};
      "/var/log/geode" = {};
      "/etc/geode" = {};
    };
    
    # Labels for metadata
    Labels = {
      "org.opencontainers.image.title" = "Geode Graph Database";
      "org.opencontainers.image.description" = "Open-source ACID-compliant graph database implementing ISO/IEC 39075:2024 GQL";
      "org.opencontainers.image.vendor" = "Spyder Organization";
      "org.opencontainers.image.version" = geode.version or "latest";
      "org.opencontainers.image.source" = "https://github.com/spyderorg/geode";
      "org.opencontainers.image.documentation" = "https://github.com/spyderorg/geode/docs";
      "org.opencontainers.image.licenses" = "MIT";
      
      # Geode-specific labels
      "geode.version" = geode.version or "latest";
      "geode.quic.enabled" = "true";
      "geode.tls.enabled" = "true";
    };
    
    # Health check
    Healthcheck = {
      Test = [ "CMD" "${geode}/bin/geode" "health-check" ];
      Interval = "30s";
      Timeout = "10s";
      Retries = 3;
      StartPeriod = "60s";
    };
  };
  
  meta = with lib; {
    description = "Docker image for Geode graph database";
    homepage = "https://github.com/spyderorg/geode";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}