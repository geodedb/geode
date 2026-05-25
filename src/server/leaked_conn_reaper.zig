// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Leaked-connection reaper (#864 / qa-seed deadlock §6.5).
//!
//! When `handleQuicConnection`'s owner side bails on the acceptor's exit
//! wait (`acceptor wait deadline exceeded; leaking conn to avoid UAF`),
//! it sets `destroy_conn = false` so the conn is intentionally NOT freed
//! — the acceptor task may still be dereferencing `conn` from inside
//! `tryAcceptStream`, and freeing under it would re-introduce the UAF
//! that motivated the heap-allocated `StreamAcceptorContext` + refcount
//! lifetime model in the first place.
//!
//! The previous behavior was to leak the conn entirely; the underlying
//! QUIC connection state is reclaimed only when the QUIC library's
//! protocol-level idle timeout fires (~300 s).  At the qa-seed
//! reproduction rate of multiple new connections per second, the leak
//! rate exceeded the reaper rate and `quic_active_connections` climbed
//! monotonically.
//!
//! This reaper restores eventual reclamation by:
//!   1. Capturing the leaked `{conn, ctx}` pair at the bail point with
//!      an extra `ctx` ref (via `StreamAcceptorContext.addRef`).
//!   2. Periodically polling `ctx.done` from a dedicated reaper thread.
//!   3. When `ctx.done == true` (the acceptor has exited and is no
//!      longer dereferencing `conn`), calling `transport.destroyConnection`
//!      and releasing the reaper's `ctx` ref.
//!
//! The reaper is purely additive: the bail path remains the safety
//! mechanism, the reaper just shortens the wait for cleanup from the
//! QUIC idle timeout (300 s) to the reaper interval (default 1 s).

const std = @import("std");
const quic_transport = @import("transport/quic");

const logging = @import("logging");
const log = logging.scoped("leaked_conn_reaper");
const Attr = logging.Attr;

/// Default interval (nanoseconds) between reaper passes.  1 s is well
/// under the QUIC idle timeout (300 s) so the reaper materially
/// improves recovery, while being long enough that the load of walking
/// the registry is negligible.
pub const default_interval_ns: u64 = 1 * std.time.ns_per_s;

/// Opaque-to-the-reaper interface to `StreamAcceptorContext`.  Defined as
/// a trait-like vtable so the registry can be exercised in unit tests
/// without pulling in the full handler module (and its transitive deps).
pub const CtxHandle = struct {
    /// Opaque pointer to the underlying ctx allocation.
    self: *anyopaque,
    /// Returns true once the acceptor has stopped dereferencing `conn`.
    is_done: *const fn (ctx: *anyopaque) bool,
    /// Releases the reaper's extra ref.  Must be safe to call from the
    /// reaper thread.
    release: *const fn (ctx: *anyopaque) void,
};

pub const Entry = struct {
    transport: *quic_transport.QuicTransport,
    conn: *quic_transport.QuicConnection,
    ctx: CtxHandle,
    /// Monotonic timestamp (ns) at which the entry was registered;
    /// surfaced as `quic_leaked_connection_age_ns_max` for operator
    /// alerting on slow reapers.
    registered_ns: u64,
};

/// Process-wide leaked-connection registry + reaper.  Single instance
/// owned by `main.zig`.  Public methods are thread-safe; internal access
/// is gated by a single mutex.
pub const LeakedConnRegistry = struct {
    mu: std.Io.Mutex = std.Io.Mutex.init,
    entries: std.ArrayList(Entry) = std.ArrayList(Entry).empty,
    /// Lifetime stats — monotonic counters surfaced as gauges.
    reaped_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    registered_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Shutdown flag toggled by main.zig at process exit so the reaper
    /// thread joins cleanly.
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init() LeakedConnRegistry {
        return .{};
    }

    pub fn deinit(self: *LeakedConnRegistry, gpa: std.mem.Allocator) void {
        // Final pass: any entry left here is one whose acceptor still
        // hasn't exited.  Drop our extra ref so the ctx is freed once
        // the acceptor eventually releases its ref; we cannot safely
        // destroyConnection because is_done==false.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        for (self.entries.items) |entry| {
            entry.ctx.release(entry.ctx.self);
        }
        self.entries.deinit(gpa);
    }

    /// Register a leaked conn for eventual reaping.  Caller must already
    /// have bumped the ctx refcount with `addRef` (or equivalent) so the
    /// reaper holds its own ref.
    pub fn register(
        self: *LeakedConnRegistry,
        gpa: std.mem.Allocator,
        transport: *quic_transport.QuicTransport,
        conn: *quic_transport.QuicConnection,
        ctx: CtxHandle,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        try self.entries.append(gpa, .{
            .transport = transport,
            .conn = conn,
            .ctx = ctx,
            .registered_ns = monoNs(),
        });
        _ = self.registered_total.fetchAdd(1, .monotonic);
    }

    /// Walk the registry and destroy any conn whose acceptor has exited.
    /// Returns the number of conns reaped in this pass.  Safe to call
    /// from any thread.
    pub fn reapOnce(self: *LeakedConnRegistry, gpa: std.mem.Allocator) usize {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        // Walk in reverse so swapRemove is safe across the iteration.
        var i: usize = self.entries.items.len;
        var reaped: usize = 0;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            if (entry.ctx.is_done(entry.ctx.self)) {
                // Acceptor has stopped dereferencing conn; safe to free.
                entry.transport.destroyConnection(entry.conn);
                entry.ctx.release(entry.ctx.self);
                _ = self.entries.swapRemove(i);
                reaped += 1;
            }
        }
        _ = self.entries.toOwnedSlice(gpa) catch {}; // ensure capacity matches
        if (reaped > 0) {
            _ = self.reaped_total.fetchAdd(reaped, .monotonic);
            log.debug("reaped leaked connections", &.{Attr.int("count", @intCast(reaped))});
        }
        return reaped;
    }

    /// Current number of leaked conns awaiting reaping.
    pub fn pendingCount(self: *LeakedConnRegistry) usize {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.entries.items.len;
    }

    /// Cumulative count of conns successfully reaped.  Surfaced as the
    /// `quic_leaked_connections_reaped_total` gauge.
    pub fn reapedTotal(self: *const LeakedConnRegistry) u64 {
        return self.reaped_total.load(.monotonic);
    }

    /// Cumulative count of conns that were ever registered as leaked.
    /// Surfaced as `quic_leaked_connections_registered_total`.
    pub fn registeredTotal(self: *const LeakedConnRegistry) u64 {
        return self.registered_total.load(.monotonic);
    }
};

