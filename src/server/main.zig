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
    if (std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "yes") or std.mem.eql(u8, raw, "on")) return true;
    if (std.mem.eql(u8, raw, "0") or std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "no") or std.mem.eql(u8, raw, "off")) return false;
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
// Import server initialization (M3.2 Phase 3 initialization extraction)
const server_init = @import("server_init.zig");
const fd_limit = @import("geode").fd_limit;
// Import QUIC connection handlers (M3.3 Phase 3 QUIC handlers extraction)
const quic_connection_handler = @import("quic_connection_handler.zig");
// Import QUIC connection-state aggregation for runtime_metrics gauges
// (Task 4 of docs/superpowers/plans/2026-04-25-quic-cascade-investigation.md)
const quic_metrics = @import("quic_connection_metrics.zig");
const leaked_conn_reaper = @import("leaked_conn_reaper.zig");
const proto_reader_metrics = @import("buffered_proto_reader_metrics.zig");
const quic_response_metrics = @import("quic_response_metrics");
// CANARY: REQ=REQ-ABAC-WIRE-017; FEATURE="ABAC Enforcement"; ASPECT=AsyncConnection; STATUS=IMPL; OWNER=server; UPDATED=2026-01-27
// GAP-0165: Import geode_auth for SecurityManager type in async connection context
const geode_auth = @import("geode_auth");

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

// CANARY: REQ=REQ-QUIC-HC-009; FEATURE="High-Concurrency Allocator"; ASPECT=ServerAllocator; STATUS=IMPL; OWNER=transport; UPDATED=2026-05-25
//
// Debug builds keep DebugAllocator leak detection. Optimized server builds use
// the SMP allocator so high-concurrency request parsing/protobuf work does not
// serialize on debug-allocation bookkeeping.
const ServerAllocator = if (builtin.mode == .Debug)
    std.heap.DebugAllocator(.{})
else
    struct {
        pub fn allocator(_: *@This()) std.mem.Allocator {
            return std.heap.smp_allocator;
        }
    };

// CANARY: REQ=REQ-QUIC-HC-018; FEATURE="QUIC High-Concurrency Worker Fanout"; ASPECT=StreamPoolSizing; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-25
//
// Stream handlers are long-lived per-client query loops. A fixed, non-tunable
// 64-worker pool serialized 128+ client fan-out even after connection
// admission became detached. Keep the startup-safe default unchanged and expose
// env overrides for benchmark/production high-fanout tuning.
const default_quic_stream_worker_count = 64;
const default_quic_stream_queue_capacity = 4096;
const default_quic_acceptor_worker_count = 64;
const default_quic_acceptor_queue_capacity = 4096;
const default_quic_connection_worker_count = 64;
const default_quic_detached_first_stream_threads = if (builtin.mode == .Debug) 64 else 256;
const default_quic_cooperative_first_stream_worker_count = if (builtin.mode == .Debug) 16 else 256;
const default_quic_poll_worker_count = if (builtin.mode == .Debug) 1 else 16;
const quic_connection_queue_capacity = 1024;
const default_quic_connection_admission_threads = if (builtin.mode == .Debug) 64 else 1024;
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
    // The store lock may already be held by the calling thread (e.g., QUIC
    // handler executing a CALL query or MFA setup for a non-existent user).
    // Use tryAcquire to avoid deadlock; if the lock can't be acquired, return
    // null (caller treats the user as "not found" and falls back to in-memory
    // state).
    const locked = geode.graph_store.tryAcquireStoreLock();
    defer if (locked) geode.graph_store.releaseStoreLock();

    const store = geode.graph_store.getGlobalStore(allocator);
    const record = user_storage.UserStorageBackend.findUserByUsernameInGraph(store, username) orelse return null;
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

    for (records, 0..) |record, i| {
        users[i] = try duplicatePersistentUser(allocator, store, record);
        initialized += 1;
    }
    return users;
}

// CANARY: REQ=REQ-PERF-ASYNC-CONN-001; FEATURE="AsyncConnectionHandling"; ASPECT=ThreadPool; STATUS=IMPL; OWNER=server; UPDATED=2026-01-27
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

