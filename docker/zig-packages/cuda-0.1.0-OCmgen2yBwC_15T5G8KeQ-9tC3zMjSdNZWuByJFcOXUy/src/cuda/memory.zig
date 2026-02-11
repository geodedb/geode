// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! CUDA Memory Management
//!
//! This module provides memory allocation and transfer primitives for CUDA devices.
//! It supports device buffers, pinned host memory, and unified memory with automatic
//! pooling for reduced allocation overhead.
//!
//! ## Memory Types
//! - **Device**: GPU-only memory, fastest for compute
//! - **Pinned**: Page-locked host memory, enables async transfers
//! - **Unified**: Automatically migrated between host/device (requires CC 3.0+)
//!
//! ## Usage
//! ```zig
//! var mem = try Memory.init(&driver, allocator);
//! defer mem.deinit();
//!
//! const buf = try mem.allocDevice(1024 * 1024); // 1MB
//! defer mem.freeDevice(buf);
//!
//! try mem.copyHostToDevice(buf, host_data);
//! try mem.copyDeviceToHost(result_data, buf);
//! ```

const std = @import("std");
const driver = @import("driver.zig");
const types = @import("types.zig");

// Re-exports
pub const DeviceBuffer = types.DeviceBuffer;
pub const CudaError = types.CudaError;
pub const CUdeviceptr = types.CUdeviceptr;

// ============================================================================
// Memory Kind
// ============================================================================

/// Type of memory allocation
pub const MemoryKind = enum {
    /// Device-only memory (fastest)
    device,
    /// Page-locked host memory (enables async transfers)
    pinned,
    /// Unified memory (auto-migrated)
    unified,
};

// ============================================================================
// Buffer
// ============================================================================

/// Unified memory buffer (accessible from both host and device)
pub const UnifiedBuffer = struct {
    /// Device pointer (also accessible from host via casting)
    ptr: CUdeviceptr,
    /// Size in bytes
    size: usize,
    /// Driver reference
    drv: *const driver.CudaDriver,

    /// Get as host pointer for CPU access
    pub fn asHostPtr(self: UnifiedBuffer, comptime T: type) [*]T {
        return @ptrFromInt(self.ptr);
    }

    /// Get as slice for CPU access
    pub fn asHostSlice(self: UnifiedBuffer, comptime T: type) []T {
        const ptr: [*]T = @ptrFromInt(self.ptr);
        return ptr[0 .. self.size / @sizeOf(T)];
    }

    /// Prefetch data to specified device (async)
    /// Use types.CU_DEVICE_CPU to prefetch to host
    pub fn prefetchToDevice(self: *const UnifiedBuffer, device: types.CUdevice, stream: driver.CUstream) !void {
        const result = self.drv.memPrefetchAsync(self.ptr, self.size, device, stream);
        if (result != types.CUDA_SUCCESS) {
            return CudaError.GpuError;
        }
    }

    /// Prefetch data to host (async)
    pub fn prefetchToHost(self: *const UnifiedBuffer, stream: driver.CUstream) !void {
        try self.prefetchToDevice(types.CU_DEVICE_CPU, stream);
    }

    /// Set memory access hint
    pub fn advise(self: *const UnifiedBuffer, advice: types.CUmem_advise, device: types.CUdevice) !void {
        const result = self.drv.memAdvise(self.ptr, self.size, @intFromEnum(advice), device);
        if (result != types.CUDA_SUCCESS) {
            return CudaError.GpuError;
        }
    }

    /// Check if buffer is valid
    pub fn isValid(self: UnifiedBuffer) bool {
        return self.ptr != 0 and self.size > 0;
    }
};

/// GPU memory buffer with metadata
pub const Buffer = struct {
    /// Device pointer
    ptr: CUdeviceptr,
    /// Size in bytes
    size: usize,
    /// Memory type
    kind: MemoryKind,
    /// Whether currently allocated
    allocated: bool,
    /// Alignment (typically 256 bytes for CUDA)
    alignment: usize = 256,

    /// Check if buffer is valid for use
    pub fn isValid(self: Buffer) bool {
        return self.ptr != 0 and self.size > 0 and self.allocated;
    }

    /// Get buffer as typed slice (unsafe - for kernel parameters)
    pub fn asPtr(self: Buffer, comptime T: type) [*]T {
        return @ptrFromInt(self.ptr);
    }
};

// ============================================================================
// Memory Manager
// ============================================================================

