// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

//! Parallel utilities for data structures using spice heartbeat scheduling.
//!
//! Provides low-overhead parallelism for common operations on collections
//! using the fork/join pattern with sub-nanosecond overhead.

const std = @import("std");
const build_options = @import("build_options");
const spice = if (build_options.enable_spice) @import("spice") else struct {
    pub const ThreadPool = void;
    pub const Task = void;
    pub fn Future(comptime I: type, comptime O: type) type {
        _ = I;
        _ = O;
        return void;
    }
};

// ============================================================================
// Global Spice Thread Pool
// ============================================================================

var global_spice_pool: if (build_options.enable_spice) ?spice.ThreadPool else void = if (build_options.enable_spice) null else {};
var spice_pool_mutex: std.Thread.Mutex = .{};

/// Get the global spice thread pool, initializing if needed
pub fn getSpicePool() if (build_options.enable_spice) *spice.ThreadPool else void {
    if (!build_options.enable_spice) return;

    spice_pool_mutex.lock();
    defer spice_pool_mutex.unlock();

    if (global_spice_pool == null) {
        global_spice_pool = spice.ThreadPool.init(std.heap.page_allocator);
        global_spice_pool.?.start(.{});
    }
    return &global_spice_pool.?;
}

/// Deinitialize the global spice pool.
///
/// **Safety:** Must only be called after all parallel operations have
/// completed. Calling deinit while operations are in-flight on other
/// threads will result in use-after-free, as those threads may still
/// hold references to the pool's internal state.
pub fn deinitSpicePool() void {
    if (!build_options.enable_spice) return;

    spice_pool_mutex.lock();
    defer spice_pool_mutex.unlock();

    if (global_spice_pool) |*pool| {
        pool.deinit();
        global_spice_pool = null;
    }
}

// ============================================================================
// Context Types for Parallel Operations
// ============================================================================

/// Helper to create a reduce context type for a given element type
pub fn ReduceContext(comptime T: type) type {
    return struct {
        data: []const T,
        initial: T,
    };
}

/// Helper to create a map context type for given input/output types
pub fn MapContext(comptime T: type, comptime U: type) type {
    return struct {
        input: []const T,
        output: []U,
    };
}

// ============================================================================
// Parallel Reduce Operations
// ============================================================================

/// Minimum input length to engage parallel execution. Below this threshold
/// the sequential fallback is used (overhead of thread dispatch exceeds gain).
const parallel_min_length: usize = 1024;

/// Base-case chunk size for fork/join recursion. Chunks at or below this
/// size are processed sequentially within a worker thread.
const fork_join_chunk_size: usize = 512;

/// Parallel reduce using fork/join pattern.
/// Combines elements using the provided function with sub-nanosecond overhead.
pub fn parallelReduce(
    comptime T: type,
    data: []const T,
    initial: T,
    comptime reduceFn: fn (T, T) T,
) T {
    if (!build_options.enable_spice or data.len < parallel_min_length) {
        // Sequential fallback
        var acc = initial;
        for (data) |v| acc = reduceFn(acc, v);
        return acc;
    }

    const pool = getSpicePool();
    const Ctx = ReduceContext(T);
    return pool.call(T, ParallelReduceTask(T, reduceFn).task, Ctx{ .data = data, .initial = initial });
}

fn ParallelReduceTask(comptime T: type, comptime reduceFn: fn (T, T) T) type {
    const Ctx = ReduceContext(T);
    return struct {
        pub fn task(t: *spice.Task, ctx: Ctx) T {
            const data = ctx.data;
            const initial = ctx.initial;

            // Base case
            if (data.len <= fork_join_chunk_size) {
                var acc = initial;
                for (data) |v| acc = reduceFn(acc, v);
                return acc;
            }

            // Fork/join
            const mid = data.len / 2;
            const left_ctx = Ctx{ .data = data[0..mid], .initial = initial };
            const right_ctx = Ctx{ .data = data[mid..], .initial = initial };

            var fut = spice.Future(Ctx, T).init();
            fut.fork(t, task, right_ctx);

            const left_result = t.call(T, task, left_ctx);
            const right_result = if (fut.join(t)) |val| val else t.call(T, task, right_ctx);

            return reduceFn(left_result, right_result);
        }
    };
}

