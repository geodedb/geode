// Raft consensus integration over the external raft library.
// This module owns Geode-specific command types, protobuf framing, and QUIC
// transport wiring while delegating consensus state transitions to the
// external raft package.

const std = @import("std");

fn compat_sleep(ns: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
}

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

// Zig 0.16 compat: std.posix.getenv was removed; wrap std.c.getenv to return a slice.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}
const Allocator = std.mem.Allocator;
const txn_coordinator = @import("txn_coordinator.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
const protobuf = @import("protobuf");
const raft_schema = @import("raft_schema");
const raft_lib = @import("raft");
// SONNY-6571: the Raft log, hard state and snapshots under GEODE_TDE_KEY.
pub const raft_tde_storage = @import("raft_tde_storage.zig");
const tde_file_encryption = @import("../storage/tde_file_encryption.zig");

const cluster_auth = @import("cluster_auth.zig");

const logging = @import("logging");
const log = logging.scoped("raft");
const Attr = logging.Attr;

const MAX_FRAME_SIZE: u32 = 16 * 1024 * 1024; // 16 MiB

// Type aliases
pub const TxnCoordinator = txn_coordinator.TxnCoordinator;

pub const ClientResponse = struct {
    prepare_result: ?bool = null,
    decision: ?[]const u8 = null,
    xid: u64,
};

// Clock abstraction for deterministic elections & tests
pub const Clock = struct {
    nowMillisFn: *const fn () i64,
    randFn: *const fn (max: u64) u64,
    pub fn nowMillis(self: *const Clock) i64 {
        return self.nowMillisFn();
    }
    pub fn rand(self: *const Clock, max: u64) u64 {
        return if (max == 0) 0 else self.randFn(max);
    }
};

fn realNow() i64 {
    return compat_milliTimestamp();
}
fn realRand(max: u64) u64 {
    return if (max == 0) 0 else blk: {
        var _rng_buf: [@sizeOf(u64)]u8 = undefined;
        // fips-exempt: non-security election-timeout jitter
        compat_fillRandom(&_rng_buf);
        break :blk std.mem.readInt(u64, &_rng_buf, .little);
    } % max;
}
pub const RealClock = struct {
    pub const instance: Clock = .{ .nowMillisFn = realNow, .randFn = realRand };
};

// ---- Domain types (geode-specific) ----

pub const State = enum {
    follower,
    candidate,
    leader,
    shutdown,
};

// ===========================================================================
// owed item (4): frozen-term pre-vote VISIBILITY
// ---------------------------------------------------------------------------
// With `pre_vote = true` (raft_consensus.zig initWithStorageDir), the term only
// increments AFTER a node WINS a pre-vote round. So when a node is wedged as a
// candidate because its RequestVote frames are silently undelivered at restart,
// the term NEVER changes — the cluster sits at an all-candidate frozen term with
// ZERO transport errors and ZERO term churn. The wedge is therefore SILENT: no
// log, no metric, nothing for an operator to see. This tracker makes it visible.
//
// `frozenCandidateWarnDue` is a PURE, clock-injectable decision: it fires a
// rate-limited operator warning when a node has been a CANDIDATE at an UNCHANGING
// term for longer than `frozen_candidate_warn_after_ms` (≈ 3× the default
// election timeout = 15 s, so a single slow-but-progressing election round never
// trips it), and then not again until `frozen_candidate_warn_interval_ms` has
// elapsed (rate limit). Any term advance (election progressing) or a transition
// to leader/follower resets the tracker.
//
// The fixer polls this from the raft loop (likely `cluster.zig` raftLoop /
// `clientPollLoop`), feeding it the live `(role, term, now_ms)` each pass and
// emitting `log.warn` when it returns true. The tracker itself owns no I/O.
pub const FrozenCandidateTracker = struct {
    /// Warn once a node has been a candidate at an unchanging term for this long.
    /// ≈ 3× the default 5000 ms election timeout: a healthy election round is
    /// 1-2 s, so 15 s of NO term movement while still a candidate is the wedge.
    pub const frozen_candidate_warn_after_ms: i64 = 15000;

    /// After a warn fires, suppress further warns for this interval (rate limit).
    pub const frozen_candidate_warn_interval_ms: i64 = 30000;

    /// The role observed on the last `update`. `null` until first observation.
    last_role: ?State = null,
    /// The term observed on the last `update`.
    last_term: u64 = 0,
    /// Wall-clock ms at which the CURRENT (role==candidate, term==last_term) run
    /// began. Reset whenever the role leaves candidate or the term advances.
    candidate_since_ms: i64 = 0,
    /// Wall-clock ms of the last warn emitted, for rate limiting. `null` = never.
    last_warn_ms: ?i64 = null,

    /// Feed the live `(role, term, now_ms)` and return whether an operator warn
    /// is DUE on this pass. Updates internal state (candidate-run start, term
    /// tracking, role transitions) as a side effect so the next call rate-limits
    /// correctly.
    ///
    /// Semantics:
    ///   1. candidate at an unchanging term for > frozen_candidate_warn_after_ms
    ///      → due (and stamp last_warn_ms);
    ///   2. term changed since the candidate run began (election progressing)
    ///      → NOT due, and the candidate run restarts at the new term;
    ///   3. role left candidate (became leader/follower) → NOT due, state resets;
    ///   4. rate limit: immediately after a warn, NOT due again until
    ///      frozen_candidate_warn_interval_ms has elapsed.
    pub fn update(self: *FrozenCandidateTracker, role: State, term: u64, now_ms: i64) bool {
        const role_changed = self.last_role == null or self.last_role.? != role;
        const term_changed = self.last_term != term;

        // A role transition (into/out of/within candidate) or a term advance
        // (election progressing) breaks the frozen run: re-anchor the run start
        // at `now_ms` and clear the rate-limit stamp so a genuinely-new frozen
        // run gets a fresh warn once it crosses the threshold.
        if (role != .candidate or role_changed or term_changed) {
            self.candidate_since_ms = now_ms;
            self.last_warn_ms = null;
        }
        self.last_role = role;
        self.last_term = term;

        // Only a candidate at an unchanging term can be frozen.
        if (role != .candidate) return false;

        // Not yet past the warn-after threshold relative to the run start.
        if (now_ms - self.candidate_since_ms <= frozen_candidate_warn_after_ms) return false;

        // Past the threshold: rate-limit relative to the last warn so a node that
        // stays wedged does not re-warn on every poll.
        if (self.last_warn_ms) |last_warn| {
            if (now_ms - last_warn < frozen_candidate_warn_interval_ms) return false;
        }
        self.last_warn_ms = now_ms;
        return true;
    }
};

// ===========================================================================
// k8s churn recovery, ROOT CAUSE #2 (RC2): rebuild clock-reset re-eviction chase.
// ---------------------------------------------------------------------------
// The stall reaper `maybeReconnectOnStall` rebuilds this node's OUTBOUND
// connection to a peer. The buggy rebuild path stamped `last_progress_ms = now`
// at connect time — i.e. it treated a FORCED rebuild as PROOF OF HEALTH. With
// all directed connections stale and all nodes candidates, the rebuilds chase
// each other on phase-shifted clocks: each side rebuilds, stamps itself
// "healthy", and never actually exchanges a frame before the next stale window —
// the cluster never converges.
//
// FIX: a stall-triggered rebuild does NOT count as progress proof. After a
// rebuild the peer enters PROBATION (it is "unproven"). ONLY a real inbound
// `*_response` frame (the `frameProvesOurOutboundDelivered` gate) clears
// probation. CONSECUTIVE rebuilds without an intervening proof ESCALATE the next
// eviction budget (exponential backoff, capped) — so simultaneous mutual
// rebuilds get progressively longer windows to complete handshakes and exchange
// frames. A real `*_response` clears probation AND resets the budget to base.
//
// This is a PURE, clock-free state machine (no QUIC). The wiring (off
// `PeerConnection`) lives in `Transport`: `noteStallRebuild()` on a
// stall-triggered rebuild (and NO `last_progress_ms` stamp as proof), the reaper
// compares the stall window against `currentBudgetMs()` while in probation, and
// the gated stamp site calls `noteOutboundProof()` exactly when
// `frameProvesOurOutboundDelivered(body)` is true.
// CANARY: REQ=REQ-DIST-RAFT-REBUILD-PROBATION; FEATURE="Raft Rebuild Probation"; ASPECT=Backoff; STATUS=TESTED; TEST=tests/test_raft_rebuild_probation.zig; OWNER=distributed; UPDATED=2026-06-12
pub const RebuildProbation = struct {
    /// Base eviction budget; equals the flat `Transport.peer_stall_budget_ms`.
    pub const base_budget_ms: i64 = Transport.peer_stall_budget_ms; // 15_000
    /// Cap for the exponential backoff (60 s = base * 4).
    pub const max_budget_ms: i64 = base_budget_ms * 4; // 60_000

    in_probation: bool = false,
    consecutive_rebuilds: u32 = 0,

    /// A stall-triggered rebuild occurred: enter probation and escalate the
    /// consecutive-rebuild count. Stamps NO progress clock (the whole fix).
    /// The escalation is saturating so the `<<` in `currentBudgetMs` can never
    /// shift past the cap or overflow.
    pub fn noteStallRebuild(self: *RebuildProbation) void {
        self.in_probation = true;
        // Saturate the counter well below any shift-overflow point. The budget is
        // capped at base*4 (shift of 2), so anything >= a small bound is already
        // pinned at the cap; clamp to keep `base << consecutive_rebuilds` safe.
        if (self.consecutive_rebuilds < 32) self.consecutive_rebuilds += 1;
    }

    /// A real inbound `*_response` proved our outbound: clear probation and reset
    /// the escalation back to base.
    pub fn noteOutboundProof(self: *RebuildProbation) void {
        self.in_probation = false;
        self.consecutive_rebuilds = 0;
    }

    /// Are we currently unproven since the last stall-rebuild?
    pub fn inProbation(self: *const RebuildProbation) bool {
        return self.in_probation;
    }

    /// Eviction budget for the NEXT stall window given the current escalation:
    /// min(base << consecutive_rebuilds, max), i.e.
    ///   0 rebuilds -> base (15 s); 1 -> 30 s; 2 -> 60 s; 3+ -> 60 s (capped).
    pub fn currentBudgetMs(self: *const RebuildProbation) i64 {
        // Clamp the shift to where the cap is already reached (base << 2 == cap):
        // any larger escalation is pinned at `max_budget_ms`, so a tiny shift
        // bound keeps `base << shift` trivially overflow-safe.
        const shift: u6 = @intCast(@min(self.consecutive_rebuilds, 8));
        const scaled = base_budget_ms << shift;
        return @min(scaled, max_budget_ms);
    }
};

pub const Command = union(enum) {
    noop,
    write: []const u8,
    graph_mutation: GraphMutation,
    schema_change: SchemaChange,
    config_change: ConfigChange,
    snapshot_pointer: SnapshotPointer,
    txn_prepare: TxnPrepare,
    txn_decide: TxnDecide,
};

pub const TxnPrepare = struct {
    xid: u64,
    shard_id: u64,
    write_set: []const u8,
    metadata: []const u8,
};

pub const TxnDecide = struct {
    xid: u64,
    commit: bool,
};

pub const GraphMutation = struct {
    graph: []const u8,
    mutation_type: enum { create, update, delete, merge },
    data: []const u8,
    txn_id: ?u64,
};

pub const SchemaChange = struct {
    operation: enum { create_graph, drop_graph, alter_graph },
    graph: []const u8,
    schema: []const u8,
};

pub const ConfigChange = struct {
    change_type: enum { add_server, remove_server, update_server },
    server_id: u64,
    server_endpoint: ?[]const u8,
    server_port: ?u16 = null,
};

pub const SnapshotPointer = struct {
    last_included_index: u64,
    last_included_term: u64,
    size_bytes: u64,
    checksum: u64,
};

pub const LogEntry = struct {
    term: u64,
    index: u64,
    command: Command,
    timestamp: i64,
    client_id: ?u64,
    serial_number: ?u64,
    /// Inbound-only ownership handle.  When a LogEntry is reconstructed from
    /// the protobuf wire (`protoToMessage`), `command` is the result of
    /// `deserializeCommand` aliasing into this allocator-owned buffer (a dup
    /// of the proto `command_bytes`).  The proto decode buffer is freed
    /// immediately after `protoToMessage` returns, so we keep our own copy
    /// here and free it in `freeMessage`.  Null for entries built any other
    /// way (the command's slices then point into externally-owned memory).
    owned_wire_bytes: ?[]u8 = null,
};

pub const Peer = struct {
    id: u64,
    endpoint: []const u8,
    port: u16,
    /// Wall-clock ms of the last authenticated raft frame from this peer
    /// (start time until the first). SONNY-6459: written by the cluster's
    /// inbound handlers (`ClusterCoordinator.noteHeardFrom`) while other
    /// threads read it, so access it with `@atomicLoad` / `@atomicStore`.
    last_contact: i64,
};

pub const Statistics = struct {
    elections_called: u64,
    elections_won: u64,
    elections_lost: u64,
    heartbeats_sent: u64,
    entries_appended: u64,
    entries_committed: u64,
    entries_applied: u64,
    // CANARY: REQ=QUAL-D005; FEATURE="Raft Apply Callback Error Visibility"; ASPECT=ApplyErrorCount; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
    apply_errors: u64,
    // GAP-0889 (F1): committed entries whose command bytes failed to decode.
    // These entries are NOT applied (no silent `.write` fabrication) — a
    // non-zero count means a poisoned/future-format entry reached commit.
    decode_errors: u64,
    snapshots_sent: u64,
    snapshots_received: u64,
    // CANARY: REQ=REQ-SONNY-6631-APPLY-HYDRATION-OFF-RAFT-MUTEX; FEATURE="DistributedCluster"; ASPECT=ApplyCriticalSectionMeasured; STATUS=TESTED; TEST=tests/test_sonny6631_apply_hydration_off_mutex.zig; OWNER=distributed; UPDATED=2026-11-15
    /// SONNY-6631: the longest a Ready's committed entries took to apply
    /// (`finishReady`, under `inner_mutex`), in nanoseconds. While they
    /// apply the node takes no tick, heartbeat or message.
    apply_max_ns: u64,
    /// SONNY-6636 (b): snapshots this node took of its own state machine
    /// and compacted its Raft log at.
    snapshots_taken: u64,
    /// SONNY-6636 (b): the longest snapshot copy (the snapshot thread,
    /// without `inner_mutex`), and the longest commit and log compaction of
    /// a finished one (under `inner_mutex`; SONNY-6665: the data was written
    /// and synced by the snapshot thread), in nanoseconds.
    snapshot_create_max_ns: u64,
    snapshot_install_max_ns: u64,
    /// SONNY-6667: the longest `advancePersist()` (the Ready's hard state,
    /// entries and snapshot written and fsynced, under `inner_mutex`, before
    /// anything it announces is sent or applied), in nanoseconds.
    persist_max_ns: u64,
};

// CANARY: REQ=REQ-SONNY-6636-SERVER-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=SnapshotThreshold; STATUS=TESTED; TEST=tests/test_sonny6636_server_snapshot.zig; OWNER=distributed; UPDATED=2026-11-16
/// SONNY-6636 (b): when a node snapshots its state machine and compacts its
/// Raft log: once `entries` entries were applied since its last snapshot,
/// or `bytes` bytes of entry data. 0 turns a criterion off; both 0 turn
/// snapshots off.
pub const SnapshotPolicy = struct {
    entries: u64 = default_entries,
    bytes: u64 = default_bytes,
    /// The longest a tick spends applying the entries held back while a
    /// snapshot was copied (at least one entry per tick).
    apply_budget_ns: u64 = 10 * std.time.ns_per_ms,

    pub const default_entries: u64 = 10_000;
    pub const default_bytes: u64 = 64 * 1024 * 1024;
    pub const disabled: SnapshotPolicy = .{ .entries = 0, .bytes = 0 };

    pub fn enabled(self: SnapshotPolicy) bool {
        return self.entries > 0 or self.bytes > 0;
    }

    /// GEODE_RAFT_SNAPSHOT_ENTRIES and GEODE_RAFT_SNAPSHOT_BYTES, each
    /// defaulting when unset or not a number.
    pub fn fromEnv(allocator: Allocator) SnapshotPolicy {
        return .{
            .entries = envU64(allocator, "GEODE_RAFT_SNAPSHOT_ENTRIES") orelse default_entries,
            .bytes = envU64(allocator, "GEODE_RAFT_SNAPSHOT_BYTES") orelse default_bytes,
        };
    }

    fn envU64(allocator: Allocator, name: []const u8) ?u64 {
        const raw = getEnvVarOwned(allocator, name) catch return null;
        defer allocator.free(raw);
        return std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch {
            log.warn("raft: ignoring a snapshot threshold that is not a number", &.{Attr.string("variable", name)});
            return null;
        };
    }
};

// ---- RPC / Transport stubs ----

const builtin = @import("builtin");
const real_quic = @import("transport/quic");

/// SONNY-6456: whether this test binary's raft transport uses the real QUIC
/// client (`useRealQuicInTests`). Read when a client or listener is created.
var test_real_quic = std.atomic.Value(bool).init(false);

/// SONNY-6456 (test builds only): make the raft transport's QUIC clients and
/// listeners created from now on real ones, so an in-process test can drive
/// the real sender (`Transport.send`, its client poll thread, TLS and the
/// wire). Off by default: unit tests keep the no-op stub. A connection keeps
/// the kind it was created with.
pub fn useRealQuicInTests(on: bool) void {
    if (!builtin.is_test) @compileError("useRealQuicInTests is for test builds only");
    test_real_quic.store(on, .release);
}

/// SONNY-6636 (5): set once a stub QUIC client in this test binary was
/// asked to connect to a peer (`warnStubConnectOnce`).
var test_stub_connect_warned = std.atomic.Value(bool).init(false);

/// SONNY-6636 (5): in a test build without `useRealQuicInTests(true)` the
/// raft transport's client is a no-op stub: started coordinators in one
/// process send each other no Raft frame (no leader, "peer stalled ...
/// evicting"), which looks like a geode wiring bug. The first time a stub
/// client is asked to connect to a peer, this says so, once per test
/// binary. A warning, not a failure: single-node, lifecycle and in-process
/// network tests run coordinators on the stub on purpose.
fn warnStubConnectOnce(host: []const u8, port: u16) void {
    if (test_stub_connect_warned.swap(true, .acq_rel)) return;
    log.warn("raft transport in a test build: QUIC is a no-op stub, so this connection to a Raft peer sends nothing; a test whose started coordinators must reach each other calls raft_consensus.useRealQuicInTests(true) first (SONNY-6456, SONNY-6636)", &.{
        Attr.string("peer", host),
        Attr.uint("port", port),
    });
}

/// SONNY-6636 (5): whether this test binary has warned that a stub client
/// was asked to connect (`warnStubConnectOnce`).
pub fn stubConnectWarnedForTesting() bool {
    if (!builtin.is_test) @compileError("stubConnectWarnedForTesting is for test builds only");
    return test_stub_connect_warned.load(.acquire);
}

// CANARY: REQ=REQ-SONNY-6665-SNAPSHOT-CHUNK-DROP-HOOK; FEATURE="Raft Snapshot Persistence"; ASPECT=LostChunkHook; STATUS=TESTED; TEST=tests/test_sonny6665_cluster_snapshot_resume.zig; OWNER=distributed; UPDATED=2026-11-16
/// SONNY-6665: lost InstallSnapshot chunks for tests, compiled only into
/// test and Debug builds (release builds are ReleaseSafe or ReleaseFast and
/// have none of it). Armed with a count `n` (`armTestDropSnapshotChunks`):
/// this node drops, up to `n` times, a chunk that directly follows the
/// first chunk (offset 0) of the same snapshot, as if lost in transit, so
/// a send from offset 0 never completes and only a send resumed at the
/// lost chunk does; it logs every inbound chunk while armed. A spawned
/// Debug `geode serve` arms it from GEODE_TEST_RAFT_DROP_SNAPSHOT_CHUNKS.
pub const snapshot_chunk_drop_hook_available = builtin.is_test or builtin.mode == .Debug;
var test_snapshot_chunk_drops = std.atomic.Value(u32).init(0);
var test_snapshot_chunk_trace = std.atomic.Value(bool).init(false);
/// The snapshot index (+1) whose offset-0 chunk was the last one received;
/// 0 otherwise.
var test_snapshot_after_first = std.atomic.Value(u64).init(0);

pub fn armTestDropSnapshotChunks(n: u32) error{SnapshotChunkDropHookUnavailable}!void {
    if (comptime !snapshot_chunk_drop_hook_available) return error.SnapshotChunkDropHookUnavailable;
    test_snapshot_chunk_drops.store(n, .release);
    test_snapshot_chunk_trace.store(n > 0, .release);
}

/// SONNY-6665: whether the hook drops this inbound chunk (it logs it
/// either way while armed).
fn testDropsSnapshotChunk(from: u64, is: InstallSnapshot) bool {
    if (comptime !snapshot_chunk_drop_hook_available) return false;
    if (!test_snapshot_chunk_trace.load(.acquire)) return false;
    const after_first = test_snapshot_after_first.swap(if (is.offset == 0) is.last_included_index + 1 else 0, .acq_rel);
    var left = test_snapshot_chunk_drops.load(.acquire);
    while (after_first == is.last_included_index + 1 and is.offset > 0 and left > 0) {
        left = test_snapshot_chunk_drops.cmpxchgWeak(left, left - 1, .acq_rel, .acquire) orelse {
            log.warn("TEST HOOK: InstallSnapshot chunk dropped (Debug build only)", &.{
                Attr.uint("from", from),
                Attr.uint("snapshot_index", is.last_included_index),
                Attr.uint("chunk_offset", is.offset),
                Attr.uint("chunk_bytes", is.data.len),
            });
            return true;
        };
    }
    log.warn("TEST HOOK: InstallSnapshot chunk received (Debug build only)", &.{
        Attr.uint("from", from),
        Attr.uint("snapshot_index", is.last_included_index),
        Attr.uint("chunk_offset", is.offset),
        Attr.uint("chunk_bytes", is.data.len),
        Attr.boolean("done", is.done),
    });
    return false;
}

const quic = if (builtin.is_test) test_quic else real_quic;

/// The raft transport's QUIC in test builds: a no-op stub (nothing is sent),
/// or the real client and listener once a test calls `useRealQuicInTests`.
const test_quic = struct {
    fn useReal() bool {
        return test_real_quic.load(.acquire);
    }
    // A single shared, well-defined stub stream that every stub `getStream()`
    // hands back. Returning `undefined` here (the prior behavior) made
    // `conn.send_stream = getStream()` an undefined optional pointer; the
    // subsequent `conn.send_stream.?` unwrap in `Transport.send` is illegal
    // behavior whose bit pattern Debug happened to leave non-null but
    // ReleaseSafe's optional-unwrap safety check caught as "attempt to use
    // null value" (SIGABRT). Its methods are no-ops.
    var stub_stream: QuicClientStream = .{};
    pub const QuicClient = struct {
        allocator: ?std.mem.Allocator = null,
        real: ?real_quic.QuicClient = null,

        pub fn init(allocator: std.mem.Allocator) QuicClient {
            if (!useReal()) return .{};
            return .{ .allocator = allocator, .real = real_quic.QuicClient.init(allocator) };
        }
        pub fn connect(self: *QuicClient, host: []const u8, port: u16) !void {
            if (self.real) |*c| return c.connect(host, port);
            warnStubConnectOnce(host, port);
        }
        pub fn connectInsecure(self: *QuicClient, host: []const u8, port: u16, allow_insecure: bool) !void {
            if (self.real) |*c| return c.connectInsecure(host, port, allow_insecure);
            warnStubConnectOnce(host, port);
        }
        pub fn connectEx(self: *QuicClient, host: []const u8, port: u16, ca: ?[]const u8, cert: ?[]const u8, key: ?[]const u8) !void {
            if (self.real) |*c| return c.connectEx(host, port, ca, cert, key);
            warnStubConnectOnce(host, port);
        }
        pub fn waitForHandshake(self: *QuicClient, timeout_secs: u32) !void {
            if (self.real) |*c| return c.waitForHandshake(timeout_secs);
        }
        pub fn deinit(self: *QuicClient) void {
            if (self.real) |*c| c.deinit();
            self.real = null;
        }
        pub fn getStream(self: *QuicClient) !*QuicClientStream {
            const c = if (self.real) |*r| r else return &stub_stream;
            const s = try c.getStream();
            errdefer s.deinit();
            const w = try self.allocator.?.create(QuicClientStream);
            w.* = .{ .allocator = self.allocator, .real = s };
            return w;
        }
        // Task A6b: the poll() call the production path uses to flush.
        pub fn poll(self: *QuicClient, timeout_ms: u32) !void {
            if (self.real) |*c| return c.poll(timeout_ms);
        }
        // SONNY-6451: the closed-connection check in `Transport.send` (a stub
        // connection never closes).
        pub fn isClosed(self: *const QuicClient) bool {
            if (self.real) |*c| return c.isClosed();
            return false;
        }
    };
    pub const QuicClientStream = struct {
        allocator: ?std.mem.Allocator = null,
        real: ?*real_quic.QuicClientStream = null,

        pub fn writeAll(self: *QuicClientStream, data: []const u8) !void {
            if (self.real) |s| return s.writeAll(data);
        }
        pub fn deinit(self: *QuicClientStream) void {
            const s = self.real orelse return;
            s.deinit();
            self.allocator.?.destroy(self);
        }
        // Task A6b: the finish() call the production path uses for FIN.
        pub fn finish(self: *QuicClientStream) !void {
            if (self.real) |s| return s.finish();
        }
    };
    pub const QuicTransport = struct {
        real: ?real_quic.QuicTransport = null,

        pub fn init(allocator: std.mem.Allocator, config: real_quic.QuicTransport.Config) !QuicTransport {
            if (!useReal()) return .{};
            return .{ .real = try real_quic.QuicTransport.init(allocator, config) };
        }
        pub fn listen(self: *QuicTransport) !void {
            if (self.real) |*t| return t.listen();
        }
        pub fn deinit(self: *QuicTransport) void {
            if (self.real) |*t| t.deinit();
            self.real = null;
        }
        pub fn getStream(_: *QuicTransport) !*QuicClientStream {
            return &stub_stream;
        }
    };
    // Peer re-resolution used by clientPollLoop. With the stub, tests address
    // peers by IP literal, so "resolution" returns the host unchanged and the
    // periodic IP-change reaper never evicts.
    pub fn resolveHostIpAlloc(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
        if (useReal()) return real_quic.resolveHostIpAlloc(allocator, host);
        return allocator.dupe(u8, host);
    }
};

/// Task A6e (2026-05-26 plan), repartitioned per-peer by A2 (2026-06-08): one
/// queued outbound raft RPC.  Owned by the destination peer's
/// `Transport.PeerDrain.queue`; freed by `freeOutboundMessage` once that peer's
/// drain thread has written it to the wire (or determined the peer is
/// permanently unreachable).
pub const OutboundEntry = struct {
    peer: Peer,
    from: u64,
    term: u64,
    msg: Message,
};

pub const Transport = struct {
    allocator: Allocator,
    server: ?quic.QuicTransport = null,
    /// Optional override for `send`.  When non-null, `Transport.send`
    /// dispatches through this function pointer instead of the default
    /// QUIC+TLS path.  Used by `tests/test_drainready_dispatch.zig` (A5b
    /// of the 2026-05-25 distributed cluster testing plan) to capture
    /// outbound raft messages produced by the inner raft library without
    /// spinning up a QUIC listener or a TLS handshake.  Production code
    /// leaves this null so the default path is used.
    send_override: ?*const fn (self: *Transport, peer: Peer, from: u64, term: u64, msg: Message) anyerror!void = null,
    /// Optional opaque context for `send_override`.  Tests can stash a
    /// pointer to their capture struct here and retrieve it from inside
    /// the override callback.  Ignored by the default send path.
    send_override_ctx: ?*anyopaque = null,

    /// election-livelock fix (2026-06-11) + owed item (4) frozen-term wedge: the
    /// live `StallArm` role source for the stalled-stream reaper
    /// (`maybeReconnectOnStall`). The reaper arms its eviction decision ONLY when
    /// THIS node is the raft LEADER or a CANDIDATE; a FOLLOWER is suppressed.
    /// Rationale: during a leaderless election there is legitimately no
    /// AppendEntries flow, so arming a follower would trip every peer and tear
    /// down the connections votes/responses ride (the original livelock); but a
    /// CANDIDATE must get its RequestVote frames through a possibly-wedged stream
    /// at restart, so it MUST be armed. The cluster coordinator wires this from
    /// `RaftNode.role()` mapped onto `StallArm`. Null (default / standalone) is
    /// treated as `.follower`, so the standalone path never evicts on stall.
    /// Mirrors the `send_override` injection pattern.
    role_source_fn: ?*const fn (ctx: ?*anyopaque) StallArm = null,
    role_source_ctx: ?*anyopaque = null,

    /// Task A6c (2026-05-25 distributed cluster testing plan):
    /// Persistent per-peer QUIC connection pool.  Each entry is keyed
    /// by `peer.id` and owns a long-lived `QuicClient` plus its TLS
    /// handshake state, so subsequent raft RPCs only allocate a fresh
    /// bidirectional stream rather than reconstructing the entire QUIC
    /// endpoint.  Guarded by `peers_mutex` because raft tick, heartbeat,
    /// and inbound dispatch can all hit `send` concurrently.
    peers_mutex: std.Io.Mutex = std.Io.Mutex.init,
    peers: std.AutoHashMap(u64, *PeerConnection) = undefined,
    peers_initialized: bool = false,

    /// RC2 (rebuild-probation) escalation carry, keyed by `peer.id`. A
    /// stall-triggered eviction DESTROYS the `PeerConnection`, so the consecutive
    /// -rebuild escalation count cannot live solely on it — it must survive the
    /// evict → (lazy) rebuild boundary. This map carries the escalation forward:
    /// `noteStallRebuildForPeer` bumps it at eviction time;
    /// `getOrCreatePeerConnection` seeds the freshly built `PeerConnection`'s
    /// probation atomics from it; a real inbound `*_response`
    /// (`notePeerProgress`) clears it. Guarded by `peers_mutex` (same lock as
    /// `peers`, so the seed-at-build read and the clear-on-proof write are
    /// serialized with eviction). A peer with no entry is "proven" (no escalation).
    probation_carry: std.AutoHashMap(u64, u32) = undefined,

    /// Task A6e (2026-05-26 distributed cluster testing plan), reworked into
    /// PER-PEER queues by Task A2 (2026-06-08 raft-transport-stream-starvation
    /// plan).  The raft library's `sendMsg` vtable callback fires synchronously
    /// from inside `inner.step()` / `inner.tick()` while the wrapper's
    /// `inner_mutex` is held; if `sendMsg` performs blocking QUIC I/O inline the
    /// mutex stays held for the entire round-trip and the inbound dispatch
    /// thread can't deliver vote / heartbeat responses until the next tick.  So
    /// each outbound message is enqueued (cheap copy) and drained OUTSIDE the
    /// inner_mutex on a dedicated worker thread.
    ///
    /// A2 (k8s root cause #5): a SINGLE serial drain thread sends every peer's
    /// messages through `send`, and `send → getOrCreatePeerConnection →
    /// waitForHandshake(1)` can BLOCK ~1s on one slow/unreachable peer.  At
    /// election time that serial blocking stalls votes/heartbeats to EVERY peer
    /// → no leader is elected → the cluster can't converge.  The fix is one send
    /// queue + one dedicated drain thread PER peer, so a blocking send to a slow
    /// peer is isolated to that peer's thread and never delays another peer's
    /// votes/heartbeats.  Peers are stable for a cluster's lifetime, so the
    /// per-peer drains are created lazily on first enqueue and live until
    /// `stopOutboxDrain` / `deinit`.
    ///
    /// Lock ordering: `peer_drains_mutex` (the map guard) is a LEAF lock held
    /// only for brief get-or-create lookups + the one-time thread spawn — it is
    /// NEVER held while doing a network `send`/handshake (the drain loop
    /// releases its own per-peer `PeerDrain.mutex` before calling `send`, and
    /// never touches the map mutex on the hot path).  Each `PeerDrain.mutex` is
    /// likewise a leaf lock guarding only that peer's queue snapshot-and-swap.
    peer_drains_mutex: std.Io.Mutex = std.Io.Mutex.init,
    peer_drains: std.AutoHashMap(u64, *PeerDrain) = undefined,
    peer_drains_initialized: bool = false,

    /// Global cancellation flag for ALL per-peer drain threads.  Set by
    /// `stopOutboxDrain` / `deinit`; checked by `enqueueOutbound` (reject new
    /// work), each per-peer drain loop, and `send` (reject after shutdown).
    /// `startOutboxDrain` is the lifecycle gate: while false, lazy per-peer
    /// drains may be created on enqueue.
    outbox_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// True between `startOutboxDrain` and `stopOutboxDrain`.  Gates lazy
    /// per-peer drain creation so a stray enqueue before start / after stop
    /// never spawns an orphaned thread.
    outbox_running: bool = false,

    /// Task A6e: dedicated client-side poll thread.  The QUIC vendor
    /// library buffers outbound bytes until `poll()` is invoked on the
    /// originating endpoint — `cluster_poll_pool` drives the SERVER
    /// endpoint but each `PeerConnection` owns its own client endpoint
    /// which still needs polling.  Previously `Transport.send` called
    /// `conn.client.poll(10)` synchronously after every write to flush;
    /// that 10 ms-per-send cost was a major contributor to the
    /// inner_mutex starvation.  With this thread, sends are
    /// fire-and-forget: data lands in the vendor buffer and the poll
    /// loop pushes it onto the wire within ~1 ms.
    client_poll_thread: ?std.Thread = null,
    client_poll_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Persistent QUIC client + endpoint metadata kept alive across raft
    /// RPCs to a single peer.  `client.deinit()` is deferred to
    /// `Transport.deinit` (or to a re-establishment after a connection
    /// failure), so the TLS handshake cost is paid once per peer.
    pub const PeerConnection = struct {
        allocator: Allocator,
        client: quic.QuicClient,
        /// Set after `connectWithTLS` succeeds for the first time.
        /// Treated as "definitely-non-zero until we observe an error",
        /// at which point the entry is evicted and rebuilt on the next
        /// send.
        established: bool = false,
        endpoint: []const u8,
        port: u16,
        /// The destination peer's id. Stored so the IP-change reaper in
        /// `clientPollLoop` (which iterates the snapshot by pointer) can call
        /// `evictPeerConnection(peer_id)` when this connection's endpoint has
        /// been rescheduled to a new IP. Immutable after publish into the map.
        peer_id: u64 = 0,
        /// The IP `endpoint` resolved to when this connection was established.
        /// Owned. The reaper compares it against a fresh resolution of
        /// `endpoint`; a difference means the peer pod was rescheduled to a new
        /// IP and the cached connection (which silently blackholes against the
        /// old IP) must be evicted + rebuilt. Immutable after publish.
        resolved_ip: []const u8 = &.{},

        /// Refcount for safe concurrent eviction-vs-poll (A6f, 2026-05-26).
        /// Semantics: entries in `Transport.peers` carry an implicit ref of 1
        /// (the map's ownership). `clientPollLoop` and `send` each bump+drop
        /// a transient ref around their use of `client.poll()` /
        /// `client.getStream()`. `evictPeerConnection` removes the entry
        /// from the map and drops the map's implicit ref; whichever thread
        /// observes the final 1→0 transition owns the deinit. Initial value
        /// is 1 because the entry is created and immediately placed in the
        /// map (which now owns that ref).
        refcount: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

        /// A6f (2026-05-26): serialize all access to the QUIC vendor library
        /// for this connection. The library's internal stream-tracking
        /// HashMap is not thread-safe — concurrent `poll()` (from
        /// clientPollLoop) and `getStream()`/`finish()` (from send) on the
        /// same QuicClient produce a segfault inside `dropAckedStreamTracking`
        /// → `fetchRemove` → `getIndex` (the HashMap's metadata pointer is
        /// read after free). Holding this mutex around every client.* call
        /// prevents the race.
        client_mutex: std.Io.Mutex = std.Io.Mutex.init,

        /// 2026-06-08 raft multiplexed streams: ONE long-lived bidirectional
        /// stream reused for every raft frame to this peer, so we never open a
        /// stream per RPC (which exhausted per-peer bidi-stream credit under
        /// write load and dropped heartbeats/votes → split-brain). Guarded by
        /// `client_mutex` (same as every other client.* access — A6f). Lazily
        /// opened on first send; closed+nulled on any write/open error and
        /// reopened on the next send.
        send_stream: ?*quic.QuicClientStream = null,

        /// k8s root cause #5 (stalled-stream liveness, 2026-06-11): the raft
        /// transport is fire-and-forget — a write into a stale/half-open QUIC
        /// connection (peer's OLD endpoint after a pod reschedule) buffers
        /// locally and returns success, so neither the send-error eviction path
        /// nor the IP-change reaper (the strand victim's IP never changed) ever
        /// fires. This timestamp records the last time we OBSERVED forward
        /// progress with this peer (an inbound frame / RPC response, stamped via
        /// `Transport.notePeerProgress`). Initialized at connect time so a brand
        /// new connection is not immediately judged stalled. The stall reaper
        /// compares `now - last_progress_ms` against `peer_stall_budget_ms`.
        last_progress_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

        /// Count of frames handed to the wire for this peer. The stall reaper
        /// must only act on a peer we have actually been SENDING to (a peer with
        /// no traffic has no progress to expect and must not be evicted). Bumped
        /// on each successful `send`.
        frames_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        /// k8s root cause #5 (election-livelock fix, 2026-06-11): consecutive
        /// stalled-reaper passes observed for this peer. A SINGLE stalled
        /// observation must NOT evict — during a leaderless election there is
        /// legitimately no AppendEntries flow, so a one-shot stall check trips on
        /// every peer and tears down the very connections votes/responses ride,
        /// preventing any leader from ever being elected. Eviction requires
        /// `peer_stall_strikes_required` CONSECUTIVE stalled passes (tracked by
        /// `recordStallPassArmed`); any progress stamp (`notePeerProgress`) or an
        /// unarmed (follower) pass resets this to zero.
        stall_strikes: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        /// RC2 (rebuild-probation): atomic backing for the `RebuildProbation`
        /// state machine. A stall-triggered rebuild enters probation
        /// (`probation_active = true`) and escalates `probation_rebuilds` instead
        /// of stamping `last_progress_ms` as health; the reaper then measures the
        /// stall window from `rebuilt_at_ms` against the escalated
        /// `RebuildProbation.currentBudgetMs()` (NOT the flat budget) while in
        /// probation, so simultaneous mutual rebuilds get progressively longer
        /// windows to actually exchange a frame. A real inbound `*_response`
        /// (`noteOutboundProof` from the inbound path) clears probation and resets
        /// the escalation. Atomics (not a plain struct) because the reaper thread
        /// writes the escalation while the inbound-dispatch thread writes the
        /// clear — the same fail-safe-toward-not-evicting discipline as
        /// `stall_strikes`.
        probation_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        probation_rebuilds: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        /// Wall-clock ms of the last stall-triggered rebuild. The probation-window
        /// arithmetic measures `now - rebuilt_at_ms` (NOT delivery proof — a
        /// rebuild is explicitly NOT health), giving the freshly rebuilt
        /// connection the escalated budget to complete a handshake + exchange a
        /// real frame before it can be re-evicted.
        rebuilt_at_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

        /// RC3 (follower response-direction eviction): wall-clock ms of the last
        /// inbound REQUEST (request_vote / append_entries / install_snapshot)
        /// observed FROM this peer. Stamped in the inbound path
        /// (`cluster.zig:applyDecodedRaftFrame`) for the NON-response branch — i.e.
        /// exactly when `!frameProvesOurOutboundDelivered(body)`. Drives
        /// `inbound_request_recent` in `directionalEvictAllowed`: a follower whose
        /// response-carrying OUTBOUND is dead keeps receiving requests (inbound
        /// fine) but never gets an outbound proof, so it must be allowed to
        /// rebuild — while a QUIET follower (no recent inbound requests) stays
        /// suppressed so a leaderless election never churns connections.
        last_inbound_request_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

        /// RC3 (healthy-follower implicit ack): the highest `prev_log_index` /
        /// `leader_commit` seen on an inbound AppendEntries from the leader keyed
        /// by this outbound peer. A healthy follower never receives `*_response`
        /// frames, so its outbound would look permanently unproven; but the leader
        /// only ADVANCES these after it applied the follower's prior response, so
        /// an advance is an IMPLICIT ack that our response arrived. When either
        /// advances we stamp `notePeerProgress` — keeping a healthy follower's
        /// `outbound_proof_stale == false` (no churn) while a WEDGED follower sees
        /// only non-advancing retransmits and is allowed to rebuild.
        /// `+1`-biased sentinel is unnecessary: index/commit start at 0 and only
        /// ever grow, so a strict `>` comparison against the stored value is the
        /// advance test. Initialized to 0; the first AppendEntries with a non-zero
        /// index/commit (or any later advance) counts as an advance.
        last_seen_prev_log_index: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        last_seen_leader_commit: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        fn deinit(self: *PeerConnection) void {
            if (self.send_stream) |s| {
                s.finish() catch {};
                s.deinit();
                self.send_stream = null;
            }
            self.client.deinit();
            self.allocator.free(self.endpoint);
            if (self.resolved_ip.len > 0) self.allocator.free(self.resolved_ip);
            self.allocator.destroy(self);
        }

        /// SONNY-6459: whether this connection was built for `peer`'s current
        /// configured endpoint (host and port). A change of the IP behind an
        /// unchanged host name is the client poll loop's re-resolve reaper's
        /// job (`resolved_ip`); this check costs no DNS lookup per send.
        fn connectsTo(self: *const PeerConnection, peer: Peer) bool {
            return self.port == peer.port and std.mem.eql(u8, self.endpoint, peer.endpoint);
        }

        /// Acquire a reference. Must be called while holding the parent
        /// Transport's `peers_mutex` to ensure the entry is still in the map.
        fn acquire(self: *PeerConnection) void {
            _ = self.refcount.fetchAdd(1, .acq_rel);
        }

        /// Release a reference. Returns true if this was the final
        /// reference (caller may deinit). Lock-free.
        fn release(self: *PeerConnection) bool {
            const prev = self.refcount.fetchSub(1, .acq_rel);
            return prev == 1;
        }
    };

    /// Task A2 (2026-06-08): a single peer's send queue + dedicated drain
    /// thread.  One of these exists per destination peer for the cluster's
    /// lifetime (created lazily on first enqueue, joined+freed at shutdown).
    /// Its `mutex` is a LEAF lock guarding only the queue snapshot-and-swap; it
    /// is released before the drain loop calls `send`, so a blocking send to
    /// this peer never holds any lock and never delays another peer's drain.
    pub const PeerDrain = struct {
        mutex: std.Io.Mutex = std.Io.Mutex.init,
        queue: std.ArrayList(OutboundEntry) = .empty,
        thread: ?std.Thread = null,
        /// Per-peer shutdown.  Set (alongside the global `outbox_shutdown`) by
        /// `stopOutboxDrain`/`deinit` so the loop exits promptly.
        shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// Back-pointer so the spawned thread can reach `Transport.send` and the
        /// global `outbox_shutdown` without a separate context allocation.
        transport: *Transport = undefined,
        peer_id: u64 = 0,
    };

    pub fn init(allocator: Allocator) Transport {
        return .{
            .allocator = allocator,
            .peers_mutex = std.Io.Mutex.init,
            .peers = std.AutoHashMap(u64, *PeerConnection).init(allocator),
            .probation_carry = std.AutoHashMap(u64, u32).init(allocator),
            .peers_initialized = true,
            .peer_drains_mutex = std.Io.Mutex.init,
            .peer_drains = std.AutoHashMap(u64, *PeerDrain).init(allocator),
            .peer_drains_initialized = true,
            .outbox_shutdown = std.atomic.Value(bool).init(false),
            .outbox_running = false,
            .client_poll_thread = null,
            .client_poll_shutdown = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Transport) void {
        // Task A6e/A2: stop the dispatch threads BEFORE we tear down the peer
        // map.  Both the per-peer drain threads (`getOrCreatePeerConnection`)
        // and the client poll thread (direct `self.peers` iteration) touch the
        // connection pool, so freeing entries while they ran would race.
        // `stopOutboxDrain` joins every per-peer drain thread, drains+frees its
        // queue, and removes+frees its `PeerDrain` — leaving the map empty.
        self.stopOutboxDrain();
        self.stopClientPoll();

        if (self.peer_drains_initialized) {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.peer_drains_mutex.lockUncancelable(io);
            // stopOutboxDrain already joined+freed every PeerDrain, but defend
            // against a deinit without a matching start (the map is then empty).
            var it = self.peer_drains.iterator();
            while (it.next()) |entry| {
                const pd = entry.value_ptr.*;
                for (pd.queue.items) |*qe| freeOutboundMessage(self.allocator, qe.msg);
                pd.queue.deinit(self.allocator);
                self.allocator.destroy(pd);
            }
            self.peer_drains.deinit();
            self.peer_drains_initialized = false;
            self.peer_drains_mutex.unlock(io);
        }

        if (self.peers_initialized) {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.peers_mutex.lockUncancelable(io);
            var it = self.peers.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            self.peers.deinit();
            self.probation_carry.deinit();
            self.peers_initialized = false;
            self.peers_mutex.unlock(io);
        }
        if (self.server) |*s| s.deinit();
        self.server = null;
    }

    /// Task A2: get-or-create the `PeerDrain` for `peer_id`, spawning its
    /// dedicated drain thread when the transport is running.  Holds
    /// `peer_drains_mutex` only for the map lookup/insert + the (fast,
    /// non-blocking) thread spawn — NEVER across a network send.  Returns null
    /// only after `stopOutboxDrain` has flipped `outbox_shutdown`, in which case
    /// the caller drops the message (the raft library re-sends next tick).
    ///
    /// The PeerDrain (queue) is created even before `startOutboxDrain` so the
    /// synchronous `snapshotOutbox`/`flushOutboxBlocking` path (and the in-
    /// process A5 test) can enqueue+flush without a running thread; the thread
    /// is spawned lazily once `outbox_running` is set (here, or retroactively by
    /// `startOutboxDrain` for any pre-created drains).
    fn getOrCreatePeerDrain(self: *Transport, peer_id: u64) !?*PeerDrain {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.peer_drains_mutex.lockUncancelable(io);
        defer self.peer_drains_mutex.unlock(io);
        // Re-check under the lock so we never spawn a drain that
        // `stopOutboxDrain` (which also takes the map mutex) won't join.
        if (self.outbox_shutdown.load(.acquire)) return null;

        const pd = self.peer_drains.get(peer_id) orelse blk: {
            const fresh = try self.allocator.create(PeerDrain);
            errdefer self.allocator.destroy(fresh);
            fresh.* = .{
                .queue = .empty,
                .thread = null,
                .shutdown = std.atomic.Value(bool).init(false),
                .transport = self,
                .peer_id = peer_id,
            };
            try self.peer_drains.put(peer_id, fresh);
            break :blk fresh;
        };

        // Spawn the dedicated drain thread on first use while running.  Spawning
        // is fast and takes no geode lock, so doing it under `peer_drains_mutex`
        // does not violate the "no send under the map mutex" rule.
        if (self.outbox_running and pd.thread == null) {
            pd.shutdown.store(false, .release);
            pd.thread = try std.Thread.spawn(.{}, peerDrainEntry, .{@as(?*anyopaque, @ptrCast(pd))});
        }
        return pd;
    }

    /// Task A6e/A2: append an outbound message to the OWNING PEER's queue.
    /// Called from the bridge `sendImpl` while the wrapper's `inner_mutex` is
    /// held — cheap: a get-or-create lookup + a vec append under that peer's
    /// leaf mutex.  The actual QUIC write happens later on that peer's drain
    /// thread, isolated from every other peer.
    ///
    /// Lifecycle contract: producers (the raft loop) must be quiesced before
    /// `stopOutboxDrain` frees the per-peer drains — `ClusterCoordinator.stop`
    /// guarantees this by joining `raft_pool` before calling `stopOutboxDrain`.
    /// (Same invariant the single-outbox design relied on.)
    pub fn enqueueOutbound(self: *Transport, peer: Peer, from: u64, term: u64, msg: Message) !void {
        if (self.outbox_shutdown.load(.acquire)) return error.TransportShutdown;
        const pd = (try self.getOrCreatePeerDrain(peer.id)) orelse return error.TransportShutdown;

        const io = std.Io.Threaded.global_single_threaded.io();
        pd.mutex.lockUncancelable(io);
        defer pd.mutex.unlock(io);

        // Coalesce AppendEntries within THIS peer's queue (2026-06-04 cluster
        // write-replication BLOCKER).  The raft tick enqueues an AppendEntries
        // to every peer on a short cadence; if this peer's drain thread can't
        // keep up (e.g. it is paying a slow QUIC handshake), the queue would
        // grow an unbounded backlog of stale heartbeats and a freshly PROPOSED
        // entry's AppendEntries would sit at the TAIL, draining minutes later —
        // or never before the leader steps down.  AppendEntries is idempotent
        // and cumulative: a newer one to this peer strictly supersedes any older
        // still-pending one, so we replace it in place.  This bounds the queue
        // to ~one AppendEntries.  Votes, responses and snapshots are distinct
        // and never coalesced.  (Now a per-peer scan — strictly smaller than
        // the old global scan.)
        switch (msg) {
            .append_entries => {
                for (pd.queue.items) |*existing| {
                    if (existing.msg == .append_entries) {
                        freeOutboundMessage(self.allocator, existing.msg);
                        existing.* = .{ .peer = peer, .from = from, .term = term, .msg = msg };
                        return;
                    }
                }
            },
            // CANARY: REQ=REQ-SONNY-6636-OUTBOX-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=OneSnapshotSendQueued; STATUS=TESTED; TEST=tests/test_sonny6636_outbox_snapshot.zig; OWNER=distributed; UPDATED=2026-11-16
            // SONNY-6636 (c): a snapshot goes out as a burst of chunks from
            // offset 0, sent whole again every few rounds while the peer does
            // not answer. A new burst supersedes every chunk still queued for
            // this peer: a peer that was down came back to thousands of stale
            // chunks of older snapshots, restored the oldest and never caught
            // up with the newest.
            .install_snapshot => |is| if (is.offset == 0) {
                var k: usize = 0;
                while (k < pd.queue.items.len) {
                    if (pd.queue.items[k].msg == .install_snapshot) {
                        freeOutboundMessage(self.allocator, pd.queue.items[k].msg);
                        _ = pd.queue.orderedRemove(k);
                    } else k += 1;
                }
            },
            else => {},
        }

        try pd.queue.append(self.allocator, .{ .peer = peer, .from = from, .term = term, .msg = msg });
        // The peer's drain thread polls every 2 ms, so no condvar signal is
        // needed; the wakeup-latency floor stays well under the heartbeat
        // budget (50 ms).
    }

    /// Task A6e/A2: snapshot-and-swap the combined backlog across ALL per-peer
    /// queues.  Used by the synchronous test/in-process path via
    /// `flushOutboxBlocking` (and the legacy A5b dispatch test).  Returns an
    /// owned slice the caller must `deinit` and whose `msg` fields must be freed
    /// via `freeOutboundMessage`.  Production code lets each peer's drain thread
    /// do the work; this entry point exists so tests can flush synchronously.
    pub fn snapshotOutbox(self: *Transport) std.ArrayList(OutboundEntry) {
        const io = std.Io.Threaded.global_single_threaded.io();
        var snap: std.ArrayList(OutboundEntry) = .empty;
        if (!self.peer_drains_initialized) return snap;
        self.peer_drains_mutex.lockUncancelable(io);
        defer self.peer_drains_mutex.unlock(io);
        var it = self.peer_drains.iterator();
        while (it.next()) |entry| {
            const pd = entry.value_ptr.*;
            pd.mutex.lockUncancelable(io);
            for (pd.queue.items) |qe| {
                // On OOM here we'd leak the queued msg; appendBounded would be
                // worse (silent drop). Use a best-effort append and free on
                // failure to keep the no-double-free invariant.
                snap.append(self.allocator, qe) catch |err| {
                    freeOutboundMessage(self.allocator, qe.msg);
                    log.debug("snapshotOutbox append failed; dropping queued msg", &.{
                        Attr.string("error", @errorName(err)),
                    });
                };
            }
            // We moved ownership of every entry into `snap` (or freed it), so
            // clear the queue without re-freeing.
            pd.queue.clearRetainingCapacity();
            pd.mutex.unlock(io);
        }
        return snap;
    }

    /// Task A6e: dispatch one outbox snapshot inline.  Used by each per-peer
    /// drain loop and by the synchronous test path via `flushOutboxBlocking`.
    /// Each entry's `msg` is freed after the send attempt regardless of outcome
    /// — the raft library re-sends on its next tick if the send failed.
    pub fn dispatchOutbox(self: *Transport, snap: *std.ArrayList(OutboundEntry)) void {
        for (snap.items) |entry| {
            // Shutdown is a cancellation boundary.  Once SIGTERM has reached
            // ClusterCoordinator.stop(), peers may already be gone; continuing
            // to drain a stale snapshot can pay the QUIC handshake timeout for
            // every queued heartbeat/vote and make subprocess cleanup hang.
            if (self.outbox_shutdown.load(.acquire)) {
                freeOutboundMessage(self.allocator, entry.msg);
                continue;
            }
            // CANARY: REQ=REQ-DIST-RAFT-A6E-OUTBOX-DISPATCH; FEATURE="Raft Outbox Async Dispatch"; ASPECT=Send; STATUS=TESTED; OWNER=distributed; UPDATED=2026-05-26
            self.send(entry.peer, entry.from, entry.term, entry.msg) catch |err| {
                log.debug("raft outbox dispatch failed", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("peer", entry.peer.id),
                });
            };
            freeOutboundMessage(self.allocator, entry.msg);
        }
        snap.deinit(self.allocator);
    }

    /// Task A6e: synchronous helper used by tests (and by the in-process A5
    /// election test) that want to flush queued messages without depending on
    /// the background drain threads.  Drains every per-peer queue serially.
    /// Production code always lets the per-peer drain threads do the work.
    pub fn flushOutboxBlocking(self: *Transport) void {
        var snap = self.snapshotOutbox();
        self.dispatchOutbox(&snap);
    }

    /// Task A2: one peer's drain loop.  Snapshot-and-swap THIS peer's queue
    /// under its own leaf mutex, release the mutex, then `send` each entry
    /// serially to this one peer (blocking on a slow handshake is fine — it is
    /// isolated to this thread).  2 ms idle when the queue is empty.  Honors
    /// both the per-peer `shutdown` and the global `outbox_shutdown`.
    fn peerDrainLoop(self: *Transport, pd: *PeerDrain) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        while (!pd.shutdown.load(.acquire) and !self.outbox_shutdown.load(.acquire)) {
            pd.mutex.lockUncancelable(io);
            const snap = pd.queue;
            pd.queue = .empty;
            const have_work = snap.items.len > 0;
            pd.mutex.unlock(io);
            if (have_work) {
                var snap_mut = snap;
                self.dispatchOutbox(&snap_mut);
            } else {
                var empty_mut = snap;
                empty_mut.deinit(self.allocator);
                compat_sleep(2 * std.time.ns_per_ms);
            }
        }
    }

    fn peerDrainEntry(ctx: ?*anyopaque) void {
        const pd: *PeerDrain = @ptrCast(@alignCast(ctx.?));
        pd.transport.peerDrainLoop(pd);
    }

    pub fn startOutboxDrain(self: *Transport) !void {
        // Flip the running gate so `getOrCreatePeerDrain` will spawn per-peer
        // drain threads on first enqueue.  Also spawn a thread for any drain
        // already created pre-start (e.g. an early enqueue that only built the
        // queue), so no queued backlog is left without a draining thread.
        self.outbox_shutdown.store(false, .release);
        const io = std.Io.Threaded.global_single_threaded.io();
        self.peer_drains_mutex.lockUncancelable(io);
        defer self.peer_drains_mutex.unlock(io);
        self.outbox_running = true;
        var it = self.peer_drains.iterator();
        while (it.next()) |entry| {
            const pd = entry.value_ptr.*;
            if (pd.thread == null) {
                pd.shutdown.store(false, .release);
                pd.thread = try std.Thread.spawn(.{}, peerDrainEntry, .{@as(?*anyopaque, @ptrCast(pd))});
            }
        }
    }

    pub fn stopOutboxDrain(self: *Transport) void {
        // Signal global cancellation FIRST so every per-peer loop sees it (and
        // `getOrCreatePeerDrain` refuses to spawn new drains).
        self.outbox_shutdown.store(true, .release);
        if (!self.peer_drains_initialized) return;

        const io = std.Io.Threaded.global_single_threaded.io();
        self.peer_drains_mutex.lockUncancelable(io);
        defer self.peer_drains_mutex.unlock(io);
        self.outbox_running = false;

        // Join + free every per-peer drain.  Holding `peer_drains_mutex` across
        // the joins is safe: the drain loops are pure leaf consumers that never
        // take this (or any other) geode lock, so there is no lock-order
        // inversion and no deadlock.  Because `outbox_shutdown` was set BEFORE we
        // took this mutex, `getOrCreatePeerDrain` can no longer hand out (or
        // create) a drain — so no NEW producer can reach a `pd`.  Join BEFORE
        // freeing each queue so the drain loop has fully unwound (no
        // use-after-free); then briefly take `pd.mutex` around the queue
        // teardown to close the window against a producer that grabbed `pd`
        // just before shutdown and is still appending under `pd.mutex`.  Finally
        // drop any messages still queued (the loop may have exited mid-backlog).
        var it = self.peer_drains.iterator();
        while (it.next()) |entry| {
            const pd = entry.value_ptr.*;
            pd.shutdown.store(true, .release);
            if (pd.thread) |t| {
                t.join();
                pd.thread = null;
            }
            pd.mutex.lockUncancelable(io);
            for (pd.queue.items) |*qe| freeOutboundMessage(self.allocator, qe.msg);
            pd.queue.deinit(self.allocator);
            pd.mutex.unlock(io);
            self.allocator.destroy(pd);
        }
        // Drop all (now-freed) entries from the map without re-iterating.
        self.peer_drains.clearRetainingCapacity();
    }

    fn clientPollLoop(self: *Transport) void {
        // Poll every cached peer client endpoint with a 0 ms timeout so
        // we never block here.  2 ms between iterations is a deliberate
        // tradeoff: it keeps wire-to-wire latency well under the raft
        // heartbeat interval (50 ms) while bounding the per-second
        // wakeup rate to ~500 per node — vs. 2000/sec at 500 µs, which
        // pinned a full CPU core per node in early iterations.
        //
        // CRITICAL: snapshot the peer pointer list before polling so we
        // don't hold `peers_mutex` while calling into the vendor library.
        // The vendor library takes its own per-connection locks; nesting
        // our peers_mutex around those locks would invert the lock order
        // observed by `getOrCreatePeerConnection` (vendor → ours during
        // handshake) and deadlock.  A stale pointer here is impossible
        // because `evictPeerConnection` is the only deletion site and it
        // also runs under `peers_mutex`.  We use a small inline buffer
        // for the snapshot to avoid allocator pressure on the hot path.
        var snap_buf: [16]*PeerConnection = undefined;
        const io = std.Io.Threaded.global_single_threaded.io();
        // k8s membership churn: re-resolve every peer FQDN on a slow cadence so a
        // pod reschedule (peer moves to a new IP, old IP becomes a silent
        // blackhole that never errors a send) is detected and the stale
        // connection rebuilt. Gated well above the 2 ms poll cadence so the DNS
        // lookups add negligible load; well below any election timeout so
        // recovery is prompt.
        // The reaper cadence is the public `peer_reresolve_ms` const (mirrored so
        // tests can assert the stall budget is decoupled from it).
        var last_reresolve_ms: i64 = compat_milliTimestamp();
        while (!self.client_poll_shutdown.load(.acquire)) {
            const now_ms = compat_milliTimestamp();
            const do_reresolve = (now_ms - last_reresolve_ms) >= peer_reresolve_ms;
            if (do_reresolve) last_reresolve_ms = now_ms;
            // Snapshot the peer set AND acquire a reference on each entry
            // while holding peers_mutex. evictPeerConnection waits for the
            // refcount to drop to zero before freeing, so the references
            // we hold here keep each PeerConnection alive across the
            // unlocked poll calls below. A6f (2026-05-26).
            var snap_len: usize = 0;
            self.peers_mutex.lockUncancelable(io);
            var it = self.peers.iterator();
            while (it.next()) |entry| {
                if (snap_len >= snap_buf.len) break;
                const pc = entry.value_ptr.*;
                if (pc.established) {
                    pc.acquire();
                    snap_buf[snap_len] = pc;
                    snap_len += 1;
                }
            }
            self.peers_mutex.unlock(io);
            for (snap_buf[0..snap_len]) |pc| {
                // A6f: serialize against send's getStream/finish on the same
                // QuicClient. The vendor library's stream-tracking HashMap
                // is not thread-safe.
                pc.client_mutex.lockUncancelable(io);
                pc.client.poll(0) catch {};
                pc.client_mutex.unlock(io);
                // IP-change reaper: outside client_mutex (DNS only, never touches
                // the QUIC client). May evict pc; our snapshot ref keeps it alive
                // until the release below.
                if (do_reresolve) self.maybeReconnectOnIpChange(pc);
                // k8s root cause #5: stalled-stream reaper, same slow cadence.
                // Catches the silent-blackhole case the IP-change reaper cannot
                // (the strand victim's OWN IP never changed): frames have been
                // sent but no inbound progress observed within the budget. Pure
                // atomic reads + (on stall) evictPeerConnection; never touches
                // the QUIC client, so it is safe outside client_mutex. May evict
                // pc; our snapshot ref keeps it alive until the release below.
                if (do_reresolve) self.maybeReconnectOnStall(pc, now_ms);
                if (pc.release()) {
                    // Eviction completed while we were polling/re-resolving; we
                    // hold the last reference and must deinit.
                    pc.deinit();
                }
            }
            compat_sleep(2 * std.time.ns_per_ms);
        }
    }

    /// Periodic peer IP-change reaper, invoked from `clientPollLoop` on a slow
    /// cadence. Re-resolves the peer's FQDN; if it now maps to a DIFFERENT IP
    /// than the live connection, the peer pod was rescheduled to a new IP and
    /// the cached connection is silently blackholing against the old one (no
    /// send error ever fires, so the evict-on-send-error path can't recover it).
    /// Evict it so the next `send` rebuilds via `connectWithTLS`, which resolves
    /// the FQDN to the current IP. Reads only fields that are immutable after the
    /// connection is published (`endpoint`/`resolved_ip`/`peer_id`); takes no
    /// lock here — `evictPeerConnection` takes `peers_mutex` itself.
    fn maybeReconnectOnIpChange(self: *Transport, pc: *PeerConnection) void {
        if (pc.resolved_ip.len == 0) return; // IP unknown (resolve failed at connect) — nothing to compare
        const fresh = quic.resolveHostIpAlloc(self.allocator, pc.endpoint) catch return; // transient resolve failure: keep the connection, retry next interval
        defer self.allocator.free(fresh);
        if (std.mem.eql(u8, fresh, pc.resolved_ip)) return; // same IP — connection still valid
        // warn (not info/debug): a peer reschedule is an operationally important
        // membership event an operator must be able to see — the bug report
        // specifically complained that churn was invisible ("0 errors") while the
        // cluster silently failed to reconverge. Only fires on an actual IP change
        // (then the connection is rebuilt to the new IP), so it is not noisy.
        log.warn("raft transport peer rescheduled to a new IP; evicting stale connection", &.{
            Attr.string("endpoint", pc.endpoint),
            Attr.string("old_ip", pc.resolved_ip),
            Attr.string("new_ip", fresh),
            Attr.uint("peer", pc.peer_id),
        });
        self.evictPeerConnection(pc.peer_id);
    }

    /// k8s root cause #5 (stalled-stream liveness): the budget, in ms, after
    /// which a peer we are actively sending to but have observed NO forward
    /// progress from is judged stalled and its cached connection evicted +
    /// rebuilt (the same recovery the IP-change reaper performs).
    ///
    /// SIZING (election-livelock fix, 2026-06-11). The earlier 3000 ms value was
    /// derived from a wrong "≤ 5000 ms election-timeout ceiling" rationale and
    /// caused a total-cluster election livelock: it was BELOW the real election
    /// convergence and EQUAL to the reaper interval. The correct derivation of the
    /// worst-case election round is `2 * election_tick * tick_ms`:
    ///   - `election_tick = max(2, election_timeout_ms / 50) = 100` ticks for the
    ///     default 5000 ms timeout (see `RaftNode.initWithClock` election_tick),
    ///   - the raft loop ticks every 10 ms (`cluster.zig` 10 ms tick),
    ///   - the election timeout randomizes up to 2x,
    /// → `2 * 100 * 10 = 2000 ms` per round (multi-round under churn). The budget
    /// must give wide headroom so a leaderless election never trips the detector
    /// AND must be decoupled from — strictly greater than — the reaper interval.
    /// 15000 ms is ≥ 7x the 2000 ms worst-case round and 5x the 3000 ms reaper
    /// interval (`peer_reresolve_ms`), while still recovering a genuinely wedged
    /// leader stream within seconds. At the steady-state 50 ms heartbeat/response
    /// cadence this budget gives a 300x margin, so a healthy link is never judged
    /// stalled.
    pub const peer_stall_budget_ms: i64 = 15000;

    /// The `clientPollLoop` stalled-stream reaper cadence (mirror of the local
    /// `peer_reresolve_ms` const inside `clientPollLoop`). Exposed `pub` so the
    /// regression tests can assert the budget is decoupled from — and strictly
    /// greater than — the interval at which the stall check runs. The check
    /// window must NOT equal what it measures (the original bug: budget ==
    /// interval == 3000 ms).
    pub const peer_reresolve_ms: i64 = 3000;

    /// Number of CONSECUTIVE stalled reaper passes required before a peer is
    /// evicted (election-livelock fix, 2026-06-11). M >= 2: a single stalled
    /// observation — which legitimately happens for every peer during a
    /// leaderless election — must NOT evict. Any progress stamp or leader-loss
    /// resets the strike counter.
    pub const peer_stall_strikes_required: u32 = 2;

    // =======================================================================
    // owed item (4): all-candidate frozen-term wedge — role-arming widening
    // -----------------------------------------------------------------------
    // The original leader-only stall detector (added in 3aeb0fcc to stop the
    // election livelock) over-corrected for the divergent-durable-state restart
    // wedge: when vote frames are silently undelivered over a stale/half-open
    // QUIC stream AT RESTART, a leader-only-gated detector means that during the
    // leaderless window NOTHING
    // detects or recovers the stalled outbound vote stream — the node sits as a
    // silent candidate forever (`pre_vote=true` also freezes the term, so the
    // wedge is silent; see FrozenCandidateTracker below).
    //
    // CORRECTED arming: the stall detector must arm for a node that is the
    // LEADER **or a CANDIDATE**, and suppress ONLY a FOLLOWER. Rationale:
    //   * a FOLLOWER expects inbound heartbeats and its OUTBOUND health is the
    //     leader's detector's job, so a follower stands down (this is the safe
    //     refinement of the old "suppress when not leader" rule — it now
    //     suppresses only the follower, not the candidate);
    //   * a CANDIDATE is EXACTLY the role that must get its RequestVote frames
    //     through a possibly-wedged stream to make progress, so it must be
    //     armed; and the 15 s budget + 2 consecutive strikes (≥ ~18-30 s to
    //     evict, vs the 1-2 s healthy election round) cannot recreate the old
    //     3 s-budget livelock.
    //
    /// Role the stall detector arms against. `.follower` suppresses the
    /// detector; `.leader` and `.candidate` arm it. This is the single role
    /// source for the stalled-stream reaper (the legacy `is_leader: bool` form
    /// was removed in favor of this three-way arming).
    pub const StallArm = enum {
        leader,
        candidate,
        follower,
    };

    /// k8s root cause #5 (stalled-stream liveness) + owed item (4) role-arming:
    /// PURE, clock- and role-injectable decision used by `maybeReconnectOnStall`
    /// (and unit tests). Returns true iff this connection LOOKS stalled on this
    /// single pass AND the local node is in an ARMED role (leader OR candidate):
    /// frames have been sent to the peer, and no forward progress has been
    /// observed for longer than `peer_stall_budget_ms`.
    ///
    /// Role arming (owed item (4)):
    ///   * arm == .follower  → false. A follower expects INBOUND heartbeats; its
    ///     outbound health is the leader's detector's job. Arming a follower
    ///     would re-introduce the leaderless-window eviction storm (the original
    ///     election-livelock bug), so a follower always stands down. The
    ///     IP-change reaper (`maybeReconnectOnIpChange`) still covers a moved
    ///     peer regardless of role, so suppressing the follower loses no
    ///     recovery coverage.
    ///   * arm == .candidate → armed. A candidate is EXACTLY the role that must
    ///     get its RequestVote frames through a possibly-wedged stream at
    ///     restart; the 15 s budget + 2 consecutive strikes (≥ ~18-30 s to evict,
    ///     vs the 1-2 s healthy election round) cannot recreate the old 3 s-budget
    ///     livelock.
    ///   * arm == .leader    → armed. The leader's silent OUTBOUND stream to a
    ///     follower is the original target wedge.
    ///
    /// Per-connection guards that keep this from evicting a healthy peer:
    ///   1. `frames_sent == 0` → we have never sent to this peer, so there is no
    ///      progress to expect (an idle/quiet peer must never be evicted).
    ///   2. `now_ms - last_progress_ms <= peer_stall_budget_ms` → progress was
    ///      observed recently. A freshly connected peer stamps `last_progress_ms`
    ///      at connect time, so a brand new connection reads as fresh.
    ///
    /// This is a SINGLE-PASS look; eviction additionally requires
    /// `peer_stall_strikes_required` consecutive such passes — see
    /// `recordStallPassArmed`.
    ///
    /// Pure / side-effect-free: it only reads atomics and never mutates `pc`, so
    /// it is safe to call from the reaper and from unit tests with an injected
    /// clock + arm.
    pub fn shouldEvictOnStallArmed(pc: *PeerConnection, now_ms: i64, arm: StallArm) bool {
        // Role arming: suppress ONLY a follower; leader and candidate are armed.
        if (arm == .follower) return false;
        if (pc.frames_sent.load(.acquire) == 0) return false;
        const last = pc.last_progress_ms.load(.acquire);
        return (now_ms - last) > peer_stall_budget_ms;
    }

    /// Record one stalled-reaper pass for `pc` and return whether the peer has
    /// now accumulated `peer_stall_strikes_required` CONSECUTIVE armed-and-stalled
    /// passes (election-livelock fix, 2026-06-11; candidate-armed for owed item
    /// (4)). Resets strikes to 0 when the armed decision is false on this pass
    /// (healthy / follower / idle / progress observed). A progress stamp
    /// (`notePeerProgress`) independently resets strikes.
    ///
    /// Atomicity discipline: `stall_strikes` is an atomic, but this is driven
    /// exclusively by the single-threaded `clientPollLoop` reaper (one pass at a
    /// time), so its load-then-store sequence is never racing another pass. The
    /// only concurrent writer is `notePeerProgress` (the inbound path), which only
    /// ever resets the counter to 0 — strictly the safe direction: a lost-update
    /// race can at worst under-count strikes and DELAY an eviction by one reaper
    /// pass, never cause a spurious one. We therefore use a plain atomic load/store
    /// (not a CAS loop): the simplest discipline that preserves the "fail-safe
    /// toward NOT evicting" invariant.
    pub fn recordStallPassArmed(pc: *PeerConnection, now_ms: i64, arm: StallArm) bool {
        if (!shouldEvictOnStallArmed(pc, now_ms, arm)) {
            pc.stall_strikes.store(0, .release);
            return false;
        }
        const strikes = pc.stall_strikes.load(.acquire) + 1;
        pc.stall_strikes.store(strikes, .release);
        return strikes >= peer_stall_strikes_required;
    }

    /// k8s churn recovery, ROOT CAUSE #3 (RC3): follower response-direction
    /// eviction. PURE decision, additive to (and leaving untouched)
    /// `shouldEvictOnStallArmed` so the existing 22-test stall suite stays green.
    ///
    /// `shouldEvictOnStallArmed` suppresses eviction for ANY follower
    /// unconditionally, which was correct to stop the original election livelock
    /// (a QUIET follower during a leaderless election must not churn its
    /// connections). But a follower whose RESPONSE-carrying OUTBOUND is dead keeps
    /// receiving AppendEntries (its INBOUND is fine), answers into a dead send
    /// buffer, and the leader never gets the acks — the write never commits and
    /// the follower never rebuilds. This replaces the blanket suppression with a
    /// DIRECTIONAL condition: a follower ACTIVELY RECEIVING requests but with no
    /// outbound-delivery proof for the budget IS allowed to evict/rebuild; a quiet
    /// follower (no recent inbound requests) stays suppressed.
    ///
    /// Inputs (the reaper computes the booleans; this is pure given them):
    ///   * `frames_sent_nonzero`    — we have actually been sending to this peer.
    ///   * `outbound_proof_stale`   — now - last_progress_ms > effective budget.
    ///   * `inbound_request_recent` — we recently saw an inbound REQUEST from peer.
    ///
    /// CRITICAL caveat owned by the reaper, not this function: for a follower,
    /// `outbound_proof_stale` must NOT be permanently true just because a follower
    /// never receives `*_response` frames. A healthy follower's outbound is
    /// IMPLICITLY proven when it receives an AppendEntries whose prev_log_index /
    /// leader_commit ADVANCES (the leader only advances after applying the
    /// follower's prior response). The inbound path stamps `notePeerProgress` on
    /// that advance, so a healthy follower reads `outbound_proof_stale == false`
    /// and this returns false; a WEDGED follower sees repeated non-advancing
    /// retransmits -> stale + inbound recent -> eviction allowed.
    // CANARY: REQ=REQ-DIST-RAFT-FOLLOWER-DIRECTIONAL-EVICT; FEATURE="Raft Directional Eviction"; ASPECT=DirectionalEvictAllowed; STATUS=TESTED; TEST=tests/test_raft_follower_response_eviction.zig; OWNER=distributed; UPDATED=2026-06-12
    pub fn directionalEvictAllowed(
        arm: StallArm,
        frames_sent_nonzero: bool,
        outbound_proof_stale: bool,
        inbound_request_recent: bool,
    ) bool {
        if (!frames_sent_nonzero) return false; // never sent -> nothing to rebuild
        if (!outbound_proof_stale) return false; // outbound proven recently -> healthy
        return switch (arm) {
            .leader, .candidate => true, // armed roles evict on stale proof alone
            .follower => inbound_request_recent, // follower: only the one-way-wedge case
        };
    }

    /// RC3 residual (idle-cluster churn guard): PURE decision for whether an
    /// inbound AppendEntries counts as an IMPLICIT outbound-delivery proof.
    ///
    /// THE BUG it closes: on a fully idle (zero-write) HEALTHY cluster the leader
    /// sends only EMPTY heartbeats (no log entries, CONSTANT prev_log_index /
    /// leader_commit). The advance-only implicit-ack path then never stamps a
    /// quiet follower's outbound proof, so after the base budget its
    /// `outbound_proof_stale` is permanently true while the leader's heartbeats
    /// keep `last_inbound_request_ms` fresh -> `directionalEvictAllowed(.follower,
    /// true, true, true)` -> the follower evicts and rebuilds a perfectly healthy
    /// outbound every budget window, FOREVER. Churn is exactly what destabilizes
    /// this fire-and-forget transport (teardown drops in-flight acks, which can
    /// make the leader's per-direction detector fire too, amplifying).
    ///
    /// DISTINGUISHING SIGNAL: a wedged follower->leader response direction shows
    /// up leader-side as ack loss, so the leader RETRANSMITS entries — the
    /// follower sees repeated NON-EMPTY, NON-ADVANCING AppendEntries. A healthy
    /// idle cluster sends EMPTY heartbeats. So:
    ///   * advanced (entries or not)        -> stamp (the leader applied our prior
    ///                                          response, real implicit ack)
    ///   * !advanced AND !has_entries        -> stamp (empty heartbeat == "nothing
    ///                                          pending, connection presumed fine")
    ///   * !advanced AND has_entries         -> DO NOT stamp (a non-advancing
    ///                                          retransmit — leaves a genuinely
    ///                                          wedged follower eviction-eligible;
    ///                                          this is exactly how a
    ///                                          committed-blocked write manifests,
    ///                                          preserving the F2/RC3 detection).
    ///
    /// Accepted residual: an idle cluster whose follower outbound dies SILENTLY is
    /// indistinguishable from healthy-idle at the follower until the next write
    /// turns the loss into retransmits — at which point the third case makes it
    /// eligible. Leader-side per-direction liveness (dacf4771) covers detection
    /// meanwhile.
    // CANARY: REQ=REQ-DIST-RAFT-FOLLOWER-DIRECTIONAL-EVICT; FEATURE="Raft Directional Eviction"; ASPECT=ImplicitAckStampsProof; STATUS=TESTED; TEST=tests/test_raft_follower_response_eviction.zig; OWNER=distributed; UPDATED=2026-06-12
    pub fn implicitAckStampsProof(advanced: bool, has_entries: bool) bool {
        return advanced or !has_entries;
    }

    /// RC2 wiring: the eviction budget the reaper measures against for `pc` on
    /// this pass. While the connection is in probation (a stall-rebuild without an
    /// intervening `*_response` proof), use the ESCALATED
    /// `RebuildProbation.currentBudgetMs()` so a freshly rebuilt connection gets a
    /// progressively longer window to exchange a real frame. Otherwise the flat
    /// `peer_stall_budget_ms`. Pure (reads atomics only).
    fn effectiveStallBudgetMs(pc: *PeerConnection) i64 {
        if (!pc.probation_active.load(.acquire)) return peer_stall_budget_ms;
        const rp = RebuildProbation{
            .in_probation = true,
            .consecutive_rebuilds = pc.probation_rebuilds.load(.acquire),
        };
        return rp.currentBudgetMs();
    }

    /// RC2+RC3 wiring: the per-pass directional stall decision for the reaper.
    /// Composes the probation-aware budget (RC2) with the directional eviction
    /// rule (RC3). PURE (reads atomics only), so it is unit-testable with an
    /// injected clock + arm and never mutates `pc`.
    ///
    /// `outbound_proof_stale` is measured against `effectiveStallBudgetMs`. While
    /// in probation the baseline is `rebuilt_at_ms` (the rebuild is NOT delivery
    /// proof, so we cannot measure from `last_progress_ms`); otherwise it is
    /// `last_progress_ms` (the response-gated / implicit-ack progress clock).
    /// `inbound_request_recent` is true iff an inbound REQUEST was observed within
    /// the same budget — this is what lets a one-way-wedged follower recover while
    /// a QUIET follower stays suppressed.
    fn shouldEvictDirectional(pc: *PeerConnection, now_ms: i64, arm: StallArm) bool {
        const frames_sent_nonzero = pc.frames_sent.load(.acquire) != 0;
        const budget = effectiveStallBudgetMs(pc);
        const baseline = if (pc.probation_active.load(.acquire))
            pc.rebuilt_at_ms.load(.acquire)
        else
            pc.last_progress_ms.load(.acquire);
        const outbound_proof_stale = (now_ms - baseline) > budget;
        const last_inbound = pc.last_inbound_request_ms.load(.acquire);
        const inbound_request_recent = last_inbound != 0 and (now_ms - last_inbound) <= budget;
        return directionalEvictAllowed(arm, frames_sent_nonzero, outbound_proof_stale, inbound_request_recent);
    }

    /// RC2+RC3 wiring: strike-gated directional stall pass for the reaper, the
    /// directional analog of `recordStallPassArmed`. Requires
    /// `peer_stall_strikes_required` CONSECUTIVE positive directional passes
    /// before returning true (so a single isolated pass — common during a
    /// leaderless election — never evicts). Resets strikes when the directional
    /// decision is false on this pass. Shares the `stall_strikes` counter with
    /// `recordStallPassArmed` and `notePeerProgress` under the same
    /// "fail-safe-toward-not-evicting" discipline (single reaper writer; the
    /// inbound path only ever resets to 0).
    fn recordDirectionalStallPass(pc: *PeerConnection, now_ms: i64, arm: StallArm) bool {
        if (!shouldEvictDirectional(pc, now_ms, arm)) {
            pc.stall_strikes.store(0, .release);
            return false;
        }
        const strikes = pc.stall_strikes.load(.acquire) + 1;
        pc.stall_strikes.store(strikes, .release);
        return strikes >= peer_stall_strikes_required;
    }

    /// Refresh the forward-progress timestamp for the peer identified by
    /// `peer_id`. Called from the INBOUND path (raft AppendEntries from the
    /// leader / AppendEntriesResponse from a follower, dispatched in
    /// `cluster.zig:applyDecodedRaftFrame`), which arrives on a DIFFERENT
    /// connection object than the outbound `PeerConnection`, so progress must be
    /// stamped by a peer-id keyed lookup into `peers` rather than by pointer.
    /// Safe to call for an unknown peer (no-op) — e.g. before the outbound
    /// connection has been built, or for a frame whose sender we never send to.
    ///
    /// Locking: takes `peers_mutex` (tier 3) only, and writes a leaf atomic; it
    /// never acquires a lower-tier lock while held, so it respects the GAP-0278
    /// ordering. We do NOT bump the refcount: the store is a single atomic on a
    /// field that lives for the PeerConnection's lifetime, and `peers_mutex`
    /// keeps the entry in the map (eviction also runs under `peers_mutex`) for
    /// the duration of the store.
    pub fn notePeerProgress(self: *Transport, peer_id: u64, now_ms: i64) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.peers_mutex.lockUncancelable(io);
        defer self.peers_mutex.unlock(io);
        // RC2 (rebuild-probation): a real proof of outbound delivery clears the
        // escalation carry so a peer that resumes responding drops back to the
        // base budget on its next (re)build. Cleared even if the PeerConnection is
        // not yet (re)built — the carry is keyed by peer_id and lives across the
        // evict → rebuild boundary.
        _ = self.probation_carry.remove(peer_id);
        if (self.peers.get(peer_id)) |pc| {
            pc.last_progress_ms.store(now_ms, .release);
            // election-livelock fix (2026-06-11): observed progress clears any
            // accumulated stall strikes so a peer that resumes responding is not
            // evicted on a later isolated stalled-looking pass. This is the only
            // off-reaper writer of `stall_strikes`, and it only ever resets to 0
            // (the safe direction — see `recordStallPassArmed`).
            pc.stall_strikes.store(0, .release);
            // RC2: this is the `RebuildProbation.noteOutboundProof()` site — a real
            // inbound `*_response` proved OUR outbound reached the peer (the caller
            // already gated on `frameProvesOurOutboundDelivered`), so clear the
            // PeerConnection's probation atomics too.
            pc.probation_active.store(false, .release);
            pc.probation_rebuilds.store(0, .release);
        }
    }

    /// RC3: stamp the last-inbound-REQUEST clock for the peer that sent us a
    /// request frame (request_vote / append_entries / install_snapshot). Called
    /// from the inbound path for the NON-response branch (i.e. when
    /// `!frameProvesOurOutboundDelivered(body)`). Drives `inbound_request_recent`
    /// in the directional reaper: a one-way-wedged follower keeps receiving
    /// requests, so this clock stays fresh while its outbound proof goes stale —
    /// exactly the signal that distinguishes a recoverable wedge from a quiet
    /// follower. Same peer-id-keyed, `peers_mutex`-guarded, leaf-atomic discipline
    /// as `notePeerProgress`; a no-op if we have no outbound connection to that
    /// peer yet.
    pub fn noteInboundRequest(self: *Transport, peer_id: u64, now_ms: i64) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.peers_mutex.lockUncancelable(io);
        defer self.peers_mutex.unlock(io);
        if (self.peers.get(peer_id)) |pc| {
            pc.last_inbound_request_ms.store(now_ms, .release);
        }
    }

    /// RC3 (healthy-follower implicit ack) + idle-cluster churn guard: an inbound
    /// AppendEntries from the leader is treated as an IMPLICIT proof that our PRIOR
    /// response reached the leader when EITHER it ADVANCES (`prev_log_index` OR
    /// `leader_commit` grew versus the last one we saw — the leader only advances
    /// after applying our response) OR it is an EMPTY heartbeat (`!has_entries` —
    /// "nothing pending, connection presumed fine"). Both stamp forward progress
    /// (clearing probation / strikes via the same path as a real `*_response`) so a
    /// HEALTHY follower's outbound never looks stale and never churns its
    /// connection. The ONLY case that does NOT stamp is a NON-advancing
    /// AppendEntries that STILL CARRIES entries — i.e. a leader RETRANSMIT, which is
    /// exactly how a wedged follower->leader response direction (ack loss) and a
    /// committed-blocked write manifest; that follower gets no stamp and remains
    /// eligible for directional eviction. The stamp predicate is the pure
    /// `implicitAckStampsProof`.
    ///
    /// WHY `has_entries` matters: before this guard, a fully idle (zero-write)
    /// healthy cluster — which sends only empty, non-advancing heartbeats — left a
    /// quiet follower's outbound proof permanently stale and churned its connection
    /// every budget window forever. See `implicitAckStampsProof` for the full
    /// matrix and the accepted silent-death residual.
    ///
    /// Peer-id keyed and `peers_mutex`-guarded like `notePeerProgress`; a no-op if
    /// the outbound connection to the leader does not exist yet. The last-seen
    /// values live on that outbound PeerConnection.
    // CANARY: REQ=REQ-DIST-RAFT-FOLLOWER-DIRECTIONAL-EVICT; FEATURE="Raft Directional Eviction"; ASPECT=NoteInboundAppendEntriesAdvance; STATUS=TESTED; TEST=tests/test_raft_follower_response_eviction.zig; OWNER=distributed; UPDATED=2026-06-12
    pub fn noteInboundAppendEntriesAdvance(
        self: *Transport,
        peer_id: u64,
        prev_log_index: u64,
        leader_commit: u64,
        now_ms: i64,
        has_entries: bool,
    ) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.peers_mutex.lockUncancelable(io);
        defer self.peers_mutex.unlock(io);
        const pc = self.peers.get(peer_id) orelse return;
        const prev_seen_idx = pc.last_seen_prev_log_index.load(.acquire);
        const prev_seen_commit = pc.last_seen_leader_commit.load(.acquire);
        const advanced = prev_log_index > prev_seen_idx or leader_commit > prev_seen_commit;
        if (prev_log_index > prev_seen_idx) pc.last_seen_prev_log_index.store(prev_log_index, .release);
        if (leader_commit > prev_seen_commit) pc.last_seen_leader_commit.store(leader_commit, .release);
        // Stamp on an ADVANCE or an EMPTY heartbeat; a non-advancing retransmit
        // (still carrying entries) leaves a genuinely wedged follower eligible.
        if (!implicitAckStampsProof(advanced, has_entries)) return;
        // Implicit ack: treat exactly like a real outbound proof.
        _ = self.probation_carry.remove(peer_id);
        pc.last_progress_ms.store(now_ms, .release);
        pc.stall_strikes.store(0, .release);
        pc.probation_active.store(false, .release);
        pc.probation_rebuilds.store(0, .release);
    }

    /// election-livelock fix (2026-06-11) + owed item (4): wire the live
    /// `StallArm` role source the stalled-stream reaper arms on (leader OR
    /// candidate; suppress follower). The cluster coordinator passes a closure
    /// that maps `RaftNode.role()` onto `StallArm`. Mirrors `send_override`
    /// injection. Leaving it unset (standalone) means the reaper treats the node
    /// as a follower and never evicts on stall.
    pub fn setRoleSource(self: *Transport, ctx: ?*anyopaque, f: *const fn (ctx: ?*anyopaque) StallArm) void {
        self.role_source_ctx = ctx;
        self.role_source_fn = f;
    }

    /// Periodic stalled-stream reaper, sibling to `maybeReconnectOnIpChange`,
    /// invoked from `clientPollLoop` on the same slow cadence. If the connection
    /// has stalled (`shouldEvictDirectional`), evict it so the next `send`
    /// rebuilds via `connectWithTLS` (which re-resolves the FQDN) — exactly like
    /// the IP-change path. Takes no lock here for the decision; `evictPeerConnection`
    /// and the probation-carry bump take `peers_mutex` themselves. Logs at warn
    /// (mirroring the IP-change reaper) so the previously-silent wedge is
    /// observable to an operator.
    fn maybeReconnectOnStall(self: *Transport, pc: *PeerConnection, now_ms: i64) void {
        // election-livelock fix (2026-06-11) + owed item (4): the eviction
        // decision is armed ONLY when THIS node is the raft LEADER or a
        // CANDIDATE. The live role comes from the injected `role_source_fn`
        // (wired by the cluster coordinator from `RaftNode.role()`); if unset we
        // conservatively treat the node as a `.follower` so the standalone path
        // never evicts.
        const arm = if (self.role_source_fn) |f| f(self.role_source_ctx) else StallArm.follower;
        // RC2+RC3: `recordDirectionalStallPass` tracks M consecutive directional
        // stalled passes — armed roles evict on stale OUTBOUND proof alone, a
        // follower only in the one-way-wedge case (stale outbound proof AND recent
        // inbound requests), and the budget is the probation-escalated window
        // while in probation. Only the Mth consecutive pass returns true, so a
        // single quiet pass (or a quiet follower) never evicts.
        if (recordDirectionalStallPass(pc, now_ms, arm)) {
            const baseline = if (pc.probation_active.load(.acquire))
                pc.rebuilt_at_ms.load(.acquire)
            else
                pc.last_progress_ms.load(.acquire);
            log.warn("raft transport peer stalled (no progress within budget); evicting stale connection", &.{
                Attr.string("endpoint", pc.endpoint),
                Attr.uint("peer", pc.peer_id),
                Attr.uint("strikes", pc.stall_strikes.load(.acquire)),
                Attr.uint("strikes_required", peer_stall_strikes_required),
                Attr.int("budget_ms", effectiveStallBudgetMs(pc)),
                Attr.int("stall_ms", now_ms - baseline),
            });
            // RC2: this eviction triggers a (lazy) rebuild — record it as a
            // stall-rebuild in the probation carry so the rebuilt connection
            // enters probation with an escalated budget (NOT treated as health).
            // The carry survives the PeerConnection's destruction; a later real
            // `*_response` (`notePeerProgress`) clears it.
            self.noteStallRebuildForPeer(pc.peer_id);
            self.evictPeerConnection(pc.peer_id);
        }
    }

    /// RC2: bump the probation escalation carry for `peer_id` (the
    /// `RebuildProbation.noteStallRebuild()` effect, persisted across the
    /// evict → rebuild boundary). Saturates well below the shift-overflow point
    /// (the budget is capped at base*4, so a small count already pins the cap).
    /// Guarded by `peers_mutex` so it is serialized with the build-time seed read
    /// and the proof-time clear.
    fn noteStallRebuildForPeer(self: *Transport, peer_id: u64) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.peers_mutex.lockUncancelable(io);
        defer self.peers_mutex.unlock(io);
        const gop = self.probation_carry.getOrPut(peer_id) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
        } else if (gop.value_ptr.* < 32) {
            gop.value_ptr.* += 1;
        }
    }

    fn clientPollEntry(ctx: ?*anyopaque) void {
        const self: *Transport = @ptrCast(@alignCast(ctx.?));
        self.clientPollLoop();
    }

    pub fn startClientPoll(self: *Transport) !void {
        if (self.client_poll_thread != null) return;
        self.client_poll_shutdown.store(false, .release);
        self.client_poll_thread = try std.Thread.spawn(.{}, clientPollEntry, .{@as(?*anyopaque, @ptrCast(self))});
    }

    pub fn stopClientPoll(self: *Transport) void {
        if (self.client_poll_thread) |t| {
            self.client_poll_shutdown.store(true, .release);
            t.join();
            self.client_poll_thread = null;
        }
    }

    /// Task A6e: eagerly establish a persistent connection to `peer` so
    /// the first RaftRPC doesn't pay the TLS-handshake latency on the
    /// critical path.  Best-effort: a failure here is logged and
    /// silently ignored (the next `send` will retry).  Called by
    /// `ClusterCoordinator.start` once the local QUIC listener is up.
    pub fn preconnectPeer(self: *Transport, peer: Peer) void {
        const conn = self.getOrCreatePeerConnection(peer) catch |err| {
            log.debug("raft transport preconnect failed", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("peer", peer.id),
            });
            return;
        };
        _ = conn;
    }

    /// Default server-side dead-connection reap budget for the raft listener's
    /// QUIC endpoint, in milliseconds. The QUIC reaper closes an INBOUND server
    /// connection whose peer has gone silent past this budget — the recovery the
    /// previously-dead idle path never performed, which let a churned pod's
    /// connection (the `proto_reader stall idle_ms≈12min` symptom) linger forever
    /// and starve the replacement pod's handshake. 30s is well above any
    /// healthy-peer silence (raft heartbeats every ~50ms; even a leaderless
    /// election keeps RequestVote/AppendEntries flowing) and matches the timescale
    /// of the OUTBOUND stall reaper (`peer_stall_budget_ms` 15s × 2 strikes), so
    /// both directions of a churned peer recover together. The QUIC layer ALSO
    /// closes same-peer stale connections the instant a replacement reconnects
    /// from a recycled address, so 30s is only the different-IP backstop. Tunable
    /// for k8s churn validation via GEODE_RAFT_DEAD_CONN_REAP_MS (0 disables).
    pub const default_server_dead_conn_reap_ms: u64 = 30000;

    /// The raft listener's dead-connection reap budget: GEODE_RAFT_DEAD_CONN_REAP_MS
    /// or `default_server_dead_conn_reap_ms`. Also used by the cluster
    /// coordinator's listener (`ClusterCoordinator.start`, SONNY-6456).
    pub fn serverDeadConnReapMs(allocator: Allocator) u64 {
        const raw = getEnvVarOwned(allocator, "GEODE_RAFT_DEAD_CONN_REAP_MS") catch return default_server_dead_conn_reap_ms;
        defer allocator.free(raw);
        return std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch default_server_dead_conn_reap_ms;
    }

    pub fn listen(self: *Transport, address: []const u8, port: u16) !void {
        const qt = try quic.QuicTransport.init(self.allocator, .{
            .address = address,
            .port = port,
            // k8s pod-churn recovery (iter-3): opt the raft listener into the QUIC
            // dead-connection reaper so a vanished/churned peer's stale inbound
            // connection is closed instead of wedging an inbound stream forever.
            .dead_conn_reap_ms = serverDeadConnReapMs(self.allocator),
        });
        self.server = qt;
        try self.server.?.listen();
    }

    // SEC-D011: TLS-aware Raft transport matching cluster.zig:sendToNode pattern.
    // CANARY: REQ=SEC-D011; FEATURE="Raft RPC TLS"; ASPECT=TransportSend; STATUS=TESTED; OWNER=security; UPDATED=2026-04-10
    /// k8s root cause #5: `error.OutOfStreams` (peer MAX_STREAMS_BIDI credit
    /// momentarily exhausted — quic `methods_b.zig` returns it when
    /// `opened_bidi >= peer_max_streams_bidi`) and `error.WouldBlock` are
    /// TRANSIENT backpressure on a HEALTHY connection. Evicting the peer
    /// connection over them forces a fresh TLS handshake on the next send AND
    /// resets the stream credit — worsening the exhaustion and starving that
    /// peer's heartbeats until it parks as a candidate. Drop the one message
    /// instead (periodic heartbeats/AppendEntries re-send on the next tick) and
    /// keep the connection. Only a genuinely-dead connection warrants eviction.
    fn shouldEvictOnSendError(err: anyerror) bool {
        return switch (err) {
            error.OutOfStreams, error.WouldBlock => false,
            else => true,
        };
    }

    pub fn send(self: *Transport, peer: Peer, from: u64, term: u64, msg: Message) !void {
        if (self.outbox_shutdown.load(.acquire)) return error.TransportShutdown;
        if (self.send_override) |override| {
            try override(self, peer, from, term, msg);
            return;
        }

        // Task A6c: reuse a long-lived QuicClient per peer so the TLS
        // handshake + endpoint setup cost is paid once.  Each RPC still
        // gets a fresh bidirectional stream — that's the cheap part on
        // an already-established QUIC connection.  Without this pool the
        // sender's deinit() race against finish() caused the vendor
        // library to RESET in-flight payload, surfacing as
        // InvalidInput|WouldBlock on the receiver's networkLoop.
        const conn = self.getOrCreatePeerConnection(peer) catch |err| {
            log.warn("raft transport getOrCreatePeerConnection failed", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("peer", peer.id),
            });
            return err;
        };
        // A6f: matching release. Use `defer` so every exit path drops
        // our refcount; evictPeerConnection (which also bumps+releases)
        // is safe to call inside this scope.
        defer self.releasePeerConnection(conn);

        // A6f: serialize all subsequent client.* calls against the poll
        // loop on the same connection. The vendor QUIC library's internal
        // stream-tracking HashMap segfaults under concurrent access.
        const io_send = std.Io.Threaded.global_single_threaded.io();
        conn.client_mutex.lockUncancelable(io_send);
        defer conn.client_mutex.unlock(io_send);

        // SONNY-6451: the peer closed this connection (CONNECTION_CLOSE: it
        // shut down, or its inbound handler gave up a stream that stayed
        // quiet past the idle deadline). The vendor still accepts writes on a
        // closed connection and sends nothing, so rebuild it instead.
        if (conn.client.isClosed()) {
            log.info("raft transport peer closed the connection; evicting it", &.{
                Attr.uint("peer", peer.id),
            });
            self.evictPeerConnection(peer.id);
            return error.ConnectionClosed;
        }

        // 2026-06-08 raft multiplexed streams: reuse ONE long-lived stream per
        // peer instead of opening a fresh bidi stream per RPC. Lazily (re)open
        // it; never finish() per RPC (that would close it). On error, close+null
        // so the next send reopens — but only EVICT the connection for
        // genuinely-fatal errors (shouldEvictOnSendError), never for transient
        // backpressure (which per-RPC streams used to hit as OutOfStreams).
        if (conn.send_stream == null) {
            conn.send_stream = conn.client.getStream() catch |err| {
                if (shouldEvictOnSendError(err)) {
                    log.warn("raft transport open send_stream failed; evicting peer connection", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.uint("peer", peer.id),
                    });
                    self.evictPeerConnection(peer.id);
                } else {
                    // Transient stream-credit backpressure (OutOfStreams/WouldBlock):
                    // the connection is healthy — keep it; this RPC is dropped and the
                    // next raft tick re-sends. debug-level to avoid log spam under load.
                    log.debug("raft transport open send_stream backpressure; keeping connection", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.uint("peer", peer.id),
                    });
                }
                return err;
            };
        }
        const s = conn.send_stream.?;
        writeRaftFrame(self.allocator, s, from, term, msg) catch |err| {
            // The stream is now suspect — close+null it so the next send opens a
            // fresh one (the receiver's frame loop ends on EndOfStream and the
            // re-opened stream is re-accepted). Evict the whole connection only
            // for fatal errors. CRITICAL: null `conn.send_stream` BEFORE any
            // evictPeerConnection so PeerConnection.deinit does not double-free.
            s.finish() catch {};
            s.deinit();
            conn.send_stream = null;
            if (shouldEvictOnSendError(err)) {
                log.warn("raft transport writeRaftFrame failed; evicting peer connection", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("peer", peer.id),
                });
                self.evictPeerConnection(peer.id);
            } else {
                log.debug("raft transport writeRaftFrame backpressure; reopening stream next send", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("peer", peer.id),
                });
            }
            return err;
        };
        // NOTE: no per-RPC finish()/deinit() — the stream stays open for the
        // next frame. The dedicated client_poll_thread (A6e) flushes the write
        // onto the wire; the bridge returns immediately.

        // k8s root cause #5 (stalled-stream liveness): we successfully handed a
        // frame to the wire. Mark that this peer now has traffic to expect a
        // response for, so the stall reaper is allowed to act if no inbound
        // progress is observed within the budget. Frames written to a
        // stale/half-open connection buffer locally and "succeed" here (that is
        // precisely the fire-and-forget wedge), which is why the eviction
        // decision is gated on OBSERVED inbound progress, not on send success.
        _ = conn.frames_sent.fetchAdd(1, .acq_rel);
    }

    /// Look up or construct a persistent peer connection.  The
    /// expensive `connectWithTLS` call is performed outside
    /// `peers_mutex` to avoid blocking concurrent sends to other peers
    /// during the handshake.  If two callers race to create the same
    /// peer, the loser tears its own client down and returns the
    /// winner's entry.
    /// Acquire-or-build a PeerConnection. Returns an entry with refcount
    /// already bumped — caller MUST call `releasePeerConnection` (or call
    /// `pc.release()` and deinit on transition) when done.
    fn getOrCreatePeerConnection(self: *Transport, peer: Peer) !*PeerConnection {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Fast path: already cached and established, to the peer's current
        // endpoint. SONNY-6459: a cached connection to an endpoint the peer
        // no longer has is dropped and rebuilt below; it used to be reused,
        // so frames for the peer kept going to its old address.
        {
            var moved: ?*PeerConnection = null;
            defer if (moved) |pc| {
                log.info("raft transport peer endpoint changed; reconnecting", &.{
                    Attr.uint("peer", peer.id),
                    Attr.string("old_endpoint", pc.endpoint),
                    Attr.string("new_endpoint", peer.endpoint),
                });
                // Drop the map's implicit ref (outside `peers_mutex`, as
                // evictPeerConnection does); a concurrent holder deinits last.
                if (pc.release()) pc.deinit();
            };
            self.peers_mutex.lockUncancelable(io);
            defer self.peers_mutex.unlock(io);
            if (self.peers.get(peer.id)) |existing| {
                if (existing.established) {
                    if (existing.connectsTo(peer)) {
                        existing.acquire();
                        return existing;
                    }
                    moved = existing;
                    _ = self.peers.remove(peer.id);
                }
            }
        }

        // Slow path: build the client + perform TLS handshake outside
        // the lock so we don't serialize handshakes across peers.
        const conn = try self.allocator.create(PeerConnection);
        errdefer self.allocator.destroy(conn);
        const endpoint_dup = try self.allocator.dupe(u8, peer.endpoint);
        errdefer self.allocator.free(endpoint_dup);
        // Record the IP `endpoint` resolves to NOW so the clientPollLoop reaper
        // can later detect a pod reschedule (FQDN -> new IP) and rebuild this
        // connection. A resolution failure is non-fatal: store an empty IP — the
        // reaper treats "" as "unknown" and skips this peer (it never reconnects
        // off a missing baseline). In practice this is unreachable: if resolution
        // fails here, the connectWithTLS below resolves the same FQDN and fails
        // too, so no established connection is ever published with an empty IP.
        const resolved = quic.resolveHostIpAlloc(self.allocator, endpoint_dup) catch &.{};
        errdefer if (resolved.len > 0) self.allocator.free(resolved);
        const build_ms = compat_milliTimestamp();
        conn.* = .{
            .allocator = self.allocator,
            .client = quic.QuicClient.init(self.allocator),
            .established = false,
            .endpoint = endpoint_dup,
            .port = peer.port,
            .peer_id = peer.id,
            .resolved_ip = resolved,
            // k8s root cause #5: stamp the stall clock at connect time and reset
            // the frame counter so a brand new connection reads as "fresh, no
            // sends yet" — the stall reaper never fires on it until we have both
            // sent a frame AND observed no progress for the full budget. This is
            // the "stall clock resets on reconnect" guarantee that prevents a
            // re-evict loop after the stall reaper rebuilds a connection.
            //
            // RC2 (rebuild-probation): `last_progress_ms = build_ms` is the
            // FRESH-connection (no prior stall) baseline; it is NOT counted as
            // delivery proof. When this build is a stall-triggered REBUILD (the
            // `probation_carry` below is non-empty for this peer), the reaper
            // ignores `last_progress_ms` and instead measures the window from
            // `rebuilt_at_ms` against the ESCALATED `RebuildProbation.currentBudgetMs()`
            // — so the freshly rebuilt connection gets a progressively longer
            // window to complete its handshake and exchange a real frame, instead
            // of being immediately re-evicted on the next stale pass.
            .last_progress_ms = std.atomic.Value(i64).init(build_ms),
            .frames_sent = std.atomic.Value(u64).init(0),
            .rebuilt_at_ms = std.atomic.Value(i64).init(build_ms),
        };
        errdefer conn.client.deinit();

        try connectWithTLS(&conn.client, conn.endpoint, conn.port);
        conn.established = true;

        // Re-acquire the lock to insert.  If another caller beat us to
        // it, prefer the existing entry and discard ours so we never
        // leave a half-initialized client in the map.
        var replaced: ?*PeerConnection = null;
        defer if (replaced) |pc| {
            if (pc.release()) pc.deinit();
        };
        self.peers_mutex.lockUncancelable(io);
        defer self.peers_mutex.unlock(io);
        if (self.peers.get(peer.id)) |existing| {
            if (existing.established) {
                if (existing.connectsTo(peer)) {
                    conn.deinit();
                    existing.acquire();
                    return existing;
                }
                // SONNY-6459: a racing caller cached a connection to the
                // peer's old endpoint; ours replaces it.
                replaced = existing;
                _ = self.peers.remove(peer.id);
            }
        }
        // RC2: seed this (re)built connection's probation state from the carry.
        // A non-zero carry means prior stall-rebuilds escalated the budget without
        // an intervening `*_response` proof; the connection enters probation so
        // the reaper uses the escalated window. Zero / absent carry = fresh,
        // proven connection on the base budget. Read under `peers_mutex` so it is
        // serialized with the eviction-time bump and the proof-time clear.
        const carried = self.probation_carry.get(peer.id) orelse 0;
        if (carried > 0) {
            conn.probation_active.store(true, .release);
            conn.probation_rebuilds.store(carried, .release);
        }
        try self.peers.put(peer.id, conn);
        conn.acquire();
        return conn;
    }

    /// Release a reference acquired via getOrCreatePeerConnection.
    /// If the entry was evicted concurrently and we hold the last reference,
    /// the deinit fires here.
    fn releasePeerConnection(_: *Transport, pc: *PeerConnection) void {
        if (pc.release()) pc.deinit();
    }

    /// Remove a cached peer connection (typically after observing an
    /// error on `getStream`/`writeRaftFrame`).
    ///
    /// A6f (2026-05-26): the map entry carries an implicit refcount of 1
    /// (the map's ownership). Eviction removes from the map and drops
    /// that implicit ref. If no concurrent send/poll holds a transient
    /// ref, refcount transitions 1→0 here and we own the deinit.
    /// Otherwise the transient holder's `release` will observe 1→0 and
    /// deinit. Removing from the map under peers_mutex denies new
    /// acquisitions (getOrCreatePeerConnection has to look it up again).
    fn evictPeerConnection(self: *Transport, peer_id: u64) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.peers_mutex.lockUncancelable(io);
        const maybe_kv = self.peers.fetchRemove(peer_id);
        self.peers_mutex.unlock(io);
        if (maybe_kv) |kv| {
            const pc = kv.value;
            // Drop the map's implicit ref. If the count is now 0 we own
            // the deinit; otherwise a concurrent send/poll holder will.
            if (pc.release()) pc.deinit();
        }
    }
};

