const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const Allocator = std.mem.Allocator;
const pooled = @import("transport/thread_pool");

// CANARY: REQ=REQ-PERF-ASYNC-001; FEATURE="AsynchronousIO"; ASPECT=Performance; STATUS=TESTED; TEST=TestCANARY_AsynchronousIO; OWNER=performance; UPDATED=2025-10-04

/// High-performance asynchronous I/O system with completion queues
/// Enables non-blocking database operations for maximum throughput
/// Asynchronous I/O operation types
pub const IOOperation = union(enum) {
    read: struct {
        file: std.Io.File,
        buffer: []u8,
        offset: u64,
    },
    write: struct {
        file: std.Io.File,
        data: []const u8,
        offset: u64,
    },
    sync: struct {
        file: std.Io.File,
    },
    close: struct {
        file: std.Io.File,
    },
};

/// I/O operation completion result
pub const IOResult = union(enum) {
    read: struct {
        bytes_read: usize,
        status: IOStatus,
    },
    write: struct {
        bytes_written: usize,
        status: IOStatus,
    },
    sync: struct {
        status: IOStatus,
    },
    close: struct {
        status: IOStatus,
    },
};

/// I/O operation status
pub const IOStatus = enum {
    success,
    error_access_denied,
    error_file_not_found,
    error_disk_full,
    error_io_error,
    error_timeout,
    error_cancelled,
};

/// Completion callback function type
pub const CompletionCallback = *const fn (operation_id: u64, result: IOResult, user_data: ?*anyopaque) void;

/// Asynchronous I/O completion entry
pub const CompletionEntry = struct {
    operation_id: u64,
    operation: IOOperation,
    result: ?IOResult,
    callback: CompletionCallback,
    user_data: ?*anyopaque,
    timestamp: i64,
    timeout_ms: ?u32,
};