/// CUDA memory manager with pooling support
pub const Memory = struct {
    /// CUDA driver reference
    drv: *const driver.CudaDriver,
    /// Host allocator for internal structures
    allocator: std.mem.Allocator,
    /// Device buffer pool for reuse
    device_pool: std.ArrayList(Buffer),
    /// Pinned host buffer tracking
    pinned_buffers: std.ArrayList(PinnedBuffer),
    /// Statistics
    stats: MemoryStats,

    const PinnedBuffer = struct {
        host_ptr: [*]u8,
        size: usize,
        /// Whether this was allocated with true CUDA pinned memory
        is_cuda_pinned: bool,
    };

    /// Initialize memory manager
    pub fn init(drv: *const driver.CudaDriver, allocator: std.mem.Allocator) !Memory {
        if (!drv.available()) {
            return CudaError.DriverNotFound;
        }

        return Memory{
            .drv = drv,
            .allocator = allocator,
            .device_pool = .{},
            .pinned_buffers = .{},
            .stats = .{},
        };
    }

    /// Clean up all allocations
    pub fn deinit(self: *Memory) void {
        // Free all pooled device buffers
        for (self.device_pool.items) |buf| {
            if (buf.allocated and buf.ptr != 0) {
                _ = self.drv.memFree(buf.ptr);
            }
        }
        self.device_pool.deinit(self.allocator);

        // Free pinned host buffers
        for (self.pinned_buffers.items) |buf| {
            self.allocator.free(buf.host_ptr[0..buf.size]);
        }
        self.pinned_buffers.deinit(self.allocator);
    }

    // ========================================================================
    // Device Memory
    // ========================================================================

    /// Allocate device memory
    pub fn allocDevice(self: *Memory, size: usize) !Buffer {
        if (!self.drv.available()) return CudaError.DriverNotFound;
        if (size == 0) return CudaError.InvalidArgument;

        // Align size to 256 bytes
        const aligned_size = alignUp(size, 256);

        // Try to reuse from pool
        for (self.device_pool.items, 0..) |*buf, idx| {
            if (!buf.allocated and buf.size >= aligned_size) {
                self.device_pool.items[idx].allocated = true;
                self.stats.pool_hits += 1;
                return self.device_pool.items[idx];
            }
        }

        // Allocate new buffer
        var dptr: CUdeviceptr = 0;
        const result = self.drv.memAlloc(&dptr, aligned_size);
        if (result != types.CUDA_SUCCESS) {
            return CudaError.OutOfMemory;
        }

        const buf = Buffer{
            .ptr = dptr,
            .size = aligned_size,
            .kind = .device,
            .allocated = true,
        };

        try self.device_pool.append(self.allocator, buf);
        self.stats.device_allocs += 1;
        self.stats.device_bytes_allocated += aligned_size;

        return buf;
    }

    /// Free device memory (returns to pool)
    pub fn freeDevice(self: *Memory, buf: Buffer) void {
        for (self.device_pool.items, 0..) |pool_buf, idx| {
            if (pool_buf.ptr == buf.ptr) {
                self.device_pool.items[idx].allocated = false;
                return;
            }
        }
    }

    /// Actually free device memory (remove from pool)
    pub fn freeDeviceImmediate(self: *Memory, buf: Buffer) void {
        for (self.device_pool.items, 0..) |pool_buf, idx| {
            if (pool_buf.ptr == buf.ptr) {
                _ = self.drv.memFree(buf.ptr);
                _ = self.device_pool.orderedRemove(idx);
                self.stats.device_bytes_allocated -= buf.size;
                return;
            }
        }
    }

    // ========================================================================
    // Memory Transfers
    // ========================================================================

    /// Copy from host to device (synchronous)
    pub fn copyHostToDevice(self: *Memory, dst: Buffer, src: []const u8) !void {
        if (!self.drv.available()) return CudaError.DriverNotFound;
        if (!dst.isValid()) return CudaError.InvalidArgument;
        if (src.len > dst.size) return CudaError.InvalidArgument;

        const result = self.drv.memcpyHtoD(dst.ptr, src.ptr, src.len);
        if (result != types.CUDA_SUCCESS) {
            return CudaError.CopyFailed;
        }

        self.stats.h2d_transfers += 1;
        self.stats.h2d_bytes += src.len;
    }

    /// Copy from device to host (synchronous)
    pub fn copyDeviceToHost(self: *Memory, dst: []u8, src: Buffer) !void {
        if (!self.drv.available()) return CudaError.DriverNotFound;
        if (!src.isValid()) return CudaError.InvalidArgument;
        if (dst.len > src.size) return CudaError.InvalidArgument;

        const result = self.drv.memcpyDtoH(dst.ptr, src.ptr, dst.len);
        if (result != types.CUDA_SUCCESS) {
            return CudaError.CopyFailed;
        }

        self.stats.d2h_transfers += 1;
        self.stats.d2h_bytes += dst.len;
    }

    /// Copy from device to device
    pub fn copyDeviceToDevice(self: *Memory, dst: Buffer, src: Buffer, size: usize) !void {
        if (!self.drv.available()) return CudaError.DriverNotFound;
        if (!dst.isValid() or !src.isValid()) return CudaError.InvalidArgument;
        if (size > dst.size or size > src.size) return CudaError.InvalidArgument;

        const result = self.drv.memcpyDtoD(dst.ptr, src.ptr, size);
        if (result != types.CUDA_SUCCESS) {
            return CudaError.CopyFailed;
        }

        self.stats.d2d_transfers += 1;
        self.stats.d2d_bytes += size;
    }

    /// Set device memory to a byte value
    pub fn memset(self: *Memory, dst: Buffer, value: u8, count: usize) !void {
        if (!self.drv.available()) return CudaError.DriverNotFound;
        if (!dst.isValid()) return CudaError.InvalidArgument;
        if (count > dst.size) return CudaError.InvalidArgument;

        const result = self.drv.memsetD8(dst.ptr, value, count);
        if (result != types.CUDA_SUCCESS) {
            return CudaError.GpuError;
        }
    }

    /// Set device memory to zero
    pub fn zero(self: *Memory, dst: Buffer) !void {
        try self.memset(dst, 0, dst.size);
    }

    // ========================================================================
    // Async Memory Transfers (if stream support available)
    // ========================================================================

    /// Copy from host to device (asynchronous)
    pub fn copyHostToDeviceAsync(
        self: *Memory,
        dst: Buffer,
        src: []const u8,
        stream: driver.CUstream,
    ) !void {
        if (!self.drv.available()) return CudaError.DriverNotFound;
        if (!self.drv.supportsAsyncMemory()) return CudaError.NotSupported;
        if (!dst.isValid()) return CudaError.InvalidArgument;
        if (src.len > dst.size) return CudaError.InvalidArgument;

        const result = self.drv.memcpyHtoDAsync(dst.ptr, src.ptr, src.len, stream);
        if (result != types.CUDA_SUCCESS) {
            return CudaError.CopyFailed;
        }

        self.stats.h2d_transfers += 1;
        self.stats.h2d_bytes += src.len;
    }

    /// Copy from device to host (asynchronous)
    pub fn copyDeviceToHostAsync(
        self: *Memory,
        dst: []u8,
        src: Buffer,
        stream: driver.CUstream,
    ) !void {
        if (!self.drv.available()) return CudaError.DriverNotFound;
        if (!self.drv.supportsAsyncMemory()) return CudaError.NotSupported;
        if (!src.isValid()) return CudaError.InvalidArgument;
        if (dst.len > src.size) return CudaError.InvalidArgument;

        const result = self.drv.memcpyDtoHAsync(dst.ptr, src.ptr, dst.len, stream);
        if (result != types.CUDA_SUCCESS) {
            return CudaError.CopyFailed;
        }

        self.stats.d2h_transfers += 1;
        self.stats.d2h_bytes += dst.len;
    }

    // ========================================================================
    // Pinned Host Memory
    // ========================================================================

    /// Allocate pinned (page-locked) host memory
    /// Uses CUDA cuMemAllocHost for true pinned memory when available,
    /// falls back to regular allocation otherwise.
    /// Pinned memory enables faster async DMA transfers to/from GPU (2-3x faster).
    pub fn allocPinned(self: *Memory, size: usize) ![]u8 {
        // Try to use true CUDA pinned memory allocation
        if (self.drv.hasPinnedMemory()) {
            var ptr: ?*anyopaque = null;
            const result = self.drv.memAllocHost(&ptr, size);
            if (result == types.CUDA_SUCCESS and ptr != null) {
                const host_ptr: [*]u8 = @ptrCast(ptr);
                try self.pinned_buffers.append(self.allocator, .{
                    .host_ptr = host_ptr,
                    .size = size,
                    .is_cuda_pinned = true,
                });
                self.stats.pinned_bytes_allocated += size;
                return host_ptr[0..size];
            }
            // Fall through to fallback if CUDA allocation failed
        }

        // Fallback: Use regular host allocation
        // This won't have the DMA transfer benefits but still works
        const buf = try self.allocator.alloc(u8, size);
        try self.pinned_buffers.append(self.allocator, .{
            .host_ptr = buf.ptr,
            .size = size,
            .is_cuda_pinned = false,
        });
        self.stats.pinned_bytes_allocated += size;
        return buf;
    }

    /// Free pinned host memory
    /// Automatically uses the correct deallocation method based on how memory was allocated
    pub fn freePinned(self: *Memory, ptr: []u8) void {
        for (self.pinned_buffers.items, 0..) |buf, idx| {
            if (buf.host_ptr == ptr.ptr) {
                if (buf.is_cuda_pinned) {
                    // Free using CUDA driver
                    _ = self.drv.memFreeHost(ptr.ptr);
                } else {
                    // Free using regular allocator
                    self.allocator.free(ptr);
                }
                _ = self.pinned_buffers.orderedRemove(idx);
                self.stats.pinned_bytes_allocated -= ptr.len;
                return;
            }
        }
        // Not found in tracked list, try regular allocator
        self.allocator.free(ptr);
    }

    /// Check if true CUDA pinned memory is available
    pub fn hasTruePinnedMemory(self: *const Memory) bool {
        return self.drv.hasPinnedMemory();
    }

    // ========================================================================
    // Unified Memory
    // ========================================================================

    /// Allocate unified memory accessible from both host and device.
    /// Unified memory automatically migrates between host and device as needed.
    /// Requires compute capability 3.0+ and CUDA 6.0+
    pub fn allocUnified(self: *Memory, size: usize) !UnifiedBuffer {
        if (!self.drv.available()) return CudaError.DriverNotFound;
        if (!self.drv.hasUnifiedMemory()) return CudaError.NotSupported;
        if (size == 0) return CudaError.InvalidArgument;

        var dptr: CUdeviceptr = 0;
        const result = self.drv.memAllocManaged(
            &dptr,
            size,
            @intFromEnum(types.CUmem_attach_flags.global),
        );
        if (result != types.CUDA_SUCCESS) {
            return CudaError.OutOfMemory;
        }

        self.stats.unified_bytes_allocated += size;
        return UnifiedBuffer{
            .ptr = dptr,
            .size = size,
            .drv = self.drv,
        };
    }

    /// Free unified memory
    pub fn freeUnified(self: *Memory, buf: *UnifiedBuffer) void {
        if (buf.ptr != 0) {
            _ = self.drv.memFree(buf.ptr);
            self.stats.unified_bytes_allocated -= buf.size;
            buf.ptr = 0;
            buf.size = 0;
        }
    }

    /// Check if unified memory is supported
    pub fn hasUnifiedMemory(self: *const Memory) bool {
        return self.drv.hasUnifiedMemory();
    }

    // ========================================================================
    // Memory Info
    // ========================================================================

    /// Get current free and total device memory
    pub fn getMemoryInfo(self: *Memory) !struct { free: usize, total: usize } {
        if (!self.drv.available()) return CudaError.DriverNotFound;

        var free: usize = 0;
        var total: usize = 0;
        const result = self.drv.memGetInfo(&free, &total);
        if (result != types.CUDA_SUCCESS) {
            return CudaError.GpuError;
        }

        return .{ .free = free, .total = total };
    }

    /// Get memory statistics
    pub fn getStats(self: *const Memory) MemoryStats {
        return self.stats;
    }

    /// Clear buffer pool (free all unused buffers)
    pub fn clearPool(self: *Memory) void {
        var i: usize = 0;
        while (i < self.device_pool.items.len) {
            const buf = self.device_pool.items[i];
            if (!buf.allocated) {
                _ = self.drv.memFree(buf.ptr);
                self.stats.device_bytes_allocated -= buf.size;
                _ = self.device_pool.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Synchronize all memory operations
    pub fn synchronize(self: *Memory) !void {
        if (!self.drv.available()) return CudaError.DriverNotFound;
        if (self.drv.cuCtxSynchronize() != types.CUDA_SUCCESS) {
            return CudaError.SyncFailed;
        }
    }

    // ========================================================================
    // Pool Fragmentation Handling (#13)
    // ========================================================================

    /// Get detailed pool statistics
    pub fn getPoolStats(self: *const Memory) PoolStats {
        var stats = PoolStats{};
        var size_set = std.AutoHashMap(usize, void).init(self.allocator);
        defer size_set.deinit();

        var largest_free: usize = 0;

        for (self.device_pool.items) |buf| {
            stats.total_buffers += 1;
            stats.total_bytes += buf.size;

            if (buf.allocated) {
                stats.allocated_buffers += 1;
                stats.allocated_bytes += buf.size;
            } else {
                stats.free_buffers += 1;
                stats.free_bytes += buf.size;
                if (buf.size > largest_free) {
                    largest_free = buf.size;
                }
            }

            size_set.put(buf.size, {}) catch {};
        }

        stats.unique_sizes = size_set.count();
        stats.largest_free_block = largest_free;

        // Calculate fragmentation ratio
        // Higher unique sizes relative to total buffers = more fragmentation
        if (stats.total_buffers > 0 and stats.free_buffers > 0) {
            const size_diversity: f32 = @as(f32, @floatFromInt(stats.unique_sizes)) /
                @as(f32, @floatFromInt(stats.total_buffers));
            const free_ratio: f32 = @as(f32, @floatFromInt(stats.free_buffers)) /
                @as(f32, @floatFromInt(stats.total_buffers));
            stats.fragmentation_ratio = size_diversity * free_ratio;
        }

        return stats;
    }

    /// Defragment pool by freeing small unused buffers
    /// threshold_bytes: Free unused buffers smaller than this size
    pub fn defragment(self: *Memory, threshold_bytes: usize) usize {
        var freed_count: usize = 0;
        var i: usize = 0;

        while (i < self.device_pool.items.len) {
            const buf = self.device_pool.items[i];
            if (!buf.allocated and buf.size < threshold_bytes) {
                _ = self.drv.memFree(buf.ptr);
                self.stats.device_bytes_allocated -= buf.size;
                _ = self.device_pool.orderedRemove(i);
                freed_count += 1;
            } else {
                i += 1;
            }
        }

        return freed_count;
    }

    /// Compact pool by removing all unused buffers except the largest N
    pub fn compact(self: *Memory, keep_count: usize) usize {
        // Sort free buffers by size (largest first)
        var free_indices = std.ArrayList(usize).init(self.allocator);
        defer free_indices.deinit();

        for (self.device_pool.items, 0..) |buf, idx| {
            if (!buf.allocated) {
                free_indices.append(idx) catch continue;
            }
        }

        if (free_indices.items.len <= keep_count) return 0;

        // Sort by size descending
        std.mem.sort(usize, free_indices.items, self.device_pool.items, struct {
            fn lessThan(pool: []Buffer, a: usize, b: usize) bool {
                return pool[a].size > pool[b].size; // Descending
            }
        }.lessThan);

        // Free all but the largest keep_count
        var freed_count: usize = 0;
        var to_remove = std.ArrayList(usize).init(self.allocator);
        defer to_remove.deinit();

        for (free_indices.items[keep_count..]) |idx| {
            to_remove.append(idx) catch continue;
        }

        // Sort removal indices in descending order to avoid index shifting issues
        std.mem.sort(usize, to_remove.items, {}, std.sort.desc(usize));

        for (to_remove.items) |idx| {
            const buf = self.device_pool.items[idx];
            _ = self.drv.memFree(buf.ptr);
            self.stats.device_bytes_allocated -= buf.size;
            _ = self.device_pool.orderedRemove(idx);
            freed_count += 1;
        }

        return freed_count;
    }

    /// Create a transfer batch for this memory manager
    pub fn createTransferBatch(self: *Memory, stream: driver.CUstream) TransferBatch {
        return TransferBatch.init(self.drv, self.allocator, stream);
    }
};

// ============================================================================
// Async Transfer Batching (#11)
// ============================================================================

/// Transfer operation type
pub const TransferOp = enum {
    host_to_device,
    device_to_host,
    device_to_device,
};

/// Single transfer request in a batch
pub const TransferRequest = struct {
    op: TransferOp,
    dst_ptr: CUdeviceptr,
    src_ptr: CUdeviceptr,
    host_ptr: ?[*]u8,
    size: usize,
};

/// Batch multiple async transfers for efficient execution
/// Reduces kernel launch overhead by queuing transfers and executing together
pub const TransferBatch = struct {
    /// Pending transfers
    requests: std.ArrayList(TransferRequest),
    /// Stream to execute on
    stream: driver.CUstream,
    /// Driver reference
    drv: *const driver.CudaDriver,
    /// Allocator
    allocator: std.mem.Allocator,
    /// Total bytes queued
    total_bytes: usize = 0,
    /// Whether batch has been submitted
    submitted: bool = false,

    /// Create a new transfer batch
    pub fn init(drv: *const driver.CudaDriver, allocator: std.mem.Allocator, stream: driver.CUstream) TransferBatch {
        return TransferBatch{
            .requests = .{},
            .stream = stream,
            .drv = drv,
            .allocator = allocator,
        };
    }

    /// Clean up batch
    pub fn deinit(self: *TransferBatch) void {
        self.requests.deinit(self.allocator);
    }

    /// Add host-to-device transfer to batch
    pub fn addH2D(self: *TransferBatch, dst: Buffer, src: []const u8) !void {
        if (self.submitted) return CudaError.InvalidArgument;
        try self.requests.append(self.allocator, .{
            .op = .host_to_device,
            .dst_ptr = dst.ptr,
            .src_ptr = @intFromPtr(src.ptr),
            .host_ptr = @constCast(src.ptr),
            .size = src.len,
        });
        self.total_bytes += src.len;
    }

    /// Add device-to-host transfer to batch
    pub fn addD2H(self: *TransferBatch, dst: []u8, src: Buffer) !void {
        if (self.submitted) return CudaError.InvalidArgument;
        try self.requests.append(self.allocator, .{
            .op = .device_to_host,
            .dst_ptr = @intFromPtr(dst.ptr),
            .src_ptr = src.ptr,
            .host_ptr = dst.ptr,
            .size = dst.len,
        });
        self.total_bytes += dst.len;
    }

    /// Add device-to-device transfer to batch
    pub fn addD2D(self: *TransferBatch, dst: Buffer, src: Buffer, size: usize) !void {
        if (self.submitted) return CudaError.InvalidArgument;
        try self.requests.append(self.allocator, .{
            .op = .device_to_device,
            .dst_ptr = dst.ptr,
            .src_ptr = src.ptr,
            .host_ptr = null,
            .size = size,
        });
        self.total_bytes += size;
    }

    /// Submit all transfers asynchronously
    pub fn submit(self: *TransferBatch) !void {
        if (self.submitted) return CudaError.InvalidArgument;

        for (self.requests.items) |req| {
            const result = switch (req.op) {
                .host_to_device => self.drv.memcpyHtoDAsync(
                    req.dst_ptr,
                    req.host_ptr.?,
                    req.size,
                    self.stream,
                ),
                .device_to_host => self.drv.memcpyDtoHAsync(
                    req.host_ptr.?,
                    req.src_ptr,
                    req.size,
                    self.stream,
                ),
                .device_to_device => blk: {
                    // D2D async not directly available, use sync version
                    break :blk self.drv.memcpyDtoD(req.dst_ptr, req.src_ptr, req.size);
                },
            };
            if (result != types.CUDA_SUCCESS) {
                return CudaError.CopyFailed;
            }
        }
        self.submitted = true;
    }

    /// Wait for all transfers to complete
    pub fn synchronize(self: *TransferBatch) !void {
        if (!self.submitted) return CudaError.InvalidArgument;

        if (self.stream != null) {
            if (self.drv.streamSynchronize(self.stream) != types.CUDA_SUCCESS) {
                return CudaError.SyncFailed;
            }
        } else {
            if (self.drv.cuCtxSynchronize() != types.CUDA_SUCCESS) {
                return CudaError.SyncFailed;
            }
        }
    }

    /// Submit and wait for completion
    pub fn execute(self: *TransferBatch) !void {
        try self.submit();
        try self.synchronize();
    }

    /// Get number of pending transfers
    pub fn count(self: *const TransferBatch) usize {
        return self.requests.items.len;
    }

    /// Get total bytes to transfer
    pub fn getTotalBytes(self: *const TransferBatch) usize {
        return self.total_bytes;
    }

    /// Reset batch for reuse
    pub fn reset(self: *TransferBatch) void {
        self.requests.clearRetainingCapacity();
        self.total_bytes = 0;
        self.submitted = false;
    }
};

// ============================================================================
// Memory Pool Fragmentation Handling (#13)
// ============================================================================

/// Memory pool statistics for fragmentation analysis
pub const PoolStats = struct {
    /// Total buffers in pool
    total_buffers: usize = 0,
    /// Allocated (in-use) buffers
    allocated_buffers: usize = 0,
    /// Free (available) buffers
    free_buffers: usize = 0,
    /// Total bytes in pool
    total_bytes: usize = 0,
    /// Allocated bytes
    allocated_bytes: usize = 0,
    /// Free bytes
    free_bytes: usize = 0,
    /// Number of unique sizes
    unique_sizes: usize = 0,
    /// Fragmentation ratio (0.0 = no fragmentation, 1.0 = fully fragmented)
    fragmentation_ratio: f32 = 0.0,
    /// Largest free block
    largest_free_block: usize = 0,
};

// ============================================================================
// Memory Statistics
// ============================================================================

/// Memory usage statistics
pub const MemoryStats = struct {
    /// Number of device allocations
    device_allocs: usize = 0,
    /// Total device bytes allocated
    device_bytes_allocated: usize = 0,
    /// Pool reuse hits
    pool_hits: usize = 0,
    /// Pinned bytes allocated
    pinned_bytes_allocated: usize = 0,
    /// Unified memory bytes allocated
    unified_bytes_allocated: usize = 0,
    /// Host to device transfers
    h2d_transfers: usize = 0,
    /// Host to device bytes
    h2d_bytes: usize = 0,
    /// Device to host transfers
    d2h_transfers: usize = 0,
    /// Device to host bytes
    d2h_bytes: usize = 0,
    /// Device to device transfers
    d2d_transfers: usize = 0,
    /// Device to device bytes
    d2d_bytes: usize = 0,

    /// Format stats as string
    pub fn format(self: MemoryStats, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\Memory Statistics:
            \\  Device Allocs: {}
            \\  Device Bytes: {} ({d:.2} MB)
            \\  Pool Hits: {}
            \\  Pinned Bytes: {} ({d:.2} MB)
            \\  Unified Bytes: {} ({d:.2} MB)
            \\  H2D Transfers: {} ({d:.2} MB)
            \\  D2H Transfers: {} ({d:.2} MB)
            \\  D2D Transfers: {} ({d:.2} MB)
        , .{
            self.device_allocs,
            self.device_bytes_allocated,
            @as(f64, @floatFromInt(self.device_bytes_allocated)) / (1024 * 1024),
            self.pool_hits,
            self.pinned_bytes_allocated,
            @as(f64, @floatFromInt(self.pinned_bytes_allocated)) / (1024 * 1024),
            self.unified_bytes_allocated,
            @as(f64, @floatFromInt(self.unified_bytes_allocated)) / (1024 * 1024),
            self.h2d_transfers,
            @as(f64, @floatFromInt(self.h2d_bytes)) / (1024 * 1024),
            self.d2h_transfers,
            @as(f64, @floatFromInt(self.d2h_bytes)) / (1024 * 1024),
            self.d2d_transfers,
            @as(f64, @floatFromInt(self.d2d_bytes)) / (1024 * 1024),
        });
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

// ============================================================================
// Tests
// ============================================================================

test "Buffer validation" {
    const valid_buf = Buffer{ .ptr = 0x1000, .size = 1024, .kind = .device, .allocated = true };
    const invalid_buf = Buffer{ .ptr = 0, .size = 0, .kind = .device, .allocated = false };

    try std.testing.expect(valid_buf.isValid());
    try std.testing.expect(!invalid_buf.isValid());
}

test "alignUp" {
    try std.testing.expectEqual(@as(usize, 256), alignUp(100, 256));
    try std.testing.expectEqual(@as(usize, 256), alignUp(256, 256));
    try std.testing.expectEqual(@as(usize, 512), alignUp(257, 256));
    try std.testing.expectEqual(@as(usize, 0), alignUp(0, 256));
}

test "MemoryStats format" {
    const stats = MemoryStats{
        .device_allocs = 10,
        .device_bytes_allocated = 1024 * 1024,
        .pool_hits = 5,
        .h2d_transfers = 20,
        .h2d_bytes = 2 * 1024 * 1024,
    };

    const formatted = try stats.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Device Allocs: 10") != null);
}

test "Buffer isValid edge cases" {
    // Zero pointer is invalid
    const buf1 = Buffer{ .ptr = 0, .size = 1024, .kind = .device, .allocated = true };
    try std.testing.expect(!buf1.isValid());

    // Zero size is invalid
    const buf2 = Buffer{ .ptr = 0x1000, .size = 0, .kind = .device, .allocated = true };
    try std.testing.expect(!buf2.isValid());

    // Not allocated is invalid
    const buf3 = Buffer{ .ptr = 0x1000, .size = 1024, .kind = .device, .allocated = false };
    try std.testing.expect(!buf3.isValid());

    // All conditions must be met
    const buf4 = Buffer{ .ptr = 0x1000, .size = 1024, .kind = .device, .allocated = true };
    try std.testing.expect(buf4.isValid());
}

test "Buffer asPtr type safety" {
    const buf = Buffer{ .ptr = 0x10000, .size = 1024, .kind = .device, .allocated = true };

    // Should be able to interpret as different pointer types
    const ptr_u8: [*]u8 = buf.asPtr(u8);
    const ptr_f32: [*]f32 = buf.asPtr(f32);
    const ptr_u64: [*]u64 = buf.asPtr(u64);

    // All should point to the same address
    try std.testing.expectEqual(@as(usize, 0x10000), @intFromPtr(ptr_u8));
    try std.testing.expectEqual(@as(usize, 0x10000), @intFromPtr(ptr_f32));
    try std.testing.expectEqual(@as(usize, 0x10000), @intFromPtr(ptr_u64));
}

test "alignUp edge cases" {
    // Power of 2 alignments
    try std.testing.expectEqual(@as(usize, 8), alignUp(1, 8));
    try std.testing.expectEqual(@as(usize, 8), alignUp(8, 8));
    try std.testing.expectEqual(@as(usize, 16), alignUp(9, 8));

    // Large values
    try std.testing.expectEqual(@as(usize, 4096), alignUp(4000, 4096));
    try std.testing.expectEqual(@as(usize, 4096), alignUp(4096, 4096));
    try std.testing.expectEqual(@as(usize, 8192), alignUp(4097, 4096));

    // Very large values (check for overflow)
    const large: usize = 1024 * 1024 * 1024; // 1GB
    try std.testing.expectEqual(large, alignUp(large, 256));
}

test "MemoryStats default values" {
    const stats = MemoryStats{};

    try std.testing.expectEqual(@as(usize, 0), stats.device_allocs);
    try std.testing.expectEqual(@as(usize, 0), stats.device_bytes_allocated);
    try std.testing.expectEqual(@as(usize, 0), stats.pool_hits);
    try std.testing.expectEqual(@as(usize, 0), stats.pinned_bytes_allocated);
    try std.testing.expectEqual(@as(usize, 0), stats.h2d_transfers);
    try std.testing.expectEqual(@as(usize, 0), stats.h2d_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.d2h_transfers);
    try std.testing.expectEqual(@as(usize, 0), stats.d2h_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.d2d_transfers);
    try std.testing.expectEqual(@as(usize, 0), stats.d2d_bytes);
}

test "MemoryStats format with zeros" {
    const stats = MemoryStats{};

    const formatted = try stats.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Device Allocs: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "0.00 MB") != null);
}

test "MemoryStats format with large values" {
    const stats = MemoryStats{
        .device_allocs = 1000,
        .device_bytes_allocated = 16 * 1024 * 1024 * 1024, // 16 GB
        .pool_hits = 500,
        .h2d_transfers = 10000,
        .h2d_bytes = 100 * 1024 * 1024 * 1024, // 100 GB
        .d2h_transfers = 5000,
        .d2h_bytes = 50 * 1024 * 1024 * 1024, // 50 GB
    };

    const formatted = try stats.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Device Allocs: 1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Pool Hits: 500") != null);
}

test "MemoryKind enum values" {
    // Verify enum variants exist and are distinct
    try std.testing.expect(MemoryKind.device != MemoryKind.pinned);
    try std.testing.expect(MemoryKind.pinned != MemoryKind.unified);
    try std.testing.expect(MemoryKind.device != MemoryKind.unified);
}

test "Buffer alignment default" {
    const buf = Buffer{ .ptr = 0x1000, .size = 1024, .kind = .device, .allocated = true };
    try std.testing.expectEqual(@as(usize, 256), buf.alignment);
}
