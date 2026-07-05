// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Process-wide registry of active `BufferedProtoReader` instances
//! (#864 §10 — per-stream stall observability).
//!
//! Background: with the v0.6.3 stall watchdog we can detect when ALL
//! proto-reader counters freeze, but the qa-seed reproduction in
//! divelife-argo/docs/quic-deadlock.md §10 shows a different shape —
//! the process-wide counters keep moving (some streams ARE delivering
//! messages) while a SPECIFIC stream's handler is wedged.  The
//! process-wide idle gauge stays low because other streams cover for
//! the stuck one.
//!
//! This registry tracks each active reader as it enters the handler
//! loop and unregisters it on handler exit.  The watchdog walks the
//! registry every 5 s, computes `now - reader.last_activity_ns` for
//! each entry, and surfaces the max (oldest activity) as the
//! `quic_max_stream_idle_ns` gauge.  When the max exceeds the stall
//! threshold AND `quic_pending_stream_handlers > 0`, the watchdog logs
//! `ERR`-level details (stream id, peer addr, idle time) so operators
//! can correlate the stall with a specific in-flight request instead
//! of having to read all goroutine dumps by hand.
//!
//! Like the v0.6.3 process-wide watchdog this is observability-only:
//! a wedged handler may be mid-transaction, so the watchdog never
//! aborts a stuck stream.  Recovery remains pod restart.

const std = @import("std");

/// Public handle on a reader instance.  The registry stores opaque
/// pointers + a callback so it doesn't have to know about the full
/// `BufferedProtoReader` definition (which lives in
/// `quic_connection_handler.zig` and pulls in the whole server-side
/// graph).  Each `BufferedProtoReader` registers a handle pointing to
/// itself with `getActivityNs`/`getStreamId`/`getPeerAddr` callbacks.
pub const Handle = struct {
    /// Opaque pointer to the underlying reader allocation.
    self: *anyopaque,
    /// Reads the monotonic-clock timestamp of the reader's last
    /// `nextMessage` iteration.  Returns 0 if the reader hasn't
    /// recorded any activity yet.
    getActivityNs: *const fn (self: *anyopaque) u64,
    /// Returns the underlying QUIC stream id for diagnostic logging.
    getStreamId: *const fn (self: *anyopaque) u64,
    /// Returns the peer address string for diagnostic logging.  The
    /// pointer must remain valid until `unregister` is called.
    getPeerAddr: *const fn (self: *anyopaque) []const u8,
    /// GAP-ENT-0045: request cancellation of the reader's in-flight
    /// executor. Sets the reader's per-stream atomic cancel flag; the
    /// executor's scan/aggregate loops poll it at row/batch boundaries
    /// (read_budget.check()) and abort with SQLSTATE 57014. Optional so
    /// pre-existing handles keep compiling; null = cancellation not
    /// supported for this reader.
    requestCancel: ?*const fn (self: *anyopaque) void = null,
};

/// Snapshot of the slowest-progressing reader; returned by
/// `maxIdleNs()` so the watchdog can log a useful diagnostic.
pub const StallSnapshot = struct {
    idle_ns: u64,
    stream_id: u64,
    peer_addr: []const u8,
};

