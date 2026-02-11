# cuda - Zig CUDA Compute Library

A comprehensive CUDA compute library for Zig with graceful degradation, dynamic driver loading, and support for NVIDIA Blackwell architectures.

## Status

| Aspect | Info |
|--------|------|
| API Stability | Beta |
| Zig Version | 0.14.0+ |
| Platforms | Linux, Windows (CUDA-capable) |

## Features

### Core Capabilities
- **Dynamic Driver Loading**: Runtime loading of CUDA driver via dlopen/LoadLibrary (no compile-time NVIDIA SDK required)
- **Graceful Degradation**: Never panics when CUDA unavailable - returns errors for graceful handling
- **NVIDIA Blackwell Support**: Full support for SM 10.0 (GB100/GB102/GB202) architectures
- **Cross-Platform**: Linux, macOS, Windows support with platform-specific driver detection
- **Zero Dependencies**: Pure Zig implementation using only the standard library
- **Memory Pooling**: Efficient buffer reuse to minimize allocation overhead
- **PTX Loading**: Load and execute PTX (Parallel Thread Execution) kernels
- **NVRTC Integration**: Optional JIT compilation of CUDA C to PTX at runtime
- **Performance Profiling**: Built-in CUDA event-based timing and bandwidth measurement

### GPU Support
- **Device Enumeration**: Automatic detection and enumeration of all CUDA devices
- **Compute Capabilities**: SM 3.0 (Kepler) through SM 10.0 (Blackwell)
- **Architecture Detection**: Automatic architecture name and feature detection
- **Multi-GPU Ready**: Support for device selection and multi-context workflows

### Memory Management
- **Device Memory**: Standard GPU memory allocation
- **Pinned Memory**: Page-locked host memory for faster transfers
- **Unified Memory**: Managed memory accessible from CPU and GPU
- **Async Transfers**: Overlapped H2D/D2H transfers with streams
- **Memory Statistics**: Track allocations, transfers, and pool usage

In the high-level context API, `createBuffer` honors `MemoryKind`:

```zig
const device_buf = try ctx.createBuffer(1024, .device);
defer ctx.destroyBuffer(device_buf);

const unified_buf = try ctx.createBuffer(1024, .unified);
defer ctx.destroyBuffer(unified_buf);

const pinned = try ctx.createPinnedBuffer(1024);
defer ctx.destroyPinnedBuffer(pinned);
```

### Streams and Events
- **CUDA Streams**: Async kernel execution and memory operations
- **CUDA Events**: Synchronization and timing measurement
- **Stream Pools**: Reusable stream management
- **Event Timers**: High-precision GPU timing

## Requirements

- Zig 0.15.1 or later
- NVIDIA GPU with CUDA drivers (optional - library works without GPU)
- CUDA Driver 11.0+ recommended for full feature support

## Installation