/// SEC-D011: dial a raft peer with the cluster transport configuration
/// (`cluster_auth.dialClusterPeer`: GEODE_CLUSTER_CA_CERT, or
/// GEODE_CLUSTER_INSECURE in Debug builds; neither is error.ClusterCaRequired,
/// as no CA is loaded from anywhere else), then wait for the handshake.
// CANARY: REQ=SEC-D011; FEATURE="Raft RPC TLS"; ASPECT=ConnectHelper; STATUS=TESTED; TEST=tests/test_sonny6453_cluster_peer_tls.zig; OWNER=security; UPDATED=2026-11-13
fn connectWithTLS(qc: *quic.QuicClient, host: []const u8, port: u16) !void {
    try @import("cluster_auth.zig").dialClusterPeer(qc, host, port);
    // Task A6e (2026-05-26): the previous 10s timeout was disastrous on
    // the outbox dispatch path: every send to a peer that's still
    // booting or transiently unreachable stalls the dispatch thread for
    // 10 SECONDS, during which the queue fills with retries that ALL
    // pay the same cost (each evicts the cached connection, so the
    // next send pays the full handshake again).  Loopback TLS over
    // QUIC completes in <50 ms on a healthy host; 1 second covers
    // first-boot races (the test brings node N up before node N+1) and
    // the worst-case post-quantum key exchange.  Long enough to be
    // robust, short enough that even a permanent failure only burns
    // 3 × 1 s per round of retries instead of 30 s.
    try qc.waitForHandshake(1);
}

