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

// CANARY: REQ=REQ-GAP-0928-POOL-EXHAUSTED-DIAGNOSTIC; FEATURE="ConnectionPool"; ASPECT=RateLimitPredicate; STATUS=TESTED; TEST=test-gap0927; OWNER=transport; UPDATED=2026-11-12
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
const diagnostics = @import("geode").diagnostics;
const eval = geode.eval;
const eval_extended = geode.eval_ext;
const SelectivityEstimator = @import("index_selectivity").SelectivityEstimator;
const quic_transport = @import("transport/quic");
const grpc_transport = @import("../transport/grpc_server.zig");
const thread_pool = @import("transport/thread_pool");
const cert_gen = @import("../tools/cert_gen.zig");
const query_ast_cache = @import("query_ast_cache");
// Note: cert_gen now imported for certificate generation (M3.2 Phase 3 CLI extraction)
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
// ENG-3921: cross-process exclusion on the data directory (flock leaf module).
const data_dir_lock_mod = @import("data_dir_lock");
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
const default_quic_connection_worker_count = 64;
const default_quic_detached_first_stream_threads = if (builtin.mode == .Debug) 64 else 256;
const default_quic_cooperative_first_stream_worker_count = if (builtin.mode == .Debug) 16 else 512;

// CANARY: REQ=REQ-SONNY-6466-CONN-STALL-CANCEL; FEATURE="QUIC Abandoned Read Cancellation"; ASPECT=ConfigurableConnectionStallThreshold; STATUS=TESTED; TEST=tests/test_sonny6466_abandoned_read_cancel.zig; OWNER=transport; UPDATED=2026-11-13
//
// SONNY-6466: the per-connection stall watchdog's threshold
// (GEODE_QUIC_STALL_CANCEL_MS). A client that vanishes without a
// CONNECTION_CLOSE (a crash, a pulled cable) sends nothing more, and vendored
// quic (still on v0.1.51: `connection/idle.zig` is not wired and the
// dead-connection reaper is opt-in) neither sends PINGs nor enforces the
// idle timeout it advertises, so the server cannot tell it from a quiet live client. What it
// can see is a connection on which no stream has read a message for this
// long: the watchdog then cancels that connection's in-flight reads (57014).
// The same bound therefore caps a single read that runs this long on a
// connection with no other stream reading — set it above the longest read
// you run. Checked every 5 s, so a cancel lands up to 5 s after it.
const default_conn_stall_cancel_ms: usize = 60_000;
const min_conn_stall_cancel_ms: usize = 1_000;
const max_conn_stall_cancel_ms: usize = 3_600_000;
// ENG-3914 (RC-4): the Debug default used to be 1 ("deterministic local
// traces"). ONE endpoint poll worker serialises datagram delivery for EVERY
// connection, and the stall is not linear — measured on this repo's Debug
// binary with four concurrent `geode query --batch` sessions replaying 200
// MERGE statements each: 1 worker drained 149/200 statements in 120 s
// (~800 ms/statement) while 2 workers drained 200/200 in 3.4 s and 4 in 3.2 s
// (~16 ms/statement) — a >30x cliff that exists ONLY at 1. Every local
// `zig build test-*` step, every geodetestlab spec and every developer shell
// runs a Debug binary, so that cliff was the real cause of "concurrent writers
// time out" spec failures (merge_cross_session_idempotency.yml's 30 s shell
// budget). 4 matches `high_fanout_poll_worker_cap` for Debug in
// tests/e2e_quic_high_concurrency.zig, so it stays well clear of the
// poll-thread CPU storm the release cap guards against in same-process
// harnesses while restoring sane concurrent latency.
const default_quic_poll_worker_count = if (builtin.mode == .Debug) 4 else 16;
const quic_connection_queue_capacity = 1024;
const default_quic_connection_admission_threads = if (builtin.mode == .Debug) 64 else 4096;
// SONNY-3191 (N-5): an admission thread runs a connection's first stream
// itself when the stream pool refuses it or no stream reactor is installed,
// so it gets a request thread's stack (it had 1 MiB, where a plain MATCH was
// refused, and overflowed in a Debug build). A thread that cannot be spawned
// rejects its connection, as before.
//
// CANARY: REQ=REQ-SONNY-3253-ADMISSION-STACK; FEATURE="QuicAdmission"; ASPECT=StackAndSpawnFailure; STATUS=TESTED; TEST=tests/test_sonny3253_round14_minors.zig; OWNER=transport; UPDATED=2026-09-28
// SONNY-3253 (round 15, F13): the stacks are reserved address space, not
// committed memory (a thread touches only the pages it uses), but the
// reservation is `admission threads x stack`: 4096 x 16 MiB is 64 GiB, which
// a kernel with strict overcommit (vm.overcommit_memory=2) counts against
// its commit limit, so spawns fail there long before 4096. A release build
// now takes 8 MiB (32 GiB at 4096 threads): the gRPC connection threads
// serve every request on 8 MiB, and the parser and evaluator bound what a
// request can nest (SONNY-3133, SONNY-3181, SONNY-3189, SONNY-3251), which
// the round 14 and 15 regressions run on 8 MiB threads in ReleaseSafe. A
// Debug build keeps 16 MiB (its frames are several times larger; 64
// admission threads, 1 GiB). GEODE_QUIC_ADMISSION_STACK_MB overrides it
// (8..536870912); lower GEODE_QUIC_CONNECTION_ADMISSION_THREADS under strict
// overcommit. A thread that cannot be spawned rejects its connection
// (logged); the server serves on.
//
// SONNY-3317 (round 16, M5): the override's floor is 8 MiB
// (`min_quic_admission_stack_mb`); it took 1 MiB, the stack on which round
// 13 found a plain MATCH refused, and a Debug build crashed. Two kinds of
// thread serve QUIC requests: the admission threads, which run a
// connection's first stream under overload (8 MiB in a release build, 16
// MiB in Debug, this setting), and the request workers, which serve every
// other stream on 16 MiB stacks (`stack_guard.request_thread_stack_bytes`).
// A request's nesting limits hold on the smaller of the two.
const default_quic_admission_stack_mb: usize = if (builtin.mode == .Debug) 16 else 8;
const min_quic_admission_stack_mb: usize = 8;
// The override's ceiling, 512 TiB, is above the default mmap window of every
// 64-bit Linux user address space (47-bit on x86-64, 48-bit on arm64), so a
// stack of that size can never be mapped. The F13 regression
// (tests/test_sonny3253_round14_minors.zig) relies on that to make every
// admission spawn fail. The old ceiling, 1 TiB, could be mapped: Zig reserves
// the stack PROT_NONE and then makes it writable, and with
// vm.overcommit_memory=1 (the kubelet default on the k8s CI nodes) the kernel
// accepts 1 TiB, so the spawn succeeded and the connection was served.
const max_quic_admission_stack_mb: usize = 512 * 1024 * 1024;
var g_quic_admission_stack_size: usize = default_quic_admission_stack_mb * 1024 * 1024;

// ENG-3979: the `__geode_security`-backed PersistentUserResolver callbacks
// (and their role/duplication helpers) live in a dedicated module so the
// regression suite can drive the REAL callbacks — the seam where a mutating
// `CALL geode.auth.*` re-enters a store lock this thread already holds.
const persistent_auth_resolver = @import("persistent_auth_resolver.zig");
const lookupPersistentAuthUser = persistent_auth_resolver.lookupPersistentAuthUser;
const persistentAuthUsersExist = persistent_auth_resolver.persistentAuthUsersExist;
const lookupPersistentAuthVersion = persistent_auth_resolver.lookupPersistentAuthVersion;
const listPersistentAuthUsers = persistent_auth_resolver.listPersistentAuthUsers;

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
    env_storage_checksum_error: bool,
    security_manager: ?*geode_auth.SecurityManager,
    shared_ast_cache: ?*query_ast_cache.SharedAstCache,
    // Issue #460: Shared cross-connection query optimizer
    shared_optimizer: ?*query_plan_cache.SharedQueryOptimizer = null,
    // #683: Cached env config to avoid per-connection syscalls
    env_config: *const server_init.EnvironmentConfig = undefined,
    // Shared stream pool owned by main(); one per server lifetime instead of one
    // per connection (which leaked under msft-graph reconnect).
    // See docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md.
    //
    // SONNY-1219b (F1): there is no longer an acceptor POOL. Stream accepts are
    // driven for every multiplexed connection by the process-wide
    // `StreamAcceptReactor` (installed via `setAcceptReactor` below), because a
    // per-connection accept task pinned one pool worker for the connection's
    // whole life and silently disabled multiplexing past the worker count.
    stream_pool: *thread_pool.ThreadPool,
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
        ctx.env_storage_checksum_error,
        false,
        ctx.security_manager,
        ctx.shared_ast_cache,
        ctx.shared_optimizer,
        ctx.env_config,
        ctx.stream_pool,
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
// stable. Each accepted connection is dispatched to a `runLspSession`
// thread — multiple LSP clients can therefore have concurrent sessions,
// which is what enables a geode-ui tab plus a terminal editor (or two
// browser tabs) to drive the LSP at the same time without serializing on
// a single accept-and-run loop the way standalone `geode lsp --listen`
// does.
//
// Every session verifies its `initialize` against `provider` (a token,
// through `verifier`) or the user store (a user name and password, as a
// QUIC HELLO, SONNY-6589); the TCP-embedded path always requires auth.
//
// CANARY: REQ=REQ-SONNY-6374-LSP-AUTH-PROVIDER-LIFETIME; FEATURE="Embedded LSP"; ASPECT=ListenerOwnsProviderLifetime; STATUS=TESTED; TEST=tests/test_sonny6374_lsp_auth_provider_lifetime.zig; OWNER=lsp; UPDATED=2026-11-12
// SONNY-6374: the provider used to be freed by a `defer` inside the `if`
// block that spawned the listener, i.e. as soon as the thread had started,
// so every session's verifier read freed memory (a debug server panicked on
// the first `initialize`). `EmbeddedLsp` now owns the provider, the
// listener thread and the live sessions together: `stop` wakes the accept
// loop, the listener shuts down every open session's socket and waits for
// the session threads to return, and only then is the provider freed. If a
// session outlives the bounded drain, the provider (and the listener's Io)
// is leaked deliberately rather than freed under it.
const lsp_session_drain_timeout_ms: u64 = 5_000;

