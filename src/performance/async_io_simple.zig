const std = @import("std");
const Allocator = std.mem.Allocator;

// CANARY: REQ=REQ-PERF-ASYNC-001; FEATURE="SimpleAsyncIO"; ASPECT=Performance; STATUS=TESTED; TEST=TestCANARY_SimpleAsyncIO; OWNER=performance; UPDATED=2025-10-04

/// Simplified asynchronous I/O framework for testing performance concepts
/// This provides the basic structure for async I/O without complex threading
/// I/O operation status
pub const IOStatus = enum {
    success,
    error_io_error,
    error_file_not_found,
    error_cancelled,
};

/// Simple async operation result
pub const AsyncResult = struct {
    bytes_processed: usize,
    status: IOStatus,
};

/// Completion callback
pub const CompletionCallback = *const fn (operation_id: u64, result: AsyncResult, user_data: ?*anyopaque) void;

/// Simple async operation
pub const AsyncOperation = struct {
    id: u64,
    callback: CompletionCallback,
    user_data: ?*anyopaque,
    completed: bool,
    result: AsyncResult,
};

/// Simplified async I/O manager
pub const SimpleAsyncIO = struct {
    allocator: Allocator,
    operations: [16]?AsyncOperation, // Fixed size for simplicity
    next_id: u64,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .operations = [_]?AsyncOperation{null} ** 16,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self; // Nothing to cleanup in this simple implementation
    }

    /// Submit async operation (mock implementation)
    pub fn submitRead(
        self: *Self,
        file_path: []const u8,
        buffer: []u8,
        callback: CompletionCallback,
        user_data: ?*anyopaque,
    ) !u64 {
        // Find empty slot
        for (&self.operations) |*slot| {
            if (slot.* == null) {
                const operation_id = self.next_id;
                self.next_id += 1;

                // Execute synchronously for testing
                const result = self.executeRead(file_path, buffer);

                slot.* = AsyncOperation{
                    .id = operation_id,
                    .callback = callback,
                    .user_data = user_data,
                    .completed = true,
                    .result = result,
                };

                return operation_id;
            }
        }

        return error.TooManyOperations;
    }

    /// Process completed operations
    pub fn processCompletions(self: *Self) u32 {
        var processed: u32 = 0;

        for (&self.operations) |*slot| {
            if (slot.*) |*operation| {
                if (operation.completed) {
                    operation.callback(operation.id, operation.result, operation.user_data);
                    slot.* = null;
                    processed += 1;
                }
            }
        }

        return processed;
    }

    /// Execute read operation synchronously
    fn executeRead(self: *Self, file_path: []const u8, buffer: []u8) AsyncResult {
        _ = self;

        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            return AsyncResult{ .bytes_processed = 0, .status = .error_file_not_found };
        };
        defer file.close();

        const bytes_read = file.readAll(buffer) catch {
            return AsyncResult{ .bytes_processed = 0, .status = .error_io_error };
        };

        return AsyncResult{ .bytes_processed = bytes_read, .status = .success };
    }

    /// Get statistics
    pub fn getStatistics(self: *Self) AsyncStatistics {
        var pending: u32 = 0;
        var completed: u32 = 0;

        for (self.operations) |slot| {
            if (slot) |operation| {
                if (operation.completed) {
                    completed += 1;
                } else {
                    pending += 1;
                }
            }
        }

        return AsyncStatistics{
            .pending_operations = pending,
            .completed_operations = completed,
            .max_operations = 16,
        };
    }
};

/// Statistics structure
pub const AsyncStatistics = struct {
    pending_operations: u32,
    completed_operations: u32,
    max_operations: u32,
};

/// High-level async file wrapper
pub const AsyncFile = struct {
    file_path: []const u8,
    async_io: *SimpleAsyncIO,

    const Self = @This();

    pub fn init(async_io: *SimpleAsyncIO, file_path: []const u8) Self {
        return Self{
            .file_path = file_path,
            .async_io = async_io,
        };
    }

    /// Promise-style read (blocks until completion)
    pub fn readSync(self: *Self, buffer: []u8) !AsyncResult {
        var result: ?AsyncResult = null;

        const Context = struct {
            result_ptr: *?AsyncResult,
        };

        var context = Context{ .result_ptr = &result };

        const callback = struct {
            fn cb(operation_id: u64, async_result: AsyncResult, user_data: ?*anyopaque) void {
                _ = operation_id;
                const ctx = @as(*Context, @ptrCast(@alignCast(user_data.?)));
                ctx.result_ptr.* = async_result;
            }
        }.cb;

        _ = try self.async_io.submitRead(self.file_path, buffer, callback, &context);

        // Process completion
        while (result == null) {
            _ = self.async_io.processCompletions();
        }

        return result.?;
    }
};

