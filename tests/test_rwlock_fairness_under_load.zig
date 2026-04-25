// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Regression test pinning fairness on `mg.rwlock` under sustained
//! 16-way SHARED contention. Pre-fix, EXCLUSIVE acquirers were
//! starved indefinitely; post-fix, they complete in well under 30 s
//! via the writer-preferred slow path.

// CANARY: REQ=REQ-PERF-RWLOCK-FAIRNESS-001; FEATURE="MgRwLockFairness"; ASPECT=ExclusiveAcquireUnderLoad; STATUS=TESTED; TEST=tests/test_rwlock_fairness_under_load.zig; OWNER=perf; UPDATED=2026-04-25

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;

const SharedHolderCtx = struct {
    mg: *adapter_mod.ManagedGraph,
    stop: *std.atomic.Value(u32),
};

// Zig 0.16 compat — see tests/test_graph_write_lock_cancelable.zig:44-51.
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

fn sharedHolder(ctx_ptr: *anyopaque) void {
    const ctx: *SharedHolderCtx = @ptrCast(@alignCast(ctx_ptr));
    const io = std.Io.Threaded.global_single_threaded.io();
    while (ctx.stop.load(.acquire) == 0) {
        ctx.mg.rwlock.lockSharedUncancelable(io);
        sleepNs(1_000_000); // 1ms
        ctx.mg.rwlock.unlockShared(io);
    }
}

test "EXCLUSIVE acquire completes within 30s under 16-way SHARED contention" {
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
    const mg = try adapter.getOrCreateGraph("g_fairness");

    var stop = std.atomic.Value(u32).init(0);
    var ctxs: [16]SharedHolderCtx = undefined;
    var threads: [16]std.Thread = undefined;
    for (&ctxs, &threads) |*c, *t| {
        c.* = .{ .mg = mg, .stop = &stop };
        t.* = try std.Thread.spawn(.{}, sharedHolder, .{@as(*anyopaque, @ptrCast(c))});
    }

    // Give the holders a chance to ramp up.
    sleepNs(1 * std.time.ns_per_s);

    // Now try to acquire EXCLUSIVE via the writer-preferred path.
    const start_ns = monoNanos();
    const deadline = start_ns + 120 * std.time.ns_per_s;
    const handle = try graph_store.acquireGraphWriteLockCancelable("g_fairness", deadline);
    const acquired_ns = monoNanos();
    const wait_ns: u64 = acquired_ns - start_ns;

    graph_store.releaseGraphLock(handle);
    stop.store(1, .release);
    for (threads) |t| t.join();

    const max_wait_ns: u64 = 30 * std.time.ns_per_s;
    if (wait_ns > max_wait_ns) {
        std.debug.print("EXCLUSIVE acquire took {d} ns (= {d:.1} s) — expected < 30 s\n", .{ wait_ns, @as(f64, @floatFromInt(wait_ns)) / 1e9 });
    }
    try std.testing.expect(wait_ns < max_wait_ns);
}
