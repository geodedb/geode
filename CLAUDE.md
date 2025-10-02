# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⚠️ CRITICAL: String Literal Syntax

**ALWAYS USE SINGLE QUOTES for string literals in GQL queries.**
- ✅ CORRECT: `CREATE (n {name: 'Alice', city: 'New York'})`
- ❌ WRONG: `CREATE (n {name: "Alice", city: "New York"})` 

Double quotes cause parser hangs. This is a known issue. All examples, tests, and documentation must use single quotes exclusively.

## Project Overview

Geode is an open-source, ACID-compliant graph database implementing ISO/IEC 39075:2024 Graph Query Language (GQL). Written in Zig 0.15.1+ for low-level efficiency, it focuses on reliability, security, and deterministic behavior.

**Key Features (v0.18.0):**
- QUIC+TLS transport only with optional Transparent Data Encryption (TDE)
- MVCC with snapshot isolation; WAL/ARIES crash recovery
- Deterministic MATCH engine with bounded path expansions
- Federated reads via distributed coordinator/shards
- S3 backups (full/incremental); CDC webhooks
- Tamper‑evident audit log (hash chain + signed digests)
- **Enterprise audit logging**: Multi-platform support (JSON files, Windows Event Log, syslog)
- **Security compliance**: CLI command tracking, authentication logging, SIEM integration
- Evidence governance via CANARY with generated status.csv
- **Comprehensive type system**: 50+ data types including network, spatial, temporal, JSON, and vector types
- **Advanced indexing**: Patricia trie (CIDR), R-tree (spatial), HNSW (vector KNN), with persistence

## Data Types and Functions

For a complete reference of all supported data types and functions, see [docs/TYPES_AND_FUNCTIONS.md](docs/TYPES_AND_FUNCTIONS.md). This includes:
- **Core types**: Numeric, string, temporal, binary
- **First-class types**: Network (IP/CIDR/MAC), geographic, cryptographic, vector
- **Advanced types**: JSONB, XML, URL, UUID, ranges, arrays, bit strings
- **Constructor functions** and **built-in functions** for all types
- **Persisted indexes** with snapshot/WAL support

## Development Commands

### Build Commands
```bash
# Build debug version (Zig + Go clients)
make build
# or: zig build

# Build release version
make release
# or: zig build -Doptimize=ReleaseSafe

# Build tools
make tools
# or: zig build tools

# Format all code
make fmt
```

### Test Commands
```bash
# Run all tests (Zig + Go + dataset integration)
make test
# or: zig build test

# Run specific test file
zig test tests/test_specific_file.zig

# Run integration tests
make integration-test

# Run dataset integration tests
make dataset-integration-test

# Run fuzz tests
make fuzz
# or: zig build fuzz

# Run benchmarks
make bench
# or: zig build bench
```

### Client Development
```bash
# Build Go client library (strict vendor mode)
make go-build

# Test Go clients
make go-test

# Run Go client example
make go-example

# Cross-compile clients for all platforms
make cross-clients

# Test cross-compiled clients
make test-cross-clients
```

### Server & CLI Commands
```bash
# Start server (QUIC+TLS only)
./zig-out/bin/geoded --listen-quic 0.0.0.0:8443

# Run CLI client
./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --format json

# Run unified CLI
./zig-out/bin/geode --help

# Run GQL CLI
./zig-out/bin/gql
```

### Governance & Quality
```bash
# Generate status.csv from CANARY markers
make status-generate

# Check for compile-time feature flags (enforces no flags)
make no-feature-flags

# Run governance checks
make governance-check

# Update status hash
make update-status-hash

# Show governance delta
make governance-delta
```

### Docker Operations
```bash
# Build Docker images
make docker-build

# Start singleton container
make docker-up-singleton

# Start distributed cluster
make docker-up-distributed

# Stop all containers
make docker-down

# Run Docker tests
make docker-test

# Full Docker CI pipeline
make docker-ci
```

### Nix Commands
```bash
# Build with Nix
nix build                    # Build default package
nix build .#geode-debug      # Build debug version
nix build .#geode-static     # Build static version
nix build .#geode-docker     # Build Docker image

# Run with Nix
nix run                      # Run Geode
nix run . -- serve --help    # Run with arguments
nix run .#geode-debug        # Run debug version

# Development environments
nix develop                  # Enter default dev shell
nix develop .#ci             # CI environment
nix develop .#deploy         # Deployment environment

# Templates and deployment
nix flake init -t .#geode-service     # Create NixOS service template
nix flake init -t .#geode-dev         # Create dev environment template
nix run .#generate-docker-compose     # Generate docker-compose.yml
nix run .#generate-k8s-manifests      # Generate Kubernetes manifests

# Testing Nix configurations
nix flake check              # Validate all configurations
```