/// Reaper thread entry point.  Loops until `registry.shutdown == true`
/// calling `reapOnce` every `interval_ns`.
pub const ReaperArgs = struct {
    registry: *LeakedConnRegistry,
    gpa: std.mem.Allocator,
    interval_ns: u64 = default_interval_ns,
};

pub fn reaperLoop(args: *ReaperArgs) void {
    while (!args.registry.shutdown.load(.acquire)) {
        _ = args.registry.reapOnce(args.gpa);
        const req = std.os.linux.timespec{
            .sec = @intCast(args.interval_ns / std.time.ns_per_s),
            .nsec = @intCast(args.interval_ns % std.time.ns_per_s),
        };
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.nanosleep(&req, &rem);
    }
    // Final pass on shutdown.
    _ = args.registry.reapOnce(args.gpa);
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

/// Test double used to exercise the registry without dragging in the full
/// `StreamAcceptorContext`.  `done` mimics the atomic flag the acceptor
/// sets when it exits; `refcount` mimics the refcount that `release`
/// decrements.
const TestCtx = struct {
    done: bool = false,
    refs: i32 = 1,

    fn isDone(ptr: *anyopaque) bool {
        const self: *TestCtx = @ptrCast(@alignCast(ptr));
        return self.done;
    }

    fn release(ptr: *anyopaque) void {
        const self: *TestCtx = @ptrCast(@alignCast(ptr));
        self.refs -= 1;
    }

    fn handle(self: *TestCtx) CtxHandle {
        return .{
            .self = @ptrCast(self),
            .is_done = TestCtx.isDone,
            .release = TestCtx.release,
        };
    }
};

test "LeakedConnRegistry reap skips entries whose acceptor still runs" {
    var reg = LeakedConnRegistry.init();
    defer reg.deinit(testing.allocator);

    var ctx = TestCtx{ .done = false, .refs = 1 };
    // We don't actually call destroyConnection in the registry path
    // here because is_done returns false — the test exits before any
    // transport pointer is dereferenced.
    const dummy_transport: *quic_transport.QuicTransport = undefined;
    const dummy_conn: *quic_transport.QuicConnection = undefined;
    try reg.register(testing.allocator, dummy_transport, dummy_conn, ctx.handle());

    try testing.expectEqual(@as(usize, 1), reg.pendingCount());
    try testing.expectEqual(@as(usize, 0), reg.reapOnce(testing.allocator));
    try testing.expectEqual(@as(usize, 1), reg.pendingCount());
    try testing.expectEqual(@as(u64, 0), reg.reapedTotal());
    try testing.expectEqual(@as(u64, 1), reg.registeredTotal());

    // Cleanup: pretend the acceptor has now exited so deinit doesn't
    // leave the test ctx with a dangling ref expectation.
    ctx.done = true;
}

test "LeakedConnRegistry counters monotonic across multiple registers" {
    var reg = LeakedConnRegistry.init();
    defer reg.deinit(testing.allocator);

    var ctx1 = TestCtx{ .done = false, .refs = 1 };
    var ctx2 = TestCtx{ .done = false, .refs = 1 };
    const dummy_transport: *quic_transport.QuicTransport = undefined;
    const dummy_conn: *quic_transport.QuicConnection = undefined;

    try reg.register(testing.allocator, dummy_transport, dummy_conn, ctx1.handle());
    try reg.register(testing.allocator, dummy_transport, dummy_conn, ctx2.handle());
    try testing.expectEqual(@as(u64, 2), reg.registeredTotal());
    try testing.expectEqual(@as(usize, 2), reg.pendingCount());
}
