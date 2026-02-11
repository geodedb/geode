# ADR-006: Context Management Strategy

## Status
Accepted

## Context

CUDA contexts are fundamental to GPU operations:
- All GPU operations happen within a context
- Contexts are bound to a specific device
- Multi-GPU requires managing multiple contexts
- Context switching has overhead

We need a context management strategy that:
- Makes single-GPU usage simple
- Enables multi-GPU programming
- Minimizes context switching overhead
- Prevents common mistakes

## Decision

Provide multiple context management patterns at different abstraction levels.

### Level 1: Implicit Context (High-Level API)

The `Context` type manages context automatically:

```zig
var ctx = try cuda.Context.init(allocator, .{ .device = 0 });
defer ctx.deinit();

// All operations implicitly use this context
const buf = try ctx.memory.allocDevice(1024);
try ctx.launchKernel(kernel, config, params);
```

**Implementation**: Context creates and activates a CUDA context on init.

### Level 2: Device-Based Context (Multi-GPU)

Each Device can have its own context:

```zig
var devices = try cuda.device.enumerate(driver, allocator);
defer devices.deinit();

// Create contexts for all GPUs
try devices.createAllContexts(0);

// Work on specific GPU
try devices.items[0].makeCurrent();
// ... operations on GPU 0

try devices.items[1].makeCurrent();
// ... operations on GPU 1
```

### Level 3: Context Stack (Temporary Switch)

CUDA's context stack for temporary operations:

```zig
// Save current, switch to device
try device.pushContext();
defer _ = device.popContext() catch {};

// Work on device
try memory.allocDevice(1024);
```

### Level 4: Scoped Context (RAII Pattern)

ContextScope for automatic push/pop:

```zig
{
    var scope = try cuda.ContextScope.init(&gpu1);
    defer scope.deinit();

    // All operations in this scope use gpu1
    try memory.allocDevice(1024);
}
// Original context restored
```

### Level 5: Direct Context Functions

Module-level functions for low-level control:

```zig
const current = try cuda.getCurrentContext(driver);
try cuda.pushContext(driver, ctx);
_ = try cuda.popContext(driver);
```

## Context Lifecycle

```
┌─────────────────────────────────────────────┐
│              Application                     │
├─────────────────────────────────────────────┤
│  cuda.Context.init()                        │
│    └─> cuCtxCreate()                        │
│    └─> Makes context current                │
├─────────────────────────────────────────────┤
│  ... GPU operations ...                     │
│    └─> All use current context              │
├─────────────────────────────────────────────┤
│  cuda.Context.deinit()                      │
│    └─> cuCtxDestroy()                       │
└─────────────────────────────────────────────┘
```

## Multi-GPU Pattern

Recommended pattern for multi-GPU workloads:

```zig
const devices = try cuda.device.enumerate(driver, allocator);
defer devices.deinit();

// Option A: Sequential with context switching
for (devices.items) |*dev| {
    try dev.makeCurrent();
    processOnDevice(dev);
}

// Option B: Parallel with per-thread contexts
var threads: [MAX_GPUS]Thread = undefined;
for (devices.items, 0..) |*dev, i| {
    threads[i] = try Thread.spawn(.{}, struct {
        fn work(device: *Device) void {
            try device.createContext(0);
            defer device.destroyContext();
            try device.makeCurrent();
            processOnDevice(device);
        }
    }.work, .{dev});
}
for (threads[0..devices.count()]) |t| t.join();

// Option C: ContextScope for temporary switch
for (devices.items) |*dev| {
    var scope = try ContextScope.init(dev);
    defer scope.deinit();
    processOnDevice(dev);
}
```

## Consequences

### Positive

- **Simple default**: Single-GPU just works
- **Flexible**: Multiple patterns for different needs
- **Safe**: ContextScope prevents context leaks
- **Efficient**: Stack-based switching is fast
- **Familiar**: Patterns match CUDA documentation

### Negative

- **Complexity**: Multiple patterns to learn
- **Subtle bugs**: Wrong context can cause silent failures
- **Overhead**: Context creation is expensive

### Best Practices

1. **Single GPU**: Use `Context` high-level API
2. **Multi-GPU parallel**: Per-thread contexts
3. **Multi-GPU sequential**: ContextScope or makeCurrent
4. **Temporary switch**: Use pushContext/popContext or ContextScope
5. **Peer access**: Enable before cross-GPU transfers

## Alternatives Considered

### 1. Always-Implicit Context
Rejected: Doesn't work for multi-GPU scenarios.

### 2. Always-Explicit Context Parameter
Rejected: Too verbose for single-GPU (common case).

### 3. Global Context Registry
Rejected: Complicates multi-threading.

## References

- [CUDA Context Management](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__CTX.html)
- [Multi-GPU Programming](https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#multi-gpu)
