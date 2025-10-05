# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⚠️ CRITICAL: String Literal Syntax

**ALWAYS USE SINGLE QUOTES for string literals in GQL queries.**
- ✅ CORRECT: `CREATE (n {name: 'Alice', city: 'New York'})`
- ❌ WRONG: `CREATE (n {name: "Alice", city: "New York"})` 

Double quotes cause parser hangs. This is a known issue. All examples, tests, and documentation must use single quotes exclusively.

## 🏆 Project Status (October 2025)

Geode is an **enterprise-ready graph database** with industry-leading compliance and performance:

- **✅ 93.9% Test Coverage** (1166/1242 geodetestlab tests)
- **✅ 98.6% GQL Compliance** (69/70 ISO/IEC 39075:2024 tests)  
- **✅ 1016 CANARY Markers** tracking governance compliance
- **✅ Enterprise Features** complete (TDE, audit, vector search, cloud backup)

## 📚 Documentation Structure

**Complete documentation is available in the [`./docs/`](docs/) directory:**

### Essential References
- **[Implementation Status](docs/IMPLEMENTATION_STATUS.md)** - Evidence-based feature status with test proof
- **[Development TODO](docs/TODO.md)** - Current priorities based on CANARY analysis  
- **[Documentation Index](docs/README.md)** - Complete documentation navigation
- **[Quick Reference](docs/QUICK_REFERENCE.md)** - Essential commands and syntax

### Core Technical Documentation
- **[API Reference](docs/API_REFERENCE.md)** - Complete API documentation
- **[Types & Functions](docs/TYPES_AND_FUNCTIONS.md)** - 50+ specialized data types
- **[GQL Compliance](docs/GQL_COMPLIANCE.md)** - ISO/IEC 39075:2024 conformance details
- **[Performance Analysis](docs/PERFORMANCE_ANALYSIS_REPORT.md)** - Detailed benchmarks and optimizations

### Enterprise & Security
- **[Audit Logging](docs/AUDIT_LOGGING.md)** - Multi-platform audit capabilities
- **[User Authentication](docs/USER_AUTH.md)** - RBAC/ABAC with MFA support
- **[TDE & KMS Design](docs/DESIGN_TDE_KMS.md)** - Transparent data encryption
- **[Security Progress](docs/SECURITY_PROGRESS.md)** - Security implementation status

## 🎯 Key Implementation Highlights

### ✅ Recently Completed (October 2025)
1. **S3 Cloud Backup** - Production-ready with Digital Ocean Spaces integration
2. **REPL QUIC Integration** - Real-time interactive shell with comprehensive features  
3. **Vector Operations** - HNSW indexing with 6 distance metrics and SIMD acceleration
4. **Performance Optimization** - 13.18x I/O improvement, memory-mapped operations
5. **IndexOptimizer** - Cost-based query planning with statistics integration

### 🔧 Current High-Priority Work
1. **CLI Subprocess Elimination** - Replace external process spawning with in-process calls
2. **Vector Index Population** - Backfill existing data into HNSW indexes
3. **BM25 Full-Text Integration** - Connect BM25 scoring to IndexOptimizer

## 🏗️ Architecture Overview

### Core Components
- **Parser/Lexer** (`src/gql/`): 98.6% ISO GQL compliance
- **Query Planner** (`src/planner/`): Cost-based optimization with statistics
- **Storage Engine** (`src/storage/`): MVCC, WAL, TDE with <1% overhead
- **Index System** (`src/index/`): 6 index types including HNSW and R-tree
- **Security** (`src/security/`): Enterprise authentication, audit, encryption
- **Transport** (`src/transport/`): QUIC+TLS only with protocol compliance

### Advanced Features  
- **Vector Search**: HNSW K-NN with SIMD acceleration
- **Network Types**: IPv4/IPv6, CIDR, MAC with <1μs parsing
- **Spatial Indexing**: R-tree for geographic queries
- **Cloud Backup**: S3-compatible with compression and encryption
- **Real-time CDC**: Event capture with adaptive backpressure

## 🧪 Testing & Quality