/// Parallel sum using fork/join
pub fn parallelSum(comptime T: type, data: []const T) T {
    return parallelReduce(T, data, 0, struct {
        fn add(a: T, b: T) T {
            return a + b;
        }
    }.add);
}

/// Parallel max using fork/join
pub fn parallelMax(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;
    return parallelReduce(T, data[1..], data[0], struct {
        fn max(a: T, b: T) T {
            return if (a > b) a else b;
        }
    }.max);
}

/// Parallel min using fork/join
pub fn parallelMin(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;
    return parallelReduce(T, data[1..], data[0], struct {
        fn min(a: T, b: T) T {
            return if (a < b) a else b;
        }
    }.min);
}

// ============================================================================
// Parallel Map Operations
// ============================================================================

/// Parallel map using fork/join pattern.
/// Applies a function to each element in parallel.
pub fn parallelMap(
    comptime T: type,
    comptime U: type,
    input: []const T,
    output: []U,
    comptime mapFn: fn (T) U,
) void {
    std.debug.assert(input.len == output.len);

    if (!build_options.enable_spice or input.len < parallel_min_length) {
        // Sequential fallback
        for (input, 0..) |v, i| output[i] = mapFn(v);
        return;
    }

    const pool = getSpicePool();
    const Ctx = MapContext(T, U);
    _ = pool.call(void, ParallelMapTask(T, U, mapFn).task, Ctx{ .input = input, .output = output });
}

fn ParallelMapTask(comptime T: type, comptime U: type, comptime mapFn: fn (T) U) type {
    const Ctx = MapContext(T, U);
    return struct {
        pub fn task(t: *spice.Task, ctx: Ctx) void {
            const input = ctx.input;
            const output = ctx.output;

            // Base case
            if (input.len <= fork_join_chunk_size) {
                for (input, 0..) |v, i| output[i] = mapFn(v);
                return;
            }

            // Fork/join
            const mid = input.len / 2;
            const left_ctx = Ctx{ .input = input[0..mid], .output = output[0..mid] };
            const right_ctx = Ctx{ .input = input[mid..], .output = output[mid..] };

            var fut = spice.Future(Ctx, void).init();
            fut.fork(t, task, right_ctx);

            t.call(void, task, left_ctx);

            if (fut.join(t) == null) {
                t.call(void, task, right_ctx);
            }
        }
    };
}

// ============================================================================
// Parallel Filter Operations
// ============================================================================

/// Parallel count of elements matching a predicate
pub fn parallelCount(
    comptime T: type,
    data: []const T,
    comptime predicate: fn (T) bool,
) usize {
    if (!build_options.enable_spice or data.len < parallel_min_length) {
        // Sequential fallback
        var count: usize = 0;
        for (data) |v| {
            if (predicate(v)) count += 1;
        }
        return count;
    }

    const pool = getSpicePool();
    return pool.call(usize, ParallelCountTask(T, predicate).task, data);
}

fn ParallelCountTask(comptime T: type, comptime predicate: fn (T) bool) type {
    return struct {
        pub fn task(t: *spice.Task, data: []const T) usize {
            // Base case
            if (data.len <= fork_join_chunk_size) {
                var count: usize = 0;
                for (data) |v| {
                    if (predicate(v)) count += 1;
                }
                return count;
            }

            // Fork/join
            const mid = data.len / 2;
            const left = data[0..mid];
            const right = data[mid..];

            var fut = spice.Future([]const T, usize).init();
            fut.fork(t, task, right);

            const left_count = t.call(usize, task, left);
            const right_count = if (fut.join(t)) |val| val else t.call(usize, task, right);

            return left_count + right_count;
        }
    };
}

