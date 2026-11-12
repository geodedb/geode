const std = @import("std");
const cb = @import("crypto_backend");

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
const builtin = @import("builtin");
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc_zig = @import("grpc_server");
const GrpcServer = grpc_zig.GrpcServer;
/// SONNY-3313: `pub` for the regression test, which serves a Handshake on
/// a real accepted socket.
pub const GrpcTransport = grpc_zig.Transport;
const proto_util = geode.proto_util;
const server_flags = geode.server_flags;
const diagnostics = geode.diagnostics;
const execution = geode.execution;
const graph_store = geode.graph_store;
const server_state = geode.server_state;
const query_runner = geode.query_runner;
const query_traits = geode.query_traits;
// GAP-0755: Per-query arena pool for executor scratch.
const query_arena = geode.query_arena;
const explain_payload = geode.explain_payload;
const profile_payload = geode.profile_payload;
const txn_undo_log = geode.txn_undo_log;
const index_manager = geode.index_manager;
const user_mgmt = geode.user_management;
const gql_ast = geode.gql.ast;
const gql_print = geode.printer;
const planned_read_runtime = geode.planned_read_runtime;
const node_scan_stream = geode.node_scan_stream;
// GAP-0756: SharedQueryOptimizer cross-connection plan cache (parity with QUIC handler).
const query_plan_cache = geode.query_plan_cache;
const geode_auth = @import("geode_auth");
const grpc_tls = @import("grpc_tls.zig");
// Issue #515: Backup types for new gRPC handlers
const backup_mgr = geode.backup_manager;
const SimplifiedBackupManager = backup_mgr.SimplifiedBackupManager;

// GAP-0281: FLE integration for per-tenant encryption namespace setup.
const fle_integration = geode.fle_integration;
// GAP-0282: Import audit module for per-thread tenant_id enrichment
const audit_mod = geode.security.audit;
// S1: RLS post-result filtering (parity with QUIC handler).
const rls_filter = @import("../server/rls_filter.zig");
// S6: Auth rate limiter (parity with QUIC handler).
const auth_rate_limiter_mod = @import("../server/auth_rate_limiter.zig");
// GAP-0283: Graph-scoped RBAC enforcement (parity with QUIC handler).
const multi_graph_security = geode.multi_graph_security;
// GAP-0289: Per-tenant resource quotas (parity with QUIC handler).
const tenant_quota = geode.tenant_quota;

const logging = @import("logging");
const log = logging.scoped("grpc");
const Attr = logging.Attr;

pub const GrpcConfig = struct {
    spill_threshold: usize = 0,
    storage_checksum_error: bool = false,
    disable_estimates: bool = false,
    compact_profile: bool = false,
    memcurve_profile: bool = false,
    security_manager: ?*geode_auth.SecurityManager = null,
    // GAP-0756: Shared query optimizer — plan cache reused across connections.
    // Populated from `server_init.InitContext.shared_optimizer` by `main.zig`.
    shared_optimizer: ?*query_plan_cache.SharedQueryOptimizer = null,
    // SONNY-3032: session lifetimes (`SessionStore`). `main.zig` sets them
    // from `--idle-in-transaction-timeout`, `--grpc-session-idle-timeout`
    // and `--grpc-max-sessions-per-principal` (or the config file's
    // `idle_in_transaction_timeout`, `grpc_session_idle_timeout` and
    // `grpc_max_sessions_per_principal`). 0 turns each off.
    idle_in_transaction_timeout_ms: u64 = default_idle_in_transaction_timeout_ms,
    session_idle_timeout_ms: u64 = default_session_idle_timeout_ms,
    max_sessions_per_principal: u32 = default_max_sessions_per_principal,
};

/// SONNY-1560: made `pub` so the flow-control regression suite can drive
/// `pushResultPages` against a hand-built session without standing up the
/// global session store.
pub const SessionEntry = struct {
    state: *server_state.ServerState,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// SONNY-1560: monotonic generation of this session's active result set.
    /// Bumped under `mutex` by every Execute that installs a new result and by
    /// the deterministic release path below. A pushed gRPC stream claims the
    /// generation it is draining and re-validates it after every UNLOCKED page
    /// write; a mismatch means a newer Execute superseded this stream, so the
    /// stream stops instead of touching (or freeing) the newer result. This is
    /// what lets the push loop drop the session mutex between pages without
    /// reintroducing the Issue #514 use-after-free.
    ///
    /// CANARY: REQ=REQ-TRANSPORT-GRPC-RESULT-EPOCH-001; FEATURE="GrpcSessionSafety"; ASPECT=ResultGeneration; STATUS=TESTED; TEST=tests/test_sonny1560_grpc_flow_control.zig; OWNER=transport; UPDATED=2026-09-14
    result_epoch: u64 = 0,
    /// SONNY-3032: who the session counts against for
    /// `max_sessions_per_principal`. SONNY-3252 (round 15): the user name
    /// the session authenticated as (not the tenant: one user name in two
    /// tenants is one principal); without authentication
    /// `anonymous@<peer ip>`, and on the federation path
    /// `federation@<peer ip>` (`principalFor`). Owned by the store.
    principal: []const u8 = "",
    /// SONNY-3032: requests holding the session (`SessionStore.acquire` ..
    /// `release`); the reaper closes only a session none holds.
    refs: std.atomic.Value(u32) = .init(0),
    /// SONNY-3032: when the session's last request ended (`monoMillis`).
    last_active_ms: std.atomic.Value(i64) = .init(0),
};

const SessionAuthStatus = enum {
    ok,
    missing,
    invalidated,
};

const AdminSessionStatus = enum {
    ok,
    missing,
    invalidated,
    forbidden,
};

fn envFlagEnabled(allocator: std.mem.Allocator, name: []const u8) bool {
    const raw = getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(raw);
    if (raw.len == 0) return false;
    if (raw[0] == '0') return false;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "off")) return false;
    return true;
}

fn shouldAllowGrpcPlaintextFallback(allocator: std.mem.Allocator) bool {
    if (!envFlagEnabled(allocator, "GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK")) return false;
    if (builtin.mode == .Debug) return true;

    log.warn("Ignoring GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK outside Debug builds", &.{});
    return false;
}

fn generateSessionId(allocator: std.mem.Allocator) ![]const u8 {
    var entropy: [16]u8 = undefined;
    // fips-exempt: non-security session identifier (not a key, nonce, or secret)
    compat_fillRandom(&entropy);
    const token = std.fmt.bytesToHex(entropy, .lower);
    return std.fmt.allocPrint(allocator, "sess_{s}", .{token});
}

/// SONNY-3032: a Handshake whose session could not be registered: the
/// principal holds `max_sessions_per_principal` sessions, all in use. Any
/// other error is the handler's.
fn helloSessionRefused(allocator: std.mem.Allocator, caps: std.ArrayList([]const u8), err: anyerror) ![]u8 {
    if (err != error.TooManySessions) return err;
    const resp = schema.HelloResponse{
        .success = false,
        .session_id = "",
        // SONNY-3252 (round 15): resource exhausted. Refused, not made room
        // for by closing a session in a transaction.
        .error_message = "RESOURCE_EXHAUSTED: too many sessions for this principal: it holds the server's max_sessions_per_principal sessions, each in use or in an open transaction. Close sessions, or raise --grpc-max-sessions-per-principal",
        .capabilities = caps,
    };
    return encodeMessage(allocator, resp);
}

fn throttleInvalidSessionProbe() void {
    var jitter: [1]u8 = undefined;
    // fips-exempt: non-security throttle delay jitter (timing only, not cryptographic)
    compat_fillRandom(&jitter);
    const delay_ms: u64 = 5 + @as(u64, @intCast(jitter[0] % 6));
    const ns: u64 = delay_ms * std.time.ns_per_ms;
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
}

fn rebuildPendingIndexes(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    pending_index_rebuilds: *std.StringHashMap(void),
) void {
    if (pending_index_rebuilds.count() == 0) return;
    const manager = index_manager.getGlobalIndexManager() orelse return;

    // geode#875 RC-2b / RC-5: identical to the QUIC drain site — snapshot under
    // the SHARED lock, build the shadow index lock-free, swap, and REPORT the
    // indexed count instead of swallowing it. See
    // `quic_connection_handler.rebuildPendingIndexes`.
    var iter = pending_index_rebuilds.keyIterator();
    while (iter.next()) |k| {
        const indexed = manager.rebuildAdvancedVectorIndexNonBlocking(allocator, graph_name, k.*) catch |err| {
            log.warn("Advanced index backfill failed", &.{
                Attr.string("index", k.*),
                Attr.string("graph", graph_name),
                Attr.string("error", @errorName(err)),
            });
            continue;
        };
        log.info("Advanced index backfill complete", &.{
            Attr.string("index", k.*),
            Attr.string("graph", graph_name),
            Attr.uint("entities_indexed", indexed),
        });
    }
}

// CANARY: REQ=REQ-SONNY-3252-SESSION-CAP; FEATURE="GrpcSessionLifetime"; ASPECT=PrincipalKeys; STATUS=TESTED; TEST=tests/test_sonny3252_grpc_session_cap.zig; OWNER=transport; UPDATED=2026-09-28
/// SONNY-3252 (round 15, F8, F9): the principal a Handshake's session counts
/// against for `max_sessions_per_principal`, written into `buf`:
///   - an authenticated user: the user name (the cap is per user name, not
///     per tenant: the same name in two tenants shares one cap);
///   - without authentication: `anonymous@<peer ip>`. Every anonymous client
///     was the principal "", so any of them could take the cap's room from
///     every other one; now the clients of one host share a cap, and
///     clients of different hosts do not touch each other's sessions;
///   - the federation path (a peer node with the cluster token): every peer
///     node sends the same name (`validateFederationAuth` accepts only
///     `geode-cluster`), so it counts as `federation@<peer ip>`: one cap per
///     peer node, not one for the cluster.
///
/// SONNY-3313 (round 16, I1): `<peer ip>` is the connection's real peer
/// address (`getPeerIp`, `formatPeerIp`); it was "unknown" for every client
/// until round 16, so all anonymous clients shared one cap. What it keys is
/// the address the server sees:
///   - clients behind one NAT gateway, proxy or load balancer (one that does
///     not keep the client's address) are one peer, and share one cap;
///   - an IPv6 client is keyed by its full address, and a host usually holds
///     a whole /64: by rotating addresses in it, one host can take the cap's
///     room many times over. The auth rate limiter's per-IP bucket, which
///     uses the same address, has the same two limits.
pub fn principalFor(buf: []u8, kind: enum { user, anonymous, federation }, username: []const u8, peer_ip: []const u8) []const u8 {
    return switch (kind) {
        .user => username,
        .anonymous => std.fmt.bufPrint(buf, "anonymous@{s}", .{peer_ip}) catch "anonymous@",
        .federation => std.fmt.bufPrint(buf, "federation@{s}", .{peer_ip}) catch "federation@",
    };
}

/// SONNY-3032: the defaults of the session lifetimes (`GrpcConfig`).
pub const default_idle_in_transaction_timeout_ms: u64 = 10 * std.time.ms_per_min;
pub const default_session_idle_timeout_ms: u64 = 30 * std.time.ms_per_min;
pub const default_max_sessions_per_principal: u32 = 1024;

/// SONNY-3032: milliseconds on the monotonic clock, for session idle times.
pub fn monoMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    } else {
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    }
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

// Issue #453: Use RwLock instead of Mutex to allow concurrent readers
//
// SONNY-1221: `pub`, with `setSessionStore`, `handleExecute` and `handlePull`,
// so the fast-path schema regression can drive the REAL Execute and Pull
// handlers in process. Over a real `geode serve` the gRPC node-scan fast path
// is unreachable for an authenticated session (the global RLS filter engine is
// always installed there, see `rls_active`), so that handler's fast-path schema
// frame can only be exercised in process.
/// `pub` as a SONNY-1221 test seam only; production dispatch must go through
/// `handlePacket`, and production installs the store in `GeodeGrpcServer.init`.
///
/// CANARY: REQ=REQ-SONNY-3032-GRPC-SESSION-EXPIRY; FEATURE="GrpcSessionLifetime"; ASPECT=Reaper; STATUS=TESTED; TEST=tests/test_sonny3032_grpc_session_expiry.zig; OWNER=transport; UPDATED=2026-09-27
/// SONNY-3032: a gRPC session lives until it is idle too long. It used to
/// live as long as the server: nothing ever removed one, a Handshake made a
/// new one each time, and a client that began a transaction, wrote and went
/// away left the transaction open for good, with its undo entries, its engine
/// transaction and its graph hold (SONNY-3134: that graph could never be
/// dropped). QUIC ends a session with its stream; gRPC has no such end.
/// The reaper (`startReaper`, `reap`) closes, with the teardown every other
/// end of a session runs (`deinitServerState`: the transaction is rolled
/// back, the engine transaction aborted, the hold released):
/// - a session idle in an open transaction for `idle_in_transaction_timeout_ms`
///   (default 10 minutes): its transaction is rolled back and the session is
///   closed, as PostgreSQL's idle_in_transaction_session_timeout does; its
///   next request answers as for an unknown session, and its COMMIT fails;
/// - any session idle for `session_idle_timeout_ms` (default 30 minutes).
/// A session a request is using (`acquire` .. `release`) is never closed, and
/// one principal holds at most `max_sessions_per_principal` sessions (default
/// 1024): past that a Handshake closes the principal's least recently used
/// idle session, or is refused when all of them are in use.
///
/// SONNY-3252 (round 15, F8, F9): a session in an open transaction is never
/// closed to make room: when each of the principal's sessions is in use or
/// in a transaction, the Handshake is refused (resource exhausted). The
/// principal is keyed per `principalFor`. Each principal's sessions are
/// listed (`principals`), so the check is O(1) and the search for a session
/// to close looks at that principal's sessions only. A closed session's
/// teardown runs on the reaper thread, not the Handshake's (inline only
/// when no reaper runs). And a Handshake whose insert cannot be made closes
/// nothing: the room is reserved before a session is taken out.
pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    rwlock: std.Io.RwLock = std.Io.RwLock.init,
    sessions: std.StringHashMap(*SessionEntry),
    /// SONNY-3252: each principal's session ids (the keys of `sessions`),
    /// under `rwlock`. The keys are the store's own copies.
    principals: std.StringHashMap(std.ArrayList([]const u8)),
    /// SONNY-3252: sessions the cap closed, for the reaper to tear down
    /// (under `rwlock`), and how many wait.
    pending_teardown: std.ArrayList(std.StringHashMap(*SessionEntry).KV) = .empty,
    pending_teardown_count: std.atomic.Value(usize) = .init(0),
    config: GrpcConfig,
    /// SONNY-3032: the reaper thread (`startReaper`) and its stop flag.
    reaper: ?std.Thread = null,
    reaper_stop: std.atomic.Value(bool) = .init(false),
    /// SONNY-3032: sessions the reaper closed, for tests and diagnostics.
    reaped_total: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, config: GrpcConfig) SessionStore {
        execution.initEvaluator();
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(*SessionEntry).init(allocator),
            .principals = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *SessionStore) void {
        self.stopReaper();
        self.drainTeardown();
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.destroyEntry(entry.key_ptr.*, entry.value_ptr.*);
        }
        self.sessions.deinit();
        var pit = self.principals.iterator();
        while (pit.next()) |p| {
            self.allocator.free(p.key_ptr.*);
            p.value_ptr.deinit(self.allocator);
        }
        self.principals.deinit();
        self.pending_teardown.deinit(self.allocator);
    }

    /// SONNY-3252: tear down the sessions the cap closed.
    fn drainTeardown(self: *SessionStore) void {
        var batch: std.ArrayList(std.StringHashMap(*SessionEntry).KV) = .empty;
        {
            self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());
            batch = self.pending_teardown;
            self.pending_teardown = .empty;
            self.pending_teardown_count.store(0, .release);
        }
        defer batch.deinit(self.allocator);
        for (batch.items) |kv| {
            self.destroyEntry(kv.key, kv.value);
            _ = self.reaped_total.fetchAdd(1, .monotonic);
        }
    }

    /// SONNY-3252: the number of sessions `principal` holds.
    pub fn principalSessionCount(self: *SessionStore, principal: []const u8) usize {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
        const list = self.principals.get(principal) orelse return 0;
        return list.items.len;
    }

    /// SONNY-3252: `session_id` out of its principal's list, with `rwlock`
    /// held exclusively; an emptied list goes with its key.
    fn untrackLocked(self: *SessionStore, principal: []const u8, session_id: []const u8) void {
        const list = self.principals.getPtr(principal) orelse return;
        for (list.items, 0..) |id, i| {
            if (id.ptr == session_id.ptr) {
                _ = list.swapRemove(i);
                break;
            }
        }
        if (list.items.len == 0) {
            if (self.principals.fetchRemove(principal)) |kv| {
                var l = kv.value;
                l.deinit(self.allocator);
                self.allocator.free(kv.key);
            }
        }
    }

    /// SONNY-3032: end a session that is out of `sessions` and that no
    /// request holds: the teardown every end of a session runs
    /// (`deinitServerState`: an open transaction is rolled back, its engine
    /// transaction aborted, its graph hold released), then its memory.
    fn destroyEntry(self: *SessionStore, session_id: []const u8, entry: *SessionEntry) void {
        deinitServerState(entry.state);
        self.allocator.destroy(entry.state);
        self.allocator.free(entry.principal);
        self.allocator.destroy(entry);
        self.allocator.free(session_id);
    }

    /// A session for `username`, counted against the principal of the same
    /// name (SONNY-3252: see `principalFor`).
    pub fn createSession(
        self: *SessionStore,
        username: []const u8,
        password: []const u8,
        role: ?user_mgmt.Role,
        tenant_id: ?[]const u8,
        graph: ?[]const u8,
        pwd_reset_required: bool,
        auth_version: u64,
    ) ![]const u8 {
        return self.createSessionAs(username, username, password, role, tenant_id, graph, pwd_reset_required, auth_version);
    }

    /// SONNY-6334: the FLE role a HELLO named, validated
    /// (`fle_integration.helloFleRole`, as QUIC), kept on the session's
    /// state; an invalid or empty one is no role.
    pub fn setSessionFleRole(self: *SessionStore, session_id: []const u8, requested: ?[]const u8) !void {
        const role = fle_integration.helloFleRole(requested) orelse {
            if (requested) |r| if (r.len > 0) log.warn("Rejected invalid FLE role: contains illegal characters", &.{});
            return;
        };
        const entry = self.acquire(session_id) orelse return error.SessionNotFound;
        defer self.release(entry);
        {
            entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            const copy = try entry.state.allocator.dupe(u8, role);
            if (entry.state.fle_user_role) |old| entry.state.allocator.free(old);
            entry.state.fle_user_role = copy;
        }
        // SONNY-6341: a role the user does not hold is audited and not acted
        // under (`ServerState.effectiveFleRole`, every request).
        entry.state.auditUnheldFleRole();
    }

    /// SONNY-3252: a session for `username`, counted against `principal`.
    pub fn createSessionAs(
        self: *SessionStore,
        principal: []const u8,
        username: []const u8,
        password: []const u8,
        role: ?user_mgmt.Role,
        tenant_id: ?[]const u8,
        graph: ?[]const u8,
        pwd_reset_required: bool,
        auth_version: u64,
    ) ![]const u8 {
        const session_id = try generateSessionId(self.allocator);
        // SONNY-3252 (round 15, F9): a step that fails frees what the steps
        // before it made (the id, the state, the entry); from the entry on,
        // `destroyEntry` does.
        const entry = entry_blk: {
            errdefer self.allocator.free(session_id);
            const state = try initServerState(self.allocator, self.config);
            errdefer {
                deinitServerState(state);
                self.allocator.destroy(state);
            }
            if (username.len > 0) {
                state.authenticated_user = try self.allocator.dupe(u8, username);
            }
            if (password.len > 0) {
                state.authenticated_password = try self.allocator.dupe(u8, password);
            }
            if (role) |r| {
                state.authenticated_role = @intFromEnum(r);
            }
            state.authenticated_auth_version = auth_version;
            state.authenticated_auth_validation_epoch = user_mgmt.authInvalidationEpoch();
            // GAP-0284: Persist password_reset_required flag so execute handler can enforce it.
            state.password_reset_required = pwd_reset_required;
            if (tenant_id) |tenant| {
                // SONNY-3317 (round 16, M8): the copy is made before the quota
                // is taken, and the session's config owns both at once: the
                // quota is released with the config (`deinitServerState`). A
                // copy that failed after the quota was taken leaked the quota.
                const tenant_copy = try self.allocator.dupe(u8, tenant);
                // GAP-0289: Enforce per-tenant connection quota before registering the session.
                if (tenant_quota.getGlobalQuotaManager()) |qm| {
                    qm.acquireConnection(tenant) catch {
                        self.allocator.free(tenant_copy);
                        return error.OutOfMemory; // quota exceeded
                    };
                }
                state.session_config = server_state.SessionConfiguration.init(self.allocator);
                state.session_config.?.tenant_id = tenant_copy;
            }

            // GAP-0281/0282, SONNY-6334: the tenant reaches FLE and audit
            // through each request's context (`installRequestThreadState`),
            // not the Handshake's thread, which serves other sessions next.

            // CANARY: REQ=REQ-DSN-GRAPH-BIND-004; FEATURE="DSNGraphBinding"; ASPECT=GrpcSessionGraph; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-25
            if (graph) |g| {
                if (g.len > 0) {
                    // SONNY-2775: stored the one way (the session's allocator);
                    // HELLO checked the bind before it got here.
                    if (state.exec_session) |*sess| try execution.session_graph.set(sess, g);
                    state.graph_bound = true;
                }
            }

            const e = try self.allocator.create(SessionEntry);
            errdefer self.allocator.destroy(e);
            e.* = .{
                .state = state,
                .principal = try self.allocator.dupe(u8, principal),
                .last_active_ms = .init(monoMillis()),
            };
            break :entry_blk e;
        };
        // The principals map's own copy of the name, for a principal with no
        // list yet; freed below when it is not needed.
        var principal_key: ?[]u8 = self.allocator.dupe(u8, principal) catch {
            self.destroyEntry(session_id, entry);
            return error.OutOfMemory;
        };
        defer if (principal_key) |k| self.allocator.free(k);

        // SONNY-3032, SONNY-3252: at most `max_sessions_per_principal`
        // sessions each; room is reserved before anything is taken out, so
        // a failure closes nothing (F9: the victim was taken out, the insert
        // failed, and the victim was never torn down and kept its hold).
        var evicted: ?std.StringHashMap(*SessionEntry).KV = null;
        var evicted_queued = false;
        const registered: error{ TooManySessions, OutOfMemory }!void = blk: {
            self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());
            self.sessions.ensureUnusedCapacity(1) catch |err| break :blk err;
            const gop = self.principals.getOrPut(principal_key.?) catch |err| break :blk err;
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                principal_key = null; // the map's now
            }
            const list = gop.value_ptr;
            list.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                if (list.items.len == 0) {
                    const kv = self.principals.fetchRemove(principal).?;
                    self.allocator.free(kv.key);
                }
                break :blk err;
            };
            if (self.config.max_sessions_per_principal > 0 and list.items.len >= self.config.max_sessions_per_principal) {
                const victim = self.victimLocked(list.items) orelse {
                    if (list.items.len == 0) {
                        const kv = self.principals.fetchRemove(principal).?;
                        self.allocator.free(kv.key);
                    }
                    break :blk error.TooManySessions;
                };
                evicted = self.sessions.fetchRemove(victim);
                if (evicted) |kv| {
                    for (list.items, 0..) |id, i| {
                        if (id.ptr == kv.key.ptr) {
                            _ = list.swapRemove(i);
                            break;
                        }
                    }
                }
            }
            self.sessions.putAssumeCapacityNoClobber(session_id, entry);
            list.appendAssumeCapacity(session_id);
            if (evicted) |kv| {
                // Torn down by the reaper, off this Handshake's thread.
                if (self.reaper != null) {
                    self.pending_teardown.append(self.allocator, kv) catch break :blk {};
                    _ = self.pending_teardown_count.fetchAdd(1, .release);
                    evicted = null;
                    evicted_queued = true;
                }
            }
            break :blk {};
        };
        registered catch |err| {
            self.destroyEntry(session_id, entry);
            return err;
        };
        // SONNY-3317 (round 16, M8): a session closed to make room is logged
        // whether it is torn down here or queued for the reaper (the queued
        // one was not logged).
        if (evicted_queued) {
            log.warn("closing a principal's least recently used idle gRPC session: the principal is at max_sessions_per_principal (torn down by the reaper)", &.{
                Attr.uint("max_sessions_per_principal", self.config.max_sessions_per_principal),
            });
        }
        if (evicted) |kv| {
            log.warn("closing a principal's least recently used idle gRPC session: the principal is at max_sessions_per_principal", &.{
                Attr.uint("max_sessions_per_principal", self.config.max_sessions_per_principal),
            });
            // No reaper runs (or no room to queue it): torn down here.
            self.destroyEntry(kv.key, kv.value);
            _ = self.reaped_total.fetchAdd(1, .monotonic);
        }
        return session_id;
    }

    /// SONNY-3252: with the store's lock held exclusively: the least recently
    /// used of `ids` (one principal's sessions) that no request holds and
    /// that has no open transaction, or null when every one is in use or in
    /// a transaction (F8: such a session was closed, and its transaction
    /// rolled back, to make room).
    fn victimLocked(self: *SessionStore, ids: []const []const u8) ?[]const u8 {
        var victim: ?[]const u8 = null;
        var victim_time: i64 = 0;
        for (ids) |id| {
            const e = self.sessions.get(id) orelse continue;
            if (e.refs.load(.acquire) != 0) continue;
            if (e.state.in_txn or e.state.session_engine_txn.open) continue;
            const t = e.last_active_ms.load(.acquire);
            if (victim == null or t < victim_time) {
                victim = id;
                victim_time = t;
            }
        }
        return victim;
    }

    /// The session's entry, for a caller that does not keep it (tests).
    /// Requests use `acquire` and `release`: the reaper may close a session
    /// no request holds.
    pub fn getEntry(self: *SessionStore, session_id: []const u8) ?*SessionEntry {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
        return self.sessions.get(session_id);
    }

    /// SONNY-3032: the session's entry, held for a request until `release`:
    /// the reaper does not close a held session.
    pub fn acquire(self: *SessionStore, session_id: []const u8) ?*SessionEntry {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
        const entry = self.sessions.get(session_id) orelse return null;
        _ = entry.refs.fetchAdd(1, .acq_rel);
        return entry;
    }

    /// SONNY-3032: the request is done with the session; it has been idle
    /// since now.
    pub fn release(self: *SessionStore, entry: *SessionEntry) void {
        _ = self;
        entry.last_active_ms.store(monoMillis(), .release);
        _ = entry.refs.fetchSub(1, .acq_rel);
    }

    /// SONNY-3032: one pass of the reaper at `now_ms` (the monotonic clock of
    /// `monoMillis`): close every session no request holds that has been
    /// idle in an open transaction for `idle_in_transaction_timeout_ms`, or
    /// idle for `session_idle_timeout_ms` (0 turns either off). The sessions
    /// leave the map under its lock, where no request can take them, and are
    /// torn down after it. Returns how many it closed.
    pub fn reap(self: *SessionStore, now_ms: i64) usize {
        const txn_ms: i64 = @intCast(@min(self.config.idle_in_transaction_timeout_ms, std.math.maxInt(i64)));
        const idle_ms: i64 = @intCast(@min(self.config.session_idle_timeout_ms, std.math.maxInt(i64)));
        // SONNY-3252: the sessions the cap closed first.
        if (self.pending_teardown_count.load(.acquire) > 0) self.drainTeardown();
        if (txn_ms == 0 and idle_ms == 0) return 0;
        var sfa = std.heap.stackFallback(16 * @sizeOf(std.StringHashMap(*SessionEntry).KV), std.heap.smp_allocator);
        const la = sfa.get();
        var closed: std.ArrayList(std.StringHashMap(*SessionEntry).KV) = .empty;
        defer closed.deinit(la);
        {
            self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());
            var ids: std.ArrayList([]const u8) = .empty;
            defer ids.deinit(la);
            var it = self.sessions.iterator();
            while (it.next()) |kv| {
                const e = kv.value_ptr.*;
                // Held by a request: not idle. Unheld, nothing touches its
                // state while this lock is held.
                if (e.refs.load(.acquire) != 0) continue;
                const idle = now_ms - e.last_active_ms.load(.acquire);
                const in_txn = e.state.in_txn or e.state.session_engine_txn.open;
                const expired = (in_txn and txn_ms > 0 and idle >= txn_ms) or (idle_ms > 0 and idle >= idle_ms);
                if (expired) ids.append(la, kv.key_ptr.*) catch break;
            }
            for (ids.items) |id| {
                const kv = self.sessions.fetchRemove(id) orelse continue;
                closed.append(la, kv) catch {
                    // No room to list it: put it back for the next pass.
                    self.sessions.putAssumeCapacity(kv.key, kv.value);
                    break;
                };
                // SONNY-3252: out of its principal's list.
                self.untrackLocked(kv.value.principal, kv.key);
            }
        }
        for (closed.items) |kv| {
            const in_txn = kv.value.state.in_txn or kv.value.state.session_engine_txn.open;
            log.info("closing an idle gRPC session", &.{
                Attr.boolean("in_transaction", in_txn),
                Attr.int("idle_ms", now_ms - kv.value.last_active_ms.load(.acquire)),
            });
            self.destroyEntry(kv.key, kv.value);
        }
        _ = self.reaped_total.fetchAdd(closed.items.len, .monotonic);
        return closed.items.len;
    }

    /// SONNY-3032: how often the reaper runs: a quarter of the shorter
    /// timeout, between 25 ms and 30 s.
    fn reaperIntervalMs(self: *const SessionStore) u64 {
        var shortest: u64 = std.math.maxInt(u64);
        if (self.config.idle_in_transaction_timeout_ms > 0) shortest = @min(shortest, self.config.idle_in_transaction_timeout_ms);
        if (self.config.session_idle_timeout_ms > 0) shortest = @min(shortest, self.config.session_idle_timeout_ms);
        if (shortest == std.math.maxInt(u64)) return 30 * std.time.ms_per_s;
        return std.math.clamp(shortest / 4, 25, 30 * std.time.ms_per_s);
    }

    fn reaperMain(self: *SessionStore) void {
        const interval = self.reaperIntervalMs();
        while (!self.reaper_stop.load(.acquire)) {
            var waited: u64 = 0;
            while (waited < interval and !self.reaper_stop.load(.acquire) and self.pending_teardown_count.load(.acquire) == 0) : (waited += 25) {
                const req = std.os.linux.timespec{ .sec = 0, .nsec = 25 * std.time.ns_per_ms };
                std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
            }
            if (self.reaper_stop.load(.acquire)) break;
            // A pass counts as a handler for the shutdown drain
            // (`waitForGrpcInflightZero`): the teardown touches the store.
            _ = g_grpc_inflight.fetchAdd(1, .acq_rel);
            defer _ = g_grpc_inflight.fetchSub(1, .acq_rel);
            if (g_grpc_shutting_down.load(.acquire)) break;
            _ = self.reap(monoMillis());
        }
    }

    /// SONNY-3032: run the reaper on a thread of its own, until
    /// `stopReaper` (or `deinit`). Nothing to do when both timeouts are off.
    pub fn startReaper(self: *SessionStore) !void {
        if (self.reaper != null) return;
        // SONNY-3252: the cap's teardowns run on the reaper as well.
        if (self.config.idle_in_transaction_timeout_ms == 0 and self.config.session_idle_timeout_ms == 0 and self.config.max_sessions_per_principal == 0) return;
        self.reaper_stop.store(false, .release);
        self.reaper = try std.Thread.spawn(.{}, reaperMain, .{self});
    }

    pub fn stopReaper(self: *SessionStore) void {
        const t = self.reaper orelse return;
        self.reaper_stop.store(true, .release);
        t.join();
        self.reaper = null;
    }
};

