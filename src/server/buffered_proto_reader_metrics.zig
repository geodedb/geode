// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Process-wide counters for `BufferedProtoReader.nextMessage` —
//! the server's single read-side QUIC entry point. These are
//! monotonic-increment counters (not gauges); deltas between
//! periodic emits give the per-interval rate.
//!
//! #864 / qa-seed deadlock observability:
//! `last_activity_ns` is a monotonic-clock timestamp updated on every
//! counter increment.  `getIdleNs()` derives `now - last_activity_ns`
//! to surface "no reader is making progress" as a single gauge
//! (`proto_reader_idle_ns`).  Sustained high values WITH non-zero
//! `quic_pending_stream_handlers` mean handlers are wedged downstream
//! of `nextMessage` (e.g. query execution, storage locks, response
//! send) — a different failure mode from the would-block ramp-up
//! addressed by the v0.6.2 stream-admission work.  The stall watchdog
//! in main.zig polls this every 5 s and emits a critical log line when
//! the threshold is exceeded so operators get a deterministic alert
//! signal instead of having to infer the stall from frozen counters.

const std = @import("std");

pub var messages_delivered_total = std.atomic.Value(u64).init(0);
pub var would_block_loop_iterations_total = std.atomic.Value(u64).init(0);
pub var bytes_read_total = std.atomic.Value(u64).init(0);
pub var eof_total = std.atomic.Value(u64).init(0);

/// Monotonic-clock timestamp (ns) of the most recent counter
/// increment across any of the four proto_reader counters.  Updated by
/// `recordActivity()` on every increment site in
/// `BufferedProtoReader.nextMessage`.  Zero means "no activity has ever
/// happened" (process just started); the watchdog treats that as
/// non-stalled.
pub var last_activity_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Snapshot the monotonic clock and publish it as the most recent
/// activity timestamp.  Wait-free: a single release store from any
/// number of handler threads.  Called from
/// `BufferedProtoReader.nextMessage` after every counter increment.
pub fn recordActivity() void {
    last_activity_ns.store(monoNs(), .release);
}

/// Nanoseconds since the most recent counter increment.  Returns 0 if
/// no activity has ever been recorded (process just started); callers
/// must treat 0 as "not stalled" rather than "stalled for the whole
/// process lifetime".
pub fn getIdleNs() u64 {
    const last = last_activity_ns.load(.acquire);
    if (last == 0) return 0;
    const now = monoNs();
    return if (now > last) now - last else 0;
}

/// GAP-0896: compact one-line metrics summary emitted at `info` every
/// watchdog tick, replacing the ~100-field full registry dump (which is
/// gated behind GEODE_METRICS_LOG_FULL and the metrics endpoint).
pub const CompactSummary = struct {
    delivered_delta: u64,
    delivered_total: u64,
    active_streams: usize,
    proto_idle_ms: u64,
};

pub fn appendCompactSummary(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    s: CompactSummary,
) !void {
    try buf.print(gpa, "msgs_delivered+={d} total={d} active_streams={d} proto_idle_ms={d}", .{
        s.delivered_delta,
        s.delivered_total,
        s.active_streams,
        s.proto_idle_ms,
    });
}

/// Called from main.zig after the registry is created.
pub fn registerAll(registry: anytype) !void {
    try registry.register("proto_reader_messages_delivered_total", &messages_delivered_total);
    try registry.register("proto_reader_would_block_loop_iterations_total", &would_block_loop_iterations_total);
    try registry.register("proto_reader_bytes_read_total", &bytes_read_total);
    try registry.register("proto_reader_eof_total", &eof_total);
}

fn monoNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "recordActivity advances last_activity_ns" {
    // Reset to a known state so the test is independent of process history.
    last_activity_ns.store(0, .release);
    try testing.expectEqual(@as(u64, 0), getIdleNs());

    recordActivity();
    const after_first = last_activity_ns.load(.acquire);
    try testing.expect(after_first != 0);

    // A short sleep, then another tick, must strictly advance the
    // timestamp.  Using 1ms is well above the monotonic clock granularity.
    const req = std.os.linux.timespec{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);

    recordActivity();
    const after_second = last_activity_ns.load(.acquire);
    try testing.expect(after_second > after_first);

    // Cleanup: leave the counter zeroed so the next test starts clean.
    last_activity_ns.store(0, .release);
}

test "getIdleNs grows when no activity is recorded" {
    last_activity_ns.store(0, .release);
    recordActivity();

    const req = std.os.linux.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);

    const idle = getIdleNs();
    // At least 5 ms must have elapsed since recordActivity().
    try testing.expect(idle >= 5 * std.time.ns_per_ms);

    last_activity_ns.store(0, .release);
}

test "getIdleNs returns 0 when no activity has ever been recorded" {
    last_activity_ns.store(0, .release);
    try testing.expectEqual(@as(u64, 0), getIdleNs());
}

test "appendCompactSummary formats a single compact line" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendCompactSummary(testing.allocator, &buf, .{
        .delivered_delta = 1200,
        .delivered_total = 348000,
        .active_streams = 7,
        .proto_idle_ms = 42,
    });
    try testing.expect(std.mem.indexOf(u8, buf.items, "msgs_delivered+=1200") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "active_streams=7") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "proto_idle_ms=42") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\n") == null);
}
