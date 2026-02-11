# ADR-003: Error Handling Approach

## Status
Accepted

## Context

CUDA operations can fail for many reasons:
- Driver not installed
- No GPU available
- Out of memory
- Invalid parameters
- Kernel launch failures
- Synchronization errors

We need an error handling approach that:
- Is idiomatic Zig
- Provides actionable error information
- Enables graceful degradation
- Doesn't require exception handling overhead

## Decision

Use Zig's error union types with a comprehensive `CudaError` enum.

### Error Type Definition

```zig
pub const CudaError = error{
    // Initialization
    DriverNotFound,
    InitFailed,
    NoDevice,
    InvalidDevice,

    // Memory
    OutOfMemory,
    InvalidArgument,

    // Context
    ContextError,
    ContextCreateFailed,

    // Modules/Kernels
    ModuleLoadFailed,
    FunctionNotFound,
    LaunchFailed,

    // Operations
    SyncFailed,
    CopyFailed,

    // Features
    NotSupported,
    CompilationFailed,
    NvrtcNotFound,

    // Generic
    GpuError,
};
```

### Error Checking Pattern

```zig
pub fn allocDevice(self: *Memory, size: usize) !Buffer {
    if (!self.drv.available()) return CudaError.DriverNotFound;
    if (size == 0) return CudaError.InvalidArgument;

    var dptr: CUdeviceptr = 0;
    const result = self.drv.memAlloc(&dptr, size);
    if (result != CUDA_SUCCESS) {
        return CudaError.OutOfMemory;
    }

    return Buffer{ .ptr = dptr, .size = size, ... };
}
```

### Pre-flight Availability Checks

```zig
// Quick check
if (!cuda.isAvailable()) {
    return fallback();
}

// Detailed check
var result = try cuda.probe(allocator);
defer result.deinit(allocator);

if (!result.available) {
    log.warn("CUDA unavailable: {s}", .{result.getErrorMessage()});
    return fallback();
}
```

### Error Recovery Patterns

```zig
// Retry with cleanup
const buf = mem.allocDevice(size) catch |err| switch (err) {
    error.OutOfMemory => {
        mem.clearPool();
        return mem.allocDevice(size);
    },
    else => return err,
};

// Fallback
const result = kernel.launch(config, params) catch |err| {
    log.err("GPU failed: {}, using CPU", .{err});
    return cpuFallback();
};
```

## Consequences

### Positive

- **Type safety**: Compiler enforces error handling
- **No hidden control flow**: Errors are explicit in signatures
- **Zero overhead**: No exception mechanism
- **Pattern matching**: `switch` on error for specific handling
- **Graceful degradation**: Easy to implement fallbacks

### Negative

- **Verbose in some cases**: Must handle or propagate all errors
- **Limited error context**: No stack traces by default
- **CUDA code mapping**: Manual translation from CUDA error codes

### Error Code Mapping

We deliberately map CUDA error codes to semantic errors:

| CUDA Code | CudaError |
|-----------|-----------|
| CUDA_ERROR_NOT_INITIALIZED | InitFailed |
| CUDA_ERROR_NO_DEVICE | NoDevice |
| CUDA_ERROR_OUT_OF_MEMORY | OutOfMemory |
| CUDA_ERROR_INVALID_VALUE | InvalidArgument |
| CUDA_ERROR_LAUNCH_FAILED | LaunchFailed |

This provides meaningful errors without exposing CUDA internals.

## Alternatives Considered

### 1. Return CUDA Error Codes Directly
Rejected: Leaks CUDA abstraction, harder to handle.

### 2. Global Error State
Rejected: Not thread-safe, error-prone, not idiomatic Zig.

### 3. Result Types with Error Details
Considered: Could add `ErrorContext` struct with more details.
May add in future for debugging scenarios.

### 4. Panic on Unrecoverable Errors
Rejected: Users should decide recovery strategy.

## Future Enhancements

1. **Error context**: Add optional detailed error info
2. **CUDA error strings**: Map codes to human-readable messages (#25)
3. **Logging integration**: Optional error logging hook

## References

- [Zig Error Handling](https://ziglang.org/documentation/master/#Errors)
- [CUDA Error Codes](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__TYPES.html)
