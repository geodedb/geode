{
  description = "Geode Graph Database - Open-source ACID-compliant graph database implementing ISO/IEC 39075:2024 GQL";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    dev-env.url = "github:devnw/dev-env";
    quic.url = "gitlab:devnw/zig/quic";
  };

  outputs =
    {
      self,
      nixpkgs,
      unstable,
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

          unstablePkgs = import unstable {
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
            pkgs.libmsquic
            pkgs.pkg-config
            pkgs.docker
            pkgs.docker-compose
            pkgs.systemd
            pkgs.prometheus
            pkgs.grafana
            pkgs.yq # Command-line YAML/XML/TOML processor - jq wrapper for YAML, XML, TOML documents
            pkgs.pdftk # Command-line tool for working with PDFs
            pkgs.pdfid # Scan a file to look for certain PDF keywords
            pkgs.vulkan-loader
            pkgs.vulkan-headers
            pkgs.vulkan-utility-libraries
            pkgs.glslang
            pkgs.cudaPackages.libnpp
            unstablePkgs.zig-zlint
            pkgs.glibc.dev # Required for building quiche/BoringSSL with C++ stdlib
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

          # Python environment for geodetestlab and client test harness
          pythonWithPackages = pkgs.python3.withPackages (ps: with ps; [
            pip
            cffi
            setuptools
            wheel
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
            aioquic
            cryptography
            pyopenssl
            service-identity
            python-lsp-server
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
              license = pkgs.lib.licenses.asl20;
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
                # --- Python path --------------------------------------------------------------
                # Use the Python 3 environment with all required packages (cffi, aioquic, etc)
                # This ensures we use Python 3.12 with cffi instead of the system Python 3.13
                export PATH="${pythonWithPackages}/bin:$PATH"

                # Reset PYTHONPATH safely, then prepend the env's site-packages if it exists.
                export PYTHONPATH=''${PYTHONPATH:-""}
                if [ -d "${pythonWithPackages}/${pythonWithPackages.sitePackages}" ]; then
                  export PYTHONPATH="${pythonWithPackages}/${pythonWithPackages.sitePackages}:$PYTHONPATH"
                fi

                # --- C/C++ compiler flags for glibc -------------------------------------------
                # Required for building C/C++ projects (like quiche's BoringSSL) with proper glibc headers
                # Use -idirafter to append glibc includes after C++ stdlib, avoiding #include_next issues
                export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-""}"
                export NIX_CXXFLAGS_COMPILE="''${NIX_CXXFLAGS_COMPILE:-""}"
                export NIX_LDFLAGS="''${NIX_LDFLAGS:-""} -L${pkgs.glibc}/lib -L${pkgs.gcc.cc.lib}/lib -L${pkgs.libffi}/lib"

                # Set CFLAGS/CXXFLAGS for CMake-based builds (e.g., BoringSSL in quiche)
                # CMake doesn't inherit Nix's wrapper flags, so we need to set them explicitly
                export CFLAGS="''${CFLAGS:-""} -I${pkgs.glibc.dev}/include -I${pkgs.boringssl}/include"
                export CXXFLAGS="''${CXXFLAGS:-""} -I${pkgs.glibc.dev}/include -I${pkgs.boringssl}/include"
                export LDFLAGS="''${LDFLAGS:-""} -L${pkgs.glibc}/lib -L${pkgs.gcc.cc.lib}/lib -L${pkgs.libffi}/lib"

                # CMake-specific flags (CMake doesn't use CFLAGS/CXXFLAGS from environment)
                export CMAKE_C_FLAGS="''${CMAKE_C_FLAGS:-""} -I${pkgs.glibc.dev}/include -I${pkgs.boringssl}/include"
                export CMAKE_CXX_FLAGS="''${CMAKE_CXX_FLAGS:-""} -I${pkgs.glibc.dev}/include -I${pkgs.boringssl}/include"

                # Ensure libffi is in the library path for cffi
                export LD_LIBRARY_PATH="${pkgs.libffi}/lib:''${LD_LIBRARY_PATH:-""}"

                # --- GitHub CLI auth ----------------------------------------------------------
                # If not authenticated, try token-based login from ~/.github_token
                ${pkgs.gh}/bin/gh auth status >/dev/null 2>&1 || \
                  ${pkgs.gh}/bin/gh auth login --with-token < "$HOME/.github_token" 2>/dev/null || \
                  warn "GitHub CLI not authenticated, some features may not work"
                
                # Export a real token value (command substitution was missing before)
                export GITHUB_TOKEN="$(${pkgs.gh}/bin/gh auth token 2>/dev/null || true)"
                
                # --- Vault login & secret retrieval ------------------------------------------
                export VAULT_ADDR="https://pki.devnw.com"
                
                # Use the pinned vault binary consistently
                if ! ${pkgs.vault}/bin/vault token lookup -no-print >/dev/null 2>&1; then
                  # Use the GH token we just exported
                  ${pkgs.vault}/bin/vault login -no-print -method=github token="''${GITHUB_TOKEN}" \
                    >/dev/null 2>&1 || warn "Vault login failed"
                fi
                
                # Pull secrets (command substitutions were previously double-$-escaped)
                OPENAI_API_KEY="$(${pkgs.vault}/bin/vault kv get -mount=secret -field=token /dev/openai/actions-primary 2>/dev/null || echo "")"
                export OPENAI_API_KEY
                
                CACHIX_AUTH_TOKEN="$(${pkgs.vault}/bin/vault kv get -mount=secret -field=token /cicd/gh/cachix 2>/dev/null || echo "")"
                export CACHIX_AUTH_TOKEN
                
                # --- Nix configuration & Cachix ----------------------------------------------
                # Use ''${VAR} to avoid Nix interpolation while still expanding in bash.
                NIX_CONFIG="experimental-features = nix-command flakes
                access-tokens = github.com=''${GITHUB_TOKEN}
                trusted-users = root $(whoami)"
                export NIX_CONFIG
                
                # Best-effort: add current user as trusted in /etc/nix/nix.conf (may require sudo)
                if ! grep -q "trusted-users.*$(whoami)" /etc/nix/nix.conf 2>/dev/null; then
                  warn "Adding $(whoami) as trusted user for Nix..."
                  echo "trusted-users = root $(whoami)" | sudo tee -a /etc/nix/nix.conf >/dev/null || true
                  sudo pkill nix-daemon 2>/dev/null || true
                  sleep 2
                fi
                
                # Cachix auth & binary cache (use pinned cachix)
                if [ -n "''${CACHIX_AUTH_TOKEN-}" ]; then
                  ${pkgs.cachix}/bin/cachix authtoken "''${CACHIX_AUTH_TOKEN}" >/dev/null 2>&1 || true
                  ${pkgs.cachix}/bin/cachix use spyder >/dev/null 2>&1 || warn "Could not configure Cachix binary cache"
                fi

                # Export environment variables for Vulkan and CUDA
                export GEODE_DEV="1"
                export GEODE_NIX_BUILD="1"
                export VULKAN_SDK="${pkgs.vulkan-headers.out}"
                export VULKAN_INCLUDE_DIR="${pkgs.vulkan-headers.out}/include"
                export VULKAN_LIB_DIR="${pkgs.vulkan-loader.out}/lib"
                export CUDA_INCLUDE_DIR="${pkgs.cudaPackages.libnpp.out}/include"
                export CUDA_LIB_DIR="${pkgs.cudaPackages.libnpp.out}/lib"

                echo "🔺 Geode Development Environment (CodePros)"
                echo "Zig version: $(zig version)"
                echo "Python version: $(${pythonWithPackages}/bin/python --version | cut -d' ' -f2)"
                echo ""
                echo "Available commands:"
                echo "  make build              - Build Geode"
                echo "  make test               - Run tests"
                echo "  make release            - Build release version"
                echo "  make verify-all         - Full E2E verification (includes client tests)"
                echo "  make client-test-harness - Run multi-language client test suite"
                echo "  make geodetestlab       - Run geodetestlab test specifications"
                echo ""
                echo "Vulkan SDK: $VULKAN_SDK"
                echo "For NixOS module usage, see: ./nix/modules/geode-daemon.nix"
              '';
              
              packages = builtins.filter (p: p != null) (
                (with dev-env.packages.${system}; [
                  zigPackages
                  goPackages
                  commonPackages
                ])
                ++ (with pkgs; [
                  # Core development tools
                  toybox
                  strace
                  file
                  pkg-config
                  openssl
                  zlib
                  libuv

                  # Rust toolchain for client tests
                  rustc
                  cargo
                  rustfmt
                  rust-analyzer
                  clippy
                  boringssl
                  glibc
                  glibc.dev
                  gcc.cc.lib
                  libev
                  libffi

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

                  # Platform specific
                  (if pkgs.stdenv.isLinux then glibc else null)
                  (if system == "x86_64-linux" then wine else null)
                ])
                ++ (with unstablePkgs; [
                  zig-zlint
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
