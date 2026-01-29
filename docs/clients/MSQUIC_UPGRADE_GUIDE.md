# MsQuic Upgrade Guide - Fix for Zig/Rust Client Compatibility

## Current Status

- **Installed Version**: MsQuic 2.4.16 (Ubuntu package)
- **Issue**: Incompatible with MsQuic and quiche QUIC clients
- **Solution**: Upgrade to latest MsQuic from source

## Prerequisites

```bash
# Install build dependencies
sudo apt-get update
sudo apt-get install -y cmake build-essential git libssl-dev \
  libnuma-dev pkg-config
```

## Step 1: Remove Old Package

```bash
# Backup current setup
sudo ldconfig -p | grep msquic > /tmp/msquic_old_libs.txt

# Remove Ubuntu package
sudo apt-get remove -y libmsquic libmsquic-dev

# Verify removal
dpkg -l | grep msquic  # Should show no results
```

## Step 2: Build MsQuic from Source

```bash
# Clone latest MsQuic
cd /tmp
git clone --recursive https://github.com/microsoft/msquic.git
cd msquic

# Check out latest stable release (or use main for bleeding edge)
git checkout $(git describe --tags `git rev-list --tags --max-count=1`)

# Create build directory
mkdir build && cd build

# Configure build
cmake -G 'Unix Makefiles' \
  -DCMAKE_BUILD_TYPE=Release \
  -DQUIC_TLS=openssl \
  ..

# Build (this will take 10-20 minutes)
cmake --build . --config Release -j$(nproc)

# Install system-wide
sudo cmake --install .

# Update library cache
sudo ldconfig

# Verify installation
ldconfig -p | grep msquic
```

Expected output:

```
libmsquic.so.2 (libc6,x86-64) => /usr/local/lib/libmsquic.so.2
libmsquic.so (libc6,x86-64) => /usr/local/lib/libmsquic.so
```

## Step 3: Rebuild Geode

```bash
cd /home/benji/src/spyder/geode

# Clean previous build
make clean
rm -rf zig-cache zig-out

# Rebuild with new MsQuic
make build

# Verify geode binary is linked correctly
ldd ./zig-out/bin/geode | grep msquic
```

Expected output should show `/usr/local/lib/libmsquic.so.2`

## Step 4: Test All Clients

```bash
cd clients/test-harness

# Run comprehensive test suite
make test-with-coverage
```

### Expected Results (BEFORE fix)

- Python: 51/51 ✅ (100%)
- Go: 51/51 ✅ (100%)
- Rust: 0/51 ❌ (0% - timeout)
- Zig: 0/51 ❌ (0% - timeout)

### Expected Results (AFTER fix)

- Python: 51/51 ✅ (100%)
- Go: 51/51 ✅ (100%)
- Rust: 51/51 ✅ (100%) ← **FIXED**
- Zig: 51/51 ✅ (100%) ← **FIXED**

## Troubleshooting

### Issue: Library Not Found After Install

```bash
# Check if library is in non-standard location
find /usr -name "libmsquic.so*" 2>/dev/null

# If found in /usr/local/lib, add to LD_LIBRARY_PATH
echo 'export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH' >> ~/.bashrc
source ~/.bashrc

# Or add to system library path
echo "/usr/local/lib" | sudo tee /etc/ld.so.conf.d/msquic.conf
sudo ldconfig
```

### Issue: Build Fails with OpenSSL Errors

```bash
# Ensure OpenSSL development headers are installed
sudo apt-get install -y libssl-dev

# Check OpenSSL version
openssl version  # Should be 1.1.1 or newer

# If using OpenSSL 3.x, you may need:
cmake -DQUIC_TLS=openssl3 ..
```

### Issue: Geode Still Uses Old MsQuic

```bash
# Force clean rebuild
cd /home/benji/src/spyder/geode
rm -rf zig-cache zig-out ~/.cache/zig

# Rebuild
zig build

# Verify linkage
ldd ./zig-out/bin/geode | grep msquic
```

## Rollback Procedure

If the upgrade causes issues:

```bash
# Reinstall Ubuntu package
sudo apt-get install -y libmsquic=2.4.16

# Remove source-built version
sudo rm -f /usr/local/lib/libmsquic.so*
sudo ldconfig

# Rebuild geode
cd /home/benji/src/spyder/geode
make clean && make build
```

## Verification Tests

### Test 1: Quick Zig Client Test

```bash
cd /home/benji/src/spyder/geode

# Start server
./zig-out/bin/geode serve --listen 127.0.0.1:9999 &
SERVER_PID=$!
sleep 2

# Test Zig client
cd clients/zig
./zig-out/bin/test_connection_v2

# Should complete successfully without timeout
kill $SERVER_PID
```

### Test 2: Quick Rust Client Test

```bash
cd /home/benji/src/spyder/geode

# Start server
./zig-out/bin/geode serve --listen 127.0.0.1:9999 &
SERVER_PID=$!
sleep 2

# Test Rust client (if built)
cd clients/rust
cargo run --example simple_query

# Should complete successfully without timeout
kill $SERVER_PID
```

## Estimated Timeline

- Step 1 (Remove): 2 minutes
- Step 2 (Build MsQuic): 15-25 minutes
- Step 3 (Rebuild Geode): 2-3 minutes
- Step 4 (Test): 5-10 minutes

**Total**: ~25-40 minutes

## Success Criteria

✅ All 4 client languages (Python, Go, Rust, Zig) pass 100% of tests  
✅ No timeout errors from Zig or Rust clients  
✅ Server log shows `[LISTENER_CALLBACK] NEW_CONNECTION` events for all clients  
✅ `make test-with-coverage` shows 100% pass rate across all runners

---

**Next Steps**: Follow this guide step-by-step, then rerun the test suite to verify the fix.