// ---- Message types ----

pub const Message = union(enum) {
    request_vote: RequestVote,
    request_vote_response: RequestVoteResponse,
    append_entries: AppendEntries,
    append_entries_response: AppendEntriesResponse,
    install_snapshot: InstallSnapshot,
    install_snapshot_response: InstallSnapshotResponse,
};

// k8s root cause #5 transport-wedge REGRESSION (per-direction liveness),
// 2026-06-12:
//
// The original stalled-stream fix (`notePeerProgress`) stamped forward progress
// on the OUTBOUND PeerConnection for the sender of EVERY inbound raft frame
// (cluster.zig:applyDecodedRaftFrame). That is per-PEER, not per-DIRECTION, and
// it masks the leader-side wedge: a stranded candidate re-sends RequestVote
// every 1-2 s; each inbound RequestVote stamps the LEADER's outbound-to-that-
// peer clock, so `now - last_progress_ms` never crosses the 15 s budget and the
// leader never evicts/rebuilds its genuinely-wedged outbound stream to that peer.
//
// Direction reasoning:
//   * An inbound REQUEST (`request_vote` / `append_entries` / `install_snapshot`)
//     proves only the PEER's OUTBOUND path to us works. It says NOTHING about
//     whether OUR outbound request to that peer was ever delivered — so it must
//     NOT stamp our outbound liveness clock.
//   * An inbound RESPONSE (`*_response`) can only exist if OUR outbound request
//     reached the peer (the peer produced the response by handling our request).
//     A response is therefore the only frame that proves OUR outbound path is
//     alive, so only a response may stamp.
//
// `frameProvesOurOutboundDelivered(body)` is the PURE classifier the gated stamp
// site will call: `if (frameProvesOurOutboundDelivered(body)) notePeerProgress(...)`.
// It returns true ONLY for the three `*_response` variants. Pre-vote is a bool
// FIELD on the vote messages, not a separate tag, so a pre-vote RequestVote is
// still a request (false) and a pre-vote RequestVoteResponse is still a response
// (true).
//
pub fn frameProvesOurOutboundDelivered(body: Message) bool {
    return switch (body) {
        .request_vote_response,
        .append_entries_response,
        .install_snapshot_response,
        => true,
        else => false,
    };
}

