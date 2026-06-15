const std = @import("std");

// Zig 0.16 compat: std.Thread.sleep was removed; use raw linux nanosleep.
fn compat_sleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

/// Monotonic clock reader in nanoseconds, used for poll-loop cycle latency
/// instrumentation (§6.6).  Returns 0 on syscall failure rather than
/// propagating an error — the metric is observability-only and a missed
/// sample is preferable to crashing the poll thread.
fn monoNsRaw() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

// VENDOR QUIC MIGRATION COMPLETE - 2025-11-20
// This module now uses the vendor/quic library's native Endpoint API
// Following the pattern from vendor/quic/echo_quic_server.zig
//
// Updated 2026-02: Endpoint stored as heap pointer (api.endpointInit/endpointDeinit),
// PollSync uses mutex+condvar instead of atomic spin-loops, QuicConfig heap-allocated
// to ensure cert/key DER lifetime, quic_connection nullable field on QuicConnection.

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICCore; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICCore; OWNER=wire; UPDATED=2025-11-21

const logging = @import("logging");
const tlog = logging.scoped("transport");
const Attr = logging.Attr;
const quic_response_metrics = @import("quic_response_metrics");

// DNS resolution for hostnames that the vendor QUIC library cannot resolve.
const dns = @import("dns");
// GAP-0838 (Bug A): resolv.conf `search`-domain + `ndots` aware expansion.
const dns_search = @import("dns_search");

// Import the QUIC modules through the vendor API which re-exports them
const api = @import("vendor_quic");
const Endpoint = api.QuicEndpoint;
const Connection = api.QuicConnection;
const VendorQuicConfig = api.QuicConfig;
const builtin = @import("builtin");

/// Allocation-free, Io-independent readability check for a cert/key file.
/// Mirrors `cert_gen.certFileReadable`: it attempts a raw `openat` and lets the
/// result be authoritative, deliberately avoiding `std.Io.Dir.access` over the
/// `.failing` global_single_threaded Io (which was environment-sensitive as a
/// container entrypoint). See
/// docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md.
fn certPathReadable(path: []const u8) bool {
    if (comptime builtin.os.tag == .linux) {
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
        defer _ = std.os.linux.close(fd);
        return true;
    }
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

pub const QuicInnerConnection = Connection;
pub const QuicReadReadyFn = *const fn (ctx: *anyopaque, c: *QuicInnerConnection) void;

// Re-export core types
pub const QuicError = error{
    InitFailed,
    ConnectionFailed,
    StreamFailed,
    WriteError,
    ReadError,
    CertificateError,
    HandshakeError,
    Timeout,
    WouldBlock,
    Closed,
    InvalidState,
};

// Module-level pointer set by listen() so the OTel gauge callback can read
// the current connection count without holding a reference to the transport.
// Single-writer (listen() runs once at startup), multiple readers (gauge callback).
var g_quic_transport_instance: ?*QuicTransport = null;

fn activeConnectionCountProvider() i64 {
    if (g_quic_transport_instance) |t| return @intCast(t.getConnectionCount());
    return 0;
}

inline fn debugLog(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}

/// Readers-writer synchronization for QUIC endpoint poll() vs handler I/O.
///
/// The vendored QUIC library's `ep.poll()` processes frames for ALL connections,
/// updating their internal HashMaps (`stream_txs`, etc.). Handler threads
/// concurrently call `readStream()`/`writeStream()` on the same connections.
/// Without synchronization, concurrent HashMap access causes SIGABRT.
///
/// This implements a readers-writer pattern:
/// - Handler threads are "readers" (can do I/O concurrently with each other)
/// - The main thread is the "writer" (needs exclusive access for poll())
///
/// GAP-0277: Each wait-point has its own condition variable so signal() is
/// correct and broadcast() is unnecessary. This eliminates the fragile
/// requirement that broadcast() must be used to avoid cross-wakeup stalls.
///
/// QUIC-HC-001: `waitForPoll` uses a futex-backed generation counter instead
/// of Zig 0.16's earlier nanosleep fallback. Handler waiters now park on
/// `poll_generation` and wake as soon as the poll loop advances delivery,
/// avoiding a fixed timeout floor per WouldBlock tick under high stream
/// fan-out.
pub const PollSync = struct {
    mu: std.Io.Mutex = std.Io.Mutex.init,
    /// Wakes handler threads blocked in enterIo (waiting for poll to finish).
    io_cv: std.Io.Condition = std.Io.Condition.init,
    /// Wakes the poll thread blocked in enterPoll (waiting for I/O to drain).
    drain_cv: std.Io.Condition = std.Io.Condition.init,
    poll_requested: bool = false,
    active_io_count: u32 = 0,
    poll_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // CANARY: REQ=REQ-QUIC-HC-036; FEATURE="QUIC High-Concurrency Requests"; ASPECT=BoundedPollWakeFanout; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
    // Waking every stream reader after every packet-bearing poll cycle creates
    // a thundering herd under 100s of connections. A bounded futex wake lets
    // active streams make progress without burning the poll thread's CPU slice
    // on readers whose connection did not receive data in that cycle.
    // Do not pair this with a Condition.broadcast(); poll_generation is the
    // stream-reader wait path, and broadcasting reintroduces the wake storm.
    const poll_wake_batch_size: u32 = 256;

    /// Called by handler threads before I/O. Blocks until safe to proceed.
    pub fn enterIo(self: *PollSync) void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        while (self.poll_requested) {
            self.io_cv.waitUncancelable(std.Io.Threaded.global_single_threaded.io(), &self.mu);
        }
        self.active_io_count += 1;
    }

    /// Called by handler threads after I/O.
    pub fn leaveIo(self: *PollSync) void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        if (self.active_io_count > 0) self.active_io_count -= 1;
        // signal() is safe: only the poll thread waits on drain_cv.
        if (self.active_io_count == 0) self.drain_cv.signal(std.Io.Threaded.global_single_threaded.io());
    }

    /// Called by the main thread before poll(). Blocks until all I/O finishes.
    pub fn enterPoll(self: *PollSync) void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        self.poll_requested = true;
        while (self.active_io_count > 0) {
            self.drain_cv.waitUncancelable(std.Io.Threaded.global_single_threaded.io(), &self.mu);
        }
    }

    /// Called by the main thread after poll().
    pub fn leavePoll(self: *PollSync) void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        self.poll_requested = false;
        self.io_cv.broadcast(std.Io.Threaded.global_single_threaded.io()); // Wake all handlers waiting to enter I/O
        self.notifyPoll();
    }

    /// Handler threads call this instead of blind Thread.sleep().
    pub fn waitForPoll(self: *PollSync, timeout_ns: u64) void {
        if (timeout_ns == 0) return;

        const io = std.Io.Threaded.global_single_threaded.io();
        const observed = self.poll_generation.load(.acquire);
        const start_ns = monoNsRaw();
        var remaining_ns = timeout_ns;

        while (true) {
            const current = self.poll_generation.load(.acquire);
            if (current != observed) return;

            const timeout: std.Io.Timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(@intCast(remaining_ns)),
                .clock = .awake,
            } };
            io.futexWaitTimeout(u32, &self.poll_generation.raw, current, timeout) catch |err| switch (err) {
                error.Canceled => return,
            };

            if (self.poll_generation.load(.acquire) != observed) return;
            const elapsed_ns = monoNsRaw() -| start_ns;
            if (elapsed_ns >= timeout_ns) return;
            remaining_ns = timeout_ns - elapsed_ns;
        }
    }

    /// Advance the poll generation and wake a bounded batch of stream readers
    /// parked in `waitForPoll`.  This is called after every endpoint poll cycle that may
    /// have delivered packets into connection stream buffers.
    pub fn notifyPoll(self: *PollSync) void {
        _ = self.poll_generation.fetchAdd(1, .release);
        const io = std.Io.Threaded.global_single_threaded.io();
        io.futexWake(u32, &self.poll_generation.raw, poll_wake_batch_size);
    }
};

/// The canonical default QUIC server port for Geode.
/// All server and client code should reference this constant rather than hard-coding 3141 or 7567.
pub const DEFAULT_PORT: u16 = 3141;

// CANARY: REQ=REQ-QUIC-HC-025; FEATURE="QUIC High-Concurrency Reads"; ASPECT=ServerReadBackoff; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-26
//
// Server stream handlers park on PollSync after a WouldBlock. notifyPoll()
// wakes them as soon as endpoint polling delivers packets, so this value is
// only the lost-wake/idle fallback. Keeping it well above the poll-loop
// hot-path cadence prevents 100s of idle handlers from hammering
// per-connection locks and starving endpoint polling under high fan-out.
pub const server_handler_wait_for_poll_ns: u64 = 100 * std.time.ns_per_ms;

// 2026-06-08 idle-CPU fix: poll-loop park duration when there are ZERO live
// connections. The fast 500us active floor (below, in pollLoop) exists for
// low-latency packet processing on LIVE connections; with no connections at all
// nothing arrives on the poll path — new-connection Initials are serviced by the
// accept loop on its own cadence — so the poll workers can park far longer. This
// is the fix for the idle node burning ~810% CPU: 16 release poll workers each
// spin pollOnce(0)+500us, and each pollOnce(0) is NOT cheap — under ReleaseSafe
// (what prod ships) endpoint.pollWithStats stack-declares a 64×4096 = 256 KB
// recv batch buffer `= undefined`, which the safety machinery 0xAA-fills on
// EVERY call. So idle poll cost is dominated by that per-call fill, not the
// syscall. 250ms => ~4 wakeups/s/worker: 16 × 4 × (256 KB fill) is negligible.
// New-connection latency is unaffected: the accept loop (its own ~50ms cadence)
// drains the first handshake packet and bumps active_connection_count, after
// which the poll workers resume the 500us floor within <=250ms. See
// tests/test_quic_idle_cpu.zig and the downstream quic-lib issue filed for the
// 256 KB per-poll fill (which also taxes ACTIVE polling).
pub const idle_poll_empty_park_ns: u64 = 250 * std.time.ns_per_ms;

// CANARY: REQ=REQ-QUIC-HC-075; FEATURE="QUIC High-Concurrency Requests"; ASPECT=ServerWriteWouldBlockRetry; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
//
// Under response fan-out, nonblocking UDP sends can return WouldBlock when the
// kernel send queue is briefly full. Treat that like congestion/flow-control
// pressure: park briefly, let endpoint polling process ACK/MAX_DATA progress,
// then retry instead of failing the request with no response.
pub const server_writer_wait_for_poll_ns: u64 = 1 * std.time.ns_per_ms;

// CANARY: REQ=REQ-QUIC-HC-083; FEATURE="QUIC High-Concurrency Requests"; ASPECT=ServerWriteCongestionDeadline; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
//
// PollSync can wake writers for unrelated connection progress during a 512+
// response burst. Use a wall-clock congestion deadline plus a periodic real
// sleep so a single response does not burn through a retry-count budget while
// waiting for ACKs to open the congestion window.
pub const server_writer_max_blocked_ns: u64 = 60 * std.time.ns_per_s;
const server_writer_retry_yield_every: usize = 64;
const server_writer_credit_wait_ns: u64 = 5 * std.time.ns_per_ms;

// Max connections destroyed per drainPendingDestroy() call. drainPendingDestroy
// holds the endpoint mutex (ep.mu) — which the vendored QUIC poll path also
// acquires to process incoming datagrams — across the whole batch. Under
// sustained connection churn (rapid leader-kill / reschedule storms) the
// pending-destroy backlog can reach thousands; draining it in ONE batch parks
// every poll worker on ep.mu for the whole batch, the listener UDP rx_queue
// backs up to MiB, and the raft transport can no longer accept AppendEntries —
// the acceptor wedge (docs/bugs/2026-06-03-acceptor-wedge-connection-burst-new
// -conns-refused.md; sustained-churn stranded-candidate, RC-A follow-up). Capping
// the per-call batch bounds the ep.mu hold (~this many api.destroy calls) so the
// 16 poll workers reclaim ep.mu and keep draining the socket between calls; the
// accept loop calls drainPendingDestroy every iteration (<=5 ms admission park),
// so any remainder is reaped across cycles at >> the churn rate. Tunable for
// k8s validation via GEODE_QUIC_DESTROY_BATCH (0/unset → this default).
const drain_pending_destroy_batch_default: usize = 64;
var drain_pending_destroy_batch: usize = drain_pending_destroy_batch_default;