/// High-performance asynchronous I/O manager with completion queues
pub const AsyncIOManager = struct {
    allocator: Allocator,
    thread_pool: *pooled.ThreadPool,
    completion_queue: std.ArrayList(CompletionEntry),
    pending_operations: std.HashMap(u64, *CompletionEntry, std.hash_map.AutoContext(u64), 80),
    next_operation_id: std.atomic.Value(u64),
    running: std.atomic.Value(bool),
    mutex: std.Io.Mutex,

    const Self = @This();
    const WorkItem = struct {
        operation_entry: *CompletionEntry,
        manager: *AsyncIOManager,
    };

    pub fn init(allocator: Allocator, thread_count: usize) !Self {
        return Self{
            .allocator = allocator,
            .thread_pool = try pooled.ThreadPool.init(allocator, .{
                .num_threads = thread_count,
                .queue_capacity = @max(thread_count * 64, 256),
            }),
            .completion_queue = std.ArrayList(CompletionEntry).init(allocator),
            .pending_operations = std.HashMap(u64, *CompletionEntry, std.hash_map.DefaultContext(u64), 80).init(allocator),
            .next_operation_id = std.atomic.Value(u64).init(1),
            .running = std.atomic.Value(bool).init(true),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.running.store(false, .release);

        // Cancel pending operations
        {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

            var it = self.pending_operations.iterator();
            while (it.next()) |entry| {
                const completion_entry = entry.value_ptr.*;
                completion_entry.result = switch (completion_entry.operation) {
                    .read => IOResult{ .read = .{ .bytes_read = 0, .status = .error_cancelled } },
                    .write => IOResult{ .write = .{ .bytes_written = 0, .status = .error_cancelled } },
                    .sync => IOResult{ .sync = .{ .status = .error_cancelled } },
                    .close => IOResult{ .close = .{ .status = .error_cancelled } },
                };
                self.allocator.destroy(completion_entry);
            }
            self.pending_operations.clearAndFree();
        }

        self.thread_pool.deinit();
        self.completion_queue.deinit();
        self.pending_operations.deinit();
    }

    /// Submit asynchronous I/O operation
    pub fn submitIO(
        self: *Self,
        operation: IOOperation,
        callback: CompletionCallback,
        user_data: ?*anyopaque,
        timeout_ms: ?u32,
    ) !u64 {
        const operation_id = self.next_operation_id.fetchAdd(1, .acq_rel);

        const completion_entry = try self.allocator.create(CompletionEntry);
        completion_entry.* = CompletionEntry{
            .operation_id = operation_id,
            .operation = operation,
            .result = null,
            .callback = callback,
            .user_data = user_data,
            .timestamp = compat_milliTimestamp(),
            .timeout_ms = timeout_ms,
        };

        // Register pending operation
        {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            try self.pending_operations.put(operation_id, completion_entry);
        }

        const work_item = try self.allocator.create(WorkItem);
        errdefer self.allocator.destroy(work_item);
        work_item.* = .{
            .operation_entry = completion_entry,
            .manager = self,
        };

        // Submit to the shared thread-pool dependency instead of managing a
        // dedicated worker queue in-process.
        _ = try self.thread_pool.submitTask(runWorkItem, @ptrCast(work_item), .{
            .backpressure = .block,
            .lane = .blocking,
        });

        return operation_id;
    }

    /// Cancel pending operation
    pub fn cancelOperation(self: *Self, operation_id: u64) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.pending_operations.fetchRemove(operation_id)) |removed| {
            const completion_entry = removed.value;
            completion_entry.result = switch (completion_entry.operation) {
                .read => IOResult{ .read = .{ .bytes_read = 0, .status = .error_cancelled } },
                .write => IOResult{ .write = .{ .bytes_written = 0, .status = .error_cancelled } },
                .sync => IOResult{ .sync = .{ .status = .error_cancelled } },
                .close => IOResult{ .close = .{ .status = .error_cancelled } },
            };

            // Add to completion queue for callback execution
            self.completion_queue.append(completion_entry.*) catch {};
            self.allocator.destroy(completion_entry);
            return true;
        }

        return false;
    }

    /// Process completed operations and execute callbacks
    pub fn processCompletions(self: *Self, max_completions: ?usize) u32 {
        var processed: u32 = 0;
        const limit = max_completions orelse std.math.maxInt(u32);

        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        while (processed < limit and self.completion_queue.items.len > 0) {
            const completion = self.completion_queue.orderedRemove(0);

            // Execute callback
            if (completion.result) |result| {
                completion.callback(completion.operation_id, result, completion.user_data);
            }

            processed += 1;
        }

        return processed;
    }

    /// Get statistics about pending operations
    pub fn getStatistics(self: *Self) IOStatistics {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        var read_ops: u32 = 0;
        var write_ops: u32 = 0;
        var sync_ops: u32 = 0;
        var close_ops: u32 = 0;

        var it = self.pending_operations.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*.operation) {
                .read => read_ops += 1,
                .write => write_ops += 1,
                .sync => sync_ops += 1,
                .close => close_ops += 1,
            }
        }

        return IOStatistics{
            .pending_operations = @intCast(self.pending_operations.count()),
            .queued_completions = @intCast(self.completion_queue.items.len),
            .read_operations = read_ops,
            .write_operations = write_ops,
            .sync_operations = sync_ops,
            .close_operations = close_ops,
        };
    }

    /// Internal: Notify completion of I/O operation
    fn notifyCompletion(self: *Self, completion: CompletionEntry) !void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Remove from pending operations
        if (self.pending_operations.fetchRemove(completion.operation_id)) |removed| {
            self.allocator.destroy(removed.value);
        }

        // Add to completion queue
        try self.completion_queue.append(completion);
    }

    fn runWorkItem(ctx: *anyopaque, runtime: *pooled.TaskContext) void {
        _ = runtime;
        const work_item: *WorkItem = @ptrCast(@alignCast(ctx));
        defer work_item.manager.allocator.destroy(work_item);

        const result = executeIOOperation(work_item.operation_entry.operation);
        work_item.operation_entry.result = result;
        work_item.manager.notifyCompletion(work_item.operation_entry.*) catch {};
    }
};

/// I/O operation statistics
pub const IOStatistics = struct {
    pending_operations: u32,
    queued_completions: u32,
    read_operations: u32,
    write_operations: u32,
    sync_operations: u32,
    close_operations: u32,
};