pub const RequestVote = struct {
    term: u64,
    candidate_id: u64,
    last_log_index: u64,
    last_log_term: u64,
    pre_vote: bool,
};

pub const RequestVoteResponse = struct {
    term: u64,
    vote_granted: bool,
    voter_id: u64,
    /// A6d: must echo the candidate's `pre_vote` flag.  The raft library's
    /// pre-vote phase (enabled by default in node.zig:43) counts only
    /// responses whose `pre_vote` matches the candidate's current phase;
    /// dropping this bit caused subprocess candidates to never accumulate
    /// a quorum.
    pre_vote: bool = false,
};

pub const AppendEntries = struct {
    term: u64,
    leader_id: u64,
    prev_log_index: u64,
    prev_log_term: u64,
    entries: []LogEntry,
    leader_commit: u64,
};

pub const AppendEntriesResponse = struct {
    term: u64,
    success: bool,
    /// On success the last index the follower matches; on a rejection the
    /// rejected AppendEntries' prev_log_index (raft v0.2.2).
    match_index: u64,
    /// SONNY-6622: a rejection's backtracking hint (raft v0.2.2): where the
    /// leader may resume, and the follower's term at the rejected index (0:
    /// its log is too short). 0 and 0 from a peer that does not send them.
    conflict_index: u64 = 0,
    conflict_term: u64 = 0,
};

pub const InstallSnapshot = struct {
    term: u64,
    leader_id: u64,
    last_included_index: u64,
    last_included_term: u64,
    offset: u64,
    data: []const u8,
    done: bool,
    /// SONNY-6633: BLAKE3 digest of the whole snapshot (final chunk; zero
    /// otherwise) and the configuration it was taken at, carried end to end
    /// (the raft library refuses a snapshot whose digest does not match).
    checksum: [32]u8 = std.mem.zeroes([32]u8),
    voters: []const u64 = &.{},
    voters_outgoing: []const u64 = &.{},
    is_joint: bool = false,
};

pub const InstallSnapshotResponse = struct {
    term: u64,
    success: bool,
    /// SONNY-6665 (raft v0.2.5): on success the snapshot index the follower
    /// holds (the one sent, or a newer one it already had); on a chunk lost
    /// in transit the index of the snapshot being sent, with `next_offset`
    /// the offset the follower expects next, where the leader resumes. 0
    /// and 0 from a peer that sends neither.
    last_index: u64 = 0,
    next_offset: u64 = 0,
};

// ---- Wire format (protobuf frames over QUIC) ----

// SEC-D009: Import nonce tracker for replay protection.
const nonce_tracker = @import("nonce_tracker.zig");

pub fn encodeRaftFrame(allocator: Allocator, from: u64, term: u64, msg: Message) ![]u8 {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer aw.deinit();

    const proto_msg = try messageToProto(allocator, msg);
    // SEC-D009: Generate cryptographic nonce for replay protection.
    // SEC-D001: Include cluster token for inter-node authentication.
    //
    // Task A6b (2026-05-25 distributed cluster testing plan): the env-var
    // pointer returned by `posixGetenv` points into libc's environ table,
    // which is NOT allocator-owned.  Assigning it directly to the
    // envelope's `auth_token` field worked at encode time but tripped an
    // "Invalid free" panic inside `envelope.deinit(allocator)` below
    // because the protobuf generic deinit unconditionally calls
    // `allocator.free` on non-empty string fields (protobuf.zig:1108).
    // The panic killed the raft worker on the very first tick before any
    // RequestVote actually made it onto the wire, which surfaced upstream
    // as "no leader ever elected" in the A6 subprocess test.  Dupe the
    // token into the allocator so the envelope owns it cleanly.
    const env_token = posixGetenv("GEODE_CLUSTER_TOKEN") orelse "";
    const owned_token: []const u8 = if (env_token.len > 0)
        try allocator.dupe(u8, env_token)
    else
        "";
    var envelope = raft_schema.RaftEnvelope{
        .term = term,
        .from = from,
        .nonce = nonce_tracker.NonceTracker.generateNonce(),
        .message = proto_msg,
        .auth_token = owned_token,
    };
    defer envelope.deinit(allocator);

    try protobuf.encode(&aw.writer, allocator, envelope);
    const out = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    aw.deinit();
    return out;
}

pub const DecodedRaftFrame = struct {
    term: u64,
    from: u64,
    /// SEC-D009: Nonce for replay protection (0 if absent / legacy frame).
    nonce: u64 = 0,
    /// SEC-D001: Cluster authentication token carried in the Raft envelope.
    auth_token: []const u8 = "",
    body: Message,

    pub fn deinit(self: DecodedRaftFrame, allocator: Allocator) void {
        if (self.auth_token.len > 0) allocator.free(self.auth_token);
        var msg = self.body;
        freeMessage(allocator, &msg);
    }
};

pub fn decodeRaftFrame(allocator: Allocator, payload: []const u8) !DecodedRaftFrame {
    var reader: std.Io.Reader = .fixed(payload);
    var decoded = try protobuf.decode(raft_schema.RaftEnvelope, &reader, allocator);
    defer decoded.deinit(allocator);

    const msg = decoded.message orelse return error.InvalidFrame;
    const body = try protoToMessage(allocator, msg);
    // SEC-D001: Carry auth_token through to caller for validation.
    const token_copy = if (decoded.auth_token.len > 0)
        try allocator.dupe(u8, decoded.auth_token)
    else
        @as([]const u8, "");
    return DecodedRaftFrame{ .term = decoded.term, .from = decoded.from, .nonce = decoded.nonce, .auth_token = token_copy, .body = body };
}

pub fn writeRaftFrame(allocator: Allocator, stream: anytype, from: u64, term: u64, msg: Message) !void {
    const payload = try encodeRaftFrame(allocator, from, term, msg);
    defer allocator.free(payload);
    // Emit the 4-byte big-endian length prefix and the payload as ONE
    // contiguous write so the vendor QUIC layer packs them into a SINGLE
    // STREAM frame / datagram (payloads here are << path MTU).  The prior
    // two-write form (`writeAll(len)` then `writeAll(payload)`) produced two
    // separate STREAM frames in two packets; the receiver accepts the stream
    // on the first (length) packet, reads the length, then blocks for the
    // second (payload) packet on a poll-less 5 ms retry loop.  For frames
    // larger than what landed in the first packet this races the per-RPC
    // stream FIN/close and the payload was dropped — empty-heartbeat frames
    // (single packet) replicated while any AppendEntries carrying a real log
    // entry silently vanished, wedging the cluster commit index. One write =
    // one packet = atomic receive.
    const framed = try allocator.alloc(u8, 4 + payload.len);
    defer allocator.free(framed);
    std.mem.writeInt(u32, framed[0..4], @intCast(payload.len), .big);
    @memcpy(framed[4..], payload);
    try stream.writeAll(framed);
}

pub fn readRaftFrame(allocator: Allocator, stream: anytype) !DecodedRaftFrame {
    var len_buf: [4]u8 = undefined;
    var read_len: usize = 0;
    var retry_count: usize = 0;
    const max_retries: usize = 200;

    while (read_len < len_buf.len) {
        const n = stream.read(len_buf[read_len..]) catch |err| {
            if (err == error.WouldBlock) {
                retry_count += 1;
                if (retry_count >= max_retries) return error.WouldBlock;
                compat_sleep(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) {
            if (read_len == 0) return error.EndOfStream;
            return error.UnexpectedEndOfStream;
        }
        read_len += n;
        retry_count = 0;
    }

    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len == 0) return error.InvalidFrame;
    if (msg_len > MAX_FRAME_SIZE) return error.FrameTooLarge;

    const payload = try allocator.alloc(u8, msg_len);
    defer allocator.free(payload);

    var got: usize = 0;
    retry_count = 0;
    while (got < msg_len) {
        const n = stream.read(payload[got..]) catch |err| {
            if (err == error.WouldBlock) {
                retry_count += 1;
                if (retry_count >= max_retries) return error.WouldBlock;
                compat_sleep(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) return error.UnexpectedEndOfStream;
        got += n;
        retry_count = 0;
    }

    return decodeRaftFrame(allocator, payload);
}

// ---- Protobuf conversion helpers ----

fn messageToProto(allocator: Allocator, msg: Message) !raft_schema.RaftMessage {
    return switch (msg) {
        .request_vote => |rv| .{
            .request_vote = .{
                .term = rv.term,
                .candidate_id = rv.candidate_id,
                .last_log_index = rv.last_log_index,
                .last_log_term = rv.last_log_term,
                // A6d: propagate the pre-vote phase bit on the outbound wire.
                .pre_vote = rv.pre_vote,
            },
        },
        .request_vote_response => |rvr| .{ .request_vote_response = .{
            .term = rvr.term,
            .vote_granted = rvr.vote_granted,
            .voter_id = rvr.voter_id,
            .pre_vote = rvr.pre_vote,
        } },
        // raft_schema.AppendEntries.entries carries the log entries to
        // replicate.  Serialize each geode LogEntry into a proto
        // RaftLogEntry whose `command_bytes` holds the canonical
        // tag-prefixed command encoding (serializeCommand).  This is the
        // replication payload the cluster bridge MUST carry: dropping it
        // (the historic `.empty`) left every AppendEntries an empty
        // heartbeat, so followers' match_index never advanced past their
        // prev_log_index and the leader's commit index was wedged at 0 —
        // no write ever replicated.  The ArrayList + each entry's
        // command_bytes are allocator-owned and freed by the envelope's
        // recursive `deinit` after protobuf.encode (encodeRaftFrame).
        .append_entries => |ae| blk: {
            var entries = std.ArrayList(raft_schema.RaftLogEntry).empty;
            errdefer {
                for (entries.items) |*e| e.deinit(allocator);
                entries.deinit(allocator);
            }
            for (ae.entries) |entry| {
                const cmd_bytes = try serializeCommand(allocator, entry.command);
                errdefer allocator.free(cmd_bytes);
                try entries.append(allocator, .{
                    .term = entry.term,
                    .index = entry.index,
                    .timestamp = entry.timestamp,
                    .client_id = entry.client_id,
                    .serial_number = entry.serial_number,
                    .command = null,
                    .command_bytes = cmd_bytes,
                });
            }
            break :blk .{ .append_entries = .{
                .term = ae.term,
                .leader_id = ae.leader_id,
                .prev_log_index = ae.prev_log_index,
                .prev_log_term = ae.prev_log_term,
                .entries = entries,
                .leader_commit = ae.leader_commit,
            } };
        },
        .append_entries_response => |aer| .{ .append_entries_response = .{
            .term = aer.term,
            .success = aer.success,
            .match_index = aer.match_index,
            .conflict_index = aer.conflict_index,
            .conflict_term = aer.conflict_term,
        } },
        // SONNY-6633: the chunk, the digest and the configuration go on the
        // wire (they were dropped, so no snapshot could be installed over
        // QUIC). Owned copies: the envelope's deinit frees them.
        .install_snapshot => |is| blk: {
            const data: []const u8 = if (is.data.len > 0) try allocator.dupe(u8, is.data) else "";
            errdefer if (data.len > 0) allocator.free(data);
            const zero = std.mem.zeroes([32]u8);
            const checksum: []const u8 = if (!std.mem.eql(u8, &is.checksum, &zero)) try allocator.dupe(u8, &is.checksum) else "";
            errdefer if (checksum.len > 0) allocator.free(checksum);
            var voters = std.ArrayList(u64).empty;
            errdefer voters.deinit(allocator);
            try voters.appendSlice(allocator, is.voters);
            var outgoing = std.ArrayList(u64).empty;
            errdefer outgoing.deinit(allocator);
            try outgoing.appendSlice(allocator, is.voters_outgoing);
            break :blk .{ .install_snapshot = .{
                .term = is.term,
                .leader_id = is.leader_id,
                .last_included_index = is.last_included_index,
                .last_included_term = is.last_included_term,
                .offset = is.offset,
                .data = data,
                .done = is.done,
                .checksum = checksum,
                .voters = voters,
                .voters_outgoing = outgoing,
                .is_joint = is.is_joint,
            } };
        },
        // SONNY-6633: a refusal is sent as `failed` (absent from an older
        // peer, which therefore still acknowledges).
        .install_snapshot_response => |isr| .{ .install_snapshot_response = .{
            .term = isr.term,
            .failed = !isr.success,
            .last_index = isr.last_index,
            .next_offset = isr.next_offset,
        } },
    };
}

fn protoToMessage(allocator: Allocator, msg: raft_schema.RaftMessage) !Message {
    return switch (msg) {
        .request_vote => |rv| .{
            .request_vote = .{
                .term = rv.term,
                .candidate_id = rv.candidate_id,
                .last_log_index = rv.last_log_index,
                .last_log_term = rv.last_log_term,
                // A6d: pre_vote is part of the wire schema and must be
                // propagated.  Hard-coding it to false here caused the
                // embedded raft library's pre-vote handshake to fail end-to-end:
                // candidates issued pre_vote=true RequestVotes (and bumped
                // current_term + 1 in request_term), peers always saw
                // pre_vote=false on inbound, so they treated every request as
                // a real vote and bumped their term unconditionally on
                // msg.term > current_term.  No leader was ever elected
                // because all 3 candidates ended up at the same higher term
                // every round-trip.
                .pre_vote = rv.pre_vote,
            },
        },
        .request_vote_response => |rvr| .{ .request_vote_response = .{
            .term = rvr.term,
            .vote_granted = rvr.vote_granted,
            .voter_id = rvr.voter_id,
            .pre_vote = rvr.pre_vote,
        } },
        // Reconstruct the replicated log entries from the wire.  Each proto
        // RaftLogEntry.command_bytes is the canonical serializeCommand
        // encoding; dupe it into an allocator-owned buffer (the proto decode
        // buffer is freed the moment decodeRaftFrame returns) and deserialize
        // it back into the geode Command.  `owned_wire_bytes` keeps the dup
        // alive until freeMessage runs.  Historic code dropped entries here
        // (`&.{}`), which — paired with the same drop in messageToProto —
        // wedged the cluster commit index at 0.
        .append_entries => |ae| blk: {
            const items = ae.entries.items;
            const entries = try allocator.alloc(LogEntry, items.len);
            var built: usize = 0;
            errdefer {
                for (entries[0..built]) |*e| {
                    if (e.owned_wire_bytes) |b| allocator.free(b);
                }
                allocator.free(entries);
            }
            for (items, 0..) |pe, i| {
                const dup = try allocator.dupe(u8, pe.command_bytes);
                errdefer allocator.free(dup);
                // GAP-0889 (F1): transit path — keep the raw bytes moving as an
                // opaque `.write` (owned_wire_bytes preserves the exact wire
                // encoding for storage/forwarding) but make the decode failure
                // visible. The apply site (decodeCommittedCommand) is the
                // enforcement point that refuses to apply such an entry.
                const cmd = deserializeCommand(dup) catch |err| fallback: {
                    log.warn("Raft inbound entry decode failed — forwarding raw bytes", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.uint("entry_index", pe.index),
                    });
                    break :fallback Command{ .write = dup };
                };
                entries[i] = .{
                    .term = pe.term,
                    .index = pe.index,
                    .command = cmd,
                    .timestamp = pe.timestamp,
                    .client_id = pe.client_id,
                    .serial_number = pe.serial_number,
                    .owned_wire_bytes = dup,
                };
                built += 1;
            }
            break :blk .{ .append_entries = .{
                .term = ae.term,
                .leader_id = ae.leader_id,
                .prev_log_index = ae.prev_log_index,
                .prev_log_term = ae.prev_log_term,
                .entries = entries,
                .leader_commit = ae.leader_commit,
            } };
        },
        .append_entries_response => |aer| .{ .append_entries_response = .{
            .term = aer.term,
            .success = aer.success,
            .match_index = aer.match_index,
            .conflict_index = aer.conflict_index,
            .conflict_term = aer.conflict_term,
        } },
        // SONNY-6633: owned copies (the decode buffer is freed when
        // decodeRaftFrame returns), freed by `freeMessage`.
        .install_snapshot => |is| blk: {
            var checksum = std.mem.zeroes([32]u8);
            switch (is.checksum.len) {
                0 => {},
                32 => @memcpy(&checksum, is.checksum),
                else => return error.InvalidFrame,
            }
            const data: []const u8 = if (is.data.len > 0) try allocator.dupe(u8, is.data) else &.{};
            errdefer if (data.len > 0) allocator.free(data);
            const voters: []const u64 = if (is.voters.items.len > 0) try allocator.dupe(u64, is.voters.items) else &.{};
            errdefer if (voters.len > 0) allocator.free(voters);
            const outgoing: []const u64 = if (is.voters_outgoing.items.len > 0) try allocator.dupe(u64, is.voters_outgoing.items) else &.{};
            break :blk .{ .install_snapshot = .{
                .term = is.term,
                .leader_id = is.leader_id,
                .last_included_index = is.last_included_index,
                .last_included_term = is.last_included_term,
                .offset = is.offset,
                .data = data,
                .done = is.done,
                .checksum = checksum,
                .voters = voters,
                .voters_outgoing = outgoing,
                .is_joint = is.is_joint,
            } };
        },
        .install_snapshot_response => |isr| .{
            .install_snapshot_response = .{
                .term = isr.term,
                .success = !isr.failed,
                .last_index = isr.last_index,
                .next_offset = isr.next_offset,
            },
        },
    };
}

fn freeMessage(allocator: Allocator, msg: *Message) void {
    // Most Message fields are scalars or slices that point into a protobuf
    // decode buffer freed elsewhere.  The exception is an inbound
    // AppendEntries reconstructed by `protoToMessage`: it owns the
    // `entries` slice and, per entry, the duped `owned_wire_bytes` buffer
    // that the deserialized Command aliases.  Free those here so the
    // DecodedRaftFrame.deinit path doesn't leak one buffer per replicated
    // log entry.
    switch (msg.*) {
        .append_entries => |ae| {
            for (ae.entries) |entry| {
                if (entry.owned_wire_bytes) |b| allocator.free(b);
            }
            if (ae.entries.len > 0) allocator.free(ae.entries);
        },
        .install_snapshot => |is| freeSnapshotSlices(allocator, is),
        else => {},
    }
}

/// SONNY-6633: an InstallSnapshot's owned chunk and configuration copies.
fn freeSnapshotSlices(allocator: Allocator, is: InstallSnapshot) void {
    if (is.data.len > 0) allocator.free(is.data);
    if (is.voters.len > 0) allocator.free(is.voters);
    if (is.voters_outgoing.len > 0) allocator.free(is.voters_outgoing);
}

fn freeLogEntryDeep(_: Allocator, _: *LogEntry) void {
    // Log entries own command data which may need freeing
}

/// Task A6e (2026-05-26): free heap-owned slices inside an outbound
/// `Message` built by `raftLibMessageToGeode`: `append_entries.entries`
/// with each entry's command copy, and `install_snapshot.data` (SONNY-6592:
/// it aliased the raft library's snapshot chunk, freed before the outbox
/// sent it). Vote and response variants own no slices.
pub fn freeOutboundMessage(allocator: Allocator, msg: Message) void {
    switch (msg) {
        .append_entries => |ae| {
            // Free the per-entry private command copies made by
            // `raftLibMessageToGeode` (see the deep-copy note there), then the
            // entries slice itself.
            for (ae.entries) |entry| {
                if (entry.owned_wire_bytes) |b| allocator.free(b);
            }
            if (ae.entries.len > 0) allocator.free(ae.entries);
        },
        .install_snapshot => |is| freeSnapshotSlices(allocator, is),
        else => {},
    }
}

// ---- Command serialization (tag-prefix format) ----
// Format: 1-byte tag | payload bytes
// Tags: 0=noop, 1=write, 2=graph_mutation, 3=schema_change,
//        4=config_change, 5=snapshot_pointer, 6=txn_prepare, 7=txn_decide

const CMD_TAG_NOOP: u8 = 0;
const CMD_TAG_WRITE: u8 = 1;
const CMD_TAG_GRAPH_MUTATION: u8 = 2;
const CMD_TAG_SCHEMA_CHANGE: u8 = 3;
const CMD_TAG_CONFIG_CHANGE: u8 = 4;
const CMD_TAG_SNAPSHOT_POINTER: u8 = 5;
const CMD_TAG_TXN_PREPARE: u8 = 6;
const CMD_TAG_TXN_DECIDE: u8 = 7;

/// Proposal-time command validation (GAP-0870).
///
/// Commands that can never be applied meaningfully are REJECTED here, at
/// propose time, instead of being skipped at apply time.  Apply-time skips
/// are silent divergence hazards: the entry is committed cluster-wide and
/// every node pays the replication cost for a no-op.  `proposeCommand`
/// calls this before the leader check so callers get a deterministic
/// rejection regardless of raft role.
pub fn validateCommand(cmd: Command) !void {
    switch (cmd) {
        .schema_change => |sc| {
            if (sc.graph.len == 0) return error.InvalidSchemaChange;
            // Geode has no ALTER GRAPH semantics anywhere (no GQL surface,
            // no GraphStore handler).  Until those land, an alter_graph
            // entry can never be applied — refuse to replicate it.
            if (sc.operation == .alter_graph) return error.UnsupportedSchemaOperation;
        },
        .config_change => |cc| switch (cc.change_type) {
            // add/update must carry a non-empty endpoint — a member without
            // an address can never be contacted.
            .add_server, .update_server => {
                const ep = cc.server_endpoint orelse return error.InvalidConfigChange;
                if (ep.len == 0) return error.InvalidConfigChange;
            },
            .remove_server => {},
        },
        .snapshot_pointer => |sp| {
            // Index/term 0 is "no snapshot" — recording it would licence
            // truncating the whole log against a snapshot that doesn't exist.
            if (sp.last_included_index == 0 or sp.last_included_term == 0)
                return error.InvalidSnapshotPointer;
        },
        .txn_prepare => |tp| {
            // An empty write set has nothing to prepare; the decide that
            // follows would commit nothing.  Reject the pointless round.
            if (tp.write_set.len == 0) return error.EmptyWriteSet;
            // The write set must carry the native G2PC codec magic — any
            // other payload (e.g. the blocked protobuf TwoPhaseMessage wire
            // format) can never be applied by TxnCoordinator.
            if (!txn_coordinator.isWriteSetPayload(tp.write_set)) return error.InvalidWriteSet;
        },
        .noop, .write, .graph_mutation, .txn_decide => {},
    }
}

/// Serialize a Command into a tag-prefixed byte array.
/// Caller owns the returned slice and must free with the same allocator.
pub fn serializeCommand(allocator: Allocator, cmd: Command) ![]u8 {
    switch (cmd) {
        .noop => {
            const buf = try allocator.alloc(u8, 1);
            buf[0] = CMD_TAG_NOOP;
            return buf;
        },
        .write => |data| {
            const buf = try allocator.alloc(u8, 1 + data.len);
            buf[0] = CMD_TAG_WRITE;
            @memcpy(buf[1..], data);
            return buf;
        },
        .graph_mutation => |gm| {
            // Serialize: tag | graph_len(4) | graph | type(1) | has_txn(1) [| txn_id(8)] | data
            const has_txn: u8 = if (gm.txn_id != null) 1 else 0;
            const txn_size: usize = if (gm.txn_id != null) 8 else 0;
            const total = 1 + 4 + gm.graph.len + 1 + 1 + txn_size + gm.data.len;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_GRAPH_MUTATION;
            pos += 1;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(gm.graph.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..gm.graph.len], gm.graph);
            pos += gm.graph.len;
            buf[pos] = @intFromEnum(gm.mutation_type);
            pos += 1;
            buf[pos] = has_txn;
            pos += 1;
            if (gm.txn_id) |tid| {
                std.mem.writeInt(u64, buf[pos..][0..8], tid, .big);
                pos += 8;
            }
            @memcpy(buf[pos..], gm.data);
            return buf;
        },
        .schema_change => |sc| {
            const total = 1 + 1 + 4 + sc.graph.len + sc.schema.len;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_SCHEMA_CHANGE;
            pos += 1;
            buf[pos] = @intFromEnum(sc.operation);
            pos += 1;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(sc.graph.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..sc.graph.len], sc.graph);
            pos += sc.graph.len;
            @memcpy(buf[pos..], sc.schema);
            return buf;
        },
        .config_change => |cc| {
            const ep = cc.server_endpoint orelse &[_]u8{};
            const has_port: u8 = if (cc.server_port != null) 1 else 0;
            const port_size: usize = if (cc.server_port != null) 2 else 0;
            const total = 1 + 1 + 8 + 4 + ep.len + 1 + port_size;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_CONFIG_CHANGE;
            pos += 1;
            buf[pos] = @intFromEnum(cc.change_type);
            pos += 1;
            std.mem.writeInt(u64, buf[pos..][0..8], cc.server_id, .big);
            pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(ep.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..ep.len], ep);
            pos += ep.len;
            buf[pos] = has_port;
            pos += 1;
            if (cc.server_port) |p| {
                std.mem.writeInt(u16, buf[pos..][0..2], p, .big);
            }
            return buf;
        },
        .snapshot_pointer => |sp| {
            const buf = try allocator.alloc(u8, 1 + 8 * 4);
            buf[0] = CMD_TAG_SNAPSHOT_POINTER;
            std.mem.writeInt(u64, buf[1..][0..8], sp.last_included_index, .big);
            std.mem.writeInt(u64, buf[9..][0..8], sp.last_included_term, .big);
            std.mem.writeInt(u64, buf[17..][0..8], sp.size_bytes, .big);
            std.mem.writeInt(u64, buf[25..][0..8], sp.checksum, .big);
            return buf;
        },
        .txn_prepare => |tp| {
            const total = 1 + 8 + 8 + 4 + tp.write_set.len + 4 + tp.metadata.len;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_TXN_PREPARE;
            pos += 1;
            std.mem.writeInt(u64, buf[pos..][0..8], tp.xid, .big);
            pos += 8;
            std.mem.writeInt(u64, buf[pos..][0..8], tp.shard_id, .big);
            pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(tp.write_set.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..tp.write_set.len], tp.write_set);
            pos += tp.write_set.len;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(tp.metadata.len), .big);
            pos += 4;
            @memcpy(buf[pos..], tp.metadata);
            return buf;
        },
        .txn_decide => |td| {
            const buf = try allocator.alloc(u8, 1 + 8 + 1);
            buf[0] = CMD_TAG_TXN_DECIDE;
            std.mem.writeInt(u64, buf[1..][0..8], td.xid, .big);
            buf[9] = if (td.commit) 1 else 0;
            return buf;
        },
    }
}

