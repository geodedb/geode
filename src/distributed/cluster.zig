const std = @import("std");

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

// Zig 0.16 compat: std.Thread.sleep was removed; use raw linux nanosleep.
fn compat_sleepNs(ns: u64) void {
    if (comptime @import("builtin").os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    } else {
        // POSIX fallback via libc nanosleep.
        const req = std.c.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const Allocator = std.mem.Allocator;
const raft_consensus = @import("raft_consensus.zig");
const RaftNode = raft_consensus.RaftNode;
const graph_store = @import("../graph_store.zig");
const dist_schema = @import("distributed_schema");
const protobuf = @import("protobuf");
const fd = protobuf.fd;
const quic = @import("transport/quic");
const pooled = @import("transport/thread_pool");
const NonceTracker = @import("nonce_tracker.zig").NonceTracker;

const cluster_auth = @import("cluster_auth.zig");
const raft_apply = @import("raft_apply.zig");
const cluster_replication = @import("cluster_replication.zig");

const logging = @import("logging");
const log = logging.scoped("cluster");
const Attr = logging.Attr;

pub const cluster_health = @import("cluster_health.zig");
pub const HealthMonitor = cluster_health.HealthMonitor;

// CANARY: REQ=REQ-DIST-SHOW-CLUSTER-STATUS; FEATURE="SHOW CLUSTER STATUS"; ASPECT=GlobalCoordinatorHandle; STATUS=TESTED; TEST=tests/test_show_cluster_status.zig; OWNER=distributed; UPDATED=2026-05-26
// ---------------------------------------------------------------------------
// Global ClusterCoordinator handle.
//
// Set by `cluster_bootstrap.maybeStart` after `ClusterCoordinator.init`
// succeeds; cleared by `Bootstrap.deinit`.  The execution layer reads this
// via `getGlobalClusterCoordinator()` to populate `SHOW CLUSTER STATUS` rows
// without taking a direct compile-time dependency on the distributed module
// (`src/execution/admin_ddl.zig` would otherwise create a layering cycle).
//
// Null means "standalone mode" — no cluster wired.  In that case the SHOW
// handler returns a single synthetic row with role=standalone instead of
// failing.
// ---------------------------------------------------------------------------

var g_cluster_coordinator: ?*ClusterCoordinator = null;

pub fn setGlobalClusterCoordinator(c: *ClusterCoordinator) void {
    g_cluster_coordinator = c;
}

/// Clear the global pointer.  Called on shutdown (or in tests) to prevent
/// dangling references into freed coordinator memory.
pub fn clearGlobalClusterCoordinator() void {
    g_cluster_coordinator = null;
}

pub fn getGlobalClusterCoordinator() ?*ClusterCoordinator {
    return g_cluster_coordinator;
}

/// Fail-closed gate for durable write surfaces that have NO Raft replication
/// slice (timeseries ingest, auth/policy/tenant/index/graph/constraint DDL,
/// TDE/CDC/FLE). In cluster mode these writes would land on exactly one node
/// and silently diverge — so they are refused loudly instead. Standalone mode
/// is unaffected.
///
/// Mirrors the role semantics of `clusterWriteRole()`
/// (src/execution/crud_operations.zig): no coordinator → standalone (allowed,
/// unchanged local path); non-leader → `error.ClusterNotLeader` (clients retry
/// against the leader); leader → `error.ClusterWriteNotReplicable` because the
/// surface has no replication slice — applying it leader-local would diverge.
// CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=GateHelper; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
pub fn gateUnreplicatedWrite() error{ ClusterNotLeader, ClusterWriteNotReplicable }!void {
    const coord = getGlobalClusterCoordinator() orelse return; // standalone: allowed
    if (coord.role() != .leader) return error.ClusterNotLeader;
    return error.ClusterWriteNotReplicable;
}

// ===========================================================================
// k8s churn recovery, ROOT CAUSE #1 (RC1): receiver-side worker-pool starvation.
// ---------------------------------------------------------------------------
// Each inbound cluster connection runs a long-lived `handleQuicConnection` task
// on the fixed 4-thread `connection_pool`. For a half-open / zombie peer
// connection the accept loop NEVER exits: `acceptStream()` returns
// `error.WouldBlock`, the handler parks and `continue`s forever until the
// ~300 s QUIC idle timeout finally tears the connection down. After a few rapid
// pod kills the zombie inbound connections pin all 4 worker threads, so REBUILT
// outbound connections from peers are never serviced — vote/heartbeat delivery
// is dead no matter what the sender does, and the cluster wedges all-candidate
// at a frozen term.
//
// FIX: the inbound-connection handler REAPS an idle connection and releases its
// worker after a bounded inactivity deadline (default ~30 s, env-overridable via
// GEODE_CLUSTER_INBOUND_IDLE_MS), far below the ~300 s QUIC idle timeout.
// "Activity" = any accepted stream or successfully dispatched frame; the handler
// stamps a `last_activity_ms` on each. The reap decision is a PURE,
// unit-testable function (fake clock), mirroring the stall-detector decision
// functions in raft_consensus.zig.
// ===========================================================================

/// Default idle deadline (ms) after which an inbound cluster connection with no
/// observed activity is reaped and its worker thread released. ~30 s: far below
/// the ~300 s QUIC idle timeout (the whole point), but large enough not to churn
/// a healthy-but-quiet peer (heartbeats keep a live link active well within it).
// CANARY: REQ=REQ-DIST-CLUSTER-INBOUND-REAP; FEATURE="DistributedCluster"; ASPECT=InboundIdleDeadline; STATUS=TESTED; TEST=tests/test_raft_receiver_reap.zig; OWNER=distributed; UPDATED=2026-06-12
pub const inbound_connection_idle_deadline_ms: i64 = 30_000;

/// PURE: true iff we have observed NO activity on an inbound cluster connection
/// for longer than `deadline_ms`. Strict `>` so exactly-at-deadline does NOT
/// reap (one extra reaper tick of grace).
// CANARY: REQ=REQ-DIST-CLUSTER-INBOUND-REAP; FEATURE="DistributedCluster"; ASPECT=ShouldReapIdleInbound; STATUS=TESTED; TEST=tests/test_raft_receiver_reap.zig; OWNER=distributed; UPDATED=2026-06-12
pub fn shouldReapIdleInboundConnection(now_ms: i64, last_activity_ms: i64, deadline_ms: i64) bool {
    return (now_ms - last_activity_ms) > deadline_ms;
}

/// PURE: resolve the effective idle deadline from an optional env override
/// (GEODE_CLUSTER_INBOUND_IDLE_MS). A null / empty / non-numeric / non-positive
/// value falls back to the default. Kept pure (takes the raw string, returns ms)
/// so it is testable without touching the real env.
// CANARY: REQ=REQ-DIST-CLUSTER-INBOUND-REAP; FEATURE="DistributedCluster"; ASPECT=ResolveInboundIdleDeadline; STATUS=TESTED; TEST=tests/test_raft_receiver_reap.zig; OWNER=distributed; UPDATED=2026-06-12
pub fn resolveInboundIdleDeadlineMs(env_value: ?[]const u8) i64 {
    const raw = env_value orelse return inbound_connection_idle_deadline_ms;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return inbound_connection_idle_deadline_ms;
    const parsed = std.fmt.parseInt(i64, trimmed, 10) catch return inbound_connection_idle_deadline_ms;
    if (parsed <= 0) return inbound_connection_idle_deadline_ms;
    return parsed;
}

// ===========================================================================
// k8s churn recovery, ROOT CAUSE A (RC-A): AGGREGATE inbound-pool occupancy
// starvation in the receiver.
// ---------------------------------------------------------------------------
// RC1 (above) reaps a SINGLE idle connection from inside its own pinned worker
// loop, stamping the idle clock at WORKER-ACQUISITION time. That leaves an
// aggregate gap: under 3 back-to-back 4-kill churn rounds, zombie half-open
// inbound conns arrive faster than the serialized 4-wide × 30 s-each drain can
// clear them. A QUEUED zombie never starts its reap clock (it never acquired a
// worker), pool occupancy stays ≥ 4 across rounds (the A→B→C monotonic-
// degradation signature), and the only path to `raft.handleMessage` starves for
// 87–180 s+. The node can't hear the leader's AppendEntries → it strands as a
// candidate at the quorum's term (the lib's only same-term step-down is an
// inbound AE).
//
// FIX: (a) every accepted inbound conn's idle clock starts at ACCEPT time, not
// at worker acquisition; and (b) an INDEPENDENT sweeper (running off the
// health loop, not a victim's own worker) reaps idle zombies — queued AND
// pinned — so a fresh ACTIVE conn (the leader's rebuilt conn carrying current-
// term AppendEntries) is serviced within a bounded budget well under one
// election timeout. The aggregate decision is a PURE, unit-testable function
// (injected clock + injected per-conn accept/last-activity timestamps), a
// sibling to `shouldReapIdleInboundConnection`.
// ===========================================================================

/// One inbound connection's liveness snapshot for the aggregate RC-A decision.
/// `accepted_ms` is stamped at ACCEPT time (the RC-A fix — NOT at worker
/// acquisition); `last_activity_ms` is the most recent stream/frame activity
/// (== accepted_ms until the conn does anything). A "zombie" is a conn whose
/// last_activity is older than the idle deadline measured from NOW.
// CANARY: REQ=REQ-DIST-CLUSTER-INBOUND-OCCUPANCY; FEATURE="DistributedCluster"; ASPECT=InboundConnSnapshot; STATUS=TESTED; TEST=tests/test_raft_inbound_pool_occupancy.zig; OWNER=distributed; UPDATED=2026-06-12
pub const InboundConnSnapshot = struct {
    accepted_ms: i64,
    last_activity_ms: i64,
};

/// The bounded service budget for a fresh ACTIVE inbound conn under churn — MUST
/// be well under one election timeout (so a rebuilt leader conn is serviced
/// before a stranded candidate's election timer fires) and far below the ~300 s
/// QUIC idle timeout it replaces as the effective recovery bound.
// CANARY: REQ=REQ-DIST-CLUSTER-INBOUND-OCCUPANCY; FEATURE="DistributedCluster"; ASPECT=FreshConnServiceBudget; STATUS=TESTED; TEST=tests/test_raft_inbound_pool_occupancy.zig; OWNER=distributed; UPDATED=2026-06-12
pub const inbound_fresh_conn_service_budget_ms: i64 = 1_000;

/// PURE: count inbound conns whose idle age (`now - last_activity`) exceeds
/// `deadline_ms` — the reap-eligible "zombies". The idle clock runs from
/// accept/last-activity, INDEPENDENT of whether the conn ever acquired a worker,
/// so a never-serviced QUEUED zombie is counted just like a pinned one. This is
/// the count the independent sweeper MUST reap this pass to free capacity.
///
/// Contract (pinned by tests/test_raft_inbound_pool_occupancy.zig):
///   * if all `workers` slots are occupied AND ≥1 zombie exists, returns ≥1
///     (never 0 while the pool is full of zombies);
///   * never counts a conn with fresh activity (idle age ≤ deadline);
///   * returns 0 when no zombie exists (healthy quiet peers are safe);
///   * never exceeds the number of actual zombies (no over-reaping of live
///     conns).
// CANARY: REQ=REQ-DIST-CLUSTER-INBOUND-OCCUPANCY; FEATURE="DistributedCluster"; ASPECT=InboundReapCountForCapacity; STATUS=TESTED; TEST=tests/test_raft_inbound_pool_occupancy.zig; OWNER=distributed; UPDATED=2026-06-12
pub fn inboundReapCountForCapacity(
    snapshots: []const InboundConnSnapshot,
    workers: usize,
    now_ms: i64,
    deadline_ms: i64,
) usize {
    _ = workers; // every stale conn is reapable regardless of slot count; a full
    // pool of zombies therefore always yields a non-zero count (the RC-A core),
    // while a pool of fresh-active conns yields 0 (genuine load is not a wedge).
    var zombies: usize = 0;
    for (snapshots) |s| {
        if (shouldReapIdleInboundConnection(now_ms, s.last_activity_ms, deadline_ms)) {
            zombies += 1;
        }
    }
    return zombies;
}

/// PURE: true iff a freshly-accepted ACTIVE conn can be serviced within
/// `budget_ms` given the current snapshot — i.e. the sweeper frees a slot in
/// time. The whole point of RC-A: this holds even when all `workers` slots are
/// pinned by zombies, because their accept-time idle clocks let the sweeper reap
/// them within one reaper tick (≪ budget). Returns false only when NON-zombie
/// (active) conns alone already saturate every worker — genuine load, not a
/// churn wedge, with nothing to reap.
// CANARY: REQ=REQ-DIST-CLUSTER-INBOUND-OCCUPANCY; FEATURE="DistributedCluster"; ASPECT=FreshActiveConnServiceableWithin; STATUS=TESTED; TEST=tests/test_raft_inbound_pool_occupancy.zig; OWNER=distributed; UPDATED=2026-06-12
pub fn freshActiveConnServiceableWithin(
    snapshots: []const InboundConnSnapshot,
    workers: usize,
    now_ms: i64,
    deadline_ms: i64,
    budget_ms: i64,
) bool {
    // A non-positive budget can never service anything in time.
    if (budget_ms <= 0) return false;

    const zombies = inboundReapCountForCapacity(snapshots, workers, now_ms, deadline_ms);
    const total = snapshots.len;
    const active = total - zombies; // conns with fresh activity (genuine load)

    // If the pool is not full of ACTIVE conns there is already free capacity (or
    // the sweeper will free it), so a fresh conn is serviceable. The only wedge
    // the sweeper cannot break is a pool fully saturated by live conns — that is
    // real load, and the fresh conn must wait in line (no live-conn reaping).
    return active < workers;
}

// ===========================================================================
// RC-1: commit-aware post-propose wait decision (pure, unit-testable)
// ===========================================================================
//
// "committed write -> client Timeout -> retry double-insert" (2026-06-12),
// root cause 1: the post-propose wait busy-polled the LOCAL apply index with a
// flat budget and returned error.Timeout for an entry that was already
// COMMITTED. Raft guarantees a committed entry applies (once, in the current
// term), so a committed-but-apply-lagged entry is NOT a replication failure —
// reporting it as Timeout is the wrong signal that drives the client retry.
//
// This is the decision factored out of the wait loop so the wrong-signal logic
// is testable without a live cluster (sibling to the stall-detector decision
// functions in raft_consensus.zig and the inbound-reap decisions above).

/// The outcome of evaluating a post-propose wait against the current
/// (committed, applied, target, budget) state.
pub const WaitOutcome = enum {
    /// applied_index >= target: the entry is applied locally — full success.
    applied,
    /// committed_index >= target but applied_index < target: the entry is
    /// COMMITTED (durably replicated to a quorum) and WILL apply; the wait must
    /// keep waiting for local apply rather than surfacing a timeout. A success
    /// class — NEVER a Timeout, even with the budget exhausted.
    committed_apply_pending,
    /// Neither committed nor applied yet, but budget remains: keep waiting.
    keep_waiting,
    /// commit could NOT be confirmed (committed_index < target) and the budget
    /// is exhausted: a genuine unknown — this node cannot confirm the write
    /// reached a quorum. The ONLY state that maps to error.Timeout.
    commit_unknown_timeout,
};

/// PURE decision over (committed_index, applied_index, target_index,
/// budget_exhausted). The truth table (RC-1 of the committed-write-Timeout fix):
///
///   | committed>=target | applied>=target | budget_exhausted | outcome                 |
///   |-------------------|-----------------|------------------|-------------------------|
///   | *                 | yes             | *                | applied                 |
///   | yes               | no              | *                | committed_apply_pending |  <- the FIX
///   | no                | no              | no               | keep_waiting            |
///   | no                | no              | yes              | commit_unknown_timeout  |
///
/// A committed entry is NEVER reported as a timeout: commit guarantees apply, so
/// once committed_index >= target the only remaining wait is for LOCAL apply.
/// error.Timeout is reserved for the genuine unknown (commit not confirmed in
/// budget).
// CANARY: REQ=REQ-DIST-CLUSTER-COMMIT-AWARE-WAIT; FEATURE="DistributedCluster"; ASPECT=CommitAwarePostProposeWait; STATUS=TESTED; TEST=tests/test_cluster_commit_aware_wait.zig; OWNER=distributed; UPDATED=2026-06-12
pub fn waitOutcomeForState(
    committed_index: u64,
    applied_index: u64,
    target_index: u64,
    budget_exhausted: bool,
) WaitOutcome {
    // Fast path: the entry is applied locally — full success regardless of budget.
    if (applied_index >= target_index) return .applied;
    // Committed but apply lagging: a success class (commit guarantees apply).
    // This is the bug fix — pre-fix this state returned Timeout once the budget
    // elapsed, the exact wrong inference that drove the client retry.
    if (committed_index >= target_index) return .committed_apply_pending;
    // Not yet committed: keep waiting while there is budget; once the budget is
    // exhausted without a confirmed commit it is a genuine unknown.
    return if (budget_exhausted) .commit_unknown_timeout else .keep_waiting;
}

// NOTE: the standalone-path unit test for gateUnreplicatedWrite lives in
// tests/test_cluster_coordinator_config.zig (named step
// test-cluster-coord-config). An inline `test` here would force analysis of
// ClusterCoordinator (via setGlobalClusterCoordinator's parameter type) in
// every unit-test module whose import closure reaches this file — and module
// roots like graph_store.zig don't map "transport/quic", breaking the sharded
// `zig build test` compile.

fn envFlagEnabled(allocator: std.mem.Allocator, name: []const u8) bool {
    const raw = getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(raw);
    if (raw.len == 0) return false;
    if (raw[0] == '0') return false;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "off")) return false;
    return true;
}