/// Issue #514: Use atomic for session store pointer to prevent race on initialization.
/// CANARY: REQ=REQ-GRPC-ATOMIC-SESSION-001; FEATURE="GrpcSessionSafety"; ASPECT=AtomicPointer; STATUS=IMPL; OWNER=transport; UPDATED=2026-02-13
var g_session_store_atomic: std.atomic.Value(?*SessionStore) = std.atomic.Value(?*SessionStore).init(null);

/// Thread-safe getter for session store.
fn getSessionStore() ?*SessionStore {
    return g_session_store_atomic.load(.acquire);
}

/// Thread-safe setter for session store. `pub` as a SONNY-1221 test seam
/// only; production dispatch must go through `handlePacket`, and production
/// installs the store in `GeodeGrpcServer.init` (see SessionStore).
pub fn setSessionStore(store: ?*SessionStore) void {
    g_session_store_atomic.store(store, .release);
}

// ── gRPC shutdown drain (REQ-TRANSPORT-GRPC-SHUTDOWN-001/002) ───────────────
// gRPC request handlers run on threads the vendored grpc_zig accept loop
// DETACHES (its accept loop is `while (true)` + `Thread.detach`), so geode
// cannot join or cancel them. Without a geode-side drain, SIGTERM frees the
// global store (src/server/main.zig deinit defer) while a detached handler is
// still reading it — a use-after-free that panics with "incorrect alignment"
// inside graph_storage_adapter. This gate lets the shutdown path (a) refuse new
// handlers once shutdown has begun and (b) wait for the in-flight count to reach
// zero BEFORE the store is torn down. It mirrors the QUIC connection drain.
var g_grpc_shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_grpc_inflight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Begin gRPC shutdown: new handlers are refused from this instant.
pub fn requestGrpcShutdown() void {
    g_grpc_shutting_down.store(true, .release);
}

/// Number of gRPC handlers currently executing.
pub fn grpcInflightCount() u32 {
    return g_grpc_inflight.load(.acquire);
}

/// Block until no gRPC handler is executing, or until `timeout_ms` elapses.
/// Returns the residual in-flight count (0 on a clean drain). Bounded so a
/// long-running or stuck handler cannot hang shutdown forever.
pub fn waitForGrpcInflightZero(timeout_ms: u64) u32 {
    const start = compat_milliTimestamp();
    while (true) {
        const n = g_grpc_inflight.load(.acquire);
        if (n == 0) return 0;
        if (compat_milliTimestamp() - start >= @as(i64, @intCast(timeout_ms))) return n;
        // Use std.os.linux.timespec (NOT std.posix.timespec) to match the type
        // std.os.linux.nanosleep expects. std.posix.timespec resolves to
        // std.c.timespec when libc is linked (the OpenSSL-enabled release
        // cross-build), producing a timespec type mismatch that broke
        // v0.8.12 build-release (grpc_server.zig:353); the native/no-libc test
        // builds never linked libc so never saw it. Mirrors quic.zig
        // compat_sleepNs. std.Thread.sleep is unavailable in Zig 0.16.
        const req = std.os.linux.timespec{ .sec = 0, .nsec = 25 * std.time.ns_per_ms };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    }
}