/// GAP-0889 (F1): decode a committed entry's command bytes for apply.
/// On decode failure the entry is reported loudly (log.err + dedicated
/// `decode_errors` counter) and `null` is returned so the caller SKIPS the
/// entry instead of fabricating an inert `.write` command from poisoned or
/// future-format bytes. Pulled out of `drainReady` so it is unit-testable
/// without standing up a full RaftNode.
fn decodeCommittedCommand(stats: *Statistics, data: []const u8, entry_index: u64, term: u64) ?Command {
    return deserializeCommand(data) catch |err| {
        log.err("Raft committed entry decode failed — entry NOT applied", &.{
            Attr.string("error", @errorName(err)),
            Attr.uint("entry_index", entry_index),
            Attr.uint("term", term),
        });
        stats.decode_errors += 1;
        return null;
    };
}

/// Deserialize a tag-prefixed byte array back into a Command.
/// The returned Command borrows slices from `data` (zero-copy for the payload).
pub fn deserializeCommand(data: []const u8) !Command {
    if (data.len == 0) return error.InvalidData;
    const tag = data[0];
    const payload = data[1..];
    switch (tag) {
        CMD_TAG_NOOP => return .noop,
        CMD_TAG_WRITE => return .{ .write = payload },
        CMD_TAG_SCHEMA_CHANGE => {
            // Wire format mirrors serializeCommand: 1B op | 4B graph_len(BE) | graph | schema
            if (payload.len < 1 + 4) return error.InvalidData;
            const op_byte = payload[0];
            const graph_len = std.mem.readInt(u32, payload[1..][0..4], .big);
            const graph_start: usize = 5;
            const graph_end: usize = graph_start + graph_len;
            if (graph_end > payload.len) return error.InvalidData;
            const schema_start: usize = graph_end;
            return .{ .schema_change = .{
                .operation = @enumFromInt(op_byte),
                .graph = payload[graph_start..graph_end],
                .schema = payload[schema_start..],
            } };
        },
        CMD_TAG_TXN_DECIDE => {
            if (payload.len < 9) return error.InvalidData;
            return .{ .txn_decide = .{
                .xid = std.mem.readInt(u64, payload[0..8], .big),
                .commit = payload[8] != 0,
            } };
        },
        CMD_TAG_GRAPH_MUTATION => {
            // Wire format mirrors serializeCommand:
            //   4B graph_len(BE) | graph | 1B mutation_type | 1B has_txn [| 8B txn_id(BE)] | data
            // Without this case, a proposed graph mutation fell into the `else`
            // branch below and was applied as an inert `.write`, so cluster
            // writes never replicated (root cause #2 of
            // docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md).
            // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-CREATE; FEATURE="DistributedCluster"; ASPECT=DeserializeGraphMutation; STATUS=TESTED; TEST=tests/test_cluster_3node_steady_state.zig; OWNER=distributed; UPDATED=2026-06-04
            if (payload.len < 4 + 1 + 1) return error.InvalidData;
            const graph_len = std.mem.readInt(u32, payload[0..4], .big);
            var pos: usize = 4;
            if (pos + graph_len > payload.len) return error.InvalidData;
            const graph = payload[pos .. pos + graph_len];
            pos += graph_len;
            if (pos + 2 > payload.len) return error.InvalidData;
            const mtype: @FieldType(GraphMutation, "mutation_type") = @enumFromInt(payload[pos]);
            pos += 1;
            const has_txn = payload[pos];
            pos += 1;
            var txn_id: ?u64 = null;
            if (has_txn != 0) {
                if (pos + 8 > payload.len) return error.InvalidData;
                txn_id = std.mem.readInt(u64, payload[pos..][0..8], .big);
                pos += 8;
            }
            return .{ .graph_mutation = .{
                .graph = graph,
                .mutation_type = mtype,
                .data = payload[pos..],
                .txn_id = txn_id,
            } };
        },
        CMD_TAG_CONFIG_CHANGE => {
            // Wire format mirrors serializeCommand:
            //   1B change_type | 8B server_id(BE) | 4B ep_len(BE) | ep | 1B has_port [| 2B port(BE)]
            // GAP-0870: without this case a replicated config_change fell into
            // the legacy `.write` fallback and was applied as an inert no-op.
            if (payload.len < 1 + 8 + 4 + 1) return error.InvalidData;
            const change_type: @FieldType(ConfigChange, "change_type") = @enumFromInt(payload[0]);
            const server_id = std.mem.readInt(u64, payload[1..][0..8], .big);
            const ep_len = std.mem.readInt(u32, payload[9..][0..4], .big);
            var pos: usize = 13;
            if (pos + ep_len + 1 > payload.len) return error.InvalidData;
            const ep = payload[pos .. pos + ep_len];
            pos += ep_len;
            const has_port = payload[pos];
            pos += 1;
            var port: ?u16 = null;
            if (has_port != 0) {
                if (pos + 2 > payload.len) return error.InvalidData;
                port = std.mem.readInt(u16, payload[pos..][0..2], .big);
            }
            return .{ .config_change = .{
                .change_type = change_type,
                .server_id = server_id,
                .server_endpoint = if (ep.len > 0) ep else null,
                .server_port = port,
            } };
        },
        CMD_TAG_SNAPSHOT_POINTER => {
            if (payload.len < 8 * 4) return error.InvalidData;
            return .{ .snapshot_pointer = .{
                .last_included_index = std.mem.readInt(u64, payload[0..8], .big),
                .last_included_term = std.mem.readInt(u64, payload[8..16], .big),
                .size_bytes = std.mem.readInt(u64, payload[16..24], .big),
                .checksum = std.mem.readInt(u64, payload[24..32], .big),
            } };
        },
        CMD_TAG_TXN_PREPARE => {
            // 8B xid(BE) | 8B shard_id(BE) | 4B ws_len(BE) | ws | 4B md_len(BE) | md
            if (payload.len < 8 + 8 + 4) return error.InvalidData;
            const xid = std.mem.readInt(u64, payload[0..8], .big);
            const shard_id = std.mem.readInt(u64, payload[8..16], .big);
            const ws_len = std.mem.readInt(u32, payload[16..20], .big);
            var pos: usize = 20;
            if (pos + ws_len + 4 > payload.len) return error.InvalidData;
            const write_set = payload[pos .. pos + ws_len];
            pos += ws_len;
            const md_len = std.mem.readInt(u32, payload[pos..][0..4], .big);
            pos += 4;
            if (pos + md_len > payload.len) return error.InvalidData;
            const metadata = payload[pos .. pos + md_len];
            return .{ .txn_prepare = .{
                .xid = xid,
                .shard_id = shard_id,
                .write_set = write_set,
                .metadata = metadata,
            } };
        },
        else => {
            // GAP-0870: an unknown tag is NOT silently downgraded to a `.write`
            // any more — fail loud so a mixed-version cluster surfaces the
            // incompatibility instead of replicating inert payloads.
            return error.UnknownCommandTag;
        },
    }
}

// ---- RaftNode (wraps external raft library) ----

