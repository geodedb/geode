# Geode v0.16.0 Build & Development Notes

## Default Settings (v0.16.0)
- **Recursive CTEs**: Enabled by default (depth limit: 100)
- **Bounded path expansions**: Enabled by default (deterministic ordering)
- **Phantom prevention**: Enabled by default (range tracking active)
- **OPTIONAL MATCH**: Fixed null semantics
- **Stats registry**: Disabled by default (set GEODE_STATS_REGISTRY=1 to enable)

## Transport Configuration
- **QUIC+TLS is mandatory** - no TCP fallback
- Auto-generates self-signed certificates if missing in `certs/`
- Certificate permissions automatically set to 0600

## Build System
- **No compile-time feature flags** - all subsystems are integrated
- Use runtime environment variables for non-transport feature kill-switches only
- CI enforces no feature flags via `tools/no_feature_flags_check.py`

## Status Tracking
- **docs/status.csv is generated** - never hand-edit
- Use `tools/status_generate.py --repo . --out docs/status.csv` to regenerate
- CANARY annotations track implementation status in code

## Testing Commands
```bash
# Run all tests
zig build test -Drelease-safe

# Check for feature flags
python3 tools/no_feature_flags_check.py --repo .

# Generate status CSV
python3 tools/status_generate.py --repo . --out docs/status.csv

# Test multi-process cluster
sh scripts/cluster_spawn.sh

# Lint check
zig fmt --check src/ tests/

# Run specific test suites
zig test tests/e2e_recursive_bounded_default.zig
zig test tests/e2e_rls_integration.zig
zig test tests/e2e_materialized_views_refresh.zig
```

## GPU linking notes

When building with system libdl and CUDA driver present, set the following in build.zig or environment:

- Linker will resolve __libc_dlopen/__libc_dlsym/__libc_dlclose and cuInit if system libraries are present.
- The code falls back to runtime stubs when symbols are not available.

If you want to force linking against libdl and libcuda add linker options in build.zig or pass -lc -lcuda to link step.