/// Process-wide registry of active proto readers.  Single instance
/// owned by the handler module's globals.  Locking discipline: a
/// single `std.Io.Mutex` guards all access.  The watchdog read path
/// holds the mutex while iterating; both `register` and `unregister`
/// hold it briefly.  All operations are O(n) in the registry size
/// (bounded by the configured global stream-thread cap), which is fine
/// for the 5 s watchdog cadence and the handler add/remove edges.
pub const Registry = struct {
    mu: std.Io.Mutex = std.Io.Mutex.init,
    entries: std.ArrayList(Handle) = std.ArrayList(Handle).empty,

    pub fn init() Registry {
        return .{};
    }

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.entries.deinit(gpa);
    }

    pub fn reserveCapacity(self: *Registry, gpa: std.mem.Allocator, capacity: usize) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        try self.entries.ensureTotalCapacity(gpa, capacity);
    }

    /// Add a reader to the registry.  Each registered reader must be
    /// unregistered before its underlying allocation is freed; the
    /// registry stores raw pointers and a dangling entry would crash
    /// the next watchdog walk.
    pub fn register(self: *Registry, gpa: std.mem.Allocator, handle: Handle) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        try self.entries.append(gpa, handle);
    }

    /// Remove a previously-registered reader.  Looks up by the
    /// `self` pointer; no-op if not found (defensive — duplicate
    /// unregisters are tolerated so handler shutdown paths can be
    /// idempotent).
    pub fn unregister(self: *Registry, handle_self: *anyopaque) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (self.entries.items[i].self == handle_self) {
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    /// Snapshot the oldest-activity reader.  Returns null if there are
    /// no active readers, or if no reader has yet recorded activity
    /// (last_activity_ns == 0).
    pub fn maxIdleNs(self: *Registry, now_ns: u64) ?StallSnapshot {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        var snap: ?StallSnapshot = null;
        for (self.entries.items) |entry| {
            const last = entry.getActivityNs(entry.self);
            if (last == 0) continue; // No activity recorded yet.
            const idle = if (now_ns > last) now_ns - last else 0;
            if (snap == null or idle > snap.?.idle_ns) {
                snap = .{
                    .idle_ns = idle,
                    .stream_id = entry.getStreamId(entry.self),
                    .peer_addr = entry.getPeerAddr(entry.self),
                };
            }
        }
        return snap;
    }

    /// GAP-0895: connection-aware stall detection. A single idle stream on
    /// an otherwise-live connection (the multiplexed control stream while
    /// bulk mutations flow on sibling streams) is NOT a stall. Group
    /// registered readers by connection — `peer_addr` is the QUIC 4-tuple,
    /// shared by every stream of one connection — and only return a
    /// snapshot when EVERY stream on a connection has been idle past
    /// `threshold_ns` (the whole connection is wedged, the genuinely
    /// actionable condition). Returns the oldest stream of the most-wedged
    /// fully-idle connection, or null if every connection has at least one
    /// stream active within the threshold. O(n^2) in registry size, which
    /// is bounded by the stream-thread cap and only walked at the 5 s
    /// watchdog cadence.
    pub fn connectionLevelStall(self: *Registry, now_ns: u64, threshold_ns: u64) ?StallSnapshot {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        var result: ?StallSnapshot = null;
        for (self.entries.items, 0..) |entry, i| {
            const last = entry.getActivityNs(entry.self);
            if (last == 0) continue; // never recorded activity => not stalled
            const idle = if (now_ns > last) now_ns - last else 0;
            if (idle < threshold_ns) continue; // this stream itself is active

            const peer = entry.getPeerAddr(entry.self);

            // Is ANY sibling on the same connection active within threshold?
            var sibling_active = false;
            for (self.entries.items, 0..) |other, j| {
                if (i == j) continue;
                if (!std.mem.eql(u8, other.getPeerAddr(other.self), peer)) continue;
                const o_last = other.getActivityNs(other.self);
                if (o_last == 0) { // freshly-opened sibling => connection alive
                    sibling_active = true;
                    break;
                }
                const o_idle = if (now_ns > o_last) now_ns - o_last else 0;
                if (o_idle < threshold_ns) {
                    sibling_active = true;
                    break;
                }
            }
            if (sibling_active) continue; // connection is alive — suppress

            if (result == null or idle > result.?.idle_ns) {
                result = .{
                    .idle_ns = idle,
                    .stream_id = entry.getStreamId(entry.self),
                    .peer_addr = peer,
                };
            }
        }
        return result;
    }

    /// GAP-ENT-0045: request cancellation of EVERY registered reader's
    /// in-flight executor. Used by the process-wide proto_reader stall
    /// watchdog ("all counters frozen + pending handlers"): every handler
    /// is wedged downstream of nextMessage, so abort them all instead of
    /// only logging "restart pod". Returns the number of readers whose
    /// cancel was requested (handles without a requestCancel callback are
    /// skipped and not counted).
    pub fn cancelAll(self: *Registry) usize {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        var n: usize = 0;
        for (self.entries.items) |entry| {
            const cb = entry.requestCancel orelse continue;
            cb(entry.self);
            n += 1;
        }
        return n;
    }

    /// GAP-ENT-0045: request cancellation of every reader on ONE connection
    /// (`peer` is the QUIC 4-tuple shared by that connection's multiplexed
    /// streams — the same grouping `connectionLevelStall` uses). Used by the
    /// per-connection stall watchdog: the whole connection is wedged / the
    /// client is gone, so its in-flight executors must stop, while executors
    /// on other connections are untouched. Returns the number of readers
    /// whose cancel was requested.
    pub fn cancelConnection(self: *Registry, peer: []const u8) usize {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        var n: usize = 0;
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.getPeerAddr(entry.self), peer)) continue;
            const cb = entry.requestCancel orelse continue;
            cb(entry.self);
            n += 1;
        }
        return n;
    }

    /// Current number of registered readers (== active handler threads
    /// currently inside the read loop).  Used by the metrics layer.
    pub fn count(self: *Registry) usize {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.entries.items.len;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Test double mimicking the per-reader state the registry walks.
const FakeReader = struct {
    activity: u64,
    stream_id: u64,
    peer: []const u8,
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn getActivity(ptr: *anyopaque) u64 {
        const self: *FakeReader = @ptrCast(@alignCast(ptr));
        return self.activity;
    }
    fn getStreamId(ptr: *anyopaque) u64 {
        const self: *FakeReader = @ptrCast(@alignCast(ptr));
        return self.stream_id;
    }
    fn getPeerAddr(ptr: *anyopaque) []const u8 {
        const self: *FakeReader = @ptrCast(@alignCast(ptr));
        return self.peer;
    }
    fn requestCancel(ptr: *anyopaque) void {
        const self: *FakeReader = @ptrCast(@alignCast(ptr));
        self.cancel_requested.store(true, .release);
    }

    fn handle(self: *FakeReader) Handle {
        return .{
            .self = @ptrCast(self),
            .getActivityNs = FakeReader.getActivity,
            .getStreamId = FakeReader.getStreamId,
            .getPeerAddr = FakeReader.getPeerAddr,
            .requestCancel = FakeReader.requestCancel,
        };
    }
};

test "Registry register/unregister round-trip" {
    var reg = Registry.init();
    defer reg.deinit(testing.allocator);

    var r = FakeReader{ .activity = 100, .stream_id = 42, .peer = "10.0.0.1" };
    try testing.expectEqual(@as(usize, 0), reg.count());

    try reg.register(testing.allocator, r.handle());
    try testing.expectEqual(@as(usize, 1), reg.count());

    reg.unregister(@ptrCast(&r));
    try testing.expectEqual(@as(usize, 0), reg.count());
}

test "Registry unregister is idempotent when entry missing" {
    var reg = Registry.init();
    defer reg.deinit(testing.allocator);

    var r = FakeReader{ .activity = 100, .stream_id = 42, .peer = "10.0.0.1" };
    // Never registered, but unregister must not panic / crash.
    reg.unregister(@ptrCast(&r));
    try testing.expectEqual(@as(usize, 0), reg.count());
}

test "Registry maxIdleNs returns the oldest reader's snapshot" {
    var reg = Registry.init();
    defer reg.deinit(testing.allocator);

    // Three readers at increasing activity timestamps; with now=1000
    // the OLDEST (smallest activity ts) has the largest idle.
    var fresh = FakeReader{ .activity = 900, .stream_id = 1, .peer = "fresh-peer" };
    var middle = FakeReader{ .activity = 500, .stream_id = 2, .peer = "middle-peer" };
    var stale = FakeReader{ .activity = 100, .stream_id = 3, .peer = "stale-peer" };

    try reg.register(testing.allocator, fresh.handle());
    try reg.register(testing.allocator, middle.handle());
    try reg.register(testing.allocator, stale.handle());

    const snap = reg.maxIdleNs(1000) orelse return error.NoSnapshot;
    try testing.expectEqual(@as(u64, 900), snap.idle_ns); // 1000 - 100
    try testing.expectEqual(@as(u64, 3), snap.stream_id);
    try testing.expectEqualStrings("stale-peer", snap.peer_addr);
}

test "Registry maxIdleNs returns null when no readers active" {
    var reg = Registry.init();
    defer reg.deinit(testing.allocator);

    try testing.expectEqual(@as(?StallSnapshot, null), reg.maxIdleNs(1000));
}

test "Registry maxIdleNs skips readers with no recorded activity" {
    var reg = Registry.init();
    defer reg.deinit(testing.allocator);

    // activity=0 means "never recorded any activity yet" — must be
    // treated as not-stalled (process just started).
    var blank = FakeReader{ .activity = 0, .stream_id = 1, .peer = "blank-peer" };
    try reg.register(testing.allocator, blank.handle());

    try testing.expectEqual(@as(?StallSnapshot, null), reg.maxIdleNs(1000));
}

test "GAP-0895: idle control stream on a live connection is NOT a stall" {
    var reg = Registry.init();
    defer reg.deinit(testing.allocator);

    // One multiplexed connection ("conn-A"):
    //   stream 0 = control stream, last activity at t=100 (idle 900 @ now=1000)
    //   stream 1 = data stream, last activity at t=950 (idle  50 @ now=1000)
    var ctrl = FakeReader{ .activity = 100, .stream_id = 0, .peer = "conn-A" };
    var data = FakeReader{ .activity = 950, .stream_id = 1, .peer = "conn-A" };
    try reg.register(testing.allocator, ctrl.handle());
    try reg.register(testing.allocator, data.handle());

    // The naive global-max watchdog WOULD have flagged the control stream.
    const naive = reg.maxIdleNs(1000) orelse return error.NoSnapshot;
    try testing.expect(naive.idle_ns >= 500);

    // Connection-aware watchdog suppresses it: a sibling is active.
    try testing.expectEqual(@as(?StallSnapshot, null), reg.connectionLevelStall(1000, 500));
}

test "GAP-ENT-0045: cancelAll sets every registered reader's cancel flag" {
    var reg = Registry.init();
    defer reg.deinit(testing.allocator);

    var a = FakeReader{ .activity = 100, .stream_id = 1, .peer = "conn-A" };
    var b = FakeReader{ .activity = 100, .stream_id = 2, .peer = "conn-B" };
    try reg.register(testing.allocator, a.handle());
    try reg.register(testing.allocator, b.handle());

    try testing.expectEqual(@as(usize, 2), reg.cancelAll());
    try testing.expect(a.cancel_requested.load(.acquire));
    try testing.expect(b.cancel_requested.load(.acquire));
}

test "GAP-ENT-0045: cancelConnection cancels only the wedged connection's readers" {
    var reg = Registry.init();
    defer reg.deinit(testing.allocator);

    var wedged0 = FakeReader{ .activity = 100, .stream_id = 0, .peer = "conn-W" };
    var wedged1 = FakeReader{ .activity = 120, .stream_id = 1, .peer = "conn-W" };
    var healthy = FakeReader{ .activity = 950, .stream_id = 7, .peer = "conn-H" };
    try reg.register(testing.allocator, wedged0.handle());
    try reg.register(testing.allocator, wedged1.handle());
    try reg.register(testing.allocator, healthy.handle());

    try testing.expectEqual(@as(usize, 2), reg.cancelConnection("conn-W"));
    try testing.expect(wedged0.cancel_requested.load(.acquire));
    try testing.expect(wedged1.cancel_requested.load(.acquire));
    try testing.expect(!healthy.cancel_requested.load(.acquire));
}

test "GAP-ENT-0045: handles without requestCancel are skipped, not counted" {
    var reg = Registry.init();
    defer reg.deinit(testing.allocator);

    var legacy = FakeReader{ .activity = 100, .stream_id = 3, .peer = "conn-L" };
    var no_cancel_handle = legacy.handle();
    no_cancel_handle.requestCancel = null; // pre-0045 handle shape
    try reg.register(testing.allocator, no_cancel_handle);

    try testing.expectEqual(@as(usize, 0), reg.cancelAll());
    try testing.expect(!legacy.cancel_requested.load(.acquire));
}

test "GAP-0895: a fully-wedged connection IS still reported" {
    var reg = Registry.init();
    defer reg.deinit(testing.allocator);

    // Every stream on conn-B idle past threshold => genuine connection stall.
    var s0 = FakeReader{ .activity = 100, .stream_id = 0, .peer = "conn-B" };
    var s1 = FakeReader{ .activity = 120, .stream_id = 1, .peer = "conn-B" };
    try reg.register(testing.allocator, s0.handle());
    try reg.register(testing.allocator, s1.handle());

    const snap = reg.connectionLevelStall(1000, 500) orelse return error.NoSnapshot;
    try testing.expect(snap.idle_ns >= 500);
    try testing.expectEqualStrings("conn-B", snap.peer_addr);
}
