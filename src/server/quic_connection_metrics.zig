// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Per-process aggregation of QUIC `Connection` state for the
//! runtime_metrics gauge surface. Reads are snapshot-time only —
//! these are gauges, not counters. Iteration over the active
//! connection list is read-only and short-lived.
//!
//! The vendored quic library at hash `c7808ed` (resolved as
//! `quic-0.1.11-gBIqUaSsNwA7iXj1KIrXsebs6BObfFf7Rf4geAhkZy2O`)
//! does NOT have separate `cc_nr` / `cc_cubic` fields as the spec
//! suggested. Instead the `Recovery` struct (`conn.rec`) carries a
//! single `cc: CcState` field plus a `use_cubic: bool` flag selecting
//! the algorithm in the update path. Both NewReno and CUBIC mutate
//! the same `cc.bytes_in_flight` / `cc.cwnd` fields, so a direct read
//! is correct regardless of which algorithm is active.
//!
//! Lock hygiene: each callback acquires `QuicTransport.connections_mutex`
//! (Tier-3 in CLAUDE.md's lock-ordering table) for the duration of the
//! iteration. The gauge callbacks are leaf operations — they do not
//! recurse into any other mutex — so the brief Tier-3 hold is hierarchy-
//! safe. Acquiring the mutex avoids the data race that the previous
//! "lock-free" implementation introduced: writers in `tryAccept`
//! (`connections.append`, which may reallocate the backing slice) and
//! `destroyConnection` (`swapRemove`) can otherwise produce a torn
//! `(.ptr, .len)` read or a use-after-free against the freed old buffer.
//! The same pattern is used by `QuicTransport.getConnectionCount` for
//! the trivial `.len` read.
//!
//! RTT semantics: the upstream `RttState` initialises `smoothed_rtt_ns`
//! to `333ms` (RFC 9002 §6.2 initial RTT) but reading it before the
//! first ACK lands surfaces an arbitrary value. Worse, in safe-mode
//! Zig builds, fields not yet written through the explicit init path
//! can carry the `0xAA` undefined-fill pattern (~1.23e19 ns). Both RTT
//! callbacks gate on `RttState.have_sample` so connections without an
//! RTT sample are excluded from the min/max accumulation; if no
//! connection has a sample, the callbacks return 0.
//!
//! Lifetime: `Ctx` must outlive the registry that holds the gauge
//! callbacks. The expected pattern (Task 4) is heap-allocate `Ctx`
//! in `main.zig`, register the gauges, and free `Ctx` only after
//! `Registry.deinit()` — both on the same `defer` chain.

const std = @import("std");
const quic_transport_mod = @import("transport/quic");

const QuicTransport = quic_transport_mod.QuicTransport;

/// Shared context for all six gauge callbacks. Holds a borrowed
/// (non-owning) pointer to the QUIC transport.
pub const Ctx = struct {
    transport: *QuicTransport,
};

/// Number of active QUIC connections. Acquires `connections_mutex`
/// (Tier-3) for the duration of the read; matches the locking pattern
/// used by `QuicTransport.getConnectionCount`.
pub fn activeConnections(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const io = std.Io.Threaded.global_single_threaded.io();
    ctx.transport.connections_mutex.lockUncancelable(io);
    defer ctx.transport.connections_mutex.unlock(io);
    return @intCast(ctx.transport.connections.items.len);
}

/// Sum of `rec.cc.bytes_in_flight` across all active connections (bytes).
/// Spikes here suggest the congestion window is full — packets cannot
/// be sent until ACKs free up credit. Acquires `connections_mutex`
/// (Tier-3) for the duration of the iteration.
pub fn totalBytesInFlight(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const io = std.Io.Threaded.global_single_threaded.io();
    ctx.transport.connections_mutex.lockUncancelable(io);
    defer ctx.transport.connections_mutex.unlock(io);
    var total: u64 = 0;
    for (ctx.transport.connections.items) |wrapper| {
        total += @intCast(wrapper.inner.rec.cc.bytes_in_flight);
    }
    return total;
}

/// Sum of `rec.cc.cwnd` across all active connections (bytes).
/// If the sum collapses while bytes_in_flight stays high, congestion
/// control is throttling — likely loss event. Acquires `connections_mutex`
/// (Tier-3) for the duration of the iteration.
pub fn totalCongestionWindow(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const io = std.Io.Threaded.global_single_threaded.io();
    ctx.transport.connections_mutex.lockUncancelable(io);
    defer ctx.transport.connections_mutex.unlock(io);
    var total: u64 = 0;
    for (ctx.transport.connections.items) |wrapper| {
        total += @intCast(wrapper.inner.rec.cc.cwnd);
    }
    return total;
}

/// Min smoothed RTT across active connections, in nanoseconds.
/// Returns 0 when no active connection has yet observed an RTT sample
/// (`RttState.have_sample == false`). A floor that climbs once samples
/// land means the network path itself is slowing. Acquires
/// `connections_mutex` (Tier-3) for the duration of the iteration.
pub fn minSmoothedRttNs(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const io = std.Io.Threaded.global_single_threaded.io();
    ctx.transport.connections_mutex.lockUncancelable(io);
    defer ctx.transport.connections_mutex.unlock(io);
    var min_val: u64 = std.math.maxInt(u64);
    var any: bool = false;
    for (ctx.transport.connections.items) |wrapper| {
        if (!wrapper.inner.rtt_app.have_sample) continue;
        const v = wrapper.inner.rtt_app.smoothed_rtt_ns;
        if (v < min_val) min_val = v;
        any = true;
    }
    return if (any) min_val else 0;
}

/// Max smoothed RTT across active connections, in nanoseconds.
/// Returns 0 when no active connection has yet observed an RTT sample
/// (`RttState.have_sample == false`). A spike here on one connection
/// once samples land means that connection is suffering disproportionately.
/// Acquires `connections_mutex` (Tier-3) for the duration of the iteration.
pub fn maxSmoothedRttNs(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const io = std.Io.Threaded.global_single_threaded.io();
    ctx.transport.connections_mutex.lockUncancelable(io);
    defer ctx.transport.connections_mutex.unlock(io);
    var max_val: u64 = 0;
    var any: bool = false;
    for (ctx.transport.connections.items) |wrapper| {
        if (!wrapper.inner.rtt_app.have_sample) continue;
        const v = wrapper.inner.rtt_app.smoothed_rtt_ns;
        if (v > max_val) max_val = v;
        any = true;
    }
    return if (any) max_val else 0;
}

/// Min flow-control headroom (peer_max_data − bytes_in_flight) across
/// connections, in bytes. Returns 0 when no active connections.
/// A floor of 0 with active connections means at least one connection
/// has saturated the receiver's advertised window — sender cannot send
/// more until peer issues a MAX_DATA frame. Acquires `connections_mutex`
/// (Tier-3) for the duration of the iteration.
pub fn minFlowControlHeadroom(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const io = std.Io.Threaded.global_single_threaded.io();
    ctx.transport.connections_mutex.lockUncancelable(io);
    defer ctx.transport.connections_mutex.unlock(io);
    var min_val: u64 = std.math.maxInt(u64);
    var any: bool = false;
    for (ctx.transport.connections.items) |wrapper| {
        const sent: u64 = @intCast(wrapper.inner.rec.cc.bytes_in_flight);
        const cap: u64 = wrapper.inner.peer_max_data;
        const headroom: u64 = if (cap > sent) cap - sent else 0;
        if (headroom < min_val) min_val = headroom;
        any = true;
    }
    return if (any) min_val else 0;
}