const MessageType = enum(i32) {
    READ = 0,
    WRITE = 1,
    UPDATE = 2,
    DELETE = 3,
    JOIN_CLUSTER = 4,
    LEAVE_CLUSTER = 5,
    REPLICATE_DATA = 6,
    FAILOVER_REQUEST = 7,
};

// Protobuf-encodable message for distributed operations
const Message = struct {
    msg_type: MessageType = .READ,
    key: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    data: ?[]const u8 = null,
    /// SEC-D002: Cluster authentication token for JOIN_CLUSTER and other operations.
    auth_token: []const u8 = "",

    pub const _desc_table = .{
        .msg_type = fd(1, .{ .@"enum" = {} }),
        .key = fd(2, .{ .scalar = .string }),
        .client_id = fd(3, .{ .scalar = .string }),
        .data = fd(4, .{ .scalar = .bytes }),
        .auth_token = fd(5, .{ .scalar = .string }),
    };

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const ResponseStatus = enum(i32) {
    OK = 0,
    ABORTED = 1,
    ERR = 2,
    REDIRECT = 3,
};

const Response = struct {
    status: ResponseStatus = .OK,
    data: ?[]const u8 = null,
    leader_id: ?u64 = null,

    pub const _desc_table = .{
        .status = fd(1, .{ .@"enum" = {} }),
        .data = fd(2, .{ .scalar = .bytes }),
        .leader_id = fd(3, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// ---- Cluster RPC framing (Task A3e of 2026-05-25 plan) ----
//
// Cross-node read forwarding (`forwardToShard`) uses a request/response
// protocol that shares the same intra-cluster QUIC listener as Raft
// consensus traffic.  To distinguish the two frame types on a single
// stream, every cluster RPC frame is prefixed with a 1-byte magic
// marker (`CLUSTER_RPC_MAGIC`).  Raft frames begin with a 4-byte
// big-endian length whose high byte is `0x00` for any frame under 16
// MiB, so the magic byte is unambiguous: receivers peek the first byte
// to decide whether to dispatch via `readRaftFrame` (raft) or the
// cluster RPC reader (this module).
//
// Wire format (request and response both share the same shape):
//   [1 byte: CLUSTER_RPC_MAGIC]
//   [4 bytes: big-endian payload length]
//   [N bytes: protobuf-encoded Message (request) or Response (reply)]
//
// A single bidirectional stream carries exactly one request frame
// followed by exactly one response frame written by the receiver
// before the stream is FIN'd.  This keeps the protocol lightweight
// (no request-id correlation needed) and matches the existing
// "one-frame-per-stream" idiom used by the raft transport.
const CLUSTER_RPC_MAGIC: u8 = 0xC1;
const CLUSTER_RPC_MAX_FRAME: u32 = 16 * 1024 * 1024; // 16 MiB, same as raft

/// Encode `msg` (request) or `resp` (response) into an on-wire cluster
/// RPC frame.  The caller owns the returned slice and MUST free it.
fn encodeClusterRpcFrame(allocator: Allocator, value: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, value);
    const body = aw.writer.buffer[0..aw.writer.end];
    const framed = try allocator.alloc(u8, 1 + 4 + body.len);
    framed[0] = CLUSTER_RPC_MAGIC;
    std.mem.writeInt(u32, framed[1..5], @intCast(body.len), .big);
    @memcpy(framed[5..], body);
    return framed;
}

/// Read exactly `buf.len` bytes from `stream`, polling on WouldBlock.
/// Generic over any stream type that exposes a `read([]u8) !usize`
/// method (QuicStream on the server side, QuicClientStream on the
/// client side).  Returns `error.EndOfStream` if the peer FIN'd
/// before any byte arrived, `error.UnexpectedEndOfStream` if it FIN'd
/// mid-frame, and `error.Timeout` if the per-call max retry budget
/// expires.
fn readExactCluster(stream: anytype, buf: []u8) !void {
    var read_len: usize = 0;
    var retry_count: usize = 0;
    const max_retries: usize = 1000; // ~5s at 5ms sleep
    while (read_len < buf.len) {
        const n = stream.read(buf[read_len..]) catch |err| {
            if (err == error.WouldBlock) {
                retry_count += 1;
                if (retry_count >= max_retries) return error.Timeout;
                compat_sleepNs(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) {
            if (read_len == 0) return error.EndOfStream;
            retry_count += 1;
            if (retry_count >= max_retries) return error.UnexpectedEndOfStream;
            compat_sleepNs(5 * std.time.ns_per_ms);
            continue;
        }
        read_len += n;
        retry_count = 0;
    }
}

/// Read the cluster RPC frame body that follows a `CLUSTER_RPC_MAGIC`
/// byte.  The magic byte must have already been consumed by the
/// caller (the receiver's frame-type peek); only the 4-byte length
/// and payload remain on the wire.  Returns an allocator-owned
/// payload buffer; the caller owns it and MUST free.
fn readClusterRpcBodyAfterMagic(allocator: Allocator, stream: anytype) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try readExactCluster(stream, len_buf[0..]);
    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len == 0) return error.InvalidFrame;
    if (msg_len > CLUSTER_RPC_MAX_FRAME) return error.FrameTooLarge;
    const payload = try allocator.alloc(u8, msg_len);
    errdefer allocator.free(payload);
    try readExactCluster(stream, payload);
    return payload;
}

/// Read a full cluster RPC frame (magic + length + body).  Used by
/// the request originator (`forwardToShard`) to consume the
/// response.  Returns an allocator-owned payload buffer; the caller
/// owns it and MUST free.
fn readClusterRpcFrame(allocator: Allocator, stream: anytype) ![]u8 {
    var magic_buf: [1]u8 = undefined;
    try readExactCluster(stream, magic_buf[0..]);
    if (magic_buf[0] != CLUSTER_RPC_MAGIC) return error.InvalidFrame;
    return readClusterRpcBodyAfterMagic(allocator, stream);
}

/// Adapter that prepends a single already-consumed byte to an
/// underlying stream.  Used by the inbound dispatcher to feed the
/// raft frame reader after peeking the first byte of the wire stream.
/// `Inner` must be a pointer to a type that exposes a
/// `read([]u8) !usize` method (matches both `*quic.QuicStream` and
/// `*quic.QuicClientStream`).
fn PrefixedStream(comptime Inner: type) type {
    return struct {
        inner: Inner,
        prefix: u8,
        have_prefix: bool,

        const Self = @This();

        pub fn read(self: *Self, buf: []u8) !usize {
            if (self.have_prefix and buf.len > 0) {
                buf[0] = self.prefix;
                self.have_prefix = false;
                return 1;
            }
            return self.inner.read(buf);
        }
    };
}

const ReplicationPayload = struct {
    shard_id: u64 = 0,
    snapshot: []const u8 = "",

    pub const _desc_table = .{
        .shard_id = fd(1, .{ .scalar = .uint64 }),
        .snapshot = fd(2, .{ .scalar = .bytes }),
    };

    pub fn deinit(self: *ReplicationPayload, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

/// SEC-D012: Minimal join response that does not leak full cluster topology.
const JoinResponsePayload = struct {
    assigned_node_id: u64 = 0,
    node_count: u32 = 0,
    success: bool = false,

    pub const _desc_table = .{
        .assigned_node_id = fd(1, .{ .scalar = .uint64 }),
        .node_count = fd(2, .{ .scalar = .uint32 }),
        .success = fd(3, .{ .scalar = .bool }),
    };

    pub fn deinit(_: *@This(), _: Allocator) void {}
};

/// SEC-D009: Replay protection guard for Raft frames.
const ReplayGuard = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    entries: std.AutoHashMap(u128, i64), // key = (from << 64) | term, value = timestamp
    max_entries: usize,
    window_ms: i64,

    fn init(allocator: Allocator, max_entries: usize, window_ms: i64) ReplayGuard {
        return .{
            .entries = std.AutoHashMap(u128, i64).init(allocator),
            .max_entries = max_entries,
            .window_ms = window_ms,
        };
    }

    fn deinit(self: *ReplayGuard) void {
        self.entries.deinit();
    }

    /// Returns true if this (from, term) pair is fresh (not a replay).
    fn check(self: *ReplayGuard, from: u64, term: u64) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const now = compat_milliTimestamp();
        const key: u128 = (@as(u128, from) << 64) | @as(u128, term);
        if (self.entries.get(key)) |prev_ts| {
            if (now - prev_ts < self.window_ms) return false; // replay
        }
        // Evict oldest if full
        if (self.entries.count() >= self.max_entries) {
            var oldest_key: u128 = 0;
            var oldest_ts: i64 = std.math.maxInt(i64);
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* < oldest_ts) {
                    oldest_ts = entry.value_ptr.*;
                    oldest_key = entry.key_ptr.*;
                }
            }
            _ = self.entries.remove(oldest_key);
        }
        self.entries.put(key, now) catch return true; // allow on OOM
        return true;
    }
};

const NodeInfoProto = struct {
    id: u64 = 0,
    endpoint: []const u8 = "",

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .endpoint = fd(2, .{ .scalar = .string }),
    };

    pub fn deinit(self: *NodeInfoProto, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TxnMetadata = struct {
    client_id: []const u8 = "",
    timestamp: i64 = 0,
    msg_type: MessageType = .READ,

    pub const _desc_table = .{
        .client_id = fd(1, .{ .scalar = .string }),
        .timestamp = fd(2, .{ .scalar = .int64 }),
        .msg_type = fd(3, .{ .@"enum" = {} }),
    };

    pub fn deinit(self: *TxnMetadata, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TopologyNode = struct {
    id: u64 = 0,
    endpoint: []const u8 = "",
    state: []const u8 = "",

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .endpoint = fd(2, .{ .scalar = .string }),
        .state = fd(3, .{ .scalar = .string }),
    };

    pub fn deinit(self: *TopologyNode, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TopologyShard = struct {
    id: u64 = 0,
    primary_node: u64 = 0,
    replica_count: u32 = 0,
    size_bytes: u64 = 0,

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .primary_node = fd(2, .{ .scalar = .uint64 }),
        .replica_count = fd(3, .{ .scalar = .uint32 }),
        .size_bytes = fd(4, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *TopologyShard, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TopologyPayload = struct {
    nodes: std.ArrayList(TopologyNode),
    shards: std.ArrayList(TopologyShard),

    pub const _desc_table = .{
        .nodes = fd(1, .{ .repeated = .{ .submessage = {} } }),
        .shards = fd(2, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *TopologyPayload, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// Distributed cluster coordinator
pub const ClusterCoordinator = struct {
    allocator: Allocator,
    node_id: u64,
    raft: *RaftNode,
    store: *graph_store.GraphStore,
    replication_factor: u32,
    sharding_strategy: ShardingStrategy,
    failover_config: FailoverConfig,
    cluster_state: ClusterState,
    network_transport: NetworkTransport,
    health_monitor: HealthMonitor,
    /// SEC-D009: Nonce tracker for Raft frame replay protection.
    raft_nonce_tracker: NonceTracker,
    /// SEC-D009: Replay guard for (from, term) deduplication.
    replay_guard: ReplayGuard,
    message_callback: ?*const fn (*ClusterCoordinator, *const Message) void = null,
    // PERF-D006: Connection semaphore to limit concurrent cluster threads
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Maximum simultaneous inbound peer connections (sourced from
    /// Config.max_connections at init time).  PERF-D006.
    max_connections: u32 = 100,

    // === Cluster bootstrap state (Task A3/A3b/A3c of 2026-05-25 plan) ===
    // Mirrored from Config so background loops can read them without
    // re-touching the Config struct.  All three are stored by reference;
    // the caller is responsible for keeping the backing memory alive for
    // the lifetime of the coordinator.
    /// Address `networkLoop` binds the intra-cluster listener to.
    listen_address: []const u8 = "0.0.0.0",
    /// Port `networkLoop` binds the intra-cluster listener to.
    cluster_port: u16 = 4242,
    /// Pre-shared token validated on every inbound cluster connection.
    /// Empty string disables the auth check (used by A3f).
    cluster_token: []const u8 = "",
    /// Cluster name, used for OTel attributes and operator-facing logs.
    cluster_name: []const u8 = "geode-cluster",
    /// TLS certificate path for the intra-cluster QUIC listener.  When the
    /// server-side `cert_gen` workflow places certs in `<data-dir>/server.crt`,
    /// the cluster listener needs to reuse those.  A missing cert here is
    /// self-signed by `QuicTransport.listen` only in dev posture (Debug build,
    /// GEODE_ENV not "production") or with GEODE_TLS_AUTOGENERATE_CERT=1; in
    /// production posture the listener refuses to start and the network loop
    /// fails (SONNY-2394; A6 reproducer).
    cert_path: []const u8 = "certs/server.crt",
    /// TLS private key path for the intra-cluster QUIC listener.  Mirrors
    /// `cert_path` lifetime / fallback semantics.
    key_path: []const u8 = "certs/server.key",

    /// Outbound raft RPC transport, wired to the inner raft node via
    /// `RaftNode.setTransport` so that vote / heartbeat traffic produced by
    /// the inner raft library reaches its target peers over QUIC+TLS.  The
    /// inbound side is handled by `networkLoop` (a separate QUIC listener
    /// stored under `network_transport.quic_server`); this field is the
    /// pure-outbound dispatch path that the RaftLibTransportBridge needs.
    ///
    /// Without this field the bridge has no destination to send to and the
    /// raft library silently drops every RequestVote / AppendEntries —
    /// which is exactly the symptom of "three nodes start, no leader is
    /// ever elected" that Task A6 (2026-05-25 plan) is closing.
    raft_transport: raft_consensus.Transport,

    /// GAP-0870: applied cluster membership view, mutated by committed
    /// `config_change` Raft entries (registered with raft_apply at init).
    applied_cluster_config: *raft_apply.AppliedClusterConfig,
    /// GAP-0870: 2PC coordinator that committed `txn_prepare` / `txn_decide`
    /// Raft entries route into (registered with raft_apply at init).
    txn_coord: *raft_consensus.TxnCoordinator,
    /// RC-3 (2026-06-12): the idempotency-key dedup table consulted by the keyed
    /// create apply path (registered with raft_apply at init). Owned here; rebuilt
    /// naturally by committed-log replay on restart, so it needs no persistence.
    idempotency_dedup: *cluster_replication.IdempotencyDedup,

    /// owed item (4) — frozen-term pre-vote VISIBILITY: tracks whether this node
    /// has been wedged as a CANDIDATE at an UNCHANGING term past the warn
    /// threshold. `pre_vote = true` freezes the term while a node is wedged as a
    /// candidate (the term only increments after a WON pre-vote), so the
    /// all-candidate divergent-durable-state wedge is otherwise SILENT — zero
    /// transport errors, zero term churn. `raftLoop` polls this each tick and
    /// emits a rate-limited operator warn when it returns true. Owns no I/O.
    frozen_candidate_tracker: raft_consensus.FrozenCandidateTracker = .{},

    // QUAL-D004: Shutdown signal and pool handles for graceful stop.
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    raft_pool: ?*pooled.ThreadPool = null,
    network_pool: ?*pooled.ThreadPool = null,
    health_pool: ?*pooled.ThreadPool = null,
    replication_pool: ?*pooled.ThreadPool = null,
    connection_pool: ?*pooled.ThreadPool = null,
    /// Dedicated polling thread for the intra-cluster QUIC endpoint.
    /// `accept()` blocks on `accepted.items.len > 0` via a CV — connections
    /// only land in that queue once the endpoint's `poll()` has processed
    /// the incoming UDP datagrams and completed the TLS handshake.  The
    /// client-facing transport runs `QuicTransport.pollLoop` on a separate
    /// thread (see `runPollLoopTask` in `src/server/main.zig`); the
    /// cluster listener needs the same.  Without this, every outbound
    /// `connectInsecure` from a peer times out with HandshakeError because
    /// the server side never processes the ClientHello (Task A6
    /// 2026-05-25 plan reproducer).
    cluster_poll_pool: ?*pooled.ThreadPool = null,

    // === RC-A: AGGREGATE inbound-pool occupancy sweeper (k8s sustained churn) ==
    // Live registry of every accepted inbound cluster connection. Each worker
    // registers its connection at ACCEPT time (the accept-time idle clock — the
    // RC-A fix) and deregisters on exit. The independent sweeper (driven off the
    // health loop, NOT a victim's own worker) snapshots this list and, via
    // `inboundReapCountForCapacity`, flags idle zombies for reap — queued AND
    // pinned — by setting each victim's `reap_requested` flag. The parked worker
    // observes that flag on its ~200 µs WouldBlock poll cycle and unwinds,
    // releasing its slot. The sweeper NEVER frees a connection or touches QUIC
    // internals, so there is no use-after-free: only the owning worker
    // deregisters and the transport owns the wrapper lifetime.
    //
    // `inbound_conns_mutex` is a LEAF lock (never held while acquiring another
    // geode lock; brief list append/remove/snapshot only) — it sits outside the
    // CLAUDE.md tier table the same way the timeseries store lock does.
    inbound_conns: std.ArrayList(*InboundConnRecord) = .empty,
    inbound_conns_mutex: std.Io.Mutex = std.Io.Mutex.init,

    // Helper to access replication map
    fn replication_map(self: *ClusterCoordinator) std.AutoHashMap(u64, []u64) {
        return self.cluster_state.replication_map;
    }

    /// RC-A: per-connection liveness record, owned by the accepting worker for
    /// its connection's lifetime and referenced (read-only, under
    /// `inbound_conns_mutex`) by the independent sweeper. Heap-allocated so the
    /// pointer stays stable while it lives in `inbound_conns`.
    const InboundConnRecord = struct {
        /// Wall-clock ms at ACCEPT time (network loop), before the worker runs.
        accepted_ms: i64,
        /// Most recent stream/frame activity (atomically restamped by the worker;
        /// == accepted_ms until the conn does anything).
        last_activity_ms: std.atomic.Value(i64),
        /// Set by the sweeper to ask the owning worker to unwind and free its
        /// slot. The worker checks this on every WouldBlock poll cycle.
        reap_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn snapshot(self: *const InboundConnRecord) InboundConnSnapshot {
            return .{
                .accepted_ms = self.accepted_ms,
                .last_activity_ms = self.last_activity_ms.load(.acquire),
            };
        }
    };

    const Self = @This();

    pub const ShardingStrategy = enum {
        hash_based,
        range_based,
        graph_based,
        custom,
    };

    pub const FailoverConfig = struct {
        auto_failover: bool = true,
        failover_timeout_ms: u64 = 5000,
        min_replicas: u32 = 2,
        max_failover_attempts: u32 = 3,
        backoff_multiplier: f32 = 1.5,
    };

    pub const ClusterState = struct {
        nodes: std.ArrayList(NodeInfo),
        shards: std.ArrayList(ShardInfo),
        replication_map: std.AutoHashMap(u64, []u64),
        leader_node: ?u64,
        cluster_version: u64,
        topology_version: u64,
    };

    pub const NodeInfo = struct {
        id: u64,
        endpoint: []const u8,
        state: NodeState,
        role: NodeRole,
        capacity: NodeCapacity,
        last_heartbeat: i64,
        metadata: std.StringHashMap([]const u8),
    };

    pub const NodeState = enum {
        joining,
        active,
        leaving,
        failed,
        maintenance,
    };

    pub const NodeRole = enum {
        leader,
        follower,
        candidate,
        observer,
    };

    pub const NodeCapacity = struct {
        cpu_cores: u32,
        memory_gb: u32,
        storage_gb: u32,
        network_mbps: u32,
        current_load: f32,
    };

    pub const ShardInfo = struct {
        id: u64,
        primary_node: u64,
        replica_nodes: []u64,
        key_range: KeyRange,
        size_bytes: u64,
        record_count: u64,
    };

    pub const KeyRange = struct {
        start: []const u8,
        end: []const u8,

        pub fn contains(self: KeyRange, key: []const u8) bool {
            return std.mem.order(u8, key, self.start) != .lt and
                std.mem.order(u8, key, self.end) != .gt;
        }
    };

    pub const NetworkTransport = struct {
        allocator: Allocator,
        quic_server: ?quic.QuicTransport,
        connections: std.AutoHashMap(u64, Connection),
        message_queue: MessageQueue,
        /// Task A3c (2026-05-25 plan): cap on simultaneous inbound peer
        /// connections, sourced from `Config.max_connections`.  Mirrors the
        /// coordinator-level field for callers that only have a pointer to
        /// the transport.
        max_connections: u32 = 256,

        pub const Connection = struct {
            stream: *quic.QuicStream,
            node_id: u64,
            last_activity: i64,
            pending_requests: std.ArrayList(PendingRequest),
        };

        pub const PendingRequest = struct {
            id: u64,
            timeout: i64,
            callback: *const fn (response: Response) void,
        };

        pub const MessageQueue = struct {
            incoming: std.ArrayList(IncomingMessage),
            outgoing: std.ArrayList(OutgoingMessage),
            mutex: std.Io.Mutex,
        };

        pub const IncomingMessage = struct {
            from: u64,
            data: []const u8,
            received_at: i64,
        };

        pub const OutgoingMessage = struct {
            to: u64,
            data: []const u8,
            priority: u32,
            retry_count: u32,
        };
    };

    pub fn init(
        allocator: Allocator,
        node_id: u64,
        config: Config,
    ) !ClusterCoordinator {
        const peers = try resolvePeers(allocator, config.peers);
        // resolvePeers duped each peer.endpoint and allocated the slice; the
        // coordinator only takes ownership once it is fully constructed and
        // returned (deinit frees peers + endpoints). If any `try` below fails
        // before that return — e.g. RaftNode.init rejecting node_id==0 as
        // InvalidId, or initNetworkTransport/initHealthMonitor failing — these
        // would otherwise leak (observed as DebugAllocator leaks aborting
        // geodetestlab cluster startup). This errdefer mirrors deinit's free
        // ordering; it does NOT fire on the success return.
        errdefer {
            for (peers) |peer| {
                if (peer.endpoint.len > 0) allocator.free(peer.endpoint);
            }
            allocator.free(peers);
        }
        // RaftNode.init() already returns a heap-owned *RaftNode (it does the
        // create() inside).  The previous code double-allocated by calling
        // allocator.create(RaftNode) and then assigning raft.* = init(...),
        // which doesn't even type-check (init returns a pointer, not a
        // value).  As with resolvePeers above, this path was never reached
        // from production until the A3 test forced full type resolution.
        //
        // Durable raft state: when the operator supplies a data_dir, root the
        // raft hard-state + log at `<data_dir>/raft` via FileStorage so a
        // restarted node restores currentTerm / votedFor (Raft election-safety)
        // instead of resetting to term 0. FileStorage opens a Dir handle at
        // init and does NOT retain the path slice, so we free `raft_dir`
        // immediately after `initWithStorageDir` returns. A null data_dir keeps
        // the legacy in-memory (non-durable) backing.
        const raft_dir: ?[]u8 = if (config.data_dir) |d|
            try std.fmt.allocPrint(allocator, "{s}/raft", .{d})
        else
            null;
        defer if (raft_dir) |p| allocator.free(p);
        if (raft_dir == null) {
            std.log.warn("cluster: no data_dir configured — raft hard-state/log is NON-DURABLE (in-memory); a restarted node forgets its term/vote (election-safety risk)", .{});
        }
        const raft = try RaftNode.initWithStorageDir(
            allocator,
            node_id,
            peers,
            config.election_timeout_ms,
            raft_dir,
        );
        // raft.deinit() does not touch raft.peers (see deinit above, which
        // frees peers separately), so this unwind composes with the peers
        // errdefer without double-freeing. Fires only on an error return from
        // a later `try` in this function, never on the success return.
        errdefer {
            raft.deinit();
            allocator.destroy(raft);
        }

        const store = graph_store.getGlobalStore(allocator);

        // Wire the Raft apply callback so committed entries are routed to
        // the graph store.  The module-level store reference must be set
        // before the raft node starts ticking.
        raft_apply.setGlobalStore(store);
        raft.apply_callback = &raft_apply.applyCallbackFn;

        // GAP-0870: register the applied-membership view and the 2PC
        // coordinator so committed config_change / txn_prepare / txn_decide
        // entries have a real apply target (raft_apply fails loud otherwise).
        const applied_cfg = try allocator.create(raft_apply.AppliedClusterConfig);
        errdefer allocator.destroy(applied_cfg);
        applied_cfg.* = raft_apply.AppliedClusterConfig.init(allocator);
        errdefer applied_cfg.deinit();
        // Seed with bootstrap membership (self + static peers) so committed
        // config_change deltas apply on top of the configured topology.
        try applied_cfg.upsertMember(node_id, config.listen_address, config.cluster_port);
        for (config.peers) |pc| {
            try applied_cfg.upsertMember(pc.id, pc.address, pc.port);
        }
        const txn_coord = try allocator.create(raft_consensus.TxnCoordinator);
        errdefer allocator.destroy(txn_coord);
        txn_coord.* = try raft_consensus.TxnCoordinator.init(allocator, store);
        errdefer txn_coord.deinit();
        raft_apply.setGlobalClusterConfig(applied_cfg);
        raft_apply.setGlobalTxnCoordinator(txn_coord);

        // RC-3 (2026-06-12): the idempotency-key dedup table consulted by keyed
        // create apply. Owned by the coordinator; rebuilt by committed-log replay.
        const idem_dedup = try allocator.create(cluster_replication.IdempotencyDedup);
        errdefer allocator.destroy(idem_dedup);
        idem_dedup.* = cluster_replication.IdempotencyDedup.init(allocator);
        errdefer idem_dedup.deinit();
        raft_apply.setGlobalIdempotencyDedup(idem_dedup);

        var cluster_state = try initClusterState(allocator);
        // Task A5 (2026-05-25 plan): seed cluster_state.nodes from PeerConfig
        // so the network transport's findNodeEndpoint() lookup works from
        // t=0.  Without this bridge, sendToNode(peer_id) always returns
        // error.NodeNotFound because cluster_state.nodes only gets populated
        // by inbound JOIN_CLUSTER messages — but the leader hasn't been
        // elected yet, so no node has joined yet, so the address book is
        // empty, so RequestVote can't be sent, so no leader is ever
        // elected.  The "host:port" endpoint format matches what
        // findNodeEndpoint() (this file, search "lastIndexOf") expects.
        errdefer {
            for (cluster_state.nodes.items) |*node| {
                if (node.endpoint.len > 0) allocator.free(node.endpoint);
                node.metadata.deinit();
            }
            cluster_state.nodes.deinit(allocator);
            cluster_state.shards.deinit(allocator);
            cluster_state.replication_map.deinit();
        }
        for (config.peers) |pc| {
            const ep = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ pc.address, pc.port });
            errdefer allocator.free(ep);
            try cluster_state.nodes.append(allocator, .{
                .id = pc.id,
                .endpoint = ep,
                .state = .active,
                .role = .follower,
                .capacity = .{
                    .cpu_cores = 0,
                    .memory_gb = 0,
                    .storage_gb = 0,
                    .network_mbps = 0,
                    .current_load = 0.0,
                },
                .last_heartbeat = compat_milliTimestamp(),
                .metadata = std.StringHashMap([]const u8).init(allocator),
            });
        }

        return ClusterCoordinator{
            .allocator = allocator,
            .node_id = node_id,
            .raft = raft,
            .store = store,
            .applied_cluster_config = applied_cfg,
            .txn_coord = txn_coord,
            .idempotency_dedup = idem_dedup,
            .replication_factor = config.replication_factor,
            .sharding_strategy = config.sharding_strategy,
            .failover_config = config.failover_config,
            .cluster_state = cluster_state,
            .network_transport = try initNetworkTransport(allocator, config),
            .health_monitor = try initHealthMonitor(allocator, config),
            .raft_nonce_tracker = try NonceTracker.init(allocator, 10000),
            .replay_guard = ReplayGuard.init(allocator, 1024, 30_000),
            // Task A3/A3b/A3c: mirror cluster bootstrap fields from Config
            // so networkLoop and the auth path can read them without
            // re-touching the Config struct.
            .max_connections = config.max_connections,
            .listen_address = config.listen_address,
            .cluster_port = config.cluster_port,
            .cluster_token = config.cluster_token,
            .cluster_name = config.cluster_name,
            .cert_path = config.cert_path,
            .key_path = config.key_path,
            // Task A6 (2026-05-25 plan): outbound raft RPC transport.  We
            // wire it to the inner raft node via `setTransport` in
            // `start()` (not here) because the RaftLibTransportBridge
            // stores a `*Transport` pointer and the returned-by-value
            // ClusterCoordinator's address only becomes stable after the
            // caller stores it (e.g. cluster_bootstrap heap-allocates the
            // coordinator and calls start() on the heap pointer).
            .raft_transport = raft_consensus.Transport.init(allocator),
        };
    }

    pub fn deinit(self: *ClusterCoordinator) void {
        self.stop();
        // RC-A: `stop()` has joined every worker + the health loop, so no thread
        // can still touch the inbound registry. Free any record a worker left
        // behind (defensive — the normal path deregisters on exit) and release the
        // list's backing memory.
        for (self.inbound_conns.items) |rec| self.allocator.destroy(rec);
        self.inbound_conns.deinit(self.allocator);
        self.raft_nonce_tracker.deinit();
        self.replay_guard.deinit();
        // GAP-0870: unregister + free the applied-config / 2PC apply targets.
        // Only reset the module-level registration if it is still ours (an
        // in-process multi-coordinator test may have re-registered).
        if (raft_apply.getGlobalClusterConfig() == self.applied_cluster_config) {
            raft_apply.resetGlobalClusterConfig();
        }
        if (raft_apply.getGlobalTxnCoordinator() == self.txn_coord) {
            raft_apply.resetGlobalTxnCoordinator();
        }
        // RC-3: unregister + free the idempotency dedup table (same ownership
        // pattern as the apply targets above).
        if (raft_apply.getGlobalIdempotencyDedup() == self.idempotency_dedup) {
            raft_apply.resetGlobalIdempotencyDedup();
        }
        self.idempotency_dedup.deinit();
        self.allocator.destroy(self.idempotency_dedup);
        self.applied_cluster_config.deinit();
        self.allocator.destroy(self.applied_cluster_config);
        self.txn_coord.deinit();
        self.allocator.destroy(self.txn_coord);
        // resolvePeers duped each peer.endpoint into self.allocator; raft's
        // own deinit doesn't reclaim them, so free them here before the
        // backing slice goes away.
        for (self.raft.peers) |peer| {
            if (peer.endpoint.len > 0) self.allocator.free(peer.endpoint);
        }
        self.allocator.free(self.raft.peers);
        self.raft.deinit();
        self.allocator.destroy(self.raft);
        for (self.cluster_state.nodes.items) |*node| {
            if (node.endpoint.len > 0) {
                self.allocator.free(node.endpoint);
            }
            var meta_it = node.metadata.iterator();
            while (meta_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            node.metadata.deinit();
        }
        self.cluster_state.nodes.deinit(self.allocator);
        for (self.cluster_state.shards.items) |shard| {
            if (shard.replica_nodes.len > 0) {
                self.allocator.free(shard.replica_nodes);
            }
        }
        self.cluster_state.shards.deinit(self.allocator);
        self.cluster_state.replication_map.deinit();

        var conn_it = self.network_transport.connections.iterator();
        while (conn_it.next()) |entry| {
            entry.value_ptr.pending_requests.deinit(self.allocator);
        }
        self.network_transport.connections.deinit();
        for (self.network_transport.message_queue.incoming.items) |msg| {
            if (msg.data.len > 0) {
                self.allocator.free(msg.data);
            }
        }
        for (self.network_transport.message_queue.outgoing.items) |msg| {
            if (msg.data.len > 0) {
                self.allocator.free(msg.data);
            }
        }
        self.network_transport.message_queue.incoming.deinit(self.allocator);
        self.network_transport.message_queue.outgoing.deinit(self.allocator);
        if (self.network_transport.quic_server) |*server| {
            server.deinit();
        }
        // Task A6 (2026-05-25 plan): outbound raft transport teardown.
        // The Transport struct owns a `?quic.QuicTransport` server slot
        // that we never listen() on (we only use the outbound `send`
        // path), but its deinit() is a safe no-op when the slot is null.
        self.raft_transport.deinit();

        self.health_monitor.health_checks.deinit(self.allocator);
    }

    // QUAL-D004: start() spawns background threads and returns immediately.
    // Call stop() (or deinit()) to signal shutdown and join all threads.
    pub fn start(self: *ClusterCoordinator) !void {
        // Task A6 (2026-05-25 plan): wire the outbound raft transport into
        // the inner raft node now that `self` has a stable address.  The
        // RaftLibTransportBridge stores `&self.raft_transport` indirectly
        // (through `RaftNode.transport`), so we MUST do this before the
        // raft loop starts ticking — otherwise the very first RequestVote
        // emitted by the inner library hits a null transport and the
        // election can't progress.
        self.raft.setTransport(&self.raft_transport);

        // election-livelock fix (2026-06-11) + owed item (4): wire the live
        // `StallArm` role source the transport's stalled-stream reaper
        // (`maybeReconnectOnStall`) arms its eviction decision on. The detector
        // fires while THIS node is the raft LEADER or a CANDIDATE, and suppresses
        // a FOLLOWER. Off-arm (follower) every peer reads as stalled during a
        // leaderless election and evicting them all would livelock the cluster;
        // but a CANDIDATE must get its RequestVote frames through a possibly-
        // wedged stream at restart, so it MUST be armed (owed item (4) divergent-
        // durable-state wedge). `ctx` is `self` (the coordinator owns
        // `raft_transport` and outlives it, so the closure's ctx lifetime is
        // sound), and the closure maps `coordinator.role()` onto `StallArm` (any
        // shutdown/other state -> `.follower`, never armed). Wire it before the
        // poll loop starts so the first reaper pass already sees a truthful role.
        // Left unset (standalone) the transport defaults to `.follower` and never
        // evicts on stall.
        self.raft_transport.setRoleSource(@ptrCast(self), struct {
            fn armOf(ctx: ?*anyopaque) raft_consensus.Transport.StallArm {
                const coord: *ClusterCoordinator = @ptrCast(@alignCast(ctx.?));
                return switch (coord.role()) {
                    .leader => .leader,
                    .candidate => .candidate,
                    .follower, .shutdown => .follower,
                };
            }
        }.armOf);

        self.shutdown.store(false, .release);

        // Task A6 (2026-05-25 plan): bring up the QUIC listener BEFORE any
        // loop thread starts.  Previously networkLoop did this lazily on its
        // first iteration, which meant the poll-loop thread (added below)
        // would race against an uninitialised `quic_server` slot.  Doing it
        // up-front also lets `cluster_poll_pool` and the network accept
        // loop share the same lifecycle.
        if (self.network_transport.quic_server == null) {
            var qt_config = quic.QuicTransport.Config{
                .address = self.listen_address,
                .port = self.cluster_port,
            };
            if (self.cert_path.len > 0) qt_config.cert_path = self.cert_path;
            if (self.key_path.len > 0) qt_config.key_path = self.key_path;
            const qt = try quic.QuicTransport.init(self.allocator, qt_config);
            self.network_transport.quic_server = qt;
            try self.network_transport.quic_server.?.listen();
        }

        self.connection_pool = try pooled.ThreadPool.init(self.allocator, .{
            .num_threads = 4,
            .queue_capacity = 128,
        });
        errdefer {
            self.connection_pool.?.deinit();
            self.connection_pool = null;
        }
        // Task A6 (2026-05-25 plan): dedicated poll loop for the cluster
        // QUIC endpoint.  Without this thread, the server side never
        // processes peer ClientHello packets and every outbound peer
        // connectInsecure() hangs until waitForHandshake() times out with
        // QuicError.HandshakeError.  See the long comment on
        // `cluster_poll_pool` for the full rationale.
        self.cluster_poll_pool = try startLoopPool(self, runClusterPollLoop);
        errdefer {
            self.cluster_poll_pool.?.deinit();
            self.cluster_poll_pool = null;
        }

        // Task A6e (2026-05-26 plan): the outbox drain thread takes
        // outbound raft RPCs off the `inner_mutex` critical path so
        // the raft tick loop can run at its full 100 ticks/sec rate
        // even while QUIC handshakes / writes are in flight.  Must
        // start BEFORE the raft loop so the very first heartbeat /
        // RequestVote produced by the inner library has somewhere to
        // land.
        try self.raft_transport.startOutboxDrain();
        errdefer self.raft_transport.stopOutboxDrain();

        // Task A6e: the per-peer client endpoint owns its own UDP
        // socket and needs `poll()` called on it for the vendor
        // library to actually push bytes out.  `cluster_poll_pool`
        // drives the SERVER endpoint only; this thread drives every
        // PeerConnection that the outbox dispatcher has cached.
        try self.raft_transport.startClientPoll();
        errdefer self.raft_transport.stopClientPoll();

        self.raft_pool = try startLoopPool(self, runRaftLoop);
        errdefer {
            self.raft_pool.?.deinit();
            self.raft_pool = null;
        }
        self.network_pool = try startLoopPool(self, runNetworkLoop);
        errdefer {
            self.network_pool.?.deinit();
            self.network_pool = null;
        }
        self.health_pool = try startLoopPool(self, runHealthLoop);
        errdefer {
            self.health_pool.?.deinit();
            self.health_pool = null;
        }
        self.replication_pool = try startLoopPool(self, runReplicationLoop);
        errdefer {
            self.replication_pool.?.deinit();
            self.replication_pool = null;
        }
    }

    pub fn stop(self: *ClusterCoordinator) void {
        // Signal shutdown FIRST so every loop sees `shutdown == true` on its
        // next check.  networkLoop polls inside accept() (50ms slices) so it
        // exits within one polling cycle; the other loops sleep-poll on
        // `shutdown` between work units.
        self.shutdown.store(true, .release);

        // Join the worker threads BEFORE destroying the QUIC server.  An
        // earlier revision tore down `quic_server` while the network thread
        // was still inside `waitForAccepted`, which races with that thread's
        // `orderedRemove(0)` on `endpoint.accepted` and segfaults under the
        // bootstrap tests (A4b reproducer).  Pool.deinit() blocks until the
        // worker thread returns, so doing it first means the network loop
        // has fully unwound by the time we touch the server.
        if (self.raft_pool) |pool| {
            pool.deinit();
            self.raft_pool = null;
        }
        if (self.network_pool) |pool| {
            pool.deinit();
            self.network_pool = null;
        }
        // Task A6 (2026-05-25 plan): join the cluster-poll thread before
        // we destroy the QUIC server below — same race avoidance pattern
        // as `network_pool` above.
        if (self.cluster_poll_pool) |pool| {
            pool.deinit();
            self.cluster_poll_pool = null;
        }
        if (self.health_pool) |pool| {
            pool.deinit();
            self.health_pool = null;
        }
        if (self.replication_pool) |pool| {
            pool.deinit();
            self.replication_pool = null;
        }
        if (self.connection_pool) |pool| {
            pool.deinit();
            self.connection_pool = null;
        }

        // Task A6e (2026-05-26): stop the outbox + client-poll threads
        // after the raft loops are joined so no producer can enqueue a
        // new message after the dispatch thread exits.  Stopping the
        // client poll thread after the cluster poll pool is fine —
        // both touch independent endpoints (server vs cached clients).
        self.raft_transport.stopOutboxDrain();
        self.raft_transport.stopClientPoll();

        // Now that no thread can still be in accept(), it is safe to free
        // the QUIC server.  deinit() is the only place that ever destroys
        // it; networkLoop only reads `quic_server.?` while it holds a
        // reference to the same pointer this code is about to free.
        if (self.network_transport.quic_server) |*server| {
            server.deinit();
            self.network_transport.quic_server = null;
        }
    }

    fn raftLoop(self: *ClusterCoordinator) !void {
        // Task A6 follow-on (2026-05-25 plan): emit a periodic role/term log
        // so the subprocess smoke test (and operators) can observe leader
        // election progress without attaching a debugger.  Every 100 ticks
        // (~1 second of wallclock) we log the current raft state and term.
        // Crucially we emit this through `std.debug.print` which goes to
        // stderr unconditionally — the scoped logger filters info-level
        // output by default in release builds, but the harness needs to
        // see leader election before any other log machinery is set up.
        var iter: u64 = 0;
        std.debug.print("[raft] node {d} state=follower term=0 iter=0\n", .{self.node_id});
        while (!self.shutdown.load(.acquire)) {
            self.raft.tick() catch |err| {
                std.debug.print("[raft] node {d} tick error: {s}\n", .{ self.node_id, @errorName(err) });
            };
            iter += 1;
            if (iter % 100 == 0) {
                std.debug.print("[raft] node {d} state={s} term={d} iter={d}\n", .{ self.node_id, @tagName(self.raft.state), self.raft.current_term, iter });

                // owed item (4) — frozen-term pre-vote VISIBILITY: sample the
                // live (role, term) on this ~1 s cadence (NOT every 10 ms tick —
                // cheap, no per-tick inner-mutex lock, no per-tick allocation) and
                // feed the frozen-candidate tracker. When a node has been wedged
                // as a candidate at an UNCHANGING term past the warn threshold
                // (`pre_vote=true` freezes the term, so the divergent-durable-state
                // wedge would otherwise be SILENT), emit a rate-limited operator
                // warn naming the condition. The tracker resets on any term advance
                // or role transition, so a healthy (progressing) election is never
                // flagged.
                const cur_role = self.raft.role();
                const term = self.raft.currentTerm();
                const now_ms = compat_milliTimestamp();
                if (self.frozen_candidate_tracker.update(cur_role, term, now_ms)) {
                    const frozen_for_ms = now_ms - self.frozen_candidate_tracker.candidate_since_ms;
                    log.warn("raft candidate frozen at term — possible vote-delivery stall or divergent durable state; check peer connectivity", &.{
                        Attr.uint("node", self.node_id),
                        Attr.uint("term", term),
                        Attr.int("frozen_for_ms", frozen_for_ms),
                    });
                }
            }
            compat_sleepNs(10 * std.time.ns_per_ms);
        }
    }

    fn networkLoop(self: *ClusterCoordinator) !void {
        // Task A3b/A3c/A6 (2026-05-25 plan): the QUIC listener is now
        // brought up inside `start()` (above) BEFORE any loop thread is
        // spawned.  That guarantees `cluster_poll_pool` and this accept
        // loop both observe a fully-initialised `quic_server` from the
        // first iteration on.  We assert here rather than re-initialise
        // because a null slot is a programming error, not a recoverable
        // condition.
        std.debug.assert(self.network_transport.quic_server != null);

        while (!self.shutdown.load(.acquire)) {
            const conn = self.network_transport.quic_server.?.accept() catch |err| switch (err) {
                error.WouldBlock => continue,
                else => {
                    if (self.shutdown.load(.acquire)) break;
                    log.err("Accept failed", &.{Attr.string("error", @errorName(err))});
                    continue;
                },
            };

            // PERF-D006: Connection semaphore - reject if at capacity
            if (self.active_connections.load(.acquire) >= self.max_connections) {
                log.warn("Connection limit reached, rejecting new connection", &.{
                    Attr.uint("active", self.active_connections.load(.acquire)),
                    Attr.uint("max", self.max_connections),
                });
                // Connection will be cleaned up when it goes out of scope
                continue;
            }

            if (self.connection_pool) |pool| {
                const ctx = try self.allocator.create(ConnectionTaskCtx);
                errdefer self.allocator.destroy(ctx);
                ctx.* = .{
                    .allocator = self.allocator,
                    .coordinator = self,
                    .conn = conn,
                    // RC-A: stamp the idle clock at ACCEPT, not at worker
                    // acquisition — a queued conn (no free worker yet) still ages.
                    .accepted_ms = compat_milliTimestamp(),
                };
                if (!pool.submit(.{
                    .context = @ptrCast(ctx),
                    .callback = runConnectionTask,
                })) {
                    self.allocator.destroy(ctx);
                    log.warn("Connection pool saturated, dropping cluster connection", &.{});
                }
            }
        }
    }

    fn healthLoop(self: *ClusterCoordinator) !void {
        // RC-A: resolve the inbound idle deadline ONCE (same env override the
        // per-worker RC1 reap uses — GEODE_CLUSTER_INBOUND_IDLE_MS — so operators
        // tune both with one knob). The independent occupancy sweeper runs on this
        // loop's ~1 s cadence (health_check_interval_ms), flagging idle zombies for
        // reap independent of any victim worker's own loop. ~1 s sweep + ~200 µs
        // worker poll ⇒ recovery well under one election timeout (the RC-A goal).
        const inbound_idle_deadline_ms = blk: {
            const raw = getEnvVarOwned(self.allocator, "GEODE_CLUSTER_INBOUND_IDLE_MS") catch break :blk inbound_connection_idle_deadline_ms;
            defer self.allocator.free(raw);
            break :blk resolveInboundIdleDeadlineMs(raw);
        };

        while (!self.shutdown.load(.acquire)) {
            try self.healthPass();

            // RC-A: independent inbound-pool occupancy sweep. Frees worker slots
            // pinned by zombie half-open inbound conns so a rebuilt leader conn
            // (current-term AppendEntries) is serviced and the node steps down from
            // a stranded candidacy instead of wedging across churn rounds.
            self.sweepInboundOccupancy(inbound_idle_deadline_ms);

            compat_sleepNs(self.health_monitor.check_interval_ms * std.time.ns_per_ms);
        }
    }

    /// One health-check pass over the peers in `cluster_state.nodes`. A peer
    /// is failed over once, when it turns unhealthy, and is active again when
    /// it is heard from. SONNY-6451: nothing in the pass adds to or removes
    /// from `cluster_state.nodes` (the slice iterated here).
    fn healthPass(self: *ClusterCoordinator) !void {
        for (self.cluster_state.nodes.items) |*node| {
            if (node.id == self.node_id) continue;

            const health_status = try self.checkNodeHealth(node);
            try self.updateHealthStatus(node.id, health_status);

            if (health_status == .unhealthy) {
                if (node.state != .failed) try self.handleNodeFailure(node.id);
            } else if (node.state == .failed) {
                node.state = .active;
            }
        }
    }

    fn replicationLoop(self: *ClusterCoordinator) !void {
        while (!self.shutdown.load(.acquire)) {
            if (self.raft.state == .leader) {
                try self.performReplication();
            }
            compat_sleepNs(100 * std.time.ns_per_ms);
        }
    }

    const ConnectionTaskCtx = struct {
        allocator: Allocator,
        coordinator: *ClusterCoordinator,
        conn: *quic.QuicConnection,
        /// RC-A: wall-clock ms stamped at ACCEPT time in the network loop, BEFORE
        /// the worker runs. The worker seeds its `InboundConnRecord.accepted_ms`
        /// from this so a connection that sits QUEUED (never acquires a worker)
        /// still has a running idle clock — the core RC-A accept-time-clock fix.
        accepted_ms: i64,
    };

    fn startLoopPool(self: *ClusterCoordinator, callback: *const fn (*anyopaque) void) !*pooled.ThreadPool {
        const pool = try pooled.ThreadPool.init(self.allocator, .{
            .num_threads = 1,
            .queue_capacity = 4,
        });
        errdefer pool.deinit();
        try pool.submitBlocking(.{
            .context = @ptrCast(self),
            .callback = callback,
        });
        return pool;
    }

    fn runRaftLoop(ctx: *anyopaque) void {
        const self: *ClusterCoordinator = @ptrCast(@alignCast(ctx));
        self.raftLoop() catch |err| {
            log.err("Raft loop failed", &.{Attr.string("error", @errorName(err))});
        };
    }

    fn runNetworkLoop(ctx: *anyopaque) void {
        const self: *ClusterCoordinator = @ptrCast(@alignCast(ctx));
        self.networkLoop() catch |err| {
            log.err("Network loop failed", &.{Attr.string("error", @errorName(err))});
        };
    }

    /// Drive `QuicTransport.pollLoop` on the cluster-side endpoint so the
    /// vendor QUIC stack actually processes inbound UDP datagrams.  Without
    /// this thread, `accept()` (which only blocks on a CV that fires once a
    /// connection has been fully handshaked into the `accepted` queue) sits
    /// forever and every outbound peer connect times out with HandshakeError.
    /// Task A6 (2026-05-25 plan).
    fn runClusterPollLoop(ctx: *anyopaque) void {
        const self: *ClusterCoordinator = @ptrCast(@alignCast(ctx));
        if (self.network_transport.quic_server) |*server| {
            quic.QuicTransport.pollLoop(server, &self.shutdown);
        } else {
            log.err("Cluster poll loop: quic_server is null at startup", &.{});
        }
    }

    fn runHealthLoop(ctx: *anyopaque) void {
        const self: *ClusterCoordinator = @ptrCast(@alignCast(ctx));
        self.healthLoop() catch |err| {
            log.err("Health loop failed", &.{Attr.string("error", @errorName(err))});
        };
    }

    fn runReplicationLoop(ctx: *anyopaque) void {
        const self: *ClusterCoordinator = @ptrCast(@alignCast(ctx));
        self.replicationLoop() catch |err| {
            log.err("Replication loop failed", &.{Attr.string("error", @errorName(err))});
        };
    }

    fn runConnectionTask(ctx: *anyopaque) void {
        const task_ctx: *ConnectionTaskCtx = @ptrCast(@alignCast(ctx));
        const accepted_ms = task_ctx.accepted_ms;
        defer task_ctx.allocator.destroy(task_ctx);
        task_ctx.coordinator.handleQuicConnection(task_ctx.conn, accepted_ms) catch |err| {
            log.err("Cluster connection handler failed", &.{Attr.string("error", @errorName(err))});
        };
    }

    /// RC-A: register an inbound connection in the live occupancy registry,
    /// seeding the accept-time idle clock. Returns the heap-owned record (the
    /// worker owns it and MUST `deregisterInboundConn` it on exit). On OOM
    /// returns null — the worker then runs without sweeper visibility, falling
    /// back to the RC1 self-reap (no worse than pre-RC-A behavior).
    fn registerInboundConn(self: *ClusterCoordinator, accepted_ms: i64) ?*InboundConnRecord {
        const rec = self.allocator.create(InboundConnRecord) catch return null;
        rec.* = .{
            .accepted_ms = accepted_ms,
            .last_activity_ms = std.atomic.Value(i64).init(accepted_ms),
        };
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inbound_conns_mutex.lockUncancelable(io);
        defer self.inbound_conns_mutex.unlock(io);
        self.inbound_conns.append(self.allocator, rec) catch {
            self.allocator.destroy(rec);
            return null;
        };
        return rec;
    }

    /// RC-A: remove and free an inbound connection record on worker exit.
    fn deregisterInboundConn(self: *ClusterCoordinator, rec: *InboundConnRecord) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inbound_conns_mutex.lockUncancelable(io);
        var idx: usize = 0;
        while (idx < self.inbound_conns.items.len) : (idx += 1) {
            if (self.inbound_conns.items[idx] == rec) {
                _ = self.inbound_conns.swapRemove(idx);
                break;
            }
        }
        self.inbound_conns_mutex.unlock(io);
        self.allocator.destroy(rec);
    }

    /// RC-A: the INDEPENDENT inbound-pool sweeper. Snapshots the live inbound
    /// registry, asks the pure `inboundReapCountForCapacity` how many idle
    /// zombies must be reaped to free capacity, and flags exactly those (the
    /// stalest first) by setting their `reap_requested` flag. The owning worker
    /// observes the flag on its next ~200 µs WouldBlock poll and unwinds —
    /// releasing the slot WITHOUT requiring the victim's own loop to have noticed
    /// the idle timeout, and WITHOUT the sweeper ever freeing a connection (no
    /// UAF). Idempotent: re-flagging an already-flagged victim is harmless.
    /// Driven off the health loop (an existing periodic ~check_interval cadence).
    // CANARY: REQ=REQ-DIST-CLUSTER-INBOUND-OCCUPANCY; FEATURE="DistributedCluster"; ASPECT=InboundOccupancySweeper; STATUS=TESTED; TEST=tests/test_raft_inbound_pool_occupancy.zig; OWNER=distributed; UPDATED=2026-06-12
    fn sweepInboundOccupancy(self: *ClusterCoordinator, deadline_ms: i64) void {
        const now_ms = compat_milliTimestamp();
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inbound_conns_mutex.lockUncancelable(io);
        defer self.inbound_conns_mutex.unlock(io);

        const n = self.inbound_conns.items.len;
        if (n == 0) return;

        // Flag every zombie (idle age past the deadline) for reap on its
        // accept-time clock. `inboundReapCountForCapacity` counts exactly these;
        // we flag each matching record. A live conn (fresh activity) is never
        // flagged — the per-record predicate is identical to the pure decision.
        var flagged: usize = 0;
        for (self.inbound_conns.items) |rec| {
            const last = rec.last_activity_ms.load(.acquire);
            if (shouldReapIdleInboundConnection(now_ms, last, deadline_ms)) {
                if (!rec.reap_requested.swap(true, .acq_rel)) flagged += 1;
            }
        }
        if (flagged > 0) {
            log.debug("inbound occupancy sweeper flagged idle zombies for reap", &.{
                Attr.uint("flagged", flagged),
                Attr.uint("inbound_total", n),
                Attr.int("deadline_ms", deadline_ms),
            });
        }
    }

    fn handleQuicConnection(self: *ClusterCoordinator, conn: *quic.QuicConnection, accepted_ms: i64) !void {
        // PERF-D006: Track active connections
        _ = self.active_connections.fetchAdd(1, .release);
        defer _ = self.active_connections.fetchSub(1, .release);

        // RC-A: register in the live occupancy registry so the independent
        // sweeper can see this connection's accept-time idle clock and flag it
        // for reap even while this worker is parked. The record outlives the
        // worker only conceptually — we free it on exit via deregister.
        const rec = self.registerInboundConn(accepted_ms);
        defer if (rec) |r| self.deregisterInboundConn(r);

        // Task A6c (2026-05-25 distributed cluster testing plan):
        // The sender now keeps a persistent QuicClient per peer and opens
        // a fresh bidirectional stream for every raft RPC.  The receiver
        // therefore has to accept streams in a loop for the lifetime of
        // the connection — handling just one stream (the original
        // pattern) drops every RPC after the first.
        //
        // The vendor QUIC library re-queues the same stream_id every time
        // new data arrives on it (see queueIncomingStream comment in
        // zig-pkg/quic-*/src/quic/connection/methods_c.zig).  For our
        // "one raft frame per stream, then FIN" usage that means we may
        // accept a stream_id we have already drained — `readRaftFrame`
        // would then see an empty + FIN'd stream and return EndOfStream.
        // Dedupe by tracking which stream_ids we have already handled on
        // this connection.
        var seen_streams = std.AutoHashMap(u64, void).init(self.allocator);
        defer seen_streams.deinit();

        // RC1 (k8s churn): resolve the idle-reap deadline ONCE at handler start
        // (env override, else default). `last_activity_ms` is stamped on every
        // accepted stream / dispatched frame; an inbound connection that goes
        // quiet past the deadline is reaped here so its worker thread is released
        // long before the ~300 s QUIC idle timeout would — otherwise a handful of
        // zombie half-open connections after a pod churn pin all 4 workers and
        // rebuilt peer connections are never serviced.
        const idle_deadline_ms = blk: {
            const raw = getEnvVarOwned(self.allocator, "GEODE_CLUSTER_INBOUND_IDLE_MS") catch break :blk inbound_connection_idle_deadline_ms;
            defer self.allocator.free(raw);
            break :blk resolveInboundIdleDeadlineMs(raw);
        };
        var last_activity_ms: i64 = compat_milliTimestamp();

        while (!self.shutdown.load(.acquire)) {
            const stream = conn.acceptStream() catch |err| switch (err) {
                error.WouldBlock => {
                    // RC-A: the independent occupancy sweeper may have flagged this
                    // connection for reap (its accept-time idle clock fired) WITHOUT
                    // this worker's own RC1 timer having noticed — e.g. a QUEUED
                    // zombie whose worker-local clock started late, or any zombie the
                    // aggregate decision picked to free pool capacity. Honor that
                    // flag first so the slot is released on the next poll cycle.
                    if (rec) |r| {
                        if (r.reap_requested.load(.acquire)) {
                            log.debug("reaping inbound cluster connection on sweeper request; releasing worker", &.{
                                Attr.int("idle_ms", compat_milliTimestamp() - last_activity_ms),
                            });
                            return;
                        }
                    }
                    // RC1: reap an idle inbound connection so its worker thread is
                    // released. A half-open / zombie peer never sends another
                    // stream; without this the handler parks here until the ~300 s
                    // QUIC idle timeout, pinning the worker the whole time.
                    if (shouldReapIdleInboundConnection(compat_milliTimestamp(), last_activity_ms, idle_deadline_ms)) {
                        log.debug("reaping idle inbound cluster connection; releasing worker", &.{
                            Attr.int("idle_ms", compat_milliTimestamp() - last_activity_ms),
                            Attr.int("deadline_ms", idle_deadline_ms),
                        });
                        return;
                    }
                    compat_sleepNs(200 * std.time.ns_per_us);
                    continue;
                },
                else => {
                    // Connection-level error: peer closed, draining, etc.
                    // Drop the connection and let the caller fall through
                    // to cleanup.  Don't bubble up here — we don't want a
                    // single bad connection to crash the network thread.
                    log.debug("acceptStream returned error; ending connection handler", &.{
                        Attr.string("error", @errorName(err)),
                    });
                    return;
                },
            };

            // RC1: any accepted stream is fresh activity from this peer (the
            // vendor re-queues a stream_id only when new data arrives on it), so
            // bump the idle window before the dedup check — a live peer that keeps
            // re-sending on a drained stream must not be reaped as idle.
            // RC-A: publish to the registry record too so the independent sweeper
            // sees the same fresh activity and never flags a live conn as a zombie.
            last_activity_ms = compat_milliTimestamp();
            if (rec) |r| r.last_activity_ms.store(last_activity_ms, .release);

            // Drop duplicates surfaced by the vendor's re-queue semantics.
            if (seen_streams.contains(stream.stream_id)) {
                conn.destroyStream(stream);
                continue;
            }
            seen_streams.put(stream.stream_id, {}) catch {};

            // Each stream carries a single inbound frame.  Read once,
            // then either dispatch as raft (existing path) or cluster
            // RPC (A3e, this commit).  The next RPC arrives on a fresh
            // stream which `acceptStream` will surface on the next
            // iteration.
            //
            // A3e (2026-05-26): the wire now multiplexes two frame
            // types on the same stream by inspecting the first byte.
            // `CLUSTER_RPC_MAGIC` selects the request/response path
            // (cluster RPC); any other byte is treated as the high
            // byte of a 4-byte big-endian length prefix and fed into
            // the existing raft frame reader.  We peek by reading
            // exactly one byte first, then dispatch.
            const watch: InboundStreamWatch = .{ .conn = conn, .rec = rec, .idle_deadline_ms = idle_deadline_ms };
            self.dispatchInboundStream(stream, &watch) catch |err| {
                if (err == error.InboundStreamAbandoned) {
                    // SONNY-6451: release the worker. Close the connection
                    // too, so a sender that is still alive (a quiet peer,
                    // not a dead one) sees it end and reconnects instead of
                    // writing into a connection nobody reads any more.
                    conn.destroyStream(stream);
                    conn.requestShutdown(quic.app_error.server_teardown);
                    return;
                }
                log.debug("dispatchInboundStream error", &.{
                    Attr.string("error", @errorName(err)),
                });
            };
            // RC1: a dispatched frame (possibly several, the multiplexed stream
            // reads frames until EndOfStream) is the strongest activity signal —
            // restamp so a connection actively carrying raft traffic is never
            // reaped mid-flight. RC-A: publish to the registry record too.
            last_activity_ms = compat_milliTimestamp();
            if (rec) |r| r.last_activity_ms.store(last_activity_ms, .release);
            conn.destroyStream(stream);
        }
    }

    /// Peek the first byte on `stream` and dispatch to either the
    /// raft frame reader (existing behaviour) or the cluster RPC
    /// handler (A3e, this commit).  See the `CLUSTER_RPC_MAGIC`
    /// comment for the wire format and rationale.
    /// SONNY-6451: what a handler parked on a quiet multiplexed raft stream
    /// watches, so that it gives the stream (and its worker) up.
    const InboundStreamWatch = struct {
        conn: *quic.QuicConnection,
        /// The handler's RC-A occupancy record (null on OOM at register).
        rec: ?*InboundConnRecord,
        /// The RC1 inbound idle deadline.
        idle_deadline_ms: i64,
    };

    /// SONNY-6451: true when a handler parked on a quiet inbound raft stream
    /// must give it up: the coordinator is stopping, the connection is gone,
    /// the RC-A sweeper asked for the worker back, or no frame has arrived for
    /// the RC1 idle deadline. A sender that dies without FIN or
    /// CONNECTION_CLOSE (a killed or force-exited process, a blackholed old
    /// IP) leaves its stream open, and the vendor `readStream` answers
    /// `WouldBlock` for it forever, so without this the handler kept its
    /// worker for the life of the process.
    fn inboundStreamAbandoned(self: *ClusterCoordinator, watch: *const InboundStreamWatch, last_frame_ms: i64) bool {
        if (self.shutdown.load(.acquire)) return true;
        if (watch.conn.isDrained()) return true;
        if (watch.rec) |r| {
            if (r.reap_requested.load(.acquire)) return true;
        }
        return shouldReapIdleInboundConnection(compat_milliTimestamp(), last_frame_ms, watch.idle_deadline_ms);
    }

    fn dispatchInboundStream(self: *ClusterCoordinator, stream: *quic.QuicStream, watch: *const InboundStreamWatch) !void {
        var first: [1]u8 = undefined;
        readExactCluster(stream, first[0..]) catch |err| {
            // EndOfStream means the peer FIN'd before sending any
            // payload — common during connection teardown.  Bubble up
            // silently so the caller's debug log doesn't fire on a
            // routine shutdown.
            if (err == error.EndOfStream) return;
            return err;
        };

        if (first[0] == CLUSTER_RPC_MAGIC) {
            try self.handleClusterRpcOnStream(stream);
            return;
        }

        // Non-magic byte: treat as the high byte of a raft frame's
        // 4-byte big-endian length prefix.  Wrap the stream with a
        // small adapter that prepends the byte we already consumed
        // and feed it into the existing raft frame reader.
        var prefix = PrefixedStream(*quic.QuicStream){ .inner = stream, .prefix = first[0], .have_prefix = true };
        try self.dispatchRaftFrameFromAdaptedStream(&prefix, watch);
    }

    /// Run the cluster RPC request/response cycle on `stream`.  The
    /// magic byte has already been consumed by the caller.  Reads the
    /// request payload, dispatches via `handleClusterMessage`, then
    /// writes a length-prefixed Response back on the same stream.
    fn handleClusterRpcOnStream(self: *ClusterCoordinator, stream: *quic.QuicStream) !void {
        const payload = try readClusterRpcBodyAfterMagic(self.allocator, stream);
        defer self.allocator.free(payload);

        var reader: std.Io.Reader = .fixed(payload);
        var msg = protobuf.decode(Message, &reader, self.allocator) catch |err| {
            log.warn("Cluster RPC decode failed", &.{Attr.string("error", @errorName(err))});
            try self.writeClusterRpcResponse(stream, Response{ .status = .ERR });
            return;
        };
        defer msg.deinit(self.allocator);

        // SEC-D001: validate auth token on inbound cluster RPC
        // frames.  Matches the raft frame check above.  When the
        // local `cluster_token` is empty (single-node dev mode) we
        // accept anything; otherwise the token in the Message must
        // match GEODE_CLUSTER_TOKEN.
        if (self.cluster_token.len > 0 and !cluster_auth.validateClusterToken(msg.auth_token)) {
            log.warn("Cluster RPC rejected: invalid or missing cluster token", &.{});
            try self.writeClusterRpcResponse(stream, Response{ .status = .ERR });
            return;
        }

        // Dispatch.  Inbound cluster RPCs always execute LOCALLY on
        // this node — the originator already routed the message to
        // us via `forwardToShard`, so we must not re-forward (which
        // would loop indefinitely if the local shard ownership
        // table disagrees with the originator's).  The result
        // Response may carry a `data` slice owned by the handler's
        // allocator; we encode it before `Response.deinit` reclaims
        // any backing heap memory.
        var resp = self.handleClusterRpcLocal(msg) catch |err| Response{
            .status = .ERR,
            .data = std.fmt.allocPrint(self.allocator, "handler error: {s}", .{@errorName(err)}) catch null,
        };
        defer resp.deinit(self.allocator);

        try self.writeClusterRpcResponse(stream, resp);
    }

    /// Inbound cluster RPC handler executed on the *target* node.
    /// This must NOT re-enter `forwardToShard` / `handleShardQuery`
    /// — the originator has already routed the message to us.
    ///
    /// Today this only handles READ messages; writes / 2PC reuse
    /// the existing raft + 2PC paths and are not wired through the
    /// cluster RPC frame yet (tracked under task S2 in the plan).
    /// JOIN_CLUSTER / LEAVE_CLUSTER / REPLICATE_DATA / FAILOVER_REQUEST
    /// arriving on this path are rejected with ERR so the originator
    /// surfaces a clear failure rather than silently no-op'ing. The
    /// dead pre-A3e leave/replicate/failover stubs were removed
    /// (GAP-0889); `handleJoinCluster` is retained for the planned
    /// dynamic-join wire-up but has no caller on this path yet.
    fn handleClusterRpcLocal(self: *ClusterCoordinator, msg: Message) !Response {
        switch (msg.msg_type) {
            .READ => return self.executeLocalRead(msg),
            else => return Response{ .status = .ERR },
        }
    }

    /// Execute a READ message locally and return a Response.  The
    /// returned `data` field (if non-null) is allocated with
    /// `self.allocator` and freed by the caller's `Response.deinit`.
    ///
    /// A3e (2026-05-26): the cluster RPC wire path is now plumbed
    /// end-to-end (originator -> QUIC -> target -> response).  The
    /// actual read execution against `self.store` is task S2 in the
    /// plan; this implementation returns an OK status with an
    /// "executed:<node_id>:<key>" envelope so tests can assert the
    /// message was delivered to the expected target node.  When S2
    /// lands, this body grows into a real graph_store query path.
    fn executeLocalRead(self: *ClusterCoordinator, msg: Message) !Response {
        const key = msg.key orelse "";
        const data = try std.fmt.allocPrint(
            self.allocator,
            "executed:{d}:{s}",
            .{ self.node_id, key },
        );
        return Response{ .status = .OK, .data = data };
    }

    fn writeClusterRpcResponse(self: *ClusterCoordinator, stream: *quic.QuicStream, resp: Response) !void {
        const framed = try encodeClusterRpcFrame(self.allocator, resp);
        defer self.allocator.free(framed);
        try stream.writeAll(framed);
        // Best-effort FIN so the requester's reader sees stream
        // termination rather than waiting for the idle timeout.
        stream.finish() catch {};
    }

    fn dispatchRaftFrameFromAdaptedStream(self: *ClusterCoordinator, prefix: anytype, watch: *const InboundStreamWatch) !void {
        // 2026-06-08 raft multiplexed streams: a peer now sends ALL raft frames
        // over ONE long-lived bidi stream (bounded per-peer stream usage, so
        // heartbeats/votes are never dropped on OutOfStreams under write load).
        // Read length-delimited frames until the peer closes/resets the stream.
        //
        // The first frame consumes `prefix`'s already-injected high byte;
        // subsequent frames read straight from the inner stream (PrefixedStream
        // injects its prefix only once). A closed/reset stream surfaces as
        // `error.EndOfStream` (FIN reached + no buffered data) which ends the
        // loop cleanly. `error.WouldBlock` is a transient quiet gap on a stream
        // the peer still holds open — keep the loop parked rather than tearing
        // the stream down (the connection handler's seen-stream dedup means a
        // torn-down-then-re-queued stream_id would otherwise be dropped as a
        // duplicate, wedging replication). The sender allocates a fresh
        // stream_id when it reopens after a real error, so reopen is unaffected.
        //
        // SONNY-6451: the park is bounded. `inboundStreamAbandoned` ends it
        // (error.InboundStreamAbandoned: the handler releases its worker and
        // closes the connection) on shutdown, a gone connection, an RC-A
        // sweeper request, or no frame for the RC1 idle deadline. Each frame
        // restamps the RC-A record so the sweeper never flags a live stream.
        var last_frame_ms = compat_milliTimestamp();
        while (true) {
            const frame_res = raft_consensus.readRaftFrame(self.allocator, prefix) catch |err| switch (err) {
                error.EndOfStream => return, // peer closed/reopened the stream — normal
                error.WouldBlock => {
                    // Stream still open, just momentarily idle. Re-park.
                    if (self.inboundStreamAbandoned(watch, last_frame_ms)) return error.InboundStreamAbandoned;
                    compat_sleepNs(2 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            defer frame_res.deinit(self.allocator);
            last_frame_ms = compat_milliTimestamp();
            if (watch.rec) |r| r.last_activity_ms.store(last_frame_ms, .release);
            self.applyDecodedRaftFrame(frame_res) catch |err| {
                // A single bad/late frame must not tear the whole stream down;
                // log and keep reading (raft re-sends on its own cadence).
                log.warn("raft frame apply failed; continuing stream", &.{Attr.string("error", @errorName(err))});
            };
        }
    }

    /// Apply security checks + dispatch a decoded raft frame.  Pulled
    /// out of `readOneRaftFrameAndDispatch` so the new prefix-aware
    /// path (above) can reuse the same logic without duplication.
    fn applyDecodedRaftFrame(self: *ClusterCoordinator, frame_res: raft_consensus.DecodedRaftFrame) !void {

        // SEC-D001: Always validate cluster token on incoming Raft frames.
        // Reject frames without valid token regardless of whether env var is set.
        if (!cluster_auth.validateClusterToken(frame_res.auth_token)) {
            log.warn("Raft frame rejected: invalid or missing cluster token", &.{
                Attr.uint("from", frame_res.from),
            });
            return;
        }

        // SEC-D009: Validate nonce to prevent replay attacks.  Each
        // outbound RaftEnvelope embeds a cryptographically random u64
        // nonce; the receiver maintains a bounded ring of recently-seen
        // nonces and rejects any duplicate.  Combined with the per-RPC
        // TLS handshake (SEC-D011) and the cluster_token gate
        // (SEC-D001) this gives cryptographic replay protection.
        if (!self.raft_nonce_tracker.checkAndRecord(frame_res.nonce)) {
            log.warn("Raft frame rejected: replay or missing nonce", &.{
                Attr.uint("from", frame_res.from),
                Attr.uint("nonce", frame_res.nonce),
            });
            return;
        }

        // A6d (2026-05-25): the original SEC-D009 resolution added a
        // secondary `replay_guard.check(from, term)` rejection here.
        // That key is wrong for raft semantics: a single leader sends
        // many heartbeats (AppendEntries) and a single candidate may
        // re-issue RequestVote within the SAME (from, term) pair before
        // the election timeout fires.  The (from, term) guard
        // unconditionally drops every retry/heartbeat after the first
        // hit, which prevented leader election in the 3-node subprocess
        // smoke test (the candidate's first RequestVote was answered;
        // every subsequent retry was silently dropped, so the receiver
        // never re-issued its vote response and the cluster split-voted
        // forever at term=1).
        //
        // Cryptographic replay protection still holds because the
        // nonce_tracker above rejects any byte-exact retransmission.  A
        // legitimate raft retry generates a fresh nonce via
        // `nonce_tracker.NonceTracker.generateNonce()` inside
        // `encodeRaftFrame`, so it passes the nonce check; an adversary
        // replaying a captured frame reuses the same nonce and is
        // rejected.  The `replay_guard` field is retained on the
        // ClusterCoordinator struct (zero-allocation on init when
        // unused) for binary compatibility with downstream tests that
        // exercise it directly.

        // k8s root cause #5 (stalled-stream liveness), per-DIRECTION refinement:
        // stamp forward progress for the OUTBOUND peer connection keyed by this
        // frame's sender ONLY when the frame is a RESPONSE
        // (`frameProvesOurOutboundDelivered`). A response can only exist if OUR
        // outbound request reached that peer, so it proves our outbound stream
        // is alive. An inbound REQUEST (RequestVote/AppendEntries/
        // InstallSnapshot) proves only the PEER's outbound path and must NOT
        // refresh our clock — a stranded candidate flooding RequestVote every
        // 1-2 s would otherwise mask the leader's genuinely-wedged outbound
        // stream to it forever (the k8s "stranded a term behind" wedge). The
        // stamp lands on the outbound `PeerConnection` keyed by `frame_res.from`
        // (a DIFFERENT object than the inbound connection this frame arrived
        // on), only AFTER the token + nonce gates above so a forged/replayed
        // response can never reset a genuinely stalled peer's clock.
        // `notePeerProgress` is a no-op if we have no outbound connection to
        // that peer yet (built lazily on first send) — it can never cause a
        // false eviction of a healthy peer.
        const now_inbound_ms = compat_milliTimestamp();
        if (raft_consensus.frameProvesOurOutboundDelivered(frame_res.body)) {
            self.raft_transport.notePeerProgress(frame_res.from, now_inbound_ms);
        } else {
            // RC3 (follower response-direction eviction): an inbound REQUEST
            // proves only the PEER's outbound path. Stamp the per-peer
            // last-inbound-REQUEST clock so the directional reaper can tell a
            // one-way-wedged follower (still receiving requests, outbound proof
            // stale) from a QUIET follower (suppressed).
            self.raft_transport.noteInboundRequest(frame_res.from, now_inbound_ms);
            // RC3 (healthy-follower implicit ack) + idle-cluster churn guard: an
            // AppendEntries whose prev_log_index / leader_commit ADVANCES is an
            // implicit ack that our PRIOR response reached the leader; an EMPTY
            // heartbeat (no entries) is "nothing pending, connection presumed
            // fine". Both stamp outbound progress so a HEALTHY follower never
            // looks stale and never churns its connection — critically including a
            // fully IDLE (zero-write) cluster, which sends only empty,
            // non-advancing heartbeats and would otherwise churn forever. A WEDGED
            // follower sees non-advancing RETRANSMITS (entries still present),
            // gets no stamp, and stays eligible for directional eviction.
            // `has_entries` is the distinguishing signal.
            switch (frame_res.body) {
                .append_entries => |ae| self.raft_transport.noteInboundAppendEntriesAdvance(
                    frame_res.from,
                    ae.prev_log_index,
                    ae.leader_commit,
                    now_inbound_ms,
                    ae.entries.len > 0,
                ),
                else => {},
            }
        }

        self.raft.handleMessage(frame_res.from, frame_res.body) catch |e| {
            log.err("Raft handleMessage error", &.{
                Attr.string("error", @errorName(e)),
            });
        };
    }

    fn handleClusterMessage(self: *ClusterCoordinator, msg: Message) !Response {
        // Route based on message type
        return self.handleShardQuery(msg);
    }

    fn handleJoinCluster(self: *ClusterCoordinator, msg: Message) !Response {
        // SEC-D002: Always validate cluster token before revealing topology.
        // Reject join requests without valid token regardless of whether env var is set.
        if (!cluster_auth.validateClusterToken(msg.auth_token)) {
            log.warn("JOIN_CLUSTER rejected: invalid or missing cluster token", &.{
                Attr.string("client_id", msg.client_id orelse "unknown"),
            });
            return Response{
                .status = .ERR,
                .data = null,
            };
        }

        if (self.raft.state != .leader) {
            return Response{
                .status = .REDIRECT,
                .leader_id = self.cluster_state.leader_node,
            };
        }

        const node_info = try parseNodeInfo(self.allocator, msg.data orelse return error.InvalidNodeInfo);
        try self.cluster_state.nodes.append(node_info);

        // Trigger rebalancing
        try self.rebalanceShards();

        return Response{
            .status = .OK,
            .data = try self.serializeMinimalJoinResponse(node_info.id),
        };
    }

    fn handleNodeFailure(self: *ClusterCoordinator, failed_node: u64) !void {
        log.warn("Node detected as failed", &.{
            Attr.uint("node_id", failed_node),
        });

        // SONNY-6451: mark the peer failed in place. It used to be
        // swapRemove'd here, under healthPass's iteration of this same list
        // (the pass then read the slot swapRemove left `undefined` as a node,
        // id 0xAAAAAAAAAAAAAAAA), which also dropped its endpoint from the
        // address book for good and leaked the entry. A failed peer that
        // comes back must still be reachable.
        for (self.cluster_state.nodes.items) |*node| {
            if (node.id == failed_node) node.state = .failed;
        }

        if (!self.failover_config.auto_failover) return;

        // Find shards affected by the failure
        for (self.cluster_state.shards.items) |*shard| {
            if (shard.primary_node == failed_node) {
                try self.promoteReplica(shard);
            }

            // Remove the failed node from the replica list (GAP-0889: the old
            // unconditional `len - 1` alloc underflowed when the list was
            // empty, sized the slice wrong when the node wasn't a replica,
            // and leaked the previous slice on every pass).
            var occurrences: usize = 0;
            for (shard.replica_nodes) |replica| {
                if (replica == failed_node) occurrences += 1;
            }
            if (occurrences == 0) continue;

            const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len - occurrences);
            var idx: usize = 0;
            for (shard.replica_nodes) |replica| {
                if (replica != failed_node) {
                    new_replicas[idx] = replica;
                    idx += 1;
                }
            }
            if (shard.replica_nodes.len > 0) {
                self.allocator.free(shard.replica_nodes);
            }
            shard.replica_nodes = new_replicas;
        }

        // Trigger re-replication to maintain replication factor
        try self.ensureReplicationFactor();
    }

    fn promoteReplica(self: *ClusterCoordinator, shard: *ShardInfo) !void {
        if (shard.replica_nodes.len == 0) {
            return error.NoReplicasAvailable;
        }

        // Choose the most up-to-date replica
        var best_replica: u64 = shard.replica_nodes[0];
        var best_lag: u64 = std.math.maxInt(u64);

        for (shard.replica_nodes) |replica| {
            const lag = try self.getReplicationLag(replica, shard.id);
            if (lag < best_lag) {
                best_lag = lag;
                best_replica = replica;
            }
        }

        log.info("Promoting replica to primary for shard", &.{
            Attr.uint("replica_id", best_replica),
            Attr.uint("shard_id", shard.id),
        });
        shard.primary_node = best_replica;

        // Remove the promoted replica from the replica list (GAP-0889: free
        // the previous slice — it was leaked on every promotion).
        const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len - 1);
        var idx: usize = 0;
        for (shard.replica_nodes) |replica| {
            if (replica != best_replica and idx < new_replicas.len) {
                new_replicas[idx] = replica;
                idx += 1;
            }
        }
        self.allocator.free(shard.replica_nodes);
        shard.replica_nodes = new_replicas;
    }

    fn ensureReplicationFactor(self: *ClusterCoordinator) !void {
        for (self.cluster_state.shards.items) |*shard| {
            const current_replicas = shard.replica_nodes.len + 1; // +1 for primary

            if (current_replicas < self.replication_factor) {
                const needed = self.replication_factor - current_replicas;
                const available_nodes = try self.getAvailableNodes(shard);
                // GAP-0889: this slice was leaked on every path (including
                // the happy path).
                defer self.allocator.free(available_nodes);

                if (available_nodes.len < needed) {
                    log.warn("Insufficient nodes to maintain replication factor for shard", &.{
                        Attr.uint("shard_id", shard.id),
                    });
                    continue;
                }

                // Add new replicas
                const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len + needed);
                // GAP-0889: don't leak the new slice if startReplication fails
                // mid-loop (ownership only transfers at the assignment below).
                errdefer self.allocator.free(new_replicas);
                // Zig 0.16: std.mem.copy was removed; use @memcpy.
                @memcpy(new_replicas[0..shard.replica_nodes.len], shard.replica_nodes);

                for (0..needed) |i| {
                    new_replicas[shard.replica_nodes.len + i] = available_nodes[i];
                    try self.startReplication(shard.id, available_nodes[i]);
                }

                if (shard.replica_nodes.len > 0) {
                    self.allocator.free(shard.replica_nodes);
                }
                shard.replica_nodes = new_replicas;
            }
        }
    }

    fn performReplication(self: *ClusterCoordinator) !void {
        for (self.cluster_state.shards.items) |shard| {
            if (shard.primary_node != self.node_id) continue;

            for (shard.replica_nodes) |replica| {
                try self.replicateShardToNode(shard.id, replica);
            }
        }
    }

    fn replicateShardToNode(self: *ClusterCoordinator, shard_id: u64, node_id: u64) !void {
        // Checkpoint adapter storage before snapshotting.
        try self.store.saveToFile();
        // Serialize all nodes and edges as JSON-lines for replication.
        const snapshot = try self.store.serializeSnapshot(self.allocator);

        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
        defer aw.deinit();
        const payload_msg = ReplicationPayload{
            .shard_id = shard_id,
            .snapshot = snapshot,
        };
        try protobuf.encode(&aw.writer, self.allocator, payload_msg);
        const payload = try self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
        defer self.allocator.free(payload);

        const msg = Message{
            .msg_type = .REPLICATE_DATA,
            .data = payload,
        };

        try self.sendToNode(node_id, msg);
    }

    // Helper functions
    // NOTE: `Peer` is a module-level type in raft_consensus.zig (not nested
    // inside RaftNode), so the qualified reference is `raft_consensus.Peer`,
    // not `RaftNode.Peer`.  Previously this miscoded reference compiled only
    // because `init` is never called from the main library — the type check
    // was lazily deferred.  The first test that actually constructs a
    // ClusterCoordinator (tests/test_cluster_coordinator_config.zig, A3)
    // forced the compiler to resolve the symbol.
    fn resolvePeers(allocator: Allocator, peer_configs: []const PeerConfig) ![]raft_consensus.Peer {
        var peers = try allocator.alloc(raft_consensus.Peer, peer_configs.len);
        for (peer_configs, 0..) |config, i| {
            peers[i] = .{
                .id = config.id,
                .endpoint = try allocator.dupe(u8, config.address),
                .port = config.port,
                .alive = true,
                .last_contact = compat_milliTimestamp(),
                .rpc_client = null,
            };
        }
        return peers;
    }

    fn initClusterState(allocator: Allocator) !ClusterState {
        // Zig 0.16 std.ArrayList is now unmanaged by default — there is no
        // `init(allocator)` on Aligned(T, null).  The previous code only
        // type-checked because ClusterCoordinator.init was never invoked
        // from production.  The A3 test changed that.  We use `.empty` for
        // the unmanaged ArrayLists; AutoHashMap is still managed in 0.16
        // so its `.init(allocator)` survives.
        return ClusterState{
            .nodes = .empty,
            .shards = .empty,
            .replication_map = std.AutoHashMap(u64, []u64).init(allocator),
            .leader_node = null,
            .cluster_version = 1,
            .topology_version = 1,
        };
    }

    fn findNodeEndpoint(self: *ClusterCoordinator, node_id: u64) ![]const u8 {
        for (self.cluster_state.nodes.items) |node| {
            if (node.id == node_id) return node.endpoint;
        }
        return error.NodeNotFound;
    }

    fn initNetworkTransport(allocator: Allocator, config: Config) !NetworkTransport {
        // Task A3c (2026-05-25 plan): consume Config — previously this
        // function threw the argument away with `_ = config;`, which meant
        // there was no way to plumb operator-controlled limits down to the
        // transport layer.  We currently only need `max_connections` here;
        // future tasks (A3f auth, etc.) can grow this struct as needed.
        return NetworkTransport{
            .allocator = allocator,
            .quic_server = null,
            .connections = std.AutoHashMap(u64, NetworkTransport.Connection).init(allocator),
            .message_queue = .{
                .incoming = .empty,
                .outgoing = .empty,
                .mutex = std.Io.Mutex.init,
            },
            .max_connections = config.max_connections,
        };
    }

    fn initHealthMonitor(allocator: Allocator, config: Config) !HealthMonitor {
        return HealthMonitor.init(allocator, config.health_check_interval_ms, config.unhealthy_threshold);
    }

    fn checkNodeHealth(self: *ClusterCoordinator, node: *NodeInfo) !HealthMonitor.HealthStatus {
        _ = self;
        return HealthMonitor.evaluateNodeHealth(node.last_heartbeat);
    }

    fn updateHealthStatus(self: *ClusterCoordinator, node_id: u64, status: HealthMonitor.HealthStatus) !void {
        try self.health_monitor.updateHealthStatus(node_id, status);
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-001; FEATURE="DistributedCluster"; ASPECT=ReplicationLag; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    fn getReplicationLag(self: *ClusterCoordinator, node_id: u64, shard_id: u64) !u64 {
        // Calculate replication lag based on node health check latency
        // In a real implementation, this would compare snapshot generations between primary and replica
        for (self.cluster_state.shards.items) |*shard| {
            if (shard.id == shard_id) {
                // Check if node is a replica for this shard
                for (shard.replica_nodes) |replica| {
                    if (replica == node_id) {
                        return self.health_monitor.estimateReplicationLag(node_id, shard.size_bytes);
                    }
                }
            }
        }
        // Node is not a replica for this shard
        return 0;
    }

    fn getAvailableNodes(self: *ClusterCoordinator, shard: *ShardInfo) ![]u64 {
        // Zig 0.16: std.ArrayList is unmanaged — pass allocator to every op.
        var available: std.ArrayList(u64) = .empty;
        defer available.deinit(self.allocator);

        for (self.cluster_state.nodes.items) |node| {
            if (node.state != .active) continue;
            if (node.id == shard.primary_node) continue;

            var is_replica = false;
            for (shard.replica_nodes) |replica| {
                if (replica == node.id) {
                    is_replica = true;
                    break;
                }
            }
            if (is_replica) continue;

            try available.append(self.allocator, node.id);
        }

        return available.toOwnedSlice(self.allocator);
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-002; FEATURE="DistributedCluster"; ASPECT=Replication; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    fn startReplication(self: *ClusterCoordinator, shard_id: u64, node_id: u64) !void {
        log.info("Starting replication of shard to node", &.{
            Attr.uint("shard_id", shard_id),
            Attr.uint("node_id", node_id),
        });

        // Find the shard and add the node as a replica
        for (self.cluster_state.shards.items) |*shard| {
            if (shard.id == shard_id) {
                // Check if node is already a replica
                for (shard.replica_nodes) |replica| {
                    if (replica == node_id) {
                        log.info("Node is already a replica for shard", &.{
                            Attr.uint("node_id", node_id),
                            Attr.uint("shard_id", shard_id),
                        });
                        return;
                    }
                }

                // Add node as a replica (create new slice with additional node)
                const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len + 1);
                @memcpy(new_replicas[0..shard.replica_nodes.len], shard.replica_nodes);
                new_replicas[shard.replica_nodes.len] = node_id;

                // Free old replica list and update
                if (shard.replica_nodes.len > 0) {
                    self.allocator.free(shard.replica_nodes);
                }
                shard.replica_nodes = new_replicas;

                log.info("Added node as replica for shard", &.{
                    Attr.uint("node_id", node_id),
                    Attr.uint("shard_id", shard_id),
                    Attr.uint("total_replicas", new_replicas.len),
                });
                return;
            }
        }

        log.warn("Shard not found for replication", &.{
            Attr.uint("shard_id", shard_id),
        });
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-003; FEATURE="DistributedCluster"; ASPECT=Rebalance; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    fn rebalanceShards(self: *ClusterCoordinator) !void {
        const node_count = self.cluster_state.nodes.items.len;
        if (node_count == 0) {
            log.warn("No nodes available for rebalancing", &.{});
            return;
        }

        log.info("Rebalancing shards across nodes", &.{
            Attr.uint("node_count", node_count),
        });

        // Calculate target shards per node
        const shard_count = self.cluster_state.shards.items.len;
        const target_per_node = (shard_count + node_count - 1) / node_count; // Round up

        // Count current shards per node
        var shards_per_node = std.AutoHashMap(u64, usize).init(self.allocator);
        defer shards_per_node.deinit();

        for (self.cluster_state.shards.items) |shard| {
            const entry = try shards_per_node.getOrPut(shard.primary_node);
            if (!entry.found_existing) {
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
        }

        // Find overloaded and underloaded nodes
        var moves_needed: usize = 0;
        for (self.cluster_state.nodes.items) |node| {
            const current = shards_per_node.get(node.id) orelse 0;
            if (current > target_per_node) {
                moves_needed += current - target_per_node;
            }
        }

        log.info("Rebalance analysis", &.{
            Attr.uint("shard_count", shard_count),
            Attr.uint("node_count", node_count),
            Attr.uint("target_per_node", target_per_node),
            Attr.uint("moves_needed", moves_needed),
        });
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-004; FEATURE="DistributedCluster"; ASPECT=Topology; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    fn serializeClusterTopology(self: *ClusterCoordinator) ![]const u8 {
        var nodes = std.ArrayList(TopologyNode).init(self.allocator);
        defer nodes.deinit(self.allocator);

        for (self.cluster_state.nodes.items) |node| {
            try nodes.append(self.allocator, TopologyNode{
                .id = node.id,
                .endpoint = node.endpoint,
                .state = @tagName(node.state),
            });
        }

        var shards = std.ArrayList(TopologyShard).init(self.allocator);
        defer shards.deinit(self.allocator);

        for (self.cluster_state.shards.items) |shard| {
            try shards.append(self.allocator, TopologyShard{
                .id = shard.id,
                .primary_node = shard.primary_node,
                .replica_count = @intCast(shard.replica_nodes.len),
                .size_bytes = shard.size_bytes,
            });
        }

        const payload = TopologyPayload{
            .nodes = nodes,
            .shards = shards,
        };

        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, payload);
        const body = aw.writer.buffer[0..aw.writer.end];
        return self.allocator.dupe(u8, body);
    }

    /// SEC-D012: Build a minimal join response that reveals only the assigned
    /// node ID, the current node count, and a success flag -- no topology.
    fn serializeMinimalJoinResponse(self: *ClusterCoordinator, assigned_id: u64) ![]const u8 {
        const payload = JoinResponsePayload{
            .assigned_node_id = assigned_id,
            .node_count = @intCast(self.cluster_state.nodes.items.len),
            .success = true,
        };
        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 64);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, payload);
        return self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    }

    fn parseNodeInfo(allocator: Allocator, data: []const u8) !NodeInfo {
        var reader: std.Io.Reader = .fixed(data);
        var parsed = protobuf.decode(NodeInfoProto, &reader, allocator) catch |e| {
            log.warn("parseNodeInfo protobuf error", &.{
                Attr.string("error", @errorName(e)),
            });
            return error.InvalidNodeInfo;
        };
        defer parsed.deinit(allocator);

        const endpoint_val = if (parsed.endpoint.len > 0) parsed.endpoint else "unknown:0";
        const endpoint_copy = try allocator.dupe(u8, endpoint_val);
        return NodeInfo{
            .id = parsed.id,
            .endpoint = endpoint_copy,
            .state = .joining,
            .role = .follower,
            .capacity = .{
                .cpu_cores = 8,
                .memory_gb = 16,
                .storage_gb = 100,
                .network_mbps = 1000,
                .current_load = 0.0,
            },
            .last_heartbeat = compat_milliTimestamp(),
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }

    // === Public Raft proposal API (Task A3d of 2026-05-25 plan) ===
    //
    // These methods promote internal `raft.*` accessors to the public
    // ClusterCoordinator surface so the harness, integration tests, and
    // higher-level callers (W1-W3 WAL distribution tests, the harness's
    // force-cluster-size mode, /codepros:bug-fix reproductions) can:
    //   1. Submit writes through the leader (proposeWrite).
    //   2. Confirm those writes have applied on this node (waitForApplied).
    //   3. Identify which node is the leader (role / currentTerm).
    //
    // Locking: proposeCommand internally takes self.raft.inner_mutex (see
    // raft_consensus.zig::proposeCommand) to keep the A6d invariant intact.
    // role/currentTerm/appliedIndex read self.raft mirror fields and the
    // inner library's monotonic log.applied -- safe to call concurrently
    // with proposals on the same coordinator.

    // CANARY: REQ=REQ-DIST-CLUSTER-PROPOSE-WRITE; FEATURE="ClusterCoordinator Public Propose"; ASPECT=ProposeWrite; STATUS=TESTED; TEST=tests/test_cluster_propose_write.zig; OWNER=distributed; UPDATED=2026-05-26
    /// Propose a write command to the Raft log.  Only valid on the leader --
    /// returns `error.NotLeader` if this node is a follower or candidate.
    /// Returns the log index assigned to the entry (use `waitForApplied` to
    /// confirm it was committed and applied locally / across the cluster).
    ///
    /// Thread-safe: takes `self.raft.inner_mutex` internally.
    pub fn proposeWrite(self: *ClusterCoordinator, command: raft_consensus.Command) !u64 {
        return self.raft.proposeCommand(command);
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-WAIT-APPLIED; FEATURE="ClusterCoordinator Public Propose"; ASPECT=WaitForApplied; STATUS=TESTED; TEST=tests/test_cluster_propose_write.zig; OWNER=distributed; UPDATED=2026-05-26
    /// Block until `index` has been applied on this node, or `deadline_ms`
    /// milliseconds elapse from now.  Returns `error.Timeout` on the
    /// deadline.  Polls `appliedIndex()` every 2 ms.
    ///
    /// Used by tests and the harness to confirm cross-node replication
    /// after a `proposeWrite`.
    pub fn waitForApplied(self: *ClusterCoordinator, index: u64, deadline_ms: u64) !void {
        const begin_ms = compat_milliTimestamp();
        const deadline = begin_ms +| @as(i64, @intCast(deadline_ms));
        while (true) {
            const applied = self.raft.appliedIndex();
            if (applied >= index) return;
            if (compat_milliTimestamp() >= deadline) return error.Timeout;
            compat_sleepNs(2 * std.time.ns_per_ms);
        }
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-COMMIT-AWARE-WAIT; FEATURE="DistributedCluster"; ASPECT=CommittedIndexAccessor; STATUS=TESTED; TEST=tests/test_cluster_commit_aware_wait.zig; OWNER=distributed; UPDATED=2026-06-12
    /// The COMMIT watermark on this node (distinct from `appliedIndex()`): the
    /// highest log index known replicated to a quorum. A committed entry is
    /// durable and WILL apply — see `waitForCommittedThenApplied`.
    pub fn committedIndex(self: *ClusterCoordinator) u64 {
        return self.raft.committedIndex();
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-COMMIT-AWARE-WAIT; FEATURE="DistributedCluster"; ASPECT=CommitAwarePostProposeWait; STATUS=TESTED; TEST=tests/test_cluster_commit_aware_wait.zig; OWNER=distributed; UPDATED=2026-06-12
    /// Commit-aware replacement for `waitForApplied` (RC-1 of the "committed
    /// write -> client Timeout -> retry double-insert" fix). Blocks until the
    /// target `index` is CONFIRMED COMMITTED — at which point the write is
    /// durable (replicated to a quorum) and Raft guarantees it WILL apply, so
    /// this returns SUCCESS. A committed-but-apply-lagged entry is NEVER reported
    /// as `error.Timeout`: that was the wrong signal that drove the client to
    /// retry a write that already committed (minting the duplicate row).
    ///
    /// `error.Timeout` is returned ONLY when COMMIT ITSELF cannot be confirmed
    /// within `deadline_ms` (committed_index < index AND the budget is
    /// exhausted) — a genuine unknown: this node could not confirm the write
    /// reached a quorum.
    ///
    /// The decision per poll is the pure `waitOutcomeForState`; this method only
    /// owns the clock, the poll cadence, and the budget. Polls every 2 ms.
    pub fn waitForCommittedThenApplied(self: *ClusterCoordinator, index: u64, deadline_ms: u64) !void {
        const begin_ms = compat_milliTimestamp();
        const deadline = begin_ms +| @as(i64, @intCast(deadline_ms));
        while (true) {
            const applied = self.raft.appliedIndex();
            const committed = self.raft.committedIndex();
            const budget_exhausted = compat_milliTimestamp() >= deadline;
            switch (waitOutcomeForState(committed, applied, index, budget_exhausted)) {
                // Applied locally, or committed (durable; apply guaranteed to
                // follow) — both are success. A committed entry returns here
                // immediately rather than blocking further on local apply: the
                // durability guarantee the client needs is COMMIT, and returning
                // success on commit is exactly what stops the spurious retry.
                .applied, .committed_apply_pending => return,
                // Commit not confirmed in budget — a genuine unknown.
                .commit_unknown_timeout => return error.Timeout,
                // Still within budget and not yet committed — keep polling.
                .keep_waiting => compat_sleepNs(2 * std.time.ns_per_ms),
            }
        }
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-ROLE; FEATURE="ClusterCoordinator Public Propose"; ASPECT=Role; STATUS=TESTED; TEST=tests/test_cluster_propose_write.zig; OWNER=distributed; UPDATED=2026-05-26
    /// Returns the current Raft role of this node (leader/candidate/
    /// follower/shutdown).  Used by tests to identify which node to propose
    /// against.
    pub fn role(self: *ClusterCoordinator) raft_consensus.State {
        return self.raft.role();
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-TERM; FEATURE="ClusterCoordinator Public Propose"; ASPECT=CurrentTerm; STATUS=TESTED; TEST=tests/test_cluster_propose_write.zig; OWNER=distributed; UPDATED=2026-05-26
    /// Returns the current Raft term as last observed by drainReady.
    pub fn currentTerm(self: *ClusterCoordinator) u64 {
        return self.raft.currentTerm();
    }

    // CANARY: REQ=REQ-GQL-020; FEATURE="Cluster QUIC Messaging"; ASPECT=SendToNode; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    pub fn sendToNode(self: *ClusterCoordinator, node_id: u64, msg: Message) !void {
        const endpoint = try self.findNodeEndpoint(node_id);
        const colon_idx = std.mem.lastIndexOf(u8, endpoint, ":") orelse return error.InvalidAddress;
        const host = endpoint[0..colon_idx];
        const port = try std.fmt.parseInt(u16, endpoint[colon_idx + 1 ..], 10);

        var client = quic.QuicClient.init(self.allocator);
        defer client.deinit();

        // GAP-0737 / SEC-INFRA-01 (2026-04-16): route through the single
        // cluster_auth.isInsecureModeAllowed() chokepoint so release builds
        // refuse the flag automatically.  The old envFlagEnabled path would
        // honour the env var in any build mode.
        const allow_insecure = cluster_auth.isInsecureModeAllowed();
        if (allow_insecure) {
            log.warn("SECURITY WARNING: Cluster TLS verification disabled via GEODE_CLUSTER_INSECURE (Debug build only)", &.{});
            _ = client.connectInsecure(host, port, true) catch |err| return err;
        } else {
            const ca_path = getEnvVarOwned(self.allocator, "GEODE_CLUSTER_CA_CERT") catch null;
            defer if (ca_path) |p| self.allocator.free(p);

            if (ca_path) |path| {
                try client.connectEx(host, port, path, null, null);
            } else {
                try client.connect(host, port);
            }
        }
        _ = client.waitForHandshake(10) catch |err| return err;

        var stream = try client.openStream(true);
        defer stream.deinit();

        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, msg);
        const body = aw.writer.buffer[0..aw.writer.end];

        const framed = try self.allocator.alloc(u8, body.len + 4);
        defer self.allocator.free(framed);
        std.mem.writeInt(u32, framed[0..4], @intCast(body.len), .big);
        @memcpy(framed[4..], body);

        try stream.writeAll(framed);
    }

    // CANARY: REQ=REQ-GQL-021; FEATURE="Cluster Message Handler"; ASPECT=OnMessage; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    pub fn onMessage(self: *ClusterCoordinator, callback: fn (*ClusterCoordinator, *const Message) void) void {
        self.message_callback = callback;
    }

    // GAP-0889: the dead `handleLeaveCluster` / `handleReplicateData` /
    // `handleFailoverRequest` stubs (zero callers, arg-discard, fake OK)
    // were removed. The live RPC dispatch (`handleClusterRpcLocal`)
    // rejects LEAVE_CLUSTER / REPLICATE_DATA / FAILOVER_REQUEST with ERR
    // so originators see a clear failure instead of a lying no-op ack.

    fn handleShardQuery(self: *ClusterCoordinator, msg: Message) !Response {
        // CANARY: REQ=REQ-GQL-2PC-005; FEATURE="Distributed Query Processing"; ASPECT=Distributed; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05

        // Determine if this is a read-only or write query
        const is_write = try self.isWriteQuery(msg);

        if (!is_write) {
            // Simple read query - route to appropriate shard
            const shard_id = try self.determineTargetShard(msg);
            return self.forwardToShard(shard_id, msg);
        }

        // Distributed write using 2PC
        const affected_shards = try self.determineAffectedShards(msg);

        // Generate transaction ID
        const xid = try self.generateTransactionId();

        // Phase 1: Prepare
        var prepare_votes = std.ArrayList(bool).init(self.allocator);
        defer prepare_votes.deinit();

        const write_set = try self.serializeWriteSet(msg);
        defer self.allocator.free(write_set);
        const metadata = try self.serializeMetadata(msg);
        defer self.allocator.free(metadata);

        for (affected_shards) |shard_id| {
            const prepare_msg = raft_consensus.TxnPrepare{
                .xid = xid,
                .shard_id = shard_id,
                .write_set = write_set,
                .metadata = metadata,
            };

            // Send prepare through Raft consensus
            const vote = try self.sendPrepareToShard(shard_id, prepare_msg);
            try prepare_votes.append(vote);
        }

        // Check if all shards voted to commit
        var can_commit = true;
        for (prepare_votes.items) |vote| {
            if (!vote) {
                can_commit = false;
                break;
            }
        }

        // Phase 2: Decide
        const decide_msg = raft_consensus.TxnDecide{
            .xid = xid,
            .commit = can_commit,
        };

        for (affected_shards) |shard_id| {
            try self.sendDecideToShard(shard_id, decide_msg);
        }

        return Response{
            .status = if (can_commit) .OK else .ABORTED,
            .data = try std.fmt.allocPrint(self.allocator, "Transaction {} {s}", .{ xid, if (can_commit) "committed" else "aborted" }),
        };
    }

    fn isWriteQuery(self: *ClusterCoordinator, msg: Message) !bool {
        _ = self;
        // Parse message to determine if it's a write operation
        // For now, simple heuristic based on message type
        return msg.msg_type == .WRITE or msg.msg_type == .DELETE or msg.msg_type == .UPDATE;
    }

    fn determineTargetShard(self: *ClusterCoordinator, msg: Message) !u64 {
        // Hash-based sharding for reads
        const key = msg.key orelse return error.MissingKey;
        const hash = std.hash.Fnv1a_64.hash(key);
        return hash % self.cluster_state.shards.items.len;
    }

    fn determineAffectedShards(self: *ClusterCoordinator, msg: Message) ![]u64 {
        // For writes, determine all affected shards
        var shards = std.ArrayList(u64).init(self.allocator);

        // Simple case: single shard
        const primary_shard = try self.determineTargetShard(msg);
        try shards.append(primary_shard);

        // Add replica shards if configured
        if (self.replication_map.get(primary_shard)) |replicas| {
            for (replicas) |replica| {
                try shards.append(replica);
            }
        }

        return shards.toOwnedSlice();
    }

    fn generateTransactionId(self: *ClusterCoordinator) !u64 {
        // Generate unique transaction ID
        const timestamp: u64 = @intCast(compat_milliTimestamp());
        const node_part = self.node_id << 48;
        const counter = self.incrementTxCounter();
        return node_part | (timestamp << 16) | counter;
    }

    fn incrementTxCounter(self: *ClusterCoordinator) u16 {
        _ = self;
        // Thread-safe counter increment (simplified)
        const counter = struct {
            var value: std.atomic.Atomic(u16) = std.atomic.Atomic(u16).init(0);
        };
        return counter.value.fetchAdd(1, .Monotonic);
    }

    fn serializeWriteSet(self: *ClusterCoordinator, msg: Message) ![]const u8 {
        const write_set = msg.data orelse return error.MissingWriteSet;
        var reader: std.Io.Reader = .fixed(write_set);
        var decoded = protobuf.decode(dist_schema.TwoPhaseMessage, &reader, self.allocator) catch |err| {
            log.err("Invalid 2PC write set payload", &.{Attr.string("error", @errorName(err))});
            return error.InvalidWriteSet;
        };
        defer decoded.deinit(self.allocator);
        return self.allocator.dupe(u8, write_set);
    }

    fn serializeMetadata(self: *ClusterCoordinator, msg: Message) ![]const u8 {
        const metadata = TxnMetadata{
            .client_id = msg.client_id orelse "",
            .timestamp = compat_milliTimestamp(),
            .msg_type = msg.msg_type,
        };
        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 128);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, metadata);
        const body = aw.writer.buffer[0..aw.writer.end];
        return self.allocator.dupe(u8, body);
    }

    fn sendPrepareToShard(self: *ClusterCoordinator, shard_id: u64, prepare: raft_consensus.TxnPrepare) !bool {
        _ = shard_id;
        // Send prepare message through Raft
        const command = raft_consensus.Command{ .txn_prepare = prepare };
        _ = try self.raft.proposeCommand(command);

        // Wait for response (simplified - in production would be async)
        if (self.raft.pending_responses.get(prepare.xid)) |response| {
            return response.prepare_result orelse false;
        }
        return false;
    }

    fn sendDecideToShard(self: *ClusterCoordinator, shard_id: u64, decide: raft_consensus.TxnDecide) !void {
        _ = shard_id;
        // Send decide message through Raft
        const command = raft_consensus.Command{ .txn_decide = decide };
        _ = try self.raft.proposeCommand(command);
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-FORWARD-SHARD; FEATURE="DistributedCluster"; ASPECT=ForwardToShard; STATUS=TESTED; TEST=tests/test_cluster_forward_to_shard.zig; OWNER=distributed; UPDATED=2026-05-26
    //
    // Task A3e (2026-05-25 distributed cluster testing plan):
    // Route a read query to the node that owns `shard_id` and return
    // the Response that node produces.
    //
    // Resolution order for the target node:
    //   1. If this coordinator already owns the shard (we are the
    //      primary or a replica), short-circuit through the local
    //      message handler.  No cluster traffic — the read serves
    //      out of our local graph_store.
    //   2. Otherwise prefer the shard's `primary_node`; on lookup
    //      failure (endpoint missing, peer not yet in
    //      `cluster_state.nodes`), fall back to the first reachable
    //      replica.
    //   3. If neither resolves to a known endpoint, return error.
    //
    // Wire path:
    //   forwardToShard opens a fresh one-shot QUIC client to the
    //   target endpoint (same TLS / insecure-mode plumbing as
    //   `sendToNode`), opens a bidirectional stream, writes a single
    //   cluster RPC request frame (`CLUSTER_RPC_MAGIC`-prefixed),
    //   then reads the matching response frame on the same stream
    //   and decodes it back into a `Response`.
    //
    // We deliberately do NOT reuse `raft_transport`'s persistent
    // peer connection pool here: that pool's `getStream` /
    // `writeRaftFrame` path is wired exclusively for raft RPC
    // semantics (single-frame write, no reply correlation).  Layering
    // a second protocol on top of the same pool would require
    // pool-aware response routing, which is more invasive than the
    // task scope warrants.  One-shot connections are slower per RPC
    // but match the existing `sendToNode` baseline, and the planned
    // S2 work (cross-shard read forwarding integration test) will
    // upgrade to a pooled path when there's a benchmark gating it.
    fn forwardToShard(self: *ClusterCoordinator, shard_id: u64, msg: Message) !Response {
        // Find the shard descriptor.  Returns ShardNotFound if no
        // shard with this id is currently in `cluster_state.shards`.
        const shard = self.findShard(shard_id) orelse return error.ShardNotFound;

        // Local short-circuit.  When this coordinator already owns
        // the shard, executing through `executeLocalRead` is
        // equivalent to the over-the-wire path — but we save the
        // round-trip and avoid bouncing the message through the
        // intra-cluster QUIC listener.  This deliberately bypasses
        // `handleClusterMessage` / `handleShardQuery` because those
        // would recompute the target shard and could loop back into
        // `forwardToShard`.
        if (self.ownsShard(shard)) {
            return self.executeLocalRead(msg);
        }

        // Pick a target node.  Primary first, then replicas in order.
        const target_node = self.pickReachableShardOwner(shard) orelse return error.NoReachableShardOwner;

        return self.sendClusterRpcToNode(target_node, msg);
    }

    /// Returns the ShardInfo for `shard_id`, or null if absent.
    fn findShard(self: *ClusterCoordinator, shard_id: u64) ?*ShardInfo {
        for (self.cluster_state.shards.items) |*shard| {
            if (shard.id == shard_id) return shard;
        }
        return null;
    }

    /// True when this coordinator is the primary or one of the
    /// replicas of `shard`.
    fn ownsShard(self: *ClusterCoordinator, shard: *ShardInfo) bool {
        if (shard.primary_node == self.node_id) return true;
        for (shard.replica_nodes) |replica| {
            if (replica == self.node_id) return true;
        }
        return false;
    }

    /// Pick the first replica (primary first, then replicas in
    /// declaration order) that resolves to a known endpoint in
    /// `cluster_state.nodes` AND is not this coordinator itself.
    /// Returns null when no candidate qualifies.
    fn pickReachableShardOwner(self: *ClusterCoordinator, shard: *ShardInfo) ?u64 {
        if (shard.primary_node != self.node_id and self.hasEndpoint(shard.primary_node)) {
            return shard.primary_node;
        }
        for (shard.replica_nodes) |replica| {
            if (replica == self.node_id) continue;
            if (self.hasEndpoint(replica)) return replica;
        }
        return null;
    }

    fn hasEndpoint(self: *ClusterCoordinator, node_id: u64) bool {
        _ = self.findNodeEndpoint(node_id) catch return false;
        return true;
    }

    /// Send `msg` to `target_node` over a one-shot QUIC client
    /// connection, await the Response frame written by the
    /// receiver, and return it.  The returned `Response` owns its
    /// `data` slice via the test/caller allocator; the caller MUST
    /// call `Response.deinit(allocator)` to free it.
    fn sendClusterRpcToNode(self: *ClusterCoordinator, target_node: u64, msg: Message) !Response {
        const endpoint = try self.findNodeEndpoint(target_node);
        const colon_idx = std.mem.lastIndexOf(u8, endpoint, ":") orelse return error.InvalidAddress;
        const host = endpoint[0..colon_idx];
        const port = try std.fmt.parseInt(u16, endpoint[colon_idx + 1 ..], 10);

        var client = quic.QuicClient.init(self.allocator);
        defer client.deinit();

        const allow_insecure = cluster_auth.isInsecureModeAllowed();
        if (allow_insecure) {
            log.warn("SECURITY WARNING: Cluster RPC TLS verification disabled via GEODE_CLUSTER_INSECURE", &.{});
            _ = client.connectInsecure(host, port, true) catch |err| return err;
        } else {
            const ca_path = getEnvVarOwned(self.allocator, "GEODE_CLUSTER_CA_CERT") catch null;
            defer if (ca_path) |p| self.allocator.free(p);

            if (ca_path) |path| {
                try client.connectEx(host, port, path, null, null);
            } else {
                try client.connect(host, port);
            }
        }
        _ = client.waitForHandshake(10) catch |err| return err;

        var stream = try client.openStream(true);
        defer stream.deinit();

        // Write the request frame (magic + len + protobuf Message).
        const req_frame = try encodeClusterRpcFrame(self.allocator, msg);
        defer self.allocator.free(req_frame);
        try stream.writeAll(req_frame);
        // Half-close so the receiver knows no more request bytes
        // will arrive.  The stream remains open for the response
        // direction.
        stream.finish() catch {};

        // Read the response frame (magic + len + protobuf Response).
        const resp_payload = try readClusterRpcFrame(self.allocator, stream);
        defer self.allocator.free(resp_payload);

        var reader: std.Io.Reader = .fixed(resp_payload);
        const decoded = try protobuf.decode(Response, &reader, self.allocator);
        return decoded;
    }

    pub const Config = struct {
        peers: []const PeerConfig,
        election_timeout_ms: u64 = 5000,
        replication_factor: u32 = 3,
        sharding_strategy: ShardingStrategy = .hash_based,
        failover_config: FailoverConfig = .{},
        health_check_interval_ms: u64 = 1000,
        unhealthy_threshold: u32 = 3,

        // === Cluster bootstrap configuration (Task A3 of 2026-05-25 plan) ===
        // These fields let multiple coordinator processes co-exist on one host
        // (different cluster_port values) and authenticate inter-node traffic
        // (cluster_token).  All five are stored by reference — the caller
        // owns the backing memory.

        /// Address this node binds its intra-cluster listener to. Used by
        /// `networkLoop`.  Defaults to all interfaces so a vanilla single-node
        /// dev run still accepts loopback peers without extra config.
        listen_address: []const u8 = "0.0.0.0",
        /// Port this node binds its intra-cluster listener to.  Defaults to
        /// 4242 so it does NOT collide with the QUIC client port (3141) when
        /// a coordinator is started in the same process as a client-facing
        /// QUIC server, and so the harness can place 3 nodes on one host at
        /// 4242 / 4243 / 4244.
        cluster_port: u16 = 4242,
        /// Pre-shared token validated on every inbound cluster connection.
        /// Empty string disables the auth check (single-node dev mode).
        /// Stored by reference — caller owns the lifetime.
        cluster_token: []const u8 = "",
        /// Cluster name (for OTel attributes and operator-facing logs).
        cluster_name: []const u8 = "geode-cluster",
        /// Maximum simultaneous inbound connections from peers.  Mirrored
        /// into `ClusterCoordinator.max_connections` so the existing PERF-D006
        /// connection-semaphore in `networkLoop` reads it without going
        /// back to the Config.
        max_connections: u32 = 256,
        /// TLS certificate path used by the intra-cluster QUIC listener.
        /// `networkLoop` plumbs this into `quic.QuicTransport.Config.cert_path`.
        /// The server boot path (`src/server/main.zig`) resolves cert paths
        /// via `cert_gen.ensureCertificatesAtPath`, writing
        /// `<data-dir>/server.crt`; passing that same path here lets a
        /// cluster member reuse the same self-signed cert for both the
        /// client-facing listener and the peer-facing listener (Task A6
        /// subprocess smoke).  Empty defaults preserve the QuicTransport
        /// defaults for older callers.
        cert_path: []const u8 = "",
        /// TLS private key path mirroring `cert_path`.  Same lifetime story:
        /// caller owns the backing memory.
        key_path: []const u8 = "",
        /// Server data directory. When non-null, `ClusterCoordinator.init`
        /// roots the durable raft hard-state + log at `<data_dir>/raft` via
        /// the pinned raft library's crash-safe FileStorage, so a restarted
        /// node restores its currentTerm / votedFor (Raft election-safety)
        /// rather than resetting term/vote to zero. Null keeps the legacy
        /// in-memory (non-durable) backing. Stored by reference — caller owns
        /// the backing memory (same convention as `cert_path` / `key_path`);
        /// `init` only borrows it to build the `<data_dir>/raft` path and frees
        /// that derived path before returning (FileStorage does not retain it).
        data_dir: ?[]const u8 = null,
    };

    pub const PeerConfig = struct {
        id: u64,
        address: []const u8,
        port: u16,
    };
};

// ---------------------------------------------------------------------------
// Public testing surface
// ---------------------------------------------------------------------------
// Task A3e (2026-05-25 distributed cluster testing plan): expose just
// enough of the private Message / Response / forwardToShard machinery
// so the regression test (tests/test_cluster_forward_to_shard.zig) can
// drive the cross-node read path without leaking those internals into
// the production API surface.  Everything inside `testing_surface` is
// gated by a CANARY=EXEMPT marker — never call these from non-test
// code.  Re-exported from the geode module root as
// `geode.distributed.cluster.testing` (lower-case alias below).
//
// File-scope aliases used to bridge the file-private types into the
// public `testing_surface` namespace below.  The aliases are not
// `pub` — only the `testing_surface` struct's `pub const`
// declarations leak them out of this module.  Inside the struct
// body the fn signature uses the alias name to disambiguate from
// the file-private `Message` / `Response` / `ResponseStatus`
// symbols that share the unqualified name.
const TestingMessage = Message;
const TestingResponse = Response;
const TestingResponseStatus = ResponseStatus;

// CANARY: REQ=REQ-DIST-CLUSTER-FORWARD-SHARD-TEST-SURFACE; FEATURE="DistributedCluster"; ASPECT=TestExposure; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-05-26
pub const testing_surface = struct {
    pub const Message = TestingMessage;
    pub const Response = TestingResponse;
    pub const ResponseStatus = TestingResponseStatus;
    pub fn forwardToShard(
        coord: *ClusterCoordinator,
        shard_id: u64,
        msg: TestingMessage,
    ) !TestingResponse {
        return coord.forwardToShard(shard_id, msg);
    }
    /// One pass of the health loop (SONNY-6451 item 2).
    pub fn healthPass(coord: *ClusterCoordinator) !void {
        return coord.healthPass();
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "Message struct carries auth_token field" {
    // SEC-D002: Verify the Message struct includes auth_token for JOIN_CLUSTER authentication.
    const msg = Message{
        .msg_type = .JOIN_CLUSTER,
        .key = null,
        .client_id = "test-node",
        .data = null,
        .auth_token = "my-secret-token",
    };
    try testing.expectEqualStrings("my-secret-token", msg.auth_token);
    try testing.expectEqual(MessageType.JOIN_CLUSTER, msg.msg_type);
}

test "Message auth_token defaults to empty" {
    const msg = Message{};
    try testing.expectEqualStrings("", msg.auth_token);
}

test "SEC-D012: minimal join response has no topology" {
    // JoinResponsePayload must carry exactly 3 fields: assigned_node_id, node_count, success.
    // It must NOT contain endpoint, shard, or any other topology detail.
    const info = @typeInfo(JoinResponsePayload);
    const fields = info.@"struct".fields;
    try testing.expectEqual(@as(usize, 3), fields.len);

    // Verify the exact field names
    try testing.expectEqualStrings("assigned_node_id", fields[0].name);
    try testing.expectEqualStrings("node_count", fields[1].name);
    try testing.expectEqualStrings("success", fields[2].name);

    // Verify defaults are safe (no information leak)
    const payload = JoinResponsePayload{};
    try testing.expectEqual(@as(u64, 0), payload.assigned_node_id);
    try testing.expectEqual(@as(u32, 0), payload.node_count);
    try testing.expectEqual(false, payload.success);
}

test "SEC-D009: ReplayGuard rejects duplicate within window" {
    var guard = ReplayGuard.init(testing.allocator, 16, 30_000);
    defer guard.deinit();

    // First call should be accepted (fresh)
    try testing.expect(guard.check(1, 10));

    // Identical (from, term) within the window must be rejected
    try testing.expect(!guard.check(1, 10));

    // Different (from, term) pair should be accepted
    try testing.expect(guard.check(2, 10));
    try testing.expect(guard.check(1, 11));
}