/// Benchmark async I/O vs sync I/O
pub fn benchmarkAsyncIO(
    allocator: Allocator,
    file_size: u64,
    iterations: u32,
) !struct { async_ns: u64, sync_ns: u64, advantage: f64 } {
    const test_file = "benchmark_async.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create test file
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();

        const test_data = try allocator.alloc(u8, file_size);
        defer allocator.free(test_data);

        for (test_data, 0..) |*byte, i| {
            byte.* = @intCast(i % 256);
        }

        _ = try file.writeAll(test_data);
        try file.sync();
    }

    // Buffer for reads
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    // Benchmark async
    var async_io = SimpleAsyncIO.init(allocator);
    defer async_io.deinit();

    var async_file = AsyncFile.init(&async_io, test_file);

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const result = try async_file.readSync(buffer);
        if (result.status != .success) {
            return error.AsyncReadFailed;
        }
    }
    const async_time = timer.read();

    // Benchmark sync
    timer.reset();
    for (0..iterations) |_| {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();
        _ = try file.readAll(buffer);
    }
    const sync_time = timer.read();

    const async_avg = async_time / iterations;
    const sync_avg = sync_time / iterations;
    const advantage = @as(f64, @floatFromInt(sync_avg)) / @as(f64, @floatFromInt(async_avg));

    return .{
        .async_ns = async_avg,
        .sync_ns = sync_avg,
        .advantage = advantage,
    };
}

// Tests
const testing = std.testing;

test "Simple async I/O basic functionality" {
    const allocator = testing.allocator;

    var async_io = SimpleAsyncIO.init(allocator);
    defer async_io.deinit();

    const test_file = "test_async_basic.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const test_data = "Hello async world!";

    // Create test file
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        _ = try file.writeAll(test_data);
        try file.sync();
    }

    // Test async read
    var async_file = AsyncFile.init(&async_io, test_file);

    var buffer: [32]u8 = undefined;
    const result = try async_file.readSync(buffer[0..test_data.len]);

    try testing.expect(result.status == .success);
    try testing.expectEqual(test_data.len, result.bytes_processed);
    try testing.expectEqualStrings(test_data, buffer[0..test_data.len]);
}

test "Async I/O statistics" {
    const allocator = testing.allocator;

    var async_io = SimpleAsyncIO.init(allocator);
    defer async_io.deinit();

    const stats = async_io.getStatistics();

    try testing.expectEqual(@as(u32, 0), stats.pending_operations);
    try testing.expectEqual(@as(u32, 0), stats.completed_operations);
    try testing.expectEqual(@as(u32, 16), stats.max_operations);
}

test "Performance benchmark functionality" {
    const allocator = testing.allocator;

    const results = try benchmarkAsyncIO(allocator, 1024, 3);

    // Validate results are reasonable
    try testing.expect(results.async_ns > 0);
    try testing.expect(results.sync_ns > 0);
    try testing.expect(results.advantage > 0.1);
}

test "CANARY: REQ=REQ-PERF-ASYNC-001 - Simple async I/O validation" {
    const allocator = testing.allocator;

    var async_io = SimpleAsyncIO.init(allocator);
    defer async_io.deinit();

    const test_file = "canary_async.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const test_data = "CANARY: Async I/O validation for REQ=REQ-PERF-ASYNC-001";

    // Create test file
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        _ = try file.writeAll(test_data);
        try file.sync();
    }

    // Test functionality
    var async_file = AsyncFile.init(&async_io, test_file);

    var buffer: [128]u8 = undefined;
    const result = try async_file.readSync(buffer[0..test_data.len]);

    try testing.expect(result.status == .success);
    try testing.expectEqual(test_data.len, result.bytes_processed);
    try testing.expectEqualStrings(test_data, buffer[0..test_data.len]);
}