const EmbeddedLsp = struct {
    allocator: std.mem.Allocator,
    port: u16,
    loopback_only: bool,
    provider: *authn_mod.AuthProvider,
    verifier: lsp_auth_mod.Verifier,
    thread: ?std.Thread = null,
    // Set by `stop`; the accept loop exits on the next accept.
    stopping: std.atomic.Value(bool) = .init(false),
    // Set by the listener thread as its last action.
    finished: std.atomic.Value(bool) = .init(false),
    // A session (or the listener) outlived the drain: nothing it may still
    // touch is freed.
    abandoned: std.atomic.Value(bool) = .init(false),
    // Session threads that have not returned yet. Decremented as the last
    // action of each session thread.
    live_sessions: std.atomic.Value(usize) = .init(0),
    // Open sessions whose sockets `stop` shuts down. A session removes
    // itself before it closes its socket, so the listener never shuts down
    // a closed (and possibly reused) descriptor.
    sessions_mutex: std.Io.Mutex = .init,
    sessions: std.ArrayList(*LspSessionArgs) = .empty,

    fn create(allocator: std.mem.Allocator, port: u16, loopback_only: bool) !*EmbeddedLsp {
        const provider = try allocator.create(authn_mod.AuthProvider);
        errdefer allocator.destroy(provider);
        // Empty stores: the server issues no API keys or session tokens
        // (SONNY-6554), so every `initialize` token is rejected. Sessions
        // log in with a user name and password instead (SONNY-6589,
        // `lspCredentialsVerifyFn`).
        provider.* = authn_mod.AuthProvider.init(allocator);
        errdefer provider.deinit();
        const self = try allocator.create(EmbeddedLsp);
        self.* = .{
            .allocator = allocator,
            .port = port,
            .loopback_only = loopback_only,
            .provider = provider,
            .verifier = lsp_auth_mod.verifierFromAuthProvider(provider),
        };
        return self;
    }

    fn start(self: *EmbeddedLsp) !void {
        self.thread = try std.Thread.spawn(.{}, runLspListener, .{self});
    }

    fn unregister(self: *EmbeddedLsp, io: std.Io, session: *LspSessionArgs) void {
        self.sessions_mutex.lockUncancelable(io);
        defer self.sessions_mutex.unlock(io);
        for (self.sessions.items, 0..) |s, i| {
            if (s == session) {
                _ = self.sessions.swapRemove(i);
                return;
            }
        }
    }

    /// Unblock the listener's `accept` with a loopback connection, which the
    /// listener closes on sight once `stopping` is set.
    fn wakeAccept(self: *EmbeddedLsp) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch return;
        const stream = addr.connect(io, .{ .mode = .stream }) catch return;
        stream.close(io);
    }

    /// Stop accepting, close every open session and wait (bounded) for the
    /// listener thread to return. Idempotent.
    fn stop(self: *EmbeddedLsp) void {
        if (self.thread == null) return;
        const t0 = compat_milliTimestamp();
        self.stopping.store(true, .release);
        // The listener's own drain is bounded by
        // lsp_session_drain_timeout_ms; allow it that plus a margin.
        const deadline = t0 + @as(i64, @intCast(lsp_session_drain_timeout_ms)) + 2_000;
        var next_wake: i64 = 0;
        while (!self.finished.load(.acquire)) {
            const now = compat_milliTimestamp();
            if (now >= deadline) break;
            // Repeat the wake: a stop that races the listener's bind can
            // connect before it accepts.
            if (now >= next_wake) {
                self.wakeAccept();
                next_wake = now + 250;
            }
            compat_sleepMs(10);
        }
        const thr = self.thread.?;
        self.thread = null;
        if (self.finished.load(.acquire)) {
            thr.join();
        } else {
            self.abandoned.store(true, .release);
            thr.detach();
        }
        if (self.abandoned.load(.acquire)) {
            std.debug.print(
                "[shutdown] LSP listener or {d} LSP session(s) still running after {d}ms; leaking the LSP AuthProvider to avoid use-after-free\n",
                .{ self.live_sessions.load(.acquire), compat_milliTimestamp() - t0 },
            );
        } else {
            std.debug.print("[shutdown] LSP listener stopped ({d}ms)\n", .{compat_milliTimestamp() - t0});
        }
    }

    /// `stop`, then free the provider and this struct unless something that
    /// borrows them is still running.
    fn shutdown(self: *EmbeddedLsp) void {
        self.stop();
        if (self.abandoned.load(.acquire)) return;
        self.sessions.deinit(self.allocator);
        self.provider.deinit();
        self.allocator.destroy(self.provider);
        self.allocator.destroy(self);
    }
};

fn runLspListener(self: *EmbeddedLsp) void {
    defer self.finished.store(true, .release);
    const host: []const u8 = if (self.loopback_only) "127.0.0.1" else "0.0.0.0";

    // LSP-SEC-008 / SEC-LSP-BIND-01: hard-assert the bind policy at the
    // layer that knows both the bind scope and the auth wiring. Embedded
    // sessions always run with allow_unauth=false; a non-loopback bind
    // (`--lsp-bind-all`) additionally requires a real verifier — refusing
    // here means no future caller can wire an unauthenticated bind-all
    // listener without tripping this guard (and its regression test,
    // tests/test_gap0885_lsp_hardening.zig).
    lsp_server.validateBindPolicy(.{
        .loopback_only = self.loopback_only,
        .allow_unauth = false,
        .has_verifier = true,
    }) catch {
        log.err("LSP listener: refusing non-loopback bind without an authentication verifier (LSP-SEC-008)", &.{
            Attr.string("host", host),
            Attr.int("port", @as(i64, self.port)),
        });
        return;
    };

    // Each accept loop and every per-session reader needs to share one
    // `std.Io` vtable for the lifetime of the listener. A dedicated
    // `std.Io.Threaded` instance, owned by this thread, satisfies that
    // (same pattern as `metrics_server.zig` and the standalone
    // `geode lsp --listen` path in `cli/main.zig`). Sessions that outlived
    // the drain still use it, so it is then leaked with them.
    var threaded = std.Io.Threaded.init(self.allocator, .{});
    defer if (!self.abandoned.load(.acquire)) threaded.deinit();
    const io = threaded.io();

    // Zig 0.16 net stack: `std.Io.net.IpAddress.parse` handles v4 and
    // falls back to v6. We bind a numeric literal — no DNS — so the
    // narrow `parseIp4`/`parseIp6` fallbacks would also work, but
    // `parse` is the more forgiving entry point.
    var bind_addr = std.Io.net.IpAddress.parse(host, self.port) catch
        std.Io.net.IpAddress.parseIp4(host, self.port) catch
        std.Io.net.IpAddress.parseIp6(host, self.port) catch {
        log.err("LSP listener: failed to parse bind host", &.{
            Attr.string("host", host),
            Attr.int("port", @as(i64, self.port)),
        });
        return;
    };

    var listener = std.Io.net.IpAddress.listen(&bind_addr, io, .{ .reuse_address = true }) catch |err| {
        log.err("LSP listener: bind failed", &.{
            Attr.string("host", host),
            Attr.int("port", @as(i64, self.port)),
            Attr.string("error", @errorName(err)),
        });
        return;
    };
    defer listener.deinit(io);

    log.info("LSP server started", &.{
        Attr.string("address", host),
        Attr.int("port", @as(i64, self.port)),
        Attr.string("transport", "tcp"),
    });

    while (!self.stopping.load(.acquire)) {
        const accepted = listener.accept(io) catch |err| {
            if (self.stopping.load(.acquire)) break;
            log.warn("LSP accept error", &.{Attr.string("error", @errorName(err))});
            continue;
        };
        if (self.stopping.load(.acquire)) {
            accepted.close(io);
            break;
        }
        // The session takes ownership of `accepted`. Spawning failure
        // means we still own it and must close it ourselves to avoid
        // leaking the FD.
        const session_args = self.allocator.create(LspSessionArgs) catch {
            log.err("LSP session args alloc failed", &.{});
            accepted.close(io);
            continue;
        };
        session_args.* = .{
            .owner = self,
            .allocator = self.allocator,
            .io = io,
            .stream = accepted,
            .verifier = self.verifier,
        };
        session_args.setPeerIp(accepted.socket.address);
        {
            self.sessions_mutex.lockUncancelable(io);
            defer self.sessions_mutex.unlock(io);
            self.sessions.append(self.allocator, session_args) catch {
                log.err("LSP session registry alloc failed", &.{});
                accepted.close(io);
                self.allocator.destroy(session_args);
                continue;
            };
        }
        _ = self.live_sessions.fetchAdd(1, .acq_rel);
        const thr = std.Thread.spawn(.{}, runLspSession, .{session_args}) catch |err| {
            log.err("LSP session spawn error", &.{Attr.string("error", @errorName(err))});
            self.unregister(io, session_args);
            _ = self.live_sessions.fetchSub(1, .acq_rel);
            accepted.close(io);
            self.allocator.destroy(session_args);
            continue;
        };
        thr.detach();
    }

    // Shut down every open session's socket so its blocked read returns
    // end-of-stream, then wait for the session threads to return before
    // the Io (and, in `EmbeddedLsp.shutdown`, the provider) is freed.
    {
        self.sessions_mutex.lockUncancelable(io);
        defer self.sessions_mutex.unlock(io);
        for (self.sessions.items) |s| s.stream.shutdown(io, .both) catch {};
    }
    const deadline = compat_milliTimestamp() + @as(i64, @intCast(lsp_session_drain_timeout_ms));
    while (self.live_sessions.load(.acquire) > 0 and compat_milliTimestamp() < deadline) {
        compat_sleepMs(10);
    }
    if (self.live_sessions.load(.acquire) > 0) self.abandoned.store(true, .release);
}

const LspSessionArgs = struct {
    owner: *EmbeddedLsp,
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    // Forwarded from the listener and plumbed into
    // `lsp_server.Server.initWithTransport` so the per-session
    // `AuthState.verify` call can validate the client's bearer / session
    // token against the live AuthProvider.
    verifier: lsp_auth_mod.Verifier,
    // SONNY-6589: the peer's IP, the rate limiter's key for a login.
    peer_ip_buf: [64]u8 = undefined,
    peer_ip_len: usize = 0,

    fn setPeerIp(self: *LspSessionArgs, address: std.Io.net.IpAddress) void {
        var a = address;
        a.setPort(0);
        const text = std.fmt.bufPrint(&self.peer_ip_buf, "{f}", .{a}) catch {
            self.peer_ip_len = 0;
            return;
        };
        // "<ip>:0" / "[<ip6>]:0": the address without the port.
        var ip = if (std.mem.endsWith(u8, text, ":0")) text[0 .. text.len - 2] else text;
        if (ip.len >= 2 and ip[0] == '[' and ip[ip.len - 1] == ']') ip = ip[1 .. ip.len - 1];
        std.mem.copyForwards(u8, self.peer_ip_buf[0..ip.len], ip);
        self.peer_ip_len = ip.len;
    }

    fn peerIp(self: *const LspSessionArgs) []const u8 {
        return if (self.peer_ip_len == 0) "unknown" else self.peer_ip_buf[0..self.peer_ip_len];
    }

    /// The session's verifier: a token goes to the listener's provider; a
    /// user name and password to `lspCredentialsVerifyFn`. `self` outlives
    /// the session's Server (freed last in `runLspSession`).
    fn sessionVerifier(self: *LspSessionArgs) lsp_auth_mod.Verifier {
        return .{
            .ctx = self,
            .verifyFn = lspTokenVerifyFn,
            .verifyCredentialsFn = lspCredentialsVerifyFn,
        };
    }
};

fn lspTokenVerifyFn(ctx: *anyopaque, token: []const u8) lsp_auth_mod.Verifier.Outcome {
    const args: *LspSessionArgs = @ptrCast(@alignCast(ctx));
    return args.verifier.verifyFn(args.verifier.ctx, token);
}