Add `cuda` as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .cuda = .{
        .url = "https://gitlab.com/devnw/zig/cuda/-/archive/main/cuda-main.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const cuda_dep = b.dependency("cuda", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("cuda", cuda_dep.module("cuda"));
```

## Quick Start

### Check CUDA Availability

```zig
const std = @import("std");
const cuda = @import("cuda");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Quick availability check
    if (!cuda.isAvailable()) {
        std.debug.print("CUDA is not available\n", .{});
        return;
    }

    // Detailed probe with diagnostics
    var result = try cuda.probe(allocator);
    defer result.deinit(allocator);

    if (result.available) {
        std.debug.print("Found {} CUDA device(s)\n", .{result.device_count});
        for (result.devices) |dev| {
            std.debug.print("  {}: {s} ({s})\n", .{
                dev.id,
                dev.getName(),
                dev.getArchName(),
            });
        }
    } else {
        std.debug.print("CUDA unavailable: {s}\n", .{result.getErrorMessage()});
    }
}
```

### Basic GPU Compute

```zig
const std = @import("std");
const cuda = @import("cuda");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create CUDA context
    var ctx = cuda.Context.init(allocator, .{}) catch |err| {
        std.debug.print("Failed to create context: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    // Allocate device memory
    const buffer = try ctx.createBuffer(1024 * @sizeOf(f32), .device);
    defer ctx.destroyBuffer(buffer);

    // Upload data
    var host_data: [1024]f32 = undefined;
    for (&host_data, 0..) |*v, i| {
        v.* = @floatFromInt(i);
    }
    try ctx.memcpyH2D(buffer, std.mem.sliceAsBytes(&host_data));

    // Download results
    var result: [1024]f32 = undefined;
    try ctx.memcpyD2H(std.mem.sliceAsBytes(&result), buffer);
}
```

### Running a PTX Kernel

```zig
const cuda = @import("cuda");

// PTX kernel source
const kernel_ptx =
    \\.version 7.0
    \\.target sm_52
    \\.address_size 64
    \\
    \\.visible .entry my_kernel(
    \\    .param .u64 data,
    \\    .param .u32 n
    \\)
    \\{
    \\    // kernel code...
    \\    ret;
    \\}
;

pub fn main() !void {
    // ... context setup ...

    // Load PTX module
    const module = try ctx.createModulePtx(kernel_ptx);
    defer ctx.destroyModule(module);

    // Get kernel function
    const kernel = try ctx.getKernel(module, "my_kernel");

    // Set up arguments
    var data_ptr: u64 = buffer.ptr;
    var n: u32 = 1024;

    var args = cuda.KernelArgs(4){};
    args.addPtr(&data_ptr);
    args.addPtr(&n);

    // Launch kernel
    try ctx.launch(kernel, .{
        .grid = .{ 4, 1, 1 },
        .block = .{ 256, 1, 1 },
    }, args.getArgs());

    // Synchronize
    try ctx.syncAll();
}
```

## Building

```bash
# Build the library
zig build

# Run all tests (GPU tests skip gracefully if unavailable)
zig build test --summary all

# Run specific test suites
zig build test-types      # Type definitions
zig build test-driver     # Driver loading
zig build test-probe      # Device probing
zig build test-memory     # Memory management
zig build test-stream     # Streams and events
zig build test-module     # PTX loading
zig build test-context    # Context API
zig build test-integration # Full integration tests

# Build with optimization
zig build -Doptimize=ReleaseFast

# Build examples
zig build examples

# Run benchmarks
zig build benchmarks -Doptimize=ReleaseFast
./zig-out/bin/cuda_benchmark
```

## Using the Makefile

```bash
# Build and test
make

# Quick probe for CUDA
make probe

# Run benchmarks
make bench

# Development workflow
make dev

# See all targets
make help
```

## Project Structure

```
src/
├── cuda.zig             # Public API entry point
└── cuda/
    ├── types.zig        # CUDA types, errors, ComputeArch
    ├── driver.zig       # Dynamic CUDA driver loading
    ├── probe.zig        # Device detection and diagnostics
    ├── memory.zig       # Buffer management with pooling
    ├── stream.zig       # Streams, events, timers
    ├── module.zig       # PTX/CUBIN loading, kernels
    ├── context.zig      # High-level Context API
    └── profiler.zig     # Performance profiling
tests/
├── integration.zig      # GPU integration tests
benchmarks/
├── main.zig             # Benchmark suite (H2D, D2H, launch overhead)
examples/
├── device_info.zig      # Device enumeration example
└── vector_add.zig       # Complete CUDA workflow example
```

## Architecture Support

| Architecture | Compute Capability | Status |
|-------------|-------------------|--------|
| Kepler | SM 3.0 - 3.7 | Supported |
| Maxwell | SM 5.0 - 5.3 | Supported |
| Pascal | SM 6.0 - 6.2 | Supported |
| Volta | SM 7.0 | Supported |
| Turing | SM 7.5 | Supported |
| Ampere | SM 8.0 - 8.9 | Supported |
| Ada Lovelace | SM 8.9 | Supported |
| Hopper | SM 9.0 | Supported |
| **Blackwell** | SM 10.0 | **Supported** |

## Cross-Compilation

```bash
# Linux ARM64 (e.g., NVIDIA Jetson)
zig build -Dtarget=aarch64-linux-gnu

# Windows x64
zig build -Dtarget=x86_64-windows-gnu

# macOS ARM64
zig build -Dtarget=aarch64-macos
```

## Graceful Degradation

The library is designed to work on systems without CUDA:

```zig
// This never panics - returns false if CUDA unavailable
if (!cuda.isAvailable()) {
    // Fall back to CPU implementation
    return cpuCompute();
}

// Detailed diagnostics available
var probe = try cuda.probe(allocator);
if (!probe.available) {
    switch (probe.unavailable_reason) {
        .driver_not_found => // CUDA driver not installed
        .no_devices => // No NVIDIA GPUs found
        .kernel_module_not_loaded => // nvidia.ko not loaded
        .unsupported_platform => // Platform not supported
        // ... handle each case
    }
}
```

## Performance Considerations

- **Memory Pooling**: Buffers are pooled and reused to minimize cuMemAlloc overhead
- **Pinned Memory**: Use `.host_pinned` for faster H2D/D2H transfers
- **Streams**: Use streams for overlapped transfers and kernel execution
- **Batch Transfers**: Minimize the number of small transfers

## Documentation

- [Roadmap](docs/ROADMAP.md) - Development milestones and planned features
- [Changelog](docs/CHANGELOG.md) - Version history and changes

## Roadmap

The project follows a milestone-based development approach. See the full [Roadmap](docs/ROADMAP.md) for details.

| Milestone | Focus | Issues |
|-----------|-------|--------|
| **v0.2.0** | Critical Fixes | [#1](https://gitlab.com/devnw/zig/cuda/-/issues/1), [#2](https://gitlab.com/devnw/zig/cuda/-/issues/2), [#3](https://gitlab.com/devnw/zig/cuda/-/issues/3), [#4](https://gitlab.com/devnw/zig/cuda/-/issues/4), [#5](https://gitlab.com/devnw/zig/cuda/-/issues/5) |
| **v0.3.0** | Core Features | Unified memory, multi-GPU, CUBIN loading |
| **v0.4.0** | Performance | Transfer batching, pool optimization, profiling |
| **v1.0.0** | Stable Release | Documentation, cross-platform, API stability |

## Contributing

See [GitLab Issues](https://gitlab.com/devnw/zig/cuda/-/issues) for open tasks and the [Roadmap](docs/ROADMAP.md) for planned features.

### Guidelines

1. Code passes `zig fmt`
2. All tests pass (GPU tests may be skipped)
3. New features include tests
4. Graceful degradation maintained
5. Document thread-safety assumptions

### Getting Started

1. Pick an issue from the [roadmap](docs/ROADMAP.md)
2. Comment on the issue to claim it
3. Fork the repository
4. Create a feature branch
5. Submit a merge request

## License

Apache-2.0 License - see [LICENSE](LICENSE) for details.