// ============================================================================
// Parallel Search Operations
// ============================================================================

/// Parallel find using fork/join pattern.
/// Returns true if any element matches the predicate.
pub fn parallelAny(
    comptime T: type,
    data: []const T,
    comptime predicate: fn (T) bool,
) bool {
    if (!build_options.enable_spice or data.len < parallel_min_length) {
        // Sequential fallback
        for (data) |v| {
            if (predicate(v)) return true;
        }
        return false;
    }

    const pool = getSpicePool();
    return pool.call(bool, ParallelAnyTask(T, predicate).task, data);
}

fn ParallelAnyTask(comptime T: type, comptime predicate: fn (T) bool) type {
    return struct {
        pub fn task(t: *spice.Task, data: []const T) bool {
            // Base case
            if (data.len <= fork_join_chunk_size) {
                for (data) |v| {
                    if (predicate(v)) return true;
                }
                return false;
            }

            // Fork/join
            const mid = data.len / 2;
            const left = data[0..mid];
            const right = data[mid..];

            var fut = spice.Future([]const T, bool).init();
            fut.fork(t, task, right);

            const left_result = t.call(bool, task, left);
            if (left_result) return true;

            const right_result = if (fut.join(t)) |val| val else t.call(bool, task, right);
            return right_result;
        }
    };
}

/// Parallel check if all elements match predicate
pub fn parallelAll(
    comptime T: type,
    data: []const T,
    comptime predicate: fn (T) bool,
) bool {
    if (!build_options.enable_spice or data.len < parallel_min_length) {
        // Sequential fallback
        for (data) |v| {
            if (!predicate(v)) return false;
        }
        return true;
    }

    const pool = getSpicePool();
    return pool.call(bool, ParallelAllTask(T, predicate).task, data);
}

