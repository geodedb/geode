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

// CANARY: REQ=REQ-GAP-0928-POOL-EXHAUSTED-DIAGNOSTIC; FEATURE="ConnectionPool"; ASPECT=RateLimitPredicate; STATUS=TESTED; TEST=tests/test_gap0928_pool_exhausted.zig; OWNER=transport; UPDATED=2026-07-10
/// GAP-0928: rate-limit the POOL_EXHAUSTED diagnostic to at most once per
/// `pool_exhausted_log_window_ms` while the pool stays at capacity. Pure and
/// unit-testable — it reads no clock. `last_log_ms == 0` means "never logged"
/// (always log the first time). Emits when the window has elapsed.
pub const pool_exhausted_log_window_ms: i64 = 5_000;
pub fn shouldLogPoolExhausted(last_log_ms: i64, now_ms: i64) bool {
    if (last_log_ms == 0) return true;
    return (now_ms - last_log_ms) >= pool_exhausted_log_window_ms;
}

test "gap0928_pool_exhausted_diagnostic_rate_limit" {
    // First time (never logged) always logs.
    try std.testing.expect(shouldLogPoolExhausted(0, 1_000));
    // Within the window: suppressed.
    try std.testing.expect(!shouldLogPoolExhausted(1_000, 1_000));
    try std.testing.expect(!shouldLogPoolExhausted(1_000, 1_000 + pool_exhausted_log_window_ms - 1));
    // At/after the window: logs again.
    try std.testing.expect(shouldLogPoolExhausted(1_000, 1_000 + pool_exhausted_log_window_ms));
    try std.testing.expect(shouldLogPoolExhausted(1_000, 1_000 + pool_exhausted_log_window_ms + 500));
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

fn monoNs() u64 {
    if (comptime @import("builtin").os.tag == .linux) {
        var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
        const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        if (rc != 0) return 0;
        const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
        const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
        return sec * std.time.ns_per_s + nsec;
    } else {
        // std.c.timespec on macos differs from std.posix.timespec when
        // cross-compiling from linux to macos under Zig 0.16; pair the
        // c-namespaced call with the c-namespaced type.
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        const rc = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        if (rc != 0) return 0;
        const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
        const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
        return sec * std.time.ns_per_s + nsec;
    }
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

/// Non-allocating getenv returning a borrowed slice (valid for the process
/// lifetime, like all of `environ`). Used where the value is consumed
/// immediately (e.g. parsed into a config) and not retained.
fn posixGetenv(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn envUsize(allocator: std.mem.Allocator, name: []const u8, default_value: usize, min_value: usize, max_value: usize) usize {
    const raw = getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(raw);
    if (raw.len == 0) return default_value;
    const parsed = std.fmt.parseUnsigned(usize, raw, 10) catch return default_value;
    return @min(@max(parsed, min_value), max_value);
}

fn envBool(allocator: std.mem.Allocator, name: []const u8, default_value: bool) bool {
    const raw = getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(raw);
    if (raw.len == 0) return default_value;
    // GAP-0848/0850 follow-up: match GEODE_STRICT_TENANCY's case-insensitive
    // truthy parsing (see cli_args.zig) so GEODE_PERMISSIVE_TENANCY=TRUE and
    // GEODE_INSECURE_ALLOW_ALL_I_UNDERSTAND=On behave like their lowercase
    // forms — an operator setting a break-glass flag in upper/mixed case must
    // not silently fall through to the (security-relevant) default. The numeric
    // "1"/"0" forms are case-agnostic already; eqlIgnoreCase covers the rest.
    if (std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "on")) return true;
    if (std.mem.eql(u8, raw, "0") or
        std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no") or
        std.ascii.eqlIgnoreCase(raw, "off")) return false;
    return default_value;
}

const builtin = @import("builtin");
const build_options = @import("build_options");
const posix = std.posix;
const geode = @import("geode");
const impl_flagger = geode.impl_flagger;
const diagnostics = @import("geode").diagnostics;
const eval = geode.eval;
const eval_extended = geode.eval_ext;
const exec = geode.exec;
const txn_mgr = @import("txn");
const SelectivityEstimator = @import("index_selectivity").SelectivityEstimator;
const TextFormatter = @import("text_formatter").TextFormatter;
const quic_transport = @import("transport/quic");
const grpc_transport = @import("../transport/grpc_server.zig");
const thread_pool = @import("transport/thread_pool");
const cert_gen = @import("../tools/cert_gen.zig");
const query_ast_cache = @import("query_ast_cache");
// Note: cert_gen now imported for certificate generation (M3.2 Phase 3 CLI extraction)
// const mvcc = @import("server/txn/mvcc.zig");
// const logger = @import("log/logger.zig");
const query_plan_cache = geode.query_plan_cache;

// Import real logger for proper log level handling
const logger = geode.audit.system_logger;
// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-010; FEATURE="Structured Logging"; ASPECT=ServerMain; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;
const audit = geode.security.audit;
// CANARY: REQ=REQ-PROMETHEUS-WIRE-003; FEATURE="Prometheus Metrics Endpoint"; ASPECT=ServerImport; STATUS=TESTED; TEST=geodetestlab/specs/gap_0166_prometheus_metrics.yml; OWNER=monitoring; UPDATED=2026-01-14
// GAP-0166: Import metrics server for Prometheus endpoint
const metrics_server = @import("../monitoring/metrics_server.zig");
const runtime_metrics_mod = geode.runtime_metrics;
// Import backup manager (M3.1 Phase 3 modularization)
const backup_manager = geode.backup_manager;
const SimplifiedBackupManager = backup_manager.SimplifiedBackupManager;
const user_storage = @import("user_storage");
// Import index catalog (M3.1 Phase 3 modularization)
const index_catalog = @import("index_catalog.zig");
// Import server flags (M3.1 Phase 3 modularization)
const server_flags = geode.server_flags;
// Import CLI argument parsing (M3.2 Phase 3 CLI extraction)
const cli_args = @import("cli_args.zig");
// Portable process-argv holder (captured from std.process.Args at startup);
// replaces the Linux-only /proc/self/cmdline read in parseLspBootstrapConfig.
const process_args = @import("process_args.zig");
// Import server initialization (M3.2 Phase 3 initialization extraction)
const server_init = @import("server_init.zig");
const fd_limit = @import("geode").fd_limit;
// Import QUIC connection handlers (M3.3 Phase 3 QUIC handlers extraction)
const quic_connection_handler = @import("quic_connection_handler.zig");
// Import QUIC connection-state aggregation for runtime_metrics gauges
// (Task 4 of docs/superpowers/plans/2026-04-25-quic-cascade-investigation.md)
const quic_metrics = @import("quic_connection_metrics.zig");
const leaked_conn_reaper = @import("leaked_conn_reaper.zig");
const acceptor_watchdog = @import("acceptor_watchdog.zig");
const proto_reader_metrics = @import("buffered_proto_reader_metrics.zig");
const quic_response_metrics = @import("quic_response_metrics");
// CANARY: REQ=REQ-ABAC-WIRE-017; FEATURE="ABAC Enforcement"; ASPECT=AsyncConnection; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=server; UPDATED=2026-06-11
// GAP-0165: Import geode_auth for SecurityManager type in async connection context
const geode_auth = @import("geode_auth");

fn runtimeMetricsPrometheusSnapshot(allocator: std.mem.Allocator, ctx: *anyopaque) anyerror![]u8 {
    const registry: *runtime_metrics_mod.Registry = @ptrCast(@alignCast(ctx));

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    try registry.snapshotInto(allocator, &raw);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var entries = std.mem.splitScalar(u8, raw.items, ' ');
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const name = entry[0..eq];
        const value = entry[eq + 1 ..];
        if (name.len == 0 or value.len == 0) continue;

        try out.appendSlice(allocator, "# TYPE ");
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, " gauge\n");
        try out.appendSlice(allocator, name);
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, value);
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

// Task 28 (Phase 9 of docs/superpowers/plans/2026-05-14-lsp-permission-aware-completion.md):
// Embedded LSP listener — co-host an LSP JSON-RPC TCP endpoint inside
// `geode serve` so geode-ui (and any future TCP-based LSP client) can
// reach the same in-process schema view as QUIC handlers without
// spawning a side-car `geode lsp --listen` process. The Server is
// rooted at src/unified_entry.zig, so relative paths into src/cli/lsp/
// resolve against src/server/main.zig's containing dir.
const lsp_server = @import("../cli/lsp/server.zig");
const lsp_transport_mod = @import("../cli/lsp/transport.zig");
// LSP AuthProvider→Verifier adapter (Task 28 follow-up).
const lsp_auth_mod = @import("../cli/lsp/auth.zig");
const authn_mod = geode.security.authn;

// CANARY: REQ=REQ-QUIC-HC-009; FEATURE="High-Concurrency Allocator"; ASPECT=ServerAllocator; STATUS=TESTED; TEST=tests/e2e_quic_high_concurrency.zig; OWNER=transport; UPDATED=2026-06-11
//
// Debug builds keep DebugAllocator leak detection. Optimized server builds use
// the libc allocator (glibc malloc).
//
// GAP-0343 (RSS): the SMP allocator caches freed memory in per-thread,
// per-size-class free lists and never returns it to the OS. Under connection
// churn each of the ~hundreds of pooled stream/worker threads accumulates the
// per-connection buffers it has handled (the multi-MB stream reassembly
// buffer sized by max_stream_data dominates), so RSS climbed ~19 MB per
// connection without bound — a single-tenant 5-minute load reached >9 GB. The
// libc allocator munmaps large allocations on free and trims its arenas, so
// freed per-connection memory is returned to the OS (release now tracks the
// flat RSS profile already observed under the debug page-backed allocator).
// glibc's per-thread-arena design keeps the hot parse/protobuf path lock-light,
// so this does not reintroduce the serialization the SMP allocator avoided.
const ServerAllocator = if (builtin.mode == .Debug)
    std.heap.DebugAllocator(.{})
else
    struct {
        pub fn allocator(_: *@This()) std.mem.Allocator {
            return std.heap.c_allocator;
        }
    };

// CANARY: REQ=REQ-QUIC-HC-018; FEATURE="QUIC High-Concurrency Worker Fanout"; ASPECT=StreamPoolSizing; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-25
//
// Stream handlers are long-lived per-client query loops. The current
// high-throughput default runs single-stream clients through the cooperative
// first-stream scheduler, but the shared stream pool still needs enough queue
// headroom for compatibility-mode multiplexed streams and fallback owners.
const default_quic_stream_worker_count = 64;
const default_quic_stream_queue_capacity = 8192;
const default_quic_acceptor_worker_count = 64;
const default_quic_acceptor_queue_capacity = 4096;
const default_quic_connection_worker_count = 64;
const default_quic_detached_first_stream_threads = if (builtin.mode == .Debug) 64 else 256;
const default_quic_cooperative_first_stream_worker_count = if (builtin.mode == .Debug) 16 else 512;
const default_quic_poll_worker_count = if (builtin.mode == .Debug) 1 else 16;
const quic_connection_queue_capacity = 1024;
const default_quic_connection_admission_threads = if (builtin.mode == .Debug) 64 else 4096;
const quic_connection_admission_stack_size = 1024 * 1024;

// Process-global AuthProvider used by the embedded LSP TCP listener to
// authenticate `initialize` bearer / session tokens.  `null` until the
// server bootstraps it (and stays `null` if `--lsp-port=0`), in which
// case the listener stays fail-closed.  The provider lives for the
// lifetime of the server process — we never tear it down because the
// listener and accepted sessions hold borrowed pointers into it.
var g_lsp_auth_provider: ?*authn_mod.AuthProvider = null;
// GPS Phase 4 (Task 4-1): role resolution extracted to dedicated module.
// Use the geode lib re-export rather than a raw file path so that the
// "user_storage" named import inside role_resolver.zig is resolved correctly.
const role_resolver = geode.security.role_resolver;

// CANARY: REQ=REQ-GPS-PDP-008; FEATURE="GPS Decision Engine"; ASPECT=AuthRoleGraphLookup; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
/// Thin shims that delegate to role_resolver — kept for call-site compatibility.
fn authRoleFromRecord(record: user_storage.UserStorageBackend.UserRecord) geode.user_management.Role {
    return role_resolver.authRoleFromRecord(record);
}

fn resolveRoleFromGraph(store: *geode.graph_store.GraphStore, record: user_storage.UserStorageBackend.UserRecord) geode.user_management.Role {
    return role_resolver.resolveRoleFromGraph(store, record);
}

fn duplicatePersistentUser(allocator: std.mem.Allocator, store: *geode.graph_store.GraphStore, record: user_storage.UserStorageBackend.UserRecord) !geode.user_management.User {
    return .{
        .username = try allocator.dupe(u8, record.getUsername()),
        .password_hash = try allocator.dupe(u8, record.getPasswordHash()),
        .email = try allocator.dupe(u8, record.getEmail()),
        .role = resolveRoleFromGraph(store, record),
        .created_at = record.created_at,
        .last_login = if (record.last_login != 0) record.last_login else null,
        .active = record.is_active,
        .password_reset_required = record.password_reset_required,
        .auth_version = record.auth_version,
    };
}

fn lookupPersistentAuthUser(_: ?*anyopaque, allocator: std.mem.Allocator, username: []const u8) anyerror!?geode.user_management.User {
    // NEW-8 residual (#860): block reserved usernames at the resolver boundary.
    // Returning null here means ensureUserCached / authenticate treat the
    // principal as "not found", preventing geode-cluster from being seeded into
    // user_store via the persistent-lookup path regardless of what is stored in
    // the auth graph.  Uses RESERVED_USERNAMES as the single source of truth.
    for (geode.user_management.RESERVED_USERNAMES) |reserved| {
        if (std.mem.eql(u8, username, reserved)) return null;
    }
    // The store lock may already be held exclusively by another thread (e.g. a
    // checkpoint or an auth-DDL write). Use tryAcquire to avoid blocking the
    // auth path behind it.
    //
    // ENG-3954 / #874: when the lock cannot be acquired we must NOT read the
    // store unsynchronized, and we must NOT report "no such user" either — we
    // simply could not look. Reporting absence here made `authenticate` return
    // error.Unauthenticated for a perfectly valid principal, which the per-IP
    // rate limiter counted as a brute-force attempt and, since the contention
    // persisted, re-armed the lockout on every retry. Report unavailability so
    // authenticate() can normalise it to error.AuthUnavailable.
    // CANARY: REQ=REQ-SEC-AUTH-UNAVAILABLE-003; FEATURE="AuthOutcomeClassification"; ASPECT=PersistentResolver; STATUS=TESTED; TEST=tests/test_auth_unavailable_classification.zig; OWNER=security; UPDATED=2026-08-28
    if (!geode.graph_store.tryAcquireStoreLock()) {
        return user_storage.UserStorageBackend.SecurityStoreUnavailable;
    }
    defer geode.graph_store.releaseStoreLock();

    const store = geode.graph_store.getGlobalStore(allocator);
    const record = try user_storage.UserStorageBackend.findUserByUsernameInGraphChecked(store, username) orelse return null;
    return try duplicatePersistentUser(allocator, store, record);
}

fn persistentAuthUsersExist(_: ?*anyopaque) anyerror!bool {
    // Same tryAcquire pattern as lookupPersistentAuthUser to prevent deadlock
    // when called from a thread already holding the store lock.
    const locked = geode.graph_store.tryAcquireStoreLock();
    defer if (locked) geode.graph_store.releaseStoreLock();

    const store = geode.graph_store.getGlobalStore(std.heap.c_allocator);
    return user_storage.UserStorageBackend.hasUserRecordsInGraph(store);
}

fn lookupPersistentAuthVersion(_: ?*anyopaque, username: []const u8) anyerror!?u64 {
    // The store lock may already be held by the calling thread (e.g., QUIC
    // handler executing a CALL query).  Use tryAcquire to avoid deadlock;
    // if the lock can't be acquired, return null (caller treats the user as
    // "not cached" and falls back to in-memory state).
    const locked = geode.graph_store.tryAcquireStoreLock();
    defer if (locked) geode.graph_store.releaseStoreLock();

    const store = geode.graph_store.getGlobalStore(std.heap.c_allocator);
    return user_storage.UserStorageBackend.findUserAuthVersionByUsernameInGraph(store, username);
}

fn listPersistentAuthUsers(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]geode.user_management.User {
    // Same tryAcquire pattern as lookupPersistentAuthUser to prevent deadlock
    // when called from a thread already holding the store lock.
    const locked = geode.graph_store.tryAcquireStoreLock();
    defer if (locked) geode.graph_store.releaseStoreLock();

    const store = geode.graph_store.getGlobalStore(allocator);
    const records = try user_storage.UserStorageBackend.listUsersFromGraph(allocator, store);
    defer allocator.free(records);

    const users = try allocator.alloc(geode.user_management.User, records.len);
    var initialized: usize = 0;
    errdefer {
        for (users[0..initialized]) |*user| {
            user.deinit(allocator);
        }
        allocator.free(users);
    }

    for (records) |record| {
        // NEW-8 residual (#860): skip reserved usernames at the bulk-list boundary
        // so geode-cluster cannot be injected into user_store via the list path.
        // Uses RESERVED_USERNAMES as the single source of truth.
        const is_reserved = blk: {
            for (geode.user_management.RESERVED_USERNAMES) |reserved| {
                if (std.mem.eql(u8, record.getUsername(), reserved)) break :blk true;
            }
            break :blk false;
        };
        if (is_reserved) continue;
        users[initialized] = try duplicatePersistentUser(allocator, store, record);
        initialized += 1;
    }

    if (initialized == records.len) return users;
    // Some reserved records were skipped — trim the allocation to the actual count.
    // On trim-alloc failure, the errdefer above cleans up users[0..initialized].
    const trimmed = try allocator.alloc(geode.user_management.User, initialized);
    @memcpy(trimmed, users[0..initialized]);
    allocator.free(users); // free the over-allocated array frame; strings are in trimmed
    return trimmed;
}

// CANARY: REQ=REQ-PERF-ASYNC-CONN-001; FEATURE="AsyncConnectionHandling"; ASPECT=ThreadPool; STATUS=TESTED; TEST=tests/e2e_quic_high_concurrency.zig; OWNER=server; UPDATED=2026-06-11
// GAP-0202: Async connection handling context for thread pool execution
// This struct holds all parameters needed by handleQuicConnection for async execution
const ConnectionContext = struct {
    allocator: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    conn: *quic_transport.QuicConnection,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    env_spill_threshold: usize,
    env_storage_checksum_error: bool,
    security_manager: ?*geode_auth.SecurityManager,
    shared_ast_cache: ?*query_ast_cache.SharedAstCache,
    // Issue #460: Shared cross-connection query optimizer
    shared_optimizer: ?*query_plan_cache.SharedQueryOptimizer = null,
    // #683: Cached env config to avoid per-connection syscalls
    env_config: *const server_init.EnvironmentConfig = undefined,
    // Shared stream + acceptor pools owned by main(); one per server lifetime
    // instead of one per connection (which leaked under msft-graph reconnect).
    // See docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md.
    stream_pool: *thread_pool.ThreadPool,
    acceptor_pool: *thread_pool.ThreadPool,
    admission_gate: ?*ConnectionAdmissionGate = null,
};

// CANARY: REQ=REQ-QUIC-HC-012; FEATURE="DetachedConnectionAdmission"; ASPECT=HelloFanout; STATUS=TESTED; TEST=tests/e2e_quic_high_concurrency.zig; OWNER=transport; UPDATED=2026-06-11
//
// The external thread_pool dependency is intentionally capped at 64 workers.
// That is acceptable for long-lived stream loops, but it becomes a HELLO
// admission ceiling when hundreds of clients connect at once. These detached
// admission threads are deliberately short-lived: handleQuicConnection returns
// after HELLO and first-stream handoff, while query loops remain on stream_pool.
const ConnectionAdmissionGate = struct {
    active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max: std.atomic.Value(u32) = std.atomic.Value(u32).init(default_quic_connection_admission_threads),

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
        if (prev <= 1) {
            const io = std.Io.Threaded.global_single_threaded.io();
            io.futexWake(u32, &self.active.raw, 1);
        }
    }

    fn waitForZero(self: *@This(), timeout_ns: u64) bool {
        const start_ns = monoNs();
        var remaining_ns = timeout_ns;
        while (self.active.load(.acquire) != 0) {
            if (remaining_ns == 0) return false;
            const observed = self.active.load(.acquire);
            if (observed == 0) return true;
            const timeout: std.Io.Timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(@intCast(remaining_ns)),
                .clock = .awake,
            } };
            const io = std.Io.Threaded.global_single_threaded.io();
            io.futexWaitTimeout(u32, &self.active.raw, observed, timeout) catch |err| switch (err) {
                error.Canceled => {},
            };
            const elapsed_ns = monoNs() -| start_ns;
            if (elapsed_ns >= timeout_ns) return self.active.load(.acquire) == 0;
            remaining_ns = timeout_ns - elapsed_ns;
        }
        return true;
    }
};

var g_connection_admission_gate = ConnectionAdmissionGate{};

const PollLoopContext = struct {
    transport: *quic_transport.QuicTransport,
    shutdown: *std.atomic.Value(bool),
};

