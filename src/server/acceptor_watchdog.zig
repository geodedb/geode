// Accept-path wedge watchdog: detect a fully-wedged QUIC acceptor and
// auto-recover.
//
// docs/bugs/2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md:
// under an extreme compound connection-burst, the QUIC acceptor can wedge on
// upstream `Endpoint.mu` contention (poll vs acceptStream). geode stays
// `1/1 Running` but stops draining new QUIC Initials — the :3141 UDP socket's
// rx_queue backs up to many megabytes (12.6 MB observed 2026-06-05) and new
// connections time out indefinitely. The geode-side bail-deadline fix
// (`303c9d38`) removed the worker-starvation amplifier but does NOT prevent the
// wedge, and there was NO automatic recovery — operators had to
// `kubectl delete pod`. The standard liveness probe (`grep :0C45 /proc/net/udp`)
// passes throughout because the socket stays bound.
//
// This watchdog samples the listener's UDP rx_queue depth on the existing
// metrics-loop tick. A healthy acceptor keeps rx_queue at 0–few KB; a wedged
// one lets it grow to megabytes and never recede. When rx_queue stays at/above
// a (tunable) threshold continuously for longer than a (tunable) deadline, the
// watchdog triggers a controlled, loudly-logged self-restart (process exit) so
// the Kubernetes restart policy recovers the pod automatically — converting a
// silent, manual-restart outage into automatic recovery within the deadline.
//
// Everything decision-related here is a pure function (no env, no syscalls, no
// process exit) so it is unit-testable. The single side effect (read
// /proc/net/udp; exit the process) lives in the caller. (SONNY-1219c: this note
// used to point at `parseAcceptorBailMs` / `waitForAcceptorExit` in
// quic_connection_handler.zig as the model for that split; SONNY-1219b deleted
// both along with the acceptor bail path. The watchdog itself is live and
// unrelated to that change.)
//
// CANARY: REQ=REQ-QUIC-ACCEPTOR-WEDGE-WATCHDOG; FEATURE="QUIC High-Concurrency Connection Admission"; ASPECT=AcceptPathWedgeAutoRecovery; STATUS=TESTED; TEST=src/server/acceptor_watchdog.zig; OWNER=transport; UPDATED=2026-06-05

const std = @import("std");
const builtin = @import("builtin");

/// rx_queue threshold (bytes) above which the listener UDP socket is considered
/// to be backing up. Healthy is 0–~4 KB; the 2026-06-05 wedge hit ~12.6 MB.
/// 8 MiB is far above any transient legitimate burst yet well below the
/// observed wedge depth, so it never false-positives on a busy-but-draining
/// socket.
pub const default_rx_threshold_bytes: u64 = 8 * 1024 * 1024;

/// How long rx_queue must stay continuously at/above the threshold before the
/// watchdog self-restarts. 30 s of a non-draining multi-MB backlog is
/// unambiguously a wedge (a healthy acceptor drains the queue within
/// milliseconds), and is short enough to recover well inside a typical
/// connection-retry budget.
pub const default_deadline_ms: i64 = 30_000;

const min_deadline_ms: i64 = 1_000;
const max_deadline_ms: i64 = 600_000; // 10 min

pub const Config = struct {
    enabled: bool = true,
    rx_threshold_bytes: u64 = default_rx_threshold_bytes,
    deadline_ms: i64 = default_deadline_ms,
};

/// Resolve the watchdog config from raw env-var strings. PURE (no env access)
/// so it is unit-testable. `disable_val` truthy ("1"/"true") disables the
/// watchdog entirely. Bad numeric values fall back to the defaults; the
/// deadline is clamped to [min_deadline_ms, max_deadline_ms].
pub fn parseConfig(rx_val: ?[]const u8, deadline_val: ?[]const u8, disable_val: ?[]const u8) Config {
    var cfg = Config{};

    if (disable_val) |d| {
        if (std.mem.eql(u8, d, "1") or std.mem.eql(u8, d, "true")) cfg.enabled = false;
    }

    if (rx_val) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t\r\n"), 10)) |n| {
            if (n > 0) cfg.rx_threshold_bytes = n;
        } else |_| {}
    }

    if (deadline_val) |v| {
        if (std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t\r\n"), 10)) |n| {
            cfg.deadline_ms = std.math.clamp(n, min_deadline_ms, max_deadline_ms);
        } else |_| {}
    }

    return cfg;
}

