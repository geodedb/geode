// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! CUDA Stream and Event Management
//!
//! Streams enable concurrent kernel execution and async memory transfers.
//! Events provide precise GPU timing and synchronization points.
//!
//! ## Usage
//! ```zig
//! var stream = try Stream.create(&driver);
//! defer stream.destroy();
//!
//! // Launch kernels on stream...
//! try stream.synchronize();
//!
//! var timer = try EventTimer.create(&driver);
//! defer timer.destroy();
//! timer.start();
//! // ... GPU work ...
//! timer.stop();
//! const elapsed_ms = try timer.elapsedMs();
//! ```

const std = @import("std");
const driver = @import("driver.zig");
const types = @import("types.zig");

// Re-exports
pub const CUstream = types.CUstream;
pub const CUevent = types.CUevent;
pub const CudaError = types.CudaError;
pub const CUDA_SUCCESS = types.CUDA_SUCCESS;

// ============================================================================
// Stream
// ============================================================================

/// Stream priority levels
pub const StreamPriority = struct {
    /// Lowest priority (highest number, default)
    least: i32,
    /// Highest priority (lowest number)
    greatest: i32,

    /// Get default priority (typically 0)
    pub fn default(_: StreamPriority) i32 {
        return 0;
    }

    /// Get a priority value at the given percentage between least and greatest
    /// 0.0 = least priority, 1.0 = greatest priority
    pub fn atPercent(self: StreamPriority, pct: f32) i32 {
        const range: f32 = @floatFromInt(self.least - self.greatest);
        const offset: i32 = @intFromFloat(range * (1.0 - pct));
        return self.greatest + offset;
    }
};

/// CUDA Stream for async operations
pub const Stream = struct {
    /// Underlying CUDA stream handle
    handle: CUstream,
    /// Driver reference
    drv: *const driver.CudaDriver,
    /// Whether this is the default stream
    is_default: bool,
    /// Stream priority (if created with priority)
    priority: i32 = 0,

    /// Create a new CUDA stream
    pub fn create(drv: *const driver.CudaDriver) !Stream {
        if (!drv.available()) return CudaError.DriverNotFound;
        if (!drv.supportsStreams()) return CudaError.NotSupported;

        var handle: CUstream = null;
        const result = drv.streamCreate(&handle, 0);
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }

        return Stream{
            .handle = handle,
            .drv = drv,
            .is_default = false,
            .priority = 0,
        };
    }

    /// Create a stream with specified priority (lower number = higher priority)
    pub fn createWithPriority(drv: *const driver.CudaDriver, priority: i32) !Stream {
        if (!drv.available()) return CudaError.DriverNotFound;
        if (!drv.supportsStreamPriority()) return CudaError.NotSupported;

        var handle: CUstream = null;
        const result = drv.streamCreateWithPriority(&handle, 0, priority);
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }

        return Stream{
            .handle = handle,
            .drv = drv,
            .is_default = false,
            .priority = priority,
        };
    }

    /// Create a high-priority stream
    pub fn createHighPriority(drv: *const driver.CudaDriver) !Stream {
        const range = try getPriorityRange(drv);
        return createWithPriority(drv, range.greatest);
    }

    /// Create a low-priority stream
    pub fn createLowPriority(drv: *const driver.CudaDriver) !Stream {
        const range = try getPriorityRange(drv);
        return createWithPriority(drv, range.least);
    }

    /// Create a non-blocking stream
    pub fn createNonBlocking(drv: *const driver.CudaDriver) !Stream {
        if (!drv.available()) return CudaError.DriverNotFound;
        if (!drv.supportsStreams()) return CudaError.NotSupported;

        var handle: CUstream = null;
        const result = drv.streamCreate(&handle, @intFromEnum(types.CUstream_flags.non_blocking));
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }

        return Stream{
            .handle = handle,
            .drv = drv,
            .is_default = false,
            .priority = 0,
        };
    }

    /// Create a non-blocking stream with priority
    pub fn createNonBlockingWithPriority(drv: *const driver.CudaDriver, priority: i32) !Stream {
        if (!drv.available()) return CudaError.DriverNotFound;
        if (!drv.supportsStreamPriority()) return CudaError.NotSupported;

        var handle: CUstream = null;
        const result = drv.streamCreateWithPriority(
            &handle,
            @intFromEnum(types.CUstream_flags.non_blocking),
            priority,
        );
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }

        return Stream{
            .handle = handle,
            .drv = drv,
            .is_default = false,
            .priority = priority,
        };
    }

    /// Get the default (null) stream
    pub fn getDefault(drv: *const driver.CudaDriver) Stream {
        return Stream{
            .handle = null,
            .drv = drv,
            .is_default = true,
            .priority = 0,
        };
    }

    /// Get current priority of this stream
    pub fn getPriority(self: *const Stream) !i32 {
        if (self.handle == null) return 0; // Default stream has priority 0

        var priority: i32 = 0;
        const result = self.drv.streamGetPriority(self.handle, &priority);
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }
        return priority;
    }

    /// Destroy the stream
    pub fn destroy(self: *Stream) void {
        if (!self.is_default and self.handle != null) {
            _ = self.drv.streamDestroy(self.handle);
            self.handle = null;
        }
    }

    /// Synchronize the stream (wait for all operations to complete)
    pub fn synchronize(self: *const Stream) !void {
        if (self.handle == null and self.is_default) {
            // Default stream: use context sync
            if (self.drv.cuCtxSynchronize() != CUDA_SUCCESS) {
                return CudaError.SyncFailed;
            }
        } else if (self.handle != null) {
            if (self.drv.streamSynchronize(self.handle) != CUDA_SUCCESS) {
                return CudaError.SyncFailed;
            }
        } else {
            // Invalid state: handle is null but not marked as default stream
            return CudaError.InvalidArgument;
        }
    }

    /// Query if stream has completed all operations
    pub fn isComplete(self: *const Stream) bool {
        if (self.handle == null) return true;
        return self.drv.streamQuery(self.handle) == CUDA_SUCCESS;
    }

    /// Get raw handle (for passing to other CUDA functions)
    pub fn getHandle(self: *const Stream) CUstream {
        return self.handle;
    }
};