// CANARY: REQ=REQ-SONNY-6589-LSP-PASSWORD-AUTH; FEATURE="Embedded LSP"; ASPECT=HelloCredentialsAuthenticateLsp; STATUS=TESTED; TEST=tests/test_sonny6589_lsp_auth.zig; OWNER=lsp; UPDATED=2026-11-15
/// SONNY-6589 (3): an embedded LSP `initialize` logs in with a user name and
/// password, checked as a QUIC HELLO's: `user_management.authenticate`
/// behind the same per-(peer IP, user) rate limiter, a checked-and-rejected
/// credential counting against it. A user who must change their password
/// first is refused (the HELLO admits it only to change the password). The
/// LSP's AuthProvider had no credential at all, so every `initialize` was
/// refused.
fn lspCredentialsVerifyFn(ctx: *anyopaque, username: []const u8, password: []const u8) lsp_auth_mod.Verifier.Outcome {
    const args: *LspSessionArgs = @ptrCast(@alignCast(ctx));
    const user_mgmt = geode.user_management;
    const auth_rate_limiter = @import("auth_rate_limiter.zig");
    if (!auth_rate_limiter.credentialsPresent(username, password)) return .invalid;
    const peer_ip = args.peerIp();
    const limiter = quic_connection_handler.getAuthRateLimiter();
    if (limiter) |l| {
        if (l.isLockedForPrincipal(peer_ip, username)) {
            log.warn("LSP login refused: too many failed authentication attempts", &.{
                Attr.string("peer_ip", peer_ip),
                Attr.string("username", username),
            });
            return .invalid;
        }
    }
    const result = user_mgmt.authenticate(username, password) catch |err| {
        if (auth_rate_limiter.shouldCountFailedAttempt(err)) {
            if (limiter) |l| l.recordFailureForPrincipal(peer_ip, username);
        }
        log.warn("LSP login refused", &.{
            Attr.string("peer_ip", peer_ip),
            Attr.string("username", username),
            Attr.string("error", @errorName(err)),
        });
        return .invalid;
    };
    if (limiter) |l| l.recordSuccessForPrincipal(peer_ip, username);
    if (result.password_reset_required) {
        log.warn("LSP login refused: the user must change their password first", &.{Attr.string("username", username)});
        return .invalid;
    }
    return .{ .ok = .{ .username = username, .role = result.role.toString() } };
}

fn runLspSession(args: *LspSessionArgs) void {
    const owner = args.owner;
    // Last action of the thread: after it the listener may free the Io
    // and the provider.
    defer _ = owner.live_sessions.fetchSub(1, .acq_rel);
    // The listener allocated this struct; we own it now and must free
    // it on every return path.
    defer args.allocator.destroy(args);

    // The session validates `initialize` tokens against the live
    // provider through `args.verifier`. The TCP-embedded path always
    // REQUIRES auth (`--no-auth` is stdio-only).
    var tx = lsp_transport_mod.Transport.initTcp(args.allocator, args.io, args.stream) catch |err| {
        log.warn("LSP transport init error", &.{Attr.string("error", @errorName(err))});
        owner.unregister(args.io, args);
        args.stream.close(args.io);
        return;
    };
    var srv = lsp_server.Server.initWithTransport(args.allocator, tx, args.sessionVerifier(), false) catch |err| {
        log.warn("LSP server init error", &.{Attr.string("error", @errorName(err))});
        owner.unregister(args.io, args);
        tx.deinit();
        return;
    };
    // `srv.deinit` closes the socket; unregister first (defers run LIFO).
    defer srv.deinit();
    defer owner.unregister(args.io, args);
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
/// limits this task to `src/server/main.zig` only; `parseArgs` accepts
/// these two without reading them (it refuses every other flag it does
/// not know, SONNY-6442), and we re-walk argv here.
///
/// Zig 0.16: `std.process.argsAlloc` was removed; argv is recovered from the
/// portable `process_args` holder that `src/unified_entry.zig` captures from
/// the `std.process.Args` delivered to `main`. This works on every supported
/// platform (the prior `/proc/self/cmdline` read was Linux-only). Any failure
/// degrades silently to the defaults (port=3142, loopback-only).
///
/// SONNY-6332: `GEODE_LSP_PORT` sets the port when `--lsp-port` is absent
/// (the flag wins; 0 disables the listener). Every `geode serve` used to open
/// TCP 3142, so concurrent test servers on one host fought over it; the test
/// build sets GEODE_LSP_PORT=0 for every test that spawns geode.
fn parseLspBootstrapConfig(allocator: std.mem.Allocator) LspBootstrapConfig {
    var cfg: LspBootstrapConfig = .{};
    if (posixGetenv("GEODE_LSP_PORT")) |v| {
        cfg.port = std.fmt.parseUnsigned(u16, v, 10) catch blk: {
            log.warn("GEODE_LSP_PORT is not a port number; using the default", &.{
                Attr.string("value", v),
                Attr.int("port", @as(i64, cfg.port)),
            });
            break :blk cfg.port;
        };
    }
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

/// SONNY-6459: when the shutdown tail noticed the signal (ms, 0 = no
/// shutdown yet), so the last teardown line can report the whole shutdown.
var g_shutdown_started_ms = std.atomic.Value(i64).init(0);

fn compat_sleepMs(ms: u64) void {
    if (comptime @import("builtin").os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
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
) !void {
    // SONNY-6567 (5): the tenant hierarchy and quotas are rebuilt from the
    // registry whole, or startup fails. A failed listing, hierarchy add or
    // quota replay was a warning: a tenant missing from the hierarchy (its
    // parent no longer sees its rows; a cascade drop misses it) or running
    // with the default quota instead of its own.
    const recs = reg.list(gpa) catch |err| {
        log.err("tenant_registry.rehydrate_list_failed; refusing to start", &.{Attr.string("error", @errorName(err))});
        return err;
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
                else => {
                    log.err("tenant_registry.rehydrate_hierarchy_failed; refusing to start", &.{
                        Attr.string("tenant", rec.tenant_id),
                        Attr.string("error", @errorName(err)),
                    });
                    return err;
                },
            };
            try added.put(i, {});
            made_progress = true;
        }
    }
    // SONNY-6607 (4): a tenant whose parent is not registered (or a parent
    // cycle) cannot be placed in the hierarchy; it was a warning and the
    // server ran with the tenant outside it (its parent did not see its
    // rows; a cascade drop missed it). The registry never writes one, so it
    // is damage: refuse to start, naming each, as for any other part of the
    // tenant state that cannot be rebuilt.
    if (added.count() < recs.len) {
        for (recs, 0..) |rec, i| {
            if (added.contains(i)) continue;
            log.err("tenant_registry.rehydrate_orphan_parent; refusing to start", &.{
                Attr.string("tenant", rec.tenant_id),
                Attr.string("parent", rec.parent orelse ""),
            });
            std.debug.print("geode: tenant registry: tenant '{s}' names parent '{s}', which is not registered; refusing to start (restore the registry, or remove or re-parent the tenant)\n", .{ rec.tenant_id, rec.parent orelse "" });
        }
        return error.TenantRegistryOrphanParent;
    }

    // Replay quota overrides into the live manager (order-independent).
    for (recs) |rec| {
        if (!rec.has_quota) continue;
        quota_mgr.setQuota(rec.tenant_id, .{
            .max_connections = rec.max_connections,
            .max_concurrent_queries = rec.max_concurrent_queries,
            .max_graphs = rec.max_graphs,
            .max_nodes_per_graph = rec.max_nodes_per_graph,
        }) catch |err| {
            log.err("tenant_registry.rehydrate_quota_failed; refusing to start", &.{
                Attr.string("tenant", rec.tenant_id),
                Attr.string("error", @errorName(err)),
            });
            return err;
        };
    }

    log.info("tenant_registry.rehydrated", &.{Attr.int("tenants", @intCast(recs.len))});
}

fn readCapabilityProfile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => {},
        else => return error.UnsupportedCapabilityProfileFilePlatform,
    }
    const max_bytes = 1 << 20;
    const io = std.Io.Threaded.global_single_threaded.io();
    const fd = try std.posix.openat(std.Io.Dir.cwd().handle, path, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .CLOEXEC = true,
        .NOCTTY = true,
    }, 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidCapabilityProfileFileType;
    if (stat.size > max_bytes) return error.StreamTooLong;
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse error.ReadFailed,
        else => return err,
    };
    errdefer allocator.free(bytes);
    if (bytes.len > max_bytes) return error.StreamTooLong;
    return bytes;
}

fn enforceCapabilityProfile(allocator: std.mem.Allocator, path: []const u8) !void {
    const bytes = try readCapabilityProfile(allocator, path);
    defer allocator.free(bytes);
    var caps = try geode.execution.admin_ddl.executeShowCapabilities(allocator);
    defer caps.deinit(allocator);
    if (caps.columns.len != 2 or !std.mem.eql(u8, caps.columns[0], "feature") or
        !std.mem.eql(u8, caps.columns[1], "supported") or caps.rows.len > 256) return error.MalformedCapabilityRows;
    const rows = try allocator.alloc(geode.capability_gate.CapabilityRow, caps.rows.len);
    defer allocator.free(rows);
    for (caps.rows, 0..) |row, i| {
        if (row.len != 2 or row[0] != .Str or row[1] != .Str) return error.MalformedCapabilityRows;
        rows[i] = .{ .name = row[0].Str, .value = row[1].Str };
    }
    try geode.capability_gate.validateProfile(allocator, bytes, rows, geode.capability_gate.engineVersionFromBuildLabel(build_options.version));
}

/// GEODE_MTLS_REQUIRED is "1", "true" or "on" (case-insensitive).
fn mtlsRequiredFromEnv(gpa: std.mem.Allocator) bool {
    const v = getEnvVarOwned(gpa, "GEODE_MTLS_REQUIRED") catch return false;
    defer gpa.free(v);
    return std.ascii.eqlIgnoreCase(v, "true") or std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "on");
}

// CANARY: REQ=REQ-AUTH-MTLS-QUIC-006; FEATURE="mTLS over QUIC"; ASPECT=ClientCaTrust; STATUS=TESTED; TEST=tests/test_sonny6453_mtls_client_ca.zig; OWNER=security; UPDATED=2026-11-13
/// SONNY-6453: with GEODE_MTLS_REQUIRED set, load GEODE_MTLS_CLIENT_CA (a PEM
/// bundle of CA certificates) as the only trust anchors for client
/// certificates. Refuses (error) when it is unset, cannot be loaded, holds no
/// certificate or a non-CA one, or when a gRPC listener is configured: the
/// gRPC transport does not request or verify client certificates, so it would
/// serve without the mTLS the operator required.
fn loadMtlsClientCa(gpa: std.mem.Allocator, grpc_listener: bool) !quic_transport.ClientCaTrust {
    if (grpc_listener) {
        log.err("mTLS: GEODE_MTLS_REQUIRED cannot be enforced on the gRPC listener; refusing to start (drop --listen-grpc or GEODE_MTLS_REQUIRED)", &.{});
        return error.MtlsNotSupportedOnGrpc;
    }
    const path = getEnvVarOwned(gpa, "GEODE_MTLS_CLIENT_CA") catch {
        log.err("mTLS: GEODE_MTLS_REQUIRED is set but GEODE_MTLS_CLIENT_CA (the CA bundle client certificates must chain to) is not; refusing to start", &.{});
        return error.MtlsClientCaRequired;
    };
    defer gpa.free(path);
    const trust = quic_transport.loadClientCaTrust(gpa, path) catch |err| {
        log.err("mTLS: cannot use GEODE_MTLS_CLIENT_CA; refusing to start", &.{
            Attr.string("path", path),
            Attr.string("error", @errorName(err)),
        });
        return err;
    };
    log.info("mTLS: client certificates verified against GEODE_MTLS_CLIENT_CA", &.{
        Attr.string("path", path),
        Attr.int("ca_certificates", @intCast(trust.ders.len)),
    });
    return trust;
}

