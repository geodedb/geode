{
  description = "Geode Graph Database - Open-source ACID-compliant graph database implementing ISO/IEC 39075:2024 GQL";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
    dev-env.url = "github:spyderorg/dev-env";
    quic.url = "github:spyderorg/quic";
  };

  outputs =
    {
      self,
      nixpkgs,
      dev-env,
      quic,
      flake-utils,
      ...
    }:
    let
      flakeForSystem =
        nixpkgs: system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = { allowUnfree = true; };
            overlays = [ self.overlays.default ];
          };

          zigPkg = dev-env.packages.${system}.zigPackages;
          quicPkg = quic.packages.${system}.quic;
          quicDebugPkg = quic.packages.${system}.quic-debug;

          # Geode package variants
          geodePackage = pkgs.callPackage ./nix/packages/geode.nix {
            zig = zigPkg;
            quic = quicPkg;
            enableOptimization = true;
            enableQuic = true;
          };

          geodeDebugPackage = pkgs.callPackage ./nix/packages/geode.nix {
            zig = zigPkg;
            quic = quicDebugPkg;
            enableOptimization = false;
            enableQuic = true;
            enableSentinel = true;
          };

          geodeStaticPackage = pkgs.callPackage ./nix/packages/geode.nix {
            zig = zigPkg;
            quic = quicPkg;
            enableOptimization = true;
            enableQuic = true;
          };

          # Build zcap packages for compatibility (if needed)
          zcapPkg = pkgs.callPackage ./nix/packages/zcap.nix {
            zig = zigPkg;
            optimize = "ReleaseFast";
            enableXdp = false;
          };
          
          # Development shell packages
          devShellPackages = [
            quicPkg
            quicDebugPkg
            zigPkg
            pkgs.tcpdump
            pkgs.file
            pkgs.openssl
            pkgs.pkg-config
            pkgs.docker
            pkgs.docker-compose
            pkgs.systemd
            pkgs.prometheus
            pkgs.grafana
            pkgs.zig-zlint
          ];

          # Documentation packages
          docs = pkgs.stdenv.mkDerivation {
            name = "geode-docs";
            src = ./docs;
            buildCommand = ''
              mkdir -p $out/share/doc/geode
              cp -r $src/* $out/share/doc/geode/
            '';
          };

          # Python environment for geodetestlab
          pythonWithPackages = pkgs.python3.withPackages (ps: with ps; [
            typer
            pydantic
            rich
            jmespath
            psutil
            keyring
            pyyaml
            pytest
            mypy
            black
            isort
            flake8
          ]);

          # Geodetestlab package
          geodetestlab = pkgs.python3Packages.buildPythonApplication {
            pname = "geodetestlab";
            version = "0.1.0";
            src = ./geodetestlab;
            
            pyproject = true;
            build-system = [ pkgs.python3Packages.setuptools ];
            
            dependencies = with pkgs.python3Packages; [
              typer
              pydantic
              rich
              jmespath
              psutil
              keyring
              pyyaml
            ];
            
            nativeCheckInputs = with pkgs.python3Packages; [
              pytest
              mypy
              black
              isort
              flake8
            ];
            
            checkPhase = ''
              python -m pytest tests/ -v
            '';
            
            meta = {
              description = "CLI testing framework for Geode graph database";
              license = pkgs.lib.licenses.mit;
            };
          };

        in
        {
          packages = {
            # Main Geode packages
            geode = geodePackage;
            geode-debug = geodeDebugPackage;
            geode-static = geodeStaticPackage;
            
            # Legacy compatibility
            zcap = zcapPkg;
            zcap-static = zcapPkg;
            
            # Documentation
            docs = docs;
            
            # Python packages
            python-with-packages = pythonWithPackages;
            geodetestlab = geodetestlab;
            
            # Default package
            default = geodePackage;
          };

          # Development shell with all necessary tools
          devShells = {
            default = pkgs.mkShell {
              name = "geode-dev";
              shellHook = ''
                echo "🔺 Geode Development Environment"
                echo "Zig version: $(zig version)"
                echo "Available commands:"
                echo "  make build      - Build Geode"
                echo "  make test       - Run tests"
                echo "  make release    - Build release version"
                echo "  make serve      - Start development server"
                echo "  nix run         - Run Geode daemon"
                echo ""
                echo "For NixOS module usage, see: ./nix/modules/geode-daemon.nix"
              '';
              
              env = {
                GEODE_DEV = "1";
                GEODE_NIX_BUILD = "1";
              };
              
              packages = builtins.filter (p: p != null) (
                (with dev-env.packages.${system}; [
                  zigPackages
                  goPackages
                  commonPackages
                ])
                ++ (with pkgs; [
                  # Core development tools
                  strace
                  file
                  pkg-config
                  openssl
                  zlib
                  libuv
                  
                  # Debugging and analysis
                  gdb
                  valgrind
                  strace
                  
                  # Network tools
                  tcpdump
                  wireshark-cli
                  netcat-gnu
                  
                  # Container and orchestration
                  docker
                  docker-compose
                  
                  # Monitoring and observability
                  prometheus
                  grafana
                  
                  # Documentation and development
                  mdbook
                  plantuml
                  
                  # Python environment for geodetestlab
                  pythonWithPackages
                  zig-zlint
                  
                  # Platform specific
                  (if pkgs.stdenv.isLinux then glibc else null)
                  (if system == "x86_64-linux" then wine else null)
                ])
              );
            };

            # Minimal shell for CI/automation
            ci = pkgs.mkShell {
              name = "geode-ci";
              packages = [
                zigPkg
                pkgs.git
                pkgs.openssl
                pkgs.pkg-config
                pythonWithPackages
              ];
            };
            
            # Python development shell for geodetestlab
            python = pkgs.mkShell {
              name = "geodetestlab-dev";
              packages = [
                pythonWithPackages
                geodePackage
              ];
              shellHook = ''
                echo "🐍 Geodetestlab Development Environment"
                echo "Python version: $(python --version)"
                echo "Available commands:"
                echo "  geodetestlab --help     - Show geodetestlab help"
                echo "  pytest                  - Run tests"
                echo "  python -m geodetestlab.cli - Run CLI directly"
                echo ""
              '';
            };

            # Production deployment shell
            deploy = pkgs.mkShell {
              name = "geode-deploy";
              packages = [
                geodePackage
                pkgs.systemd
                pkgs.openssl
                pkgs.docker
                pkgs.kubectl
                pkgs.terraform
              ];
            };
          };

          # Apps for easy running
          apps = {
            geode = {
              type = "app";
              program = "${geodePackage}/bin/geode";
            };
            
            geode-debug = {
              type = "app";
              program = "${geodeDebugPackage}/bin/geode";
            };
            
            geodetestlab = {
              type = "app";
              program = "${geodetestlab}/bin/geodetestlab";
            };
            
            default = {
              type = "app";
              program = "${geodePackage}/bin/geode";
            };
          };

          # NixOS module
          nixosModules.geode = import ./nix/modules/geode-daemon.nix;

          # Formatter
          formatter = pkgs.nixpkgs-fmt;

          # Checks for CI
          checks = {
            # Package builds
            geode-package = geodePackage;
            geode-debug-package = geodeDebugPackage;
            geodetestlab-package = geodetestlab;
            
            # Module evaluation test
            nixos-module-test = pkgs.nixos {
              imports = [ self.nixosModules.geode ];
              services.geode.enable = true;
            };
            
            # Static analysis
            nix-lint = pkgs.runCommand "nix-lint" { } ''
              ${pkgs.statix}/bin/statix check ${./.}
              touch $out
            '';
          };
        };

      # System-independent outputs
      systemAgnosticOutputs = {
        # Overlay for adding Geode to nixpkgs
        overlays.default = final: prev: {
          geode = final.callPackage ./nix/packages/geode.nix {
            zig = final.zig;
          };
        };

        # NixOS modules
        nixosModules = {
          geode = import ./nix/modules/geode-daemon.nix;
          default = import ./nix/modules/geode-daemon.nix;
        };

        # Templates for new projects
        templates = {
          geode-service = {
            path = ./nix/templates/geode-service;
            description = "NixOS configuration template for Geode service";
          };
          
          geode-dev = {
            path = ./nix/templates/geode-dev;
            description = "Development environment template for Geode";
          };
        };

        # Hydra jobsets
        hydraJobs = nixpkgs.lib.mapAttrs (system: packages: packages) self.packages;
      };

    in
    flake-utils.lib.eachDefaultSystem (system: flakeForSystem nixpkgs system)
    // systemAgnosticOutputs;

  nixConfig = {
    extra-substituters = [ "https://spyder.cachix.org" ];
    extra-trusted-public-keys = [
      "spyder.cachix.org-1:xZG2a8INH6yNyOAwtN2Ojjys0GO9D1pXEe3PNriT04E="
    ];
  };
}
