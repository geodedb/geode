# QUIC Library Git Submodule Setup

## Overview

The QUIC library has been migrated from a vendored/nix-based approach to a git submodule for better source control and availability.

## Submodule Details

- **Repository**: https://github.com/spyderorg/quic.git
- **Location**: `vendor/quic/`
- **Wrapper**: `vendor/quic/lib.zig`

## Setup

### Initial Setup (Already Done)

```bash
# Add the submodule
git submodule add https://github.com/spyderorg/quic.git vendor/quic

# Initialize and fetch submodule content
git submodule update --init --recursive
```

### For New Clones

When cloning the geode repository, initialize the submodule:

```bash
# Clone with submodules
git clone --recursive https://gitlab.com/devnw/codepros/geode.git

# Or if already cloned without submodules
git submodule update --init --recursive
```

## Usage in Build System

The build system (`build.zig`) references the QUIC library as:

```zig
const vendor_quic_mod = b.createModule(.{ 
    .root_source_file = b.path("vendor/quic/lib.zig"), 
    .target = target, 
    .optimize = optimize 
});
```

The `lib.zig` wrapper file exports:
- Main QUIC implementation from `quic.zig`
- API types from `src/quic/api.zig`
- Common types like Connection, Stream, Listener, and Config

## Makefile Targets

```bash
# Check QUIC submodule status
make quic-status

# Initialize QUIC submodule
make quic-init

# Development setup (includes QUIC init)
make dev-setup
```

## Updating the Submodule

To update to the latest QUIC library version:

```bash
# Navigate to submodule
cd vendor/quic

# Pull latest changes
git pull origin main

# Go back to main repository
cd ../..

# Commit the submodule update
git add vendor/quic
git commit -m "Update QUIC submodule to latest version"
```

## Migration from Vendored Approach

### Previous Setup
- QUIC library was fetched from nix using `scripts/vendor_quic.sh`
- Files were copied to `vendor/quic/` and made writable
- Required nix environment and manual compatibility fixes

### Current Setup
- QUIC library is a git submodule
- Always available as source code
- Version controlled with the main repository
- No nix dependency for QUIC library

## File Structure

```
vendor/quic/
├── .git                 # Submodule git reference
├── lib.zig             # Wrapper module (created by us)
├── quic.zig            # Main QUIC implementation
├── build.zig           # QUIC build configuration
├── src/
│   ├── quic/
│   │   ├── api.zig     # QUIC API
│   │   ├── connection.zig
│   │   ├── stream.zig
│   │   └── ...
│   └── h3/             # HTTP/3 implementation
└── examples/           # QUIC examples and tests
```

## Troubleshooting

### Submodule Not Initialized
```bash
# Check status
make quic-status

# Initialize if needed
git submodule update --init --recursive
```

### Build Errors
If you encounter build errors related to QUIC:
1. Ensure the submodule is initialized: `make quic-status`
2. Check that `vendor/quic/lib.zig` exists
3. Verify the QUIC library version is compatible with Zig 0.15.1

### Submodule Dirty State
If the submodule shows as modified:
```bash
# Check what changed
cd vendor/quic
git status
git diff

# Reset if needed (loses local changes)
git reset --hard HEAD
```

## Benefits of Submodule Approach

1. **Always Available**: Source code is always available, no external dependencies
2. **Version Control**: Specific QUIC versions are tracked with the main repository
3. **Reproducible Builds**: Same QUIC version for all developers
4. **Easy Updates**: Simple git commands to update the library
5. **No Nix Required**: Removes nix dependency for QUIC library access