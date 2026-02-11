# ADR-004: Thread Safety Model

## Status
Accepted

## Context

GPU programming involves multiple threads:
- Host threads launching kernels
- Multiple streams for concurrent execution
- Multi-GPU scenarios with different contexts

We need to define clear thread-safety guarantees that:
- Enable safe concurrent usage
- Don't add unnecessary overhead
- Follow Zig's explicit concurrency philosophy

## Decision

Adopt a **minimal locking** approach with clearly documented thread-safety guarantees.

### Thread-Safety Levels

#### 1. Thread-Safe (with internal synchronization)

**Module kernel cache**: Protected by mutex

```zig
pub const Module = struct {
    mutex: std.Thread.Mutex = .{},
    kernels: StringHashMap(Kernel),

    pub fn getKernel(self: *Module, name: []const u8) !Kernel {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.kernels.get(name)) |k| return k;
        // ... load kernel
    }
};
```

#### 2. Thread-Compatible (safe if not shared)

**Memory manager**: No internal locking

```zig
// CORRECT: Per-thread memory managers
fn workerThread(allocator: Allocator) void {
    var mem = try Memory.init(driver, allocator);
    defer mem.deinit();
    // Safe: this thread owns mem
}

// INCORRECT: Shared memory manager
var shared_mem: Memory = undefined;
fn workerThread() void {
    const buf = shared_mem.allocDevice(1024); // RACE CONDITION
}
```

#### 3. CUDA-Level Synchronization

**Streams**: CUDA handles stream synchronization

```zig
// Different streams can be used from different threads
var stream1 = try Stream.create(driver);
var stream2 = try Stream.create(driver);

// Thread 1
kernel.launch(config.withStream(stream1), params);

// Thread 2 (concurrent)
kernel.launch(config.withStream(stream2), params);

// Synchronize
try stream1.synchronize();
try stream2.synchronize();
```

### Context Management

Each thread that uses CUDA must have a context active:

```zig
// Option 1: Primary context (automatic)
// CUDA automatically uses primary context if none is set

// Option 2: Explicit context with ContextScope
var scope = try ContextScope.init(&device);
defer scope.deinit();
// All CUDA calls in this scope use device's context

// Option 3: Push/Pop for temporary switch
try device.pushContext();
defer _ = device.popContext() catch {};
// Use device
```

### Multi-GPU Thread Affinity

Recommended pattern for multi-GPU:

```zig
fn gpuWorker(device: *Device) void {
    // Create context for this thread
    try device.createContext(0);
    defer device.destroyContext();

    try device.makeCurrent();

    // All operations use this device
    var mem = try Memory.init(device.drv, allocator);
    defer mem.deinit();

    // ... work
}

// Launch workers
var threads: [gpu_count]Thread = undefined;
for (devices.items, 0..) |*dev, i| {
    threads[i] = try Thread.spawn(.{}, gpuWorker, .{dev});
}
```

## Consequences

### Positive

- **Low overhead**: No locks on hot paths
- **Explicit**: Users know what is/isn't thread-safe
- **Flexible**: Per-thread resources scale well
- **CUDA-aligned**: Matches CUDA's own threading model

### Negative

- **User responsibility**: Must manage per-thread resources
- **Documentation critical**: Misuse causes subtle bugs
- **No global convenience**: Can't share Memory across threads easily

### Guidelines for Users

1. **Create per-thread**: Memory, Context, NvrtcCompiler
2. **Can share**: Module (has mutex), Driver (read-only after init)
3. **Use streams**: For concurrent GPU operations
4. **Use ContextScope**: For multi-GPU code

## Alternatives Considered

### 1. Full Thread Safety (all types locked)
Rejected: Too much overhead, not needed for typical usage.

### 2. No Thread Safety (all external)
Rejected: Module cache contention is common, worth protecting.

### 3. Lock-Free Structures
Considered: May add for specific hot paths in future.

## Documentation Requirements

Thread-safety must be documented:
- In type doc comments
- In API reference
- In usage guide with examples

## References

- [CUDA Thread Safety](https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#thread-safety)
- [Zig Atomics and Concurrency](https://ziglang.org/documentation/master/#Atomics)