/// Parse `/proc/net/udp` (or `/proc/net/udp6`) contents and return the rx_queue
/// byte count for the row whose local port equals `local_port`. Returns null if
/// the port is not found. PURE (operates on a supplied buffer).
///
/// Row format (whitespace-separated):
///   sl  local_address rem_address st tx_queue:rx_queue tr tm->when ...
/// `local_address` is `HEXIP:HEXPORT`; field index 4 is `HEXTX:HEXRX`.
pub fn parseUdpRxQueueBytes(proc_net_udp: []const u8, local_port: u16) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, proc_net_udp, '\n');
    // Skip the header line ("  sl  local_address ...").
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // sl
        const local_addr = fields.next() orelse continue; // IP:PORT
        _ = fields.next() orelse continue; // rem_address
        _ = fields.next() orelse continue; // st
        const queues = fields.next() orelse continue; // tx:rx

        const colon = std.mem.lastIndexOfScalar(u8, local_addr, ':') orelse continue;
        const port_hex = local_addr[colon + 1 ..];
        const port = std.fmt.parseInt(u16, port_hex, 16) catch continue;
        if (port != local_port) continue;

        const qcolon = std.mem.indexOfScalar(u8, queues, ':') orelse continue;
        const rx_hex = queues[qcolon + 1 ..];
        const rx = std.fmt.parseInt(u64, rx_hex, 16) catch continue;
        return rx;
    }
    return null;
}

pub const Action = enum { ok, restart };

/// SONNY-2719: the most stall time one sample interval may add. The metrics
/// loop samples every 5 s; an interval much longer than that means the
/// watchdog itself did not run (the process was frozen, the host suspended
/// or starved of CPU), and nothing can be concluded about that span: the
/// acceptor did not run either.
pub const max_interval_credit_ms: i64 = 10_000;

// CANARY: REQ=REQ-SONNY-2719-PROGRESS-BASED-WEDGE; FEATURE="QUIC High-Concurrency Connection Admission"; ASPECT=StarvationIsNotAWedge; STATUS=TESTED; TEST=tests/test_sonny2719_starved_acceptor_survives.zig; OWNER=transport; UPDATED=2026-11-13
/// Tracks how long the listener has stayed backlogged with nothing drained.
/// `update` is PURE: feed it the current rx_queue, the endpoint's running
/// count of drained datagrams (`QuicTransport.getDatagramsDrained`), a
/// monotonic millisecond clock and the config; it returns `.restart` once the
/// acceptor has been backlogged without draining a datagram for the deadline.
/// Time is injected so it is deterministically testable.
///
/// SONNY-2719: the backlog alone is not a wedge. A starved acceptor (a 1-CPU
/// runner, a throttled container) or an overloaded one keeps a backlog while
/// it drains it, slower than datagrams arrive; restarting it drops every
/// connection and helps nothing. So the streak resets whenever a datagram was
/// drained since the previous sample, or a sample is below the threshold, and
/// one interval adds at most `max_interval_credit_ms`. A wedged acceptor
/// drains nothing and is restarted after the deadline, as before.
pub const WedgeTracker = struct {
    /// Backlogged, nothing drained, accumulated over consecutive samples.
    stalled_ms: i64 = 0,
    last_ms: ?i64 = null,
    last_drained: u64 = 0,
    last_high: bool = false,

    pub fn update(self: *WedgeTracker, rx_queue_bytes: u64, drained_total: u64, now_ms: i64, cfg: Config) Action {
        const prev_ms = self.last_ms;
        const prev_drained = self.last_drained;
        const prev_high = self.last_high;
        const high = cfg.enabled and rx_queue_bytes >= cfg.rx_threshold_bytes;
        self.last_ms = now_ms;
        self.last_drained = drained_total;
        self.last_high = high;

        // Below the threshold (or disabled), or the first backlogged sample
        // of a streak: nothing to attribute yet.
        if (!high or !prev_high or prev_ms == null) {
            self.stalled_ms = 0;
            return .ok;
        }
        // Drained since the last sample: slow, not wedged.
        if (drained_total != prev_drained) {
            self.stalled_ms = 0;
            return .ok;
        }
        const interval = std.math.clamp(now_ms -| prev_ms.?, 0, max_interval_credit_ms);
        self.stalled_ms +|= interval;
        if (self.stalled_ms >= cfg.deadline_ms) return .restart;
        return .ok;
    }
};