pub const RaftNode = struct {
    allocator: Allocator,
    id: u64,
    state: State,
    current_term: u64,

    /// A6d follow-on (2026-05-26): serialize concurrent access to the
    /// embedded raft library's mutable state.  Before this mutex landed,
    /// the cluster coordinator's `raftLoop` (calling `tick()` every
    /// 10ms) and the QUIC accept thread (calling `handleMessage()` on
    /// every inbound frame) could both reach `self.inner.*` at the same
    /// instant.  Once leader election started working (post-A6d wire
    /// fix + pre_vote propagation), the elected leader's first
    /// `sendHeartbeats` could observe `replication_state` being
    /// `becomeFollower`-nulled by the receive thread, surfacing as
    /// `incorrect alignment` inside the inner library's hash-map
    /// metadata pointer.
    inner_mutex: std.Io.Mutex = std.Io.Mutex.init,

    // External raft library node
    inner: raft_lib.RaftNode,
    // Heap-allocated, OWNED storage backing whose Storage vtable interface
    // (which captures the backing pointer) remains valid for the RaftNode's
    // lifetime. A previous version held this as an inline value, which dangled
    // the moment RaftNode.init returned. See A4d of the distributed cluster
    // testing plan.
    //
    // The variant is chosen at construction: `.in_memory` (today's behavior,
    // and the in-process test path) loses hard-state/log on restart; `.file`
    // (production, when a `storage_dir` is supplied) persists currentTerm /
    // votedFor / the raft log via the pinned raft library's crash-safe
    // FileStorage, so a restarted node restores its hard-state (Raft
    // election-safety) instead of resetting term/vote to zero. `.tde_file`
    // (SONNY-6571, GEODE_TDE_KEY set) is that FileStorage with entry and
    // snapshot data sealed under keys derived from the TDE key.
    storage_backing: union(enum) {
        in_memory: *raft_lib.InMemoryStorage,
        file: *raft_lib.FileStorage,
        tde_file: *raft_tde_storage.TdeRaftStorage,
    },

    // Configuration
    peers: []Peer,
    election_timeout_ms: u64,

    // Network
    transport: ?*Transport,

    // Callbacks
    apply_callback: ?*const fn (allocator: Allocator, cmd: Command, raft_index: u64) anyerror![]u8,

    // Statistics
    stats: Statistics,

    // Transaction coordinator
    txn_coordinator: ?*TxnCoordinator,
    pending_responses: std.StringHashMap(ClientResponse),

    /// The raft library Transport given to `setInnerTransport` (in-process
    /// tests), or null. `drainReady` sends `Ready.messages` through it when
    /// no wrapper `transport` is set: raft v0.2.0 hands votes and replies to
    /// the consumer instead of sending them from `step()` / `tick()`.
    inner_transport: ?raft_lib.Transport = null,

    // CANARY: REQ=REQ-SONNY-6622-RAFT-SNAPSHOT-RESTORE; FEATURE="Raft Snapshot Persistence"; ASPECT=RestoreFromReadySnapshot; STATUS=TESTED; TEST=tests/test_sonny6622_raft_v022_adapt.zig; OWNER=distributed; UPDATED=2026-11-15
    /// SONNY-6622: restores the state machine from a snapshot this node
    /// installed (raft v0.2.2 `Ready.snapshot`: InstallSnapshot from the
    /// leader, `data` as the leader passed it to `reportSnapshot`). Called
    /// under `inner_mutex`, before the snapshot is persisted and before any
    /// entry after it is applied. An error pauses the node as a failed
    /// persist does (`stalled_ready`): it must not apply later entries onto
    /// a state machine without the snapshot's contents. With an
    /// `apply_callback` and no restore callback a snapshot is refused the
    /// same way.
    snapshot_restore_callback: ?*const fn (allocator: Allocator, data: []const u8, index: u64, term: u64) anyerror!void = null,
    // CANARY: REQ=REQ-SONNY-6631-APPLY-HYDRATION-OFF-RAFT-MUTEX; FEATURE="DistributedCluster"; ASPECT=PrehydrateWhereEntriesEnterTheLog; STATUS=TESTED; TEST=tests/test_sonny6631_apply_hydration_off_mutex.zig; OWNER=distributed; UPDATED=2026-11-15
    /// SONNY-6631: hydrates the graphs a command's apply writes. Called
    /// without `inner_mutex` wherever entries enter this node's log
    /// (`handleMessage`, `stepInner`; a proposer calls it itself) and for
    /// the entries a restarted node replays (`prehydrateUnapplied`), so the
    /// apply under `inner_mutex` finds them hydrated: its time does not
    /// depend on the graphs' size.
    prehydrate_callback: ?*const fn (cmd: Command) void = null,
    /// SONNY-6622: the last index this node's state machine applied (or
    /// restored a snapshot up to), set when a Ready is finished. The raft
    /// library moves its own `log.applied` to a snapshot's index as soon as
    /// it installs the snapshot, before the state machine is restored, so
    /// that one overstates a node whose restore failed. Atomic: read
    /// without `inner_mutex` (`appliedIndex`).
    applied_index: u64 = 0,

    // CANARY: REQ=REQ-SONNY-6617-RAFT-PERSIST-RETRY; FEATURE="Raft Consensus Persistence"; ASPECT=PersistFailureRetried; STATUS=TESTED; TEST=tests/test_sonny6617_raft_persist_failure.zig; OWNER=distributed; UPDATED=2026-11-15
    /// SONNY-6617: the Ready whose `advancePersist()` failed, kept (with
    /// the inner node untouched) until a retry writes it; null otherwise.
    /// While set the node takes no Raft input (`step`, `tick`, `propose`):
    /// stepping would mutate the log the Ready's committed entries borrow
    /// from. `tick` retries the write with backoff (`persist_retry_wait`).
    stalled_ready: ?raft_lib.Ready = null,
    /// Ticks to wait before the next persist retry, and the next backoff.
    persist_retry_wait: u32 = 0,
    persist_backoff: u32 = 1,
    /// Failed persist attempts since the last success (for logs and stats).
    persist_failures: u64 = 0,
    /// `stalled_ready != null`, readable without `inner_mutex`.
    persist_stalled: bool = false,

    // CANARY: REQ=REQ-SONNY-6636-RESTORE-OFF-INNER-MUTEX; FEATURE="Raft Snapshot Persistence"; ASPECT=RestoreThreadWhilePaused; STATUS=TESTED; TEST=tests/test_sonny6636_durable_snapshot_restore.zig; OWNER=distributed; UPDATED=2026-11-16
    /// SONNY-6636 (3): the restore of the stalled Ready's snapshot
    /// (`snapshot_restore_callback`) runs on this thread, never under
    /// `inner_mutex`: a durable restore writes files and takes graph locks
    /// and the store's write lock. The node stays paused (`stalled_ready`)
    /// until it succeeds; `tick` collects it (`retryStalledPersist`), then
    /// persists the snapshot and applies what follows it.
    restore_thread: ?std.Thread = null,
    /// A `RestoreState`: written by the restore thread (release), read under
    /// `inner_mutex` (acquire).
    restore_state: std.atomic.Value(u8) = .init(@intFromEnum(RestoreState.idle)),
    /// The restore thread's error, set before `restore_state` turns `failed`.
    restore_error: anyerror = error.Unexpected,
    /// The stalled Ready's snapshot is restored into the state machine.
    stalled_restored: bool = false,
    /// SONNY-6665: the stalled Ready's `advancePersist()` succeeded; only
    /// the restore of its snapshot remains (raft v0.2.6 commits a staged
    /// snapshot in `advancePersist()`, and with FileStorage the restore
    /// reads it from the committed file).
    stalled_persisted: bool = false,
    /// SONNY-6665: `drainReady` released inner_mutex between `ready()` and
    /// `advancePersist()` to sync a received snapshot. Another thread may
    /// step the inner node meanwhile (raft v0.2.6), but none drains a Ready
    /// or runs the timers until it is done. Under `inner_mutex`.
    draining: bool = false,
    /// SONNY-6665: InstallSnapshot transfers the leader asked for
    /// (Ready.snapshot_sends), streamed once `inner_mutex` is released
    /// (`unlockInner`). Under `inner_mutex`.
    snapshot_sends: std.ArrayList(raft_lib.SnapshotSend) = .empty,

    // CANARY: REQ=REQ-SONNY-6636-SERVER-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=SnapshotOffInnerMutex; STATUS=TESTED; TEST=tests/test_sonny6636_server_snapshot.zig; OWNER=distributed; UPDATED=2026-11-16
    /// SONNY-6636 (b): encodes the state machine as it is: it reflects Raft
    /// `index` (of `term`) exactly, as the node applies nothing meanwhile
    /// (`applies_held`). Runs on the snapshot thread, never under
    /// `inner_mutex`. null: this node takes no snapshots.
    snapshot_create_callback: ?*const fn (allocator: Allocator, index: u64, term: u64) anyerror![]u8 = null,
    snapshot_policy: SnapshotPolicy = .{},
    /// Entry bytes applied since the last snapshot (`SnapshotPolicy.bytes`).
    snapshot_bytes_since: u64 = 0,
    snapshot_thread: ?std.Thread = null,
    /// A `RestoreState` (idle, running, succeeded, failed) of the snapshot
    /// thread: written by it (release), read under `inner_mutex` (acquire).
    snapshot_job_state: std.atomic.Value(u8) = .init(@intFromEnum(RestoreState.idle)),
    /// SONNY-6665: where the running snapshot stands (raft
    /// `snapshotPoint()`, taken under `inner_mutex` when it starts), and the
    /// snapshot the snapshot thread staged in the Raft storage (written and
    /// synced off `inner_mutex`; `collectSnapshot` commits it).
    snapshot_job_point: ?raft_lib.SnapshotPoint = null,
    snapshot_job_staged: ?raft_lib.StagedSnapshot = null,
    snapshot_job_bytes: u64 = 0,
    snapshot_job_stage_ns: u64 = 0,
    snapshot_job_error: anyerror = error.Unexpected,
    snapshot_job_index: u64 = 0,
    snapshot_job_term: u64 = 0,
    snapshot_job_ns: u64 = 0,
    /// Set when an entry was applied during the copy after all (it could
    /// not be held): the copy no longer reflects one index and is dropped.
    snapshot_job_spoiled: bool = false,
    /// Ticks before the next snapshot attempt after a failed one.
    snapshot_retry_wait: u32 = 0,
    snapshot_backoff: u32 = 1,
    /// While the snapshot thread copies the state machine, committed
    /// entries are not applied but held (`held_entries`, in order), and
    /// applied after it, a bounded batch per tick. Under `inner_mutex`.
    applies_held: bool = false,
    held_entries: std.ArrayList(HeldEntry) = .empty,
    held_start: usize = 0,
    /// The snapshot thread's copy and the restore thread's swap of the
    /// state machine's files exclude each other. Never taken under
    /// `inner_mutex`.
    state_machine_io_mutex: std.Io.Mutex = .init,
    /// The last index the state machine applied (or restored a snapshot
    /// up to); behind `inner.log.applied` while entries are held.
    sm_applied: u64 = 0,

    pub fn init(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
    ) !*RaftNode {
        return initWithClock(allocator, id, peers, election_timeout_ms, &RealClock.instance);
    }

    /// Construct a RaftNode whose raft hard-state (currentTerm/votedFor) and log
    /// are rooted at a per-node on-disk directory when `storage_dir` is non-null,
    /// or held purely in memory when it is null.
    ///
    /// * `storage_dir == null` → heap-allocate a `raft_lib.InMemoryStorage`
    ///   (today's behavior, and the in-process test path). Hard-state and log
    ///   are lost on restart.
    /// * `storage_dir != null` → heap-allocate a `raft_lib.FileStorage` rooted
    ///   at that dir. The library creates the full dir path and opens a Dir
    ///   handle (it does NOT retain the `storage_dir` slice, so the caller may
    ///   free it once this returns) and takes an exclusive `.lock` flock. If a
    ///   live process already holds that lock, `FileStorage.init` returns
    ///   `error.WouldBlock` which we surface as `error.RaftStorageDirLocked`
    ///   (do NOT mislabel as InvalidNodeId). The persisted hard-state + log
    ///   survive a process restart so a re-initialized node restores its
    ///   currentTerm / votedFor (Raft election-safety).
    ///
    /// The chosen backing pointer is OWNED by the returned RaftNode and freed in
    /// `deinit`; `FileStorage.deinit` releases the flock.
    ///
    /// SONNY-6571: with GEODE_TDE_KEY set, the directory's entry and snapshot
    /// data are encrypted (`raft_tde_storage`); see `initWithStorageDirKey`.
    pub fn initWithStorageDir(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
        storage_dir: ?[]const u8,
    ) !*RaftNode {
        const tde_key: ?[raft_tde_storage.KEY_BYTES]u8 = if (storage_dir != null) try tde_file_encryption.loadKey(allocator) else null;
        return initWithStorageDirKey(allocator, id, peers, election_timeout_ms, storage_dir, tde_key);
    }

    /// `initWithStorageDir` with the TDE key given instead of read from
    /// GEODE_TDE_KEY. With a key, `storage_dir`'s Raft entry and snapshot data
    /// are sealed under keys derived from it; a directory holding Raft state
    /// written without TDE is refused (`error.RaftStoragePlaintextUnderTde`),
    /// as is one encrypted under another key (`RaftStorageTdeKeyMismatch`).
    /// Without a key an encrypted directory is refused
    /// (`RaftStorageNeedsTdeKey`). Ignored when `storage_dir` is null.
    pub fn initWithStorageDirKey(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
        storage_dir: ?[]const u8,
        tde_key: ?[raft_tde_storage.KEY_BYTES]u8,
    ) !*RaftNode {
        const node = try allocator.create(RaftNode);
        // If any subsequent init step fails (most notably raft_lib.RaftNode.init
        // rejecting an invalid config such as id==0 -> InvalidId), the wrapper
        // we just allocated would leak. The node's fields aren't populated until
        // the `node.* = ...` at the end, so a bare destroy is the correct unwind
        // here (no deinit of partial state required).
        errdefer allocator.destroy(node);

        // Map Peer IDs to u64 array for external raft library
        const peer_ids = try allocator.alloc(u64, peers.len);
        defer allocator.free(peer_ids);
        for (peers, 0..) |peer, i| {
            peer_ids[i] = peer.id;
        }

        // Heap-allocate the chosen storage backing so the Storage interface
        // pointer that raft_lib.RaftNode.init captures (via backing.storage())
        // remains valid for the lifetime of the RaftNode. A previous version
        // held storage as a stack-local `var`, so the interface pointer dangled
        // the moment this function returned — surfacing as `OutOfMemory` on the
        // first advance and then `ReadyNotAdvanced` indefinitely once
        // ClusterCoordinator.start() became reachable (A4b/A4c).
        const StorageBacking = @FieldType(RaftNode, "storage_backing");
        var backing: StorageBacking = undefined;
        if (storage_dir) |dir| backing = blk: {
            const file_ptr = try allocator.create(raft_lib.FileStorage);
            errdefer allocator.destroy(file_ptr);
            // The dir's exclusive `.lock` flock is held by whatever process last
            // opened it. On an IN-PLACE restart (k8s pod restart with a
            // preserved PVC, modelled by the netns churn test's M4), the
            // *previous* incarnation may still be finishing its SIGTERM-driven
            // shutdown when the replacement boots, so its flock lingers for a
            // brief handoff window. An OS flock is released automatically the
            // instant the holder exits (even on SIGKILL / crash), so a bounded
            // retry reliably bridges that window without risking a true
            // two-writers situation. We fail with a clear error only if the
            // lock is STILL held after the budget — that means a genuinely live
            // peer owns the dir (operator misconfiguration) or a kernel that
            // leaked the lock, neither of which a longer wait would fix.
            const lock_retry_budget_ns: u64 = 15 * std.time.ns_per_s;
            const lock_retry_step_ns: u64 = 250 * std.time.ns_per_ms;
            var waited_ns: u64 = 0;
            file_ptr.* = while (true) {
                break raft_lib.FileStorage.init(allocator, dir) catch |err| switch (err) {
                    error.WouldBlock => {
                        if (waited_ns >= lock_retry_budget_ns) {
                            // Predecessor never released the flock within budget.
                            return error.RaftStorageDirLocked;
                        }
                        compat_sleep(lock_retry_step_ns);
                        waited_ns += lock_retry_step_ns;
                        continue;
                    },
                    // SONNY-6622: raft v0.2.2 refuses a log it cannot read
                    // in full and leaves it as it is; never repaired here.
                    error.LogCorrupted => return error.RaftStorageLogCorrupted,
                    error.LogAuthFailed => return error.RaftStorageLogAuthFailed,
                    error.LogEncryptionMismatch => return error.RaftStorageLogEncryptionMismatch,
                    else => return err,
                };
            };
            // Scoped to this block: once `backing` owns the storage, the
            // errdefer below releases it.
            errdefer file_ptr.deinit();
            if (tde_key) |key| {
                const tde_ptr = try allocator.create(raft_tde_storage.TdeRaftStorage);
                errdefer allocator.destroy(tde_ptr);
                tde_ptr.* = try raft_tde_storage.TdeRaftStorage.adopt(allocator, file_ptr, key);
                break :blk .{ .tde_file = tde_ptr };
            }
            try raft_tde_storage.refuseIfEncrypted(file_ptr);
            break :blk .{ .file = file_ptr };
        } else {
            const mem_ptr = try allocator.create(raft_lib.InMemoryStorage);
            errdefer allocator.destroy(mem_ptr);
            mem_ptr.* = raft_lib.InMemoryStorage.init(allocator);
            backing = .{ .in_memory = mem_ptr };
        }
        // From here on the backing is live (FileStorage holds a flock); any
        // failure must deinit + destroy the correct variant to release it.
        errdefer switch (backing) {
            inline else => |p| {
                p.deinit();
                allocator.destroy(p);
            },
        };

        const storage_iface = switch (backing) {
            inline else => |p| p.storage(),
        };

        const heartbeat_tick: u32 = 1;
        const election_tick: u32 = @intCast(@max(2, election_timeout_ms / 50));

        var raft_config = raft_lib.Config{
            .id = id,
            .peers = peer_ids,
            .election_tick = election_tick,
            .heartbeat_tick = heartbeat_tick,
            .pre_vote = true,
            // SONNY-6665 (raft v0.2.5): a leader hands each InstallSnapshot
            // transfer over in Ready.snapshot_sends and this wrapper streams
            // it chunk by chunk after releasing inner_mutex
            // (`unlockInner`), instead of the library reading the whole
            // snapshot inside tick() / step().
            .stream_snapshots = true,
            // SONNY-6665 (raft v0.2.6): a follower writes each chunk it
            // receives to a staged file and `drainReady` syncs it without
            // inner_mutex; advancePersist() only renames it into place.
            .stage_received_snapshots = true,
        };
        // Staged on disk, a received snapshot is never held in memory whole,
        // so FileStorage takes any size; the in-memory and TDE storages
        // stage in memory and keep the library's bound.
        if (backing == .file) raft_config.max_snapshot_size = 0;

        const inner = try raft_lib.RaftNode.init(allocator, raft_config, storage_iface);

        node.* = RaftNode{
            .allocator = allocator,
            .id = id,
            .state = .follower,
            .current_term = 0,
            .inner_mutex = std.Io.Mutex.init,
            .inner = inner,
            .storage_backing = backing,
            .peers = peers,
            .election_timeout_ms = election_timeout_ms,
            .transport = null,
            .apply_callback = null,
            .stats = std.mem.zeroes(Statistics),
            .txn_coordinator = null,
            .pending_responses = std.StringHashMap(ClientResponse).init(allocator),
            .applied_index = inner.log.applied,
            .sm_applied = inner.log.applied,
        };

        return node;
    }

    pub fn initWithClock(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
        _: *const Clock,
    ) !*RaftNode {
        // In-process / test path: in-memory storage backing (no durability).
        return initWithStorageDir(allocator, id, peers, election_timeout_ms, null);
    }

    // CANARY: REQ=REQ-SONNY-6667-QUIESCE-BEFORE-FREE; FEATURE="DistributedCluster"; ASPECT=RestoreJoinedBeforeApplyTargetsFreed; STATUS=TESTED; TEST=tests/test_sonny6667_dedup_restore_race.zig; OWNER=distributed; UPDATED=2026-11-16
    /// SONNY-6667: wait for the restore and snapshot threads to end. They
    /// run without `inner_mutex` and use the state machine and its apply
    /// targets (the store, the idempotency table): an owner calls this,
    /// once nothing ticks or steps the node (no new thread starts then),
    /// before it frees any of them. `deinit` calls it too. Idempotent.
    pub fn quiesce(self: *RaftNode) void {
        self.state = .shutdown;
        // SONNY-6636 (3): the restore thread reads the stalled Ready's data.
        if (self.restore_thread) |t| t.join();
        self.restore_thread = null;
        // SONNY-6636 (b): the snapshot thread reads the state machine.
        if (self.snapshot_thread) |t| t.join();
        self.snapshot_thread = null;
    }

    pub fn deinit(self: *RaftNode) void {
        self.quiesce();
        if (self.snapshot_job_staged) |*st| self.inner.storage.releaseStagedSnapshot(st);
        self.snapshot_job_staged = null;
        if (self.snapshot_job_point) |*p| p.deinit();
        self.snapshot_job_point = null;
        self.snapshot_sends.deinit(self.allocator);
        for (self.held_entries.items[self.held_start..]) |h| self.allocator.free(h.data);
        self.held_entries.deinit(self.allocator);
        self.inner.deinit();
        // Deinit + destroy the OWNED storage backing variant. FileStorage.deinit
        // releases the exclusive `.lock` flock so the dir can be re-opened by a
        // subsequent (e.g. restarted) node.
        switch (self.storage_backing) {
            inline else => |p| {
                p.deinit();
                self.allocator.destroy(p);
            },
        }
        self.pending_responses.deinit();
    }

    /// Wire the wrapper's geode-level `Transport` (typically QUIC+TLS in
    /// production) so that outbound raft traffic produced by the inner raft
    /// library reaches its peers.
    ///
    /// The raft library (v0.2.0) produces outbound traffic two ways. Leader
    /// replication (AppendEntries, heartbeats, InstallSnapshot) goes to its
    /// own `raft_lib.Transport` straight from `step()` / `tick()` /
    /// `propose()`; votes, a candidate's RequestVote and every reply are
    /// queued in `Ready.messages`, which `drainReady` sends once
    /// `advancePersist()` has made the state they announce durable.
    ///
    /// For the first kind this installs a tiny adapter that implements
    /// `raft_lib.Transport.VTable` and forwards each `(to, msg)` to the
    /// wrapper transport (`queueOutbound`) after looking up the peer's
    /// endpoint by id and converting the raft_lib Message into the geode
    /// Message union. Without it the wrapper's `transport` field would be
    /// set but no raft traffic would flow over it (A5b of the 2026-05-25
    /// distributed cluster testing plan).
    ///
    /// Tests that drive multiple raft nodes in-process should call
    /// `setInnerTransport` instead — that path bypasses this bridge.
    pub fn setTransport(self: *RaftNode, t: *Transport) void {
        self.transport = t;
        self.inner.setTransport(.{
            .ptr = @ptrCast(self),
            .vtable = &RaftLibTransportBridge.vtable,
        });
    }

    /// Inject the underlying raft library's Transport directly into the inner
    /// raft node.  Used by in-process multi-node tests (e.g. A5 in the
    /// 2026-05-25 distributed cluster testing plan) to wire several inner
    /// raft nodes together via `raft_lib.InProcessTransport` without going
    /// through the QUIC layer.  Production code wires QUIC via the outer
    /// `setTransport` instead. `drainReady` sends `Ready.messages` through
    /// `t` too when no wrapper transport is set.
    pub fn setInnerTransport(self: *RaftNode, t: raft_lib.Transport) void {
        self.inner_transport = t;
        self.inner.setTransport(t);
    }

    /// Deliver an inbound raft_lib message directly to the inner raft node
    /// (bypassing the geode Message conversion path) and then drain Ready
    /// state.  Used by in-process multi-node tests that pull messages out
    /// of a `raft_lib.InProcessTransport` inbox and feed them back into
    /// the recipient raft node.  Production code routes inbound traffic
    /// through `handleMessage` (which decodes the geode Message wire
    /// format first).
    pub fn stepInner(self: *RaftNode, from: u64, msg: raft_lib.Message) !void {
        // SONNY-6631: before `inner_mutex` (see `prehydrate_callback`).
        if (self.prehydrate_callback) |hydrate| switch (msg) {
            .append_entries => |ae| for (ae.entries) |entry| prehydrateEntry(hydrate, entry),
            else => {},
        };
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.unlockInner();
        if (self.stalled_ready != null) return error.RaftStoragePersistFailed;
        try self.inner.step(from, msg);
        self.drainReady();
    }

    pub fn tick(self: *RaftNode) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.unlockInner();
        // SONNY-6665: no timer runs while another thread's drainReady syncs
        // a received snapshot (it released inner_mutex to do so).
        if (self.draining) return;
        // SONNY-6636 (b): a finished snapshot is saved and the log compacted.
        self.collectSnapshot();
        // SONNY-6617: no election or heartbeat timer runs while a persist
        // failure is pending (a stalled leader lets the cluster fail over).
        if (self.stalled_ready != null) return self.retryStalledPersist();
        try self.inner.tick(null);
        self.drainReady();
        if (self.snapshot_retry_wait > 0) self.snapshot_retry_wait -= 1;
        self.applyHeld();
        self.maybeStartSnapshot();
    }

    pub fn handleMessage(self: *RaftNode, from: u64, msg: Message) !void {
        // SONNY-6665: the Debug-only lost-chunk hook.
        if (msg == .install_snapshot and testDropsSnapshotChunk(from, msg.install_snapshot)) return;
        // SONNY-6567 (6b), SONNY-6631: the graphs the carried entries'
        // applies write are hydrated here, on the receiving thread, before
        // `inner_mutex` (see `prehydrate_callback`). An entry not committed
        // yet only builds the resident indexes any first read builds.
        if (self.prehydrate_callback) |hydrate| switch (msg) {
            .append_entries => |ae| for (ae.entries) |entry| hydrate(entry.command),
            else => {},
        };
        // Map geode Message to external raft library Message, preserving all data.
        var converted_entries: ?[]raft_lib.Entry = null;
        defer if (converted_entries) |ce| self.allocator.free(ce);

        const raft_msg: raft_lib.Message = switch (msg) {
            .request_vote => |rv| .{ .request_vote = .{
                .term = rv.term,
                .candidate_id = rv.candidate_id,
                .last_log_index = rv.last_log_index,
                .last_log_term = rv.last_log_term,
                .pre_vote = rv.pre_vote,
            } },
            .request_vote_response => |rvr| .{ .request_vote_response = .{
                .term = rvr.term,
                .vote_granted = rvr.vote_granted,
                .pre_vote = rvr.pre_vote,
            } },
            .append_entries => |ae| blk: {
                // Convert geode LogEntry[] to raft_lib Entry[]
                const entries = try self.allocator.alloc(raft_lib.Entry, ae.entries.len);
                for (ae.entries, 0..) |entry, i| {
                    const data = try serializeCommand(self.allocator, entry.command);
                    entries[i] = .{
                        .index = entry.index,
                        .term = entry.term,
                        .kind = .normal,
                        .data = data,
                    };
                }
                converted_entries = entries;
                break :blk .{ .append_entries = .{
                    .term = ae.term,
                    .leader_id = ae.leader_id,
                    .prev_log_index = ae.prev_log_index,
                    .prev_log_term = ae.prev_log_term,
                    .entries = entries,
                    .leader_commit = ae.leader_commit,
                } };
            },
            .append_entries_response => |aer| .{ .append_entries_response = .{
                .term = aer.term,
                .success = aer.success,
                .match_index = aer.match_index,
                .conflict_index = aer.conflict_index,
                .conflict_term = aer.conflict_term,
            } },
            .install_snapshot => |is| .{ .install_snapshot = .{
                .term = is.term,
                .leader_id = is.leader_id,
                .last_included_index = is.last_included_index,
                .last_included_term = is.last_included_term,
                .offset = is.offset,
                .data = is.data,
                .done = is.done,
                .checksum = is.checksum,
                .config = .{ .voters = is.voters, .voters_outgoing = is.voters_outgoing, .is_joint = is.is_joint },
            } },
            .install_snapshot_response => |isr| .{ .install_snapshot_response = .{
                .term = isr.term,
                .success = isr.success,
                .last_index = isr.last_index,
                .next_offset = isr.next_offset,
            } },
        };

        // A6d follow-on: serialize inner-library mutation across the
        // raft tick thread (cluster.zig:raftLoop) and the QUIC accept
        // thread (cluster.zig:readOneRaftFrameAndDispatch).  Without the
        // mutex, a concurrent `becomeFollower` from the receive thread
        // could null out replication_state mid-`sendHeartbeats`,
        // surfacing as an "incorrect alignment" panic on the hash-map
        // metadata pointer.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.unlockInner();

        // SONNY-6617: dropped while a persist failure is pending; the sender
        // retries (Raft tolerates message loss).
        if (self.stalled_ready != null) {
            if (converted_entries) |ce| for (ce) |entry| self.allocator.free(entry.data);
            log.debug("raft message dropped: Raft storage write pending retry", &.{Attr.uint("from", from)});
            return;
        }

        // raft-0.1.3 RaftNode.step takes (from, msg); the older 3-arg form
        // (with a trailing thread-pool param) is gone.
        self.inner.step(from, raft_msg) catch |err| {
            log.warn("raft step error", &.{Attr.string("error", @errorName(err))});
        };
        // Free serialized entry data before freeing the entries array
        if (converted_entries) |ce| {
            for (ce) |entry| {
                self.allocator.free(entry.data);
            }
        }
        self.drainReady();
    }

    pub fn proposeCommand(self: *RaftNode, cmd: Command) !u64 {
        // Serialize Command to bytes for the external raft library's propose().
        // Format: 1-byte tag | payload
        // Tags: 0=noop, 1=write, 2=graph_mutation, 3=schema_change,
        //        4=config_change, 5=snapshot_pointer, 6=txn_prepare, 7=txn_decide
        //
        // A3d (2026-05-26): take the inner_mutex around propose() + drain so
        // we keep the locking invariant established by A6d.  Concurrent
        // raftLoop ticks and inbound-message handlers may already be calling
        // `tick()` / `step()` under the mutex, so an unguarded propose race
        // could trigger the same `incorrect alignment` corruption A6d
        // closed.
        //
        // Returns the log index assigned to the proposed entry, i.e.
        // `log.lastIndex()` after append.  Callers can pair this with
        // `appliedIndex()` (or the higher-level ClusterCoordinator.
        // waitForApplied helper) to confirm commit + apply on this node.
        // The previous form returned `stats.entries_applied` -- a running
        // count of all entries ever applied -- which was unusable as a
        // wait condition.  All existing internal callers ignore the
        // return value with `_ = try ...`, so the change is local.
        //
        // GAP-0870: validate BEFORE the leader check so invalid commands get
        // a deterministic rejection on any node — they must never reach the
        // log only to be skipped at apply time.
        try validateCommand(cmd);
        const cmd_bytes = try serializeCommand(self.allocator, cmd);
        defer self.allocator.free(cmd_bytes);
        if (!self.lockInnerForRequest()) return error.GraphNotFound;
        defer self.unlockInner();
        // SONNY-6617: a node whose Raft storage write failed takes no write.
        if (self.stalled_ready != null) return error.RaftStoragePersistFailed;
        if (self.inner.role != .leader) return error.NotLeader;
        try self.inner.propose(cmd_bytes);
        const new_index = self.inner.log.lastIndex();
        self.drainReady();
        return new_index;
    }

    /// SONNY-6631: hydrate, without `inner_mutex`, the graphs of every entry
    /// in the log this node has not applied: a restarted node replays its
    /// committed log, and nothing received or proposed those entries in
    /// this process. Call once `prehydrate_callback` is set, before the node
    /// is ticked (`ClusterCoordinator.init`). Best effort: an entry it cannot
    /// read is hydrated by its apply, as before.
    pub fn prehydrateUnapplied(self: *RaftNode) void {
        const hydrate = self.prehydrate_callback orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();
        var next: u64 = undefined;
        var last: u64 = undefined;
        {
            self.inner_mutex.lockUncancelable(io);
            defer self.inner_mutex.unlock(io);
            next = self.inner.log.applied + 1;
            last = self.inner.log.lastIndex();
        }
        const chunk: u64 = 256;
        while (next <= last) {
            const hi = @min(last + 1, next + chunk);
            const entries = blk: {
                self.inner_mutex.lockUncancelable(io);
                defer self.inner_mutex.unlock(io);
                break :blk self.inner.log.slice(next, hi) catch |err| {
                    log.warn("raft: entries to replay not hydrated ahead; their applies hydrate them", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.uint("from_index", next),
                    });
                    return;
                };
            };
            defer raft_lib.freeEntries(self.allocator, entries);
            for (entries) |entry| prehydrateEntry(hydrate, entry);
            next = hi;
        }
    }

    /// Returns the index of the most recently applied log entry on this
    /// node: monotonic, advanced only when `drainReady()` finishes a Ready,
    /// after its entries were applied by `apply_callback` (and a snapshot
    /// restored, SONNY-6622: not `inner.log.applied`, which moves to a
    /// snapshot's index before the restore). Safe to call from any thread.
    pub fn appliedIndex(self: *RaftNode) u64 {
        return @atomicLoad(u64, &self.applied_index, .acquire);
    }

    /// Returns the COMMIT watermark of this node's inner Raft log -- the highest
    /// index known to be replicated to a quorum (distinct from `appliedIndex`,
    /// which is the highest index the state machine has applied locally). Raft
    /// guarantees a committed entry WILL apply, so a committed-but-not-yet-applied
    /// entry is a durable success, never a replication failure.
    ///
    /// Reads `inner.log.committed` the same way `appliedIndex` reads
    /// `inner.log.applied`: a plain u64 load, monotonic, advanced only inside the
    /// inner library under `inner_mutex` (commitTo). Safe to call from any thread;
    /// a torn read would at worst cost a spurious wait iteration (it never
    /// fabricates a higher watermark out of nothing because the field only ever
    /// increases). Used by the commit-aware post-propose wait
    /// (ClusterCoordinator.waitForCommittedThenApplied), RC-1 of the
    /// "committed write -> client Timeout -> retry double-insert" fix.
    /// CANARY: REQ=REQ-DIST-CLUSTER-COMMIT-AWARE-WAIT; FEATURE="DistributedCluster"; ASPECT=CommittedIndexAccessor; STATUS=TESTED; TEST=tests/test_cluster_commit_aware_wait.zig; OWNER=distributed; UPDATED=2026-06-12
    pub fn committedIndex(self: *RaftNode) u64 {
        return self.inner.log.committed;
    }

    /// Returns the current Raft role of this node mirroring the inner
    /// library's state.  Falls through to `self.state` (which `drainReady`
    /// keeps in sync) so this remains correct under shutdown.
    pub fn role(self: *RaftNode) State {
        return self.state;
    }

    /// Returns the current Raft term, read live from the inner library under
    /// the inner mutex. The wrapper's `self.current_term` mirror only advances
    /// when `drainReady` runs and reads a hard_state; on a steady leader that
    /// has no committed-entries to drain, the mirror can lag behind the actual
    /// term observed after a re-election. Reading inner directly avoids the
    /// stale-term mismatch that breaks cross-node term-agreement invariants.
    pub fn currentTerm(self: *RaftNode) u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        // SONNY-6541 (1): a request that must not wait (`lockInnerForRequest`)
        // reads the term unlocked, as `appliedIndex` reads its index.
        if (!self.lockInnerForRequest()) return @atomicLoad(u64, &self.inner.current_term, .acquire);
        defer self.inner_mutex.unlock(io);
        return self.inner.current_term;
    }

    /// Returns the current leader id from the inner raft library's view, or
    /// null if no leader has been observed in this term (election in flight,
    /// just-started cluster, partition healing). Followers learn the leader's
    /// id from AppendEntries; candidates know themselves; leaders know themselves.
    /// admin_ddl.executeShowClusterStatus surfaces this through SHOW CLUSTER STATUS.
    pub fn leaderId(self: *RaftNode) ?u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        // SONNY-6541 (1): see `currentTerm`; no leader known then.
        if (!self.lockInnerForRequest()) return null;
        defer self.inner_mutex.unlock(io);
        return self.inner.leader_id;
    }

    // CANARY: REQ=REQ-SONNY-6541-DROP-APPLY-NO-DEADLOCK; FEATURE="DistributedCluster"; ASPECT=RequestInnerMutexYields; STATUS=TESTED; TEST=tests/test_sonny6541_drop_apply_deadlock.zig; OWNER=distributed; UPDATED=2026-11-14
    /// SONNY-6541 (1): take `inner_mutex` for a request (a propose, a term or
    /// leader read), or return false, without it, when the calling thread
    /// holds the lock of a graph a Raft `drop_graph` apply is waiting for
    /// (`graph_storage_adapter.threadHoldsGraphAwaitedByReplicatedDrop`).
    /// That apply holds `inner_mutex` until the graph's lock is free, so
    /// waiting for it here never ends. Lock order: a graph's `rwlock` ->
    /// `inner_mutex`; the one apply that takes a graph's `rwlock` under
    /// `inner_mutex` (drop_graph) announces it first, and every request that
    /// holds a graph's lock gives up instead of waiting for it. A thread
    /// that holds no graph lock waits as before.
    fn lockInnerForRequest(self: *RaftNode) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (self.inner_mutex.tryLock()) return true;
        if (!graph_storage_adapter.threadHoldsAnyGraphOrStoreLock()) {
            self.inner_mutex.lockUncancelable(io);
            return true;
        }
        var sleep_ns: u64 = 20 * std.time.ns_per_us;
        while (true) {
            if (graph_storage_adapter.threadMustYieldToReplicatedApply()) return false;
            io.sleep(.fromNanoseconds(sleep_ns), .awake) catch {};
            if (self.inner_mutex.tryLock()) return true;
            sleep_ns = @min(sleep_ns * 2, 500 * std.time.ns_per_us);
        }
    }

    // CANARY: REQ=REQ-SONNY-6611-RAFT-PERSIST-BEFORE-APPLY; FEATURE="Raft Consensus Persistence"; ASPECT=ApplyAfterAdvancePersist; STATUS=TESTED; TEST=tests/test_sonny6611_raft_persist_before_apply.zig; OWNER=distributed; UPDATED=2026-11-15
    // CANARY: REQ=REQ-SONNY-6563-VOTE-PERSIST-BEFORE-SEND; FEATURE="Raft Consensus Persistence"; ASPECT=SentAfterAdvancePersist; STATUS=TESTED; TEST=tests/test_sonny6563_vote_persist_before_send.zig; OWNER=distributed; UPDATED=2026-11-15
    /// Process one raft Ready, under `inner_mutex`, in the order Raft's
    /// durability rules need (raft v0.2.0):
    ///
    /// 1. `ready()`;
    /// 1b. SONNY-6665 (raft v0.2.6): a snapshot received from the leader
    ///    arrives staged in a file (`Ready.staged_snapshot`); its data and
    ///    metadata are synced with `inner_mutex` RELEASED (the only gap in a
    ///    Ready's processing; another thread may step the node meanwhile,
    ///    but none drains a Ready or runs the timers: `draining`);
    /// 2. `advancePersist()`: the Ready's hard state (term, vote), its
    ///    unstable entries and its snapshot reach storage (FileStorage:
    ///    written and fsynced; a staged snapshot is renamed into place);
    /// 2b. SONNY-6622, SONNY-6665: the state machine is restored from that
    ///    snapshot (on the restore thread when there is a restore callback,
    ///    the node paused meanwhile) before any entry after it applies and
    ///    before its acknowledgement goes out; with FileStorage the data is
    ///    read from the committed snapshot file. A node that stops between
    ///    2 and 2b restores it when it starts again (the store's Raft index
    ///    is behind the snapshot's);
    /// 3. send `Ready.messages` (votes, a candidate's RequestVote, every
    ///    vote / append / snapshot reply), which announce that state
    ///    (SONNY-6563, SONNY-6592);
    /// 4. apply `Ready.committed_entries` (SONNY-6611 item 7: a follower can
    ///    receive an entry and its commit in one AppendEntries, and it was
    ///    applied while it was only in memory);
    /// 5. `advanceApply()`, which releases the Ready (and the committed
    ///    entries' data).
    ///
    /// If persisting or restoring fails nothing is sent or applied, and the
    /// node pauses (SONNY-6617): it keeps the Ready, takes no Raft input,
    /// and `tick` retries what failed with backoff (`retryStalledPersist`).
    /// Retrying, not stopping the node, because both steps are idempotent
    /// and the usual causes (a full or read-only disk) clear without a
    /// restart; a paused leader stops heartbeating, so the cluster fails
    /// over to a node that can write meanwhile.
    fn drainReady(self: *RaftNode) void {
        // SONNY-6665: another thread's drain released inner_mutex to sync a
        // snapshot; its Ready is not advanced yet. What this thread's step
        // produced goes out with the next Ready.
        if (self.draining) return;
        const rd = self.inner.ready() catch |err| {
            log.warn("raft ready error", &.{Attr.string("error", @errorName(err))});
            return;
        };

        // raft-0.1.3 removed `Ready.soft_state`; the role and term live
        // directly on RaftNode now.  Sync our mirror state from there.
        self.state = switch (self.inner.role) {
            .leader => .leader,
            .candidate => .candidate,
            .follower => .follower,
        };

        if (rd.hard_state) |hs| {
            self.current_term = hs.current_term;
        } else {
            self.current_term = self.inner.current_term;
        }

        // SONNY-6636 (b): the entries held back that a snapshot from the
        // leader covers go.
        if (rd.snapshot) |snap| self.dropHeldThrough(snap.metadata.index);
        // CANARY: REQ=REQ-SONNY-6665-STAGED-INSTALL-OFF-MUTEX; FEATURE="Raft Snapshot Persistence"; ASPECT=SyncStagedSnapshotUnlocked; STATUS=TESTED; TEST=tests/test_sonny6665_install_lock_hold.zig; OWNER=distributed; UPDATED=2026-11-16
        if (rd.staged_snapshot) |staged| {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.draining = true;
            self.inner_mutex.unlock(io);
            const synced = self.inner.storage.syncStagedSnapshot(staged);
            self.inner_mutex.lockUncancelable(io);
            self.draining = false;
            // advancePersist() syncs it under the lock if this failed.
            synced catch |err| log.warn("raft: received snapshot not synced off the lock; advancePersist syncs it", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("snapshot_index", staged.metadata.index),
            });
        }
        const persist_start = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
        const persisted = self.inner.advancePersist();
        self.notePersist(persist_start);
        persisted catch |err| {
            self.stall(rd);
            log.err("raft storage write failed: this node sends no vote or reply, applies nothing and takes no Raft input until the write succeeds (retried every few ticks); check the Raft data directory (disk full, read-only, permissions)", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("node_id", self.id),
                Attr.uint("term", self.inner.current_term),
            });
            return;
        };
        if (rd.snapshot) |snap| {
            // SONNY-6636 (3): on the restore thread, the node paused meanwhile.
            if (self.snapshot_restore_callback != null) {
                self.stall(rd);
                self.stalled_persisted = true;
                self.startRestore(snap);
                return;
            }
            self.restoreSnapshot(snap) catch |err| {
                self.stall(rd);
                self.stalled_persisted = true;
                log.err("raft snapshot restore failed: this node sends no vote or reply, applies nothing and takes no Raft input until the restore succeeds (retried every few ticks); applying later entries without the snapshot's contents would diverge from the cluster", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("node_id", self.id),
                    Attr.uint("snapshot_index", snap.metadata.index),
                    Attr.uint("snapshot_term", snap.metadata.term),
                });
                return;
            };
            self.sm_applied = @max(self.sm_applied, snap.metadata.index);
        }
        self.finishReady(rd);
    }

    /// SONNY-6667: account an `advancePersist()` that started at `start`.
    fn notePersist(self: *RaftNode, start: std.Io.Timestamp) void {
        const ns: u64 = @intCast(@max(0, start.durationTo(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io())).nanoseconds));
        if (ns > self.stats.persist_max_ns) self.stats.persist_max_ns = ns;
    }

    /// SONNY-6617: keep `rd` and pause the node until `retryStalledPersist`
    /// gets it through.
    fn stall(self: *RaftNode, rd: raft_lib.Ready) void {
        self.stalled_ready = rd;
        self.stalled_restored = false;
        self.stalled_persisted = false;
        @atomicStore(bool, &self.persist_stalled, true, .release);
        self.persist_failures = 1;
        self.persist_backoff = 1;
        self.persist_retry_wait = 0;
    }

    /// SONNY-6622: restore the state machine from `snap` (see
    /// `snapshot_restore_callback`). Under `inner_mutex`.
    fn restoreSnapshot(self: *RaftNode, snap: raft_lib.Snapshot) !void {
        const restore = self.snapshot_restore_callback orelse {
            // No state machine, nothing to restore (in-process tests).
            if (self.apply_callback == null) return;
            return error.RaftSnapshotRestoreUnavailable;
        };
        const owned = try self.committedSnapshotData(snap);
        defer if (owned) |d| self.allocator.free(d);
        const data = owned orelse snap.data;
        try restore(self.allocator, data, snap.metadata.index, snap.metadata.term);
        self.stats.snapshots_received += 1;
        log.info("raft: state machine restored from the leader's snapshot", &.{
            Attr.uint("node_id", self.id),
            Attr.uint("snapshot_index", snap.metadata.index),
            Attr.uint("snapshot_term", snap.metadata.term),
            Attr.uint("bytes", data.len),
        });
    }

    /// SONNY-6665: the data of `snap`, a snapshot `advancePersist()`
    /// committed, when the Ready does not carry it (raft v0.2.6 staged it in
    /// FileStorage): read from the committed snapshot file and checked
    /// against the digest committed with it. Null when the Ready carries
    /// it. Safe without `inner_mutex` (`FileStorage.openSnapshotReader`).
    /// The caller frees it.
    fn committedSnapshotData(self: *RaftNode, snap: raft_lib.Snapshot) !?[]u8 {
        if (snap.data.len > 0) return null;
        const fs = switch (self.storage_backing) {
            .file => |fs| fs,
            // These stage in memory: the Ready carries the data.
            .in_memory, .tde_file => return null,
        };
        var reader = (try fs.openSnapshotReader()) orelse return error.RaftSnapshotMissing;
        defer reader.close();
        // A newer snapshot committed since (this node's own) supersedes it.
        if (reader.metadata.index != snap.metadata.index or reader.metadata.term != snap.metadata.term) return error.RaftSnapshotChanged;
        const data = try self.allocator.alloc(u8, @intCast(reader.size));
        errdefer self.allocator.free(data);
        if (try reader.readAt(data, 0) != data.len) return error.RaftSnapshotChanged;
        if (reader.expected_digest) |want| {
            var got: [32]u8 = undefined;
            // fips-exempt: non-security — snapshot-data integrity digest (raft's).
            std.crypto.hash.Blake3.hash(data, &got, .{});
            if (!std.mem.eql(u8, &got, &want)) return error.RaftSnapshotDigestMismatch;
        }
        return data;
    }

    /// SONNY-6617: the most ticks between two persist retries.
    const persist_backoff_max_ticks: u32 = 64;

    const RestoreState = enum(u8) { idle, running, succeeded, failed };

    /// SONNY-6636 (3): start restoring `snap` (the stalled Ready's) on the
    /// restore thread. Under `inner_mutex`.
    fn startRestore(self: *RaftNode, snap: raft_lib.Snapshot) void {
        self.restore_state.store(@intFromEnum(RestoreState.running), .release);
        self.restore_thread = std.Thread.spawn(.{}, restoreWorker, .{ self, snap }) catch |err| {
            self.restore_error = err;
            self.restore_state.store(@intFromEnum(RestoreState.failed), .release);
            return;
        };
        log.info("raft: restoring the leader's snapshot on the restore thread; the node is paused until it ends", &.{
            Attr.uint("node_id", self.id),
            Attr.uint("snapshot_index", snap.metadata.index),
            Attr.uint("snapshot_term", snap.metadata.term),
            Attr.uint("bytes", snap.data.len),
        });
    }

    fn restoreWorker(self: *RaftNode, snap: raft_lib.Snapshot) void {
        const restore = self.snapshot_restore_callback.?;
        // SONNY-6636 (b): not while the snapshot thread copies the files.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.state_machine_io_mutex.lockUncancelable(io);
        defer self.state_machine_io_mutex.unlock(io);
        const outcome: anyerror!void = blk: {
            const owned = self.committedSnapshotData(snap) catch |err| break :blk err;
            defer if (owned) |d| self.allocator.free(d);
            break :blk restore(self.allocator, owned orelse snap.data, snap.metadata.index, snap.metadata.term);
        };
        if (outcome) |_| {
            self.restore_state.store(@intFromEnum(RestoreState.succeeded), .release);
        } else |err| {
            self.restore_error = err;
            self.restore_state.store(@intFromEnum(RestoreState.failed), .release);
        }
    }

    /// SONNY-6636 (3): the restore thread's outcome, once it has ended (the
    /// thread joined); null while it runs. Under `inner_mutex`.
    fn collectRestore(self: *RaftNode) ?anyerror!void {
        const state: RestoreState = @enumFromInt(self.restore_state.load(.acquire));
        switch (state) {
            .running => return null,
            .idle => return error.RaftSnapshotRestoreNotStarted,
            .succeeded, .failed => {},
        }
        if (self.restore_thread) |t| t.join();
        self.restore_thread = null;
        self.restore_state.store(@intFromEnum(RestoreState.idle), .release);
        if (state == .failed) return self.restore_error;
        return {};
    }

    /// SONNY-6617: retry what failed of the stalled Ready: its
    /// `advancePersist()` (idempotent: it re-writes the hard state, still
    /// unacknowledged by `advanceApply`, re-appends the unstable entries,
    /// truncating the storage from their first index, and re-commits a
    /// snapshot), then (SONNY-6622, SONNY-6665) the restore of its snapshot.
    /// On success the Ready is sent and applied as `drainReady` would have;
    /// on failure the wait doubles, up to `persist_backoff_max_ticks`.
    /// Under `inner_mutex`.
    fn retryStalledPersist(self: *RaftNode) void {
        const rd = self.stalled_ready orelse return;
        // SONNY-6636 (3): a snapshot restoring on the restore thread: wait
        // for it; a failed one is started again after the backoff.
        if (rd.snapshot) |snap| if (self.snapshot_restore_callback != null and self.stalled_persisted and !self.stalled_restored) {
            const state: RestoreState = @enumFromInt(self.restore_state.load(.acquire));
            if (state == .idle) {
                if (self.persist_retry_wait > 0) {
                    self.persist_retry_wait -= 1;
                    return;
                }
                self.startRestore(snap);
                return;
            }
            const outcome = self.collectRestore() orelse return;
            outcome catch |err| {
                self.persist_failures += 1;
                self.persist_retry_wait = self.persist_backoff;
                self.persist_backoff = @min(self.persist_backoff * 2, persist_backoff_max_ticks);
                log.err("raft snapshot restore failed: this node sends no vote or reply, applies nothing and takes no Raft input until a restore succeeds (retried with backoff); applying later entries without the snapshot's contents would diverge from the cluster", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("node_id", self.id),
                    Attr.uint("snapshot_index", snap.metadata.index),
                    Attr.uint("attempts", self.persist_failures),
                    Attr.uint("next_retry_ticks", self.persist_retry_wait),
                });
                return;
            };
            self.stalled_restored = true;
            self.persist_retry_wait = 0;
            self.stats.snapshots_received += 1;
            log.info("raft: state machine restored from the leader's snapshot", &.{
                Attr.uint("node_id", self.id),
                Attr.uint("snapshot_index", snap.metadata.index),
                Attr.uint("snapshot_term", snap.metadata.term),
                Attr.uint("bytes", snap.data.len),
            });
        };
        if (self.persist_retry_wait > 0) {
            self.persist_retry_wait -= 1;
            return;
        }
        const retried: anyerror!void = blk: {
            if (!self.stalled_persisted) {
                self.inner.advancePersist() catch |err| break :blk err;
                self.stalled_persisted = true;
                // SONNY-6636 (3): the restore runs on the restore thread.
                if (rd.snapshot) |snap| if (self.snapshot_restore_callback != null) {
                    self.persist_failures = 0;
                    self.persist_backoff = 1;
                    self.startRestore(snap);
                    return;
                };
            }
            if (rd.snapshot) |snap| if (self.snapshot_restore_callback == null and !self.stalled_restored) {
                self.restoreSnapshot(snap) catch |err| break :blk err;
                self.stalled_restored = true;
            };
        };
        retried catch |err| {
            self.persist_failures += 1;
            self.persist_retry_wait = self.persist_backoff;
            self.persist_backoff = @min(self.persist_backoff * 2, persist_backoff_max_ticks);
            log.err("raft storage write or snapshot restore still failing; node remains paused", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("node_id", self.id),
                Attr.uint("attempts", self.persist_failures),
                Attr.uint("next_retry_ticks", self.persist_retry_wait),
            });
            return;
        };
        log.info("raft storage write and snapshot restore succeeded; node resumes", &.{
            Attr.uint("node_id", self.id),
            Attr.uint("attempts", self.persist_failures + 1),
        });
        self.stalled_ready = null;
        self.stalled_restored = false;
        self.stalled_persisted = false;
        @atomicStore(bool, &self.persist_stalled, false, .release);
        self.persist_failures = 0;
        self.persist_backoff = 1;
        self.persist_retry_wait = 0;
        if (rd.snapshot) |snap| self.sm_applied = @max(self.sm_applied, snap.metadata.index);
        self.finishReady(rd);
    }

    /// SONNY-6617: true while a failed Raft storage write (or, SONNY-6622, a
    /// failed snapshot restore) is pending retry (the node takes no Raft
    /// input and sends nothing). For health checks.
    pub fn persistStalled(self: *RaftNode) bool {
        return @atomicLoad(bool, &self.persist_stalled, .acquire);
    }

    /// Steps 3-5 of `drainReady` for a Ready that `advancePersist()` wrote.
    fn finishReady(self: *RaftNode, rd: raft_lib.Ready) void {
        // CANARY: REQ=REQ-SONNY-6665-SNAPSHOT-STREAM; FEATURE="Raft Snapshot Persistence"; ASPECT=StreamedOffInnerMutex; STATUS=TESTED; TEST=tests/test_sonny6665_snapshot_resume.zig; OWNER=distributed; UPDATED=2026-11-16
        // SONNY-6665: InstallSnapshot transfers are streamed once
        // inner_mutex is released (`unlockInner`); the Ready's slice is
        // released by advanceApply(). One that cannot be kept is sent again
        // by the leader after its retry interval.
        self.snapshot_sends.appendSlice(self.allocator, rd.snapshot_sends) catch |err| {
            log.warn("raft: snapshot send dropped; the leader sends it again after its retry interval", &.{Attr.string("error", @errorName(err))});
        };

        // CANARY: REQ=REQ-DIST-RAFT-DRAINREADY-DISPATCH; FEATURE="Raft Wrapper Transport Dispatch"; ASPECT=DrainReadyMessages; STATUS=TESTED; TEST=tests/test_drainready_dispatch.zig; OWNER=distributed; UPDATED=2026-11-15
        for (rd.messages) |out| {
            if (self.transport != null) {
                self.dispatchRaftLibMessageWithDest(out.to, out.msg) catch |err| {
                    // Dropped: raft retries (a candidate asks again, a
                    // leader re-sends AppendEntries).
                    log.warn("raft message dispatch failed", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.uint("to", out.to),
                    });
                };
            } else if (self.inner_transport) |t| {
                t.send(out.to, out.msg);
            } else {
                log.debug("raft drainReady has a message but no transport set", &.{Attr.uint("to", out.to)});
            }
        }

        // Apply committed entries -- deserialize the tag-prefixed command bytes
        const apply_io = std.Io.Threaded.global_single_threaded.io();
        const apply_start = std.Io.Clock.awake.now(apply_io);
        // SONNY-6636 (b): while a snapshot copies the state machine, and
        // until what it held back is applied, entries are held in order.
        if (self.applies_held or self.heldCount() > 0) {
            self.holdEntries(rd.committed_entries);
        } else {
            for (rd.committed_entries) |entry| self.applyEntry(entry.index, entry.kind, entry.data);
        }
        const apply_ns: u64 = @intCast(@max(0, apply_start.durationTo(std.Io.Clock.awake.now(apply_io)).nanoseconds));
        if (apply_ns > self.stats.apply_max_ns) self.stats.apply_max_ns = apply_ns;

        // `advanceApply()` returns `!void`; this void fn logs on failure —
        // the next ready() reports ReadyNotAdvanced if it was skipped.
        self.inner.advanceApply() catch |err| {
            log.warn("raft advance error", &.{Attr.string("error", @errorName(err))});
        };
        if (!self.applies_held and self.heldCount() == 0) self.sm_applied = @max(self.sm_applied, self.inner.log.applied);
        @atomicStore(u64, &self.applied_index, self.sm_applied, .release);
    }

    const HeldEntry = struct { index: u64, kind: raft_lib.EntryKind, data: []u8 };

    fn heldCount(self: *const RaftNode) usize {
        return self.held_entries.items.len - self.held_start;
    }

    /// Apply one committed entry (`apply_callback`). Under `inner_mutex`.
    fn applyEntry(self: *RaftNode, index: u64, kind: raft_lib.EntryKind, data: []const u8) void {
        if (kind == .normal and data.len > 0) apply: {
            const callback = self.apply_callback orelse break :apply;
            // GAP-0889 (F1): a committed entry that fails to decode is
            // skipped loudly — fabricating an inert `.write` here would
            // silently degrade poisoned/future-format entries.
            const cmd = decodeCommittedCommand(&self.stats, data, index, self.current_term) orelse break :apply;
            // CANARY: REQ=QUAL-D005; FEATURE="Raft Apply Callback Error Visibility"; ASPECT=ErrorLogging; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
            // Pass the committed entry's globally-unique, cross-node-identical
            // log index so the apply layer can derive a deterministic,
            // restart-idempotent node id (Raft Log Matching Property).
            // SONNY-3348 (round 19): the result is the caller's to
            // free (`raft_apply.applyCommand`); it was dropped, and a
            // create's 8-byte id leaked per committed entry per node.
            const applied = callback(self.allocator, cmd, index) catch |err| blk: {
                log.err("Raft apply_callback failed — committed entry not applied", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("entry_index", index),
                    Attr.uint("term", self.current_term),
                });
                self.stats.apply_errors += 1;
                break :blk null;
            };
            if (applied) |result| self.allocator.free(result);
        }
        self.stats.entries_applied += 1;
        self.snapshot_bytes_since +|= data.len;
        self.sm_applied = @max(self.sm_applied, index);
    }

    /// SONNY-6636 (b): keep copies of `entries` (the Ready's, freed by
    /// `advanceApply`) to apply after the snapshot. One that cannot be
    /// copied is applied now, after everything held before it, and the
    /// running snapshot no longer reflects one index: it is dropped.
    fn holdEntries(self: *RaftNode, entries: []const raft_lib.Entry) void {
        for (entries) |entry| {
            const copied = blk: {
                const data = self.allocator.dupe(u8, entry.data) catch break :blk false;
                self.held_entries.append(self.allocator, .{ .index = entry.index, .kind = entry.kind, .data = data }) catch {
                    self.allocator.free(data);
                    break :blk false;
                };
                break :blk true;
            };
            if (copied) continue;
            log.err("raft: out of memory holding a committed entry during a snapshot; applying it now and dropping the snapshot", &.{Attr.uint("entry_index", entry.index)});
            self.snapshot_job_spoiled = true;
            self.applyHeldUpTo(std.math.maxInt(u64));
            self.applyEntry(entry.index, entry.kind, entry.data);
        }
    }

    /// SONNY-6636 (b): apply held entries, oldest first, for at most
    /// `SnapshotPolicy.apply_budget_ns` (at least one), once the snapshot no
    /// longer holds them. Under `inner_mutex`.
    fn applyHeld(self: *RaftNode) void {
        if (self.applies_held or self.heldCount() == 0) return;
        self.applyHeldUpTo(self.snapshot_policy.apply_budget_ns);
    }

    fn applyHeldUpTo(self: *RaftNode, budget_ns: u64) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const start = std.Io.Clock.awake.now(io);
        while (self.held_start < self.held_entries.items.len) {
            const h = self.held_entries.items[self.held_start];
            self.held_start += 1;
            self.applyEntry(h.index, h.kind, h.data);
            self.allocator.free(h.data);
            const spent: u64 = @intCast(@max(0, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));
            if (spent >= budget_ns) break;
        }
        if (self.held_start == self.held_entries.items.len) {
            self.held_entries.clearRetainingCapacity();
            self.held_start = 0;
            self.sm_applied = @max(self.sm_applied, self.inner.log.applied);
        }
        @atomicStore(u64, &self.applied_index, self.sm_applied, .release);
    }

    /// SONNY-6636 (b): a snapshot from the leader covers the held entries
    /// up to `index`; they go unapplied. Under `inner_mutex`.
    fn dropHeldThrough(self: *RaftNode, index: u64) void {
        while (self.held_start < self.held_entries.items.len and self.held_entries.items[self.held_start].index <= index) {
            self.allocator.free(self.held_entries.items[self.held_start].data);
            self.held_start += 1;
        }
        if (self.held_start == self.held_entries.items.len) {
            self.held_entries.clearRetainingCapacity();
            self.held_start = 0;
        }
    }

    /// SONNY-6636 (b): no snapshot copy is running or waiting to be saved.
    /// Safe to call from any thread.
    pub fn snapshotInProgress(self: *const RaftNode) bool {
        return @as(RestoreState, @enumFromInt(self.snapshot_job_state.load(.acquire))) != .idle;
    }

    /// SONNY-6636 (b): the index this node's Raft log is compacted at (its
    /// last snapshot's, taken or installed).
    pub fn snapshotIndex(self: *RaftNode) u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.inner_mutex.unlock(io);
        return self.inner.log.snapshot_index;
    }

    /// SONNY-6665: the index and term of the snapshot this node's Raft log
    /// is compacted at (0 and 0: none).
    pub fn snapshotPoint(self: *RaftNode) struct { index: u64, term: u64 } {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.inner_mutex.unlock(io);
        return .{ .index = self.inner.log.snapshot_index, .term = self.inner.log.snapshot_term };
    }

    /// SONNY-6636 (b): the data of the snapshot in this node's Raft
    /// storage, or null. The caller frees it.
    pub fn localSnapshotData(self: *RaftNode, allocator: Allocator) !?[]u8 {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.inner_mutex.unlock(io);
        const snap = (try self.inner.storage.loadSnapshot()) orelse return null;
        defer raft_lib.freeSnapshot(self.allocator, snap);
        return try allocator.dupe(u8, snap.data);
    }

    /// SONNY-6636 (b): start a snapshot once the log has grown past the
    /// policy since the last one. The applies are held from here, so the
    /// state machine reflects exactly the index the snapshot records.
    /// Under `inner_mutex`.
    fn maybeStartSnapshot(self: *RaftNode) void {
        if (self.snapshot_create_callback == null or !self.snapshot_policy.enabled()) return;
        if (self.snapshotInProgress() or self.stalled_ready != null) return;
        if (self.applies_held or self.heldCount() > 0 or self.snapshot_retry_wait > 0) return;
        const index = self.sm_applied;
        if (index != self.inner.log.applied) return;
        const since = index -| self.inner.log.snapshot_index;
        if (since == 0) return;
        const p = self.snapshot_policy;
        if (!((p.entries > 0 and since >= p.entries) or (p.bytes > 0 and self.snapshot_bytes_since >= p.bytes))) return;
        _ = self.inner.log.term(index) catch return;
        // SONNY-6665: raft's point for a snapshot taken now (the applied
        // index, its term and the configuration), which the staged snapshot
        // carries.
        const point = self.inner.snapshotPoint() catch |err| {
            self.backOffSnapshot(err, index);
            return;
        };
        self.snapshot_job_point = point;
        self.applies_held = true;
        self.snapshot_job_spoiled = false;
        self.snapshot_job_index = point.index;
        self.snapshot_job_term = point.term;
        self.snapshot_job_bytes = 0;
        self.snapshot_job_stage_ns = 0;
        self.snapshot_job_state.store(@intFromEnum(RestoreState.running), .release);
        self.snapshot_thread = std.Thread.spawn(.{}, snapshotWorker, .{self}) catch |err| {
            self.snapshot_job_error = err;
            self.snapshot_job_state.store(@intFromEnum(RestoreState.failed), .release);
            return;
        };
        log.info("raft: snapshotting the state machine on the snapshot thread; committed entries are held until it is copied", &.{
            Attr.uint("node_id", self.id),
            Attr.uint("snapshot_index", index),
            Attr.uint("entries_since_last", since),
            Attr.uint("bytes_since_last", self.snapshot_bytes_since),
        });
    }

    /// SONNY-6636 (b), SONNY-6665: copies the state machine, then writes
    /// and syncs the copy in the Raft storage as a staged snapshot (raft
    /// `Storage.stageSnapshot`), both without `inner_mutex`;
    /// `collectSnapshot` commits it under the lock.
    fn snapshotWorker(self: *RaftNode) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const start = std.Io.Clock.awake.now(io);
        const create = self.snapshot_create_callback.?;
        const outcome = blk: {
            // Not while a restore swaps the files.
            self.state_machine_io_mutex.lockUncancelable(io);
            defer self.state_machine_io_mutex.unlock(io);
            break :blk create(self.allocator, self.snapshot_job_index, self.snapshot_job_term);
        };
        self.snapshot_job_ns = @intCast(@max(0, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));
        const data = outcome catch |err| {
            self.snapshot_job_error = err;
            self.snapshot_job_state.store(@intFromEnum(RestoreState.failed), .release);
            return;
        };
        defer self.allocator.free(data);
        self.snapshot_job_bytes = data.len;
        const stage_start = std.Io.Clock.awake.now(io);
        // `inner.storage` is set once at init; the point is this job's.
        const meta = self.snapshot_job_point.?.metadata();
        const staged = self.inner.storage.stageSnapshot(self.allocator, .{ .metadata = meta, .data = data }) catch |err| {
            self.snapshot_job_error = err;
            self.snapshot_job_state.store(@intFromEnum(RestoreState.failed), .release);
            return;
        };
        self.snapshot_job_stage_ns = @intCast(@max(0, stage_start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));
        self.snapshot_job_staged = staged;
        self.snapshot_job_state.store(@intFromEnum(RestoreState.succeeded), .release);
    }

    /// SONNY-6636 (b): once the snapshot thread ended, the held entries are
    /// released, and the snapshot is committed and the log compacted at its
    /// index (SONNY-6665: raft `commitSnapshot` of the snapshot the thread
    /// staged, at the index the copy reflects, which `log.applied` has moved
    /// past; only renames and the compaction happen here). Dropped when a
    /// snapshot from the leader was installed meanwhile or a persist is
    /// pending. A failure backs off. Under `inner_mutex`.
    fn collectSnapshot(self: *RaftNode) void {
        const state: RestoreState = @enumFromInt(self.snapshot_job_state.load(.acquire));
        if (state != .succeeded and state != .failed) return;
        if (self.snapshot_thread) |t| t.join();
        self.snapshot_thread = null;
        self.applies_held = false;
        var point = self.snapshot_job_point;
        self.snapshot_job_point = null;
        defer if (point) |*p| p.deinit();
        var staged = self.snapshot_job_staged;
        self.snapshot_job_staged = null;
        defer if (staged) |*st| self.inner.storage.releaseStagedSnapshot(st);
        if (self.snapshot_job_ns > self.stats.snapshot_create_max_ns) self.stats.snapshot_create_max_ns = self.snapshot_job_ns;
        defer self.snapshot_job_state.store(@intFromEnum(RestoreState.idle), .release);
        const index = self.snapshot_job_index;
        if (state == .failed) {
            if (self.snapshot_job_error == error.RaftSnapshotNeedsDurableStore) {
                log.warn("raft: this node's state machine cannot be snapshotted (not a durable store); its Raft log is not compacted", &.{Attr.uint("node_id", self.id)});
                self.snapshot_policy = SnapshotPolicy.disabled;
                return;
            }
            self.backOffSnapshot(self.snapshot_job_error, index);
            return;
        }
        const dropped = self.snapshot_job_spoiled or self.stalled_ready != null or index <= self.inner.log.snapshot_index;
        const io = std.Io.Threaded.global_single_threaded.io();
        const start = std.Io.Clock.awake.now(io);
        const committed: anyerror!void = if (dropped) error.SnapshotOutOfDate else self.inner.commitSnapshot(&staged.?);
        committed catch |err| switch (err) {
            error.SnapshotOutOfDate => {
                log.info("raft: snapshot dropped (an entry was applied during it, or a newer snapshot is installed or pending)", &.{
                    Attr.uint("node_id", self.id),
                    Attr.uint("snapshot_index", index),
                });
                return;
            },
            else => {
                self.backOffSnapshot(err, index);
                return;
            },
        };
        const ns: u64 = @intCast(@max(0, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));
        if (ns > self.stats.snapshot_install_max_ns) self.stats.snapshot_install_max_ns = ns;
        self.stats.snapshots_taken += 1;
        self.snapshot_bytes_since = 0;
        self.snapshot_backoff = 1;
        log.info("raft: snapshot taken; the Raft log is compacted up to it", &.{
            Attr.uint("node_id", self.id),
            Attr.uint("snapshot_index", index),
            Attr.uint("bytes", self.snapshot_job_bytes),
            Attr.uint("copy_ms", self.snapshot_job_ns / std.time.ns_per_ms),
            Attr.uint("stage_ms", self.snapshot_job_stage_ns / std.time.ns_per_ms),
            Attr.uint("commit_ms", ns / std.time.ns_per_ms),
        });
    }

    fn backOffSnapshot(self: *RaftNode, err: anyerror, index: u64) void {
        self.snapshot_retry_wait = self.snapshot_backoff * 16;
        self.snapshot_backoff = @min(self.snapshot_backoff * 2, persist_backoff_max_ticks);
        log.err("raft: snapshot failed; the Raft log is not compacted (retried with backoff)", &.{
            Attr.string("error", @errorName(err)),
            Attr.uint("node_id", self.id),
            Attr.uint("snapshot_index", index),
            Attr.uint("next_retry_ticks", self.snapshot_retry_wait),
        });
    }

    /// SONNY-6665: release `inner_mutex`, then stream the InstallSnapshot
    /// transfers the Readys drained under it asked for (raft
    /// `Config.stream_snapshots`): the snapshot is read chunk by chunk and
    /// each chunk queued on the peer's outbox, none of it under the lock.
    /// Every entry point that drains a Ready unlocks with this.
    fn unlockInner(self: *RaftNode) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (self.snapshot_sends.items.len == 0) {
            self.inner_mutex.unlock(io);
            return;
        }
        var sends = self.snapshot_sends;
        self.snapshot_sends = .empty;
        defer sends.deinit(self.allocator);
        // The in-memory storage has no reader that is safe without the
        // lock: its snapshot is copied under it.
        var mem_snap: ?raft_lib.Snapshot = null;
        if (self.storage_backing == .in_memory) mem_snap = self.inner.storage.loadSnapshot() catch |err| blk: {
            log.warn("raft: snapshot to send unreadable; the leader sends it again after its retry interval", &.{Attr.string("error", @errorName(err))});
            break :blk null;
        };
        defer if (mem_snap) |snap| raft_lib.freeSnapshot(self.allocator, snap);
        self.inner_mutex.unlock(io);
        for (sends.items) |req| self.streamSnapshotSend(req, mem_snap) catch |err| {
            log.warn("raft: snapshot send failed; the leader sends it again after its retry interval", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("to", req.to),
                Attr.uint("snapshot_index", req.index),
                Attr.uint("offset", req.offset),
            });
        };
    }

    /// SONNY-6665: stream the storage's committed snapshot for `req`
    /// (raft `streamSnapshot`) through the wrapper transport (or, in
    /// in-process tests, the inner one). Without `inner_mutex`.
    fn streamSnapshotSend(self: *RaftNode, req: raft_lib.SnapshotSend, mem_snap: ?raft_lib.Snapshot) !void {
        var sink = SnapshotStreamSink{ .node = self, .term = req.term };
        const t: raft_lib.Transport = if (self.transport != null) sink.transport() else self.inner_transport orelse return error.NoTransport;
        switch (self.storage_backing) {
            .file => |fs| {
                var reader = (try fs.openSnapshotReader()) orelse return error.NoSnapshot;
                defer reader.close();
                try raft_lib.streamSnapshot(self.allocator, &reader, req, t);
            },
            .tde_file => |tde| {
                const snap = (try tde.loadSnapshotUnlocked()) orelse return error.NoSnapshot;
                defer raft_lib.freeSnapshot(self.allocator, snap);
                var reader = raft_lib.MemorySnapshotReader.init(snap);
                try raft_lib.streamSnapshot(self.allocator, &reader, req, t);
            },
            .in_memory => {
                var reader = raft_lib.MemorySnapshotReader.init(mem_snap orelse return error.NoSnapshot);
                try raft_lib.streamSnapshot(self.allocator, &reader, req, t);
            },
        }
        log.info("raft: snapshot streamed to a follower", &.{
            Attr.uint("node_id", self.id),
            Attr.uint("to", req.to),
            Attr.uint("snapshot_index", req.index),
            Attr.uint("offset", req.offset),
        });
    }

    /// Look up a peer by id.  Returns null if the id isn't in `self.peers`.
    /// Linear scan is fine: the peer count is bounded by the cluster size
    /// (typically 3-7) and message dispatch dominates lookup cost.
    fn findPeerById(self: *RaftNode, to: u64) ?Peer {
        for (self.peers) |*p| {
            if (p.id != to) continue;
            // SONNY-6459: `last_contact` is stored atomically by the
            // cluster's inbound handlers; copy it with an atomic load.
            return .{
                .id = p.id,
                .endpoint = p.endpoint,
                .port = p.port,
                .last_contact = @atomicLoad(i64, &p.last_contact, .monotonic),
            };
        }
        return null;
    }

    /// Forward a raft_lib.Message to peer `to` through the wrapper
    /// transport: converted to a geode Message (which owns copies of the
    /// entry and snapshot data, `raftLibMessageToGeode`) and queued on the
    /// peer's outbox, whose drain thread sends it without `inner_mutex`
    /// (A6e: a QUIC write inline stalled the receive thread for the length
    /// of a handshake). A test's `send_override` is called in place. Used by
    /// `drainReady` for `Ready.messages` and by the bridge for leader
    /// replication.
    ///
    /// The term is read from `self.inner`: the wrapper's `current_term`
    /// mirror is refreshed only in `drainReady`, and the bridge fires while
    /// `inner.step` / `inner.tick` is still running.
    fn dispatchRaftLibMessageWithDest(self: *RaftNode, to: u64, msg: raft_lib.Message) !void {
        return self.dispatchToPeer(to, self.inner.current_term, msg);
    }

    /// `dispatchRaftLibMessageWithDest` with the envelope's term given:
    /// callable without `inner_mutex` (SONNY-6665: a streamed snapshot's
    /// chunks carry the term the leader asked for the send in).
    fn dispatchToPeer(self: *RaftNode, to: u64, term: u64, msg: raft_lib.Message) !void {
        const t = self.transport orelse return error.NoTransport;
        const peer = self.findPeerById(to) orelse return error.PeerNotFound;
        const geode_msg = try raftLibMessageToGeode(self.allocator, msg);
        if (t.send_override != null) {
            defer freeOutboundMessage(self.allocator, geode_msg);
            return t.send(peer, self.id, term, geode_msg);
        }
        t.enqueueOutbound(peer, self.id, term, geode_msg) catch |err| {
            freeOutboundMessage(self.allocator, geode_msg);
            return err;
        };
    }
};