/// Override the per-call drainPendingDestroy() batch cap (0 = unbounded, the
/// pre-fix behaviour). Called once at startup from main.zig with
/// GEODE_QUIC_DESTROY_BATCH so the cap can be tuned in a k8s churn run without
/// a rebuild. Single-threaded startup write; drainPendingDestroy reads it from
/// the accept loop only.
pub fn setDrainPendingDestroyBatch(n: usize) void {
    drain_pending_destroy_batch = n;
}

/// Override the vendored QUIC endpoint's per-poll-cycle server socket-DRAIN cap
/// (acceptor-wedge RC-A, quic v0.1.28). The drain cap is decoupled from the
/// Initial PROCESSING budget so a reconnect storm's surplus Initials are cheaply
/// shed and the kernel UDP rx_queue stays bounded independent of teardown. 0 ->
/// the lib's compiled default (UdpBatchCap*64 = 4096). Called once at startup
/// from main.zig with GEODE_QUIC_DRAIN_PACKETS so the cap can be tuned in a k8s
/// churn run without a rebuild. Single-threaded startup write; the lib reads it
/// on the poll hot path.
pub fn setServerSocketDrainPackets(n: usize) void {
    api.setServerSocketDrainPackets(n);
}

/// Override the vendored QUIC endpoint's per-poll-cycle server Initial
/// (new-connection) PROCESSING budget (acceptor-wedge RC-A it.2, quic v0.1.29).
/// Surplus Initials beyond this are shed lock-free (client PTO retransmits), so
/// the shed-drain engages immediately and the kernel rx_queue stays bounded
/// under a reconnect storm. 0 -> the lib's compiled default (one UDP batch = 64).
/// Startup-only write; the lib reads it on the poll hot path.
pub fn setServerInitialProcessingBudget(n: usize) void {
    api.setServerInitialProcessingBudget(n);
}

/// Pure split for drainPendingDestroy: of `total` queued destroys, process the
/// tail `n` this call and keep the surviving prefix `keep` for the next call.
/// `batch == 0` means unbounded (process everything). Extracted so the bounding
/// arithmetic is unit-testable without a configured QUIC endpoint.
const DrainSplit = struct { n: usize, keep: usize };
fn drainBatchSplit(total: usize, batch: usize) DrainSplit {
    const n = if (batch == 0) total else @min(total, batch);
    return .{ .n = n, .keep = total - n };
}

test "drainBatchSplit bounds the per-call destroy count and preserves the remainder" {
    const t = std.testing;
    // empty
    try t.expectEqual(@as(usize, 0), drainBatchSplit(0, 64).n);
    // below the cap → drain all, keep none
    try t.expectEqual(DrainSplit{ .n = 10, .keep = 0 }, drainBatchSplit(10, 64));
    // exactly the cap
    try t.expectEqual(DrainSplit{ .n = 64, .keep = 0 }, drainBatchSplit(64, 64));
    // above the cap → drain the cap, keep the remainder for the next call
    try t.expectEqual(DrainSplit{ .n = 64, .keep = 936 }, drainBatchSplit(1000, 64));
    // unbounded (batch == 0) → drain everything (pre-fix behaviour)
    try t.expectEqual(DrainSplit{ .n = 1000, .keep = 0 }, drainBatchSplit(1000, 0));
    // draining a large backlog in capped chunks reaps every entry exactly once
    var left: usize = 5000;
    var total_drained: usize = 0;
    var calls: usize = 0;
    while (left > 0) {
        const s = drainBatchSplit(left, 64);
        total_drained += s.n;
        left = s.keep;
        calls += 1;
        try t.expect(s.n <= 64); // hold stays bounded every call
    }
    try t.expectEqual(@as(usize, 5000), total_drained);
    try t.expectEqual(@as(usize, (5000 + 63) / 64), calls);
}

// CANARY: REQ=REQ-QUIC-HC-084; FEATURE="QUIC High-Concurrency Requests"; ASPECT=ClientWriteCongestionDeadline; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
//
// Request fan-out has the same congestion-window burst behavior as response
// fan-out. Keep client writes bounded by wall clock instead of the old 10s
// retry budget so early EXECUTE frames can wait for ACK progress.
pub const client_writer_max_blocked_ns: u64 = 60 * std.time.ns_per_s;

// CANARY: REQ=REQ-QUIC-HC-088; FEATURE="QUIC High-Concurrency Requests"; ASPECT=ConfigurableInitialCwnd; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
//
// Geode's QUIC deployment is server/datacenter oriented and routinely opens
// hundreds or thousands of fresh connections in one fan-out. A 10-packet
// initial application cwnd makes small HELLO/EXECUTE responses wait for ACK
// credit even on loopback. Keep this explicit in the wrapper instead of
// changing the QUIC library's RFC-friendly default.
const high_concurrency_initial_cwnd_packets: u16 = 64;

fn waitForServerWriterProgress(stream: *QuicStream, blocked_retries: usize, observed_credit_generation: u32) void {
    // CANARY: REQ=REQ-QUIC-HC-087; FEATURE="QUIC High-Concurrency Requests"; ASPECT=PerConnectionTxCreditWake; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
    // Congestion-window zero returns clear only when this connection receives
    // Application ACK credit. Waiting on the endpoint-wide poll generation
    // wakes every blocked writer for unrelated peers and turns a response burst
    // into retry contention.
    const current = stream.connection.tx_credit_generation.load(.acquire);
    if (current == observed_credit_generation) {
        const io = std.Io.Threaded.global_single_threaded.io();
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(server_writer_credit_wait_ns),
            .clock = .awake,
        } };
        io.futexWaitTimeout(u32, &stream.connection.tx_credit_generation.raw, current, timeout) catch |err| switch (err) {
            error.Canceled => {},
        };
    }
    if (blocked_retries % server_writer_retry_yield_every == 0) {
        if (stream.poll_sync) |ps| {
            ps.waitForPoll(server_writer_wait_for_poll_ns);
        } else {
            compat_sleepNs(server_writer_wait_for_poll_ns);
        }
    }
}

/// Decide whether a slow-poll warning should fire for a cycle of `cycle_ns`.
/// Pure: fires when the cycle exceeds `threshold_ns` AND at least
/// `min_interval_ns` has elapsed since `last_warn_ns` (rate limit).
pub fn shouldWarnSlowPoll(cycle_ns: u64, threshold_ns: u64, last_warn_ns: u64, now_ns: u64, min_interval_ns: u64) bool {
    if (cycle_ns <= threshold_ns) return false;
    return (now_ns -% last_warn_ns) >= min_interval_ns;
}