/// Execute synchronous I/O operation (called by worker threads)
fn executeIOOperation(operation: IOOperation) IOResult {
    switch (operation) {
        .read => |read_op| {
            var bytes_read: usize = 0;
            const status: IOStatus = blk: {
                read_op.file.seekTo(read_op.offset) catch break :blk .error_io_error;
                bytes_read = read_op.file.readAll(read_op.buffer) catch break :blk .error_io_error;
                break :blk .success;
            };
            return IOResult{ .read = .{ .bytes_read = bytes_read, .status = status } };
        },
        .write => |write_op| {
            var bytes_written: usize = 0;
            const status: IOStatus = blk: {
                write_op.file.seekTo(write_op.offset) catch break :blk .error_io_error;
                bytes_written = write_op.file.writeAll(write_op.data) catch break :blk .error_io_error;
                break :blk .success;
            };
            return IOResult{ .write = .{ .bytes_written = bytes_written, .status = status } };
        },
        .sync => |sync_op| {
            const status: IOStatus = blk: {
                sync_op.file.sync() catch break :blk .error_io_error;
                break :blk .success;
            };
            return IOResult{ .sync = .{ .status = status } };
        },
        .close => |close_op| {
            const status: IOStatus = blk: {
                close_op.file.close();
                break :blk .success;
            };
            return IOResult{ .close = .{ .status = status } };
        },
    }
}

/// High-level asynchronous file operations
pub const AsyncFile = struct {
    file: std.Io.File,
    io_manager: *AsyncIOManager,
    allocator: Allocator,

    const Self = @This();

    pub fn init(io_manager: *AsyncIOManager, file: std.Io.File, allocator: Allocator) Self {
        return Self{
            .file = file,
            .io_manager = io_manager,
            .allocator = allocator,
        };
    }

    /// Asynchronous read operation
    pub fn readAsync(
        self: *Self,
        buffer: []u8,
        offset: u64,
        callback: CompletionCallback,
        user_data: ?*anyopaque,
        timeout_ms: ?u32,
    ) !u64 {
        const operation = IOOperation{
            .read = .{
                .file = self.file,
                .buffer = buffer,
                .offset = offset,
            },
        };

        return self.io_manager.submitIO(operation, callback, user_data, timeout_ms);
    }

    /// Asynchronous write operation
    pub fn writeAsync(
        self: *Self,
        data: []const u8,
        offset: u64,
        callback: CompletionCallback,
        user_data: ?*anyopaque,
        timeout_ms: ?u32,
    ) !u64 {
        const operation = IOOperation{
            .write = .{
                .file = self.file,
                .data = data,
                .offset = offset,
            },
        };

        return self.io_manager.submitIO(operation, callback, user_data, timeout_ms);
    }

    /// Asynchronous sync operation
    pub fn syncAsync(
        self: *Self,
        callback: CompletionCallback,
        user_data: ?*anyopaque,
        timeout_ms: ?u32,
    ) !u64 {
        const operation = IOOperation{
            .sync = .{
                .file = self.file,
            },
        };

        return self.io_manager.submitIO(operation, callback, user_data, timeout_ms);
    }

    /// Promise-based asynchronous read (blocks until completion)
    pub fn readSync(self: *Self, buffer: []u8, offset: u64, timeout_ms: ?u32) !IOResult {
        var result: ?IOResult = null;

        // PERF-D / #816 follow-up: the prior agent classified this site as
        // "no-signal-source" and left a 1 ms sleep between processCompletions
        // calls. Re-scout: the callback fires from inside processCompletions
        // (drains AsyncIOManager.completion_queue on the calling thread —
        // see src/performance/async_io.zig:241-250). So the "signal source"
        // IS the in-thread drain itself; there is no other thread that can
        // wake us. The right pattern here is `processCompletions; yield;
        // repeat` (no sleep) — the 1 ms sleep added an unconditional latency
        // floor with no upside. Yielding lets other threads (e.g. the worker
        // running runWorkItem which calls notifyCompletion) actually make
        // progress and enqueue the completion we're waiting for, then we
        // drain on the next iteration.
        const Context = struct {
            result_ptr: *?IOResult,
            completed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0), // 0 = pending, 1 = done
        };

        var context = Context{
            .result_ptr = &result,
        };

        const callback = struct {
            fn cb(operation_id: u64, io_result: IOResult, user_data: ?*anyopaque) void {
                _ = operation_id;
                const ctx = @as(*Context, @ptrCast(@alignCast(user_data.?)));
                ctx.result_ptr.* = io_result;
                // Atomic release-store so a parallel `completed.load(.acquire)`
                // sees `result_ptr.*` populated before observing the flag.
                ctx.completed.store(1, .release);
            }
        }.cb;

        _ = try self.readAsync(buffer, offset, callback, &context, timeout_ms);

        // Tight drain loop with yield. processCompletions is non-blocking
        // (just drains AsyncIOManager.completion_queue and fires callbacks
        // in-thread). Yielding instead of sleeping eliminates the prior
        // 1 ms latency floor; total completion latency drops to whatever
        // it takes the worker thread to finish executeIOOperation and
        // call notifyCompletion (a few µs for an in-memory cache hit, the
        // disk read time for a cold read).
        while (context.completed.load(.acquire) == 0) {
            _ = self.io_manager.processCompletions(10);
            std.Thread.yield() catch {};
        }

        return result.?;
    }

    /// Promise-based asynchronous write (blocks until completion)
    pub fn writeSync(self: *Self, data: []const u8, offset: u64, timeout_ms: ?u32) !IOResult {
        var result: ?IOResult = null;

        const Context = struct {
            result_ptr: *?IOResult,
            completed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        };

        var context = Context{
            .result_ptr = &result,
        };

        const callback = struct {
            fn cb(operation_id: u64, io_result: IOResult, user_data: ?*anyopaque) void {
                _ = operation_id;
                const ctx = @as(*Context, @ptrCast(@alignCast(user_data.?)));
                ctx.result_ptr.* = io_result;
                ctx.completed.store(1, .release);
            }
        }.cb;

        _ = try self.writeAsync(data, offset, callback, &context, timeout_ms);

        // PERF-D / #816 follow-up: yield-based drain, same rationale as
        // readSync above.
        while (context.completed.load(.acquire) == 0) {
            _ = self.io_manager.processCompletions(10);
            std.Thread.yield() catch {};
        }

        return result.?;
    }
};