fn initServerState(allocator: std.mem.Allocator, config: GrpcConfig) !*server_state.ServerState {
    const state = try allocator.create(server_state.ServerState);
    state.* = .{ .allocator = allocator };
    state.exec_session = execution.SessionState.init(allocator);
    state.telemetry_paging = if (getEnvVarOwned(allocator, "GEODE_TELEMETRY_PAGING")) |v| blk: {
        defer allocator.free(v);
        break :blk true;
    } else |_| false;
    state.txn_manager.init(allocator);
    state.inserted_values = .empty;
    state.catalog_schemas = std.HashMap([]const u8, server_state.CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    state.catalog_graphs = std.HashMap([]const u8, server_state.CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    state.graph_types = std.HashMap([]const u8, server_state.GraphTypeDefinition, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    state.query_mem_limit_bytes = config.spill_threshold;
    state.storage_checksum_error = config.storage_checksum_error;
    state.security_manager = config.security_manager;
    // GAP-0756: Wire the shared query optimizer so the gRPC handler hits the
    // cross-connection plan cache the same way the QUIC handler does.
    state.query_optimizer = config.shared_optimizer;
    state.query_optimizer_enabled = if (getEnvVarOwned(allocator, "GEODE_ENABLE_QUERY_OPTIMIZER")) |v| blk: {
        defer allocator.free(v);
        // Use consistent boolean parsing across transports (matches QUIC handler)
        if (v.len == 0) break :blk false;
        if (v[0] == '0') break :blk false;
        if (std.ascii.eqlIgnoreCase(v, "false")) break :blk false;
        if (std.ascii.eqlIgnoreCase(v, "off")) break :blk false;
        break :blk true;
    } else |_| false;
    return state;
}

fn deinitServerState(state: *server_state.ServerState) void {
    const alloc = state.allocator;
    // GAP-0285: Clear per-thread FLE state (tenant_id and role) to prevent stale
    // state from leaking into a subsequent request that reuses this thread.
    // CANARY: REQ=REQ-FLE-ROLE-ISOLATION-004; FEATURE="FLERoleIsolation"; ASPECT=GrpcCleanup; STATUS=IMPL; OWNER=security; UPDATED=2026-04-05
    fle_integration.clearCurrentThreadState();
    // GAP-0285: Also clear per-thread audit tenant_id.
    audit_mod.setCurrentAuditTenantId(null);
    if (state.fle_user_role) |r| {
        alloc.free(r);
        state.fle_user_role = null;
    }

    // CANARY: REQ=REQ-SONNY-2823-SESSION-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=GrpcTeardown; STATUS=TESTED; TEST=tests/test_sonny2823_session_engine_txn.zig; OWNER=storage; UPDATED=2026-09-26
    // SONNY-2823: a session that ends with a transaction open rolls it back,
    // and aborts its engine transaction, as QUIC's stream close does. Its
    // undo entries stayed in the log, and its engine transaction on a
    // worker thread.
    if (state.in_txn or state.session_engine_txn.open) state.rollBackTransaction(state.sessionGraph());
    state.resetResult();
    state.clearTxnGraph(); // SONNY-2776
    if (state.exec_session) |*sess| sess.deinit();
    // GAP-0289: Release per-tenant connection quota before freeing session config.
    if (state.session_config) |cfg| {
        if (cfg.tenant_id) |tid| {
            if (tenant_quota.getGlobalQuotaManager()) |qm| {
                qm.releaseConnection(tid);
            }
        }
    }
    if (state.session_config) |*cfg| cfg.deinit();
    if (state.authenticated_user) |u| alloc.free(u);
    if (state.authenticated_password) |p| {
        cb.secureZero(@constCast(p)); // SECURITY (S7): Zero plaintext password before freeing
        alloc.free(p);
    }
    state.txn_manager.deinit();
    for (state.inserted_values.items) |item| {
        alloc.free(item.value);
    }
    state.inserted_values.deinit(alloc);
    state.catalog_schemas.deinit();
    state.catalog_graphs.deinit();
    var gt_iter = state.graph_types.iterator();
    while (gt_iter.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        alloc.free(entry.value_ptr.name);
    }
    state.graph_types.deinit();
}

fn invalidateAuthenticatedSession(allocator: std.mem.Allocator, state: *server_state.ServerState) void {
    state.resetResult();
    // SONNY-2776: under the write lock of the graph the transaction changed
    // (`current_graph` is never set on gRPC, so this used to lock `default`).
    // SONNY-2799: the session's own undo transaction, whatever this thread's.
    // SONNY-2823: and its engine transaction.
    if (state.in_txn or state.session_engine_txn.open) state.rollBackTransaction(state.sessionGraph());
    state.endTransaction();
    state.current_user_id = null;
    if (state.authenticated_user) |u| {
        allocator.free(u);
        state.authenticated_user = null;
    }
    if (state.authenticated_password) |p| {
        cb.secureZero(@constCast(p));
        allocator.free(p);
        state.authenticated_password = null;
    }
    state.authenticated_role = null;
    state.authenticated_auth_version = 0;
    state.authenticated_auth_validation_epoch = 0;
    state.password_reset_required = false;
}

fn validateSessionAuth(allocator: std.mem.Allocator, state: *server_state.ServerState) !SessionAuthStatus {
    if (!user_mgmt.isAuthEnabled()) return .ok;
    const username = state.authenticated_user orelse return .missing;
    if (state.authenticated_auth_version == 0) return .ok;
    if (try user_mgmt.isSessionAuthCurrentCached(username, state.authenticated_auth_version, &state.authenticated_auth_validation_epoch)) {
        return .ok;
    }
    invalidateAuthenticatedSession(allocator, state);
    return .invalidated;
}

fn authorizeAdminSession(session_id: []const u8, allocator: std.mem.Allocator) !AdminSessionStatus {
    if (!user_mgmt.isAuthEnabled()) return .ok;
    if (session_id.len == 0) return .missing;
    const store = getSessionStore() orelse return .missing;
    const entry = store.acquire(session_id) orelse {
        throttleInvalidSessionProbe();
        return .missing;
    };
    // SONNY-3032: held for the request; the reaper closes only an unheld session.
    defer store.release(entry);

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;
    // SONNY-2799, SONNY-2823: the session's undo-log and engine transactions
    // are this thread's for the request, whichever worker thread serves it.
    const txn_scope = state.enterSessionTxn();
    defer state.leaveSessionTxn(txn_scope);

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        .missing => return .missing,
        .invalidated => return .invalidated,
    }

    const role_raw = state.authenticated_role orelse return .forbidden;
    const role = @as(user_mgmt.Role, @enumFromInt(role_raw));
    if (role != .Admin) return .forbidden;
    if (state.authenticated_user == null) return .missing;
    return .ok;
}

/// SONNY-2729: the RLS post-filter could not run and withheld every row;
/// the request is answered with its error instead of the rows.
fn postFilterErrorResponse(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    const info = proto_util.mapError(err);
    var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
    defer resp.deinit(allocator);
    return encodeMessage(allocator, resp);
}

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
fn whereHasIndexedEq(root: gql_ast.Expr, var_name: []const u8, label: []const u8, cat: anytype) bool {
    // SONNY-3189: down an AND chain with a loop, not one recursion (and one
    // copy of the expression) per AND: EXPLAIN reaches this before
    // authorization.
    var at: *const gql_ast.Expr = &root;
    while (at.* == .Binary and at.Binary.op == .And) {
        if (whereHasIndexedEq(at.Binary.right.*, var_name, label, cat)) return true;
        at = at.Binary.left;
    }
    const where_expr = at.*;
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

// CANARY: REQ=REQ-SONNY-2805-TXN-PROGRAM-ORDER; FEATURE="TransactionManagement"; ASPECT=GrpcHandler; STATUS=TESTED; TEST=tests/test_sonny2805_txn_sessions.zig; OWNER=engine; UPDATED=2026-09-26
/// Track the session's transaction after `program` ran. SONNY-2776:
/// `write_graph` is the graph the program changed (null if it changed none);
/// the first graph an open transaction changes becomes its graph.
///
/// SONNY-2805: the statements are followed in program order, as the executor
/// ran them. A COMMIT or ROLLBACK used to end the transaction whatever came
/// after it: after `COMMIT; START TRANSACTION; ...` the handler had no
/// transaction and the executor had begun one, so the next change of another
/// graph escaped the one-graph rule, and the client's ROLLBACK did nothing.
/// The transaction's id is the undo log's (`ServerState.leaveSessionTxn`). A
/// transaction the handler holds and the undo log does not is begun, so its
/// changes are recorded.
fn updateTxnStateFromProgram(state: *server_state.ServerState, program: *const gql_ast.Program, write_graph: ?[]const u8) void {
    for (program.statements) |*stmt| noteTxnStatement(state, stmt, write_graph);
    if (state.in_txn and txn_undo_log.currentThreadTxnId() == 0) txn_undo_log.getGlobalUndoLog(state.allocator).begin();
}

fn noteTxnStatement(state: *server_state.ServerState, stmt: *const gql_ast.Statement, write_graph: ?[]const u8) void {
    switch (stmt.*) {
        .StartTransaction => |st| {
            if (st.body == null and !state.in_txn) {
                state.clearTxnGraph();
                state.in_txn = true;
            }
        },
        .Commit, .Rollback => state.endTransaction(),
        // SONNY-3026: a PROFILE ran the statement it wraps (the handler
        // refuses one of transaction control; this keeps the bookkeeping
        // honest anyway). An EXPLAIN ran nothing.
        .Profile => |p| noteTxnStatement(state, p.query, write_graph),
        .Explain => {},
        else => if (state.in_txn and query_traits.isMutatingStatement(stmt)) {
            // A failed allocation leaves the transaction without a graph; its
            // end then locks the session's graph, as before SONNY-2776.
            if (write_graph) |g| state.noteTxnWrite(g) catch {};
        },
    }
}

// CANARY: REQ=REQ-SONNY-2799-FAILED-TXN-ROLLBACK; FEATURE="TransactionManagement"; ASPECT=GrpcHandler; STATUS=TESTED; TEST=tests/test_sonny2805_txn_sessions.zig; OWNER=engine; UPDATED=2026-09-26
/// SONNY-2799: after a request whose execution failed. If the undo log's
/// transaction is still open on this thread, the executor failed it
/// (GAP-0917) and left the undo to the handler (`defer_failed_txn_rollback`):
/// roll it back, under the write lock of the graph it changed (or
/// `request_graph`, the graph the request ran on). The request's own lock is
/// released by now. If the handler thought a transaction open that the
/// executor ended (a ROLLBACK before the failure), end it.
fn abortFailedTransaction(state: *server_state.ServerState, request_graph: []const u8, ended_txn: bool) void {
    const open = txn_undo_log.currentThreadTxnId();
    if (open != 0) {
        state.txn_id = open;
        state.rollBackTransaction(request_graph);
        // SONNY-3348 (round 18, I2): and the session stays in the aborted
        // transaction until the client ends it (`query_traits.abortedTxnVerdict`),
        // unless the program itself ended it last (`ended_txn`: a COMMIT that
        // failed, which rolls back).
        state.txn_aborted = !ended_txn;
    } else if (state.in_txn) {
        state.endTransaction();
    }
}

/// SONNY-3348 (round 19, m5): the error a failed COMMIT or ROLLBACK message
/// carries: the code the statement form answers.
fn txnEndError(err: anyerror) schema.Error {
    const info = proto_util.mapError(err);
    return .{ .code = info.code, .message = info.message };
}

/// SONNY-3348 (round 19, m3): ROLLBACK's answer: success, or 40003 when the
/// rollback could not undo every change.
fn rollbackResponse(incomplete: bool) schema.RollbackResponse {
    if (!incomplete) return .{ .success = true };
    return .{ .success = false, .@"error" = txnEndError(error.RollbackIncomplete) };
}

/// SONNY-3348 (round 19, m2): a streamed statement that fails at a later
/// PULL page fails its explicit transaction (aborted until ROLLBACK or
/// COMMIT), as a failure in its first page does. The stream is gone and
/// holds no lock.
fn abortTxnAfterPullFailure(state: *server_state.ServerState) void {
    if (!state.in_txn) return;
    abortFailedTransaction(state, state.sessionGraph(), false);
}

fn encodeMessage(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch return error.OutOfMemory;
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    const result = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    return result;
}

pub const GeodeGrpcServer = struct {
    allocator: std.mem.Allocator,
    server: GrpcServer,
    session_store: *SessionStore,
    /// GAP-0518: Heap-allocated random session key (freed in deinit).
    grpc_session_key: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        cert_path: ?[]const u8,
        key_path: ?[]const u8,
        config: GrpcConfig,
    ) !GeodeGrpcServer {
        // GAP-0518: Generate a random session key per startup instead of a
        // hardcoded literal.  The 32-byte key is hex-encoded (64 chars) and
        // heap-allocated so it lives as long as the server.
        var grpc_session_key_raw: [32]u8 = undefined;
        try cb.Csprng.bytes(&grpc_session_key_raw);
        const grpc_session_key = try allocator.alloc(u8, 64);
        const hex_array = std.fmt.bytesToHex(grpc_session_key_raw, .lower);
        @memcpy(grpc_session_key, &hex_array);
        var server = try GrpcServer.init(allocator, std.Io.Threaded.global_single_threaded.io(), port, grpc_session_key);
        const allow_plaintext_fallback = shouldAllowGrpcPlaintextFallback(allocator);

        if (allow_plaintext_fallback) {
            server.on_tls_accept = grpc_tls.rawAccept;
            log.warn("gRPC plaintext enabled in Debug mode via GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK", &.{});
        }

        // Initialize TLS if cert and key are provided and plaintext mode is not forced.
        if (server.on_tls_accept == null) {
            if (cert_path) |cp| {
                if (key_path) |kp| {
                    // Create null-terminated strings for OpenSSL
                    const cert_z = try allocator.dupeZ(u8, cp);
                    defer allocator.free(cert_z);
                    const key_z = try allocator.dupeZ(u8, kp);
                    defer allocator.free(key_z);

                    grpc_tls.initTlsContext(cert_z, key_z) catch |err| {
                        if (!allow_plaintext_fallback) {
                            log.err("gRPC TLS init failed; refusing plaintext fallback", &.{
                                Attr.string("error", @errorName(err)),
                            });
                            return err;
                        }
                        log.warn("gRPC TLS init failed; plaintext fallback explicitly enabled", &.{
                            Attr.string("error", @errorName(err)),
                        });
                    };
                    if (grpc_tls.hasTlsContext()) {
                        server.on_tls_accept = grpc_tls.tlsAccept;
                        log.info("gRPC TLS enabled", &.{});
                    }
                }
            }
        }

        // Fail-closed by default: plaintext fallback requires explicit opt-in.
        if (server.on_tls_accept == null and allow_plaintext_fallback) {
            server.on_tls_accept = grpc_tls.rawAccept;
            log.warn("gRPC plaintext fallback enabled in Debug mode", &.{});
        } else if (server.on_tls_accept == null) {
            return error.TlsRequired;
        }

        const store = try allocator.create(SessionStore);
        store.* = SessionStore.init(allocator, config);
        setSessionStore(store);

        var self = GeodeGrpcServer{
            .allocator = allocator,
            .server = server,
            .session_store = store,
            .grpc_session_key = grpc_session_key,
        };

        try self.registerHandlers();
        return self;
    }

    pub fn deinit(self: *GeodeGrpcServer) void {
        self.session_store.deinit();
        self.allocator.destroy(self.session_store);
        setSessionStore(null);
        grpc_tls.deinitTlsContext();
        // GAP-0518: Securely zero and free the random session key.
        if (self.grpc_session_key) |key| {
            cb.secureZero(key);
            self.allocator.free(key);
        }
        self.server.deinit();
    }

    pub fn start(self: *GeodeGrpcServer) !void {
        log.info("Starting gRPC server", &.{});
        // SONNY-3032: close sessions idle too long (`SessionStore.reap`).
        self.session_store.startReaper() catch |err| {
            log.err("gRPC session reaper failed to start: idle sessions and transactions are not closed", &.{Attr.string("error", @errorName(err))});
        };
        try self.server.start();
    }

    /// Fully-qualified gRPC method paths served by `handlePacket`.
    ///
    /// grpc-zig dispatches by exact `Handler.name` == `:path` match, so every
    /// method the packet wrapper understands must be registered under its
    /// full `/geode.GeodeService/<Method>` path. Anything absent gets a
    /// `grpc-status: 12` (UNIMPLEMENTED) trailer from the vendor listener
    /// before `handlePacket` is ever reached. Keep this list in sync with the
    /// suffix dispatch in `handlePacket` and with `src/proto/geode.proto`.
    const method_paths = [_][]const u8{
        "/geode.GeodeService/Handshake",
        "/geode.GeodeService/Execute",
        "/geode.GeodeService/Ping",
        "/geode.GeodeService/Begin",
        "/geode.GeodeService/Commit",
        "/geode.GeodeService/Rollback",
        "/geode.GeodeService/Savepoint",
        "/geode.GeodeService/RollbackTo",
        "/geode.GeodeService/CdcDiag",
        "/geode.GeodeService/CdcCtrl",
        "/geode.GeodeService/Backup",
        "/geode.GeodeService/Restore",
        "/geode.GeodeService/UploadBackup",
    };

    fn registerHandlers(self: *GeodeGrpcServer) !void {
        for (method_paths) |path| {
            try self.server.handlers.append(self.allocator, .{
                .name = path,
                .handler_fn = handlePacket,
            });
        }
    }
};

fn buildPacketError(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    var resp = try buildErrorResponse(allocator, code, message, &.{}, &.{});
    defer resp.deinit(allocator);
    var packet = schema.ServerPacket{ .quic = .{ .execute = resp } };
    defer packet.deinit(allocator);
    return encodeMessage(allocator, packet);
}

/// Helper: send a unary gRPC response (HEADERS + DATA + TRAILERS).
fn sendUnaryResponse(trans: *GrpcTransport, response: []const u8) !void {
    try trans.writeMessage(response);
}

/// Helper: send a streaming gRPC response message.
fn sendStreamResponse(trans: *GrpcTransport, response: []const u8, is_first: bool) !void {
    try trans.writeStreamMessage(response, is_first);
}

fn handlePacket(request_bytes: []const u8, method: []const u8, trans: *GrpcTransport, allocator: std.mem.Allocator) anyerror!void {
    // gRPC shutdown drain (REQ-TRANSPORT-GRPC-SHUTDOWN-001/002): register this
    // handler so the shutdown path can wait for it before freeing the store, and
    // refuse new work once shutdown has begun so a late request cannot race the
    // teardown. Increment BEFORE the flag check so a handler admitted just
    // before the flag flips is always counted by the drain.
    _ = g_grpc_inflight.fetchAdd(1, .acq_rel);
    defer _ = g_grpc_inflight.fetchSub(1, .acq_rel);
    if (g_grpc_shutting_down.load(.acquire)) {
        // Refuse cleanly instead of touching the (about-to-be-freed) store.
        const err_resp = try buildPacketError(allocator, "57P01", "Server is shutting down");
        defer allocator.free(err_resp);
        return sendUnaryResponse(trans, err_resp);
    }

    log.info("gRPC dispatch", &.{
        Attr.string("method", if (method.len > 0) method else "(empty)"),
        Attr.uint("payload_len", request_bytes.len),
    });

    // Standard gRPC: route by method path from HEADERS frame.
    if (method.len > 0) {
        if (std.mem.endsWith(u8, method, "/Handshake")) {
            const resp = try handleHandshake(request_bytes, trans, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Execute")) {
            return handleExecuteStreaming(request_bytes, trans, allocator);
        } else if (std.mem.endsWith(u8, method, "/Ping")) {
            const resp = try handlePing(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Begin")) {
            const resp = try handleBegin(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Commit")) {
            const resp = try handleCommit(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Rollback")) {
            const resp = try handleRollback(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Savepoint")) {
            // Issue #515: Savepoint handler (stub — matches QUIC behavior)
            const resp = try handleSavepoint(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/RollbackTo")) {
            const resp = try handleRollbackTo(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/CdcDiag")) {
            const resp = try handleCdcDiag(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/CdcCtrl")) {
            const resp = try handleCdcCtrl(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Backup")) {
            const resp = try handleBackup(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Restore")) {
            const resp = try handleRestore(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/UploadBackup")) {
            const resp = try handleUploadBackup(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else {
            log.warn("Unknown gRPC method", &.{});
            const err_resp = try buildPacketError(allocator, "0A000", "Unknown gRPC method");
            defer allocator.free(err_resp);
            return sendUnaryResponse(trans, err_resp);
        }
    }

    // Fallback: legacy ClientPacket-wrapped messages (custom gRPC clients)
    const resp = try handleLegacyPacket(request_bytes, trans, allocator);
    defer allocator.free(resp);
    return sendUnaryResponse(trans, resp);
}

/// Build a data page ExecutionResponse directly (avoids decode+re-encode cycle).
/// Returns encoded ExecutionResponse bytes and whether this is the final page.
const PageResult = struct { bytes: []u8, is_final: bool };
const grpc_stream_page_size: usize = query_runner.default_page_size;

fn buildStreamDataPage(session_id: []const u8, allocator: std.mem.Allocator) !PageResult {
    const store = getSessionStore() orelse {
        var resp = try buildErrorResponse(allocator, "58000", "Server not initialized", &.{}, &.{});
        defer resp.deinit(allocator);
        return .{ .bytes = try encodeMessage(allocator, resp), .is_final = true };
    };

    const entry = store.acquire(session_id) orelse {
        throttleInvalidSessionProbe();
        var resp = try buildErrorResponse(allocator, "28000", "Unknown session", &.{}, &.{});
        defer resp.deinit(allocator);
        return .{ .bytes = try encodeMessage(allocator, resp), .is_final = true };
    };
    // SONNY-3032: held for the request; the reaper closes only an unheld session.
    defer store.release(entry);

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;
    // SONNY-2799, SONNY-2823: the session's undo-log and engine transactions
    // are this thread's for the request, whichever worker thread serves it.
    const txn_scope = state.enterSessionTxn();
    defer state.leaveSessionTxn(txn_scope);
    // SONNY-6334: the session's request context (tenant, FLE role,
    // decrypt_field gate) on this thread for the request, as QUIC does.
    state.installRequestThreadState();
    defer server_state.ServerState.clearRequestThreadState();

    const result_ptr = if (state.active_result_values) |*res| res else {
        var resp = try buildErrorResponse(allocator, "02000", "No active result set", &.{}, &.{});
        defer resp.deinit(allocator);
        return .{ .bytes = try encodeMessage(allocator, resp), .is_final = true };
    };

    const start = state.result_page_index;

    // Arena allocator for data page serialization (Issue #446):
    // Per-value string dups become bump allocations; arena bulk-frees after encode.
    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();
    const pa = page_arena.allocator();

    const page = try proto_util.buildDataPage(pa, result_ptr, start, grpc_stream_page_size, state.result_ordered, state.result_order_keys);
    state.result_page_index += page.rows.items.len;
    const is_final = page.final;

    const status = try proto_util.buildStatus(pa, "00000", result_ptr.flags.items);
    const resp = schema.ExecutionResponse{
        .status = status,
        .payload = .{ .page = page },
    };
    // resp.deinit not needed: arena handles all proto object memory

    const encoded_tmp = try encodeMessage(pa, resp);
    const encoded = try allocator.dupe(u8, encoded_tmp);

    if (is_final) {
        state.resetResult();
    }

    return .{ .bytes = encoded, .is_final = is_final };
}

/// Issue #514: Lock-free variant that operates on an already-locked state pointer.
/// Caller MUST hold entry.mutex for the entire streaming loop.
fn buildStreamDataPageLocked(state: *server_state.ServerState, allocator: std.mem.Allocator) !PageResult {
    // SONNY-6334: the page encodes FLE fields as the session may read them.
    state.installRequestThreadState();
    defer server_state.ServerState.clearRequestThreadState();
    const result_ptr = if (state.active_result_values) |*res| res else {
        var resp = try buildErrorResponse(allocator, "02000", "No active result set", &.{}, &.{});
        defer resp.deinit(allocator);
        return .{ .bytes = try encodeMessage(allocator, resp), .is_final = true };
    };

    const start = state.result_page_index;

    // Arena allocator for data page serialization (Issue #446)
    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();
    const pa = page_arena.allocator();

    const page = try proto_util.buildDataPage(pa, result_ptr, start, grpc_stream_page_size, state.result_ordered, state.result_order_keys);
    state.result_page_index += page.rows.items.len;
    const is_final = page.final;

    const status = try proto_util.buildStatus(pa, "00000", result_ptr.flags.items);
    const resp = schema.ExecutionResponse{
        .status = status,
        .payload = .{ .page = page },
    };

    const encoded_tmp = try encodeMessage(pa, resp);
    const encoded = try allocator.dupe(u8, encoded_tmp);

    if (is_final) {
        state.resetResult();
    }

    return .{ .bytes = encoded, .is_final = is_final };
}

// ── SONNY-1560: bounded, lock-free-between-pages pushed-result drain ────────
//
// grpc-zig 0.1.8 DOES honour HTTP/2 WINDOW_UPDATE: every outbound DATA write
// goes through `Transport.reserveSendCredit`
// (grpc_zig/src/transport.zig:1017), which blocks until the connection AND
// per-stream send windows both have headroom, and `processWindowUpdate`
// (grpc_zig/src/transport.zig:935) credits those windows back.
//
// What it does NOT do is read the socket while a handler is writing. The
// server runs one thread per connection (grpc_zig/src/server.zig:319) and that
// thread's loop is `readMessage()` -> `handler_fn()`
// (grpc_zig/src/server.zig:361/471). The ONLY server-side WINDOW_UPDATE
// dispatch sits inside `readMessageCore` (grpc_zig/src/transport.zig:1547), so
// while this handler is pushing pages nobody is draining the socket and the
// peer's WINDOW_UPDATE cannot be processed. Once the advertised 1 MiB initial
// window (grpc_zig/src/transport.zig:88) is consumed the writer parks in the
// futex at grpc_zig/src/transport.zig:1076 until `flow_credit_timeout_ns`
// (30 s default, grpc_zig/src/transport.zig:457) expires and the library emits
// RST_STREAM(FLOW_CONTROL_ERROR). That is the 30 s stall SONNY-1560 observed.
//
// The engine cannot fix the missing reader thread (see the report's
// "SONNY-1560 library half"). What it CAN do, and now does:
//
//   1. Never hold the session mutex across a page write, so a stalled or
//      abandoned stream cannot block the next Execute on that session.
//   2. Probe the peer's remaining send window BEFORE each write and refuse to
//      enter a wait it knows cannot be satisfied, turning a silent 30 s stall
//      into an immediate, classified RESOURCE_EXHAUSTED.
//   3. Release the session's cursor deterministically on every abandonment.

/// gRPC status code (https://grpc.io/docs/guides/status-codes/) used when the
/// peer's flow-control window cannot accept the next page.
const grpc_status_resource_exhausted: u8 = 8;

/// Static, identifier-free trailer text for a stream abandoned mid-push.
/// MUST stay under 128 bytes: `Transport.endStreamWithStatus`
/// (grpc_zig/src/transport.zig:2237) truncates past a 7-bit HPACK prefix.
const stream_window_exhausted_message: []const u8 =
    "stream window exhausted: peer stopped draining the pushed result";

/// Safety bound on pages pushed for one Execute (pre-existing limit, kept).
const max_pushed_pages: usize = 1000;

/// Per-message gRPC length-prefix width that `Transport.writeStreamMessage`
/// (grpc_zig/src/transport.zig:2192) adds before reserving send credit.
const grpc_message_prefix_len: usize = 5;

// SONNY-1560 seam pin. The window probe below reaches into grpc-zig's
// flow-control state because the library exposes no accessor for it (the
// report's §4 secondary ask is
// `pub fn availableSendWindow(self: *Transport, stream_id: u31) i32`). These
// assertions fail the BUILD -- not a test, not production -- if a library
// upgrade renames or retypes any part of that seam, so the mirroring below can
// never drift silently.
comptime {
    // (a) The exhaustion signal. `Transport.writeStreamMessage`
    //     (grpc_zig/src/transport.zig:2192) surfaces this verbatim from
    //     `reserveSendCreditOrRst` (:2205 -> :1100), whose error set is
    //     `reserveSendCredit`'s explicit one (:1017).
    const ReserveErr = @typeInfo(@typeInfo(@TypeOf(GrpcTransport.reserveSendCredit)).@"fn".return_type.?).error_union.error_set;
    const reserve_errs = @typeInfo(ReserveErr).error_set orelse
        @compileError("SONNY-1560: grpc-zig's reserveSendCredit no longer has an explicit error set; re-pin the exhaustion classification in pushResultPages");
    var has_flow_control_timeout = false;
    for (reserve_errs) |e| {
        if (std.mem.eql(u8, e.name, "FlowControlTimeout")) has_flow_control_timeout = true;
    }
    if (!has_flow_control_timeout) @compileError(
        "SONNY-1560: grpc-zig no longer signals error.FlowControlTimeout from reserveSendCredit; " ++
            "pushResultPages' window-exhaustion classification must be re-pinned",
    );

    // (b) The flow-control state `peerSendWindow` reads directly. `@FieldType`
    //     itself fails the build if a field is renamed away.
    if (@FieldType(GrpcTransport, "flow_mutex") != std.Io.Mutex)
        @compileError("SONNY-1560: grpc-zig's Transport.flow_mutex changed type; re-pin peerSendWindow");
    if (@FieldType(GrpcTransport, "conn_send_window") != i32)
        @compileError("SONNY-1560: grpc-zig's Transport.conn_send_window changed type; re-pin peerSendWindow");
    if (@FieldType(GrpcTransport, "stream_send_windows") != []i32)
        @compileError("SONNY-1560: grpc-zig's Transport.stream_send_windows changed type; re-pin peerSendWindow");
    if (@FieldType(GrpcTransport, "last_stream_id") != u31)
        @compileError("SONNY-1560: grpc-zig's Transport.last_stream_id changed type; re-pin peerSendWindow");
}

/// Octets the library will reserve send credit for when handing `message_len`
/// payload bytes to `Transport.writeStreamMessage`
/// (grpc_zig/src/transport.zig:2192-2196: it prefixes the 5-byte gRPC header
/// and reserves for the whole framed message in one call).
fn framedMessageLen(message_len: usize) i64 {
    return @intCast(message_len + grpc_message_prefix_len);
}

/// SONNY-1560: peer send-window headroom for `sid`, in octets.
///
/// THE ONE PLACE that mirrors grpc-zig's own effective-window rule, taken from
/// `reserveSendCredit` (grpc_zig/src/transport.zig:1017-1033):
///
///   * the effective window is `@min(conn_send_window, <stream window>)`;
///   * stream id 0, and any id at or past the tracked-stream bound
///     (`MAX_TRACKED_STREAMS` = the length of `stream_send_windows`,
///     grpc_zig/src/transport.zig:94/:426-431), are gated on the CONNECTION
///     window only -- the library treats the per-stream window as unbounded
///     there, and so must we, or we would refuse writes the library would
///     happily make.
///
/// Read under the library's own `flow_mutex` so the value is consistent with
/// what the next `reserveSendCredit` will see. Still ADVISORY: the lock is
/// released before the write, so the library's reservation remains the
/// authoritative gate (report §7.4).
fn peerSendWindow(trans: *GrpcTransport, sid: u31) i64 {
    trans.flow_mutex.lockUncancelable(trans.io);
    defer trans.flow_mutex.unlock(trans.io);
    const idx: usize = @intCast(sid);
    const stream_avail: i32 = if (sid != 0 and idx < trans.stream_send_windows.len)
        trans.stream_send_windows[idx]
    else
        std.math.maxInt(i32);
    return @min(trans.conn_send_window, stream_avail);
}

/// SONNY-1560: how a pushed-result drain ended. Every non-`complete` outcome
/// has already released the session's cursor.
pub const PushOutcome = enum {
    /// Final page produced and handed to the peer; the result set is drained.
    complete,
    /// A newer Execute replaced this session's result mid-push. This stream
    /// stopped without reading, freeing, or paging the newer result.
    superseded,
    /// The session had no active result set to push.
    no_result,
    /// Page materialisation failed.
    build_failed,
    /// The peer's stream write failed (client gone, connection broken).
    write_failed,
    /// The peer's flow-control window cannot accept the next page. Classified
    /// to the caller as RESOURCE_EXHAUSTED rather than waited out.
    window_exhausted,
    /// The per-Execute page bound was hit before the result drained.
    page_limit,
};

/// SONNY-1560: sink for pushed result pages. Production wraps the vendored
/// grpc-zig transport; the regression suite substitutes a stub that stalls,
/// abandons, or reports a bounded window.
pub const PageSink = struct {
    ctx: *anyopaque,
    /// Hand one encoded `ExecutionResponse` to the peer as a stream message.
    /// There is deliberately no `is_first` parameter: the schema/HEADERS write
    /// is issued by `handleExecuteStreaming` before the drain begins, so every
    /// page pushed through this seam is a continuation.
    writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
    /// Octets the peer will currently accept on this stream. `null` means the
    /// sink cannot report a window and writes are treated as unbounded.
    windowFn: ?*const fn (ctx: *anyopaque) i64 = null,
    /// Emit a loud, classified terminal status for an abandoned stream.
    failFn: ?*const fn (ctx: *anyopaque, code: u8, message: []const u8) void = null,

    fn write(self: PageSink, bytes: []const u8) anyerror!void {
        return self.writeFn(self.ctx, bytes);
    }

    fn window(self: PageSink) ?i64 {
        const f = self.windowFn orelse return null;
        return f(self.ctx);
    }

    fn fail(self: PageSink, code: u8, message: []const u8) void {
        const f = self.failFn orelse return;
        f(self.ctx, code, message);
    }
};

/// Release a session's result set, but only while this stream still owns it.
///
/// Bumping the epoch makes the release visible to any other claimant and makes
/// a second release by the same stream a no-op. A stream that was superseded
/// leaves the newer result completely alone.
fn releaseClaimedResult(entry: *SessionEntry, claimed_epoch: u64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    entry.mutex.lockUncancelable(io);
    defer entry.mutex.unlock(io);
    if (entry.result_epoch != claimed_epoch) return;
    entry.state.resetResult();
    entry.result_epoch +%= 1;
}

/// SONNY-1560: drain `entry`'s active result set to `sink`, one page at a time.
///
/// Locking contract — the whole point of this function:
///   * `entry.mutex` is held ONLY while a page is materialised
///     (`buildStreamDataPageLocked` advances the cursor and copies the encoded
///     bytes out of the arena into caller-owned memory).
///   * `entry.mutex` is NOT held while the page is written to the peer.
///   * After every unlocked write the claimed epoch is re-validated, so a
///     concurrent Execute that reset the result while we were writing is
///     detected instead of being paged over. This preserves the Issue #514
///     invariant (`active_result_values` is only ever read, written, or freed
///     under `entry.mutex`) without the Issue #514 whole-loop lock.
///
/// CANARY: REQ=REQ-TRANSPORT-GRPC-PUSH-UNLOCKED-001; FEATURE="GrpcSessionSafety"; ASPECT=PushLoopLockScope; STATUS=TESTED; TEST=tests/test_sonny1560_grpc_flow_control.zig; OWNER=transport; UPDATED=2026-09-14
/// Mirrors the QUIC push loop's ownership invariant
/// (src/server/quic_connection_handler.zig:7729-7743), where the pushed result
/// is stream-local and therefore never blocks another statement on the session.
pub fn pushResultPages(
    entry: *SessionEntry,
    claimed_epoch: u64,
    sink: PageSink,
    allocator: std.mem.Allocator,
) PushOutcome {
    const io = std.Io.Threaded.global_single_threaded.io();

    var page_count: usize = 0;
    while (page_count < max_pushed_pages) : (page_count += 1) {
        // ── produce one page: session lock held for this block ONLY ─────────
        entry.mutex.lockUncancelable(io);

        if (entry.result_epoch != claimed_epoch) {
            entry.mutex.unlock(io);
            log.warn("gRPC streaming: result superseded by a newer statement", &.{
                Attr.uint("page", page_count),
            });
            return .superseded;
        }
        if (entry.state.active_result_values == null) {
            entry.mutex.unlock(io);
            return .no_result;
        }

        const page = buildStreamDataPageLocked(entry.state, allocator) catch |err| {
            entry.mutex.unlock(io);
            log.err("gRPC streaming: failed to build data page", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("page", page_count),
            });
            releaseClaimedResult(entry, claimed_epoch);
            return .build_failed;
        };

        entry.mutex.unlock(io);
        // ── hand the page to the peer: NO session lock held ─────────────────
        defer allocator.free(page.bytes);

        // Bound the write by the peer's advertised window instead of parking in
        // `reserveSendCredit` for `flow_credit_timeout_ns`. A page that does not
        // fit cannot be made to fit from here: this handler owns the connection
        // thread, so the peer's WINDOW_UPDATE cannot be read until we return.
        if (sink.window()) |avail| {
            if (avail < framedMessageLen(page.bytes.len)) {
                log.err("gRPC streaming: peer flow-control window cannot accept the next page", &.{
                    Attr.uint("page", page_count),
                    Attr.uint("page_bytes", page.bytes.len),
                });
                sink.fail(grpc_status_resource_exhausted, stream_window_exhausted_message);
                releaseClaimedResult(entry, claimed_epoch);
                return .window_exhausted;
            }
        }

        sink.write(page.bytes) catch |err| {
            log.err("gRPC streaming: write failed mid-stream", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("page", page_count),
            });
            releaseClaimedResult(entry, claimed_epoch);
            // Typed, not a name compare: the seam pin above asserts at COMPILE
            // time that the library still signals this error, so a rename in
            // grpc-zig fails the build rather than silently downgrading this
            // branch to `.write_failed`.
            return switch (err) {
                // The library's `reserveSendCreditOrRst`
                // (grpc_zig/src/transport.zig:1100) has ALREADY emitted
                // RST_STREAM(FLOW_CONTROL_ERROR) for this stream before
                // surfacing the error, so the stream is closed at the peer.
                // Writing a trailer HEADERS frame now would be a RFC 7540 §5.1
                // STREAM_CLOSED violation and would race a second, conflicting
                // status against the RST. The RST is the terminal signal:
                // classify the outcome, say nothing more on the wire.
                // (Contrast the pre-write probe above, which sends no RST and
                // therefore MUST supply the trailer itself.)
                error.FlowControlTimeout => .window_exhausted,
                else => .write_failed,
            };
        };

        if (page.is_final) return .complete;
    }

    log.err("gRPC streaming: page bound reached before the result drained", &.{
        Attr.uint("pages", max_pushed_pages),
    });
    releaseClaimedResult(entry, claimed_epoch);
    return .page_limit;
}

/// SONNY-1560: `PageSink` backed by the vendored grpc-zig transport.
const TransportSink = struct {
    trans: *GrpcTransport,

    fn writeThunk(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *TransportSink = @ptrCast(@alignCast(ctx));
        // Never `is_first`: the HEADERS-bearing schema write is already out by
        // the time the drain starts.
        return sendStreamResponse(self.trans, bytes, false);
    }

    /// Peer send-window headroom for the stream currently being served.
    /// Delegates to `peerSendWindow`, the single place that mirrors the
    /// library's tracked-stream fallback rule.
    fn windowThunk(ctx: *anyopaque) i64 {
        const self: *TransportSink = @ptrCast(@alignCast(ctx));
        return peerSendWindow(self.trans, self.trans.last_stream_id);
    }

    fn failThunk(ctx: *anyopaque, code: u8, message: []const u8) void {
        const self: *TransportSink = @ptrCast(@alignCast(ctx));
        self.trans.endStreamWithStatus(self.trans.last_stream_id, code, message) catch {};
    }

    fn sink(self: *TransportSink) PageSink {
        return .{
            .ctx = @ptrCast(self),
            .writeFn = writeThunk,
            .windowFn = windowThunk,
            .failFn = failThunk,
        };
    }
};

/// Handle Execute as a server-streaming RPC: send schema, then all data pages.
/// Issue #479: Added error recovery to prevent leaving HTTP/2 streams in an
/// inconsistent state when writes fail (e.g. client disconnect, partial write).
fn handleExecuteStreaming(request_bytes: []const u8, trans: *GrpcTransport, allocator: std.mem.Allocator) !void {
    // Get the schema/first response from handleExecute. `claimed_epoch` is the
    // session result generation this Execute installed (SONNY-1560); the push
    // loop below re-validates it after every unlocked write.
    var claimed_epoch: u64 = 0;
    const exec_resp = try handleExecute(request_bytes, allocator, &claimed_epoch);
    defer allocator.free(exec_resp);

    // SONNY-1560: probe the initial schema write the same way the page writes
    // are probed. Without this it is still possible to park here for the
    // library's 30 s `flow_credit_timeout_ns` -- a pipelined request arriving
    // on a connection whose window a previous response already drained, from a
    // peer that never credits it back, cannot be satisfied from inside this
    // handler (it owns the connection thread, so no WINDOW_UPDATE can be read
    // until it returns). Probing is preferred over documenting the residual
    // because it is the same advisory read the loop already performs and it
    // turns the last remaining 30 s stall into an immediate, classified status.
    if (peerSendWindow(trans, trans.last_stream_id) < framedMessageLen(exec_resp.len)) {
        log.err("gRPC streaming: peer flow-control window cannot accept the initial response", &.{
            Attr.uint("response_bytes", exec_resp.len),
        });
        // No RST has been emitted on this path (nothing was written), so this
        // handler owes the peer the terminal status.
        trans.endStreamWithStatus(
            trans.last_stream_id,
            grpc_status_resource_exhausted,
            stream_window_exhausted_message,
        ) catch {};
        // The session's result set is deliberately left installed, matching the
        // pre-existing initial-write-failure path below: not one page was
        // pushed, so a follow-up Pull can still retrieve the whole result.
        return;
    }

    // Send first streaming message (with HEADERS).
    // If this fails, the connection is broken — propagate the error so the
    // connection loop can detect it and close cleanly.
    sendStreamResponse(trans, exec_resp, true) catch |err| {
        log.err("gRPC streaming: failed to send initial response", &.{
            Attr.string("error", @errorName(err)),
        });
        return err;
    };

    // Check if the response is EXPLAIN, PROFILE, or error — these have no data pages to pull
    var skip_pages = false;
    blk: {
        var resp_reader: std.Io.Reader = .fixed(exec_resp);
        var resp = protobuf.decode(schema.ExecutionResponse, &resp_reader, allocator) catch {
            skip_pages = true;
            break :blk;
        };
        defer resp.deinit(allocator);
        if (resp.payload) |payload| {
            switch (payload) {
                .explain, .profile, .@"error" => {
                    skip_pages = true;
                },
                else => {},
            }
        }
    }

    if (!skip_pages) {
        // Extract session_id from the request for data pages
        var reader: std.Io.Reader = .fixed(request_bytes);
        var req = protobuf.decode(schema.ExecuteRequest, &reader, allocator) catch {
            trans.endStream() catch {};
            return;
        };
        defer req.deinit(allocator);

        const store = getSessionStore() orelse {
            trans.endStream() catch {};
            return;
        };
        const entry = store.acquire(req.session_id) orelse {
            throttleInvalidSessionProbe();
            trans.endStream() catch {};
            return;
        };
        // SONNY-3032: held for the request; the reaper closes only an unheld session.
        defer store.release(entry);

        // SONNY-1560: drain the pages WITHOUT pinning the session mutex across
        // the writes. Issue #514's use-after-free is prevented by the epoch
        // claim re-validated inside `pushResultPages`, not by a whole-loop lock,
        // so a stalled or abandoned stream can no longer block the next Execute
        // on this session for the library's 30 s flow-credit timeout.
        var sink_ctx = TransportSink{ .trans = trans };
        switch (pushResultPages(entry, claimed_epoch, sink_ctx.sink(), allocator)) {
            .complete => {},
            // The stream is already terminated: either by our own classified
            // RESOURCE_EXHAUSTED trailer (pre-write probe) or by the library's
            // RST_STREAM(FLOW_CONTROL_ERROR) (write-time `FlowControlTimeout`).
            // Emitting another END_STREAM would be a protocol error either way.
            .window_exhausted => return,
            else => {
                // Try to end the stream gracefully so the client gets a clean
                // close. If this also fails the connection is broken and the
                // connection loop will detect it on the next readMessage.
                trans.endStream() catch {};
                return;
            },
        }
    }

    // End the stream normally
    trans.endStream() catch |err| {
        log.err("gRPC streaming: failed to send end-of-stream", &.{
            Attr.string("error", @errorName(err)),
        });
    };
}

fn handleLegacyPacket(request_bytes: []const u8, trans: *GrpcTransport, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var packet = protobuf.decode(schema.ClientPacket, &reader, allocator) catch |err| {
        log.err("Failed to decode gRPC packet", &.{Attr.string("error", @errorName(err))});
        return buildPacketError(allocator, "22023", "Invalid client packet");
    };
    defer packet.deinit(allocator);

    const msg = packet.quic orelse {
        return buildPacketError(allocator, "22023", "Missing client message");
    };

    return switch (msg) {
        .hello => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleHandshake(req_bytes, trans, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.HelloResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .hello = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .execute => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleExecute(req_bytes, allocator, null);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.ExecutionResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .execute = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .pull => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handlePull(req_bytes, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.PullResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .pull = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .ping => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handlePing(req_bytes, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.PingResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .ping = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .begin => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleBegin(req_bytes, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.BeginResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .begin = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .commit => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleCommit(req_bytes, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.CommitResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .commit = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .rollback => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleRollback(req_bytes, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.RollbackResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .rollback = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        // Issue #515: Route 7 previously-unsupported message types through handlers
        .savepoint => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleSavepoint(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.SavepointResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .savepoint = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .rollback_to => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleRollbackTo(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.RollbackToResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .rollback_to = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .cdc_diag => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleCdcDiag(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.CdcDiagnosticsResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .cdc_diag = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .cdc_ctrl => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleCdcCtrl(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.CdcControlResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .cdc_ctrl = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .backup => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleBackup(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.BackupResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .backup = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .restore => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleRestore(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.RestoreResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .restore = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .upload_backup => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleUploadBackup(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.UploadBackupResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .upload_backup = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .cancel => blk: {
            // SONNY-1841: per-stream CANCEL is a QUIC-transport concept — it maps
            // an incoming QUIC stream id to that stream's cancel flag via the
            // proto_reader_registry. The gRPC bridge has no equivalent per-stream
            // registry (each RPC is its own call), so acknowledge it as a no-op
            // here rather than silently dropping the message.
            var out = schema.ServerPacket{ .quic = .{ .cancel = .{
                .cancelled = false,
                .message = try allocator.dupe(u8, "per-stream cancel is not supported over the gRPC bridge"),
            } } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
    };
}

fn handlePing(_: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const response = schema.PingResponse{ .ok = true };
    return encodeMessage(allocator, response);
}

// CANARY: REQ=REQ-SONNY-3313-GRPC-PEER-IP; FEATURE="GrpcSessionLifetime"; ASPECT=PeerAddress; STATUS=TESTED; TEST=tests/test_sonny3313_grpc_peer_ip.zig; OWNER=transport; UPDATED=2026-09-28
/// Extract peer IP address string from a gRPC transport's underlying socket.
/// Returns a stack-allocated formatted IP string, or "unknown" on failure.
///
/// SONNY-3313 (round 16, I1): this was a Zig 0.16 placeholder that answered
/// "unknown" for every peer, so every anonymous client was
/// `anonymous@unknown` and every federation peer `federation@unknown` (one
/// session cap for all of them: one host holding its sessions in open
/// transactions refused every other host's Handshake), and the auth rate
/// limiter's per-IP bucket was one bucket for every client (one client's
/// username-rotating spray locked every client out). It formats the peer's
/// address now (`formatPeerIp`).
fn getPeerIp(trans: *GrpcTransport) [45]u8 {
    return peerIpOfSocket(trans.stream.socket.handle);
}

/// SONNY-3313: the peer address of the connected socket `handle`, formatted
/// by `formatPeerIp` into a NUL-padded buffer ("unknown" when the socket has
/// no peer). `pub` for the regression test's real sockets.
pub fn peerIpOfSocket(handle: std.posix.socket_t) [45]u8 {
    var buf: [45]u8 = .{0} ** 45;
    var addr: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    std.posix.getpeername(handle, @ptrCast(&addr), &addr_len) catch {
        @memcpy(buf[0..7], "unknown");
        return buf;
    };
    _ = formatPeerIp(&buf, &addr, addr_len);
    return buf;
}

/// SONNY-3313: the IP address in `addr` (`len` bytes of it), as text, into
/// `buf`: IPv4 dotted (`127.0.0.1`), IPv6 as eight groups of four lowercase
/// hex digits (`0000:0000:0000:0000:0000:0000:0000:0001`, the QUIC handler's
/// form, one spelling per address), and an IPv4-mapped IPv6 address
/// (`::ffff:a.b.c.d`, a dual-stack listener's IPv4 client) as its IPv4 form,
/// so a client counts as the same peer whichever listener it reached.
/// "unknown" for any other family. The port is not part of it: one host is
/// one peer.
pub fn formatPeerIp(buf: *[45]u8, addr: *const std.posix.sockaddr.storage, len: std.posix.socklen_t) []const u8 {
    @memset(buf, 0);
    const fam = addr.family;
    if (fam == std.posix.AF.INET and len >= @sizeOf(std.posix.sockaddr.in)) {
        const in4: *const std.posix.sockaddr.in = @ptrCast(@alignCast(addr));
        const b: [4]u8 = @bitCast(in4.addr);
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch unknownPeer(buf);
    }
    if (fam == std.posix.AF.INET6 and len >= @sizeOf(std.posix.sockaddr.in6)) {
        const in6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(addr));
        const a = in6.addr;
        const mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
        if (std.mem.eql(u8, a[0..12], &mapped_prefix)) {
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a[12], a[13], a[14], a[15] }) catch unknownPeer(buf);
        }
        var w: std.Io.Writer = .fixed(buf);
        var g: usize = 0;
        while (g < 8) : (g += 1) {
            if (g > 0) w.writeByte(':') catch return unknownPeer(buf);
            w.print("{x:0>2}{x:0>2}", .{ a[g * 2], a[g * 2 + 1] }) catch return unknownPeer(buf);
        }
        return w.buffered();
    }
    return unknownPeer(buf);
}

fn unknownPeer(buf: *[45]u8) []const u8 {
    @memset(buf, 0);
    @memcpy(buf[0..7], "unknown");
    return buf[0..7];
}

/// Return a slice of the peer IP buffer up to the first null byte.
fn peerIpSlice(buf: *const [45]u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

/// Validate federation HELLO using GEODE_CLUSTER_TOKEN (parity with QUIC handler).
/// GAP-0284 / GAP-0490: Both nodes must share the same cluster token.
/// Returns true only if username is "geode-cluster" AND password matches token.
/// SEC-INFRA-03: delegates to the shared cluster_auth validator (constant-time
/// compare) so the dual-token rotation overlap window
/// (GEODE_CLUSTER_TOKEN_PREVIOUS) applies to federation HELLOs too.
// CANARY: REQ=REQ-GAP-0284-FEDERATION-GRPC-AUTH; FEATURE="FederationAuth"; ASPECT=GrpcServerValidation; STATUS=IMPL; OWNER=security; UPDATED=2026-06-10
fn validateFederationAuth(username: []const u8, password: []const u8) bool {
    if (!std.mem.eql(u8, username, "geode-cluster")) return false;
    if (comptime builtin.os.tag == .windows) return false;
    return geode.distributed.cluster_auth.validateClusterToken(password);
}

/// Parse an ALTER USER <name> SET PASSWORD '<pwd>' statement from raw query text.
/// Returns the extracted username and new password, or null if the query doesn't match.
/// GAP-0284: Parity with QUIC handler's parseAlterUserSetPassword.
// CANARY: REQ=REQ-GAP-0284-ALTER-USER-GRPC; FEATURE="PasswordResetEnforcement"; ASPECT=GrpcAlterUserParse; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
fn parseAlterUserSetPassword(query: []const u8) ?struct { username: []const u8, new_password: []const u8 } {
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
/// a SecurityManager instance. Returns an error message string if the password
/// fails validation, or null if it passes.
/// GAP-0284: Parity with QUIC handler's validatePasswordFallback.
// CANARY: REQ=REQ-GAP-0284-PWD-VALIDATE-GRPC; FEATURE="PasswordPolicyEnforcement"; ASPECT=GrpcFallbackValidation; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
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

/// `pub` as a SONNY-3313 test seam only (a Handshake on a real accepted
/// socket); production dispatch goes through `handlePacket`.
pub fn handleHandshake(request_bytes: []const u8, trans: *GrpcTransport, allocator: std.mem.Allocator) ![]u8 {
    log.debug("gRPC Handshake", &.{Attr.uint("request_bytes_len", request_bytes.len)});

    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.HelloRequest, &reader, allocator) catch |err| {
        log.err("Failed to decode HELLO request", &.{Attr.string("error", @errorName(err))});
        const resp = schema.HelloResponse{
            .success = false,
            .session_id = "",
            .error_message = "Invalid request",
            .capabilities = std.ArrayList([]const u8).empty,
        };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    log.debug("gRPC Handshake decoded", &.{
        Attr.uint("username_len", req.username.len),
        Attr.uint("password_len", req.password.len),
    });

    const store = getSessionStore() orelse {
        const resp = schema.HelloResponse{
            .success = false,
            .session_id = "",
            .error_message = "Server not initialized",
            .capabilities = std.ArrayList([]const u8).empty,
        };
        return encodeMessage(allocator, resp);
    };

    var caps = std.ArrayList([]const u8).initCapacity(allocator, 3) catch return error.OutOfMemory;
    try caps.append(allocator, try allocator.dupe(u8, "GRPC"));
    try caps.append(allocator, try allocator.dupe(u8, "PROTOBUF"));
    try caps.append(allocator, try allocator.dupe(u8, "TLS1.3"));

    // S12: Use peer IP as rate limiter key (not attacker-controlled username).
    // This matches the QUIC handler which uses peer_ip at quic_connection_handler.zig:1301.
    const peer_ip_buf = getPeerIp(trans);
    const peer_ip = peerIpSlice(&peer_ip_buf);

    // S6: Check auth rate limiter before authentication attempt (parity with QUIC handler).
    if (auth_rate_limiter_mod.getGlobalRateLimiter()) |limiter| {
        if (limiter.isLockedForPrincipal(peer_ip, req.username)) {
            // ENG-3954 RC-3 (QUIC parity): name the attempted username and which
            // bucket denied so a per-account guessing run is distinguishable from
            // a NAT-egress spray in the logs.
            const reason = limiter.lockoutReason(peer_ip, req.username);
            log.warn("Authentication rate limit exceeded", &.{
                Attr.string("peer_ip", peer_ip),
                Attr.string("username", req.username),
                Attr.string("denial_reason", switch (reason orelse .principal) {
                    .principal => "principal",
                    .ip_ceiling => "ip_ceiling",
                }),
            });
            const resp = schema.HelloResponse{
                .success = false,
                .session_id = "",
                .error_message = "Too many failed authentication attempts. Try again later.",
                .capabilities = caps,
            };
            return encodeMessage(allocator, resp);
        }
    }

    // GAP-0284: Federation inter-node authentication via cluster token — fast-path.
    // Must be checked BEFORE normal user auth to allow federation when auth is enabled.
    // CANARY: REQ=REQ-GAP-0284-FEDERATION-GRPC-WIRE; FEATURE="FederationAuth"; ASPECT=GrpcHelloCheck; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
    if (validateFederationAuth(req.username, req.password)) {
        log.info("Federation node authenticated via cluster token (gRPC)", &.{
            Attr.string("client", req.client_name),
        });
        // Grant federation-level session with ReadWrite role
        // SONNY-3252: the name a federation peer sends is its own choice; its
        // sessions count against `federation@<peer ip>`.
        var fed_buf: [96]u8 = undefined;
        const fed_principal = principalFor(&fed_buf, .federation, req.username, peer_ip);
        const session_id = store.createSessionAs(fed_principal, req.username, "", .ReadWrite, req.tenant_id, null, false, 0) catch |err| return helloSessionRefused(allocator, caps, err);
        const resp = schema.HelloResponse{
            .success = true,
            .session_id = try allocator.dupe(u8, session_id),
            .error_message = "",
            .capabilities = caps,
        };
        return encodeMessage(allocator, resp);
    }

    if (user_mgmt.isAuthEnabled()) {
        if (!auth_rate_limiter_mod.credentialsPresent(req.username, req.password)) {
            // ENG-3954/#874 (QUIC parity): a truncated / half-open HELLO
            // deserializes to proto3 defaults. Malformed handshake, not a failed
            // credential check — it must not arm the brute-force lockout.
            const resp = schema.HelloResponse{
                .success = false,
                .session_id = "",
                .error_message = "Authentication required",
                .capabilities = caps,
            };
            return encodeMessage(allocator, resp);
        }
        const auth_result = user_mgmt.authenticate(req.username, req.password) catch |auth_err| {
            // S6 / ENG-3954 (QUIC parity): only a checked-and-rejected
            // credential counts against the per-IP lockout.
            const checked = auth_rate_limiter_mod.shouldCountFailedAttempt(auth_err);
            if (checked) {
                // ENG-3954 RC-1 (QUIC parity): charge the ATTEMPTED principal so
                // one principal's failures never lock another; the coarse per-IP
                // ceiling still accrues a username-rotating spray.
                if (auth_rate_limiter_mod.getGlobalRateLimiter()) |limiter| {
                    limiter.recordFailureForPrincipal(peer_ip, req.username);
                }
            }
            const resp = schema.HelloResponse{
                .success = false,
                .session_id = "",
                .error_message = if (checked) "Authentication failed" else "Authentication temporarily unavailable",
                .capabilities = caps,
            };
            return encodeMessage(allocator, resp);
        };

        // S6: Successful authentication — reset this principal's counter.
        if (auth_rate_limiter_mod.getGlobalRateLimiter()) |limiter| {
            limiter.recordSuccessForPrincipal(peer_ip, req.username);
        }
        // CANARY: REQ=REQ-DSN-GRAPH-BIND-005; FEATURE="DSNGraphBinding"; ASPECT=GrpcGraphResolution; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-25
        // Resolve graph from HELLO request — validate, auto-create, bind session
        var resolved_graph: ?[]const u8 = null;
        if (req.graph) |requested_graph| {
            if (requested_graph.len > 0) {
                // SONNY-2775: the bind check is `execution.session_graph.mayBind`,
                // the one every session graph change uses.
                const role_names_hello = [_][]const u8{@tagName(auth_result.role)};
                const hello_principal = geode.security.principal_derive.derivePrincipal(.{
                    .username = req.username,
                    .role_names = &role_names_hello,
                    .tenant_id = req.tenant_id,
                    // active_graph = requested_graph so graph_grant_check_fn can widen access.
                    .active_graph = requested_graph,
                    .auth_version = auth_result.auth_version,
                    .auth_method = .password,
                    .source = .grpc_handler,
                });
                // Validate graph name: max 128 chars, alphanumeric + underscore only
                if (requested_graph.len > 128) {
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Invalid graph name: too long (max 128 characters)",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                }
                for (requested_graph) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '_') {
                        const resp = schema.HelloResponse{
                            .success = false,
                            .session_id = "",
                            .error_message = "Invalid graph name: must contain only alphanumeric characters and underscores",
                            .capabilities = caps,
                        };
                        return encodeMessage(allocator, resp);
                    }
                }
                // SONNY-2791: the __geode_* graphs are the engine's own; no
                // session binds (or auto-creates) one.
                if (graph_store.isInternalGraphName(requested_graph)) {
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Invalid graph name: the __geode_* graphs are internal",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                }
                const gstore = graph_store.getGlobalStore(allocator);
                const cat = try execution.ensureCatalogInstance(allocator);

                // CANARY: REQ=REQ-SONNY-2824-HELLO-GRAPH-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=GrpcHello; STATUS=TESTED; TEST=tests/test_sonny2824_hello_graph_gate.zig; OWNER=security; UPDATED=2026-09-27
                // SONNY-2824: the session-graph gate decides, as on QUIC:
                // permission (bind_graph), then existence, and a graph that
                // does not exist is created only for a principal that may
                // change its schema, as CREATE GRAPH needs (SONNY-2803). HELLO
                // created it for any Admin or ReadWrite role.
                switch (execution.session_graph.helloGraph(&hello_principal, cat, requested_graph)) {
                    .refused => {
                        // GAP-0283: Graph-scoped RBAC authorization check before binding (parity with QUIC handler).
                        // CANARY: REQ=REQ-MULTI-GRAPH-RBAC-WIRE-003; FEATURE="GraphRBACEnforcement"; ASPECT=GrpcGraphAuth; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
                        // CANARY: REQ=REQ-GPS-PDP-005; FEATURE="GPS Decision Engine"; ASPECT=GrpcHandshakeEnforcement; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
                        // Compatibility invariant (#861, kept in mayBind): any authenticated
                        // user may always bind the default graph by name — parity with the
                        // QUIC HELLO handler. This block is nested under
                        // `if (user_mgmt.isAuthEnabled())` above, so there is a principal.
                        const resp = schema.HelloResponse{
                            .success = false,
                            .session_id = "",
                            .error_message = "Access denied: insufficient permissions for graph",
                            .capabilities = caps,
                        };
                        return encodeMessage(allocator, resp);
                    },
                    .missing => {
                        const resp = schema.HelloResponse{
                            .success = false,
                            .session_id = "",
                            .error_message = "Graph does not exist and user lacks permission to create it",
                            .capabilities = caps,
                        };
                        return encodeMessage(allocator, resp);
                    },
                    .bind => resolved_graph = requested_graph,
                    .create => {
                        var auto_create_succeeded = false;
                        if (gstore.createGraph(requested_graph)) {
                            auto_create_succeeded = true;
                        } else |err| {
                            // dsn_graph_binding.yml defense-in-depth
                            // (2026-05-24): mirror the QUIC handler — if
                            // the post-condition (graph exists) is
                            // satisfied despite createGraph errors, bind
                            // instead of bouncing the client. The gate's
                            // bind check (before existence) already allowed
                            // this graph.
                            if (gstore.graphExists(requested_graph) or cat.hasGraph(requested_graph)) {
                                log.warn("createGraph errored but graph is present; binding instead", &.{
                                    Attr.string("graph", requested_graph),
                                    Attr.string("error", @errorName(err)),
                                });
                                resolved_graph = requested_graph;
                            } else {
                                log.err("Graph auto-creation failed", &.{
                                    Attr.string("graph", requested_graph),
                                    Attr.string("error", @errorName(err)),
                                });
                                const resp = schema.HelloResponse{
                                    .success = false,
                                    .session_id = "",
                                    .error_message = "Failed to create graph",
                                    .capabilities = caps,
                                };
                                return encodeMessage(allocator, resp);
                            }
                        }
                        if (auto_create_succeeded) {
                            const uuid = graph_store.GraphStore.getGraphUuid(requested_graph) orelse {
                                const resp = schema.HelloResponse{
                                    .success = false,
                                    .session_id = "",
                                    .error_message = "Graph created without persistent UUID",
                                    .capabilities = caps,
                                };
                                return encodeMessage(allocator, resp);
                            };
                            cat.addGraphWithUuid(requested_graph, uuid) catch |err| switch (err) {
                                // Race-safe — same shape as the QUIC handler.
                                error.GraphAlreadyExists => {},
                                else => {
                                    gstore.dropGraph(requested_graph) catch {};
                                    log.err("Failed to persist graph metadata", &.{
                                        Attr.string("graph", requested_graph),
                                        Attr.string("error", @errorName(err)),
                                    });
                                    const resp = schema.HelloResponse{
                                        .success = false,
                                        .session_id = "",
                                        .error_message = "Failed to persist graph metadata",
                                        .capabilities = caps,
                                    };
                                    return encodeMessage(allocator, resp);
                                },
                            };
                            resolved_graph = requested_graph;
                        }
                    },
                }
            }
        }

        const session_id = store.createSession(req.username, req.password, auth_result.role, req.tenant_id, resolved_graph, auth_result.password_reset_required, auth_result.auth_version) catch |err| return helloSessionRefused(allocator, caps, err);
        // GAP-0284, SONNY-6334: the FLE role the HELLO named, validated as
        // QUIC does, kept on the session (its requests install it), never
        // on the Handshake's thread.
        store.setSessionFleRole(session_id, req.role) catch |err| return helloSessionRefused(allocator, caps, err);
        const resp = schema.HelloResponse{
            .success = true,
            .session_id = try allocator.dupe(u8, session_id),
            .error_message = "",
            .capabilities = caps,
            .password_reset_required = auth_result.password_reset_required,
            .graph = if (resolved_graph) |g| try allocator.dupe(u8, g) else null,
        };
        return encodeMessage(allocator, resp);
    }

    // CANARY: REQ=REQ-DSN-GRAPH-BIND-006; FEATURE="DSNGraphBinding"; ASPECT=GrpcNoAuthGraph; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-25
    // No-auth path: auto-create graph if needed
    var noauth_resolved_graph: ?[]const u8 = null;
    if (req.graph) |requested_graph| {
        if (requested_graph.len > 0) {
            // Validate graph name: max 128 chars, alphanumeric + underscore only
            if (requested_graph.len > 128) {
                const resp = schema.HelloResponse{
                    .success = false,
                    .session_id = "",
                    .error_message = "Invalid graph name: too long (max 128 characters)",
                    .capabilities = caps,
                };
                return encodeMessage(allocator, resp);
            }
            for (requested_graph) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') {
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Invalid graph name: must contain only alphanumeric characters and underscores",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                }
            }
            // SONNY-2791: the __geode_* graphs are the engine's own.
            if (graph_store.isInternalGraphName(requested_graph)) {
                const resp = schema.HelloResponse{
                    .success = false,
                    .session_id = "",
                    .error_message = "Invalid graph name: the __geode_* graphs are internal",
                    .capabilities = caps,
                };
                return encodeMessage(allocator, resp);
            }
            const gstore = graph_store.getGlobalStore(allocator);
            const cat = try execution.ensureCatalogInstance(allocator);

            const in_store = gstore.graphExists(requested_graph);
            const in_catalog = cat.hasGraph(requested_graph);

            if (!in_store and !in_catalog) {
                // No auth = always allow auto-create
                _ = gstore.createGraph(requested_graph) catch |err| {
                    log.err("Graph auto-creation failed (no-auth)", &.{
                        Attr.string("graph", requested_graph),
                        Attr.string("error", @errorName(err)),
                    });
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Failed to create graph",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                };
                const uuid = graph_store.GraphStore.getGraphUuid(requested_graph) orelse {
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Graph created without persistent UUID",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                };
                cat.addGraphWithUuid(requested_graph, uuid) catch |err| {
                    gstore.dropGraph(requested_graph) catch {};
                    log.err("Failed to persist graph metadata (no-auth)", &.{
                        Attr.string("graph", requested_graph),
                        Attr.string("error", @errorName(err)),
                    });
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Failed to persist graph metadata",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                };
            }
            noauth_resolved_graph = requested_graph;
        }
    }

    // SONNY-3252: without authentication, a client's sessions count against
    // `anonymous@<peer ip>`, not the principal "" every client shared.
    var anon_buf: [96]u8 = undefined;
    const anon_principal = principalFor(&anon_buf, .anonymous, "", peer_ip);
    const session_id = store.createSessionAs(anon_principal, "", "", null, req.tenant_id, noauth_resolved_graph, false, 0) catch |err| return helloSessionRefused(allocator, caps, err);
    store.setSessionFleRole(session_id, req.role) catch |err| return helloSessionRefused(allocator, caps, err);
    const resp = schema.HelloResponse{
        .success = true,
        .session_id = try allocator.dupe(u8, session_id),
        .error_message = "",
        .capabilities = caps,
        .graph = if (noauth_resolved_graph) |g| try allocator.dupe(u8, g) else null,
    };
    return encodeMessage(allocator, resp);
}

/// SONNY-1229 (GEO-UP-002): the session's tenant binding, as HELLO recorded it —
/// the SAME value threaded into the `ExecutionContext.tenant_id` the `.rows` arm
/// hands to `node_scan_stream.prepare`. Mirrors
/// `quic_connection_handler.sessionTenantId`.
fn sessionTenantId(state: *const server_state.ServerState) ?[]const u8 {
    return if (state.session_config) |cfg| cfg.tenant_id else null;
}

/// GAP-0900 (scan-no-clone): mirror of
/// `quic_connection_handler.readWillStreamEngineSide`. True iff this read is
/// served by the engine-backed `node_scan_stream` path in the `.rows` arm, so
/// the handler can skip the O(graph) QueryReadSession deep-clone. Conditions
/// are a strict subset of the `.rows` arm's streaming gate.
fn readWillStreamEngineSide(state: *const server_state.ServerState, analysis: *const query_traits.ProgramAnalysis) bool {
    if (graph_store.getGlobalAdapter() == null) return false;
    if (analysis.kind != .rows) return false;
    const rls_active = rls_filter.getGlobalRLSFilterEngine() != null and state.authenticated_user != null;
    if (rls_active) return false;
    if (analysis.has_effectful_preamble) return false;
    const target = analysis.target orelse return false;
    if (target.* != .Query) return false;
    // SONNY-1229: the tenant half of the decision lives inside `isEligible`
    // (shared with `prepare`), so this can never claim a read the stream refuses.
    return node_scan_stream.isEligible(&target.Query, sessionTenantId(state));
}

/// GAP-0902: true iff this read is served ENGINE-DIRECT (no whole-graph snapshot
/// clone) by EITHER `node_scan_stream` OR the storage-native planned-read path
/// (single-chain ORDER BY / DISTINCT / aggregate / WHERE-count). Mirrors the
/// QUIC handler's `readServedEngineDirect`: skipping the snapshot lets the
/// `.rows` arm read the live store engine-direct via the fast paths /
/// planned_read instead of materializing an O(all-nodes)-resident snapshot
/// (the RSS balloon under the bounded node cache). Same RLS / preamble / adapter
/// gates as the streaming predicate; RLS reads stay on the snapshot path.
/// SONNY-2749: the session's graph as the executor sees it: the graph a
/// program's statements start on (`state.current_graph` is not kept in step
/// on gRPC).
fn sessionGraphName(state: *const server_state.ServerState) []const u8 {
    if (state.exec_session) |*sess| return sess.graph orelse graph_store.DEFAULT_GRAPH_NAME;
    return state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
}

/// SONNY-2775: where SESSION RESET and SESSION CLOSE take the session: the
/// graph HELLO bound it to (`graph_bound`), or the default graph.
fn homeGraphName(state: *const server_state.ServerState) []const u8 {
    return if (state.graph_bound) sessionGraphName(state) else graph_store.DEFAULT_GRAPH_NAME;
}

fn readServedEngineDirect(state: *const server_state.ServerState, analysis: *const query_traits.ProgramAnalysis) bool {
    if (graph_store.getGlobalAdapter() == null) return false;
    if (analysis.kind != .rows) return false;
    const rls_active = rls_filter.getGlobalRLSFilterEngine() != null and state.authenticated_user != null;
    if (rls_active) return false;
    if (analysis.has_effectful_preamble) return false;
    const target = analysis.target orelse return false;
    if (target.* != .Query) return false;
    // SONNY-1229: see the QUIC twin — `isEligible` now also declines for a
    // concrete tenant scope / effective strict tenancy, and the storage-native
    // shape needs no tenant gate here because `buildPlanIfSupported` demotes a
    // tenant-scoped plan to the legacy (tenant-aware) executor on the live store.
    return node_scan_stream.isEligible(&target.Query, sessionTenantId(state)) or
        planned_read_runtime.isStorageNativeReadShape(&target.Query);
}

/// SONNY-1560: `epoch_out`, when supplied, receives the session result
/// generation this Execute installs. The streaming push loop claims it and
/// aborts if a later Execute supersedes it mid-push.
/// `pub` as a SONNY-1221 test seam only; production dispatch must go through
/// `handlePacket` (see SessionStore).
pub fn handleExecute(request_bytes: []const u8, allocator: std.mem.Allocator, epoch_out: ?*u64) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.ExecuteRequest, &reader, allocator) catch |err| {
        log.err("Failed to decode Execute request", &.{Attr.string("error", @errorName(err))});
        var resp = try buildErrorResponse(allocator, "22023", "Invalid execute request", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0) {
        var resp = try buildErrorResponse(allocator, "28000", "Missing session_id", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    }

    const store = getSessionStore() orelse {
        var resp = try buildErrorResponse(allocator, "58000", "Server not initialized", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    };

    const entry = store.acquire(req.session_id) orelse {
        throttleInvalidSessionProbe();
        var resp = try buildErrorResponse(allocator, "28000", "Unknown session", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    };
    // SONNY-3032: held for the request; the reaper closes only an unheld session.
    defer store.release(entry);

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;
    // SONNY-2799, SONNY-2823: the session's undo-log and engine transactions
    // are this thread's for the request, whichever worker thread serves it.
    const txn_scope = state.enterSessionTxn();
    defer state.leaveSessionTxn(txn_scope);
    // SONNY-6334: the session's request context (tenant, FLE role,
    // decrypt_field gate) on this thread for the request, as QUIC does.
    state.installRequestThreadState();
    defer server_state.ServerState.clearRequestThreadState();

    state.resetResult();
    // SONNY-1560: a new statement invalidates any in-flight pushed stream on
    // this session. Bumped under `entry.mutex`, which is held from here until
    // this function returns, so the generation reported to the caller is the
    // generation of whatever result this Execute goes on to install.
    entry.result_epoch +%= 1;
    if (epoch_out) |out| out.* = entry.result_epoch;

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        .missing => {
            var resp = try buildErrorResponse(allocator, "28000", "Authentication required", &.{}, &.{});
            defer resp.deinit(allocator);
            return encodeMessage(allocator, resp);
        },
        .invalidated => {
            var resp = try buildErrorResponse(allocator, "28000", "Session invalidated due to credential or role change", &.{}, &.{});
            defer resp.deinit(allocator);
            return encodeMessage(allocator, resp);
        },
    }

    // GAP-0284: Handle ALTER USER SET PASSWORD — intercept before GQL parser since
    // ALTER USER is not part of GQL syntax. Works both during forced
    // password reset and for normal password changes (parity with QUIC handler).
    // CANARY: REQ=REQ-GAP-0284-ALTER-USER-GRPC-WIRE; FEATURE="PasswordResetEnforcement"; ASPECT=GrpcExecuteIntercept; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
    {
        const trimmed = std.mem.trim(u8, req.query, " \t\r\n");
        if (parseAlterUserSetPassword(trimmed)) |parsed| {
            // Verify the user is changing their own password
            if (state.authenticated_user) |auth_user| {
                if (!std.mem.eql(u8, auth_user, parsed.username)) {
                    var resp = try buildErrorResponse(allocator, "42501", "You can only change your own password", &.{}, &.{});
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                }
            } else {
                var resp = try buildErrorResponse(allocator, "42501", "Authentication required to change passwords", &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            }

            // Validate password against SecurityManager policy BEFORE updating
            if (state.security_manager) |sm| {
                sm.validatePassword(parsed.new_password) catch |err| {
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
                    var resp = try buildErrorResponse(allocator, "28P01", msg, &.{}, &.{});
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                };
            } else {
                // Fallback policy enforcement when SecurityManager is null
                if (validatePasswordFallback(parsed.new_password)) |msg| {
                    var resp = try buildErrorResponse(allocator, "28P01", msg, &.{}, &.{});
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                }
            }

            user_mgmt.updateUserPassword(allocator, parsed.username, parsed.new_password) catch |err| {
                const msg = switch (err) {
                    error.PasswordReuse => "New password must not match the current password",
                    else => "Failed to update password",
                };
                var resp = try buildErrorResponse(allocator, "28P01", msg, &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            };

            // Persist the password change to the auth graph store so it survives
            // restarts. Twin of handleAlterUserSetPassword in
            // server/quic_connection_handler.zig — same seams, so the bug 731
            // fixes apply here too: the durable password_reset_required clear
            // lives in AuthGraphManager.updateUserPassword (4a), reached through
            // the user_mgmt persistent writer above, and this SecurityManager
            // call mirrors the change in memory without a second durable write
            // while that writer owns durability (4c).
            if (state.security_manager) |sm| {
                if (sm.getUserIdByUsername(parsed.username)) |user_id| {
                    sm.updatePassword(user_id, parsed.new_password) catch |err| {
                        log.warn("Failed to persist password change to auth graph", &.{
                            Attr.string("username", parsed.username),
                            Attr.string("error", @errorName(err)),
                        });
                    };
                }
            }

            state.password_reset_required = false;

            // Send success response as a status-only execution result
            const status = try proto_util.buildStatus(allocator, "00000", &.{});
            var resp = schema.ExecutionResponse{
                .status = status,
                .payload = null,
            };
            defer resp.deinit(allocator);
            return encodeMessage(allocator, resp);
        }
    }

    // GAP-0284: Block all other queries when password reset is required (parity with QUIC handler).
    // CANARY: REQ=REQ-GAP-0284-PWD-RESET-BLOCK-GRPC; FEATURE="PasswordResetEnforcement"; ASPECT=GrpcExecuteBlock; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
    if (state.password_reset_required) {
        var resp = try buildErrorResponse(allocator, "08P01", "Password reset required. Change password with: ALTER USER <username> SET PASSWORD '<new_password>'", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    }

    const bindings = proto_util.parseParams(allocator, req.params.items) catch |err| {
        var resp = try buildErrorResponse(allocator, "22023", @errorName(err), &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    };
    defer proto_util.freeParamBindings(allocator, bindings);

    const order_keys_expr = server_flags.getOrderKeysExpr();
    const parse_opts = geode.ParseOptions{
        .ident_order_only = !order_keys_expr,
        .forbid_orderby_calls = !order_keys_expr,
    };

    var normalized = try query_traits.normalizeExplainCalibrated(allocator, req.query);
    defer normalized.deinit(allocator);

    const query_text = normalized.text;
    if (state.query_text) |qt| allocator.free(qt);
    state.query_text = try allocator.dupe(u8, query_text);

    const outcome = try geode.parseGqlOutcome(query_text, allocator, parse_opts);
    switch (outcome) {
        .Err => |err_info| {
            const msg = if (err_info.has_double_dash_comment)
                diagnostics.defaultMessage(.GB02CommentDisabled)
            else
                err_info.msg;
            // SONNY-3244: a parser limit answers its class 54 code.
            var resp = try buildErrorResponse(allocator, if (err_info.has_double_dash_comment) "42000" else err_info.code, msg, &.{}, &.{});
            defer resp.deinit(allocator);
            return encodeMessage(allocator, resp);
        },
        .Ok => |parse_result_const| {
            var parse_result = parse_result_const;
            defer parse_result.deinit();

            if (parse_result.has_double_dash_comment) {
                var resp = try buildErrorResponse(allocator, "42000", diagnostics.defaultMessage(.GB02CommentDisabled), &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            }

            // SONNY-3348 (round 18, I2): a session whose transaction a failed
            // statement aborted runs nothing until it ends the transaction.
            if (state.txn_aborted) {
                const verdict = query_traits.abortedTxnVerdict(&parse_result.program);
                if (verdict != .refuse) state.txn_aborted = false;
                // SONNY-3348 (round 19, m3): the ROLLBACK or COMMIT that ends
                // it reports a rollback that could not undo every change.
                const incomplete = verdict != .refuse and state.takeRollbackIncomplete();
                if (verdict != .rollback or incomplete) {
                    const info = proto_util.mapError(if (incomplete) error.RollbackIncomplete else if (verdict == .commit) error.TransactionRolledBack else error.TransactionAborted);
                    var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                }
            }

            // SONNY-3247: every parameter the program names is one the request
            // supplies (42P02 otherwise), checked before any path runs it.
            execution.checkProgramParams(&parse_result.program, bindings.names, bindings.values) catch |err| {
                const info = proto_util.mapError(err);
                var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            };

            // SONNY-2805: `analyzeRequest` keeps a program with transaction
            // control off the fast paths that run only its last query.
            const analysis = query_traits.analyzeRequest(&parse_result.program);
            var traits = analysis.traits;
            const ordered = traits.ordered;
            const distinct = traits.distinct;
            const heur_index = traits.has_where_eq or traits.has_filter_eq;

            const role = if (state.authenticated_role) |role_u8|
                @as(user_mgmt.Role, @enumFromInt(role_u8))
            else
                null;

            const catalog = try execution.ensureCatalogInstance(allocator);

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
            // GAP-0756: Consult the shared query optimizer before building the
            // execution context so repeat parameterised queries hit the
            // cross-connection plan cache instead of re-planning every time.
            // CANARY: REQ=REQ-PERF-SHARED-OPT-001; FEATURE="SharedQueryOptimizer"; ASPECT=GrpcHandlerWire; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-18
            var plan_handle: ?query_plan_cache.SharedPlanHandle = null;
            var optimizer_hints_storage: query_plan_cache.OptimizerHints = .{};
            defer if (plan_handle) |*h| h.release();

            if (state.query_optimizer) |shared_opt| {
                const store_for_stats = graph_store.getGlobalStore(allocator);
                const store_stats = query_plan_cache.StoreStats{
                    .node_count = @intCast(store_for_stats.getNodeCount()),
                    .edge_count = @intCast(store_for_stats.getEdgeCount()),
                };
                plan_handle = shared_opt.optimizeQuery(query_text, &parse_result.program, store_stats) catch null;
                if (plan_handle) |*h| {
                    optimizer_hints_storage = h.toHints();
                }
            }

            // CANARY: REQ=REQ-GPS-DERIVE-002; FEATURE="GPS Principal Derivation"; ASPECT=GrpcHandlerWiring; STATUS=TESTED; TEST=tests/test_gps_principal_propagation.zig; OWNER=security; UPDATED=2026-05-20
            // Phase 2: delegate to derivePrincipal() so all transport sites share
            // the same field-population logic. source=.grpc_handler lets GPS Phase 6
            // distinguish transport origin even when QUIC and gRPC share the same
            // execution path.
            const principal_for_request = blk: {
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
                    .source = .grpc_handler,
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
                // GAP-0844 (secondary), SONNY-6334: the session's FLE role, the
                // one its HELLO named (`SessionStore.setSessionFleRole`), when
                // the authenticated user holds it (SONNY-6341).
                .fle_role = state.effectiveFleRole(),
                .principal = &principal_for_request,
                .pending_index_rebuilds = null,
                // SONNY-2799: see `abortFailedTransaction`.
                .defer_failed_txn_rollback = true,
            };

            var pending_index_rebuilds = std.StringHashMap(void).init(allocator);
            defer {
                var iter = pending_index_rebuilds.keyIterator();
                while (iter.next()) |k| allocator.free(k.*);
                pending_index_rebuilds.deinit();
            }
            exec_context.pending_index_rebuilds = &pending_index_rebuilds;
            exec_context.pending_index_rebuilds_allocator = allocator;

            var flags = std.ArrayList([]const u8).initCapacity(allocator, 8) catch return error.OutOfMemory;
            defer flags.deinit(allocator);
            var base_flags_buf: server_flags.BaseFlagsBuf = undefined;
            const base_flags = server_flags.computeBaseFlags(&base_flags_buf, ordered, distinct);
            for (base_flags) |flag| {
                try appendFlagIfMissing(allocator, &flags, flag);
            }
            if (traits.has_union) {
                try appendFlagIfMissing(allocator, &flags, server_flags.F_UNION_PHASES);
            }
            if (heur_index) {
                try appendFlagIfMissing(allocator, &flags, server_flags.F_HEUR_INDEX);
            }
            if (parse_result.has_double_solidus_comment) {
                try appendFlagIfMissing(allocator, &flags, "GB03:DoubleSolidusComment");
            }

            // GAP-0289: Enforce per-tenant query concurrency quota before execution.
            const grpc_query_tenant = if (state.session_config) |cfg| cfg.tenant_id else null;
            var grpc_query_quota_acquired = false;
            if (grpc_query_tenant) |tid| {
                if (tenant_quota.getGlobalQuotaManager()) |qm| {
                    qm.acquireQuery(tid) catch {
                        var resp = try buildErrorResponse(allocator, "42000", "Query quota exceeded for tenant", &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };
                    grpc_query_quota_acquired = true;
                }
            }
            defer if (grpc_query_quota_acquired) {
                if (grpc_query_tenant) |tid| {
                    if (tenant_quota.getGlobalQuotaManager()) |qm| {
                        qm.releaseQuery(tid);
                    }
                }
            };

            // #564: Acquire the appropriate store lock based on query type.
            // Without this, gRPC queries ran with no synchronization, allowing
            // concurrent mutations to corrupt shared HashMaps and ArrayLists.
            // P1: Per-graph locking — queries against different graphs no longer serialize.
            // SONNY-2733: a lone CALL of a procedure that takes each graph's
            // lock itself (geode.tenant.backfill_edge_tags) runs holding none:
            // under this graph's lock it would deadlock on it, or hold two. It
            // is still a mutation for the permission gate below.
            // CANARY: REQ=REQ-SONNY-2743-WHOLE-PROGRAM-GATE; FEATURE="StatementAuthorization"; ASPECT=GrpcHandler; STATUS=TESTED; TEST=tests/test_sonny2743_whole_program_gate.zig; OWNER=security; UPDATED=2026-09-25
            // SONNY-2743: the lock, and whether the write gate applies, come
            // from the whole program (`statementPlan`, shared with QUIC). A
            // program ending in EXPLAIN used to skip the gate whatever else it
            // held.
            // SONNY-2749: the graph the program starts on is the executor
            // session's (`exec_session.graph`). gRPC never synced
            // `state.current_graph`, so every write here locked `default`,
            // whatever graph the session was on. Copied, because a USE GRAPH
            // in the program frees the session's string.
            const query_graph_name = try allocator.dupe(u8, sessionGraphName(state));
            defer allocator.free(query_graph_name);
            const stmt_plan = query_traits.statementPlan(&parse_result.program, &analysis, query_graph_name, homeGraphName(state), .grpc);
            // CANARY: REQ=REQ-SONNY-2799-TXN-END-LOCK; FEATURE="TransactionManagement"; ASPECT=GrpcHandler; STATUS=TESTED; TEST=tests/test_sonny2805_txn_sessions.zig; OWNER=engine; UPDATED=2026-09-26
            // SONNY-2799: a COMMIT or ROLLBACK in the program ends the
            // session's transaction, which changed `state.txn_graph`. The
            // program runs under that graph's write lock (a ROLLBACK changes
            // it back) and touches no other graph's data (a handler holds one
            // lock). It ran under the request's own lock: for a ROLLBACK a
            // read lock, or a read snapshot the undo went into. Copied: the
            // COMMIT frees the session's copy.
            const txn_end_graph: ?[]const u8 = blk: {
                if (!state.in_txn or !query_traits.transactionControl(&parse_result.program).ends) break :blk null;
                const g = state.txn_graph orelse break :blk null;
                break :blk try allocator.dupe(u8, g);
            };
            defer if (txn_end_graph) |g| allocator.free(g);
            // CANARY: REQ=REQ-SONNY-2749-PROGRAM-GRAPH-LOCK; FEATURE="StatementAuthorization"; ASPECT=GrpcHandler; STATUS=TESTED; TEST=tests/test_sonny2749_program_graph_lock.zig; OWNER=security; UPDATED=2026-09-25
            // SONNY-2749: every lock below is on the graph the program's
            // statements run on, which a USE GRAPH in it moves.
            const lock_graph = txn_end_graph orelse stmt_plan.lock_graph;
            const self_locking = stmt_plan.self_locking;
            const needs_store_lock = stmt_plan.needs_store_lock or txn_end_graph != null;
            const program_is_mutating = stmt_plan.is_mutation;
            const is_mutation = stmt_plan.is_mutation;
            // The write lock: for a change, or for the end of a transaction.
            const write_locked = is_mutation or txn_end_graph != null;

            // Spec geode-vectorization-and-reranking: per-request hard read-only
            // floor, independent of the principal's role ("authorization must be
            // enforced below the LLM"). Fires BEFORE the role-based mutation gate
            // below and regardless of whether auth is enabled — a gateway/
            // orchestrator sets ExecuteRequest.read_only=true to guarantee no
            // mutation reaches the store no matter what role the connection holds.
            // CANARY: REQ=REQ-EXEC-READ-ONLY-REQUEST-001; FEATURE="ReadOnlyExecute"; ASPECT=GrpcGate; STATUS=TESTED; TEST=tests/test_read_only_execute.zig; OWNER=engine; UPDATED=2026-08-28
            if (req.read_only and program_is_mutating) {
                var resp = try buildErrorResponse(allocator, "42501", "Read-only request: data modification rejected", &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            }

            // GAP-0526: Enforce write-permission check before mutation execution.
            // ReadOnly and User roles lack Write permission and must be denied.
            // CANARY: REQ=REQ-GPS-PDP-005; FEATURE="GPS Decision Engine"; ASPECT=GrpcEnforcement; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-05-20
            // Phase 2: delegated to gps.decide() so the PDP is uniform across all transports.
            // principal_for_request is derived above (line ~1964) and is in scope here.
            // SONNY-2743: `gps.writePermitted`, the same gate QUIC runs.
            // CANARY: REQ=REQ-SEC-PER-GRAPH-GRANTS; FEATURE="PerGraphGrants"; ASPECT=GrpcWriteGate; STATUS=TESTED; TEST=tests/test_per_graph_grants.zig; OWNER=security; UPDATED=2026-10-11
            // REQ-SEC-PER-GRAPH-GRANTS: write on the graph the program
            // changes, for every principal; a self-locking CALL needs
            // database-wide write. See the QUIC handler.
            if (is_mutation) {
                const write_ok = if (stmt_plan.self_locking)
                    geode.security.gps.writePermitted(std.heap.smp_allocator, &principal_for_request)
                else
                    geode.security.gps.writePermittedOn(std.heap.smp_allocator, &principal_for_request, lock_graph);
                if (!write_ok) {
                    var resp = try buildErrorResponse(allocator, "42501", "Permission denied: insufficient privileges for data modification", &.{}, &.{});
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                }
            }
            // CANARY: REQ=REQ-SEC-DEFAULT-ROLE-FAIL-CLOSED; FEATURE="FailClosedDefaultRole"; ASPECT=GrpcReadGate; STATUS=TESTED; TEST=tests/test_default_role_fail_closed.zig; OWNER=security; UPDATED=2026-10-11
            // A principal with no global Read (a user with no stored role)
            // reads only graphs it holds a READ grant on, the default graph
            // included. A session with no role (auth disabled) is not gated,
            // as on QUIC: it has no principal for `gps.decide` to allow.
            if (role != null) {
                if (!try execution.session_graph.programReadPermitted(allocator, &principal_for_request, &parse_result.program, &analysis, query_graph_name, homeGraphName(state))) {
                    var resp = try buildErrorResponse(allocator, "42501", "Permission denied: no grant on the graph", &.{}, &.{});
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                }
            }

            // CANARY: REQ=REQ-SONNY-2802-PROFILE-REGIME; FEATURE="StatementAuthorization"; ASPECT=GrpcHandler; STATUS=TESTED; TEST=tests/test_sonny2802_profile_regime.zig; OWNER=security; UPDATED=2026-09-26
            // SONNY-2802 / SONNY-2752: the .explain and .profile arms plan or
            // run one statement. A program with anything else in it is
            // refused rather than run in part under the whole program's lock.
            if (query_traits.explainOrProfileHasCompany(&parse_result.program, &analysis, query_graph_name)) {
                var resp = try buildErrorResponse(allocator, "0A000", query_traits.explain_profile_alone_message, &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            }
            // CANARY: REQ=REQ-SONNY-3026-PROFILE-TXN-CONTROL; FEATURE="StatementAuthorization"; ASPECT=GrpcHandler; STATUS=TESTED; TEST=tests/test_sonny3026_profile_txn_control.zig; OWNER=security; UPDATED=2026-09-27
            // SONNY-3026: nor an EXPLAIN or PROFILE of transaction control, a
            // session statement or graph selection. `PROFILE ROLLBACK` undid
            // the transaction under a read lock and the transaction stayed open.
            if (query_traits.explainOrProfileTargetRefused(&parse_result.program)) {
                var resp = try buildErrorResponse(allocator, "0A000", query_traits.explain_profile_target_message, &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            }
            // SONNY-2749: one graph's write lock cannot cover a program that
            // changes data on several, and a handler never holds two.
            if (stmt_plan.spans_graphs) {
                var resp = try buildErrorResponse(allocator, "0A000", query_traits.spans_graphs_message, &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            }
            // CANARY: REQ=REQ-SONNY-3130-GRAPH-DDL-ALONE; FEATURE="MultiGraphIsolation"; ASPECT=GrpcHandler; STATUS=TESTED; TEST=tests/test_sonny3130_graph_ddl_alone.zig; OWNER=storage; UPDATED=2026-09-27
            // SONNY-3130: nor graph DDL with a statement on graph data. The
            // lock taken below is the old graph's; a CREATE OR REPLACE (or a
            // DROP then CREATE) puts a new graph, with its own lock, under the
            // name, and the program's writes landed there without it.
            if (stmt_plan.graph_ddl_has_company) {
                var resp = try buildErrorResponse(allocator, "0A000", query_traits.graph_ddl_alone_message, &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            }
            // CANARY: REQ=REQ-SONNY-2776-TXN-ONE-GRAPH; FEATURE="StatementAuthorization"; ASPECT=GrpcHandler; STATUS=TESTED; TEST=tests/test_sonny2776_session_graph_uses.zig; OWNER=security; UPDATED=2026-09-26
            // SONNY-2776: an open transaction changes one graph (its end takes
            // that graph's write lock); a change of another is refused.
            if (stmt_plan.is_mutation and state.txnWouldSpanGraphs(lock_graph)) {
                var resp = try buildErrorResponse(allocator, "0A000", query_traits.txn_spans_graphs_message, &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            }
            if (txn_end_graph) |g| {
                if (!query_traits.programDataOnlyOn(&parse_result.program, query_graph_name, homeGraphName(state), g)) {
                    var resp = try buildErrorResponse(allocator, "0A000", query_traits.txn_end_graph_message, &.{}, &.{});
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                }
            }

            // SONNY-2799: a failed statement's transaction is rolled back
            // after the request's lock is released: this defer is registered
            // before the lock's, so it runs after it.
            var failed_in_txn = false;
            defer if (failed_in_txn) abortFailedTransaction(state, lock_graph, query_traits.endsTransactionLast(&parse_result.program));

            var graph_lock_handle: ?graph_store.GraphLockHandle = null;
            // GAP-0753: Read path takes the shared graph lock only long
            // enough to capture a QueryReadSession snapshot; downstream
            // parse + plan + execute + row materialization runs against the
            // snapshot without holding the graph lock. Mutations still take
            // the exclusive writer lock for their full duration.
            //
            // GAP-0805 (M1.3): Simple point-reads bypass the deep-clone
            // snapshot path and use a zero-copy `PointReadView` while
            // holding the shared read lock across the short execute window.
            // Falls back cleanly to the snapshot path on init failure or
            // when the plan isn't flagged as a point read.
            var read_session: ?graph_store.QueryReadSession = null;
            var point_read_view: ?graph_store.PointReadView = null;
            var prev_active_read_store: ?*graph_store.GraphStore = null;
            if (needs_store_lock) {
                if (write_locked) {
                    // Mutations: exclusive writer lock held across execute to
                    // prevent HashMap rehash races (GAP-0001, CWE-362/CWE-416).
                    // SONNY-2749: the graph the program writes; no deadline.
                    // SONNY-2799: or the graph whose transaction it ends.
                    graph_lock_handle = graph_store.acquireProgramWriteLockCancelable(lock_graph, query_graph_name, std.math.maxInt(u64)) catch |err| blk: {
                        // SONNY-3028: CREATE GRAPH of a new graph, or DROP
                        // GRAPH IF EXISTS of a missing one: no lock to take.
                        if (err == error.GraphNotFound and stmt_plan.lock_graph_may_be_missing) break :blk null;
                        const info = proto_util.mapError(err);
                        var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };
                } else if (stmt_plan.reads_several_graphs) {
                    // CANARY: REQ=REQ-SONNY-3312-MULTI-GRAPH-READ; FEATURE="MultiGraphIsolation"; ASPECT=GrpcHandler; STATUS=TESTED; TEST=tests/test_sonny3312_multi_graph_read.zig; OWNER=storage; UPDATED=2026-09-28
                    // SONNY-3312: a read whose statements run on several
                    // graphs snapshots each of them, under each one's read
                    // lock taken in name order. A snapshot of `lock_graph`
                    // (the session graph) alone read the others as empty.
                    // No live fallback: it would hold one graph's lock.
                    const read_graphs = try query_traits.programDataGraphList(allocator, &parse_result.program, query_graph_name, homeGraphName(state));
                    defer allocator.free(read_graphs);
                    if (graph_store.snapshotUnderReadLocks(allocator, read_graphs, &exec_context)) |session| {
                        read_session = session;
                        prev_active_read_store = graph_store.pushActiveQueryReadStore(
                            read_session.?.store(),
                        );
                    } else |err| {
                        const info = proto_util.mapError(err);
                        var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    }
                } else if (stmt_plan.point_read and !execution.wouldEvaluateRLS()) {
                    // GAP-0805: zero-copy point-read view scoped by the
                    // shared read lock (handle kept alive until defer).
                    // NOTE: RLS-evaluating reads bypass this path (wouldEvaluateRLS()
                    // returns true) and fall through to the snapshot path below, so
                    // the SHARED rwlock is released before per-node row construction.
                    graph_lock_handle = graph_store.acquireGraphReadLockTagged(lock_graph, .point_read);
                    const store_ref = graph_store.getWritableGlobalStore(allocator);
                    if (graph_store.PointReadView.init(store_ref)) |view| {
                        point_read_view = view;
                        prev_active_read_store = graph_store.pushActiveQueryReadStore(
                            point_read_view.?.store(),
                        );
                    } else |_| {
                        if (graph_lock_handle) |h| graph_store.releaseGraphLock(h);
                        graph_lock_handle = null;
                        if (graph_store.snapshotUnderReadLock(allocator, lock_graph)) |session| {
                            read_session = session;
                            prev_active_read_store = graph_store.pushActiveQueryReadStore(
                                read_session.?.store(),
                            );
                        } else |_| {
                            graph_lock_handle = graph_store.acquireGraphReadLockTagged(lock_graph, .fallback);
                        }
                    }
                } else if (readServedEngineDirect(state, &analysis)) {
                    // GAP-0900 / GAP-0902 (scan/analytical no-clone): the read is
                    // served ENGINE-DIRECT in the `.rows` arm below — by
                    // `node_scan_stream` (bounded scan / projection / WHERE /
                    // count) OR, for single-chain ORDER BY / DISTINCT / aggregate
                    // / WHERE-count, by the storage-native planned-read + fast
                    // paths. All read only the needed properties straight from the
                    // storage adapter (never the cache map) and never consume the
                    // active read store. Skip the O(all-nodes) QueryReadSession
                    // deep-clone — under the bounded node cache it materialized
                    // every evicted node into an O(N)-resident snapshot (the RSS
                    // balloon). See the same fix + rationale in
                    // src/server/quic_connection_handler.zig. Snapshot isolation,
                    // FLE decrypt-on-read, and tenant filtering are preserved; RLS
                    // reads stay on the snapshot path (excluded by the predicate).
                } else {
                    // Reads: snapshot under the shared reader lock, then
                    // release immediately. Executor reads from the thread-
                    // local active-snapshot store installed below.
                    if (graph_store.snapshotUnderReadLock(allocator, lock_graph)) |session| {
                        read_session = session;
                        prev_active_read_store = graph_store.pushActiveQueryReadStore(
                            read_session.?.store(),
                        );
                    } else |_| {
                        // Snapshot path unavailable (e.g. legacy no-adapter
                        // test path): fall back to the wide-scope shared
                        // reader lock, same semantics as GAP-0752.
                        graph_lock_handle = graph_store.acquireGraphReadLockTagged(lock_graph, .fallback);
                    }
                }
            }
            var lock_released = false;
            // GAP-0755: Borrow a per-query arena from the process-wide pool
            // and install its allocator as the current-thread scratch hint.
            // See src/server/query_arena.zig for details; mirrors the
            // wiring in src/server/quic_connection_handler.zig.
            var scratch_arena: ?*query_arena.Arena = null;
            var prev_scratch: ?std.mem.Allocator = null;
            var scratch_installed = false;
            // REQ-EXEC-MATERIALIZE-OWNERSHIP-002: a scratch arena MUST back this
            // query so materialized row interior drops with it (no row-by-row
            // leak). If the pooled arena is unavailable, install a per-request
            // fallback arena rather than silently degrading to the leaking
            // graph-store global allocator.
            var fallback_arena: ?std.heap.ArenaAllocator = null;
            if (query_arena.ensureDefaultPool(graph_store.global_allocator())) |pool| {
                if (pool.acquire()) |a| {
                    scratch_arena = a;
                    prev_scratch = query_arena.pushScratchAllocator(a.allocator());
                    scratch_installed = true;
                } else |err| {
                    log.warn("gRPC query scratch arena acquire failed; using per-request fallback arena", &.{
                        Attr.string("error", @errorName(err)),
                    });
                }
            } else |err| {
                log.warn("gRPC query scratch arena pool init failed; using per-request fallback arena", &.{
                    Attr.string("error", @errorName(err)),
                });
            }
            if (!scratch_installed) {
                fallback_arena = std.heap.ArenaAllocator.init(allocator);
                prev_scratch = query_arena.pushScratchAllocator(fallback_arena.?.allocator());
                scratch_installed = true;
            }
            defer {
                if (!lock_released) {
                    if (graph_lock_handle) |h| {
                        // GAP-0511: Release lock before index rebuild
                        graph_store.releaseGraphLock(h);
                        rebuildPendingIndexes(allocator, lock_graph, &pending_index_rebuilds);
                    }
                }
                // GAP-0753: Always pop the active-store thread-local and
                // deinit the session on every exit path, including early
                // returns on error.
                if (read_session) |*session| {
                    graph_store.popActiveQueryReadStore(prev_active_read_store);
                    session.deinit();
                }
                // GAP-0805 (M1.3): mirror cleanup for the zero-copy point-read
                // view. The graph_lock_handle above scopes the read lock that
                // guarantees snapshot consistency; PointReadView.deinit is a
                // no-op (doesn't own the lock).
                if (point_read_view) |*view| {
                    graph_store.popActiveQueryReadStore(prev_active_read_store);
                    view.deinit();
                }
                // GAP-0755: Always pop scratch allocator + return arena to
                // pool on every exit path.
                if (scratch_installed) {
                    query_arena.popScratchAllocator(prev_scratch);
                }
                if (scratch_arena) |a| {
                    if (query_arena.defaultPool()) |pool| pool.release(a);
                }
                // Deinit the per-request fallback arena AFTER it is popped.
                if (fallback_arena) |*fa| fa.deinit();
            }

            switch (analysis.kind) {
                .explain => {
                    const explain_msg = blk: {
                        if (analysis.target) |target| {
                            if (target.* == .Query) {
                                var planned_query = target.Query;
                                if (try planned_read_runtime.buildPlanIfSupported(allocator, &planned_query, exec_context)) |plan| {
                                    var owned_plan = plan;
                                    defer owned_plan.deinit(allocator);
                                    break :blk try explain_payload.buildExplainPayloadFromPlan(allocator, owned_plan);
                                }
                            }
                        }
                        break :blk try explain_payload.buildExplainPayload(
                            allocator,
                            traits,
                            analysis.union_part_count,
                            normalized.explain_calibrated,
                        );
                    };

                    const status = try proto_util.buildStatus(allocator, "00000", flags.items);
                    var resp = schema.ExecutionResponse{
                        .status = status,
                        .payload = .{ .explain = explain_msg },
                    };
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                },
                .profile => {
                    const target_stmt = analysis.target orelse {
                        var resp = try buildErrorResponse(allocator, "0A000", "PROFILE target missing", &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };

                    // SONNY-3139, SONNY-3182, SONNY-3184 (round-3 review C1):
                    // the whole program passes the write-shape allowlist before
                    // the statement a PROFILE wraps runs by either path below.
                    // The planned runtime reached the query dispatcher with no
                    // validation (it also declines a statement that writes now).
                    execution.validateProgramShapes(&parse_result.program, exec_context) catch |err| {
                        failed_in_txn = true;
                        const info = proto_util.mapError(err);
                        var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };

                    if (target_stmt.* == .Query) {
                        var planned_query = target_stmt.Query;
                        if (planned_read_runtime.executeProfiledIfSupported(
                            allocator,
                            &planned_query,
                            exec_context,
                            bindings.names,
                            bindings.values,
                            true,
                        ) catch |err| {
                            failed_in_txn = true;
                            const info = proto_util.mapError(err);
                            var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                            defer resp.deinit(allocator);
                            return encodeMessage(allocator, resp);
                        }) |planned| {
                            var owned_planned = planned;
                            defer owned_planned.deinitMetadata(allocator);
                            defer owned_planned.result.deinit(allocator);
                            // CANARY: REQ=REQ-SONNY-3027-PROFILE-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=GrpcProfileSettle; STATUS=TESTED; TEST=tests/test_sonny3027_profile_engine_txn.zig; OWNER=storage; UPDATED=2026-09-27
                            // SONNY-3027: the session engine transaction the
                            // program's changes opened commits here, while the
                            // request still holds its write lock.
                            geode.graph_storage_adapter.settleThreadSessionTxn() catch |err| {
                                failed_in_txn = true;
                                const info = proto_util.mapError(err);
                                var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                                defer resp.deinit(allocator);
                                return encodeMessage(allocator, resp);
                            };
                            // CANARY: REQ=REQ-SONNY-2802-PROFILE-REGIME; FEATURE="StatementAuthorization"; ASPECT=GrpcProfileTxn; STATUS=TESTED; TEST=tests/test_sonny2802_profile_regime.zig; OWNER=security; UPDATED=2026-09-26
                            // SONNY-2802: a PROFILE'd change is its transaction's,
                            // recorded as soon as it ran, as the .rows arm does.
                            // The arm never recorded it: the transaction then
                            // changed a second graph, and its end locked another.
                            updateTxnStateFromProgram(state, &parse_result.program, if (stmt_plan.is_mutation) lock_graph else null);

                            for (flags.items) |flag| {
                                try appendFlagToResult(allocator, &owned_planned.result, flag);
                            }

                            const store_ptr = graph_store.getGlobalStore(allocator);
                            const profile_node_count: u64 = @intCast(store_ptr.getNodeCount());
                            const profile_edge_count: u64 = @intCast(store_ptr.getEdgeCount());
                            const profile_is_dirty = store_ptr.isDirty();

                            if (needs_store_lock) {
                                if (graph_lock_handle) |h| {
                                    // GAP-0511: Release lock before index rebuild
                                    graph_store.releaseGraphLock(h);
                                    lock_released = true;
                                    rebuildPendingIndexes(allocator, lock_graph, &pending_index_rebuilds);
                                }
                            }

                            if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                                if (state.authenticated_user) |auth_user| {
                                    const rls_graph = state.sessionGraph(); // SONNY-2776: the graph the rows came from
                                    _ = rls_filter.applyRLSFilter(allocator, &owned_planned.result, rls_engine, auth_user, rls_graph) catch |err| return postFilterErrorResponse(allocator, err);
                                }
                            }

                            const profile_msg = try profile_payload.buildProfilePayloadFromTrace(allocator, owned_planned.plan, owned_planned.trace, .{
                                .compact = store.config.compact_profile,
                                .include_mem_curve = store.config.memcurve_profile,
                                .disable_estimates = store.config.disable_estimates,
                                .spill_threshold = state.query_mem_limit_bytes,
                                .committed_txns = state.global_commit_ts,
                                .graph_store_nodes = profile_node_count,
                                .graph_store_edges = profile_edge_count,
                                .graph_store_dirty = profile_is_dirty,
                                .flagger_findings = owned_planned.result.flags.items,
                                .union_part_count = analysis.union_part_count,
                            });

                            const status = try proto_util.buildStatus(allocator, "00000", owned_planned.result.flags.items);
                            var resp = schema.ExecutionResponse{
                                .status = status,
                                .payload = .{ .profile = profile_msg },
                            };
                            defer resp.deinit(allocator);
                            return encodeMessage(allocator, resp);
                        }
                    }

                    var exec_result = execution.executeStatementWithContext(allocator, target_stmt.*, exec_context) catch |err| {
                        failed_in_txn = true;
                        const info = proto_util.mapError(err);
                        var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };
                    defer exec_result.deinit(allocator);
                    geode.graph_storage_adapter.settleThreadSessionTxn() catch |err| {
                        failed_in_txn = true;
                        const info = proto_util.mapError(err);
                        var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };
                    // SONNY-2802: see the planned path above.
                    updateTxnStateFromProgram(state, &parse_result.program, if (stmt_plan.is_mutation) lock_graph else null);

                    // CANARY: REQ=REQ-SEC-RLS-ALGO-001; FEATURE="RLS Algorithm Filtering"; ASPECT=gRPCProfileWire; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
                    // Algorithm RLS filter BEFORE lock release — requires store access.
                    const store_ptr = graph_store.getGlobalStore(allocator);
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.sessionGraph(); // SONNY-2776: the graph the rows came from
                            _ = rls_filter.applyAlgorithmRLSFilter(allocator, &exec_result, rls_engine, store_ptr, auth_user, rls_graph) catch |err| return postFilterErrorResponse(allocator, err);
                        }
                    }

                    // #564: Release lock after execution, before serialization/network I/O
                    if (needs_store_lock) {
                        if (graph_lock_handle) |h| {
                            // GAP-0511: Release lock before index rebuild
                            graph_store.releaseGraphLock(h);
                            lock_released = true;
                            rebuildPendingIndexes(allocator, lock_graph, &pending_index_rebuilds);
                        }
                    }

                    for (flags.items) |flag| {
                        try appendFlagToResult(allocator, &exec_result, flag);
                    }

                    // S1: Apply RLS filter on gRPC PROFILE path (parity with QUIC handler).
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.sessionGraph(); // SONNY-2776: the graph the rows came from
                            _ = rls_filter.applyRLSFilter(allocator, &exec_result, rls_engine, auth_user, rls_graph) catch |err| return postFilterErrorResponse(allocator, err);
                        }
                    }
                    const profile_msg = try profile_payload.buildProfilePayload(allocator, traits, exec_result.rows.len, .{
                        .compact = store.config.compact_profile,
                        .include_mem_curve = store.config.memcurve_profile,
                        .disable_estimates = store.config.disable_estimates,
                        .spill_threshold = state.query_mem_limit_bytes,
                        .committed_txns = state.global_commit_ts,
                        .graph_store_nodes = @intCast(store_ptr.getNodeCount()),
                        .graph_store_edges = @intCast(store_ptr.getEdgeCount()),
                        .graph_store_dirty = store_ptr.isDirty(),
                        .flagger_findings = exec_result.flags.items,
                        .union_part_count = analysis.union_part_count,
                    });

                    const status = try proto_util.buildStatus(allocator, "00000", exec_result.flags.items);
                    var resp = schema.ExecutionResponse{
                        .status = status,
                        .payload = .{ .profile = profile_msg },
                    };
                    defer resp.deinit(allocator);

                    return encodeMessage(allocator, resp);
                },
                .rows => {
                    const rls_active = rls_filter.getGlobalRLSFilterEngine() != null and state.authenticated_user != null;
                    // GAP-0892: node-scan streaming executes only `analysis.target`;
                    // bail when other statements (SESSION SET, DDL, ...) must run
                    // (same gate as the QUIC handler).
                    if (!rls_active and !analysis.has_effectful_preamble) {
                        if (analysis.target) |target| {
                            if (target.* == .Query) {
                                const query_ptr = &target.Query;
                                // SONNY-3251 (round 15, F6): a limit the scan's
                                // WHERE ran into (a count is computed here)
                                // answers its SQLSTATE, not a Zig error.
                                const prepared_opt = node_scan_stream.prepare(allocator, query_ptr, exec_context, bindings.names, bindings.values, flags.items) catch |err| {
                                    // SONNY-3348 (round 19, m2): any error the
                                    // scan fails with fails its transaction.
                                    failed_in_txn = true;
                                    if (!geode.eval.isResourceLimitError(err)) return err;
                                    const info = proto_util.mapError(err);
                                    var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                                    defer resp.deinit(allocator);
                                    return encodeMessage(allocator, resp);
                                };
                                if (prepared_opt) |prepared_stream| {
                                    var active_stream = prepared_stream;
                                    errdefer active_stream.deinit();

                                    // FIX #1 (scan cancellation): wall-clock
                                    // deadline backstop so a gRPC node scan can
                                    // never linger unboundedly (holding the
                                    // SHARED read lock / burning CPU) if its
                                    // client goes away. 300 s default mirrors the
                                    // QUIC path's scan_query_timeout_ms default.
                                    active_stream.deadline_mono_ns = node_scan_stream.monoNanosNowForDeadline() + 300_000 * std.time.ns_per_ms;

                                    if (needs_store_lock) {
                                        if (graph_lock_handle) |h| {
                                            // GAP-0511: Release lock before index rebuild
                                            graph_store.releaseGraphLock(h);
                                            lock_released = true;
                                            rebuildPendingIndexes(allocator, lock_graph, &pending_index_rebuilds);
                                        }
                                    }

                                    // SONNY-1221: build the rows the schema
                                    // frame's column types come from BEFORE the
                                    // frame; they stay on the stream and the
                                    // first Pull serves them (twin of the QUIC
                                    // handler). If they cannot be built, answer
                                    // as the executor path does when its rows
                                    // fail.
                                    active_stream.prefetchSchemaSample(allocator) catch |err| {
                                        // SONNY-3348 (round 19, m2): and it fails
                                        // its transaction, as the executor's do.
                                        failed_in_txn = true;
                                        const info = proto_util.mapError(err);
                                        var err_resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                                        defer err_resp.deinit(allocator);
                                        const encoded = try encodeMessage(allocator, err_resp);
                                        active_stream.deinit();
                                        return encoded;
                                    };
                                    const status = try proto_util.buildStatus(allocator, "00000", active_stream.flags);
                                    const schema_def = try active_stream.buildSchema(allocator);
                                    var schema_resp = schema.ExecutionResponse{
                                        .status = status,
                                        .payload = .{ .schema = schema_def },
                                    };
                                    defer schema_resp.deinit(allocator);

                                    state.active_node_scan_stream = active_stream;
                                    state.active_result = true;
                                    state.result_page_index = 0;
                                    state.result_ordered = false;
                                    state.result_order_keys = &.{};

                                    updateTxnStateFromProgram(state, &parse_result.program, if (stmt_plan.is_mutation) lock_graph else null);
                                    return encodeMessage(allocator, schema_resp);
                                }
                            }
                        }
                    }

                    var exec_result = execution.executeProgramWithContext(allocator, &parse_result.program, exec_context) catch |err| {
                        failed_in_txn = true;
                        const info = proto_util.mapError(err);
                        var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };
                    var store_result = false;
                    defer if (!store_result) exec_result.deinit(allocator);
                    // SONNY-3027: see the .profile arm.
                    geode.graph_storage_adapter.settleThreadSessionTxn() catch |err| {
                        failed_in_txn = true;
                        const info = proto_util.mapError(err);
                        var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };
                    // SONNY-2805: the session's transaction as the program left
                    // it, recorded before anything below (the post-filter, the
                    // response) can fail the request.
                    updateTxnStateFromProgram(state, &parse_result.program, if (stmt_plan.is_mutation) lock_graph else null);

                    // CANARY: REQ=REQ-SEC-RLS-ALGO-001; FEATURE="RLS Algorithm Filtering"; ASPECT=gRPCRowsWire; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
                    // Algorithm RLS filter BEFORE lock release — requires store access.
                    // SONNY-2733: a self-locking program holds no lock here, and
                    // its rows (edge ids) carry no node ids to look up.
                    if (!self_locking) {
                        const algo_store = graph_store.getGlobalStore(allocator);
                        if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                            if (state.authenticated_user) |auth_user| {
                                const rls_graph = state.sessionGraph(); // SONNY-2776: the graph the rows came from
                                _ = rls_filter.applyAlgorithmRLSFilter(allocator, &exec_result, rls_engine, algo_store, auth_user, rls_graph) catch |err| return postFilterErrorResponse(allocator, err);
                            }
                        }
                    }

                    // #564: Release lock after execution, before serialization/network I/O
                    if (needs_store_lock) {
                        if (graph_lock_handle) |h| {
                            // GAP-0511: Release lock before index rebuild
                            graph_store.releaseGraphLock(h);
                            lock_released = true;
                            rebuildPendingIndexes(allocator, lock_graph, &pending_index_rebuilds);
                        }
                    }

                    for (flags.items) |flag| {
                        try appendFlagToResult(allocator, &exec_result, flag);
                    }

                    // S1: Apply RLS filter on gRPC rows path (parity with QUIC handler).
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.sessionGraph(); // SONNY-2776: the graph the rows came from
                            _ = rls_filter.applyRLSFilter(allocator, &exec_result, rls_engine, auth_user, rls_graph) catch |err| return postFilterErrorResponse(allocator, err);
                        }
                    }

                    var order_keys: []const []const u8 = &.{};
                    defer if (!store_result) {
                        for (order_keys) |key| allocator.free(key);
                        if (order_keys.len > 0) allocator.free(order_keys);
                    };
                    if (ordered) {
                        if (findOrderBy(&parse_result.program)) |ob| {
                            order_keys = try buildOrderKeys(allocator, ob, &exec_result);
                        }
                    }

                    const status = try proto_util.buildStatus(allocator, "00000", exec_result.flags.items);
                    const schema_def = try proto_util.buildSchemaDefinition(allocator, &exec_result);
                    var schema_resp = schema.ExecutionResponse{
                        .status = status,
                        .payload = .{ .schema = schema_def },
                    };
                    defer schema_resp.deinit(allocator);

                    // Deep-copy result to prevent use-after-free when AST is freed
                    // (gRPC streaming builds data pages after handleExecute returns)
                    var duped = try execution.duplicateResult(allocator, exec_result);
                    // SONNY-3385: the stored result outlives this request, and
                    // the nodes and relationships it holds may live in the
                    // request's scratch arena (`ownGraphEntities`): it owns
                    // copies of them.
                    execution.ownGraphEntities(allocator, &duped) catch |err| {
                        duped.deinit(allocator);
                        return err;
                    };
                    exec_result.deinit(allocator);
                    store_result = true;
                    state.active_result_values = duped;
                    state.active_result = true;
                    state.result_page_index = 0;
                    state.result_ordered = ordered;
                    state.result_order_keys = order_keys;

                    return encodeMessage(allocator, schema_resp);
                },
            }
        },
    }
}

/// `pub` as a SONNY-1221 test seam only; production dispatch must go through
/// `handlePacket` (see SessionStore).
pub fn handlePull(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.PullRequest, &reader, allocator) catch |err| {
        log.err("Failed to decode Pull request", &.{Attr.string("error", @errorName(err))});
        var resp = try buildErrorResponse(allocator, "22023", "Invalid pull request", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0) {
        var resp = try buildErrorResponse(allocator, "28000", "Missing session_id", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    }

    const store = getSessionStore() orelse {
        var resp = try buildErrorResponse(allocator, "58000", "Server not initialized", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    };

    const entry = store.acquire(req.session_id) orelse {
        throttleInvalidSessionProbe();
        var resp = try buildErrorResponse(allocator, "28000", "Unknown session", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    };
    // SONNY-3032: held for the request; the reaper closes only an unheld session.
    defer store.release(entry);

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;
    // SONNY-2799, SONNY-2823: the session's undo-log and engine transactions
    // are this thread's for the request, whichever worker thread serves it.
    const txn_scope = state.enterSessionTxn();
    defer state.leaveSessionTxn(txn_scope);
    // SONNY-6334: the session's request context (tenant, FLE role,
    // decrypt_field gate) on this thread for the request, as QUIC does.
    state.installRequestThreadState();
    defer server_state.ServerState.clearRequestThreadState();

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        .missing => {
            var resp = try buildErrorResponse(allocator, "28000", "Authentication required", &.{}, &.{});
            defer resp.deinit(allocator);
            const pull_resp = schema.PullResponse{ .response = resp };
            return encodeMessage(allocator, pull_resp);
        },
        .invalidated => {
            var resp = try buildErrorResponse(allocator, "28000", "Session invalidated due to credential or role change", &.{}, &.{});
            defer resp.deinit(allocator);
            const pull_resp = schema.PullResponse{ .response = resp };
            return encodeMessage(allocator, pull_resp);
        },
    }

    // Arena allocator for pull page serialization (Issue #446)
    var pull_arena = std.heap.ArenaAllocator.init(allocator);
    defer pull_arena.deinit();
    const pa = pull_arena.allocator();

    if (state.active_node_scan_stream) |*active_stream| {
        // SONNY-3251 (round 15, F6): a limit a page's WHERE ran into ends
        // the stream with its SQLSTATE.
        var page_result = active_stream.buildNextPage(allocator, req.page_size) catch |err| {
            if (!geode.eval.isResourceLimitError(err)) return err;
            state.resetResult();
            // SONNY-3348 (round 19, m2): a later page's failure fails the
            // transaction the statement ran in, as its first page's would.
            abortTxnAfterPullFailure(state);
            const info = proto_util.mapError(err);
            var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
            defer resp.deinit(allocator);
            const pull_resp = schema.PullResponse{ .response = resp };
            return encodeMessage(allocator, pull_resp);
        };
        defer page_result.result.deinit(allocator);

        const page = try proto_util.buildDataPageFromRows(pa, page_result.result.rows, page_result.final, false, &.{});
        const status = try proto_util.buildStatus(pa, "00000", active_stream.flags);
        const resp = schema.ExecutionResponse{
            .status = status,
            .payload = .{ .page = page },
        };

        const pull_resp = schema.PullResponse{ .response = resp };
        const encoded_tmp = try encodeMessage(pa, pull_resp);
        const encoded = try allocator.dupe(u8, encoded_tmp);

        if (page.final) {
            state.resetResult();
        }

        return encoded;
    }

    const result_ptr = if (state.active_result_values) |*res| res else {
        var resp = try buildErrorResponse(allocator, "02000", "No active result set", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    };

    const start = state.result_page_index;

    const page = try proto_util.buildDataPage(pa, result_ptr, start, req.page_size, state.result_ordered, state.result_order_keys);
    state.result_page_index += page.rows.items.len;

    const status = try proto_util.buildStatus(pa, "00000", result_ptr.flags.items);
    const resp = schema.ExecutionResponse{
        .status = status,
        .payload = .{ .page = page },
    };

    const pull_resp = schema.PullResponse{ .response = resp };
    const encoded_tmp = try encodeMessage(pa, pull_resp);
    const encoded = try allocator.dupe(u8, encoded_tmp);

    if (page.final) {
        state.resetResult();
    }

    return encoded;
}

/// `pub` as a SONNY-2776 test seam only; production dispatch goes through
/// `handlePacket`.
pub fn handleBegin(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.BeginRequest, &reader, allocator) catch {
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0) {
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    }

    const store = getSessionStore() orelse {
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    };

    const entry = store.acquire(req.session_id) orelse {
        throttleInvalidSessionProbe();
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    };
    // SONNY-3032: held for the request; the reaper closes only an unheld session.
    defer store.release(entry);

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;
    // SONNY-2799, SONNY-2823: the session's undo-log and engine transactions
    // are this thread's for the request, whichever worker thread serves it.
    const txn_scope = state.enterSessionTxn();
    defer state.leaveSessionTxn(txn_scope);

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        else => {
            const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
            return encodeMessage(allocator, resp);
        },
    }

    // SONNY-3348 (round 18, I2): nor while its last transaction is aborted.
    if (state.in_txn or state.txn_aborted) {
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    }

    state.clearTxnGraph();
    state.in_txn = true;
    state.session_snapshot_ts = state.global_commit_ts;
    // SONNY-2799: the transaction's id is its undo-log transaction's, which
    // the session keeps across requests (`leaveSessionTxn`).
    txn_undo_log.getGlobalUndoLog(allocator).begin();
    state.txn_id = txn_undo_log.currentThreadTxnId();

    const tx_id_str = try std.fmt.allocPrint(allocator, "{d}", .{state.txn_id});
    const resp = schema.BeginResponse{
        .session_id = try allocator.dupe(u8, req.session_id),
        .tx_id = tx_id_str,
    };
    return encodeMessage(allocator, resp);
}

/// `pub` as a SONNY-2776 test seam only; production dispatch goes through
/// `handlePacket`.
pub fn handleCommit(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.CommitRequest, &reader, allocator) catch {
        const resp = schema.CommitResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0) {
        const resp = schema.CommitResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    const store = getSessionStore() orelse {
        const resp = schema.CommitResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const entry = store.acquire(req.session_id) orelse {
        throttleInvalidSessionProbe();
        const resp = schema.CommitResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    // SONNY-3032: held for the request; the reaper closes only an unheld session.
    defer store.release(entry);

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;
    // SONNY-2799, SONNY-2823: the session's undo-log and engine transactions
    // are this thread's for the request, whichever worker thread serves it.
    const txn_scope = state.enterSessionTxn();
    defer state.leaveSessionTxn(txn_scope);

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        else => {
            const resp = schema.CommitResponse{ .success = false };
            return encodeMessage(allocator, resp);
        },
    }

    // SONNY-3348 (round 18, I2): COMMIT of an aborted transaction ends it,
    // and fails: it was rolled back.
    if (state.txn_aborted) {
        state.txn_aborted = false;
        // SONNY-3348 (round 19, m5): with the code a COMMIT statement answers
        // (40000), or 40003 when the rollback could not undo every change.
        const resp = schema.CommitResponse{ .success = false, .@"error" = txnEndError(if (state.takeRollbackIncomplete()) error.RollbackIncomplete else error.TransactionRolledBack) };
        return encodeMessage(allocator, resp);
    }

    if (state.in_txn) {
        // SONNY-2776: the graph the transaction changed (it used to be
        // `current_graph`, never set on gRPC: always `default`).
        const commit_graph = state.txnLockGraph(state.sessionGraph());
        const commit_lock = graph_store.acquireGraphWriteLock(commit_graph);
        defer graph_store.releaseGraphLock(commit_lock);

        // CANARY: REQ=REQ-SONNY-2823-SESSION-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=GrpcCommit; STATUS=TESTED; TEST=tests/test_sonny2823_session_engine_txn.zig; OWNER=storage; UPDATED=2026-09-26
        // SONNY-2823: and the session's engine transaction. gRPC never
        // committed it: the transaction's writes on its shard had no COMMIT
        // record, and were gone after a crash. SONNY-3031: first; if it
        // cannot commit, the transaction is rolled back and COMMIT fails.
        state.commitEngineTxn() catch {
            txn_undo_log.getGlobalUndoLog(allocator).rollback(graph_store.getWritableGlobalStore(allocator)) catch |err| {
                log.warn("transaction rollback after a failed commit failed", &.{Attr.string("error", @errorName(err))});
            };
            state.endTransaction();
            const resp = schema.CommitResponse{ .success = false, .@"error" = txnEndError(error.SessionCommitFailed) };
            return encodeMessage(allocator, resp);
        };
        const store_ptr = graph_store.getGlobalStore(allocator);
        txn_undo_log.getGlobalUndoLog(allocator).commit(store_ptr);

        state.global_commit_ts += 1;
        state.endTransaction();
        const resp = schema.CommitResponse{ .success = true };
        return encodeMessage(allocator, resp);
    }

    const resp = schema.CommitResponse{ .success = false };
    return encodeMessage(allocator, resp);
}

/// `pub` as a SONNY-2776 test seam only; production dispatch goes through
/// `handlePacket`.
pub fn handleRollback(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.RollbackRequest, &reader, allocator) catch {
        const resp = schema.RollbackResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0) {
        const resp = schema.RollbackResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    const store = getSessionStore() orelse {
        const resp = schema.RollbackResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const entry = store.acquire(req.session_id) orelse {
        throttleInvalidSessionProbe();
        const resp = schema.RollbackResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    // SONNY-3032: held for the request; the reaper closes only an unheld session.
    defer store.release(entry);

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;
    // SONNY-2799, SONNY-2823: the session's undo-log and engine transactions
    // are this thread's for the request, whichever worker thread serves it.
    const txn_scope = state.enterSessionTxn();
    defer state.leaveSessionTxn(txn_scope);

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        else => {
            const resp = schema.RollbackResponse{ .success = false };
            return encodeMessage(allocator, resp);
        },
    }

    // SONNY-3348 (round 18, I2): ROLLBACK ends an aborted transaction (the
    // failed statement's handler already undid it).
    if (state.txn_aborted) {
        state.txn_aborted = false;
        // SONNY-3348 (round 19, m3): a rollback that could not undo every
        // change is reported (40003), not answered as a success.
        const resp = rollbackResponse(state.takeRollbackIncomplete());
        return encodeMessage(allocator, resp);
    }

    if (state.in_txn) {
        // SONNY-2776: the rollback changes the store back; it took no lock.
        // It now holds the write lock of the graph the transaction changed.
        // SONNY-2823: `rollBackTransaction` aborts the session's engine
        // transaction first, which gRPC never did.
        state.rollBackTransaction(state.sessionGraph());
        const resp = rollbackResponse(state.takeRollbackIncomplete());
        return encodeMessage(allocator, resp);
    }

    const resp = schema.RollbackResponse{ .success = false };
    return encodeMessage(allocator, resp);
}

// ============================================================================
// Issue #515: 7 new gRPC message handlers (matching QUIC handler behavior)
// CANARY: REQ=REQ-GRPC-FULL-ROUTING-001; FEATURE="GrpcFullMessageRouting"; ASPECT=HandlerParity; STATUS=IMPL; OWNER=transport; UPDATED=2026-02-13
// ============================================================================

// CANARY: REQ=REQ-TXN-SAVEPOINT-006; FEATURE="TransactionSavepoints"; ASPECT=GrpcSavepoint; STATUS=IMPL; OWNER=transport; UPDATED=2026-04-01
fn handleSavepoint(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.SavepointRequest, &reader, allocator) catch {
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0 or req.name.len == 0) {
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    const sess_store = getSessionStore() orelse {
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const entry = sess_store.acquire(req.session_id) orelse {
        throttleInvalidSessionProbe();
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    // SONNY-3032: held for the request; the reaper closes only an unheld session.
    defer sess_store.release(entry);

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;
    // SONNY-2799, SONNY-2823: the session's undo-log and engine transactions
    // are this thread's for the request, whichever worker thread serves it.
    const txn_scope = state.enterSessionTxn();
    defer state.leaveSessionTxn(txn_scope);

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        else => {
            const resp = schema.SavepointResponse{ .success = false };
            return encodeMessage(allocator, resp);
        },
    }

    if (!state.in_txn) {
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    const undo = txn_undo_log.getGlobalUndoLog(allocator);
    undo.createSavepoint(req.name) catch {
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const resp = schema.SavepointResponse{ .success = true };
    return encodeMessage(allocator, resp);
}

// CANARY: REQ=REQ-TXN-SAVEPOINT-007; FEATURE="TransactionSavepoints"; ASPECT=GrpcRollbackTo; STATUS=IMPL; OWNER=transport; UPDATED=2026-04-01
fn handleRollbackTo(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.RollbackToRequest, &reader, allocator) catch {
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0 or req.name.len == 0) {
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    const sess_store = getSessionStore() orelse {
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const entry = sess_store.acquire(req.session_id) orelse {
        throttleInvalidSessionProbe();
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    // SONNY-3032: held for the request; the reaper closes only an unheld session.
    defer sess_store.release(entry);

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;
    // SONNY-2799, SONNY-2823: the session's undo-log and engine transactions
    // are this thread's for the request, whichever worker thread serves it.
    const txn_scope = state.enterSessionTxn();
    defer state.leaveSessionTxn(txn_scope);

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        else => {
            const resp = schema.RollbackToResponse{ .success = false };
            return encodeMessage(allocator, resp);
        },
    }

    if (!state.in_txn) {
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    // SONNY-2776: the partial rollback changes the store back; it took no
    // lock. It holds the write lock of the graph the transaction changed.
    const rts_lock = graph_store.acquireGraphWriteLock(state.txnLockGraph(state.sessionGraph()));
    defer graph_store.releaseGraphLock(rts_lock);
    const store_ptr = graph_store.getGlobalStore(allocator);
    const undo = txn_undo_log.getGlobalUndoLog(allocator);
    undo.rollbackToSavepoint(req.name, store_ptr) catch {
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const resp = schema.RollbackToResponse{ .success = true };
    return encodeMessage(allocator, resp);
}

fn handleCdcDiag(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // SEC-002 (#849): Authenticate before exposing any diagnostic data.
    // Decode the request to read session_id; on any non-.ok auth status return
    // the SAFE empty/default response (leaks no diagnostics).
    var diag_reader: std.Io.Reader = .fixed(request_bytes);
    var diag_req = protobuf.decode(schema.CdcDiagnosticsRequest, &diag_reader, allocator) catch {
        // Undecodable body — treat as unauthenticated (no session_id). Return safe default.
        var safe_resp = schema.CdcDiagnosticsResponse{
            .config = .{ .enabled = false },
            .engine = .{ .is_running = false },
            .malformed_snapshots = std.ArrayList(schema.CdcMalformedSnapshot).empty,
            .malformed_hashes = std.ArrayList(schema.CdcMalformedHash).empty,
            .version = try allocator.dupe(u8, @import("build_options").version),
            .timestamp_ms = compat_milliTimestamp(),
        };
        defer safe_resp.deinit(allocator);
        return try encodeMessage(allocator, safe_resp);
    };
    defer diag_req.deinit(allocator);

    switch (try authorizeAdminSession(diag_req.session_id, allocator)) {
        .ok => {},
        .missing, .invalidated, .forbidden => {
            // Return safe default — leaks no diagnostics.
            var safe_resp = schema.CdcDiagnosticsResponse{
                .config = .{ .enabled = false },
                .engine = .{ .is_running = false },
                .malformed_snapshots = std.ArrayList(schema.CdcMalformedSnapshot).empty,
                .malformed_hashes = std.ArrayList(schema.CdcMalformedHash).empty,
                .version = try allocator.dupe(u8, @import("build_options").version),
                .timestamp_ms = compat_milliTimestamp(),
            };
            defer safe_resp.deinit(allocator);
            return try encodeMessage(allocator, safe_resp);
        },
    }

    // GAP-0255: Use the real global CDC engine when available (parity with QUIC handler).
    // Acquire CDC mutex for thread-safe access (parity with procedure_registry).
    const cdc_mutex = execution.getCdcMutex();
    cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (execution.getGlobalCdcEngine()) |eng| {
        const resp = try eng.exportDiagnostics(allocator);
        return encodeMessage(allocator, resp);
    }
    // No CDC engine running — return default diagnostics
    const resp = schema.CdcDiagnosticsResponse{
        .config = .{ .enabled = false },
        .engine = .{ .is_running = false },
        .malformed_snapshots = std.ArrayList(schema.CdcMalformedSnapshot).empty,
        .malformed_hashes = std.ArrayList(schema.CdcMalformedHash).empty,
        .version = try allocator.dupe(u8, @import("build_options").version),
        .timestamp_ms = compat_milliTimestamp(),
    };
    return encodeMessage(allocator, resp);
}

fn handleCdcCtrl(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // SEC-002 (#849): Authenticate before touching the CDC engine.
    // Decode the request FIRST to read session_id, then gate before
    // execution.getGlobalCdcEngine().  This closes both the native gRPC path
    // AND the legacy handleLegacyPacket shim which calls this handler directly.
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.CdcControlRequest, &reader, allocator) catch {
        var inval_resp = schema.CdcControlResponse{
            .success = false,
            .status = try allocator.dupe(u8, "INVALID_REQUEST"),
            .guardrail_epoch = 0,
        };
        defer inval_resp.deinit(allocator);
        return try encodeMessage(allocator, inval_resp);
    };
    defer req.deinit(allocator);

    switch (try authorizeAdminSession(req.session_id, allocator)) {
        .ok => {},
        .missing, .invalidated, .forbidden => {
            var auth_resp = schema.CdcControlResponse{
                .success = false,
                .status = try allocator.dupe(u8, "AUTH_REQUIRED"),
                .guardrail_epoch = 0,
            };
            defer auth_resp.deinit(allocator);
            return try encodeMessage(allocator, auth_resp);
        },
    }

    // GAP-0255: Use the real global CDC engine when available (parity with QUIC handler).
    // Acquire CDC mutex for thread-safe access (parity with procedure_registry).
    const cdc_mutex = execution.getCdcMutex();
    cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (execution.getGlobalCdcEngine()) |eng| {
        if (std.ascii.eqlIgnoreCase(req.action, "RESET_GUARDRAILS")) {
            eng.resetGuardrailState();
            var ok_resp = schema.CdcControlResponse{
                .success = true,
                .status = try allocator.dupe(u8, "OK"),
                .guardrail_epoch = eng.guardrail_epoch,
            };
            defer ok_resp.deinit(allocator);
            return try encodeMessage(allocator, ok_resp);
        } else {
            var unsup_resp = schema.CdcControlResponse{
                .success = false,
                .status = try allocator.dupe(u8, "UNSUPPORTED"),
                .guardrail_epoch = eng.guardrail_epoch,
            };
            defer unsup_resp.deinit(allocator);
            return try encodeMessage(allocator, unsup_resp);
        }
    }
    // No CDC engine running — return NO_ENGINE
    var no_eng_resp = schema.CdcControlResponse{
        .success = false,
        .status = try allocator.dupe(u8, "NO_ENGINE"),
        .guardrail_epoch = 0,
    };
    defer no_eng_resp.deinit(allocator);
    return try encodeMessage(allocator, no_eng_resp);
}

fn handleBackup(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.BackupRequest, &reader, allocator) catch {
        const resp = schema.BackupResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Invalid backup request"),
        };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    switch (try authorizeAdminSession(req.session_id, allocator)) {
        .ok => {},
        .missing => {
            const resp = schema.BackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Authentication required"),
            };
            return encodeMessage(allocator, resp);
        },
        .invalidated => {
            const resp = schema.BackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Session invalidated due to credential or role change"),
            };
            return encodeMessage(allocator, resp);
        },
        .forbidden => {
            const resp = schema.BackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Permission denied: Admin role required for backup operations"),
            };
            return encodeMessage(allocator, resp);
        },
    }

    // GAP-0255: Acquire shared store lock for backup consistency (parity with QUIC handler).
    // P1: Per-graph locking — back up with a read lock on the default graph.
    const backup_lock_handle = graph_store.acquireGraphReadLockTagged(graph_store.DEFAULT_GRAPH_NAME, .misc);
    defer graph_store.releaseGraphLock(backup_lock_handle);

    // SONNY-6299: under the data directory (or GEODE_BACKUP_DIR), not
    // ./server_backups of the working directory.
    var mgr = SimplifiedBackupManager.initForServer(allocator, .{
        // GAP-0880: gzip is the only compression codec with a real encoder;
        // never request zstd (no encoder — UnsupportedCompression).
        .compression = if (req.compress) .gzip else .none,
        // SONNY-6355: encrypted under GEODE_TDE_KEY when it is set.
        .encryption = backup_mgr.encryptionFromEnv(),
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Backup init failed: {s}", .{@errorName(err)});
        const resp = schema.BackupResponse{ .success = false, .message = msg };
        return encodeMessage(allocator, resp);
    };
    defer mgr.deinit();

    if (!std.ascii.eqlIgnoreCase(req.backup_type, "full")) {
        const msg = try allocator.dupe(u8, "Only full backups are supported with GraphStore");
        const resp = schema.BackupResponse{ .success = false, .message = msg };
        return encodeMessage(allocator, resp);
    }

    const metadata = mgr.createFullBackup() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Backup failed: {s}", .{@errorName(err)});
        const resp = schema.BackupResponse{ .success = false, .message = msg };
        return encodeMessage(allocator, resp);
    };

    const resp = schema.BackupResponse{
        .success = true,
        .message = try allocator.dupe(u8, "Backup completed successfully"),
        .backup_id = try std.fmt.allocPrint(allocator, "{x}", .{metadata.backup_id}),
        .backup_type = try allocator.dupe(u8, @tagName(metadata.backup_type)),
        .size_bytes = metadata.size_bytes,
        .compression = try allocator.dupe(u8, @tagName(metadata.compression)),
        .checksum = try std.fmt.allocPrint(allocator, "{x}", .{metadata.checksum}),
    };
    return encodeMessage(allocator, resp);
}

/// The authenticated username of `session_id`, copied into `buf` (for an
/// audit record); "" when there is none or it does not fit.
fn sessionUsername(session_id: []const u8, buf: []u8) []const u8 {
    if (session_id.len == 0) return "";
    const store = getSessionStore() orelse return "";
    const entry = store.acquire(session_id) orelse return "";
    defer store.release(entry);
    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const name = entry.state.authenticated_user orelse return "";
    if (name.len > buf.len) return "";
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

fn handleRestore(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.RestoreRequest, &reader, allocator) catch {
        const resp = schema.RestoreResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Invalid restore request"),
        };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    switch (try authorizeAdminSession(req.session_id, allocator)) {
        .ok => {},
        .missing => {
            const resp = schema.RestoreResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Authentication required"),
            };
            return encodeMessage(allocator, resp);
        },
        .invalidated => {
            const resp = schema.RestoreResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Session invalidated due to credential or role change"),
            };
            return encodeMessage(allocator, resp);
        },
        .forbidden => {
            const resp = schema.RestoreResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Permission denied: Admin role required for restore operations"),
            };
            return encodeMessage(allocator, resp);
        },
    }

    if (!req.confirm) {
        const resp = schema.RestoreResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Restore requires confirmation"),
        };
        return encodeMessage(allocator, resp);
    }

    // SONNY-6288: same restore as the QUIC handler (backup_manager.
    // restoreForServer): into a new directory beside the server's data
    // directory, never into the live store (which used to be GEODE_DATA_DIR
    // or ./data, written in place while this server kept serving old data).
    var user_buf: [256]u8 = undefined;
    const username = sessionUsername(req.session_id, &user_buf);
    const result = try backup_mgr.restoreForServerDefault(allocator, req.target_time, username);
    defer allocator.free(result.message);
    defer allocator.free(result.restore_dir);
    const resp = schema.RestoreResponse{
        .success = result.success,
        .message = result.message,
        .restore_dir = result.restore_dir,
        .target_time = if (req.target_time.len > 0) req.target_time else "latest",
        .restore_timestamp = @intCast(compat_milliTimestamp()),
    };
    return encodeMessage(allocator, resp);
}

fn handleUploadBackup(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.UploadBackupRequest, &reader, allocator) catch {
        const resp = schema.UploadBackupResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Invalid upload request"),
        };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    switch (try authorizeAdminSession(req.session_id, allocator)) {
        .ok => {},
        .missing => {
            const resp = schema.UploadBackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Authentication required"),
            };
            return encodeMessage(allocator, resp);
        },
        .invalidated => {
            const resp = schema.UploadBackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Session invalidated due to credential or role change"),
            };
            return encodeMessage(allocator, resp);
        },
        .forbidden => {
            const resp = schema.UploadBackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Permission denied: Admin role required for backup upload"),
            };
            return encodeMessage(allocator, resp);
        },
    }

    // GAP-0880: real upload ingestion (mirror of the QUIC handler). The
    // request must carry the complete backup artifact bytes; the old
    // metadata-only path created an EMPTY file and reported fake success.
    if (req.size_bytes == 0 or req.checksum.len == 0) {
        const resp = schema.UploadBackupResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Invalid upload request: missing size or checksum"),
        };
        return encodeMessage(allocator, resp);
    }
    if (req.payload.len == 0) {
        const resp = schema.UploadBackupResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Upload payload required: metadata-only upload is not supported"),
        };
        return encodeMessage(allocator, resp);
    }
    if (req.payload.len != req.size_bytes) {
        const resp = schema.UploadBackupResponse{
            .success = false,
            .message = try std.fmt.allocPrint(allocator, "Upload size mismatch: declared {d} bytes, received {d}", .{ req.size_bytes, req.payload.len }),
        };
        return encodeMessage(allocator, resp);
    }
    const expected_checksum = std.fmt.parseInt(u64, req.checksum, 16) catch {
        const resp = schema.UploadBackupResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Invalid checksum: expected hex CRC32 from BackupResponse"),
        };
        return encodeMessage(allocator, resp);
    };

    var upload_mgr = SimplifiedBackupManager.initForServer(allocator, .{}) catch |err| {
        const resp = schema.UploadBackupResponse{
            .success = false,
            .message = try std.fmt.allocPrint(allocator, "Upload init failed: {s}", .{@errorName(err)}),
        };
        return encodeMessage(allocator, resp);
    };
    defer upload_mgr.deinit();

    const ingested = upload_mgr.ingestUploadedBackup(req.payload, expected_checksum) catch |err| {
        const resp = schema.UploadBackupResponse{
            .success = false,
            .message = try std.fmt.allocPrint(allocator, "Upload rejected: {s}", .{@errorName(err)}),
        };
        return encodeMessage(allocator, resp);
    };

    const resp = schema.UploadBackupResponse{
        .success = true,
        .message = try allocator.dupe(u8, "Backup uploaded, verified, and registered"),
        .upload_path = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ upload_mgr.backupDir(), ingested.backup_id }),
    };
    return encodeMessage(allocator, resp);
}

// ============================================================================
// SEC-002 (#849): gRPC CDC handler auth unit tests
// ============================================================================

test "unauthenticated gRPC cdc_ctrl is rejected (SEC-002 live-engine path)" {
    const a = std.testing.allocator;
    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(true); // restore default
    // Encode a CdcControlRequest with NO session_id (unauthenticated caller).
    const req = schema.CdcControlRequest{ .action = "RESET_GUARDRAILS" };
    const req_bytes = try encodeMessage(a, req);
    defer a.free(req_bytes);
    const resp_bytes = try handleCdcCtrl(req_bytes, a);
    defer a.free(resp_bytes);
    var reader: std.Io.Reader = .fixed(resp_bytes);
    var resp = try protobuf.decode(schema.CdcControlResponse, &reader, a);
    defer resp.deinit(a);
    // POST-fix: gate fires before engine logic -> "AUTH_REQUIRED".
    // PRE-fix: never returns AUTH_REQUIRED (returns OK / NO_ENGINE / UNSUPPORTED).
    try std.testing.expectEqualStrings("AUTH_REQUIRED", resp.status);
}

test "auth-disabled gRPC cdc_ctrl bypasses the gate (no over-block)" {
    const a = std.testing.allocator;
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);
    const req = schema.CdcControlRequest{ .action = "RESET_GUARDRAILS" };
    const req_bytes = try encodeMessage(a, req);
    defer a.free(req_bytes);
    const resp_bytes = try handleCdcCtrl(req_bytes, a);
    defer a.free(resp_bytes);
    var reader: std.Io.Reader = .fixed(resp_bytes);
    var resp = try protobuf.decode(schema.CdcControlResponse, &reader, a);
    defer resp.deinit(a);
    // When auth is disabled, authorizeAdminSession returns .ok -> gate does NOT fire.
    // With no engine running, status is "NO_ENGINE" (not "AUTH_REQUIRED").
    try std.testing.expect(!std.mem.eql(u8, "AUTH_REQUIRED", resp.status));
}