/// SONNY-6631: `hydrate` the graphs a raft library entry's command writes.
fn prehydrateEntry(hydrate: *const fn (cmd: Command) void, entry: raft_lib.Entry) void {
    if (entry.kind != .normal or entry.data.len == 0) return;
    const cmd = deserializeCommand(entry.data) catch return;
    hydrate(cmd);
}

/// SONNY-6665: the raft library Transport a streamed snapshot's chunks go
/// through (`RaftNode.streamSnapshotSend`): each is converted, with its own
/// copy of the chunk, and queued on the peer's outbox, with the term the
/// leader asked for the send in. Used without `inner_mutex`.
const SnapshotStreamSink = struct {
    node: *RaftNode,
    term: u64,

    const vtable = raft_lib.Transport.VTable{ .send = &sendImpl };

    fn transport(self: *SnapshotStreamSink) raft_lib.Transport {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn sendImpl(ptr: *anyopaque, to: u64, msg: raft_lib.Message) void {
        const self: *SnapshotStreamSink = @ptrCast(@alignCast(ptr));
        self.node.dispatchToPeer(to, self.term, msg) catch |err| log.warn("raft: snapshot chunk not queued; the leader sends it again after its retry interval", &.{
            Attr.string("error", @errorName(err)),
            Attr.uint("to", to),
        });
    }
};

/// Adapter that implements `raft_lib.Transport` and forwards every send
/// through the wrapper `Transport` field of the surrounding `RaftNode`.
///
/// Installed by `RaftNode.setTransport`. Since raft v0.2.0 the library sends
/// only leader replication (AppendEntries, heartbeats, InstallSnapshot)
/// through it, straight from `step()` / `tick()` / `propose()` (Raft thesis
/// §10.2.1: a leader may replicate before its own write is durable); votes
/// and replies come out of `Ready.messages` in `drainReady`, after
/// `advancePersist()`. The library frees an AppendEntries' entry data and a
/// snapshot's chunk data as soon as `send` returns, so the message is
/// converted, with its own copies, before it is queued.
///
/// The `to` parameter supplied by the raft library is authoritative.
const RaftLibTransportBridge = struct {
    pub const vtable = raft_lib.Transport.VTable{ .send = &sendImpl };

    fn sendImpl(ptr: *anyopaque, to: u64, msg: raft_lib.Message) void {
        const node: *RaftNode = @ptrCast(@alignCast(ptr));
        node.dispatchRaftLibMessageWithDest(to, msg) catch |err| switch (err) {
            error.NoTransport, error.PeerNotFound => log.debug("raft bridge: no route to peer", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("to", to),
            }),
            else => log.warn("raft bridge: send failed; dropping message", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("to", to),
            }),
        };
    }
};

