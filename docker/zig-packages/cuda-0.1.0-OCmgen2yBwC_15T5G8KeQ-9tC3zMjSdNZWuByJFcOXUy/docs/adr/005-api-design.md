# ADR-005: API Design Principles

## Status
Accepted

## Context

We're building a Zig interface to CUDA that should be:
- Idiomatic Zig
- Safe by default
- Performant
- Easy to use correctly
- Hard to use incorrectly

We need consistent design principles across the API.

## Decision

Adopt the following API design principles:

### 1. Explicit Resource Management

**RAII with explicit cleanup**:
```zig
var ctx = try cuda.Context.init(allocator, .{});
defer ctx.deinit();  // User controls cleanup timing

var stream = try Stream.create(driver);
defer stream.destroy();
```

**Why**: Zig doesn't have destructors. Explicit cleanup is idiomatic and makes resource lifetime clear.

### 2. Configuration via Structs

**Options structs with defaults**:
```zig
pub const ContextOptions = struct {
    device: u32 = 0,
    flags: u32 = 0,
    enable_pooling: bool = true,
};

var ctx = try Context.init(allocator, .{});  // All defaults
var ctx2 = try Context.init(allocator, .{ .device = 1 });  // Override one
```

**Why**: Extensible, self-documenting, no positional argument confusion.

### 3. Builder Pattern for Complex Configuration

**Chainable setters**:
```zig
var opts = NvrtcOptions.forArch(arch)
    .maxPerformance()
    .addDefine("DEBUG=1");
```

**Why**: Complex configurations are readable and discoverable.

### 4. Consistent Parameter Order

**Destination-Source-Size-Stream**:
```zig
copyHostToDevice(dst: Buffer, src: []const u8) !void
copyDeviceToHost(dst: []u8, src: Buffer) !void
copyDeviceToDevice(dst: Buffer, src: Buffer, size: usize) !void
copyHostToDeviceAsync(dst: Buffer, src: []const u8, stream: CUstream) !void
```

**Why**: Matches `memcpy` convention, consistent across all transfer functions.

### 5. Type Safety at Compile Time

**Typed kernel arguments**:
```zig
// Instead of void pointer arrays:
var args = cuda.TypedKernelArgs(struct {
    input: CUdeviceptr,
    output: CUdeviceptr,
    n: u32,
}).init(.{
    .input = in_buf.ptr,
    .output = out_buf.ptr,
    .n = 1024,
});

try kernel.launch(config, args.asParams());
```

**Why**: Compiler catches type mismatches before runtime.

### 6. Capability Queries Before Use

**Check before optional features**:
```zig
if (memory.hasUnifiedMemory()) {
    var buf = try memory.allocUnified(size);
} else {
    // Fallback
}

if (driver.supportsOccupancy()) {
    const opt = try kernel.getOptimalBlockSize(0, 0);
}
```

**Why**: Graceful handling of varying GPU capabilities.

### 7. Zero Surprises

**No hidden allocations**:
```zig
// Allocator is always explicit
var module = try Module.loadPtx(driver, allocator, ptx);

// No hidden state
const count = cuda.getDeviceCount();  // Pure query
```

**No hidden failures**:
```zig
// Errors are always in return type
pub fn launch(...) !void  // Can fail
pub fn isValid(...) bool  // Cannot fail
```

### 8. Convenience Wrappers

**Simple cases should be simple**:
```zig
// Full control
try kernel.launch(config, params);

// Convenience for common case
try kernel.launch1D(num_elements, block_size, params);
try kernel.launchSync(config, params);  // Launch + sync
```

### 9. Progressive Disclosure

**Layers of API complexity**:

1. **Simple**: `Context` high-level API
2. **Detailed**: Individual module APIs (Memory, Stream, Module)
3. **Low-level**: Direct driver access via `cuda.getDriver()`

```zig
// Level 1: High-level
var ctx = try cuda.Context.init(allocator, .{});
try ctx.memcpyH2D(buffer, data);

// Level 2: Module API
var mem = try Memory.init(driver, allocator);
try mem.copyHostToDevice(buffer, data);

// Level 3: Direct driver
const driver = cuda.getDriver();
_ = driver.memcpyHtoD(dptr, src, size);
```

## Consequences

### Positive

- **Consistent**: Patterns repeat across the API
- **Discoverable**: IDE autocomplete works well
- **Safe**: Type system catches errors
- **Flexible**: Multiple abstraction levels

### Negative

- **Verbose in some cases**: Type annotations required
- **Learning curve**: Multiple ways to do things
- **Documentation burden**: Must explain all patterns

## API Checklist

When adding new functionality:

- [ ] Uses error unions for fallible operations
- [ ] Takes allocator parameter if allocating
- [ ] Has options struct if >2 configuration points
- [ ] Follows dst-src-size-stream parameter order
- [ ] Has capability query if feature is optional
- [ ] Includes convenience wrappers for common cases
- [ ] Has comprehensive doc comments
- [ ] Has unit tests

## References

- [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide)
- [CUDA Best Practices Guide](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/)
