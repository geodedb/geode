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
//! Lock hygiene: the callbacks deliberately do NOT acquire
//! `QuicTransport.connections_mutex`. A stale `.len` or pointer read
//! is acceptable for an emit-time gauge and avoids deadlock risk
//! against the registry's own mutex during snapshotting. The QUIC
//! handler/poll threads append to the list under the mutex; iteration
//! here may briefly observe a torn `.len` but will never escape the
//! current `items.len` bound at iteration start.
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

/// Number of active QUIC connections.
pub fn activeConnections(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    return @intCast(ctx.transport.connections.items.len);
}

/// Sum of `rec.cc.bytes_in_flight` across all active connections (bytes).
/// Spikes here suggest the congestion window is full — packets cannot
/// be sent until ACKs free up credit.
pub fn totalBytesInFlight(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    var total: u64 = 0;
    for (ctx.transport.connections.items) |wrapper| {
        total += @intCast(wrapper.inner.rec.cc.bytes_in_flight);
    }
    return total;
}

/// Sum of `rec.cc.cwnd` across all active connections (bytes).
/// If the sum collapses while bytes_in_flight stays high, congestion
/// control is throttling — likely loss event.
pub fn totalCongestionWindow(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    var total: u64 = 0;
    for (ctx.transport.connections.items) |wrapper| {
        total += @intCast(wrapper.inner.rec.cc.cwnd);
    }
    return total;
}

/// Min smoothed RTT across active connections, in nanoseconds.
/// Returns 0 when no active connections. A floor that climbs means
/// the network path itself is slowing.
pub fn minSmoothedRttNs(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    var min_val: u64 = std.math.maxInt(u64);
    var any: bool = false;
    for (ctx.transport.connections.items) |wrapper| {
        const v = wrapper.inner.rtt_app.smoothed_rtt_ns;
        if (v < min_val) min_val = v;
        any = true;
    }
    return if (any) min_val else 0;
}

/// Max smoothed RTT across active connections, in nanoseconds.
/// A spike here on one connection means that connection is suffering
/// disproportionately.
pub fn maxSmoothedRttNs(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    var max_val: u64 = 0;
    for (ctx.transport.connections.items) |wrapper| {
        const v = wrapper.inner.rtt_app.smoothed_rtt_ns;
        if (v > max_val) max_val = v;
    }
    return max_val;
}

/// Min flow-control headroom (peer_max_data − bytes_in_flight) across
/// connections, in bytes. Returns 0 when no active connections.
/// A floor of 0 with active connections means at least one connection
/// has saturated the receiver's advertised window — sender cannot send
/// more until peer issues a MAX_DATA frame.
pub fn minFlowControlHeadroom(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
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