### Development Verification
```bash
# Full E2E verification (strict)
make verify-all

# Faster dev verification (no fuzz/bench/docker/governance)
make verify-fast

# Full CI pipeline
make ci
```

## Audit Logging & Security Monitoring

Geode provides comprehensive audit logging capabilities for enterprise security compliance and monitoring. The audit system logs CLI operations, authentication events, and command execution across multiple output formats.

### Supported Audit Outputs

#### 1. JSON File Logging (Cross-Platform)
```bash
# Enable file-based audit logging
geode --audit --audit-file /var/log/geode/cli-audit.log <command>

# Environment variable configuration
export GEODE_AUDIT_ENABLED=true
export GEODE_AUDIT_FILE_ENABLED=true
export GEODE_AUDIT_FILE_PATH=/var/log/geode/cli-audit.log
```

**JSON Event Format:**
```json
{"timestamp":1759264693,"category":"auth","action":"login","outcome":"success","actor":"geode-cli"}
{"timestamp":1759264693,"category":"command","action":"query","outcome":"started","actor":"geode-cli"}
{"timestamp":1759264693,"category":"cli","action":"startup","outcome":"success","actor":"geode-cli"}
```

#### 2. Windows Event Log Integration (Windows Only)
```bash
# Enable Windows Event Log with default source "Geode"
geode --audit --audit-eventlog <command>

# Custom event source name
geode --audit --audit-eventlog "MyGeodeApp" <command>

# Environment variable configuration
set GEODE_AUDIT_WINDOWS_EVENTLOG_ENABLED=true
set GEODE_AUDIT_WINDOWS_EVENTLOG_SOURCE=MyGeodeApp
```

**Windows Event Log Features:**
- **Native Integration**: Events appear in Windows Event Viewer
- **Event Categories**: Structured event IDs (1000-1003) for filtering
- **SIEM Compatibility**: Windows Event Forwarding (WEF) support
- **Event Types**: Information, Warning, Error based on outcome

#### 3. Syslog Integration (Planned)
```bash
# Syslog server configuration (future feature)
geode --audit --audit-syslog syslog.example.com:514 <command>

# Environment variables
export GEODE_AUDIT_SYSLOG_ENABLED=true
export GEODE_AUDIT_SYSLOG_HOST=syslog.example.com
export GEODE_AUDIT_SYSLOG_PORT=514
```

### Event Categories & Classifications

#### Authentication Events (Event ID: 1001)
- **Login attempts**: Success/failure with user context
- **Logout events**: Session termination tracking
- **Password resets**: Forced password change events

#### Command Execution Events (Event ID: 1002)
- **All CLI commands**: serve, shell, query, backup, restore, etc.
- **Execution context**: Timestamp, command type, outcome
- **Error tracking**: Failed command attempts with error codes

#### CLI Lifecycle Events (Event ID: 1003)
- **Startup events**: CLI initialization
- **Shutdown events**: Clean termination
- **Configuration loading**: Audit config initialization

#### General Events (Event ID: 1000)
- **Fallback category**: Miscellaneous audit events
- **System events**: Configuration changes, errors

### Multi-Output Configuration

#### Combined Audit Outputs
```bash
# Log to both file and Windows Event Log simultaneously
geode --audit --audit-file audit.log --audit-eventlog MyApp <command>

# Mixed environment and CLI configuration
export GEODE_AUDIT_FILE_ENABLED=true
export GEODE_AUDIT_FILE_PATH=/var/log/geode/audit.log
geode --audit --audit-eventlog query "MATCH (n) RETURN n"
```

#### Cross-Platform Behavior
- **Windows systems**: All outputs available (file + Windows Event Log)
- **Non-Windows systems**: File and syslog outputs (graceful Windows Event Log warning)
- **Error handling**: Continues operation if audit outputs fail

### Enterprise Integration

#### SIEM Integration
- **Windows Event Viewer**: Native Windows monitoring integration
- **JSON structured logs**: Compatible with ELK, Splunk, and other log aggregators
- **Event correlation**: Consistent event IDs for alerting and filtering
- **PowerShell queries**: `Get-WinEvent -FilterHashtable @{LogName="Application"; ProviderName="Geode"}`

#### Security Compliance
- **Audit trail**: Complete command and authentication logging
- **Tamper resistance**: Windows Event Log native protection
- **Non-repudiation**: Timestamped, categorized event logging
- **Regulatory compliance**: Meets enterprise logging requirements (SOX, PCI-DSS, HIPAA)