// CANARY: REQ=REQ-SONNY-6339-RESOLVED-DATA-DIR; FEATURE="Server Startup"; ASPECT=OneResolver; STATUS=TESTED; TEST=tests/test_sonny6339_resolved_data_dir.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6339: the server's data directory: the `--data-dir` flag, else
/// GEODE_DATA_DIR, else the per-user default (graph_store's own chain,
/// `getPersistenceFilePath`, the one the storage engine resolves). The only
/// place startup reads the raw flag. It replaces the flag field of `config`
/// with the resolved path (owned by `config`), and returns it non-optional, so no
/// consumer can take "no flag" for "no directory": the HMAC key lookup, the
/// auth graph, the audit log path, the tenant registry, timeseries and raft
/// storage did, and ran without durable state. A source check in
/// tests/test_sonny6339_resolved_data_dir.zig fails when main.zig reads the
/// flag anywhere else.
///
/// SONNY-6499: the path is made absolute and normalized (`.` and `..`
/// resolved against the working directory) once, here, so every component
/// sees the same path: the timeseries store refuses any path holding `..`
/// (`validateDataDir`, PathTraversal), and the auth graph manager's failure
/// to open read as "auth records exist", so `--data-dir ../X` on a fresh
/// directory refused to start with "HMAC key required".
fn resolveServerDataDir(gpa: std.mem.Allocator, config: *cli_args.ServerConfig) ![]const u8 {
    const given: []u8 = if (config.data_dir) |flag|
        try gpa.dupe(u8, flag)
    else
        try graph_store.getPersistenceFilePath(gpa);
    defer gpa.free(given);
    const resolved: []u8 = try absoluteDataDir(gpa, given);
    if (config._allocated_data_dir) {
        if (config.data_dir) |old| gpa.free(old);
    }
    config.data_dir = resolved;
    config._allocated_data_dir = true;
    return resolved;
}

