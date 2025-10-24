# Geode Database - Session Context

## Current State (as of commit f823785)

### Project Overview
Geode is a Zig-based graph database implementing ISO/IEC 39075:2024 (GQL) with ACID properties.

### Recent Major Changes
1. **QUIC/TLS 1.3 Support Added**
   - Transport layer: `src/transport/quic.zig` (simplified wrapper, vendored lib pending full integration)
   - Server: `--listen-quic` flag (e.g., `--listen-quic 0.0.0.0:7567`)
   - Client: QUIC by default, `--no-quic` for stdio fallback
   - Go client: `quic:` DSN prefix support with `github.com/quic-go/quic-go`
   - Certificate tool: `src/tools/cert_gen.zig`
   - Vendor script: `scripts/vendor_quic.sh`

2. **Build System Fixed**
   - Makefile: Comprehensive targets, proper error handling
   - Zig 0.15.1 compatibility fixes applied
   - All binaries building successfully

### Key Files & Modules
- **Server**: `src/server/main.zig` - Protocol handler, QUIC/TCP support
- **Client**: `src/client/main.zig` - CLI client with QUIC support
- **Protocol**: `src/protocol.zig` - Wire protocol definitions
- **Transport**: `src/transport/quic.zig` - QUIC transport layer
- **Go Client**: `clients/go/gql/` - Go client library with QUIC
- **Build**: `build.zig`, `Makefile` - Build configuration

### Build & Run
```bash
make build          # Debug build
make release        # Release build
make vendor-quic    # Vendor QUIC library from nix
make cert-gen       # Generate TLS certificates
make dev-setup      # Complete dev setup

# Run server
./zig-out/bin/geoded --listen-quic 0.0.0.0:7567

# Run client
./zig-out/bin/geodec "RETURN 1 AS x" --server 127.0.0.1:7567
```

### Current Status
- ✅ Core GQL language features implemented
- ✅ Binary protocol with SCHEMA/BINDINGS frames
- ✅ QUIC transport architecture complete
- ✅ Build system functional
- ⚠️ QUIC vendored library needs Zig 0.15.1 compatibility fixes
- ⚠️ Full QUIC implementation pending (using simplified wrapper)

### Next Steps Suggested
1. Complete QUIC library integration (fix vendored lib compatibility)
2. Implement actual QUIC connection handling (currently returns NotImplemented)
3. Add integration tests for QUIC transport
4. Implement missing storage features (CSR adjacency, persistent catalog)
5. Complete transaction support (MVCC conflict detection)

### Environment
- Zig 0.15.1 (via nix flake)
- Linux x86_64
- Nix flake with dev-env and quic inputs
- Vendored QUIC library from `github:spyderorg/quic`

### Testing
```bash
make test           # Run all tests
make go-test        # Run Go client tests
zig build test      # Run Zig tests only
```

### Documentation
- `README.md` - Project overview
- `USAGE.md` - Usage examples with QUIC
- `CRUSH.md` - Quick reference for development
- `QUIC_INTEGRATION_SUMMARY.md` - QUIC implementation details
- `docs/` - Detailed documentation

### Notes for Next Session
- Vendor directory excluded from git (in .gitignore)
- QUIC library vendored but needs compatibility fixes
- Server currently returns `QuicError.NotImplemented` for QUIC operations
- All core functionality works with TCP/stdio modes
- Go client fully supports QUIC protocol selection