pub const QuicTransport = struct {
    allocator: std.mem.Allocator,
    config: Config,
    /// Heap-allocated endpoint (via api.endpointInit / api.endpointDeinit).
    endpoint: ?*Endpoint = null,
    connections: std.ArrayList(*QuicConnection),
    // GAP-0202: Mutex for thread-safe connection list access in async mode
    connections_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// 2026-06-08 idle-CPU fix: lock-free mirror of `connections.items.len`,
    /// updated under `connections_mutex` at every add/remove site. Read by the
    /// poll workers (`pollLoop`) to choose the idle park duration WITHOUT taking
    /// `connections_mutex` on the hot path. A momentarily stale value is
    /// harmless — worst case the poll cadence adjusts one cycle late.
    active_connection_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// PERF-D / #816 follow-up: generation counter that is incremented every
    /// time a connection slot is freed (via `destroyConnection`'s swapRemove
    /// or via `drainPendingDestroy` completing a batch). The server's accept
    /// loop parks on this word via `io.futexWaitTimeout` when at
    /// `max_connections`; producers call `io.futexWake(..., 1)` after
    /// dropping the slot to wake exactly one parked acceptor. This replaces
    /// the prior unconditional 5 ms nanosleep poll. The wake is best-effort
    /// (lost-wake race is bounded by the 5 ms timeout the acceptor still
    /// applies as a safety net). Follows the b3790685 signal-not-broadcast
    /// discipline since there is at most one accept loop.
    connection_slot_freed_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // GAP-0203: Deferred connection destruction to prevent use-after-free.
    // Handler threads add inner connections here after sending CONNECTION_CLOSE;
    // the main accept loop thread processes them via drainPendingDestroy()
    // where endpoint bookkeeping can be safely updated without racing with poll().
    pending_destroy: std.ArrayList(*Connection),
    pending_destroy_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Readers-writer sync: handler threads are "readers" (concurrent I/O),
    /// main thread is the "writer" (exclusive poll). See PollSync docs.
    poll_sync: PollSync = .{},
    /// #864 / qa-seed deadlock §6.6: max observed `poll(0)` cycle latency
    /// (nanoseconds) since process start. Updated lock-free via CAS from
    /// the poll thread; read by the runtime-metrics gauge
    /// `quic_poll_cycle_max_ns`. Lets operators detect pollLoop saturation
    /// before handler `BufferedProtoReader.nextMessage` starts spinning.
    poll_cycle_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Max observed vendor endpoint transport poll phase latency. This splits
    /// `quic_poll_cycle_max_ns` into actionable sub-phases for high fan-out
    /// request profiling.
    poll_transport_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_recv_process_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_recv_short_header_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_recv_short_endpoint_map_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_recv_short_rx_serial_wait_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_recv_short_conn_lock_wait_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_recv_short_decrypt_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_recv_short_frame_process_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_recv_short_ack_send_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_recv_initial_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_recv_handshake_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_recv_fallback_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_pending_hs_send_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_timer_process_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    poll_pto_dirty_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Cumulative count of poll cycles whose `poll(0)` latency exceeded
    /// the handler waitForPoll fallback timeout. Each such cycle means at
    /// least one handler missed the broadcast and will re-enter its
    /// would-block loop for another iteration. Surface via the
    /// `quic_poll_overrun_total` gauge.
    poll_overrun_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Last wall-clock ns a slow-poll warning was emitted (rate limiting).
    /// See shouldWarnSlowPoll and observePollCycle. Updated lock-free via CAS.
    slow_poll_last_warn_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Heap-allocated QUIC config; owns the inline cert/key DER byte slices.
    quic_config: ?*VendorQuicConfig = null,

    pub const Config = struct {
        address: []const u8 = "0.0.0.0",
        port: u16 = DEFAULT_PORT,
        max_connections: usize = 10000,
        idle_timeout_ms: u64 = 300000,
        max_stream_data: u64 = 10 * 1024 * 1024,
        max_data: u64 = 100 * 1024 * 1024,
        cert_path: []const u8 = "certs/server.crt",
        key_path: []const u8 = "certs/server.key",
        ca_path: ?[]const u8 = null,
        /// Allow insecure TLS connections (skip certificate validation)
        /// SECURITY: Default is false. Only set to true for testing with self-signed certificates.
        /// GAP-0105 FIX: Changed default from true to false for secure-by-default behavior.
        allow_insecure: bool = false,
        /// Require client certificates for mTLS authentication over QUIC.
        /// When true, connections without a valid client certificate will be rejected.
        /// CANARY: REQ=REQ-AUTH-MTLS-QUIC-002; FEATURE="mTLS over QUIC"; ASPECT=Config; STATUS=TESTED; TEST=geodetestlab-cli/specs/authn_mtls_rejection_matrix.yml; OWNER=transport; UPDATED=2026-06-11
        require_client_cert: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !QuicTransport {
        return QuicTransport{
            .allocator = allocator,
            .config = config,
            .connections = std.ArrayList(*QuicConnection).empty,
            .pending_destroy = std.ArrayList(*Connection).empty,
        };
    }

    pub fn deinit(self: *QuicTransport) void {
        // Clear the module-global pointer first so the OTel observable gauge
        // callback (registered via registerTransportConnectionGauge) cannot
        // observe a half-torn-down transport. otel_metrics.shutdown() also
        // nulls its provider pointer, but symmetry here prevents a latent
        // test-only race.
        g_quic_transport_instance = null;

        // GAP-0203: Process any deferred connection cleanups first.
        // These are inner connections queued by handler threads via destroyConnection().
        self.drainPendingDestroy();

        self.connections_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        var conns = self.connections;
        self.connections = .empty;
        self.connections_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        for (conns.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }
        conns.deinit(self.allocator);

        self.drainPendingDestroy();
        self.pending_destroy.deinit(self.allocator);

        if (self.endpoint) |ep| {
            api.endpointDeinit(ep);
            self.endpoint = null;
        }

        // Free the heap-allocated config and its owned cert/key DER bytes.
        if (self.quic_config) |cfg| {
            if (cfg.inline_server_cert_der) |cert| {
                self.allocator.free(cert);
            }
            if (cfg.inline_server_priv_p256) |key| {
                self.allocator.free(key);
            }
            self.allocator.destroy(cfg);
            self.quic_config = null;
        }
    }

    /// Process deferred connection destructions queued by handler threads.
    /// MUST be called from the main accept loop thread (the same thread that
    /// calls poll()/accept()) to avoid racing with endpoint packet processing.
    /// GAP-0203: Fix use-after-free race condition between handler threads
    /// calling deinit() and the main thread's poll() accessing freed memory.
    pub fn drainPendingDestroy(self: *QuicTransport) void {
        var drained: usize = 0;
        {
            self.pending_destroy_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.pending_destroy_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            const total = self.pending_destroy.items.len;
            if (total == 0) return;

            // Bound the per-call batch so the ep.mu hold (which the vendored QUIC
            // poll path also needs, to drain the listener socket) stays short
            // under sustained connection churn — see drain_pending_destroy_batch.
            // Process the TAIL `n` entries and keep the surviving prefix `keep`
            // for the next accept-loop iteration (destroy order is irrelevant —
            // each connection is independent).
            const split = drainBatchSplit(total, drain_pending_destroy_batch);
            const n = split.n;
            const keep = split.keep;

            // api.destroyBatch() modifies endpoint internal maps (conns, accepted,
            // retired) without acquiring ep.mu. Acquire it here to prevent racing
            // with poll().
            if (self.endpoint) |ep| {
                // REQ-QUIC-HC-035 pairs with endpoint poll's PTO recompute
                // lifetime guard: do not free a connection while poll is
                // walking a snapshotted PTO-dirty pointer.
                ep.pto_lifetime_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
                defer ep.pto_lifetime_mu.unlock(std.Io.Threaded.global_single_threaded.io());
                ep.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
                defer ep.mu.unlock(std.Io.Threaded.global_single_threaded.io());
                const doomed = self.pending_destroy.items[keep..];
                // Side-set removal (closed/pto-dirty/pending-hs) is per-conn and
                // O(1) each; do it for the whole batch first.
                for (doomed) |inner_conn| {
                    self.removeEndpointPendingRefs(ep, inner_conn);
                }
                // REQ-QUIC-HC-099: free the whole batch in ONE sweep of the
                // endpoint connection map. The old per-conn api.destroy()
                // re-scanned the entire map for every freed connection, so
                // draining a churn backlog of B conns from a map of N entries was
                // O(B × N) under ep.mu — that long hold starved the poll workers
                // that drain the listener UDP socket and wedged the rx_queue.
                // destroyBatch collapses the map work to a single O(N + keys)
                // pass; combined with the batch bound above the per-call ep.mu
                // hold stays short under sustained churn.
                api.destroyBatch(ep, doomed);
            } else {
                for (self.pending_destroy.items[keep..]) |inner_conn| {
                    inner_conn.deinit();
                }
            }
            drained = n;
            self.pending_destroy.shrinkRetainingCapacity(keep);
        }

        // PERF-D / #816 follow-up: signal admission waiter outside the lock
        // (b3790685 signal-after-unlock pattern). Each call to drain that
        // actually freed inner connections bumps the gen counter once — the
        // accept loop only needs to know "at least one slot may be free", not
        // the precise count. Wake exactly one waiter (single accept loop).
        if (drained > 0) {
            _ = self.connection_slot_freed_gen.fetchAdd(1, .release);
            const io = std.Io.Threaded.global_single_threaded.io();
            io.futexWake(u32, &self.connection_slot_freed_gen.raw, 1);
        }
    }

    fn removeEndpointPendingRefs(self: *QuicTransport, ep: *Endpoint, inner_conn: *Connection) void {
        _ = self;
        // QUIC-HC-002: the QUIC package keeps side indexes for "closed" and
        // PTO-dirty connections outside the main endpoint map. api.destroy()
        // removes maps/timers but not these side sets. Under concurrent close
        // churn the next poll() could snapshot a freed pointer from one of
        // those sets and crash in pruneClosed/processPtoDirty. We already hold
        // ep.mu here, so no endpoint poll can be snapshotting while these leaf
        // locks are taken.
        ep.closed_conn_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        if (ep.closed_conn_set.remove(inner_conn)) {
            _ = ep.closed_conn_count.fetchSub(1, .acq_rel);
        }
        ep.closed_conn_mu.unlock(std.Io.Threaded.global_single_threaded.io());

        ep.pto_dirty_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        if (ep.pto_dirty_set.remove(inner_conn)) {
            _ = ep.pto_dirty_count.fetchSub(1, .acq_rel);
        }
        ep.pto_dirty_mu.unlock(std.Io.Threaded.global_single_threaded.io());

        // CANARY: REQ=REQ-QUIC-HC-034; FEATURE="QUIC High-Concurrency Requests"; ASPECT=EndpointSideSetDestroyCleanup; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
        // pending_hs_send_set also stores raw connection pointers outside the
        // endpoint map. Remove it before api.destroy() frees the connection,
        // or a later poll cycle can retry a handshake send on freed state.
        ep.pending_hs_send_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        if (ep.pending_hs_send_set.remove(inner_conn)) {
            _ = ep.pending_hs_send_count.fetchSub(1, .acq_rel);
        }
        ep.pending_hs_send_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    pub fn listen(self: *QuicTransport) !void {
        // Verify certificates exist or generate them.
        //
        // CANARY: REQ=REQ-CLUSTER-CERT-PROVIDED-HONORED; FEATURE="DistributedClusterTLS"; ASPECT=ListenerCertProbe; STATUS=TESTED; TEST=tests/test_cert_provided_cert_honored.zig; OWNER=transport; UPDATED=2026-06-04
        //
        // The previous probe used `std.Io.Dir.access` over the `.failing`
        // global_single_threaded Io, which was environment-sensitive when geode
        // runs as a container entrypoint and could misreport a present cert as
        // missing → spurious self-sign. `certPathReadable` is an allocation-free
        // openat() syscall and only takes the generate branch on genuine
        // absence. See
        // docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md.
        if (!certPathReadable(self.config.cert_path)) {
            // Cert genuinely absent → try to generate self-signed certificates.
            if (self.generateSelfSignedCert()) {
                tlog.info("auto-generated self-signed TLS certificate", &.{
                    Attr.string("path", self.config.cert_path),
                });
            } else |gen_err| {
                // Use .err (not .fatal) so the logger does not panic when
                // this fires inside a unit-test binary.  The caller still
                // receives CertificateError and the server refuses to start.
                tlog.err("TLS certificates not found and generation failed", &.{
                    Attr.string("cert_path", self.config.cert_path),
                    Attr.string("key_path", self.config.key_path),
                    Attr.string("error", @errorName(gen_err)),
                });
                std.debug.print("SECURITY: Refusing to start without TLS. Generate certificates manually:\n", .{});
                std.debug.print("  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout {s} -out {s} -days 365\n", .{ self.config.key_path, self.config.cert_path });
                return QuicError.CertificateError;
            }
        }

        // Load and parse certificate file (convert to DER for inline TLS material)
        const io_cert = std.Io.Threaded.global_single_threaded.io();
        const cert_file = try std.Io.Dir.cwd().openFile(io_cert, self.config.cert_path, .{});
        defer cert_file.close(io_cert);
        const cert_stat = try cert_file.stat(io_cert);
        const cert_size: usize = @intCast(@min(cert_stat.size, 1024 * 1024));
        const cert_pem = try self.allocator.alloc(u8, cert_size);
        defer self.allocator.free(cert_pem);
        _ = try cert_file.readPositionalAll(io_cert, cert_pem, 0);
        const inline_cert_der = api.pem.parseCertificate(self.allocator, cert_pem) catch |err| {
            tlog.err("failed to parse certificate", &.{
                Attr.string("path", self.config.cert_path),
                Attr.string("error", @errorName(err)),
            });
            return QuicError.CertificateError;
        };

        // Load and parse private key (DER inline for TLS)
        const key_file = try std.Io.Dir.cwd().openFile(io_cert, self.config.key_path, .{});
        defer key_file.close(io_cert);
        const key_stat = try key_file.stat(io_cert);
        const key_size: usize = @intCast(@min(key_stat.size, 1024 * 1024));
        const key_pem = try self.allocator.alloc(u8, key_size);
        defer self.allocator.free(key_pem);
        _ = try key_file.readPositionalAll(io_cert, key_pem, 0);
        const inline_priv_key = api.pem.parsePrivateKey(self.allocator, key_pem) catch |err| {
            tlog.err("failed to parse private key", &.{
                Attr.string("path", self.config.key_path),
                Attr.string("error", @errorName(err)),
            });
            self.allocator.free(inline_cert_der);
            return QuicError.CertificateError;
        };

        // Allocate QuicConfig on the heap so cert/key DER slices remain valid
        // for the lifetime of the endpoint (endpointInit stores references).
        const cfg = try self.allocator.create(VendorQuicConfig);
        errdefer {
            self.allocator.free(inline_cert_der);
            self.allocator.free(inline_priv_key);
            self.allocator.destroy(cfg);
        }
        cfg.* = VendorQuicConfig{
            .version = .v1,
            .alpn = &[_][]const u8{"geode/1"},
            .cc = .cubic,
            .enable_datagram = false,
            .enable_spin_bit = false,
            .grease = true,
            .compatible_vn = false,
            .enable_retry = false,
            .token_secret = null,
            .token_expiry_ms = 60000,
            .enable_pacing = false,
            .max_datagram_size = 1200,
            .initial_congestion_window_packets = high_concurrency_initial_cwnd_packets,
            .max_idle_timeout_ms = @intCast(self.config.idle_timeout_ms),
            .max_udp_payload = 1350,
            .cert_path = self.config.cert_path,
            .key_path = self.config.key_path,
            .ca_path = self.config.ca_path,
            .allow_insecure = self.config.allow_insecure,
            .aead_confidentiality_limit_override = null,
            .aead_integrity_limit_override = null,
            .max_connections = self.config.max_connections,
            .defer_accept_until_stream = true,
            .require_client_cert = self.config.require_client_cert,
            .inline_server_cert_der = inline_cert_der,
            .inline_server_priv_p256 = inline_priv_key,
        };
        self.quic_config = cfg;

        // Normalize "localhost" to "127.0.0.1"
        const bind_address = if (std.mem.eql(u8, self.config.address, "localhost"))
            "127.0.0.1"
        else
            self.config.address;

        // Create bind address string
        const bind_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ bind_address, self.config.port });
        defer self.allocator.free(bind_addr);

        // Initialize endpoint using api.endpointInit (heap-allocates the Endpoint struct).
        self.endpoint = try api.endpointInit(&self.allocator, bind_addr, cfg);

        tlog.info("QUIC transport listening", &.{
            Attr.int("port", @intCast(self.config.port)),
            Attr.string("tls", "true"),
            Attr.string("status", "listening"),
        });
        // Startup banner for operational tooling (JSON on stderr)
        std.debug.print("{{\"component\":\"transport\",\"transport\":\"quic\",\"tls\":\"true\",\"port\":{d},\"library\":\"vendor/quic\",\"api\":\"native-endpoint\",\"status\":\"listening\"}}\n", .{self.config.port});
        // Register OTel observable gauge for active connection count.
        // Set module-level pointer so the callback can read getConnectionCount().
        g_quic_transport_instance = self;
        @import("otel_metrics").registerTransportConnectionGauge(activeConnectionCountProvider) catch {};
    }

    fn pollOnce(self: *QuicTransport, timeout_ms: u32) !api.PollStats {
        if (self.endpoint) |ep| {
            const timeout_i32: i32 = if (timeout_ms > std.math.maxInt(i32))
                std.math.maxInt(i32)
            else
                @intCast(timeout_ms);
            // QUIC library v0.1.10: poll() is internally thread-safe with
            // fine-grained per-phase locking. No external PollSync needed
            // for the poll call itself. We still advance poll_generation so handlers
            // waiting for data delivery wake up promptly after packet-bearing
            // cycles. Empty polls do not advance the generation; otherwise a
            // quiet socket wakes every blocked handler every 500us.
            const stats = try ep.pollWithStats(timeout_i32);
            if (stats.packets_processed > 0) {
                self.poll_sync.notifyPoll();
            }
            return stats;
        }
        return .{};
    }

    pub fn poll(self: *QuicTransport, timeout_ms: u32) !void {
        _ = try self.pollOnce(timeout_ms);
    }

    /// Dedicated poll loop — run on a separate thread to decouple packet delivery
    /// from the accept loop. This eliminates the c=8+ contention bottleneck where
    /// handler threads starve waiting for data that only arrives when the main
    /// thread calls poll() between accept attempts (#540).
    ///
    /// The poll thread continuously processes incoming UDP datagrams into connection
    /// RX buffers and signals waiting handler threads via PollSync.notifyPoll().
    ///
    /// #864 / qa-seed deadlock §6.6: tracks per-cycle latency so operators can
    /// detect saturation (handler `BufferedProtoReader.nextMessage` spins on
    /// WouldBlock once the poll cycle exceeds the handler waitForPoll
    /// timeout).  An overrun is any cycle whose `poll(0)` + housekeeping
    /// exceeds the handler wait timeout — the canonical leading indicator
    /// of pollLoop saturation.  Deeper sharding (multi-threaded poll
    /// dispatch) requires upstream QUIC-library changes; see
    /// divelife-argo/docs/quic-deadlock.md §6.6 for the full rationale.
    pub fn pollLoop(self: *QuicTransport, shutdown: *std.atomic.Value(bool)) void {
        // Threshold: a single cycle whose poll(0) call exceeds the handler
        // waitForPoll timeout (see server_handler_wait_for_poll_ns)
        // means at least one handler missed this cycle's broadcast.
        const overrun_threshold_ns: u64 = server_handler_wait_for_poll_ns;
        while (!shutdown.load(.acquire)) {
            // Non-blocking poll — process any pending UDP datagrams without
            // blocking on the socket. QUIC-HC-003: when a cycle drains packets,
            // immediately loop again to clear bursts; when it is empty, park for
            // 500us to avoid idle wake storms.
            // drainPendingDestroy is handled by the main accept loop thread only
            // (it acquires ep.mu which would contend with poll's internal locking).
            const start_ns = monoNsRaw();
            const stats = self.pollOnce(0) catch api.PollStats{}; // Best-effort cleanup
            const cycle_ns = monoNsRaw() -% start_ns;
            self.observePollCycle(stats, cycle_ns, overrun_threshold_ns);
            if (stats.packets_processed == 0) {
                // 2026-06-08 idle-CPU fix: when this cycle drained nothing, park.
                // With ZERO live connections nothing will arrive on the poll path
                // (new-connection Initials are serviced by the accept loop on its
                // own cadence), so park long (idle_poll_empty_park_ns) instead of
                // 500us — otherwise the 16 release poll workers each spin
                // pollOnce(0)+500us = ~56% of a core = ~810% on an idle node.
                // With >=1 live connection keep the 500us low-latency floor so
                // active connections (even low-QPS ones) are never delayed.
                const park_ns: u64 = if (self.active_connection_count.load(.monotonic) == 0)
                    idle_poll_empty_park_ns
                else
                    500 * std.time.ns_per_us;
                compat_sleepNs(park_ns);
            }
        }
        // Final poll to flush any remaining packets on shutdown
        self.poll(0) catch {}; // Best-effort cleanup
    }

    /// Update the poll-cycle observability counters from a single iteration.
    /// `cycle_ns` is the duration of the `poll(0)` call (excluding the
    /// inter-cycle sleep).  Records the max-of-window via CAS and bumps the
    /// overrun counter if the cycle exceeded `overrun_threshold_ns`.
    fn observePollCycle(self: *QuicTransport, stats: api.PollStats, cycle_ns: u64, overrun_threshold_ns: u64) void {
        observeMaxAtomic(&self.poll_cycle_max_ns, cycle_ns);
        observeMaxAtomic(&self.poll_transport_max_ns, stats.transport_poll_ns);
        observeMaxAtomic(&self.poll_recv_process_max_ns, stats.recv_process_ns);
        observeMaxAtomic(&self.poll_recv_short_header_max_ns, stats.recv_short_header_ns);
        observeMaxAtomic(&self.poll_recv_short_endpoint_map_max_ns, stats.recv_short_endpoint_map_ns);
        observeMaxAtomic(&self.poll_recv_short_rx_serial_wait_max_ns, stats.recv_short_rx_serial_wait_ns);
        observeMaxAtomic(&self.poll_recv_short_conn_lock_wait_max_ns, stats.recv_short_conn_lock_wait_ns);
        observeMaxAtomic(&self.poll_recv_short_decrypt_max_ns, stats.recv_short_decrypt_ns);
        observeMaxAtomic(&self.poll_recv_short_frame_process_max_ns, stats.recv_short_frame_process_ns);
        observeMaxAtomic(&self.poll_recv_short_ack_send_max_ns, stats.recv_short_ack_send_ns);
        observeMaxAtomic(&self.poll_recv_initial_max_ns, stats.recv_initial_ns);
        observeMaxAtomic(&self.poll_recv_handshake_max_ns, stats.recv_handshake_ns);
        observeMaxAtomic(&self.poll_recv_fallback_max_ns, stats.recv_fallback_ns);
        observeMaxAtomic(&self.poll_pending_hs_send_max_ns, stats.pending_hs_send_ns);
        observeMaxAtomic(&self.poll_timer_process_max_ns, stats.timer_process_ns);
        observeMaxAtomic(&self.poll_pto_dirty_max_ns, stats.pto_dirty_ns);
        if (cycle_ns > overrun_threshold_ns) {
            _ = self.poll_overrun_total.fetchAdd(1, .monotonic);
        }
        // Slow-poll WARNING (bug 2026-06-07): surface multi-second poll cycles in
        // logs before the in-band liveness probe times out. 1s threshold,
        // rate-limited to one line / 5s so sustained load can't flood the log.
        const slow_threshold_ns: u64 = 1 * std.time.ns_per_s;
        if (cycle_ns > slow_threshold_ns) {
            const now_ns = monoNsRaw();
            const last = self.slow_poll_last_warn_ns.load(.acquire);
            if (shouldWarnSlowPoll(cycle_ns, slow_threshold_ns, last, now_ns, 5 * std.time.ns_per_s)) {
                if (self.slow_poll_last_warn_ns.cmpxchgStrong(last, now_ns, .acq_rel, .acquire) == null) {
                    tlog.warn("QUIC poll cycle slow — query path degraded (sustained-load liveness-kill risk)", &.{
                        Attr.uint("cycle_ms", cycle_ns / std.time.ns_per_ms),
                        Attr.uint("recv_process_ms", stats.recv_process_ns / std.time.ns_per_ms),
                        Attr.uint("timer_process_ms", stats.timer_process_ns / std.time.ns_per_ms),
                        Attr.uint("packets", @intCast(stats.packets_processed)),
                    });
                }
            }
        }
    }

    fn observeMaxAtomic(cell: *std.atomic.Value(u64), value: u64) void {
        // Lock-free max via CAS loop.  At most cpu-count writers (one poll
        // thread today) so contention is minimal; the metric reader is the
        // gauge callback which loads once per scrape.
        while (true) {
            const cur = cell.load(.acquire);
            if (value <= cur) break;
            if (cell.cmpxchgWeak(cur, value, .acq_rel, .acquire)) |_| {
                continue;
            }
            break;
        }
    }

    pub fn accept(self: *QuicTransport) !*QuicConnection {
        if (self.endpoint) |ep| {
            // GAP-0203: Drain deferred connection cleanups.
            self.drainPendingDestroy();

            // CV-based blocking accept: waits up to 50ms for a new
            // connection via the endpoint's accept_cv, using near-zero
            // CPU when idle. Falls back to WouldBlock if no connection
            // arrives within the timeout.
            const conn = api.waitForAccepted(ep, 50) orelse return QuicError.WouldBlock;

            // Return immediately — handler waits for streams via PollSync.
            const wrapper = try self.allocator.create(QuicConnection);
            wrapper.* = QuicConnection{
                .allocator = self.allocator,
                .quic_connection = conn,
                .inner = conn,
                .streams = try std.ArrayList(*QuicStream).initCapacity(self.allocator, 0),
                .poll_sync = &self.poll_sync,
            };
            // GAP-0202: Thread-safe connection list append
            self.connections_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.connections_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            try self.connections.append(self.allocator, wrapper);
            // 2026-06-08 idle-CPU fix: keep the lock-free count mirror current.
            self.active_connection_count.store(self.connections.items.len, .monotonic);
            @import("otel_metrics").recordTransportConnectionOpened(.quic);
            return wrapper;
        }
        return QuicError.InvalidState;
    }

    /// #49: Returns the current number of tracked connections for admission control.
    pub fn getConnectionCount(self: *QuicTransport) usize {
        self.connections_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.connections_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.connections.items.len;
    }

    /// Ask active connection handlers to unwind without freeing wrappers they
    /// still own. Handlers observe the per-connection shutdown flag on their
    /// next stream read/write and then call destroyConnection() normally.
    ///
    /// CANARY: REQ=REQ-QUIC-HC-004; FEATURE="QUIC High-Concurrency Shutdown"; ASPECT=ConnectionDrainSignal; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
    pub fn requestShutdown(self: *QuicTransport) void {
        self.connections_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.connections_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        for (self.connections.items) |conn| {
            conn.requestShutdown();
        }
        self.poll_sync.notifyPoll();
    }

    /// #864 §6.6: snapshot the max-observed `poll(0)` cycle latency
    /// (nanoseconds).  Surfaces pollLoop saturation independently of the
    /// proto-reader would-block counter so dashboards can alert on the
    /// upstream cause rather than the downstream symptom.
    pub fn getPollCycleMaxNs(self: *QuicTransport) u64 {
        return self.poll_cycle_max_ns.load(.acquire);
    }

    pub fn getPollTransportMaxNs(self: *QuicTransport) u64 {
        return self.poll_transport_max_ns.load(.acquire);
    }

    pub fn getPollRecvProcessMaxNs(self: *QuicTransport) u64 {
        return self.poll_recv_process_max_ns.load(.acquire);
    }

    pub fn getPollRecvShortHeaderMaxNs(self: *QuicTransport) u64 {
        return self.poll_recv_short_header_max_ns.load(.acquire);
    }

    pub fn getPollRecvShortEndpointMapMaxNs(self: *QuicTransport) u64 {
        return self.poll_recv_short_endpoint_map_max_ns.load(.acquire);
    }

    pub fn getPollRecvShortRxSerialWaitMaxNs(self: *QuicTransport) u64 {
        return self.poll_recv_short_rx_serial_wait_max_ns.load(.acquire);
    }

    pub fn getPollRecvShortConnLockWaitMaxNs(self: *QuicTransport) u64 {
        return self.poll_recv_short_conn_lock_wait_max_ns.load(.acquire);
    }

    pub fn getPollRecvShortDecryptMaxNs(self: *QuicTransport) u64 {
        return self.poll_recv_short_decrypt_max_ns.load(.acquire);
    }

    pub fn getPollRecvShortFrameProcessMaxNs(self: *QuicTransport) u64 {
        return self.poll_recv_short_frame_process_max_ns.load(.acquire);
    }

    pub fn getPollRecvShortAckSendMaxNs(self: *QuicTransport) u64 {
        return self.poll_recv_short_ack_send_max_ns.load(.acquire);
    }

    pub fn getPollRecvInitialMaxNs(self: *QuicTransport) u64 {
        return self.poll_recv_initial_max_ns.load(.acquire);
    }

    pub fn getPollRecvHandshakeMaxNs(self: *QuicTransport) u64 {
        return self.poll_recv_handshake_max_ns.load(.acquire);
    }

    pub fn getPollRecvFallbackMaxNs(self: *QuicTransport) u64 {
        return self.poll_recv_fallback_max_ns.load(.acquire);
    }

    pub fn getPollPendingHsSendMaxNs(self: *QuicTransport) u64 {
        return self.poll_pending_hs_send_max_ns.load(.acquire);
    }

    pub fn getPollTimerProcessMaxNs(self: *QuicTransport) u64 {
        return self.poll_timer_process_max_ns.load(.acquire);
    }

    pub fn getPollPtoDirtyMaxNs(self: *QuicTransport) u64 {
        return self.poll_pto_dirty_max_ns.load(.acquire);
    }

    /// #864 §6.6: snapshot the cumulative count of overran poll cycles —
    /// cycles whose `poll(0)` exceeded the handler waitForPoll fallback
    /// timeout, causing at least one handler to miss the broadcast.
    pub fn getPollOverrunTotal(self: *QuicTransport) u64 {
        return self.poll_overrun_total.load(.monotonic);
    }

    pub fn tryAccept(self: *QuicTransport) ?*QuicConnection {
        if (self.endpoint) |ep| {
            // QUIC library v0.1.10: poll() is internally thread-safe
            ep.poll(0) catch {
                return null;
            };
            self.poll_sync.notifyPoll();
            const conn = api.tryAccept(ep) orelse return null;
            const wrapper = self.allocator.create(QuicConnection) catch return null;
            wrapper.* = QuicConnection{
                .allocator = self.allocator,
                .quic_connection = conn,
                .inner = conn,
                .streams = std.ArrayList(*QuicStream).initCapacity(self.allocator, 0) catch return null,
                .poll_sync = &self.poll_sync,
            };
            // GAP-0202: Thread-safe connection list append
            self.connections_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.connections_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            self.connections.append(self.allocator, wrapper) catch {
                self.allocator.destroy(wrapper);
                return null;
            };
            // 2026-06-08 idle-CPU fix: keep the lock-free count mirror current.
            self.active_connection_count.store(self.connections.items.len, .monotonic);
            return wrapper;
        }
        return null;
    }

    /// CANARY: REQ=REQ-QUIC-CONN-CLEANUP-002; FEATURE="ConnectionMemoryManagement"; ASPECT=ConnectionListCleanup; STATUS=EXEMPT; OWNER=transport; UPDATED=2025-12-27
    /// Remove a connection from tracking, close it, and destroy it.
    /// This should be called after a connection handler completes to prevent resource leaks.
    /// GAP-0201: Use swapRemove for O(1) removal instead of O(n) orderedRemove
    /// CANARY: REQ=REQ-PERF-CONN-REMOVE-001; FEATURE="ConnectionRemovalOptimization"; ASPECT=O1Removal; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-01-30
    /// GAP-0202: Thread-safe connection removal for async connection handling
    /// GAP-0203: Defer inner connection deinit to main thread to prevent use-after-free
    pub fn destroyConnection(self: *QuicTransport, conn: *QuicConnection) void {
        conn.shutdown_requested.store(true, .release);
        @import("otel_metrics").recordTransportConnectionClosed("destroy");
        // GAP-0202: Lock mutex for thread-safe list modification
        self.connections_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        // Remove connection from the tracked list using O(1) swapRemove
        var removed: bool = false;
        var idx: usize = 0;
        while (idx < self.connections.items.len) {
            if (self.connections.items[idx] == conn) {
                _ = self.connections.swapRemove(idx);
                removed = true;
                break;
            }
            idx += 1;
        }
        // 2026-06-08 idle-CPU fix: keep the lock-free count mirror current so the
        // poll workers back off to the idle cadence once the last connection goes.
        self.active_connection_count.store(self.connections.items.len, .monotonic);
        self.connections_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // PERF-D / #816 follow-up: signal the admission control waiter that a
        // slot has freed. Done AFTER unlock (b3790685 signal-after-unlock
        // pattern) to avoid waking a thread that immediately blocks on the
        // mutex we still hold. Wake exactly one — there's only a single
        // accept loop.
        if (removed) {
            _ = self.connection_slot_freed_gen.fetchAdd(1, .release);
            const io = std.Io.Threaded.global_single_threaded.io();
            io.futexWake(u32, &self.connection_slot_freed_gen.raw, 1);
        }

        // Close streams and send CONNECTION_CLOSE frame, but DO NOT call
        // inner.deinit() here. The inner connection is still referenced by
        // the endpoint's tracking tables and the main thread's poll() loop
        // may still deliver packets to it. Freeing it here causes a
        // use-after-free crash (GAP-0203).
        // Use poll_sync to ensure poll() doesn't race with connection teardown.
        // Close streams and connection. The QUIC library's closeStream/
        // closeConnection are thread-safe (per-connection mutex).
        for (conn.streams.items) |stream| {
            conn.inner.closeStream(stream.stream_id, 0) catch {}; // Best-effort cleanup
            conn.allocator.destroy(stream);
        }
        conn.streams.deinit(conn.allocator);
        api.closeConnection(conn.inner, 0) catch {}; // Best-effort cleanup

        // Queue the inner connection for deferred destruction on the main thread.
        // drainPendingDestroy() will use api.destroy() to properly remove it
        // from all endpoint bookkeeping before freeing.
        // Use quic_connection (nullable, nulled by close()) with inner as fallback.
        const inner_conn = conn.quic_connection orelse conn.inner;
        self.pending_destroy_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        self.pending_destroy.append(self.allocator, inner_conn) catch {
            // If append fails (OOM), fall back to direct deinit.
            // This risks a crash but avoids a resource leak.
            conn.inner.deinit();
        };
        self.pending_destroy_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Destroy the wrapper struct (safe - no other thread references it)
        self.allocator.destroy(conn);
    }

    fn generateSelfSignedCert(self: *QuicTransport) !void {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Ensure the parent directory for the certificate exists.
        if (std.fs.path.dirname(self.config.cert_path)) |dir_path| {
            if (dir_path.len > 0) {
                std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return QuicError.CertificateError,
                };
            }
        }

        // Build argv: openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1
        //   -nodes -keyout <key_path> -out <cert_path> -days 365 -subj "/CN=geode-autogen"
        const argv = [_][]const u8{
            "openssl",                      "req",    "-x509",
            "-newkey",                      "ec",     "-pkeyopt",
            "ec_paramgen_curve:prime256v1", "-nodes", "-keyout",
            self.config.key_path,           "-out",   self.config.cert_path,
            "-days",                        "365",    "-subj",
            "/CN=geode-autogen",
        };

        var child = try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });

        const term = try std.process.Child.wait(&child, io);
        switch (term) {
            .exited => |code| {
                if (code != 0) return QuicError.CertificateError;
            },
            else => return QuicError.CertificateError,
        }
    }
};

