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
const quic_connection_handler = @import("quic_connection_handler.zig");
const proto_reader_metrics = @import("buffered_proto_reader_metrics.zig");

const QuicTransport = quic_transport_mod.QuicTransport;

/// Shared context for all gauge callbacks. Holds a borrowed
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

/// Number of stream-handler OS threads currently in flight across all
/// QUIC connections (i.e. the saturation level of the global stream
/// throttle). Operators should watch this against `maxStreamHandlers`
/// — when it sustains near max, the pollLoop is at risk of saturation
/// and clients should expect admission backpressure (#864 / divelife-argo
/// qaseed deadlock investigation §6.3).
///
/// Reads an atomic counter; no transport-level lock required. The
/// `ctx_ptr` parameter is unused but the runtime-metrics registry
/// requires the callback signature `fn(*anyopaque) u64`.
pub fn pendingStreamHandlers(ctx_ptr: *anyopaque) u64 {
    _ = ctx_ptr;
    return @intCast(quic_connection_handler.getGlobalStreamThreadCount());
}

/// Configured maximum number of concurrent stream-handler threads. Used
/// as the divisor for `quic_pending_stream_handlers` to produce a
/// saturation ratio in dashboards. Returns the current throttle cap
/// (changes on `setMaxGlobalStreamThreads`).
pub fn maxStreamHandlers(ctx_ptr: *anyopaque) u64 {
    _ = ctx_ptr;
    return @intCast(quic_connection_handler.getMaxGlobalStreamThreads());
}

/// Cumulative count of peer-initiated streams rejected because the global
/// stream-handler throttle was saturated when the 10ms admission wait
/// elapsed (#864 / qa-seed deadlock §6.4).  Monotonic counter exposed
/// through the gauge surface; dashboards should compute the rate.
pub fn streamAdmissionRejectionsTotal(ctx_ptr: *anyopaque) u64 {
    _ = ctx_ptr;
    return quic_connection_handler.getStreamAdmissionRejectionsTotal();
}

/// Maximum observed pollLoop cycle latency in nanoseconds since process
/// start (#864 / qa-seed deadlock §6.6).  Alerting threshold: 2 ms (the
/// handler waitForPoll budget).  Sustained values above 2 ms indicate
/// pollLoop saturation and predict handler-side WouldBlock spinning.
pub fn pollCycleMaxNs(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    return ctx.transport.getPollCycleMaxNs();
}

/// Cumulative count of pollLoop cycles whose `poll(0)` exceeded the 2 ms
/// handler waitForPoll timeout (#864 §6.6).  Each overrun means at least
/// one handler missed that cycle's broadcast and re-entered its
/// WouldBlock loop — directly correlates with
/// `proto_reader_would_block_loop_iterations_total` ramp-up.
pub fn pollOverrunTotal(ctx_ptr: *anyopaque) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    return ctx.transport.getPollOverrunTotal();
}

/// Current number of conns parked in the leaked-connection registry
/// awaiting reaping (#864 / qa-seed deadlock §6.5).  Sustained non-zero
/// values mean acceptors are stuck past their exit deadline; the reaper
/// will reclaim them on each pass.
pub fn leakedConnectionsPending(ctx_ptr: *anyopaque) u64 {
    _ = ctx_ptr;
    if (quic_connection_handler.getLeakedConnRegistry()) |reg| {
        return @intCast(reg.pendingCount());
    }
    return 0;
}

/// Cumulative count of conns successfully reaped by the leaked-conn
/// reaper since process start (#864 §6.5).  Monotonic; rate equals the
/// rate of acceptor exit-deadline bails.
pub fn leakedConnectionsReapedTotal(ctx_ptr: *anyopaque) u64 {
    _ = ctx_ptr;
    if (quic_connection_handler.getLeakedConnRegistry()) |reg| {
        return reg.reapedTotal();
    }
    return 0;
}

/// Cumulative count of conns ever registered as leaked (#864 §6.5).
/// Used with `quic_leaked_connections_reaped_total` to compute the
/// in-flight leak count (`registered - reaped == pending`).
pub fn leakedConnectionsRegisteredTotal(ctx_ptr: *anyopaque) u64 {
    _ = ctx_ptr;
    if (quic_connection_handler.getLeakedConnRegistry()) |reg| {
        return reg.registeredTotal();
    }
    return 0;
}

/// Nanoseconds since the most recent increment of any
/// `proto_reader_*_total` counter (#864 frozen-counter observability).
/// Sustained high values WITH `quic_pending_stream_handlers > 0` mean
/// handlers are wedged downstream of `BufferedProtoReader.nextMessage`
/// — query execution, storage locks, or response send.  Returns 0
/// when no activity has ever been recorded (process start).
pub fn protoReaderIdleNs(ctx_ptr: *anyopaque) u64 {
    _ = ctx_ptr;
    return proto_reader_metrics.getIdleNs();
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
