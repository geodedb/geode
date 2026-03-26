// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # concurrency
//!
//! A portable, high-performance thread pool and bounded concurrent queue
//! for Zig applications.
//!
//! ## Features
//!
//! - Lock-free bounded MPMC queue (Vyukov algorithm)
//! - Configurable thread pool with auto-detection of CPU count
//! - Non-blocking and blocking work submission (with optional timeout)
//! - Per-item completion callbacks
//! - Pool statistics and observability
//!
//! ## Quick Start
//!
//! ```zig
//! const concurrency = @import("concurrency");
//!
//! pub fn main() !void {
//!     const pool = try concurrency.ThreadPool.init(
//!         std.heap.page_allocator,
//!         .{ .num_threads = 4 },
//!     );
//!     defer pool.deinit();
//!
//!     _ = pool.submit(.{
//!         .context = @ptrCast(&my_ctx),
//!         .callback = myWork,
//!     });
//! }
//! ```
//!
//! ## License
//!
//! Apache-2.0

const std = @import("std");
const thread_pool = @import("thread_pool.zig");
const bounded_queue = @import("bounded_queue.zig");

/// Library version.
pub const version = "0.1.0";

// Re-export public API.
pub const BoundedQueue = bounded_queue.BoundedQueue;
pub const ThreadPool = thread_pool.ThreadPool;
pub const ThreadPoolConfig = thread_pool.ThreadPoolConfig;
pub const WorkItem = thread_pool.WorkItem;
pub const Stats = thread_pool.Stats;

// ============================================================================
// Unit Tests
// ============================================================================

test "re-exports are accessible" {
    try std.testing.expect(@TypeOf(ThreadPool) != void);
    try std.testing.expect(@TypeOf(ThreadPoolConfig) != void);
    try std.testing.expect(@TypeOf(WorkItem) != void);
    try std.testing.expect(@TypeOf(Stats) != void);
}

test "version is defined" {
    try std.testing.expectEqualStrings("0.1.0", version);
}

test {
    std.testing.refAllDecls(@This());
}