pub const QuicConnection = struct {
    allocator: std.mem.Allocator,
    /// Nullable; nulled in close() to prevent double-close.
    quic_connection: ?*Connection = null,
    /// Non-nullable alias for the underlying connection (stays set after close).
    inner: *Connection,
    streams: std.ArrayList(*QuicStream),
    /// Shared poll synchronization — see PollSync docs.
    poll_sync: ?*PollSync = null,
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn openStream(self: *QuicConnection, bidirectional: bool) !*QuicStream {
        const qc = self.quic_connection orelse return QuicError.Closed;
        const stream_id = try api.openStream(qc, bidirectional);

        const stream = try self.allocator.create(QuicStream);
        stream.* = QuicStream{
            .allocator = self.allocator,
            .connection = self.inner,
            .stream_id = stream_id,
            .poll_sync = self.poll_sync,
            .shutdown_requested = &self.shutdown_requested,
            .tracking_index = self.streams.items.len,
        };
        try self.streams.append(self.allocator, stream);
        return stream;
    }

    pub fn acceptStream(self: *QuicConnection) !*QuicStream {
        const qc = self.quic_connection orelse return QuicError.Closed;
        const stream_id = try api.acceptStream(qc);
        // GAP-0200: Debug print removed from hot path for performance
        const stream = try self.allocator.create(QuicStream);
        stream.* = QuicStream{
            .allocator = self.allocator,
            .connection = self.inner,
            .stream_id = stream_id,
            .poll_sync = self.poll_sync,
            .shutdown_requested = &self.shutdown_requested,
            .tracking_index = self.streams.items.len,
        };
        try self.streams.append(self.allocator, stream);
        return stream;
    }

    /// Non-blocking stream accept: returns null when no peer-initiated stream
    /// is pending, instead of returning error.WouldBlock like acceptStream().
    /// Used by the multiplexed connection handler to poll for new streams
    /// while servicing the first stream inline.
    pub fn tryAcceptStream(self: *QuicConnection) ?*QuicStream {
        const qc = self.quic_connection orelse return null;
        const stream_id = api.acceptStream(qc) catch return null;
        const stream = self.allocator.create(QuicStream) catch return null;
        stream.* = QuicStream{
            .allocator = self.allocator,
            .connection = self.inner,
            .stream_id = stream_id,
            .poll_sync = self.poll_sync,
            .shutdown_requested = &self.shutdown_requested,
            .tracking_index = self.streams.items.len,
        };
        self.streams.append(self.allocator, stream) catch {
            self.allocator.destroy(stream);
            return null;
        };
        return stream;
    }

    pub fn isDrained(self: *QuicConnection) bool {
        const qc = self.quic_connection orelse return true;
        return api.isDrained(qc);
    }

    pub fn isHandshakeConfirmed(self: *QuicConnection) bool {
        const qc = self.quic_connection orelse return false;
        return api.isHandshakeConfirmed(qc);
    }

    /// Retrieve the peer's leaf certificate in DER format from the TLS handshake.
    /// Returns null if no client certificate was presented or the TLS context is unavailable.
    /// CANARY: REQ=REQ-AUTH-MTLS-QUIC-001; FEATURE="mTLS over QUIC"; ASPECT=PeerCertExtraction; STATUS=TESTED; TEST=geodetestlab-cli/specs/authn_mtls_rejection_matrix.yml; OWNER=transport; UPDATED=2026-06-11
    pub fn getPeerCertificateDer(self: *QuicConnection) ?[]const u8 {
        const qc = self.quic_connection orelse return null;
        const tls_ctx = qc.tls_context orelse return null;
        const chain = tls_ctx.peer_cert_chain orelse return null;
        if (chain.len == 0) return null;
        return chain[0];
    }

    /// Return a human-readable IP string for the peer (e.g. "192.168.1.1").
    /// Falls back to "unknown" when the underlying connection is closed or the
    /// address family is unrecognised.
    /// CANARY: REQ=REQ-SEC-RATE-LIMIT-002; FEATURE="AuthRateLimiting"; ASPECT=PeerIPExtraction; STATUS=TESTED; TEST=geodetestlab-cli/specs/authn_rate_limiter.yml; OWNER=transport; UPDATED=2026-06-11
    pub fn getPeerAddressString(self: *QuicConnection, allocator: std.mem.Allocator) []const u8 {
        const qc = self.quic_connection orelse return "unknown";
        const peer = &qc.peer;
        const fam = peer.family();
        if (fam == std.posix.AF.INET) {
            const ip_bytes = peer.getIpBytes();
            if (ip_bytes.len == 4) {
                return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                    ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3],
                }) catch "unknown";
            }
        } else if (fam == std.posix.AF.INET6) {
            const ip_bytes = peer.getIpBytes();
            if (ip_bytes.len == 16) {
                return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{
                    ip_bytes[0],  ip_bytes[1],  ip_bytes[2],  ip_bytes[3],
                    ip_bytes[4],  ip_bytes[5],  ip_bytes[6],  ip_bytes[7],
                    ip_bytes[8],  ip_bytes[9],  ip_bytes[10], ip_bytes[11],
                    ip_bytes[12], ip_bytes[13], ip_bytes[14], ip_bytes[15],
                }) catch "unknown";
            }
        }
        return "unknown";
    }

    /// Remove a stream from tracking and destroy it
    /// CANARY: REQ=REQ-QUIC-STREAM-CLEANUP-001; FEATURE="StreamMemoryManagement"; ASPECT=DoubleFreePrevention; STATUS=EXEMPT; OWNER=transport; UPDATED=2025-12-27
    /// GAP-0201: Use swapRemove for O(1) removal instead of O(n) orderedRemove
    /// CANARY: REQ=REQ-PERF-STREAM-REMOVE-001; FEATURE="StreamRemovalOptimization"; ASPECT=O1Removal; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-01-30
    pub fn destroyStream(self: *QuicConnection, stream: *QuicStream) void {
        // Prefer O(1) removal using stream-tracked index.
        var idx = stream.tracking_index;
        if (idx >= self.streams.items.len or self.streams.items[idx] != stream) {
            // Fallback for defensive consistency if index drifted.
            idx = 0;
            while (idx < self.streams.items.len and self.streams.items[idx] != stream) : (idx += 1) {}
            if (idx >= self.streams.items.len) {
                self.allocator.destroy(stream);
                return;
            }
        }

        _ = self.streams.swapRemove(idx);
        if (idx < self.streams.items.len) {
            self.streams.items[idx].tracking_index = idx;
        }
        // Now destroy the stream
        self.allocator.destroy(stream);
    }

    pub fn close(self: *QuicConnection) void {
        self.shutdown_requested.store(true, .release);
        if (self.poll_sync) |ps| ps.enterIo();
        defer {
            if (self.poll_sync) |ps| ps.leaveIo();
        }
        for (self.streams.items) |stream| {
            self.inner.closeStream(stream.stream_id, 0) catch {}; // Best-effort cleanup
            self.allocator.destroy(stream);
        }
        self.streams.deinit(self.allocator);
        // CANARY: REQ=REQ-QUIC-CONN-CLEANUP-001; FEATURE="ConnectionMemoryManagement"; ASPECT=ResourceLeak; STATUS=EXEMPT; OWNER=transport; UPDATED=2025-12-27
        // Use quic_connection and null it out to prevent double-close.
        if (self.quic_connection) |qc| {
            api.closeConnection(qc, 0) catch {}; // Best-effort cleanup
            self.quic_connection = null;
        }
    }

    pub fn requestShutdown(self: *QuicConnection) void {
        self.shutdown_requested.store(true, .release);
        if (self.quic_connection) |qc| {
            api.closeConnection(qc, 0) catch {}; // Best-effort close signal.
        }
        if (self.poll_sync) |ps| ps.notifyPoll();
    }

    // CANARY: REQ=REQ-QUIC-HC-037; FEATURE="QUIC High-Concurrency Requests"; ASPECT=PerConnectionRxWake; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
    pub fn readGeneration(self: *const QuicConnection) u32 {
        return self.inner.rx_data_generation.load(.acquire);
    }

    pub fn waitForReadGeneration(self: *QuicConnection, observed: u32, timeout_ns: u64) void {
        if (timeout_ns == 0) return;

        const io = std.Io.Threaded.global_single_threaded.io();
        const start_ns = monoNsRaw();
        var remaining_ns = timeout_ns;

        while (true) {
            const current = self.inner.rx_data_generation.load(.acquire);
            if (current != observed) return;
            if (self.shutdown_requested.load(.acquire)) return;

            const timeout: std.Io.Timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(@intCast(remaining_ns)),
                .clock = .awake,
            } };
            io.futexWaitTimeout(u32, &self.inner.rx_data_generation.raw, current, timeout) catch |err| switch (err) {
                error.Canceled => return,
            };

            if (self.inner.rx_data_generation.load(.acquire) != observed) return;
            const elapsed_ns = monoNsRaw() -| start_ns;
            if (elapsed_ns >= timeout_ns) return;
            remaining_ns = timeout_ns - elapsed_ns;
        }
    }
};