#### Monitoring Examples
```bash
# Monitor authentication failures
Get-WinEvent -FilterHashtable @{LogName="Application"; ProviderName="Geode"; ID=1001} | 
  Where-Object {$_.Message -like "*failure*"}

# Track command execution patterns
grep '"category":"command"' /var/log/geode/audit.log | jq -r '.action' | sort | uniq -c

# Real-time audit monitoring
tail -f /var/log/geode/audit.log | jq -r '[.timestamp, .category, .action, .outcome] | @csv'
```

### Configuration Reference

#### Environment Variables
```bash
# Core audit settings
GEODE_AUDIT_ENABLED=true                           # Enable audit logging
GEODE_AUDIT_FILE_ENABLED=true                     # Enable file output
GEODE_AUDIT_FILE_PATH=/var/log/geode/audit.log    # File path

# Windows Event Log settings
GEODE_AUDIT_WINDOWS_EVENTLOG_ENABLED=true         # Enable Windows Event Log
GEODE_AUDIT_WINDOWS_EVENTLOG_SOURCE=MyApp         # Custom source name
GEODE_AUDIT_WINDOWS_EVENTLOG_LOG=Application      # Target log (future use)

# Syslog settings (planned)
GEODE_AUDIT_SYSLOG_ENABLED=true                   # Enable syslog
GEODE_AUDIT_SYSLOG_HOST=syslog.example.com        # Syslog server
GEODE_AUDIT_SYSLOG_PORT=514                       # Syslog port
```

#### CLI Flags
```bash
--audit                              # Enable audit logging
--audit-file <path>                 # File output path
--audit-eventlog [source]           # Windows Event Log (optional source name)
--audit-syslog <host:port>          # Syslog server (planned)
```

## Architecture Overview

### Core Components
- **Parser/Lexer** (`src/gql/`): GQL language processing
- **Planner** (`src/planner/`): Query optimization and execution planning
- **Storage** (`src/storage/`): Page management, WAL, and persistence
- **Index** (`src/index/`): Multiple index types (B-tree, HNSW, R-tree, etc.)
- **Graph** (`src/graph/`): Graph algorithms and traversal
- **Security** (`src/security/`): TDE, audit, MFA, RLS/ABAC
- **Distributed** (`src/distributed/`): Raft consensus and federation
- **Monitoring** (`src/monitoring/`): Metrics and observability

### Key Execution Flow
1. **Parse**: GQL text → AST via lexer/parser
2. **Plan**: AST → logical operators → optimized physical plan
3. **Execute**: Physical operators over storage with index utilization
4. **Stream**: Results via SCHEMA + paged BINDINGS frames

### Storage & ACID
- **Pages**: Slotted page layout with CSR-style adjacency
- **WAL**: ARIES-style write-ahead logging with LSNs
- **MVCC**: Snapshot isolation with optimistic conflict detection
- **Recovery**: Crash recovery with undo/redo from WAL
- **Indexes**: Transactional maintenance across multiple index types

### Protocol
- **Transport**: QUIC+TLS only (no TCP fallback)
- **Frames**: HELLO, BEGIN/COMMIT/ROLLBACK, RUN_GQL, PULL
- **Results**: SCHEMA, BINDINGS (with ordering metadata), EXPLAIN/PROFILE
- **Diagnostics**: ISO GQLSTATUS codes with precedence rules

## Code Conventions

### Language & Style
- **Language**: Zig 0.15.1+
- **Formatting**: Use `zig fmt` for all Zig code
- **Go Code**: Use `go fmt` for client libraries
- **Comments**: Minimal comments unless required for clarity

### CANARY System
The project uses a CANARY annotation system for tracking implementation status:

```zig
// CANARY: REQ=REQ-GQL-XXX; FEATURE="FeatureName"; ASPECT=AspectName; STATUS=IMPL; TEST=TestName; OWNER=team; UPDATED=2025-09-29
```

**Valid STATUS values**: `IMPL` (implemented), `TESTED` (tested), or `BENCHED` (benchmarked)

**Important**: All implemented features must have CANARY markers. Tests should be named `TestCANARY_REQ_GQL_XXX_*` for traceability.

### File Organization
- **Tests**: Place in `tests/` directory with descriptive names
- **Benchmarks**: Use `benchmark_*.zig` naming pattern  
- **Canary Tests**: Use `canary_*.zig` for governance verification
- **Tools**: Utility programs in `tools/` directory
- **Examples**: Client examples in `examples/` and `clients/*/example/`

