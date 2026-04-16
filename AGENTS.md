# AGENTS.md

Guidelines for AI agents working in the Geode graph database codebase.

## Project Overview

**Geode** is an enterprise-ready graph database implementing ISO/IEC 39075:2024 (GQL standard) with 98.6% compliance. Written primarily in Zig 0.16.0+ with Python test tooling.

**Key stats:**

- 95%+ test coverage (geodetestlab)
- 1016 CANARY governance markers
- Unified CLI binary (`geode`) for server and client

---

## Essential Commands

### Build

```bash
make build              # Debug build (Zig)
make release            # Optimized build (-Doptimize=ReleaseSafe)
zig build               # Direct Zig build
make fmt                # Format code (zig fmt on src/, tests/, build.zig)
make clean              # Remove build artifacts
```

### Test

```bash
make test                        # All tests (Zig + Go + QUIC + clients)
zig build test                   # Zig unit tests only
make geodetestlab-comprehensive  # Full integration test suite
make integration-test            # Integration tests
make fuzz                        # Fuzz testing
make bench                       # Benchmarks

# Run specific geodetestlab spec
make geodetestlab-spec SPEC=geode_auth
python3 scripts/test/extended_test_runner.py geode_auth

# Run specific Zig test filter
zig build test -Dtest-filter="CANARY"
```

### Run Server/Client

```bash
# Start server (QUIC+TLS only, default port 3141)
./zig-out/bin/geode serve --listen 0.0.0.0:3141

# Interactive shell
./zig-out/bin/geode shell

# Execute query
./zig-out/bin/geode query "RETURN 1 AS x"

# Query with JSON output
./zig-out/bin/geode query "MATCH (n) RETURN n LIMIT 10" --format json
```

### Governance & Verification

```bash
make status-generate    # Generate docs/status.csv from CANARY markers
make no-feature-flags   # Check for compile-time feature flags
make verify-fast        # Quick verification (build, test, cross-compile)
make verify-all         # Full E2E verification (CI pipeline)
```

### Docker

```bash
make docker-build           # Build images
make docker-up-singleton    # Single node
make docker-up-distributed  # Cluster
make docker-down            # Stop all
make docker-test            # Run Docker tests
```

---

## Code Organization

```
src/
├── gql/           # Parser, lexer, AST (98.6% ISO GQL compliance)
├── planner/       # Cost-based query optimization
├── storage/       # MVCC, WAL, TDE, page management
├── index/         # 6 index types (HNSW, R-tree, B-tree, etc.)
├── security/      # Auth, RLS, audit, encryption, KMS
├── transport/     # QUIC+TLS transport
├── cli/           # Unified CLI (server + client + REPL)
├── distributed/   # Raft, sharding, federation
├── execution/     # Query execution, graph algorithms
├── ml/            # Graph embeddings (Node2Vec, GraphSAGE)
└── analytics/     # Real-time streaming analytics

geodetestlab/
├── specs/         # YAML test specifications
├── geodetestlab/  # Python test framework
└── fixtures/      # Test data setup scripts

tests/             # Zig integration tests, regression scripts
benchmarks/        # Performance benchmarks
docs/              # Comprehensive documentation
```

---

## Code Conventions

### Naming

| Element | Convention | Example |
|---------|------------|---------|
| Types/Structs | `PascalCase` | `Lexer`, `Parser`, `AuditLogger` |
| Functions | `camelCase` | `skipSeparators`, `parseProgram` |
| Fields/constants | `snake_case` | `slot_count`, `free_end` |
| Enum values | `PascalCase` | `SHA3_256`, `BLAKE3` |
| Test names | `snake_case` | `test "test_feature_name"` |

### Memory Management (Critical)

**Zero tolerance for memory leaks.** Never use `std.heap.page_allocator` in production code.

```zig
// ✅ GOOD: Pass allocator, use defer for cleanup
pub fn processData(allocator: std.mem.Allocator, value: []const u8) !Result {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit(allocator);
    // ...
}

// ✅ GOOD: Store allocator in struct
pub const Processor = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) !Processor { ... }
    pub fn deinit(self: *Processor) void {
        self.data.deinit(self.allocator);
    }
};

// ✅ GOOD: Main functions use GeneralPurposeAllocator
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // ...
}

// ❌ BAD: page_allocator never frees memory
var buf = std.ArrayList(u8).init(std.heap.page_allocator);  // FORBIDDEN!
```

### Struct Pattern

```zig
pub const StructName = struct {
    allocator: std.mem.Allocator,
    field: Type,
    field2: Type = default_value,

    pub fn init(allocator: std.mem.Allocator) !StructName { ... }
    pub fn deinit(self: *StructName) void { ... }

    // Private helpers have no `pub`
    fn privateHelper(self: *StructName) void { ... }
};
```

