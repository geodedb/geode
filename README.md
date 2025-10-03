# Geode Graph Database (spyderorg)

Geode is an open-source, ACID-compliant graph database implementing the ISO/IEC 39075:2024 Graph Query Language (GQL). Written in Zig for low-level efficiency, Geode focuses on reliability, security, and deterministic behavior.

🏆 **98.6% GQL ISO/IEC 39075:2024 Compliance** - Industry-leading standards compliance

> **⚠️ IMPORTANT: String Literal Syntax**  
> Currently, **only single quotes** are supported for string literals in GQL queries.  
> Double quotes cause the parser to hang. Always use single quotes: `'string'` not `"string"`  
> Example: `CREATE (n {name: 'Alice'})` ✓ | `CREATE (n {name: "Alice"})` ✗

Highlights (v0.19.0-dev):
- **NEW**: 🏆 **98.6% GQL ISO/IEC 39075:2024 Compliance** with comprehensive feature support
- **NEW**: Complete built-in function library (aggregation, string, math, list, type functions)
- **NEW**: Full DML support (SET, REMOVE, DETACH DELETE, MERGE with ON CREATE/MATCH)
- **NEW**: Session management (USE GRAPH, SET SESSION) and transaction control
- **NEW**: String concatenation operator (||) and all comparison/logical operators
- QUIC+TLS transport only; optional Transparent Data Encryption (TDE)
- MVCC with snapshot isolation; WAL/ARIES crash recovery
- Deterministic MATCH engine; bounded path expansions; US001 guard
- Index operations (CREATE/DROP INDEX) with btree, hash, fulltext, spatial, vector support
- Backup/Restore operations with point-in-time recovery
- Variable-length path patterns (*min..max syntax) and path variable assignment
- Enhanced UNION/INTERSECT/EXCEPT operations
- Federated reads via distributed coordinator/shards
- S3 backups (full/incremental); CDC webhooks
- Tamper‑evident audit log (hash chain + signed digests)
- Evidence governance via CANARY with generated status.csv
- Enterprise audit logging with Windows Event Log and syslog support

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

# Run CLI with embedded server (no external server needed)
./zig-out/bin/geode query "RETURN 1 AS x"

# Interactive shell
./zig-out/bin/geode shell
```

### CLI Commands
The unified CLI (`geode`) provides comprehensive database management:

```bash
# Query execution (auto-starts embedded server if needed)
geode query "MATCH (n) RETURN n LIMIT 10"

# User management
geode user create alice alice@example.com
geode user list
geode user assign-role alice admin

# Authentication
geode auth login --user admin
geode auth validate --token <token>

# Role and policy management
geode role create analyst "Data analyst role"
geode policy create user_access "User data access policy"

# Permissions
geode grant read database analyst
geode revoke write graph limited_role
```

## Documentation

### GQL Compliance Guide
For comprehensive documentation on Geode's GQL ISO/IEC 39075:2024 compliance features, see:
- 📚 **[GQL Compliance Guide](docs/GQL_COMPLIANCE.md)** - Complete feature documentation
- 🧪 **[Development Guide](CLAUDE.md)** - Implementation details and testing

## Testing

### GQL Compliance Testing
```bash
# Run GQL ISO compliance test suite (98.6% compliance)
zig run test_gql_compliance.zig

# Debug specific GQL syntax issues
zig run debug_set_parsing.zig
```

### Quick Test
```bash
# Run all tests
make test

# Run integration tests with large datasets
make integration-test

# Load example dataset and test
make load-dataset
make dataset-integration-test
```

### Integration Tests
The project includes comprehensive integration tests with realistic large-scale datasets:
- **Social Network**: 10,000+ users, posts, groups, events
- **IoT Network**: 25,000+ devices, sensors, telemetry data
- **Financial Network**: 50,000 accounts, 250,000 transactions, fraud detection
- **Geographic Data**: 100 cities, 25,000 POIs, spatial queries

See [docs/INTEGRATION_TESTING.md](docs/INTEGRATION_TESTING.md) for details.

## Documentation

### Core Documentation
- [docs/NEW_FEATURES.md](docs/NEW_FEATURES.md) - **NEW**: Index operations, backup/restore, variable paths, audit logging
- [docs/API_REFERENCE.md](docs/API_REFERENCE.md) - Comprehensive API documentation
- [GAP_ANALYSIS.md](GAP_ANALYSIS.md) - Current implementation status and conformance gaps
- [NEXT.md](NEXT.md) - Development roadmap and priority slices
- [docs/README.md](docs/README.md) - Full documentation set (v0.19.0)

### Features & Types
- [docs/TYPES_AND_FUNCTIONS.md](docs/TYPES_AND_FUNCTIONS.md) - Complete type system reference
- [docs/FIXES_SUMMARY.md](docs/FIXES_SUMMARY.md) - Recent fixes and improvements

### Testing & Quality
- [docs/INTEGRATION_TESTING.md](docs/INTEGRATION_TESTING.md) - **NEW**: Integration testing guide with large datasets
- [docs/TEST_DATASETS.md](docs/TEST_DATASETS.md) - **NEW**: Test dataset schemas and characteristics
- [docs/TEST_COVERAGE.md](docs/TEST_COVERAGE.md) - Comprehensive test suite documentation

### Deployment
- [nix/README.md](nix/README.md) - Nix packaging and deployment guide
- [docs/NIX_DEPLOYMENT.md](docs/NIX_DEPLOYMENT.md) - Complete Nix deployment documentation

For CANARY governance and evidence tracking, see `tools/canaryscan/` and run:
```bash
cd tools/canaryscan && go run . --root ../.. --out ../../status.json --csv ../../status.csv
```