/// SONNY-6499: `path` absolute and normalized; a relative path is taken
/// from the working directory. Owned by `gpa`.
fn absoluteDataDir(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(gpa, &.{path});
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), gpa);
    defer gpa.free(cwd);
    return std.fs.path.resolve(gpa, &.{ cwd, path });
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
    // SONNY-6459: runs last (registered first): the whole SIGTERM shutdown,
    // teardown and allocator leak check included.
    defer if (g_shutdown_started_ms.load(.acquire) != 0) {
        std.debug.print(
            "[shutdown] teardown complete ({d}ms after the signal)\n",
            .{compat_milliTimestamp() - g_shutdown_started_ms.load(.acquire)},
        );
    };
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
    // SONNY-6378: the proto-reader registry capacity reserved for the QUIC
    // listener. Registered this early so it runs after every stream thread
    // (which unregisters itself) has been joined.
    defer quic_connection_handler.deinitProtoReaderRegistry(gpa);
    // Parse server CLI args using modularized cli_args module (M3.2 Phase 3 CLI extraction)
    // SONNY-6442: an unknown option, or an option without its value, is a
    // usage error (exit 2, as `geode backup create`); the parser has printed
    // which argument.
    const config_opt = cli_args.parseArgs(gpa) catch |err| switch (err) {
        error.UnknownServeOption, error.MissingArgument => std.process.exit(2),
        // SONNY-1336: a --listen-grpc address the listener cannot bind as given.
        error.InvalidGrpcListenPort, error.GrpcListenAddressNotIpv4, error.GrpcPortOnlyListenNotIpv4 => std.process.exit(2),
        else => return err,
    };
    if (config_opt == null) return; // Help was shown, exit

    var config = config_opt.?;
    defer config.deinit(gpa);

    // Extract config values into local variables for compatibility with existing code
    var memcurve_profile = false;
    const listen_quic = config.listen_quic;
    const listen_grpc = config.listen_grpc;
    const order_keys_mode_expr = config.order_keys_mode_expr;
    const log_level_arg = config.log_level_arg;

    // CANARY: REQ=REQ-ENG-3921-DATA-DIR-LOCK-001; FEATURE="DataDirLock"; ASPECT=ServerStartup; STATUS=TESTED; TEST=tests/test_datadir_lock_subprocess.zig; OWNER=storage; UPDATED=2026-08-31
    // ENG-3921: take single-writer ownership of the data directory before any
    // component opens it. Two `geode serve` processes on one --data-dir used
    // to both come up (split-brain over one on-disk store, last snapshot
    // wins = silent data loss). This must run BEFORE server_init.initialize,
    // which is the first thing to open the store.
    //
    // The lock covers the RESOLVED directory, not the raw flag: an omitted
    // --data-dir still resolves (GEODE_DATA_DIR, else the per-user default
    // from graph_store.defaultDataDir) to a real directory that a second
    // process would share.
    //
    // SONNY-6339: and so does everything else. `data_dir` is the resolved
    // directory, never null; it is installed as the store override at once,
    // so every later consumer (the storage engine, the HMAC key and auth
    // graph, the audit log, the tenant registry, timeseries, raft, TLS,
    // backups, the catalog) sees the same directory however it was given.
    //
    // SONNY-6386: a set but malformed GEODE_TDE_KEY refuses startup here,
    // before the data directory is created: it used to open the store with
    // no page key and write every page in plaintext.
    try server_init.refuseUnusableTdeKey(gpa);
    // SONNY-6422: likewise a half-configured audit key pair, a short
    // GEODE_MASTER_KEY, or a GEODE_WAL_KEY nothing reads.
    try server_init.refuseUnusableKeyConfig(gpa);
    // SONNY-6453: GEODE_MTLS_REQUIRED verifies client certificates against
    // GEODE_MTLS_CLIENT_CA and nothing else; without a usable one, or with a
    // gRPC listener (which cannot verify client certificates), refuse to start.
    const mtls_required = mtlsRequiredFromEnv(gpa);
    var mtls_client_ca: ?quic_transport.ClientCaTrust = if (mtls_required)
        try loadMtlsClientCa(gpa, listen_grpc != null)
    else
        null;
    defer if (mtls_client_ca) |*t| t.deinit();
    const data_dir: []const u8 = try resolveServerDataDir(gpa, &config);
    graph_store.setDataDirOverride(gpa, data_dir);

    // GAP-0909: a --data-dir that does not exist used to crash the server at
    // startup. Create it (mkdir -p); refuse cleanly only if creation fails.
    // ENG-3921 R1: the RESOLVED directory is created, not just the flag —
    // the per-user default ($XDG_STATE_HOME/geode, $HOME/.local/state/geode)
    // does not exist on a fresh machine, and the lockfile below lives in it.
    graph_store.ensureDataDir(data_dir) catch |err| {
        log.err("data dir unavailable; refusing to start", &.{
            Attr.string("path", data_dir),
            Attr.string("error", @errorName(err)),
        });
        return error.DataDirUnavailable;
    };

    // CANARY: REQ=REQ-ENG-3921-DATA-DIR-LOCK-005; FEATURE="DataDirLock"; ASPECT=NestedTreeRefusal; STATUS=TESTED; TEST=tests/test_datadir_lock_subprocess.zig; OWNER=storage; UPDATED=2026-08-31
    // ENG-3921 R3: the lock is per-DIRECTORY, so `--data-dir <live_dir>/nested`
    // used to start cleanly INSIDE a running server's tree and write into it.
    // Refuse when any ANCESTOR holds a live `.geode.lock` (flock probe, so a
    // stale lockfile left by a dead holder never blocks a legitimate start).
    if (data_dir_lock_mod.findLiveAncestorLock(gpa, data_dir)) |ancestor| {
        var holder = ancestor;
        defer holder.deinit(gpa);
        std.debug.print(
            "[startup] data directory {s} is nested inside {s}, which is locked by pid {d}; refusing to start\n",
            .{ data_dir, holder.dir, holder.pid },
        );
        log.err("data directory is nested inside a locked data directory; refusing to start", &.{
            Attr.string("path", data_dir),
            Attr.string("locked_ancestor", holder.dir),
            Attr.int("holder_pid", holder.pid),
        });
        return error.DataDirLocked;
    }

    const lock_budget_ms = data_dir_lock_mod.timeoutFromEnv();
    var data_dir_guard = data_dir_lock_mod.DataDirLock.acquireWithTimeout(
        gpa,
        data_dir,
        lock_budget_ms,
    ) catch |err| switch (err) {
        error.DataDirLocked => {
            const holder = data_dir_lock_mod.readHolderPid(gpa, data_dir) orelse -1;
            // Message wording is load-bearing: operators and the e2e test
            // both key off "data directory is locked by pid".
            std.debug.print(
                "[startup] data directory is locked by pid {d} ({s}); refusing to start\n",
                .{ holder, data_dir },
            );
            log.err("data directory is locked by pid; refusing to start", &.{
                Attr.string("path", data_dir),
                Attr.int("holder_pid", holder),
                Attr.int("waited_ms", @intCast(lock_budget_ms)),
            });
            return error.DataDirLocked;
        },
        else => {
            // CANARY: REQ=REQ-ENG-3921-DATA-DIR-LOCK-007; FEATURE="DataDirLock"; ASPECT=LockUnavailableDiagnostic; STATUS=TESTED; TEST=tests/test_datadir_lock_subprocess.zig; OWNER=storage; UPDATED=2026-08-31
            // ENG-3921 R2: this branch used to log.err only, which the default
            // log configuration does not emit — an unopenable
            // `{data_dir}/.geode.lock` (mode 000, or owned by another uid)
            // killed startup with nothing but a raw error trace. Print an
            // operator message naming the directory, exactly as the
            // DataDirLocked branch above does. Wording is load-bearing.
            std.debug.print(
                "[startup] cannot acquire data directory lock for {s}: {s}; refusing to start\n" ++
                    "  Check that {s}/{s} is a regular file this user can read and write,\n" ++
                    "  and that the filesystem supports advisory locks.\n",
                .{ data_dir, @errorName(err), data_dir, data_dir_lock_mod.lock_filename },
            );
            log.err("cannot acquire data directory lock; refusing to start (fail-closed)", &.{
                Attr.string("path", data_dir),
                Attr.string("error", @errorName(err)),
            });
            return error.DataDirLockUnavailable;
        },
    };
    // Released last, after the shutdown durability flush, so a restarting
    // successor never opens the store while the outgoing process is still
    // writing. Watchdog force-exits bypass this defer, which is harmless:
    // flock dies with the process.
    defer data_dir_guard.release();

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
    // CANARY: REQ=REQ-SONNY-6600-CLUSTER-TOKEN-CONFIG; FEATURE="ClusterAuth"; ASPECT=StartupRefusal; STATUS=TESTED; TEST=tests/test_sonny6600_cluster_token.zig; OWNER=security; UPDATED=2026-11-15
    // SONNY-6600: refuse a cluster token too short to be a secret before any
    // listener binds (GEODE_CLUSTER_TOKEN=t turned cluster mode on with a
    // one-byte shared secret). Printed as well as logged, as above.
    {
        const cluster_auth = geode.distributed.cluster_auth;
        cluster_auth.validateClusterTokenEnv() catch |err| {
            const name = if (err == error.ClusterTokenTooShort) "GEODE_CLUSTER_TOKEN" else "GEODE_CLUSTER_TOKEN_PREVIOUS";
            const value: ?[]const u8 = posixGetenv(if (err == error.ClusterTokenTooShort) "GEODE_CLUSTER_TOKEN" else "GEODE_CLUSTER_TOKEN_PREVIOUS");
            const len: usize = if (value) |v| v.len else 0;
            std.debug.print(
                "SECURITY: refusing to start — {s} is {d} bytes; a cluster token must be at least {d} bytes (generate one with `openssl rand -hex 32`). See src/distributed/README.md.\n",
                .{ name, len, cluster_auth.min_token_len },
            );
            log.err("SECURITY: refusing to start — the cluster token is too short", &.{
                Attr.string("variable", name),
                Attr.int("length", @intCast(len)),
                Attr.int("minimum", @intCast(cluster_auth.min_token_len)),
            });
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

    // Resolve certificate paths and ensure they exist
    const cert_paths = try cli_args.resolveCertPaths(gpa, &config, data_dir);
    const cert_path = cert_paths.cert_path;
    const key_path = cert_paths.key_path;
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
            // Auto path: no cert supplied → use or generate the pair in the
            // resolved data directory (or GEODE_CERT_DIR).
            //
            // CANARY: REQ=REQ-SONNY-6325-NO-FIXED-TMP; FEATURE="Secret File Hygiene"; ASPECT=NoTmpCertFallback; STATUS=TESTED; TEST=tests/test_sonny6325_no_fixed_tmp_paths.zig; OWNER=security; UPDATED=2026-11-11
            // SONNY-6325: there is no fallback. A failure here used to switch
            // to /tmp/geode-server.{crt,key}, a fixed path in a shared
            // directory: a key already there was served whoever planted it.
            // An unusable auto key (a link, another user's, group/world
            // readable, or half a pair) or an unwritable directory refuses
            // startup with the reason; the key is never changed.
            cert_gen.ensureCertificatesAtPath(gpa, cert_path, key_path) catch |err| {
                std.debug.print(
                    "SECURITY: the auto-generated TLS key {s} / certificate {s} cannot be used: {s} ({s}). Refusing to start.\n" ++
                        "Fix or remove the files (the key must be a regular file owned by this user, mode 0600), set GEODE_CERT_DIR to a directory this user can write, or pass --cert and --key.\n",
                    .{ key_path, cert_path, cert_gen.describeTlsError(err), @errorName(err) },
                );
                log.err("auto TLS certificate/key unusable; refusing to start", &.{
                    Attr.string("cert_path", cert_path),
                    Attr.string("key_path", key_path),
                    Attr.string("error", @errorName(err)),
                });
                return err;
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
        defer {
            gpa.free(result.provider_name);
            gpa.free(result.endpoint);
            gpa.free(result.test_result);
        }
        if (!result.configured) {
            log.err("KMS configuration unsuccessful; refusing to start", &.{
                Attr.string("test_result", result.test_result),
                Attr.string("url", url),
            });
            return error.KmsUnreachable;
        }
        // SONNY-6348: only reachability is checked; say so rather than
        // "KMS configured" (no key is fetched from or wrapped by it).
        log.info("KMS endpoint reachable (TCP only; TDE keys still come from GEODE_TDE_KEY)", &.{
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
    } else {
        // SONNY-6339: without --data-dir this was the working directory's
        // audit.jsonl.
        default_audit_path = try std.fmt.allocPrint(gpa, "{s}/audit.jsonl", .{data_dir});
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
    // SONNY-6339: server_init.initialize refuses to start rather than return
    // without an auth graph manager. There is no in-memory-only
    // authentication mode any more: it was the silent fallback when the HMAC
    // key or the store was unavailable (always, without --data-dir), and
    // auth DDL then succeeded into process memory and was gone on restart.
    const agm = init_ctx.auth_graph_mgr orelse return error.AuthGraphUnavailable;
    user_mgmt.setPersistentUserResolver(.{
        .lookup_fn = lookupPersistentAuthUser,
        .has_users_fn = persistentAuthUsersExist,
        .list_fn = listPersistentAuthUsers,
        .auth_version_fn = lookupPersistentAuthVersion,
    });
    // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-036; FEATURE="AuthDDLPersistence"; ASPECT=StartupWiring; STATUS=TESTED; TEST=tests/test_auth_persistence.zig; OWNER=security; UPDATED=2026-06-11
    // P7: Install write-through callbacks for user/role/grant DDL and hydrate
    // in-memory state from __geode_security.
    try server_init.wireAuthDDLCallbacks(agm, gpa);
    // SONNY-6378: registered here, so it runs after the listener blocks
    // below have stopped every request thread.
    defer server_init.releaseAuthDDLPolicy(gpa);
    log.info("Authentication configured for persistent auth graph with LRU cache", &.{});

    // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=StartupHydration; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
    // GPS Phase 4 (Task 4-5): hydrate the in-memory PolicyCatalog from the
    // persisted :Policy nodes in __geode_security.  SONNY-6567 (5): an error
    // fails startup (it continued without the stored policies).
    try server_init.wireGpsPolicyHooks(gpa, agm, &global_policy_catalog);
    std.debug.print("[startup] auth cache configured ({d}ms)\n", .{compat_milliTimestamp() - phase_start});

    // Extract initialization values for compatibility with existing code
    const env_storage_checksum_error = init_ctx.env_config.storage_checksum_error;
    const disable_estimates = init_ctx.env_config.disable_estimates;
    const compact_profile = init_ctx.env_config.compact_profile;
    memcurve_profile = init_ctx.env_config.memcurve_profile;

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

    // SONNY-6346: a tenant registry that cannot be durable refuses startup
    // (it fell back to an in-memory registry whose tenants a restart lost),
    // like the auth state of SONNY-6339.
    var tenant_reg = geode.tenant_registry.TenantRegistry.initWithDataDir(gpa, data_dir) catch |err| {
        log.err("cannot open the tenant registry in the data directory; refusing to start", &.{
            Attr.string("dir", data_dir),
            Attr.string("error", @errorName(err)),
        });
        return err;
    };
    defer tenant_reg.deinit();
    geode.tenant_registry.setGlobalRegistry(&tenant_reg);
    defer geode.tenant_registry.setGlobalRegistry(null);

    // Replay persisted tenants into the live hierarchy + quota manager. The
    // registry is the source of truth; these structures are derived. Tenants are
    // sorted parent-before-child by their created_at so addTenant's "parent must
    // exist" invariant holds for hierarchies built in order; any out-of-order
    // parent is retried until the set stabilizes.
    try rehydrateTenantDerivedState(gpa, &tenant_reg, &expr_rls_engine, &quota_manager);

    // CANARY: REQ=REQ-GAP-0848-TENANCY-DEFAULT-001; FEATURE="StrictTenancyAutoDefault"; ASPECT=Startup; STATUS=TESTED; TEST=tests/test_gap0848_tenancy_default.zig; OWNER=security; UPDATED=2026-06-09
    // GAP-0848: resolve the FINAL effective strict-tenancy mode now that the
    // tenant registry is hydrated, and BEFORE any gRPC/QUIC serve path begins. In
    // a multi-tenant deployment (>=1 non-default tenant registered) strict tenancy
    // auto-enables unless the operator explicitly opted out with
    // GEODE_PERMISSIVE_TENANCY=1. Explicit --strict-tenancy / GEODE_STRICT_TENANCY
    // (already applied above) always wins; single-tenant deployments keep the
    // legacy permissive behaviour.
    applyEffectiveStrictTenancy(gpa, config.strict_tenancy, tenant_reg.hasNonDefaultTenant());

    // CANARY: REQ=REQ-SONNY-CAPABILITY-PROFILE-002; FEATURE="SonnyCapabilityProfile"; ASPECT=StartupOrdering; STATUS=IMPL; TEST=tests/test_capability_gate_startup.zig; OWNER=server; UPDATED=2026-09-08
    if (config.require_capability_profile) |path| {
        enforceCapabilityProfile(gpa, path) catch |err| {
            std.debug.print("[startup] capability profile rejected; refusing to start: {s} (engine {s})\n", .{ @errorName(err), build_options.version[0..@min(build_options.version.len, 128)] });
            log.err("capability profile rejected; refusing to start", &.{
                Attr.string("error", @errorName(err)),
                Attr.string("engine_version", build_options.version[0..@min(build_options.version.len, 128)]),
            });
            return err;
        };
    }

    // CANARY: REQ=REQ-SONNY-6561-CDC-ENABLE-ENV; FEATURE="CDCProcedures"; ASPECT=StartupEnable; STATUS=TESTED; TEST=tests/test_sonny6561_cdc_transport_parity.zig; OWNER=cdc; UPDATED=2026-11-14
    // SONNY-6561: GEODE_CDC_ENABLE=1 (docs/QUICK_REFERENCE.md) starts the CDC
    // engine as `CALL cdc.enable()` does; nothing read it. A server told to
    // run CDC that cannot start it does not start.
    if (envBool(gpa, "GEODE_CDC_ENABLE", false)) {
        try geode.storage_dispatch.enableCdc();
        log.info("CDC engine started via GEODE_CDC_ENABLE", &.{});
    }

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
    // SONNY-6636: after a Raft snapshot restore replaced a graph's files,
    // the vector indexes (not per graph) are rebuilt from it.
    geode.distributed.raft_snapshot_manager.setGraphRestoredHook(&geode.index_manager.rebuildVectorIndexesForRestoredGraph);

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
    // ENG-3954: resolveConfig applies the geode-wide precedence
    // flags > env > default per knob, so --auth-lockout-attempts /
    // --auth-lockout-secs override GEODE_AUTH_RATE_MAX_ATTEMPTS /
    // GEODE_AUTH_RATE_LOCKOUT_SECS (which the harness still uses to exercise
    // the lockout-expiry path with a short window).
    const lockout_cfg = auth_rate_limiter_mod.resolveConfig(config.auth_lockout_attempts, config.auth_lockout_secs);
    var ip_rate_limiter = auth_rate_limiter_mod.AuthRateLimiter.initWithConfig(gpa, lockout_cfg.max_attempts, lockout_cfg.lockout_duration_ns);
    // ENG-3954 RC-1c: the coarse per-IP ceiling (across ALL usernames) resolves
    // with the same flags > env > default precedence, validated to stay strictly
    // above the per-principal threshold so username-keyed limiting keeps meaning.
    ip_rate_limiter.ip_max_attempts = auth_rate_limiter_mod.resolveIpMaxAttempts(config.auth_lockout_ip_attempts, lockout_cfg.max_attempts);
    defer ip_rate_limiter.deinit();
    quic_connection_handler.setAuthRateLimiter(&ip_rate_limiter);
    defer quic_connection_handler.setAuthRateLimiter(null);
    // Also set the centralized global so gRPC transport can access the same limiter.
    auth_rate_limiter_mod.setGlobalRateLimiter(&ip_rate_limiter);
    defer auth_rate_limiter_mod.setGlobalRateLimiter(null);

    // SONNY-6598: test hook, Debug builds only (see
    // user_management.injectKdfAllocFailures): the next N logins of one user
    // fail their Argon2id allocation.
    if (comptime user_mgmt.kdf_fault_hook_available) {
        if (getEnvVarOwned(gpa, "GEODE_TEST_AUTH_KDF_FAULT_USER")) |fault_user| {
            defer gpa.free(fault_user);
            const fault_count = envUsize(gpa, "GEODE_TEST_AUTH_KDF_FAULT_COUNT", 0, 0, 1_000_000);
            if (fault_count > 0) {
                user_mgmt.injectKdfAllocFailures(fault_user, @intCast(fault_count)) catch |err| {
                    log.err("GEODE_TEST_AUTH_KDF_FAULT_USER refused", &.{Attr.string("error", @errorName(err))});
                    return err;
                };
                log.warn("TEST HOOK: password verifications of this user will fail their Argon2id allocation (Debug build only)", &.{
                    Attr.string("user", fault_user),
                    Attr.int("count", @intCast(fault_count)),
                });
            }
        } else |_| {}
    }

    // Task 1 (throughput plan): initialise per-mutation timing instrumentation.
    const mutation_timing = geode.mutation_timing;
    mutation_timing.init(null);

    // Task 11 (throughput plan): initialise bulk-ingest opt-in gate.
    geode.bulk_ingest.initFromEnv();

    // SONNY-2691 / SONNY-2692 (item 5 of the SONNY-2686 review): publish the
    // evaluator's execution callbacks and its row visibility once, before any
    // listener starts. The connection handlers' own `initEvaluator` calls
    // then only read them.
    geode.execution.initEvaluator();

    // S1: Initialize the global RLS label-deny engine.
    // CANARY: REQ=REQ-SEC-RLS-WIRE-004; FEATURE="RLS Query Enforcement"; ASPECT=ServerInit; STATUS=TESTED; TEST=src/server/rls_filter.zig; OWNER=security; UPDATED=2026-06-11
    // GAP-0510 Task 3 / SONNY-2729: one engine (rls_types'), read by the
    // executor and by the transport post-filter (rls_filter re-exports its
    // type and global). There were two, kept in step here.
    // CANARY: REQ=REQ-SEC-RLS-WIRE-012; FEATURE="RLS Expression Wiring"; ASPECT=ServerInitLabelEngine; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=security; UPDATED=2026-06-11
    const rls_types_mod = @import("rls_types");
    var rls_engine = rls_types_mod.RLSFilterEngine.init(gpa);
    defer rls_engine.deinit();
    rls_types_mod.setGlobalRLSFilterEngine(&rls_engine);
    defer rls_types_mod.setGlobalRLSFilterEngine(null);

    // REQ-RLS-DDL-001: Wire the geode.rls.* deny-policy procedures to the live
    // engine the connection handlers consult.
    // CANARY: REQ=REQ-RLS-DDL-001; FEATURE="RLS deny-policy procedure"; ASPECT=ServerCallbackWiring; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/rls_cross_tenant_query_shapes.yml; OWNER=security; UPDATED=2026-05-22
    const rls_dispatch_mod = geode.execution.rls_dispatch;
    const RlsAgm = @import("auth_graph_manager").AuthGraphManager;
    const RlsCbCtx = struct {
        engine: *rls_types_mod.RLSFilterEngine,
    };
    var rls_cb_ctx: RlsCbCtx = .{ .engine = &rls_engine };
    const RlsCbFns = struct {
        fn addDeny(
            ctx_anyopaque: ?*anyopaque,
            graph: []const u8,
            label: []const u8,
            username: []const u8,
        ) anyerror!void {
            const ctx: *RlsCbCtx = @ptrCast(@alignCast(ctx_anyopaque.?));
            // SONNY-3038: all or nothing (one engine since SONNY-2729).
            try ctx.engine.addDenyPolicy(graph, label, username);
        }
        fn removeDeny(
            ctx_anyopaque: ?*anyopaque,
            graph: []const u8,
            label: []const u8,
            username: []const u8,
        ) usize {
            const ctx: *RlsCbCtx = @ptrCast(@alignCast(ctx_anyopaque.?));
            const before = ctx.engine.policyCount();
            ctx.engine.removeDenyPolicy(graph, label, username);
            const after = ctx.engine.policyCount();
            return if (before >= after) before - after else 0;
        }
        fn listDeny(
            ctx_anyopaque: ?*anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror![]rls_dispatch_mod.ListedPolicy {
            const ctx: *RlsCbCtx = @ptrCast(@alignCast(ctx_anyopaque.?));
            ctx.engine.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer ctx.engine.mu.unlock(std.Io.Threaded.global_single_threaded.io());

            var list = std.ArrayList(rls_dispatch_mod.ListedPolicy).empty;
            errdefer {
                for (list.items) |item| {
                    allocator.free(item.graph);
                    allocator.free(item.label);
                    allocator.free(item.username);
                }
                list.deinit(allocator);
            }
            for (ctx.engine.policies.items) |p| {
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
            return ctx.engine.policyCount();
        }
        // SONNY-3034: the restrictions are stored in __geode_security. No
        // auth graph manager (a degraded start): refused, not kept in memory
        // only.
        fn restriction(kind: rls_dispatch_mod.RestrictionKind, graph: []const u8, label: []const u8, subject: []const u8, attribute: []const u8) RlsAgm.RlsRestriction {
            return .{
                .kind = switch (kind) {
                    .deny => .rls_deny,
                    .attribute => .rls_attribute,
                },
                .graph = graph,
                .label = label,
                .subject = subject,
                .attribute = attribute,
            };
        }
        fn persist(_: ?*anyopaque, kind: rls_dispatch_mod.RestrictionKind, graph: []const u8, label: []const u8, subject: []const u8, attribute: []const u8) anyerror!void {
            const rls_agm = RlsAgm.getGlobal() orelse return error.SecurityGraphUnavailable;
            try rls_agm.persistRlsRestriction(&rls_agm.hmac_key, restriction(kind, graph, label, subject, attribute));
        }
        fn unpersist(_: ?*anyopaque, kind: rls_dispatch_mod.RestrictionKind, graph: []const u8, label: []const u8, subject: []const u8, attribute: []const u8) anyerror!void {
            const rls_agm = RlsAgm.getGlobal() orelse return error.SecurityGraphUnavailable;
            try rls_agm.removeRlsRestriction(&rls_agm.hmac_key, restriction(kind, graph, label, subject, attribute));
        }
    };
    rls_dispatch_mod.setCallbacks(.{
        .ctx = @ptrCast(&rls_cb_ctx),
        .add_deny_fn = RlsCbFns.addDeny,
        .remove_deny_fn = RlsCbFns.removeDeny,
        .list_deny_fn = RlsCbFns.listDeny,
        .policy_count_fn = RlsCbFns.count,
        .persist_fn = RlsCbFns.persist,
        .unpersist_fn = RlsCbFns.unpersist,
    });
    defer rls_dispatch_mod.resetCallbacks();

    // CANARY: REQ=REQ-SONNY-3034-RLS-RESTRICTIONS-DURABLE; FEATURE="RLS deny-policy procedure"; ASPECT=ServerHydration; STATUS=TESTED; TEST=tests/test_sonny3034_rls_restrictions_durable.zig; OWNER=security; UPDATED=2026-11-12
    // SONNY-3034: put the stored geode.rls.* restrictions back in force
    // before any listener starts. One that cannot be applied is logged
    // loudly; the rest still load.
    if (RlsAgm.getGlobal()) |rls_agm| load: {
        const stored = rls_agm.listRlsRestrictions(gpa) catch |err| {
            log.err("SONNY-3034: the stored geode.rls restrictions could not be read; none are in force", &.{Attr.string("error", @errorName(err))});
            std.debug.print("[startup] ERROR: the stored geode.rls restrictions could not be read ({s}); none are in force\n", .{@errorName(err)});
            break :load;
        };
        defer RlsAgm.freeRlsRestrictions(gpa, stored);
        var loaded: usize = 0;
        for (stored) |r| {
            const kind: rls_dispatch_mod.RestrictionKind = if (r.kind == .rls_deny) .deny else .attribute;
            rls_dispatch_mod.applyStoredRestriction(kind, r.graph, r.label, r.subject, r.attribute) catch |err| {
                log.err("SONNY-3034: a stored geode.rls restriction could not be put back in force", &.{
                    Attr.string("kind", @tagName(kind)),
                    Attr.string("graph", r.graph),
                    Attr.string("label", r.label),
                    Attr.string("error", @errorName(err)),
                });
                std.debug.print("[startup] ERROR: stored geode.rls {s} restriction on {s}:{s} NOT in force ({s})\n", .{ @tagName(kind), r.graph, r.label, @errorName(err) });
                continue;
            };
            loaded += 1;
        }
        if (stored.len > 0) std.debug.print("[startup] geode.rls restrictions loaded: {d} of {d}\n", .{ loaded, stored.len });
    }

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
        // SONNY-1336: bind the --listen-grpc address itself (it used to reach
        // only the log line, and grpc-zig bound 127.0.0.1). cli_args already
        // refused an address that cannot be bound as given.
        const grpc_bind = try cli_args.resolveGrpcBind(grpc_addr, listen_quic);
        const grpc_port = grpc_bind.port;
        const grpc_address = grpc_bind.address;

        const grpc_config = grpc_transport.GrpcConfig{
            .storage_checksum_error = env_storage_checksum_error,
            .disable_estimates = disable_estimates,
            .compact_profile = compact_profile,
            .memcurve_profile = memcurve_profile,
            .security_manager = init_ctx.security_manager,
            // GAP-0756: Parity with QUIC — gRPC handlers hit the same
            // cross-connection SharedQueryOptimizer plan cache.
            .shared_optimizer = init_ctx.shared_optimizer,
            // SONNY-3032: session lifetimes (the reaper `start` runs).
            .idle_in_transaction_timeout_ms = config.grpc_idle_in_transaction_timeout_ms,
            .session_idle_timeout_ms = config.grpc_session_idle_timeout_ms,
            .max_sessions_per_principal = config.grpc_max_sessions_per_principal,
        };

        const grpc_server = try gpa.create(grpc_transport.GeodeGrpcServer);
        errdefer gpa.destroy(grpc_server);
        grpc_server.* = try grpc_transport.GeodeGrpcServer.init(gpa, grpc_address, grpc_port, cert_path, key_path, grpc_config);
        grpc_server_owner = grpc_server;
        // Startup banner for operational tooling (JSON on stderr), naming the
        // address and port the listener actually bound (the QUIC twin is in
        // QuicTransport.start).
        std.debug.print("{{\"component\":\"transport\",\"transport\":\"grpc\",\"address\":\"{s}\",\"port\":{d},\"status\":\"listening\"}}\n", .{ grpc_address, grpc_server.boundPort() });

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
        // SONNY-6487: the shared host:port grammar. parseArgs already refused
        // an address this cannot resolve; an IPv6 address keeps its brackets
        // because the transport binds "{address}:{port}".
        const quic_listen = cli_args.resolveQuicListen(addr_str) catch |err| {
            log.err("Invalid --listen address; refusing to start", &.{
                Attr.string("listen", addr_str),
                Attr.string("error", @errorName(err)),
            });
            return err;
        };
        const port: u16 = quic_listen.port;
        const address_str: []const u8 = quic_listen.address;

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
        // SONNY-6453: resolved (the client CA bundle loaded) at startup.
        // SONNY-6457: the bundle goes to the TLS layer, which verifies client
        // chains against these CAs only and completes a chain sent without
        // its issuer from them. SONNY-6490: the listener is its only user.
        if (mtls_client_ca) |*trust| {
            transport.config.require_client_cert = true;
            transport.config.inline_client_ca_der = trust.ders;
        }
        // SONNY-6490: with passive teardown the transport is never torn down,
        // so its TLS configuration keeps pointing at the client CA bundle.
        // The bundle is left allocated with it (main's `deinit` of
        // `mtls_client_ca` sees null), never freed under a live endpoint.
        defer if (passive_teardown) {
            mtls_client_ca = null;
        };

        var mtls_prov = geode.mtls_provider.MtlsProvider.init(gpa);
        defer mtls_prov.deinit();
        quic_connection_handler.setMtlsProvider(&mtls_prov);
        defer quic_connection_handler.setMtlsProvider(null);

        // GAP-0901: the per-IP auth rate limiter, both RLS filter engines, the
        // RLS deny-policy DDL callbacks, and the mutation-timing / bulk-ingest
        // gates were HOISTED to before the gRPC serve path (search
        // "GAP-0901"). They formerly lived here, INSIDE the `if (listen_quic)`
        // block, so the gRPC-only serve path never initialized them.
        // `ip_rate_limiter`, `rls_engine` (the one label-deny engine), and `rls_cb_ctx`
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
        // wired via GEODE_TS_RETENTION_DAYS and TDE via GEODE_TDE_KEY
        // (SONNY-6590: on whenever it is set; GEODE_TS_TDE=0 opts out).
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
                Attr.string("dir", data_dir),
                // SONNY-6590: the server-wide time-series store holds data
                // written in plaintext before time-series encryption
                // followed GEODE_TDE_KEY; it is neither opened nor dropped.
                Attr.string("hint", if (err == error.TimeseriesNotEncrypted)
                    "the time-series store <data-dir>/timeseries holds data written in plaintext before TDE covered time-series; geode will not keep plaintext data under GEODE_TDE_KEY. To keep it: start once with GEODE_TS_TDE=0, export it with CALL geode.ts.range, stop, remove <data-dir>/timeseries, restart without GEODE_TS_TDE and re-insert it (docs/TDE_FILE_LEVEL_ENCRYPTION.md)"
                else if (err == error.TimeseriesNeedsTdeKey)
                    "the time-series store <data-dir>/timeseries is encrypted; start with the GEODE_TDE_KEY it was written with and without GEODE_TS_TDE=0"
                else
                    "set GEODE_TS_DURABILITY=best_effort to degrade to in-memory"),
            });
            return err;
        };
        defer ts_store.deinit();
        // Engine init already replayed the WAL and verified segments;
        // loadFromDisk is a no-op kept for API symmetry.
        try ts_store.loadFromDisk();
        eval.setGlobalTimeseriesStore(&ts_store);
        defer eval.setGlobalTimeseriesStore(null);

        // GAP-0268: Wire the persistence-loop hooks: a light (O(dirty))
        // engine checkpoint on every persistence tick, which also truncates
        // the storage-engine WAL (SONNY-6422: no logical WAL is behind them).
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

        // SONNY-6332: the bound port (the kernel's choice for `--listen
        // host:0`), so a caller can start on port 0 and read it back.
        log.info("QUIC server started", &.{
            Attr.string("address", address_str),
            Attr.int("port", transport.boundPort()),
            Attr.string("tls", "1.3"),
        });

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
            // REQ-TRANSPORT-GRPC-SHUTDOWN-001: never free the store while a
            // detached gRPC handler thread is still executing against it — the
            // vendored accept loop detaches handlers geode cannot join, so a
            // free here is a use-after-free (panics inside graph_storage_adapter).
            // The shutdown tail waits for in-flight handlers; if one outlived the
            // bounded drain, leak the store deliberately (the process is exiting
            // and the teardown watchdog force-exits rc=0) rather than free it out
            // from under the handler.
            const grpc_still_running = grpc_transport.grpcInflightCount();
            if (grpc_still_running == 0) {
                const close_t0 = compat_milliTimestamp();
                graph_store.deinitGlobalStore();
                // SONNY-6459: per-phase shutdown timing (the storage engines'
                // close runs here: each shard's WAL writes its checkpoint file).
                if (g_shutdown_started_ms.load(.acquire) != 0) {
                    std.debug.print("[shutdown] store closed ({d}ms)\n", .{compat_milliTimestamp() - close_t0});
                }
            } else {
                log.warn("skipping global store free at teardown: gRPC handler still in flight", &.{
                    Attr.int("grpc_inflight", @intCast(grpc_still_running)),
                });
            }
        }

        // Task 28 (Phase 9): spawn the embedded LSP TCP listener so
        // geode-ui / monaco-languageclient sessions can attach to the
        // same in-process schema view as QUIC handlers. `lsp_port == 0`
        // disables the listener entirely.
        //
        // SONNY-6374: `EmbeddedLsp` owns the listener thread, its sessions
        // and the AuthProvider their verifier borrows. The shutdown tail
        // stops it (closing open sessions) before the data flush, and this
        // defer frees the provider only after the listener and every
        // session thread have returned. It is registered after the store's
        // deinit defer so it runs first: sessions read the global store.
        var embedded_lsp: ?*EmbeddedLsp = null;
        defer if (embedded_lsp) |lsp| lsp.shutdown();
        const lsp_bootstrap_cfg = parseLspBootstrapConfig(gpa);
        if (lsp_bootstrap_cfg.port != 0) {
            const lsp = EmbeddedLsp.create(gpa, lsp_bootstrap_cfg.port, lsp_bootstrap_cfg.loopback_only) catch |err| {
                log.err("Failed to allocate the embedded LSP listener", &.{Attr.string("error", @errorName(err))});
                return err;
            };
            // `shutdown` with no thread started just frees.
            embedded_lsp = lsp;
            lsp.start() catch |err| {
                log.err("Failed to spawn LSP listener thread", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("port", @as(i64, lsp_bootstrap_cfg.port)),
                });
                return err;
            };
        } else {
            log.info("LSP listener disabled (--lsp-port=0 or GEODE_LSP_PORT=0)", &.{});
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
            // accept reactor — see the comment at stream_pool's init for
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
        // SONNY-1837: independent idle-reap deadline (ms) for ADDITIONAL (sibling)
        // QUIC streams. An idle-OPEN sibling pins a shared stream-pool worker + a
        // global throttle slot for its lifetime; without this it is only reclaimed
        // on the ~300s connection idle timeout, so 64 idle-open siblings starve new
        // handshakes (the admission gate already rejects+logs, but the slots stay
        // held). This lets operators reap idle siblings on a tighter, independent
        // schedule. 0 (default) = fall back to the connection idle timeout.
        const quic_stream_idle_reap_ms = envUsize(
            gpa,
            "GEODE_QUIC_STREAM_IDLE_REAP_MS",
            0,
            0,
            3_600_000,
        );
        quic_connection_handler.BufferedProtoReader.setStreamIdleReapDeadlineMs(@intCast(quic_stream_idle_reap_ms));
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
        // connection used to submit ONE long-lived accept task (an infinite
        // poll loop that exits only when its connection tears down), so any
        // concurrent client fan-out beyond the worker count queued accept loops
        // behind already-running ones — they never started, and those
        // connections' client-initiated streams were never accepted
        // server-side.
        //
        // SONNY-1219b (F1): raising the worker count was a mitigation, not a
        // fix — 64 live connections (one-shot CLI queries included) still
        // exhausted it, against a `max_connections` of 10000. Accepts are now
        // driven by the reactor below and a connection occupies no worker at
        // all; this value sizes the reactor's THREADS.
        //
        const quic_acceptor_worker_count = envUsize(
            gpa,
            "GEODE_QUIC_ACCEPTOR_WORKERS",
            default_quic_acceptor_worker_count,
            2,
            64,
        );
        // SONNY-1219b (F1): `GEODE_QUIC_ACCEPTOR_WORKERS` now sizes the stream
        // ACCEPT REACTOR's threads, not a pool of per-connection accept tasks.
        // It keeps its name, its [2, 64] clamp and its meaning ("how many
        // threads drive stream accepts"), but a connection no longer occupies
        // one of them: the reactor shards every multiplexed connection across
        // these threads and drives `tryAcceptStream` for all of them, so the
        // live-connection ceiling is `Config.max_connections` (10000) rather
        // than the worker count. `GEODE_QUIC_ACCEPTOR_QUEUE_CAPACITY` is gone
        // with the pool — there is no accept-task queue to size.
        const accept_reactor = try quic_connection_handler.StreamAcceptReactor.init(gpa, quic_acceptor_worker_count);
        quic_connection_handler.setAcceptReactor(accept_reactor);
        defer {
            quic_connection_handler.setAcceptReactor(null);
            accept_reactor.deinit();
        }

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
                quic_connection_handler.handleQuicConnection(gpa, &transport, conn, disable_estimates, compact_profile, memcurve_profile, env_storage_checksum_error, false, init_ctx.security_manager, init_ctx.shared_ast_cache, init_ctx.shared_optimizer, &init_ctx.env_config, stream_pool) catch |err2| {
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
        // SONNY-3253 (round 15, F13): see `default_quic_admission_stack_mb`.
        g_quic_admission_stack_size = envUsize(
            gpa,
            "GEODE_QUIC_ADMISSION_STACK_MB",
            default_quic_admission_stack_mb,
            min_quic_admission_stack_mb,
            max_quic_admission_stack_mb,
        ) * 1024 * 1024;

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
        // ENG-3954 RC-4: surface store-unavailable auth resolver reads (the
        // "we could not check" outcomes the rate limiter does not count).
        try metrics_registry.register(
            "geode_security_auth_store_unavailable_total",
            persistent_auth_resolver.storeUnavailableCounter(),
        );
        // SONNY-1219b: F2's wrapper-accumulation gauge and F1's reactor-occupancy
        // gauge. `tests/e2e_quic_first_stream_close_mux.zig` asserts on both.
        try metrics_registry.registerGauge(
            "quic_max_tracked_streams",
            quic_metrics.maxTrackedStreams,
            quic_metrics_ctx,
        );
        try metrics_registry.registerGauge(
            "quic_accept_reactor_connections",
            quic_metrics.acceptReactorConnections,
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
        // SONNY-3348 (round 19, m3): statement undo replays, undo failures,
        // and writes refused by the undo record's budget.
        try geode.statement_undo.registerAll(metrics_registry);

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
            // The QUIC listener the accept-path wedge watchdog watches: the
            // transport's bound address (null = unknown, watchdog inert).
            // SONNY-6480: it was the port parsed from `--listen host:port`,
            // so `host:0` left the watchdog off, and only the port was
            // matched (IPv4 only).
            listener: ?acceptor_watchdog.ListenerAddr,
            // SONNY-2719: the listener's drained-datagram count, the
            // watchdog's progress signal.
            transport: *quic_transport.QuicTransport,
            // SONNY-6466: per-connection stall threshold (ns) — how long every
            // stream of one connection may go without reading a message before
            // its in-flight reads are cancelled. GEODE_QUIC_STALL_CANCEL_MS.
            conn_stall_threshold_ns: u64,
        };
        // CANARY: REQ=REQ-SONNY-6480-WATCHDOG-LISTENER; FEATURE="QUIC High-Concurrency Connection Admission"; ASPECT=WatchesBoundListener; STATUS=TESTED; TEST=tests/test_sonny6480_acceptor_watchdog.zig; OWNER=transport; UPDATED=2026-11-13
        // The listener the wedge watchdog watches: the bound socket.
        const watchdog_listener: ?acceptor_watchdog.ListenerAddr = blk: {
            const st = transport.boundAddress() orelse break :blk null;
            break :blk acceptor_watchdog.ListenerAddr.fromStorage(&st);
        };
        if (watchdog_listener) |wl| {
            std.debug.print("[startup] acceptor watchdog: watching {s} {f} port {d}\n", .{ wl.tableName(), wl, wl.port });
        } else {
            std.debug.print("[startup] acceptor watchdog: off (the QUIC listener's address is unknown)\n", .{});
        }
        const metrics_ctx = try gpa.create(MetricsCtx);
        defer gpa.destroy(metrics_ctx);
        metrics_ctx.* = .{
            .registry = metrics_registry,
            .should_stop = &metrics_should_stop,
            .allocator = gpa,
            .listener = watchdog_listener,
            .transport = &transport,
            .conn_stall_threshold_ns = @as(u64, envUsize(gpa, "GEODE_QUIC_STALL_CANCEL_MS", default_conn_stall_cancel_ms, min_conn_stall_cancel_ms, max_conn_stall_cancel_ms)) * std.time.ns_per_ms,
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
                    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
                    _ = if (comptime builtin.os.tag == .linux)
                        std.os.linux.clock_gettime(.MONOTONIC, &ts)
                    else
                        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
                    const now_ns: u64 = @as(u64, @intCast(@max(ts.sec, 0))) * std.time.ns_per_s + @as(u64, @intCast(@max(ts.nsec, 0)));
                    if (reg.connectionLevelStall(now_ns, ctx.conn_stall_threshold_ns)) |snap| {
                        // GAP-ENT-0045: the whole connection is wedged (every
                        // stream idle past threshold — client likely gone).
                        // Abort ITS in-flight read executors only; healthy
                        // connections are untouched. SONNY-6466: the
                        // connection is the vendored connection's identity,
                        // not the peer IP, which every client on one host
                        // shares.
                        const conn_cancelled_n = reg.cancelConnection(snap.conn_id);
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
                    // SONNY-6480: not once shutdown has begun (the acceptor
                    // stops accepting, so queued datagrams are not drained).
                    if (wd_cfg.enabled and ctx.listener != null and !ctx.transport.isShuttingDown()) {
                        if (acceptor_watchdog.readListenerRxQueue(ctx.listener.?)) |rx| {
                            const now_ms2: i64 = @intCast(now_ns / std.time.ns_per_ms);
                            // SONNY-2719: with the drained-datagram count, so a
                            // starved or overloaded acceptor that is still
                            // reading its socket is not taken for a wedge.
                            if (wd_tracker.update(rx, ctx.transport.getDatagramsDrained(), now_ms2, wd_cfg) == .restart) {
                                std.log.err(
                                    "ACCEPTOR WEDGE: :{d} UDP rx_queue={d} bytes stayed >= {d} with no datagram drained for >= {d}ms — the QUIC acceptor is wedged and not draining new connections. Self-restarting so the orchestrator recovers automatically (set GEODE_ACCEPTOR_WATCHDOG_DISABLE=1 to opt out).",
                                    .{ ctx.listener.?.port, rx, wd_cfg.rx_threshold_bytes, wd_cfg.deadline_ms },
                                );
                                std.debug.print(
                                    "ACCEPTOR WEDGE: :{d} UDP rx_queue={d} bytes, no datagram drained for >= {d}ms; self-restarting for automatic recovery.\n",
                                    .{ ctx.listener.?.port, rx, wd_cfg.deadline_ms },
                                );
                                // Let the log flush, then exit non-zero so the
                                // k8s restartPolicy restarts the pod. (This path
                                // is linux-only — readListenerRxQueue returns
                                // null elsewhere.)
                                const flush_req = std.os.linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
                                std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, flush_req.sec) * std.time.ns_per_s + flush_req.nsec), .awake) catch {};
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

        // CANARY: REQ=REQ-GAP-0928-POOL-EXHAUSTED-DIAGNOSTIC; FEATURE="ConnectionPool"; ASPECT=AdmissionDiagnostic; STATUS=TESTED; TEST=test-gap0927; OWNER=transport; UPDATED=2026-11-12
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

            // CANARY: REQ=REQ-ABAC-WIRE-016; FEATURE="ABAC Enforcement"; ASPECT=QUICLoop; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
            // GAP-0202: Create context for async connection handling
            // #50: Reject connection on alloc failure instead of blocking main thread
            const ctx = gpa.create(ConnectionContext) catch {
                log.err("Failed to allocate connection context, rejecting connection", &.{});
                // SONNY-1219: a refusal is a server-initiated close. Close with
                // the distinct application error code so the peer does not read
                // it as a graceful NO_ERROR teardown.
                transport.destroyConnectionWithError(conn, quic_transport.app_error.server_teardown);
                continue;
            };

            ctx.* = .{
                .allocator = gpa,
                .transport = &transport,
                .conn = conn,
                .disable_estimates = disable_estimates,
                .compact_profile = compact_profile,
                .memcurve_profile = memcurve_profile,
                .env_storage_checksum_error = env_storage_checksum_error,
                .security_manager = init_ctx.security_manager,
                .shared_ast_cache = init_ctx.shared_ast_cache,
                .shared_optimizer = init_ctx.shared_optimizer,
                .env_config = &init_ctx.env_config,
                .stream_pool = stream_pool,
            };

            if (detached_connection_admission) {
                if (!g_connection_admission_gate.tryAcquire()) {
                    log.warn("Connection admission thread cap reached, rejecting connection", &.{
                        Attr.int("active_admission", @intCast(g_connection_admission_gate.active.load(.acquire))),
                        Attr.int("max_admission", @intCast(g_connection_admission_gate.max.load(.acquire))),
                    });
                    // SONNY-1219: server-initiated refusal, not a graceful close.
                    transport.destroyConnectionWithError(conn, quic_transport.app_error.server_teardown);
                    gpa.destroy(ctx);
                    continue;
                }
                ctx.admission_gate = &g_connection_admission_gate;

                const admission_thread = std.Thread.spawn(
                    .{ .stack_size = g_quic_admission_stack_size },
                    handleConnectionAsync,
                    .{@as(*anyopaque, @ptrCast(ctx))},
                ) catch |err| {
                    log.warn("Failed to spawn connection admission thread, rejecting connection", &.{
                        Attr.string("error", @errorName(err)),
                    });
                    ctx.admission_gate = null;
                    g_connection_admission_gate.release();
                    // SONNY-1219: server-initiated refusal, not a graceful close.
                    transport.destroyConnectionWithError(conn, quic_transport.app_error.server_teardown);
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
                    // SONNY-1219: server-initiated refusal, not a graceful close.
                    transport.destroyConnectionWithError(conn, quic_transport.app_error.server_teardown);
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
        // REQ-TRANSPORT-GRPC-SHUTDOWN-002: refuse new gRPC handlers from this
        // instant (mirrors transport.requestShutdown for QUIC). The in-flight
        // drain happens below, after the QUIC connection drain.
        grpc_transport.requestGrpcShutdown();
        // SONNY-6605 (3): and stop its accept loop, so the pool running it
        // (`grpc_pool_owner`) joins at teardown instead of timing out and
        // leaving the teardown watchdog to force the exit.
        if (grpc_server_owner) |grpc_srv| grpc_srv.stopAccepting();
        if (detached_connection_admission and !g_connection_admission_gate.waitForZero(10 * std.time.ns_per_s)) {
            log.warn("Connection admission threads still active during shutdown", &.{
                Attr.int("active_admission", @intCast(g_connection_admission_gate.active.load(.acquire))),
            });
        }
        std.debug.print("[shutdown] signal received, flushing data and stopping...\n", .{});
        g_shutdown_started_ms.store(compat_milliTimestamp(), .release);
        // SONNY-6459: checkpoint runs this shutdown makes (reported below).
        const checkpoint_runs_at_signal = graph_store.checkpointRunsTotal();

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

        // ── Embedded LSP (SONNY-6374) ──
        // Stop accepting and close open LSP sessions (bounded) before the
        // data flush. The provider is freed by the `embedded_lsp` defer.
        if (embedded_lsp) |lsp| lsp.stop();

        // ── gRPC in-flight handler drain (REQ-TRANSPORT-GRPC-SHUTDOWN-001) ──
        // gRPC handlers run on threads the vendored accept loop detaches, so
        // they are invisible to the QUIC connection drain above and to
        // getConnectionCount(). Wait for them here — bounded by the same drain
        // timeout — BEFORE the store is flushed and freed, so a handler cannot
        // read a freed StorageAdapter. If a handler outlives the wait, the store
        // free is skipped (see the deinit defer above) and the teardown watchdog
        // force-exits rc=0.
        {
            const gdrain_t0 = compat_milliTimestamp();
            const grpc_inflight0 = grpc_transport.grpcInflightCount();
            if (grpc_inflight0 > 0) {
                std.debug.print(
                    "[shutdown] draining {d} in-flight gRPC handler(s) (timeout {d}ms)\n",
                    .{ grpc_inflight0, drain_timeout_ms },
                );
                const residual = grpc_transport.waitForGrpcInflightZero(drain_timeout_ms);
                if (residual > 0) {
                    std.debug.print(
                        "[shutdown] {d} gRPC handler(s) still in flight after {d}ms; leaking store to avoid use-after-free and proceeding\n",
                        .{ residual, compat_milliTimestamp() - gdrain_t0 },
                    );
                    log.warn("gRPC handlers still in flight after drain timeout", &.{
                        Attr.int("grpc_inflight", @intCast(residual)),
                    });
                } else {
                    std.debug.print(
                        "[shutdown] gRPC handler drain complete ({d}ms)\n",
                        .{compat_milliTimestamp() - gdrain_t0},
                    );
                }
            }
        }

        // ── Data safety: final flush + WAL checkpoint, UNBOUNDED ────────
        // Runs on this thread BEFORE any pool-deinit defer can wedge on a
        // stuck handler, and before the teardown watchdog is armed. However
        // long the checkpoint takes, the watchdog cannot cut it short.
        const pstop_t0 = compat_milliTimestamp();
        // SONNY-6459: no final light checkpoint here when the FULL one below
        // applies — it flushes the same pages and truncates the same WAL.
        graph_store.stopPersistenceThreadForCleanShutdown();
        std.debug.print(
            "[shutdown] persistence thread stopped ({d}ms)\n",
            .{compat_milliTimestamp() - pstop_t0},
        );
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
        // ── Cluster transport (SONNY-6451) ──
        // Stop the raft loops, the outbox drains, the client poll / peer
        // re-resolve thread and the inbound cluster handlers BEFORE the final
        // flush: a node still leading or following would otherwise apply
        // committed entries to the store during and after the flush, and its
        // transport threads ran on until the `cluster_handle` defer. Runs under
        // the first-stage flush watchdog (armed above), so a wedged join still
        // ends in a bounded exit; every raft apply has finished before the
        // full checkpoint below. `stop()` is idempotent; the defer still frees
        // the coordinator.
        if (cluster_handle) |*h| {
            const cstop_t0 = compat_milliTimestamp();
            h.coordinator.stop();
            std.debug.print(
                "[shutdown] cluster transport stopped ({d}ms)\n",
                .{compat_milliTimestamp() - cstop_t0},
            );
        }

        const flush_t0 = compat_milliTimestamp();
        graph_store.flushForCleanShutdown();
        g_shutdown_flush_done.store(true, .release); // disarm the first-stage watchdog
        persistence_flushed_eagerly = true;
        std.debug.print(
            "[shutdown] data flush complete ({d}ms, checkpoint runs since the signal: {d})\n",
            .{ compat_milliTimestamp() - flush_t0, graph_store.checkpointRunsTotal() -| checkpoint_runs_at_signal },
        );

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