fn ParallelAllTask(comptime T: type, comptime predicate: fn (T) bool) type {
    return struct {
        pub fn task(t: *spice.Task, data: []const T) bool {
            // Base case
            if (data.len <= fork_join_chunk_size) {
                for (data) |v| {
                    if (!predicate(v)) return false;
                }
                return true;
            }

            // Fork/join
            const mid = data.len / 2;
            const left = data[0..mid];
            const right = data[mid..];

            var fut = spice.Future([]const T, bool).init();
            fut.fork(t, task, right);

            const left_result = t.call(bool, task, left);
            if (!left_result) return false;

            const right_result = if (fut.join(t)) |val| val else t.call(bool, task, right);
            return right_result;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parallel sum" {
    if (!build_options.enable_spice) return error.SkipZigTest;

    const data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const result = parallelSum(i32, &data);
    try std.testing.expectEqual(@as(i32, 55), result);
}

test "parallel sum large" {
    if (!build_options.enable_spice) return error.SkipZigTest;

    var data: [10000]i32 = undefined;
    var expected: i32 = 0;
    for (0..data.len) |i| {
        data[i] = @intCast(i + 1);
        expected += data[i];
    }

    const result = parallelSum(i32, &data);
    try std.testing.expectEqual(expected, result);
}

test "parallel max" {
    if (!build_options.enable_spice) return error.SkipZigTest;

    const data = [_]i32{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3 };
    const result = parallelMax(i32, &data);
    try std.testing.expectEqual(@as(?i32, 9), result);
}

test "parallel count" {
    if (!build_options.enable_spice) return error.SkipZigTest;

    const data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const count = parallelCount(i32, &data, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try std.testing.expectEqual(@as(usize, 5), count);
}

test "parallel any" {
    if (!build_options.enable_spice) return error.SkipZigTest;

    const data = [_]i32{ 1, 3, 5, 7, 8, 9 };
    const hasEven = parallelAny(i32, &data, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try std.testing.expect(hasEven);

    const allOdd = [_]i32{ 1, 3, 5, 7, 9 };
    const hasEvenInOdd = parallelAny(i32, &allOdd, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try std.testing.expect(!hasEvenInOdd);
}

test "parallel all" {
    if (!build_options.enable_spice) return error.SkipZigTest;

    const positives = [_]i32{ 1, 2, 3, 4, 5 };
    const allPositive = parallelAll(i32, &positives, struct {
        fn isPositive(x: i32) bool {
            return x > 0;
        }
    }.isPositive);
    try std.testing.expect(allPositive);

    const mixed = [_]i32{ 1, 2, -3, 4, 5 };
    const allPositiveMixed = parallelAll(i32, &mixed, struct {
        fn isPositive(x: i32) bool {
            return x > 0;
        }
    }.isPositive);
    try std.testing.expect(!allPositiveMixed);
}

// ============================================================================
// Sequential fallback tests (work regardless of spice being enabled)
// ============================================================================

test "sequential fallback - reduce, sum, max, min with small data" {
    // Small data (below parallel_min_length threshold) always uses sequential fallback
    const data = [_]i32{ 10, 20, 30, 40, 50 };

    // parallelSum on small data
    const sum = parallelSum(i32, &data);
    try std.testing.expectEqual(@as(i32, 150), sum);

    // parallelMax on small data
    const max = parallelMax(i32, &data);
    try std.testing.expectEqual(@as(?i32, 50), max);

    // parallelMin on small data
    const min = parallelMin(i32, &data);
    try std.testing.expectEqual(@as(?i32, 10), min);

    // Edge cases: empty slices
    const empty = [_]i32{};
    try std.testing.expectEqual(@as(?i32, null), parallelMax(i32, &empty));
    try std.testing.expectEqual(@as(?i32, null), parallelMin(i32, &empty));
    try std.testing.expectEqual(@as(i32, 0), parallelSum(i32, &empty));

    // Single element
    const single = [_]i32{42};
    try std.testing.expectEqual(@as(i32, 42), parallelSum(i32, &single));
    try std.testing.expectEqual(@as(?i32, 42), parallelMax(i32, &single));
    try std.testing.expectEqual(@as(?i32, 42), parallelMin(i32, &single));
}

test "sequential fallback - count, any, all, map with small data" {
    const isEven = struct {
        fn f(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.f;
    const isPositive = struct {
        fn f(x: i32) bool {
            return x > 0;
        }
    }.f;

    // parallelCount on small data
    const data = [_]i32{ 1, 2, 3, 4, 5, 6 };
    try std.testing.expectEqual(@as(usize, 3), parallelCount(i32, &data, isEven));

    // parallelAny: match present
    try std.testing.expect(parallelAny(i32, &data, isEven));
    // parallelAny: no match
    const all_odd = [_]i32{ 1, 3, 5, 7 };
    try std.testing.expect(!parallelAny(i32, &all_odd, isEven));

    // parallelAll: all match
    const positives = [_]i32{ 1, 2, 3 };
    try std.testing.expect(parallelAll(i32, &positives, isPositive));
    // parallelAll: not all match
    const mixed = [_]i32{ 1, -2, 3 };
    try std.testing.expect(!parallelAll(i32, &mixed, isPositive));

    // parallelMap on small data
    const dbl = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;
    const input = [_]i32{ 1, 2, 3, 4, 5 };
    var output: [5]i32 = undefined;
    parallelMap(i32, i32, &input, &output, dbl);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 2, 4, 6, 8, 10 }, &output);

    // Empty data edge cases
    const empty = [_]i32{};
    try std.testing.expectEqual(@as(usize, 0), parallelCount(i32, &empty, isEven));
    try std.testing.expect(!parallelAny(i32, &empty, isEven));
    try std.testing.expect(parallelAll(i32, &empty, isPositive));
}
