const std = @import("std");

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

fn compat_sleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
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
const builtin = @import("builtin");
const geode = @import("geode");
const quic_transport = @import("transport/quic");
const proto_reader_metrics = @import("buffered_proto_reader_metrics.zig");
const quic_response_metrics = @import("quic_response_metrics");
const query_plan_cache = geode.query_plan_cache;
// Per-mutation wall-clock timing instrumentation (Task 1, throughput plan).
const mutation_timing = geode.mutation_timing;
// GAP-0755: Per-query arena pool for executor scratch.
const query_arena = geode.query_arena;
const query_traits = geode.query_traits;
const explain_payload = geode.explain_payload;
const profile_payload = geode.profile_payload;
const ServerState = geode.server_state.ServerState;
const CatalogSchema = geode.server_state.CatalogSchema;
const CatalogGraph = geode.server_state.CatalogGraph;
const execution = geode.execution;
const server_flags = geode.server_flags;
const graph_store = geode.graph_store;
const proto_util = geode.proto_util;
const gql_print = geode.printer;
const gql_ast = geode.gql.ast;
const backup_manager = geode.backup_manager;
const SimplifiedBackupManager = backup_manager.SimplifiedBackupManager;
const BackupConfig = @import("storage/backup").BackupConfig;
const txn_undo_log = geode.txn_undo_log;
const diagnostics = geode.diagnostics;
const user_mgmt = geode.user_management;
const planned_read_runtime = geode.planned_read_runtime;
const node_scan_stream = geode.node_scan_stream;
const pooled = @import("transport/thread_pool");
// Issue #444: Import AST cache to wire into parse hot path
const query_ast_cache = @import("query_ast_cache");
const group_commit = geode.group_commit;
// CANARY: REQ=REQ-ABAC-WIRE-012; FEATURE="ABAC Enforcement"; ASPECT=QUICImport; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Import geode_auth for SecurityManager type in QUIC connection handling
const geode_auth = @import("geode_auth");
const server_init = @import("server_init.zig");
// GAP-0258: Import mTLS provider for QUIC client certificate authentication
const mtls_provider = geode.mtls_provider;
// GAP-0271: Import FLE integration for role-based field access control
const fle_integration = geode.fle_integration;
// GAP-0282: Import audit module for per-thread tenant_id enrichment
const audit_mod = geode.security.audit;
// GAP-0283: Import multi-graph security for graph-scoped RBAC enforcement
const multi_graph_security = geode.multi_graph_security;
// GAP-0289: Import tenant quota manager for per-tenant resource limits
const tenant_quota = geode.tenant_quota;
const stream_registry = @import("active_stream_registry.zig");
const proto_reader_registry = @import("proto_reader_registry.zig");

// CANARY: REQ=REQ-SERVER-REFACTOR-012; FEATURE="ServerRefactoring"; ASPECT=QUIC_HANDLERS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.3 - QUIC Connection Handlers Module (Eighth Increment)
// Extracted from server/main.zig to improve modularity and reduce main() function size
// Contains handleQuicConnection and processMessage functions for QUIC protocol handling

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-012; FEATURE="Structured Logging"; ASPECT=QUICHandler; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;

const schema = @import("schema");
const protobuf = @import("protobuf");

// GAP-0258: Global mTLS provider for QUIC certificate authentication
// CANARY: REQ=REQ-AUTH-MTLS-QUIC-004; FEATURE="mTLS over QUIC"; ASPECT=GlobalProvider; STATUS=TESTED; TEST=geodetestlab/specs/authn_mtls_rejection_matrix.yml; OWNER=security; UPDATED=2026-06-11
var g_mtls_provider: ?*mtls_provider.MtlsProvider = null;

// S6: Per-IP authentication rate limiter — prevents brute-force attacks on QUIC HELLO.
// CANARY: REQ=REQ-SEC-RATE-LIMIT-003; FEATURE="AuthRateLimiting"; ASPECT=GlobalInstance; STATUS=TESTED; TEST=geodetestlab/specs/authn_rate_limiter.yml; OWNER=security; UPDATED=2026-06-11
const auth_rate_limiter = @import("auth_rate_limiter.zig");
var g_auth_rate_limiter: ?*auth_rate_limiter.AuthRateLimiter = null;

// S1: Post-execution RLS filter — removes result rows containing denied labels.
// CANARY: REQ=REQ-SEC-RLS-WIRE-002; FEATURE="RLS Query Enforcement"; ASPECT=QUICImport; STATUS=TESTED; TEST=geodetestlab/specs/rls_injection_resistance.yml; OWNER=security; UPDATED=2026-06-11
const rls_filter = @import("rls_filter.zig");
const index_manager = geode.index_manager;

// PERF-P1-004: Global stream thread throttle — caps OS thread spawning across
// all QUIC connections to prevent thread exhaustion under high concurrency.
// CANARY: REQ=PERF-P1-004; FEATURE="GlobalStreamThrottle"; ASPECT=QUICWiring; STATUS=TESTED; OWNER=server; UPDATED=2026-04-10
var g_stream_throttle: stream_registry.GlobalStreamThrottle = stream_registry.GlobalStreamThrottle.init(
    stream_registry.default_max_global_stream_threads,
);
// CANARY: REQ=REQ-QUIC-HC-129; FEATURE="DetachedFirstStream"; ASPECT=ParserSafeOwnerStack; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
//
// Detached first-stream owners run the full request loop, including GQL parse
// and execution. 1 MiB is enough for lightweight protocol handling but can
// overflow in the parser on ordinary client queries such as `RETURN 1 AS x`.
//
// GAP-0333: the recursive-descent GQL parser climbs ~6 precedence frames per
// nested parenthesis (parseOrExpr → … → parsePrimaryExpr → parseOrExpr). The
// parser enforces a hard nesting limit of 128 (Parser.enterRecursion), so the
// owner stack must hold ~130 levels of that chain or a legal 128-deep query
// segfaults before the depth guard can return a clean error. Per-level stack
// cost is ~20 KiB in release but ~66 KiB in unoptimized debug builds, so 130
// levels needs ~2.6 MiB (release) / ~8.6 MiB (debug). 8 MiB was just short in
// debug (120-deep OK, 128-deep segfaulted); 16 MiB holds the full 128-deep
// limit with margin in BOTH build modes (~240 debug / ~800 release levels).
// This is virtual reservation only — pages fault in solely for genuinely deep
// queries (bounded by the 128 guard), so normal-load RSS is unchanged.
const first_stream_owner_stack_size = 16 * 1024 * 1024;
const default_detached_first_stream_owner_threads: u32 = if (builtin.mode == .Debug) 64 else 256;
const first_stream_scheduler_idle_sweep_ns: u64 = 10 * std.time.ns_per_ms;
// 2026-06-08 idle-CPU fix: when the scheduler has ZERO contexts (no active
// streams), the 10ms idle sweep has nothing to do — shouldSweepIdleContextsLocked
// returns false at contexts.len==0 — so 512 cooperative workers each waking every
// 10ms is pure waste (~51k futex round-trips/s = the dominant idle-node CPU cost
// after the QUIC poll-loop fix; profiled 2026-06-08, see
// docs/bugs/2026-06-08-idle-node-810pct-cpu-poll-and-pool-spin.md). enqueueReady
// bumps ready_generation + futexWakes (and shutdown broadcasts), so new work
// wakes a worker immediately regardless of this timeout; the missed-wake sweep it
// gates is only meaningful when contexts already exist. Park this long instead of
// the 10ms sweep cadence whenever there are no contexts: 512 × 1/s = ~512 futex/s.
const first_stream_scheduler_idle_park_ns: u64 = 1 * std.time.ns_per_s;
const first_stream_scheduler_turn_delay_per_excess_ns: u64 = 2 * std.time.ns_per_us;
const first_stream_scheduler_turn_delay_cap_ns: u64 = std.time.ns_per_ms;
const first_stream_mutation_offload_worker_cap: usize = if (builtin.mode == .Debug) 8 else 64;
const first_stream_mutation_offload_shutdown_wait_ns: u64 = 30 * std.time.ns_per_s;
// CANARY: REQ=REQ-QUIC-HC-150; FEATURE="QUIC High-Concurrency Mutations"; ASPECT=CooperativeMutationWindowCap; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-29
//
// The original four-wide mutation window protected reads while all mutations
// funneled through a whole-graph writer. Keep that small serial window for
// general mutations, but route simple multi-property MERGE through a wider
// shard-parallel window because that path uses tuple and shard locks instead
// of the whole-graph writer. The default is intentionally below the full
// 512-worker cooperative pool: 2048x8 mixed fan-out is fastest when enough
// scheduler workers remain available for read progress and response flushes.
const serial_first_stream_scheduler_mutation_limit_cap: usize = 4;
pub const default_first_stream_scheduler_mutation_limit_cap: usize = 80;
pub const max_first_stream_scheduler_mutation_limit_cap: usize = 512;
// CANARY: REQ=REQ-QUIC-HC-108; FEATURE="High-Concurrency First Streams"; ASPECT=CooperativeBatchBudget; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-28
//
// The scheduler runs persistent first streams through a shared worker pool.
// Letting one owner process multiple ready messages in a turn lets early
// clients drain sequential EXECUTE/PULL bursts while tail clients remain
// queued. One-message FIFO turns plus buffered-only requeueing keep high
// fan-out from timing out without raising the worker pool into thread-storm
// territory.
const first_stream_scheduler_messages_per_tick: u32 = 1;

const CooperativeFirstStreamTurn = enum {
    keep,
    done,
    offloaded,
};

// CANARY: REQ=REQ-QUIC-HC-044; FEATURE="QUIC High-Concurrency Requests"; ASPECT=BoundedDetachedFirstStreams; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
//
// First-stream owners are long-lived persistent stream loops. Spawning one OS
// thread per authenticated connection keeps 256-way fanout simple, but at
// 512+ it starves the single QUIC poller and stalls packet delivery. Bound the
// detached owner count separately from the global stream admission cap; overflow
// first streams stay admitted but run through the shared stream pool.
const FirstStreamDetachGate = struct {
    active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max: std.atomic.Value(u32) = std.atomic.Value(u32).init(default_detached_first_stream_owner_threads),

    fn configure(self: *@This(), max_threads: u32) void {
        self.max.store(@max(max_threads, 1), .release);
    }

    fn tryAcquire(self: *@This()) bool {
        const max_threads = self.max.load(.acquire);
        var observed = self.active.load(.acquire);
        while (observed < max_threads) {
            if (self.active.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire)) |next| {
                observed = next;
            } else {
                return true;
            }
        }
        return false;
    }

    fn release(self: *@This()) void {
        const prev = self.active.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
    }

    fn count(self: *const @This()) u32 {
        return self.active.load(.acquire);
    }

    fn limit(self: *const @This()) u32 {
        return self.max.load(.acquire);
    }
};

var g_first_stream_detach_gate = FirstStreamDetachGate{};

/// Monotonic-clock reader used by `BufferedProtoReader.recordActivity`
/// for per-stream stall detection (#864 §10).  Mirrors the helper in
/// `buffered_proto_reader_metrics.zig` but kept local to this module
/// to avoid widening the metric module's API surface for what is
/// really a handler-internal concern.
fn monoNsFromHandler() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

/// #864 §10: process-wide registry of active BufferedProtoReader
/// instances.  Initialized once at module load; `main.zig` reads it
/// via the metric/watchdog callbacks below.  Allocator passed at
/// register/unregister time matches the gpa the handler is using.
var g_proto_reader_registry: proto_reader_registry.Registry = proto_reader_registry.Registry.init();

/// Snapshot accessor for the metric layer (`quic_max_stream_idle_ns`).
pub fn getProtoReaderRegistry() *proto_reader_registry.Registry {
    return &g_proto_reader_registry;
}

// #864 / qa-seed deadlock §6.5: process-wide leaked-connection registry.
// `handleQuicConnection`'s acceptor-wait bail path adds entries here when
// it leaves a conn alive to avoid UAF; a periodic reaper task in main.zig
// (`reaperLoop`) detects when each entry's acceptor has finished and
// calls `destroyConnection` to reclaim it.  Nullable so unit tests can
// skip wiring; main.zig installs the registry at startup via
// `setLeakedConnRegistry`.
const leaked_conn_reaper_mod = @import("leaked_conn_reaper.zig");
var g_leaked_conn_registry: ?*leaked_conn_reaper_mod.LeakedConnRegistry = null;

/// Install the process-wide leaked-conn registry (called from main.zig).
/// Pass `null` at shutdown to detach so subsequent leak paths skip
/// registration without erroring.
pub fn setLeakedConnRegistry(reg: ?*leaked_conn_reaper_mod.LeakedConnRegistry) void {
    g_leaked_conn_registry = reg;
}

/// Snapshot accessor for the metrics layer.
pub fn getLeakedConnRegistry() ?*leaked_conn_reaper_mod.LeakedConnRegistry {
    return g_leaked_conn_registry;
}

fn acceptorCtxIsDone(ptr: *anyopaque) bool {
    const ctx: *StreamAcceptorContext = @ptrCast(@alignCast(ptr));
    return ctx.done.load(.acquire);
}

fn acceptorCtxRelease(ptr: *anyopaque) void {
    const ctx: *StreamAcceptorContext = @ptrCast(@alignCast(ptr));
    ctx.release();
}

/// Override the global stream thread limit (called from server startup).
/// A value of 0 resets to the default.
pub fn setMaxGlobalStreamThreads(max: u32) void {
    const effective = if (max == 0) stream_registry.default_max_global_stream_threads else max;
    g_stream_throttle = stream_registry.GlobalStreamThrottle.init(effective);
}

// CANARY: REQ=REQ-QUIC-HC-020; FEATURE="ConfigurableStreamThrottle"; ASPECT=RegistryPreallocation; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-26
pub fn reserveProtoReaderRegistryCapacity(gpa: std.mem.Allocator, capacity: usize) !void {
    try g_proto_reader_registry.reserveCapacity(gpa, capacity);
}

/// Return the current number of active stream handler threads globally.
pub fn getGlobalStreamThreadCount() u32 {
    return g_stream_throttle.count();
}

/// Return the configured maximum number of concurrent stream handler
/// threads.  Used by the runtime-metrics gauge surface so operators can
/// compute a saturation ratio without hard-coding the cap on the
/// dashboard side.
pub fn getMaxGlobalStreamThreads() u32 {
    return g_stream_throttle.max;
}

// CANARY: REQ=REQ-QUIC-HC-044; FEATURE="QUIC High-Concurrency Requests"; ASPECT=BoundedDetachedFirstStreams; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
pub fn setMaxDetachedFirstStreamOwners(max: u32) void {
    const effective = if (max == 0) default_detached_first_stream_owner_threads else max;
    g_first_stream_detach_gate.configure(effective);
}

pub fn getDetachedFirstStreamOwnerCount() u32 {
    return g_first_stream_detach_gate.count();
}

pub fn getMaxDetachedFirstStreamOwners() u32 {
    return g_first_stream_detach_gate.limit();
}

/// Counter incremented whenever a new peer-initiated stream is rejected
/// because the global stream-handler throttle is saturated. Exposed via
/// `getStreamAdmissionRejectionsTotal` for runtime-metrics. Lets
/// operators detect admission backpressure independently of the
/// would-block counter (which fires on quiescent streams too).
var g_stream_admission_rejections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Snapshot of the cumulative admission-rejection counter. The
/// runtime-metrics framework calls this for the
/// `quic_stream_admission_rejections_total` counter surface.
pub fn getStreamAdmissionRejectionsTotal() u64 {
    return g_stream_admission_rejections.load(.monotonic);
}

/// Set the global mTLS provider (called from server/main.zig during startup)
pub fn setMtlsProvider(provider: ?*mtls_provider.MtlsProvider) void {
    g_mtls_provider = provider;
}

/// Get the current global mTLS provider
pub fn getMtlsProvider() ?*mtls_provider.MtlsProvider {
    return g_mtls_provider;
}

/// Set the global authentication rate limiter (called from server/main.zig during startup).
/// CANARY: REQ=REQ-SEC-RATE-LIMIT-004; FEATURE="AuthRateLimiting"; ASPECT=GlobalSetter; STATUS=TESTED; TEST=geodetestlab/specs/authn_rate_limiter.yml; OWNER=security; UPDATED=2026-06-11
pub fn setAuthRateLimiter(limiter: ?*auth_rate_limiter.AuthRateLimiter) void {
    g_auth_rate_limiter = limiter;
}

/// Get the current global authentication rate limiter.
pub fn getAuthRateLimiter() ?*auth_rate_limiter.AuthRateLimiter {
    return g_auth_rate_limiter;
}

// GAP-0283: Graph-scoped RBAC policy access — delegates to multi_graph_security global singleton.
// CANARY: REQ=REQ-MULTI-GRAPH-RBAC-WIRE-001; FEATURE="GraphRBACEnforcement"; ASPECT=GlobalInstance; STATUS=TESTED; TEST=tests/test_gap0514_quic_handler.zig; OWNER=security; UPDATED=2026-06-11

/// Set the global graph RBAC policy (called from server/main.zig during startup).
pub fn setGraphRbacPolicy(policy: ?*multi_graph_security.GraphRBACPolicy) void {
    multi_graph_security.setGlobalPolicy(policy);
}

/// Get the current global graph RBAC policy.
pub fn getGraphRbacPolicy() ?*multi_graph_security.GraphRBACPolicy {
    return multi_graph_security.getGlobalPolicy();
}

/// GAP-0001 / #564: Delegate to shared mutation classification in query_traits.
/// These detect inline mutations inside Query nodes (MATCH...CREATE, etc.)
/// that previously only took a shared read lock, causing data races.
const isMutatingStatement = query_traits.isMutatingStatement;

const isMutatingProgram = query_traits.isMutatingProgram;

fn rebuildPendingIndexes(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    pending_index_rebuilds: *std.StringHashMap(void),
) void {
    if (pending_index_rebuilds.count() == 0) return;
    const manager = index_manager.getGlobalIndexManager() orelse return;

    const rebuild_lock = graph_store.acquireGraphReadLockTagged(graph_name, .misc);
    defer graph_store.releaseGraphLock(rebuild_lock);

    const store = graph_store.getGlobalStore(allocator);
    var iter = pending_index_rebuilds.keyIterator();
    while (iter.next()) |k| manager.rebuildAdvancedIndex(store, k.*) catch {};
}

/// Task 11 (enterprise-ingest-throughput) fast-path dispatcher for the
/// simple single-label, scalar-property CREATE pattern detected by
/// `bulk_ingest.matchSingleStatement`.  Writes the node directly through
/// `adapter.bulkInsertNode`, skipping `executeProgramWithContext`, the
/// undo log, RLS filtering, and row materialization.  Sends the same
/// wire response shape (schema 0 cols + final data page + status 00000)
/// that a no-RETURN CREATE emits from the regular executor.
///
/// Lock protocol: takes the per-graph exclusive writer lock for the
/// duration of the write — matching the existing mutation path in
/// `processMessage` until Task 16 introduces the two-phase split.  The
/// session / statement engine txn is joined implicitly via the
/// adapter's thread-local slots (R8 / R9).
fn executeBulkSimpleCreate(
    gpa: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
    state: *ServerState,
    program: *const gql_ast.Program,
    query_graph_name: []const u8,
    ctx: execution.ExecutionContext,
) !void {
    // The detector has already verified program shape; re-extract the
    // create statement here.  If detection and dispatch somehow disagree
    // (a programming error), fall through to the regular executor —
    // `return error.BulkDispatchDisagreement` would be noise.
    if (program.statements.len != 1) {
        try sendExecuteError(gpa, stream, "XX000", "bulk fast-path: unexpected program shape", &.{}, &.{});
        return;
    }
    const create_stmt = switch (program.statements[0]) {
        .Create => |c| c,
        else => {
            try sendExecuteError(gpa, stream, "XX000", "bulk fast-path: non-CREATE statement", &.{}, &.{});
            return;
        },
    };
    if (create_stmt.pattern.chains.len != 1) {
        try sendExecuteError(gpa, stream, "XX000", "bulk fast-path: multi-chain CREATE", &.{}, &.{});
        return;
    }
    const node_pattern = create_stmt.pattern.chains[0].head orelse {
        try sendExecuteError(gpa, stream, "XX000", "bulk fast-path: missing node pattern", &.{}, &.{});
        return;
    };

    // Evaluate each property value.  The detector already guaranteed
    // that every value is a literal or parameter, so we only need to
    // handle those two cases — any other expression variant would have
    // been rejected by `bulk_ingest.isScalarPropExpr`.
    const geode_eval = geode.eval;
    // Import via the `geode` module (not a relative path) so the file
    // stays in the 'geode' module only — relative imports pull it into
    // the 'root' module too, which Zig 0.16 rejects with a "file exists
    // in modules 'root' and 'geode'" error.
    const property_codec = geode.property_value_codec;
    var eval_arena = std.heap.ArenaAllocator.init(gpa);
    defer eval_arena.deinit();
    const eval_allocator = eval_arena.allocator();

    const env = geode.makeEnv(
        eval_allocator,
        &.{},
        &.{},
        .{ .names = ctx.query_param_names, .values = ctx.query_param_values },
    );

    var kvs_buf: [16]geode.graph_storage_adapter.StorageAdapter.PropKV = undefined;
    const props_slice = node_pattern.props orelse &[_]gql_ast.Property{};
    var kvs: []geode.graph_storage_adapter.StorageAdapter.PropKV = if (props_slice.len <= kvs_buf.len)
        kvs_buf[0..props_slice.len]
    else
        try eval_allocator.alloc(geode.graph_storage_adapter.StorageAdapter.PropKV, props_slice.len);

    for (props_slice, 0..) |prop, i| {
        const v = try geode_eval.evalExpr(eval_allocator, prop.value.*, env);
        const pv = try property_codec.valueToPropertyValue(eval_allocator, v);
        kvs[i] = .{ .key = prop.key, .value = pv };
    }

    var mut_sample = mutation_timing.begin();

    // Task 19 (2026-04-23): group-commit coordinator path.
    //
    // When `GEODE_GROUP_COMMIT=1` is set, route the apply through a
    // per-graph coordinator thread that batches 16-way concurrent
    // submits under a single exclusive write-lock acquire + one
    // statement txn (one WAL fsync per batch instead of per worker).
    // Falls back to the direct single-phase path when the feature is
    // off or the adapter is missing (legacy tests).
    const adapter_opt = graph_store.getGlobalAdapter();
    if (adapter_opt == null) {
        try sendExecuteError(gpa, stream, "XX000", "bulk fast-path: no adapter registered", &.{}, &.{});
        return;
    }
    const adapter = adapter_opt.?;

    if (group_commit.isEnabled()) {
        // Lazily start the coordinator on first mutation against this graph.
        const coord = group_commit.getOrStartCoordinator(
            graph_store.global_allocator(),
            adapter,
            query_graph_name,
        ) catch |err| {
            const info = proto_util.mapError(err);
            try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
            return;
        };

        // Submit + wait.  The coordinator thread owns the write lock for
        // the batch, so we do NOT take `mg.rwlock` here.
        mut_sample.markLockAcquired();
        var op = group_commit.ApplyOp{ .bulk_insert_node = .{
            .labels = node_pattern.labels,
            .props = kvs,
            .result = .{},
        } };
        _ = coord.submit(&op) catch |err| {
            const info = proto_util.mapError(err);
            try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
            return;
        };
        mut_sample.markExecuteDone();
        mut_sample.markLockReleased();
    } else {
        // Single-phase path: acquire per-graph exclusive write lock with
        // the per-request deadline policy and apply directly.
        const write_lock_timeout_ns = mutationWriteLockTimeoutNs(state);
        const deadline = monoNanosNow() + write_lock_timeout_ns;
        const lock_handle = graph_store.acquireGraphWriteLockCancelable(query_graph_name, deadline) catch |err| {
            if (err == error.Deadline) {
                log.warn("Write lock acquisition timed out (bulk path)", &.{
                    Attr.string("graph", query_graph_name),
                    Attr.uint("timeout_ns", write_lock_timeout_ns),
                });
                try sendExecuteError(gpa, stream, "40001", "Write lock acquisition timed out", &.{}, &.{});
                return;
            }
            return err;
        };
        mut_sample.markLockAcquired();

        const node_id_res = adapter.bulkInsertNode(
            query_graph_name,
            node_pattern.labels,
            kvs,
            null,
        );
        _ = node_id_res catch |err| {
            graph_store.releaseGraphLock(lock_handle);
            const info = proto_util.mapError(err);
            try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
            return;
        };

        mut_sample.markExecuteDone();
        graph_store.releaseGraphLock(lock_handle);
        mut_sample.markLockReleased();
    }

    try sendEmptySuccessResult(gpa, stream);

    mut_sample.record("bulk_simple_create");

    // Keep txn / audit / session state tracking consistent with the
    // regular mutation path so downstream handlers don't observe drift.
    auditQueryExecution(state, "bulk_simple_create", true);
    // Auto-index the node label(s) — mirrors the regular-executor hook at
    // `src/execution/crud_operations.zig:696` and the edge fast-path at
    // `executeBulkMatchCreateEdge` above.  The bulk fast path bypasses
    // `executeProgramWithContext`, so without this call the spec
    // `auto_index_id.yml` (and `auto_index_lifecycle.yml`) fails: a single
    // `CREATE (n:L {...})` never lists `auto_idx_<label>_id` in SHOW INDEXES.
    execution.ensureAutoIndexes(gpa, node_pattern.labels);
    syncGraphFromSession(state);
    updateTxnStateFromProgram(state, program);
}

/// Shared helper: send the "0 rows affected, success" wire response that
/// both successful bulk edge inserts and silently-skipped orphan edges
/// use.  Matches the shape of a no-RETURN MATCH+CREATE coming out of the
/// regular executor: one schema (0 cols) + one page (0 rows, final=true)
/// + status 00000.
fn sendBulkEdgeSuccessResponse(
    gpa: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
) !void {
    try sendEmptySuccessResult(gpa, stream);
}

/// Task 12 (enterprise-ingest-throughput) fast-path dispatcher for the
/// two-match-one-edge pattern detected by `bulk_ingest.matchEdgeSpec`:
///
///     MATCH (a:L1 {node_id: v1}), (b:L2 {node_id: v2})
///     CREATE (a)-[r:T {props}]->(b)
///
/// Writes the edge directly through `adapter.bulkInsertEdgeWithIds`,
/// skipping `executeProgramWithContext`, the undo log, RLS filtering,
/// match-pattern planning, and row materialization.  Sends the same wire
/// response shape (schema 0 cols + final data page + status 00000) that a
/// no-RETURN MATCH+CREATE emits from the regular executor.
///
/// Lock protocol (Task 15/16, 2026-04-23): two-phase split.  The MATCH
/// endpoint lookups run under a SHARED read lock so 16 concurrent workers
/// can resolve their source/target node IDs in parallel.  Once both IDs
/// are captured on the stack, the read lock is released and the exclusive
/// write lock is acquired for the `createEdgeWithGraph` + per-property
/// apply step (the write critical section is now ~tens of µs instead of
/// 60+ ms of lookup-and-apply).  Between the two phases another writer
/// could delete an endpoint; `bulkInsertEdgeWithIds` re-checks under the
/// write lock and surfaces `SourceNodeNotFound` / `TargetNodeNotFound` so
/// the wire response is the same as the single-phase pre-Task-16 path.
/// The session / statement engine txn is joined implicitly via the
/// adapter's thread-local slots (R8 / R9).
fn executeBulkMatchCreateEdge(
    gpa: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
    state: *ServerState,
    program: *const gql_ast.Program,
    spec: geode.bulk_ingest.MatchCreateEdgeSpec,
    query_graph_name: []const u8,
    ctx: execution.ExecutionContext,
) !void {
    const geode_eval = geode.eval;
    const property_codec = geode.property_value_codec;

    var eval_arena = std.heap.ArenaAllocator.init(gpa);
    defer eval_arena.deinit();
    const eval_allocator = eval_arena.allocator();

    const env = geode.makeEnv(
        eval_allocator,
        &.{},
        &.{},
        .{ .names = ctx.query_param_names, .values = ctx.query_param_values },
    );

    // Resolve the two endpoint filter values (typically string / int /
    // parameter).  The detector already verified both are scalar literal
    // or bound parameter expressions; any eval failure here is a bug
    // (non-scalar slipped past the detector) — surface it as a server
    // error rather than silently falling back.
    const src_filter_val = try geode_eval.evalExpr(eval_allocator, spec.source.filter_value.*, env);
    const dst_filter_val = try geode_eval.evalExpr(eval_allocator, spec.target.filter_value.*, env);
    const src_filter_pv = try property_codec.valueToPropertyValue(eval_allocator, src_filter_val);
    const dst_filter_pv = try property_codec.valueToPropertyValue(eval_allocator, dst_filter_val);

    // Evaluate all edge properties upfront (detector guaranteed scalar).
    var kvs_buf: [16]geode.graph_storage_adapter.StorageAdapter.PropKV = undefined;
    var kvs: []geode.graph_storage_adapter.StorageAdapter.PropKV = if (spec.props.len <= kvs_buf.len)
        kvs_buf[0..spec.props.len]
    else
        try eval_allocator.alloc(geode.graph_storage_adapter.StorageAdapter.PropKV, spec.props.len);
    for (spec.props, 0..) |prop, i| {
        const v = try geode_eval.evalExpr(eval_allocator, prop.value.*, env);
        const pv = try property_codec.valueToPropertyValue(eval_allocator, v);
        kvs[i] = .{ .key = prop.key, .value = pv };
    }

    var mut_sample = mutation_timing.begin();

    const adapter_opt = graph_store.getGlobalAdapter();
    if (adapter_opt == null) {
        try sendExecuteError(gpa, stream, "XX000", "bulk fast-path: no adapter registered", &.{}, &.{});
        return;
    }
    const adapter = adapter_opt.?;

    // Phase 2.3 (2026-04-23): when the group-commit coordinator is
    // enabled, the endpoint lookup happens INSIDE the coordinator under
    // its already-held EXCLUSIVE lock — NO shared read lock needed
    // here.  This eliminates the reader/writer serialization that was
    // forcing msft-graph to serial-fallback on the morning-baseline
    // and Phase 2.1/2.2 designs.
    //
    // Orphan-edge semantics (matches the regular MATCH+CREATE
    // executor): missing endpoint → silent skip (0-rows success), not
    // an error code.  The coordinator signals "orphan skip" by
    // returning `result.node_or_edge_id = 0` with no err.
    if (group_commit.isEnabled()) {
        const coord = group_commit.getOrStartCoordinator(
            graph_store.global_allocator(),
            adapter,
            query_graph_name,
        ) catch |err| {
            const info = proto_util.mapError(err);
            try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
            return;
        };
        mut_sample.markLockAcquired();

        var op = group_commit.ApplyOp{ .bulk_match_create_edge = .{
            .src_label = spec.source.label,
            .src_filter_key = spec.source.filter_key,
            .src_filter_value = src_filter_pv,
            .dst_label = spec.target.label,
            .dst_filter_key = spec.target.filter_key,
            .dst_filter_value = dst_filter_pv,
            .rel_type = spec.rel_type,
            .props = kvs,
            .result = .{},
        } };
        const result_id = coord.submit(&op) catch |err| {
            const info = proto_util.mapError(err);
            try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
            return;
        };
        mut_sample.markExecuteDone();
        mut_sample.markLockReleased();

        try sendBulkEdgeSuccessResponse(gpa, stream);
        if (result_id == 0) {
            mut_sample.record("bulk_match_create_edge_skipped");
            auditQueryExecution(state, "bulk_match_create_edge_skipped", true);
        } else {
            mut_sample.record("bulk_match_create_edge");
            auditQueryExecution(state, "bulk_match_create_edge", true);
            // Auto-index the edge type — mirrors the regular-executor
            // hook at `src/execution/crud_operations.zig:690`.  The bulk
            // fast path bypasses `executeProgramWithContext`, so without
            // this call the spec `auto_index_id.yml::auto-idx-edge-visible`
            // fails: `SHOW INDEXES` doesn't list `auto_idx_<edge_type>_id`.
            execution.ensureAutoIndexes(gpa, &.{spec.rel_type});
        }
        syncGraphFromSession(state);
        updateTxnStateFromProgram(state, program);
        return;
    }

    // Non-coordinator path: use the legacy SHARED-lock endpoint
    // resolve + per-op write lock.  Used only when GEODE_GROUP_COMMIT=0.
    const resolved = blk: {
        const read_handle = graph_store.acquireGraphReadLockTagged(query_graph_name, .bulk_edge);
        defer graph_store.releaseGraphLock(read_handle);
        const s = adapter.lookupNodeByMergeKey(
            query_graph_name,
            spec.source.label,
            spec.source.filter_key,
            src_filter_pv,
            error.SourceNodeNotFound,
        ) catch |err| switch (err) {
            error.SourceNodeNotFound => break :blk null,
            else => return err,
        };
        const t = adapter.lookupNodeByMergeKey(
            query_graph_name,
            spec.target.label,
            spec.target.filter_key,
            dst_filter_pv,
            error.TargetNodeNotFound,
        ) catch |err| switch (err) {
            error.TargetNodeNotFound => break :blk null,
            else => return err,
        };
        break :blk @as(?struct { src: u64, dst: u64 }, .{ .src = s, .dst = t });
    };

    if (resolved == null) {
        try sendBulkEdgeSuccessResponse(gpa, stream);
        mut_sample.record("bulk_match_create_edge_skipped");
        auditQueryExecution(state, "bulk_match_create_edge_skipped", true);
        syncGraphFromSession(state);
        updateTxnStateFromProgram(state, program);
        return;
    }
    const source_id: u64 = resolved.?.src;
    const target_id: u64 = resolved.?.dst;

    {
        // Single-phase path: acquire the per-graph exclusive write lock
        // with the per-request deadline policy.  Cancelable so a long
        // queue doesn't pin the worker forever.  The write critical
        // section below is just the `createEdgeWithGraph` + per-property
        // apply — tens of µs.
        const write_lock_timeout_ns = mutationWriteLockTimeoutNs(state);
        const deadline = monoNanosNow() + write_lock_timeout_ns;
        const lock_handle = graph_store.acquireGraphWriteLockCancelable(query_graph_name, deadline) catch |err| {
            if (err == error.Deadline) {
                log.warn("Write lock acquisition timed out (bulk edge path)", &.{
                    Attr.string("graph", query_graph_name),
                    Attr.uint("timeout_ns", write_lock_timeout_ns),
                });
                try sendExecuteError(gpa, stream, "40001", "Write lock acquisition timed out", &.{}, &.{});
                return;
            }
            return err;
        };
        mut_sample.markLockAcquired();

        const edge_id_res = adapter.bulkInsertEdgeWithIds(
            query_graph_name,
            source_id,
            target_id,
            spec.rel_type,
            kvs,
            null,
        );
        _ = edge_id_res catch |err| {
            graph_store.releaseGraphLock(lock_handle);
            switch (err) {
                error.SourceNodeNotFound, error.TargetNodeNotFound => {
                    try sendBulkEdgeSuccessResponse(gpa, stream);
                    mut_sample.record("bulk_match_create_edge_skipped_race");
                    auditQueryExecution(state, "bulk_match_create_edge_skipped_race", true);
                    syncGraphFromSession(state);
                    updateTxnStateFromProgram(state, program);
                    return;
                },
                else => {
                    const info = proto_util.mapError(err);
                    try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                    return;
                },
            }
        };

        mut_sample.markExecuteDone();
        graph_store.releaseGraphLock(lock_handle);
        mut_sample.markLockReleased();
    }

    // Wire response: identical shape to `executeBulkSimpleCreate` — schema
    // with 0 columns + one page with 0 rows final=true + status 00000 —
    // matches regular-executor output for a no-RETURN MATCH+CREATE.
    try sendBulkEdgeSuccessResponse(gpa, stream);

    mut_sample.record("bulk_match_create_edge");

    auditQueryExecution(state, "bulk_match_create_edge", true);
    // Auto-index the edge type — non-coordinator path counterpart of the
    // call above.  See note in coordinator-path branch.
    execution.ensureAutoIndexes(gpa, &.{spec.rel_type});
    syncGraphFromSession(state);
    updateTxnStateFromProgram(state, program);
}

/// Fast-path dispatcher for the simple-MERGE pattern detected by
/// `bulk_ingest.matchSimpleNodeMergeSpec`:
///
///     MERGE (n:L {merge_key: lit_or_param})
///     [ON CREATE SET n.a = lit_or_param, n.b = ..., ...]
///
/// Skips `executeProgramWithContext`, the undo log, RLS filtering, and
/// row materialization.  Sends the same wire response shape (schema 0
/// cols + final data page + status 00000) the regular executor emits
/// for a no-RETURN MERGE.
///
/// Lock protocol (two-phase, mirrors `executeBulkMatchCreateEdge`):
/// Phase 1 runs the merge-index lookup under a SHARED read lock so N
/// concurrent workers can probe in parallel for their hit-path (the
/// msft-graph ingest workload's common case is repeated MERGEs where
/// every call hits an existing node — those never need the write lock
/// at all).  On miss, the read lock is released and the exclusive write
/// lock is acquired for the insert phase; `bulkMergeNode` re-probes the
/// index inside the write critical section to catch the narrow window
/// where another writer inserted the same key between our Phase 1 miss
/// and Phase 2 acquire.
fn executeBulkSimpleMerge(
    gpa: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
    state: *ServerState,
    program: *const gql_ast.Program,
    spec: geode.bulk_ingest.SimpleNodeMergeSpec,
    query_graph_name: []const u8,
    ctx: execution.ExecutionContext,
) !void {
    const geode_eval = geode.eval;
    const property_codec = geode.property_value_codec;

    var eval_arena = std.heap.ArenaAllocator.init(gpa);
    defer eval_arena.deinit();
    const eval_allocator = eval_arena.allocator();

    const env = geode.makeEnv(
        eval_allocator,
        &.{},
        &.{},
        .{ .names = ctx.query_param_names, .values = ctx.query_param_values },
    );

    // Resolve the merge filter values (literal or parameter). The detector
    // already screened `isScalarPropExpr`, so eval must succeed for any
    // pattern we accepted — a failure here is a programming error.
    var merge_kvs_buf: [32]geode.graph_storage_adapter.StorageAdapter.PropKV = undefined;
    var merge_kvs: []geode.graph_storage_adapter.StorageAdapter.PropKV = if (spec.merge_props.len <= merge_kvs_buf.len)
        merge_kvs_buf[0..spec.merge_props.len]
    else
        try eval_allocator.alloc(geode.graph_storage_adapter.StorageAdapter.PropKV, spec.merge_props.len);
    for (spec.merge_props, 0..) |prop, i| {
        const v = try geode_eval.evalExpr(eval_allocator, prop.value.*, env);
        const pv = try property_codec.valueToPropertyValue(eval_allocator, v);
        merge_kvs[i] = .{ .key = prop.key, .value = pv };
    }
    const merge_value_pv = merge_kvs[0].value;

    // Evaluate all ON CREATE / bare SET property values upfront. The
    // detector guaranteed each is scalar (or a coalesce over a scalar). For
    // a coalesce prop (GAP-0900) whose scalar evaluates to NULL we OMIT the
    // prop entirely: on create it stays unset (= coalesce(null, null)); on
    // match it is untouched (= coalesce(null, existing)). The buffer is
    // sized to the max possible count and trimmed to the kept props.
    var kvs_buf: [32]geode.graph_storage_adapter.StorageAdapter.PropKV = undefined;
    var kvs: []geode.graph_storage_adapter.StorageAdapter.PropKV = if (spec.on_create_props.len <= kvs_buf.len)
        kvs_buf[0..spec.on_create_props.len]
    else
        try eval_allocator.alloc(geode.graph_storage_adapter.StorageAdapter.PropKV, spec.on_create_props.len);
    var kvs_len: usize = 0;
    for (spec.on_create_props) |prop| {
        const v = try geode_eval.evalExpr(eval_allocator, prop.value.*, env);
        if (prop.coalesce and geode.value_types.isNull(v)) continue;
        const pv = try property_codec.valueToPropertyValue(eval_allocator, v);
        kvs[kvs_len] = .{ .key = prop.key, .value = pv };
        kvs_len += 1;
    }
    kvs = kvs[0..kvs_len];

    var mut_sample = mutation_timing.begin();

    const adapter_opt = graph_store.getGlobalAdapter();
    if (adapter_opt == null) {
        try sendExecuteError(gpa, stream, "XX000", "bulk fast-path: no adapter registered", &.{}, &.{});
        return;
    }
    const adapter = adapter_opt.?;

    // Phase 1: shared-read probe.  `lookupNodeByMergeKey` is a pure
    // HashMap read against `merge_prop_index` + `nodes` — safe under a
    // reader lock per the Phase 4 invariants.  If the node already
    // exists, we're done: ON MATCH is a no-op (detector rejected
    // `ON MATCH SET`) and we send back the same 0-row response shape
    // the regular executor emits for a no-RETURN hit-path MERGE.
    //
    // For bare-`SET` MERGE (`spec.apply_on_match = true`) we skip
    // Phase 1 entirely — the SET clauses must apply on the match
    // branch, which requires the same write-side critical section as
    // the create branch.  Going straight to Phase 2 keeps the apply
    // atomic with the merge_prop_index update.
    var found_in_phase1 = false;
    if (!spec.apply_on_match and merge_kvs.len == 1) {
        const read_handle = graph_store.acquireGraphReadLockTagged(query_graph_name, .bulk_merge);
        defer graph_store.releaseGraphLock(read_handle);
        const res = adapter.lookupNodeByMergeKey(
            query_graph_name,
            spec.label,
            spec.merge_key,
            merge_value_pv,
            error.MergeCandidateMissing,
        );
        if (res) |_| {
            found_in_phase1 = true;
        } else |err| switch (err) {
            error.MergeCandidateMissing => {},
            else => {
                const info = proto_util.mapError(err);
                try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                return;
            },
        }
    }

    if (!found_in_phase1) {
        // Phase 2: apply — either via the group-commit coordinator (Task 19,
        // 2026-04-23) or direct write-lock acquire.  `bulkMergeNode`
        // re-probes the index inside the write critical section in both
        // paths so a concurrent writer that won the Phase 1 race is
        // detected and we return their id without double-inserting.
        // For `apply_on_match` the same call also applies the SET
        // clauses to an existing match before returning (true upsert).
        if (group_commit.isEnabled()) {
            const coord = group_commit.getOrStartCoordinator(
                graph_store.global_allocator(),
                adapter,
                query_graph_name,
            ) catch |err| {
                const info = proto_util.mapError(err);
                try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                return;
            };
            mut_sample.markLockAcquired();

            var op = if (merge_kvs.len == 1)
                group_commit.ApplyOp{ .bulk_merge_node = .{
                    .label = spec.label,
                    .merge_key = spec.merge_key,
                    .merge_value = merge_value_pv,
                    .on_create_props = kvs,
                    .result = .{},
                    .apply_on_match = spec.apply_on_match,
                } }
            else
                group_commit.ApplyOp{ .bulk_merge_node_props = .{
                    .label = spec.label,
                    .merge_props = merge_kvs,
                    .on_create_props = kvs,
                    .result = .{},
                    .apply_on_match = spec.apply_on_match,
                } };
            _ = coord.submit(&op) catch |err| {
                const info = proto_util.mapError(err);
                try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                return;
            };
            mut_sample.markExecuteDone();
            mut_sample.markLockReleased();
        } else if (merge_kvs.len > 1) {
            mut_sample.markLockAcquired();
            const store = graph_store.getGlobalStore(graph_store.global_allocator());
            const reserved_id = store.reserveNodeId();
            const node_id_res = adapter.bulkMergeNodeWithReservedIdMultiProp(
                query_graph_name,
                reserved_id,
                spec.label,
                merge_kvs,
                kvs,
                spec.apply_on_match,
            );
            _ = node_id_res catch |err| {
                const info = proto_util.mapError(err);
                try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                return;
            };
            mut_sample.markExecuteDone();
            mut_sample.markLockReleased();
        } else {
            const write_lock_timeout_ns = mutationWriteLockTimeoutNs(state);
            const deadline = monoNanosNow() + write_lock_timeout_ns;
            const lock_handle = graph_store.acquireGraphWriteLockCancelable(query_graph_name, deadline) catch |err| {
                if (err == error.Deadline) {
                    log.warn("Write lock acquisition timed out (bulk merge path)", &.{
                        Attr.string("graph", query_graph_name),
                        Attr.uint("timeout_ns", write_lock_timeout_ns),
                    });
                    try sendExecuteError(gpa, stream, "40001", "Write lock acquisition timed out", &.{}, &.{});
                    return;
                }
                return err;
            };
            mut_sample.markLockAcquired();

            const node_id_res = adapter.bulkMergeNode(
                query_graph_name,
                spec.label,
                spec.merge_key,
                merge_value_pv,
                kvs,
                null,
                spec.apply_on_match,
            );
            _ = node_id_res catch |err| {
                graph_store.releaseGraphLock(lock_handle);
                const info = proto_util.mapError(err);
                try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                return;
            };

            mut_sample.markExecuteDone();
            graph_store.releaseGraphLock(lock_handle);
            mut_sample.markLockReleased();
        }
    } else {
        // Phase 1 hit on the ON-CREATE-SET-only path: the merge id is
        // already in the store, ON MATCH is a no-op, nothing to apply.
        // (The bare-SET / apply_on_match case never enters this branch —
        // it skipped Phase 1 above and always took the write path.)
        mut_sample.markExecuteDone();
    }

    quic_response_metrics.recordFirstStreamMutationQueryExecute(mut_sample.execute_done_ns -| mut_sample.lock_acquire_start_ns);
    try sendEmptySuccessResult(gpa, stream);

    mut_sample.record("bulk_simple_merge");

    auditQueryExecution(state, "bulk_simple_merge", true);
    // Auto-index the merge label — mirrors the regular-executor MERGE hook at
    // `src/execution/crud_operations.zig:2293`, which runs unconditionally
    // regardless of create-vs-match (`ensureAutoIndexes` is idempotent).  The
    // bulk fast path bypasses `executeProgramWithContext`, so without this a
    // single `MERGE (n:L {...})` fails `auto_index_id_advanced.yml`: SHOW
    // INDEXES never lists `auto_idx_<label>_id`.
    execution.ensureAutoIndexes(gpa, &.{spec.label});
    syncGraphFromSession(state);
    updateTxnStateFromProgram(state, program);
}

/// GAP-0900 lever (c): concurrent batch-write fast path.
///
/// A `/*+BATCH*/`-prefixed program carrying N independent simple-MERGE
/// statements is applied by submitting ALL N ops to the group-commit
/// coordinator BEFORE awaiting any of them. The 16 shard workers then drain
/// the per-shard queues concurrently, so the coordinator coalesces many ops
/// into a handful of fsyncs (the baseline's one-op-per-round-trip pattern
/// yields ~1 op/batch -> ~1 fsync/op).
///
/// Concurrency comes purely from the submit/await split (no threads spawned):
/// `submitNoWait` runs the per-thread prepare (tenant capture + node-id
/// reservation) on THIS handler thread and enqueues; `awaitOp` blocks only
/// after every op is already in flight.
///
/// Returns `true` when the request was handled here (response sent). Returns
/// `false` to signal the caller to fall back to the general executor for the
/// WHOLE program — this happens when group-commit is disabled, when there are
/// no statements, or when ANY statement is not a simple node MERGE (no partial
/// batching). On `false` no response has been sent and no side effects remain.
fn executeBatchSimpleMerge(
    gpa: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
    state: *ServerState,
    program: *const gql_ast.Program,
    query_graph_name: []const u8,
    ctx: execution.ExecutionContext,
) !bool {
    if (!group_commit.isEnabled()) return false;
    if (program.statements.len == 0) return false;

    const geode_eval = geode.eval;
    const property_codec = geode.property_value_codec;
    const PropKV = geode.graph_storage_adapter.StorageAdapter.PropKV;

    // The arena owns every ApplyOp plus all borrowed property-value slices
    // (label/merge_key/value/props). It MUST outlive the final awaitOp — the
    // shard workers read these slices during apply and the submitter only
    // unblocks once apply completes. Freed once all awaits return.
    var batch_arena = std.heap.ArenaAllocator.init(gpa);
    var arena_live = true;
    defer if (arena_live) batch_arena.deinit();
    const ba = batch_arena.allocator();

    const env = geode.makeEnv(
        ba,
        &.{},
        &.{},
        .{ .names = ctx.query_param_names, .values = ctx.query_param_values },
    );

    const n = program.statements.len;
    const ops = try ba.alloc(group_commit.ApplyOp, n);

    // Classify + evaluate every statement BEFORE submitting anything. If ANY
    // statement is not a simple node merge, abandon the whole batch (free the
    // arena, no submits issued) and let the caller run the general executor.
    var labels = try ba.alloc([]const u8, n);
    for (program.statements, 0..) |*stmt, i| {
        const spec = geode.bulk_ingest.matchSimpleNodeMergeSpecStmt(stmt) orelse {
            // Not a simple merge -> no partial batching. Nothing submitted yet.
            return false;
        };

        // Evaluate merge filter values into the arena. The detector already
        // screened `isScalarPropExpr`, so eval/encode must succeed.
        const merge_kvs = try ba.alloc(PropKV, spec.merge_props.len);
        for (spec.merge_props, 0..) |prop, j| {
            const v = try geode_eval.evalExpr(ba, prop.value.*, env);
            const pv = try property_codec.valueToPropertyValue(ba, v);
            merge_kvs[j] = .{ .key = prop.key, .value = pv };
        }

        // Evaluate ON CREATE / bare SET values into the arena. NOTE: the
        // spec's `on_create_props` aliases a thread-local scratch buffer
        // reused on the NEXT classifier call, so we copy (by re-evaluating)
        // here. GAP-0900: a coalesce prop whose scalar evaluates to NULL is
        // OMITTED (kept-existing on match / unset on create), so trim to the
        // kept count.
        const kvs_full = try ba.alloc(PropKV, spec.on_create_props.len);
        var kvs_len: usize = 0;
        for (spec.on_create_props) |prop| {
            const v = try geode_eval.evalExpr(ba, prop.value.*, env);
            if (prop.coalesce and geode.value_types.isNull(v)) continue;
            const pv = try property_codec.valueToPropertyValue(ba, v);
            kvs_full[kvs_len] = .{ .key = prop.key, .value = pv };
            kvs_len += 1;
        }
        const kvs = kvs_full[0..kvs_len];

        labels[i] = spec.label;
        ops[i] = if (merge_kvs.len == 1)
            group_commit.ApplyOp{ .bulk_merge_node = .{
                .label = spec.label,
                .merge_key = spec.merge_key,
                .merge_value = merge_kvs[0].value,
                .on_create_props = kvs,
                .result = .{},
                .apply_on_match = spec.apply_on_match,
            } }
        else
            group_commit.ApplyOp{ .bulk_merge_node_props = .{
                .label = spec.label,
                .merge_props = merge_kvs,
                .on_create_props = kvs,
                .result = .{},
                .apply_on_match = spec.apply_on_match,
            } };
    }

    const adapter_opt = graph_store.getGlobalAdapter();
    if (adapter_opt == null) {
        try sendExecuteError(gpa, stream, "XX000", "batch fast-path: no adapter registered", &.{}, &.{});
        return true;
    }
    const adapter = adapter_opt.?;

    const coord = group_commit.getOrStartCoordinator(
        graph_store.global_allocator(),
        adapter,
        query_graph_name,
    ) catch |err| {
        const info = proto_util.mapError(err);
        try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
        return true;
    };

    var mut_sample = mutation_timing.begin();
    mut_sample.markLockAcquired();

    // Phase A: enqueue ALL ops. They pile into the per-shard queues so the
    // coordinator coalesces them. We skip the single-merge Phase-1 read probe
    // entirely — `bulkMergeNode*` re-probes the merge index inside the write
    // critical section, so concurrent/duplicate keys are handled there.
    var submit_err: ?anyerror = null;
    var submitted: usize = 0;
    while (submitted < n) : (submitted += 1) {
        coord.submitNoWait(&ops[submitted]) catch |err| {
            submit_err = err;
            break;
        };
    }

    // Phase B: await everything we managed to submit. Even on a submit error
    // we must drain the ops already enqueued so their borrowed arena slices
    // are not freed out from under an in-flight worker.
    var first_op_err: ?anyerror = null;
    var succeeded: usize = 0;
    var k: usize = 0;
    while (k < submitted) : (k += 1) {
        _ = coord.awaitOp(&ops[k]) catch |err| {
            if (first_op_err == null) first_op_err = err;
            continue;
        };
        succeeded += 1;
    }

    mut_sample.markExecuteDone();
    mut_sample.markLockReleased();

    // Auto-index every distinct merge label (idempotent), mirroring the
    // single-merge path's `ensureAutoIndexes` hook.
    execution.ensureAutoIndexes(gpa, labels);

    // All awaits have returned -> the borrowed arena slices are no longer
    // referenced by any worker. Safe to free now (response uses gpa).
    batch_arena.deinit();
    arena_live = false;

    const reportable_err: ?anyerror = if (submit_err) |se| se else first_op_err;
    if (reportable_err) |e| {
        const info = proto_util.mapError(e);
        try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
        return true;
    }

    quic_response_metrics.recordFirstStreamMutationQueryExecute(mut_sample.execute_done_ns -| mut_sample.lock_acquire_start_ns);
    // No-RETURN success shape: same empty schema + final data page the
    // single-statement merge fast path emits. `succeeded` is the count of
    // applied merges (all of them when no error fired).
    try sendEmptySuccessResult(gpa, stream);

    mut_sample.record("batch_simple_merge");
    auditQueryExecution(state, "batch_simple_merge", true);
    syncGraphFromSession(state);
    updateTxnStateFromProgram(state, program);
    return true;
}

/// Build a protobuf error response with status and error payload
fn buildErrorResponse(
    allocator: std.mem.Allocator,
    status_class: []const u8,
    message: []const u8,
    additional_statuses: []const []const u8,
    flagger_findings: []const []const u8,
) !schema.ExecutionResponse {
    const status = try proto_util.buildStatusFull(allocator, status_class, additional_statuses, flagger_findings);
    return .{
        .status = status,
        .payload = .{
            .@"error" = .{
                .code = try allocator.dupe(u8, status_class),
                .message = try allocator.dupe(u8, message),
                .type = try allocator.dupe(u8, "ERROR"),
                .anchor = try allocator.dupe(u8, ""),
            },
        },
    };
}

/// Write a length-prefixed protobuf ServerPacket to the stream
fn writeServerPacket(allocator: std.mem.Allocator, stream: *quic_transport.QuicStream, packet: schema.ServerPacket) !void {
    // Encode the packet to protobuf bytes.
    // #675: Start with 4KB initial capacity since most responses (status,
    // errors, small result sets) are well under 1KB.  The Allocating writer
    // will grow automatically for larger payloads (1000+ row result sets).
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch return error.OutOfMemory;
    defer aw.deinit();

    try protobuf.encode(&aw.writer, allocator, packet);

    const msg_bytes = aw.writer.buffer[0..aw.writer.end];
    const msg_len: u32 = @intCast(msg_bytes.len);
    _ = quic_response_metrics.response_messages_started_total.fetchAdd(1, .monotonic);
    _ = quic_response_metrics.response_encode_bytes_total.fetchAdd(msg_len, .monotonic);

    // #688: Single writeAll with length prefix prepended to avoid two QUIC
    // mutex acquisitions per response. Allocate a combined buffer, copy
    // the 4-byte big-endian length header followed by the payload, and
    // send in one call.
    const framed = try allocator.alloc(u8, 4 + msg_bytes.len);
    defer allocator.free(framed);
    std.mem.writeInt(u32, framed[0..4], msg_len, .big);
    @memcpy(framed[4..], msg_bytes);
    try stream.writeAll(framed);
    _ = quic_response_metrics.response_messages_completed_total.fetchAdd(1, .monotonic);
}

// CANARY: REQ=REQ-PERF-QUIC-READLINE-001; FEATURE="BufferedProtoReader"; ASPECT=TransportHotPath; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=wire; UPDATED=2026-06-11
/// Buffered Protobuf reader that handles Length-Prefixed messages.
const BufferedProtoReader = struct {
    allocator: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    stream: *quic_transport.QuicStream,
    buffer: std.ArrayList(u8),
    start_index: usize = 0,
    read_buf: [4096]u8 = undefined,
    /// #864 §10 per-stream stall observability.  Monotonic-clock
    /// timestamp of the most recent `nextMessage` iteration (either a
    /// successful message delivery, an EOF, a WouldBlock tick, or a
    /// raw read returning bytes).  Read by the process-wide watchdog
    /// via the registry to compute per-stream idle time — distinguishes
    /// "this specific stream is wedged" from "all streams are stuck"
    /// (which the process-wide `proto_reader_idle_ns` already covers).
    last_activity_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Cached peer-address string for diagnostic logging.  Set by the
    /// caller after `init`; the registry callback exposes it so the
    /// stall log line can identify WHICH client is wedged.  Empty
    /// string when unset (initial state).
    peer_addr: []const u8 = "",

    pub fn init(
        allocator: std.mem.Allocator,
        transport: *quic_transport.QuicTransport,
        stream: *quic_transport.QuicStream,
    ) !BufferedProtoReader {
        return .{
            .allocator = allocator,
            .transport = transport,
            .stream = stream,
            .buffer = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *BufferedProtoReader) void {
        self.buffer.deinit(self.allocator);
    }

    /// Snapshot the monotonic clock and publish it as the most recent
    /// per-reader activity timestamp.  Wait-free release store.
    /// Called from each branch of the `nextMessage` loop (alongside
    /// the global proto_reader counter ticks) so the registry sees
    /// progress on every iteration, not just successful deliveries.
    fn recordActivity(self: *BufferedProtoReader) void {
        self.last_activity_ns.store(monoNsFromHandler(), .release);
    }

    /// Registry callback: read the per-reader last-activity timestamp.
    fn registryGetActivity(ptr: *anyopaque) u64 {
        const self: *BufferedProtoReader = @ptrCast(@alignCast(ptr));
        return self.last_activity_ns.load(.acquire);
    }

    /// Registry callback: read the per-reader QUIC stream id.
    fn registryGetStreamId(ptr: *anyopaque) u64 {
        const self: *BufferedProtoReader = @ptrCast(@alignCast(ptr));
        return self.stream.stream_id;
    }

    /// Registry callback: read the per-reader peer-address string.
    fn registryGetPeerAddr(ptr: *anyopaque) []const u8 {
        const self: *BufferedProtoReader = @ptrCast(@alignCast(ptr));
        return self.peer_addr;
    }

    /// Build a registry handle pointing at this reader.  The caller is
    /// responsible for invoking `proto_reader_registry.register`
    /// immediately after this returns and `unregister` before the
    /// reader's storage is freed.
    pub fn registryHandle(self: *BufferedProtoReader) proto_reader_registry.Handle {
        return .{
            .self = @ptrCast(self),
            .getActivityNs = registryGetActivity,
            .getStreamId = registryGetStreamId,
            .getPeerAddr = registryGetPeerAddr,
        };
    }

    fn decodeBufferedMessage(self: *BufferedProtoReader) !?schema.ClientPacket {
        // REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME (2026-06-10): defensive framing
        // guard. The diagnosed SIGSEGV was a GP fault in `std.mem.readInt` at the
        // length-prefix read below, ultimately rooted in a use-after-free of the
        // owning `FirstStreamOwnerContext` (a freed/torn reader). The lifetime fix
        // removes the root cause; this guard turns any residual torn/corrupt
        // reader (`start_index` advanced past the buffer, e.g. a partially-freed
        // ArrayList observed mid-tear) into a loud, recoverable error instead of
        // an out-of-bounds slice that GP-faults. Pinned by
        // `first_stream_decode_buffered_framing_bounds_pin`.
        if (self.start_index > self.buffer.items.len) {
            log.err("decodeBufferedMessage: start_index past buffer end (torn/corrupt reader)", &.{
                Attr.int("start_index", @intCast(self.start_index)),
                Attr.int("buf_len", @intCast(self.buffer.items.len)),
            });
            return error.CorruptStreamFraming;
        }
        const unread = self.buffer.items[self.start_index..];
        if (unread.len < 4) return null;

        const len_bytes = unread[0..4];
        const msg_len = std.mem.readInt(u32, len_bytes, .big);
        if (msg_len > 16 * 1024 * 1024) {
            log.err("MessageTooLarge: msg_len={d} bytes_in_buf={d} start_index={d}", &.{ Attr.int("msg_len", @intCast(msg_len)), Attr.int("buf_len", @intCast(self.buffer.items.len)), Attr.int("start", @intCast(self.start_index)) });
            return error.MessageTooLarge;
        }

        if (unread.len < 4 + msg_len) return null;

        const msg_bytes = unread[4..][0..msg_len];
        var reader: std.Io.Reader = .fixed(msg_bytes);
        const msg = protobuf.decode(schema.ClientPacket, &reader, self.allocator) catch |err| {
            log.warn("Failed to decode Protobuf message", &.{Attr.string("error", @errorName(err))});
            return err;
        };

        self.start_index += 4 + msg_len;
        self.compactBuffer();
        _ = proto_reader_metrics.messages_delivered_total.fetchAdd(1, .monotonic);
        proto_reader_metrics.recordActivity();
        self.recordActivity();
        return msg;
    }

    // CANARY: REQ=REQ-QUIC-HC-140; FEATURE="High-Concurrency First Streams"; ASPECT=CooperativeBufferedRequeue; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-28
    //
    // Cooperative owners process a bounded number of messages per scheduler
    // turn. If a read pulled multiple framed client messages into the proto
    // buffer, the owner must stay runnable even without a fresh QUIC RX
    // generation. Empty buffers should park until the notifier fires instead
    // of taking an immediate extra scheduler turn just to observe WouldBlock.
    fn hasBufferedUnread(self: *const BufferedProtoReader) bool {
        return self.start_index < self.buffer.items.len;
    }

    // CANARY: REQ=REQ-QUIC-HC-054; FEATURE="QUIC High-Concurrency Requests"; ASPECT=CooperativeFirstStreams; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
    /// Non-blocking variant used by the cooperative first-stream scheduler.
    /// It returns WouldBlock as soon as the current stream has no readable
    /// bytes, letting the scheduler move to another connection instead of
    /// pinning a worker on this one.
    pub fn nextMessageNonBlocking(self: *BufferedProtoReader) !?schema.ClientPacket {
        while (true) {
            if (try self.decodeBufferedMessage()) |msg| return msg;

            const n = self.stream.read(&self.read_buf) catch |err| {
                if (err == error.WouldBlock) {
                    _ = proto_reader_metrics.would_block_loop_iterations_total.fetchAdd(1, .monotonic);
                    proto_reader_metrics.recordActivity();
                    self.recordActivity();
                }
                return err;
            };

            if (n == 0) {
                if (self.start_index == self.buffer.items.len) {
                    _ = proto_reader_metrics.eof_total.fetchAdd(1, .monotonic);
                    proto_reader_metrics.recordActivity();
                    self.recordActivity();
                    return null;
                }
                return error.UnexpectedEndOfStream;
            }

            _ = proto_reader_metrics.bytes_read_total.fetchAdd(@as(u64, n), .monotonic);
            proto_reader_metrics.recordActivity();
            self.recordActivity();
            try self.buffer.appendSlice(self.allocator, self.read_buf[0..n]);
        }
    }

    // Idle-connection reap policy for `nextMessage`.
    //
    // FIX (docs/bugs/2026-06-18-idle-pool-spin-reap-cap.md): the previous
    // policy reaped a lingering/idle client connection by counting WouldBlock
    // attempts (`max_would_block_attempts = 300000`) with a comment claiming
    // "300s at 1ms sleep". But each WouldBlock parks for
    // `quic_transport.server_handler_wait_for_poll_ns` which is 100ms, NOT
    // 1ms — so the real reap deadline was 300000 × 100ms = 30,000,000ms ≈
    // 8.3 HOURS. Idle connections lingered ~8.3h, each waking the thread pool
    // every 100ms → sustained pool spin / high CPU post-ingest.
    //
    // This is now a WALL-CLOCK deadline measured with `compat_milliTimestamp()`
    // rather than an attempt count, so it is robust to the wait duration
    // (server_handler_wait_for_poll_ns = 100ms): the reap fires at ~300s of
    // CONTINUOUS idleness regardless of how long each park lasts, instead of
    // mis-scaling with the park duration. 300s matches the QUIC idle-timeout
    // intent for reaping lingering client connections.
    pub const proto_reader_idle_reap_deadline_ms: i64 = 300_000; // ~300s wall-clock idle reap deadline

    /// Pure reap predicate: given how long a connection has been idle (no
    /// readable bytes, only WouldBlock), decide whether to reap it. Takes the
    /// elapsed time as a parameter so it is deterministic and unit-testable —
    /// it must NOT read the clock itself.
    pub fn shouldReapIdleConnection(elapsed_idle_ms: i64) bool {
        return elapsed_idle_ms >= proto_reader_idle_reap_deadline_ms;
    }

    // Reads the next length-prefixed message.
    // Length is 4 bytes Big Endian.
    pub fn nextMessage(self: *BufferedProtoReader) !?schema.ClientPacket {
        // Wall-clock idle reap: lazily capture the first-WouldBlock timestamp
        // and reap after `proto_reader_idle_reap_deadline_ms` of CONTINUOUS
        // idleness. Robust to the park duration (server_handler_wait_for_poll_ns
        // = 100ms), unlike the old attempt-count cap which mis-scaled to ~8.3h.
        var idle_start_ms: ?i64 = null;

        while (true) {
            if (try self.decodeBufferedMessage()) |msg| return msg;

            // Need more data
            const read_generation = self.stream.readGeneration();
            const n = self.stream.read(&self.read_buf) catch |err| {
                if (err == error.WouldBlock) {
                    _ = proto_reader_metrics.would_block_loop_iterations_total.fetchAdd(1, .monotonic);
                    proto_reader_metrics.recordActivity();
                    self.recordActivity();
                    const start_ms = idle_start_ms orelse blk: {
                        const now = compat_milliTimestamp();
                        idle_start_ms = now;
                        break :blk now;
                    };
                    const elapsed_ms = compat_milliTimestamp() - start_ms;
                    if (shouldReapIdleConnection(elapsed_ms)) {
                        return error.Timeout;
                    }
                    // QUIC-HC-037: wait on this connection's RX generation.
                    // The vendored endpoint bumps it when STREAM data or FIN
                    // is delivered to this connection, so high fan-out readers
                    // avoid the endpoint-wide poll wake herd.
                    self.stream.waitForReadGeneration(read_generation, quic_transport.server_handler_wait_for_poll_ns);
                    continue;
                }
                return err;
            };

            // Any progress (real read or EOF) resets the continuous-idle clock,
            // so the deadline only measures uninterrupted no-bytes time — same
            // intent as the old `would_block_attempts = 0` reset.
            idle_start_ms = null;

            if (n == 0) {
                if (self.start_index == self.buffer.items.len) {
                    // Clean EOF
                    _ = proto_reader_metrics.eof_total.fetchAdd(1, .monotonic);
                    proto_reader_metrics.recordActivity();
                    self.recordActivity();
                    return null; // Return optional null for EOF
                }
                // Partial message EOF
                return error.UnexpectedEndOfStream;
            }

            _ = proto_reader_metrics.bytes_read_total.fetchAdd(@as(u64, n), .monotonic);
            proto_reader_metrics.recordActivity();
            self.recordActivity();
            try self.buffer.appendSlice(self.allocator, self.read_buf[0..n]);
        }
    }

    fn compactBuffer(self: *BufferedProtoReader) void {
        if (self.start_index == 0) return;

        const remaining = self.buffer.items.len - self.start_index;
        if (remaining == 0) {
            self.buffer.clearRetainingCapacity();
            self.start_index = 0;
            return;
        }

        // Compact when we've consumed a significant prefix
        if (self.start_index < 4096 and self.start_index * 2 < self.buffer.items.len) {
            return;
        }

        std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[self.start_index..]);
        self.buffer.shrinkRetainingCapacity(remaining);
        self.start_index = 0;
    }
};

/// TEST SEAM (REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME): drive the REAL framing
/// decode (`decodeBufferedMessage`) over a caller-supplied buffer with a chosen
/// `start_index`, so the lifetime test can pin the defensive-framing contract.
///
/// The diagnosed SIGSEGV was a `std.mem.readInt` GP-fault at the framing site;
/// the root cause is a use-after-free, but the fixer is also adding a bounds
/// diagnostic to `decodeBufferedMessage`. This export pins that diagnostic:
/// with a torn/corrupt reader (`start_index > buffer.len`) the decoder must NOT
/// index out of bounds. `BufferedProtoReader` is private, so this thin export
/// is the seam. The `transport`/`stream` pointers are NOT dereferenced by
/// `decodeBufferedMessage` (it only touches `self.buffer`/`self.start_index`),
/// so dummy pointers are safe here.
pub fn decodeBufferedMessageForTest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    start_index: usize,
) !?schema.ClientPacket {
    const dummy_transport: *quic_transport.QuicTransport = @ptrFromInt(0xDEAD_F00D_1000);
    const dummy_stream: *quic_transport.QuicStream = @ptrFromInt(0xDEAD_F00D_2000);
    var reader = try BufferedProtoReader.init(allocator, dummy_transport, dummy_stream);
    defer reader.deinit();
    try reader.buffer.appendSlice(allocator, bytes);
    reader.start_index = start_index;
    return reader.decodeBufferedMessage();
}

fn sendQuicMessage(allocator: std.mem.Allocator, stream: *quic_transport.QuicStream, msg: schema.QuicServerMessage) !void {
    const first_stream_response_start_ns = monoNsFromHandler();
    defer quic_response_metrics.recordFirstStreamResponseSend(monoNsFromHandler() -| first_stream_response_start_ns);

    var msg_copy = msg;
    defer msg_copy.deinit(allocator);
    try writeServerPacket(allocator, stream, .{ .quic = msg_copy });
}

// CANARY: REQ=REQ-QUIC-HC-077; FEATURE="QUIC High-Concurrency Requests"; ASPECT=BatchedExecuteResponseWrite; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
fn sendQuicMessagesBatched(
    allocator: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
    messages: []const schema.QuicServerMessage,
) !void {
    const first_stream_response_start_ns = monoNsFromHandler();
    defer quic_response_metrics.recordFirstStreamResponseSend(monoNsFromHandler() -| first_stream_response_start_ns);

    _ = quic_response_metrics.response_batches_started_total.fetchAdd(1, .monotonic);
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(allocator);

    for (messages) |msg| {
        var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 1024) catch return error.OutOfMemory;
        defer aw.deinit();

        try protobuf.encode(&aw.writer, allocator, schema.ServerPacket{ .quic = msg });
        const msg_bytes = aw.writer.buffer[0..aw.writer.end];
        const msg_len: u32 = @intCast(msg_bytes.len);
        _ = quic_response_metrics.response_messages_started_total.fetchAdd(1, .monotonic);
        _ = quic_response_metrics.response_encode_bytes_total.fetchAdd(msg_len, .monotonic);

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, msg_len, .big);
        try framed.appendSlice(allocator, &len_buf);
        try framed.appendSlice(allocator, msg_bytes);
    }

    try stream.writeAll(framed.items);
    _ = quic_response_metrics.response_messages_completed_total.fetchAdd(@intCast(messages.len), .monotonic);
    _ = quic_response_metrics.response_batches_completed_total.fetchAdd(1, .monotonic);
}

// CANARY: REQ=REQ-QUIC-HC-089; FEATURE="QUIC High-Concurrency Requests"; ASPECT=BatchedEmptyMutationSuccess; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
fn sendEmptySuccessResult(
    allocator: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
) !void {
    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const ra = response_arena.allocator();

    const schema_status = try proto_util.buildStatus(ra, "00000", &.{});
    const schema_def = schema.SchemaDefinition{
        .columns = std.ArrayList(schema.ColumnDefinition).empty,
    };
    const schema_resp = schema.ExecutionResponse{
        .status = schema_status,
        .payload = .{ .schema = schema_def },
    };

    const page = try proto_util.buildDataPageFromRows(ra, &.{}, true, false, &.{});
    const page_status = try proto_util.buildStatus(ra, "00000", &.{});
    const page_resp = schema.ExecutionResponse{
        .status = page_status,
        .payload = .{ .page = page },
    };

    const batched = [_]schema.QuicServerMessage{
        .{ .execute = schema_resp },
        .{ .execute = page_resp },
    };
    try sendQuicMessagesBatched(ra, stream, &batched);
}

// CANARY: REQ=REQ-QUIC-HC-146; FEATURE="QUIC High-Concurrency Reads"; ASPECT=SharedCountResponseBatch; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-28
fn sendSinglePageExecutionResultBatched(
    allocator: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
    result: *execution.ExecutionResult,
) !void {
    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const ra = response_arena.allocator();

    const status = try proto_util.buildStatus(ra, "00000", result.flags.items);
    const schema_def = try proto_util.buildSchemaDefinition(ra, result);
    const schema_resp = schema.ExecutionResponse{
        .status = status,
        .payload = .{ .schema = schema_def },
    };

    const page = try proto_util.buildDataPage(ra, result, 0, 1, false, &.{});
    const page_status = try proto_util.buildStatus(ra, "00000", result.flags.items);
    const page_resp = schema.ExecutionResponse{
        .status = page_status,
        .payload = .{ .page = page },
    };

    const batched = [_]schema.QuicServerMessage{
        .{ .execute = schema_resp },
        .{ .execute = page_resp },
    };
    try sendQuicMessagesBatched(ra, stream, &batched);
}

fn sendExecuteError(
    allocator: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
    status_class: []const u8,
    message: []const u8,
    additional_statuses: []const []const u8,
    flagger_findings: []const []const u8,
) !void {
    const resp = try buildErrorResponse(allocator, status_class, message, additional_statuses, flagger_findings);
    try sendQuicMessage(allocator, stream, .{ .execute = resp });
}

fn sendPullError(
    allocator: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
    status_class: []const u8,
    message: []const u8,
    additional_statuses: []const []const u8,
    flagger_findings: []const []const u8,
) !void {
    const resp = try buildErrorResponse(allocator, status_class, message, additional_statuses, flagger_findings);
    try sendQuicMessage(allocator, stream, .{ .pull = .{ .response = resp } });
}

fn appendFlagIfMissing(allocator: std.mem.Allocator, flags: *std.ArrayList([]const u8), flag: []const u8) !void {
    for (flags.items) |existing| {
        if (std.mem.eql(u8, existing, flag)) return;
    }
    try flags.append(allocator, flag);
}

// Append a flag to an ExecutionResult, duplicating if the result owns memory
fn appendFlagToResult(allocator: std.mem.Allocator, result: *execution.ExecutionResult, flag: []const u8) !void {
    for (result.flags.items) |existing| {
        if (std.mem.eql(u8, existing, flag)) return;
    }
    // Duplicate flag if result owns memory, otherwise string literal is fine
    const flag_to_add = if (result.owns_value_memory) try allocator.dupe(u8, flag) else flag;
    try result.flags.append(allocator, flag_to_add);
}

fn replaceOwnedOptionalString(allocator: std.mem.Allocator, slot: *?[]const u8, next: ?[]const u8) !void {
    if (slot.*) |current| {
        if (next) |candidate| {
            if (std.mem.eql(u8, current, candidate)) return;
        }
        allocator.free(current);
        slot.* = null;
    }
    if (next) |value| {
        slot.* = try allocator.dupe(u8, value);
    }
}

/// Extract variable name and property name from a property access expression.
/// Handles both PropertyAccess (object.property) and Member (Ident.field) forms.
fn extractVarProperty(expr: gql_ast.Expr) ?struct { variable: []const u8, property: []const u8 } {
    if (expr == .PropertyAccess) {
        const pa = expr.PropertyAccess;
        return .{ .variable = pa.object, .property = pa.property };
    }
    if (expr == .Member) {
        const m = expr.Member;
        if (m.target.* == .Ident) {
            return .{ .variable = m.target.Ident.orig, .property = m.field };
        }
    }
    return null;
}

/// Check if a WHERE clause contains an equality predicate on a property
/// that matches a catalog index for the given label and variable name.
fn whereHasIndexedEq(where_expr: gql_ast.Expr, var_name: []const u8, label: []const u8, cat: anytype) bool {
    switch (where_expr) {
        .Binary => |bin| {
            if (bin.op == .And) {
                if (whereHasIndexedEq(bin.left.*, var_name, label, cat)) return true;
                if (whereHasIndexedEq(bin.right.*, var_name, label, cat)) return true;
                return false;
            } else if (bin.op == .Eq) {
                const prop_name = blk: {
                    if (extractVarProperty(bin.left.*)) |vp| {
                        if (std.mem.eql(u8, vp.variable, var_name)) break :blk vp.property;
                    }
                    if (extractVarProperty(bin.right.*)) |vp| {
                        if (std.mem.eql(u8, vp.variable, var_name)) break :blk vp.property;
                    }
                    break :blk @as(?[]const u8, null);
                };
                if (prop_name) |pn| {
                    var idx_iter = cat.indexes.valueIterator();
                    while (idx_iter.next()) |info| {
                        if (std.mem.eql(u8, info.table_name, label) and
                            info.columns.len > 0 and
                            std.mem.eql(u8, info.columns[0], pn)) return true;
                    }
                }
                return false;
            }
            return false;
        },
        else => return false,
    }
}

fn findOrderBy(program: *const gql_ast.Program) ?*const gql_ast.OrderBy {
    var idx: usize = program.statements.len;
    while (idx > 0) : (idx -= 1) {
        const stmt_ptr = &program.statements[idx - 1];
        switch (stmt_ptr.*) {
            .Query => |*q| {
                if (q.order_by) |*ob| return ob;
                return null;
            },
            .Union => |*u| {
                if (u.order_by) |ob_ptr| return ob_ptr;
                return null;
            },
            .StartTransaction, .Commit, .Rollback => continue,
            else => return null,
        }
    }
    return null;
}

fn buildOrderKeys(
    allocator: std.mem.Allocator,
    order_by: *const gql_ast.OrderBy,
    result: *const execution.ExecutionResult,
) ![]const []const u8 {
    var keys = try allocator.alloc([]const u8, order_by.keys.len);
    var i: usize = 0;
    while (i < order_by.keys.len) : (i += 1) {
        const expr = order_by.keys[i].expr;
        if (expr == .Int) {
            const ordinal = expr.Int;
            if (ordinal > 0 and @as(usize, @intCast(ordinal)) <= result.columns.len) {
                keys[i] = try allocator.dupe(u8, result.columns[@intCast(ordinal - 1)]);
                continue;
            }
        }
        keys[i] = try gql_print.stringifyExprAlloc(allocator, expr, .{});
    }
    return keys;
}

const DEBUG_PROFILE = false;

// ── Stream multiplexing support ──────────────────────────────────────────────
// CANARY: REQ=REQ-QUIC-MUX-001; FEATURE="StreamMultiplexing"; ASPECT=SharedConnState; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=server; UPDATED=2026-06-11
/// Shared connection state for QUIC stream multiplexing.
/// After the HELLO handshake on the first stream, this holds the authenticated
/// identity that is inherited by all additional streams on the connection.
/// Fields are read-only after initialization (set once after HELLO).
pub const SharedConnState = struct {
    allocator: std.mem.Allocator,
    /// Authenticated username (owned, heap-allocated). Null if auth is disabled.
    authenticated_user: ?[]const u8 = null,
    /// Authenticated role (u8 enum value of user_mgmt.Role).
    authenticated_role: ?u8 = null,
    /// Authenticated auth_version captured at HELLO.
    authenticated_auth_version: u64 = 0,
    /// Auth invalidation epoch observed after the last successful validation.
    authenticated_auth_validation_epoch: u64 = 0,
    /// Whether the user must reset their password.
    password_reset_required: bool = false,
    /// Tenant id captured from HELLO session config (owned).
    tenant_id: ?[]const u8 = null,
    /// FLE role captured from HELLO (owned).
    fle_user_role: ?[]const u8 = null,
    /// Session graph binding (owned, heap-allocated). Null if not bound.
    current_graph: ?[]const u8 = null,
    /// Whether the session was bound to a graph via DSN/HELLO.
    graph_bound: bool = false,
    /// Security manager pointer (global lifetime, not owned).
    security_manager: ?*geode_auth.SecurityManager = null,
    /// Shared AST cache pointer (global lifetime, not owned).
    shared_ast_cache: ?*anyopaque = null,
    /// Shared query optimizer pointer (global lifetime, not owned).
    shared_optimizer: ?*query_plan_cache.SharedQueryOptimizer = null,
    /// Peer IP string for rate limiting (owned if allocated).
    peer_ip: []const u8 = "unknown",
    peer_ip_allocated: bool = false,
    /// Server configuration flags (immutable after init).
    disable_estimates: bool = false,
    compact_profile: bool = false,
    memcurve_profile: bool = false,
    env_spill_threshold: usize = 0,
    env_storage_checksum_error: bool = false,
    /// #683: Cached env config pointer (global lifetime, not owned).
    env_config: ?*const server_init.EnvironmentConfig = null,
    /// Number of active streams (including the first one). Used to know when
    /// the connection is idle. Atomic so the acceptor thread and stream handler
    /// threads can update it without a mutex.
    active_streams: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// GAP-0274: Condition variable for stream drain — replaces sleep-polling.
    /// Handler threads signal on stream close; main thread waits instead of spinning.
    streams_mu: std.Io.Mutex = std.Io.Mutex.init,
    streams_cv: std.Io.Condition = std.Io.Condition.init,
    /// Active QUIC stream IDs currently owned by handlers. The QUIC library may
    /// re-queue a stream ID whenever more data arrives, so the acceptor must not
    /// treat every accept notification as a new handler-worthy stream.
    active_stream_registry: stream_registry.ActiveStreamRegistry = .{},

    /// Pending result transferred from a stream handler that exited before the
    /// client's PULL arrived.  The QUIC library can report a spurious stream
    /// FIN under concurrent load, causing the handler to exit while the client
    /// still has an active result.  Protected by streams_mu.
    pending_result: ?execution.ExecutionResult = null,
    pending_node_scan_stream: ?node_scan_stream.NodeScanStream = null,
    pending_result_page_index: usize = 0,
    pending_result_ordered: bool = false,
    pending_result_order_keys: []const []const u8 = &.{},

    /// Snapshot shared identity from a fully-initialized ServerState (after HELLO).
    pub fn captureFromState(self: *SharedConnState, state: *const ServerState) !void {
        if (state.authenticated_user) |u| {
            self.authenticated_user = try self.allocator.dupe(u8, u);
        }
        self.authenticated_role = state.authenticated_role;
        self.authenticated_auth_version = state.authenticated_auth_version;
        self.authenticated_auth_validation_epoch = state.authenticated_auth_validation_epoch;
        self.password_reset_required = state.password_reset_required;
        if (state.session_config) |cfg| {
            if (cfg.tenant_id) |tid| {
                self.tenant_id = try self.allocator.dupe(u8, tid);
            }
        }
        if (state.fle_user_role) |role| {
            self.fle_user_role = try self.allocator.dupe(u8, role);
        }
        self.graph_bound = state.graph_bound;
        if (state.exec_session) |sess| {
            if (sess.graph) |g| {
                self.current_graph = try self.allocator.dupe(u8, g);
            }
        }
    }

    pub fn deinit(self: *SharedConnState) void {
        if (self.authenticated_user) |u| self.allocator.free(u);
        if (self.tenant_id) |tid| self.allocator.free(tid);
        if (self.fle_user_role) |role| self.allocator.free(role);
        if (self.current_graph) |g| self.allocator.free(g);
        if (self.pending_result) |*r| r.deinit(self.allocator);
        if (self.pending_node_scan_stream) |*s| s.deinit();
        for (self.pending_result_order_keys) |k| self.allocator.free(k);
        if (self.pending_result_order_keys.len > 0) self.allocator.free(self.pending_result_order_keys);
        // peer_ip freed by the connection handler's defer
    }

    pub fn registerActiveStream(self: *SharedConnState, stream_id: u64) !bool {
        return self.active_stream_registry.register(stream_id);
    }

    pub fn unregisterActiveStream(self: *SharedConnState, stream_id: u64) void {
        _ = self.active_stream_registry.unregister(stream_id);
    }

    pub fn releaseActiveStream(self: *SharedConnState) void {
        const prev = self.active_streams.fetchSub(1, .release);
        std.debug.assert(prev > 0);
        // Wake both the connection-owner drain waiter and the acceptor's
        // stream-slot admission waiter.  One stream slot was freed, so one
        // futex waiter is enough; the condition signal preserves the existing
        // owner wait contract.
        self.streams_cv.signal(std.Io.Threaded.global_single_threaded.io());
        std.Io.Threaded.global_single_threaded.io().futexWake(u32, &self.active_streams.raw, 1);
    }

    pub fn waitForStreamSlot(self: *SharedConnState, limit: u32, timeout_ns: u64) void {
        if (timeout_ns == 0) return;

        const io = std.Io.Threaded.global_single_threaded.io();
        const start_ns = monoNsFromHandler();
        var remaining_ns = timeout_ns;

        while (self.active_streams.load(.acquire) >= limit) {
            const observed = self.active_streams.load(.acquire);
            if (observed < limit) return;

            const timeout: std.Io.Timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(@intCast(remaining_ns)),
                .clock = .awake,
            } };
            io.futexWaitTimeout(u32, &self.active_streams.raw, observed, timeout) catch |err| switch (err) {
                error.Canceled => return,
            };

            const elapsed_ns = monoNsFromHandler() -| start_ns;
            if (elapsed_ns >= timeout_ns) return;
            remaining_ns = timeout_ns - elapsed_ns;
        }
    }

    pub fn waitForAllStreamsDrained(self: *SharedConnState) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        while (true) {
            const observed = self.active_streams.load(.acquire);
            if (observed == 0) return;
            std.Io.futexWaitUncancelable(io, u32, &self.active_streams.raw, observed);
        }
    }

    pub fn syncGraphFromState(self: *SharedConnState, state: *const ServerState) !void {
        self.streams_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.streams_mu.unlock(std.Io.Threaded.global_single_threaded.io());

        const usernames_equal = blk: {
            if (self.authenticated_user) |current| {
                if (state.authenticated_user) |next| {
                    break :blk std.mem.eql(u8, current, next);
                }
            }
            break :blk self.authenticated_user == null and state.authenticated_user == null;
        };
        if (!usernames_equal) {
            if (self.authenticated_user) |user| {
                self.allocator.free(user);
                self.authenticated_user = null;
            }
            if (state.authenticated_user) |user| {
                self.authenticated_user = try self.allocator.dupe(u8, user);
            }
        }
        self.authenticated_role = state.authenticated_role;
        self.authenticated_auth_version = state.authenticated_auth_version;
        self.authenticated_auth_validation_epoch = state.authenticated_auth_validation_epoch;
        self.password_reset_required = state.password_reset_required;
        try replaceOwnedOptionalString(
            self.allocator,
            &self.tenant_id,
            if (state.session_config) |cfg| cfg.tenant_id else null,
        );
        try replaceOwnedOptionalString(self.allocator, &self.fle_user_role, state.fle_user_role);

        if (self.current_graph) |graph| {
            self.allocator.free(graph);
            self.current_graph = null;
        }

        if (state.exec_session) |sess| {
            if (sess.graph) |graph| {
                self.current_graph = try self.allocator.dupe(u8, graph);
            }
        }
    }
};

/// Context passed to a spawned stream handler thread.
const StreamHandlerContext = struct {
    allocator: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    stream: *quic_transport.QuicStream,
    conn_state: *SharedConnState,
};

/// Context shared between `handleQuicConnection` (the owner) and the
/// dedicated stream-acceptor worker thread.  Exposed so the regression
/// tests in `tests/test_acceptor_lifetime.zig` can pin the heap +
/// refcount lifetime contract via the public API.
///
/// Lifetime model (2026-04-28 rewrite):
/// The struct is HEAP-allocated and refcounted with two starting refs:
/// one for the owner and one for the acceptor. Each side calls
/// `release()` exactly once when it's done with the struct; the last
/// caller frees it. Atomics live INSIDE the struct (not as pointers
/// to stack vars), so even if the owner's frame would unwind early
/// the acceptor's `shutdown.load()` reads valid heap memory.
///
/// Why not stack-allocate (the previous design, pre-2026-04-28)?
/// The owner used to wait on a stack `acceptor_done` flag with a 5 s
/// deadline-bail. Under heavy stream-pool contention the wait sometimes
/// timed out before the acceptor's idle loop saw `shutdown=true`,
/// the owner's frame popped, and the acceptor's next `@atomicLoad`
/// segfaulted on freed stack memory (address 0x6, see
/// `tests/test_acceptor_lifetime.zig`).  Heap allocation + refcount
/// removes that failure mode entirely: the owner can wait as long as
/// it likes (or even give up — though we still wait forever today, just
/// with periodic warnings), without any UAF risk.
///
/// Conn lifetime: `transport.destroyConnection(conn)` is still in the
/// owner's defer (line ~1728), and runs LAST (LIFO).  The owner's
/// shutdown-wait defer (registered after) runs first; it returns only
/// when `done=true`, i.e., the acceptor's loop has exited and is no
/// longer touching `conn`.  So conn destruction always happens after
/// the acceptor stops dereferencing it.
pub const StreamAcceptorContext = struct {
    allocator: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    conn: *quic_transport.QuicConnection,
    conn_state: *SharedConnState,
    stream_pool: *pooled.ThreadPool,
    /// Set true by the owner when it wants the acceptor to exit.  The
    /// acceptor checks this at the top of every loop iteration.
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set true by the acceptor's defer immediately before it returns.
    /// The owner waits on this before letting its stack frame unwind so
    /// `conn` stays alive while the acceptor is still dereferencing it.
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Futex generation paired with `done`. The public done flag remains a
    /// bool for the leaked-connection reaper/tests, while the owner can wait
    /// without a fixed sleep loop during high connection close churn.
    done_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Outstanding refs.  Initialized to 2 (owner + acceptor); each
    /// caller invokes `release()` exactly once when finished.  The
    /// last release frees the heap struct.
    refcount: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),

    /// Heap-allocate and initialize a new context.  Caller owns one
    /// reference; the acceptor will own the other once its task starts.
    pub fn create(
        gpa: std.mem.Allocator,
        transport: *quic_transport.QuicTransport,
        conn: *quic_transport.QuicConnection,
        conn_state: *SharedConnState,
        stream_pool: *pooled.ThreadPool,
    ) !*StreamAcceptorContext {
        const self = try gpa.create(StreamAcceptorContext);
        self.* = .{
            .allocator = gpa,
            .transport = transport,
            .conn = conn,
            .conn_state = conn_state,
            .stream_pool = stream_pool,
        };
        return self;
    }

    /// Decrement the refcount; free the struct on the last release.
    /// Safe to call from either the owner thread or the acceptor thread.
    pub fn release(self: *StreamAcceptorContext) void {
        const prev = self.refcount.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
        if (prev == 1) {
            self.allocator.destroy(self);
        }
    }

    /// Bump the refcount by one.  Used by the leaked-connection reaper
    /// registry (§6.5): when the owner bails on the acceptor's exit
    /// deadline it parks the {conn, ctx} pair with an additional ref so
    /// the reaper can later poll `ctx.done` safely without risk of the
    /// ctx being freed under it.  The caller must pair with a later
    /// `release()`.  Safe to call from any thread holding a live ref.
    pub fn addRef(self: *StreamAcceptorContext) void {
        const prev = self.refcount.fetchAdd(1, .acq_rel);
        std.debug.assert(prev > 0);
    }

    pub fn markDone(self: *StreamAcceptorContext) void {
        self.done.store(true, .release);
        _ = self.done_generation.fetchAdd(1, .release);
        std.Io.Threaded.global_single_threaded.io().futexWake(u32, &self.done_generation.raw, std.math.maxInt(u32));
    }

    pub fn waitUntilDone(self: *StreamAcceptorContext, timeout_ns: u64) bool {
        if (self.done.load(.acquire)) return true;
        if (timeout_ns == 0) return self.done.load(.acquire);

        const observed = self.done_generation.load(.acquire);
        if (self.done.load(.acquire)) return true;

        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(@intCast(timeout_ns)),
            .clock = .awake,
        } };
        const io = std.Io.Threaded.global_single_threaded.io();
        io.futexWaitTimeout(u32, &self.done_generation.raw, observed, timeout) catch |err| switch (err) {
            error.Canceled => return self.done.load(.acquire),
        };
        return self.done.load(.acquire);
    }
};

const SessionAuthStatus = enum {
    ok,
    missing,
    invalidated,
};

fn isIdleStreamReadError(err: anyerror) bool {
    return err == error.EndOfStream or err == error.Timeout or err == error.Closed;
}

fn installThreadLocalSessionState(state: *const ServerState) void {
    fle_integration.setCurrentTenantId(if (state.session_config) |cfg| cfg.tenant_id else null);
    audit_mod.setCurrentAuditTenantId(if (state.session_config) |cfg| cfg.tenant_id else null);
    fle_integration.setCurrentUserRole(state.fle_user_role);
}

fn clearThreadLocalSessionState() void {
    fle_integration.clearCurrentThreadState();
    audit_mod.setCurrentAuditTenantId(null);
}

const CooperativeMutationAdmissionClass = enum(u8) {
    none = 0,
    serial = 1,
    shard_parallel = 2,
};

fn releaseQuotaTenant(gpa: std.mem.Allocator, quota_tenant_id: *?[]const u8) void {
    if (quota_tenant_id.*) |tid| {
        if (tenant_quota.getGlobalQuotaManager()) |qm| {
            qm.releaseConnection(tid);
        }
        gpa.free(tid);
        quota_tenant_id.* = null;
    }
}

fn deinitQuicServerState(gpa: std.mem.Allocator, state: *ServerState, context: []const u8) void {
    const store_for_teardown = graph_store.getGlobalStore(gpa);
    state.tearDownForStreamClose(store_for_teardown) catch |err| {
        log.warn("orphan-txn teardown failed", &.{
            Attr.string("context", context),
            Attr.string("error", @errorName(err)),
        });
    };
    state.resetResult();
    if (state.current_graph) |g| {
        gpa.free(g);
        state.current_graph = null;
    }
    if (state.exec_session) |*sess| {
        sess.deinit();
        state.exec_session = null;
    }
    if (state.session_config) |*cfg| {
        cfg.deinit();
        state.session_config = null;
    }
    if (state.authenticated_user) |u| {
        gpa.free(u);
        state.authenticated_user = null;
    }
    if (state.authenticated_password) |p| {
        std.crypto.secureZero(u8, @constCast(p));
        gpa.free(p);
        state.authenticated_password = null;
    }
    if (state.fle_user_role) |role| {
        gpa.free(role);
        state.fle_user_role = null;
    }
    state.txn_manager.deinit();
    for (state.inserted_values.items) |item| {
        state.allocator.free(item.value);
    }
    state.inserted_values.deinit(state.allocator);
    state.catalog_schemas.deinit();
    state.catalog_graphs.deinit();
    var gt_iter = state.graph_types.iterator();
    while (gt_iter.next()) |entry| {
        state.allocator.free(entry.key_ptr.*);
        state.allocator.free(entry.value_ptr.name);
    }
    state.graph_types.deinit();
}

/// Entry point for additional (non-first) stream handler threads.
/// Each stream gets its own ServerState with per-stream transaction/result
/// state, but inherits the connection's authenticated identity.
// CANARY: REQ=REQ-QUIC-MUX-002; FEATURE="StreamMultiplexing"; ASPECT=StreamHandler; STATUS=IMPL; OWNER=server; UPDATED=2026-03-27
fn handleAdditionalStream(ctx_ptr: *anyopaque) void {
    const ctx: *StreamHandlerContext = @ptrCast(@alignCast(ctx_ptr));
    const gpa = ctx.allocator;
    const cs = ctx.conn_state;
    const stream = ctx.stream;
    const transport = ctx.transport;
    defer {
        stream.close();
        cs.unregisterActiveStream(stream.stream_id);
        cs.releaseActiveStream();
        // PERF-P1-004: Release the global stream thread slot so another
        // connection's stream can proceed.
        g_stream_throttle.release();
        gpa.destroy(ctx);
    }

    // Build a per-stream ServerState inheriting shared connection identity.
    var state = ServerState{ .allocator = gpa };
    state.exec_session = execution.SessionState.init(gpa);
    state.txn_manager.init(gpa);
    state.inserted_values = .empty;
    state.catalog_schemas = std.HashMap([]const u8, CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.catalog_graphs = std.HashMap([]const u8, CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.graph_types = std.HashMap([]const u8, geode.server_state.GraphTypeDefinition, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.query_mem_limit_bytes = cs.env_spill_threshold;
    state.storage_checksum_error = cs.env_storage_checksum_error;
    state.security_manager = cs.security_manager;
    state.query_optimizer = cs.shared_optimizer;
    state.query_ast_cache = cs.shared_ast_cache;
    state.graph_bound = cs.graph_bound;
    state.shared_conn = cs;

    // Inherit authenticated identity from the connection's HELLO.
    if (cs.authenticated_user) |u| {
        state.authenticated_user = gpa.dupe(u8, u) catch null;
    }
    state.authenticated_role = cs.authenticated_role;
    state.authenticated_auth_version = cs.authenticated_auth_version;
    state.authenticated_auth_validation_epoch = cs.authenticated_auth_validation_epoch;
    state.password_reset_required = cs.password_reset_required;
    if (cs.tenant_id) |tid| {
        state.session_config = geode.server_state.SessionConfiguration.init(gpa);
        state.session_config.?.tenant_id = gpa.dupe(u8, tid) catch null;
    }
    if (cs.fle_user_role) |role| {
        state.fle_user_role = gpa.dupe(u8, role) catch null;
    }

    // Bind to the same graph as the connection.
    cs.streams_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    if (cs.current_graph) |graph_name| {
        if (state.exec_session) |*sess| {
            sess.graph = gpa.dupe(u8, graph_name) catch null;
        }
    }
    cs.streams_mu.unlock(std.Io.Threaded.global_single_threaded.io());

    // Initialize evaluator callbacks (idempotent).
    execution.initEvaluator();

    // Federation planner (per-stream; lightweight init).
    var federation_manager = geode.distributed.query_planner.FederationManager.init(gpa);
    defer federation_manager.deinit();
    var dist_planner = geode.distributed.query_planner.DistributedQueryPlanner.init(gpa, &federation_manager);
    defer dist_planner.deinit();
    state.federation_manager = &federation_manager;
    state.distributed_planner = &dist_planner;

    // #683: Use cached env config from SharedConnState instead of per-stream syscalls.
    if (cs.env_config) |ec| {
        state.query_optimizer_enabled = ec.query_optimizer_enabled;
        state.inline_results_enabled = ec.inline_results_enabled;
        state.inline_results_max_rows = ec.inline_results_max_rows;
    }

    installThreadLocalSessionState(&state);
    defer clearThreadLocalSessionState();

    defer {
        deinitQuicServerState(gpa, &state, "additional stream close");
    }

    // Run the query loop for this stream.
    runStreamQueryLoop(gpa, transport, stream, &state, cs, cs.disable_estimates, cs.compact_profile, cs.memcurve_profile, cs.peer_ip);
}

/// Stream acceptor loop: runs on a dedicated thread after the first stream's
/// HELLO succeeds. Polls the connection for new peer-initiated streams and
/// spawns a handler thread for each one.
// CANARY: REQ=REQ-QUIC-MUX-003; FEATURE="StreamMultiplexing"; ASPECT=StreamAcceptor; STATUS=IMPL; OWNER=server; UPDATED=2026-03-27
fn streamAcceptorLoop(ctx: *StreamAcceptorContext) void {
    const gpa = ctx.allocator;
    const transport = ctx.transport;
    const conn = ctx.conn;
    const conn_state = ctx.conn_state;
    const stream_pool = ctx.stream_pool;
    // 2026-04-28 lifetime model: `ctx` is heap-allocated and refcounted.
    // We hold one ref for the duration of this function; on exit we
    // store `done=true` (the owner's wait condition) and release our
    // ref.  Even if the owner gives up waiting and unwinds early, the
    // refcount keeps `ctx` alive until we exit, and accessing `ctx`
    // fields (including `shutdown` / `done`) is always safe.
    defer {
        ctx.markDone();
        ctx.release();
    }
    while (!ctx.shutdown.load(.acquire)) {
        // Check if connection is still alive
        if (conn.isDrained()) break;

        // Check the total per-connection stream limit, including the first
        // stream that bootstraps the session before the acceptor starts.
        if (conn_state.active_streams.load(.acquire) >= stream_registry.max_total_streams_per_connection) {
            conn_state.waitForStreamSlot(stream_registry.max_total_streams_per_connection, 5 * std.time.ns_per_ms);
            continue;
        }

        // Non-blocking attempt to accept a new stream. Snapshot the
        // per-connection RX generation before checking the queue so a STREAM
        // frame that lands between the check and wait cannot be missed.
        const read_generation = conn.readGeneration();
        if (conn.tryAcceptStream()) |new_stream| {
            const is_new_stream = conn_state.registerActiveStream(new_stream.stream_id) catch |err| {
                log.warn("Failed to register multiplexed stream", &.{
                    Attr.int("stream_id", @intCast(new_stream.stream_id)),
                    Attr.string("error", @errorName(err)),
                });
                new_stream.close();
                conn.destroyStream(new_stream);
                continue;
            };

            // The QUIC library re-queues active stream IDs when more data arrives.
            // Accept notifications are therefore readiness signals, not proof of a
            // brand-new stream. Only spawn a handler once per active stream ID.
            if (!is_new_stream) {
                conn.destroyStream(new_stream);
                continue;
            }

            log.debug("Accepted additional multiplexed stream", &.{});

            // PERF-P1-004: Enforce the global stream thread cap before
            // spawning. Wait up to 10 ms for a slot; if still full, apply
            // backpressure by closing this stream so the peer retries.
            //
            // #864 / qa-seed deadlock §6.4: count rejections via the
            // dedicated `g_stream_admission_rejections` counter so the
            // condition is observable independently of the would-block
            // counter (which fires on quiescent streams too) and so
            // operators can correlate dashboards with client back-off.
            g_stream_throttle.acquire(10 * std.time.ns_per_ms) catch {
                _ = g_stream_admission_rejections.fetchAdd(1, .monotonic);
                log.warn("Global stream thread limit reached, rejecting stream", &.{
                    Attr.int("active_global", @intCast(g_stream_throttle.count())),
                    Attr.int("max_global", @intCast(g_stream_throttle.max)),
                });
                new_stream.close();
                conn_state.unregisterActiveStream(new_stream.stream_id);
                conn.destroyStream(new_stream);
                continue;
            };

            _ = conn_state.active_streams.fetchAdd(1, .release);

            // Allocate context for the handler thread
            const handler_ctx = gpa.create(StreamHandlerContext) catch {
                log.warn("Failed to allocate stream handler context", &.{});
                new_stream.close();
                conn_state.unregisterActiveStream(new_stream.stream_id);
                conn_state.releaseActiveStream();
                g_stream_throttle.release();
                continue;
            };
            handler_ctx.* = .{
                .allocator = gpa,
                .transport = transport,
                .stream = new_stream,
                .conn_state = conn_state,
            };

            if (!stream_pool.submit(.{
                .context = @ptrCast(handler_ctx),
                .callback = handleAdditionalStream,
            })) {
                log.warn("Failed to submit stream handler task", &.{});
                new_stream.close();
                conn_state.unregisterActiveStream(new_stream.stream_id);
                conn_state.releaseActiveStream();
                g_stream_throttle.release();
                gpa.destroy(handler_ctx);
                continue;
            }
        } else {
            // No stream pending — sleep and re-check shutdown.
            //
            // 2026-04-28: removed `transport.poll(0)` from this branch.
            // The dedicated server poll thread (`runPollLoopTask` in
            // main.zig) is the single owner of packet delivery; calling
            // poll(0) here just contends with the poll thread and with
            // every other connection's acceptor on `ep.mu`.  Under heavy
            // close-churn (e.g. 16 client connections all closing at
            // once when an msft-graph file boundary tears them down),
            // that contention blocked individual acceptors inside
            // poll(0) for >5 seconds — long enough to miss the
            // `acceptor_shutdown` signal and trip the
            // "acceptor thread did not exit within deadline; bailing
            // despite UAF risk" guard in handleQuicConnection's defer,
            // and ultimately crash the server.  Just sleeping here is
            // both correct (the poll thread keeps running) and lets the
            // loop re-check `shutdown` whenever the next poll cycle lands.
            conn.waitForReadGeneration(read_generation, quic_transport.server_handler_wait_for_poll_ns);
        }
    }
}

fn runStreamAcceptorLoop(ctx: *anyopaque) void {
    const acceptor_ctx: *StreamAcceptorContext = @ptrCast(@alignCast(ctx));
    streamAcceptorLoop(acceptor_ctx);
}

/// Run the protobuf message loop using an already-owned reader.
/// This lets the first-stream owner preserve bytes buffered while reading
/// HELLO before handing the stream off to the stream pool.
fn runStreamQueryLoopWithReader(
    gpa: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    stream: *quic_transport.QuicStream,
    line_reader: *BufferedProtoReader,
    state: *ServerState,
    conn_state: ?*SharedConnState,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    peer_ip: []const u8,
) void {
    _ = transport;
    while (true) {
        const packet_opt = line_reader.nextMessage() catch |err| {
            if (isIdleStreamReadError(err)) return;
            if (err == error.WouldBlock) {
                if (stream.poll_sync) |ps| {
                    ps.waitForPoll(quic_transport.server_handler_wait_for_poll_ns);
                } else {
                    compat_sleepNs(100 * std.time.ns_per_us);
                }
                continue;
            }
            log.err("Protobuf read error", &.{Attr.string("error", @errorName(err))});
            return;
        };

        if (packet_opt == null) return;
        var packet = packet_opt.?;
        defer packet.deinit(gpa);

        const msg = packet.quic orelse {
            log.err("Received empty ClientPacket", &.{});
            sendExecuteError(gpa, stream, "58000", "Empty packet", &.{}, &.{}) catch return;
            continue;
        };

        {
            // OTel transport request instrumentation. op_name is "QUERY" for
            // all requests at this layer; Task 10 will refine per parsed type.
            const om = @import("otel_metrics");
            const otel_lib = @import("otel");
            const op_name: []const u8 = "QUERY";
            om.incTransportInflight(op_name);
            defer om.decTransportInflight(op_name); // ALWAYS runs, including the catch-return path
            const t0_ns = otel_lib.internal.clock.unixNanoNow();

            // The `geode.transport.request` parent trace span was rolled
            // back here pending a coordinated otel pin bump to 0c34ce9b+.
            // It fired on every inbound QUIC client message, making this
            // the hottest of the rolled-back sites — every concurrent
            // connection ended one of these spans simultaneously, which
            // is exactly the BatchSpanProcessor concurrent-producer race
            // (panic at otel/src/sdk/export.zig:330 — see the May 01
            // 2026 production crash log). The recordTransportRequest
            // counter + latency histogram below continues to publish
            // non-trace monitoring data. See
            // src/storage/graph_storage_adapter.zig:2237 and
            // tests/test_bsp_race_regression.zig.

            handleClientMessage(gpa, state, stream, msg, disable_estimates, compact_profile, memcurve_profile, peer_ip) catch |err| {
                const elapsed_ns = otel_lib.internal.clock.unixNanoNow() - t0_ns;
                const dur_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
                om.recordTransportRequest(op_name, dur_s, .error_, @errorName(err));
                log.err("Protobuf process error", &.{Attr.string("error", @errorName(err))});
                sendExecuteError(gpa, stream, "58000", "Internal Server Error", &.{}, &.{}) catch {}; // best-effort; don't leak inflight, defer handles it
                continue;
            };
            const elapsed_ns = otel_lib.internal.clock.unixNanoNow() - t0_ns;
            const dur_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            om.recordTransportRequest(op_name, dur_s, .success, null);
        }

        if (conn_state) |shared| {
            shared.syncGraphFromState(state) catch |err| {
                log.warn("Failed to sync shared graph context", &.{Attr.string("error", @errorName(err))});
            };
        }

        // CANARY: REQ=REQ-QUIC-HC-026; FEATURE="QUIC High-Concurrency Requests"; ASPECT=PersistentStreamFairness; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-26
        // CANARY: REQ=REQ-QUIC-HC-027; FEATURE="QUIC High-Concurrency Requests"; ASPECT=PersistentFollowupBackoff; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-26
        //
        // Under 700+ persistent first streams, clients that receive an early
        // response can immediately re-enter this loop with their next request
        // while tail clients are still waiting for their first response. Yield
        // at normal fanout, and add a small bounded sleep only when stream
        // owner pressure is high enough that pure yielding still lets the same
        // hot subset of owners dominate the run queue.
        const active_stream_handlers = g_stream_throttle.count();
        if (active_stream_handlers > 512) {
            const excess: u64 = @intCast(active_stream_handlers - 512);
            const delay_ns = @min(excess * 10 * std.time.ns_per_us, 3 * std.time.ns_per_ms);
            compat_sleepNs(delay_ns);
        } else {
            std.Thread.yield() catch {};
        }
    }
}

/// Run the protobuf message loop for a single QUIC stream.
/// Additional multiplexed streams start with an empty reader. The first stream
/// uses `runStreamQueryLoopWithReader` directly so buffered post-HELLO bytes
/// are not discarded during worker handoff.
fn runStreamQueryLoop(
    gpa: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    stream: *quic_transport.QuicStream,
    state: *ServerState,
    conn_state: ?*SharedConnState,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    peer_ip: []const u8,
) void {
    var line_reader = BufferedProtoReader.init(gpa, transport, stream) catch return;
    line_reader.peer_addr = peer_ip;
    // #864 §10 per-stream stall observability: hand the reader to the
    // process-wide registry so the watchdog can detect this specific
    // stream stalling while others keep delivering messages.  Register
    // failure (OOM) is non-fatal — we simply lose the per-stream
    // signal for this stream; the global proto_reader_idle_ns gauge
    // still covers the all-streams-stuck case.
    g_proto_reader_registry.register(gpa, line_reader.registryHandle()) catch |reg_err| {
        log.warn("proto_reader registry append failed; per-stream stall signal disabled for this stream", &.{
            Attr.string("error", @errorName(reg_err)),
        });
    };
    defer {
        g_proto_reader_registry.unregister(@ptrCast(&line_reader));
        line_reader.deinit();
    }

    runStreamQueryLoopWithReader(
        gpa,
        transport,
        stream,
        &line_reader,
        state,
        conn_state,
        disable_estimates,
        compact_profile,
        memcurve_profile,
        peer_ip,
    );
}

/// Signal the stream acceptor to exit and wait (bounded) for it to do so.
///
/// Returns `true` if it BAILED — i.e. the acceptor did not exit within the
/// deadline and is therefore still dereferencing `first_ctx.conn_state` and
/// `first_ctx.conn` from inside `streamAcceptorLoop`. On bail the caller MUST
/// NOT free `first_ctx`: ownership of the conn_state + FirstStreamOwnerContext
/// + conn teardown is transferred to the leaked-conn reaper, which runs
/// `deferredDestroyFirstStreamOwner` only after the acceptor has exited
/// (`acceptor_ctx.done`). If no reaper is available (or registration fails) the
/// resources are intentionally LEAKED and reclaimed at the QUIC idle timeout —
/// a leak is strictly safer than the use-after-free.
///
/// 2026-06-02 fix: the previous code set `destroy_conn=false` (sparing only the
/// conn wrapper) and then let the owner UNCONDITIONALLY free `first_ctx` (and
/// its embedded `conn_state`). The still-running acceptor's stale atomic/mutex
/// writes through the freed `conn_state` corrupted whatever the allocator
/// recycled the block into, surfacing later as the protobuf `@memcpy`-alias
/// panic or the poll-thread `recovery.onPacketSent` SIGSEGV on an unrelated
/// connection. See docs/bugs/2026-06-02-sendexecuteerror-memcpy-alias-and-quic-initial-crash.md.
/// Default grace period (ms) the first-stream owner waits for a shutdown-signalled
/// acceptor to exit before deferring teardown to the leaked-conn reaper.
///
/// A healthy acceptor checks `ctx.shutdown` at the top of every loop iteration
/// and its idle sleep is bounded by `server_handler_wait_for_poll_ns` (100 ms),
/// so it exits well within this window. A WEDGED acceptor (blocked inside the
/// QUIC library on endpoint-lock contention under a connection-burst) never
/// exits; capping the wait here — rather than at the old 30 s — frees the
/// owner's capped concurrency slot (stream-pool worker / first-stream detach
/// gate) ~30x faster, so a burst of closing+wedged connections can no longer
/// starve NEW-connection admission. The reaper reclaims the wedged conn once its
/// acceptor finally exits (or at the QUIC idle timeout).
/// See docs/bugs/2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md.
const default_acceptor_bail_deadline_ms: i64 = 1_000;
/// After this much elapsed time (ms) the owner logs that the acceptor is still
/// running, at most once per second, while it waits out the bail deadline.
const default_acceptor_bail_warn_ms: i64 = 500;

/// Parse the `GEODE_ACCEPTOR_BAIL_MS` override value. Pure (no env access) so it
/// is unit-testable. Falls back to the default on null / unparseable input and
/// clamps to a sane [50 ms, 60 s] range so a typo cannot reintroduce a
/// many-second owner-thread stall (or a 0 ms busy-bail).
fn parseAcceptorBailMs(env_val: ?[]const u8) i64 {
    const raw = env_val orelse return default_acceptor_bail_deadline_ms;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const parsed = std.fmt.parseInt(i64, trimmed, 10) catch return default_acceptor_bail_deadline_ms;
    return std.math.clamp(parsed, 50, 60_000);
}

/// Resolve the acceptor bail deadline from the environment (operator override
/// via `GEODE_ACCEPTOR_BAIL_MS`), defaulting to `default_acceptor_bail_deadline_ms`.
fn acceptorBailDeadlineMs() i64 {
    return parseAcceptorBailMs(posixGetenv("GEODE_ACCEPTOR_BAIL_MS"));
}

/// Wait for a shutdown-signalled acceptor to set `done`, up to `deadline_ms`.
/// Returns `true` if the deadline elapsed first (the acceptor is still wedged and
/// the caller MUST defer teardown to the reaper to avoid a UAF), `false` if the
/// acceptor exited cleanly in time (the caller may tear down inline).
///
/// Touches only `acceptor_ctx`'s done flag / futex, so it is unit-testable
/// without a live connection. Parks in ≤100 ms slices on the done futex so a
/// prompt acceptor exit returns immediately rather than after a fixed sleep.
fn waitForAcceptorExit(acceptor_ctx: *StreamAcceptorContext, deadline_ms: i64, warn_ms: i64) bool {
    const wait_start = compat_milliTimestamp();
    var last_warn_ms: i64 = wait_start;
    while (!acceptor_ctx.done.load(.acquire)) {
        _ = acceptor_ctx.waitUntilDone(100 * std.time.ns_per_ms);
        const now = compat_milliTimestamp();
        const elapsed = now - wait_start;
        if (elapsed >= deadline_ms) return true;
        if (elapsed > warn_ms and now - last_warn_ms > 1_000) {
            log.warn("acceptor still running after shutdown signal", &.{
                Attr.int("elapsed_ms", @intCast(elapsed)),
            });
            last_warn_ms = now;
        }
    }
    return false;
}

fn shutdownAcceptorOwner(
    gpa: std.mem.Allocator,
    first_ctx: *FirstStreamOwnerContext,
    acceptor_ctx: *StreamAcceptorContext,
    acceptor_submitted: bool,
) bool {
    var bailed = false;
    if (acceptor_submitted) {
        acceptor_ctx.shutdown.store(true, .release);
        const deadline_ms = acceptorBailDeadlineMs();
        if (waitForAcceptorExit(acceptor_ctx, deadline_ms, default_acceptor_bail_warn_ms)) {
            bailed = true;
            var registered = false;
            if (g_leaked_conn_registry) |reg| {
                acceptor_ctx.addRef();
                if (reg.register(gpa, first_ctx.transport, first_ctx.conn, .{
                    .self = @ptrCast(acceptor_ctx),
                    .is_done = acceptorCtxIsDone,
                    .release = acceptorCtxRelease,
                }, .{
                    .self = @ptrCast(first_ctx),
                    .run = deferredDestroyFirstStreamOwner,
                })) |_| {
                    registered = true;
                } else |reg_err| {
                    acceptor_ctx.release();
                    log.warn("failed to register leaked conn for deferred reaping", &.{
                        Attr.string("error", @errorName(reg_err)),
                    });
                }
            }
            if (registered) {
                log.err("acceptor did not exit within bail deadline; deferring conn+conn_state teardown to reaper to avoid UAF (connection-burst wedge; reaper reclaims once acceptor exits)", &.{
                    Attr.int("deadline_ms", @intCast(deadline_ms)),
                });
            } else {
                log.err("acceptor did not exit within bail deadline; leaking conn+ctx to avoid UAF (no reaper; reclaimed at QUIC idle timeout)", &.{
                    Attr.int("deadline_ms", @intCast(deadline_ms)),
                });
            }
        }
    }
    acceptor_ctx.release();
    return bailed;
}

/// Minimal one-shot signal used only by the lifetime test seams. Zig 0.16
/// retired `std.Thread.ResetEvent`, so we use the established codebase idiom
/// (atomic u32 + short-yield busy-wait; see
/// tests/bulk_ingest/test_two_phase_edge_lock.zig). Behavior-neutral in
/// production — only constructed/referenced by tests.
pub const FirstStreamTestGate = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn set(self: *FirstStreamTestGate) void {
        self.state.store(1, .release);
    }

    pub fn wait(self: *FirstStreamTestGate) void {
        while (self.state.load(.acquire) == 0) {
            std.Thread.yield() catch {};
        }
    }

    pub fn isSet(self: *const FirstStreamTestGate) bool {
        return self.state.load(.acquire) != 0;
    }
};

const FirstStreamOwnerContext = struct {
    allocator: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    conn: *quic_transport.QuicConnection,
    stream: *quic_transport.QuicStream,
    state: ServerState,
    conn_state: SharedConnState,
    reader: BufferedProtoReader,
    federation_manager: geode.distributed.query_planner.FederationManager,
    dist_planner: geode.distributed.query_planner.DistributedQueryPlanner,
    acceptor_ctx: ?*StreamAcceptorContext = null,
    acceptor_submitted: bool = false,
    quota_tenant_id: ?[]const u8 = null,
    peer_ip: []const u8 = "unknown",
    peer_ip_allocated: bool = false,
    stream_throttle_acquired: bool = false,
    detached_first_stream_acquired: bool = false,
    reader_registered: bool = false,
    cooperative_scheduler: ?*FirstStreamScheduler = null,
    cooperative_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cooperative_queued: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cooperative_needs_reschedule: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cooperative_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cooperative_force_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    cooperative_generation_seen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    cooperative_enqueued_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cooperative_mutation_waiting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cooperative_mutation_wait_class: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(CooperativeMutationAdmissionClass.none)),
    pending_packet: ?schema.ClientPacket = null,
    post_hello_packets: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // ── LIFETIME REFCOUNT (REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME, 2026-06-10) ──
    //
    // Lifetime refcount mirroring the `StreamAcceptorContext` model (:1887).
    // The struct starts with a single lifecycle ref. The DIAGNOSED use-after-free
    // was that `finishCooperativeContext` freed this context via the detached
    // `cleanupFirstStreamOwnerAsync` path WITHOUT any synchronization against
    // (a) the detached-owner read loop touching `&ctx.reader`, or
    // (b) the poll-thread RX-ready notifier `firstStreamReadyCallback` which
    // reads `ctx.cooperative_*` after a TOCTOU on `cooperative_done`.
    //
    // FIX: every thread that can touch the ctx holds a ref while it does so.
    //   * The terminal teardown holds the initial lifecycle ref (=1).
    //   * `submit` takes a second ref for the poll-thread notifier when it
    //     installs the RX-ready callback (the cooperative path), released by
    //     `cleanupFirstStreamOwner` only AFTER the lib notifier is cleared and
    //     all in-flight callbacks have drained (`notifier_inflight == 0`).
    // `destroyFirstStreamOwnerResources` runs the heavy teardown then frees the
    // allocation behind `releaseOwnerRef` — the releaser that brings the count
    // to zero performs `gpa.destroy(ctx)`. See the notifier-gate fields below.
    owner_refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    // ── NOTIFIER QUIESCE GATE ────────────────────────────────────────────────
    //
    // The vendored QUIC lib fires `firstStreamReadyCallback` from the poll
    // thread inside `pushStreamFrame`'s defer, AFTER releasing `Connection.mu`
    // and with NO lock geode can take to mutually exclude an in-flight callback
    // (quic-0.1.21 conn.zig:1918-1922 / methods_a.zig:801-817). It also offers no
    // quiesce primitive: `clearReadReadyNotifier` only nulls the fn pointer, so a
    // poll thread that already captured a non-null fn can still invoke us once.
    //
    // `notifier_inflight` brackets every callback body (inc at entry / dec at
    // exit). `cleanupFirstStreamOwner` sets `cooperative_done`, clears the lib
    // notifier, then spins until `notifier_inflight == 0` so no ENTERED callback
    // is mid-deref before it drops the notifier ref. The notifier ref itself
    // keeps the allocation alive across that whole quiesce window.
    //
    // KNOWN RESIDUAL (capture window): the vendored lib's `notifyRxReady`
    // (quic-0.1.21 conn.zig:1967-1971) loads the fn pointer and ctx pointer
    // NON-ATOMICALLY, after `Connection.mu` is released, and `destroyConnection`
    // does NOT quiesce the poll thread — the inner conn goes to pending_destroy
    // precisely because poll may still touch it (GAP-0203 comment,
    // src/transport/quic.zig:1005-1009). So a poll thread that has captured
    // fn+ctx but not yet invoked the callback survives BOTH
    // `clearReadReadyNotifier` AND `waitNotifierDrained` (it hasn't entered the
    // gate, so the counter is still 0) and can enter `firstStreamReadyCallback`
    // on a ctx the teardown has since freed. The exposure is ~3 instructions
    // (capture → invoke) racing a µs-ms teardown — versus the previous
    // whole-read-loop window, so the observed 9x/hour crash is closed; what
    // remains is a rare structural residual, not a fixed bug. Real fixes, in
    // preference order: (a) lib-level lock/quiesce around the capture+invoke in
    // `notifyRxReady`, (b) defer the ctx free into the same pending_destroy
    // drain epoch as the inner conn, (c) a type-stable freelist for
    // `FirstStreamOwnerContext` so a stale entry derefs poisoned-but-mapped
    // memory of the right type.
    notifier_inflight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// True once `submit` installed the lib notifier and took the notifier ref.
    /// Guards `cleanupFirstStreamOwner` so it releases that ref exactly once
    /// (and only when it was actually taken — non-cooperative paths never arm).
    notifier_armed: bool = false,

    /// Test-only barrier checked by `cleanupFirstStreamOwnerAsync` immediately
    /// before it runs the free path. When set, the detached cleanup blocks here
    /// until the test signals, making the free-vs-read window deterministic
    /// (it is otherwise a tight timing race). Never set in production
    /// (`g_first_stream_cleanup_test_barrier` defaults to null), so this is a
    /// no-op on the hot path.
    test_cleanup_reached: ?*FirstStreamTestGate = null,

    /// Bump the lifetime refcount. Paired with a later `releaseOwnerRef`.
    /// Safe from any thread holding a live ref (the notifier / read loop).
    pub fn retainOwnerRef(self: *FirstStreamOwnerContext) void {
        const prev = self.owner_refs.fetchAdd(1, .acq_rel);
        std.debug.assert(prev > 0);
    }

    /// Drop one lifetime ref. Returns true when this was the LAST ref, i.e.
    /// the caller is now responsible for freeing the allocation. The fix
    /// gates `gpa.destroy(ctx)` behind a true return from here.
    pub fn releaseOwnerRef(self: *FirstStreamOwnerContext) bool {
        const prev = self.owner_refs.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
        return prev == 1;
    }

    /// Mark a notifier callback as in-flight. Called as the FIRST action of
    /// `firstStreamReadyCallback`, before any other field access, so the
    /// quiesce spin in `cleanupFirstStreamOwner` can observe the callback.
    pub fn enterNotifier(self: *FirstStreamOwnerContext) void {
        _ = self.notifier_inflight.fetchAdd(1, .acq_rel);
    }

    /// Mark a notifier callback as finished. Paired with `enterNotifier`.
    pub fn exitNotifier(self: *FirstStreamOwnerContext) void {
        const prev = self.notifier_inflight.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
    }

    /// Bounded spin until no notifier callback is mid-flight. Called by the
    /// teardown AFTER the lib notifier has been cleared, so no NEW callback can
    /// be dispatched once this returns 0. Yields rather than busy-spins.
    pub fn waitNotifierDrained(self: *FirstStreamOwnerContext) void {
        while (self.notifier_inflight.load(.acquire) != 0) {
            std.Thread.yield() catch {};
        }
    }
};

/// Test-only barrier hook. When non-null, `cleanupFirstStreamOwnerAsync`
/// records that it reached the free point (so the test knows the detached
/// cleanup is committed to freeing) and waits on the per-context barrier.
/// Always null in production (set/cleared only by lifetime tests under a
/// process-global lock); behavior-neutral on the hot path.
var g_first_stream_cleanup_test_barrier: bool = false;

fn registerFirstStreamReader(ctx: *FirstStreamOwnerContext) void {
    if (ctx.reader_registered) return;
    const gpa = ctx.allocator;
    g_proto_reader_registry.register(gpa, ctx.reader.registryHandle()) catch |reg_err| {
        log.warn("proto_reader registry append failed; per-stream stall signal disabled for first stream", &.{
            Attr.string("error", @errorName(reg_err)),
        });
        return;
    };
    ctx.reader_registered = true;
}

fn cleanupFirstStreamOwner(ctx: *FirstStreamOwnerContext) void {
    const gpa = ctx.allocator;

    if (posixGetenv("GEODE_QUIC_FIRST_STREAM_DIAGNOSTICS")) |enabled| {
        if (enabled.len == 0 or enabled[0] != '0') {
            const post_hello = ctx.post_hello_packets.load(.acquire);
            if (post_hello == 0) {
                std.debug.print(
                    "first-stream diag cleanup peer={s} stream={d} post_hello={d} read_gen={d} seen_gen={d} rx_available={d} rx_recv_off={d} done={} running={} queued={} reschedule={} force={}\n",
                    .{
                        ctx.peer_ip,
                        ctx.stream.stream_id,
                        post_hello,
                        ctx.stream.readGeneration(),
                        ctx.cooperative_generation_seen.load(.acquire),
                        ctx.stream.debugRxAvailable(),
                        ctx.stream.debugRxRecvOffset(),
                        ctx.cooperative_done.load(.acquire),
                        ctx.cooperative_running.load(.acquire),
                        ctx.cooperative_queued.load(.acquire),
                        ctx.cooperative_needs_reschedule.load(.acquire),
                        ctx.cooperative_force_ready.load(.acquire),
                    },
                );
            }
        }
    }

    if (ctx.reader_registered) {
        g_proto_reader_registry.unregister(@ptrCast(&ctx.reader));
        ctx.reader_registered = false;
    }

    if (ctx.pending_packet) |*packet| {
        packet.deinit(gpa);
        ctx.pending_packet = null;
    }
    ctx.reader.deinit();

    if (ctx.detached_first_stream_acquired) {
        g_first_stream_detach_gate.release();
        ctx.detached_first_stream_acquired = false;
    }
    if (ctx.cooperative_scheduler) |scheduler| {
        // Quiesce the poll-thread RX-ready notifier before releasing its ref
        // (REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME). Order matters:
        //   1. publish `cooperative_done` (TOCTOU flag a live callback reads),
        //   2. clear the lib notifier so NO NEW callback is dispatched,
        //   3. drain any callback already in-flight (`notifier_inflight -> 0`),
        //   4. re-purge the scheduler's ready_queue (stale re-enqueue, below),
        //   5. drop the notifier ref taken in `submit`.
        // The notifier ref (still held through 1-4) keeps the allocation alive
        // for the whole window, so an in-flight callback never derefs freed
        // memory. After step 5 only the lifecycle ref remains (held by THIS
        // thread, which proceeds to the gated teardown), so no other thread can
        // free the ctx concurrently.
        //
        // NOTE: `ctx.cooperative_scheduler` is deliberately NOT nulled here.
        // The poll-thread callback reads the field concurrently (:3620); a
        // plain non-atomic write from this thread racing that read is formal
        // UB even if the value is never "used". The done flag + notifier clear
        // + drain already gate every post-teardown use, and the scheduler is
        // server-global (set once at startup, outlives every ctx — the test
        // harness likewise destroys ctx before scheduler), so a stale read of
        // the pointer is always a read of a live scheduler.
        ctx.cooperative_done.store(true, .release);
        ctx.stream.clearReadReadyNotifier();
        ctx.waitNotifierDrained();
        // Stale re-enqueue purge: a notifier callback that already passed the
        // `cooperative_done == false` check (:3536) in a stale-read window
        // after `finishCooperativeContext`'s `removeContext` purge can have
        // re-enqueued this ctx into the ready_queue before exiting the gate.
        // The drain above only guarantees the callback has EXITED — not that
        // its enqueue was undone. Re-running the (idempotent) purge after the
        // drain, while the notifier ref still pins the allocation, guarantees
        // no dangling ctx pointer remains in the queue for a worker to pop
        // once the gated teardown frees it.
        scheduler.removeContext(ctx);
        if (ctx.notifier_armed) {
            ctx.notifier_armed = false;
            // Not the last ref: the lifecycle ref is still held here. Asserted
            // by the contract that `submit` took exactly one extra ref.
            const was_last = ctx.releaseOwnerRef();
            std.debug.assert(!was_last);
        }
    }
    if (ctx.stream_throttle_acquired) {
        g_stream_throttle.release();
        ctx.stream_throttle_acquired = false;
    }

    ctx.stream.close();

    if (ctx.acceptor_ctx) |acceptor_ctx| {
        const bailed = shutdownAcceptorOwner(gpa, ctx, acceptor_ctx, ctx.acceptor_submitted);
        ctx.acceptor_ctx = null;
        ctx.acceptor_submitted = false;
        if (bailed) {
            // The acceptor thread did not exit within the deadline and is
            // still dereferencing `&ctx.conn_state` and `ctx.conn` every loop
            // iteration. Ownership of the conn_state + this
            // FirstStreamOwnerContext + the conn has been transferred to the
            // reaper (or intentionally leaked when no reaper is available).
            // Freeing any of it here is the 2026-06-02 use-after-free.
            return;
        }
    }

    destroyFirstStreamOwnerResources(ctx);
}

/// Tear down a first-stream owner's per-connection resources and free the
/// context, then destroy the underlying connection. Runs on the owner thread
/// for a normal close, or — via `deferredDestroyFirstStreamOwner` — on the
/// reaper thread for the acceptor-bail path, but ONLY after the acceptor has
/// exited (`acceptor_ctx.done`), so nothing else still references
/// `ctx.conn_state` / `ctx.conn`. `waitForAllStreamsDrained` then blocks until
/// every additional-stream handler the acceptor spawned has also released
/// `conn_state`, making the subsequent `deinit`/free safe.
fn destroyFirstStreamOwnerResources(ctx: *FirstStreamOwnerContext) void {
    const gpa = ctx.allocator;
    ctx.conn_state.unregisterActiveStream(ctx.stream.stream_id);
    ctx.conn_state.releaseActiveStream();
    ctx.conn_state.waitForAllStreamsDrained();
    ctx.conn_state.deinit();

    ctx.dist_planner.deinit();
    ctx.federation_manager.deinit();
    releaseQuotaTenant(gpa, &ctx.quota_tenant_id);
    deinitQuicServerState(gpa, &ctx.state, "first stream close");
    ctx.transport.destroyConnection(ctx.conn);
    if (ctx.peer_ip_allocated) gpa.free(ctx.peer_ip);

    // REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME: free behind the lifetime refcount.
    // By the time this runs, `cleanupFirstStreamOwner` has already cleared +
    // drained the notifier and released the notifier ref, so the only ref left
    // is the lifecycle ref owned by THIS thread — `releaseOwnerRef` returns true
    // and this is the single, exactly-once free. The refcount gate is the
    // defensive invariant (mirrors `StreamAcceptorContext.release`): if any path
    // ever held an outstanding ref, the last releaser — not necessarily this
    // thread — performs the destroy.
    if (ctx.releaseOwnerRef()) {
        gpa.destroy(ctx);
    }
}

/// Reaper callback: runs `destroyFirstStreamOwnerResources` once the acceptor
/// has exited. Registered by `shutdownAcceptorOwner` on the bail path.
fn deferredDestroyFirstStreamOwner(p: *anyopaque) void {
    const ctx: *FirstStreamOwnerContext = @ptrCast(@alignCast(p));
    destroyFirstStreamOwnerResources(ctx);
}

fn cleanupFirstStreamOwnerAsync(ctx: *FirstStreamOwnerContext) void {
    // TEST SEAM (REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME): when a lifetime test
    // installs a barrier, block here — committed to freeing — until the test
    // releases us. This pins the otherwise-tight free-vs-read window open so
    // the reproduction is deterministic. Null/false in production.
    if (g_first_stream_cleanup_test_barrier) {
        if (ctx.test_cleanup_reached) |ev| ev.wait();
    }
    cleanupFirstStreamOwner(ctx);
}

fn processFirstStreamPacket(
    gpa: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    stream: *quic_transport.QuicStream,
    line_reader: *BufferedProtoReader,
    state: *ServerState,
    conn_state: ?*SharedConnState,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    peer_ip: []const u8,
    packet: *schema.ClientPacket,
) bool {
    _ = transport;
    const msg = packet.quic orelse {
        log.err("Received empty ClientPacket", &.{});
        sendExecuteError(gpa, stream, "58000", "Empty packet", &.{}, &.{}) catch return false;
        return true;
    };

    {
        const om = @import("otel_metrics");
        const otel_lib = @import("otel");
        const op_name: []const u8 = "QUERY";
        om.incTransportInflight(op_name);
        defer om.decTransportInflight(op_name);
        const t0_ns = otel_lib.internal.clock.unixNanoNow();

        handleClientMessage(gpa, state, stream, msg, disable_estimates, compact_profile, memcurve_profile, peer_ip) catch |err| {
            const elapsed_ns = otel_lib.internal.clock.unixNanoNow() - t0_ns;
            const dur_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            om.recordTransportRequest(op_name, dur_s, .error_, @errorName(err));
            log.err("Protobuf process error", &.{Attr.string("error", @errorName(err))});
            sendExecuteError(gpa, stream, "58000", "Internal Server Error", &.{}, &.{}) catch {};
            return true;
        };
        const elapsed_ns = otel_lib.internal.clock.unixNanoNow() - t0_ns;
        const dur_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        om.recordTransportRequest(op_name, dur_s, .success, null);
    }

    if (conn_state) |shared| {
        shared.syncGraphFromState(state) catch |err| {
            log.warn("Failed to sync shared graph context", &.{Attr.string("error", @errorName(err))});
        };
    }

    _ = line_reader;
    return true;
}

// CANARY: REQ=REQ-QUIC-HC-054; FEATURE="QUIC High-Concurrency Requests"; ASPECT=CooperativeFirstStreams; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
pub const FirstStreamScheduler = struct {
    allocator: std.mem.Allocator = undefined,
    contexts: std.ArrayList(*FirstStreamOwnerContext) = .empty,
    ready_queue: std.ArrayList(*FirstStreamOwnerContext) = .empty,
    ready_head: usize = 0,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    ready_cv: std.Io.Condition = std.Io.Condition.init,
    ready_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ready_depth: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    context_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    mutation_inflight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    shard_parallel_mutation_inflight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    mutation_retry_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    mutation_offload_inflight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    mutation_offload_pool: ?*pooled.ThreadPool = null,
    mutation_limit: u32 = 1,
    shard_parallel_mutation_limit: u32 = 1,
    workers: []std.Thread = &.{},
    next_index: usize = 0,
    last_idle_sweep_ns: u64 = 0,

    pub fn init(
        self: *FirstStreamScheduler,
        allocator: std.mem.Allocator,
        worker_count: usize,
        mutation_limit_cap: usize,
    ) !void {
        const effective_mutation_cap = @max(
            @as(usize, 1),
            @min(mutation_limit_cap, max_first_stream_scheduler_mutation_limit_cap),
        );
        const offload_workers = @min(effective_mutation_cap, first_stream_mutation_offload_worker_cap);
        const offload_pool = try pooled.ThreadPool.init(allocator, .{
            .num_threads = @max(offload_workers, 1),
            .queue_capacity = @max(effective_mutation_cap * 8, 64),
            .blocking_workers = 0,
            .deinit_timeout_ns = first_stream_mutation_offload_shutdown_wait_ns,
        });
        var offload_pool_owned = true;
        errdefer if (offload_pool_owned) offload_pool.deinit();

        const worker_threads = try allocator.alloc(std.Thread, @max(worker_count, 1));
        errdefer allocator.free(worker_threads);

        self.* = .{
            .allocator = allocator,
            .contexts = .empty,
            .ready_queue = .empty,
            .ready_head = 0,
            .mutex = std.Io.Mutex.init,
            .ready_cv = std.Io.Condition.init,
            .ready_generation = std.atomic.Value(u32).init(0),
            .ready_depth = std.atomic.Value(u32).init(0),
            .shutdown = std.atomic.Value(bool).init(false),
            .context_count = std.atomic.Value(u32).init(0),
            .mutation_inflight = std.atomic.Value(u32).init(0),
            .shard_parallel_mutation_inflight = std.atomic.Value(u32).init(0),
            .mutation_retry_waiters = std.atomic.Value(u32).init(0),
            .mutation_offload_inflight = std.atomic.Value(u32).init(0),
            .mutation_offload_pool = offload_pool,
            .mutation_limit = @intCast(@max(@as(usize, 1), @min(@max(worker_count, 1) / 4, serial_first_stream_scheduler_mutation_limit_cap))),
            .shard_parallel_mutation_limit = @intCast(@max(@as(usize, 1), @min(@max(worker_count, 1), effective_mutation_cap))),
            .workers = worker_threads,
            .next_index = 0,
            .last_idle_sweep_ns = 0,
        };
        offload_pool_owned = false;

        for (self.workers, 0..) |*worker, i| {
            errdefer {
                self.shutdown.store(true, .release);
                var j: usize = 0;
                while (j < i) : (j += 1) self.workers[j].join();
                if (self.mutation_offload_pool) |pool| {
                    pool.deinit();
                    self.mutation_offload_pool = null;
                }
            }
            // CANARY: REQ=REQ-QUIC-HC-139; FEATURE="QUIC High-Concurrency Requests"; ASPECT=CooperativeWorkerStackCap; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-28
            //
            // High-fanout runs can intentionally raise the scheduler pool into
            // the thousands, so keep stack reservation explicit instead of
            // inheriting platform defaults.
            worker.* = try std.Thread.spawn(.{ .stack_size = first_stream_owner_stack_size }, workerMain, .{self});
        }
    }

    pub fn deinit(self: *FirstStreamScheduler) void {
        self.shutdown.store(true, .release);
        {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.mutex.lockUncancelable(io);
            _ = self.ready_generation.fetchAdd(1, .release);
            self.ready_cv.broadcast(io);
            io.futexWake(u32, &self.ready_generation.raw, std.math.maxInt(u32));
            self.mutex.unlock(io);
        }
        for (self.workers) |*worker| worker.join();

        // CANARY: REQ=REQ-QUIC-HC-178; FEATURE="HighConcurrencyMutations"; ASPECT=CooperativeMutationOffload; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
        //
        // Shard-parallel mutations can wait on group commit for milliseconds
        // to seconds under 4k+ fanout. The cooperative scheduler worker that
        // admitted the packet must not remain tied to that wait. Offloaded
        // packets keep their owner marked running, and shutdown waits for those
        // packet tasks before reclaiming contexts.
        const offload_wait_start = monoNsFromHandler();
        while (self.mutation_offload_inflight.load(.acquire) != 0 and
            monoNsFromHandler() -| offload_wait_start < first_stream_mutation_offload_shutdown_wait_ns)
        {
            compat_sleepNs(std.time.ns_per_ms);
        }
        if (self.mutation_offload_inflight.load(.acquire) != 0) {
            log.warn("cooperative mutation offload tasks still active at scheduler shutdown", &.{
                Attr.int("inflight", @intCast(self.mutation_offload_inflight.load(.acquire))),
            });
        }
        if (self.mutation_offload_pool) |pool| {
            pool.deinit();
            self.mutation_offload_pool = null;
        }

        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        var remaining = self.contexts;
        self.contexts = .empty;
        var ready = self.ready_queue;
        self.ready_queue = .empty;
        self.ready_head = 0;
        self.ready_depth.store(0, .release);
        self.mutex.unlock(io);

        ready.deinit(self.allocator);
        for (remaining.items) |ctx| {
            ctx.cooperative_done.store(true, .release);
            ctx.stream.clearReadReadyNotifier();
            cleanupFirstStreamOwner(ctx);
        }
        remaining.deinit(self.allocator);
        self.allocator.free(self.workers);
        self.workers = &.{};
    }

    /// Publish a first-stream owner to the cooperative scheduler.
    ///
    /// CONTRACT (REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME, 2026-06-10): on success
    /// the scheduler OWNS the ctx — the caller MUST NOT dereference `ctx` again,
    /// because a worker can finish and free it the instant `enqueueReady`
    /// publishes it (and the poll-thread notifier becomes live the instant
    /// `setReadReadyNotifier` is installed). The previous caller deref of
    /// `first_ctx.cooperative_scheduler` after `submit` returned was a
    /// use-after-free. Callers now branch on the returned bool instead.
    ///
    /// Returns `true` if the owner was scheduled (scheduler owns it); `false`
    /// only on a registration/enqueue failure, in which case the ctx is NOT
    /// owned by the scheduler, the notifier ref has been released, and the
    /// caller must run the fallback path with the still-valid ctx.
    pub fn submit(self: *FirstStreamScheduler, ctx: *FirstStreamOwnerContext) bool {
        registerFirstStreamReader(ctx);
        ctx.cooperative_scheduler = self;
        ctx.cooperative_done.store(false, .release);
        ctx.cooperative_running.store(false, .release);
        ctx.cooperative_queued.store(false, .release);
        ctx.cooperative_needs_reschedule.store(false, .release);
        ctx.cooperative_force_ready.store(false, .release);
        ctx.cooperative_generation_seen.store(ctx.stream.readGeneration(), .release);
        ctx.cooperative_mutation_waiting.store(false, .release);
        ctx.cooperative_mutation_wait_class.store(@intFromEnum(CooperativeMutationAdmissionClass.none), .release);
        ctx.pending_packet = null;

        // Take the notifier ref BEFORE installing the lib callback so the
        // allocation is kept alive for the entire window the poll thread can
        // fire `firstStreamReadyCallback`. Released by `cleanupFirstStreamOwner`
        // after the notifier is cleared + drained. owner_refs: 1 -> 2.
        ctx.retainOwnerRef();
        ctx.notifier_armed = true;

        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        self.contexts.append(self.allocator, ctx) catch {
            self.mutex.unlock(io);
            // Roll back: not scheduled. Drop the notifier ref we just took and
            // disarm so the caller's fallback teardown does not double-release.
            ctx.notifier_armed = false;
            ctx.cooperative_scheduler = null;
            _ = ctx.releaseOwnerRef(); // 2 -> 1; caller still holds lifecycle ref
            return false;
        };
        _ = self.context_count.fetchAdd(1, .acq_rel);
        self.mutex.unlock(io);

        ctx.stream.setReadReadyNotifier(@ptrCast(ctx), firstStreamReadyCallback);
        // Prime the owner once so data that arrived between HELLO completion
        // and callback installation is observed without waiting for another
        // STREAM frame. enqueueReady never fails fatally for the lifetime of a
        // live scheduler (append OOM only), and even on its internal error path
        // the ctx is already owned + the notifier installed, so we keep
        // ownership and let the notifier/idle-sweep re-arm it. DO NOT touch
        // `ctx` after this point — a worker may already be freeing it.
        self.enqueueReady(ctx) catch |err| {
            log.warn("Failed to prime cooperative first-stream owner; relying on notifier", &.{
                Attr.string("error", @errorName(err)),
            });
        };
        return true;
    }

    fn workerMain(self: *FirstStreamScheduler) void {
        self.workerLoop();
    }

    fn finishCooperativeContext(self: *FirstStreamScheduler, ctx: *FirstStreamOwnerContext) void {
        ctx.cooperative_done.store(true, .release);
        self.removeContext(ctx);
        // CANARY: REQ=REQ-QUIC-HC-073; FEATURE="QUIC High-Concurrency Requests"; ASPECT=SchedulerNonBlockingCleanup; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
        //
        // Connection cleanup can wait for QUIC teardown and stream
        // drain. Running it on the cooperative scheduler worker
        // starves the ready queue after the first worker-count
        // streams finish, so detach cleanup and keep the scheduler
        // focused on request processing.
        const cleanup_thread = std.Thread.spawn(
            .{ .stack_size = first_stream_owner_stack_size },
            cleanupFirstStreamOwnerAsync,
            .{ctx},
        ) catch |err| {
            log.warn("Failed to detach first-stream cleanup, running inline", &.{
                Attr.string("error", @errorName(err)),
            });
            cleanupFirstStreamOwner(ctx);
            return;
        };
        cleanup_thread.detach();
    }

    fn completeCooperativeTurn(self: *FirstStreamScheduler, ctx: *FirstStreamOwnerContext) void {
        // Clear `running` before consuming reschedule flags. If a STREAM frame
        // arrives after the non-blocking read returned WouldBlock, the
        // RX-ready callback must either enqueue the owner directly or leave a
        // flag this worker observes here.
        ctx.cooperative_running.store(false, .release);
        const force = ctx.cooperative_force_ready.load(.acquire);
        const reschedule = ctx.cooperative_needs_reschedule.swap(false, .acq_rel);
        const parked_mutation = force and !self.forceReadyEligible(ctx);
        if ((force or reschedule) and !parked_mutation) {
            if (force and !ctx.cooperative_mutation_waiting.load(.acquire)) {
                _ = ctx.cooperative_force_ready.swap(false, .acq_rel);
            }
            self.enqueueReady(ctx) catch |err| {
                log.warn("Failed to requeue cooperative first-stream owner", &.{
                    Attr.string("error", @errorName(err)),
                });
            };
        }
    }

    fn workerLoop(self: *FirstStreamScheduler) void {
        while (!self.shutdown.load(.acquire)) {
            if (self.takeReady()) |ctx| {
                if (ctx.cooperative_done.load(.acquire)) continue;
                if (ctx.cooperative_running.cmpxchgStrong(false, true, .acq_rel, .acquire)) |_| {
                    ctx.cooperative_needs_reschedule.store(true, .release);
                    continue;
                }
                switch (processCooperativeFirstStream(ctx)) {
                    .done => self.finishCooperativeContext(ctx),
                    .keep => self.completeCooperativeTurn(ctx),
                    .offloaded => {},
                }
                self.pauseAfterTurn();
                continue;
            }
        }
    }

    fn pauseAfterTurn(self: *FirstStreamScheduler) void {
        // CANARY: REQ=REQ-QUIC-HC-147; FEATURE="QUIC High-Concurrency Requests"; ASPECT=CooperativePollerFairness; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-29
        // CANARY: REQ=REQ-QUIC-HC-176; FEATURE="QUIC High-Concurrency Requests"; ASPECT=BacklogAwareCooperativePacing; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-29
        //
        // Cooperative first-stream workers can process cheap count responses
        // faster than the QUIC poll workers can flush request/response packets
        // during 4k+ same-process fan-out. Keep low fan-out hot, but yield once
        // the pool is large and add the same bounded backoff used by the legacy
        // persistent stream loop when thousands of first streams are live.
        //
        // When the ready queue itself is backed up, the post-turn sleep becomes
        // scheduler head-of-line delay rather than poller relief. Skip the
        // backoff only while a meaningful backlog exists; the existing yield and
        // sleep remain active once workers catch up.
        const ready_depth = self.ready_depth.load(.acquire);
        if (ready_depth > self.readyBacklogPauseSkipThreshold()) return;

        const active_contexts = self.context_count.load(.acquire);
        if (active_contexts > 512) {
            const excess: u64 = @intCast(active_contexts - 512);
            const delay_ns = @min(excess * first_stream_scheduler_turn_delay_per_excess_ns, first_stream_scheduler_turn_delay_cap_ns);
            compat_sleepNs(delay_ns);
        } else if (self.workers.len > 64) {
            std.Thread.yield() catch {};
        }
    }

    fn readyBacklogPauseSkipThreshold(self: *FirstStreamScheduler) u32 {
        return @intCast(@min(@max(@as(usize, 1), self.workers.len), std.math.maxInt(u32)));
    }

    fn decrementReadyDepth(self: *FirstStreamScheduler) void {
        var observed = self.ready_depth.load(.acquire);
        while (observed > 0) {
            observed = self.ready_depth.cmpxchgWeak(observed, observed - 1, .acq_rel, .acquire) orelse return;
        }
    }

    fn mutationCounterForClass(self: *FirstStreamScheduler, class: CooperativeMutationAdmissionClass) ?struct { inflight: *std.atomic.Value(u32), limit: u32 } {
        return switch (class) {
            .none => null,
            .serial => .{ .inflight = &self.mutation_inflight, .limit = self.mutation_limit },
            .shard_parallel => .{ .inflight = &self.shard_parallel_mutation_inflight, .limit = self.shard_parallel_mutation_limit },
        };
    }

    fn mutationPermitCapacityForClass(self: *FirstStreamScheduler, class: CooperativeMutationAdmissionClass) bool {
        const counter = self.mutationCounterForClass(class) orelse return true;
        return counter.inflight.load(.acquire) < counter.limit;
    }

    fn anyMutationPermitCapacity(self: *FirstStreamScheduler) bool {
        return self.mutationPermitCapacityForClass(.serial) or self.mutationPermitCapacityForClass(.shard_parallel);
    }

    fn tryAcquireMutationPermit(self: *FirstStreamScheduler, class: CooperativeMutationAdmissionClass) bool {
        // CANARY: REQ=REQ-QUIC-HC-148; FEATURE="QUIC High-Concurrency Mutations"; ASPECT=CooperativeMutationAdmission; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-28
        //
        // General mutating requests can occupy scheduler workers behind the
        // graph writer, while multi-property MERGE uses shard/tuple locks.
        // Admit each class against its own window so serial writers cannot
        // starve reads and shard-parallel mutations are not throttled by the
        // old four-wide writer cap.
        const counter = self.mutationCounterForClass(class) orelse return true;
        var observed = counter.inflight.load(.acquire);
        while (observed < counter.limit) {
            observed = counter.inflight.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire) orelse return true;
        }
        return false;
    }

    fn releaseMutationPermit(self: *FirstStreamScheduler, class: CooperativeMutationAdmissionClass) void {
        const counter = self.mutationCounterForClass(class) orelse return;
        _ = counter.inflight.fetchSub(1, .acq_rel);
        if (self.mutation_retry_waiters.load(.acquire) != 0) {
            const io = std.Io.Threaded.global_single_threaded.io();
            _ = self.ready_generation.fetchAdd(1, .release);
            io.futexWake(u32, &self.ready_generation.raw, 1);
        }
    }

    fn decrementMutationRetryWaiters(self: *FirstStreamScheduler) void {
        var observed = self.mutation_retry_waiters.load(.acquire);
        while (observed > 0) {
            observed = self.mutation_retry_waiters.cmpxchgWeak(observed, observed - 1, .acq_rel, .acquire) orelse return;
        }
    }

    fn markMutationRetryWaiter(self: *FirstStreamScheduler, ctx: *FirstStreamOwnerContext, class: CooperativeMutationAdmissionClass) void {
        // CANARY: REQ=REQ-QUIC-HC-159; FEATURE="QUIC High-Concurrency Mutations"; ASPECT=PermitGatedMutationRetry; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-29
        //
        // Overflow mutations must retain stream ordering, but immediately
        // requeueing them spins the cooperative ready queue while the global
        // mutation window is full. Park the packet until the next mutation
        // permit release wakes a waiter.
        ctx.cooperative_mutation_wait_class.store(@intFromEnum(class), .release);
        if (!ctx.cooperative_mutation_waiting.swap(true, .acq_rel)) {
            _ = self.mutation_retry_waiters.fetchAdd(1, .acq_rel);
        }
    }

    fn clearMutationRetryWaiter(self: *FirstStreamScheduler, ctx: *FirstStreamOwnerContext) void {
        if (ctx.cooperative_mutation_waiting.swap(false, .acq_rel)) {
            self.decrementMutationRetryWaiters();
        }
        ctx.cooperative_mutation_wait_class.store(@intFromEnum(CooperativeMutationAdmissionClass.none), .release);
    }

    fn submitMutationOffload(
        self: *FirstStreamScheduler,
        ctx: *FirstStreamOwnerContext,
        packet: schema.ClientPacket,
        class: CooperativeMutationAdmissionClass,
    ) bool {
        if (class != .shard_parallel) return false;
        const pool = self.mutation_offload_pool orelse return false;

        const task = self.allocator.create(CooperativeMutationOffloadTask) catch return false;
        task.* = .{
            .scheduler = self,
            .ctx = ctx,
            .packet = packet,
            .mutation_class = class,
        };
        _ = self.mutation_offload_inflight.fetchAdd(1, .acq_rel);
        if (!pool.submitDefault(.{
            .context = @ptrCast(task),
            .callback = processCooperativeMutationOffload,
        })) {
            _ = self.mutation_offload_inflight.fetchSub(1, .acq_rel);
            self.allocator.destroy(task);
            return false;
        }
        return true;
    }

    fn forceReadyEligible(self: *FirstStreamScheduler, ctx: *FirstStreamOwnerContext) bool {
        if (!ctx.cooperative_mutation_waiting.load(.acquire)) return true;
        const class: CooperativeMutationAdmissionClass = @enumFromInt(ctx.cooperative_mutation_wait_class.load(.acquire));
        return self.mutationPermitCapacityForClass(class);
    }

    fn dequeueReadyLocked(self: *FirstStreamScheduler) ?*FirstStreamOwnerContext {
        if (self.ready_head >= self.ready_queue.items.len) {
            self.ready_queue.clearRetainingCapacity();
            self.ready_head = 0;
            self.ready_depth.store(0, .release);
            return null;
        }

        // CANARY: REQ=REQ-QUIC-HC-067; FEATURE="QUIC High-Concurrency Requests"; ASPECT=FirstStreamSchedulerFIFO; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
        //
        // FIFO avoids starving older HELLO streams during a 512+ connection
        // burst. Keep a head index so dequeue stays O(1) while preserving
        // fairness.
        const ctx = self.ready_queue.items[self.ready_head];
        self.ready_head += 1;
        if (self.ready_head >= self.ready_queue.items.len) {
            self.ready_queue.clearRetainingCapacity();
            self.ready_head = 0;
        } else if (self.ready_head > 1024 and self.ready_head * 2 >= self.ready_queue.items.len) {
            std.mem.copyForwards(
                *FirstStreamOwnerContext,
                self.ready_queue.items[0 .. self.ready_queue.items.len - self.ready_head],
                self.ready_queue.items[self.ready_head..],
            );
            self.ready_queue.items.len -= self.ready_head;
            self.ready_head = 0;
        }
        ctx.cooperative_queued.store(false, .release);
        self.decrementReadyDepth();
        const enqueued_ns = ctx.cooperative_enqueued_ns.swap(0, .acq_rel);
        if (enqueued_ns != 0) {
            quic_response_metrics.recordFirstStreamReadyDequeued(monoNsFromHandler() -| enqueued_ns);
        }
        return ctx;
    }

    fn takeChangedContextLocked(self: *FirstStreamScheduler, include_force_scan: bool, include_generation: bool) ?*FirstStreamOwnerContext {
        const len = self.contexts.items.len;
        if (len == 0) {
            self.next_index = 0;
            return null;
        }

        var idx = if (self.next_index < len) self.next_index else 0;
        var scanned: usize = 0;
        while (scanned < len) : (scanned += 1) {
            const ctx = self.contexts.items[idx];
            idx += 1;
            if (idx >= len) idx = 0;

            if (ctx.cooperative_done.load(.acquire)) continue;
            if (ctx.cooperative_running.load(.acquire)) continue;
            if (ctx.cooperative_queued.load(.acquire)) continue;

            const force = ctx.cooperative_force_ready.load(.acquire);
            if ((include_force_scan or include_generation) and force and self.forceReadyEligible(ctx)) {
                self.next_index = idx;
                return ctx;
            }
            if (include_generation) {
                const current_generation = ctx.stream.readGeneration();
                const seen_generation = ctx.cooperative_generation_seen.load(.acquire);
                if (current_generation != seen_generation) {
                    self.next_index = idx;
                    return ctx;
                }
            }
        }

        self.next_index = idx;
        return null;
    }

    fn shouldSweepIdleContextsLocked(self: *FirstStreamScheduler) bool {
        if (self.contexts.items.len == 0) return false;
        const now = monoNsFromHandler();
        if (self.last_idle_sweep_ns == 0 or now -| self.last_idle_sweep_ns >= first_stream_scheduler_idle_sweep_ns) {
            self.last_idle_sweep_ns = now;
            return true;
        }
        return false;
    }

    fn takeReady(self: *FirstStreamScheduler) ?*FirstStreamOwnerContext {
        const io = std.Io.Threaded.global_single_threaded.io();
        while (true) {
            self.mutex.lockUncancelable(io);
            if (self.dequeueReadyLocked()) |ctx| {
                self.mutex.unlock(io);
                return ctx;
            }
            if (self.shutdown.load(.acquire)) {
                self.mutex.unlock(io);
                return null;
            }

            // CANARY: REQ=REQ-QUIC-HC-100; FEATURE="QUIC High-Concurrency Requests"; ASPECT=CooperativeSchedulerMissedWakeSweep; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
            //
            // RX-ready callbacks can be lost during close-heavy fan-out when a
            // stream is idle for the whole burst and only receives a verifier
            // query afterwards. A low-frequency sweep compares each stream's
            // per-connection RX generation with the last generation observed
            // at WouldBlock, giving long-idle connections a bounded recovery
            // path without polling every worker on every scheduler wait.
            const scan_mutation_waiters = self.mutation_retry_waiters.load(.acquire) != 0 and self.anyMutationPermitCapacity();
            const sweep_idle_contexts = self.shouldSweepIdleContextsLocked();
            if (scan_mutation_waiters or sweep_idle_contexts) {
                if (self.takeChangedContextLocked(scan_mutation_waiters, sweep_idle_contexts)) |ctx| {
                    self.mutex.unlock(io);
                    return ctx;
                }
            }

            const observed = self.ready_generation.load(.acquire);
            // 2026-06-08 idle-CPU fix: read the context count while still holding
            // the lock so the timeout choice is consistent. With no contexts the
            // 10ms sweep is a no-op, so park long (see
            // first_stream_scheduler_idle_park_ns); with contexts present keep the
            // 10ms sweep cadence for the missed-wake recovery path above.
            const has_contexts = self.contexts.items.len != 0;
            self.mutex.unlock(io);

            const wait_ns: u64 = if (has_contexts)
                first_stream_scheduler_idle_sweep_ns
            else
                first_stream_scheduler_idle_park_ns;
            const timeout: std.Io.Timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(wait_ns),
                .clock = .awake,
            } };
            io.futexWaitTimeout(u32, &self.ready_generation.raw, observed, timeout) catch |err| switch (err) {
                error.Canceled => return null,
            };
        }
    }

    fn enqueueReady(self: *FirstStreamScheduler, ctx: *FirstStreamOwnerContext) !void {
        if (self.shutdown.load(.acquire)) return;
        if (ctx.cooperative_done.load(.acquire)) return;
        if (!self.forceReadyEligible(ctx)) return;
        if (ctx.cooperative_queued.cmpxchgStrong(false, true, .acq_rel, .acquire)) |_| {
            return;
        }
        ctx.cooperative_enqueued_ns.store(monoNsFromHandler(), .release);
        quic_response_metrics.recordFirstStreamReadyEnqueued();

        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        errdefer {
            ctx.cooperative_queued.store(false, .release);
            self.mutex.unlock(io);
        }
        try self.ready_queue.append(self.allocator, ctx);
        _ = self.ready_depth.fetchAdd(1, .acq_rel);
        _ = self.ready_generation.fetchAdd(1, .release);
        self.ready_cv.signal(io);
        io.futexWake(u32, &self.ready_generation.raw, 1);
        self.mutex.unlock(io);
    }

    fn removeContext(self: *FirstStreamScheduler, ctx: *FirstStreamOwnerContext) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.clearMutationRetryWaiter(ctx);

        var ready_idx: usize = self.ready_head;
        while (ready_idx < self.ready_queue.items.len) {
            if (self.ready_queue.items[ready_idx] == ctx) {
                _ = self.ready_queue.swapRemove(ready_idx);
                self.decrementReadyDepth();
                if (self.ready_head > self.ready_queue.items.len) {
                    self.ready_head = self.ready_queue.items.len;
                }
                continue;
            }
            ready_idx += 1;
        }
        ctx.cooperative_queued.store(false, .release);

        var i: usize = 0;
        while (i < self.contexts.items.len) : (i += 1) {
            if (self.contexts.items[i] == ctx) {
                _ = self.contexts.swapRemove(i);
                if (self.contexts.items.len == 0) {
                    self.next_index = 0;
                } else if (self.next_index >= self.contexts.items.len) {
                    self.next_index = 0;
                }
                _ = self.context_count.fetchSub(1, .acq_rel);
                return;
            }
        }
    }
};

var g_first_stream_scheduler: ?*FirstStreamScheduler = null;

pub fn setFirstStreamScheduler(scheduler: ?*FirstStreamScheduler) void {
    g_first_stream_scheduler = scheduler;
}

fn firstStreamReadyCallback(ctx_ptr: *anyopaque, _: *quic_transport.QuicInnerConnection) void {
    const ctx: *FirstStreamOwnerContext = @ptrCast(@alignCast(ctx_ptr));
    // Notifier quiesce gate (REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME). The poll
    // thread can invoke this lock-free after the lib released `Connection.mu`.
    // Bracket the whole body with the in-flight counter so the teardown's
    // `waitNotifierDrained` (run AFTER `clearReadReadyNotifier`) blocks until
    // any entered callback has finished touching the ctx, before the notifier
    // ref is released. The notifier ref keeps this allocation alive across the
    // call, so every field access below is on live memory.
    ctx.enterNotifier();
    defer ctx.exitNotifier();
    // TOCTOU flag: a torn-down owner sets this before clearing the lib notifier.
    // Read it INSIDE the gate so a concurrent teardown cannot have freed the
    // allocation underneath this read.
    if (ctx.cooperative_done.load(.acquire)) return;
    if (ctx.cooperative_running.load(.acquire)) {
        ctx.cooperative_needs_reschedule.store(true, .release);
        return;
    }
    const scheduler = ctx.cooperative_scheduler orelse return;
    scheduler.enqueueReady(ctx) catch |err| {
        ctx.cooperative_queued.store(false, .release);
        log.warn("Failed to queue cooperative first-stream owner", &.{
            Attr.string("error", @errorName(err)),
        });
    };
}

// ── TEST SEAM (REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME, 2026-06-10) ─────────────
//
// The diagnosed use-after-free is `FirstStreamOwnerContext` being freed by the
// detached cleanup path (`finishCooperativeContext` -> `cleanupFirstStreamOwnerAsync`)
// while the poll-thread RX-ready notifier `firstStreamReadyCallback` still reads
// `ctx.cooperative_*` and dereferences `ctx.cooperative_scheduler`. The full
// production free path (`destroyFirstStreamOwnerResources`) tears down heavy,
// externally-owned deps (conn_state / dist_planner / transport / reader) that
// cannot be constructed in-process, so the harness below isolates the RACING
// SUBSET: the same struct allocation, the REAL `firstStreamReadyCallback`, the
// REAL `FirstStreamScheduler.enqueueReady`, and the same `gpa.destroy(ctx)`
// that ends the production free path. The notifier path touches ONLY ctx
// atomics + the scheduler (never the heavy deps), so dummy heavy-dep pointers
// are safe and never dereferenced — identical idiom to the `StreamAcceptorContext`
// lifetime tests (:6938+).
pub const FirstStreamLifetimeTestHarness = struct {
    allocator: std.mem.Allocator,
    scheduler: *FirstStreamScheduler,
    ctx: *FirstStreamOwnerContext,

    /// Allocate a worker-less scheduler + a minimally-wired owner context whose
    /// `cooperative_scheduler` points at it, mirroring exactly what the real
    /// `submit` (:2890) publishes for the cooperative fields. No worker threads
    /// are spawned (the test drives the callback/free directly), so no heavy-dep
    /// field is ever touched.
    pub fn init(allocator: std.mem.Allocator) !FirstStreamLifetimeTestHarness {
        const scheduler = try allocator.create(FirstStreamScheduler);
        scheduler.* = .{ .allocator = allocator };

        const ctx = try allocator.create(FirstStreamOwnerContext);
        // Heavy, externally-owned deps: NEVER dereferenced by the notifier /
        // enqueueReady / destroy(ctx) subset this harness exercises. Distinct
        // poison values so any accidental deref faults loudly.
        ctx.* = .{
            .allocator = allocator,
            .transport = @ptrFromInt(0xDEAD_0F50_1000),
            .conn = @ptrFromInt(0xDEAD_0F50_2000),
            .stream = @ptrFromInt(0xDEAD_0F50_3000),
            .state = undefined,
            .conn_state = undefined,
            .reader = undefined,
            .federation_manager = undefined,
            .dist_planner = undefined,
        };
        // Mirror the cooperative-field publish that `submit` performs, minus the
        // registry/notifier installation (which would touch `ctx.stream`).
        ctx.cooperative_scheduler = scheduler;
        ctx.cooperative_done.store(false, .release);
        ctx.cooperative_running.store(false, .release);
        ctx.cooperative_queued.store(false, .release);
        ctx.cooperative_needs_reschedule.store(false, .release);
        ctx.cooperative_force_ready.store(false, .release);
        ctx.cooperative_mutation_waiting.store(false, .release);

        return .{ .allocator = allocator, .scheduler = scheduler, .ctx = ctx };
    }

    /// Free the scheduler's queues + the scheduler. The ctx is freed by the
    /// test's free path (or here if the test never freed it).
    pub fn deinit(self: *FirstStreamLifetimeTestHarness, ctx_already_freed: bool) void {
        if (!ctx_already_freed) self.allocator.destroy(self.ctx);
        self.scheduler.ready_queue.deinit(self.allocator);
        self.scheduler.contexts.deinit(self.allocator);
        self.allocator.destroy(self.scheduler);
    }

    /// Drive the REAL poll-thread RX-ready notifier against this context.
    /// Reads `ctx.cooperative_*` and dereferences `ctx.cooperative_scheduler`
    /// — the exact accesses that UAF if the ctx was freed underneath.
    pub fn fireReadyNotifier(self: *FirstStreamLifetimeTestHarness) void {
        const dummy_inner: *quic_transport.QuicInnerConnection = @ptrFromInt(0xDEAD_0F50_4000);
        firstStreamReadyCallback(@ptrCast(self.ctx), dummy_inner);
    }

    /// Models the CURRENT (buggy) terminal free of the production path:
    /// `destroyFirstStreamOwnerResources` ends with `gpa.destroy(ctx)`
    /// UNCONDITIONALLY, with no synchronization against in-flight notifier /
    /// read-loop accesses. The reproduction test calls this concurrently with
    /// `fireReadyNotifier` so the testing allocator observes the use-after-free.
    /// The FIX replaces this with a refcount-gated free (`destroyOwnerGated`);
    /// at that point the reproduction tests switch their free call to the gated
    /// variant and assert the no-race contract.
    pub fn destroyOwnerUnsynchronized(self: *FirstStreamLifetimeTestHarness) void {
        self.allocator.destroy(self.ctx);
    }

    /// The terminal free GATED behind the lifetime refcount the FIX introduces.
    /// Frees only on the last release. Returns true if it actually freed. This
    /// is the post-fix shape `destroyFirstStreamOwnerResources` must adopt.
    pub fn destroyOwnerGated(self: *FirstStreamLifetimeTestHarness) bool {
        if (self.ctx.releaseOwnerRef()) {
            self.allocator.destroy(self.ctx);
            return true;
        }
        return false;
    }
};

/// Install/clear the process-global cleanup test barrier flag. Used only by the
/// lifetime tests under their own serialization; behavior-neutral otherwise.
pub fn setFirstStreamCleanupTestBarrier(enabled: bool) void {
    g_first_stream_cleanup_test_barrier = enabled;
}

fn isGqlIdentifierByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn skipQuotedToken(query: []const u8, start: usize, quote: u8) usize {
    var i = start + 1;
    while (i < query.len) : (i += 1) {
        if (query[i] != quote) continue;
        if (i + 1 < query.len and query[i + 1] == quote) {
            i += 1;
            continue;
        }
        return i + 1;
    }
    return query.len;
}

fn skipLineComment(query: []const u8, start: usize) usize {
    var i = start + 2;
    while (i < query.len and query[i] != '\n') : (i += 1) {}
    return i;
}

fn skipBlockComment(query: []const u8, start: usize) usize {
    var i = start + 2;
    while (i + 1 < query.len and !(query[i] == '*' and query[i + 1] == '/')) : (i += 1) {}
    return @min(i + 2, query.len);
}

fn isCooperativeMutationKeyword(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "CREATE") or
        std.ascii.eqlIgnoreCase(token, "MERGE") or
        std.ascii.eqlIgnoreCase(token, "DELETE") or
        std.ascii.eqlIgnoreCase(token, "DETACH") or
        std.ascii.eqlIgnoreCase(token, "SET") or
        std.ascii.eqlIgnoreCase(token, "REMOVE") or
        std.ascii.eqlIgnoreCase(token, "INSERT") or
        std.ascii.eqlIgnoreCase(token, "DROP") or
        std.ascii.eqlIgnoreCase(token, "ALTER") or
        std.ascii.eqlIgnoreCase(token, "GRANT") or
        std.ascii.eqlIgnoreCase(token, "DENY") or
        std.ascii.eqlIgnoreCase(token, "REVOKE") or
        std.ascii.eqlIgnoreCase(token, "RESTORE");
}

fn isShardParallelMergeDisqualifier(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "MATCH") or
        std.ascii.eqlIgnoreCase(token, "CREATE") or
        std.ascii.eqlIgnoreCase(token, "DELETE") or
        std.ascii.eqlIgnoreCase(token, "DETACH") or
        std.ascii.eqlIgnoreCase(token, "SET") or
        std.ascii.eqlIgnoreCase(token, "REMOVE") or
        std.ascii.eqlIgnoreCase(token, "INSERT") or
        std.ascii.eqlIgnoreCase(token, "DROP") or
        std.ascii.eqlIgnoreCase(token, "ALTER") or
        std.ascii.eqlIgnoreCase(token, "GRANT") or
        std.ascii.eqlIgnoreCase(token, "DENY") or
        std.ascii.eqlIgnoreCase(token, "REVOKE") or
        std.ascii.eqlIgnoreCase(token, "RESTORE") or
        std.ascii.eqlIgnoreCase(token, "RETURN") or
        std.ascii.eqlIgnoreCase(token, "ON") or
        std.ascii.eqlIgnoreCase(token, "CALL") or
        std.ascii.eqlIgnoreCase(token, "UNWIND") or
        std.ascii.eqlIgnoreCase(token, "USE") or
        std.ascii.eqlIgnoreCase(token, "BEGIN") or
        std.ascii.eqlIgnoreCase(token, "COMMIT") or
        std.ascii.eqlIgnoreCase(token, "ROLLBACK");
}

fn queryLooksShardParallelSimpleMergeForCooperativeAdmission(query: []const u8) bool {
    // CANARY: REQ=REQ-QUIC-HC-160; FEATURE="QUIC High-Concurrency Mutations"; ASPECT=ShardParallelMutationAdmission; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-29
    //
    // This deliberately recognizes only the storage fast path that bypasses
    // the whole-graph writer: a single no-RETURN MERGE node pattern with at
    // least two merge properties. Broader mutation shapes keep the small
    // serial admission window until they have their own storage-level
    // concurrency contract.
    var i: usize = 0;
    var saw_first_identifier = false;
    var saw_merge = false;
    var paren_depth: u32 = 0;
    var property_depth: u32 = 0;
    var property_key_count: usize = 0;
    var node_pattern_closed = false;

    while (i < query.len) {
        const c = query[i];
        if (std.ascii.isWhitespace(c) or c == ';') {
            i += 1;
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            i = skipQuotedToken(query, i, c);
            continue;
        }
        if (c == '/' and i + 1 < query.len and query[i + 1] == '/') {
            i = skipLineComment(query, i);
            continue;
        }
        if (c == '/' and i + 1 < query.len and query[i + 1] == '*') {
            i = skipBlockComment(query, i);
            continue;
        }
        if (node_pattern_closed) return false;

        if (isGqlIdentifierByte(c)) {
            const start = i;
            while (i < query.len and isGqlIdentifierByte(query[i])) : (i += 1) {}
            const token = query[start..i];
            if (!saw_first_identifier) {
                saw_first_identifier = true;
                if (!std.ascii.eqlIgnoreCase(token, "MERGE")) return false;
                saw_merge = true;
                continue;
            }
            if (isShardParallelMergeDisqualifier(token)) return false;
            continue;
        }

        if (!saw_merge) return false;

        switch (c) {
            '(' => {
                paren_depth += 1;
                i += 1;
            },
            ')' => {
                if (paren_depth == 0 or property_depth != 0) return false;
                paren_depth -= 1;
                if (paren_depth == 0) node_pattern_closed = true;
                i += 1;
            },
            '[' => return false,
            '{' => {
                if (paren_depth != 1 or property_depth != 0) return false;
                property_depth = 1;
                i += 1;
            },
            '}' => {
                if (property_depth != 1) return false;
                property_depth = 0;
                i += 1;
            },
            ':' => {
                if (property_depth == 1) property_key_count += 1;
                i += 1;
            },
            else => {
                i += 1;
            },
        }
    }

    return node_pattern_closed and property_key_count >= 2;
}

fn queryCooperativeMutationAdmissionClass(query: []const u8) CooperativeMutationAdmissionClass {
    // CANARY: REQ=REQ-QUIC-HC-148; FEATURE="QUIC High-Concurrency Mutations"; ASPECT=CooperativeMutationClassifier; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-28
    //
    // This is an admission-control prefilter, not the semantic authority. The
    // normal parser and query_traits still decide lock mode. Here we only need
    // to recognize mutating packets early enough to avoid letting a mutation
    // burst consume every cooperative scheduler worker.
    var i: usize = 0;
    while (i < query.len) {
        const c = query[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            i = skipQuotedToken(query, i, c);
            continue;
        }
        if (c == '/' and i + 1 < query.len and query[i + 1] == '/') {
            i = skipLineComment(query, i);
            continue;
        }
        if (c == '/' and i + 1 < query.len and query[i + 1] == '*') {
            i = skipBlockComment(query, i);
            continue;
        }
        if (!isGqlIdentifierByte(c)) {
            i += 1;
            continue;
        }

        const start = i;
        while (i < query.len and isGqlIdentifierByte(query[i])) : (i += 1) {}
        const token = query[start..i];
        if (isCooperativeMutationKeyword(token)) {
            if (std.ascii.eqlIgnoreCase(token, "MERGE") and
                queryLooksShardParallelSimpleMergeForCooperativeAdmission(query))
            {
                return .shard_parallel;
            }
            return .serial;
        }
    }
    return .none;
}

fn packetCooperativeMutationAdmissionClass(packet: *const schema.ClientPacket) CooperativeMutationAdmissionClass {
    const msg = packet.quic orelse return .none;
    return switch (msg) {
        .execute => |execute_req| queryCooperativeMutationAdmissionClass(execute_req.query),
        .commit, .rollback, .rollback_to, .restore, .upload_backup, .cdc_ctrl => .serial,
        else => .none,
    };
}

const CooperativeMutationOffloadTask = struct {
    scheduler: *FirstStreamScheduler,
    ctx: *FirstStreamOwnerContext,
    packet: schema.ClientPacket,
    mutation_class: CooperativeMutationAdmissionClass,
};

fn processCooperativeFirstStreamPacket(ctx: *FirstStreamOwnerContext, packet: *schema.ClientPacket) bool {
    // CANARY: REQ=REQ-QUIC-HC-157; FEATURE="HighConcurrencyDiagnostics"; ASPECT=FirstStreamSchedulerLatency; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
    //
    // Record one server-side application-processing sample per delivered
    // first-stream packet. Combined with response write metrics, this
    // separates scheduler queue tail from execution/write tail.
    quic_response_metrics.recordFirstStreamPacketStart();
    const packet_process_start_ns = monoNsFromHandler();
    const packet_processed = blk: {
        quic_response_metrics.beginFirstStreamPhaseSample();
        defer quic_response_metrics.endFirstStreamPhaseSample();
        break :blk processFirstStreamPacket(
            ctx.allocator,
            ctx.transport,
            ctx.stream,
            &ctx.reader,
            &ctx.state,
            &ctx.conn_state,
            ctx.conn_state.disable_estimates,
            ctx.conn_state.compact_profile,
            ctx.conn_state.memcurve_profile,
            ctx.peer_ip,
            packet,
        );
    };
    quic_response_metrics.recordFirstStreamPacketComplete(monoNsFromHandler() -| packet_process_start_ns);
    return packet_processed;
}

fn processCooperativeMutationOffload(task_ptr: *anyopaque) void {
    const task: *CooperativeMutationOffloadTask = @ptrCast(@alignCast(task_ptr));
    const scheduler = task.scheduler;
    const ctx = task.ctx;
    const gpa = ctx.allocator;
    defer {
        _ = scheduler.mutation_offload_inflight.fetchSub(1, .acq_rel);
        scheduler.allocator.destroy(task);
    }
    defer scheduler.releaseMutationPermit(task.mutation_class);
    defer task.packet.deinit(gpa);

    installThreadLocalSessionState(&ctx.state);
    defer clearThreadLocalSessionState();

    const packet_processed = processCooperativeFirstStreamPacket(ctx, &task.packet);
    if (!packet_processed) {
        scheduler.finishCooperativeContext(ctx);
        return;
    }

    if (ctx.reader.hasBufferedUnread()) {
        ctx.cooperative_force_ready.store(true, .release);
    } else {
        ctx.cooperative_generation_seen.store(ctx.stream.readGeneration(), .release);
    }
    scheduler.completeCooperativeTurn(ctx);
}

fn processCooperativeFirstStream(ctx: *FirstStreamOwnerContext) CooperativeFirstStreamTurn {
    const gpa = ctx.allocator;
    installThreadLocalSessionState(&ctx.state);
    defer clearThreadLocalSessionState();

    var processed: u32 = 0;
    while (processed < first_stream_scheduler_messages_per_tick) : (processed += 1) {
        var packet: schema.ClientPacket = undefined;
        if (ctx.pending_packet) |pending| {
            packet = pending;
            ctx.pending_packet = null;
            ctx.cooperative_force_ready.store(false, .release);
            if (ctx.cooperative_scheduler) |scheduler| {
                scheduler.clearMutationRetryWaiter(ctx);
            }
        } else {
            const read_generation = ctx.stream.readGeneration();
            const packet_opt = ctx.reader.nextMessageNonBlocking() catch |err| {
                if (err == error.WouldBlock) {
                    ctx.cooperative_generation_seen.store(read_generation, .release);
                    return .keep;
                }
                if (isIdleStreamReadError(err)) return .done;
                log.err("Protobuf read error", &.{Attr.string("error", @errorName(err))});
                return .done;
            };

            if (packet_opt == null) return .done;
            packet = packet_opt.?;
            _ = ctx.post_hello_packets.fetchAdd(1, .acq_rel);
        }

        var mutation_scheduler: ?*FirstStreamScheduler = null;
        var mutation_class: CooperativeMutationAdmissionClass = .none;
        const admission_class = packetCooperativeMutationAdmissionClass(&packet);
        if (admission_class != .none) {
            if (ctx.cooperative_scheduler) |scheduler| {
                if (!scheduler.tryAcquireMutationPermit(admission_class)) {
                    quic_response_metrics.recordFirstStreamMutationDeferral();
                    ctx.pending_packet = packet;
                    scheduler.markMutationRetryWaiter(ctx, admission_class);
                    ctx.cooperative_force_ready.store(true, .release);
                    return .keep;
                }
                if (scheduler.submitMutationOffload(ctx, packet, admission_class)) {
                    return .offloaded;
                }
                mutation_scheduler = scheduler;
                mutation_class = admission_class;
            }
        }
        defer {
            if (mutation_scheduler) |scheduler| scheduler.releaseMutationPermit(mutation_class);
            packet.deinit(gpa);
        }

        if (!processCooperativeFirstStreamPacket(ctx, &packet)) return .done;
    }

    if (ctx.reader.hasBufferedUnread()) {
        ctx.cooperative_force_ready.store(true, .release);
    } else {
        ctx.cooperative_generation_seen.store(ctx.stream.readGeneration(), .release);
    }
    return .keep;
}

// CANARY: REQ=REQ-QUIC-HC-011; FEATURE="DetachedFirstStream"; ASPECT=ConnectionAdmission; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
fn handleFirstStreamOwner(ctx_ptr: *anyopaque) void {
    const ctx: *FirstStreamOwnerContext = @ptrCast(@alignCast(ctx_ptr));
    defer cleanupFirstStreamOwner(ctx);

    installThreadLocalSessionState(&ctx.state);
    defer clearThreadLocalSessionState();

    registerFirstStreamReader(ctx);

    runStreamQueryLoopWithReader(
        ctx.allocator,
        ctx.transport,
        ctx.stream,
        &ctx.reader,
        &ctx.state,
        &ctx.conn_state,
        ctx.conn_state.disable_estimates,
        ctx.conn_state.compact_profile,
        ctx.conn_state.memcurve_profile,
        ctx.peer_ip,
    );
}

// CANARY: REQ=REQ-ABAC-WIRE-013; FEATURE="ABAC Enforcement"; ASPECT=QUICHandler; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Updated handleQuicConnection signature to accept SecurityManager for ABAC enforcement
pub fn handleQuicConnection(
    gpa: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    conn: *quic_transport.QuicConnection,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    env_spill_threshold: usize,
    env_storage_checksum_error: bool,
    _force_serialization_failure_unused: bool,
    security_manager: ?*geode_auth.SecurityManager,
    shared_ast_cache: ?*anyopaque, // Type is query_ast_cache.SharedAstCache
    shared_optimizer: ?*query_plan_cache.SharedQueryOptimizer, // Issue #460
    env_config: *const server_init.EnvironmentConfig, // #683: Cached env vars
    stream_pool: *pooled.ThreadPool,
    acceptor_pool: *pooled.ThreadPool,
) !void {
    _ = _force_serialization_failure_unused;
    // CANARY: REQ=REQ-QUIC-CONN-CLEANUP-003; FEATURE="ConnectionMemoryManagement"; ASPECT=ProperCleanup; STATUS=EXEMPT; OWNER=server; UPDATED=2025-12-27
    // 2026-04-28: conn destruction is gated on `destroy_conn`.  The acceptor
    // wait defer (later in this function) clears it if the acceptor doesn't
    // exit within the bounded deadline — leaving the conn alive (a leak)
    // is preferable to freeing it under a still-running acceptor whose
    // next `tryAcceptStream` would UAF.  The QUIC library will eventually
    // idle-timeout the leaked conn at the protocol layer.
    var destroy_conn: bool = true;
    defer if (destroy_conn) transport.destroyConnection(conn);
    log.debug("Entering handleQuicConnection", &.{});

    // Wait for incoming STREAM frames with handler-driven polling.
    // #540: Instead of blind-sleeping, handlers call poll(0) themselves to
    // process incoming handshake packets. This eliminates the dependency on
    // the main thread's poll frequency for handshake completion.
    var poll_attempts: usize = 0;
    var backoff_us: u64 = 100; // Start at 100μs
    const max_backoff_us: u64 = 10_000; // Cap at 10ms (reduced from 50ms)
    // 2026-04-28: bumped from 500ms → 30s.  Under 16-way concurrent client
    // fan-out (msft-graph parallel pipeline), the QUIC main poll thread
    // takes longer than 500ms to land STREAM frames on every accepted
    // connection.  Connections 5-16 bailed here and `defer
    // transport.destroyConnection` quietly tore them down — but the
    // QUIC `closeConnection` path does NOT reliably send a
    // CONNECTION_CLOSE frame to the peer (`catch {}` at the call
    // site), so the client sat in `BeginTx` waiting for a stream the
    // server had abandoned.  Symptom: msft-graph stalls at
    // `flushed=281` with `quic_active_connections=4` even though the
    // client logged "pinned connections acquired count=16".  30s
    // matches the typical client-side connect/idle timeout and gives
    // the server's poll thread plenty of slack at high fan-out
    // without disabling the safety check entirely (a truly idle
    // client will still get reaped, just by the QUIC layer's
    // 300s idle timeout instead).
    const max_total_wait_ms: u64 = 30_000;
    const first_stream_wait_start_ns = monoNsFromHandler();
    var total_waited_us: u64 = 0;
    while (total_waited_us < max_total_wait_ms * 1000) : (poll_attempts += 1) {
        const read_generation = conn.readGeneration();
        if (conn.inner.hasIncomingStreams()) break;
        // Dedicated poll thread handles packet delivery — no handler poll needed.
        conn.waitForReadGeneration(read_generation, backoff_us * std.time.ns_per_us);
        const wait_after_ns = monoNsFromHandler();
        total_waited_us = @intCast((wait_after_ns -| first_stream_wait_start_ns) / std.time.ns_per_us);
        backoff_us = @min(backoff_us * 2, max_backoff_us);
        if (poll_attempts > 0 and poll_attempts % 10 == 0) {
            log.debug("No streams yet, retrying", &.{
                Attr.int("attempt", @intCast(poll_attempts + 1)),
                Attr.int("total_waited_ms", @intCast(total_waited_us / 1000)),
            });
        }
    }

    // If the handshake didn't complete within the timeout, return cleanly
    // rather than calling acceptStream() which would return WouldBlock and
    // log a misleading "Error handling QUIC connection" message.
    if (!conn.inner.hasIncomingStreams()) {
        log.debug("No streams after handshake timeout, closing connection", &.{
            Attr.int("waited_ms", @intCast(total_waited_us / 1000)),
        });
        return;
    }

    // Accept a stream for the protocol communication
    log.debug("Attempting to accept stream", &.{});
    const stream = try conn.acceptStream();
    log.debug("Stream accepted successfully", &.{});
    var stream_handed_off = false;
    defer if (!stream_handed_off) stream.close();

    // Initialize state
    var state = ServerState{
        .allocator = gpa,
    };
    state.exec_session = execution.SessionState.init(gpa);
    state.telemetry_paging = env_config.telemetry_paging;
    state.txn_manager.init(gpa);
    state.inserted_values = .empty;
    state.catalog_schemas = std.HashMap([]const u8, CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.catalog_graphs = std.HashMap([]const u8, CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.graph_types = std.HashMap([]const u8, geode.server_state.GraphTypeDefinition, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.query_mem_limit_bytes = env_spill_threshold;
    state.storage_checksum_error = env_storage_checksum_error;
    // CANARY: REQ=REQ-ABAC-WIRE-014; FEATURE="ABAC Enforcement"; ASPECT=QUICState; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: Wire SecurityManager into ServerState for QUIC connection ABAC enforcement
    state.security_manager = security_manager;

    // Initialize evaluator callbacks for execution engine.
    execution.initEvaluator();

    // GAP-0289: Track which tenant acquired a connection quota slot so we can release it on close.
    var quota_tenant_id: ?[]const u8 = null;
    var state_handed_off = false;

    // Ensure cleanup of per-connection state.
    defer {
        // GAP-0285: Clear per-thread FLE state (tenant_id and role) to prevent stale
        // state from leaking into a subsequent connection that reuses this thread.
        // CANARY: REQ=REQ-FLE-ROLE-ISOLATION-003; FEATURE="FLERoleIsolation"; ASPECT=QUICCleanup; STATUS=TESTED; OWNER=security; UPDATED=2026-04-05
        clearThreadLocalSessionState();

        // GAP-0289: Release connection quota slot for this tenant.
        releaseQuotaTenant(gpa, &quota_tenant_id);

        if (!state_handed_off) {
            deinitQuicServerState(gpa, &state, "connection close");
        }
    }

    // #683: Use cached env config instead of per-connection getEnvVarOwned syscalls.
    // CANARY: REQ=REQ-PERF-OPT-GATE-001; FEATURE="OptimizerGating"; ASPECT=HotPath; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=engine; UPDATED=2026-06-11
    state.query_optimizer_enabled = env_config.query_optimizer_enabled;
    // CANARY: REQ=REQ-PERF-INLINE-PULL-001; FEATURE="InlineRunPull"; ASPECT=HotPath; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=engine; UPDATED=2026-06-11
    state.inline_results_enabled = env_config.inline_results_enabled;
    state.inline_results_max_rows = env_config.inline_results_max_rows;

    // Issue #460: Use shared cross-connection optimizer instead of per-connection instance
    // CANARY: REQ=REQ-PERF-SHARED-OPT-001; FEATURE="SharedQueryOptimizer"; ASPECT=ConnectionWiring; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
    state.query_optimizer = shared_optimizer;

    // Attach shared AST cache for cross-connection reuse.
    // CANARY: REQ=REQ-PERF-AST-CACHE-003; FEATURE="SharedASTCache"; ASPECT=ConnectionState; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
    state.query_ast_cache = shared_ast_cache;

    // Initialize distributed query planner for federation-aware optimization
    var federation_manager = geode.distributed.query_planner.FederationManager.init(gpa);
    var dist_planner = geode.distributed.query_planner.DistributedQueryPlanner.init(gpa, &federation_manager);
    var distributed_planner_handed_off = false;
    defer {
        if (!distributed_planner_handed_off) {
            dist_planner.deinit();
            federation_manager.deinit();
        }
    }
    state.federation_manager = &federation_manager;
    state.distributed_planner = &dist_planner;

    // GAP-0258: mTLS authentication over QUIC — extract peer certificate and authenticate
    // CANARY: REQ=REQ-AUTH-MTLS-QUIC-003; FEATURE="mTLS over QUIC"; ASPECT=ConnectionAuth; STATUS=TESTED; TEST=geodetestlab/specs/authn_mtls_rejection_matrix.yml; OWNER=security; UPDATED=2026-06-11
    if (conn.getPeerCertificateDer()) |cert_der| {
        const identity = mtls_provider.extractIdentity(gpa, cert_der) catch |err| {
            log.warn("mTLS: Failed to extract certificate identity", &.{Attr.string("error", @errorName(err))});
            return err;
        };
        // Look up global mTLS provider (set in server/main.zig startup)
        if (g_mtls_provider) |provider| {
            if (provider.authenticate(&identity)) |auth_result_opt| {
                if (auth_result_opt) |auth_result| {
                    // Store the authenticated user from the mTLS certificate
                    state.authenticated_user = try std.fmt.allocPrint(gpa, "mtls:{}", .{auth_result.user_id});
                    log.info("mTLS: Authenticated user via certificate", &.{
                        Attr.int("user_id", @intCast(auth_result.user_id)),
                    });
                }
            } else |err| {
                log.warn("mTLS: Authentication failed", &.{Attr.string("error", @errorName(err))});
                if (transport.config.require_client_cert) {
                    return err;
                }
            }
        }
    } else if (transport.config.require_client_cert) {
        log.warn("mTLS: No client certificate presented (required)", &.{});
        return error.CertificateError;
    }

    // S6: Extract peer IP for rate limiting before the message loop.
    // CANARY: REQ=REQ-SEC-RATE-LIMIT-005; FEATURE="AuthRateLimiting"; ASPECT=PeerIPExtraction; STATUS=TESTED; TEST=geodetestlab/specs/authn_rate_limiter.yml; OWNER=security; UPDATED=2026-06-11
    const peer_ip = conn.getPeerAddressString(gpa);
    const peer_ip_allocated = !std.mem.eql(u8, peer_ip, "unknown");
    var peer_ip_handed_off = false;
    defer if (peer_ip_allocated and !peer_ip_handed_off) gpa.free(peer_ip);

    // ── Phase 1: HELLO on first stream ─────────────────────────────────────
    // Wait for the first message (expected to be HELLO) and process it.
    // This keeps the handshake flow identical to the pre-multiplexing code.
    // CANARY: REQ=REQ-QUIC-HC-014; FEATURE="BoundedHelloAdmission"; ASPECT=ConnectionThreadLifetime; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
    //
    // Detached connection-admission threads must be short-lived. Bound the
    // post-stream HELLO read as well as the pre-stream wait so an idle peer
    // cannot keep an admission thread alive indefinitely. The timeout is
    // cached at startup so high-fanout deployments can align it with client
    // retry budgets without per-connection environment lookups.
    const hello_read_timeout_ns: u64 = env_config.quic_hello_read_timeout_ms * std.time.ns_per_ms;
    const hello_read_start_ns = monoNsFromHandler();
    var line_reader = try BufferedProtoReader.init(gpa, transport, stream);
    line_reader.peer_addr = peer_ip;
    var line_reader_handed_off = false;
    var line_reader_registered = false;
    // #864 §10 per-stream stall observability — see runStreamQueryLoop.
    if (g_proto_reader_registry.register(gpa, line_reader.registryHandle())) |_| {
        line_reader_registered = true;
    } else |reg_err| {
        log.warn("proto_reader registry append failed; per-stream stall signal disabled for this stream", &.{
            Attr.string("error", @errorName(reg_err)),
        });
    }
    defer {
        if (!line_reader_handed_off) {
            if (line_reader_registered) {
                g_proto_reader_registry.unregister(@ptrCast(&line_reader));
            }
            line_reader.deinit();
        }
    }

    // Read and process the first message (HELLO).
    const hello_done = hello_blk: {
        while (true) {
            if (monoNsFromHandler() -| hello_read_start_ns >= hello_read_timeout_ns) {
                log.warn("Timed out waiting for QUIC HELLO message", &.{
                    Attr.int("timeout_ms", @intCast(hello_read_timeout_ns / std.time.ns_per_ms)),
                });
                return;
            }
            const packet_opt = line_reader.nextMessage() catch |err| {
                if (err == error.EndOfStream) return;
                if (err == error.WouldBlock) {
                    if (stream.poll_sync) |ps| {
                        ps.waitForPoll(quic_transport.server_handler_wait_for_poll_ns);
                    } else {
                        compat_sleepNs(100 * std.time.ns_per_us);
                    }
                    continue;
                }
                log.err("Protobuf read error during HELLO", &.{Attr.string("error", @errorName(err))});
                return err;
            };

            if (packet_opt == null) return; // EOF before HELLO
            var packet = packet_opt.?;
            defer packet.deinit(gpa);

            const msg = packet.quic orelse {
                try sendExecuteError(gpa, stream, "58000", "Empty packet", &.{}, &.{});
                continue;
            };

            // Process the message (should be HELLO, but handleClientMessage handles all types).
            handleClientMessage(gpa, &state, stream, msg, disable_estimates, compact_profile, memcurve_profile, peer_ip) catch |err| {
                log.err("HELLO processing error", &.{Attr.string("error", @errorName(err))});
                sendExecuteError(gpa, stream, "58000", "Internal Server Error", &.{}, &.{}) catch return;
                continue;
            };

            // After the first successfully processed message, continue to the query phase.
            break :hello_blk true;
        }
        break :hello_blk false;
    };
    if (!hello_done) return;

    // GAP-0289: After HELLO, enforce per-tenant connection quota.
    // The tenant_id is now stored in state.session_config by handleClientMessage.
    if (state.session_config) |cfg| {
        if (cfg.tenant_id) |tid| {
            if (tenant_quota.getGlobalQuotaManager()) |qm| {
                qm.acquireConnection(tid) catch {
                    log.warn("Connection quota exceeded for tenant — closing connection", &.{
                        Attr.string("tenant", tid),
                    });
                    sendExecuteError(gpa, stream, "42000", "Connection quota exceeded for tenant", &.{}, &.{}) catch {};
                    return;
                };
                quota_tenant_id = gpa.dupe(u8, tid) catch null;
            }
        }
    }

    // ── Phase 2: Stream multiplexing ─────────────────────────────────────
    // CANARY: REQ=REQ-QUIC-MUX-004; FEATURE="StreamMultiplexing"; ASPECT=AcceptorSpawn; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=server; UPDATED=2026-06-11
    // Start a stream acceptor thread that watches for additional client-initiated
    // streams on this connection. Each new stream gets its own handler thread
    // with per-stream transaction/result state but shared authentication.
    var conn_state = SharedConnState{
        .allocator = gpa,
        .security_manager = security_manager,
        .shared_ast_cache = shared_ast_cache,
        .shared_optimizer = shared_optimizer,
        .peer_ip = peer_ip,
        .peer_ip_allocated = false, // Lifetime managed by caller's defer
        .disable_estimates = disable_estimates,
        .compact_profile = compact_profile,
        .memcurve_profile = memcurve_profile,
        .env_spill_threshold = env_spill_threshold,
        .env_storage_checksum_error = env_storage_checksum_error,
        .env_config = env_config,
    };
    conn_state.captureFromState(&state) catch |err| {
        // S7: Do NOT allow unauthenticated streams — close connection on capture failure
        log.err("Failed to capture connection state for multiplexing", &.{Attr.string("error", @errorName(err))});
        return;
    };
    state.shared_conn = &conn_state;
    _ = try conn_state.registerActiveStream(stream.stream_id);
    // First stream counts as active.
    _ = conn_state.active_streams.fetchAdd(1, .release);
    var conn_state_handed_off = false;
    defer {
        if (!conn_state_handed_off) {
            conn_state.unregisterActiveStream(stream.stream_id);
            conn_state.releaseActiveStream();
            // GAP-0274 / QUIC-HC-002: Wait for ALL additional stream handlers to
            // finish before freeing conn_state. Park on the same active-stream
            // futex word that handlers wake on release, avoiding condition-variable
            // lost-wake races during high close churn.
            conn_state.waitForAllStreamsDrained();
            conn_state.deinit();
        }
    }

    // SP Tasks 2+3 (2026-04-25): stream_pool and acceptor_pool are now owned by
    // main() and passed in as parameters.  Per-connection pool init was removed
    // because per-connection deinit leaked ~5 zombie worker threads per QUIC
    // connection-close under msft-graph's per-file reconnect pattern (~720
    // closes × 5 = ~1800 zombie threads, starving the QUIC packet pump).
    // See docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md.

    const first_ctx = gpa.create(FirstStreamOwnerContext) catch |err| {
        log.warn("Failed to allocate first-stream owner context, running inline", &.{
            Attr.string("error", @errorName(err)),
        });
        runStreamQueryLoopWithReader(
            gpa,
            transport,
            stream,
            &line_reader,
            &state,
            &conn_state,
            disable_estimates,
            compact_profile,
            memcurve_profile,
            peer_ip,
        );
        return;
    };
    if (line_reader_registered) {
        g_proto_reader_registry.unregister(@ptrCast(&line_reader));
        line_reader_registered = false;
    }
    first_ctx.* = .{
        .allocator = gpa,
        .transport = transport,
        .conn = conn,
        .stream = stream,
        .state = state,
        .conn_state = conn_state,
        .reader = line_reader,
        .federation_manager = federation_manager,
        .dist_planner = dist_planner,
        .quota_tenant_id = quota_tenant_id,
        .peer_ip = peer_ip,
        .peer_ip_allocated = peer_ip_allocated,
    };
    first_ctx.dist_planner.federation_manager = &first_ctx.federation_manager;
    first_ctx.state.federation_manager = &first_ctx.federation_manager;
    first_ctx.state.distributed_planner = &first_ctx.dist_planner;
    first_ctx.state.shared_conn = &first_ctx.conn_state;
    first_ctx.conn_state.peer_ip = first_ctx.peer_ip;

    state_handed_off = true;
    distributed_planner_handed_off = true;
    conn_state_handed_off = true;
    line_reader_handed_off = true;
    stream_handed_off = true;
    peer_ip_handed_off = true;
    quota_tenant_id = null;
    destroy_conn = false;

    // CANARY: REQ=REQ-QUIC-HC-030; FEATURE="QUIC High-Concurrency Requests"; ASPECT=MultiplexingGate; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-10
    //
    // CLI batch mode opens additional streams on an authenticated QUIC
    // connection, so multiplexing stays enabled by default. High-fanout
    // one-stream clients can disable this acceptor to avoid creating one idle
    // long-lived task per connection during the HELLO fan-out.
    if (env_config.quic_stream_multiplexing_enabled) {
        // 2026-04-28 lifetime rewrite: the acceptor context is HEAP-allocated
        // and refcounted (owner=1, acceptor=1).  This eliminates the previous
        // UAF crash where a popped-stack `acceptor_ctx` was dereferenced by
        // a still-running acceptor (segfault at address 0x6 in
        // `streamAcceptorLoop`'s first `shutdown.load(.acquire)`).  See the
        // `StreamAcceptorContext` doc-comment for the full rationale.
        const acceptor_ctx = StreamAcceptorContext.create(
            gpa,
            transport,
            conn,
            &first_ctx.conn_state,
            stream_pool,
        ) catch |err| {
            log.warn("Failed to allocate acceptor context, single-stream mode", &.{
                Attr.string("error", @errorName(err)),
            });
            handleFirstStreamOwner(@ptrCast(first_ctx));
            return;
        };
        first_ctx.acceptor_ctx = acceptor_ctx;
        // 2026-04-28 ROOT-CAUSE FIX: use submit() (default lane, ~63 workers)
        // not submitBlocking() (blocking lane, ONLY 1 WORKER).  submitBlocking's
        // name describes the backpressure policy (block if queue full), not the
        // lane — but its implementation routes to `.lane = .blocking` which has
        // a single dedicated worker.  With 8 active conns the previous code
        // serialized all acceptors through that one worker; the first acceptor
        // (whose conn was still actively reading its first stream) never exited,
        // and the other 7 acceptor tasks sat in the blocking-lane queue forever
        // — owners spinning on `done.load()=false` because their acceptor's
        // `done.store(true)` was waiting in the queue.  Symptom in production:
        //
        //   WARN acceptor still running after shutdown signal elapsed_ms=300000+
        //
        // The default lane has ~63 workers (acceptor_pool num_threads=64 minus
        // 1 reserved for the blocking lane) and a 256-task queue.  With ≤ 16
        // production conns we never come close to saturating it.  If submit()
        // does return false on queue-full we fall back to single-stream mode
        // like the previous error path.
        if (!acceptor_pool.submit(.{
            .context = @ptrCast(acceptor_ctx),
            .callback = runStreamAcceptorLoop,
        })) {
            log.warn("Failed to start stream acceptor (queue full), single-stream mode", &.{});
            // The acceptor's ref will never be released because its task
            // never starts.  Drop it here so the deferred owner release
            // brings the refcount to zero and frees the heap struct.
            acceptor_ctx.release();
            handleFirstStreamOwner(@ptrCast(first_ctx));
            return;
        }
        first_ctx.acceptor_submitted = true;
    }

    // ── Phase 3: First stream query loop (bounded detached owner) ──────────
    //
    // CANARY: REQ=REQ-QUIC-HC-054; FEATURE="QUIC High-Concurrency Requests"; ASPECT=CooperativeFirstStreams; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
    if (!env_config.quic_stream_multiplexing_enabled and env_config.quic_cooperative_first_streams_enabled) {
        if (g_first_stream_scheduler) |scheduler| {
            // CONTRACT (REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME): branch on the
            // returned bool, NOT on a post-submit deref of `first_ctx` — once
            // `submit` returns true the scheduler owns the ctx and a worker may
            // already have freed it. Reading `first_ctx.cooperative_scheduler`
            // here was the publish-before-return use-after-free.
            if (scheduler.submit(first_ctx)) {
                return;
            }
            log.warn("Failed to schedule cooperative first-stream owner, falling back to detached owner", &.{});
        }
    }

    // REQ-QUIC-HC-011 follow-up: the first stream must leave the connection
    // admission thread after HELLO, but unbounded per-first-stream detached
    // threads starve endpoint polling at 512+ fanout. Use the existing global
    // stream throttle as admission control, detach only while the detached-owner
    // gate has capacity, and route overflow owners through the shared stream
    // pool. Extra multiplexed streams still use the shared stream pool.
    if (g_stream_throttle.acquire(10 * std.time.ns_per_ms)) |_| {
        first_ctx.stream_throttle_acquired = true;
        if (g_first_stream_detach_gate.tryAcquire()) {
            first_ctx.detached_first_stream_acquired = true;
            const first_arg: *anyopaque = @ptrCast(first_ctx);
            const first_thread = std.Thread.spawn(
                .{ .stack_size = first_stream_owner_stack_size },
                handleFirstStreamOwner,
                .{first_arg},
            ) catch |err| {
                first_ctx.detached_first_stream_acquired = false;
                g_first_stream_detach_gate.release();
                log.warn("Failed to spawn first-stream owner, falling back to shared stream pool", &.{
                    Attr.string("error", @errorName(err)),
                });
                if (!stream_pool.submit(.{
                    .context = @ptrCast(first_ctx),
                    .callback = handleFirstStreamOwner,
                })) {
                    log.warn("Failed to submit first-stream owner, running inline", &.{});
                    handleFirstStreamOwner(@ptrCast(first_ctx));
                }
                return;
            };
            first_thread.detach();
        } else {
            log.debug("Detached first-stream owner limit reached, using shared stream pool", &.{
                Attr.int("active_detached", @intCast(g_first_stream_detach_gate.count())),
                Attr.int("max_detached", @intCast(g_first_stream_detach_gate.limit())),
            });
            if (!stream_pool.submit(.{
                .context = @ptrCast(first_ctx),
                .callback = handleFirstStreamOwner,
            })) {
                log.warn("Failed to submit first-stream owner, running inline", &.{});
                handleFirstStreamOwner(@ptrCast(first_ctx));
            }
        }
    } else |_| {
        log.warn("Global stream thread limit reached for first stream, falling back to shared stream pool", &.{
            Attr.int("active_global", @intCast(g_stream_throttle.count())),
            Attr.int("max_global", @intCast(g_stream_throttle.max)),
        });
        if (!stream_pool.submit(.{
            .context = @ptrCast(first_ctx),
            .callback = handleFirstStreamOwner,
        })) {
            log.warn("Failed to submit first-stream owner, running inline", &.{});
            handleFirstStreamOwner(@ptrCast(first_ctx));
        }
    }
    return;
}

/// Resolve the audit logger for the current query context.
///
/// Returns the per-graph audit logger iff the graph has auditing
/// explicitly enabled (i.e. `StorageAdapter.getAuditLogger(graph_name)`
/// returned a non-null logger during graph init).  Returns null when
/// the graph has no per-graph logger — the global fallback is
/// intentionally removed so audit ONLY fires when the specific graph
/// has opted in (user requirement, 2026-04-23).
///
/// Rationale: under 16-way ingest workloads, a global-fallback audit
/// would emit one event per mutation across every graph the server
/// hosts, producing tens of thousands of useless events/sec on graphs
/// the operator never configured for auditing.  Opt-in per graph
/// aligns audit with the other per-graph security features (FLE, TDE,
/// KMS) and drops a measurable write-path overhead on the msft-graph
/// hot path.
fn resolveAuditLogger(state: *const ServerState) ?*audit_mod.AuditLogger {
    const graph_name = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
    const adapter = graph_store.getGlobalAdapter() orelse return null;
    return adapter.getAuditLogger(graph_name);
}

/// Log a query execution audit event — only when the specific graph has
/// auditing enabled (see `resolveAuditLogger`).  Returns before any
/// allocation / clock / event-building work when the graph has no
/// per-graph audit logger, which is the common case on non-security
/// graphs under the msft-graph ingest workload.
///
/// The per-thread tenant_id is already set earlier in the request flow
/// via `audit_mod.setCurrentAuditTenantId`, so we do not pass it
/// explicitly here.
fn auditQueryExecution(state: *const ServerState, query_text: []const u8, is_mutation: bool) void {
    const logger = resolveAuditLogger(state) orelse return;
    const event_type: audit_mod.AuditEventType = if (is_mutation) .data_modification else .data_access;
    logger.logEvent(.{
        .event_type = event_type,
        .resource = query_text,
        .action = if (is_mutation) "MUTATE" else "QUERY",
    }) catch {};
}

/// Sync ServerState.current_graph from the execution session after a program
/// that may contain USE GRAPH statements.  Without this, `state.current_graph`
/// stays null and every downstream consumer (per-graph locking, RLS filtering,
/// PULL materialisation) falls back to DEFAULT_GRAPH_NAME — which is wrong when
/// the session has been switched to a different graph.
fn syncGraphFromSession(state: *ServerState) void {
    const new_graph: ?[]const u8 = if (state.exec_session) |sess| sess.graph else null;

    // If session graph hasn't changed, nothing to do.
    if (state.current_graph) |cur| {
        if (new_graph) |ng| {
            if (std.mem.eql(u8, cur, ng)) return;
        }
    } else if (new_graph == null) {
        return;
    }

    // Free old value and duplicate the new one (state owns its copy).
    if (state.current_graph) |old| state.allocator.free(old);
    state.current_graph = if (new_graph) |ng|
        state.allocator.dupe(u8, ng) catch null
    else
        null;
}

fn updateTxnStateFromProgram(state: *ServerState, program: *const gql_ast.Program) void {
    var has_start: bool = false;
    var has_commit: bool = false;
    var has_rollback: bool = false;

    for (program.statements) |stmt| {
        switch (stmt) {
            .StartTransaction => |st| {
                if (st.body == null) has_start = true;
            },
            .Commit => has_commit = true,
            .Rollback => has_rollback = true,
            else => {},
        }
    }

    if (has_commit or has_rollback) {
        state.in_txn = false;
        state.txn_id = 0;
        return;
    }

    if (has_start) {
        state.in_txn = true;
        if (state.txn_id == 0) {
            state.txn_id = @intCast(compat_milliTimestamp());
        }
    }
}

fn generateSessionId(allocator: std.mem.Allocator) ![]const u8 {
    var entropy: [16]u8 = undefined;
    compat_fillRandom(&entropy);
    const token = std.fmt.bytesToHex(entropy, .lower);
    return std.fmt.allocPrint(allocator, "sess_{s}", .{token});
}

/// Validate federation HELLO using GEODE_CLUSTER_TOKEN.
/// GAP-0490: Both nodes must share the same cluster token.
/// Returns true only if username is "geode-cluster" AND password matches token.
/// SEC-INFRA-03: delegates to the shared cluster_auth validator (constant-time
/// compare) so the dual-token rotation overlap window
/// (GEODE_CLUSTER_TOKEN_PREVIOUS) applies to federation HELLOs too.
// CANARY: REQ=REQ-GAP-0490-FEDERATION-SERVER-AUTH; FEATURE="FederationAuth"; ASPECT=ServerValidation; STATUS=TESTED; OWNER=security; UPDATED=2026-06-10
fn validateFederationAuth(username: []const u8, password: []const u8) bool {
    if (!std.mem.eql(u8, username, "geode-cluster")) return false;
    if (comptime builtin.os.tag == .windows) return false;
    return geode.distributed.cluster_auth.validateClusterToken(password);
}

/// Parse an ALTER USER <name> SET PASSWORD '<pwd>' statement from raw query text.
/// Returns the extracted username and new password, or null if the query doesn't match.
fn parseAlterUserSetPassword(query: []const u8) ?struct { username: []const u8, new_password: []const u8 } {
    // Case-insensitive prefix match: ALTER USER
    var pos: usize = 0;
    const q = query;
    if (q.len < 30) return null; // minimum: "ALTER USER x SET PASSWORD 'y'"

    // Skip leading whitespace
    while (pos < q.len and (q[pos] == ' ' or q[pos] == '\t')) pos += 1;

    // Match ALTER
    if (pos + 5 > q.len) return null;
    if (!std.ascii.eqlIgnoreCase(q[pos..][0..5], "ALTER")) return null;
    pos += 5;

    // Skip whitespace
    while (pos < q.len and q[pos] == ' ') pos += 1;

    // Match USER
    if (pos + 4 > q.len) return null;
    if (!std.ascii.eqlIgnoreCase(q[pos..][0..4], "USER")) return null;
    pos += 4;

    // Skip whitespace
    while (pos < q.len and q[pos] == ' ') pos += 1;

    // Extract username (until next space)
    const uname_start = pos;
    while (pos < q.len and q[pos] != ' ') pos += 1;
    if (pos == uname_start) return null;
    const username = q[uname_start..pos];

    // Skip whitespace
    while (pos < q.len and q[pos] == ' ') pos += 1;

    // Match SET
    if (pos + 3 > q.len) return null;
    if (!std.ascii.eqlIgnoreCase(q[pos..][0..3], "SET")) return null;
    pos += 3;

    // Skip whitespace
    while (pos < q.len and q[pos] == ' ') pos += 1;

    // Match PASSWORD
    if (pos + 8 > q.len) return null;
    if (!std.ascii.eqlIgnoreCase(q[pos..][0..8], "PASSWORD")) return null;
    pos += 8;

    // Skip whitespace
    while (pos < q.len and q[pos] == ' ') pos += 1;

    // Extract password from single quotes
    if (pos >= q.len or q[pos] != '\'') return null;
    pos += 1; // skip opening quote
    const pwd_start = pos;
    while (pos < q.len and q[pos] != '\'') pos += 1;
    if (pos >= q.len) return null; // no closing quote
    const new_password = q[pwd_start..pos];

    return .{ .username = username, .new_password = new_password };
}

/// Validate a password against the default geodeSecure policy without requiring
/// a SecurityManager instance.  Returns an error message string if the password
/// fails validation, or null if it passes.
/// SECURITY (S4): Fallback policy enforcement when SecurityManager is null.
fn validatePasswordFallback(password: []const u8) ?[]const u8 {
    const policy = geode_auth.PasswordPolicy.geodeSecure();

    if (password.len < policy.min_length) return "Password too short (minimum 20 characters)";
    if (password.len > policy.max_length) return "Password too long (maximum 256 characters)";

    if (policy.require_uppercase) {
        var found = false;
        for (password) |c| {
            if (std.ascii.isUpper(c)) {
                found = true;
                break;
            }
        }
        if (!found) return "Password must contain at least one uppercase letter";
    }

    if (policy.require_lowercase) {
        var found = false;
        for (password) |c| {
            if (std.ascii.isLower(c)) {
                found = true;
                break;
            }
        }
        if (!found) return "Password must contain at least one lowercase letter";
    }

    if (policy.require_digit) {
        var found = false;
        for (password) |c| {
            if (std.ascii.isDigit(c)) {
                found = true;
                break;
            }
        }
        if (!found) return "Password must contain at least one digit";
    }

    if (!policy.allow_spaces) {
        for (password) |c| {
            if (c == ' ') return "Password must not contain spaces";
        }
    }

    if (policy.require_passphrase) {
        var word_count: usize = 0;
        var in_word = false;
        for (password) |c| {
            if (c == ' ') {
                in_word = false;
            } else {
                if (!in_word) word_count += 1;
                in_word = true;
            }
        }
        if (word_count < policy.min_words) return "Password must be a passphrase with at least 3 words";
    }

    return null;
}

/// Handle ALTER USER SET PASSWORD when password reset is required.
/// Updates the user's password, clears the reset flag, and sends a success response.
fn handleAlterUserSetPassword(
    gpa: std.mem.Allocator,
    state: *ServerState,
    stream: *quic_transport.QuicStream,
    username: []const u8,
    new_password: []const u8,
) !void {
    // Verify the user is changing their own password.
    // SECURITY (S9): When authenticated_user is null (auth disabled or session
    // not authenticated), reject password changes -- callers must authenticate
    // before altering any user's password.
    if (state.authenticated_user) |auth_user| {
        if (!std.mem.eql(u8, auth_user, username)) {
            try sendExecuteError(gpa, stream, "42501", "You can only change your own password", &.{}, &.{});
            return;
        }
    } else {
        try sendExecuteError(gpa, stream, "42501", "Authentication required to change passwords", &.{}, &.{});
        return;
    }

    // Validate password against SecurityManager policy BEFORE updating the
    // in-memory store.  Previously, user_mgmt accepted any password (no policy
    // validation), then sm.updatePassword silently failed when the password
    // didn't meet policy — so the change never persisted and reverted on restart.
    if (state.security_manager) |sm| {
        sm.validatePassword(new_password) catch |err| {
            const msg = switch (err) {
                error.PasswordTooShort => "Password too short (minimum 20 characters)",
                error.PasswordTooLong => "Password too long (maximum 256 characters)",
                error.PasswordMissingUppercase => "Password must contain at least one uppercase letter",
                error.PasswordMissingLowercase => "Password must contain at least one lowercase letter",
                error.PasswordMissingDigit => "Password must contain at least one digit",
                error.PasswordContainsSpaces => "Password must not contain spaces",
                error.PasswordNotPassphrase => "Password must be a passphrase with at least 3 words",
                else => "Password does not meet security policy requirements",
            };
            try sendExecuteError(gpa, stream, "28P01", msg, &.{}, &.{});
            return;
        };
    } else {
        // SECURITY (S4): When SecurityManager is null, enforce the same password
        // policy as geodeSecure() to prevent bypassing password requirements.
        if (validatePasswordFallback(new_password)) |msg| {
            try sendExecuteError(gpa, stream, "28P01", msg, &.{}, &.{});
            return;
        }
    }

    user_mgmt.updateUserPassword(gpa, username, new_password) catch |err| {
        const msg = switch (err) {
            error.PasswordReuse => "New password must not match the current password",
            else => "Failed to update password",
        };
        try sendExecuteError(gpa, stream, "28P01", msg, &.{}, &.{});
        return;
    };

    // Persist the password change to the auth graph store so it survives restarts.
    // The in-memory user_mgmt store is ephemeral; the SecurityManager's callback
    // writes the new hash to the persistent GraphStore via AuthGraphManager.
    if (state.security_manager) |sm| {
        if (sm.getUserIdByUsername(username)) |user_id| {
            sm.updatePassword(user_id, new_password) catch |err| {
                log.warn("Failed to persist password change to auth graph", &.{
                    Attr.string("username", username),
                    Attr.string("error", @errorName(err)),
                });
            };
        }
    }

    state.password_reset_required = false;

    // Send success response as a status-only execution result (no payload).
    // Sending a page payload would cause the REPL to issue a PULL request,
    // which fails with "no active result set" since no query was executed.
    const status = try proto_util.buildStatus(gpa, "00000", &.{});
    const resp = schema.ExecutionResponse{
        .status = status,
        .payload = null,
    };
    try sendQuicMessage(gpa, stream, .{ .execute = resp });
}

fn invalidateAuthenticatedSession(gpa: std.mem.Allocator, state: *ServerState) void {
    state.resetResult();
    // R3: delegate to the stream-close teardown hook so both code paths
    // go through the same orphan-txn rollback logic (lock ordering,
    // txn_id stamping, audit log).
    const store = graph_store.getGlobalStore(gpa);
    state.tearDownForStreamClose(store) catch |err| {
        log.warn("Failed to rollback invalidated session transaction", &.{Attr.string("error", @errorName(err))});
        // Safety: ensure the flags are cleared even if the hook errored
        // out partway through.
        state.in_txn = false;
        state.txn_id = 0;
    };
    state.current_user_id = null;
    if (state.authenticated_user) |user| {
        gpa.free(user);
        state.authenticated_user = null;
    }
    if (state.authenticated_password) |password| {
        std.crypto.secureZero(u8, @constCast(password));
        gpa.free(password);
        state.authenticated_password = null;
    }
    state.authenticated_role = null;
    state.authenticated_auth_version = 0;
    state.authenticated_auth_validation_epoch = 0;
    state.password_reset_required = false;
    if (state.fle_user_role) |role| {
        gpa.free(role);
        state.fle_user_role = null;
    }
    fle_integration.setCurrentUserRole(null);
}

fn validateSessionAuth(gpa: std.mem.Allocator, state: *ServerState) !SessionAuthStatus {
    if (!user_mgmt.isAuthEnabled()) return .ok;
    const username = state.authenticated_user orelse return .missing;
    if (state.authenticated_auth_version == 0) return .ok;
    if (try user_mgmt.isSessionAuthCurrentCached(username, state.authenticated_auth_version, &state.authenticated_auth_validation_epoch)) {
        return .ok;
    }
    invalidateAuthenticatedSession(gpa, state);
    return .invalidated;
}

// R2 (2026-04-22): per-request write-lock deadline helpers.

/// Current CLOCK_MONOTONIC nanoseconds.  Used to compute absolute
/// deadlines for `graph_store.acquireGraphWriteLockCancelable`.
fn monoNanosNow() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Default per-request timeout for acquiring the exclusive graph write
/// lock.
///
/// R7 (2026-04-22): raised from 30 s → 120 s.  30 s was too aggressive
/// for the msft-graph 16-worker-on-one-graph ingest workload — once the
/// per-statement critical section plus 16-way FIFO queueing approached
/// the 30 s ceiling, the cascade pattern from the R6 report
/// (`40001: Write lock acquisition timed out` on every worker, immediate
/// serial-mode fallback, HELLO retries) kicked in even though each
/// worker was making forward progress.  120 s gives the same workload
/// ≈ 4 × the budget it actually needs (sustained aggregate ≈ 5 stmts/s
/// × 16 workers × 38-statement chunk ≈ 122 s worst case before R7's
/// 2 × per-op speedup), so normal contended workloads never trip the
/// cancellation path while a genuinely-stuck worker still surfaces
/// within 2 minutes.  Override via `GEODE_GRAPH_WRITE_LOCK_TIMEOUT_MS`.
const default_mutation_write_lock_timeout_ms: u64 = 120_000;

/// Returns the mutation write-lock timeout (in nanoseconds) for the
/// current request.  Pulls the value from the connection's cached
/// `EnvironmentConfig` (set by `GEODE_GRAPH_WRITE_LOCK_TIMEOUT_MS`) when
/// available; falls back to `default_mutation_write_lock_timeout_ms`.
fn mutationWriteLockTimeoutNs(state: *const ServerState) u64 {
    if (state.shared_conn) |shared_ptr| {
        const shared: *SharedConnState = @ptrCast(@alignCast(shared_ptr));
        if (shared.env_config) |ec| {
            return ec.graph_write_lock_timeout_ms * std.time.ns_per_ms;
        }
    }
    return default_mutation_write_lock_timeout_ms * std.time.ns_per_ms;
}

/// GAP-0900 (live-routing): policy-aware "does a REAL RLS policy exist?" gate
/// used by the node-scan streaming routing. Returns true only when an
/// authenticated session is present AND at least one RLS policy is installed in
/// ANY of the active engines. The server registers EMPTY (default-allow) RLS
/// engines at startup, so the previous `getGlobalRLSFilterEngine() != null`
/// test was true for every authenticated session even with no policy — which
/// disabled engine-side streaming for all authenticated reads and forced them
/// onto the O(graph) snapshot clone. We check BOTH the server-side label
/// engine (`rls_filter`, the one the handler actually applies) AND the shared
/// `rls_types`/expression engines (`execution.activeRlsPoliciesConfigured`), so
/// a best-effort sync failure between the two engines can never let a streamed
/// read bypass an installed policy. When any real policy exists, streaming is
/// disabled and the snapshot path runs `passesRLSFilter` per candidate node.
fn authenticatedReadNeedsRlsSnapshot(state: *const ServerState) bool {
    if (state.authenticated_user == null) return false;
    if (rls_filter.getGlobalRLSFilterEngine()) |engine| {
        if (engine.policyCount() != 0) return true;
    }
    return execution.activeRlsPoliciesConfigured();
}

/// GAP-0900 (scan-no-clone): true iff this read will be served by the
/// engine-backed `node_scan_stream` path in the `.rows` arm, so the handler
/// can skip the O(graph) `QueryReadSession` deep-clone. The conditions are a
/// strict subset of what the `.rows` arm checks before calling
/// `node_scan_stream.prepare`, guaranteeing we never skip the snapshot for a
/// query that then falls through to the snapshot-consuming legacy executor:
///   - a storage adapter must exist (the streaming path returns no rows
///     without one; the legacy fallback needs the snapshot in that case);
///   - the query must be `.rows` shaped with a single `.Query` target;
///   - no RLS engine active for an authenticated user (RLS reads must keep the
///     snapshot path so `passesRLSFilter` runs per candidate node);
///   - no effectful preamble (multi-statement programs run the full executor);
///   - the target must be streaming-eligible per `node_scan_stream.isEligible`
///     (bounded `MATCH (n:Label) RETURN n [LIMIT k]`, no WHERE/ORDER/etc.).
/// GAP-0900 (live-routing): true iff any effectful preamble does NOT block the
/// node-scan streaming fast path for `query_graph_name`. A fully empty preamble
/// is fine. A preamble consisting solely of graph selectors that all name the
/// graph the stream will scan (`query_graph_name`) is ALSO fine: re-selecting
/// the already-bound target graph is a no-op for the streamed query, so skipping
/// its execution drops no observable side effect and the target still scans the
/// intended graph. Any other effectful preamble (a different graph, a SET, DDL,
/// a braced transaction body, ...) blocks streaming — the full executor must run
/// so those side effects take hold and the target sees them. This is the read
/// analogue of GAP-0894's `<graph-selector>; <MERGE>` write fast path, and is
/// the 2-statement shape the CLI `-g` flag and pooled `database/sql` drivers
/// emit on EVERY query (without this, every such scan paid the O(graph) clone).
fn preamblePermitsStreaming(analysis: *const query_traits.ProgramAnalysis, query_graph_name: []const u8) bool {
    if (!analysis.has_effectful_preamble) return true;
    const selector = analysis.preamble_graph_selector orelse return false;
    return std.mem.eql(u8, selector, query_graph_name);
}

fn readWillStreamEngineSide(
    state: *const ServerState,
    analysis: *const query_traits.ProgramAnalysis,
    query_graph_name: []const u8,
) bool {
    if (graph_store.getGlobalAdapter() == null) return false;
    if (analysis.kind != .rows) return false;
    // GAP-0900 (live-routing fix): use the POLICY-AWARE RLS gate, not the
    // coarse "any engine registered" test. The server installs EMPTY (default-
    // allow) RLS engines at startup, so `getGlobalRLSFilterEngine() != null`
    // was true for EVERY authenticated session even with no policy — which
    // disabled engine-side streaming for all authenticated reads and forced
    // them onto the O(graph) snapshot clone (the measured live slow path: a
    // `LIMIT 5` projection on 200K nodes took ~8s). Only a REAL installed
    // policy requires the snapshot path so RLS runs per candidate node; this
    // matches the contract the count and point-read fast paths already use.
    if (authenticatedReadNeedsRlsSnapshot(state)) return false;
    if (!preamblePermitsStreaming(analysis, query_graph_name)) return false;
    const target = analysis.target orelse return false;
    if (target.* != .Query) return false;
    return node_scan_stream.isEligible(&target.Query);
}

/// GAP-0902: true iff this read will be served ENGINE-DIRECT (no whole-graph
/// snapshot clone) by EITHER the `node_scan_stream` fast path OR the
/// storage-native planned-read path (single-chain ORDER BY / DISTINCT /
/// aggregate / WHERE-count reads). When true the handler skips
/// `snapshotUnderReadLock` and lets `executeProgramWithContext` read the live
/// store engine-direct via the fast paths / `planned_read_runtime` — which read
/// every live node straight from the engine (O(result)/O(scanned) cheap-property
/// reads, NEVER the cache map) instead of materializing an O(all-nodes)-resident
/// snapshot (81 GB at 14.27M, the RSS-balloon source under the bounded cache).
///
/// SAFETY: gated by the SAME RLS / preamble / adapter checks as the streaming
/// path. RLS-evaluating reads, multi-chain traversal, and any shape that is NOT
/// storage-native keep the snapshot (so per-candidate RLS / the legacy executor
/// still see a consistent clone). `isStorageNativeReadShape` is exactly the
/// predicate that makes `executeIfSupported` run storage_native (engine-direct)
/// and NEVER fall back to the legacy resident-only executor, so a skipped
/// snapshot can never strand such a read on the resident-only path.
fn readServedEngineDirect(
    state: *const ServerState,
    analysis: *const query_traits.ProgramAnalysis,
    query_graph_name: []const u8,
) bool {
    if (graph_store.getGlobalAdapter() == null) return false;
    if (analysis.kind != .rows) return false;
    if (authenticatedReadNeedsRlsSnapshot(state)) return false;
    if (!preamblePermitsStreaming(analysis, query_graph_name)) return false;
    const target = analysis.target orelse return false;
    if (target.* != .Query) return false;
    return node_scan_stream.isEligible(&target.Query) or
        planned_read_runtime.isStorageNativeReadShape(&target.Query);
}

fn handleClientMessage(
    gpa: std.mem.Allocator,
    state: *ServerState,
    stream: *quic_transport.QuicStream,
    msg: schema.QuicClientMessage,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    peer_ip: []const u8,
) !void {
    switch (msg) {
        .hello => |hello_req| {
            var caps = std.ArrayList([]const u8).initCapacity(gpa, 3) catch return error.OutOfMemory;
            try caps.append(gpa, try gpa.dupe(u8, "QUIC"));
            try caps.append(gpa, try gpa.dupe(u8, "TLS1.3"));
            try caps.append(gpa, try gpa.dupe(u8, "PROTOBUF"));

            // S6: Per-IP rate limiting — reject locked-out IPs before attempting authentication.
            // CANARY: REQ=REQ-SEC-RATE-LIMIT-006; FEATURE="AuthRateLimiting"; ASPECT=HelloCheck; STATUS=TESTED; TEST=geodetestlab/specs/authn_rate_limiter.yml; OWNER=security; UPDATED=2026-06-11
            if (g_auth_rate_limiter) |limiter| {
                if (limiter.isLocked(peer_ip)) {
                    log.warn("Authentication rate limit exceeded", &.{
                        Attr.string("peer_ip", peer_ip),
                    });
                    const resp = schema.QuicServerMessage{ .hello = .{
                        .success = false,
                        .session_id = try gpa.dupe(u8, ""),
                        .error_message = try gpa.dupe(u8, "Too many failed authentication attempts. Please try again later."),
                        .capabilities = caps,
                    } };
                    try sendQuicMessage(gpa, stream, resp);
                    return;
                }
            }

            // GAP-0490: Federation inter-node authentication via cluster token — fast-path
            // Must be checked BEFORE normal user auth to allow federation when auth is enabled.
            if (validateFederationAuth(hello_req.username, hello_req.password)) {
                log.info("Federation node authenticated via cluster token", &.{
                    Attr.string("client", hello_req.client_name),
                });
                // Grant federation-level session: store identity, grant ReadWrite role
                if (state.authenticated_user) |u| gpa.free(u);
                if (state.authenticated_password) |p| {
                    std.crypto.secureZero(u8, @constCast(p)); // SECURITY (S7): Zero plaintext password before freeing
                    gpa.free(p);
                }
                state.authenticated_user = try gpa.dupe(u8, hello_req.username);
                state.authenticated_role = @intFromEnum(user_mgmt.Role.ReadWrite);
                state.authenticated_auth_version = 0;
                state.authenticated_auth_validation_epoch = user_mgmt.authInvalidationEpoch();
                // GAP-0293: Zero plaintext password — federation auth complete, no need to retain
                state.authenticated_password = null;
                // GAP-0490: mTLS enforcement for federation connections (opportunistic — log only)
                if (g_mtls_provider) |provider| {
                    _ = provider;
                    log.info("Federation mTLS provider configured; certificate validation deferred to TLS layer", &.{});
                }
            } else if (user_mgmt.isAuthEnabled()) {
                if (hello_req.username.len == 0 or hello_req.password.len == 0) {
                    // S6: Record failure for empty credentials (still counts as a failed attempt).
                    if (g_auth_rate_limiter) |limiter| limiter.recordFailure(peer_ip);
                    const resp = schema.QuicServerMessage{ .hello = .{
                        .success = false,
                        .session_id = try gpa.dupe(u8, ""),
                        .error_message = try gpa.dupe(u8, "Authentication required"),
                        .capabilities = caps,
                    } };
                    try sendQuicMessage(gpa, stream, resp);
                    return;
                }

                const auth_result = user_mgmt.authenticate(hello_req.username, hello_req.password) catch {
                    // S6: Record failure for bad credentials.
                    if (g_auth_rate_limiter) |limiter| limiter.recordFailure(peer_ip);
                    const resp = schema.QuicServerMessage{ .hello = .{
                        .success = false,
                        .session_id = try gpa.dupe(u8, ""),
                        .error_message = try gpa.dupe(u8, "Authentication failed"),
                        .capabilities = caps,
                    } };
                    try sendQuicMessage(gpa, stream, resp);
                    return;
                };

                // S6: Successful authentication — reset failure counter for this IP.
                if (g_auth_rate_limiter) |limiter| limiter.recordSuccess(peer_ip);

                if (state.authenticated_user) |u| gpa.free(u);
                if (state.authenticated_password) |p| {
                    std.crypto.secureZero(u8, @constCast(p)); // SECURITY (S7): Zero plaintext password before freeing
                    gpa.free(p);
                }
                state.authenticated_user = try gpa.dupe(u8, hello_req.username);
                state.authenticated_role = @intFromEnum(auth_result.role);
                state.authenticated_auth_version = auth_result.auth_version;
                state.authenticated_auth_validation_epoch = user_mgmt.authInvalidationEpoch();
                state.password_reset_required = auth_result.password_reset_required;
                // GAP-0293: Zero plaintext password immediately after successful auth.
                // Authentication has already completed — no need to retain password in memory.
                state.authenticated_password = null;
            }

            if (hello_req.tenant_id) |tenant| {
                if (state.session_config == null) {
                    state.session_config = geode.server_state.SessionConfiguration.init(gpa);
                }
                if (state.session_config.?.tenant_id) |old| {
                    gpa.free(old);
                }
                state.session_config.?.tenant_id = try gpa.dupe(u8, tenant);
            }

            // GAP-0281: Set per-thread FLE tenant_id from session config for encryption namespace isolation.
            fle_integration.setCurrentTenantId(if (state.session_config) |cfg| cfg.tenant_id else null);
            // GAP-0282: Set per-thread audit tenant_id so all audit events carry tenant context.
            audit_mod.setCurrentAuditTenantId(if (state.session_config) |cfg| cfg.tenant_id else null);

            // GAP-0271: Set FLE role from HELLO request with injection validation.
            // Always reset role on new connection to prevent stale role leakage.
            if (state.fle_user_role) |old_role| {
                gpa.free(old_role);
                state.fle_user_role = null;
            }
            if (hello_req.role) |requested_role| {
                if (requested_role.len > 0) {
                    // Validate role: only [a-zA-Z0-9_-] allowed — reject semicolons, commas, wildcards
                    var role_valid = true;
                    for (requested_role) |c| {
                        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                            role_valid = false;
                            break;
                        }
                    }
                    if (role_valid) {
                        state.fle_user_role = try gpa.dupe(u8, requested_role);
                        fle_integration.setCurrentUserRole(state.fle_user_role);
                    } else {
                        log.warn("Rejected invalid FLE role: contains illegal characters", &.{});
                        fle_integration.setCurrentUserRole(null);
                    }
                } else {
                    fle_integration.setCurrentUserRole(null);
                }
            } else {
                fle_integration.setCurrentUserRole(null);
            }

            // CANARY: REQ=REQ-DSN-GRAPH-BIND-003; FEATURE="DSNGraphBinding"; ASPECT=QuicGraphResolution; STATUS=TESTED; TEST=tests/test_gap0514_quic_handler.zig; OWNER=transport; UPDATED=2026-06-11
            // Resolve graph from HELLO request — validate, auto-create, bind session
            var resolved_graph: ?[]const u8 = null;
            if (hello_req.graph) |requested_graph| {
                if (requested_graph.len > 0) {
                    // Validate graph name: max 128 chars, alphanumeric + underscore only
                    if (requested_graph.len > 128) {
                        const resp = schema.QuicServerMessage{ .hello = .{
                            .success = false,
                            .session_id = try gpa.dupe(u8, ""),
                            .error_message = try gpa.dupe(u8, "Invalid graph name: too long (max 128 characters)"),
                            .capabilities = caps,
                        } };
                        try sendQuicMessage(gpa, stream, resp);
                        return;
                    }
                    for (requested_graph) |c| {
                        if (!std.ascii.isAlphanumeric(c) and c != '_') {
                            const resp = schema.QuicServerMessage{ .hello = .{
                                .success = false,
                                .session_id = try gpa.dupe(u8, ""),
                                .error_message = try gpa.dupe(u8, "Invalid graph name: must contain only alphanumeric characters and underscores"),
                                .capabilities = caps,
                            } };
                            try sendQuicMessage(gpa, stream, resp);
                            return;
                        }
                    }
                    const store = graph_store.getGlobalStore(gpa);
                    const cat = try execution.ensureCatalogInstance(gpa);

                    const in_store = store.graphExists(requested_graph);
                    const in_catalog = cat.hasGraph(requested_graph);

                    if (in_store or in_catalog) {
                        // GAP-0283: Graph-scoped RBAC authorization check before binding.
                        // Admin bypass: admins always have access to all graphs.
                        // If RBAC policy has graph-specific assignments, check them.
                        // Fall back to user's global role (backward compatible).
                        // CANARY: REQ=REQ-MULTI-GRAPH-RBAC-WIRE-002; FEATURE="GraphRBACEnforcement"; ASPECT=QuicGraphAuth; STATUS=TESTED; TEST=tests/test_gap0514_quic_handler.zig; OWNER=security; UPDATED=2026-06-11
                        const rbac_allowed = blk: {
                            if (!user_mgmt.isAuthEnabled()) break :blk true; // No auth = allow
                            const role_val = state.authenticated_role;
                            if (role_val) |r| {
                                const role = @as(user_mgmt.Role, @enumFromInt(r));
                                if (role == .Admin) break :blk true; // Admin bypass
                            }
                            // Check graph RBAC policy if available
                            if (multi_graph_security.getGlobalPolicy()) |rbac| {
                                // Resolve user_id from username for RBAC lookup
                                if (state.authenticated_user) |username| {
                                    const uid = std.hash.Wyhash.hash(0, username);
                                    // Check if user has any graph-specific permission (read access suffices for binding)
                                    if (rbac.hasPermission(uid, requested_graph, "graph", .read)) break :blk true;
                                    // If RBAC has no entry for this user+graph, fall through to global role
                                    const key = multi_graph_security.GraphRoleKey.init(uid, requested_graph);
                                    if (rbac.graph_user_roles.get(key)) |_| {
                                        // Explicit graph assignment exists but no read permission via role.
                                        // A per-graph READ grant (GRANT READ ON GRAPH) widens access here.
                                        if (rbac.hasGraphGrant(uid, requested_graph, 0)) {
                                            log.info("bind permitted by per-graph READ grant", &.{
                                                Attr.string("graph", requested_graph),
                                                Attr.string("user", username),
                                            });
                                            break :blk true;
                                        }
                                        // Explicit graph assignment exists but no read permission — deny
                                        break :blk false;
                                    }
                                }
                            }
                            // No graph-specific RBAC policy or no explicit denial — allow based on global role
                            break :blk true;
                        };

                        if (!rbac_allowed) {
                            const resp = schema.QuicServerMessage{ .hello = .{
                                .success = false,
                                .session_id = try gpa.dupe(u8, ""),
                                .error_message = try gpa.dupe(u8, "Access denied: insufficient permissions for graph"),
                                .capabilities = caps,
                            } };
                            try sendQuicMessage(gpa, stream, resp);
                            return;
                        }

                        // Graph exists — bind session to it
                        if (state.exec_session) |*sess| {
                            if (sess.graph) |old| gpa.free(old);
                            sess.graph = try gpa.dupe(u8, requested_graph);
                        }
                        state.graph_bound = true;
                        resolved_graph = requested_graph;
                    } else {
                        // Graph does not exist — check if user can create it
                        const role_val = state.authenticated_role;
                        const can_create = if (role_val) |r| blk: {
                            const role = @as(user_mgmt.Role, @enumFromInt(r));
                            break :blk role == .Admin or role == .ReadWrite;
                        } else !user_mgmt.isAuthEnabled(); // No auth = allow

                        if (can_create) auto_create_done: {
                            _ = store.createGraph(requested_graph) catch |err| {
                                // dsn_graph_binding.yml defense-in-depth
                                // (2026-05-24): createGraph errored but the
                                // post-condition (graph exists) may already
                                // be satisfied — e.g. a CREATE GRAPH DDL on
                                // the SAME server registered the graph in
                                // the catalog between this connection's
                                // earlier pre-check (line 2911-2912) and
                                // this auto-create, leaving createGraph to
                                // race with the adapter's hash put.  When
                                // the graph is now visible to either store
                                // or catalog, the user's goal is achieved;
                                // bind to it instead of bouncing the
                                // client with "Failed to create graph".
                                if (store.graphExists(requested_graph) or cat.hasGraph(requested_graph)) {
                                    log.warn("createGraph errored but graph is present; binding instead", &.{
                                        Attr.string("graph", requested_graph),
                                        Attr.string("error", @errorName(err)),
                                    });
                                    if (state.exec_session) |*sess| {
                                        if (sess.graph) |old| gpa.free(old);
                                        sess.graph = try gpa.dupe(u8, requested_graph);
                                    }
                                    state.graph_bound = true;
                                    resolved_graph = requested_graph;
                                    break :auto_create_done;
                                }
                                log.err("Graph auto-creation failed", &.{
                                    Attr.string("graph", requested_graph),
                                    Attr.string("error", @errorName(err)),
                                });
                                const resp = schema.QuicServerMessage{ .hello = .{
                                    .success = false,
                                    .session_id = try gpa.dupe(u8, ""),
                                    .error_message = try gpa.dupe(u8, "Failed to create graph"),
                                    .capabilities = caps,
                                } };
                                try sendQuicMessage(gpa, stream, resp);
                                return;
                            };
                            const uuid = graph_store.GraphStore.getGraphUuid(requested_graph) orelse {
                                const resp = schema.QuicServerMessage{ .hello = .{
                                    .success = false,
                                    .session_id = try gpa.dupe(u8, ""),
                                    .error_message = try gpa.dupe(u8, "Graph created without persistent UUID"),
                                    .capabilities = caps,
                                } };
                                try sendQuicMessage(gpa, stream, resp);
                                return;
                            };
                            cat.addGraphWithUuid(requested_graph, uuid) catch |err| switch (err) {
                                // dsn_graph_binding.yml race fix (2026-05-23):
                                // another connection won the race to register
                                // this graph in the catalog between our
                                // `cat.hasGraph` pre-check (line 2912) and
                                // this add.  The graph IS present — proceed
                                // to bind.  Pre-fix we'd drop the graph the
                                // race winner just created, then surface
                                // "Failed to persist graph metadata" to the
                                // client and leave the catalog inconsistent
                                // with the store.
                                error.GraphAlreadyExists => {},
                                else => {
                                    store.dropGraph(requested_graph) catch {};
                                    log.err("Failed to persist auto-created graph in catalog", &.{
                                        Attr.string("graph", requested_graph),
                                        Attr.string("error", @errorName(err)),
                                    });
                                    const resp = schema.QuicServerMessage{ .hello = .{
                                        .success = false,
                                        .session_id = try gpa.dupe(u8, ""),
                                        .error_message = try gpa.dupe(u8, "Failed to persist graph metadata"),
                                        .capabilities = caps,
                                    } };
                                    try sendQuicMessage(gpa, stream, resp);
                                    return;
                                },
                            };

                            if (state.exec_session) |*sess| {
                                if (sess.graph) |old| gpa.free(old);
                                sess.graph = try gpa.dupe(u8, requested_graph);
                            }
                            state.graph_bound = true;
                            resolved_graph = requested_graph;
                        } else {
                            // User lacks permission to create graph
                            const resp = schema.QuicServerMessage{ .hello = .{
                                .success = false,
                                .session_id = try gpa.dupe(u8, ""),
                                .error_message = try gpa.dupe(u8, "Graph does not exist and user lacks permission to create it"),
                                .capabilities = caps,
                            } };
                            try sendQuicMessage(gpa, stream, resp);
                            return;
                        }
                    }
                }
            }

            // Sync ServerState.current_graph from exec_session so that
            // per-graph locking, RLS, and PULL use the correct graph.
            syncGraphFromSession(state);

            const session_id = try generateSessionId(gpa);
            const resp = schema.QuicServerMessage{ .hello = .{
                .success = true,
                .session_id = session_id,
                .error_message = try gpa.dupe(u8, ""),
                .capabilities = caps,
                .password_reset_required = state.password_reset_required,
                .graph = if (resolved_graph) |g| try gpa.dupe(u8, g) else null,
            } };
            try sendQuicMessage(gpa, stream, resp);
        },
        .execute => |exec_req| {
            log.debug("PROTOBUF .execute received", &.{
                Attr.int("query_len", @intCast(exec_req.query.len)),
            });
            const first_stream_prepare_start_ns = monoNsFromHandler();

            state.resetResult();

            switch (try validateSessionAuth(gpa, state)) {
                .ok => {},
                .missing => {
                    try sendExecuteError(gpa, stream, "28000", "Authentication required", &.{}, &.{});
                    return;
                },
                .invalidated => {
                    try sendExecuteError(gpa, stream, "28000", "Session invalidated due to credential or role change", &.{}, &.{});
                    return;
                },
            }

            // Handle ALTER USER SET PASSWORD — intercept before GQL parser since
            // ALTER USER is not part of GQL syntax. Works both during forced
            // password reset and for normal password changes.
            {
                const trimmed = std.mem.trim(u8, exec_req.query, " \t\r\n");
                if (parseAlterUserSetPassword(trimmed)) |parsed| {
                    try handleAlterUserSetPassword(gpa, state, stream, parsed.username, parsed.new_password);
                    return;
                }
            }

            // Block all other queries when password reset is required
            if (state.password_reset_required) {
                try sendExecuteError(gpa, stream, "08P01", "Password reset required. Change password with: ALTER USER <username> SET PASSWORD '<new_password>'", &.{}, &.{});
                return;
            }

            const bindings = proto_util.parseParams(gpa, exec_req.params.items) catch |err| {
                const err_msg = @errorName(err);
                try sendExecuteError(gpa, stream, "22023", err_msg, &.{}, &.{});
                return;
            };
            defer proto_util.freeParamBindings(gpa, bindings);

            const order_keys_expr = server_flags.getOrderKeysExpr();
            const parse_opts = geode.ParseOptions{
                .ident_order_only = !order_keys_expr,
                .forbid_orderby_calls = !order_keys_expr,
            };

            var normalized = try query_traits.normalizeExplainCalibrated(gpa, exec_req.query);
            defer normalized.deinit(gpa);

            const query_text = normalized.text;
            if (state.query_text) |qt| gpa.free(qt);
            state.query_text = try gpa.dupe(u8, query_text);

            // Wire shared AST cache into parse hot path (Issue #444)
            // CANARY: REQ=REQ-PERF-AST-CACHE-004; FEATURE="SharedASTCache"; ASPECT=ParseHotPathWiring; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
            var ast_cache_handle: ?query_ast_cache.AstHandle = null;
            var owned_parse_result: geode.ParseResult = undefined;
            var owns_parse_result: bool = false;
            defer {
                if (ast_cache_handle) |*h| h.release();
                if (owns_parse_result) owned_parse_result.deinit();
            }

            const parse_result: *const geode.ParseResult = parse_blk: {
                // Try shared AST cache first for cross-connection reuse
                if (state.query_ast_cache) |cache_ptr| {
                    const cache: *query_ast_cache.SharedAstCache = @ptrCast(@alignCast(cache_ptr));
                    switch (try cache.getOrParse(query_text, parse_opts)) {
                        .Err => |err_info| {
                            const err_msg = if (err_info.has_double_dash_comment)
                                diagnostics.defaultMessage(.GB02CommentDisabled)
                            else
                                err_info.msg;
                            try sendExecuteError(gpa, stream, "42000", err_msg, &.{}, &.{});
                            return;
                        },
                        .Ok => |handle| {
                            ast_cache_handle = handle;
                            break :parse_blk handle.parse_result;
                        },
                    }
                }
                // Fallback: parse directly when no cache is configured
                switch (try geode.parseGqlOutcome(query_text, gpa, parse_opts)) {
                    .Err => |err_info| {
                        const err_msg = if (err_info.has_double_dash_comment)
                            diagnostics.defaultMessage(.GB02CommentDisabled)
                        else
                            err_info.msg;
                        try sendExecuteError(gpa, stream, "42000", err_msg, &.{}, &.{});
                        return;
                    },
                    .Ok => |pr| {
                        owned_parse_result = pr;
                        owns_parse_result = true;
                        break :parse_blk &owned_parse_result;
                    },
                }
            };

            if (parse_result.has_double_dash_comment) {
                try sendExecuteError(gpa, stream, "42000", diagnostics.defaultMessage(.GB02CommentDisabled), &.{}, &.{});
                return;
            }

            // #830: a multi-statement program containing BEGIN/START TRANSACTION
            // followed by mutations followed by ROLLBACK was silently committing
            // the mutations.  The execute path doesn't honor BEGIN/COMMIT/ROLLBACK
            // as inline statements -- those flow only through the dedicated
            // .begin/.commit/.rollback QUIC message types.  Detect the pattern
            // and reject it loudly so the user sees the problem instead of
            // discovering committed-then-rolled-back data later.
            blk_txn_rollback_check: {
                var saw_begin = false;
                var saw_mutation_after_begin = false;
                var saw_rollback = false;
                for (parse_result.program.statements) |stmt| {
                    switch (stmt) {
                        .StartTransaction => saw_begin = true,
                        .Rollback => {
                            if (saw_begin and saw_mutation_after_begin) {
                                saw_rollback = true;
                                break;
                            }
                        },
                        .Commit => {
                            // Commit resets the window; further BEGIN starts a new one.
                            saw_begin = false;
                            saw_mutation_after_begin = false;
                        },
                        .Create, .Insert, .Merge, .Delete => {
                            if (saw_begin) saw_mutation_after_begin = true;
                        },
                        else => {},
                    }
                }
                if (!saw_rollback) break :blk_txn_rollback_check;
                try sendExecuteError(
                    gpa,
                    stream,
                    "25001",
                    "multi-statement program contains BEGIN ... ROLLBACK with mutations; this batch cannot honor ROLLBACK semantics. Send BEGIN, the mutations, and ROLLBACK as separate query messages (the CLI does this automatically for single-statement-per-message workflows), or restructure the script to avoid the BEGIN...ROLLBACK pattern in one batch.",
                    &.{},
                    &.{},
                );
                return;
            }

            const analysis = query_traits.analyzeProgram(&parse_result.program);
            var traits = analysis.traits;
            const ordered = traits.ordered;
            const distinct = traits.distinct;
            const heur_index = traits.has_where_eq or traits.has_filter_eq;
            const program_is_mutating = isMutatingProgram(&parse_result.program);

            const role = if (state.authenticated_role) |role_u8|
                @as(user_mgmt.Role, @enumFromInt(role_u8))
            else
                null;

            const catalog = try execution.ensureCatalogInstance(gpa);

            // Detect index-seek for EXPLAIN: check if query's node pattern
            // matches a catalog index (label + property equality)
            if (analysis.kind == .explain) {
                if (analysis.target) |target| {
                    if (target.* == .Query) {
                        const q = target.Query;
                        if (q.match.chains.len > 0) {
                            const head_opt = q.match.chains[0].head;
                            if (head_opt) |head| {
                                if (head.labels.len > 0) {
                                    const label = head.labels[0];
                                    // Check inline properties
                                    if (head.props) |props| {
                                        if (props.len > 0) {
                                            const prop_name = props[0].key;
                                            catalog.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
                                            defer catalog.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
                                            var idx_iter = catalog.indexes.valueIterator();
                                            while (idx_iter.next()) |info| {
                                                if (std.mem.eql(u8, info.table_name, label) and
                                                    info.columns.len > 0 and
                                                    std.mem.eql(u8, info.columns[0], prop_name))
                                                {
                                                    traits.has_index_seek = true;
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                    // Check WHERE clause for equality on indexed property
                                    if (!traits.has_index_seek) {
                                        if (q.where_clause) |where_expr| {
                                            if (head.name) |vn| {
                                                catalog.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
                                                defer catalog.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
                                                traits.has_index_seek = whereHasIndexedEq(where_expr, vn, label, catalog);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Issue #452/#460: Consult shared optimizer for plan hints
            // CANARY: REQ=REQ-PERF-SHARED-OPT-001; FEATURE="SharedQueryOptimizer"; ASPECT=HintExtraction; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
            var plan_handle: ?query_plan_cache.SharedPlanHandle = null;
            var optimizer_hints_storage: query_plan_cache.OptimizerHints = .{};
            defer if (plan_handle) |*h| h.release();

            // CANARY: REQ=REQ-QUIC-HC-166; FEATURE="High-Concurrency Query Cache"; ASPECT=ReadOnlyPlanCacheAdmission; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=engine; UPDATED=2026-06-10
            //
            // Mutation traffic often embeds literal worker/sequence values, so
            // routing it through the cross-connection plan cache creates many
            // one-shot misses and evictions while providing no execution hint
            // benefit to the write fast paths. Keep the shared optimizer on
            // read/profile/explain queries only.
            if (!program_is_mutating) {
                if (state.query_optimizer) |shared_opt| {
                    const store = graph_store.getGlobalStore(gpa);
                    const store_stats = query_plan_cache.StoreStats{
                        .node_count = @intCast(store.getNodeCount()),
                        .edge_count = @intCast(store.getEdgeCount()),
                    };
                    plan_handle = shared_opt.optimizeQuery(query_text, &parse_result.program, store_stats) catch null;
                    if (plan_handle) |*h| {
                        optimizer_hints_storage = h.toHints();
                    }
                }
            }

            // CANARY: REQ=REQ-GPS-DERIVE-002; FEATURE="GPS Principal Derivation"; ASPECT=QuicHandlerWiring; STATUS=TESTED; TEST=tests/test_gps_principal_propagation.zig; OWNER=security; UPDATED=2026-05-20
            // Phase 2: delegate to derivePrincipal() so all transport sites share
            // the same field-population logic. auth_version threads through for
            // cache-invalidation correctness (role/active/password changes).
            //
            // CANARY: REQ=REQ-GPS-WIRE-001; FEATURE="GPS Wire Principal Forwarding"; ASPECT=ServerUnpack; STATUS=TESTED; TEST=tests/test_gps_mcp_wire.zig; OWNER=security; UPDATED=2026-06-10
            // GPS Phase 7 Tasks 7-5/7-6: if the incoming ExecuteRequest carries
            // a principal_envelope_bytes blob (field 4), deserialize it and use
            // the forwarded identity instead of the connection-level Principal.
            // This handles the distributed-coordinator → shard-worker path (Task
            // 7-6). The MCP send-side gap (Task 7-5) is documented below.
            //
            // Security invariant: the envelope is ONLY trusted when the sender is
            // already authenticated on this connection (validateSessionAuth has
            // already passed above).  An unauthenticated caller cannot reach this
            // point.  The envelope therefore only *refines* the authenticated
            // identity; it cannot escalate past the session-authenticated user.
            //
            // MCP note (Task 7-5 partial): the MCP → QUIC path uses the external
            // geode-client-zig package whose ExecuteRequest encoder does not yet
            // emit field 4.  Until a new geode-client-zig release is tagged with
            // the field, envelope_bytes will always be null on MCP-originated
            // requests and the server falls back to the connection-level Principal.
            const principal_for_request = blk: {
                const envelope_bytes = exec_req.principal_envelope_bytes;
                if (envelope_bytes) |env_bytes| {
                    if (env_bytes.len > 0) {
                        if (geode.distributed.principal_envelope.deserialize(env_bytes)) |env| {
                            var forwarded = geode.distributed.principal_envelope.toPrincipal(&env);
                            // Stamp the source as distributed_worker so GPS rules
                            // can distinguish forwarded requests from direct ones.
                            forwarded.source = .distributed_worker;
                            break :blk forwarded;
                        } else |_| {
                            // Malformed envelope — fall back to connection identity.
                            // We do not reject the request: the authenticated user
                            // still gets their connection-level principal.
                        }
                    }
                }
                const role_names: []const []const u8 = if (role) |r|
                    &[_][]const u8{@tagName(r)}
                else
                    &.{};
                break :blk geode.security.principal_derive.derivePrincipal(.{
                    .username = state.authenticated_user,
                    .role_names = role_names,
                    .tenant_id = if (state.session_config) |cfg| cfg.tenant_id else null,
                    .active_graph = if (state.exec_session) |s| s.graph else null,
                    .auth_version = state.authenticated_auth_version,
                    .auth_method = .password,
                    .source = .quic_handler,
                });
            };

            var exec_context = execution.ExecutionContext{
                .catalog = catalog,
                .user = state.authenticated_user,
                .role = role,
                .token = null,
                .strict_offset_validation = false,
                .session_state = if (state.exec_session) |*s| s else null,
                .transaction_state = if (state.in_txn) .Active else .None,
                .query_param_names = bindings.names,
                .query_param_values = bindings.values,
                .optimizer_hints = if (plan_handle != null) &optimizer_hints_storage else null,
                .graph_bound = state.graph_bound,
                // GAP-0281: Thread session tenant_id into execution context for FLE hooks
                .tenant_id = if (state.session_config) |cfg| cfg.tenant_id else null,
                // GAP-0844 (secondary): thread the session FLE role into the context
                // alongside the per-thread setter (installThreadLocalSessionState).
                // FLE read sites that hold this context prefer it via
                // getCurrentUserRoleCtx, making the context authoritative at the
                // request boundary (per-thread map remains the fallback).
                .fle_role = state.fle_user_role,
                .principal = &principal_for_request,
                // GAP-0511 Task 3b: Wire expression RLS engine pointer into execution context.
                // CANARY: REQ=REQ-SEC-RLS-WIRE-013; FEATURE="RLS Expression Wiring"; ASPECT=ExecContextWiring; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=security; UPDATED=2026-06-11
                .rls_engine = @import("rls_types").getGlobalExprRLSEngine(),
                .pending_index_rebuilds = null,
                // RC-3 (2026-06-12): thread the optional client idempotency key
                // (ExecuteRequest field 5) into the context so a clustered create
                // dedups a client retry at apply time. Null when the client did
                // not supply one (the leader then generates a per-request key).
                .idempotency_key = exec_req.idempotency_key,
            };

            var pending_index_rebuilds = std.StringHashMap(void).init(gpa);
            defer {
                var iter = pending_index_rebuilds.keyIterator();
                while (iter.next()) |k| gpa.free(k.*);
                pending_index_rebuilds.deinit();
            }
            exec_context.pending_index_rebuilds = &pending_index_rebuilds;
            exec_context.pending_index_rebuilds_allocator = gpa;

            var flags = std.ArrayList([]const u8).initCapacity(gpa, 8) catch return error.OutOfMemory;
            defer flags.deinit(gpa);
            var base_flags_buf: server_flags.BaseFlagsBuf = undefined;
            const base_flags = server_flags.computeBaseFlags(&base_flags_buf, ordered, distinct);
            for (base_flags) |flag| {
                try appendFlagIfMissing(gpa, &flags, flag);
            }
            if (traits.has_union) {
                try appendFlagIfMissing(gpa, &flags, server_flags.F_UNION_PHASES);
            }
            if (heur_index) {
                try appendFlagIfMissing(gpa, &flags, server_flags.F_HEUR_INDEX);
            }
            if (parse_result.has_double_solidus_comment) {
                try appendFlagIfMissing(gpa, &flags, "GB03:DoubleSolidusComment");
            }

            // GAP-0289: Enforce per-tenant query concurrency quota before execution.
            const query_tenant = if (state.session_config) |cfg| cfg.tenant_id else null;
            var query_quota_acquired = false;
            if (query_tenant) |tid| {
                if (tenant_quota.getGlobalQuotaManager()) |qm| {
                    qm.acquireQuery(tid) catch {
                        try sendExecuteError(gpa, stream, "42000", "Query quota exceeded for tenant", &.{}, &.{});
                        return;
                    };
                    query_quota_acquired = true;
                }
            }
            defer if (query_quota_acquired) {
                if (query_tenant) |tid| {
                    if (tenant_quota.getGlobalQuotaManager()) |qm| {
                        qm.releaseQuery(tid);
                    }
                }
            };

            // GAP-0001: Acquire the appropriate store lock based on query type.
            // Mutations (CREATE, MERGE, DELETE, INSERT, DDL) take the exclusive
            // write lock to prevent concurrent HashMap rehash races (CWE-362).
            // Read-only queries take the shared lock so they can run in parallel.
            // EXPLAIN never executes, so no lock is needed.
            // #52: Lock is released explicitly after execution completes but BEFORE
            // response serialization and network send, to avoid holding the global
            // write lock during slow I/O operations.
            // P1: Per-graph locking — queries against different graphs no longer serialize.
            // CANARY: REQ=REQ-QUIC-HC-110; FEATURE="High-Concurrency Store-Free Reads"; ASPECT=QUICLockBypass; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-27
            // Pure scalar row queries such as `RETURN 1 AS c` do not touch
            // graph storage, so they should not contend with mutation-heavy
            // workloads on the graph read/snapshot path.
            const needs_store_lock = analysis.kind != .explain and !(analysis.kind == .rows and analysis.is_store_free);
            const is_mutation = needs_store_lock and program_is_mutating;

            // CANARY: REQ=REQ-GPS-PDP-010; FEATURE="GPS Phase 2/4 Enforcement"; ASPECT=MutationGateViaDecide; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/gps_phase6_abac_migration.yml; OWNER=security; UPDATED=2026-05-21
            // GAP-0526 was originally enforced by a direct `user_mgmt.hasPermission` call
            // that bypassed the GPS policy catalog: a `(:Policy)` row granting WRITE via
            // `current_user() = '...'` or `true` could not override the role-based deny.
            // Phase 2's `decide()` already implements role + policy evaluation; route the
            // mutation gate through it so policies actually take effect at the wire layer.
            if (is_mutation) {
                if (state.authenticated_role) |role_u8| {
                    const auth_role = @as(user_mgmt.Role, @enumFromInt(role_u8));
                    if (!user_mgmt.hasPermission(auth_role, .Write)) {
                        // Builtin role lacks WRITE — consult the policy catalog before denying.
                        const gps_mod = geode.security.gps;
                        const req_local = gps_mod.DecisionRequest{
                            .principal = &principal_for_request,
                            .action = .write,
                            .resource = .{ .database = {} },
                        };
                        const decision_kind = blk: {
                            const decision = gps_mod.decide(gpa, &req_local) catch break :blk gps_mod.PolicyDecisionKind.unauthorized;
                            break :blk decision.kind;
                        };
                        if (decision_kind != .allow) {
                            try sendExecuteError(gpa, stream, "42501", "Permission denied: insufficient privileges for data modification", &.{}, &.{});
                            return;
                        }
                    }
                }
            }

            const query_graph_name = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
            quic_response_metrics.recordFirstStreamQueryPrepare(monoNsFromHandler() -| first_stream_prepare_start_ns);

            // GAP-0900 lever (c): opt-in concurrent batch-merge fast path.
            // A client signals "this program is a batch of independent simple
            // MERGEs, submit them concurrently" by prefixing the raw query
            // text with the literal sentinel `/*+BATCH*/` (a block comment the
            // lexer already strips, so `parse_result.program` is exactly the
            // parsed remainder — no re-parse needed). The default path (no
            // sentinel) is completely unchanged.
            //
            // Gating mirrors the single-statement merge fast paths: mutation,
            // autocommit (skip the undo log), non-cluster (cluster writes must
            // reach Raft), and an adapter present. `executeBatchSimpleMerge`
            // returns false (no response sent, no side effects) when it cannot
            // batch — group-commit disabled or any statement is not a simple
            // node MERGE — and we fall through to the normal dispatch.
            const BATCH_SENTINEL = "/*+BATCH*/";
            const batch_requested = std.mem.startsWith(u8, query_text, BATCH_SENTINEL);
            if (batch_requested and
                is_mutation and
                !state.in_txn and
                graph_store.getGlobalAdapter() != null and
                geode.distributed.cluster.getGlobalClusterCoordinator() == null)
            {
                if (try executeBatchSimpleMerge(gpa, stream, state, &parse_result.program, query_graph_name, exec_context)) {
                    return;
                }
                // Not batchable -> fall through to the regular dispatch, which
                // handles the (already-parsed) multi-statement program.
            }

            // CANARY: REQ=REQ-QUIC-HC-008; FEATURE="QUIC High-Concurrency Reads"; ASPECT=CountReadSnapshotBypass; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-25
            //
            // Count-only reads already have an executor fast path, but the
            // handler used to deep-clone a QueryReadSession before the executor
            // could reach it. Under mixed read/write fan-out that made cheap
            // `MATCH (n:Label) RETURN count(n)` requests queue behind snapshots
            // and writers. Execute that shape under a brief shared read lock,
            // then release the lock before protobuf serialization.
            if (needs_store_lock and !is_mutation) count_fast_path_blk: {
                const target = analysis.target orelse break :count_fast_path_blk;
                if (target.* != .Query) break :count_fast_path_blk;
                // GAP-0892: a multi-statement program (e.g. `SESSION SET
                // PROPERTY GRAPH "G1"; MATCH (n) RETURN count(*)`) must run
                // through the full executor — the count fast path executes
                // ONLY `target`, so it would count against the request-start
                // session graph and silently drop the preamble's side
                // effects (gql_conformance T11/T12/T14 returned 0).
                if (analysis.has_effectful_preamble) break :count_fast_path_blk;

                // GAP-0840: route the count fast-path tenant scope through the
                // shared strict-tenancy decision rather than the inline
                // `if tid==DEFAULT_TENANT_ID null else tid` footgun, which
                // silently widened an unscoped/"default" session to ALL tenants
                // for `count(*)`/label-count reads BEFORE the executor could
                // reject it. In strict mode `resolveTenantFilter` returns
                // `error.TenantScopeRequired`; surface it on the SAME wire-error
                // path the regular executor uses (mapError → sendExecuteError)
                // instead of swallowing it or propagating it up the stack.
                const fast_count_tenant: ?[]const u8 = geode.tenancy.resolveTenantFilter(exec_context.tenant_id) catch |err| {
                    const info = proto_util.mapError(err);
                    try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                    return;
                };

                // CANARY: REQ=REQ-QUIC-HC-146; FEATURE="QUIC High-Concurrency Reads"; ASPECT=GraphLockFreeLabelCount; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-28
                //
                // The dominant mixed fan-out read shape is a tenantless
                // single-label count. That can be answered from the exact
                // label refcount under GraphStore's label-count mutex, so it
                // does not need the per-graph SHARED rwlock at all. Broader
                // count shapes fall through to the existing locked active
                // read-store path below.
                {
                    const prev_ctx = execution.pushActiveContext(&exec_context);
                    defer execution.popActiveContext(prev_ctx);
                    const first_stream_execute_start_ns = monoNsFromHandler();
                    const fast_result_opt = try execution.countNodesLabelRefcountFastPath(gpa, target.Query, query_graph_name, fast_count_tenant);
                    quic_response_metrics.recordFirstStreamReadQueryExecute(monoNsFromHandler() -| first_stream_execute_start_ns);
                    if (fast_result_opt) |fast_result| {
                        var exec_result = fast_result;
                        defer exec_result.deinit(gpa);

                        for (flags.items) |flag| {
                            try appendFlagToResult(gpa, &exec_result, flag);
                        }

                        try sendSinglePageExecutionResultBatched(gpa, stream, &exec_result);
                        auditQueryExecution(state, query_text, is_mutation);
                        syncGraphFromSession(state);
                        updateTxnStateFromProgram(state, &parse_result.program);
                        return;
                    }
                }

                const count_lock = graph_store.acquireGraphReadLockTagged(query_graph_name, .point_read);
                var count_lock_held = true;
                defer if (count_lock_held) graph_store.releaseGraphLock(count_lock);

                const live_store = graph_store.getWritableGlobalStore(gpa);
                const prev_read_store = graph_store.pushActiveQueryReadStore(live_store);
                defer graph_store.popActiveQueryReadStore(prev_read_store);

                const prev_ctx = execution.pushActiveContext(&exec_context);
                defer execution.popActiveContext(prev_ctx);

                const first_stream_execute_start_ns = monoNsFromHandler();
                const fast_result_opt = try execution.countNodesFastPath(gpa, target.Query, query_graph_name, fast_count_tenant);
                quic_response_metrics.recordFirstStreamReadQueryExecute(monoNsFromHandler() -| first_stream_execute_start_ns);
                if (fast_result_opt) |fast_result| {
                    var exec_result = fast_result;
                    defer exec_result.deinit(gpa);

                    graph_store.releaseGraphLock(count_lock);
                    count_lock_held = false;

                    for (flags.items) |flag| {
                        try appendFlagToResult(gpa, &exec_result, flag);
                    }

                    // CANARY: REQ=REQ-QUIC-HC-119; FEATURE="QUIC High-Concurrency Reads"; ASPECT=BatchedCountFastPathResponse; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-27
                    //
                    // The count fast path is the common read half of the
                    // mixed read/mutation fan-out harness. Keep its wire
                    // response on the same single-write schema+page path as
                    // regular small row results so high fan-out count reads
                    // do not double stream write pressure.
                    try sendSinglePageExecutionResultBatched(gpa, stream, &exec_result);

                    auditQueryExecution(state, query_text, is_mutation);
                    syncGraphFromSession(state);
                    updateTxnStateFromProgram(state, &parse_result.program);
                    return;
                }
            }

            // Task 11 (enterprise-ingest-throughput): bulk-ingest fast path.
            // When GEODE_BULK_INGEST is set AND the parsed statement matches
            // the simple `CREATE (n:L {k: scalar, ...})` form, short-circuit
            // to `executeBulkSimpleCreate` — skipping the full executor, the
            // undo log, RLS filtering, and row materialization.  Any other
            // statement shape (RETURN, expressions, multi-label, etc.) falls
            // through to the regular executor path below.
            // In cluster mode the write must flow through the regular executor
            // so it is proposed to Raft and replicated to every node (root cause
            // #2 of docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md).
            // The bulk fast path writes straight to the local storage adapter,
            // bypassing the Raft propose hook in crud_operations, so skip it
            // whenever a cluster coordinator is active.
            // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-CREATE; FEATURE="DistributedCluster"; ASPECT=BulkFastPathClusterBypass; STATUS=TESTED; TEST=tests/test_cluster_3node_steady_state.zig; OWNER=distributed; UPDATED=2026-06-04
            const cluster_active = geode.distributed.cluster.getGlobalClusterCoordinator() != null;
            if (is_mutation and geode.bulk_ingest.isEnabled() and !cluster_active) {
                const bulk_shape = geode.bulk_ingest.matchSingleStatement(&parse_result.program);
                if (bulk_shape == .simple_node_create) {
                    try executeBulkSimpleCreate(gpa, stream, state, &parse_result.program, query_graph_name, exec_context);
                    return;
                }
                if (bulk_shape == .match_create_edge) {
                    if (geode.bulk_ingest.matchEdgeSpec(&parse_result.program)) |edge_spec| {
                        try executeBulkMatchCreateEdge(gpa, stream, state, &parse_result.program, edge_spec, query_graph_name, exec_context);
                        return;
                    }
                    // If the spec helper disagrees with matchSingleStatement,
                    // fall through to the regular executor (programming error
                    // — noise not worth a dedicated error code).
                }
                if (bulk_shape == .simple_node_merge) {
                    if (geode.bulk_ingest.matchSimpleNodeMergeSpec(&parse_result.program)) |merge_spec| {
                        try executeBulkSimpleMerge(gpa, stream, state, &parse_result.program, merge_spec, query_graph_name, exec_context);
                        return;
                    }
                    // Same fallthrough semantics as the edge path — if the
                    // spec helper disagrees with `matchSingleStatement`,
                    // defer to the general executor.
                }
            }

            // Default mutation fast paths (2026-05-25): promote simple
            // no-RETURN scalar CREATEs and match-create-edge statements through
            // the direct adapter paths when no transaction is active, even if
            // `GEODE_BULK_INGEST=1` was not opt-in.
            //
            // CANARY: REQ=REQ-QUIC-HC-006; FEATURE="QUIC High-Concurrency Mutations"; ASPECT=DefaultSimpleCreateFastPath; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-25
            //
            // The regular dispatch below acquires the per-graph EXCLUSIVE
            // write lock and holds it across the full executor path. Under
            // mixed high-concurrency request fan-out, this makes read snapshots
            // queue behind every simple mutation. The fast paths keep the
            // exclusive critical section to the adapter apply step and produce
            // the same no-RETURN wire shape. They remain gated on `!state.in_txn`
            // because they intentionally skip the undo log; transactional
            // rollback coverage stays on the regular executor path.
            // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-CREATE; FEATURE="DistributedCluster"; ASPECT=DefaultFastPathClusterBypass; STATUS=TESTED; TEST=tests/test_cluster_3node_steady_state.zig; OWNER=distributed; UPDATED=2026-06-04
            // In cluster mode, these direct-adapter fast paths bypass the Raft
            // propose hook in the executor and would write local-only (root
            // cause #2). Skip them whenever a cluster coordinator is active so
            // the write flows through executeProgramWithContext -> executeCreate
            // -> proposeWrite and replicates to every node.
            if (is_mutation and !state.in_txn and !geode.bulk_ingest.isEnabled() and graph_store.getGlobalAdapter() != null and geode.distributed.cluster.getGlobalClusterCoordinator() == null) {
                const bulk_shape = geode.bulk_ingest.matchSingleStatement(&parse_result.program);
                if (bulk_shape == .simple_node_create) {
                    try executeBulkSimpleCreate(gpa, stream, state, &parse_result.program, query_graph_name, exec_context);
                    return;
                }
                if (bulk_shape == .match_create_edge) {
                    if (geode.bulk_ingest.matchEdgeSpec(&parse_result.program)) |edge_spec| {
                        try executeBulkMatchCreateEdge(gpa, stream, state, &parse_result.program, edge_spec, query_graph_name, exec_context);
                        return;
                    }
                    // Spec/detector disagreement — fall through to the
                    // general executor as the original block does.
                }
                if (bulk_shape == .simple_node_merge) {
                    if (geode.bulk_ingest.matchSimpleNodeMergeSpec(&parse_result.program)) |merge_spec| {
                        try executeBulkSimpleMerge(gpa, stream, state, &parse_result.program, merge_spec, query_graph_name, exec_context);
                        return;
                    }
                    // Spec/detector disagreement — fall through to the
                    // general executor as the original block does.
                }
            }

            // GAP-0894: a `<graph-selector>; <simple MERGE>` 2-statement
            // program — the shape a pooled `database/sql` driver emits when it
            // prepends the graph selector to every statement for connection-
            // pool safety (the divelife 14.27M bulk-seed client). The single-
            // statement fast paths above reject it (statements.len != 1), so the
            // MERGE fell through to the regular executor's whole-graph EXCLUSIVE
            // write lock — the measured bottleneck (mg_rwlock_exclusive_wait_ns
            // climbing, mg_merge_tuple_lock_acquired_total pinned at 0,
            // ~50 nodes/sec). Fast-path the MERGE ONLY when the preamble
            // re-selects the graph the session is ALREADY bound to
            // (query_graph_name == state.current_graph, RBAC-checked at HELLO /
            // first USE GRAPH). A preamble that switches to a DIFFERENT graph
            // falls through so the graph-access check + session rebind run in
            // the regular executor. Same gating as the single-statement fast
            // paths: autocommit, non-cluster (cluster writes must reach Raft).
            if (is_mutation and !state.in_txn and !cluster_active and graph_store.getGlobalAdapter() != null) {
                if (geode.bulk_ingest.matchGraphSelectorThenMerge(&parse_result.program)) |gs| {
                    if (std.mem.eql(u8, gs.graph_name, query_graph_name)) {
                        try executeBulkSimpleMerge(gpa, stream, state, &parse_result.program, gs.merge, query_graph_name, exec_context);
                        return;
                    }
                }
            }

            var graph_lock_handle: ?graph_store.GraphLockHandle = null;
            // GAP-0753: Read path takes the shared graph lock only long
            // enough to capture a QueryReadSession snapshot; downstream
            // parse + plan + execute + row materialization runs against the
            // snapshot without holding the graph lock. Mutations still take
            // the exclusive writer lock for their full duration.
            //
            // GAP-0805 (M1.3): Simple point-reads (single-node MATCH with
            // single-label + single-property equality, no traversal/
            // aggregation/ordering) bypass the QueryReadSession deep-clone
            // and use a zero-copy `PointReadView` while holding the shared
            // read lock across the (short) execute window. Non-point reads
            // and any failure to initialise the view fall back to the
            // snapshot path.
            var read_session: ?graph_store.QueryReadSession = null;
            var point_read_view: ?graph_store.PointReadView = null;
            var prev_active_read_store: ?*graph_store.GraphStore = null;
            // Task 1 (throughput plan): start per-mutation timing sample.
            // Scope note: only mutations go through the write-lock branch and
            // then the executeProgramWithContext path in `.rows`; read queries
            // take `.explain`, `.profile`, or the node_scan_stream fast path
            // and never reach markExecuteDone()/record(). The sample is
            // therefore only started (and only costs a clock_gettime) on the
            // mutation path.
            var mut_sample: ?mutation_timing.Sample = null;
            if (needs_store_lock) {
                if (is_mutation) {
                    mut_sample = mutation_timing.begin();
                    // Mutations: exclusive writer lock held across execute to
                    // prevent HashMap rehash races (GAP-0001, CWE-362/CWE-416).
                    //
                    // R2 (2026-04-22): use the cancelable variant with a
                    // per-request deadline.  The previous uncancelable
                    // acquire parked transport threads forever when one
                    // worker stalled inside a long-running mutation,
                    // producing the "thread-pool deinit timed out"
                    // shutdown warning under the 16-worker ingest workload.
                    const write_lock_timeout_ns = mutationWriteLockTimeoutNs(state);
                    const deadline = monoNanosNow() + write_lock_timeout_ns;
                    if (graph_store.acquireGraphWriteLockCancelable(query_graph_name, deadline)) |h| {
                        graph_lock_handle = h;
                        if (mut_sample) |*s| s.markLockAcquired();
                    } else |err| {
                        if (err == error.Deadline) {
                            log.warn("Write lock acquisition timed out", &.{
                                Attr.string("graph", query_graph_name),
                                Attr.uint("timeout_ns", write_lock_timeout_ns),
                            });
                            try sendExecuteError(gpa, stream, "40001", "Write lock acquisition timed out", &.{}, &.{});
                            return;
                        }
                        return err;
                    }
                } else if (analysis.is_point_read and !execution.wouldEvaluateRLS()) {
                    // GAP-0805: hold the shared read lock across the brief
                    // point-read execute window, backed by a zero-copy view.
                    // `graph_lock_handle` keeps the lock alive until the
                    // defer block releases it.
                    // NOTE: RLS-evaluating reads bypass this path (wouldEvaluateRLS()
                    // returns true) and fall through to the snapshot path below, so
                    // the SHARED rwlock is released before per-node row construction.
                    graph_lock_handle = graph_store.acquireGraphReadLockTagged(query_graph_name, .point_read);
                    const store_ref = graph_store.getWritableGlobalStore(gpa);
                    if (graph_store.PointReadView.init(store_ref)) |view| {
                        point_read_view = view;
                        prev_active_read_store = graph_store.pushActiveQueryReadStore(
                            point_read_view.?.store(),
                        );
                    } else |_| {
                        // Fall back cleanly: release the read lock we just
                        // took and use the snapshot path instead.
                        if (graph_lock_handle) |h| graph_store.releaseGraphLock(h);
                        graph_lock_handle = null;
                        if (graph_store.snapshotUnderReadLock(gpa, query_graph_name)) |session| {
                            read_session = session;
                            prev_active_read_store = graph_store.pushActiveQueryReadStore(
                                read_session.?.store(),
                            );
                        } else |_| {
                            graph_lock_handle = graph_store.acquireGraphReadLockTagged(query_graph_name, .fallback);
                        }
                    }
                } else if (readServedEngineDirect(state, &analysis, query_graph_name)) {
                    // GAP-0900 / GAP-0902 (scan/analytical no-clone): the read is
                    // served ENGINE-DIRECT in the `.rows` arm below — either by
                    // the `node_scan_stream` fast path (bounded `MATCH (n:Label)
                    // RETURN n [LIMIT k]`, projection, simple WHERE, count) OR,
                    // for the analytical shapes (single-chain ORDER BY / DISTINCT
                    // / multi-aggregate / WHERE-count), by the storage-native
                    // planned-read + fast paths (top-K, property-aggregate). All
                    // read slot ids + the needed properties straight from the
                    // storage adapter (O(result)/O(scanned) cheap-property reads,
                    // never the cache map) and never consume the active read
                    // store, so the O(all-nodes) `QueryReadSession` deep-clone
                    // here was pure wasted work AND — under the bounded node cache
                    // — materialized EVERY evicted node into an O(N)-resident
                    // snapshot (81 GB at 14.27M, the RSS balloon).
                    //
                    // Skip the snapshot entirely: leave the active read store
                    // unpushed so the executor's `getGlobalStore` resolves to the
                    // live store (whose IdMap + label index are the authoritative
                    // source the clone copied anyway). The engine-direct paths
                    // take their own brief per-graph/per-shard read locks while
                    // reading, so isolation against concurrent ingest is the same
                    // fuzzy-live semantics they already have for the scan shape.
                    // FLE decrypt-on-read and tenant filtering are unaffected;
                    // RLS-evaluating reads are excluded by `readServedEngineDirect`
                    // (kept on the snapshot path so per-candidate RLS runs), and
                    // `isStorageNativeReadShape` guarantees these analytical reads
                    // run engine-direct (never the legacy resident-only executor),
                    // so a skipped snapshot can never strand them on a partial
                    // (resident-only) view.
                } else {
                    // Reads: snapshot under the shared reader lock, then
                    // release immediately. Executor reads from the thread-
                    // local active-snapshot store installed below.
                    if (graph_store.snapshotUnderReadLock(gpa, query_graph_name)) |session| {
                        read_session = session;
                        prev_active_read_store = graph_store.pushActiveQueryReadStore(
                            read_session.?.store(),
                        );
                    } else |_| {
                        // Snapshot path unavailable (e.g. legacy no-adapter
                        // test path): fall back to the wide-scope shared
                        // reader lock, same semantics as GAP-0752.
                        graph_lock_handle = graph_store.acquireGraphReadLockTagged(query_graph_name, .fallback);
                    }
                }
            }
            // Safety net: release on any unexpected error path not explicitly handled.
            var lock_released = false;
            // GAP-0755: Borrow a per-query arena from the process-wide pool
            // and install its allocator as the current-thread scratch hint.
            // Executor code that opts in via `query_arena.currentScratchAllocator()`
            // gets arena-backed scratch memory that is reset between
            // queries; sites that still use the graph_store global
            // allocator remain correct (the fall-back is unchanged).
            var scratch_arena: ?*query_arena.Arena = null;
            var prev_scratch: ?std.mem.Allocator = null;
            var scratch_installed = false;
            if (query_arena.ensureDefaultPool(graph_store.global_allocator())) |pool| {
                if (pool.acquire()) |a| {
                    scratch_arena = a;
                    prev_scratch = query_arena.pushScratchAllocator(a.allocator());
                    scratch_installed = true;
                } else |_| {
                    // Acquisition failure is non-fatal — the executor falls
                    // back to the graph_store global allocator.
                }
            } else |_| {
                // Pool init failure is non-fatal for the same reason.
            }
            defer {
                if (!lock_released) {
                    if (graph_lock_handle) |h| {
                        // GAP-0511: Release the write lock BEFORE rebuilding indexes.
                        // rebuildAdvancedIndex acquires its own rebuild_mutex and only
                        // reads the store, so it does not need the graph write lock.
                        // This prevents MERGE stalls under sustained ingest.
                        graph_store.releaseGraphLock(h);
                        rebuildPendingIndexes(gpa, query_graph_name, &pending_index_rebuilds);
                    }
                }
                // The snapshot session is owned by this handler scope —
                // always pop the active-store thread-local and deinit the
                // session on every exit path (including early returns on
                // error).  `pushActiveQueryReadStore` returned the previous
                // value so nested read scopes restore correctly.
                if (read_session) |*session| {
                    graph_store.popActiveQueryReadStore(prev_active_read_store);
                    session.deinit();
                }
                // GAP-0805 (M1.3): mirror the cleanup for the zero-copy
                // point-read view. The graph read lock that scopes the
                // view is released by the `graph_lock_handle` branch
                // above; `PointReadView.deinit` itself is a no-op.
                if (point_read_view) |*view| {
                    graph_store.popActiveQueryReadStore(prev_active_read_store);
                    view.deinit();
                }
                // GAP-0755: Always pop the scratch allocator and return the
                // arena to the pool on every exit path (including early
                // error returns).  Release resets the arena so the next
                // borrower starts at the top of the retained buffer.
                if (scratch_installed) {
                    query_arena.popScratchAllocator(prev_scratch);
                }
                if (scratch_arena) |a| {
                    if (query_arena.defaultPool()) |pool| pool.release(a);
                }
            }

            switch (analysis.kind) {
                .explain => {
                    const explain_msg = blk: {
                        if (analysis.target) |target| {
                            if (target.* == .Query) {
                                var planned_query = target.Query;
                                if (try planned_read_runtime.buildPlanIfSupported(gpa, &planned_query, exec_context)) |plan| {
                                    var owned_plan = plan;
                                    defer owned_plan.deinit(gpa);
                                    break :blk try explain_payload.buildExplainPayloadFromPlan(gpa, owned_plan);
                                }
                            }
                        }
                        break :blk try explain_payload.buildExplainPayload(
                            gpa,
                            traits,
                            analysis.union_part_count,
                            normalized.explain_calibrated,
                        );
                    };

                    const status = try proto_util.buildStatus(gpa, "00000", flags.items);
                    const resp = schema.ExecutionResponse{
                        .status = status,
                        .payload = .{ .explain = explain_msg },
                    };
                    try sendQuicMessage(gpa, stream, .{ .execute = resp });
                },
                .profile => {
                    const target_stmt = analysis.target orelse {
                        try sendExecuteError(gpa, stream, "0A000", "PROFILE target missing", &.{}, &.{});
                        return;
                    };

                    if (target_stmt.* == .Query) {
                        var planned_query = target_stmt.Query;
                        if (try planned_read_runtime.executeProfiledIfSupported(
                            gpa,
                            &planned_query,
                            exec_context,
                            bindings.names,
                            bindings.values,
                            true,
                        )) |planned| {
                            var owned_planned = planned;
                            defer owned_planned.deinitMetadata(gpa);
                            defer owned_planned.result.deinit(gpa);

                            for (flags.items) |flag| {
                                try appendFlagToResult(gpa, &owned_planned.result, flag);
                            }

                            const store = graph_store.getGlobalStore(gpa);
                            const profile_node_count: u64 = @intCast(store.getNodeCount());
                            const profile_edge_count: u64 = @intCast(store.getEdgeCount());
                            const profile_is_dirty = store.isDirty();

                            if (needs_store_lock) {
                                if (graph_lock_handle) |h| {
                                    // GAP-0511: Release lock before index rebuild
                                    graph_store.releaseGraphLock(h);
                                    rebuildPendingIndexes(gpa, query_graph_name, &pending_index_rebuilds);
                                }
                                lock_released = true;
                            }

                            if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                                if (state.authenticated_user) |auth_user| {
                                    const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                                    _ = rls_filter.applyRLSFilter(gpa, &owned_planned.result, rls_engine, auth_user, rls_graph);
                                }
                            }

                            const profile_msg = try profile_payload.buildProfilePayloadFromTrace(gpa, owned_planned.plan, owned_planned.trace, .{
                                .compact = compact_profile,
                                .include_mem_curve = memcurve_profile,
                                .disable_estimates = disable_estimates,
                                .spill_threshold = state.query_mem_limit_bytes,
                                .committed_txns = state.global_commit_ts,
                                .graph_store_nodes = profile_node_count,
                                .graph_store_edges = profile_edge_count,
                                .graph_store_dirty = profile_is_dirty,
                                .flagger_findings = owned_planned.result.flags.items,
                                .union_part_count = analysis.union_part_count,
                            });

                            const status = try proto_util.buildStatus(gpa, "00000", owned_planned.result.flags.items);
                            const resp = schema.ExecutionResponse{
                                .status = status,
                                .payload = .{ .profile = profile_msg },
                            };
                            try sendQuicMessage(gpa, stream, .{ .execute = resp });
                            // Route audit event to per-graph logger (falls back to global).
                            auditQueryExecution(state, query_text, is_mutation);
                            return;
                        }
                    }

                    var exec_result = execution.executeStatementWithContext(gpa, target_stmt.*, exec_context) catch |err| {
                        const info = proto_util.mapError(err);
                        try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                        return;
                    };
                    defer exec_result.deinit(gpa);

                    for (flags.items) |flag| {
                        try appendFlagToResult(gpa, &exec_result, flag);
                    }

                    // Capture store stats while under lock
                    const store = graph_store.getGlobalStore(gpa);
                    const profile_node_count: u64 = @intCast(store.getNodeCount());
                    const profile_edge_count: u64 = @intCast(store.getEdgeCount());
                    const profile_is_dirty = store.isDirty();

                    // CANARY: REQ=REQ-SEC-RLS-ALGO-001; FEATURE="RLS Algorithm Filtering"; ASPECT=QUICProfileWire; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
                    // Algorithm RLS filter on PROFILE path — requires store lock.
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                            _ = rls_filter.applyAlgorithmRLSFilter(gpa, &exec_result, rls_engine, store, auth_user, rls_graph);
                        }
                    }

                    // #52: Release lock before serialization and network send.
                    // exec_result is a thread-local copy; store stats are captured above.
                    if (needs_store_lock) {
                        if (graph_lock_handle) |h| {
                            // GAP-0511: Release lock before index rebuild
                            graph_store.releaseGraphLock(h);
                            rebuildPendingIndexes(gpa, query_graph_name, &pending_index_rebuilds);
                        }
                        lock_released = true;
                    }

                    // S1: RLS filter on PROFILE path (same logic as .rows path).
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                            _ = rls_filter.applyRLSFilter(gpa, &exec_result, rls_engine, auth_user, rls_graph);
                        }
                    }

                    const profile_msg = try profile_payload.buildProfilePayload(gpa, traits, exec_result.rows.len, .{
                        .compact = compact_profile,
                        .include_mem_curve = memcurve_profile,
                        .disable_estimates = disable_estimates,
                        .spill_threshold = state.query_mem_limit_bytes,
                        .committed_txns = state.global_commit_ts,
                        .graph_store_nodes = profile_node_count,
                        .graph_store_edges = profile_edge_count,
                        .graph_store_dirty = profile_is_dirty,
                        .flagger_findings = exec_result.flags.items,
                        .union_part_count = analysis.union_part_count,
                    });

                    const status = try proto_util.buildStatus(gpa, "00000", exec_result.flags.items);
                    const resp = schema.ExecutionResponse{
                        .status = status,
                        .payload = .{ .profile = profile_msg },
                    };
                    try sendQuicMessage(gpa, stream, .{ .execute = resp });

                    // Route audit event to per-graph logger (falls back to global).
                    auditQueryExecution(state, query_text, is_mutation);

                    // GAP-0260: Non-txn saves deferred to background persistence thread
                },
                .rows => {
                    // GAP-0900 (live-routing fix): this gate MUST agree with
                    // `readServedEngineDirect` (which decides whether the
                    // O(all-nodes) snapshot clone was skipped above). Use the same
                    // POLICY-AWARE RLS test: an empty default-allow engine no
                    // longer disables streaming for authenticated sessions. Only
                    // a real installed policy forces the snapshot path so RLS is
                    // evaluated per candidate node.
                    const rls_active = authenticatedReadNeedsRlsSnapshot(state);
                    // GAP-0892 / GAP-0900: node-scan streaming executes only
                    // `analysis.target`; it may run when the preamble is empty OR
                    // is solely a same-graph selector (a no-op re-selection of the
                    // graph the target already scans — see `preamblePermitsStreaming`).
                    // Any other effectful preamble (different graph, SET, DDL, txn
                    // body) must run through the full executor. GAP-0902: when the
                    // snapshot was skipped for a storage-native ANALYTICAL shape
                    // (ORDER BY / DISTINCT / aggregate — not node_scan-eligible),
                    // `node_scan_stream.prepare` below returns null and the arm
                    // falls through to `executeProgramWithContext`, which reads the
                    // live store engine-direct via the fast paths / planned_read.
                    // The snapshot-skip decision and execute decision stay in sync
                    // because both are gated on the SAME RLS + preamble checks.
                    if (!rls_active and preamblePermitsStreaming(&analysis, query_graph_name)) {
                        if (analysis.target) |target| {
                            if (target.* == .Query) {
                                const query_ptr = &target.Query;
                                if (try node_scan_stream.prepare(gpa, query_ptr, exec_context, bindings.names, bindings.values, flags.items)) |prepared_stream| {
                                    var active_stream = prepared_stream;
                                    errdefer active_stream.deinit();

                                    if (needs_store_lock) {
                                        if (graph_lock_handle) |h| {
                                            // GAP-0511: Release lock before index rebuild
                                            graph_store.releaseGraphLock(h);
                                            rebuildPendingIndexes(gpa, query_graph_name, &pending_index_rebuilds);
                                        }
                                        lock_released = true;
                                    }

                                    {
                                        var schema_arena = std.heap.ArenaAllocator.init(gpa);
                                        defer schema_arena.deinit();
                                        const sa = schema_arena.allocator();
                                        const status = try proto_util.buildStatus(sa, "00000", active_stream.flags);
                                        const schema_def = try active_stream.buildSchema(sa);
                                        const schema_resp = schema.ExecutionResponse{
                                            .status = status,
                                            .payload = .{ .schema = schema_def },
                                        };
                                        try sendQuicMessage(sa, stream, .{ .execute = schema_resp });
                                    }

                                    var page_final = false;
                                    if (state.inline_results_enabled) inline_blk: {
                                        const inline_max = if (state.inline_results_max_rows == 0) node_scan_stream.default_inline_rows else state.inline_results_max_rows;
                                        // P1: materialization runs under the per-graph SHARED read
                                        // lock to prevent data races with concurrent ingest. The
                                        // stream now acquires + releases that lock INTERNALLY in
                                        // chunked batches (`buildNextPage`), so a writer-preferred
                                        // EXCLUSIVE checkpoint/apply interleaves instead of starving
                                        // for the whole O(scanned) WHERE scan (where-scan-writer-
                                        // progress). No outer lock here — an outer hold would defeat
                                        // the chunking.
                                        var page_result = active_stream.buildNextPage(gpa, inline_max) catch |err| {
                                            // Inline page failed (e.g. concurrent ingest modified
                                            // nodes).  Reset the stream cursor so PULL starts from
                                            // the beginning and fall through to store the stream
                                            // for PULL instead of destroying it.
                                            log.warn("Inline page build failed, deferring to PULL", &.{
                                                Attr.string("error", @errorName(err)),
                                            });
                                            active_stream.next_index = 0;
                                            break :inline_blk;
                                        };
                                        defer page_result.result.deinit(gpa);

                                        var page_arena = std.heap.ArenaAllocator.init(gpa);
                                        defer page_arena.deinit();
                                        const pa = page_arena.allocator();
                                        const page = try proto_util.buildDataPageFromRows(pa, page_result.result.rows, page_result.final, false, &.{});
                                        page_final = page_result.final;
                                        const page_status = try proto_util.buildStatus(pa, "00000", active_stream.flags);
                                        const page_resp = schema.ExecutionResponse{
                                            .status = page_status,
                                            .payload = .{ .page = page },
                                        };
                                        try sendQuicMessage(pa, stream, .{ .execute = page_resp });
                                    }

                                    if (!state.inline_results_enabled or !page_final) {
                                        state.active_node_scan_stream = active_stream;
                                        state.active_result = true;
                                        state.result_page_index = 0;
                                        state.result_ordered = false;
                                        state.result_order_keys = &.{};
                                    } else {
                                        active_stream.deinit();
                                    }

                                    // Route audit event to per-graph logger (falls back to global).
                                    auditQueryExecution(state, query_text, is_mutation);

                                    syncGraphFromSession(state);
                                    updateTxnStateFromProgram(state, &parse_result.program);
                                    return;
                                }
                            }
                        }
                    }

                    const first_stream_execute_start_ns = monoNsFromHandler();
                    var exec_result = execution.executeProgramWithContext(gpa, &parse_result.program, exec_context) catch |err| {
                        const info = proto_util.mapError(err);
                        try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                        return;
                    };
                    const first_stream_execute_elapsed_ns = monoNsFromHandler() -| first_stream_execute_start_ns;
                    if (is_mutation) {
                        quic_response_metrics.recordFirstStreamMutationQueryExecute(first_stream_execute_elapsed_ns);
                    } else {
                        quic_response_metrics.recordFirstStreamReadQueryExecute(first_stream_execute_elapsed_ns);
                    }
                    // Task 1: mark execute phase complete (before lock release).
                    if (mut_sample) |*s| s.markExecuteDone();
                    defer exec_result.deinit(gpa);
                    const store = graph_store.getGlobalStore(gpa);

                    // CANARY: REQ=REQ-SEC-RLS-ALGO-001; FEATURE="RLS Algorithm Filtering"; ASPECT=QUICWire; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
                    // S1: Algorithm RLS filter BEFORE lock release — requires store access
                    // to look up node labels for integer nodeId values in algorithm results.
                    // Must run while store read lock is held for thread-safe HashMap access.
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                            _ = rls_filter.applyAlgorithmRLSFilter(gpa, &exec_result, rls_engine, store, auth_user, rls_graph);
                        }
                    }

                    // #52: Release lock immediately after execution completes.
                    // exec_result is a thread-local copy (owned data, freed by connection allocator).
                    // Everything below (flags, ordering, serialization, send, txn state update)
                    // does not access the store and does not need the lock.
                    if (needs_store_lock) {
                        if (graph_lock_handle) |h| {
                            // GAP-0511: Release lock before index rebuild
                            graph_store.releaseGraphLock(h);
                            rebuildPendingIndexes(gpa, query_graph_name, &pending_index_rebuilds);
                        }
                        lock_released = true;
                    }
                    // Task 1: mark lock-released and emit timing record.
                    if (mut_sample) |*s| {
                        s.markLockReleased();
                        s.record(query_text[0..@min(query_text.len, 80)]);
                    }

                    // S1: Apply label-based RLS filtering AFTER lock release and BEFORE
                    // response serialization.  This removes rows whose Node/Edge labels
                    // are denied for the authenticated user in the current graph.
                    // CANARY: REQ=REQ-SEC-RLS-WIRE-003; FEATURE="RLS Query Enforcement"; ASPECT=PostResultFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                            _ = rls_filter.applyRLSFilter(gpa, &exec_result, rls_engine, auth_user, rls_graph);
                        }
                    }

                    for (flags.items) |flag| {
                        try appendFlagToResult(gpa, &exec_result, flag);
                    }

                    var order_keys: []const []const u8 = &.{};
                    defer {
                        for (order_keys) |key| gpa.free(key);
                        if (order_keys.len > 0) gpa.free(order_keys);
                    }
                    if (ordered) {
                        if (findOrderBy(&parse_result.program)) |ob| {
                            order_keys = try buildOrderKeys(gpa, ob, &exec_result);
                        }
                    }

                    // Send schema plus the first data page in one stream write.
                    // This avoids a two-packet burst for the common small-result
                    // path while preserving the existing inline EXECUTE protocol.
                    {
                        var response_arena = std.heap.ArenaAllocator.init(gpa);
                        defer response_arena.deinit();
                        const ra = response_arena.allocator();

                        const status = try proto_util.buildStatus(ra, "00000", exec_result.flags.items);
                        const schema_def = try proto_util.buildSchemaDefinition(ra, &exec_result);
                        const schema_resp = schema.ExecutionResponse{
                            .status = status,
                            .payload = .{ .schema = schema_def },
                        };

                        const page_size: usize = if (state.inline_results_max_rows == 0) node_scan_stream.default_inline_rows else state.inline_results_max_rows;
                        var sent_rows: usize = 0;
                        const first_page = try proto_util.buildDataPage(ra, &exec_result, sent_rows, page_size, ordered, order_keys);
                        sent_rows += first_page.rows.items.len;
                        const first_page_final = first_page.final;
                        const page_status = try proto_util.buildStatus(ra, "00000", exec_result.flags.items);
                        const page_resp = schema.ExecutionResponse{
                            .status = page_status,
                            .payload = .{ .page = first_page },
                        };

                        const batched = [_]schema.QuicServerMessage{
                            .{ .execute = schema_resp },
                            .{ .execute = page_resp },
                        };
                        try sendQuicMessagesBatched(ra, stream, &batched);

                        // Send any remaining pages inline as EXECUTE responses.
                        // This avoids the PULL round-trip which is unreliable under
                        // concurrent load due to a QUIC library stream FIN race.
                        while (!first_page_final and sent_rows < exec_result.rows.len) {
                            var page_arena = std.heap.ArenaAllocator.init(gpa);
                            defer page_arena.deinit();
                            const pa = page_arena.allocator();
                            const page = try proto_util.buildDataPage(pa, &exec_result, sent_rows, page_size, ordered, order_keys);
                            sent_rows += page.rows.items.len;
                            const next_page_status = try proto_util.buildStatus(pa, "00000", exec_result.flags.items);
                            const next_page_resp = schema.ExecutionResponse{
                                .status = next_page_status,
                                .payload = .{ .page = page },
                            };
                            try sendQuicMessage(pa, stream, .{ .execute = next_page_resp });
                            if (page.final) break;
                        }
                    }

                    // Route audit event to per-graph logger (falls back to global).
                    auditQueryExecution(state, query_text, is_mutation);

                    syncGraphFromSession(state);
                    updateTxnStateFromProgram(state, &parse_result.program);
                },
            }
        },
        .pull => |pull_req| {
            switch (try validateSessionAuth(gpa, state)) {
                .ok => {},
                .missing => {
                    try sendPullError(gpa, stream, "28000", "Authentication required", &.{}, &.{});
                    return;
                },
                .invalidated => {
                    try sendPullError(gpa, stream, "28000", "Session invalidated due to credential or role change", &.{}, &.{});
                    return;
                },
            }

            const page_size = pull_req.page_size;

            // If this stream has no active result, check the shared connection
            // state for one transferred from a prior stream handler.  The QUIC
            // library can report a spurious stream FIN, causing the handler that
            // stored the result to exit and transfer it to SharedConnState.
            // The PULL may arrive on a new handler before the transfer completes,
            // so we poll with a brief backoff.
            if (state.active_node_scan_stream == null and state.active_result_values == null) {
                if (state.shared_conn) |shared_ptr| {
                    const shared: *SharedConnState = @ptrCast(@alignCast(shared_ptr));
                    var wait_attempts: usize = 0;
                    while (wait_attempts < 100) : (wait_attempts += 1) {
                        shared.streams_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
                        const found_result = shared.pending_result != null;
                        const found_stream = shared.pending_node_scan_stream != null;
                        if (found_result) {
                            state.active_result_values = shared.pending_result;
                            shared.pending_result = null;
                            state.active_result = true;
                            state.result_page_index = shared.pending_result_page_index;
                            state.result_ordered = shared.pending_result_ordered;
                            state.result_order_keys = shared.pending_result_order_keys;
                            shared.pending_result_order_keys = &.{};
                            shared.pending_result_page_index = 0;
                            shared.pending_result_ordered = false;
                        }
                        if (found_stream) {
                            state.active_node_scan_stream = shared.pending_node_scan_stream;
                            shared.pending_node_scan_stream = null;
                            state.active_result = true;
                        }
                        shared.streams_mu.unlock(std.Io.Threaded.global_single_threaded.io());
                        if (found_result or found_stream) break;
                        {
                            const req = std.os.linux.timespec{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                            var rem: std.os.linux.timespec = undefined;
                            _ = std.os.linux.nanosleep(&req, &rem);
                        }
                    }
                }
            }

            // Arena allocator for pull page serialization (Issue #446)
            var pull_arena = std.heap.ArenaAllocator.init(gpa);
            defer pull_arena.deinit();
            const pa = pull_arena.allocator();

            if (state.active_node_scan_stream) |*active_stream| {
                // P1: materialization runs under the per-graph SHARED read lock
                // to prevent data races with concurrent ingest. The stream
                // acquires + releases that lock INTERNALLY in chunked batches
                // (`buildNextPage`), so a writer-preferred EXCLUSIVE
                // checkpoint/apply interleaves instead of starving for the whole
                // O(scanned) WHERE scan (where-scan-writer-progress). No outer
                // lock here — an outer hold would defeat the chunking.
                var page_result = active_stream.buildNextPage(gpa, page_size) catch |err| {
                    // Node disappeared during concurrent ingest — send empty
                    // final page so the client sees what was collected so far.
                    log.warn("PULL page build failed, closing stream", &.{
                        Attr.string("error", @errorName(err)),
                    });
                    const empty_page = try proto_util.buildDataPageFromRows(pa, &.{}, true, false, &.{});
                    const err_status = try proto_util.buildStatus(pa, "00000", active_stream.flags);
                    const err_resp = schema.ExecutionResponse{
                        .status = err_status,
                        .payload = .{ .page = empty_page },
                    };
                    try sendQuicMessage(pa, stream, .{ .pull = .{ .response = err_resp } });
                    state.resetResult();
                    return;
                };
                defer page_result.result.deinit(gpa);

                const page = try proto_util.buildDataPageFromRows(pa, page_result.result.rows, page_result.final, false, &.{});

                if (state.telemetry_paging) {
                    var ps_buf: [32]u8 = undefined;
                    const ps_str = std.fmt.bufPrint(&ps_buf, "{d}", .{page_size}) catch "0";
                    var rows_buf: [32]u8 = undefined;
                    const rows_str = std.fmt.bufPrint(&rows_buf, "{d}", .{page.rows.items.len}) catch "0";
                    log.info("telemetry", &.{
                        Attr.string("type", "TELEMETRY"),
                        Attr.string("event", "PULL_PAGE"),
                        Attr.string("page_size", ps_str),
                        Attr.string("rows_emitted", rows_str),
                        Attr.string("final", if (page.final) "true" else "false"),
                    });
                }

                const status = try proto_util.buildStatus(pa, "00000", active_stream.flags);
                const resp = schema.ExecutionResponse{
                    .status = status,
                    .payload = .{ .page = page },
                };
                try sendQuicMessage(pa, stream, .{ .pull = .{ .response = resp } });

                if (page.final) {
                    state.resetResult();
                }
                return;
            }

            if (state.active_result_values == null) {
                try sendPullError(gpa, stream, "02000", "no active result set", &.{}, &.{});
                return;
            }

            const start = state.result_page_index;
            const result = &state.active_result_values.?;

            const page = try proto_util.buildDataPage(pa, result, start, page_size, state.result_ordered, state.result_order_keys);
            state.result_page_index = start + page.rows.items.len;

            if (state.telemetry_paging) {
                var ps_buf: [32]u8 = undefined;
                const ps_str = std.fmt.bufPrint(&ps_buf, "{d}", .{page_size}) catch "0";
                var rows_buf: [32]u8 = undefined;
                const rows_str = std.fmt.bufPrint(&rows_buf, "{d}", .{page.rows.items.len}) catch "0";
                log.info("telemetry", &.{
                    Attr.string("type", "TELEMETRY"),
                    Attr.string("event", "PULL_PAGE"),
                    Attr.string("page_size", ps_str),
                    Attr.string("rows_emitted", rows_str),
                    Attr.string("final", if (page.final) "true" else "false"),
                });
            }

            const status = try proto_util.buildStatus(pa, "00000", result.flags.items);
            const resp = schema.ExecutionResponse{
                .status = status,
                .payload = .{ .page = page },
            };
            try sendQuicMessage(pa, stream, .{ .pull = .{ .response = resp } });

            if (page.final) {
                state.resetResult();
            }
        },
        .ping => {
            try sendQuicMessage(gpa, stream, .{ .ping = .{ .ok = true } });
        },
        .begin => |bg| {
            _ = bg;
            switch (try validateSessionAuth(gpa, state)) {
                .ok => {},
                else => {
                    try sendQuicMessage(gpa, stream, .{ .begin = .{ .session_id = try gpa.dupe(u8, ""), .tx_id = try gpa.dupe(u8, "") } });
                    return;
                },
            }
            if (state.in_txn) {
                try sendQuicMessage(gpa, stream, .{ .begin = .{ .session_id = try gpa.dupe(u8, ""), .tx_id = try gpa.dupe(u8, "") } });
                return;
            }

            state.in_txn = true;
            state.txn_id = @intCast(compat_milliTimestamp());
            state.session_snapshot_ts = state.global_commit_ts;
            txn_undo_log.getGlobalUndoLog(gpa).begin();

            // R9 (2026-04-22, updated): do NOT open a session engine txn
            // eagerly here.  Under the msft-graph DSN graph-binding flow
            // `state.current_graph` is null at BEGIN time — it gets
            // populated by the subsequent USE GRAPH that the DSN parser
            // emits OR by the first mutation statement's target_graph.
            // Opening on `DEFAULT_GRAPH_NAME` here would either (a) fall
            // back to per-statement R8 txns (graph mismatch) or (b) open
            // a stale session txn that the stream-close teardown in R3
            // has to roll back as an orphan (we saw this as the
            // `orphan-txn rolled back on stream close (graph=default)`
            // log-spam under the 16-worker ingest).
            //
            // Instead, the session engine txn is opened LAZILY on the
            // first mutation inside the Geode txn via
            // `ensureSessionEngineTxn` (see below + crud_operations.zig).
            // That guarantees the session txn is pinned to the graph the
            // first mutation actually targets.

            const tx_id_str = try std.fmt.allocPrint(gpa, "{d}", .{state.txn_id});
            try sendQuicMessage(gpa, stream, .{ .begin = .{ .session_id = try gpa.dupe(u8, "sess"), .tx_id = tx_id_str } });
        },
        .commit => {
            switch (try validateSessionAuth(gpa, state)) {
                .ok => {},
                else => {
                    try sendQuicMessage(gpa, stream, .{ .commit = .{ .success = false } });
                    return;
                },
            }
            if (state.in_txn) {
                // GAP-0511: COMMIT acquires the write lock for state cleanup only.
                // Index rebuilds are deferred to after lock release to prevent
                // the O(N) populateAdvancedIndex scan from blocking other connections.
                const commit_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                const undo = txn_undo_log.getGlobalUndoLog(gpa);
                {
                    const commit_lock = graph_store.acquireGraphWriteLock(commit_graph);
                    defer graph_store.releaseGraphLock(commit_lock);
                    undo.commitDeferRebuilds();

                    // R9 (2026-04-22): commit the session-scoped engine
                    // txn that R8's per-statement shortcut joined during
                    // this batch — ONE fsync for the whole Geode txn.
                    if (graph_store.getGlobalAdapter()) |ad| {
                        ad.commitSessionTxn() catch |err| switch (err) {
                            error.NoActiveSessionTxn => {},
                            else => log.warn("session engine txn commit failed", &.{
                                Attr.string("error", @errorName(err)),
                            }),
                        };
                    }
                }
                // Flush deferred index rebuilds outside the write lock.
                const store = graph_store.getGlobalStore(gpa);
                undo.flushPendingRebuilds(store);

                state.global_commit_ts += 1;
                state.in_txn = false;
                state.txn_id = 0;
                try sendQuicMessage(gpa, stream, .{ .commit = .{ .success = true } });
            } else {
                try sendQuicMessage(gpa, stream, .{ .commit = .{ .success = false } });
            }
        },
        .rollback => {
            switch (try validateSessionAuth(gpa, state)) {
                .ok => {},
                else => {
                    try sendQuicMessage(gpa, stream, .{ .rollback = .{ .success = false } });
                    return;
                },
            }
            if (state.in_txn) {
                // GAP-0001: Rollback reverses mutations on the store — needs exclusive lock
                // P1: Per-graph write lock scoped to the session's current graph.
                const rb_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                const rb_lock = graph_store.acquireGraphWriteLock(rb_graph);
                defer graph_store.releaseGraphLock(rb_lock);

                // R9 (2026-04-22): abort the session-scoped engine txn
                // first so any pending WAL page records are discarded
                // before the undo-log replay re-mutates the store.
                if (graph_store.getGlobalAdapter()) |ad| {
                    ad.abortSessionTxn();
                }

                const store = graph_store.getGlobalStore(gpa);
                txn_undo_log.getGlobalUndoLog(gpa).rollback(store) catch |err| {
                    log.err("Rollback failed", &.{Attr.string("error", @errorName(err))});
                };
                state.in_txn = false;
                state.txn_id = 0;
                try sendQuicMessage(gpa, stream, .{ .rollback = .{ .success = true } });
            } else {
                try sendQuicMessage(gpa, stream, .{ .rollback = .{ .success = false } });
            }
        },
        .savepoint => |sp_req| {
            // CANARY: REQ=REQ-TXN-SAVEPOINT-004; FEATURE="TransactionSavepoints"; ASPECT=QuicSavepoint; STATUS=TESTED; TEST=tests/test_gap0514_quic_handler.zig; OWNER=transport; UPDATED=2026-06-11
            switch (try validateSessionAuth(gpa, state)) {
                .ok => {},
                else => {
                    try sendQuicMessage(gpa, stream, .{ .savepoint = .{ .success = false } });
                    return;
                },
            }
            if (!state.in_txn) {
                try sendQuicMessage(gpa, stream, .{ .savepoint = .{ .success = false } });
            } else {
                const undo = txn_undo_log.getGlobalUndoLog(gpa);
                undo.createSavepoint(sp_req.name) catch {
                    try sendQuicMessage(gpa, stream, .{ .savepoint = .{ .success = false } });
                    return;
                };
                try sendQuicMessage(gpa, stream, .{ .savepoint = .{ .success = true } });
            }
        },
        .rollback_to => |rt_req| {
            // CANARY: REQ=REQ-TXN-SAVEPOINT-005; FEATURE="TransactionSavepoints"; ASPECT=QuicRollbackTo; STATUS=TESTED; TEST=tests/test_gap0514_quic_handler.zig; OWNER=transport; UPDATED=2026-06-11
            switch (try validateSessionAuth(gpa, state)) {
                .ok => {},
                else => {
                    try sendQuicMessage(gpa, stream, .{ .rollback_to = .{ .success = false } });
                    return;
                },
            }
            if (!state.in_txn) {
                try sendQuicMessage(gpa, stream, .{ .rollback_to = .{ .success = false } });
            } else {
                // P1: Per-graph write lock for rollback-to-savepoint.
                const rts_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                const rts_lock = graph_store.acquireGraphWriteLock(rts_graph);
                defer graph_store.releaseGraphLock(rts_lock);
                const store = graph_store.getGlobalStore(gpa);
                const undo = txn_undo_log.getGlobalUndoLog(gpa);
                undo.rollbackToSavepoint(rt_req.name, store) catch {
                    try sendQuicMessage(gpa, stream, .{ .rollback_to = .{ .success = false } });
                    return;
                };
                try sendQuicMessage(gpa, stream, .{ .rollback_to = .{ .success = true } });
            }
        },
        .cdc_diag => {
            if (state.cdc_engine) |eng| {
                const payload = try eng.exportDiagnostics(gpa);
                try sendQuicMessage(gpa, stream, .{ .cdc_diag = payload });
            } else {
                const payload = schema.CdcDiagnosticsResponse{
                    .config = .{ .enabled = false },
                    .engine = .{ .is_running = false },
                    .malformed_snapshots = std.ArrayList(schema.CdcMalformedSnapshot).empty,
                    .malformed_hashes = std.ArrayList(schema.CdcMalformedHash).empty,
                    .version = try gpa.dupe(u8, @import("build_options").version),
                    .timestamp_ms = compat_milliTimestamp(),
                };
                try sendQuicMessage(gpa, stream, .{ .cdc_diag = payload });
            }
        },
        .cdc_ctrl => |ctrl| {
            if (state.cdc_engine) |eng| {
                if (std.ascii.eqlIgnoreCase(ctrl.action, "RESET_GUARDRAILS")) {
                    eng.resetGuardrailState();
                    try sendQuicMessage(gpa, stream, .{ .cdc_ctrl = .{ .success = true, .status = try gpa.dupe(u8, "OK"), .guardrail_epoch = eng.guardrail_epoch } });
                } else {
                    try sendQuicMessage(gpa, stream, .{ .cdc_ctrl = .{ .success = false, .status = try gpa.dupe(u8, "UNSUPPORTED"), .guardrail_epoch = eng.guardrail_epoch } });
                }
            } else {
                try sendQuicMessage(gpa, stream, .{ .cdc_ctrl = .{ .success = false, .status = try gpa.dupe(u8, "NO_ENGINE"), .guardrail_epoch = 0 } });
            }
        },
        .backup => |backup_req| {
            switch (try validateSessionAuth(gpa, state)) {
                .ok => {},
                .missing => {
                    try sendQuicMessage(gpa, stream, .{ .backup = .{ .success = false, .message = try gpa.dupe(u8, "Authentication required") } });
                    return;
                },
                .invalidated => {
                    try sendQuicMessage(gpa, stream, .{ .backup = .{ .success = false, .message = try gpa.dupe(u8, "Session invalidated due to credential or role change") } });
                    return;
                },
            }
            // S2: Require Admin role for backup operations
            if (user_mgmt.isAuthEnabled()) {
                const is_admin = if (state.authenticated_role) |r|
                    @as(user_mgmt.Role, @enumFromInt(r)) == .Admin
                else
                    false;
                if (state.authenticated_user == null or !is_admin) {
                    try sendQuicMessage(gpa, stream, .{ .backup = .{ .success = false, .message = try gpa.dupe(u8, "Permission denied: Admin role required for backup operations") } });
                    return;
                }
            }
            // GAP-0001: Backup reads from the store — shared lock prevents
            // concurrent mutations from corrupting the snapshot.
            // NOTE: Backup is a cross-graph operation; global lock is intentional.
            // TODO(P1): Consider multi-graph lock acquisition for backup.
            graph_store.acquireStoreLock();
            defer graph_store.releaseStoreLock();
            const backup_dir = "./server_backups";
            const backup_config = BackupConfig{
                // GAP-0880: gzip is the only compression codec with a real
                // encoder; never request zstd (no encoder — it would fail
                // with UnsupportedCompression).
                .compression = if (backup_req.compress) .gzip else .none,
                .encryption = false,
                .retention_days = 30,
            };

            var mgr = SimplifiedBackupManager.init(gpa, backup_dir, backup_config) catch |err| {
                const msg_text = try std.fmt.allocPrint(gpa, "Backup init failed: {s}", .{@errorName(err)});
                try sendQuicMessage(gpa, stream, .{ .backup = .{ .success = false, .message = msg_text } });
                return;
            };
            defer mgr.deinit();

            const metadata = if (std.ascii.eqlIgnoreCase(backup_req.backup_type, "full"))
                (mgr.createFullBackup() catch |err| {
                    const msg_text = try std.fmt.allocPrint(gpa, "Backup failed: {s}", .{@errorName(err)});
                    try sendQuicMessage(gpa, stream, .{ .backup = .{ .success = false, .message = msg_text } });
                    return;
                })
            else {
                const msg_text = try gpa.dupe(u8, "Only full backups are supported with GraphStore");
                try sendQuicMessage(gpa, stream, .{ .backup = .{ .success = false, .message = msg_text } });
                return;
            };

            const backup_id = try std.fmt.allocPrint(gpa, "{x}", .{metadata.backup_id});
            const backup_type = try gpa.dupe(u8, @tagName(metadata.backup_type));
            const compression = try gpa.dupe(u8, @tagName(metadata.compression));
            const checksum = try std.fmt.allocPrint(gpa, "{x}", .{metadata.checksum});
            try sendQuicMessage(gpa, stream, .{ .backup = .{
                .success = true,
                .message = try gpa.dupe(u8, "Backup completed successfully"),
                .backup_id = backup_id,
                .backup_type = backup_type,
                .size_bytes = metadata.size_bytes,
                .compression = compression,
                .checksum = checksum,
            } });

            // Stream backup file bytes after sending metadata response.
            if (metadata.size_bytes > 0) {
                const backup_path = try std.fmt.allocPrint(gpa, "{s}/full_{x}.backup", .{ backup_dir, metadata.backup_id });
                defer gpa.free(backup_path);

                const io_bs = std.Io.Threaded.global_single_threaded.io();
                if (std.Io.Dir.cwd().openFile(io_bs, backup_path, .{})) |file| {
                    defer file.close(io_bs);
                    var buf: [65536]u8 = undefined;
                    var remaining: u64 = metadata.size_bytes;
                    var offset: u64 = 0;
                    while (remaining > 0) {
                        const chunk = @min(remaining, buf.len);
                        const n = file.readPositionalAll(io_bs, buf[0..chunk], offset) catch |err| {
                            log.err("Failed to read backup file", &.{
                                Attr.string("path", backup_path),
                                Attr.string("error", @errorName(err)),
                            });
                            break;
                        };
                        if (n == 0) break;
                        offset += n;
                        stream.writeAll(buf[0..n]) catch |err| {
                            log.err("Failed to stream backup bytes", &.{
                                Attr.string("path", backup_path),
                                Attr.string("error", @errorName(err)),
                            });
                            break;
                        };
                        remaining -= n;
                    }
                } else |err| {
                    log.err("Backup file missing for streaming", &.{
                        Attr.string("path", backup_path),
                        Attr.string("error", @errorName(err)),
                    });
                }
            }
        },
        .restore => |restore_req| {
            switch (try validateSessionAuth(gpa, state)) {
                .ok => {},
                .missing => {
                    try sendQuicMessage(gpa, stream, .{ .restore = .{ .success = false, .message = try gpa.dupe(u8, "Authentication required") } });
                    return;
                },
                .invalidated => {
                    try sendQuicMessage(gpa, stream, .{ .restore = .{ .success = false, .message = try gpa.dupe(u8, "Session invalidated due to credential or role change") } });
                    return;
                },
            }
            // S2: Require Admin role for restore operations
            if (user_mgmt.isAuthEnabled()) {
                const is_admin = if (state.authenticated_role) |r|
                    @as(user_mgmt.Role, @enumFromInt(r)) == .Admin
                else
                    false;
                if (state.authenticated_user == null or !is_admin) {
                    try sendQuicMessage(gpa, stream, .{ .restore = .{ .success = false, .message = try gpa.dupe(u8, "Permission denied: Admin role required for restore operations") } });
                    return;
                }
            }
            // GAP-0001: Restore mutates on-disk state — exclusive write lock
            // NOTE: Restore is a cross-graph operation; global lock is intentional.
            // TODO(P1): Consider multi-graph lock acquisition for restore.
            graph_store.acquireStoreWriteLock();
            defer graph_store.releaseStoreWriteLock();
            if (!restore_req.confirm) {
                const msg_text = try gpa.dupe(u8, "Restore requires confirmation");
                try sendQuicMessage(gpa, stream, .{ .restore = .{ .success = false, .message = msg_text } });
                return;
            }

            const backup_config = BackupConfig{
                // Restore reads the codec from each backup file's header;
                // the config codec is irrelevant here. Keep the honest
                // default (.none) — .zstd has no encoder (GAP-0880).
                .compression = .none,
                .encryption = false,
                .retention_days = 30,
            };
            var mgr = SimplifiedBackupManager.init(gpa, "./server_backups", backup_config) catch |err| {
                const msg_text = try std.fmt.allocPrint(gpa, "Restore init failed: {s}", .{@errorName(err)});
                try sendQuicMessage(gpa, stream, .{ .restore = .{ .success = false, .message = msg_text } });
                return;
            };
            defer mgr.deinit();

            const target_time: i64 = if (restore_req.target_time.len > 0)
                std.fmt.parseInt(i64, restore_req.target_time, 10) catch compat_milliTimestamp()
            else
                compat_milliTimestamp();

            const restore_dir = if (getEnvVarOwned(gpa, "GEODE_DATA_DIR")) |dir| blk: {
                defer gpa.free(dir);
                break :blk try gpa.dupe(u8, dir);
            } else |_| try gpa.dupe(u8, "./data");

            mgr.restoreToPointInTime(target_time, restore_dir) catch |err| {
                const msg_text = try std.fmt.allocPrint(gpa, "Restore failed: {s}", .{@errorName(err)});
                try sendQuicMessage(gpa, stream, .{ .restore = .{ .success = false, .message = msg_text } });
                gpa.free(restore_dir);
                return;
            };

            const ts = compat_milliTimestamp();
            try sendQuicMessage(gpa, stream, .{ .restore = .{
                .success = true,
                .message = try gpa.dupe(u8, "Restore completed"),
                .restore_dir = restore_dir,
                .target_time = try gpa.dupe(u8, if (restore_req.target_time.len > 0) restore_req.target_time else "latest"),
                .restore_timestamp = @intCast(ts),
            } });
        },
        .upload_backup => |upload_req| {
            switch (try validateSessionAuth(gpa, state)) {
                .ok => {},
                .missing => {
                    try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = false, .message = try gpa.dupe(u8, "Authentication required") } });
                    return;
                },
                .invalidated => {
                    try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = false, .message = try gpa.dupe(u8, "Session invalidated due to credential or role change") } });
                    return;
                },
            }
            // S2: Require Admin role for backup upload operations
            if (user_mgmt.isAuthEnabled()) {
                const is_admin = if (state.authenticated_role) |r|
                    @as(user_mgmt.Role, @enumFromInt(r)) == .Admin
                else
                    false;
                if (state.authenticated_user == null or !is_admin) {
                    try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = false, .message = try gpa.dupe(u8, "Permission denied: Admin role required for backup upload") } });
                    return;
                }
            }
            // GAP-0880: real upload ingestion. The request must carry the
            // complete backup artifact bytes; the old metadata-only path
            // created an EMPTY file and reported fake success.
            if (upload_req.size_bytes == 0 or upload_req.checksum.len == 0) {
                try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = false, .message = try gpa.dupe(u8, "Invalid upload request: missing size or checksum") } });
                return;
            }
            if (upload_req.payload.len == 0) {
                try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = false, .message = try gpa.dupe(u8, "Upload payload required: metadata-only upload is not supported") } });
                return;
            }
            if (upload_req.payload.len != upload_req.size_bytes) {
                const msg_text = try std.fmt.allocPrint(gpa, "Upload size mismatch: declared {d} bytes, received {d}", .{ upload_req.size_bytes, upload_req.payload.len });
                try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = false, .message = msg_text } });
                return;
            }
            const expected_checksum = std.fmt.parseInt(u64, upload_req.checksum, 16) catch {
                try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = false, .message = try gpa.dupe(u8, "Invalid checksum: expected hex CRC32 from BackupResponse") } });
                return;
            };

            var upload_mgr = SimplifiedBackupManager.init(gpa, "./server_backups", .{}) catch |err| {
                const msg_text = try std.fmt.allocPrint(gpa, "Upload init failed: {s}", .{@errorName(err)});
                try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = false, .message = msg_text } });
                return;
            };
            defer upload_mgr.deinit();

            const ingested = upload_mgr.ingestUploadedBackup(upload_req.payload, expected_checksum) catch |err| {
                const msg_text = try std.fmt.allocPrint(gpa, "Upload rejected: {s}", .{@errorName(err)});
                try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = false, .message = msg_text } });
                return;
            };

            const stored_path = try std.fmt.allocPrint(gpa, "./server_backups/full_{x}.backup", .{ingested.backup_id});
            try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = true, .message = try gpa.dupe(u8, "Backup uploaded, verified, and registered"), .upload_path = stored_path } });
        },
    }
}

test "SharedConnState syncGraphFromState updates inherited graph" {
    const allocator = std.testing.allocator;

    var shared = SharedConnState{ .allocator = allocator };
    defer shared.deinit();

    var state = ServerState{ .allocator = allocator };
    state.exec_session = execution.SessionState.init(allocator);
    defer if (state.exec_session) |*session| session.deinit();

    state.exec_session.?.graph = try allocator.dupe(u8, "test_graph_inherited");
    try shared.syncGraphFromState(&state);
    try std.testing.expect(shared.current_graph != null);
    try std.testing.expectEqualStrings("test_graph_inherited", shared.current_graph.?);

    allocator.free(state.exec_session.?.graph.?);
    state.exec_session.?.graph = try allocator.dupe(u8, "__geode_security");
    try shared.syncGraphFromState(&state);
    try std.testing.expect(shared.current_graph != null);
    try std.testing.expectEqualStrings("__geode_security", shared.current_graph.?);
}

test "SharedConnState syncGraphFromState clears inherited graph on reset" {
    const allocator = std.testing.allocator;

    var shared = SharedConnState{ .allocator = allocator };
    defer shared.deinit();

    var state = ServerState{ .allocator = allocator };
    state.exec_session = execution.SessionState.init(allocator);
    defer if (state.exec_session) |*session| session.deinit();

    state.exec_session.?.graph = try allocator.dupe(u8, "test_graph_inherited");
    try shared.syncGraphFromState(&state);
    try std.testing.expect(shared.current_graph != null);

    allocator.free(state.exec_session.?.graph.?);
    state.exec_session.?.graph = null;
    try shared.syncGraphFromState(&state);
    try std.testing.expect(shared.current_graph == null);
}

test "SharedConnState registerActiveStream deduplicates requeued stream ids" {
    const allocator = std.testing.allocator;

    var shared = SharedConnState{ .allocator = allocator };
    defer shared.deinit();

    try std.testing.expect(try shared.registerActiveStream(4));
    try std.testing.expect(!try shared.registerActiveStream(4));
    try std.testing.expectEqual(@as(usize, 1), shared.active_stream_registry.count());

    shared.unregisterActiveStream(4);
    try std.testing.expectEqual(@as(usize, 0), shared.active_stream_registry.count());
    try std.testing.expect(try shared.registerActiveStream(4));
}

test "isIdleStreamReadError treats timeout as idle shutdown" {
    try std.testing.expect(isIdleStreamReadError(error.EndOfStream));
    try std.testing.expect(isIdleStreamReadError(error.Timeout));
    try std.testing.expect(isIdleStreamReadError(error.Closed));
    try std.testing.expect(!isIdleStreamReadError(error.WouldBlock));
}

// PERF-P1-004: Verify the global stream throttle is wired and configurable.
test "setMaxGlobalStreamThreads updates global throttle limit" {
    // The default should be the constant from active_stream_registry.
    try std.testing.expectEqual(
        stream_registry.default_max_global_stream_threads,
        g_stream_throttle.max,
    );

    // Override with a custom value.
    setMaxGlobalStreamThreads(128);
    try std.testing.expectEqual(@as(u32, 128), g_stream_throttle.max);

    // Zero resets to the default.
    setMaxGlobalStreamThreads(0);
    try std.testing.expectEqual(
        stream_registry.default_max_global_stream_threads,
        g_stream_throttle.max,
    );

    // Verify the counter API.
    try std.testing.expectEqual(@as(u32, 0), getGlobalStreamThreadCount());
}

test "global stream throttle acquire and release are symmetric" {
    // Use a small limit so the test is fast and deterministic.
    setMaxGlobalStreamThreads(2);
    defer setMaxGlobalStreamThreads(0); // restore default

    try g_stream_throttle.acquire(0);
    try g_stream_throttle.acquire(0);
    try std.testing.expectEqual(@as(u32, 2), getGlobalStreamThreadCount());

    // Third acquire must fail (limit = 2).
    try std.testing.expectError(
        stream_registry.ThrottleError.GlobalStreamLimitExceeded,
        g_stream_throttle.acquire(0),
    );

    // Release one, then acquire succeeds.
    g_stream_throttle.release();
    try g_stream_throttle.acquire(0);
    try std.testing.expectEqual(@as(u32, 2), getGlobalStreamThreadCount());

    // Cleanup.
    g_stream_throttle.release();
    g_stream_throttle.release();
    try std.testing.expectEqual(@as(u32, 0), getGlobalStreamThreadCount());
}

test "detached first-stream owner gate is configurable and bounded" {
    setMaxDetachedFirstStreamOwners(2);
    defer setMaxDetachedFirstStreamOwners(0);

    try std.testing.expectEqual(@as(u32, 2), getMaxDetachedFirstStreamOwners());
    try std.testing.expectEqual(@as(u32, 0), getDetachedFirstStreamOwnerCount());

    try std.testing.expect(g_first_stream_detach_gate.tryAcquire());
    try std.testing.expect(g_first_stream_detach_gate.tryAcquire());
    try std.testing.expectEqual(@as(u32, 2), getDetachedFirstStreamOwnerCount());
    try std.testing.expect(!g_first_stream_detach_gate.tryAcquire());

    g_first_stream_detach_gate.release();
    try std.testing.expect(g_first_stream_detach_gate.tryAcquire());

    g_first_stream_detach_gate.release();
    g_first_stream_detach_gate.release();
    try std.testing.expectEqual(@as(u32, 0), getDetachedFirstStreamOwnerCount());

    setMaxDetachedFirstStreamOwners(0);
    try std.testing.expectEqual(default_detached_first_stream_owner_threads, getMaxDetachedFirstStreamOwners());
}

test "SharedConnState: waitForStreamSlot wakes when active stream releases" {
    const allocator = std.testing.allocator;
    var state = SharedConnState{ .allocator = allocator };
    defer state.deinit();

    _ = state.active_streams.fetchAdd(1, .release);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *SharedConnState) void {
            const req = std.os.linux.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            var rem: std.os.linux.timespec = undefined;
            _ = std.os.linux.nanosleep(&req, &rem);
            s.releaseActiveStream();
        }
    }.run, .{&state});

    state.waitForStreamSlot(1, 1 * std.time.ns_per_s);
    thread.join();
    try std.testing.expect(state.active_streams.load(.acquire) < 1);
}

test "SharedConnState: waitForAllStreamsDrained parks until release" {
    const allocator = std.testing.allocator;
    var state = SharedConnState{ .allocator = allocator };
    defer state.deinit();

    _ = state.active_streams.fetchAdd(1, .release);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *SharedConnState) void {
            const req = std.os.linux.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            var rem: std.os.linux.timespec = undefined;
            _ = std.os.linux.nanosleep(&req, &rem);
            s.releaseActiveStream();
        }
    }.run, .{&state});

    state.waitForAllStreamsDrained();
    thread.join();
    try std.testing.expectEqual(@as(u32, 0), state.active_streams.load(.acquire));
}

// =============================================================================
// StreamAcceptorContext lifetime tests (2026-04-28)
//
// Pin the heap+refcount lifetime model that replaced the previous
// stack-allocated context.  The original bug: a busy acceptor that hadn't
// observed `shutdown=true` within the owner's 5-second wait deadline got
// its stack-allocated `acceptor_ctx` ripped out from under it, segfaulting
// on the next `shutdown.load(.acquire)` (address 0x6 because the popped
// stack memory had been reused with small-int garbage at the offset where
// the `shutdown` pointer field used to live).
//
// The new model:
//   * struct is heap-allocated via `StreamAcceptorContext.create`,
//   * starts with refcount=2 (owner + acceptor),
//   * `release()` decrements; the last caller frees,
//   * atomics live INSIDE the struct (not as pointers to stack vars), so
//     the acceptor's loop body can dereference them safely even if the
//     owner has already given up waiting.
// =============================================================================

test "StreamAcceptorContext: create allocates heap struct with refcount=2" {
    const allocator = std.testing.allocator;
    // The struct holds pointers to externally-owned objects.  For this
    // unit test we only exercise the heap allocation + refcount semantics
    // — the pointed-to fields never get dereferenced — so undefined dummy
    // pointers are fine and won't escape the test scope.
    const dummy_transport: *quic_transport.QuicTransport = @ptrFromInt(0xDEAD_BEEF_0001);
    const dummy_conn: *quic_transport.QuicConnection = @ptrFromInt(0xDEAD_BEEF_0002);
    var dummy_conn_state: SharedConnState = .{ .allocator = allocator };
    defer dummy_conn_state.deinit();
    const dummy_pool: *pooled.ThreadPool = @ptrFromInt(0xDEAD_BEEF_0004);

    const ctx = try StreamAcceptorContext.create(
        allocator,
        dummy_transport,
        dummy_conn,
        &dummy_conn_state,
        dummy_pool,
    );

    try std.testing.expectEqual(@as(u32, 2), ctx.refcount.load(.acquire));
    try std.testing.expectEqual(false, ctx.shutdown.load(.acquire));
    try std.testing.expectEqual(false, ctx.done.load(.acquire));
    try std.testing.expectEqual(allocator.vtable, ctx.allocator.vtable);
    try std.testing.expect(ctx.transport == dummy_transport);
    try std.testing.expect(ctx.conn == dummy_conn);
    try std.testing.expect(ctx.conn_state == &dummy_conn_state);
    try std.testing.expect(ctx.stream_pool == dummy_pool);

    // Two releases — owner + (would-be) acceptor — bring refcount to zero
    // and free the struct.  Testing-allocator leak detection will fail
    // the test if the second release didn't actually free.
    ctx.release();
    ctx.release();
}

test "StreamAcceptorContext: single release does not free (refcount stays >0)" {
    const allocator = std.testing.allocator;
    const dummy_transport: *quic_transport.QuicTransport = @ptrFromInt(0xDEAD_BEEF_0001);
    const dummy_conn: *quic_transport.QuicConnection = @ptrFromInt(0xDEAD_BEEF_0002);
    var dummy_conn_state: SharedConnState = .{ .allocator = allocator };
    defer dummy_conn_state.deinit();
    const dummy_pool: *pooled.ThreadPool = @ptrFromInt(0xDEAD_BEEF_0004);

    const ctx = try StreamAcceptorContext.create(
        allocator,
        dummy_transport,
        dummy_conn,
        &dummy_conn_state,
        dummy_pool,
    );

    ctx.release();
    // Refcount must be exactly 1; struct must NOT be freed (we'd UAF on
    // the load if it were).  This pins the "owner gave up first, acceptor
    // is still running" scenario that the heap model is designed to
    // tolerate.
    try std.testing.expectEqual(@as(u32, 1), ctx.refcount.load(.acquire));

    // Final release frees.  Without this, the testing allocator's leak
    // detector will fail the test.
    ctx.release();
}

test "StreamAcceptorContext: shutdown/done atomics survive owner release" {
    // Pins the core invariant of the heap-based lifetime: the acceptor
    // can read `ctx.shutdown` and write `ctx.done` AFTER the owner has
    // already called release().  Pre-fix, this was the segfault site
    // (stack-allocated atomics, popped frame, address 0x6 garbage).
    const allocator = std.testing.allocator;
    const dummy_transport: *quic_transport.QuicTransport = @ptrFromInt(0xDEAD_BEEF_0001);
    const dummy_conn: *quic_transport.QuicConnection = @ptrFromInt(0xDEAD_BEEF_0002);
    var dummy_conn_state: SharedConnState = .{ .allocator = allocator };
    defer dummy_conn_state.deinit();
    const dummy_pool: *pooled.ThreadPool = @ptrFromInt(0xDEAD_BEEF_0004);

    const ctx = try StreamAcceptorContext.create(
        allocator,
        dummy_transport,
        dummy_conn,
        &dummy_conn_state,
        dummy_pool,
    );

    // Owner side: signal shutdown, then release.  The struct must stay
    // alive because the acceptor (refcount holder #2) hasn't released
    // yet.
    ctx.shutdown.store(true, .release);
    ctx.release();

    // Acceptor side: read shutdown (should be true), write done.  These
    // accesses MUST NOT crash — the heap struct is still alive.
    try std.testing.expectEqual(true, ctx.shutdown.load(.acquire));
    ctx.markDone();
    try std.testing.expectEqual(true, ctx.done.load(.acquire));
    try std.testing.expect(ctx.done_generation.load(.acquire) > 0);

    // Acceptor's release brings refcount to 0 and frees.
    ctx.release();
}

test "StreamAcceptorContext: waitUntilDone wakes on markDone" {
    const allocator = std.testing.allocator;
    const dummy_transport: *quic_transport.QuicTransport = @ptrFromInt(0xDEAD_BEEF_0001);
    const dummy_conn: *quic_transport.QuicConnection = @ptrFromInt(0xDEAD_BEEF_0002);
    var dummy_conn_state: SharedConnState = .{ .allocator = allocator };
    defer dummy_conn_state.deinit();
    const dummy_pool: *pooled.ThreadPool = @ptrFromInt(0xDEAD_BEEF_0004);

    const ctx = try StreamAcceptorContext.create(
        allocator,
        dummy_transport,
        dummy_conn,
        &dummy_conn_state,
        dummy_pool,
    );

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(c: *StreamAcceptorContext) void {
            const req = std.os.linux.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            var rem: std.os.linux.timespec = undefined;
            _ = std.os.linux.nanosleep(&req, &rem);
            c.markDone();
        }
    }.run, .{ctx});

    try std.testing.expect(ctx.waitUntilDone(1 * std.time.ns_per_s));
    thread.join();
    ctx.release();
    ctx.release();
}

test "StreamAcceptorContext: concurrent release from two threads is safe" {
    // Stress-tests the refcount atomics under racy release.  Spawns two
    // threads that each call `release()` once.  Exactly one of them must
    // observe the "last release" path (refcount transitions 1 -> 0) and
    // free the struct.  No double-free, no use-after-free, no leak.
    //
    // Repeated 256 times to amplify the probability of catching a race.
    const allocator = std.testing.allocator;
    const dummy_transport: *quic_transport.QuicTransport = @ptrFromInt(0xDEAD_BEEF_0001);
    const dummy_conn: *quic_transport.QuicConnection = @ptrFromInt(0xDEAD_BEEF_0002);
    var dummy_conn_state: SharedConnState = .{ .allocator = allocator };
    defer dummy_conn_state.deinit();
    const dummy_pool: *pooled.ThreadPool = @ptrFromInt(0xDEAD_BEEF_0004);

    const Worker = struct {
        fn run(c: *StreamAcceptorContext) void {
            c.release();
        }
    };

    var trial: usize = 0;
    while (trial < 256) : (trial += 1) {
        const ctx = try StreamAcceptorContext.create(
            allocator,
            dummy_transport,
            dummy_conn,
            &dummy_conn_state,
            dummy_pool,
        );
        const t1 = try std.Thread.spawn(.{}, Worker.run, .{ctx});
        const t2 = try std.Thread.spawn(.{}, Worker.run, .{ctx});
        t1.join();
        t2.join();
        // Both threads have released; refcount should have hit zero and
        // freed.  The testing allocator catches any leak / double-free.
    }
}

// 2026-04-28 — owner-bails-before-acceptor regression.
//
// Pre-fix (b6ec55c3): the owner's wait-for-done loop had no deadline, so a
// stuck acceptor wedged the connection-handler thread forever.  Live repro
// on PID 2625755: 8 active conns, owner threads spinning at line 2150 with
// `elapsed_ms` climbing past 300 s, the main accept loop starved on
// ep.mu.  Post-fix: the owner waits up to 30 s, then bails and releases
// its ref.  The struct stays alive (refcount still 1 from the acceptor's
// ref) and is freed when the acceptor eventually exits.
//
// This test simulates the bail by having the OWNER release its ref WITHOUT
// waiting for done, then the acceptor continues using `ctx.shutdown` and
// `ctx.done` safely from a separate thread, eventually releases its own
// ref, and the heap struct is freed cleanly.  The testing allocator's
// leak detector catches any UAF or leak.
test "StreamAcceptorContext: owner-bails-then-acceptor-finishes does not UAF or leak" {
    const allocator = std.testing.allocator;
    const dummy_transport: *quic_transport.QuicTransport = @ptrFromInt(0xDEAD_0000_1000);
    const dummy_conn: *quic_transport.QuicConnection = @ptrFromInt(0xDEAD_0000_2000);
    var dummy_conn_state: SharedConnState = .{ .allocator = allocator };
    defer dummy_conn_state.deinit();
    const dummy_pool: *pooled.ThreadPool = @ptrFromInt(0xDEAD_0000_3000);

    const Acceptor = struct {
        fn run(c: *StreamAcceptorContext) void {
            // Spin-loop emulating the real acceptor: read shutdown each
            // iteration, sleep briefly, exit when shutdown=true.  This
            // path runs AFTER the owner has released its ref (refcount=1),
            // so any access to a freed struct would crash here.
            var spins: usize = 0;
            while (!c.shutdown.load(.acquire)) {
                const req = std.os.linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_us };
                var rem: std.os.linux.timespec = undefined;
                _ = std.os.linux.nanosleep(&req, &rem);
                spins += 1;
                if (spins > 10_000) {
                    // Safety: bail if shutdown never arrives (test bug).
                    break;
                }
            }
            // Mirror the real defer order: mark done, then release.
            c.markDone();
            c.release();
        }
    };

    const ctx = try StreamAcceptorContext.create(
        allocator,
        dummy_transport,
        dummy_conn,
        &dummy_conn_state,
        dummy_pool,
    );

    // Spawn the acceptor with refcount=2 (owner+acceptor).
    const accept_thread = try std.Thread.spawn(.{}, Acceptor.run, .{ctx});

    // Owner side: simulate the bail path.  Signal shutdown, then release
    // WITHOUT waiting for done.  The acceptor continues to read `shutdown`
    // and write `done`/`refcount` after this point.
    ctx.shutdown.store(true, .release);
    ctx.release();

    // Refcount is now 1 (acceptor still holds its ref).  The acceptor
    // will see shutdown=true on its next iteration and exit cleanly.
    accept_thread.join();
    // After join, the acceptor has fully exited (its release() ran and
    // freed the struct because refcount went 1 -> 0).  Any leak or
    // double-free here would surface via the testing allocator.
}

// =============================================================================
// 2026-06-03 — acceptor-shutdown bail-deadline regression.
//
// Bug: docs/bugs/2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md
//
// `shutdownAcceptorOwner` runs on the first-stream owner thread (a capped
// stream-pool worker / first-stream detach-gate slot). Under a connection-burst
// + close-churn the per-connection acceptor can wedge inside the QUIC library on
// endpoint-lock contention and never observe `ctx.shutdown`. The owner used to
// wait up to 30 s for it, pinning that capped slot the whole time; a burst of
// such closures exhausts the pool/gate, so NEW connections can no longer be
// admitted ("transport dial ... timeout: no recent network activity") until a
// pod restart. The fix caps the owner-side wait at a short, env-tunable deadline
// (default 1 s) and defers the wedged conn to the already-safe leaked-conn
// reaper, so capped slots free ~30x faster and the accept path survives the
// burst. These tests pin (a) the short bail deadline is honored (not 30 s),
// (b) a healthy acceptor that exits in time does NOT bail, and (c) the env
// override parses + clamps sanely (regression guard against reverting to 30 s).
// =============================================================================

test "acceptor bail deadline: wedged acceptor bails within the short deadline (not 30s)" {
    const allocator = std.testing.allocator;
    const dummy_transport: *quic_transport.QuicTransport = @ptrFromInt(0xDEAD_2026_0601);
    const dummy_conn: *quic_transport.QuicConnection = @ptrFromInt(0xDEAD_2026_0602);
    var dummy_conn_state: SharedConnState = .{ .allocator = allocator };
    defer dummy_conn_state.deinit();
    const dummy_pool: *pooled.ThreadPool = @ptrFromInt(0xDEAD_2026_0604);

    const ctx = try StreamAcceptorContext.create(
        allocator,
        dummy_transport,
        dummy_conn,
        &dummy_conn_state,
        dummy_pool,
    );
    // No acceptor thread runs here, so `done` is never set — the "wedged
    // acceptor" case. We hold both refs (owner + would-be acceptor) and free
    // them at the end.
    defer {
        ctx.release();
        ctx.release();
    }

    const start = compat_milliTimestamp();
    const bailed = waitForAcceptorExit(ctx, 150, 75);
    const elapsed = compat_milliTimestamp() - start;

    try std.testing.expect(bailed); // deadline elapsed before done -> defer to reaper
    try std.testing.expect(elapsed >= 150); // honored the deadline
    try std.testing.expect(elapsed < 5_000); // nowhere near the old 30 s
}

test "acceptor bail deadline: a timely acceptor exit does NOT bail" {
    const allocator = std.testing.allocator;
    const dummy_transport: *quic_transport.QuicTransport = @ptrFromInt(0xDEAD_2026_0611);
    const dummy_conn: *quic_transport.QuicConnection = @ptrFromInt(0xDEAD_2026_0612);
    var dummy_conn_state: SharedConnState = .{ .allocator = allocator };
    defer dummy_conn_state.deinit();
    const dummy_pool: *pooled.ThreadPool = @ptrFromInt(0xDEAD_2026_0614);

    const ctx = try StreamAcceptorContext.create(
        allocator,
        dummy_transport,
        dummy_conn,
        &dummy_conn_state,
        dummy_pool,
    );

    // Acceptor exits ~20 ms after being signalled — well within a 5 s deadline.
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(c: *StreamAcceptorContext) void {
            const req = std.os.linux.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
            var rem: std.os.linux.timespec = undefined;
            _ = std.os.linux.nanosleep(&req, &rem);
            c.markDone();
        }
    }.run, .{ctx});

    const bailed = waitForAcceptorExit(ctx, 5_000, 1_000);
    thread.join();

    try std.testing.expect(!bailed); // exited in time -> owner tears down inline
    ctx.release();
    ctx.release();
}

test "acceptor bail deadline: env parse defaults, clamps, and stays short" {
    // Regression guard: the default must never silently revert to the old 30 s.
    try std.testing.expect(default_acceptor_bail_deadline_ms >= 100);
    try std.testing.expect(default_acceptor_bail_deadline_ms <= 5_000);

    // Pure env-value parser: default on null/garbage, clamp to [50, 60000].
    try std.testing.expectEqual(default_acceptor_bail_deadline_ms, parseAcceptorBailMs(null));
    try std.testing.expectEqual(default_acceptor_bail_deadline_ms, parseAcceptorBailMs("garbage"));
    try std.testing.expectEqual(@as(i64, 2000), parseAcceptorBailMs("2000"));
    try std.testing.expectEqual(@as(i64, 50), parseAcceptorBailMs("0")); // clamp low
    try std.testing.expectEqual(@as(i64, 60_000), parseAcceptorBailMs("100000000")); // clamp high
}

// =============================================================================
// REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME — FirstStreamOwnerContext use-after-free
// =============================================================================
//
// CANARY: REQ=REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME; FEATURE="QuicTransport"; ASPECT=FirstStreamOwnerLifetime; STATUS=TESTED; TEST=tests/test_first_stream_owner_lifetime.zig; OWNER=server; UPDATED=2026-06-10
//
// Diagnosed SIGSEGV (GP fault) in std.mem.readInt at decodeBufferedMessage
// (inlined into nextMessage) under concurrent load. Root cause: a
// `FirstStreamOwnerContext` was freed by the detached cleanup path
// (`finishCooperativeContext` -> `cleanupFirstStreamOwnerAsync` ->
// `destroyFirstStreamOwnerResources` -> `gpa.destroy(ctx)`) while the
// poll-thread RX-ready notifier `firstStreamReadyCallback` and the detached
// read loop still referenced the SAME allocation.
//
// FIX (2026-06-10): `owner_refs` lifetime refcount + the notifier quiesce gate
// (`notifier_inflight` / `waitNotifierDrained`), mirroring the heap-refcounted
// `StreamAcceptorContext`. `submit` takes a notifier ref; `cleanupFirstStreamOwner`
// clears + drains the notifier before releasing it; `destroyFirstStreamOwnerResources`
// frees behind `releaseOwnerRef` (last release destroys). The `submit` contract
// also changed so the caller never derefs the ctx after publication.
//
// These tests were RED pre-fix and are GREEN post-fix. They run under
// std.testing.allocator, whose UAF/double-free/leak detection is the oracle.
// The build step `test-first-stream-owner-lifetime` roots the full server
// module and filters to these test names + the matching ones in
// tests/test_first_stream_owner_lifetime.zig, and IS now wired into the sharded
// `zig build test` aggregate.

// Serialize the few tests that toggle the process-global cleanup barrier so
// they don't race each other within the test binary. Zig 0.16 retired
// `std.Thread.Mutex`; use a tiny atomic CAS spinlock (test-only, low
// contention).
const FirstStreamTestLock = struct {
    held: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *FirstStreamTestLock) void {
        while (self.held.cmpxchgWeak(false, true, .acq_rel, .acquire) != null) {
            std.Thread.yield() catch {};
        }
    }
    fn unlock(self: *FirstStreamTestLock) void {
        self.held.store(false, .release);
    }
};
var g_first_stream_lifetime_test_lock: FirstStreamTestLock = .{};

// REGRESSION (deterministic-red): the cleanup free must be coordinated with the
// RX-ready notifier via the lifetime refcount; today it is not, so the free can
// reclaim the FirstStreamOwnerContext while a notifier still holds a reference.
//
// Oracle: a free-COUNTER. Both the async-cleanup side and the notifier/reader
// side decide independently whether THEY are responsible for the final free.
// The correct contract is "exactly one freeing release" — the one that brings
// `owner_refs` to zero. We make the window deterministic with a barrier so the
// two sides overlap on every run (not 50/50 timing).
//
//   * Pre-fix: the production teardown frees UNCONDITIONALLY (no `owner_refs`
//     check — modeled by `destroyOwnerUnsynchronized`), so it frees even though
//     the reader still holds a ref. The reader then ALSO performs the last
//     release and frees. Result: TWO frees of one allocation -> the testing
//     allocator reports a double-free / the freed-pointer access is flagged,
//     and the `free_count == 1` assertion fails. RED.
//   * Post-fix: the teardown is refcount-gated (`destroyOwnerGated`); with the
//     reader's ref outstanding the teardown release is NOT the last one, so the
//     reader's later release is the single free. `free_count == 1`. GREEN.
//
// CONTRACT CHANGE the fixer must make here (noted in the report): once the
// production free honors `owner_refs`, BOTH the cleanup side and the reader
// side call `destroyOwnerGated()` (instead of the unsynchronized free), and the
// `free_count == 1` assertion then holds because exactly one release is last.
test "first_stream_owner_notifier_vs_async_free_regression" {
    g_first_stream_lifetime_test_lock.lock();
    defer g_first_stream_lifetime_test_lock.unlock();

    const allocator = std.testing.allocator;
    var harness = try FirstStreamLifetimeTestHarness.init(allocator);

    // Reader takes a lifetime ref BEFORE touching the ctx — the exact retain the
    // fix must add at the notifier entry so the async free cannot reclaim the
    // allocation underneath it. owner_refs: 1 -> 2.
    harness.ctx.retainOwnerRef();

    var free_count = std.atomic.Value(u32).init(0);

    // PRE-FIX behavior: today the production teardown frees UNCONDITIONALLY
    // (`destroyFirstStreamOwnerResources` ends with `gpa.destroy(ctx)` with no
    // refcount), and an uncoordinated reader that finishes its access likewise
    // has nothing telling it the ctx is still in use. Model both sides as the
    // unsynchronized free so the lack of coordination is explicit. Two frees of
    // one allocation -> the testing allocator reports a double-free. RED.
    //
    // POST-FIX (fixer swaps these two `destroyOwnerUnsynchronized()` calls for
    // `if (destroyOwnerGated()) _ = free_count.fetchAdd(1, .acq_rel)`): the
    // refcount makes exactly one release the last -> a single free. GREEN.
    // CONTRACT CHANGE (fix landed): both sides now call `destroyOwnerGated()`,
    // the refcount-gated free the production teardown adopted
    // (`destroyFirstStreamOwnerResources` -> `releaseOwnerRef`-gated
    // `gpa.destroy`). Only the release that brings `owner_refs` to zero frees,
    // so exactly one of the two releases (reader vs. cleanup) performs the
    // single `gpa.destroy(ctx)`. `free_count == 1`. GREEN.
    const Reader = struct {
        h: *FirstStreamLifetimeTestHarness,
        gate: *FirstStreamTestGate,
        free_count: *std.atomic.Value(u32),
        fn run(self: *@This()) void {
            self.h.fireReadyNotifier(); // REAL notifier access while ref held
            self.gate.wait(); // overlap with the cleanup free on every run
            if (self.h.destroyOwnerGated()) _ = self.free_count.fetchAdd(1, .acq_rel);
        }
    };

    var gate: FirstStreamTestGate = .{};
    var reader = Reader{ .h = &harness, .gate = &gate, .free_count = &free_count };
    const t = try std.Thread.spawn(.{}, Reader.run, .{&reader});

    // Cleanup side: the gated production free, then release the gate so the
    // reader's release overlaps. Exactly one of the two releases is the last.
    if (harness.destroyOwnerGated()) _ = free_count.fetchAdd(1, .acq_rel);
    gate.set();
    t.join();

    // Exactly one freeing release is the contract. Pre-fix this is 2 (RED:
    // double free already reported by the testing allocator above).
    try std.testing.expectEqual(@as(u32, 1), free_count.load(.acquire));
    harness.deinit(true);
}

// SUBMIT-WINDOW REGRESSION (deterministic-red): `FirstStreamScheduler.submit`
// (:2890) publishes the ctx to workers (via `enqueueReady`) BEFORE returning,
// and the caller (`handleQuicConnection` :4171) then reads
// `first_ctx.cooperative_scheduler` to decide whether the owner was scheduled.
// A worker can finish the owner and async-free the ctx between the publish and
// that caller read -> the caller dereferences freed memory.
//
// Here we model the worker side as the unsynchronized async free racing the
// caller's post-submit read, made deterministic with a gate. Oracle = the
// free-counter (double free) + the post-read invariant.
//
//   * Pre-fix: nothing keeps the ctx alive across the caller's post-submit
//     read, so the worker's unconditional free + the caller's own teardown free
//     the same allocation twice. RED.
//   * Post-fix contract: `submit` must either (a) return a status the caller
//     uses WITHOUT dereferencing ctx, or (b) hold a ref across the publish that
//     the caller releases after its read. Either way exactly one free occurs.
//
// CONTRACT CHANGE post-fix (noted in report): replace the caller-side
// `first_ctx.cooperative_scheduler` deref with the submit-returned status, and
// swap the two unsynchronized frees for `destroyOwnerGated`.
test "first_stream_owner_submit_publish_before_return_regression" {
    g_first_stream_lifetime_test_lock.lock();
    defer g_first_stream_lifetime_test_lock.unlock();

    const allocator = std.testing.allocator;
    var harness = try FirstStreamLifetimeTestHarness.init(allocator);

    // The caller holds a conceptual ref across submit+read; the fix formalizes
    // this. owner_refs: 1 -> 2 (caller + worker).
    harness.ctx.retainOwnerRef();

    var free_count = std.atomic.Value(u32).init(0);

    // Worker side: the scheduler has published this ctx; the worker finishes it
    // and runs the async cleanup. CONTRACT CHANGE (fix landed): the free is now
    // refcount-gated, so the worker's release only frees if it is the last.
    const Worker = struct {
        h: *FirstStreamLifetimeTestHarness,
        gate: *FirstStreamTestGate,
        free_count: *std.atomic.Value(u32),
        fn run(self: *@This()) void {
            self.gate.wait(); // overlap with the caller's post-submit read
            if (self.h.destroyOwnerGated()) _ = self.free_count.fetchAdd(1, .acq_rel);
        }
    };

    var gate: FirstStreamTestGate = .{};
    var worker = Worker{ .h = &harness, .gate = &gate, .free_count = &free_count };
    const t = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    // Caller side (handleQuicConnection post-submit). The production fix removed
    // the post-submit `first_ctx.cooperative_scheduler` deref entirely — the
    // caller now branches on `submit`'s returned bool and never touches the ctx
    // after publication. The caller holds its own ref across this window (the
    // `retainOwnerRef` above) and releases it gated; exactly one of the two
    // gated releases frees.
    gate.set();
    if (harness.destroyOwnerGated()) _ = free_count.fetchAdd(1, .acq_rel);
    t.join();

    // Exactly one free is the contract. Pre-fix: 2 (RED, double free).
    try std.testing.expectEqual(@as(u32, 1), free_count.load(.acquire));
    harness.deinit(true);
}

// BARRIER-SEAM PIN: exercises the `g_first_stream_cleanup_test_barrier` +
// `test_cleanup_reached` seam end to end through the REAL
// `cleanupFirstStreamOwnerAsync` entry, confirming the detached-cleanup commit
// point can be held open deterministically and that the notifier bails on
// `cooperative_done` (the TOCTOU flag) without touching the heavy deps. This is
// a PIN of the test infrastructure (it must stay behavior-neutral in prod), not
// a repro. It does NOT run the heavy-dep teardown.
test "first_stream_owner_cleanup_barrier_seam_pin" {
    g_first_stream_lifetime_test_lock.lock();
    defer g_first_stream_lifetime_test_lock.unlock();

    const allocator = std.testing.allocator;
    var harness = try FirstStreamLifetimeTestHarness.init(allocator);

    // Notifier observes cooperative_done and bails immediately — no scheduler
    // deref, no heavy-dep access. Must not crash.
    harness.ctx.cooperative_done.store(true, .release);
    harness.fireReadyNotifier();

    // Barrier seam: when armed, a detached cleanup would park at the free point.
    // Verify the flag toggles and is observable; we do not spawn the real
    // cleanup thread here (it would tear down undefined heavy deps), but the
    // seam wiring compiles + flips as the deterministic tests rely on.
    var release_cleanup: FirstStreamTestGate = .{};
    harness.ctx.test_cleanup_reached = &release_cleanup;
    setFirstStreamCleanupTestBarrier(true);
    try std.testing.expect(g_first_stream_cleanup_test_barrier);
    setFirstStreamCleanupTestBarrier(false);
    try std.testing.expect(!g_first_stream_cleanup_test_barrier);

    // Single owner ref -> the terminal gated free is the last release.
    try std.testing.expect(harness.destroyOwnerGated());
    harness.deinit(true);
}

// UNIT: the lifetime refcount the fix introduces. owner starts at 1; a reader
// retain makes 2; the LAST release is the one that signals "free now". This
// pins the exact contract `destroyFirstStreamOwnerResources` must honor.
test "first_stream_owner_refcount_last_release_signals_free" {
    const allocator = std.testing.allocator;
    var harness = try FirstStreamLifetimeTestHarness.init(allocator);

    try std.testing.expectEqual(@as(u32, 1), harness.ctx.owner_refs.load(.acquire));
    harness.ctx.retainOwnerRef();
    try std.testing.expectEqual(@as(u32, 2), harness.ctx.owner_refs.load(.acquire));

    // First release: NOT the last; must not free.
    try std.testing.expect(!harness.ctx.releaseOwnerRef());
    // Second release: the last; signals free.
    try std.testing.expect(harness.destroyOwnerGated());
    harness.deinit(true);
}

// UNIT (stress): concurrent retain/release from N reader threads + the owner
// must free the allocation exactly once. Models many poll-thread notifier
// firings racing the async cleanup. The testing allocator catches any
// double-free / leak / UAF. Repeated to amplify race probability.
test "first_stream_owner_concurrent_retain_release_frees_once" {
    const allocator = std.testing.allocator;

    var trial: usize = 0;
    while (trial < 64) : (trial += 1) {
        var harness = try FirstStreamLifetimeTestHarness.init(allocator);
        const reader_count = 4;
        // Each reader takes a ref up front (models being mid-access).
        var r: usize = 0;
        while (r < reader_count) : (r += 1) harness.ctx.retainOwnerRef();

        const Worker = struct {
            h: *FirstStreamLifetimeTestHarness,
            freed: *std.atomic.Value(u32),
            fn run(self: *@This()) void {
                // Touch the real notifier, then release this reader's ref.
                self.h.fireReadyNotifier();
                if (self.h.ctx.releaseOwnerRef()) {
                    // Last reader -> it frees.
                    self.h.allocator.destroy(self.h.ctx);
                    _ = self.freed.fetchAdd(1, .acq_rel);
                }
            }
        };

        var freed = std.atomic.Value(u32).init(0);
        var workers: [reader_count]Worker = undefined;
        var threads: [reader_count]std.Thread = undefined;
        for (&workers, 0..) |*w, i| {
            w.* = .{ .h = &harness, .freed = &freed };
            threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
        }
        for (&threads) |th| th.join();

        // Owner's terminal release.
        if (harness.destroyOwnerGated()) _ = freed.fetchAdd(1, .acq_rel);

        // Exactly one of the {readers, owner} performed the freeing release.
        try std.testing.expectEqual(@as(u32, 1), freed.load(.acquire));
        harness.deinit(true); // ctx already freed by the last release above
    }
}

// DEFENSIVE-FRAMING PIN (not a repro): decodeBufferedMessage must not index out
// of bounds on a torn/corrupt reader. The diagnosed crash was a GP fault at the
// readInt framing site; the UAF is the root cause, but the fixer is also adding
// a bounds diagnostic here. This PINS that diagnostic. It is expected to PASS
// pre-fix for the in-bounds cases (the parser is single-thread-correct); the
// `start_index > buffer.len` case asserts the post-fix guard returns cleanly
// rather than panicking. Marked as a PIN, not a red repro.
test "first_stream_decode_buffered_framing_bounds_pin" {
    const allocator = std.testing.allocator;

    // Empty / short buffers: returns null (need >= 4 length bytes), no panic.
    try std.testing.expect((try decodeBufferedMessageForTest(allocator, &.{}, 0)) == null);
    try std.testing.expect((try decodeBufferedMessageForTest(allocator, &.{ 0x00, 0x00 }, 0)) == null);

    // start_index == buffer.len: empty unread slice, returns null cleanly.
    try std.testing.expect((try decodeBufferedMessageForTest(allocator, &.{ 0, 0, 0, 1, 0x55 }, 5)) == null);

    // A declared length larger than the cap is rejected, never read past the
    // buffer (here the 4 length bytes encode > 16 MiB).
    const oversize = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    try std.testing.expectError(error.MessageTooLarge, decodeBufferedMessageForTest(allocator, &oversize, 0));

    // A truncated frame (length says 8 but only 2 payload bytes present)
    // returns null (need more data) — never slices out of bounds.
    const truncated = [_]u8{ 0, 0, 0, 8, 0xAA, 0xBB };
    try std.testing.expect((try decodeBufferedMessageForTest(allocator, &truncated, 0)) == null);
}

// Regression test for the idle-connection reap-cap bug.
// docs/bugs/2026-06-18-idle-pool-spin-reap-cap.md
//
// `BufferedProtoReader.nextMessage` reaps an idle/lingering connection on a
// WouldBlock-attempt counter (`max_would_block_attempts = 300000`) whose
// comment assumes a 1ms park. The actual park is
// `quic_transport.server_handler_wait_for_poll_ns` == 100ms, so the real reap
// deadline is 300000 × 100ms ≈ 8.3 HOURS, not the intended ~300s. Idle
// connections linger ~8.3h, waking the thread pool every 100ms → sustained
// pool spin / high CPU after ingest.
//
// This test pins the CORRECT contract against the pure reap predicate
// `shouldReapIdleConnection` / `proto_reader_idle_reap_deadline_ms`:
//   - NOT reaped well before 300s,
//   - reaped at/after ~300s,
//   - and (the anti-regression bound that catches the original 8.3h bug) the
//     deadline is far under 30 minutes.
// It is RED with the buggy 8.3h stub and GREEN once the fixer converts the
// policy to a ~300s wall-clock deadline.
test "proto_reader_idle_connection_reap_deadline_regression" {
    const second_ms: i64 = 1000;

    // An idle connection is NOT reaped well before the ~300s deadline.
    try std.testing.expect(!BufferedProtoReader.shouldReapIdleConnection(0));
    try std.testing.expect(!BufferedProtoReader.shouldReapIdleConnection(100 * second_ms));
    try std.testing.expect(!BufferedProtoReader.shouldReapIdleConnection(290 * second_ms));

    // An idle connection IS reaped at/after the ~300s deadline.
    try std.testing.expect(BufferedProtoReader.shouldReapIdleConnection(300 * second_ms));
    try std.testing.expect(BufferedProtoReader.shouldReapIdleConnection(305 * second_ms));
    try std.testing.expect(BufferedProtoReader.shouldReapIdleConnection(310 * second_ms));

    // Anti-regression: with the buggy 8.3h logic the deadline is 30,000,000ms,
    // so neither of these holds. A 600s-idle connection MUST be reaped, and the
    // deadline constant MUST be well under 30 minutes (1,800,000ms).
    try std.testing.expect(BufferedProtoReader.shouldReapIdleConnection(600 * second_ms));
    try std.testing.expect(BufferedProtoReader.proto_reader_idle_reap_deadline_ms < 1_800_000);
}