pub const QuicStream = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    stream_id: u64,
    /// Shared poll synchronization — see PollSync docs.
    poll_sync: ?*PollSync = null,
    shutdown_requested: ?*std.atomic.Value(bool) = null,
    tracking_index: usize = 0,

    pub fn write(self: *QuicStream, data: []const u8) !usize {
        if (self.shutdown_requested) |shutdown| {
            if (shutdown.load(.acquire)) return QuicError.Closed;
        }
        // QUIC library v0.1.10: writeStream is internally thread-safe
        // (per-connection mutex protects stream state). No PollSync needed.
        const written = try self.connection.writeStream(self.stream_id, data, false);
        if (written > 0) {
            @import("otel_metrics").recordTransportBytes(.transmit, written);
        }
        return written;
    }

    pub fn writeAll(self: *QuicStream, data: []const u8) !void {
        quic_response_metrics.recordStreamWriteStart(data.len);
        const write_start_ns = monoNsRaw();
        var written: usize = 0;
        var blocked_retries: usize = 0;
        var blocked_start_ns: u64 = 0;
        const max_blocked_retries: usize = 1_000_000; // safety cap; wall-clock deadline is authoritative
        while (written < data.len) {
            if (self.shutdown_requested) |shutdown| {
                if (shutdown.load(.acquire)) {
                    _ = quic_response_metrics.stream_write_errors_total.fetchAdd(1, .monotonic);
                    return QuicError.Closed;
                }
            }
            const observed_credit_generation = self.connection.tx_credit_generation.load(.acquire);
            const n = self.connection.writeStream(self.stream_id, data[written..], false) catch |err| {
                if (err == error.FlowControlBlocked or err == error.WouldBlock) {
                    quic_response_metrics.recordStreamWriteBlocked(err);
                    if (blocked_start_ns == 0) blocked_start_ns = monoNsRaw();
                    blocked_retries += 1;
                    if (blocked_retries > max_blocked_retries or monoNsRaw() -| blocked_start_ns > server_writer_max_blocked_ns) {
                        _ = quic_response_metrics.stream_write_timeouts_total.fetchAdd(1, .monotonic);
                        return QuicError.WriteError;
                    }
                    waitForServerWriterProgress(self, blocked_retries, observed_credit_generation);
                    continue;
                }
                _ = quic_response_metrics.stream_write_errors_total.fetchAdd(1, .monotonic);
                return err;
            };
            if (n == 0) {
                // Congestion window full — retry with backoff (same as FlowControlBlocked)
                quic_response_metrics.recordStreamWriteZeroReturn();
                if (blocked_start_ns == 0) blocked_start_ns = monoNsRaw();
                blocked_retries += 1;
                if (blocked_retries > max_blocked_retries or monoNsRaw() -| blocked_start_ns > server_writer_max_blocked_ns) {
                    _ = quic_response_metrics.stream_write_timeouts_total.fetchAdd(1, .monotonic);
                    return QuicError.WriteError;
                }
                waitForServerWriterProgress(self, blocked_retries, observed_credit_generation);
                continue;
            }
            written += n;
            blocked_retries = 0;
            blocked_start_ns = 0;
        }
        quic_response_metrics.recordStreamWriteSuccess(written, monoNsRaw() -| write_start_ns);
    }

    pub fn read(self: *QuicStream, buffer: []u8) !usize {
        if (self.shutdown_requested) |shutdown| {
            if (shutdown.load(.acquire)) return QuicError.Closed;
        }
        // QUIC library v0.1.10: readStream is internally thread-safe
        // (per-connection mutex protects stream reassembly buffers).
        const n_read = try self.connection.readStream(self.stream_id, buffer);
        if (n_read > 0) {
            @import("otel_metrics").recordTransportBytes(.receive, n_read);
        }
        return n_read;
    }

    // CANARY: REQ=REQ-QUIC-HC-037; FEATURE="QUIC High-Concurrency Requests"; ASPECT=PerConnectionRxWake; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
    /// Snapshot the vendored connection's RX generation before attempting a
    /// read. If the read returns WouldBlock, waitForReadGeneration parks on
    /// this per-connection generation rather than the endpoint-wide poll
    /// generation, so a packet for one connection does not wake every reader.
    pub fn readGeneration(self: *const QuicStream) u32 {
        return self.connection.rx_data_generation.load(.acquire);
    }

    pub fn debugRxAvailable(self: *QuicStream) usize {
        self.connection.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.connection.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        const rx = self.connection.streams_rx.getPtr(self.stream_id) orelse return 0;
        return rx.available();
    }

    pub fn debugRxRecvOffset(self: *QuicStream) u64 {
        self.connection.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.connection.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        const rx = self.connection.streams_rx.getPtr(self.stream_id) orelse return 0;
        return rx.recv_off;
    }

    pub fn setReadReadyNotifier(self: *QuicStream, ctx: *anyopaque, f: QuicReadReadyFn) void {
        self.connection.setRxReadyNotifier(ctx, f);
    }

    pub fn clearReadReadyNotifier(self: *QuicStream) void {
        self.connection.clearRxReadyNotifier();
    }

    pub fn waitForReadGeneration(self: *QuicStream, observed: u32, timeout_ns: u64) void {
        if (timeout_ns == 0) return;

        const io = std.Io.Threaded.global_single_threaded.io();
        const start_ns = monoNsRaw();
        var remaining_ns = timeout_ns;

        while (true) {
            const current = self.connection.rx_data_generation.load(.acquire);
            if (current != observed) return;
            if (self.shutdown_requested) |shutdown| {
                if (shutdown.load(.acquire)) return;
            }

            const timeout: std.Io.Timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(@intCast(remaining_ns)),
                .clock = .awake,
            } };
            io.futexWaitTimeout(u32, &self.connection.rx_data_generation.raw, current, timeout) catch |err| switch (err) {
                error.Canceled => return,
            };

            if (self.connection.rx_data_generation.load(.acquire) != observed) return;
            const elapsed_ns = monoNsRaw() -| start_ns;
            if (elapsed_ns >= timeout_ns) return;
            remaining_ns = timeout_ns - elapsed_ns;
        }
    }

    pub fn readLine(self: *QuicStream, max_size: usize) ![]u8 {
        var temp_buf = try self.allocator.alloc(u8, max_size);
        defer self.allocator.free(temp_buf);
        var pos: usize = 0;
        var retry_count: usize = 0;
        const max_retries: usize = 100; // Max 100 retries = 500ms wait time

        while (pos < max_size) {
            var byte: [1]u8 = undefined;
            const n = self.read(&byte) catch |err| {
                // If we haven't read anything yet, propagate WouldBlock
                if (err == error.WouldBlock and pos == 0) return error.WouldBlock;
                // If we've read some bytes but haven't found '\n' yet, keep trying
                // This implements polling behavior for complete lines
                if (err == error.WouldBlock) {
                    retry_count += 1;
                    if (retry_count > max_retries) {
                        // GAP-0200: Debug print removed from hot path for performance
                        return error.UnexpectedEndOfStream;
                    }
                    // GAP-0200: Reduced sleep from 5ms to 500μs for high throughput
                    compat_sleepNs(500 * std.time.ns_per_us);
                    continue;
                }
                return err;
            };

            if (n == 0) {
                // Stream ended - only return if we haven't read anything
                if (pos == 0) return error.EndOfStream;
                // If we've read partial data but no '\n', this is an error
                // (client sent incomplete line before FIN)
                // GAP-0200: Debug print removed from hot path for performance
                return error.UnexpectedEndOfStream;
            }

            temp_buf[pos] = byte[0];
            pos += 1;
            retry_count = 0; // Reset retry count when we successfully read a byte

            if (byte[0] == '\n') break;
        }

        if (pos == 0) return error.EndOfStream;

        const result = try self.allocator.alloc(u8, pos);
        @memcpy(result, temp_buf[0..pos]);

        // GAP-0200: Debug prints removed from hot path for performance
        return result;
    }

    pub fn close(self: *QuicStream) void {
        if (self.poll_sync) |ps| ps.enterIo();
        defer {
            if (self.poll_sync) |ps| ps.leaveIo();
        }
        self.connection.closeStream(self.stream_id, 0) catch {}; // Best-effort cleanup
    }

    pub fn finish(self: *QuicStream) !void {
        if (self.poll_sync) |ps| ps.enterIo();
        defer {
            if (self.poll_sync) |ps| ps.leaveIo();
        }
        _ = try self.connection.writeStream(self.stream_id, &.{}, true);
    }
};