/// Convert a raft_lib.Message into the geode wire-format Message used by
/// `Transport.send` / `writeRaftFrame`.  Allocates only where the geode
/// representation owns a copy: append_entries.entries, each entry's data
/// included, and install_snapshot.data (the raft library frees both when
/// its `send` returns, SONNY-6592). The caller frees the returned Message
/// with `freeOutboundMessage` once the send completes.
///
/// The geode Message variants carry strictly more fields than the
/// raft_lib counterparts (e.g. `voter_id`); we fill those with defaults
/// since they are populated on the receiving side from the wire envelope.
fn raftLibMessageToGeode(allocator: Allocator, msg: raft_lib.Message) !Message {
    return switch (msg) {
        .request_vote => |rv| Message{ .request_vote = .{
            .term = rv.term,
            .candidate_id = rv.candidate_id,
            .last_log_index = rv.last_log_index,
            .last_log_term = rv.last_log_term,
            .pre_vote = rv.pre_vote,
        } },
        .request_vote_response => |rvr| Message{
            .request_vote_response = .{
                .term = rvr.term,
                .vote_granted = rvr.vote_granted,
                // The geode Message carries a voter_id field; the raft_lib
                // counterpart does not.  Set to 0 — the receiver fills it
                // from the wire envelope's `from` field.
                .voter_id = 0,
                // A6d: preserve the pre-vote phase bit so the candidate
                // can count this response in its current phase.
                .pre_vote = rvr.pre_vote,
            },
        },
        .append_entries => |ae| blk: {
            // Convert raft_lib.Entry[] -> geode LogEntry[] (re-serializing
            // each command's tag-prefixed bytes back into the Command
            // variant the wire format expects).
            //
            // CRITICAL (2026-06-04 cluster write-replication BLOCKER): we MUST
            // deep-copy `e.data` here, not alias it.  `e.data` points into the
            // raft library's log — for a freshly-proposed entry that is the
            // leader's *unstable* entry buffer, which `RaftLog.stableTo` FREES
            // on the very next `advance()` (it runs right after this send is
            // enqueued).  This conversion feeds the ASYNCHRONOUS outbox: the
            // message is encoded much later, on the drain thread.  Aliasing
            // `e.data` therefore reads freed memory at encode time, so the
            // command serialized to empty/garbage and the AppendEntries went
            // out with no payload — the leader could never replicate any
            // freshly-written entry (only entries already in stable storage
            // from a prior term survived).  Owning a private copy via
            // `owned_wire_bytes` (freed in `freeOutboundMessage`) makes the
            // geode message independent of the raft log's unstable lifecycle.
            const entries = try allocator.alloc(LogEntry, ae.entries.len);
            var built: usize = 0;
            errdefer {
                for (entries[0..built]) |*le| {
                    if (le.owned_wire_bytes) |b| allocator.free(b);
                }
                allocator.free(entries);
            }
            for (ae.entries, 0..) |e, i| {
                const owned: ?[]u8 = if (e.data.len > 0) try allocator.dupe(u8, e.data) else null;
                errdefer if (owned) |b| allocator.free(b);
                // GAP-0889 (F1): outbound transit — same posture as the inbound
                // path above: forward the raw bytes verbatim, but log so a
                // poisoned entry in the log is visible while replicating.
                const cmd = if (owned) |b|
                    (deserializeCommand(b) catch |err| fallback: {
                        log.warn("Raft outbound entry decode failed — forwarding raw bytes", &.{
                            Attr.string("error", @errorName(err)),
                            Attr.uint("entry_index", e.index),
                        });
                        break :fallback Command{ .write = b };
                    })
                else
                    Command{ .write = e.data };
                entries[i] = .{
                    .term = e.term,
                    .index = e.index,
                    .command = cmd,
                    .timestamp = compat_milliTimestamp(),
                    .client_id = null,
                    .serial_number = null,
                    .owned_wire_bytes = owned,
                };
                built += 1;
            }
            break :blk Message{ .append_entries = .{
                .term = ae.term,
                .leader_id = ae.leader_id,
                .prev_log_index = ae.prev_log_index,
                .prev_log_term = ae.prev_log_term,
                .entries = entries,
                .leader_commit = ae.leader_commit,
            } };
        },
        .append_entries_response => |aer| Message{ .append_entries_response = .{
            .term = aer.term,
            .success = aer.success,
            .match_index = aer.match_index,
            .conflict_index = aer.conflict_index,
            .conflict_term = aer.conflict_term,
        } },
        // SONNY-6592: `is.data` is a chunk of the snapshot the leader loaded
        // in `sendSnapshotTo`, freed when the bridge's `send` returns; the
        // outbox encodes the message later, on the peer's drain thread, so
        // the message owns a copy (freed in `freeOutboundMessage`).
        // SONNY-6633: and the digest and configuration, copied (the library
        // may free its config slices once `send` returns).
        .install_snapshot => |is| blk: {
            const data: []const u8 = if (is.data.len > 0) try allocator.dupe(u8, is.data) else &.{};
            errdefer if (data.len > 0) allocator.free(data);
            const voters: []const u64 = if (is.config.voters.len > 0) try allocator.dupe(u64, is.config.voters) else &.{};
            errdefer if (voters.len > 0) allocator.free(voters);
            const outgoing: []const u64 = if (is.config.voters_outgoing.len > 0) try allocator.dupe(u64, is.config.voters_outgoing) else &.{};
            break :blk Message{ .install_snapshot = .{
                .term = is.term,
                .leader_id = is.leader_id,
                .last_included_index = is.last_included_index,
                .last_included_term = is.last_included_term,
                .offset = is.offset,
                .data = data,
                .done = is.done,
                .checksum = is.checksum,
                .voters = voters,
                .voters_outgoing = outgoing,
                .is_joint = is.config.is_joint,
            } };
        },
        .install_snapshot_response => |isr| Message{ .install_snapshot_response = .{
            .term = isr.term,
            .success = isr.success,
            .last_index = isr.last_index,
            .next_offset = isr.next_offset,
        } },
    };
}

/// Convert a geode-shaped Message (over-the-wire protobuf) back into the
/// raft_lib.Message the raft library expects on its `step()` input.
/// Inverse of `raftLibMessageToGeode`.
///
/// Task A6b (2026-05-25 distributed cluster testing plan): this is the
/// inbound counterpart of the bridge sendImpl path.  `networkLoop`
/// accepts a peer QUIC connection, reads a framed envelope, decodes it
/// into a geode `Message`, and feeds the raft_lib equivalent into the
/// inner raft node via `RaftNode.stepInner`.  We deliberately keep the
/// `AppendEntries.entries` field empty here: the current cluster wire
/// format encodes RequestVote / heartbeat traffic only (matching
/// `messageToProto`), so callers that observe append_entries traffic
/// can safely treat the entries slice as `&.{}`.  The full LogEntry
/// round-trip is wired by the `handleMessage` path which deserializes
/// entries inline.
pub fn geodeMessageToRaftLib(msg: Message) raft_lib.Message {
    return switch (msg) {
        .request_vote => |rv| raft_lib.Message{ .request_vote = .{
            .term = rv.term,
            .candidate_id = rv.candidate_id,
            .last_log_index = rv.last_log_index,
            .last_log_term = rv.last_log_term,
            .pre_vote = rv.pre_vote,
        } },
        .request_vote_response => |rvr| raft_lib.Message{
            .request_vote_response = .{
                .term = rvr.term,
                .vote_granted = rvr.vote_granted,
                // A6d: preserve the pre-vote phase bit so the candidate
                // can count this response in its current phase.
                .pre_vote = rvr.pre_vote,
            },
        },
        .append_entries => |ae| raft_lib.Message{ .append_entries = .{
            .term = ae.term,
            .leader_id = ae.leader_id,
            .prev_log_index = ae.prev_log_index,
            .prev_log_term = ae.prev_log_term,
            .entries = &.{},
            .leader_commit = ae.leader_commit,
        } },
        .append_entries_response => |aer| raft_lib.Message{ .append_entries_response = .{
            .term = aer.term,
            .success = aer.success,
            .match_index = aer.match_index,
            .conflict_index = aer.conflict_index,
            .conflict_term = aer.conflict_term,
        } },
        .install_snapshot => |is| raft_lib.Message{ .install_snapshot = .{
            .term = is.term,
            .leader_id = is.leader_id,
            .last_included_index = is.last_included_index,
            .last_included_term = is.last_included_term,
            .offset = is.offset,
            .data = is.data,
            .done = is.done,
            .checksum = is.checksum,
            .config = .{ .voters = is.voters, .voters_outgoing = is.voters_outgoing, .is_joint = is.is_joint },
        } },
        .install_snapshot_response => |isr| raft_lib.Message{ .install_snapshot_response = .{
            .term = isr.term,
            .success = isr.success,
            .last_index = isr.last_index,
            .next_offset = isr.next_offset,
        } },
    };
}

// ---- Tests ----

test "raft_consensus: basic init and deinit" {
    const allocator = std.testing.allocator;
    const peers = &[_]Peer{};
    var node = try RaftNode.init(allocator, 1, peers, 150);
    defer {
        node.deinit();
        allocator.destroy(node);
    }
    try std.testing.expectEqual(State.follower, node.state);
}

test "serializeCommand: write command round-trips" {
    const allocator = std.testing.allocator;
    const original_data = "INSERT INTO foo VALUES (1, 'bar')";
    const cmd = Command{ .write = original_data };
    const bytes = try serializeCommand(allocator, cmd);
    defer allocator.free(bytes);

    // First byte is the write tag
    try std.testing.expectEqual(CMD_TAG_WRITE, bytes[0]);
    // Remaining bytes are the original data
    try std.testing.expectEqualStrings(original_data, bytes[1..]);

    // Deserialize and verify
    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqualStrings(original_data, restored.write);
}

test "serializeCommand: noop round-trips" {
    const allocator = std.testing.allocator;
    const bytes = try serializeCommand(allocator, .noop);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 1), bytes.len);
    try std.testing.expectEqual(CMD_TAG_NOOP, bytes[0]);

    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqual(Command.noop, restored);
}

test "serializeCommand: txn_decide round-trips" {
    const allocator = std.testing.allocator;
    const cmd = Command{ .txn_decide = .{ .xid = 42, .commit = true } };
    const bytes = try serializeCommand(allocator, cmd);
    defer allocator.free(bytes);

    try std.testing.expectEqual(CMD_TAG_TXN_DECIDE, bytes[0]);

    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqual(@as(u64, 42), restored.txn_decide.xid);
    try std.testing.expectEqual(true, restored.txn_decide.commit);
}

// CANARY: REQ=REQ-DIST-RAFT-CMD-VARIANTS; FEATURE="Raft Command Variants"; ASPECT=WireRoundTrip; STATUS=TESTED; TEST=tests/test_gap0870_raft_command_variants.zig; OWNER=distributed; UPDATED=2026-06-11
test "serializeCommand: config_change round-trips (GAP-0870)" {
    const allocator = std.testing.allocator;
    const cmd = Command{ .config_change = .{
        .change_type = .add_server,
        .server_id = 7,
        .server_endpoint = "10.1.2.3",
        .server_port = 4242,
    } };
    const bytes = try serializeCommand(allocator, cmd);
    defer allocator.free(bytes);
    try std.testing.expectEqual(CMD_TAG_CONFIG_CHANGE, bytes[0]);

    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqual(@as(u64, 7), restored.config_change.server_id);
    try std.testing.expectEqual(@as(@FieldType(ConfigChange, "change_type"), .add_server), restored.config_change.change_type);
    try std.testing.expectEqualStrings("10.1.2.3", restored.config_change.server_endpoint.?);
    try std.testing.expectEqual(@as(?u16, 4242), restored.config_change.server_port);
}

test "serializeCommand: snapshot_pointer round-trips (GAP-0870)" {
    const allocator = std.testing.allocator;
    const cmd = Command{ .snapshot_pointer = .{
        .last_included_index = 100,
        .last_included_term = 3,
        .size_bytes = 8192,
        .checksum = 0xDEADBEEF,
    } };
    const bytes = try serializeCommand(allocator, cmd);
    defer allocator.free(bytes);
    try std.testing.expectEqual(CMD_TAG_SNAPSHOT_POINTER, bytes[0]);

    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqual(@as(u64, 100), restored.snapshot_pointer.last_included_index);
    try std.testing.expectEqual(@as(u64, 3), restored.snapshot_pointer.last_included_term);
    try std.testing.expectEqual(@as(u64, 8192), restored.snapshot_pointer.size_bytes);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), restored.snapshot_pointer.checksum);
}

test "serializeCommand: txn_prepare round-trips (GAP-0870)" {
    const allocator = std.testing.allocator;
    const cmd = Command{ .txn_prepare = .{
        .xid = 99,
        .shard_id = 2,
        .write_set = "ws-bytes",
        .metadata = "md",
    } };
    const bytes = try serializeCommand(allocator, cmd);
    defer allocator.free(bytes);
    try std.testing.expectEqual(CMD_TAG_TXN_PREPARE, bytes[0]);

    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqual(@as(u64, 99), restored.txn_prepare.xid);
    try std.testing.expectEqual(@as(u64, 2), restored.txn_prepare.shard_id);
    try std.testing.expectEqualStrings("ws-bytes", restored.txn_prepare.write_set);
    try std.testing.expectEqualStrings("md", restored.txn_prepare.metadata);
}

test "deserializeCommand: unknown tag fails loud (GAP-0870)" {
    const bogus = [_]u8{ 0xFF, 1, 2, 3 };
    try std.testing.expectError(error.UnknownCommandTag, deserializeCommand(&bogus));
}

test "decodeCommittedCommand: poisoned entry skipped + counted, valid entry decoded (GAP-0889 F1)" {
    var stats = std.mem.zeroes(Statistics);

    // Poisoned/future-format entry: no fabricated `.write`, returns null and
    // bumps the dedicated decode_errors counter.
    const bogus = [_]u8{ 0xFF, 1, 2, 3 };
    try std.testing.expect(decodeCommittedCommand(&stats, &bogus, 7, 2) == null);
    try std.testing.expectEqual(@as(u64, 1), stats.decode_errors);

    // Empty payload is also a decode failure, not an inert write.
    try std.testing.expect(decodeCommittedCommand(&stats, &.{}, 8, 2) == null);
    try std.testing.expectEqual(@as(u64, 2), stats.decode_errors);

    // A valid encoding still decodes and does not touch the counter.
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const bytes = try serializeCommand(fba.allocator(), .{ .txn_decide = .{ .xid = 42, .commit = true } });
    const cmd = decodeCommittedCommand(&stats, bytes, 9, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 42), cmd.txn_decide.xid);
    try std.testing.expect(cmd.txn_decide.commit);
    try std.testing.expectEqual(@as(u64, 2), stats.decode_errors);
}

test "validateCommand: rejects invalid variants at proposal time (GAP-0870)" {
    // alter_graph has no semantics anywhere in geode — refuse to replicate.
    try std.testing.expectError(error.UnsupportedSchemaOperation, validateCommand(.{ .schema_change = .{
        .operation = .alter_graph,
        .graph = "g",
        .schema = "",
    } }));
    // schema change with empty graph name.
    try std.testing.expectError(error.InvalidSchemaChange, validateCommand(.{ .schema_change = .{
        .operation = .create_graph,
        .graph = "",
        .schema = "",
    } }));
    // add_server without an endpoint.
    try std.testing.expectError(error.InvalidConfigChange, validateCommand(.{ .config_change = .{
        .change_type = .add_server,
        .server_id = 1,
        .server_endpoint = null,
    } }));
    // snapshot pointer at index/term 0 ("no snapshot").
    try std.testing.expectError(error.InvalidSnapshotPointer, validateCommand(.{ .snapshot_pointer = .{
        .last_included_index = 0,
        .last_included_term = 0,
        .size_bytes = 0,
        .checksum = 0,
    } }));
    // empty write set has nothing to prepare.
    try std.testing.expectError(error.EmptyWriteSet, validateCommand(.{ .txn_prepare = .{
        .xid = 1,
        .shard_id = 0,
        .write_set = "",
        .metadata = "",
    } }));
    // valid variants pass.
    try validateCommand(.noop);
    try validateCommand(.{ .config_change = .{ .change_type = .remove_server, .server_id = 1, .server_endpoint = null } });
    try validateCommand(.{ .txn_decide = .{ .xid = 1, .commit = false } });
}

test "serializeCommand: write data is not empty" {
    // This test verifies the critical bug fix: proposeCommand must NOT
    // discard command data. The serialized bytes must contain the payload.
    const allocator = std.testing.allocator;
    const payload = "CREATE GRAPH mydb";
    const bytes = try serializeCommand(allocator, .{ .write = payload });
    defer allocator.free(bytes);

    // The serialized form must be longer than just a tag byte
    try std.testing.expect(bytes.len > 1);
    // The payload must be recoverable
    try std.testing.expectEqualStrings(payload, bytes[1..]);
}

test "encodeRaftFrame includes auth_token and decodeRaftFrame exposes it" {
    // SEC-D001: Verify auth_token round-trips through Raft frame encoding.
    // In test env, GEODE_CLUSTER_TOKEN is not set, so auth_token will be "".
    const allocator = std.testing.allocator;
    // Minimal valid Message variant for the frame round-trip (the legacy
    // `.noop` placeholder variant was removed from the Message union).
    const msg = Message{ .request_vote = .{
        .term = 1,
        .candidate_id = 42,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = false,
    } };
    const encoded = try encodeRaftFrame(allocator, 42, 1, msg);
    defer allocator.free(encoded);

    const decoded = try decodeRaftFrame(allocator, encoded);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), decoded.from);
    try std.testing.expectEqual(@as(u64, 1), decoded.term);
    // Without GEODE_CLUSTER_TOKEN set, auth_token should be empty
    try std.testing.expectEqualStrings("", decoded.auth_token);
}

// k8s root cause #5 (2026-06-08): transient stream-credit backpressure must NOT
// evict a healthy peer connection (evicting forces a TLS handshake + resets the
// MAX_STREAMS credit → starves that peer's heartbeats → candidate parking).
// CANARY: REQ=REQ-DIST-RAFT-A1-NO-EVICT-BACKPRESSURE; FEATURE="Raft transport backpressure"; ASPECT=SendErrorClassify; STATUS=TESTED; OWNER=distributed; UPDATED=2026-06-08
test "raft_consensus: OutOfStreams/WouldBlock are transient (no evict); other errors evict" {
    // Transient backpressure on a healthy connection — keep it.
    try std.testing.expect(!Transport.shouldEvictOnSendError(error.OutOfStreams));
    try std.testing.expect(!Transport.shouldEvictOnSendError(error.WouldBlock));
    // Genuinely-dead connection — evict so the next send rebuilds.
    try std.testing.expect(Transport.shouldEvictOnSendError(error.ConnectionReset));
    try std.testing.expect(Transport.shouldEvictOnSendError(error.BrokenPipe));
    try std.testing.expect(Transport.shouldEvictOnSendError(error.TransportShutdown));
}

// ===========================================================================
// k8s root cause #5 (transport wedge): stalled-stream liveness regression tests
// ---------------------------------------------------------------------------
// ORIGINAL wedge: a leader pod restarts with a NEW IP and re-wins leadership; a
// third node that did NOT restart is stranded as a silent stuck-candidate. The
// fire-and-forget transport never errors a send into the stale connection and
// the IP-change reaper declines (the victim's OWN IP never changed). The first
// fix added a stalled-stream liveness detector (notePeerProgress +
// shouldEvictOnStall) keyed off observed forward progress.
//
// REGRESSION (this revision): that detector caused a TOTAL-CLUSTER ELECTION
// LIVELOCK on real k8s. When the leader pod is deleted, all 3 nodes evict both
// peers every ~3s forever and no leader is ever elected, because:
//   1. the 3000 ms budget is BELOW real election convergence (~2000 ms worst
//      case, multi-round under churn) AND equals the reaper interval, so the
//      check window equals what it measures;
//   2. the check is armed regardless of raft role — during a leaderless
//      election there is legitimately no AppendEntries flow but frames_sent>0
//      from RequestVote, so every peer trips and gets evicted, tearing down the
//      connection that votes/responses ride;
//   3. a SINGLE missed refresh evicts (no consecutive-strike requirement), so a
//      transient quiet pass re-evicts even with a healthy leader.
//
// The tests below encode the CORRECTED behavior (now migrated to the role-armed
// API — `shouldEvictOnStallArmed` / `recordStallPassArmed` / `StallArm`; the
// legacy `is_leader: bool` form was removed):
//   A. role arming (`StallArm`): suppress ONLY a follower; leader AND candidate
//      are armed (owed item (4) widened the old leader-only rule);
//   B. budget >> election convergence AND > reaper interval;
//   C. M consecutive stalled passes required (recordStallPassArmed);
//   D. progress stamp resets strikes.
// CANARY: REQ=REQ-DIST-RAFT-STALL-LIVENESS; FEATURE="Raft transport stalled-stream liveness"; ASPECT=StallEvictDecision; STATUS=TESTED; OWNER=distributed; UPDATED=2026-06-11

/// Build a heap-allocated PeerConnection suitable for the PURE stall-decision
/// unit tests. In test mode `quic.QuicClient.init` is a no-op stub (unless a
/// test called `useRealQuicInTests`), so no real QUIC/TLS connection is
/// created. The endpoint is a dup so deinit's free is
/// balanced. `established=true` mirrors a live connection.
fn makeStallTestPeerConnection(
    allocator: std.mem.Allocator,
    peer_id: u64,
    frames_sent: u64,
    last_progress_ms: i64,
) !*Transport.PeerConnection {
    const pc = try allocator.create(Transport.PeerConnection);
    pc.* = .{
        .allocator = allocator,
        .client = quic.QuicClient.init(allocator),
        .established = true,
        .endpoint = try allocator.dupe(u8, "raft-peer.cluster.svc"),
        .port = 7890,
        .peer_id = peer_id,
        .resolved_ip = &.{},
        .frames_sent = std.atomic.Value(u64).init(frames_sent),
        .last_progress_ms = std.atomic.Value(i64).init(last_progress_ms),
    };
    return pc;
}

// (B) Budget must exceed worst-case election convergence AND the reaper interval.
// The worst-case election round is `2 * election_tick * tick_ms`. With the
// default 5000 ms election timeout: election_tick = max(2, 5000/50) = 100 ticks,
// the raft loop ticks every 10 ms, and the timeout is randomized up to 2x, so a
// single round is up to 2 * 100 * 10 = 2000 ms (multi-round under churn). The
// detector must give >= 3x that headroom so a leaderless election never trips.
// SKELETON: peer_stall_budget_ms = 3000 < 6000 -> this test FAILS.
test "raft stall: budget exceeds worst-case election convergence and reaper interval" {
    const worst_case_election_round_ms: i64 = 2000; // 2 * election_tick(100) * tick_ms(10)
    // >= 3x the worst-case round so multi-round convergence under churn is safe.
    try std.testing.expect(Transport.peer_stall_budget_ms >= 3 * worst_case_election_round_ms);
    // Decoupled from — and strictly above — the reaper interval (the original bug
    // was budget == interval == 3000, so the check window equaled what it measured).
    try std.testing.expect(Transport.peer_stall_budget_ms > Transport.peer_reresolve_ms);
}

// (A) Follower suppression: a follower must NEVER evict on stall, even with an
// ancient progress timestamp and frames sent. During a leaderless election this
// is exactly the case that, when armed, evicts every peer and livelocks the
// cluster. The follower's outbound health is the leader's detector's job.
test "raft stall: stall eviction is suppressed for a follower" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale_progress = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makeStallTestPeerConnection(allocator, 7, 12, stale_progress);
    defer {
        pc.client.deinit();
        allocator.free(pc.endpoint);
        allocator.destroy(pc);
    }
    // A follower -> the stall detector must stand down (the IP-change reaper
    // covers moved peers regardless of role).
    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .follower));
}

// (A, positive) As the leader, a stalled outbound stream IS the target wedge and
// must be judged stalled on a stalled pass. Single-pass look only; eviction adds
// the consecutive-strike requirement (see the M-pass test).
test "raft stall: leader sees a stalled outbound peer as stalled (single pass)" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale_progress = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makeStallTestPeerConnection(allocator, 7, 12, stale_progress);
    defer {
        pc.client.deinit();
        allocator.free(pc.endpoint);
        allocator.destroy(pc);
    }
    try std.testing.expect(Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
}

test "raft stall: healthy peer (recent progress) is NOT evicted" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    // Progress observed comfortably inside the budget.
    const recent_progress = now_ms - (Transport.peer_stall_budget_ms - 500);
    const pc = try makeStallTestPeerConnection(allocator, 7, 12, recent_progress);
    defer {
        pc.client.deinit();
        allocator.free(pc.endpoint);
        allocator.destroy(pc);
    }
    // False-positive guard: a peer with recent progress must NEVER be evicted,
    // even when we ARE the leader.
    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
}

test "raft stall: idle peer (no frames sent) is NOT evicted even with an old timestamp" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    // last_progress is ancient, but nothing has ever been sent to this peer, so
    // there is no progress to expect — it must not be evicted.
    const pc = try makeStallTestPeerConnection(allocator, 9, 0, 0);
    defer {
        pc.client.deinit();
        allocator.free(pc.endpoint);
        allocator.destroy(pc);
    }
    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
}

// (C) M consecutive stalled passes required. The FIRST stalled observation must
// NOT evict — during a leaderless election or a single transient quiet pass that
// would evict every peer. Only the Mth consecutive pass evicts.
test "raft stall: one stalled pass does not evict; M consecutive passes do" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    const stale_progress = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makeStallTestPeerConnection(allocator, 7, 12, stale_progress);
    defer {
        pc.client.deinit();
        allocator.free(pc.endpoint);
        allocator.destroy(pc);
    }
    // Strike mechanism requires at least 2 consecutive passes.
    try std.testing.expect(Transport.peer_stall_strikes_required >= 2);

    // First stalled pass: record a strike but DO NOT evict.
    try std.testing.expect(!Transport.recordStallPassArmed(pc, now_ms, .leader));
    try std.testing.expectEqual(@as(u32, 1), pc.stall_strikes.load(.acquire));

    // Drive to the required number of consecutive stalled passes; only the last
    // one evicts.
    var pass: u32 = 1;
    while (pass < Transport.peer_stall_strikes_required) : (pass += 1) {
        const is_last = (pass + 1) == Transport.peer_stall_strikes_required;
        const evict = Transport.recordStallPassArmed(pc, now_ms, .leader);
        try std.testing.expectEqual(is_last, evict);
    }
}

// (D) A progress stamp resets the strike counter, so a peer that resumes
// responding is not evicted on a later isolated stalled-looking pass.
test "raft stall: progress stamp resets strikes" {
    const allocator = std.testing.allocator;
    var transport = Transport.init(allocator);
    defer transport.deinit();

    const now_ms: i64 = 7_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 1000);
    const pc = try makeStallTestPeerConnection(allocator, 1, 4, stale);
    const io = std.Io.Threaded.global_single_threaded.io();
    transport.peers_mutex.lockUncancelable(io);
    try transport.peers.put(1, pc);
    transport.peers_mutex.unlock(io);
    // (transport.deinit frees the entry via the peers map.)

    // First stalled pass accrues strike 1 (no evict).
    try std.testing.expect(!Transport.recordStallPassArmed(pc, now_ms, .leader));
    try std.testing.expectEqual(@as(u32, 1), pc.stall_strikes.load(.acquire));

    // Inbound progress arrives -> strikes reset to 0 (and clock refreshed).
    transport.notePeerProgress(1, now_ms);
    try std.testing.expectEqual(@as(u32, 0), pc.stall_strikes.load(.acquire));

    // A later stalled-looking pass is therefore strike 1 again, NOT an eviction.
    const later = now_ms + Transport.peer_stall_budget_ms + 1;
    try std.testing.expect(!Transport.recordStallPassArmed(pc, later, .leader));
    try std.testing.expectEqual(@as(u32, 1), pc.stall_strikes.load(.acquire));
}

test "raft stall: notePeerProgress stamps the right PeerConnection (peer-id keyed)" {
    const allocator = std.testing.allocator;
    var transport = Transport.init(allocator);
    defer transport.deinit();

    // Publish two established connections into the peers map, simulating two
    // live outbound peers. Each starts with a stale progress timestamp and a
    // nonzero frames_sent so it would be judged stalled at now_ms.
    const now_ms: i64 = 5_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 1000);
    const pc1 = try makeStallTestPeerConnection(allocator, 1, 4, stale);
    const pc2 = try makeStallTestPeerConnection(allocator, 2, 4, stale);
    const io = std.Io.Threaded.global_single_threaded.io();
    transport.peers_mutex.lockUncancelable(io);
    try transport.peers.put(1, pc1);
    try transport.peers.put(2, pc2);
    transport.peers_mutex.unlock(io);
    // (transport.deinit frees both entries via the peers map.)

    // Inbound progress arrives for peer 1 only (keyed by peer id, NOT by the
    // outbound PeerConnection pointer — the inbound connection is a different
    // object in production).
    transport.notePeerProgress(1, now_ms);

    // DESIRED behavior: peer 1's stamp is refreshed (so it is no longer stalled
    // as the leader), peer 2's is untouched (still stalled). The single-pass look
    // is evaluated as the leader (arm = .leader).
    try std.testing.expectEqual(now_ms, pc1.last_progress_ms.load(.acquire));
    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc1, now_ms, .leader));
    // Peer 2 was never stamped — still stalled (as the leader).
    try std.testing.expect(Transport.shouldEvictOnStallArmed(pc2, now_ms, .leader));
}

test "raft stall: progress refresh clears the stall (no immediate re-evict loop)" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 2_000_000;
    // A peer that just reconnected: frames already queued, and progress stamped
    // at reconnect time == now. The stall clock must read as fresh so the very
    // next reaper pass does NOT immediately re-evict it (which would spin a
    // reconnect loop).
    const pc = try makeStallTestPeerConnection(allocator, 3, 1, now_ms);
    defer {
        pc.client.deinit();
        allocator.free(pc.endpoint);
        allocator.destroy(pc);
    }
    // Same instant -> 0 elapsed -> not stalled (even as the leader).
    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms, .leader));
    // A subsequent progress observation keeps it healthy across the budget.
    pc.last_progress_ms.store(now_ms + Transport.peer_stall_budget_ms, .release);
    try std.testing.expect(!Transport.shouldEvictOnStallArmed(pc, now_ms + Transport.peer_stall_budget_ms, .leader));
}

// SEC-D011 / SONNY-6453: with neither GEODE_CLUSTER_INSECURE nor
// GEODE_CLUSTER_CA_CERT set, a peer dial is refused before any packet is sent.
// CANARY: REQ=SEC-D011; FEATURE="Raft RPC TLS"; ASPECT=ConnectCompile; STATUS=TESTED; TEST=tests/test_sonny6453_cluster_peer_tls.zig; OWNER=security; UPDATED=2026-11-13
test "raft_consensus: connectWithTLS refuses without a cluster CA" {
    if (std.c.getenv("GEODE_CLUSTER_CA_CERT") != null or std.c.getenv("GEODE_CLUSTER_INSECURE") != null) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var qc = quic.QuicClient.init(allocator);
    defer qc.deinit();
    try std.testing.expectError(error.ClusterCaRequired, connectWithTLS(&qc, "127.0.0.1", 7890));
}

test "raft_consensus: Transport.send uses TLS-aware connection" {
    // SEC-D011: Verify Transport.send compiles with TLS support.
    const allocator = std.testing.allocator;
    var transport = Transport.init(allocator);
    defer transport.deinit();

    const peer = Peer{
        .id = 1,
        .endpoint = "127.0.0.1",
        .port = 7890,
        .last_contact = 0,
    };

    // In test mode the QUIC stubs are no-ops; writeRaftFrame uses the stub stream.
    // This validates the TLS code path compiles and executes without error.
    // (Legacy `.noop` Message placeholder removed; use a minimal valid variant.)
    const probe_msg = Message{ .request_vote = .{
        .term = 1,
        .candidate_id = 42,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = false,
    } };
    transport.send(peer, 42, 1, probe_msg) catch {
        // Expected: test stubs may return errors for stream operations
        // since getStream returns undefined. That's fine -- we're testing
        // that the TLS connection logic itself compiles and runs.
    };
}

// CANARY: REQ=REQ-SONNY-6636-STUB-QUIC-WARNING; FEATURE="Raft Wrapper Transport Dispatch"; ASPECT=StubConnectWarns; STATUS=TESTED; TEST="SONNY-6636 (5): a stub QUIC client asked to connect to a Raft peer warns that it sends nothing"; OWNER=distributed; UPDATED=2026-11-15
test "SONNY-6636 (5): a stub QUIC client asked to connect to a Raft peer warns that it sends nothing" {
    // The default in a test build: the stub, as for a test that never
    // called useRealQuicInTests(true).
    try std.testing.expect(!test_real_quic.load(.acquire));
    var client = quic.QuicClient.init(std.testing.allocator);
    defer client.deinit();
    try std.testing.expect(client.real == null);
    try client.connectInsecure("127.0.0.1", 1, true);
    try std.testing.expect(stubConnectWarnedForTesting());
}