/// Get the range of stream priorities for the current context
pub fn getPriorityRange(drv: *const driver.CudaDriver) !StreamPriority {
    if (!drv.available()) return CudaError.DriverNotFound;
    if (!drv.supportsStreamPriority()) return CudaError.NotSupported;

    var least: i32 = 0;
    var greatest: i32 = 0;
    const result = drv.getStreamPriorityRange(&least, &greatest);
    if (result != CUDA_SUCCESS) {
        return CudaError.GpuError;
    }

    return StreamPriority{
        .least = least,
        .greatest = greatest,
    };
}

/// Check if stream priority is supported
pub fn supportsPriority(drv: *const driver.CudaDriver) bool {
    return drv.supportsStreamPriority();
}

// ============================================================================
// Event
// ============================================================================

/// CUDA Event for synchronization and timing
pub const Event = struct {
    /// Underlying CUDA event handle
    handle: ?CUevent,
    /// Driver reference
    drv: *const driver.CudaDriver,
    /// Whether timing is enabled
    timing_enabled: bool,

    /// Create a new CUDA event
    pub fn create(drv: *const driver.CudaDriver) !Event {
        if (!drv.available()) return CudaError.DriverNotFound;
        if (!drv.supportsEvents()) return CudaError.NotSupported;

        var handle: CUevent = undefined;
        const result = drv.eventCreate(&handle, 0);
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }

        return Event{
            .handle = handle,
            .drv = drv,
            .timing_enabled = true,
        };
    }

    /// Create event without timing (lower overhead)
    pub fn createNoTiming(drv: *const driver.CudaDriver) !Event {
        if (!drv.available()) return CudaError.DriverNotFound;
        if (!drv.supportsEvents()) return CudaError.NotSupported;

        var handle: CUevent = undefined;
        const result = drv.eventCreate(&handle, @intFromEnum(types.CUevent_flags.disable_timing));
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }

        return Event{
            .handle = handle,
            .drv = drv,
            .timing_enabled = false,
        };
    }

    /// Destroy the event
    pub fn destroy(self: *Event) void {
        if (self.handle) |h| {
            _ = self.drv.eventDestroy(h);
            self.handle = null;
        }
    }

    /// Record event on a stream
    pub fn record(self: *const Event, stream: *const Stream) !void {
        if (self.handle == null) return CudaError.InvalidArgument;
        const result = self.drv.eventRecord(self.handle.?, stream.getHandle());
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }
    }

    /// Record event on default stream
    pub fn recordDefault(self: *const Event) !void {
        if (self.handle == null) return CudaError.InvalidArgument;
        const result = self.drv.eventRecord(self.handle.?, null);
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }
    }

    /// Synchronize on event (wait for completion)
    pub fn synchronize(self: *const Event) !void {
        if (self.handle == null) return CudaError.InvalidArgument;
        const result = self.drv.eventSynchronize(self.handle.?);
        if (result != CUDA_SUCCESS) {
            return CudaError.SyncFailed;
        }
    }

    /// Query if event has completed
    pub fn isComplete(self: *const Event) bool {
        if (self.handle == null) return true;
        return self.drv.eventQuery(self.handle.?) == CUDA_SUCCESS;
    }

    /// Calculate elapsed time between two events (in milliseconds)
    pub fn elapsedMs(start: *const Event, end: *const Event) !f32 {
        if (start.handle == null or end.handle == null) {
            return CudaError.InvalidArgument;
        }
        if (!start.timing_enabled or !end.timing_enabled) {
            return CudaError.NotSupported;
        }

        var ms: f32 = 0;
        const result = start.drv.eventElapsedTime(&ms, start.handle.?, end.handle.?);
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }
        return ms;
    }
};