/// Resolve a hostname to an IPv4 address string.
/// If the host is already an IP address, returns it unchanged (no allocation).
/// If it's a hostname, performs DNS resolution and returns an allocated IP string
/// that the caller must free.
fn resolveHostToIp(allocator: std.mem.Allocator, host: []const u8) !struct { ip: []const u8, allocated: bool } {
    // Fast path: already an IP address.
    if (std.Io.net.IpAddress.parseIp4(host, 0)) |_| {
        return .{ .ip = host, .allocated = false };
    } else |_| {}

    // Try IPv6.
    if (std.Io.net.IpAddress.parseIp6(host, 0)) |_| {
        return .{ .ip = host, .allocated = false };
    } else |_| {}

    // DNS resolution needed. GAP-0838 (Bug A): the bundled dns client issues a
    // bare A lookup with no resolv.conf `search`-domain expansion, so short
    // k8s headless peer names (e.g. `geode-0.geode`) return NXDOMAIN even
    // though the pod's glibc resolver finds them via the `search` list. Build
    // the search/ndots-ordered candidate list and try each until one resolves.
    // On any resolv.conf read failure `candidatesForHost` falls back to the
    // bare host name, so non-k8s environments behave exactly as before.
    const candidates = dns_search.candidatesForHost(allocator, host) catch {
        return error.InvalidAddress;
    };
    defer dns_search.freeCandidates(allocator, candidates);

    var client = dns.Client.init(allocator) catch {
        return error.InvalidAddress;
    };
    defer client.deinit();

    for (candidates) |candidate| {
        // ResolveResult.addresses is []const []const u8 — each entry is an
        // IP address string like "172.176.193.24" (not binary bytes).
        var result = client.resolveA(candidate) catch continue;
        defer result.deinit(allocator);
        if (result.addresses.len > 0) {
            const ip_str = try allocator.dupe(u8, result.addresses[0]);
            return .{ .ip = ip_str, .allocated = true };
        }
    }

    return error.InvalidAddress;
}

