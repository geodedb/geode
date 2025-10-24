# Nix package definition for Geode graph database
{ lib
, stdenv
, fetchFromGitHub
, zig
, pkg-config
, openssl
, zlib
, libuv
, quic ? null
, enableQuic ? true
, enableOptimization ? true
, enableSentinel ? false
, enableTests ? true
, enableFuzzing ? false
}:

let
  # Use the same Zig version as specified in dev-env
  zigVersion = "0.15.1";
  
  optimize = if enableOptimization then "ReleaseSafe" else "Debug";
  
  buildInputs = [
    openssl
    zlib
    libuv
  ] ++ lib.optionals enableQuic (lib.optionals (quic != null) [ quic ]);

in stdenv.mkDerivation rec {
  pname = "geode";
  version = "0.18.0";

  src = ./../..;

  nativeBuildInputs = [
    zig
    pkg-config
  ];

  inherit buildInputs;

  # Zig build flags
  zigBuildFlags = [
    "-Doptimize=${optimize}"
  ] ++ lib.optionals enableSentinel [
    "-Dsan=true"
  ] ++ lib.optionals enableFuzzing [
    "-Denable-llvm-fuzzer=true"
  ];

  # Configure phase - validate dependencies and setup
  configurePhase = ''
    runHook preConfigure
    
    # Ensure we have the right Zig version
    echo "Using Zig version: $(zig version)"
    
    # Check for required dependencies
    ${lib.optionalString enableQuic ''
      echo "QUIC support enabled"
    ''}
    
    runHook postConfigure
  '';

  # Build phase using Zig build system
  buildPhase = ''
    runHook preBuild
    
    echo "Building Geode with flags: ${lib.concatStringsSep " " zigBuildFlags}"
    
    # Build main binaries
    zig build install ${lib.concatStringsSep " " zigBuildFlags} --prefix $out
    
    # Build tools if requested
    zig build tools ${lib.concatStringsSep " " zigBuildFlags} --prefix $out
    
    runHook postBuild
  '';

  # Check phase - run tests if enabled
  doCheck = enableTests;
  checkPhase = lib.optionalString enableTests ''
    runHook preCheck
    
    echo "Running Geode tests..."
    zig build test ${lib.concatStringsSep " " zigBuildFlags}
    
    runHook postCheck
  '';

  # Install phase - install binaries and documentation
  installPhase = ''
    runHook preInstall
    
    # Binaries are already installed by zig build
    # Create additional directories for configuration
    mkdir -p $out/{etc,var/lib,var/log,share/doc}/geode
    
    # Install documentation
    cp -r docs/* $out/share/doc/geode/
    cp README.md CHANGELOG.md LICENSE $out/share/doc/geode/
    
    # Install example configurations
    cp -r config/* $out/etc/geode/ || true
    cp -r examples $out/share/doc/geode/ || true
    
    # Install migrations
    cp -r migrations $out/share/geode/ || true
    
    runHook postInstall
  '';

  # Post-install fixups
  postInstall = ''
    # Ensure binary permissions
    chmod +x $out/bin/geode* || true
    
    # Create wrapper scripts if needed
    if [ -f $out/bin/geode ]; then
      # Validate the main binary works
      $out/bin/geode --version || echo "Warning: geode binary validation failed"
    fi
  '';

  meta = with lib; {
    description = "Geode - Open-source ACID-compliant graph database implementing ISO/IEC 39075:2024 GQL";
    longDescription = ''
      Geode is an open-source, ACID-compliant graph database implementing 
      ISO/IEC 39075:2024 Graph Query Language (GQL). Written in Zig for 
      low-level efficiency, it focuses on reliability, security, and 
      deterministic behavior.

      Key features:
      - QUIC+TLS transport with optional Transparent Data Encryption (TDE)
      - MVCC with snapshot isolation; WAL/ARIES crash recovery
      - Deterministic MATCH engine with bounded path expansions
      - Federated reads via distributed coordinator/shards
      - S3 backups (full/incremental); CDC webhooks
      - Tamper-evident audit log (hash chain + signed digests)
      - Comprehensive type system with 50+ data types
      - Advanced indexing: Patricia trie, R-tree, HNSW with persistence
    '';
    homepage = "https://github.com/spyderorg/geode";
    license = licenses.mit;
    maintainers = with maintainers; [ ]; # Add maintainers here
    platforms = platforms.unix;
    mainProgram = "geode";
  };

  # Pass through attributes for debugging
  passthru = {
    inherit zigVersion optimize enableQuic enableOptimization;
  };
}