### Evidence-Based Development
- **CANARY System**: 1016 governance markers tracking all implementations
- **Geodetestlab**: 1242 comprehensive test scenarios 
- **ISO Compliance**: Official test suite verification
- **Performance Benchmarks**: Automated regression testing

### Test Execution
```bash
# Run all tests
python3 extended_test_runner.py

# Generate governance status  
make status-generate

# Run specific test suites
zig test tests/test_s3_backup.zig
zig test tests/test_cardinality_estimator.zig
```

## 🔧 Development Commands

### Build & Test
```bash
# Build debug version
make build

# Run all tests
make test

# Cross-platform verification
make verify-fast

# Generate documentation status
make status-generate
```

### Server & Client
```bash
# Start server (QUIC+TLS only)
./zig-out/bin/geoded --listen-quic 0.0.0.0:8443

# Interactive shell
./zig-out/bin/geode shell

# Execute queries
./zig-out/bin/geode query "RETURN 1 AS x"

# Authentication
./zig-out/bin/geode auth login --user admin
```

## 📋 Code Conventions

### Language & Style
- **Language**: Zig 0.15.1+
- **Comments**: Minimal unless required for clarity
- **CANARY Markers**: Required for all implementations
- **Memory Safety**: Proper allocation/deallocation patterns

### Testing Requirements
- **Unit Tests**: All components must have test coverage
- **Integration Tests**: End-to-end scenario verification  
- **Regression Tests**: Automated prevention of known issues
- **Performance Tests**: Benchmark validation for optimizations

## 🚀 Recent Major Achievements

### **S3 Backup Implementation** ✅
- **Location**: `src/storage/s3_backup.zig`
- **Tests**: `tests/test_s3_backup.zig` (6/6 passing)
- **Integration**: Digital Ocean Spaces with HMAC-SHA1 authentication
- **Features**: Multipart upload, compression, point-in-time recovery

### **REPL QUIC Integration** ✅
- **Location**: `src/client/repl/` (complete subsystem)
- **Transport**: Real QUIC connectivity, not mocked
- **Features**: Multi-line input, output formatting, persistent history, timing
- **Tests**: Comprehensive unit and integration test coverage

### **Vector Operations** ✅ 
- **Location**: `src/types/vector.zig`, `src/index/hnsw.zig`
- **Performance**: SIMD acceleration for 8+ dimensions
- **Integration**: IndexOptimizer with cost estimation  
- **Tests**: All 15 vector_operations_comprehensive.yml tests passing

### **Performance Optimization** ✅
- **File I/O**: 13.18x improvement (5,754μs → 436μs)
- **Collections**: 4.49x improvement (670μs → 149μs)  
- **Memory-Mapped I/O**: Zero-copy data access
- **Query Plan Caching**: LRU cache with cost-based optimization

## 🎯 Implementation Methodology

### Evidence-Based Development
1. **CANARY Markers**: All features tracked with governance compliance
2. **Test-Driven**: Implementation verified through automated testing
3. **Performance Validation**: Benchmarks required for optimization claims
4. **Documentation**: All features documented with implementation proof

### Quality Gates
- **Test Coverage**: Must maintain >90% pass rate  
- **Memory Safety**: Zero memory leaks in test runs
- **Standards Compliance**: Maintain 98%+ GQL compliance
- **Performance**: No regressions in core operations

## 📍 Current Focus Areas

Based on the [current TODO](docs/TODO.md) and [implementation status](docs/IMPLEMENTATION_STATUS.md):

1. **HIGH**: CLI subprocess elimination (breaks unified binary design)
2. **HIGH**: Vector index population (HNSW framework ready, needs data)
3. **HIGH**: BM25 full-text integration (implementation exists, needs optimizer)
4. **MEDIUM**: Transaction isolation improvements (phantom read prevention)
5. **MEDIUM**: Distributed query coordination (network transport integration)

---

**🔗 For comprehensive information, see the complete documentation in [`./docs/`](docs/)**

*Last Updated: October 2025*  
*Next Review: Major feature completion or >95% test coverage achievement*