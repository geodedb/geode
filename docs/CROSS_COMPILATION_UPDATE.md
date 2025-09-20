# Cross-Compilation Directory Structure Update

## Changes Made

Updated the Makefile to build cross-compiled binaries to architecture-specific directories to prevent them from overwriting each other during builds.

## Directory Structure

Cross-compiled binaries are now placed in architecture-specific subdirectories under `zig-out/`:

```
zig-out/
├── bin/                    # Native build (default)
├── linux-x86_64/          # Linux x86_64
│   └── bin/
├── linux-arm64/           # Linux ARM64
│   └── bin/
├── linux-arm/             # Linux ARM (32-bit)
│   └── bin/
├── linux-riscv64/         # Linux RISC-V 64-bit
│   └── bin/
├── windows-x86_64/        # Windows x86_64
│   └── bin/
├── windows-arm64/         # Windows ARM64
│   └── bin/
├── macos-x86_64/          # macOS Intel
│   └── bin/
└── macos-arm64/           # macOS Apple Silicon
    └── bin/
```

## Build Commands

Each cross-compilation target now uses the `-p` (prefix) flag to specify the output directory:

```bash
# Native build (uses default zig-out/)
make build

# Cross-compile for specific platforms
make cross-linux-x86_64     # Linux x86_64 → zig-out/linux-x86_64/
make cross-linux-arm64      # Linux ARM64 → zig-out/linux-arm64/
make cross-windows          # Windows x86_64 → zig-out/windows-x86_64/
make cross-macos-x86_64     # macOS Intel → zig-out/macos-x86_64/
make cross-macos-arm64      # macOS ARM64 → zig-out/macos-arm64/

# Build all cross-compilation targets
make cross-compile
```

## Benefits

1. **No Overwrites**: Each architecture has its own directory, preventing builds from overwriting each other
2. **Parallel Builds**: Multiple architectures can be built and kept simultaneously
3. **Easy Distribution**: Architecture-specific binaries are clearly organized for packaging
4. **CI/CD Friendly**: Build artifacts for different platforms can be easily collected and distributed

## Go Client Libraries

Go client examples are also built to the same architecture-specific directories:
- Windows: `zig-out/windows-x86_64/bin/gql-example.exe`
- Linux x86_64: `zig-out/linux-x86_64/bin/gql-example`
- Linux ARM64: `zig-out/linux-arm64/bin/gql-example`
- macOS Intel: `zig-out/macos-x86_64/bin/gql-example`
- macOS ARM64: `zig-out/macos-arm64/bin/gql-example`

## Docker File Updates

All Dockerfile variants have been updated to use the correct Zig 0.15.1 optimization flags:
- Changed from `-Drelease-safe` to `-Doptimize=ReleaseSafe`
- Changed from `-Drelease-fast` to `-Doptimize=ReleaseFast`

## Testing

To verify cross-compilation without overwrites:
```bash
make cross-linux-x86_64
make cross-windows
make cross-linux-arm64
ls -la zig-out/*/bin/geode*
```

All three architectures' binaries will coexist in their respective directories.