// CANARY: REQ=REQ-QUIC-HC-012; FEATURE="DetachedConnectionAdmission"; ASPECT=HelloFanout; STATUS=IMPL; OWNER=transport; UPDATED=2026-05-26
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
/// Zig 0.16: `std.process.argsAlloc` was removed; the same pattern
/// `cli_args.parseArgs` uses (read `/proc/self/cmdline` and split on
/// NULs) is the supported way to recover argv. Any I/O failure
/// degrades silently to the defaults (port=3142, loopback-only).
fn parseLspBootstrapConfig(allocator: std.mem.Allocator) LspBootstrapConfig {
    var cfg: LspBootstrapConfig = .{};
    const io = std.Io.Threaded.global_single_threaded.io();
    const cmdline_file = std.Io.Dir.openFileAbsolute(io, "/proc/self/cmdline", .{}) catch return cfg;
    defer cmdline_file.close(io);

    const max_cmdline: usize = 64 * 1024;
    const cmdline_data = allocator.alloc(u8, max_cmdline) catch return cfg;
    defer allocator.free(cmdline_data);

    var total_read: usize = 0;
    while (total_read < max_cmdline) {
        const n = cmdline_file.readPositional(io, &.{cmdline_data[total_read..]}, total_read) catch return cfg;
        if (n == 0) break;
        total_read += n;
    }
    const filled = cmdline_data[0..total_read];

    var start: usize = 0;
    for (filled, 0..) |c, i| {
        if (c != 0) continue;
        if (i > start) {
            const arg = filled[start..i];
            if (std.mem.startsWith(u8, arg, "--lsp-port=")) {
                const v = arg["--lsp-port=".len..];
                cfg.port = std.fmt.parseUnsigned(u16, v, 10) catch cfg.port;
            } else if (std.mem.eql(u8, arg, "--lsp-bind-all")) {
                cfg.loopback_only = false;
            }
        }
        start = i + 1;
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
const paginationStreamScaffold = server_flags.paginationStreamScaffold;
const initImplDefinedFlags = server_flags.initImplDefinedFlags;
const computeBaseFlags = server_flags.computeBaseFlags;
// Import graph storage management (M3.1 Phase 3 graph persistence extraction)
// CANARY: REQ=REQ-BINARY-PERSIST-003; FEATURE="BinaryPersistence"; ASPECT=MainImports; STATUS=IMPL; OWNER=server; UPDATED=2026-02-02
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

// Removed: ServerState struct now in server_state module (M3.2 Phase 3 ServerState extraction)
// Original: ServerState struct definition (~107 lines, lines 145-252)
// Extracted to server_state.zig to enable better modularization and shared access
// Includes all fields and resetResult() method - imported above via: const ServerState = server_state.ServerState;

const DEBUG_PROFILE = false; // default off; enable locally when investigating PROFILE frame assembly

// Tracking allocator (existing) provides basic net/peak metrics for PROFILE.
const TrackingAllocator = @import("tracking_alloc").TrackingAllocator;

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
// Original: paginationStreamScaffold() function (~6 lines)
// Original: initImplDefinedFlags() function (~14 lines)
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
// TODO(alloc-metrics): Counting allocator integration deferred; current bytes_alloc remains heuristic.

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

pub fn main() !void {
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
    if (config.insecure_allow_all) {
        gps.setInsecureAllowAll(true);
        log.warn("SECURITY: Geode running with --insecure-allow-all: all authorization checks bypassed. NOT FOR PRODUCTION.", &.{});
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

    // Try to generate certificates if using QUIC or gRPC (TLS needed for both)
    phase_start = compat_milliTimestamp();
    if (listen_quic != null or listen_grpc != null) {
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

    // Create heap-allocated audit logger to ensure stability
    var audit_logger = try gpa.create(audit.AuditLogger);
    audit_logger.* = try audit.AuditLogger.init(gpa, audit_config);
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
        // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-036; FEATURE="AuthDDLPersistence"; ASPECT=StartupWiring; STATUS=IMPL; OWNER=security; UPDATED=2026-05-12
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
        user_mgmt.ensureDefaultUser(gpa) catch |err| {
            log.err("Failed to create default users", &.{Attr.string("error", @errorName(err))});
            return err;
        };
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
        const id = if (@hasDecl(uuid_lib, "newV7"))
            uuid_lib.newV7() catch uuid_lib.newV4() catch unreachable
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

    // CANARY: REQ=REQ-GAP-0503-DIST-BOOT; FEATURE="DistributedMode"; ASPECT=ClusterBootstrap; STATUS=IMPL; OWNER=core; UPDATED=2026-05-25
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
    // CANARY: REQ=REQ-OTEL-METRICS-014; FEATURE="OTel Instrumentation"; ASPECT=ProcessMetrics; STATUS=IMPL; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
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
    }
    defer metrics_server.shutdownGlobalMetrics(gpa);

    // gRPC server (optional)
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
        grpc_server.* = try grpc_transport.GeodeGrpcServer.init(gpa, grpc_port, cert_path, key_path, grpc_config);
        defer {
            grpc_server.deinit();
            gpa.destroy(grpc_server);
        }

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
            defer grpc_pool.deinit();
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
        // CANARY: REQ=REQ-AUTH-MTLS-QUIC-005; FEATURE="mTLS over QUIC"; ASPECT=ServerInit; STATUS=IMPL; OWNER=security; UPDATED=2026-02-13
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

        // S6: Initialize per-IP authentication rate limiter for brute-force protection.
        // CANARY: REQ=REQ-SEC-RATE-LIMIT-007; FEATURE="AuthRateLimiting"; ASPECT=ServerInit; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
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
        // Reads GEODE_MUTATION_TIMING_LOG from the process environment; no-op
        // when the variable is unset or set to "0".
        const mutation_timing = geode.mutation_timing;
        mutation_timing.init(null);

        // Task 11 (throughput plan): initialise bulk-ingest opt-in gate.
        // Reads GEODE_BULK_INGEST from the process environment; when any
        // non-empty value is set, the QUIC handler routes simple
        // `CREATE (n:L {...})` statements through `adapter.bulkInsertNode`
        // instead of `executeProgramWithContext`.  Unset / empty keeps the
        // regular executor path.
        geode.bulk_ingest.initFromEnv();

        // S1: Initialize the global RLS filter engine for label-based row filtering.
        // The engine lives on the main thread's stack and is accessed by connection
        // handlers via the global singleton in rls_filter.zig.
        // CANARY: REQ=REQ-SEC-RLS-WIRE-004; FEATURE="RLS Query Enforcement"; ASPECT=ServerInit; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
        const rls_filter_mod = @import("rls_filter.zig");
        var rls_engine = rls_filter_mod.RLSFilterEngine.init(gpa);
        defer rls_engine.deinit();
        rls_filter_mod.setGlobalRLSFilterEngine(&rls_engine);
        defer rls_filter_mod.setGlobalRLSFilterEngine(null);

        // GAP-0510 Task 3: Also initialize the rls_types shared label-filter engine so
        // that match_operations.zig (part of the geode root module) can access it via
        // @import("rls_types").getGlobalRLSFilterEngine().  Both engines start empty;
        // policies added at runtime go to both through the procedure/admin API.
        // CANARY: REQ=REQ-SEC-RLS-WIRE-012; FEATURE="RLS Expression Wiring"; ASPECT=ServerInitLabelEngine; STATUS=IMPL; OWNER=security; UPDATED=2026-04-06
        const rls_types_mod = @import("rls_types");
        var rls_types_engine = rls_types_mod.RLSFilterEngine.init(gpa);
        defer rls_types_engine.deinit();
        rls_types_mod.setGlobalRLSFilterEngine(&rls_types_engine);
        defer rls_types_mod.setGlobalRLSFilterEngine(null);

        // REQ-RLS-DDL-001: Wire the `geode.rls.add_deny_policy` /
        // `remove_deny_policy` / `list_deny_policies` / `policy_count`
        // procedures so the CLI surface can install per-user label denies in
        // the rls_filter engine that the connection handler actually
        // consults. Without this wiring those procedures return an explicit
        // "RLS filter engine not initialized" error.
        //
        // Both engines (rls_filter + rls_types) receive every mutation so the
        // legacy label-filter path and the newer expression engine stay in
        // sync. Listing is sourced from rls_filter since that is the
        // engine quic_connection_handler / federation read from.
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
                    // The types engine is best-effort — log and continue so a
                    // partial failure doesn't leave the legacy engine empty.
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

        // GAP-0510 Task D1: Initialize the global expression RLS engine so that
        // property-based and temporal RLS policies are evaluated during query
        // execution.  The engine lives on the main thread's stack; connection
        // handlers access it via rls_types.getGlobalExprRLSEngine().
        // CANARY: REQ=REQ-SEC-RLS-WIRE-014; FEATURE="RLS Expression Wiring"; ASPECT=ServerInitExprEngine; STATUS=IMPL; OWNER=security; UPDATED=2026-04-06
        const rls_core_mod = @import("rls");
        var expr_rls_engine = try rls_core_mod.RLSEngine.init(gpa);
        defer expr_rls_engine.deinit();
        rls_types_mod.setGlobalExprRLSEngine(@ptrCast(&expr_rls_engine));
        defer rls_types_mod.setGlobalExprRLSEngine(null);

        // GAP-0280: Initialize a server-wide timeseries Store so that
        // timeseries.value() calls in the QUIC/gRPC execution path return
        // real data instead of NULL.  The store lives on the main thread's
        // stack and is published via eval.setGlobalTimeseriesStore().
        // GAP-0292: Wire ChunkStorage persistence — pass data_dir so
        // timeseries data survives server restarts.
        // CANARY: REQ=REQ-TIMESERIES-WIRE-003; FEATURE="TimeseriesServerWiring"; ASPECT=ServerInit; STATUS=TESTED; TEST=src/eval.zig; OWNER=server; UPDATED=2026-04-01
        // CANARY: REQ=REQ-TS-PERSIST-001; FEATURE="TimeSeriesPersistence"; ASPECT=ServerInit; STATUS=IMPL; OWNER=server; UPDATED=2026-04-01
        const ts_mod = geode.timeseries;
        var ts_store = ts_mod.Store.initWithConfig(gpa, .{
            .data_dir = data_dir,
        }) catch blk: {
            log.warn("timeseries.init_persist_fallback", &.{});
            break :blk ts_mod.Store.init(gpa);
        };
        defer ts_store.deinit();
        // Hydrate in-memory store from any previously persisted chunks.
        ts_store.loadFromDisk() catch |err| {
            log.warn("timeseries.load_from_disk_failed", &.{Attr.string("error", @errorName(err))});
        };
        eval.setGlobalTimeseriesStore(&ts_store);
        defer eval.setGlobalTimeseriesStore(null);

        // GAP-0268: Wire WAL persistence hooks for checkpoint truncation.
        // The hooks allow the persistence loop to sync and truncate the WAL
        // after each successful checkpoint, preventing unbounded WAL growth.
        // CANARY: REQ=REQ-WAL-HOOKS-001; FEATURE="WAL Persistence Hooks"; ASPECT=ServerInit; STATUS=IMPL; OWNER=storage; UPDATED=2026-03-27
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
        defer {
            // Stop persistence thread first (final flush), then free the global store.
            // Without deinitGlobalStore(), all in-memory graph data (nodes, edges, indexes,
            // properties) leaks and the GPA reports errors on SIGTERM exit.
            graph_store.stopPersistenceThread(gpa);
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
        // CANARY: REQ=REQ-QUIC-HC-053; FEATURE="QUIC High-Concurrency Requests"; ASPECT=MultiPollWorkers; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-26
        //
        // Release builds use a small poll-worker set so high fan-out request
        // bursts do not stall behind one endpoint poll loop. Debug keeps a
        // single worker to make local traces deterministic.
        //
        // CANARY: REQ=REQ-QUIC-HC-141; FEATURE="QUIC High-Concurrency Requests"; ASPECT=PollWorkerContentionCap; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-28
        // Per-connection TLS crypto polling is serialized in the QUIC library;
        // more than 16 endpoint poll workers contends on that serialization
        // point and regresses high-fanout setup and mixed read/write request
        // fan-out.
        const quic_poll_worker_count = envUsize(
            gpa,
            "GEODE_QUIC_POLL_WORKERS",
            default_quic_poll_worker_count,
            1,
            16,
        );
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

        // CANARY: REQ=REQ-PERF-STREAM-POOL-001; FEATURE="SharedStreamPool"; ASPECT=ThreadPoolInit; STATUS=IMPL; OWNER=server; UPDATED=2026-04-25
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

        // CANARY: REQ=REQ-PERF-ASYNC-CONN-002; FEATURE="AsyncConnectionHandling"; ASPECT=ThreadPoolInit; STATUS=IMPL; OWNER=server; UPDATED=2026-05-25
        // CANARY: REQ=REQ-QUIC-HC-132; FEATURE="QUIC High-Concurrency Requests"; ASPECT=ConnectionPoolCapCompatibility; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-28
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
            .stack_size = 2 * 1024 * 1024, // 2MB per thread (default 16MB causes ~19MB RSS growth per faulted stack)
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
        // CANARY: REQ=REQ-QUIC-HC-044; FEATURE="QUIC High-Concurrency Requests"; ASPECT=BoundedDetachedFirstStreams; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-26
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

        // CANARY: REQ=REQ-QUIC-HC-054; FEATURE="QUIC High-Concurrency Requests"; ASPECT=CooperativeFirstStreams; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-26
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

        // CANARY: REQ=REQ-PERF-METRICS-001; FEATURE="RuntimeMetrics"; ASPECT=RegistryInit; STATUS=IMPL; OWNER=server; UPDATED=2026-04-25
        // Task 4: Initialise the process-global runtime_metrics registry and spawn
        // the periodic-emit task onto the existing connection thread pool.
        // Access via geode module to avoid duplicate-module conflict (runtime_metrics.zig
        // is owned by the 'geode' module via lib.zig; main.zig is in 'root').
        const runtime_metrics_mod = geode.runtime_metrics;
        const metrics_registry = try runtime_metrics_mod.Registry.init(gpa);
        runtime_metrics_mod.setGlobalRegistry(metrics_registry);

        // Allocate the QUIC metrics context. Lives until server shutdown
        // so the gauge callbacks can dereference it from the emit loop.
        // Declared BEFORE the registry-deinit defer so on LIFO unwind it
        // runs AFTER metrics_registry.deinit() — by which point no gauge
        // callbacks can fire against this freed pointer.
        const quic_metrics_ctx = try gpa.create(quic_metrics.Ctx);
        defer gpa.destroy(quic_metrics_ctx);
        quic_metrics_ctx.* = .{ .transport = &transport };

        defer {
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

        var metrics_should_stop = std.atomic.Value(u32).init(0);
        const MetricsCtx = struct {
            registry: *runtime_metrics_mod.Registry,
            should_stop: *std.atomic.Value(u32),
            allocator: std.mem.Allocator,
        };
        const metrics_ctx = try gpa.create(MetricsCtx);
        defer gpa.destroy(metrics_ctx);
        metrics_ctx.* = .{
            .registry = metrics_registry,
            .should_stop = &metrics_should_stop,
            .allocator = gpa,
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
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(ctx.allocator);
                    ctx.registry.snapshotInto(ctx.allocator, &buf) catch continue;
                    std.log.info("metrics: {s}", .{buf.items});

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
                            std.log.err(
                                "proto_reader stall detected: idle_ms={d} pending_handlers={d} (handlers wedged downstream of BufferedProtoReader.nextMessage; restart pod to recover)",
                                .{ idle_ns / std.time.ns_per_ms, pending },
                            );
                            last_stall_log_idle_ns = idle_ns;
                        }
                    } else {
                        last_stall_log_idle_ns = 0;
                    }

                    // #864 §10 per-stream stall watchdog: walk the
                    // process-wide proto-reader registry; if any
                    // single stream has been idle past the threshold,
                    // log the stream id + peer so operators can
                    // correlate with goroutine dumps / client retries.
                    // Distinct from the process-wide watchdog above:
                    // catches the qa-seed reproduction where SOME
                    // streams keep delivering messages while a
                    // specific stream is wedged.
                    const reg = quic_connection_handler.getProtoReaderRegistry();
                    var ts: std.os.linux.timespec = undefined;
                    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
                    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
                    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
                    const now_ns: u64 = sec * std.time.ns_per_s + nsec;
                    if (reg.maxIdleNs(now_ns)) |snap| {
                        if (snap.idle_ns >= stall_threshold_ns) {
                            std.log.err(
                                "per-stream proto_reader stall: stream_id={d} peer={s} idle_ms={d} (this stream wedged while others may still be progressing; restart pod or wait for client retry)",
                                .{ snap.stream_id, snap.peer_addr, snap.idle_ns / std.time.ns_per_ms },
                            );
                        }
                    }
                }
            }
        }.run;

        // CANARY: REQ=REQ-QUIC-HC-010; FEATURE="High-Concurrency Connection Admission"; ASPECT=MetricsPoolIsolation; STATUS=IMPL; OWNER=transport; UPDATED=2026-05-25
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
        transport.requestShutdown();
        if (detached_connection_admission and !g_connection_admission_gate.waitForZero(10 * std.time.ns_per_s)) {
            log.warn("Connection admission threads still active during shutdown", &.{
                Attr.int("active_admission", @intCast(g_connection_admission_gate.active.load(.acquire))),
            });
        }
        std.debug.print("[shutdown] signal received, flushing data and stopping...\n", .{});
        return;
    }

    log.err("No QUIC listener configured. Use --listen.", &.{});
    return error.MissingListenAddress;
}
