//! SONNY-6759: the statement cancel source of one gRPC RPC.
//!
//! The QUIC handler cancels a statement whose client went away through the
//! connection's `shutdown_requested` flag (SONNY-3390). A gRPC RPC had only
//! the server-wide shutdown flag (SONNY-6753), so a statement whose client
//! closed its connection or reset its HTTP/2 stream ran on to completion.
//!
//! The executor polls one atomic flag per row (`read_budget`), and the
//! vendored grpc_zig transport publishes neither event as one: RST_STREAM is
//! recorded per stream behind `Transport.flow_mutex` (`isStreamReset`, a
//! query), and the peer's disconnect only as the private `peer_gone` flag
//! (`isPeerGone` is not `pub`). So every in-flight RPC registers a `Watch`
//! here, and one watcher thread, alive while any RPC is registered, sets the
//! RPC's `cancel` flag when any of these holds:
//!   - the server is shutting down (the flag `handlePacket` used before),
//!   - the peer reset the RPC's stream (`Transport.isStreamReset`),
//!   - the peer closed or reset the TCP connection: the socket polls
//!     read-side hangup (POLLRDHUP, Linux), hangup or error. The socket stays
//!     open until the RPC's handler returns (the connection thread closes it
//!     after its dispatch loop), so the descriptor is the connection's for as
//!     long as the watch is registered.
//! The cancel lands within `poll_interval_ms` of the event.
//!
//! Lock order: `g_mutex` is taken before `Transport.flow_mutex` (inside
//! `isStreamReset`); nothing holds a transport lock while registering.
//!
//! CANARY: REQ=REQ-SONNY-6759-GRPC-DISCONNECT-CANCEL; FEATURE="GrpcServerLifecycle"; ASPECT=PerRpcCancel; STATUS=TESTED; TEST=tests/test_sonny6759_grpc_disconnect_cancel.zig; OWNER=transport; UPDATED=2026-11-18

const std = @import("std");
const builtin = @import("builtin");
const grpc_zig = @import("grpc_server");

pub const GrpcTransport = grpc_zig.Transport;

/// How often the watcher checks the registered RPCs.
pub const poll_interval_ms: u64 = 50;
/// The watcher thread exits after this long with nothing registered.
const idle_exit_ms: u64 = 2_000;

/// Read-side hangup (POLLRDHUP, the peer's FIN) where the platform reports
/// it: Linux (0x2000, which `std.os.linux.POLL` does not name) and the
/// systems whose `POLL` names it. Elsewhere only an abortive close (hangup,
/// error) is seen.
const rdhup: i16 = if (builtin.os.tag == .linux)
    0x2000
else if (@hasDecl(std.posix.POLL, "RDHUP"))
    std.posix.POLL.RDHUP
else
    0;
const closed_events: i16 = rdhup | std.posix.POLL.HUP | std.posix.POLL.ERR;

pub const Reason = enum(u8) { none, shutdown, stream_reset, peer_closed };

/// One in-flight RPC. Lives on its handler's stack between `register` and
/// `unregister`.
pub const Watch = struct {
    trans: *GrpcTransport,
    stream_id: u31,
    fd: std.posix.fd_t,
    shutdown: *const std.atomic.Value(bool),
    /// The RPC's statement cancel source (`read_budget.setStreamCancelSource`).
    cancel: std.atomic.Value(bool) = .init(false),
    reason: std.atomic.Value(u8) = .init(@intFromEnum(Reason.none)),
    prev: ?*Watch = null,
    next: ?*Watch = null,

    pub fn init(trans: *GrpcTransport, shutdown: *const std.atomic.Value(bool)) Watch {
        return .{
            .trans = trans,
            .stream_id = trans.last_stream_id,
            .fd = trans.stream.socket.handle,
            .shutdown = shutdown,
        };
    }

    pub fn cancelReason(self: *const Watch) Reason {
        return @enumFromInt(self.reason.load(.acquire));
    }
};

var g_mutex: std.Io.Mutex = .init;
var g_head: ?*Watch = null;
var g_running: bool = false;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Register `w` with the watcher, starting its thread if none runs. False
/// when the thread cannot be started; `w` is then not registered and the
/// caller falls back to the shutdown flag alone.
pub fn register(w: *Watch) bool {
    g_mutex.lockUncancelable(io());
    defer g_mutex.unlock(io());
    if (!g_running) {
        // The default stack: geode's static TLS alone is larger than a
        // small explicit stack, which pthread_create refuses (EINVAL).
        const thread = std.Thread.spawn(.{}, watcherMain, .{}) catch return false;
        thread.detach();
        g_running = true;
    }
    w.prev = null;
    w.next = g_head;
    if (g_head) |h| h.prev = w;
    g_head = w;
    return true;
}

/// Remove `w`. After this returns the watcher never touches `w` again.
pub fn unregister(w: *Watch) void {
    g_mutex.lockUncancelable(io());
    defer g_mutex.unlock(io());
    if (w.prev) |p| p.next = w.next else g_head = w.next;
    if (w.next) |n| n.prev = w.prev;
    w.prev = null;
    w.next = null;
}

fn peerClosed(fd: std.posix.fd_t) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = rdhup, .revents = 0 }};
    const n = std.posix.poll(&fds, 0) catch return false;
    return n > 0 and (fds[0].revents & closed_events) != 0;
}

/// `g_mutex` held.
fn check(w: *Watch) void {
    if (w.cancel.load(.acquire)) return;
    const why: Reason = if (w.shutdown.load(.acquire))
        .shutdown
    else if (w.trans.isStreamReset(w.stream_id))
        .stream_reset
    else if (peerClosed(w.fd))
        .peer_closed
    else
        return;
    w.reason.store(@intFromEnum(why), .release);
    w.cancel.store(true, .release);
}

fn watcherMain() void {
    var idle_ms: u64 = 0;
    while (true) {
        {
            g_mutex.lockUncancelable(io());
            defer g_mutex.unlock(io());
            if (g_head == null) {
                if (idle_ms >= idle_exit_ms) {
                    g_running = false;
                    return;
                }
                idle_ms += poll_interval_ms;
            } else {
                idle_ms = 0;
                var it = g_head;
                while (it) |w| : (it = w.next) check(w);
            }
        }
        io().sleep(.fromMilliseconds(poll_interval_ms), .awake) catch {};
    }
}
