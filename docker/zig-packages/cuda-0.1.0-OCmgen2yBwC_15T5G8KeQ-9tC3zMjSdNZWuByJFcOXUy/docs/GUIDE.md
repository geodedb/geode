# CUDA Zig Library User Guide

A comprehensive guide to using the CUDA Zig library for GPU computing.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Basic Usage](#basic-usage)
3. [Memory Management](#memory-management)
4. [Kernel Execution](#kernel-execution)
5. [Streams and Concurrency](#streams-and-concurrency)
6. [Multi-GPU Programming](#multi-gpu-programming)
7. [Performance Optimization](#performance-optimization)
8. [Error Handling](#error-handling)
9. [Integration Examples](#integration-examples)

---

## Getting Started

### Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .cuda = .{
        .url = "https://gitlab.com/devnw/zig/cuda/-/archive/v0.3.0/cuda-v0.3.0.tar.gz",
        .hash = "...",
    },
},
```

In `build.zig`:

```zig
const cuda = b.dependency("cuda", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("cuda", cuda.module("cuda"));
```

### Prerequisites

- NVIDIA GPU with CUDA support
- NVIDIA driver installed (CUDA toolkit not required for runtime)
- Linux (Windows/macOS support planned)

### Checking Availability

Always check CUDA availability before use:

```zig
const std = @import("std");
const cuda = @import("cuda");

pub fn main() !void {
    // Quick check
    if (!cuda.isAvailable()) {
        std.debug.print("CUDA not available\n", .{});
        return;
    }

    // Detailed probe
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var result = try cuda.probe(gpa.allocator());
    defer result.deinit(gpa.allocator());

    if (result.available) {
        std.debug.print("Found {} GPU(s):\n", .{result.device_count});
        for (result.devices) |dev| {
            std.debug.print("  [{d}] {s} - {d:.1} GB ({s})\n", .{
                dev.ordinal,
                dev.getName(),
                dev.getTotalMemoryGB(),
                dev.getArchName(),
            });
        }
    } else {
        std.debug.print("CUDA error: {s}\n", .{result.getErrorMessage()});
    }
}
```

---

## Basic Usage

### High-Level Context API

The easiest way to use CUDA:

```zig
const cuda = @import("cuda");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create context (automatically selects GPU 0)
    var ctx = try cuda.Context.init(allocator, .{});
    defer ctx.deinit();

    // Allocate device memory
    const buffer = try ctx.memory.allocDevice(1024 * @sizeOf(f32));
    defer ctx.memory.freeDevice(buffer);

    // Transfer data
    var host_data: [1024]f32 = undefined;
    for (&host_data, 0..) |*v, i| {
        v.* = @floatFromInt(i);
    }

    try ctx.memory.copyHostToDevice(buffer, std.mem.sliceAsBytes(&host_data));

    // ... launch kernels ...

    try ctx.memory.copyDeviceToHost(std.mem.sliceAsBytes(&host_data), buffer);
}
```

### Selecting a Specific GPU

```zig
var ctx = try cuda.Context.init(allocator, .{
    .device = 1,  // Use GPU 1
});
```

---

## Memory Management

### Memory Types

#### Device Memory (Fastest)

```zig
const buf = try mem.allocDevice(size);
defer mem.freeDevice(buf);

// Transfer to device
try mem.copyHostToDevice(buf, host_data);

// Use in kernel
try kernel.launch(config, cuda.kernelParams(.{ &buf.ptr, &size }));

// Transfer back
try mem.copyDeviceToHost(result_data, buf);
```

#### Pinned Memory (Fast Transfers)

```zig
// Allocate page-locked host memory
const pinned = try mem.allocPinned(size);
defer mem.freePinned(pinned);

// Fill data
@memcpy(pinned, source_data);

// Async transfer (requires pinned memory!)
try mem.copyHostToDeviceAsync(device_buf, pinned, stream);
```

#### Unified Memory (Easiest)

```zig
if (mem.hasUnifiedMemory()) {
    var ubuf = try mem.allocUnified(size);
    defer mem.freeUnified(&ubuf);

    // Access directly from CPU
    const slice = ubuf.asHostSlice(f32);
    for (slice, 0..) |*v, i| {
        v.* = @floatFromInt(i);
    }

    // Use in kernel (automatic migration)
    try kernel.launch(config, cuda.kernelParams(.{ &ubuf.ptr }));
    try ctx.synchronize();

    // Read result on CPU
    std.debug.print("Result: {}\n", .{slice[0]});

    // Optimization: prefetch to device before kernel
    try ubuf.prefetchToDevice(device, stream);
}
```

### Memory Pool Management

```zig
// Monitor pool status
const stats = mem.getPoolStats();
std.debug.print("Pool: {} buffers, {} free, {d:.1}% fragmented\n", .{
    stats.total_buffers,
    stats.free_buffers,
    stats.fragmentation_ratio * 100,
});

// Clean up small unused buffers
const freed = mem.defragment(64 * 1024);  // Free buffers < 64KB
std.debug.print("Freed {} buffers\n", .{freed});

// Keep only 5 largest free buffers
_ = mem.compact(5);

// Full cleanup
mem.clearPool();
```

### Batch Transfers

```zig
// Create batch for multiple transfers
var batch = mem.createTransferBatch(stream);
defer batch.deinit();

// Queue transfers
try batch.addH2D(buf1, data1);
try batch.addH2D(buf2, data2);
try batch.addD2H(result, buf3);

// Execute all at once
try batch.execute();

std.debug.print("Transferred {} bytes in {} operations\n", .{
    batch.getTotalBytes(),
    batch.count(),
});
```

---

## Kernel Execution

### Loading Kernels

#### From PTX String

```zig
const ptx =
    \\.version 7.0
    \\.target sm_52
    \\.address_size 64
    \\
    \\.visible .entry add_vectors(
    \\    .param .u64 a,
    \\    .param .u64 b,
    \\    .param .u64 c,
    \\    .param .u32 n
    \\)
    \\{
    \\    // ... kernel code
    \\}
;

var module = try cuda.Module.loadPtx(driver, allocator, ptx);
defer module.unload();

const kernel = try module.getKernel("add_vectors");
```

#### From CUBIN File

```zig
var module = try cuda.Module.loadFile(driver, allocator, "kernels.cubin");
defer module.unload();
```

#### Runtime Compilation (NVRTC)

```zig
var compiler = cuda.NvrtcCompiler.init(allocator);
defer compiler.deinit();

if (compiler.available()) {
    const source =
        \\extern "C" __global__ void scale(float* data, float factor, int n) {
        \\    int idx = blockIdx.x * blockDim.x + threadIdx.x;
        \\    if (idx < n) data[idx] *= factor;
        \\}
    ;

    // Compile with optimization
    var opts = cuda.NvrtcOptions.forArch(device_arch);
    _ = opts.maxPerformance();

    const ptx = try compiler.compileToPtxWithOptions(source, "scale.cu", opts);
    defer allocator.free(ptx);

    var module = try cuda.Module.loadPtx(driver, allocator, ptx);
    defer module.unload();
}
```

### Launch Configuration

```zig
// Manual configuration
const config = cuda.LaunchConfig{
    .grid = .{ 256, 1, 1 },   // 256 blocks
    .block = .{ 256, 1, 1 },  // 256 threads per block
    .shared_mem = 0,
    .stream = null,
};

// 1D helper
const config1d = cuda.LaunchConfig.for1D(num_elements, 256);

// 2D helper
const config2d = cuda.LaunchConfig.for2D(width, height, 16, 16);

// Optimal configuration (uses occupancy calculator)
const opt = try kernel.getOptimalBlockSize(0, 0);
const config_opt = opt.toLaunchConfig(num_elements);
```

### Kernel Arguments

#### Type-Safe Arguments (Recommended)

```zig
const Args = struct {
    input: cuda.CUdeviceptr,
    output: cuda.CUdeviceptr,
    scale: f32,
    n: u32,
};

var args = cuda.TypedKernelArgs(Args).init(.{
    .input = in_buf.ptr,
    .output = out_buf.ptr,
    .scale = 2.5,
    .n = 1024,
});

try kernel.launch(config, args.asParams());
```

#### Quick Tuple Arguments

```zig
var scale: f32 = 2.5;
var n: u32 = 1024;

try kernel.launch(config, cuda.kernelParams(.{
    &in_buf.ptr,
    &out_buf.ptr,
    &scale,
    &n,
}));
```

#### Dynamic Arguments

```zig
var args = cuda.KernelArgs(8){};
args.addPtr(&in_buf.ptr);
args.addPtr(&out_buf.ptr);
args.addPtr(&scale);
args.addPtr(&n);

try kernel.launch(config, args.getArgs());
```

### Launching

```zig
// Async launch (returns immediately)
try kernel.launch(config, params);
// ... other work ...
try cuda.synchronize();  // Wait for completion

// Sync launch (waits for completion)
try kernel.launchSync(config, params);

// 1D convenience
try kernel.launch1D(num_elements, 256, params);
```

---

## Streams and Concurrency

### Creating Streams

```zig
// Default priority
var stream = try cuda.Stream.create(driver);
defer stream.destroy();

// High priority
var fast_stream = try cuda.Stream.createWithPriority(driver, .high);
defer fast_stream.destroy();
```

### Concurrent Execution

```zig
var stream1 = try cuda.Stream.create(driver);
var stream2 = try cuda.Stream.create(driver);
defer stream1.destroy();
defer stream2.destroy();

// Queue operations on different streams (run concurrently)
try mem.copyHostToDeviceAsync(buf1, data1, stream1.handle);
try mem.copyHostToDeviceAsync(buf2, data2, stream2.handle);

try kernel1.launch(config.withStream(stream1.handle), params1);
try kernel2.launch(config.withStream(stream2.handle), params2);

// Wait for both
try stream1.synchronize();
try stream2.synchronize();
```

### Events for Synchronization

```zig
var event = try cuda.Event.create(driver);
defer event.destroy();

// Record after kernel
try kernel.launch(config, params);
try event.record(stream.handle);

// Another stream waits for event
try stream2.waitEvent(event);
try kernel2.launch(config.withStream(stream2.handle), params2);
```

### Timing with Events

```zig
var timer = try cuda.EventTimer.start(driver, stream.handle);
try kernel.launch(config, params);
try timer.stop(stream.handle);

const elapsed = try timer.getElapsedMs();
std.debug.print("Kernel took {d:.2} ms\n", .{elapsed});
timer.deinit();
```

---

## Multi-GPU Programming

### Enumerating Devices

```zig
var devices = try cuda.device.enumerate(driver, allocator);
defer devices.deinit();

std.debug.print("Found {} GPUs:\n", .{devices.count()});
for (devices.items) |dev| {
    std.debug.print("  GPU {}: {s}\n", .{ dev.ordinal, dev.getName() });
}
```

### Using Multiple GPUs

```zig
// Create contexts for all GPUs
try devices.createAllContexts(0);

// Option 1: Sequential with context switching
for (devices.items) |*dev| {
    try dev.makeCurrent();
    processDataOnDevice(dev);
}

// Option 2: Using ContextScope
for (devices.items) |*dev| {
    var scope = try cuda.ContextScope.init(dev);
    defer scope.deinit();

    processDataOnDevice(dev);
}
```

### Parallel Multi-GPU

```zig
const Thread = std.Thread;

fn gpuWorker(dev: *cuda.Device, data: []const f32) void {
    try dev.makeCurrent();

    var mem = cuda.Memory.init(dev.drv, std.heap.page_allocator) catch return;
    defer mem.deinit();

    // Process on this GPU
    const buf = mem.allocDevice(data.len * @sizeOf(f32)) catch return;
    defer mem.freeDevice(buf);

    mem.copyHostToDevice(buf, std.mem.sliceAsBytes(data)) catch return;
    // ... kernel ...
}

// Launch workers
var threads: [8]?Thread = .{null} ** 8;
for (devices.items, 0..) |*dev, i| {
    threads[i] = try Thread.spawn(.{}, gpuWorker, .{ dev, data_chunks[i] });
}

// Wait for all
for (&threads) |*t| {
    if (t.*) |thread| {
        thread.join();
        t.* = null;
    }
}
```

### Peer-to-Peer Access

```zig
// Check and enable peer access
if (try dev0.canAccessPeer(&dev1)) {
    try dev0.enablePeerAccess(&dev1);
    try dev1.enablePeerAccess(&dev0);

    // Now can copy directly between GPUs
    try dev0.makeCurrent();
    try mem0.copyDeviceToDevice(buf_on_dev1, buf_on_dev0, size);
}
```

---

## Performance Optimization

### Occupancy-Based Launch

```zig
// Let CUDA determine optimal configuration
const opt = try kernel.getOptimalBlockSize(0, 0);
std.debug.print("Optimal: {} threads/block, min {} blocks\n", .{
    opt.block_size,
    opt.min_grid_size,
});

const config = opt.toLaunchConfig(num_elements);
try kernel.launch(config, params);
```

### Kernel Attributes

```zig
const regs = try kernel.getNumRegs();
const smem = try kernel.getSharedMemorySize();
const max_threads = try kernel.getMaxThreadsPerBlock();

std.debug.print("Kernel uses {} regs, {} bytes smem, max {} threads\n", .{
    regs, smem, max_threads,
});
```

### Profiling

```zig
// CPU-based profiling
var timer = cuda.ProfileTimer.start("vector_add");

timer.markH2DStart();
try mem.copyHostToDevice(buf, data);
timer.markH2DEnd(data.len);

timer.markKernelStart();
try kernel.launchSync(config, params);
timer.markKernelEnd();

timer.markD2HStart();
try mem.copyDeviceToHost(result, buf);
timer.markD2HEnd(result.len);

const profile = timer.finish();
const report = try profile.format(allocator);
defer allocator.free(report);
std.debug.print("{s}\n", .{report});
```

```zig
// GPU event-based profiling (more accurate)
var profiler = try cuda.EventProfiler.init(driver, allocator);
defer profiler.deinit();

try profiler.beginRegion("kernel", stream.handle);
try kernel.launch(config, params);
try profiler.endRegion("kernel", stream.handle);

try stream.synchronize();

const kernel_ms = try profiler.getRegionElapsedMs("kernel");
std.debug.print("Kernel: {d:.3} ms\n", .{kernel_ms});
```

---

## Error Handling

### Basic Pattern

```zig
const ctx = cuda.Context.init(allocator, .{}) catch |err| {
    std.debug.print("CUDA init failed: {}\n", .{err});
    return err;
};
defer ctx.deinit();
```

### Recovery Pattern

```zig
const buf = mem.allocDevice(large_size) catch |err| switch (err) {
    error.OutOfMemory => {
        // Try to free cached memory
        mem.clearPool();
        // Retry
        return mem.allocDevice(large_size);
    },
    else => return err,
};
```

### Graceful Degradation

```zig
fn compute(data: []f32) !void {
    if (cuda.isAvailable()) {
        try computeGpu(data);
    } else {
        computeCpu(data);
    }
}
```

---

## Integration Examples

### Image Processing Pipeline

```zig
fn processImage(image: Image) !Image {
    var ctx = try cuda.Context.init(allocator, .{});
    defer ctx.deinit();

    // Upload
    const d_input = try ctx.memory.allocDevice(image.size());
    const d_output = try ctx.memory.allocDevice(image.size());
    defer ctx.memory.freeDevice(d_input);
    defer ctx.memory.freeDevice(d_output);

    try ctx.memory.copyHostToDevice(d_input, image.data);

    // Process
    var args = cuda.TypedKernelArgs(struct {
        input: cuda.CUdeviceptr,
        output: cuda.CUdeviceptr,
        width: u32,
        height: u32,
    }).init(.{
        .input = d_input.ptr,
        .output = d_output.ptr,
        .width = image.width,
        .height = image.height,
    });

    const config = cuda.LaunchConfig.for2D(image.width, image.height, 16, 16);
    try kernel.launchSync(config, args.asParams());

    // Download
    var result = try Image.init(allocator, image.width, image.height);
    try ctx.memory.copyDeviceToHost(result.data, d_output);

    return result;
}
```

### Neural Network Inference

```zig
fn infer(model: *Model, input: []const f32) ![]f32 {
    var ctx = try cuda.Context.init(allocator, .{});
    defer ctx.deinit();

    // Allocate layers
    var buffers = std.ArrayList(cuda.Buffer).init(allocator);
    defer {
        for (buffers.items) |buf| ctx.memory.freeDevice(buf);
        buffers.deinit();
    }

    // Upload input
    const d_input = try ctx.memory.allocDevice(input.len * @sizeOf(f32));
    try buffers.append(d_input);
    try ctx.memory.copyHostToDevice(d_input, std.mem.sliceAsBytes(input));

    // Execute layers
    var current = d_input;
    for (model.layers) |layer| {
        const d_output = try ctx.memory.allocDevice(layer.output_size * @sizeOf(f32));
        try buffers.append(d_output);

        try layer.kernel.launchSync(
            cuda.LaunchConfig.for1D(@intCast(layer.output_size), 256),
            cuda.kernelParams(.{ &current.ptr, &d_output.ptr, &layer.weights.ptr }),
        );

        current = d_output;
    }

    // Download output
    const output = try allocator.alloc(f32, model.output_size);
    try ctx.memory.copyDeviceToHost(std.mem.sliceAsBytes(output), current);

    return output;
}
```

### Batch Processing with Multiple Streams

```zig
fn processBatches(batches: []const Batch) !void {
    var ctx = try cuda.Context.init(allocator, .{});
    defer ctx.deinit();

    const num_streams = @min(batches.len, 4);
    var streams: [4]cuda.Stream = undefined;
    for (0..num_streams) |i| {
        streams[i] = try cuda.Stream.create(driver);
    }
    defer for (0..num_streams) |i| streams[i].destroy();

    // Process batches across streams
    for (batches, 0..) |batch, i| {
        const stream = streams[i % num_streams];

        // Async upload
        try ctx.memory.copyHostToDeviceAsync(
            batch.device_buf,
            batch.host_data,
            stream.handle,
        );

        // Async kernel
        try kernel.launch(
            config.withStream(stream.handle),
            batch.params,
        );

        // Async download
        try ctx.memory.copyDeviceToHostAsync(
            batch.result,
            batch.device_buf,
            stream.handle,
        );
    }

    // Wait for all
    for (0..num_streams) |i| {
        try streams[i].synchronize();
    }
}
```

---

## Next Steps

- See [API Reference](./API.md) for complete API documentation
- See [Architecture Decision Records](./adr/) for design rationale
- See [Examples](../examples/) for runnable code samples