/// Batched asynchronous I/O operations for high throughput
pub const BatchAsyncIO = struct {
    io_manager: *AsyncIOManager,
    operations: std.ArrayList(IOOperation),
    callbacks: std.ArrayList(CompletionCallback),
    user_data: std.ArrayList(?*anyopaque),
    allocator: Allocator,

    const Self = @This();

    pub fn init(io_manager: *AsyncIOManager, allocator: Allocator) Self {
        return Self{
            .io_manager = io_manager,
            .operations = std.ArrayList(IOOperation).init(allocator),
            .callbacks = std.ArrayList(CompletionCallback).init(allocator),
            .user_data = std.ArrayList(?*anyopaque).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.operations.deinit();
        self.callbacks.deinit();
        self.user_data.deinit();
    }

    /// Add operation to batch
    pub fn addOperation(
        self: *Self,
        operation: IOOperation,
        callback: CompletionCallback,
        user_data: ?*anyopaque,
    ) !void {
        try self.operations.append(operation);
        try self.callbacks.append(callback);
        try self.user_data.append(user_data);
    }

    /// Submit all batched operations
    pub fn submitBatch(self: *Self, timeout_ms: ?u32) ![]u64 {
        const operation_ids = try self.allocator.alloc(u64, self.operations.items.len);
        errdefer self.allocator.free(operation_ids);

        for (self.operations.items, self.callbacks.items, self.user_data.items, 0..) |operation, callback, data, i| {
            operation_ids[i] = try self.io_manager.submitIO(operation, callback, data, timeout_ms);
        }

        // Clear batch for reuse
        self.operations.clearRetainingCapacity();
        self.callbacks.clearRetainingCapacity();
        self.user_data.clearRetainingCapacity();

        return operation_ids;
    }
};

/// Benchmark asynchronous I/O performance
pub fn benchmarkAsyncIO(
    allocator: Allocator,
    file_size: u64,
    concurrent_operations: u32,
    iterations: u32,
) !struct { async_throughput_mbps: f64, sync_throughput_mbps: f64, async_latency_ns: u64, sync_latency_ns: u64, async_advantage: f64 } {
    _ = concurrent_operations; // Suppress unused parameter warning
    const test_file = "benchmark_async_test.dat";
    defer std.Io.Dir.cwd().deleteFile(test_file) catch {};

    // Create test file
    {
        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), test_file, .{});
        defer file.close();

        const test_data = try allocator.alloc(u8, file_size);
        defer allocator.free(test_data);

        for (test_data, 0..) |*byte, i| {
            byte.* = @intCast(i % 256);
        }

        _ = try file.writeAll(test_data);
        try file.sync();
    }

    // Benchmark async I/O
    var async_io_manager = try AsyncIOManager.init(allocator, 4);
    defer async_io_manager.deinit();

    const file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), test_file, .{});
    defer file.close();

    var async_file = AsyncFile.init(&async_io_manager, file, allocator);

    var timer = try std.time.Timer.start();
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    // Async benchmark
    timer.reset();
    for (0..iterations) |_| {
        const result = try async_file.readSync(buffer, 0, 5000); // 5s timeout
        if (result.read.status != .success) {
            return error.AsyncIOFailed;
        }
    }
    const async_time = timer.read();

    // Sync benchmark
    timer.reset();
    for (0..iterations) |_| {
        try file.seekTo(0);
        _ = try file.readAll(buffer);
    }
    const sync_time = timer.read();

    const async_latency = async_time / iterations;
    const sync_latency = sync_time / iterations;

    const async_throughput = (@as(f64, @floatFromInt(file_size * iterations)) / @as(f64, @floatFromInt(async_time))) * 1e9 / (1024 * 1024);
    const sync_throughput = (@as(f64, @floatFromInt(file_size * iterations)) / @as(f64, @floatFromInt(sync_time))) * 1e9 / (1024 * 1024);

    const advantage = sync_throughput / async_throughput; // Note: sync might be faster for simple cases

    return .{
        .async_throughput_mbps = async_throughput,
        .sync_throughput_mbps = sync_throughput,
        .async_latency_ns = async_latency,
        .sync_latency_ns = sync_latency,
        .async_advantage = advantage,
    };
}