/// Resolve `host` (an FQDN or an IP literal) to an owned IPv4/IPv6 address
/// string. Caller owns the returned slice and must free it.
///
/// Used by the raft transport's periodic peer re-resolution: a k8s pod
/// reschedule moves a peer to a NEW IP, but a long-lived cached QUIC connection
/// keeps targeting the OLD IP and (when that IP becomes a silent blackhole)
/// never surfaces a send error to trigger a reconnect. Comparing a freshly
/// resolved IP against the live connection's IP detects the move so the stale
/// connection can be evicted and rebuilt against the current endpoint. An IP
/// literal resolves to itself, so a cluster addressed by raw IPs never churns.
pub fn resolveHostIpAlloc(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
    const r = try resolveHostToIp(allocator, host);
    const out = try allocator.dupe(u8, r.ip);
    if (r.allocated) allocator.free(@constCast(r.ip));
    return out;
}

/// GAP-0838: parse a PEM CA file into a DER trust-anchor chain.
///
/// The vendor api-client TLS path consumes inline DER trust anchors
/// (cfg.inline_ca_chain_der), not the ca_path string, so cluster TLS must parse
/// the CA itself. Every `-----BEGIN CERTIFICATE-----` block is parsed so a CA
/// bundle (root + intermediates) is trusted in full. Caller owns the returned
/// slice and each DER element (freed in QuicClient.deinit). Returns
/// error.NoCertificatesInCaFile when the file has no parseable certificate.
fn loadCaChainDer(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    const size: usize = @intCast(@min(st.size, 1024 * 1024));
    const pem = try allocator.alloc(u8, size);
    defer allocator.free(pem);
    _ = try file.readPositionalAll(io, pem, 0);
    return parsePemCertChain(allocator, pem);
}

/// Parse every `-----BEGIN CERTIFICATE-----` block in `pem` into a DER chain.
/// A malformed block is skipped so a valid bundle still loads. Returns
/// error.NoCertificatesInCaFile when no block parses. Caller owns the slice
/// and each element. Pure (no I/O) so it is unit-testable.
fn parsePemCertChain(allocator: std.mem.Allocator, pem: []const u8) ![]const []const u8 {
    var ders = std.ArrayList([]const u8).empty;
    errdefer {
        for (ders.items) |d| allocator.free(d);
        ders.deinit(allocator);
    }

    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, pem, search, begin_marker)) |b| {
        const e = std.mem.indexOfPos(u8, pem, b, end_marker) orelse break;
        const block_end = e + end_marker.len;
        const der = api.pem.parseCertificate(allocator, pem[b..block_end]) catch {
            // Skip a malformed block but keep any valid certificates.
            search = block_end;
            continue;
        };
        try ders.append(allocator, der);
        search = block_end;
    }
    if (ders.items.len == 0) return error.NoCertificatesInCaFile;
    return try ders.toOwnedSlice(allocator);
}

test "parsePemCertChain: single + multi-cert PEM bundle -> DER chain (GAP-0838)" {
    const allocator = std.testing.allocator;

    // No-cert input must error rather than return an empty chain.
    try std.testing.expectError(error.NoCertificatesInCaFile, parsePemCertChain(allocator, "not a cert"));

    // A real P-256 self-signed CA cert (PEM) loads as one DER entry.
    const real_ca =
        \\-----BEGIN CERTIFICATE-----
        \\MIIBhzCCAS2gAwIBAgIUJ6CMbLEVoIXcU/q+qA5iwVkPauEwCgYIKoZIzj0EAwIw
        \\GTEXMBUGA1UEAwwOZ2FwODM4LXRlc3QtY2EwHhcNMjYwNTMxMTI0NTI1WhcNMzYw
        \\NTI4MTI0NTI1WjAZMRcwFQYDVQQDDA5nYXA4MzgtdGVzdC1jYTBZMBMGByqGSM49
        \\AgEGCCqGSM49AwEHA0IABFldZSlqBRHc4WW5oFc0t/VzpY9rLSCw8v72dZC9H11S
        \\9cSQtvnDcw39RkP14uH+xGgo7kzQQY5qDklM5fRBw4mjUzBRMB0GA1UdDgQWBBRs
        \\Z3sXT0H9DDpGAlHA5L0vq+q4PzAfBgNVHSMEGDAWgBRsZ3sXT0H9DDpGAlHA5L0v
        \\q+q4PzAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCICpSWMBf6lAv
        \\ezUhsA35jcPhh1plsrLKH7X6C97xw0fWAiEAi0tla5rpYF3rSujSPuPExHNMVbTr
        \\FsRCzAiRbbxiaMI=
        \\-----END CERTIFICATE-----
    ;
    const single = try parsePemCertChain(allocator, real_ca);
    defer {
        for (single) |d| allocator.free(d);
        allocator.free(single);
    }
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expect(single[0].len > 0);
    try std.testing.expectEqual(@as(u8, 0x30), single[0][0]); // DER SEQUENCE tag

    // A bundle of two concatenated certs (root + intermediate style) -> two DERs.
    const bundle = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ real_ca, real_ca });
    defer allocator.free(bundle);
    const pair = try parsePemCertChain(allocator, bundle);
    defer {
        for (pair) |d| allocator.free(d);
        allocator.free(pair);
    }
    try std.testing.expectEqual(@as(usize, 2), pair.len);
}

pub const QuicClient = struct {
    allocator: std.mem.Allocator,
    /// Heap-allocated endpoint (via api.endpointInit / api.endpointDeinit).
    endpoint: ?*Endpoint = null,
    connection: ?*Connection = null,
    /// Heap-allocated QUIC config; freed in deinit().
    quic_config: ?*VendorQuicConfig = null,
    alpn_storage: [1][]const u8 = undefined,
    /// GAP-0838: DER-encoded CA trust anchors loaded from ca_cert_path, handed to
    /// the vendor TLS client via cfg.inline_ca_chain_der. Owns its backing; freed
    /// last in deinit() so it outlives any TLS context that references it.
    ca_chain_der: ?[]const []const u8 = null,

    pub fn init(allocator: std.mem.Allocator) QuicClient {
        return QuicClient{
            .allocator = allocator,
            .alpn_storage = [_][]const u8{"geode/1"},
        };
    }

    pub fn deinit(self: *QuicClient) void {
        // Let endpointDeinit handle connection cleanup — calling
        // closeConnection before deinit can leave dangling pointers
        // in the endpoint's connection map.
        self.connection = null;
        if (self.endpoint) |ep| {
            api.endpointDeinit(ep);
            self.endpoint = null;
        }
        if (self.quic_config) |cfg| {
            self.allocator.destroy(cfg);
            self.quic_config = null;
        }
        // GAP-0838: free CA trust anchors last — the destroyed config and any TLS
        // context built from it may have referenced this backing.
        if (self.ca_chain_der) |chain| {
            for (chain) |der| self.allocator.free(der);
            self.allocator.free(chain);
            self.ca_chain_der = null;
        }
    }

    pub fn connect(self: *QuicClient, host: []const u8, port: u16) !void {
        return self.connectInsecure(host, port, false);
    }

    pub fn connectInsecure(self: *QuicClient, address: []const u8, port: u16, allow_insecure: bool) !void {
        // CANARY: REQ=REQ-QUIC-LOCALHOST-001; FEATURE="LocalhostNormalization"; ASPECT=ClientConnect; STATUS=TESTED; TEST="QuicClient.connect normalizes localhost to 127.0.0.1 (GAP-0514 P3)"; OWNER=transport; UPDATED=2026-06-11
        // Issue #382: Normalize "localhost" to "127.0.0.1" for consistent DNS/TLS handling
        const normalized_address = if (std.mem.eql(u8, address, "localhost"))
            "127.0.0.1"
        else
            address;

        // Resolve hostname to IP for the vendor QUIC library (which cannot resolve DNS).
        // Keep the original hostname for TLS SNI verification.
        const resolved = try resolveHostToIp(self.allocator, normalized_address);
        defer if (resolved.allocated) self.allocator.free(resolved.ip);

        // Allocate QUIC config on the heap so the alpn_storage slice remains valid.
        const cfg = try self.allocator.create(VendorQuicConfig);
        errdefer {
            self.allocator.destroy(cfg);
            self.quic_config = null;
        }
        // ALPN is stored in struct field to persist beyond this function call
        cfg.* = VendorQuicConfig{
            .version = .v1,
            .alpn = &self.alpn_storage,
            .cc = .cubic,
            .enable_datagram = false,
            .enable_spin_bit = false,
            .grease = true,
            .compatible_vn = false,
            .enable_retry = false,
            .token_secret = null,
            .token_expiry_ms = 60000,
            .enable_pacing = false,
            .max_datagram_size = 1200,
            .initial_congestion_window_packets = high_concurrency_initial_cwnd_packets,
            // GAP-0259: Match server idle timeout (300s) to prevent premature disconnect during bulk writes
            .max_idle_timeout_ms = 300000,
            .max_udp_payload = 1350,
            .cert_path = null,
            .key_path = null,
            .ca_path = null,
            .allow_insecure = allow_insecure,
            .aead_confidentiality_limit_override = null,
            .aead_integrity_limit_override = null,
            .inline_server_cert_der = null,
            .inline_server_priv_p256 = null,
        };
        self.quic_config = cfg;

        // Initialize client endpoint using api.endpointInit (heap-allocates Endpoint).
        self.endpoint = try api.endpointInit(&self.allocator, "0.0.0.0:0", cfg);

        // Create server address string using resolved IP.
        const server_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ resolved.ip, port });
        defer self.allocator.free(server_addr);

        // Connect to server using public API.
        // SNI always uses original hostname so server can match its certificate.
        self.connection = try api.connect(self.endpoint.?, server_addr, normalized_address);
    }

    pub fn connectEx(self: *QuicClient, address: []const u8, port: u16, ca_cert_path: ?[]const u8, client_cert_path: ?[]const u8, client_key_path: ?[]const u8) !void {
        // CANARY: REQ=REQ-QUIC-LOCALHOST-002; FEATURE="LocalhostNormalization"; ASPECT=ClientConnectEx; STATUS=IMPL; OWNER=transport; UPDATED=2026-06-11
        // NOTE(GAP-0514 P3): stays IMPL — connectEx is only exercised by the cluster
        // CA-TLS path (cluster.zig / raft_consensus.zig), which always dials distinct
        // IPs, never "localhost". The identical normalization in connectInsecure IS
        // tested (REQ-QUIC-LOCALHOST-001, test-remote-kms); promoting this lane needs
        // a CA-cert localhost connect harness.
        // Issue #382: Normalize "localhost" to "127.0.0.1" for consistent DNS/TLS handling
        const normalized_address = if (std.mem.eql(u8, address, "localhost"))
            "127.0.0.1"
        else
            address;

        // Resolve hostname to IP for the vendor QUIC library (which cannot resolve DNS).
        const resolved = try resolveHostToIp(self.allocator, normalized_address);
        defer if (resolved.allocated) self.allocator.free(resolved.ip);

        // GAP-0838: the vendor api-client TLS path validates the server cert against
        // cfg.inline_ca_chain_der (DER trust anchors), NOT cfg.ca_path (a path string).
        // Load the CA bundle here so cluster TLS actually has a trust anchor and can
        // complete a leaf-only server chain. Owned by self; freed in deinit().
        if (ca_cert_path) |ca_p| {
            self.ca_chain_der = loadCaChainDer(self.allocator, ca_p) catch |err| blk: {
                tlog.warn("cluster TLS: failed to load CA chain; proceeding without pinned anchor", &.{
                    Attr.string("path", ca_p),
                    Attr.string("error", @errorName(err)),
                });
                break :blk null;
            };
        }

        // Allocate QUIC config on the heap so the alpn_storage slice remains valid.
        const cfg = try self.allocator.create(VendorQuicConfig);
        errdefer {
            self.allocator.destroy(cfg);
            self.quic_config = null;
        }
        cfg.* = VendorQuicConfig{
            .version = .v1,
            .alpn = &self.alpn_storage,
            .cc = .cubic,
            .enable_datagram = false,
            .enable_spin_bit = false,
            .grease = true,
            .compatible_vn = false,
            .enable_retry = false,
            .token_secret = null,
            .token_expiry_ms = 60000,
            .enable_pacing = false,
            .max_datagram_size = 1200,
            .initial_congestion_window_packets = high_concurrency_initial_cwnd_packets,
            // GAP-0259: Match server idle timeout (300s) to prevent premature disconnect during bulk writes
            .max_idle_timeout_ms = 300000,
            .max_udp_payload = 1350,
            .cert_path = client_cert_path,
            .key_path = client_key_path,
            .ca_path = ca_cert_path,
            .allow_insecure = false,
            .aead_confidentiality_limit_override = null,
            .aead_integrity_limit_override = null,
            .inline_server_cert_der = null,
            .inline_server_priv_p256 = null,
            // GAP-0838: hand the loaded CA trust anchors to the vendor TLS client.
            .inline_ca_chain_der = self.ca_chain_der,
        };
        self.quic_config = cfg;

        // Initialize client endpoint using api.endpointInit (heap-allocates Endpoint).
        self.endpoint = try api.endpointInit(&self.allocator, "0.0.0.0:0", cfg);

        // Create server address string using resolved IP.
        const server_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ resolved.ip, port });
        defer self.allocator.free(server_addr);

        // Connect to server using public API. SNI uses original hostname for TLS.
        self.connection = try api.connect(self.endpoint.?, server_addr, normalized_address);
    }

    pub fn waitForHandshake(self: *QuicClient, timeout_secs: u32) !void {
        if (self.endpoint == null or self.connection == null) {
            return QuicError.InvalidState;
        }

        const timeout_ns = @as(u64, timeout_secs) * std.time.ns_per_s;
        const nowNs = struct {
            fn f() i128 {
                var ts: std.os.linux.timespec = undefined;
                _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
                return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
            }
        }.f;
        const start = nowNs();

        while (nowNs() - start < timeout_ns) {
            try api.poll(self.endpoint.?, 10);
            if (api.isHandshakeConfirmed(self.connection.?)) {
                return;
            }
            // GAP-0200: Reduced sleep from 10ms to 1ms for faster handshake completion
            {
                const req = std.os.linux.timespec{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                var rem: std.os.linux.timespec = undefined;
                _ = std.os.linux.nanosleep(&req, &rem);
            }
        }

        return QuicError.HandshakeError;
    }

    pub fn openStream(self: *QuicClient, bidirectional: bool) !*QuicClientStream {
        if (self.connection == null) return QuicError.InvalidState;

        const stream_id = try self.connection.?.openStream(bidirectional);

        const stream = try self.allocator.create(QuicClientStream);
        stream.* = QuicClientStream{
            .allocator = self.allocator,
            .connection = self.connection.?,
            .stream_id = stream_id,
            .endpoint = self.endpoint.?,
        };
        return stream;
    }

    pub fn getStream(self: *QuicClient) !*QuicClientStream {
        return self.openStream(true);
    }

    pub fn poll(self: *QuicClient, timeout_ms: u32) !void {
        if (self.endpoint) |ep| {
            const timeout_i32: i32 = if (timeout_ms > std.math.maxInt(i32))
                std.math.maxInt(i32)
            else
                @intCast(timeout_ms);
            try api.poll(ep, timeout_i32);
        }
    }

    pub fn debugLocalPort(self: *QuicClient) u16 {
        const ep = self.endpoint orelse return 0;
        const addr = ep.transport.getLocalAddr() catch return 0;
        return switch (addr.storage.family) {
            std.posix.AF.INET => blk: {
                const sin: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&addr.storage));
                break :blk std.mem.bigToNative(u16, sin.port);
            },
            std.posix.AF.INET6 => blk: {
                const sin6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(&addr.storage));
                break :blk std.mem.bigToNative(u16, sin6.port);
            },
            else => 0,
        };
    }
};