/// Read the rx_queue byte count for `local_port` from /proc/net/udp. Linux-only
/// (returns null elsewhere, and on any read/parse failure). Allocation-free:
/// reads into a caller-sized stack buffer via a raw `openat` (std.posix.close
/// was removed in Zig 0.16, so close via std.os.linux).
pub fn readListenerRxQueue(local_port: u16) ?u64 {
    if (comptime builtin.os.tag != .linux) return null;
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/net/udp", .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);
    // /proc/net/udp can be large on a busy host (one row per UDP socket); read
    // in a loop into a bounded buffer. 256 KiB covers thousands of rows.
    var buf: [256 * 1024]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        // Early-out: if we already saw our port, stop reading.
        if (parseUdpRxQueueBytes(buf[0..total], local_port)) |rx| return rx;
    }
    return parseUdpRxQueueBytes(buf[0..total], local_port);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const sample_proc_net_udp =
    "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops\n" ++
    "  100: 00000000:0035 00000000:0000 07 00000000:00000000 00:00000000 00000000   101        0 12345 2 0000000000000000 0\n" ++
    "  123: 0100007F:0C45 00000000:0000 07 00000000:00C103D9 00:00000000 00000000  1000        0 67890 2 0000000000000000 0\n" ++
    "  200: 00000000:1F90 00000000:0000 07 00000000:00001000 00:00000000 00000000  1000        0 11111 2 0000000000000000 0\n";

test "parseUdpRxQueueBytes: finds the wedged :3141 (0x0C45) row" {
    const rx = parseUdpRxQueueBytes(sample_proc_net_udp, 0x0C45).?;
    try std.testing.expectEqual(@as(u64, 0x00C103D9), rx); // 12,648,409 bytes
}

test "parseUdpRxQueueBytes: a healthy row reads ~0" {
    try std.testing.expectEqual(@as(u64, 0), parseUdpRxQueueBytes(sample_proc_net_udp, 0x0035).?);
    try std.testing.expectEqual(@as(u64, 0x1000), parseUdpRxQueueBytes(sample_proc_net_udp, 0x1F90).?);
}

test "parseUdpRxQueueBytes: missing port -> null" {
    try std.testing.expectEqual(@as(?u64, null), parseUdpRxQueueBytes(sample_proc_net_udp, 0x9999));
}

test "parseUdpRxQueueBytes: garbage line is skipped, not crashed" {
    const garbage = "header\nnot a valid row\n: : :\n";
    try std.testing.expectEqual(@as(?u64, null), parseUdpRxQueueBytes(garbage, 0x0C45));
}

test "parseConfig: defaults, disable, override, clamp" {
    const d = parseConfig(null, null, null);
    try std.testing.expect(d.enabled);
    try std.testing.expectEqual(default_rx_threshold_bytes, d.rx_threshold_bytes);
    try std.testing.expectEqual(default_deadline_ms, d.deadline_ms);

    try std.testing.expect(!parseConfig(null, null, "1").enabled);
    try std.testing.expect(!parseConfig(null, null, "true").enabled);

    const o = parseConfig("4194304", "5000", null);
    try std.testing.expectEqual(@as(u64, 4194304), o.rx_threshold_bytes);
    try std.testing.expectEqual(@as(i64, 5000), o.deadline_ms);

    // Clamp + bad-value fallback.
    try std.testing.expectEqual(min_deadline_ms, parseConfig(null, "10", null).deadline_ms);
    try std.testing.expectEqual(max_deadline_ms, parseConfig(null, "99999999", null).deadline_ms);
    try std.testing.expectEqual(default_deadline_ms, parseConfig(null, "abc", null).deadline_ms);
}