### Error Handling

```zig
// Named error sets
const ParserError = error{ UnexpectedToken, OutOfMemory, InvalidSyntax };

// Error propagation with try
const result = try parser.parse(input);

// Error handling with switch
result catch |err| switch (err) {
    error.UnexpectedToken => handleUnexpected(),
    else => return err,
};

// Optional with default
const value = optional_val orelse default;
```

### CANARY Markers (Required)

Every significant feature needs a CANARY marker for governance tracking:

```zig
// CANARY: REQ=REQ-GQL-042; FEATURE="Vector Search"; ASPECT=Index; STATUS=TESTED; TEST=test_vector_knn; OWNER=core; UPDATED=2025-10-16
```

**Status values:** `STUB` → `IMPL` → `TESTED` → `BENCHED` → `COMPLETE`

---

## Testing

### Zig Unit Tests

```zig
test "test_feature_name" {
    // Use testing.allocator for leak detection
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = try Module.init(allocator);
    defer obj.deinit();

    const result = try obj.method();
    try std.testing.expect(result == expected);
    try std.testing.expectEqual(expected, actual);
}
```

### geodetestlab YAML Specs

Located in `geodetestlab/specs/*.yml`:

```yaml
version: "1.0"
name: "Suite Name"

cli:
  binary: "./zig-out/bin/geode"
  server:
    enabled: true
    startup_timeout_ms: 60000

tests:
  - name: "test-name"
    args: ["query", "-"]
    stdin: "RETURN 1 AS x"
    setup: ["user create alice ..."]
    cleanup: ["user delete alice"]
    expect:
      exit_code: 0
      stdout_contains: ["expected"]
      stdout_regex: ["\\d+"]
      stdout_json_assert:
        - expression: "results[0].name"
          equals: "Alice"
```

**Variable substitution:** `${server_address}`, `${secret:api_token}`, `${instance_id}`

---

## Critical Rules

### Never Mock Database Responses

From CLAUDE.md:
> "NEVER EVER mock or simulate responses from `geode` in the test harness. Always implement the complex missing logic in the actual code to make tests work."

### Verify Against GQL Specification

Before making architectural changes, verify against the authoritative spec:
`docs/kb/gql/ISO_IEC_39075_2024(en).pdf`

### Run Tests After Changes

Always run tests immediately after modifications:

```bash
zig build test           # Quick unit tests
make test                # Full test suite
make geodetestlab-spec SPEC=<relevant_spec>  # Relevant integration tests
```

---

## Common Gotchas

### Zig 0.15.1 API

ArrayList/HashMap require explicit allocator parameters:

```zig
var list = std.ArrayList(u8).init(allocator);
try list.append(allocator, item);      // Allocator required
try list.appendSlice(allocator, data); // Allocator required
list.deinit(allocator);                // Allocator required
```

### Build Dependencies

- **Zig**: 0.16.0+ required
- **OpenSSL**: Required for QUIC/TLS (linked for native builds)
- **Git submodules**: Run `git submodule update --init --recursive` for vendor/quic

### QUIC-Only Transport

Geode uses QUIC+TLS exclusively. No TCP/plaintext transport. Server default port: 3141.

### Cross-Compilation

The build system supports multiple targets:

```bash
make cross-linux-x86_64
make cross-linux-arm64
make cross-macos-arm64
make cross-windows  # Requires Wine for testing
```

---

## Key Documentation

| Topic | File |
|-------|------|
| Project overview | `CLAUDE.md` |
| Quick reference | `docs/QUICK_REFERENCE.md` |
| API reference | `docs/API_REFERENCE.md` |
| Types & functions | `docs/TYPES_AND_FUNCTIONS.md` |
| GQL compliance | `docs/GQL_COMPLIANCE.md` |
| Testing guide | `docs/TESTING.md` |
| Contributing | `CONTRIBUTING.md` |
| GQL specification | `docs/kb/gql/ISO_IEC_39075_2024(en).pdf` |

---

## Environment Variables

```bash
# Query behavior
GEODE_ORDER_KEYS_EXPR=1       # Allow ORDER BY expressions

# Testing/CI
GEODE_CI_QUIC_SMOKE=1         # Enable QUIC smoke tests
GEODE_QUIC_PASSIVE_TEARDOWN=1 # Passive connection teardown
GEODE_CAPTURE_SERVER_STDERR=1 # Capture server stderr

# Performance
GEODE_TELEMETRY_PAGING=1      # Enable telemetry
GEODE_CDC_ENABLE=1            # Enable CDC
```

---

*Last updated: January 2026*
