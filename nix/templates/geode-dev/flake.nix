{
  description = "Geode Development Environment Template";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    geode.url = "github:spyderorg/geode";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, geode, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          name = "geode-development";
          
          inputsFrom = [ geode.devShells.${system}.default ];
          
          packages = with pkgs; [
            # Additional development tools
            git
            gh
            just
            direnv
            
            # Database tools
            sqlite
            postgresql
            
            # Monitoring tools
            htop
            iotop
            
            # Container tools
            podman
            buildah
          ];
          
          shellHook = ''
            echo "🚀 Geode Development Environment"
            echo "==============================="
            echo ""
            echo "Available commands:"
            echo "  nix build           - Build Geode"
            echo "  nix run             - Run Geode"
            echo "  nix develop .#ci    - CI environment"
            echo "  nix develop .#deploy - Deploy environment"
            echo ""
            echo "Geode-specific commands:"
            echo "  geode --help        - Show Geode help"
            echo "  geode serve         - Start Geode server"
            echo "  geode shell         - Interactive GQL shell"
            echo ""
            echo "Development tools:"
            echo "  make build          - Build using Makefile"
            echo "  make test           - Run tests"
            echo "  make fmt            - Format code"
            echo ""
            
            # Set up development environment
            export GEODE_DEV_MODE=1
            export GEODE_LOG_LEVEL=debug
            
            # Create development data directory
            mkdir -p ./dev-data/geode
            export GEODE_DATA_DIR=./dev-data/geode
          '';
          
          env = {
            GEODE_DEVELOPMENT = "1";
            RUST_LOG = "debug";
          };
        };
        
        packages.default = geode.packages.${system}.default;
      });
}