test "WedgeTracker: sustained backlog past the deadline triggers restart" {
    const cfg = Config{ .rx_threshold_bytes = 1000, .deadline_ms = 10_000 };
    var t = WedgeTracker{};
    // First high reading: streak starts, no restart yet.
    try std.testing.expectEqual(Action.ok, t.update(5000, 7, 1_000, cfg));
    // Still high, nothing drained, but inside the deadline.
    try std.testing.expectEqual(Action.ok, t.update(5000, 7, 9_000, cfg));
    // High with nothing drained for >= deadline -> restart.
    try std.testing.expectEqual(Action.restart, t.update(5000, 7, 11_001, cfg));
}

test "WedgeTracker: a dip below the threshold resets the streak (no false restart)" {
    const cfg = Config{ .rx_threshold_bytes = 1000, .deadline_ms = 10_000 };
    var t = WedgeTracker{};
    try std.testing.expectEqual(Action.ok, t.update(5000, 0, 1_000, cfg));
    try std.testing.expectEqual(Action.ok, t.update(5000, 0, 9_000, cfg));
    // Drained — reset.
    try std.testing.expectEqual(Action.ok, t.update(0, 0, 9_500, cfg));
    // Backs up again; the deadline restarts from here, so a reading that would
    // have tripped the old streak does NOT restart.
    try std.testing.expectEqual(Action.ok, t.update(5000, 0, 12_000, cfg));
    try std.testing.expectEqual(Action.ok, t.update(5000, 0, 21_000, cfg));
    try std.testing.expectEqual(Action.restart, t.update(5000, 0, 22_001, cfg));
}

test "WedgeTracker: disabled never restarts" {
    const cfg = Config{ .enabled = false, .rx_threshold_bytes = 1, .deadline_ms = 1 };
    var t = WedgeTracker{};
    try std.testing.expectEqual(Action.ok, t.update(1_000_000, 0, 1_000, cfg));
    try std.testing.expectEqual(Action.ok, t.update(1_000_000, 0, 1_000_000, cfg));
}

test "SONNY-2719 WedgeTracker: a backlogged acceptor that drains between samples is starved, not wedged" {
    const cfg = Config{ .rx_threshold_bytes = 1000, .deadline_ms = 10_000 };
    var t = WedgeTracker{};
    // Backlogged at every 5 s sample for ten minutes, a few datagrams
    // drained in each interval: never a restart.
    var now: i64 = 0;
    var drained: u64 = 0;
    while (now <= 600_000) : (now += 5_000) {
        try std.testing.expectEqual(Action.ok, t.update(8_000_000, drained, now, cfg));
        drained += 3;
    }
    // Then it stops draining with the backlog in place (`now` is the next
    // 5 s tick): a wedge, restarted after the deadline.
    drained -= 3;
    try std.testing.expectEqual(Action.ok, t.update(8_000_000, drained, now, cfg));
    try std.testing.expectEqual(Action.restart, t.update(8_000_000, drained, now + 5_000, cfg));
}

test "SONNY-2719 WedgeTracker: a sample interval the watchdog did not run through adds at most the interval credit" {
    const cfg = Config{ .rx_threshold_bytes = 1000, .deadline_ms = 30_000 };
    var t = WedgeTracker{};
    try std.testing.expectEqual(Action.ok, t.update(5000, 9, 0, cfg));
    // The whole process was frozen for a minute (SIGSTOP, a suspended VM, a
    // starved host): the acceptor could not drain either.
    try std.testing.expectEqual(Action.ok, t.update(5000, 9, 60_000, cfg));
    try std.testing.expectEqual(max_interval_credit_ms, t.stalled_ms);
    // Running again, it drains: the streak ends.
    try std.testing.expectEqual(Action.ok, t.update(5000, 50, 65_000, cfg));
    try std.testing.expectEqual(@as(i64, 0), t.stalled_ms);
    // A real wedge while the watchdog runs normally is still caught.
    var now: i64 = 65_000;
    var action: Action = .ok;
    while (action == .ok and now < 200_000) {
        now += 5_000;
        action = t.update(5000, 50, now, cfg);
    }
    try std.testing.expectEqual(Action.restart, action);
    try std.testing.expectEqual(@as(i64, 95_000), now);
}
