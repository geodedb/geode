# Thread-Safety Guarantees

This document defines the thread-safety guarantees for the Zig CUDA library.

## Overview

The library follows a **minimal locking** approach with clearly documented guarantees:

1. **Thread-Safe Types** - Internal synchronization provided
2. **Thread-Compatible Types** - Safe if not shared between threads
3. **CUDA-Level Synchronization** - Handled by CUDA runtime

## Thread-Safety Classification

### Thread-Safe (Internal Synchronization)

These types can be safely accessed from multiple threads:

| Type | Notes |
|------|-------|
| `CudaDriver` (global) | Read-only after initialization |
| `Module.kernels` cache | Protected by internal mutex |
| `getDriver()` | Uses `std.once` for thread-safe initialization |

```zig
// Safe: global driver is thread-safe
const driver = cuda.driver.getDriver();
if (driver.available()) {
    // Multiple threads can query driver
}
```

### Thread-Compatible (Not Shared)

These types should be created per-thread or protected by external synchronization:

| Type | Recommendation |
|------|----------------|
| `Memory` | Create per-thread instance |
| `Context` | One context per thread |
| `Stream` | Can be shared, but operations should be coordinated |
| `Module` (loading) | Load once, share read-only |
| `NvrtcCompiler` | Create per-thread |

```zig
// CORRECT: Per-thread memory manager
fn workerThread(allocator: Allocator) void {
    var mem = try Memory.init(driver, allocator);
    defer mem.deinit();
    // Safe: this thread owns mem
}

// INCORRECT: Shared memory manager without synchronization
var shared_mem: Memory = undefined;
fn workerThread() void {
    const buf = shared_mem.allocDevice(1024); // RACE CONDITION!
}
```

### CUDA-Level Thread Safety

CUDA provides its own thread-safety guarantees:

| Operation | Thread Safety |
|-----------|---------------|
| Different streams | Safe to use concurrently |
| Same stream | Must synchronize |
| Context switching | Use `pushContext`/`popContext` |
| Kernel launches | Safe on different streams |

## Context Management

Each thread that uses CUDA should have an active context:

```zig
// Option 1: Automatic via high-level Context API
var ctx = try cuda.Context.init(allocator, .{});
defer ctx.deinit();

// Option 2: Explicit context scope
{
    var scope = try cuda.ContextScope.init(&device);
    defer scope.deinit();
    // All CUDA calls use device's context
}

// Option 3: Push/pop for temporary switch
try device.pushContext();
defer _ = device.popContext() catch {};
```

## Multi-GPU Programming

### Per-Thread Context Pattern (Recommended)

```zig
fn gpuWorker(device: *Device) void {
    // Create context for this thread
    try device.createContext(0);
    defer device.destroyContext();

    try device.makeCurrent();

    // Thread-local resources
    var mem = try Memory.init(device.drv, allocator);
    defer mem.deinit();

    // ... work on this GPU
}

// Launch workers
var threads: [gpu_count]Thread = undefined;
for (devices.items, 0..) |*dev, i| {
    threads[i] = try Thread.spawn(.{}, gpuWorker, .{dev});
}
for (threads) |t| t.join();
```

### Stream-Based Concurrency Pattern

```zig
// Create streams (can be done from any thread)
var streams: [4]Stream = undefined;
for (&streams) |*s| {
    s.* = try Stream.create(driver);
}
defer for (&streams) |*s| s.destroy();

// Launch work on different streams (thread-safe)
for (streams, work_items) |stream, work| {
    try kernel.launch(config.withStream(stream), work.params);
}

// Synchronize
for (&streams) |*s| try s.synchronize();
```

## Synchronization Primitives

### Stream Synchronization

```zig
// Wait for all work in a stream
try stream.synchronize();

// Query if stream is complete (non-blocking)
if (stream.query()) |_| {
    // Stream is complete
}
```

### Event Synchronization

```zig
var event = try Event.create(driver);
defer event.destroy();

try event.record(stream);
try event.synchronize(); // Wait for event

// Measure time between events
const elapsed = try Event.elapsedTime(start_event, end_event);
```

### Context Synchronization

```zig
// Synchronize all work in current context
try driver.cuCtxSynchronize();
```

## Best Practices

### DO

1. Create per-thread `Memory` and `Context` instances
2. Use `ContextScope` for temporary GPU switches
3. Use streams for concurrent GPU operations
4. Synchronize before accessing results from another thread
5. Use the global driver singleton for read-only operations

### DON'T

1. Share `Memory` manager across threads without synchronization
2. Access GPU memory from multiple threads without synchronization
3. Assume kernel completion without explicit synchronization
4. Mix contexts across threads without `pushContext`/`popContext`

## API Thread-Safety Quick Reference

```
Safe to call from any thread:
  - driver.getDriver()
  - driver.available()
  - driver.supportsX() queries
  - LaunchConfig.for1D/for2D/for3D
  - ComputeArch.name/smString
  - MemoryAlignment.* functions

Requires thread-local context:
  - Memory.allocDevice/allocHost
  - Stream.create/destroy/synchronize
  - Module.load/getKernel
  - Kernel.launch

Requires synchronization:
  - Shared Buffer access
  - Module loading (while other threads use kernels)
```

## Platform-Specific Notes

### Linux
- CUDA context is per-thread by default
- `dlopen` used for library loading (thread-safe)

### macOS
- Same context model as Linux
- Requires CUDA toolkit installation

### Windows
- Same context model
- `LoadLibrary` used for library loading (thread-safe)

## References

- [CUDA Context Management](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__CTX.html)
- [CUDA Thread Safety](https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#thread-safety)
- [ADR-004: Thread Safety Model](adr/004-thread-safety.md)
