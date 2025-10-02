# Geode Graph Database (spyderorg)

Geode is an open-source, ACID-compliant graph database implementing the ISO/IEC 39075:2024 Graph Query Language (GQL). Written in Zig for low-level efficiency, Geode focuses on reliability, security, and deterministic behavior.

> **⚠️ IMPORTANT: String Literal Syntax**  
> Currently, **only single quotes** are supported for string literals in GQL queries.  
> Double quotes cause the parser to hang. Always use single quotes: `'string'` not `"string"`  
> Example: `CREATE (n {name: 'Alice'})` ✓ | `CREATE (n {name: "Alice"})` ✗

Highlights (v0.18.0):
- QUIC+TLS transport only; optional Transparent Data Encryption (TDE)
- MVCC with snapshot isolation; WAL/ARIES crash recovery
- Deterministic MATCH engine; bounded path expansions; US001 guard
- Federated reads via distributed coordinator/shards
- S3 backups (full/incremental); CDC webhooks
- Tamper‑evident audit log (hash chain + signed digests)
- Evidence governance via CANARY with generated status.csv

## Quick Start

### Using Nix (Recommended)
```bash
# Run Geode directly
nix run github:spyderorg/geode

# Enter development environment
nix develop github:spyderorg/geode

# Deploy on NixOS
services.geode = {
  enable = true;
  network.quicPort = 8443;
  performance.memoryLimit = "4GB";
};
```

### Traditional Build
```bash
# Build with Zig
zig build -Doptimize=ReleaseSafe

# Start server
./zig-out/bin/geoded --listen-quic 0.0.0.0:8443
```

## Documentation

- [GAP_ANALYSIS.md](GAP_ANALYSIS.md) - Current implementation status and conformance gaps
- [NEXT.md](NEXT.md) - Development roadmap and priority slices
- [docs/README.md](docs/README.md) - Full documentation set (v0.18.0)
- [nix/README.md](nix/README.md) - Nix packaging and deployment guide
- [docs/NIX_DEPLOYMENT.md](docs/NIX_DEPLOYMENT.md) - Complete Nix deployment documentation
- [docs/FIXES_SUMMARY.md](docs/FIXES_SUMMARY.md) - Recent fixes and improvements
- [docs/TEST_COVERAGE.md](docs/TEST_COVERAGE.md) - Comprehensive test suite documentation

For CANARY governance and evidence tracking, see `tools/canaryscan/` and run:
```bash
cd tools/canaryscan && go run . --root ../.. --out ../../status.json --csv ../../status.csv
```
