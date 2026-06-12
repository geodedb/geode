// RED reproduction tests — k8s churn recovery, ROOT CAUSE #1 (RC1):
// receiver-side worker-pool starvation in src/distributed/cluster.zig.
//
// THE BUG (evidence-verified):
//   * Each accepted inbound cluster connection runs a long-lived
//     `handleQuicConnection` task on the fixed 4-thread `connection_pool`
//     (cluster.zig:1004-1007, submitted at :1207).
//   * For a half-open / zombie peer connection the accept loop NEVER exits:
//     `acceptStream()` returns `error.WouldBlock`, the handler sleeps 200µs and
//     `continue`s forever (cluster.zig:1337-1342) until the ~300 s QUIC idle
//     timeout finally tears the connection down.
//   * After 4 rapid pod kills, four zombie inbound connections pin all 4 worker
//     threads, so REBUILT outbound connections from peers are never serviced —
//     vote delivery is dead no matter what the sender does. The cluster wedges
//     all-candidate at a frozen term.
//
// INTENDED FIX CONTRACT A (what these tests pin):
//   The inbound-connection handler must REAP an idle connection and release its
//   worker after a bounded inactivity deadline (default ~30 s, env-overridable),
//   far below the ~300 s QUIC idle timeout. "Activity" = any accepted stream or
//   successfully read frame (the handler stamps a `last_activity_ms` on each).
//   The reap decision must be a PURE, unit-testable function (fake clock), in the
//   style of the existing stall-detector decision functions in raft_consensus.zig
//   (`shouldEvictOnStallArmed`, etc.).
//
// REQUIRED NEW SURFACE (the fixer implements these in src/distributed/cluster.zig
// as top-level `pub` decls, siblings to `gateUnreplicatedWrite`):
//
//   pub const inbound_connection_idle_deadline_ms: i64 = 30_000;
//
//   /// PURE: true iff we have observed NO activity on an inbound cluster
//   /// connection for longer than `deadline_ms`. Strict `>` so exactly-at-deadline
//   /// does NOT reap (one extra reaper tick of grace).
//   pub fn shouldReapIdleInboundConnection(now_ms: i64, last_activity_ms: i64, deadline_ms: i64) bool {
//       return (now_ms - last_activity_ms) > deadline_ms;
//   }
//
//   /// PURE: resolve the effective idle deadline from an optional env override
//   /// (e.g. GEODE_CLUSTER_INBOUND_IDLE_MS). A null / empty / non-numeric /
//   /// non-positive value falls back to the default. Kept pure (takes the raw
//   /// string, returns ms) so it is testable without touching the real env.
//   pub fn resolveInboundIdleDeadlineMs(env_value: ?[]const u8) i64 { ... }
//
// And the fixer wires `handleQuicConnection` to: (1) stamp `last_activity_ms`
// on each accepted stream / read frame; (2) in the `WouldBlock` branch, `return`
// (releasing the worker) when `shouldReapIdleInboundConnection(now, last, deadline)`
// — resolving `deadline` once via `resolveInboundIdleDeadlineMs`.
//
// RED MECHANISM: every test is guarded by `comptime @hasDecl(...)`. Until the
// fixer adds the named symbol the guard's else-branch returns an error, so the
// test FAILS (the missing-symbol then-branch is comptime-pruned, so the file
// still COMPILES). Once the symbol exists, the guard's then-branch runs the real
// behavioral assertions — implement it WRONG and the test stays red on the
// assertion. Do not edit these tests to make them pass; implement the contract.

const std = @import("std");
const geode = @import("geode");

const cluster = geode.distributed.cluster;

// The ~300 s QUIC idle timeout the reaper must beat by a wide margin. Not an
// exported constant; used here only as the upper-bound sanity ceiling.
const quic_idle_timeout_ms: i64 = 300_000;

