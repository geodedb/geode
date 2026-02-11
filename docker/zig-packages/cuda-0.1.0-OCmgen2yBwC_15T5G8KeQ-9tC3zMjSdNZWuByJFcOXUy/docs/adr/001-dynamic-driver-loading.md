# ADR-001: Dynamic CUDA Driver Loading

## Status
Accepted

## Context

CUDA libraries traditionally require linking against the CUDA runtime or driver libraries at compile time. This creates several problems:

1. **Build dependency**: Developers need the CUDA SDK installed to build
2. **Runtime coupling**: Binaries fail to start on systems without CUDA
3. **Version lock**: Hard to support multiple CUDA versions
4. **Distribution**: Can't distribute a single binary that works everywhere

We want a library that:
- Compiles without CUDA SDK installed
- Runs gracefully on systems without CUDA
- Adapts to the installed CUDA version at runtime

## Decision

Use dynamic loading (`dlopen`/`dlsym` on Linux) to load the CUDA driver library at runtime.

### Implementation

```zig
// driver.zig
pub fn loadDriver() !*CudaDriver {
    const handle = dlopen("libcuda.so.1", RTLD_LAZY) orelse {
        return error.DriverNotFound;
    };

    // Load function pointers
    driver.cuInit_fn = dlsym(handle, "cuInit");
    driver.cuDeviceGetCount_fn = dlsym(handle, "cuDeviceGetCount");
    // ... etc
}
```

### Driver API vs Runtime API

We chose the CUDA Driver API (`libcuda.so`) over the Runtime API (`libcudart.so`) because:

1. **Lower level**: More control over context and module management
2. **More stable ABI**: Driver API has better backwards compatibility
3. **System library**: `libcuda.so` is installed with the driver, not the toolkit
4. **No toolkit required**: Users only need NVIDIA drivers, not full CUDA SDK

### Symbol Versioning

CUDA uses versioned symbols (e.g., `cuCtxCreate_v2`). We load the versioned symbols when available:

```zig
driver.cuCtxCreate_fn = loadSymbol(handle, "cuCtxCreate_v2")
    orelse loadSymbol(handle, "cuCtxCreate");
```

## Consequences

### Positive

- **No build-time CUDA dependency**: Library compiles on any system
- **Graceful degradation**: `isAvailable()` returns false without CUDA
- **Single binary distribution**: Same binary works with or without CUDA
- **Version flexibility**: Adapts to installed driver version
- **CI/CD friendly**: Tests run on non-GPU machines (with mocked driver)

### Negative

- **Slightly more complex initialization**: Must check availability before use
- **Runtime symbol resolution**: Small overhead on first use
- **Platform-specific loading code**: Need separate implementations for Linux/Windows/macOS
- **No compile-time type checking for CUDA types**: Function signatures are manually defined

### Neutral

- Users must check `cuda.isAvailable()` before using GPU features
- Error messages must guide users to install NVIDIA drivers

## Alternatives Considered

### 1. Static Linking
Rejected: Creates hard dependency on CUDA SDK at build time.

### 2. Optional Dependency via Build System
Rejected: Still requires SDK for GPU builds, complicates distribution.

### 3. CUDA Runtime API
Rejected: Requires CUDA toolkit installation, not just drivers.

## References

- [CUDA Driver API Documentation](https://docs.nvidia.com/cuda/cuda-driver-api/)
- [dlopen man page](https://man7.org/linux/man-pages/man3/dlopen.3.html)
