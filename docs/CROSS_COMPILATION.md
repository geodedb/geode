# Cross-Compilation Support for Geode Clients

This document describes the cross-compilation infrastructure for Geode client libraries in both Zig and Go.

## Supported Platforms

### Zig Client Library
- **Linux x86_64** (native)
- **Linux ARM64** (aarch64)
- **Windows x86_64**
- **macOS x86_64**
- **macOS ARM64**

### Go Client Library
- **Linux x86_64** (native)
- **Linux ARM64** (aarch64)
- **Windows x86_64**
- **macOS x86_64**
- **macOS ARM64**

## Building Cross-Compiled Clients

### Build All Clients
```bash
# Build all client libraries for all platforms
make cross-clients

# Build only Zig clients
make cross-zig-clients

# Build only Go clients
make cross-go-clients
```

### Individual Platform Builds
```bash
# Windows x86_64
make cross-windows

# Linux ARM64
make cross-linux-arm64

# macOS x86_64
make cross-macos-x86_64
```

## Testing Cross-Compiled Clients

### Automated Testing
```bash
# Test all cross-compiled clients
make test-cross-clients

# Test with QEMU emulation (more comprehensive)
make qemu-test-clients

# Use the test script directly
./scripts/test-cross-clients.sh
```

### Manual Testing with QEMU

#### Linux ARM64
```bash
# Install QEMU
sudo apt-get install qemu-user qemu-user-static

# Test Zig client
qemu-aarch64 -L /usr/aarch64-linux-gnu \
    zig-out/clients/linux-arm64/geode-zig-example-linux-arm64

# Test Go client
qemu-aarch64 -L /usr/aarch64-linux-gnu \
    zig-out/clients/linux-arm64/gql-example
```

#### Windows (using Wine)
```bash
# Install Wine
sudo apt-get install wine wine64

# Test Zig client
wine64 zig-out/clients/windows-x86_64/geode-zig-example-windows-x86_64.exe

# Test Go client
wine64 zig-out/clients/windows-x86_64/gql-example.exe
```

## Output Directory Structure

After running `make cross-clients`, the following structure is created:

```
zig-out/clients/
├── linux-x86_64/
│   ├── libgeode-client-linux-x86_64.a    # Zig static library
│   ├── geode-zig-example-linux-x86_64    # Zig example executable
│   └── gql-example                       # Go example executable
├── linux-arm64/
│   ├── libgeode-client-linux-arm64.a
│   ├── geode-zig-example-linux-arm64
│   └── gql-example
├── windows-x86_64/
│   ├── geode-client-windows-x86_64.lib
│   ├── geode-zig-example-windows-x86_64.exe
│   ├── geode-zig-example-windows-x86_64.pdb
│   └── gql-example.exe
├── macos-x86_64/
│   ├── libgeode-client-macos-x86_64.a
│   ├── geode-zig-example-macos-x86_64
│   └── gql-example
└── macos-arm64/
    ├── libgeode-client-macos-arm64.a
    ├── geode-zig-example-macos-arm64
    └── gql-example
```

## Binary Sizes

Typical binary sizes for cross-compiled clients:

- **Zig clients**: 250KB - 2.2MB (depending on platform and debug symbols)
- **Go clients**: 8-9MB (statically linked, no CGO dependencies)

## CI/CD Integration

### GitHub Actions Workflow

The `.github/workflows/cross-compile-clients.yml` workflow automatically:
1. Cross-compiles clients for all platforms
2. Tests them with QEMU where available
3. Uploads artifacts for download
4. Creates release packages when tagging

### Local CI Testing
```bash
# Run the full CI pipeline including cross-compilation
make ci

# Just test cross-compilation
make cross-compile-strict
```

## Development Notes

### Zig Client
- Uses minimal dependencies for maximum portability
- Compiles to static libraries for easy integration
- Supports Zig 0.15.1+ API

### Go Client
- Built with `CGO_ENABLED=0` for pure Go binaries
- No external C dependencies
- Fully static binaries for all platforms

### Testing Considerations
- QEMU user-mode emulation is used for ARM64 testing
- Wine is used for Windows binary testing on Linux
- Connection failures during testing are expected if server isn't running
- Tests verify that binaries can execute on target platforms

## Troubleshooting

### QEMU Not Found
```bash
# Ubuntu/Debian
sudo apt-get install qemu-user qemu-user-static

# Fedora
sudo dnf install qemu-user qemu-user-static

# Arch
sudo pacman -S qemu-user qemu-user-static
```

### Wine Not Found
```bash
# Ubuntu/Debian
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install wine wine64

# Fedora
sudo dnf install wine

# Arch
sudo pacman -S wine
```

### Go Cross-Compilation Fails
Ensure CGO is disabled:
```bash
CGO_ENABLED=0 GOOS=target_os GOARCH=target_arch go build
```

### Zig Cross-Compilation Fails
Check Zig version:
```bash
zig version  # Should be 0.15.1 or later
```

## Future Enhancements

- [ ] Add RISC-V 64-bit support when stable
- [ ] Add WebAssembly (WASM) target
- [ ] Create language bindings for Python, Ruby, etc.
- [ ] Add performance benchmarks across platforms
- [ ] Implement integration tests with real server