// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Unit test for the SHARED hold-time atomics on `ManagedGraph`
//! (`rwlock_shared_hold_ns_total`, `rwlock_shared_max_hold_ns_observed`).
//!
//! Manually exercises the wrap pattern that the 6 production SHARED-acquire
//! sites in `graph_storage_adapter.zig` use (acquire → record _hold_start →
//! work → unlock → fetchAdd to total + racy load+max+store to max_observed),
//! distilled to its essentials. Verifies the field reads/writes do what the
//! next phase's bisection assumes.

// CANARY: REQ=REQ-PERF-RWLOCK-HOLD-TIME-001; FEATURE="MgRwLockSharedHoldTimeAtomics"; ASPECT=AtomicReadWrite; STATUS=TESTED; TEST=tests/test_graph_storage_adapter_metrics.zig; OWNER=perf; UPDATED=2026-04-25

const std = @import("std");
const geode = @import("geode");
const adapter_mod = geode.graph_storage_adapter;

// Zig 0.16 compat — std.time.nanoTimestamp / std.Thread.sleep were removed.
// Use clock_gettime + nanosleep directly (mirrors
// tests/test_handler_lock_hold_scope.zig:38-56 and
// tests/test_rwlock_fairness_under_load.zig:22-39).
fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

test "ManagedGraph: rwlock_shared_hold_ns_total accumulates from manual SHARED hold" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    var adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
        .data_dir = data_dir,
        .encryption_key = null,
    });
    defer adapter.deinit();
    const mg = try adapter.getOrCreateGraph("g_hold_time");

    // Sanity: a freshly-allocated graph has zero hold-time accumulated.
    try std.testing.expectEqual(@as(u64, 0), mg.rwlock_shared_hold_ns_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), mg.rwlock_shared_max_hold_ns_observed.load(.monotonic));

    const io = std.Io.Threaded.global_single_threaded.io();

    // Manually exercise the wrap pattern — this is what each acquire site in
    // production does, distilled to its essentials.
    mg.rwlock.lockSharedUncancelable(io);
    const _hold_start_ns: u64 = monoNanos();

    // Hold the lock for ~10 ms.
    sleepNs(10 * std.time.ns_per_ms);

    const _now_ns: u64 = monoNanos();
    const _hold_ns = _now_ns -| _hold_start_ns;
    _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
    const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
    if (_hold_ns > _cur_max) {
        mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
    }
    mg.rwlock.unlockShared(io);

    // Assert the counters reflect the hold.
    const total = mg.rwlock_shared_hold_ns_total.load(.monotonic);
    const max_obs = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);

    // 10 ms ± slack; nanosleep can return early or late by a few ms.
    // Floor at 5 ms; no upper bound (CI may be slow).
    try std.testing.expect(total >= 5 * std.time.ns_per_ms);
    try std.testing.expect(max_obs >= 5 * std.time.ns_per_ms);
    // Single hold, so total and max_observed must match.
    try std.testing.expectEqual(total, max_obs);
}

test "REQ-QUIC-HC-121: candidate shard mask is empty-aware and monotonic" {
    const empty = adapter_mod.candidateShardMaskForTest(&.{});
    try std.testing.expectEqual(@as(u64, 0), empty);

    const one = adapter_mod.candidateShardMaskForTest(&.{42});
    try std.testing.expect(one != 0);

    const repeated = adapter_mod.candidateShardMaskForTest(&.{ 42, 42, 42 });
    try std.testing.expectEqual(one, repeated);

    const expanded = adapter_mod.candidateShardMaskForTest(&.{ 42, 43, 44, 45 });
    try std.testing.expect((expanded & one) == one);
}