### Security Guidelines
- **Never log secrets**: No API keys, tokens, or sensitive data in logs
- **TDE**: Use placeholders like `{{KMS_ENDPOINT}}` for configuration
- **Audit**: All security-relevant operations must be auditable
- **RLS/ABAC**: Row-level security enforced via planner rewrite

## Testing Strategy

### Test Types
- **Unit Tests**: Component-level testing with `zig test`
- **Integration Tests**: End-to-end protocol and storage testing
- **Canary Tests**: Governance verification with CANARY markers
- **Fuzz Tests**: Randomized input testing in `fuzz/` directory
- **Benchmarks**: Performance regression testing

### Test Execution
- Tests must be deterministic (fixed seeds, no randomness)
- Maximum 512 MiB RAM usage per test
- 30-second timeout for E2E tests
- Cross-platform testing with Wine/QEMU when available

### Dataset Testing
Load the example social network dataset for integration testing:
```bash
make load-dataset
make dataset-integration-test
```

## Common Development Tasks

### Adding New Features
1. Implement with appropriate CANARY markers
2. Add comprehensive tests following naming conventions
3. Update documentation if user-facing
4. Run `make verify-fast` for quick validation
5. Run `make status-generate` to update governance tracking

### Debugging
- Use JSON logs with `--log_json` flag
- Check server stderr with `GEODE_CAPTURE_SERVER_STDERR` env var
- Profile with `EXPLAIN` and `PROFILE` query prefixes
- Monitor metrics via Prometheus integration

### Cross-Platform Development
- Test builds: `make cross-compile`
- Test clients: `make cross-clients && make test-cross-clients`
- Windows testing requires Wine
- ARM64 testing requires QEMU

## Environment Setup

### Prerequisites
- Zig 0.15.1+
- Go (for client libraries)
- Docker (for containerized testing)
- Git submodules: `git submodule update --init --recursive`
- **Optional**: Nix (for declarative builds and deployment)

### Quick Start

#### Traditional Build (Zig/Make)
```bash
# Initialize development environment
make dev-setup

# Build everything
make build

# Run basic tests
make test

# Start development server
./zig-out/bin/geoded --data_dir ./data --log_json
```

#### Nix Build (Declarative)
```bash
# Build and run with Nix
nix run

# Enter development environment
nix develop

# Build Docker image
nix build .#geode-docker && docker load < result

# Deploy on NixOS (see nix/README.md for full configuration)
# Add to configuration.nix:
services.geode = {
  enable = true;
  network.quicPort = 8443;
  performance.memoryLimit = "4GB";
};
```

### Submodules
- QUIC library managed as git submodule in `vendor/quic/`
- Initialize with: `git submodule update --init --recursive`
- Check status with: `make quic-status`
- Always ensure canaries are added for new additions, or when changes are made so that the canary scan tool tracks them. And run the canary scan regularly to keep the status.csv and status.json files up to date.
- remember to run `make verify-fast` to ensure builds work after changes and for large changes to run `make verify-all` and correct issues iteratively until all issues are resolved
- remember to use std.os.getenv instead of std.posix.getenv because it's compatible accross OSes
- remember when adding new tests, if there is a failure in something that should work, fix geode don't change the test to make the test work
- remember to always add regression tests when fixing bugs
- when issues are found that are complex FIX THEM, don't just document them

## Recent Major Fixes Applied (for reference)

### Fixed Issues:
1. **Property-based ordering** (`ORDER BY n.property`) - Fixed by enabling `g_order_keys_expr` flag in src/server/main.zig:108
2. **Count aggregation** - Fixed by adding aggregation detection in src/server/graph/exec.zig
3. **LIMIT without ORDER BY** - Fixed by modifying US001 enforcement to only apply to OFFSET/SKIP
4. **Parser OFFSET/LIMIT order** - Fixed parser to accept LIMIT and OFFSET in any order in src/gql/parser.zig:551-569
5. **Node ID collisions** - Fixed by implementing getNextNodeId() that finds max ID + 1

### Test Infrastructure:
- `tests/comprehensive_regression_test.sh` - Master regression test suite (34 scenarios)
- `tests/limit_skip_regression_test.sh` - Pagination behavior tests (23 scenarios)
- `tests/property_ordering_regression_test.sh` - Property ordering tests (10 scenarios)  
- `tests/count_aggregation_regression_test.sh` - Aggregation tests (8 scenarios)

### Known Remaining Issues:
- Double quote string literals cause server hang (workaround: use single quotes)
- QUIC TLS handshake inconsistency with --insecure flag