// Tests
const testing = std.testing;

test "Asynchronous I/O basic operations" {
    const allocator = testing.allocator;

    var io_manager = try AsyncIOManager.init(allocator, 2);
    defer io_manager.deinit();

    const test_file = "test_async.dat";
    defer std.Io.Dir.cwd().deleteFile(test_file) catch {};

    const test_data = "Hello, async world!";

    // Create test file
    {
        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), test_file, .{});
        defer file.close();
        _ = try file.writeAll(test_data);
        try file.sync();
    }

    // Test async read
    const file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), test_file, .{});
    defer file.close();

    var async_file = AsyncFile.init(&io_manager, file, allocator);

    var buffer: [32]u8 = undefined;
    const result = try async_file.readSync(buffer[0..test_data.len], 0, 1000);

    try testing.expect(result.read.status == .success);
    try testing.expectEqual(test_data.len, result.read.bytes_read);
    try testing.expectEqualStrings(test_data, buffer[0..test_data.len]);
}

test "Batched asynchronous operations" {
    const allocator = testing.allocator;

    var io_manager = try AsyncIOManager.init(allocator, 2);
    defer io_manager.deinit();

    var batch = BatchAsyncIO.init(&io_manager, allocator);
    defer batch.deinit();

    // Add some mock operations
    const CompletionCallbackType = struct {
        fn callback(operation_id: u64, result: IOResult, user_data: ?*anyopaque) void {
            _ = operation_id;
            _ = result;
            _ = user_data;
        }
    };

    try batch.addOperation(
        IOOperation{ .sync = .{ .file = std.Io.File{ .handle = 0 } }, .flags = .{ .nonblocking = false } },
        CompletionCallbackType.callback,
        null,
    );

    // Just test that batch operations can be managed
    try testing.expectEqual(@as(usize, 1), batch.operations.items.len);
}

test "I/O statistics collection" {
    const allocator = testing.allocator;

    var io_manager = try AsyncIOManager.init(allocator, 2);
    defer io_manager.deinit();

    const stats = io_manager.getStatistics();

    // Basic validation
    try testing.expectEqual(@as(u32, 0), stats.pending_operations);
    try testing.expectEqual(@as(u32, 0), stats.queued_completions);
}