// GAP-0202: Callback wrapper for thread pool execution
fn handleConnectionAsync(context: *anyopaque) void {
    const ctx: *ConnectionContext = @ptrCast(@alignCast(context));
    defer {
        if (ctx.admission_gate) |gate| gate.release();
        ctx.allocator.destroy(ctx);
    }
    quic_connection_handler.handleQuicConnection(
        ctx.allocator,
        ctx.transport,
        ctx.conn,
        ctx.disable_estimates,
        ctx.compact_profile,
        ctx.memcurve_profile,
        ctx.env_spill_threshold,
        ctx.env_storage_checksum_error,
        false,
        ctx.security_manager,
        ctx.shared_ast_cache,
        ctx.shared_optimizer,
        ctx.env_config,
        ctx.stream_pool,
        ctx.acceptor_pool,
    ) catch |err| {
        log.err("Error handling QUIC connection (async)", &.{
            Attr.string("error", @errorName(err)),
        });
    };
}

fn runGrpcServerTask(context: *anyopaque) void {
    const server: *grpc_transport.GeodeGrpcServer = @ptrCast(@alignCast(context));
    server.start() catch |err| {
        log.err("Failed to start gRPC server", &.{
            Attr.string("error", @errorName(err)),
        });
    };
}

fn runPollLoopTask(context: *anyopaque) void {
    const ctx: *PollLoopContext = @ptrCast(@alignCast(context));
    quic_transport.QuicTransport.pollLoop(ctx.transport, ctx.shutdown);
}

/// #864 / qa-seed deadlock §6.5: thread entry for the leaked-connection
/// reaper. Runs a periodic walk of the registry, reaping conns whose
/// acceptors have exited. Exits cleanly when the registry's shutdown
/// flag is set.
fn runLeakedConnReaper(context: *anyopaque) void {
    const args: *leaked_conn_reaper.ReaperArgs = @ptrCast(@alignCast(context));
    leaked_conn_reaper.reaperLoop(args);
}

// Task 28: embedded-LSP listener + per-session thread entry points.
//
// `runLspListener` is the long-running accept loop spawned from
// `main()` once the QUIC server is up. It owns its own
// `std.Io.Threaded` instance for the lifetime of the listener so the
// `Io` vtable handed to the listener and to every accepted stream is
// stable. Each accepted connection is dispatched to a detached
// `runLspSession` thread — multiple LSP clients can therefore have
// concurrent sessions, which is what enables a geode-ui tab plus a
// terminal editor (or two browser tabs) to drive the LSP at the same
// time without serializing on a single accept-and-run loop the way
// standalone `geode lsp --listen` does.
//
// Auth caveat: `verifier = null` and `allow_unauth = false` mean the
// session is fail-closed. Until the AuthProvider→Verifier adapter
// lands (follow-up task tracked in the plan), this listener is bound
// but cannot satisfy any client's initialize request. See
// `runLspSession`'s in-body TODO.
const LspListenerArgs = struct {
    allocator: std.mem.Allocator,
    port: u16,
    loopback_only: bool,
    // Optional verifier installed into every accepted LSP session.
    // `null` keeps the listener fail-closed (legacy behavior); a real
    // verifier is built by `verifierFromAuthProvider(g_lsp_auth_provider)`
    // when the server bootstraps an AuthProvider.
    verifier: ?lsp_auth_mod.Verifier = null,
};

fn runLspListener(args: LspListenerArgs) void {
    const host: []const u8 = if (args.loopback_only) "127.0.0.1" else "0.0.0.0";

    // LSP-SEC-008 / SEC-LSP-BIND-01: hard-assert the bind policy at the
    // layer that knows both the bind scope and the auth wiring. Embedded
    // sessions always run with allow_unauth=false; a non-loopback bind
    // (`--lsp-bind-all`) additionally requires a real verifier — refusing
    // here means no future caller can wire an unauthenticated bind-all
    // listener without tripping this guard (and its regression test,
    // tests/test_gap0885_lsp_hardening.zig).
    lsp_server.validateBindPolicy(.{
        .loopback_only = args.loopback_only,
        .allow_unauth = false,
        .has_verifier = args.verifier != null,
    }) catch {
        log.err("LSP listener: refusing non-loopback bind without an authentication verifier (LSP-SEC-008)", &.{
            Attr.string("host", host),
            Attr.int("port", @as(i64, args.port)),
        });
        return;
    };

    // Each accept loop and every per-session reader needs to share one
    // `std.Io` vtable for the lifetime of the listener. A dedicated
    // `std.Io.Threaded` instance, owned by this thread, satisfies that
    // (same pattern as `metrics_server.zig` and the standalone
    // `geode lsp --listen` path in `cli/main.zig`).
    var threaded = std.Io.Threaded.init(args.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Zig 0.16 net stack: `std.Io.net.IpAddress.parse` handles v4 and
    // falls back to v6. We bind a numeric literal — no DNS — so the
    // narrow `parseIp4`/`parseIp6` fallbacks would also work, but
    // `parse` is the more forgiving entry point.
    var bind_addr = std.Io.net.IpAddress.parse(host, args.port) catch
        std.Io.net.IpAddress.parseIp4(host, args.port) catch
        std.Io.net.IpAddress.parseIp6(host, args.port) catch {
        log.err("LSP listener: failed to parse bind host", &.{
            Attr.string("host", host),
            Attr.int("port", @as(i64, args.port)),
        });
        return;
    };

    var listener = std.Io.net.IpAddress.listen(&bind_addr, io, .{ .reuse_address = true }) catch |err| {
        log.err("LSP listener: bind failed", &.{
            Attr.string("host", host),
            Attr.int("port", @as(i64, args.port)),
            Attr.string("error", @errorName(err)),
        });
        return;
    };
    defer listener.deinit(io);

    log.info("LSP server started", &.{
        Attr.string("address", host),
        Attr.int("port", @as(i64, args.port)),
        Attr.string("transport", "tcp"),
    });

    while (true) {
        const accepted = listener.accept(io) catch |err| {
            log.warn("LSP accept error", &.{Attr.string("error", @errorName(err))});
            continue;
        };
        // The session takes ownership of `accepted`. Spawning failure
        // means we still own it and must close it ourselves to avoid
        // leaking the FD.
        const session_args = args.allocator.create(LspSessionArgs) catch {
            log.err("LSP session args alloc failed", &.{});
            accepted.close(io);
            continue;
        };
        session_args.* = .{
            .allocator = args.allocator,
            .io = io,
            .stream = accepted,
            .verifier = args.verifier,
        };
        const thr = std.Thread.spawn(.{}, runLspSession, .{session_args}) catch |err| {
            log.err("LSP session spawn error", &.{Attr.string("error", @errorName(err))});
            accepted.close(io);
            args.allocator.destroy(session_args);
            continue;
        };
        thr.detach();
    }
}

const LspSessionArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    // Forwarded from the listener.  When non-null this is plumbed into
    // `lsp_server.Server.initWithTransport` so the per-session
    // `AuthState.verify` call can validate the client's bearer / session
    // token against the live AuthProvider.
    verifier: ?lsp_auth_mod.Verifier,
};

fn runLspSession(args: *LspSessionArgs) void {
    // The listener allocated this struct; we own it now and must free
    // it on every return path.
    defer args.allocator.destroy(args);

    // AuthProvider→Verifier adapter is wired below via `args.verifier`
    // (built by `lsp_auth_mod.verifierFromAuthProvider`).  When the
    // server bootstrapped an AuthProvider this is non-null and the LSP
    // session validates `initialize` tokens against the live provider.
    // Otherwise the verifier stays `null` and the session is fail-closed
    // (every initialize is rejected) — same legacy behavior as before
    // the adapter landed.  The TCP-embedded path still REQUIRES auth
    // (`--no-auth` is stdio-only).
    var tx = lsp_transport_mod.Transport.initTcp(args.allocator, args.io, args.stream) catch |err| {
        log.warn("LSP transport init error", &.{Attr.string("error", @errorName(err))});
        args.stream.close(args.io);
        return;
    };
    var srv = lsp_server.Server.initWithTransport(args.allocator, tx, args.verifier, false) catch |err| {
        log.warn("LSP server init error", &.{Attr.string("error", @errorName(err))});
        tx.deinit();
        return;
    };
    defer srv.deinit();
    srv.run() catch |err| {
        log.warn("LSP session error", &.{Attr.string("error", @errorName(err))});
    };
}

const LspBootstrapConfig = struct {
    port: u16 = 3142,
    loopback_only: bool = true,
};

/// Task 28: parse the two embedded-LSP options that
/// `src/server/cli_args.zig` does NOT know about (`--lsp-port=N` and
/// `--lsp-bind-all`). We don't extend `ServerConfig` because the plan
/// limits this task to `src/server/main.zig` only; `parseArgs` ignores
/// flags it doesn't recognise, so these flags pass through it
/// untouched and we re-walk argv here.
///
/// Zig 0.16: `std.process.argsAlloc` was removed; argv is recovered from the
/// portable `process_args` holder that `src/unified_entry.zig` captures from
/// the `std.process.Args` delivered to `main`. This works on every supported
/// platform (the prior `/proc/self/cmdline` read was Linux-only). Any failure
/// degrades silently to the defaults (port=3142, loopback-only).
fn parseLspBootstrapConfig(allocator: std.mem.Allocator) LspBootstrapConfig {
    var cfg: LspBootstrapConfig = .{};
    const args = process_args.getArgs(allocator) catch return cfg;
    defer allocator.free(args);

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--lsp-port=")) {
            const v = arg["--lsp-port=".len..];
            cfg.port = std.fmt.parseUnsigned(u16, v, 10) catch cfg.port;
        } else if (std.mem.eql(u8, arg, "--lsp-bind-all")) {
            cfg.loopback_only = false;
        }
    }
    return cfg;
}

// Distributed query planner accessed via geode module to avoid import path issues
// Cost model explain helpers now accessed via geode root module re-exports (distinct from calibration reporting module)
const cost_explain = geode.cost_explain;

// CANARY: REQ=REQ-M11-DRY-001; FEATURE="CodeQuality"; ASPECT=DuplicateCode; STATUS=EXEMPT; OWNER=core; UPDATED=2025-10-17
// M11: Import backup types from canonical location (storage/backup.zig) instead of duplicating
const backup = @import("storage/backup");
const BackupConfig = backup.BackupConfig;
const CompressionType = backup.CompressionType;
const BackupType = backup.BackupType;
const BackupMetadata = backup.BackupMetadata;

// Removed: SimplifiedBackupManager now imported from backup_manager module
// Original code was at lines 41-180 (~140 lines), now extracted to backup_manager.zig

// Removed: UnionMetrics now imported from server_state module (see below)

// Import index catalog (M3.1 Phase 3 index management extraction)
const IndexStats = index_catalog.IndexStats;
const initIndexCatalog = index_catalog.initIndexCatalog;
const chooseIndexForPredicate = index_catalog.chooseIndexForPredicate;
const indexStatsOnInsert = index_catalog.indexStatsOnInsert;
const indexStatsOnDelete = index_catalog.indexStatsOnDelete;
// Import server flags (M3.1 Phase 3 flag utilities extraction)
const F_ILLEGAL = server_flags.F_ILLEGAL;
const F_PROPERTY_ORDER = server_flags.F_PROPERTY_ORDER;
const F_NULLS_FIRST = server_flags.F_NULLS_FIRST;
const F_NULLS_LAST = server_flags.F_NULLS_LAST;
const F_TIEBREAK = server_flags.F_TIEBREAK;
const F_DISTINCT_UNORDERED = server_flags.F_DISTINCT_UNORDERED;
const F_UNION_PHASES = server_flags.F_UNION_PHASES;
const F_ADAPT_EST = server_flags.F_ADAPT_EST;
const F_HEUR_INDEX = server_flags.F_HEUR_INDEX;
const nullsFlag = server_flags.nullsFlag;
const initImplDefinedFlags = server_flags.initImplDefinedFlags;
const computeBaseFlags = server_flags.computeBaseFlags;
// Import graph storage management (M3.1 Phase 3 graph persistence extraction)
// CANARY: REQ=REQ-BINARY-PERSIST-003; FEATURE="BinaryPersistence"; ASPECT=MainImports; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=server; UPDATED=2026-06-11
// Note: JSON Lines persistence (tryLoadGraphFromDir, saveGraphToDir) removed - using binary persistence via graph_store
const graph_store = geode.graph_store;
// Import protocol handler functions (M3.2 Phase 3 backup protocol extraction)
// Import query executor utility functions (M3.3 Phase 3 query utilities extraction)

/// Global shutdown flag set by SIGTERM/SIGINT handler so the accept loop
/// exits and deferred cleanup (persistence flush, thread pool drain) runs.
var g_shutdown_requested = std.atomic.Value(bool).init(false);

fn handleShutdownSignal(_: posix.SIG) callconv(.c) void {
    g_shutdown_requested.store(true, .release);
}

/// GAP-0065 FIX D liveness: set true once the durability flush
/// (`graph_store.flushForCleanShutdown`) has returned, so the first-stage flush
/// watchdog disarms instead of force-exiting a completed shutdown.
var g_shutdown_flush_done = std.atomic.Value(bool).init(false);