pub const QuicClientStream = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    stream_id: u64,
    endpoint: *Endpoint,

    pub fn write(self: *QuicClientStream, data: []const u8) !usize {
        return self.connection.writeStream(self.stream_id, data, false);
    }

    pub fn writeAll(self: *QuicClientStream, data: []const u8) !void {
        var written: usize = 0;
        var blocked_retries: usize = 0;
        const start_ns = monoNsRaw();
        const max_blocked_ns: u64 = client_writer_max_blocked_ns;
        const max_blocked_retries: usize = 1_000_000; // safety cap; wall-clock deadline is authoritative
        while (written < data.len) {
            if (monoNsRaw() -| start_ns > max_blocked_ns) return QuicError.WriteError;
            const n = self.write(data[written..]) catch |err| {
                if (err == error.FlowControlBlocked or err == error.WouldBlock) {
                    blocked_retries += 1;
                    if (blocked_retries > max_blocked_retries) return QuicError.WriteError;
                    // Poll to process incoming frames, then retry
                    api.poll(self.endpoint, 1) catch {}; // Best-effort poll for flow control
                    compat_sleepNs(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            if (n == 0) {
                // Congestion window full: poll to process ACKs, then retry
                blocked_retries += 1;
                if (blocked_retries > max_blocked_retries) return QuicError.WriteError;
                api.poll(self.endpoint, 1) catch {}; // Best-effort poll for congestion
                compat_sleepNs(1 * std.time.ns_per_ms);
                continue;
            }
            written += n;
            blocked_retries = 0;
        }
    }

    // CANARY: REQ=REQ-QUIC-HC-005; FEATURE="QUIC High-Concurrency Client Wait"; ASPECT=StreamReadPollCadence; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-25
    pub fn read(self: *QuicClientStream, buffer: []u8) !usize {
        // DEBUG: Track read attempts
        const debug_read = false; // Set to true to enable verbose read debugging
        if (debug_read) std.debug.print("[QUIC] read: calling readStream\n", .{});

        const result = self.connection.readStream(self.stream_id, buffer) catch |err| {
            if (err == error.WouldBlock) {
                if (debug_read) std.debug.print("[QUIC] read: WouldBlock, polling\n", .{});
                // Drive already-arrived packets without adding a fixed 10ms
                // latency floor to every WouldBlock retry.
                api.poll(self.endpoint, 0) catch {}; // Best-effort poll for incoming data
                return error.WouldBlock;
            }
            if (debug_read) std.debug.print("[QUIC] read: error {}\n", .{err});
            return err;
        };
        if (debug_read) std.debug.print("[QUIC] read: got {} bytes\n", .{result});
        if (result == 0) {
            api.poll(self.endpoint, 0) catch {}; // Best-effort poll for incoming data
        }
        return result;
    }

    // CANARY: REQ=REQ-QUIC-CLIENT-READLINE-001; FEATURE="QuicClientReadLine"; ASPECT=RetryLogic; STATUS=TESTED; TEST="QuicClientStream.readLine: WouldBlock on quiet stream, Interrupted with armed callback (GAP-0514 P3)"; OWNER=transport; UPDATED=2026-06-11
    // Issue #413: Add retry logic for WouldBlock when partial data has been read
    // This matches the server-side QuicStream.readLine() behavior for consistency
    // CANARY: REQ=REQ-SHELL-INTERRUPT-034; FEATURE="SourceInterrupt"; ASPECT=QuicReadLineTimeout; STATUS=TESTED; TEST="QuicClientStream.readLine: WouldBlock on quiet stream, Interrupted with armed callback (GAP-0514 P3)"; OWNER=transport; UPDATED=2026-06-11
    // CANARY: REQ=REQ-SHELL-INTERRUPT-038; FEATURE="SourceInterrupt"; ASPECT=QuicReadLineInterrupt; STATUS=TESTED; TEST="QuicClientStream.readLine: WouldBlock on quiet stream, Interrupted with armed callback (GAP-0514 P3)"; OWNER=transport; UPDATED=2026-06-11
    // Added interrupt callback to allow Ctrl+C detection during long server operations
    pub fn readLine(self: *QuicClientStream, max_size: usize) ![]u8 {
        return self.readLineWithInterrupt(max_size, null);
    }

    /// readLine with optional interrupt checking callback
    /// If interrupt_check returns true, returns error.Interrupted
    pub fn readLineWithInterrupt(self: *QuicClientStream, max_size: usize, interrupt_check: ?*const fn () bool) ![]u8 {
        var temp_buf = try self.allocator.alloc(u8, max_size);
        defer self.allocator.free(temp_buf);
        var pos: usize = 0;
        var retry_count: usize = 0;
        const max_retries: usize = 20; // Max 20 retries = ~100ms, allows frequent interrupt checks

        while (pos < max_size) {
            // Check for interrupt before each read attempt
            if (interrupt_check) |check_fn| {
                if (check_fn()) {
                    return error.Interrupted;
                }
            }

            var byte: [1]u8 = undefined;
            const n = self.read(&byte) catch |err| {
                // If we haven't read anything yet, propagate WouldBlock
                if (err == error.WouldBlock and pos == 0) return error.WouldBlock;
                // If we've read some bytes but haven't found '\n' yet, keep trying
                // This implements polling behavior for complete lines
                if (err == error.WouldBlock) {
                    retry_count += 1;
                    if (retry_count > max_retries) {
                        // Timeout waiting for complete line - return WouldBlock so caller can check interrupts
                        if (pos == 0) return error.WouldBlock;
                        return error.UnexpectedEndOfStream;
                    }
                    // Poll for incoming data and wait before retrying
                    api.poll(self.endpoint, 1) catch {}; // Best-effort poll for incoming data
                    compat_sleepNs(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };

            if (n == 0) {
                // No data available yet - poll and retry
                if (pos == 0) return error.WouldBlock;
                // If we've read partial data, retry a few times for complete line
                retry_count += 1;
                if (retry_count > max_retries) {
                    return error.UnexpectedEndOfStream;
                }
                api.poll(self.endpoint, 1) catch {}; // Best-effort poll for incoming data
                compat_sleepNs(1 * std.time.ns_per_ms);
                continue;
            }

            temp_buf[pos] = byte[0];
            pos += 1;
            retry_count = 0; // Reset retry count when we successfully read a byte

            if (byte[0] == '\n') break;
        }

        if (pos == 0) return error.EndOfStream;

        const result = try self.allocator.alloc(u8, pos);
        @memcpy(result, temp_buf[0..pos]);
        return result;
    }

    pub fn close(self: *QuicClientStream) void {
        self.connection.closeStream(self.stream_id, 0) catch {}; // Best-effort cleanup
        self.allocator.destroy(self);
    }

    pub fn deinit(self: *QuicClientStream) void {
        self.close();
    }

    pub fn finish(self: *QuicClientStream) !void {
        _ = try self.connection.writeStream(self.stream_id, &.{}, true);
    }
};

// --- Unit tests for PollSync ---

test "PollSync: waitForPoll times out without signal" {
    var ps = PollSync{};
    const start = std.time.nanoTimestamp();
    ps.waitForPoll(10 * std.time.ns_per_ms);
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    try std.testing.expect(elapsed_ns >= 8 * std.time.ns_per_ms);
    try std.testing.expect(elapsed_ns < 100 * std.time.ns_per_ms);
}

test "PollSync: waitForPoll wakes on poll generation advance" {
    var ps = PollSync{};
    const t = try std.Thread.spawn(.{}, struct {
        fn run(sync: *PollSync) void {
            compat_sleepNs(5 * std.time.ns_per_ms);
            sync.notifyPoll();
        }
    }.run, .{&ps});
    const start = std.time.nanoTimestamp();
    ps.waitForPoll(200 * std.time.ns_per_ms); // should return in ~5ms, not 200ms
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    try std.testing.expect(elapsed_ns < 100 * std.time.ns_per_ms);
    t.join();
}

test "PollSync: enterIo/leaveIo/enterPoll/leavePoll still correct" {
    var ps = PollSync{};
    ps.enterIo();
    ps.enterIo();
    try std.testing.expectEqual(@as(u32, 2), ps.active_io_count);
    ps.leaveIo();
    ps.leaveIo();
    try std.testing.expectEqual(@as(u32, 0), ps.active_io_count);
    ps.enterPoll();
    try std.testing.expect(ps.poll_requested);
    ps.leavePoll();
    try std.testing.expect(!ps.poll_requested);
}