// ---------------------------------------------------------------------------
// (A.1) A connection idle PAST the deadline is reaped.
// ---------------------------------------------------------------------------
test "reap: an inbound connection idle past the deadline is reaped" {
    if (comptime @hasDecl(cluster, "shouldReapIdleInboundConnection")) {
        const deadline_ms: i64 = 30_000;
        const now_ms: i64 = 1_000_000;
        const last_activity_ms: i64 = now_ms - deadline_ms - 1; // 1 ms past the deadline
        try std.testing.expect(cluster.shouldReapIdleInboundConnection(now_ms, last_activity_ms, deadline_ms));
    } else {
        return error.ShouldReapIdleInboundConnectionNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (A.2) A connection with FRESH activity is NOT reaped.
// ---------------------------------------------------------------------------
test "reap: fresh activity within the deadline is not reaped" {
    if (comptime @hasDecl(cluster, "shouldReapIdleInboundConnection")) {
        const deadline_ms: i64 = 30_000;
        const now_ms: i64 = 1_000_000;
        const last_activity_ms: i64 = now_ms - 1_000; // active 1 s ago, well inside budget
        try std.testing.expect(!cluster.shouldReapIdleInboundConnection(now_ms, last_activity_ms, deadline_ms));
    } else {
        return error.ShouldReapIdleInboundConnectionNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (A.3) Boundary: exactly AT the deadline does NOT reap; one ms past DOES.
// Pins the strict `>` inequality (one reaper tick of grace at the boundary).
// ---------------------------------------------------------------------------
test "reap: deadline boundary uses strict greater-than" {
    if (comptime @hasDecl(cluster, "shouldReapIdleInboundConnection")) {
        const deadline_ms: i64 = 30_000;
        const now_ms: i64 = 1_000_000;
        // diff == deadline -> NOT reaped
        try std.testing.expect(!cluster.shouldReapIdleInboundConnection(now_ms, now_ms - deadline_ms, deadline_ms));
        // diff == deadline + 1 -> reaped
        try std.testing.expect(cluster.shouldReapIdleInboundConnection(now_ms, now_ms - deadline_ms - 1, deadline_ms));
    } else {
        return error.ShouldReapIdleInboundConnectionNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (A.4) Activity RESETS the window: a connection that was reap-eligible becomes
// safe again once `last_activity_ms` is bumped to `now` (the handler stamps it
// on each accepted stream / read frame).
// ---------------------------------------------------------------------------
test "reap: stamping activity resets the idle window" {
    if (comptime @hasDecl(cluster, "shouldReapIdleInboundConnection")) {
        const deadline_ms: i64 = 30_000;
        const now_ms: i64 = 5_000_000;

        // Stale: would be reaped on this pass.
        const stale = now_ms - deadline_ms - 10_000;
        try std.testing.expect(cluster.shouldReapIdleInboundConnection(now_ms, stale, deadline_ms));

        // A stream was just accepted -> last_activity bumped to now -> safe.
        try std.testing.expect(!cluster.shouldReapIdleInboundConnection(now_ms, now_ms, deadline_ms));

        // ...and stays safe across a later pass that is still inside the budget.
        const later = now_ms + deadline_ms - 1;
        try std.testing.expect(!cluster.shouldReapIdleInboundConnection(later, now_ms, deadline_ms));
    } else {
        return error.ShouldReapIdleInboundConnectionNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (A.5) The default deadline is SANE: tens of seconds, and far below the ~300 s
// QUIC idle timeout (the whole point — reap long before the OS/QUIC stack does).
// ---------------------------------------------------------------------------
test "reap: default idle deadline is tens of seconds and far below the QUIC idle timeout" {
    if (comptime @hasDecl(cluster, "inbound_connection_idle_deadline_ms")) {
        const d = cluster.inbound_connection_idle_deadline_ms;
        try std.testing.expect(d > 0);
        // Far below the ~300 s QUIC idle timeout (hard requirement).
        try std.testing.expect(d < quic_idle_timeout_ms);
        // Tens of seconds: not so tiny it churns healthy-but-quiet peers, not so
        // large it defeats the purpose. The contract is "~30 s"; the [5 s, 60 s]
        // band gives the fixer room while pinning the intent.
        try std.testing.expect(d >= 5_000);
        try std.testing.expect(d <= 60_000);
    } else {
        return error.InboundIdleDeadlineConstNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (A.6) Env-override plumbing (pure): a valid positive integer overrides the
// default; null / empty / non-numeric / non-positive falls back to the default.
// ---------------------------------------------------------------------------
test "reap: env override resolves a valid positive value, else falls back to default" {
    if (comptime @hasDecl(cluster, "resolveInboundIdleDeadlineMs") and
        @hasDecl(cluster, "inbound_connection_idle_deadline_ms"))
    {
        const default_ms = cluster.inbound_connection_idle_deadline_ms;

        // Valid override is honored.
        try std.testing.expectEqual(@as(i64, 45_000), cluster.resolveInboundIdleDeadlineMs(@as(?[]const u8, "45000")));

        // Null env -> default.
        try std.testing.expectEqual(default_ms, cluster.resolveInboundIdleDeadlineMs(@as(?[]const u8, null)));

        // Empty / whitespace -> default.
        try std.testing.expectEqual(default_ms, cluster.resolveInboundIdleDeadlineMs(@as(?[]const u8, "")));

        // Non-numeric -> default.
        try std.testing.expectEqual(default_ms, cluster.resolveInboundIdleDeadlineMs(@as(?[]const u8, "abc")));

        // Non-positive -> default (a 0 or negative deadline would reap instantly).
        try std.testing.expectEqual(default_ms, cluster.resolveInboundIdleDeadlineMs(@as(?[]const u8, "0")));
        try std.testing.expectEqual(default_ms, cluster.resolveInboundIdleDeadlineMs(@as(?[]const u8, "-5")));
    } else {
        return error.ResolveInboundIdleDeadlineMsNotImplemented;
    }
}