fn compat_sleepMs(ms: u64) void {
    if (comptime @import("builtin").os.tag == .linux) {
        var req = std.os.linux.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.nanosleep(&req, &rem);
    } else {
        var req = std.c.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

/// Gap 0039: post-flush teardown watchdog. SIGTERM shutdown used to wedge
/// FOREVER when a connection handler for an abandoned peer (client vanished
/// without CONNECTION_CLOSE) never unwound: the external thread-pool's
/// `deinit` gives up draining after `deinit_timeout_ns` but then calls
/// `joinAllWorkers()` — an unbounded join — and the per-connection
/// `waitForAllStreamsDrained` is likewise unbounded, so ONE stuck stream
/// handler wedged the whole LIFO defer unwind (observed live: >= 10 min at
/// ~1.75 cores, listener still answering handshakes, until SIGKILL).
///
/// This tight watchdog is armed AFTER the durability flush / WAL checkpoint has
/// completed, so by the time it can fire, everything durable is already on disk
/// and WAL replay makes the next open clean. It then gives the remaining
/// teardown (pool joins, store free, transport deinit) a bounded budget and
/// force-exits rc=0 if the budget lapses — a stalled QUIC handler must never
/// turn a graceful shutdown into a SIGKILL-only hang. (GAP-0065 FIX D moved the
/// FULL checkpoint before this arm point to guarantee the reload snapshots are
/// written; its own — much more generous — first-stage watchdog,
/// `shutdownFlushWatchdogMain`, bounds that checkpoint against a lock wedge so
/// the shutdown can never hang forever.)
fn shutdownTeardownWatchdogMain(budget_ms: u64) void {
    var remaining = budget_ms;
    while (remaining > 0) {
        const slice = @min(remaining, 1000);
        compat_sleepMs(slice);
        remaining -= slice;
    }
    std.debug.print(
        "[shutdown] teardown watchdog: forcing process exit rc=0 after {d}ms — a connection handler or pool join is wedged (gap 0039); the data flush completed before the watchdog was armed\n",
        .{budget_ms},
    );
    std.process.exit(0);
}

/// Spawn the detached gap-0039 teardown watchdog. Best-effort: if the thread
/// cannot be spawned we proceed with the (possibly unbounded) teardown rather
/// than failing the shutdown path.
fn armShutdownTeardownWatchdog(budget_ms: u64) void {
    const t = std.Thread.spawn(.{}, shutdownTeardownWatchdogMain, .{budget_ms}) catch |err| {
        log.warn("Failed to arm shutdown teardown watchdog; teardown is unbounded this run", &.{
            Attr.string("error", @errorName(err)),
        });
        return;
    };
    t.detach();
}

/// GAP-0065 FIX D liveness: FIRST-STAGE shutdown watchdog, armed BEFORE the
/// durability flush (`graph_store.flushForCleanShutdown`). The flush runs the
/// FULL checkpoint (`checkpointAll` → `checkpointOneGraph`) whose `tryLock`
/// retry on `mg.rwlock` has NO deadline — it spins unbounded if a genuinely
/// wedged connection handler still holds the lock (`forceCloseConnections` only
/// flips a flag; quic.zig relies on this watchdog for that case). Because FIX D
/// runs that flush before the gap-0039 teardown watchdog is armed, a wedge would
/// otherwise HANG THE PROCESS FOREVER (only external SIGKILL ends it). This
/// watchdog force-exits rc=0 if the flush has not completed within a GENEROUS
/// budget (default 30 min, `GEODE_CLEAN_SHUTDOWN_FLUSH_TIMEOUT_MS`) — comfortably
/// longer than a legitimate full 14.27M checkpoint + snapshot write, so a normal
/// clean shutdown is NEVER prematurely killed; a genuine deadlock still
/// terminates → the next reopen replays the WAL tail and rebuilds (no data
/// loss, the pre-FIX-D safety net restored). It disarms the instant the flush
/// completes (`g_shutdown_flush_done`) and emits a periodic heartbeat so a
/// long-but-legitimate flush is visible instead of a silent hang.
fn shutdownFlushWatchdogMain(budget_ms: u64) void {
    const tick_ms: u64 = 30_000;
    var elapsed: u64 = 0;
    while (elapsed < budget_ms) {
        const slice = @min(tick_ms, budget_ms - elapsed);
        compat_sleepMs(slice);
        elapsed += slice;
        if (g_shutdown_flush_done.load(.acquire)) return; // flush completed → disarm
        std.debug.print(
            "[shutdown] durability flush still in progress ({d}s / {d}s budget, GEODE_CLEAN_SHUTDOWN_FLUSH_TIMEOUT_MS) — large-graph checkpoint or a wedged lock holder\n",
            .{ elapsed / 1000, budget_ms / 1000 },
        );
    }
    if (g_shutdown_flush_done.load(.acquire)) return;
    std.debug.print(
        "[shutdown] durability flush exceeded {d}ms budget (GEODE_CLEAN_SHUTDOWN_FLUSH_TIMEOUT_MS) — a graph-lock holder is wedged; force-exiting rc=0. The next reopen replays the WAL tail and rebuilds (no data loss).\n",
        .{budget_ms},
    );
    std.process.exit(0);
}

/// Spawn the detached GAP-0065 first-stage flush watchdog. Best-effort: if the
/// thread cannot be spawned we proceed with the (unbounded) flush rather than
/// failing shutdown — matching `armShutdownTeardownWatchdog`.
fn armShutdownFlushWatchdog(budget_ms: u64) void {
    const t = std.Thread.spawn(.{}, shutdownFlushWatchdogMain, .{budget_ms}) catch |err| {
        log.warn("Failed to arm shutdown flush watchdog; the durability flush is unbounded this run", &.{
            Attr.string("error", @errorName(err)),
        });
        return;
    };
    t.detach();
}

// Removed: ServerState struct now in server_state module (M3.2 Phase 3 ServerState extraction)
// Original: ServerState struct definition (~107 lines, lines 145-252)
// Extracted to server_state.zig to enable better modularization and shared access
// Includes all fields and resetResult() method - imported above via: const ServerState = server_state.ServerState;

const DEBUG_PROFILE = false; // default off; enable locally when investigating PROFILE frame assembly

// Removed: Flag constants and utilities now in server_flags module (M3.1 Phase 3 flag utilities extraction)
// Original code was at lines 202-236 (~35 lines), now extracted to server_flags.zig
// Includes: Flag constants (F_ILLEGAL, F_PROPERTY_ORDER, F_NULLS_FIRST, F_NULLS_LAST, F_TIEBREAK,
// F_DISTINCT_UNORDERED, F_UNION_PHASES, F_ADAPT_EST, F_HEUR_INDEX), global flag state
// (flags_buf_base, flags_buf_ext, g_nulls_last, g_order_keys_expr, g_adapt_estimates,
// g_estimate_adjust_factor), and helper functions (nullsFlag) - all imported above via const aliasing

// Removed: Index catalog system now in index_catalog module (M3.1 Phase 3 index management extraction)
// Original code was ~106 lines, now extracted to index_catalog.zig
// Includes: IndexStats struct, global catalog state, initIndexCatalog(), chooseIndexForPredicate(),
// indexStatsOnInsert(), indexStatsOnDelete() - all imported above via const aliasing

// Removed: Graph storage singleton and data directory now in graph_store module (M3.1 Phase 3 graph persistence extraction)
// Original: g_graph_storage, g_data_dir variables (~2 lines) - now in graph_store.zig

// Removed: g_mvcc_manager global variable (~1 line) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: Implementation-defined flag cache and related functions now in server_flags module
// Original: g_impl_defined_codes, g_impl_defined_inited variables (~2 lines)
// Original: initImplDefinedFlags() function (~14 lines)
// (paginationStreamScaffold was extracted too, then deleted as a dead
// intent-stub in GAP-0875 — streaming pagination is NOT implemented.)
// Total extracted: ~22 lines to server_flags.zig module

// Removed: server_utilities.getOrCreateMVCCManager() function (~10 lines) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: Graph storage management functions now in graph_store module (M3.1 Phase 3 graph persistence extraction)
// Original: getOrCreateGraphStore() function (~28 lines)
// Original: getNextNodeId() function (~10 lines)
// Original: tryLoadGraphFromDir() function (~98 lines)
// Original: saveGraphToDir() function (~86 lines)
// Original: initializeSampleGraph() function (~24 lines)
// Total extracted: ~246 lines to graph_store.zig module

// Removed: server_utilities.execInsertValue() function (~25 lines) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: server_utilities.buildScanValuesResult() function (~75 lines) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: hasEqualityPredicate() function (~25 lines) now in query_executor module (M3.3 Phase 3 fourth increment)

// Removed: Query utility functions now in query_executor module (M3.3 Phase 3 query utilities extraction)
// Original: valueTypeName() function (~9 lines)
// Original: bindingValueTypeName() function (~9 lines)
// Original: bindingValueRowToJson() function (~48 lines)
// Total extracted: ~66 lines to query_executor.zig module

// Removed: server_utilities.writeErrorWithFlags() function (~10 lines) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: Diagnostic utility functions now in query_executor module (M3.3 Phase 3 third increment)
// Original: collectTextDiagnostics() function (~27 lines)
// Original: collectPlannerDiagnostics() function (~10 lines)
// Total extracted: ~37 lines to query_executor.zig module

// Removed: Query utility functions now in query_executor module (M3.3 Phase 3 query utilities extraction)
// Original: writeJsonValue() function (~48 lines)
// Original: parseParams() function (~40 lines)
// Original: buildExplainJson() function (~76 lines)
// Total extracted (first increment): ~164 lines to query_executor.zig module

// Removed: writeBindingsAdaptive() function (~30 lines) now in query_executor module (M3.3 Phase 3 fifth increment)

// Removed: StageTimings struct (~46 lines) now in query_executor module (M3.3 Phase 3 sixth increment)
// GAP-0874 (2026-06-10) alloc-metrics decision: the deferred counting-allocator
// integration was RESOLVED as "won't wire". The PROFILE fallback's per-op
// bytes_alloc/memory block is a deterministic synthetic model pinned as a wire
// contract by the e2e_protocol_profile_* test battery and documented as such in
// docs/EXPLAIN_PROFILE.md and docs/BINARY_PROTOCOL.md; real per-op attribution
// would require per-operator allocator threading (a PROFILE redesign, tracked
// separately if ever needed). Real process-level memory telemetry exists via
// the OTel `process.runtime.zig.memory.resident_set` gauge (otel_metrics.zig
// registerRuntimeMetrics, /proc/self-backed). The bit-rotted dead wrappers
// (src/util/counting_allocator.zig pre-0.14 vtable, src/util/tracking_alloc.zig)
// were deleted — neither had a live caller.

// Value-based canonical key: encodes row values directly to avoid JSON reparsing.
// Removed: canonicalValuesKey() function (~34 lines) now in query_executor module (M3.3 Phase 3 second increment)

// Removed: canonicalRowKey() function (~100 lines) now in query_executor module (M3.3 Phase 3 fourth increment)

// Removed: buildAdditionalStatusesAlloc() function (~11 lines) now in query_executor module (M3.3 Phase 3 fourth increment)

// Removed: distinctDedup() function (~38 lines) now in query_executor module (M3.3 Phase 3 fifth increment)

// Removed: AllocTracker struct (~1 line) now in query_executor module (M3.3 Phase 3 sixth increment)
// Removed: trackerGet() function (~5 lines) now in query_executor module (M3.3 Phase 3 sixth increment)

// Centralized CDC_CONTROL handler to eliminate duplicated logic between network paths.
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC_CONTROL"; ASPECT=Refactor; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_ControlReset; OWNER=server; UPDATED=2025-09-20
// Removed: handleCdcControl() function (~12 lines) now in message_handlers module (M3.2 Phase 3 message handlers extraction)

// Removed: handleQuicConnection() function (~166 lines) now in quic_connection_handler module (M3.3 Phase 3 QUIC handlers extraction)
// Removed: processMessage() function (~422 lines) now in quic_connection_handler module (M3.3 Phase 3 QUIC handlers extraction)
// Total extracted: ~588 lines to quic_connection_handler.zig module

/// Bind a dependent library's observability seam to geode's
/// TracerProvider/MeterProvider. Comptime no-op when the lib was built
/// with `-Dwith_otel=false`. Wraps `otel_metrics.bindLibraryGlobals` and
/// downgrades errors to a warning since OTel wiring failures must never
/// block server startup.
fn bindLib(comptime LibObservability: type, comptime scope_name: []const u8) void {
    const otel_metrics_facade = @import("otel_metrics");
    otel_metrics_facade.bindLibraryGlobals(LibObservability, scope_name) catch |err| {
        log.warn("Failed to bind library otel observability", &.{
            Attr.string("scope", scope_name),
            Attr.string("error", @errorName(err)),
        });
    };
}

// GAP-0343 (RSS): pin glibc's mmap/trim thresholds so large per-connection
// buffers (e.g. the multi-MB stream reassembly buffer sized by max_stream_data)
// are mmap'd and munmap'd on free instead of being retained in malloc arenas.
// glibc dynamically RAISES M_MMAP_THRESHOLD (up to 32 MiB) after freeing mmap'd
// chunks, which lets those buffers fall back into sbrk arenas that are never
// returned to the OS — under connection churn RSS climbed ~17 MB per connection
// and a single 5-minute load exceeded 9 GB. Setting M_MMAP_THRESHOLD also
// disables that dynamic adjustment, so freed per-connection memory is returned
// and RSS stays flat (matching the page-backed debug allocator profile).
// No-op on non-Linux / non-glibc targets.  mallopt is a glibc extension; musl
// does not provide it, so guard the cross-compile path as well.
fn tuneServerMalloc() void {
    if (comptime builtin.os.tag != .linux) return;
    if (comptime builtin.target.abi == .musl) return;
    const c = struct {
        extern "c" fn mallopt(param: c_int, value: c_int) c_int;
    };
    const M_TRIM_THRESHOLD: c_int = -1;
    const M_MMAP_THRESHOLD: c_int = -3;
    _ = c.mallopt(M_MMAP_THRESHOLD, 128 * 1024);
    _ = c.mallopt(M_TRIM_THRESHOLD, 128 * 1024);
}

// GAP-0839: replay persisted tenants into the live HierarchyManager and the
// per-tenant quota manager after the registry hydrates from disk. The registry
// is the durable source of truth; the hierarchy and quota manager are derived
// runtime structures that must be rebuilt on every start.
//
// addTenant requires a tenant's parent to already exist in the hierarchy, but
// the registry snapshot is unordered, so we iterate to a fixed point: each pass
// adds every tenant whose parent is already present (or has no parent), until a
// pass makes no progress (any residue is an orphaned parent reference, which we
// log and skip rather than fail server startup over).
// CANARY: REQ=REQ-GAP-0848-TENANCY-DEFAULT-001; FEATURE="StrictTenancyAutoDefault"; ASPECT=ServerInit; STATUS=TESTED; TEST=tests/test_gap0848_tenancy_default.zig; OWNER=security; UPDATED=2026-06-09
// GAP-0848: resolve and apply the effective strict-tenancy mode. Reads the
// GEODE_PERMISSIVE_TENANCY break-glass opt-out, delegates the decision to the
// pure resolver in `tenancy.zig`, applies it, and logs the reason honestly.
fn applyEffectiveStrictTenancy(gpa: std.mem.Allocator, explicit_strict: bool, multi_tenant: bool) void {
    const permissive_override = envBool(gpa, "GEODE_PERMISSIVE_TENANCY", false);
    const decision = geode.tenancy.resolveEffectiveStrictTenancy(explicit_strict, multi_tenant, permissive_override);
    geode.tenancy.setStrictTenancy(decision.strict);
    switch (decision.reason) {
        .explicit_strict => {}, // already logged where the explicit flag was applied
        .single_tenant_permissive => {}, // single-tenant: legacy behaviour, no noise
        .auto_strict_multi_tenant => log.warn(
            "SECURITY: multi-tenant deployment detected (>=1 non-default tenant registered) — strict tenancy AUTO-ENABLED (GAP-0848). Tenant-scoped operations with no concrete tenant scope (unset/empty/\"default\") will be REJECTED. To force the legacy permissive behaviour, set GEODE_PERMISSIVE_TENANCY=1.",
            &.{},
        ),
        .explicit_permissive_override => log.warn(
            "SECURITY: multi-tenant deployment detected but GEODE_PERMISSIVE_TENANCY=1 is set — strict tenancy DISABLED. A tenant-scoped operation with no concrete tenant scope will read ALL tenants' data (cross-tenant leak). Remove GEODE_PERMISSIVE_TENANCY or enable --strict-tenancy to close this.",
            &.{},
        ),
    }
}

fn rehydrateTenantDerivedState(
    gpa: std.mem.Allocator,
    reg: *geode.tenant_registry.TenantRegistry,
    engine: *@import("rls").RLSEngine,
    quota_mgr: *geode.tenant_quota.TenantQuotaManager,
) void {
    const recs = reg.list(gpa) catch |err| {
        log.warn("tenant_registry.rehydrate_list_failed", &.{Attr.string("error", @errorName(err))});
        return;
    };
    defer geode.tenant_registry.TenantRegistry.freeRecordSlice(gpa, recs);
    if (recs.len == 0) return;

    // Track which tenants have been added to the hierarchy this rehydrate.
    var added = std.AutoHashMap(usize, void).init(gpa);
    defer added.deinit();

    var made_progress = true;
    while (made_progress and added.count() < recs.len) {
        made_progress = false;
        for (recs, 0..) |rec, i| {
            if (added.contains(i)) continue;
            const parent_ready = if (rec.parent) |p| engine.hierarchy_manager.tenant_hierarchy.contains(p) else true;
            if (!parent_ready) continue;
            engine.hierarchy_manager.addTenant(rec.tenant_id, rec.parent) catch |err| switch (err) {
                error.TenantAlreadyExists => {},
                else => log.warn("tenant_registry.rehydrate_hierarchy_failed", &.{
                    Attr.string("tenant", rec.tenant_id),
                    Attr.string("error", @errorName(err)),
                }),
            };
            added.put(i, {}) catch {};
            made_progress = true;
        }
    }
    if (added.count() < recs.len) {
        log.warn("tenant_registry.rehydrate_incomplete_orphan_parents", &.{
            Attr.int("added", @intCast(added.count())),
            Attr.int("total", @intCast(recs.len)),
        });
    }

    // Replay quota overrides into the live manager (order-independent).
    for (recs) |rec| {
        if (!rec.has_quota) continue;
        quota_mgr.setQuota(rec.tenant_id, .{
            .max_connections = rec.max_connections,
            .max_concurrent_queries = rec.max_concurrent_queries,
            .max_graphs = rec.max_graphs,
            .max_nodes_per_graph = rec.max_nodes_per_graph,
        }) catch |err| log.warn("tenant_registry.rehydrate_quota_failed", &.{
            Attr.string("tenant", rec.tenant_id),
            Attr.string("error", @errorName(err)),
        });
    }

    log.info("tenant_registry.rehydrated", &.{Attr.int("tenants", @intCast(recs.len))});
}

pub fn main() !void {
    // Return freed large per-connection allocations to the OS (see notes on
    // tuneServerMalloc). Must run before the first glibc allocation.
    tuneServerMalloc();

    // Raise RLIMIT_NOFILE soft to hard before anything opens an FD. Shells
    // that don't bump the systemd default (LimitNOFILESoft=1024) would
    // otherwise cap us at 1024 FDs, and the sharded storage engine opens
    // ~177 FDs per CREATE GRAPH (16 shards x ~11 files). Without this,
    // geodetestlab spec dsn_graph_binding.yml hits EMFILE on the ~5th
    // graph and surfaces as `ProcessFdQuotaExceeded`.
    const fd_raise = fd_limit.raiseSoftToHard();
    if (fd_raise.raised) {
        std.debug.print(
            "[startup] raised RLIMIT_NOFILE soft {d} -> {d} (hard {d})\n",
            .{ fd_raise.soft_before, fd_raise.soft_after, fd_raise.hard },
        );
    }
    var gpa_instance = ServerAllocator{};
    defer {
        if (builtin.mode == .Debug) _ = gpa_instance.deinit();
    }
    // The server dispatches transport work on multiple threads. Wrap the
    // process allocator so request parsing/execution can safely allocate
    // concurrently without corrupting heap state.
    const gpa = gpa_instance.allocator();
    // The global catalog singleton is created lazily on the first connection
    // via ensureCatalogInstance (execution.zig). Without this defer, its
    // per-load allocations (src/schema/catalog.zig:408 col names etc.) would
    // outlive the DebugAllocator and surface as leaks on shutdown, which the
    // test harness interprets as a server crash mid-spec. See ensuing fix.
    defer geode.execution.cleanupCatalogInstance();
    // Parse server CLI args using modularized cli_args module (M3.2 Phase 3 CLI extraction)
    const config_opt = try cli_args.parseArgs(gpa);
    if (config_opt == null) return; // Help was shown, exit

    var config = config_opt.?;
    defer config.deinit(gpa);

    // Extract config values into local variables for compatibility with existing code
    var memcurve_profile = false;
    const listen_quic = config.listen_quic;
    const listen_grpc = config.listen_grpc;
    const order_keys_mode_expr = config.order_keys_mode_expr;
    const data_dir = config.data_dir;
    const log_level_arg = config.log_level_arg;

    // GAP-0909: a --data-dir that does not exist used to crash the server at
    // startup. Create it (mkdir -p); refuse cleanly only if creation fails.
    if (data_dir) |dir| {
        graph_store.ensureDataDir(dir) catch |err| {
            log.err("data dir unavailable; refusing to start", &.{
                Attr.string("path", dir),
                Attr.string("error", @errorName(err)),
            });
            return error.DataDirUnavailable;
        };
    }

    // Apply log level and MATCH overrides
    if (log_level_arg) |lla| {
        logger.setLevel(logger.parseLevel(lla));
    }
    log.info("server.start", &.{Attr.string("level", log_level_arg orelse "info")});

    // Distributed mode activates automatically when GEODE_CLUSTER_TOKEN is set.
    // CANARY: REQ=REQ-GAP-0503-DIST-GATE; FEATURE="DistributedMode"; ASPECT=ServerStartup; STATUS=TESTED; OWNER=core; UPDATED=2026-04-05

    // GAP-0269: Track total startup time for operator diagnostics
    const startup_begin = compat_milliTimestamp();

    // Initialize user management (auth is always enabled in the server process)
    var phase_start = compat_milliTimestamp();
    const user_mgmt = geode.user_management;
    user_mgmt.initUserStore(gpa) catch |err| {
        log.err("Failed to initialize user store", &.{Attr.string("error", @errorName(err))});
        return err;
    };
    defer user_mgmt.deinitUserStore();
    user_mgmt.setAuthEnabled(true);

    // CANARY: REQ=REQ-GPS-PDP-007; FEATURE="GPS Decision Engine"; ASPECT=InsecureAllowAll; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
    // --insecure-allow-all: wire the parsed flag into the GPS decision engine.
    // When set, gps.decide() short-circuits all authorization checks and returns
    // allow for every request. Explicit WARN log makes the bypass observable.
    const gps = geode.security.gps;
    // CANARY: REQ=REQ-GAP-0850-INSECURE-GUARD-001; FEATURE="InsecureAllowAllProductionGuard"; ASPECT=Startup; STATUS=TESTED; TEST=tests/test_gap0850_insecure_guard.zig; OWNER=security; UPDATED=2026-06-09
    // GAP-0850: refuse to start with --insecure-allow-all under production
    // conditions (release build OR GEODE_ENV=production) unless the operator
    // sets the explicit break-glass override. Runs BEFORE listeners bind so a
    // misconfigured production deployment never accepts a single request with
    // authorization fully bypassed. The pure guard lives in gps.zig so it is
    // unit-testable without a live server.
    {
        const env_production = if (posixGetenv("GEODE_ENV")) |v|
            std.ascii.eqlIgnoreCase(v, "production")
        else
            false;
        const insecure_override = envBool(gpa, gps.insecure_override_env, false);
        gps.validateInsecureMode(
            config.insecure_allow_all,
            builtin.mode != .Debug,
            env_production,
            insecure_override,
        ) catch {
            // GAP-0850 follow-up: emit the refusal via std.debug.print too, not
            // just the structured logger. At this pre-listener stage the
            // structured log sink may not reach stdout/stderr (same gap the
            // cert/key refuse-to-start at ~:1128 works around), so an operator
            // reading `kubectl logs` / `docker logs` must still see WHY the
            // process exited 1 — visibility cannot depend on log config.
            std.debug.print(
                "SECURITY: refusing to start — --insecure-allow-all is set under production conditions (release build or GEODE_ENV=production). This bypasses ALL authorization (tenant isolation, RLS, FLE). To override for an explicit break-glass recovery, set " ++ gps.insecure_override_env ++ "=1. See docs/security/MULTI_TENANT_HARDENING.md.\n",
                .{},
            );
            log.err(
                "SECURITY: refusing to start — --insecure-allow-all is set under production conditions (release build or GEODE_ENV=production). This bypasses ALL authorization (tenant isolation, RLS, FLE). To override for an explicit break-glass recovery, set " ++ gps.insecure_override_env ++ "=1. See docs/security/MULTI_TENANT_HARDENING.md.",
                &.{},
            );
            std.process.exit(1);
        };
    }
    if (config.insecure_allow_all) {
        gps.setInsecureAllowAll(true);
        // CANARY: REQ=REQ-GAP-0842-INSECURE-BANNER-001; FEATURE="InsecureAllowAllStartupBanner"; ASPECT=Startup; STATUS=TESTED; TEST=tests/test_gap0842_insecure_allow_all_banner.zig; OWNER=security; UPDATED=2026-06-08
        // GAP-0842: escalate the bypass notice from a single-line WARN to a
        // prominent, unmistakable multi-line banner. The banner spells out that
        // tenant isolation, RLS, and FLE authorization are ALL disabled so the
        // condition cannot be missed in a crowded startup log. We do NOT
        // auto-refuse-to-start on multi-tenant data because tenant membership is
        // a per-record tag, not an on-disk directory — see the rationale in
        // gps.insecureAllowAllBanner() and docs/security/MULTI_TENANT_HARDENING.md.
        std.debug.print("\n{s}\n", .{gps.insecureAllowAllBanner()});
        log.warn("SECURITY: Geode running with --insecure-allow-all: all authorization checks bypassed (tenant isolation, RLS, and FLE authz are ALL disabled). NOT FOR PRODUCTION. See docs/security/MULTI_TENANT_HARDENING.md.", &.{});
    }

    // CANARY: REQ=REQ-MULTI-TENANT-STRICT-001; FEATURE="StrictTenancyMode"; ASPECT=Startup; STATUS=TESTED; TEST=tests/test_gap0840_strict_tenancy.zig; OWNER=security; UPDATED=2026-06-08
    // GAP-0840: --strict-tenancy / GEODE_STRICT_TENANCY=1 — wire the parsed flag
    // into the shared tenancy decision. When set, a tenant-scoped operation with
    // no concrete tenant scope (unset/empty/"default") is rejected with
    // error.TenantScopeRequired instead of silently reading all tenants' data.
    //
    // GAP-0848: the FINAL effective strict-tenancy decision is resolved AFTER the
    // tenant registry is hydrated (see the `applyEffectiveStrictTenancy` call
    // below), because auto-strict needs the "multi-tenant?" signal from the
    // registry. We still apply the explicit flag here so strict is active as
    // early as possible when the operator asked for it; the post-hydration
    // resolution is a no-op when explicit strict is already on (explicit wins).
    if (config.strict_tenancy) {
        geode.tenancy.setStrictTenancy(true);
        log.warn("SECURITY: Geode running with --strict-tenancy: tenant-scoped operations with no tenant scope (unset/empty/\"default\") will be REJECTED.", &.{});
    }

    std.debug.print("[startup] user store initialized ({d}ms)\n", .{compat_milliTimestamp() - phase_start});

    // GPS Phase 4 (Task 4-4): bootstrap in-memory PolicyCatalog so that
    // CREATE POLICY / DROP POLICY / SHOW POLICIES can resolve it at runtime.
    // Lifetime: scoped to this function (the server process). Phase 5 (Task 4-5)
    // will persist to __geode_security; for now the catalog is in-memory only
    // and does not survive restart.
    // CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=ServerStartupCatalog; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_integration.zig; OWNER=security; UPDATED=2026-05-20
    const policy_catalog_mod = @import("geode").security.policy_catalog;
    var global_policy_catalog = policy_catalog_mod.PolicyCatalog.init(gpa);
    defer global_policy_catalog.deinit();
    policy_catalog_mod.setGlobalCatalog(&global_policy_catalog);
    defer policy_catalog_mod.setGlobalCatalog(undefined);

    // GPS Phase 7 (Task 7-1): bootstrap bounded LRU decision cache.
    // Capacity 1024 covers typical single-tenant workloads; invalidated
    // automatically on every addPolicy / removePolicy call.
    // CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=ServerStartupCache; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
    const decision_cache_mod = @import("geode").security.decision_cache;
    var global_decision_cache = decision_cache_mod.DecisionCache.init(gpa, decision_cache_mod.DEFAULT_CAPACITY);
    defer global_decision_cache.deinit();
    decision_cache_mod.setGlobalCache(&global_decision_cache);
    defer decision_cache_mod.clearGlobalCache();

    // NOTE: ensureDefaultUser() is called AFTER server_init.initialize() below
    // so that users from the auth graph store are synced first (avoiding a
    // second admin with a different password).

    // Resolve certificate paths and ensure they exist
    const cert_paths = try cli_args.resolveCertPaths(gpa, &config);
    var cert_path = cert_paths.cert_path;
    var key_path = cert_paths.key_path;
    const cert_explicit = cert_paths.cert_explicit or cert_paths.key_explicit;

    // Try to ensure certificates if using QUIC or gRPC (TLS needed for both).
    //
    // CANARY: REQ=REQ-CLUSTER-CERT-PROVIDED-HONORED; FEATURE="DistributedClusterTLS"; ASPECT=ExplicitCertLoadAsIs; STATUS=TESTED; TEST=tests/test_cert_provided_cert_honored.zig; OWNER=distributed; UPDATED=2026-06-04
    //
    // An operator-PROVIDED --cert/--key (or config-file cert_path/key_path)
    // must be loaded exactly as supplied: never probe-then-regenerate, never
    // overwrite, never fall back to a throwaway /tmp self-signed cert. Doing
    // so silently downgraded security and — in a Kubernetes StatefulSet — gave
    // every node a distinct self-signed cert on the Raft port, so peers could
    // not verify each other and the cluster never elected a leader. See
    // docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md.
    phase_start = compat_milliTimestamp();
    if (listen_quic != null or listen_grpc != null) {
        if (cert_explicit) {
            // An explicit cert REQUIRES an explicit key (and vice versa): they
            // are a matching pair. A half-configuration is an operator error;
            // refuse loudly rather than silently self-signing the other half.
            if (!(cert_paths.cert_explicit and cert_paths.key_explicit)) {
                std.debug.print(
                    "SECURITY: --cert and --key (or config cert_path/key_path) must be provided together; got cert_explicit={}, key_explicit={}. Refusing to start.\n",
                    .{ cert_paths.cert_explicit, cert_paths.key_explicit },
                );
                log.err("TLS cert/key must be provided together; refusing to start", &.{
                    Attr.string("cert_path", cert_path),
                    Attr.string("key_path", key_path),
                });
                return error.IncompleteCertificateConfiguration;
            }
            // Load the provided cert/key as-is. Fail loud if unreadable —
            // do NOT self-sign. Use std.debug.print (reaches `kubectl logs`
            // at this pre-logger-flush stage, unlike the structured logger).
            cert_gen.requireExistingCertificates(cert_path, key_path) catch |err| {
                std.debug.print(
                    "SECURITY: operator-provided TLS certificate/key could not be read; refusing to start. cert='{s}' key='{s}' error={s}\n",
                    .{ cert_path, key_path, @errorName(err) },
                );
                log.err("operator-provided TLS cert/key unreadable; refusing to start", &.{
                    Attr.string("cert_path", cert_path),
                    Attr.string("key_path", key_path),
                    Attr.string("error", @errorName(err)),
                });
                return err;
            };
            std.debug.print(
                "[startup] using operator-provided TLS certificate {s} ({d}ms)\n",
                .{ cert_path, compat_milliTimestamp() - phase_start },
            );
            log.info("using operator-provided TLS certificate", &.{
                Attr.string("cert_path", cert_path),
                Attr.string("key_path", key_path),
            });
        } else {
            // Auto path: no cert supplied → generate-if-missing into the
            // resolved (data-dir/cert-dir) location, with a /tmp fallback only
            // when that location is not writable.
            cert_gen.ensureCertificatesAtPath(gpa, cert_path, key_path) catch |err| {
                log.warn("Could not generate certificates, using fallback paths", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.string("fallback_cert", "/tmp/geode-server.crt"),
                    Attr.string("fallback_key", "/tmp/geode-server.key"),
                });
                cert_path = "/tmp/geode-server.crt";
                key_path = "/tmp/geode-server.key";
                try cert_gen.ensureCertificatesAtPath(gpa, cert_path, key_path);
            };
            std.debug.print("[startup] certificates ready ({d}ms)\n", .{compat_milliTimestamp() - phase_start});
        }
    }

    // Initialize AuditLogger.
    //
    // 2026-04-24: the process-global audit logger is now opt-in
    // (`enabled = false` by default).  Security-graph mutations are
    // audited via a per-graph logger wired in
    // `graph_storage_adapter.initAuditForGraph`, triggered only when
    // the `__geode_security` graph is created.  The process-global
    // logger was never consumed by the mutation hot path — only
    // `setGlobalAuditLogger` writes it, and no code site reads it back
    // (grep confirms zero `getGlobalAuditLogger` callers in src/ and
    // tests/).  Turning the default off saves the keypair file
    // creation in every data dir and the "Set GEODE_AUDIT_PUB/SEC"
    // startup warning for operators who never configured audit.  See
    // `docs/performance/2026-04-24-sharding/AUDIT-PERF-TRIAGE.md`.
    //
    // Operators who want the process-global logger (e.g. for a future
    // hook into non-security-graph audit) can opt in via
    // `GEODE_AUDIT_ENABLED=1`.  The legacy `GEODE_DISABLE_AUDIT=1`
    // flag is preserved as a no-op for backward compatibility.
    var audit_config = audit.AuditLogger.Config{ .enabled = false };

    // #837: Operator-facing KMS URL. When set, the TDE key manager is
    // expected to use this endpoint for wrap/unwrap. When the URL is set
    // but the KMS is unreachable, the server must fail closed (refuse to
    // start) rather than silently fall back to a local key. The fail-
    // closed contract is implemented in src/security/tde.zig
    // configureKMS path; here we just surface the env var so operators
    // and the harness spec tde_kms_unreachable_fails_closed can drive it.
    const kms_url_env = getEnvVarOwned(gpa, "GEODE_KMS_URL") catch null;
    defer if (kms_url_env) |d| gpa.free(d);
    if (kms_url_env) |url| {
        log.info("KMS URL configured via GEODE_KMS_URL", &.{
            Attr.string("url", url),
        });
        // Best-effort KMS configuration. If the URL points at an unreachable
        // endpoint, configureKMS surfaces an error and the server refuses
        // to come up -- the fail-closed contract for #837.
        const result = (@import("geode").tde_stub).configureKMS(gpa, url) catch |err| {
            log.err("KMS configuration failed; refusing to start (fail-closed per GEODE_KMS_URL contract)", &.{
                Attr.string("error", @errorName(err)),
                Attr.string("url", url),
            });
            return err;
        };
        if (!result.configured) {
            log.err("KMS configuration unsuccessful; refusing to start", &.{
                Attr.string("test_result", result.test_result),
                Attr.string("url", url),
            });
            return error.KmsUnreachable;
        }
        log.info("KMS configured", &.{
            Attr.string("provider", result.provider_name),
            Attr.string("endpoint", result.endpoint),
            Attr.string("test_result", result.test_result),
        });
    }

    const audit_enable_env = getEnvVarOwned(gpa, "GEODE_AUDIT_ENABLED") catch null;
    defer if (audit_enable_env) |d| gpa.free(d);
    if (audit_enable_env) |d| {
        if (std.mem.eql(u8, d, "1") or std.mem.eql(u8, d, "true")) {
            audit_config.enabled = true;
            log.info("Process-global audit logger enabled via GEODE_AUDIT_ENABLED", &.{});
        }
    }

    // Legacy GEODE_DISABLE_AUDIT — kept for backward compat; a no-op
    // now that the default is already disabled, but honoured if
    // someone explicitly enabled via GEODE_AUDIT_ENABLED above.
    const audit_disable_env = getEnvVarOwned(gpa, "GEODE_DISABLE_AUDIT") catch null;
    defer if (audit_disable_env) |d| gpa.free(d);
    if (audit_disable_env) |d| {
        if (std.mem.eql(u8, d, "1") or std.mem.eql(u8, d, "true")) {
            audit_config.enabled = false;
            log.info("Process-global audit logger disabled via GEODE_DISABLE_AUDIT", &.{});
        }
    }

    var default_audit_path: ?[]u8 = null;
    defer if (default_audit_path) |p| gpa.free(p);
    const audit_path_env = getEnvVarOwned(gpa, "GEODE_AUDIT_LOG_PATH") catch null;
    defer if (audit_path_env) |p| gpa.free(p);
    if (audit_path_env) |p| {
        audit_config.file_path = p;
    } else if (data_dir) |dir| {
        default_audit_path = try std.fmt.allocPrint(gpa, "{s}/audit.jsonl", .{dir});
        audit_config.file_path = default_audit_path.?;
    }

    // Create heap-allocated audit logger to ensure stability.
    // GAP-0908: an unopenable audit sink (e.g. EACCES on the file or its
    // directory) is a graceful fail-closed refusal to start — not an
    // unhandled-error crash that also leaked the logger allocation.
    var audit_logger = audit.AuditLogger.createHeap(gpa, audit_config) catch |err| {
        log.err("cannot open audit log sink; refusing to start (fail-closed)", &.{
            Attr.string("path", audit_config.file_path),
            Attr.string("error", @errorName(err)),
        });
        return error.AuditSinkUnavailable;
    };
    defer {
        audit.setGlobalAuditLogger(null);
        audit_logger.deinit();
        gpa.destroy(audit_logger);
    }
    audit.setGlobalAuditLogger(audit_logger);

    // Initialize server components using modularized server_init (M3.2 Phase 3 initialization extraction)
    phase_start = compat_milliTimestamp();
    var init_ctx = try server_init.initialize(
        gpa,
        order_keys_mode_expr,
        data_dir,
        &memcurve_profile,
    );
    // GAP-0426: Fix dangling self-referential pointers after struct return.
    // initialize() sets shared_ast_cache = &shared_ast_cache_storage.? internally,
    // but returning the struct by value copies it to this stack frame, making those
    // pointers point at the callee's dead stack. Re-derive them at the final location.
    init_ctx.fixupSelfPointers();
    defer init_ctx.deinit();

    std.debug.print("[startup] server initialized ({d}ms)\n", .{compat_milliTimestamp() - phase_start});

    phase_start = compat_milliTimestamp();
    if (init_ctx.auth_graph_mgr) |agm| {
        user_mgmt.setPersistentUserResolver(.{
            .lookup_fn = lookupPersistentAuthUser,
            .has_users_fn = persistentAuthUsersExist,
            .list_fn = listPersistentAuthUsers,
            .auth_version_fn = lookupPersistentAuthVersion,
        });
        // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-036; FEATURE="AuthDDLPersistence"; ASPECT=StartupWiring; STATUS=TESTED; TEST=tests/test_auth_persistence.zig; OWNER=security; UPDATED=2026-06-11
        // P7: Install write-through callbacks for user/role/grant DDL and hydrate
        // in-memory state from __geode_security.
        server_init.wireAuthDDLCallbacks(agm, gpa);
        log.info("Authentication configured for persistent auth graph with LRU cache", &.{});

        // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=StartupHydration; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
        // GPS Phase 4 (Task 4-5): hydrate the in-memory PolicyCatalog from the
        // persisted :Policy nodes in __geode_security.  Errors are non-fatal —
        // the server continues without pre-loaded policies (operators can
        // recreate them via DDL).
        server_init.wireGpsPolicyHooks(gpa, agm, &global_policy_catalog);
    } else {
        user_mgmt.setPersistentUserResolver(null);
        // Review-0016 Important-3 (2026-07-01 incident residual): this branch
        // runs when NO AuthGraphManager is active (AGM.init threw, HMAC key
        // unavailable, or the store fell back to in-memory). Historically it
        // unconditionally seeded an IN-MEMORY admin from GEODE_ADMIN_PASSWORD —
        // so on a data dir that still holds a persisted admin credential, the
        // env password became the working admin credential for the session
        // (the operator-visible "password tracks the env var" symptom). Run
        // the same engine-level persisted-admin check the bootstrap guard
        // uses and REFUSE env seeding (fail closed) when persisted records
        // exist or the engine check itself fails. The persisted credential on
        // disk stays authoritative; admin login may be unavailable this
        // session until the operator repairs the store — strictly better than
        // silently activating the env credential.
        const agm_mod = @import("auth_graph_manager");
        const persisted_on_disk: ?u64 = agm_mod.persistedSecurityUserCountOnDisk() catch null; // null => engine error => fail closed
        if (persisted_on_disk == null or persisted_on_disk.? > 0) {
            log.err("ADMIN ENV SEEDING SKIPPED (fail-closed): no auth graph manager is active this session, but the storage engine reports persisted admin records in __geode_security (or errored while checking); refusing to seed an in-memory admin from GEODE_ADMIN_PASSWORD — the persisted credential remains authoritative. Repair the auth graph / HMAC key setup and restart.", &.{
                Attr.uint("persisted_user_records", persisted_on_disk orelse 0),
                Attr.string("engine_check", if (persisted_on_disk == null) "error (fail-closed)" else "ok"),
            });
            std.debug.print("[startup] admin env seeding SKIPPED: persisted admin records exist on disk (or the engine check failed) but the auth graph manager is unavailable; GEODE_ADMIN_PASSWORD ignored (fail-closed)\n", .{});
        } else {
            user_mgmt.ensureDefaultUser(gpa) catch |err| {
                log.err("Failed to create default users", &.{Attr.string("error", @errorName(err))});
                return err;
            };
        }
    }
    std.debug.print("[startup] auth cache configured ({d}ms)\n", .{compat_milliTimestamp() - phase_start});

    // Extract initialization values for compatibility with existing code
    const env_spill_threshold = init_ctx.env_config.spill_threshold;
    const env_storage_checksum_error = init_ctx.env_config.storage_checksum_error;
    const disable_estimates = init_ctx.env_config.disable_estimates;
    const compact_profile = init_ctx.env_config.compact_profile;
    memcurve_profile = init_ctx.env_config.memcurve_profile;

    // CANARY: REQ=REQ-OTEL-METRICS-002; FEATURE="OTel Instrumentation"; ASPECT=ServerInit; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
    //
    // Initialise the OTel MeterProvider BEFORE the legacy Prometheus
    // metrics server starts up — Task 7 reroutes /metrics to render
    // through the OTel exporter, and that exporter needs the global
    // provider to be live the moment the HTTP listener starts accepting.
    const otel_metrics_facade = @import("otel_metrics");
    const otel_resource_mod = @import("otel_resource");

    // Per-process instance_id. Use uuidv4 if v7 is unavailable; either
    // is acceptable as a unique identifier — v7's k-sortable property is
    // a "nice to have" for observability tools, not a correctness need.
    var instance_id_buf: [36]u8 = undefined;
    const instance_id: []const u8 = blk: {
        const uuid_lib = @import("uuid");
        // Try v7 first if exposed; fall back to v4. Both produce a
        // 36-char canonical string.
        // newV7AtTime with an explicit portable timestamp: newV7()'s default
        // clock uses a raw Linux-only clock_gettime syscall that faults
        // (SIGSYS) on non-Linux hosts. Fall back to v4 (no clock) if needed.
        const id = if (@hasDecl(uuid_lib, "newV7AtTime"))
            uuid_lib.newV7AtTime(compat_milliTimestamp()) catch uuid_lib.newV4() catch unreachable
        else
            uuid_lib.newV4() catch unreachable;
        _ = id.toString(&instance_id_buf);
        break :blk instance_id_buf[0..];
    };

    const cluster_token = getEnvVarOwned(gpa, "GEODE_CLUSTER_TOKEN") catch null;
    defer if (cluster_token) |t| gpa.free(t);
    const node_id = getEnvVarOwned(gpa, "GEODE_NODE_ID") catch null;
    defer if (node_id) |n| gpa.free(n);
    const cluster_name = getEnvVarOwned(gpa, "GEODE_CLUSTER_NAME") catch null;
    defer if (cluster_name) |c| gpa.free(c);
    const env_name = getEnvVarOwned(gpa, "OTEL_DEPLOYMENT_ENVIRONMENT") catch null;
    defer if (env_name) |e| gpa.free(e);

    const node_role: otel_resource_mod.NodeRole = if (cluster_token != null) .leader else .standalone;

    // CANARY: REQ=REQ-GAP-0503-DIST-BOOT; FEATURE="DistributedMode"; ASPECT=ClusterBootstrap; STATUS=TESTED; TEST=tests/test_cluster_bootstrap.zig; OWNER=core; UPDATED=2026-06-11
    // Cluster bootstrap (Tasks A2/A4 of the 2026-05-25 distributed
    // cluster testing plan).  Reads GEODE_CLUSTER_TOKEN/NODE_ID/NAME/
    // PEERS/CLUSTER_PORT (plus --cluster-port / --peers CLI overrides)
    // and constructs a ClusterCoordinator.  Returns null in standalone
    // mode so the single-node path is unchanged.
    //
    // NOTE: we deliberately do NOT call coordinator.start() yet — the
    // background-loop call chain (raftLoop / networkLoop / healthLoop /
    // replicationLoop) reaches a portion of cluster.zig + raft_consensus.zig
    // + raft_schema.zig that still needs a Zig-0.16 + protobuf API sweep
    // (tracked as a follow-up task).  The coordinator is fully
    // constructed and owns raft + graph_store + nonce_tracker so OTel
    // tagging, log lines, and downstream cluster-aware code paths can
    // already observe it; activating the loops is the next step.
    const cluster_bootstrap = @import("cluster_bootstrap.zig");
    var cluster_handle: ?cluster_bootstrap.Bootstrap = null;
    defer if (cluster_handle) |*h| h.deinit();

    // Cluster FTS symmetry (2026-06-10 audit slice 3): wire the raft apply +
    // snapshot-install seams to the executor's fulltext live-maintenance so a
    // follower applying committed entries (or installing a snapshot) keeps its
    // FTS indexes identical to the leader's. Idempotent; harmless without a
    // cluster (the seams simply never fire).
    // ORDERING: must be registered before cluster bootstrap starts the raft
    // threads — applies replay committed entries immediately, so a null hook
    // here would silently skip FTS maintenance for the replayed entries.
    // CANARY: REQ=REQ-DIST-CLUSTER-FTS-APPLY-SYMMETRY; FEATURE="DistributedCluster"; ASPECT=ServerInitFtsApplyHook; STATUS=TESTED; TEST=tests/test_fts_apply_symmetry.zig; OWNER=distributed; UPDATED=2026-06-10
    geode.execution.fts_index_ops.registerFtsApplyHook();

    if (cluster_token != null) {
        // Build a small EnvMap with just the keys cluster_bootstrap needs.
        // std.process.getEnvMap was removed in Zig 0.16; we already have
        // the values via getEnvVarOwned (libc getenv wrapper), so we
        // populate a fresh Environ.Map with the five GEODE_CLUSTER_* keys
        // and let cluster_bootstrap consume them as it would from the
        // process environment.
        var process_env = std.process.Environ.Map.init(gpa);
        defer process_env.deinit();
        process_env.put("GEODE_CLUSTER_TOKEN", cluster_token.?) catch |env_err| {
            log.err("Failed to seed cluster_bootstrap env (token)", &.{Attr.string("error", @errorName(env_err))});
            return env_err;
        };
        if (node_id) |nid| {
            process_env.put("GEODE_NODE_ID", nid) catch |env_err| {
                log.err("Failed to seed cluster_bootstrap env (node_id)", &.{Attr.string("error", @errorName(env_err))});
                return env_err;
            };
        }
        if (cluster_name) |cn| {
            process_env.put("GEODE_CLUSTER_NAME", cn) catch |env_err| {
                log.err("Failed to seed cluster_bootstrap env (cluster_name)", &.{Attr.string("error", @errorName(env_err))});
                return env_err;
            };
        }
        if (getEnvVarOwned(gpa, "GEODE_CLUSTER_PORT")) |cp| {
            defer gpa.free(cp);
            process_env.put("GEODE_CLUSTER_PORT", cp) catch |env_err| {
                log.err("Failed to seed cluster_bootstrap env (cluster_port)", &.{Attr.string("error", @errorName(env_err))});
                return env_err;
            };
        } else |_| {}
        if (getEnvVarOwned(gpa, "GEODE_PEERS")) |peers_csv| {
            defer gpa.free(peers_csv);
            process_env.put("GEODE_PEERS", peers_csv) catch |env_err| {
                log.err("Failed to seed cluster_bootstrap env (peers)", &.{Attr.string("error", @errorName(env_err))});
                return env_err;
            };
        } else |_| {}
        // Intra-cluster (:4242 Raft mesh) bind address override. Optional;
        // defaults to 0.0.0.0 in cluster_bootstrap (correct on k8s, one pod per
        // netns). Required to run multiple nodes on ONE host (and for the
        // steady-state regression test) so each binds a DISTINCT address rather
        // than sharing 0.0.0.0:<port> via SO_REUSEPORT (which misroutes peer
        // handshake datagrams between the co-located processes). See
        // docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md.
        if (getEnvVarOwned(gpa, "GEODE_CLUSTER_LISTEN_ADDRESS")) |addr| {
            defer gpa.free(addr);
            process_env.put("GEODE_CLUSTER_LISTEN_ADDRESS", addr) catch |env_err| {
                log.err("Failed to seed cluster_bootstrap env (cluster_listen_address)", &.{Attr.string("error", @errorName(env_err))});
                return env_err;
            };
        } else |_| {}
        // GAP-0838 (Bug B): forward $HOSTNAME so cluster_bootstrap's identity
        // self-diagnostic can match this node against its GEODE_PEERS entry
        // (the StatefulSet pod name, e.g. `geode-1`) and flag a GEODE_NODE_ID
        // that doesn't equal this node's 1-based position. Best-effort: absent
        // HOSTNAME just disables the position-mismatch check.
        if (getEnvVarOwned(gpa, "HOSTNAME")) |hn| {
            defer gpa.free(hn);
            process_env.put("HOSTNAME", hn) catch {};
        } else |_| {}

        cluster_handle = cluster_bootstrap.maybeStart(
            gpa,
            process_env,
            config.cluster_port,
            config.peers,
            // Reuse the same TLS material the client-facing listener was
            // configured with (cert_gen.ensureCertificatesAtPath wrote them
            // into <data-dir>/server.crt above).  Without this plumbing the
            // cluster QuicTransport falls back to "certs/server.crt"
            // relative to CWD and `generateSelfSignedCert` is still a stub
            // in Zig 0.16 — networkLoop hard-fatals.  Task A6 (2026-05-25).
            cert_path,
            key_path,
            // Durable raft hard-state + log live under <data_dir>/raft via
            // FileStorage when the server has a data directory; null falls back
            // to non-durable in-memory raft state.
            data_dir,
        ) catch |err| {
            log.err("Cluster bootstrap failed; refusing to start", &.{Attr.string("error", @errorName(err))});
            return err;
        };
        if (cluster_handle) |h| {
            std.debug.print("[startup] Cluster coordinator started node_id={d} cluster_port={d} cluster_name={s}\n", .{ h.coordinator.node_id, h.coordinator.cluster_port, h.coordinator.cluster_name });
            log.info("Cluster coordinator started", &.{
                Attr.int("node_id", @intCast(h.coordinator.node_id)),
                Attr.int("cluster_port", @intCast(h.coordinator.cluster_port)),
                Attr.string("cluster_name", h.coordinator.cluster_name),
            });
        }
    }

    otel_metrics_facade.init(gpa, .{
        .service_version = build_options.version,
        .instance_id = instance_id,
        .node_role = node_role,
        .cluster_name = cluster_name,
        .node_id = node_id,
        .deployment_environment = env_name,
    }) catch |err| {
        log.warn("Failed to initialise OTel metrics", &.{
            Attr.string("error", @errorName(err)),
        });
    };
    defer otel_metrics_facade.shutdown();

    otel_metrics_facade.registerServerLifecycle(0) catch |err| {
        log.warn("Failed to register server lifecycle metrics", &.{
            Attr.string("error", @errorName(err)),
        });
    };

    // Bind dependent libraries' observability seams to geode's
    // TracerProvider/MeterProvider so spans they emit land in the same
    // OTLP/HTTP pipeline as geode's own spans (bottom-up traces).
    //
    // Each call is a comptime no-op when the lib was built with
    // `-Dwith_otel=false`. The libs whose otel pin and build options
    // align with geode's are bound here; thread_pool is intentionally
    // omitted because its pin is held back to avoid a "file exists in
    // modules" conflict with quic/grpc_zig's transitive thread_pool
    // resolution (see build.zig.zon comment on .thread_pool).
    bindLib(@import("wal").observability, "wal");
    bindLib(@import("gql_lib").observability, "gql");
    bindLib(@import("repl").observability, "repl");
    bindLib(@import("dns").observability, "dns");
    bindLib(@import("slog").observability, "slog");
    bindLib(@import("vulkan").observability, "vulkan");
    bindLib(@import("thread_pool").observability, "thread_pool");
    bindLib(@import("protobuf").observability, "protobuf");
    // CANARY: REQ=REQ-OTEL-METRICS-014; FEATURE="OTel Instrumentation"; ASPECT=ProcessMetrics; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-06-11
    otel_metrics_facade.registerRuntimeMetrics() catch |err| {
        log.warn("Failed to register runtime process metrics", &.{
            Attr.string("error", @errorName(err)),
        });
    };
    otel_metrics_facade.recordServerHealth("server", true);

    // CANARY: REQ=REQ-PROMETHEUS-WIRE-004; FEATURE="Prometheus Metrics Endpoint"; ASPECT=ServerInit; STATUS=TESTED; TEST=geodetestlab/specs/gap_0166_prometheus_metrics.yml; OWNER=monitoring; UPDATED=2026-01-14
    // GAP-0166: Initialize Prometheus metrics server if enabled via environment
    // Default port is 9090 for Prometheus metrics endpoint
    const metrics_port_env = getEnvVarOwned(gpa, "GEODE_METRICS_PORT") catch null;
    defer if (metrics_port_env) |p| gpa.free(p);
    const metrics_port: ?u16 = if (metrics_port_env) |p| std.fmt.parseInt(u16, p, 10) catch 9090 else null;
    if (metrics_port) |port| {
        _ = metrics_server.initGlobalMetrics(gpa, port) catch |err| {
            log.warn("Failed to initialize metrics server", &.{
                Attr.int("port", port),
                Attr.string("error", @errorName(err)),
            });
        };
        log.info("Prometheus metrics server started", &.{
            Attr.int("port", port),
            Attr.string("endpoint", "/metrics"),
        });
        log.info("Out-of-band liveness endpoint available (use for k8s livenessProbe instead of in-band 'RETURN 1' query)", &.{
            Attr.int("port", port),
            Attr.string("liveness_endpoint", "/health"),
            Attr.string("note", "GET http://<host>:$GEODE_METRICS_PORT/health returns 200 {\"status\":\"ok\"} on a dedicated thread, independent of the QUIC query path; bind address controlled by GEODE_METRICS_BIND (default 127.0.0.1)"),
        });
        // Repro-caught (2026-06-07 QUIC liveness-kill bug): the structured
        // `log.info` lines above do NOT reach stdout/stderr on the serve path
        // (same sink gap as the first-boot admin-password breadcrumb). Emit a
        // reliable `[startup]` line via std.debug.print — the mechanism every
        // other startup phase uses — so operators and k8s liveness configs can
        // discover the out-of-band /health URL in `kubectl logs` / `docker
        // logs` without reading source. This is what makes the bug-doc §9
        // probe-split actually adoptable.
        const metrics_bind_env = getEnvVarOwned(gpa, "GEODE_METRICS_BIND") catch null;
        const metrics_bind = if (metrics_bind_env) |b| b else "127.0.0.1";
        std.debug.print("[startup] out-of-band liveness ready: GET http://{s}:{d}/health (k8s livenessProbe; off the QUIC query path) — Prometheus /metrics on the same port\n", .{ metrics_bind, port });
        if (metrics_bind_env) |b| gpa.free(b);
    }
    defer metrics_server.shutdownGlobalMetrics(gpa);

    // GAP-0848 follow-up: hoisted tenant-state setup.
    //
    // This block was hoisted out of the `if (listen_quic)` block (where it used
    // to sit just after the RLS dispatch callback wiring) to run BEFORE the gRPC
    // serve paths below. The gRPC-only path does a blocking
    // `grpc_server.start(); return;` and the combined path submits a serve task,
    // both of which begin serving immediately — so any tenant state they depend
    // on (the global quota manager that gRPC handlers consult, the tenant
    // registry, and the resolved strict-tenancy mode) MUST be published first or
    // a multi-tenant gRPC deployment serves permissively. The `defer`s below live
    // in main()'s scope, so the globals remain published for the full lifetime of
    // BOTH the gRPC and QUIC serve loops and tear down on return exactly as
    // before. Nothing in this block performs network I/O or depends on the QUIC
    // transport; its only prerequisites (`gpa`, `config`, `data_dir`, and
    // `init_ctx` storage init at line ~1280) are already satisfied here.

    // GAP-0510 Task D1: Initialize the global expression RLS engine so that
    // property-based and temporal RLS policies are evaluated during query
    // execution.  The engine lives on the main thread's stack; connection
    // handlers access it via rls_types.getGlobalExprRLSEngine().
    // CANARY: REQ=REQ-SEC-RLS-WIRE-014; FEATURE="RLS Expression Wiring"; ASPECT=ServerInitExprEngine; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=security; UPDATED=2026-06-11
    const rls_core_mod = @import("rls");
    const rls_types_mod_hoist = @import("rls_types");
    var expr_rls_engine = try rls_core_mod.RLSEngine.init(gpa);
    defer expr_rls_engine.deinit();
    rls_types_mod_hoist.setGlobalExprRLSEngine(@ptrCast(&expr_rls_engine));
    defer rls_types_mod_hoist.setGlobalExprRLSEngine(null);

    // GAP-0839: Initialize the production per-tenant quota manager and the
    // durable tenant lifecycle registry, then publish both as process globals.
    // Before this, getGlobalQuotaManager() always returned null in production (so
    // every tenant resolved to default_quota — setQuota was tests-only), and
    // there was no tenant lifecycle surface at all.
    //
    // The registry is file-backed under {data_dir}/tenants/registry.jsonl and is
    // hydrated here on startup. After hydration we replay each persisted tenant
    // into (a) the expr-RLS HierarchyManager and (b) the quota manager, so a
    // server RESTART restores the full tenant hierarchy and per-tenant quota
    // overrides — not just the registry rows.
    //
    // The global manager is constructed with an UNLIMITED default_quota
    // (initUnlimited) so that PUBLISHING it is behavior-neutral: a tenant WITHOUT
    // an explicit set_quota override stays unlimited, exactly as before GAP-0839
    // (when getGlobalQuotaManager() was null and every quota check was skipped).
    // Only tenants with an explicit override — set via CALL geode.tenant.set_quota
    // or restored from the registry below — are enforced. Using the plain init()
    // (struct default 100/32) here would silently activate enforcement on every
    // existing deployment.
    // CANARY: REQ=REQ-TENANT-LIFECYCLE-003; FEATURE="TenantRegistryServerWiring"; ASPECT=ServerInit; STATUS=TESTED; TEST=tests/test_gap0839_tenant_lifecycle.zig; OWNER=security; UPDATED=2026-06-11
    var quota_manager = geode.tenant_quota.TenantQuotaManager.initUnlimited(gpa);
    defer quota_manager.deinit();
    geode.tenant_quota.setGlobalQuotaManager(&quota_manager);
    defer geode.tenant_quota.setGlobalQuotaManager(null);

    var tenant_reg = geode.tenant_registry.TenantRegistry.initWithDataDir(gpa, data_dir) catch blk: {
        log.warn("tenant_registry.init_failed_fallback_in_memory", &.{});
        break :blk geode.tenant_registry.TenantRegistry.init(gpa);
    };
    defer tenant_reg.deinit();
    geode.tenant_registry.setGlobalRegistry(&tenant_reg);
    defer geode.tenant_registry.setGlobalRegistry(null);

    // Replay persisted tenants into the live hierarchy + quota manager. The
    // registry is the source of truth; these structures are derived. Tenants are
    // sorted parent-before-child by their created_at so addTenant's "parent must
    // exist" invariant holds for hierarchies built in order; any out-of-order
    // parent is retried until the set stabilizes.
    rehydrateTenantDerivedState(gpa, &tenant_reg, &expr_rls_engine, &quota_manager);

    // CANARY: REQ=REQ-GAP-0848-TENANCY-DEFAULT-001; FEATURE="StrictTenancyAutoDefault"; ASPECT=Startup; STATUS=TESTED; TEST=tests/test_gap0848_tenancy_default.zig; OWNER=security; UPDATED=2026-06-09
    // GAP-0848: resolve the FINAL effective strict-tenancy mode now that the
    // tenant registry is hydrated, and BEFORE any gRPC/QUIC serve path begins. In
    // a multi-tenant deployment (>=1 non-default tenant registered) strict tenancy
    // auto-enables unless the operator explicitly opted out with
    // GEODE_PERMISSIVE_TENANCY=1. Explicit --strict-tenancy / GEODE_STRICT_TENANCY
    // (already applied above) always wins; single-tenant deployments keep the
    // legacy permissive behaviour.
    applyEffectiveStrictTenancy(gpa, config.strict_tenancy, tenant_reg.hasNonDefaultTenant());

    // CANARY: REQ=REQ-GAP-0901-GRPC-GLOBAL-INIT; FEATURE="GrpcTransport"; ASPECT=TransportAgnosticGlobals; STATUS=IMPL; TEST=tests/test_gap0901_grpc_globals.zig; OWNER=transport; UPDATED=2026-07-10
    // GAP-0901: these transport-agnostic globals — the per-IP auth rate
    // limiter, both RLS filter engines, the RLS deny-policy DDL callbacks, and
    // the mutation-timing / bulk-ingest gates — used to live INSIDE the
    // `if (listen_quic)` block below. The gRPC-only serve path does
    // `grpc_server.start(); return;` and never reached them, so gRPC handlers
    // ran with a null rate limiter and null/empty RLS engines (RLS DDL
    // procedures returned "engine not initialized"). Hoisted here, BEFORE the
    // gRPC serve path, exactly as the GAP-0848 tenant-state block was — the
    // `defer`s live in main()'s scope, so the globals stay published for the
    // full lifetime of BOTH serve loops and tear down on return as before.
    // (End-to-end gRPC verification remains blocked by the vendor grpc_zig
    // listener crash tracked as GAP-0893.)

    // S6: Initialize per-IP authentication rate limiter for brute-force protection.
    // CANARY: REQ=REQ-SEC-RATE-LIMIT-007; FEATURE="AuthRateLimiting"; ASPECT=ServerInit; STATUS=TESTED; TEST=geodetestlab/specs/authn_rate_limiter.yml; OWNER=security; UPDATED=2026-06-11
    const auth_rate_limiter_mod = @import("auth_rate_limiter.zig");
    // initFromEnv honors GEODE_AUTH_RATE_LOCKOUT_SECS / _MAX_ATTEMPTS so
    // the harness can exercise the lockout-expiry path with a short window.
    var ip_rate_limiter = auth_rate_limiter_mod.AuthRateLimiter.initFromEnv(gpa);
    defer ip_rate_limiter.deinit();
    quic_connection_handler.setAuthRateLimiter(&ip_rate_limiter);
    defer quic_connection_handler.setAuthRateLimiter(null);
    // Also set the centralized global so gRPC transport can access the same limiter.
    auth_rate_limiter_mod.setGlobalRateLimiter(&ip_rate_limiter);
    defer auth_rate_limiter_mod.setGlobalRateLimiter(null);

    // Task 1 (throughput plan): initialise per-mutation timing instrumentation.
    const mutation_timing = geode.mutation_timing;
    mutation_timing.init(null);

    // Task 11 (throughput plan): initialise bulk-ingest opt-in gate.
    geode.bulk_ingest.initFromEnv();

    // S1: Initialize the global RLS filter engine for label-based row filtering.
    // CANARY: REQ=REQ-SEC-RLS-WIRE-004; FEATURE="RLS Query Enforcement"; ASPECT=ServerInit; STATUS=TESTED; TEST=src/server/rls_filter.zig; OWNER=security; UPDATED=2026-06-11
    const rls_filter_mod = @import("rls_filter.zig");
    var rls_engine = rls_filter_mod.RLSFilterEngine.init(gpa);
    defer rls_engine.deinit();
    rls_filter_mod.setGlobalRLSFilterEngine(&rls_engine);
    defer rls_filter_mod.setGlobalRLSFilterEngine(null);

    // GAP-0510 Task 3: Also initialize the rls_types shared label-filter engine.
    // CANARY: REQ=REQ-SEC-RLS-WIRE-012; FEATURE="RLS Expression Wiring"; ASPECT=ServerInitLabelEngine; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=security; UPDATED=2026-06-11
    const rls_types_mod = @import("rls_types");
    var rls_types_engine = rls_types_mod.RLSFilterEngine.init(gpa);
    defer rls_types_engine.deinit();
    rls_types_mod.setGlobalRLSFilterEngine(&rls_types_engine);
    defer rls_types_mod.setGlobalRLSFilterEngine(null);

    // REQ-RLS-DDL-001: Wire the geode.rls.* deny-policy procedures to the live
    // engines the connection handlers consult.
    // CANARY: REQ=REQ-RLS-DDL-001; FEATURE="RLS deny-policy procedure"; ASPECT=ServerCallbackWiring; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/rls_cross_tenant_query_shapes.yml; OWNER=security; UPDATED=2026-05-22
    const rls_dispatch_mod = geode.execution.rls_dispatch;
    const RlsCbCtx = struct {
        label_engine: *rls_filter_mod.RLSFilterEngine,
        types_engine: *rls_types_mod.RLSFilterEngine,
    };
    var rls_cb_ctx: RlsCbCtx = .{
        .label_engine = &rls_engine,
        .types_engine = &rls_types_engine,
    };
    const RlsCbFns = struct {
        fn addDeny(
            ctx_anyopaque: ?*anyopaque,
            graph: []const u8,
            label: []const u8,
            username: []const u8,
        ) anyerror!void {
            const ctx: *RlsCbCtx = @ptrCast(@alignCast(ctx_anyopaque.?));
            try ctx.label_engine.addDenyPolicy(graph, label, username);
            ctx.types_engine.addDenyPolicy(graph, label, username) catch |err| {
                log.warn("rls_types addDenyPolicy failed", &.{
                    logging.Attr.string("err", @errorName(err)),
                    logging.Attr.string("graph", graph),
                    logging.Attr.string("label", label),
                });
            };
        }
        fn removeDeny(
            ctx_anyopaque: ?*anyopaque,
            graph: []const u8,
            label: []const u8,
            username: []const u8,
        ) usize {
            const ctx: *RlsCbCtx = @ptrCast(@alignCast(ctx_anyopaque.?));
            const before = ctx.label_engine.policyCount();
            ctx.label_engine.removeDenyPolicy(graph, label, username);
            ctx.types_engine.removeDenyPolicy(graph, label, username);
            const after = ctx.label_engine.policyCount();
            return if (before >= after) before - after else 0;
        }
        fn listDeny(
            ctx_anyopaque: ?*anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror![]rls_dispatch_mod.ListedPolicy {
            const ctx: *RlsCbCtx = @ptrCast(@alignCast(ctx_anyopaque.?));
            ctx.label_engine.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer ctx.label_engine.mu.unlock(std.Io.Threaded.global_single_threaded.io());

            var list = std.ArrayList(rls_dispatch_mod.ListedPolicy).empty;
            errdefer {
                for (list.items) |item| {
                    allocator.free(item.graph);
                    allocator.free(item.label);
                    allocator.free(item.username);
                }
                list.deinit(allocator);
            }
            for (ctx.label_engine.policies.items) |p| {
                if (!p.deny) continue;
                try list.append(allocator, .{
                    .graph = try allocator.dupe(u8, p.graph),
                    .label = try allocator.dupe(u8, p.label),
                    .username = try allocator.dupe(u8, p.username),
                });
            }
            return try list.toOwnedSlice(allocator);
        }
        fn count(ctx_anyopaque: ?*anyopaque) usize {
            const ctx: *RlsCbCtx = @ptrCast(@alignCast(ctx_anyopaque.?));
            return ctx.label_engine.policyCount();
        }
    };
    rls_dispatch_mod.setCallbacks(.{
        .ctx = @ptrCast(&rls_cb_ctx),
        .add_deny_fn = RlsCbFns.addDeny,
        .remove_deny_fn = RlsCbFns.removeDeny,
        .list_deny_fn = RlsCbFns.listDeny,
        .policy_count_fn = RlsCbFns.count,
    });
    defer rls_dispatch_mod.resetCallbacks();

    // gRPC server (optional)
    //
    // CANARY: REQ=REQ-ENG-3907-GRPC-TRANSPORT; FEATURE="GrpcTransport"; ASPECT=DualListenerLifetime; STATUS=TESTED; TEST=geodetestlab/specs/grpc_dual_transport.yml; OWNER=transport; UPDATED=2026-08-24
    //
    // ENG-3907 (B1): both owners live at FUNCTION scope so their teardown runs
    // at process shutdown. They used to be block-scoped inside the
    // `if (listen_grpc)` below, which meant `grpc_pool.deinit()` — which JOINS
    // the worker running the gRPC serve loop — fired at the END OF THAT BLOCK,
    // before the QUIC listener was ever bound. `serve --listen X --listen-grpc Y`
    // therefore deadlocked with the gRPC TCP port open, the QUIC UDP port never
    // bound, and the server answering nothing at all.
    //
    // Hoisting also closes a latent use-after-free on the grpc-only path's twin:
    // `grpc_server.deinit()` frees the SessionStore and session key that the
    // still-running accept thread reads from. Teardown order below is
    // pool-then-server so the worker is stopped (or timed out, loudly) before
    // the state it touches is released.
    var grpc_server_owner: ?*grpc_transport.GeodeGrpcServer = null;
    var grpc_pool_owner: ?*thread_pool.ThreadPool = null;
    defer {
        if (grpc_pool_owner) |p| p.deinit();
        if (grpc_server_owner) |s| {
            s.deinit();
            gpa.destroy(s);
        }
    }

    if (listen_grpc) |grpc_addr| {
        const colon = std.mem.lastIndexOfScalar(u8, grpc_addr, ':');
        var grpc_port: u16 = 3142;
        var grpc_address: []const u8 = "0.0.0.0";

        if (colon) |ci| {
            grpc_address = grpc_addr[0..ci];
            const p = grpc_addr[ci + 1 ..];
            grpc_port = std.fmt.parseUnsigned(u16, p, 10) catch 3142;
        } else {
            grpc_port = std.fmt.parseUnsigned(u16, grpc_addr, 10) catch 3142;
        }

        const grpc_config = grpc_transport.GrpcConfig{
            .spill_threshold = env_spill_threshold,
            .storage_checksum_error = env_storage_checksum_error,
            .disable_estimates = disable_estimates,
            .compact_profile = compact_profile,
            .memcurve_profile = memcurve_profile,
            .security_manager = init_ctx.security_manager,
            // GAP-0756: Parity with QUIC — gRPC handlers hit the same
            // cross-connection SharedQueryOptimizer plan cache.
            .shared_optimizer = init_ctx.shared_optimizer,
        };

        const grpc_server = try gpa.create(grpc_transport.GeodeGrpcServer);
        errdefer gpa.destroy(grpc_server);
        grpc_server.* = try grpc_transport.GeodeGrpcServer.init(gpa, grpc_port, cert_path, key_path, grpc_config);
        grpc_server_owner = grpc_server;

        if (listen_quic == null) {
            log.info("gRPC server started", &.{
                Attr.string("address", grpc_address),
                Attr.int("port", grpc_port),
            });
            try grpc_server.start();
            return;
        } else {
            const grpc_pool = thread_pool.ThreadPool.init(gpa, .{
                .num_threads = 1,
                .queue_capacity = 4,
            }) catch |err| {
                log.err("Failed to initialize gRPC server pool", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("port", grpc_port),
                });
                return err;
            };
            grpc_pool_owner = grpc_pool;
            try grpc_pool.submitBlocking(.{
                .context = @ptrCast(grpc_server),
                .callback = runGrpcServerTask,
            });

            log.info("gRPC server started", &.{
                Attr.string("address", grpc_address),
                Attr.int("port", grpc_port),
            });
        }
    }

    // QUIC mode: preferred over TCP
    if (listen_quic) |addr_str| {
        const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':');
        var port: u16 = quic_transport.DEFAULT_PORT;
        var address_str: []const u8 = "0.0.0.0";

        if (colon) |ci| {
            address_str = addr_str[0..ci];
            const p = addr_str[ci + 1 ..];
            port = std.fmt.parseUnsigned(u16, p, 10) catch quic_transport.DEFAULT_PORT;
        } else {
            // If no colon, treat as port only
            port = std.fmt.parseUnsigned(u16, addr_str, 10) catch quic_transport.DEFAULT_PORT;
        }

        // Initialize QUIC transport
        // GAP-0327: honor --max-connections; 0 means "transport default".
        var quic_init_cfg: quic_transport.QuicTransport.Config = .{
            .address = address_str,
            .port = port,
            .cert_path = cert_path,
            .key_path = key_path,
            .idle_timeout_ms = config.idle_timeout_ms,
        };
        // GAP-0927: wire --idle-timeout into the per-connection idle-reap
        // deadline too (previously hardcoded 300000ms, decoupled from the flag).
        quic_connection_handler.BufferedProtoReader.setIdleReapDeadlineMs(@intCast(config.idle_timeout_ms));
        // CANARY: REQ=REQ-QUIC-HC-021; FEATURE="HighFanoutConnectionLimit"; ASPECT=ServerEnv; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-26
        quic_init_cfg.max_connections = if (config.max_connections > 0)
            config.max_connections
        else
            envUsize(
                gpa,
                "GEODE_QUIC_MAX_CONNECTIONS",
                quic_init_cfg.max_connections,
                1,
                1_000_000,
            );
        var transport = try quic_transport.QuicTransport.init(gpa, quic_init_cfg);
        // In short-lived test runs we avoid tearing down the QUIC endpoint to sidestep
        // vendor teardown crashes; enable passive teardown when
        // GEODE_QUIC_PASSIVE_TEARDOWN=1 is present.
        const passive_teardown_env = if (getEnvVarOwned(gpa, "GEODE_QUIC_PASSIVE_TEARDOWN")) |v| blk: {
            defer gpa.free(v);
            break :blk true;
        } else |_| false;
        const passive_teardown = passive_teardown_env;
        defer {
            if (!passive_teardown) transport.deinit();
        }

        // GAP-0258: Initialize mTLS provider for QUIC client certificate authentication
        // CANARY: REQ=REQ-AUTH-MTLS-QUIC-005; FEATURE="mTLS over QUIC"; ASPECT=ServerInit; STATUS=TESTED; TEST=geodetestlab/specs/authn_mtls_rejection_matrix.yml; OWNER=security; UPDATED=2026-06-11
        const mtls_required_env = getEnvVarOwned(gpa, "GEODE_MTLS_REQUIRED") catch null;
        defer if (mtls_required_env) |e| gpa.free(e);
        const mtls_required = if (mtls_required_env) |v| blk: {
            if (v.len == 0) break :blk false;
            if (std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "1") or std.ascii.eqlIgnoreCase(v, "on"))
                break :blk true;
            break :blk false;
        } else false;

        if (mtls_required) {
            transport.config.require_client_cert = true;
        }

        var mtls_prov = geode.mtls_provider.MtlsProvider.init(gpa);
        defer mtls_prov.deinit();
        quic_connection_handler.setMtlsProvider(&mtls_prov);
        defer quic_connection_handler.setMtlsProvider(null);

        // GAP-0901: the per-IP auth rate limiter, both RLS filter engines, the
        // RLS deny-policy DDL callbacks, and the mutation-timing / bulk-ingest
        // gates were HOISTED to before the gRPC serve path (search
        // "GAP-0901"). They formerly lived here, INSIDE the `if (listen_quic)`
        // block, so the gRPC-only serve path never initialized them.
        // `ip_rate_limiter`, `rls_engine`, `rls_types_engine`, and `rls_cb_ctx`
        // are now in scope here from the hoisted block.

        // GAP-0848 follow-up (2026-06-09): the expression RLS engine, per-tenant
        // quota manager, durable tenant registry, derived-state rehydration, and
        // the effective strict-tenancy resolution were HOISTED to before the gRPC
        // serve paths (search "GAP-0848 follow-up: hoisted tenant-state setup").
        // They formerly lived here, INSIDE the `if (listen_quic)` block, which
        // meant the gRPC-only serve path (`grpc_server.start(); return;`) and the
        // combined-mode gRPC serve task both began serving with: no published
        // quota manager (gRPC handlers call getGlobalQuotaManager()), no tenant
        // registry, and strict tenancy UNRESOLVED — so a multi-tenant deployment
        // would serve gRPC permissively. The hoisted block's `defer`s live in
        // main()'s scope, so the globals stay published for the full lifetime of
        // BOTH the gRPC and QUIC serve loops and are torn down on return exactly
        // as before. `expr_rls_engine`, `quota_manager`, and `tenant_reg` are now
        // in scope here from the hoisted block.

        // GAP-0280: Initialize a server-wide timeseries Store so that
        // timeseries.value() calls in the QUIC/gRPC execution path return
        // real data instead of NULL.  The store lives on the main thread's
        // stack and is published via eval.setGlobalTimeseriesStore().
        // GAP-0865: FAIL-CLOSED by default — an engine open error (corrupt
        // WAL/segments, wrong TDE key, unreadable dir) aborts server start
        // instead of silently degrading to an empty in-memory store. The
        // wrapper creates `{data_dir}/timeseries` itself, so a fresh data
        // dir opens durably (the old code fell back to memory-only on every
        // fresh dir because the engine refuses to mkdir). Opt back into the
        // legacy soft behaviour with GEODE_TS_DURABILITY=best_effort (the
        // wrapper then degrades internally with a warning). Retention is
        // wired via GEODE_TS_RETENTION_DAYS and TDE via GEODE_TS_TDE=1 +
        // GEODE_TDE_KEY.
        // CANARY: REQ=REQ-TIMESERIES-WIRE-003; FEATURE="TimeseriesServerWiring"; ASPECT=ServerInit; STATUS=TESTED; TEST=src/eval.zig; OWNER=server; UPDATED=2026-04-01
        // CANARY: REQ=REQ-TS-PERSIST-001; FEATURE="TimeSeriesPersistence"; ASPECT=ServerInit; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=server; UPDATED=2026-06-10
        const ts_mod = geode.timeseries;
        var ts_store = ts_mod.Store.initWithConfig(gpa, .{
            .data_dir = data_dir,
            .durability = ts_mod.durabilityFromEnv(),
            .retention_max_age_ms = ts_mod.retentionMsFromEnv(),
            .encryption_key = ts_mod.encryptionKeyFromEnv() catch |err| {
                log.err("timeseries.tde_key_invalid", &.{Attr.string("error", @errorName(err))});
                return err;
            },
        }) catch |err| {
            log.err("timeseries.open_failed_fail_closed", &.{
                Attr.string("error", @errorName(err)),
                Attr.string("hint", "set GEODE_TS_DURABILITY=best_effort to degrade to in-memory"),
            });
            return err;
        };
        defer ts_store.deinit();
        // Engine init already replayed the WAL and verified segments;
        // loadFromDisk is a no-op kept for API symmetry.
        try ts_store.loadFromDisk();
        eval.setGlobalTimeseriesStore(&ts_store);
        defer eval.setGlobalTimeseriesStore(null);

        // GAP-0268: Wire WAL persistence hooks for checkpoint truncation.
        // The hooks allow the persistence loop to sync and truncate the WAL
        // after each successful checkpoint, preventing unbounded WAL growth.
        // CANARY: REQ=REQ-WAL-HOOKS-001; FEATURE="WAL Persistence Hooks"; ASPECT=ServerInit; STATUS=TESTED; TEST=tests/test_wal.zig; OWNER=storage; UPDATED=2026-06-11
        const wal_mod = geode.wal;
        wal_mod.installPersistenceHooks();
        defer wal_mod.removePersistenceHooks();

        if (mtls_required) {
            log.info("mTLS authentication enabled for QUIC connections", &.{});
        }

        phase_start = compat_milliTimestamp();
        try transport.listen();
        std.debug.print("[startup] QUIC transport listening ({d}ms)\n", .{compat_milliTimestamp() - phase_start});

        log.info("QUIC server started", &.{
            Attr.string("address", address_str),
            Attr.int("port", port),
            Attr.string("tls", "1.3"),
        });

        // Task 28 (Phase 9): spawn the embedded LSP TCP listener so
        // geode-ui / monaco-languageclient sessions can attach to the
        // same in-process schema view as QUIC handlers. `lsp_port == 0`
        // disables the listener entirely. The thread is detached and
        // lives for the lifetime of the server process — there is no
        // explicit join on shutdown because the listener will be torn
        // down with the process. Per-session threads are similarly
        // detached and exit when their LSP session terminates. See
        // `runLspListener` for the auth caveat.
        const lsp_bootstrap_cfg = parseLspBootstrapConfig(gpa);
        if (lsp_bootstrap_cfg.port != 0) {
            // Bootstrap the process-global AuthProvider used by every
            // accepted LSP session.  AuthProvider.init is allocation-only
            // (no I/O, no syscalls beyond the mutex pair); we keep it
            // alive for the lifetime of the process.  Empty stores by
            // default — operators populate API keys via the auth CLI /
            // server-side procedures before clients can authenticate.
            const lsp_provider = gpa.create(authn_mod.AuthProvider) catch |err| {
                log.err("Failed to allocate LSP AuthProvider", &.{Attr.string("error", @errorName(err))});
                return err;
            };
            lsp_provider.* = authn_mod.AuthProvider.init(gpa);
            g_lsp_auth_provider = lsp_provider;
            // The listener thread is detached and the verifier borrows
            // `lsp_provider` for the lifetime of the process, so the
            // tear-down has to wait until the rest of the server shutdown
            // sequence has joined / cancelled every in-flight LSP session
            // (see the QUIC drain block further down).  Order here matches
            // graph_store: register a defer on the same scope so the
            // free runs exactly once when `cmdServe` returns.  DebugAllocator
            // otherwise reports the AuthProvider as leaked on graceful exit.
            defer {
                g_lsp_auth_provider = null;
                lsp_provider.deinit();
                gpa.destroy(lsp_provider);
            }
            const lsp_verifier = lsp_auth_mod.verifierFromAuthProvider(lsp_provider);

            const lsp_thr = std.Thread.spawn(.{}, runLspListener, .{LspListenerArgs{
                .allocator = gpa,
                .port = lsp_bootstrap_cfg.port,
                .loopback_only = lsp_bootstrap_cfg.loopback_only,
                .verifier = lsp_verifier,
            }}) catch |err| {
                log.err("Failed to spawn LSP listener thread", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("port", @as(i64, lsp_bootstrap_cfg.port)),
                });
                return err;
            };
            lsp_thr.detach();
        } else {
            log.info("LSP listener disabled (--lsp-port=0)", &.{});
        }

        // GAP-0260: Start background persistence thread for write coalescing
        graph_store.startPersistenceThread(config.persist_interval_ms);
        // Gap 0039: the graceful-shutdown tail now flushes EAGERLY (before the
        // LIFO pool-deinit defers get a chance to wedge on a stuck connection
        // handler) and then arms the teardown watchdog. This flag makes the
        // defer skip the second stopPersistenceThread call — re-running the
        // final WAL sync + checkpoint on an already-clean store is safe but
        // wastes shutdown budget.
        var persistence_flushed_eagerly = false;
        defer {
            // Stop persistence thread first (final flush), then free the global store.
            // Without deinitGlobalStore(), all in-memory graph data (nodes, edges, indexes,
            // properties) leaks and the GPA reports errors on SIGTERM exit.
            if (!persistence_flushed_eagerly) graph_store.stopPersistenceThread(gpa);
            graph_store.deinitGlobalStore();
        }

        // #540: Spawn a dedicated poll thread to continuously process incoming
        // UDP datagrams. This decouples packet delivery from the accept loop,
        // eliminating the c=8+ contention bottleneck where handler threads starve
        // waiting for data that only arrives when the main thread calls poll().
        //
        // CANARY: REQ=REQ-QUIC-HC-004; FEATURE="QUIC High-Concurrency Shutdown"; ASPECT=PollLoopLifetime; STATUS=IMPL; OWNER=transport; UPDATED=2026-05-25
        // Register this defer before the connection/stream pools below so Zig's
        // LIFO teardown drains handlers while the poll thread is still alive.
        // Handlers parked in PollSync.waitForPoll need the producer to keep
        // delivering FIN/CONNECTION_CLOSE during SIGTERM shutdown.
        var poll_shutdown = std.atomic.Value(bool).init(false);
        // CANARY: REQ=REQ-QUIC-HC-053; FEATURE="QUIC High-Concurrency Requests"; ASPECT=MultiPollWorkers; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-11
        //
        // Release builds use a small poll-worker set so high fan-out request
        // bursts do not stall behind one endpoint poll loop. Debug keeps a
        // single worker to make local traces deterministic.
        //
        // CANARY: REQ=REQ-QUIC-HC-141; FEATURE="QUIC High-Concurrency Requests"; ASPECT=PollWorkerContentionCap; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-29
        // QUIC v0.1.21 removed the old generic long-header TLS dispatch
        // contention point, so high-fanout mixed read/write probes can use
        // more endpoint poll workers without all threads stacking on one
        // crypto path. Keep the cap bounded to avoid a poll-thread CPU storm
        // in same-process harnesses, but no longer clamp production to 16.
        const quic_poll_worker_count = envUsize(
            gpa,
            "GEODE_QUIC_POLL_WORKERS",
            default_quic_poll_worker_count,
            1,
            64,
        );
        // QUIC-acceptor-wedge fix: bound drainPendingDestroy()'s per-call batch so
        // the endpoint-mutex hold stays short under sustained connection churn and
        // the poll workers keep draining the listener UDP rx_queue (0 = unbounded,
        // the pre-fix behaviour; default 64). See quic.drain_pending_destroy_batch.
        quic_transport.setDrainPendingDestroyBatch(envUsize(gpa, "GEODE_QUIC_DESTROY_BATCH", 64, 0, 1_000_000));
        // QUIC-acceptor-wedge RC-A (quic v0.1.28): bound the kernel UDP rx_queue
        // under a reconnect storm by draining (cheaply shedding surplus Initials)
        // a large slice per poll cycle, decoupled from the expensive Initial
        // processing budget. 0 = lib compiled default (UdpBatchCap*64 = 4096).
        quic_transport.setServerSocketDrainPackets(envUsize(gpa, "GEODE_QUIC_DRAIN_PACKETS", 0, 0, 1_000_000));
        // QUIC-acceptor-wedge RC-A it.2 (quic v0.1.29): cap per-cycle new-conn
        // (Initial) PROCESSING to a small budget so the lock-free shed-drain
        // engages immediately and the kernel rx_queue stays bounded under a
        // reconnect storm (the v0.1.28 drain cap alone was still gated behind the
        // old 256-Initial ep.mu-serialized budget). 0 = lib default (one batch=64).
        quic_transport.setServerInitialProcessingBudget(envUsize(gpa, "GEODE_QUIC_INITIAL_BUDGET", 0, 0, 1_000_000));
        const poll_contexts = gpa.alloc(PollLoopContext, quic_poll_worker_count) catch |err| {
            log.err("Failed to allocate poll loop contexts", &.{Attr.string("error", @errorName(err))});
            return;
        };
        defer gpa.free(poll_contexts);
        const poll_pool = thread_pool.ThreadPool.init(gpa, .{
            .num_threads = quic_poll_worker_count,
            .queue_capacity = @max(quic_poll_worker_count * 2, 4),
            .blocking_workers = 0,
            // 2026-04-27: same shutdown-budget cap as stream_pool /
            // acceptor_pool — see the comment at stream_pool's init for
            // the full rationale (data-loss on harness `restart_server`
            // when shutdown waits the upstream 30s default).
            .deinit_timeout_ns = 2 * std.time.ns_per_s,
        }) catch |err| {
            log.err("Failed to initialize poll loop pool", &.{Attr.string("error", @errorName(err))});
            return;
        };
        for (poll_contexts) |*poll_ctx| {
            poll_ctx.* = .{
                .transport = &transport,
                .shutdown = &poll_shutdown,
            };
            if (!poll_pool.submitDefault(.{
                .context = @ptrCast(poll_ctx),
                .callback = runPollLoopTask,
            })) {
                log.err("Failed to submit poll loop task", &.{});
                poll_shutdown.store(true, .release);
                poll_pool.deinit();
                return;
            }
        }
        defer {
            poll_shutdown.store(true, .release);
            poll_pool.deinit();
        }

        // CANARY: REQ=REQ-PERF-STREAM-POOL-001; FEATURE="SharedStreamPool"; ASPECT=ThreadPoolInit; STATUS=TESTED; TEST=tests/e2e_quic_high_concurrency.zig; OWNER=server; UPDATED=2026-06-11
        // SP Tasks 2+3: Allocate shared stream + acceptor pools at server startup.
        // These live for the full server lifetime so connection-close is no longer
        // a pool-lifecycle event.  See docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md.
        const quic_stream_worker_count = envUsize(
            gpa,
            "GEODE_QUIC_STREAM_WORKERS",
            default_quic_stream_worker_count,
            2,
            64,
        );
        const quic_stream_queue_capacity = envUsize(
            gpa,
            "GEODE_QUIC_STREAM_QUEUE_CAPACITY",
            default_quic_stream_queue_capacity,
            64,
            65536,
        );
        const stream_pool = try thread_pool.ThreadPool.init(gpa, .{
            .num_threads = quic_stream_worker_count,
            .queue_capacity = quic_stream_queue_capacity,
            .blocking_workers = 0,
            // 2026-04-27: cap deinit at 2s instead of the upstream 30s
            // default.  These pools live for the full server lifetime
            // so on shutdown the queue should already be empty (active
            // connections drained their handlers via the per-connection
            // `acceptor_done` wait added the same day).  Anything still
            // running 2s after SIGTERM is genuinely stuck and the
            // harness's `restart_server` path can't afford to wait the
            // full 30s — it loses WAL state and surfaces as data-loss
            // failures (`regression_issue_539_wal_recovery_checkpoint`,
            // `fle_large_data_stress_verification`).  The pool emits a
            // diagnostic warning if it hits the deadline so an operator
            // still sees the problem.
            .deinit_timeout_ns = 2 * std.time.ns_per_s,
        });
        defer stream_pool.deinit();

        // 2026-04-28: bumped from 4 → 64 threads.  Each accepted QUIC
        // connection submits ONE long-lived `runStreamAcceptorLoop` task
        // (an infinite poll loop that exits only when its connection
        // tears down).  With only 4 acceptor threads any concurrent
        // client fan-out > 4 would queue acceptor loops behind already-
        // running ones — they would never start, and the queued
        // connections' client-initiated streams would never get
        // accepted server-side.  64 covers realistic client fan-out
        // without burning CPU since acceptors now park on poll-generation
        // wakeups when no peer stream is pending.
        //
        const quic_acceptor_worker_count = envUsize(
            gpa,
            "GEODE_QUIC_ACCEPTOR_WORKERS",
            default_quic_acceptor_worker_count,
            2,
            64,
        );
        const quic_acceptor_queue_capacity = envUsize(
            gpa,
            "GEODE_QUIC_ACCEPTOR_QUEUE_CAPACITY",
            default_quic_acceptor_queue_capacity,
            64,
            65536,
        );
        const acceptor_pool = try thread_pool.ThreadPool.init(gpa, .{
            .num_threads = quic_acceptor_worker_count,
            .queue_capacity = quic_acceptor_queue_capacity,
            .blocking_workers = 0,
            .deinit_timeout_ns = 2 * std.time.ns_per_s,
        });
        defer acceptor_pool.deinit();

        // CANARY: REQ=REQ-PERF-ASYNC-CONN-002; FEATURE="AsyncConnectionHandling"; ASPECT=ThreadPoolInit; STATUS=TESTED; TEST=tests/e2e_quic_high_concurrency.zig; OWNER=server; UPDATED=2026-06-11
        // CANARY: REQ=REQ-QUIC-HC-132; FEATURE="QUIC High-Concurrency Requests"; ASPECT=ConnectionPoolCapCompatibility; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-11
        // GAP-0202: Initialize thread pool for async connection handling
        // This allows accepting new connections while previous ones are being
        // processed. QUIC connection handlers are long-lived socket loops, not
        // short CPU tasks, so CPU-count auto sizing starves accepted
        // connections under high fan-out. Keep the stable default explicit and
        // allow controlled tuning via GEODE_QUIC_CONNECTION_WORKERS within the
        // upstream thread-pool's 64-worker bitmap limit. Higher fan-out is
        // handled by GEODE_QUIC_DETACHED_CONNECTION_ADMISSION below; allowing a
        // >64 pooled value makes thread_pool.init fail with TooManyWorkers and
        // falls back to synchronous HELLO admission, which collapses 512+
        // connection setup.
        phase_start = compat_milliTimestamp();
        const quic_connection_worker_count = envUsize(
            gpa,
            "GEODE_QUIC_CONNECTION_WORKERS",
            default_quic_connection_worker_count,
            2,
            64,
        );
        const pool = thread_pool.ThreadPool.init(gpa, .{
            .num_threads = quic_connection_worker_count,
            .queue_capacity = quic_connection_queue_capacity,
            .blocking_workers = 0,
            // GAP-0333: connection workers also run the recursive-descent GQL
            // parser, which needs ~6 stack frames per nested paren up to the
            // 128-deep hard limit. 2 MiB overflowed (segfault) well before 128;
            // 8 MiB held ~120 levels in debug but still segfaulted at 128
            // (debug frames are ~66 KiB/level vs ~20 KiB release). 16 MiB holds
            // the full 128-deep limit with margin in both build modes so an
            // over-deep query returns a clean parse error instead of crashing.
            // Virtual reservation only — pages fault in solely for genuinely
            // deep queries, so normal-load RSS is unchanged.
            .stack_size = 16 * 1024 * 1024,
        }) catch |err| {
            log.err("Failed to initialize connection thread pool, falling back to sync mode", &.{
                Attr.string("error", @errorName(err)),
            });
            // Fallback to synchronous mode
            while (!g_shutdown_requested.load(.acquire)) {
                const conn = transport.accept() catch |err2| {
                    log.warn("Failed to accept QUIC connection", &.{
                        Attr.string("error", @errorName(err2)),
                    });
                    continue;
                };
                quic_connection_handler.handleQuicConnection(gpa, &transport, conn, disable_estimates, compact_profile, memcurve_profile, env_spill_threshold, env_storage_checksum_error, false, init_ctx.security_manager, init_ctx.shared_ast_cache, init_ctx.shared_optimizer, &init_ctx.env_config, stream_pool, acceptor_pool) catch |err2| {
                    log.err("Error handling QUIC connection", &.{
                        Attr.string("error", @errorName(err2)),
                    });
                };
            }
            return;
        };
        defer pool.deinit();

        const detached_connection_admission = envBool(
            gpa,
            "GEODE_QUIC_DETACHED_CONNECTION_ADMISSION",
            builtin.mode != .Debug,
        );
        const connection_admission_cap = envUsize(
            gpa,
            "GEODE_QUIC_CONNECTION_ADMISSION_THREADS",
            default_quic_connection_admission_threads,
            2,
            4096,
        );
        g_connection_admission_gate.configure(@intCast(@min(
            connection_admission_cap,
            @as(usize, std.math.maxInt(u32)),
        )));

        // CANARY: REQ=REQ-QUIC-HC-020; FEATURE="ConfigurableStreamThrottle"; ASPECT=ServerEnv; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-26
        //
        // The detached first-stream owner path is bounded by the global stream
        // throttle. Keep the default conservative, but allow controlled
        // high-fanout runs to lift the cap without rebuilding. Also reserve
        // the proto-reader registry up front so high-fanout connection storms
        // do not allocate while holding the registry mutex.
        const max_global_stream_threads = envUsize(
            gpa,
            "GEODE_QUIC_MAX_GLOBAL_STREAM_THREADS",
            @as(usize, @intCast(quic_connection_handler.getMaxGlobalStreamThreads())),
            1,
            65536,
        );
        quic_connection_handler.setMaxGlobalStreamThreads(@intCast(@min(
            max_global_stream_threads,
            @as(usize, std.math.maxInt(u32)),
        )));
        // CANARY: REQ=REQ-QUIC-HC-044; FEATURE="QUIC High-Concurrency Requests"; ASPECT=BoundedDetachedFirstStreams; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-11
        //
        // Cap detached first-stream owners independently from stream admission.
        // Overflow first streams remain accepted and run on the shared stream
        // pool, which avoids a 512+ thread storm starving the QUIC poller.
        const max_detached_first_stream_threads = envUsize(
            gpa,
            "GEODE_QUIC_DETACHED_FIRST_STREAM_THREADS",
            default_quic_detached_first_stream_threads,
            1,
            65536,
        );
        quic_connection_handler.setMaxDetachedFirstStreamOwners(@intCast(@min(
            max_detached_first_stream_threads,
            @as(usize, std.math.maxInt(u32)),
        )));
        quic_connection_handler.reserveProtoReaderRegistryCapacity(
            gpa,
            max_global_stream_threads,
        ) catch |err| {
            log.warn("failed to preallocate proto-reader registry for high fanout", &.{
                Attr.string("error", @errorName(err)),
                Attr.int("capacity", @intCast(max_global_stream_threads)),
            });
        };

        // CANARY: REQ=REQ-QUIC-HC-054; FEATURE="QUIC High-Concurrency Requests"; ASPECT=CooperativeFirstStreams; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-11
        //
        // In single-stream high-fanout mode, persistent first-stream owners pin
        // one worker or OS thread per live client. A bounded cooperative
        // scheduler lets worker threads rotate across connections whenever a
        // stream would block, which is the path needed for 512+ and eventually
        // 10k+ concurrent requests.
        var first_stream_scheduler = quic_connection_handler.FirstStreamScheduler{};
        var first_stream_scheduler_enabled = false;
        if (init_ctx.env_config.quic_cooperative_first_streams_enabled) {
            const cooperative_worker_count = envUsize(
                gpa,
                "GEODE_QUIC_COOPERATIVE_FIRST_STREAM_WORKERS",
                default_quic_cooperative_first_stream_worker_count,
                1,
                512,
            );
            const cooperative_mutation_limit_cap = envUsize(
                gpa,
                "GEODE_QUIC_MUTATION_ADMISSION_CAP",
                quic_connection_handler.default_first_stream_scheduler_mutation_limit_cap,
                1,
                quic_connection_handler.max_first_stream_scheduler_mutation_limit_cap,
            );
            try first_stream_scheduler.init(gpa, cooperative_worker_count, cooperative_mutation_limit_cap);
            first_stream_scheduler_enabled = true;
            quic_connection_handler.setFirstStreamScheduler(&first_stream_scheduler);
        }
        defer {
            quic_connection_handler.setFirstStreamScheduler(null);
            if (first_stream_scheduler_enabled) {
                first_stream_scheduler.deinit();
            }
        }

        // CANARY: REQ=REQ-PERF-METRICS-001; FEATURE="RuntimeMetrics"; ASPECT=RegistryInit; STATUS=TESTED; TEST=src/server/runtime_metrics.zig; OWNER=server; UPDATED=2026-06-11
        // Task 4: Initialise the process-global runtime_metrics registry and spawn
        // the periodic-emit task onto the existing connection thread pool.
        // Access via geode module to avoid duplicate-module conflict (runtime_metrics.zig
        // is owned by the 'geode' module via lib.zig; main.zig is in 'root').
        const metrics_registry = try runtime_metrics_mod.Registry.init(gpa);
        runtime_metrics_mod.setGlobalRegistry(metrics_registry);
        metrics_server.setRuntimeSnapshotCallback(runtimeMetricsPrometheusSnapshot, metrics_registry);

        // Allocate the QUIC metrics context. Lives until server shutdown
        // so the gauge callbacks can dereference it from the emit loop.
        // Declared BEFORE the registry-deinit defer so on LIFO unwind it
        // runs AFTER metrics_registry.deinit() — by which point no gauge
        // callbacks can fire against this freed pointer.
        const quic_metrics_ctx = try gpa.create(quic_metrics.Ctx);
        defer gpa.destroy(quic_metrics_ctx);
        quic_metrics_ctx.* = .{ .transport = &transport };

        defer {
            metrics_server.setRuntimeSnapshotCallback(null, null);
            runtime_metrics_mod.setGlobalRegistry(null);
            metrics_registry.deinit();
        }

        try metrics_registry.registerGauge(
            "quic_active_connections",
            quic_metrics.activeConnections,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_total_bytes_in_flight",
            quic_metrics.totalBytesInFlight,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_total_cwnd_bytes",
            quic_metrics.totalCongestionWindow,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_min_smoothed_rtt_ns",
            quic_metrics.minSmoothedRttNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_max_smoothed_rtt_ns",
            quic_metrics.maxSmoothedRttNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_min_flow_control_headroom",
            quic_metrics.minFlowControlHeadroom,
            quic_metrics_ctx,
        );
        // #864 / qa-seed deadlock §6.3: surface the global stream-throttle
        // saturation as gauges so operators can detect pollLoop saturation
        // before it cascades into client-side deadlocks. `pending` reports
        // current in-flight stream handlers; `max` reports the configured
        // cap so dashboards can compute a saturation ratio without
        // hard-coding the limit.
        try metrics_registry.registerGauge(
            "quic_pending_stream_handlers",
            quic_metrics.pendingStreamHandlers,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_max_stream_handlers",
            quic_metrics.maxStreamHandlers,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_stream_admission_rejections_total",
            quic_metrics.streamAdmissionRejectionsTotal,
            quic_metrics_ctx,
        );
        // #864 / qa-seed deadlock §6.6: surface pollLoop cycle latency so
        // operators can detect saturation upstream of the proto-reader
        // would-block counter.  Sustained `quic_poll_cycle_max_ns >= 2ms`
        // or rising `quic_poll_overrun_total` rate is the leading
        // indicator before client-side deadlocks materialize.
        try metrics_registry.registerGauge(
            "quic_poll_cycle_max_ns",
            quic_metrics.pollCycleMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_transport_max_ns",
            quic_metrics.pollTransportMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_recv_process_max_ns",
            quic_metrics.pollRecvProcessMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_recv_short_header_max_ns",
            quic_metrics.pollRecvShortHeaderMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_recv_short_endpoint_map_max_ns",
            quic_metrics.pollRecvShortEndpointMapMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_recv_short_rx_serial_wait_max_ns",
            quic_metrics.pollRecvShortRxSerialWaitMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_recv_short_conn_lock_wait_max_ns",
            quic_metrics.pollRecvShortConnLockWaitMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_recv_short_decrypt_max_ns",
            quic_metrics.pollRecvShortDecryptMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_recv_short_frame_process_max_ns",
            quic_metrics.pollRecvShortFrameProcessMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_recv_short_ack_send_max_ns",
            quic_metrics.pollRecvShortAckSendMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_recv_initial_max_ns",
            quic_metrics.pollRecvInitialMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_recv_handshake_max_ns",
            quic_metrics.pollRecvHandshakeMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_recv_fallback_max_ns",
            quic_metrics.pollRecvFallbackMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_pending_hs_send_max_ns",
            quic_metrics.pollPendingHsSendMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_timer_process_max_ns",
            quic_metrics.pollTimerProcessMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_pto_dirty_max_ns",
            quic_metrics.pollPtoDirtyMaxNs,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_poll_overrun_total",
            quic_metrics.pollOverrunTotal,
            quic_metrics_ctx,
        );
        // #864 / qa-seed deadlock §6.5: surface the reaper state.
        try metrics_registry.registerGauge(
            "quic_leaked_connections_pending",
            quic_metrics.leakedConnectionsPending,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_leaked_connections_reaped_total",
            quic_metrics.leakedConnectionsReapedTotal,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_leaked_connections_registered_total",
            quic_metrics.leakedConnectionsRegisteredTotal,
            quic_metrics_ctx,
        );
        // #864 frozen-counter observability: time since the last
        // proto_reader counter increment.  Dashboards should alert when
        // this exceeds ~60 s while `quic_pending_stream_handlers > 0`
        // — handlers are wedged downstream of nextMessage (query exec,
        // storage locks, response send).
        try metrics_registry.registerGauge(
            "proto_reader_idle_ns",
            quic_metrics.protoReaderIdleNs,
            quic_metrics_ctx,
        );
        // #864 §10 per-stream stall: surface idle time of the
        // slowest-progressing reader so dashboards alert on per-stream
        // wedges that the process-wide proto_reader_idle_ns misses
        // (other streams keep ticking and cover for the stuck one).
        try metrics_registry.registerGauge(
            "quic_max_stream_idle_ns",
            quic_metrics.maxStreamIdleNs,
            quic_metrics_ctx,
        );
        try proto_reader_metrics.registerAll(metrics_registry);
        try quic_response_metrics.registerAll(metrics_registry);

        // Phase C1: bridge the now-fully-populated runtime metrics registry into
        // OTLP as geode.runtime.* observable gauges. MUST run after every
        // runtime-metric registration above so all entries are exported. Cheap
        // no-op when the OTLP meter provider is inactive (early return inside).
        otel_metrics_facade.registerRuntimeMetricsOtel(metrics_registry) catch |err| {
            log.warn("otel_metrics: runtime bridge registration failed", &.{Attr.string("error", @errorName(err))});
        };

        var metrics_should_stop = std.atomic.Value(u32).init(0);
        const MetricsCtx = struct {
            registry: *runtime_metrics_mod.Registry,
            should_stop: *std.atomic.Value(u32),
            allocator: std.mem.Allocator,
            // QUIC listener port for the accept-path wedge watchdog (0 = unknown
            // → watchdog inert). Parsed from `--listen host:port`.
            quic_port: u16,
        };
        // Resolve the QUIC listener port for the wedge watchdog.
        const watchdog_quic_port: u16 = blk: {
            const la = listen_quic orelse break :blk 0;
            const pcolon = std.mem.lastIndexOfScalar(u8, la, ':') orelse break :blk 0;
            break :blk std.fmt.parseInt(u16, la[pcolon + 1 ..], 10) catch 0;
        };
        const metrics_ctx = try gpa.create(MetricsCtx);
        defer gpa.destroy(metrics_ctx);
        metrics_ctx.* = .{
            .registry = metrics_registry,
            .should_stop = &metrics_should_stop,
            .allocator = gpa,
            .quic_port = watchdog_quic_port,
        };

        // PERF-D / #816: park on `should_stop` via futexWaitTimeout instead
        // of an unconditional nanosleep. The 5-second tick is preserved (it
        // remains the heartbeat cadence for the metrics snapshot), but on
        // shutdown the producer (`metrics_should_stop.store(1, .release)`
        // below) calls futexWake so this loop exits immediately rather than
        // burning up to 5s of joinable time. Per the canonical futex idiom
        // we re-check `should_stop` after futexWaitTimeout returns —
        // futexWait returns void on timeout, signal, OR spurious wake, and
        // the caller is responsible for differentiating via the predicate.
        const metricsLoop = struct {
            // #864 frozen-counter observability: threshold beyond which
            // a proto-reader stall is logged at error level so operators
            // get a non-silent signal.  60 s is well past the longest
            // expected handler hop (large query + storage commit) and
            // sub-300 s (QUIC idle reap) so the alert fires before
            // clients see CONNECTION_CLOSE.
            const stall_threshold_ns: u64 = 60 * std.time.ns_per_s;
            // Suppress repeat-fire of the same stall: only log when the
            // stall starts (idle crosses the threshold) and every 30 s
            // thereafter while it persists.
            const stall_relog_interval_ns: u64 = 30 * std.time.ns_per_s;

            fn run(ctx_ptr: *anyopaque) void {
                const ctx: *MetricsCtx = @ptrCast(@alignCast(ctx_ptr));
                const io = std.Io.Threaded.global_single_threaded.io();
                const tick_timeout: std.Io.Timeout = .{ .duration = .{
                    .raw = std.Io.Duration.fromSeconds(5),
                    .clock = .awake,
                } };
                var last_stall_log_idle_ns: u64 = 0;
                var last_metrics_delivered: u64 = 0;
                const metrics_full_dump = std.c.getenv("GEODE_METRICS_LOG_FULL") != null;
                // Accept-path wedge watchdog config (parsed once). See
                // docs/bugs/2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md §6.
                const wd_cfg = acceptor_watchdog.parseConfig(
                    posixGetenv("GEODE_ACCEPTOR_WATCHDOG_RX_BYTES"),
                    posixGetenv("GEODE_ACCEPTOR_WATCHDOG_DEADLINE_MS"),
                    posixGetenv("GEODE_ACCEPTOR_WATCHDOG_DISABLE"),
                );
                var wd_tracker = acceptor_watchdog.WedgeTracker{};
                while (ctx.should_stop.load(.acquire) == 0) {
                    // Park until the 5s tick elapses or shutdown is signalled.
                    // `should_stop` is the futex word: the producer stores 1
                    // and calls futexWake. If the value already differs from
                    // 0 (race), futexWait returns immediately.
                    io.futexWaitTimeout(u32, &ctx.should_stop.raw, 0, tick_timeout) catch |err| switch (err) {
                        // The worker pool does not cancel us; this would be
                        // a bug. Treat as shutdown.
                        error.Canceled => return,
                    };
                    if (ctx.should_stop.load(.acquire) != 0) break;
                    // GAP-0896: emit a compact one-line summary at info every
                    // tick; gate the full ~100-field registry dump behind
                    // GEODE_METRICS_LOG_FULL (also available via the metrics
                    // endpoint). The full dump was 49 lines / ~5 min of spam
                    // under sustained load.
                    const proto_delivered = proto_reader_metrics.messages_delivered_total.load(.monotonic);
                    const delivered_delta = proto_delivered -| last_metrics_delivered;
                    last_metrics_delivered = proto_delivered;
                    var sum_buf: std.ArrayList(u8) = .empty;
                    defer sum_buf.deinit(ctx.allocator);
                    proto_reader_metrics.appendCompactSummary(ctx.allocator, &sum_buf, .{
                        .delivered_delta = delivered_delta,
                        .delivered_total = proto_delivered,
                        .active_streams = quic_connection_handler.getProtoReaderRegistry().count(),
                        .proto_idle_ms = proto_reader_metrics.getIdleNs() / std.time.ns_per_ms,
                    }) catch {};
                    std.log.info("metrics: {s}", .{sum_buf.items});
                    if (metrics_full_dump) {
                        var buf: std.ArrayList(u8) = .empty;
                        defer buf.deinit(ctx.allocator);
                        ctx.registry.snapshotInto(ctx.allocator, &buf) catch continue;
                        std.log.info("metrics-full: {s}", .{buf.items});
                    }

                    // #864 stall watchdog: detect "all proto_reader
                    // counters frozen despite active stream handlers"
                    // (handlers wedged downstream of nextMessage) and
                    // log a critical line so operators get a
                    // deterministic alert.  Read-only — never aborts
                    // streams (a stuck handler may be mid-transaction
                    // and force-killing it risks corruption).  Recovery
                    // remains operator-driven (pod restart); this just
                    // shortens detection from "user notices UI is dead"
                    // to seconds.
                    const idle_ns = proto_reader_metrics.getIdleNs();
                    const pending = quic_connection_handler.getGlobalStreamThreadCount();
                    if (idle_ns >= stall_threshold_ns and pending > 0) {
                        const since_last_log = if (idle_ns > last_stall_log_idle_ns)
                            idle_ns - last_stall_log_idle_ns
                        else
                            0;
                        const fresh_stall = last_stall_log_idle_ns < stall_threshold_ns;
                        if (fresh_stall or since_last_log >= stall_relog_interval_ns) {
                            // GAP-ENT-0045: ABORT the wedged executors, don't
                            // just log. Every registered reader's counters are
                            // frozen with handlers pending — each in-flight
                            // executor gets its cancel flag set; the read
                            // budget/cancel polls abort it at the next
                            // row/batch boundary with SQLSTATE 57014 and the
                            // handler thread returns to its read loop. The
                            // 2026-07-05 OOM proof: two abandoned GROUP BYs
                            // ran ~50 min unbounded because this watchdog only
                            // logged. Cancellation is read-only w.r.t. data
                            // (aborts BETWEEN rows); a wedged WRITE handler is
                            // untouched (write paths don't install the read
                            // scope), preserving the old mid-transaction
                            // safety stance for mutations.
                            const cancel_requested_n = quic_connection_handler.getProtoReaderRegistry().cancelAll();
                            std.log.err(
                                "proto_reader stall detected: idle_ms={d} pending_handlers={d} (handlers wedged downstream of BufferedProtoReader.nextMessage; requested executor cancellation for {d} in-flight readers — SQLSTATE 57014 at the next row boundary; restart pod if the stall persists)",
                                .{ idle_ns / std.time.ns_per_ms, pending, cancel_requested_n },
                            );
                            last_stall_log_idle_ns = idle_ns;
                        }
                    } else {
                        last_stall_log_idle_ns = 0;
                    }

                    // #864 §10 per-stream stall watchdog (GAP-0895): only
                    // surface a stall when EVERY stream on a connection is
                    // idle past the threshold (the whole connection is
                    // wedged). A single intentionally-idle multiplexed
                    // control stream on an otherwise-live connection is not
                    // a stall and must not trip alerting. Demoted to warn —
                    // the process-wide watchdog above owns the error-level
                    // "restart pod" signal for the all-frozen case.
                    const reg = quic_connection_handler.getProtoReaderRegistry();
                    var ts: std.os.linux.timespec = undefined;
                    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
                    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
                    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
                    const now_ns: u64 = sec * std.time.ns_per_s + nsec;
                    if (reg.connectionLevelStall(now_ns, stall_threshold_ns)) |snap| {
                        // GAP-ENT-0045: the whole connection is wedged (every
                        // stream idle past threshold — client likely gone).
                        // Abort ITS in-flight read executors only; healthy
                        // connections are untouched.
                        const conn_cancelled_n = reg.cancelConnection(snap.peer_addr);
                        std.log.warn(
                            "per-connection proto_reader stall: stream_id={d} peer={s} idle_ms={d} (every stream on this connection idle past threshold; client likely gone — requested executor cancellation for {d} readers; connection will be reaped on its own timeout)",
                            .{ snap.stream_id, snap.peer_addr, snap.idle_ns / std.time.ns_per_ms, conn_cancelled_n },
                        );
                    }

                    // Accept-path wedge watchdog: when the listener UDP rx_queue
                    // backs up past the threshold continuously for longer than
                    // the deadline, the QUIC acceptor is wedged (Endpoint.mu
                    // contention) and not draining new connections — the pod
                    // stays Running but is effectively down with no automatic
                    // recovery. Self-restart so the orchestrator recovers it.
                    // See docs/bugs/2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md.
                    // CANARY: REQ=REQ-QUIC-ACCEPTOR-WEDGE-WATCHDOG; FEATURE="QUIC High-Concurrency Connection Admission"; ASPECT=AcceptPathWedgeAutoRecovery; STATUS=TESTED; TEST=src/server/acceptor_watchdog.zig; OWNER=transport; UPDATED=2026-06-05
                    if (wd_cfg.enabled and ctx.quic_port != 0) {
                        if (acceptor_watchdog.readListenerRxQueue(ctx.quic_port)) |rx| {
                            const now_ms2: i64 = @intCast(now_ns / std.time.ns_per_ms);
                            if (wd_tracker.update(rx, now_ms2, wd_cfg) == .restart) {
                                std.log.err(
                                    "ACCEPTOR WEDGE: :{d} UDP rx_queue={d} bytes stayed >= {d} for >= {d}ms — the QUIC acceptor is wedged and not draining new connections. Self-restarting so the orchestrator recovers automatically (set GEODE_ACCEPTOR_WATCHDOG_DISABLE=1 to opt out).",
                                    .{ ctx.quic_port, rx, wd_cfg.rx_threshold_bytes, wd_cfg.deadline_ms },
                                );
                                std.debug.print(
                                    "ACCEPTOR WEDGE: :{d} UDP rx_queue={d} bytes wedged >= {d}ms; self-restarting for automatic recovery.\n",
                                    .{ ctx.quic_port, rx, wd_cfg.deadline_ms },
                                );
                                // Let the log flush, then exit non-zero so the
                                // k8s restartPolicy restarts the pod. (This path
                                // is linux-only — readListenerRxQueue returns
                                // null elsewhere.)
                                var flush_req = std.os.linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
                                var flush_rem: std.os.linux.timespec = undefined;
                                _ = std.os.linux.nanosleep(&flush_req, &flush_rem);
                                std.process.exit(70); // EX_SOFTWARE
                            }
                        }
                    }
                }
            }
        }.run;

        // CANARY: REQ=REQ-QUIC-HC-010; FEATURE="High-Concurrency Connection Admission"; ASPECT=MetricsPoolIsolation; STATUS=TESTED; TEST=tests/e2e_quic_high_concurrency.zig; OWNER=transport; UPDATED=2026-06-11
        // Keep the long-running metrics/stall watchdog off the connection
        // handler pool. Otherwise it permanently consumes a worker before the
        // first client connects and lowers the hard HELLO-admission ceiling.
        const metrics_pool = thread_pool.ThreadPool.init(gpa, .{
            .num_threads = 1,
            .queue_capacity = 4,
            .deinit_timeout_ns = 2 * std.time.ns_per_s,
        }) catch |err| {
            log.err("Failed to initialize metrics loop pool", &.{Attr.string("error", @errorName(err))});
            return;
        };
        try metrics_pool.submitBlocking(.{ .context = @ptrCast(metrics_ctx), .callback = metricsLoop });
        defer {
            // PERF-D / #816: set the stop flag AND wake the parked metrics
            // loop. Without the futexWake, shutdown would still take up to
            // 5s for the current futexWaitTimeout to expire.
            metrics_should_stop.store(1, .release);
            const io = std.Io.Threaded.global_single_threaded.io();
            io.futexWake(u32, &metrics_should_stop.raw, 1);
            metrics_pool.deinit();
        }

        std.debug.print("[startup] thread pool initialized ({d}ms, {d} workers)\n", .{ compat_milliTimestamp() - phase_start, pool.workers.len });

        // GAP-0269: Log total startup time for operator diagnostics (stderr, visible at all log levels)
        std.debug.print("[startup] server ready ({d}ms total)\n", .{compat_milliTimestamp() - startup_begin});

        // #864 / qa-seed deadlock §6.5: spawn the leaked-connection
        // reaper.  Bail entries arrive from `handleQuicConnection`'s
        // owner-side defer when the acceptor exit-wait deadline fires.
        // The reaper polls `ctx.done` once a second and reclaims conns
        // whose acceptors have exited — restoring eventual cleanup from
        // the QUIC 300s idle timeout to ~1s.
        var leaked_registry = leaked_conn_reaper.LeakedConnRegistry.init();
        defer leaked_registry.deinit(gpa);
        quic_connection_handler.setLeakedConnRegistry(&leaked_registry);
        defer quic_connection_handler.setLeakedConnRegistry(null);

        var reaper_args = leaked_conn_reaper.ReaperArgs{
            .registry = &leaked_registry,
            .gpa = gpa,
        };
        const reaper_pool = thread_pool.ThreadPool.init(gpa, .{
            .num_threads = 1,
            .queue_capacity = 4,
            .deinit_timeout_ns = 2 * std.time.ns_per_s,
        }) catch |err| {
            log.err("Failed to initialize leaked-conn reaper pool", &.{Attr.string("error", @errorName(err))});
            return;
        };
        try reaper_pool.submitBlocking(.{
            .context = @ptrCast(&reaper_args),
            .callback = runLeakedConnReaper,
        });
        defer {
            leaked_registry.shutdown.store(true, .release);
            reaper_pool.deinit();
        }

        // Install SIGTERM/SIGINT handlers so the accept loop exits cleanly
        // and deferred cleanup (persistence flush, thread join) runs.
        const sa = posix.Sigaction{
            .handler = .{ .handler = handleShutdownSignal },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.TERM, &sa, null);
        posix.sigaction(posix.SIG.INT, &sa, null);

        // CANARY: REQ=REQ-GAP-0928-POOL-EXHAUSTED-DIAGNOSTIC; FEATURE="ConnectionPool"; ASPECT=AdmissionDiagnostic; STATUS=TESTED; TEST=tests/test_gap0928_pool_exhausted.zig; OWNER=transport; UPDATED=2026-07-10
        // GAP-0928: at `--max-connections` capacity the accept loop parks and
        // the N+1-th connection got NO server-side signal — the operator only
        // saw the client's own --timeout fire (pool exhaustion was invisible
        // server-side). Emit a rate-limited POOL_EXHAUSTED diagnostic so the
        // condition is observable. `shouldLogPoolExhausted` gates it to at most
        // once per window while continuously at capacity.
        var last_pool_exhausted_log_ms: i64 = 0;

        // Production mode: accept connections in a loop and dispatch to thread pool.
        // The dedicated poll thread handles packet delivery — this loop only checks
        // for completed handshakes via tryAccept().
        while (!g_shutdown_requested.load(.acquire)) {
            // GAP-0203: Process deferred connection cleanups on the main thread.
            transport.drainPendingDestroy();

            // #49: Admission control — skip accept when at capacity.
            //
            // PERF-D / #816 follow-up: parks on `transport.connection_slot_freed_gen`,
            // a generation counter that `destroyConnection` and `drainPendingDestroy`
            // increment after dropping a slot (and then call `futexWake(..., 1)`).
            // The 5 ms `futexWaitTimeout` upper bound is preserved as a safety net
            // against a lost wake (race between our gen-read and the producer's
            // increment) — under load, the typical wake latency is sub-ms instead
            // of the prior unconditional 5 ms. Per the canonical futex idiom we
            // re-check the predicate (`getConnectionCount() < max`) on every loop
            // iteration; futexWaitTimeout returns void on signal, value-mismatch,
            // timeout, OR spurious wake, so the caller MUST re-check.
            if (transport.getConnectionCount() >= transport.config.max_connections) {
                // GAP-0928: rate-limited pool-exhausted diagnostic.
                const now_ms = compat_milliTimestamp();
                if (shouldLogPoolExhausted(last_pool_exhausted_log_ms, now_ms)) {
                    last_pool_exhausted_log_ms = now_ms;
                    log.warn("POOL_EXHAUSTED: connection pool at capacity — new connections are parked until a slot frees", &.{
                        Attr.int("connections", @intCast(transport.getConnectionCount())),
                        Attr.int("max_connections", @intCast(transport.config.max_connections)),
                    });
                }
                const gen_at_park = transport.connection_slot_freed_gen.load(.acquire);
                // Re-check after the gen snapshot to close the gap where the
                // producer increments between our count check above and the
                // snapshot below. If the count dropped in that gap, fall
                // through to accept without parking.
                if (transport.getConnectionCount() >= transport.config.max_connections) {
                    const io = std.Io.Threaded.global_single_threaded.io();
                    const wait_timeout: std.Io.Timeout = .{ .duration = .{
                        .raw = std.Io.Duration.fromNanoseconds(5 * std.time.ns_per_ms),
                        .clock = .awake,
                    } };
                    io.futexWaitTimeout(u32, &transport.connection_slot_freed_gen.raw, gen_at_park, wait_timeout) catch |err| switch (err) {
                        // No cancelation source is wired in the accept loop —
                        // treat as a spurious wake and re-check on the next
                        // iteration.
                        error.Canceled => {},
                    };
                }
                continue;
            }

            const conn = transport.accept() catch |err| {
                // WouldBlock is expected when no connections are pending.
                // accept() uses CV-based waitForAccepted(50ms) internally,
                // so no additional sleep is needed here.
                if (err != quic_transport.QuicError.WouldBlock) {
                    log.warn("Failed to accept QUIC connection", &.{
                        Attr.string("error", @errorName(err)),
                    });
                }
                continue;
            };

            // CANARY: REQ=REQ-ABAC-WIRE-016; FEATURE="ABAC Enforcement"; ASPECT=QUICLoop; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
            // GAP-0202: Create context for async connection handling
            // #50: Reject connection on alloc failure instead of blocking main thread
            const ctx = gpa.create(ConnectionContext) catch {
                log.err("Failed to allocate connection context, rejecting connection", &.{});
                transport.destroyConnection(conn);
                continue;
            };

            ctx.* = .{
                .allocator = gpa,
                .transport = &transport,
                .conn = conn,
                .disable_estimates = disable_estimates,
                .compact_profile = compact_profile,
                .memcurve_profile = memcurve_profile,
                .env_spill_threshold = env_spill_threshold,
                .env_storage_checksum_error = env_storage_checksum_error,
                .security_manager = init_ctx.security_manager,
                .shared_ast_cache = init_ctx.shared_ast_cache,
                .shared_optimizer = init_ctx.shared_optimizer,
                .env_config = &init_ctx.env_config,
                .stream_pool = stream_pool,
                .acceptor_pool = acceptor_pool,
            };

            if (detached_connection_admission) {
                if (!g_connection_admission_gate.tryAcquire()) {
                    log.warn("Connection admission thread cap reached, rejecting connection", &.{
                        Attr.int("active_admission", @intCast(g_connection_admission_gate.active.load(.acquire))),
                        Attr.int("max_admission", @intCast(g_connection_admission_gate.max.load(.acquire))),
                    });
                    transport.destroyConnection(conn);
                    gpa.destroy(ctx);
                    continue;
                }
                ctx.admission_gate = &g_connection_admission_gate;

                const admission_thread = std.Thread.spawn(
                    .{ .stack_size = quic_connection_admission_stack_size },
                    handleConnectionAsync,
                    .{@as(*anyopaque, @ptrCast(ctx))},
                ) catch |err| {
                    log.warn("Failed to spawn connection admission thread, rejecting connection", &.{
                        Attr.string("error", @errorName(err)),
                    });
                    ctx.admission_gate = null;
                    g_connection_admission_gate.release();
                    transport.destroyConnection(conn);
                    gpa.destroy(ctx);
                    continue;
                };
                admission_thread.detach();
            } else {
                // Submit to thread pool for async handling
                const work_item = thread_pool.WorkItem{
                    .context = @ptrCast(ctx),
                    .callback = handleConnectionAsync,
                };

                // GitLab #751: route connection admission through the *default*
                // lane (15+ workers) rather than the 1-wide blocking lane. The
                // blocking lane is reserved for genuinely blocking work (cert
                // generation, audit writes); connection-handler dispatch is
                // short and CPU-bound and must be parallel across connections.
                if (!pool.submitDefault(work_item)) {
                    // #50: Reject instead of blocking main thread with sync handling.
                    // Inline handleConnectionAsync() would block the accept loop for
                    // the entire duration of the connection (seconds to minutes).
                    log.warn("Thread pool queue full, rejecting connection", &.{
                        Attr.int("queue_size", @intCast(pool.pendingTasks())),
                        Attr.int("active_workers", @intCast(pool.activeWorkers())),
                    });
                    transport.destroyConnection(conn);
                    gpa.destroy(ctx);
                } else {
                    log.debug("Connection submitted to thread pool", &.{});
                }
            }
        }
        // Gap 0039: flips the transport's `shutting_down` flag FIRST, so
        // accept()/tryAccept() refuse new connections from this instant, then
        // signals every tracked connection (per-connection shutdown flag +
        // best-effort CONNECTION_CLOSE).
        transport.requestShutdown();
        if (detached_connection_admission and !g_connection_admission_gate.waitForZero(10 * std.time.ns_per_s)) {
            log.warn("Connection admission threads still active during shutdown", &.{
                Attr.int("active_admission", @intCast(g_connection_admission_gate.active.load(.acquire))),
            });
        }
        std.debug.print("[shutdown] signal received, flushing data and stopping...\n", .{});

        // ── Gap 0039: bounded graceful connection drain ─────────────────
        // Abandoned peers (client vanished without CONNECTION_CLOSE) used to
        // wedge this shutdown forever: handlers waiting on them never
        // unwound, the ext thread-pool deinit's post-timeout joinAllWorkers
        // never returned, and the process spun until SIGKILL. Give handlers
        // a bounded window to unwind gracefully, then force-close whatever
        // is left and move on. The window also covers connections admitted
        // a heartbeat before the signal.
        const drain_timeout_ms = envUsize(gpa, "GEODE_SHUTDOWN_DRAIN_TIMEOUT_MS", 30_000, 0, 86_400_000);
        {
            const drain_t0 = compat_milliTimestamp();
            std.debug.print(
                "[shutdown] draining {d} connections (timeout {d}ms, GEODE_SHUTDOWN_DRAIN_TIMEOUT_MS)\n",
                .{ transport.getConnectionCount(), drain_timeout_ms },
            );
            while (transport.getConnectionCount() > 0 and
                compat_milliTimestamp() - drain_t0 < @as(i64, @intCast(drain_timeout_ms)))
            {
                // This is the accept-loop thread — the required caller of
                // drainPendingDestroy. Handlers queue their closed inner
                // connections here; keep servicing the queue so graceful
                // closes complete during the drain window.
                transport.drainPendingDestroy();
                compat_sleepMs(25);
            }
            transport.drainPendingDestroy();
            const stalled = transport.getConnectionCount();
            if (stalled > 0) {
                std.debug.print(
                    "[shutdown] force-closing {d} stalled connections after drain timeout ({d}ms)\n",
                    .{ stalled, drain_timeout_ms },
                );
                log.warn("force-closing stalled connections after drain timeout", &.{
                    Attr.int("stalled_connections", @intCast(stalled)),
                    Attr.int("drain_timeout_ms", @intCast(drain_timeout_ms)),
                });
                _ = transport.forceCloseConnections();
                transport.drainPendingDestroy();
            } else {
                std.debug.print(
                    "[shutdown] connection drain complete ({d}ms)\n",
                    .{compat_milliTimestamp() - drain_t0},
                );
            }
        }

        // ── Data safety: final flush + WAL checkpoint, UNBOUNDED ────────
        // Runs on this thread BEFORE any pool-deinit defer can wedge on a
        // stuck handler, and before the teardown watchdog is armed. However
        // long the checkpoint takes, the watchdog cannot cut it short.
        graph_store.stopPersistenceThread(gpa);
        // GAP-0065 FIX D: `stopPersistenceThread` only runs the LIGHT engine
        // checkpoint (flush + engine-WAL truncate); it does NOT write the FIX-B
        // idmap/loop2 reload snapshots. Those were written by the FULL
        // `saveToFileEx(false)` inside the `deinitGlobalStore` defer below — which
        // runs AFTER the teardown watchdog is armed, so at 14.27M the ~minutes
        // FULL checkpoint got force-exited mid-write, leaving no reloadable
        // snapshots (and/or a committed WAL tail) → the next reopen re-scanned the
        // whole graph EVERY restart (~14–24 min). Do the FULL clean-shutdown
        // checkpoint (WAL truncate-to-frontier, no committed tail) + snapshot
        // write HERE, before the tight teardown watchdog is armed. Connections are
        // already drained/force-closed above, so no writer can race it; the deinit
        // defer then only frees memory under the teardown watchdog. On the next
        // reopen the (checkpoint_epoch, covered_lsn) gate RELOADS the snapshots
        // (sub-second) instead of rejecting a tail and re-scanning.
        //
        // GAP-0065 FIX D liveness: the FULL checkpoint's `tryLock(mg.rwlock)` retry
        // has NO deadline and spins forever if a genuinely-wedged handler holds the
        // lock. Since this flush now runs before the teardown watchdog, arm a
        // GENEROUS first-stage watchdog around it so a wedge still force-exits
        // (→ rebuild-on-restart, no data loss) instead of hanging the process
        // forever. The budget must comfortably exceed a legitimate full 14.27M
        // checkpoint+snapshot write, so a normal clean shutdown is never killed.
        const flush_budget_ms = envUsize(gpa, "GEODE_CLEAN_SHUTDOWN_FLUSH_TIMEOUT_MS", 1_800_000, 5_000, 86_400_000);
        g_shutdown_flush_done.store(false, .release);
        armShutdownFlushWatchdog(flush_budget_ms);
        // TEST/chaos hook (off by default; production never sets it): stall the
        // durability-flush region to deterministically exercise the first-stage
        // watchdog's force-exit path (simulates a wedged mg.rwlock holder).
        const flush_stall_ms = envUsize(gpa, "GEODE_TEST_SHUTDOWN_FLUSH_STALL_MS", 0, 0, 86_400_000);
        if (flush_stall_ms > 0) {
            std.debug.print("[shutdown] TEST: stalling durability flush {d}ms (GEODE_TEST_SHUTDOWN_FLUSH_STALL_MS) to exercise the liveness watchdog\n", .{flush_stall_ms});
            compat_sleepMs(flush_stall_ms);
        }
        graph_store.flushForCleanShutdown();
        g_shutdown_flush_done.store(true, .release); // disarm the first-stage watchdog
        persistence_flushed_eagerly = true;
        std.debug.print("[shutdown] data flush complete\n", .{});

        // ── Gap 0039: bounded teardown ──────────────────────────────────
        // Everything durable is on disk. If the remaining LIFO teardown
        // (pool joins, store free, transport deinit) wedges on a stalled
        // handler, the watchdog force-exits rc=0 instead of hanging forever.
        // 5 s floor: a HEALTHY idle teardown already spends ~2 s in pool
        // deinit drain budgets, so the floor must clear that comfortably —
        // the watchdog exists for the wedged-forever case, not to shave
        // seconds off a legitimate teardown.
        armShutdownTeardownWatchdog(@max(drain_timeout_ms, 5000));
        return;
    }

    log.err("No QUIC listener configured. Use --listen.", &.{});
    return error.MissingListenAddress;
}
