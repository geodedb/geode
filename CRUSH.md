# Geode v0.16.0 Build & Development Notes

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
tools/no_feature_flags_check.py --repo .

# Generate status CSV
tools/status_generate.py --repo . --out docs/status.csv

# Validate CANARY annotations
tools/canary_check.py --repo . --csv docs/status.csv

# Test multi-process cluster
scripts/cluster_spawn.sh
```

## GPU linking notes

When building with system libdl and CUDA driver present, set the following in build.zig or environment:

- Linker will resolve __libc_dlopen/__libc_dlsym/__libc_dlclose and cuInit if system libraries are present.
- The code falls back to runtime stubs when symbols are not available.

If you want to force linking against libdl and libcuda add linker options in build.zig or pass -lc -lcuda to link step.