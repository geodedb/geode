# Example NixOS configuration for Geode service
{ config, pkgs, ... }:

{
  # Enable the Geode service
  services.geode = {
    enable = true;
    
    # Network configuration
    network = {
      listenAddress = "0.0.0.0";
      quicPort = 8443;
    };
    
    # Performance tuning
    performance = {
      maxConnections = 1000;
      workerThreads = 0; # Auto-detect
      memoryLimit = "4GB";
    };
    
    # Enable monitoring
    monitoring.enable = true;
    
    # Logging configuration
    logging = {
      level = "info";
      json = true;
    };
    
    # Storage configuration
    storage = {
      walSegmentSize = "128MB";
      checkpointInterval = "10m";
      pageSize = 8192;
    };
    
    # TLS configuration
    tls = {
      generateSelfSigned = true; # Set to false in production
      # certFile = "/path/to/cert.pem";
      # keyFile = "/path/to/key.pem";
    };
    
    # Optional: Enable federation
    # federation = {
    #   enable = true;
    #   role = "shard";
    #   peers = [ "coordinator.example.com:8443" ];
    # };
    
    # Optional: Enable backups
    # backup = {
    #   enable = true;
    #   s3Bucket = "my-geode-backups";
    #   s3Region = "us-east-1";
    #   schedule = "0 2 * * *"; # Daily at 2 AM
    # };
    
    # Optional: Enable CDC
    # cdc = {
    #   enable = true;
    #   webhookUrl = "https://api.example.com/webhooks/geode";
    #   retention = "7d";
    # };
  };
  
  # System configuration
  system.stateVersion = "25.05";
  
  # Basic system settings
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  
  # Network configuration
  networking = {
    hostName = "geode-server";
    firewall.enable = true;
    # Firewall ports are automatically opened by the Geode module
  };
  
  # Enable SSH for remote management
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
  
  # Time zone and locale
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";
  
  # User management
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "geode" ];
    openssh.authorizedKeys.keys = [
      # Add your SSH public key here
      # "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ... user@host"
    ];
  };
  
  # System monitoring (optional)
  services.prometheus = {
    enable = true;
    scrapeConfigs = [
      {
        job_name = "geode";
        static_configs = [
          { targets = [ "localhost:9090" ]; }
        ];
      }
    ];
  };
  
  # Log aggregation (optional)
  services.journalbeat = {
    enable = false; # Enable if you have ELK stack
    # Configuration for sending logs to Elasticsearch
  };
  
  # Automatic updates (optional)
  system.autoUpgrade = {
    enable = false; # Enable with caution in production
    dates = "04:00";
    allowReboot = false;
  };
}