// ============================================================================
// Event Timer (convenience wrapper)
// ============================================================================

/// High-level timer using CUDA events
pub const EventTimer = struct {
    /// Start event
    start_event: Event,
    /// Stop event
    stop_event: Event,
    /// Whether timer is running
    running: bool,

    /// Create a new event timer
    pub fn create(drv: *const driver.CudaDriver) !EventTimer {
        var start_event = try Event.create(drv);
        errdefer start_event.destroy();

        var stop_event = try Event.create(drv);
        errdefer stop_event.destroy();

        return EventTimer{
            .start_event = start_event,
            .stop_event = stop_event,
            .running = false,
        };
    }

    /// Destroy the timer
    pub fn destroy(self: *EventTimer) void {
        self.start_event.destroy();
        self.stop_event.destroy();
    }

    /// Start timing (record start event on default stream)
    pub fn start(self: *EventTimer) !void {
        try self.start_event.recordDefault();
        self.running = true;
    }

    /// Start timing on specific stream
    pub fn startOnStream(self: *EventTimer, stream: *const Stream) !void {
        try self.start_event.record(stream);
        self.running = true;
    }

    /// Stop timing (record stop event on default stream)
    pub fn stop(self: *EventTimer) !void {
        try self.stop_event.recordDefault();
        self.running = false;
    }

    /// Stop timing on specific stream
    pub fn stopOnStream(self: *EventTimer, stream: *const Stream) !void {
        try self.stop_event.record(stream);
        self.running = false;
    }

    /// Get elapsed time in milliseconds (synchronizes on stop event)
    pub fn elapsedMs(self: *EventTimer) !f32 {
        try self.stop_event.synchronize();
        return try Event.elapsedMs(&self.start_event, &self.stop_event);
    }

    /// Get elapsed time in seconds
    pub fn elapsedSeconds(self: *EventTimer) !f64 {
        const ms = try self.elapsedMs();
        return @as(f64, ms) / 1000.0;
    }
};

// ============================================================================
// Stream Pool
// ============================================================================

/// Pool of reusable streams
pub const StreamPool = struct {
    /// Available streams
    streams: std.ArrayList(Stream),
    /// Driver reference
    drv: *const driver.CudaDriver,
    /// Allocator
    allocator: std.mem.Allocator,

    /// Create a stream pool with initial capacity
    pub fn init(drv: *const driver.CudaDriver, allocator: std.mem.Allocator, initial_count: usize) !StreamPool {
        var pool = StreamPool{
            .streams = .{},
            .drv = drv,
            .allocator = allocator,
        };

        // Pre-allocate streams
        for (0..initial_count) |_| {
            const stream = try Stream.create(drv);
            try pool.streams.append(allocator, stream);
        }

        return pool;
    }

    /// Destroy all streams in pool
    pub fn deinit(self: *StreamPool) void {
        for (self.streams.items) |*stream| {
            stream.destroy();
        }
        self.streams.deinit(self.allocator);
    }

    /// Acquire a stream from pool (or create new one)
    pub fn acquire(self: *StreamPool) !Stream {
        if (self.streams.items.len > 0) {
            return self.streams.pop();
        }
        return Stream.create(self.drv);
    }

    /// Return stream to pool
    pub fn release(self: *StreamPool, stream: Stream) !void {
        try self.streams.append(self.allocator, stream);
    }

    /// Get pool size
    pub fn size(self: *const StreamPool) usize {
        return self.streams.items.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Stream default" {
    const drv = driver.getDriver();
    const stream = Stream.getDefault(drv);
    try std.testing.expect(stream.is_default);
    try std.testing.expect(stream.handle == null);
}

test "Stream and Event (requires CUDA)" {
    const drv = driver.getDriver();
    if (!drv.available() or !drv.supportsStreams()) return;

    // Initialize driver
    if (drv.cuInit(0) != CUDA_SUCCESS) return;

    // Create stream
    var stream = Stream.create(drv) catch return;
    defer stream.destroy();

    try std.testing.expect(!stream.is_default);
}

test "EventTimer (no GPU required - just construction)" {
    // This test verifies the types compile correctly
    // Actual timing requires a GPU
    const EventTimerType = EventTimer;
    try std.testing.expect(@sizeOf(EventTimerType) > 0);
}
