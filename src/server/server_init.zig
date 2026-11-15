const std = @import("std");

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

/// SONNY-6322: whether the store already holds `__geode_security` auth
/// records (persisted :User records on disk, records loaded in memory, or a
/// chain root). Fails closed: when it cannot tell, it answers yes, so no key
/// is invented over records it could not see.
/// SONNY-6499: an auth graph manager that cannot be opened is that error
/// (the caller refuses startup naming it), not "records exist": a data
/// directory the timeseries store refused (`..` in the path) was reported as
/// "HMAC key required" on a fresh directory.
fn storeHasAuthRecords(allocator: std.mem.Allocator, store: *graph_store.GraphStore) !bool {
    const persisted = auth_graph_manager.persistedSecurityUserCountOnDisk() catch return true;
    if (persisted > 0) return true;
    var agm = try auth_graph_manager.AuthGraphManager.init(allocator, store);
    defer agm.deinit();
    return agm.countAuthRecords() > 0 or agm.storage.loadChainRoot() != null;
}

/// SONNY-6322: the startup refusal when auth records exist and no HMAC key
/// is available. Names the three ways to supply the key; no key bytes.
fn printHmacKeyRequired(data_dir: []const u8) void {
    std.debug.print(
        "[startup] HMAC key required: {s} holds __geode_security auth records sealed with an HMAC key, and no key was found. " ++
            "Supply the key the records were sealed with: GEODE_AUTH_HMAC_KEY=<64 hex characters>, GEODE_TDE_KEY=<64 hex characters> (the key is derived from it), " ++
            "or the file {s}/.geode_hmac_key (mode 0600). Nothing was written. A restored backup does not carry the key: use the source server's key " ++
            "(docs/GQL_AUTH_DDL.md, \"HMAC key\").\n",
        .{ data_dir, data_dir },
    );
    log.err("HMAC key required: auth records exist and no HMAC key is available; refusing to start (nothing written)", &.{
        Attr.string("data_dir", data_dir),
    });
}

/// SONNY-6339: the startup refusal when an HMAC key source is set but cannot
/// be used (a malformed or unreadable `.geode_hmac_key`, a malformed
/// GEODE_AUTH_HMAC_KEY) or the key file cannot be created. The server used to
/// run with the auth graph disabled. No key bytes.
fn printHmacKeyUnusable(data_dir: []const u8, err: anyerror) void {
    std.debug.print(
        "[startup] HMAC key unusable ({s}): the auth-chain key (GEODE_AUTH_HMAC_KEY, GEODE_TDE_KEY or {s}/.geode_hmac_key) " ++
            "cannot be read or created, so users, roles, grants and policies would not be durable. Refusing to start. " ++
            "Fix the key source (64 hex characters; the file mode 0600) (docs/GQL_AUTH_DDL.md, \"HMAC key\").\n",
        .{ @errorName(err), data_dir },
    );
    log.err("HMAC key unusable: refusing to start (the auth graph would be disabled)", &.{
        Attr.string("data_dir", data_dir),
        Attr.string("error", @errorName(err)),
    });
}

// CANARY: REQ=REQ-SONNY-6386-TDE-KEY-FAIL-CLOSED; FEATURE="TDE baseline"; ASPECT=ServerStartupRefusal; STATUS=TESTED; TEST=tests/test_sonny6386_tde_key_fail_closed.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6386: refuse to start when GEODE_TDE_KEY is set (non-empty) but is
/// not 64 hex characters. The store used to open with no page-encryption
/// key, writing every page in plaintext. Runs before the data directory is
/// created, so a refused start writes nothing. The value is never printed.
/// An unset or empty GEODE_TDE_KEY passes (no page encryption, as before).
pub fn refuseUnusableTdeKey(allocator: std.mem.Allocator) !void {
    _ = geode.tde_file_encryption.loadKey(allocator) catch |err| {
        std.debug.print(
            "[startup] GEODE_TDE_KEY is set but unusable ({s}): it must be exactly 64 hex characters (a 32-byte AES-256 key). " ++
                "Refusing to start: the store would otherwise be written without page encryption. Nothing was written. " ++
                "Fix the key, or unset GEODE_TDE_KEY to run without TDE (docs/TDE_FILE_LEVEL_ENCRYPTION.md).\n",
            .{@errorName(err)},
        );
        log.err("GEODE_TDE_KEY unusable: refusing to start (pages would be written unencrypted)", &.{
            Attr.string("error", @errorName(err)),
        });
        return error.TdeKeyInvalid;
    };
}

// CANARY: REQ=REQ-SONNY-6422-ENV-KEY-FAIL-CLOSED; FEATURE="Key configuration"; ASPECT=ServerStartupRefusal; STATUS=TESTED; TEST=tests/test_sonny6422_env_key_fail_closed.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6422: refuse to start when a key variable is set but unusable, the
/// same way `refuseUnusableTdeKey` does, before the data directory is
/// created. No value is printed.
///   - GEODE_AUDIT_PUB / GEODE_AUDIT_SEC: one without the other, a
///     malformed value, or a public key that is not the seed's. The audit
///     logger used to generate file-based keys instead.
///   - GEODE_MASTER_KEY: shorter than 32 bytes. It used to be hashed into a
///     key, so any short value worked as the FLE master key.
///   - GEODE_WAL_KEY: read by nothing in the server (the storage-engine WAL
///     is encrypted with GEODE_TDE_KEY), so a server given only
///     GEODE_WAL_KEY wrote its WAL in plaintext.
/// Unset (or empty) variables pass.
pub fn refuseUnusableKeyConfig(allocator: std.mem.Allocator) !void {
    if (geode.security.audit.AuditLogger.loadEnvSigningKey(allocator)) |maybe_kp| {
        if (maybe_kp) |kp| {
            var k = kp;
            k.deinit();
        }
    } else |err| {
        std.debug.print(
            "[startup] GEODE_AUDIT_PUB / GEODE_AUDIT_SEC unusable ({s}): set both or neither; GEODE_AUDIT_SEC is the 64 hex character Ed25519 seed " ++
                "and GEODE_AUDIT_PUB the 64 hex character public key of that seed. Refusing to start: the audit log would otherwise be signed with " ++
                "file-based keys you did not configure. Nothing was written (docs/AUDIT_LOGGING.md).\n",
            .{@errorName(err)},
        );
        log.err("audit signing key configuration unusable: refusing to start", &.{Attr.string("error", @errorName(err))});
        return error.AuditKeyConfigInvalid;
    }

    try refuseUnusableMasterKey();

    if (std.c.getenv("GEODE_WAL_KEY")) |raw| {
        if (std.mem.span(raw).len != 0) {
            std.debug.print(
                "[startup] GEODE_WAL_KEY is set, but the server does not use it: the storage-engine WAL is encrypted with GEODE_TDE_KEY, together with the pages. " ++
                    "Refusing to start rather than let you believe the WAL is encrypted with GEODE_WAL_KEY. Nothing was written. " ++
                    "Unset GEODE_WAL_KEY and set GEODE_TDE_KEY (docs/TDE_FILE_LEVEL_ENCRYPTION.md).\n",
                .{},
            );
            log.err("GEODE_WAL_KEY is not used by the server: refusing to start", &.{});
            return error.WalKeyUnsupported;
        }
    }
}

// CANARY: REQ=REQ-SONNY-6430-MASTER-KEY-FORMAT; FEATURE="Key configuration"; ASPECT=ServerStartupRefusalAndLegacyWarning; STATUS=TESTED; TEST=tests/test_sonny6430_master_key_format.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6422 / SONNY-6430: GEODE_MASTER_KEY read in the format
/// GEODE_MASTER_KEY_FORMAT names (`fle_key_manager.parseMasterKey`). A
/// value that does not match its format, an unknown format, a format without
/// a key and an unformatted value under 32 bytes refuse startup. An
/// unformatted value over 32 bytes starts with the key it always gave (its
/// first 32 bytes) and a warning that the rest is ignored. No value is
/// printed.
fn refuseUnusableMasterKey() !void {
    const km = geode.fle_key_manager;
    const docs = "docs/FIELD_LEVEL_ENCRYPTION.md, \"Master key format\"";
    const format = km.masterKeyFormatFromEnv() catch {
        std.debug.print(
            "[startup] GEODE_MASTER_KEY_FORMAT is set but unusable: it must be raw, hex or base64 (or unset). Refusing to start. Nothing was written ({s}).\n",
            .{docs},
        );
        log.err("GEODE_MASTER_KEY_FORMAT unknown: refusing to start", &.{});
        return error.MasterKeyFormatUnknown;
    };
    const value: []const u8 = if (std.c.getenv("GEODE_MASTER_KEY")) |raw| std.mem.span(raw) else "";
    if (value.len == 0) {
        if (format == .legacy) return;
        std.debug.print(
            "[startup] GEODE_MASTER_KEY_FORMAT is set but GEODE_MASTER_KEY is not. Refusing to start: set the key, or unset GEODE_MASTER_KEY_FORMAT to run without FLE. Nothing was written ({s}).\n",
            .{docs},
        );
        log.err("GEODE_MASTER_KEY_FORMAT without GEODE_MASTER_KEY: refusing to start", &.{});
        return error.MasterKeyRequired;
    }
    _ = km.parseMasterKey(value, format) catch |err| {
        switch (format) {
            .legacy => std.debug.print(
                "[startup] GEODE_MASTER_KEY is set but unusable: it is {d} bytes and must be at least {d} bytes (the first 32 bytes are the FLE master key), " ++
                    "or set GEODE_MASTER_KEY_FORMAT to hex (64 hex characters) or base64 (32 bytes). " ++
                    "Refusing to start: a short master key is a weak field-level-encryption key. Nothing was written. " ++
                    "Fix the key, or unset GEODE_MASTER_KEY to run without FLE ({s}).\n",
                .{ value.len, km.master_key_min_len, docs },
            ),
            .raw, .hex, .base64 => std.debug.print(
                "[startup] GEODE_MASTER_KEY is set but does not match GEODE_MASTER_KEY_FORMAT={s}: {s}. Refusing to start. Nothing was written ({s}).\n",
                .{ @tagName(format), switch (format) {
                    .raw => "raw takes exactly 32 bytes",
                    .hex => "hex takes exactly 64 hex characters",
                    else => "base64 takes the standard (padded) base64 of exactly 32 bytes",
                }, docs },
            ),
        }
        log.err("GEODE_MASTER_KEY unusable: refusing to start", &.{
            Attr.string("format", @tagName(format)),
            Attr.int("length", @intCast(value.len)),
        });
        return err;
    };
    if (format == .legacy and value.len > km.master_key_min_len) {
        std.debug.print(
            "[startup] WARNING: GEODE_MASTER_KEY is {d} bytes and GEODE_MASTER_KEY_FORMAT is not set, so only its first 32 bytes are the FLE master key and the rest is ignored " ++
                "(a 64-character hex value gives 128 bits, not 256). This is the key your encrypted fields were written with, so it is kept. " ++
                "To say so explicitly, set GEODE_MASTER_KEY to its first 32 characters with GEODE_MASTER_KEY_FORMAT=raw (the same key). " ++
                "GEODE_MASTER_KEY_FORMAT=hex reads the full value as a different key: only for a new deployment, or after re-encrypting ({s}).\n",
            .{ value.len, docs },
        );
        log.warn("GEODE_MASTER_KEY longer than 32 bytes without GEODE_MASTER_KEY_FORMAT: only the first 32 bytes are the key", &.{Attr.int("length", @intCast(value.len))});
    }
}

// CANARY: REQ=REQ-SONNY-6435-MASTER-KEY-CHECK; FEATURE="Key configuration"; ASPECT=StartupVerifyOrRecord; STATUS=TESTED; TEST=tests/test_sonny6435_master_key_check.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6435: refuse to start when GEODE_MASTER_KEY is not the key this
/// data directory's encrypted fields were written with. The directory keeps
/// the key's check value (`fle_key_manager.masterKeyCheckValue`, never the
/// key) in `fle_master_key.kcv` beside the FLE catalog, written like the
/// catalog (private, never through a link, under GEODE_TDE_KEY when set).
/// Without a key nothing is read or written: a deployment without FLE is
/// never blocked. With a key and no recorded value (a new directory, or one
/// from before this check) the value is recorded. A recorded value that
/// does not match, or a check file that cannot be read, refuses startup.
/// Nothing names the key.
pub fn refuseMismatchedMasterKey(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    // SONNY-6442: the check every FLE key path shares (geode fle, in-process FLE).
    return geode.fle_master_key_check.verifyOrRecord(allocator, data_dir, .serve);
}

/// SONNY-6339: the startup refusal for any other failure to establish the
/// durable auth state. No secrets.
fn printAuthStateUnavailable(data_dir: []const u8, what: []const u8, err: anyerror) void {
    std.debug.print("[startup] {s} failed in {s} ({s}); refusing to start without durable auth state\n", .{ what, data_dir, @errorName(err) });
    log.err("cannot establish durable auth state; refusing to start", &.{
        Attr.string("step", what),
        Attr.string("data_dir", data_dir),
        Attr.string("error", @errorName(err)),
    });
}

/// SONNY-2791: the policy record ids `env_name` lists (comma-separated):
/// GEODE_AUTH_RESEAL_ACCEPT_LEGACY, the records the startup reseal may sign
/// although they have no kind and their HMAC does not verify, and
/// GEODE_AUTH_RESEAL_DROP_LEGACY, the ones it deletes. At most `buf.len`; a
/// malformed entry is skipped (so it is not decided).
fn parseLegacyPolicyIds(allocator: std.mem.Allocator, env_name: []const u8, buf: []u64) []const u64 {
    const raw = getEnvVarOwned(allocator, env_name) catch return buf[0..0];
    defer allocator.free(raw);
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, raw, ", ");
    while (it.next()) |tok| {
        if (n == buf.len) break;
        buf[n] = std.fmt.parseInt(u64, tok, 10) catch continue;
        n += 1;
    }
    return buf[0..n];
}

const geode = @import("geode");
const server_flags = geode.server_flags;
// CANARY: REQ=REQ-BINARY-PERSIST-001; FEATURE="BinaryPersistence"; ASPECT=ServerInit; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=server; UPDATED=2026-06-11
const graph_store = geode.graph_store;
const index_catalog = @import("index_catalog.zig");
const query_ast_cache = @import("query_ast_cache");
const query_plan_cache = geode.query_plan_cache;
// CANARY: REQ=REQ-ABAC-WIRE-001; FEATURE="ABAC Enforcement"; ASPECT=ServerInit; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
// GAP-0165: Import geode_auth for SecurityManager initialization at server startup
const geode_auth = @import("geode_auth");
// CANARY: REQ=REQ-AUTH-GRAPH-WIRE-004; FEATURE="AuthGraphManager Integration"; ASPECT=ServerInit; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
const auth_graph_manager = @import("auth_graph_manager");
const auth_startup_hydration = @import("auth_startup_hydration");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-014; FEATURE="Structured Logging"; ASPECT=ServerInit; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;

// CANARY: REQ=REQ-SERVER-REFACTOR-008; FEATURE="ServerRefactoring"; ASPECT=SERVER_INIT; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.2 - Server Initialization Module (Fourth Increment)
// Extracted from server/main.zig to improve modularity and reduce main() function size

/// Environment-derived configuration flags
pub const EnvironmentConfig = struct {
    spill_threshold: usize = 0,
    storage_checksum_error: bool = false,
    memcurve_profile: bool = false,
    compact_profile: bool = false,
    disable_estimates: bool = false,
    order_keys_expr: bool = true, // ISO/GQL standard allows property paths in ORDER BY
    // CANARY: REQ=REQ-ABAC-WIRE-005; FEATURE="ABAC Enforcement"; ASPECT=EnvConfig; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
    // GAP-0165 / SEC-14: GEODE_ENABLE_ABAC (default true). SONNY-6374: it
    // is only reported in a startup log line; no request path enforces ABAC
    // (SONNY-6376).
    abac_enabled: bool = true,
    // #683: Cache per-connection env vars at startup to avoid repeated syscalls.
    query_optimizer_enabled: bool = false,
    inline_results_enabled: bool = true,
    inline_results_max_rows: usize = 1000,
    telemetry_paging: bool = false,
    // CANARY: REQ=REQ-QUIC-HC-030; FEATURE="QUIC High-Concurrency Requests"; ASPECT=MultiplexingGate; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-10
    // Stream multiplexing defaults ON for enterprise out-of-box correctness:
    // a non-multiplexing server hangs the Go client on secondary streams
    // (verified). Operators can opt out of the per-connection acceptor loop
    // with GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING=0.
    quic_stream_multiplexing_enabled: bool = true,
    // CANARY: REQ=REQ-QUIC-HC-054; FEATURE="QUIC High-Concurrency Requests"; ASPECT=CooperativeFirstStreams; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
    // In single-stream high-fanout deployments, service first streams with a
    // bounded cooperative scheduler instead of one persistent worker per live
    // connection. This is now the production default; set
    // GEODE_QUIC_COOPERATIVE_FIRST_STREAMS=0 only for compatibility triage.
    quic_cooperative_first_streams_enabled: bool = true,
    // R2 (2026-04-22): per-request budget for acquiring the per-graph
    // exclusive write lock.
    //
    // R7 follow-up (2026-04-22): raised from 30 s → 120 s. 30 s tripped
    // the cascade failure mode on 16-worker contended ingest even though
    // each worker was making forward progress (see R7 commit).  The
    // 120 s value is also used as the `default_mutation_write_lock_timeout_ms`
    // fallback in `quic_connection_handler.zig`; they MUST stay in sync
    // because the handler prefers this env-config value over the file-
    // scope default.  Override via `GEODE_GRAPH_WRITE_LOCK_TIMEOUT_MS`.
    graph_write_lock_timeout_ms: u64 = 120_000,
    // CANARY: REQ=REQ-QUIC-HC-114; FEATURE="High-Concurrency Setup"; ASPECT=ConfigurableHelloReadTimeout; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-06-10
    //
    // Detached connection-admission handlers remain bounded, but high-fanout
    // setup tests and production deployments need failed/stalled HELLO reads to
    // release their admission handler quickly enough for retry waves to keep
    // overall setup latency bounded. Override via
    // GEODE_QUIC_HELLO_READ_TIMEOUT_MS when slower clients require a wider
    // post-handshake application-auth window.
    quic_hello_read_timeout_ms: u64 = 1_000,
    // FIX #1 (scan cancellation): per-query wall-clock budget for a streaming
    // node scan (`NodeScanStream`). When non-zero, a scan whose total wall-clock
    // exceeds this is canceled at the next batch boundary (releases its per-graph
    // SHARED read lock and ends the stream) — a backstop against lingering scans
    // that keep burning CPU + lock churn after their client has disconnected but
    // the close was not (yet) observed. Generous by default so legitimate large
    // analytical scans complete; 0 disables the deadline. Override via
    // GEODE_SCAN_QUERY_TIMEOUT_MS.
    scan_query_timeout_ms: u64 = 300_000,
};

/// Server initialization context containing all initialized resources
pub const InitContext = struct {
    env_config: EnvironmentConfig,
    // Shared AST cache for cross-connection reuse (optional).
    shared_ast_cache: ?*query_ast_cache.SharedAstCache = null,
    shared_ast_cache_storage: ?query_ast_cache.SharedAstCache = null,
    // CANARY: REQ=REQ-ABAC-WIRE-006; FEATURE="ABAC Enforcement"; ASPECT=InitContext; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
    // GAP-0165: SecurityManager instance for RBAC+ABAC enforcement across all connections
    security_manager: ?*geode_auth.SecurityManager = null,
    security_manager_storage: ?geode_auth.SecurityManager = null,
    // CANARY: REQ=REQ-PERF-SHARED-OPT-001; FEATURE="SharedQueryOptimizer"; ASPECT=InitContext; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
    // Issue #460: Shared cross-connection query optimizer for plan reuse
    shared_optimizer: ?*query_plan_cache.SharedQueryOptimizer = null,
    shared_optimizer_storage: ?query_plan_cache.SharedQueryOptimizer = null,
    // CANARY: REQ=REQ-AUTH-GRAPH-WIRE-005; FEATURE="AuthGraphManager Integration"; ASPECT=InitContext; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
    auth_graph_mgr: ?*auth_graph_manager.AuthGraphManager = null,
    auth_graph_mgr_storage: ?auth_graph_manager.AuthGraphManager = null,

    /// Re-derive self-referential pointers after the struct has been moved.
    /// MUST be called after `initialize()` returns, because returning the struct
    /// by value copies it to a new stack location, invalidating any internal
    /// pointers that were set during initialization (GAP-0426).
    pub fn fixupSelfPointers(self: *InitContext) void {
        self.shared_ast_cache = if (self.shared_ast_cache_storage != null)
            &self.shared_ast_cache_storage.?
        else
            null;
        self.security_manager = if (self.security_manager_storage != null)
            &self.security_manager_storage.?
        else
            null;
        self.shared_optimizer = if (self.shared_optimizer_storage != null)
            &self.shared_optimizer_storage.?
        else
            null;
        self.auth_graph_mgr = if (self.auth_graph_mgr_storage != null)
            &self.auth_graph_mgr_storage.?
        else
            null;

        // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-008; FEATURE="Runtime Auth Graph Persistence"; ASPECT=WireCallbacks; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=security; UPDATED=2026-06-11
        // Wire SecurityManager's opaque pointer and callbacks to AuthGraphManager
        // so that runtime mutations (user create, login state, password change) are
        // persisted to the auth graph store for durability across restarts.
        if (self.security_manager) |sm| {
            if (self.auth_graph_mgr) |agm| {
                sm.auth_graph_mgr = @ptrCast(agm);
                sm.graph_persist_user_create = &graphPersistUserCreate;
                sm.graph_persist_login_state = &graphPersistLoginState;
                sm.graph_persist_password = &graphPersistPassword;
                sm.graph_persist_role_membership = &graphPersistRoleMembership;
            }
        }

        // CANARY: REQ=REQ-AUTH-HMAC-PERIODIC-003; FEATURE="PeriodicHmacVerification"; ASPECT=ServerStartup; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
        // Start periodic HMAC verification AFTER all pointer fixups.
        // The thread captures `self` by pointer, so it must not be started until
        // the AuthGraphManager is at its final memory location.
        if (self.auth_graph_mgr) |agm| {
            agm.startPeriodicVerification(&agm.hmac_key, 5);
        }
    }

    pub fn deinit(self: *InitContext) void {
        // Clean up index catalog (selectivity estimator + stats map)
        index_catalog.deinitIndexCatalog();

        if (self.shared_ast_cache_storage) |*cache| {
            cache.deinit();
            self.shared_ast_cache = null;
            self.shared_ast_cache_storage = null;
        }
        // CANARY: REQ=REQ-ABAC-WIRE-007; FEATURE="ABAC Enforcement"; ASPECT=Cleanup; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
        // GAP-0165: Clean up SecurityManager on server shutdown
        if (self.security_manager_storage) |*sm| {
            sm.deinit();
        }
        // Issue #460: Clean up shared optimizer on server shutdown
        if (self.shared_optimizer_storage) |*opt| {
            opt.deinit();
            self.shared_optimizer = null;
            self.shared_optimizer_storage = null;
        }
        // CANARY: REQ=REQ-AUTH-GRAPH-WIRE-006; FEATURE="AuthGraphManager Integration"; ASPECT=Cleanup; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
        // CANARY: REQ=REQ-AUTH-HMAC-PERIODIC-004; FEATURE="PeriodicHmacVerification"; ASPECT=Shutdown; STATUS=TESTED; TEST=tests/test_auth_graph_manager_unit.zig; OWNER=security; UPDATED=2026-06-11
        if (self.auth_graph_mgr_storage) |*agm| {
            agm.requestShutdown();
            agm.deinit();
            self.auth_graph_mgr = null;
            self.auth_graph_mgr_storage = null;
        }
        // WAL lifecycle is handled internally by the graph-storage adapter.
    }
};

// Zig 0.16 compat: std.process.getEnvMap was removed. Use direct getenv via libc.
fn getenvSlice(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const p = std.c.getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(p);
}

/// Process environment variables and return configuration
pub fn processEnvironmentVariables(allocator: std.mem.Allocator, memcurve_profile_ref: *bool) !EnvironmentConfig {
    _ = allocator;
    var config = EnvironmentConfig{};

    if (getenvSlice("GEODE_QUERY_MEM_LIMIT_BYTES")) |th| {
        config.spill_threshold = std.fmt.parseInt(usize, th, 10) catch config.spill_threshold;
    } else if (getenvSlice("GEODE_SPILL_THRESHOLD_BYTES")) |th| {
        config.spill_threshold = std.fmt.parseInt(usize, th, 10) catch config.spill_threshold;
    }

    if (getenvSlice("GEODE_NULLS_LAST")) |_| {
        server_flags.setNullsLast(true);
    }

    if (getenvSlice("GEODE_PROFILE_MEMCURVE")) |_| {
        config.memcurve_profile = true;
        memcurve_profile_ref.* = true;
    }

    if (getenvSlice("GEODE_PROFILE_COMPACT")) |_| {
        config.compact_profile = true;
    }

    if (getenvSlice("GEODE_DISABLE_ESTIMATES")) |_| {
        config.disable_estimates = true;
    }

    if (getenvSlice("GEODE_ADAPT_ESTIMATES")) |_| {
        server_flags.setAdaptEstimates(true);
    }

    if (getenvSlice("GEODE_DISABLE_INDEX_CATALOG")) |_| {
        index_catalog.setDisableCatalog(true);
    }

    if (getenvSlice("GEODE_ORDER_KEYS_EXPR")) |val| {
        if (val.len == 0) {
            config.order_keys_expr = true;
        } else if (std.ascii.eqlIgnoreCase(val, "1") or std.ascii.eqlIgnoreCase(val, "true") or std.ascii.eqlIgnoreCase(val, "on")) {
            config.order_keys_expr = true;
        } else {
            config.order_keys_expr = false;
        }
    }

    // #683: Read per-connection env vars once at startup instead of per-connection.
    if (getenvSlice("GEODE_ENABLE_QUERY_OPTIMIZER")) |val| {
        config.query_optimizer_enabled = val.len > 0 and val[0] != '0' and
            !std.ascii.eqlIgnoreCase(val, "false") and !std.ascii.eqlIgnoreCase(val, "off");
    }
    if (getenvSlice("GEODE_INLINE_RESULTS")) |val| {
        config.inline_results_enabled = val.len == 0 or (val[0] != '0' and
            !std.ascii.eqlIgnoreCase(val, "false") and !std.ascii.eqlIgnoreCase(val, "off"));
    }
    if (getenvSlice("GEODE_INLINE_RESULTS_MAX_ROWS")) |val| {
        config.inline_results_max_rows = std.fmt.parseInt(usize, val, 10) catch config.inline_results_max_rows;
    }
    if (getenvSlice("GEODE_TELEMETRY_PAGING")) |_| {
        config.telemetry_paging = true;
    }
    if (getenvSlice("GEODE_GRAPH_WRITE_LOCK_TIMEOUT_MS")) |val| {
        config.graph_write_lock_timeout_ms = std.fmt.parseInt(u64, val, 10) catch config.graph_write_lock_timeout_ms;
    }
    if (getenvSlice("GEODE_SCAN_QUERY_TIMEOUT_MS")) |val| {
        config.scan_query_timeout_ms = std.fmt.parseInt(u64, val, 10) catch config.scan_query_timeout_ms;
    }
    if (getenvSlice("GEODE_QUIC_HELLO_READ_TIMEOUT_MS")) |val| {
        config.quic_hello_read_timeout_ms = @max(
            @as(u64, 1),
            std.fmt.parseInt(u64, val, 10) catch config.quic_hello_read_timeout_ms,
        );
    }
    if (getenvSlice("GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING")) |val| {
        config.quic_stream_multiplexing_enabled = val.len == 0 or (val[0] != '0' and
            !std.ascii.eqlIgnoreCase(val, "false") and !std.ascii.eqlIgnoreCase(val, "off") and
            !std.ascii.eqlIgnoreCase(val, "no"));
    }
    if (getenvSlice("GEODE_QUIC_COOPERATIVE_FIRST_STREAMS")) |val| {
        config.quic_cooperative_first_streams_enabled = val.len == 0 or (val[0] != '0' and
            !std.ascii.eqlIgnoreCase(val, "false") and !std.ascii.eqlIgnoreCase(val, "off") and
            !std.ascii.eqlIgnoreCase(val, "no"));
    }

    // CANARY: REQ=REQ-ABAC-WIRE-008; FEATURE="ABAC Enforcement"; ASPECT=EnvVar; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
    // GAP-0165: Check for GEODE_ENABLE_ABAC environment variable to enable ABAC enforcement
    if (getenvSlice("GEODE_ENABLE_ABAC")) |val| {
        config.abac_enabled = val.len > 0 and (val[0] == '1' or std.ascii.eqlIgnoreCase(val, "true"));
    }

    return config;
}

// CANARY: REQ=REQ-ABAC-WIRE-009; FEATURE="ABAC Enforcement"; ASPECT=SecurityInit; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
// GAP-0165: Initialize SecurityManager for RBAC+ABAC policy enforcement
/// Initialize SecurityManager if ABAC is enabled
pub fn initializeSecurityManager(allocator: std.mem.Allocator) !geode_auth.SecurityManager {
    return geode_auth.SecurityManager.init(allocator);
}

// CANARY: REQ=REQ-ADMIN-BOOTSTRAP-HARDEN-001; FEATURE="AdminBootstrapHardening"; ASPECT=DataDirPermissions; STATUS=TESTED; TEST=tests/test_admin_bootstrap_hardening.zig; OWNER=security; UPDATED=2026-05-15
// Issue #819 (CWE-538 file/dir info exposure, CWE-732 incorrect permissions).
// The pure permission-check helper lives in `data_dir_permissions.zig` so
// it can be unit-tested without dragging in the rest of the server module.
const data_dir_permissions = @import("data_dir_permissions.zig");
pub const DataDirPermissionResult = data_dir_permissions.DataDirPermissionResult;
pub const ensureSecureDataDirPermissions = data_dir_permissions.ensureSecureDataDirPermissions;

/// Wrap `ensureSecureDataDirPermissions` with structured log emission so
/// the audit trail captures every tightening / refusal.  Returns the same
/// enum so callers can branch on `.refuse` to fail-closed.
fn logAndApplyDataDirPermissionCheck(path: []const u8) DataDirPermissionResult {
    const result = ensureSecureDataDirPermissions(path);
    switch (result) {
        .ok, .not_applicable => {},
        .tightened => log.warn("Tightened data directory permissions to 0700 before bootstrap (was world/group-readable; CWE-538)", &.{
            Attr.string("path", path),
        }),
        .refuse => log.err("AUTH BOOTSTRAP REFUSED: data directory is world/group-readable and chmod failed; refusing to write bootstrap password (CWE-538/CWE-732)", &.{
            Attr.string("path", path),
            Attr.string("remediation", "chmod 700 <data_dir> as root and restart, or set GEODE_ADMIN_PASSWORD before bootstrap"),
        }),
        .unknown => log.warn("Unable to verify data directory permissions before bootstrap (open/stat failed; proceeding)", &.{
            Attr.string("path", path),
        }),
    }
    return result;
}

// CANARY: REQ=REQ-SONNY-6339-RESOLVED-DATA-DIR; FEATURE="Server Startup"; ASPECT=DurableAuthStateOrRefuse; STATUS=TESTED; TEST=tests/test_sonny6339_resolved_data_dir.zig; OWNER=security; UPDATED=2026-11-12
/// Complete server initialization. `data_dir` is the RESOLVED data directory
/// (main.zig resolveServerDataDir: the flag, GEODE_DATA_DIR or the per-user
/// default), never the raw flag. SONNY-6339: it was the flag, so without
/// --data-dir the store fell back to memory and the HMAC key lookup got no
/// directory, and the auth graph was disabled without an error. It now
/// returns an error (the server refuses to start) whenever the durable auth
/// state cannot be established: the store does not open, the HMAC key cannot
/// be read or created, the auth graph manager does not initialize, the chain
/// does not verify, or a first boot cannot bootstrap the admin.
pub fn initialize(
    allocator: std.mem.Allocator,
    order_keys_mode_expr: bool,
    data_dir: []const u8,
    memcurve_profile_ref: *bool,
) !InitContext {
    // Initialize index catalog (idempotent)
    index_catalog.initIndexCatalog(allocator);
    // SONNY-6499: a startup refusal below (HMAC key required, storage or
    // auth state unavailable) returns before `InitContext.deinit` exists to
    // free it; it leaked the estimator and the stats maps.
    errdefer index_catalog.deinitIndexCatalog();

    // Process environment variables
    const env_config = try processEnvironmentVariables(allocator, memcurve_profile_ref);

    // Apply ORDER BY key policy
    const order_expr = if (order_keys_mode_expr) true else env_config.order_keys_expr;
    server_flags.setOrderKeysExpr(order_expr);

    // CANARY: REQ=REQ-QUIC-CATALOG-003; FEATURE="CatalogDataDirIsolation"; ASPECT=ServerInit; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=engine; UPDATED=2026-06-11
    // Note: GEODE_DATA_DIR environment variable is read at startup if needed;
    // direct configuration via graph_store.setDataDirOverride() is preferred
    // Set data directory for GraphStore persistence (canonical configuration for isolation)
    graph_store.setDataDirOverride(allocator, data_dir);
    // SONNY-6334: GPS decides FLE decrypt_field from the first request on.
    geode.execution.installDecryptDecider();

    // CANARY: REQ=REQ-SONNY-6324-FLE-CATALOG-FAIL-CLOSED; FEATURE="FieldLevelEncryption"; ASPECT=StartupLoad; STATUS=TESTED; TEST=tests/test_sonny6324_fle_catalog_fail_closed.zig; OWNER=security; UPDATED=2026-11-11
    // SONNY-6324: load the FLE catalog now, from the data directory just
    // set, and refuse to start if a catalog file exists and cannot be
    // loaded: without it the fields configured as encrypted are unknown. It
    // was loaded lazily on first use and a failure gave an empty catalog, so
    // those fields were written in plaintext.
    // SONNY-6435: a GEODE_MASTER_KEY other than the one the encrypted
    // fields were written with refuses startup (the value is recorded on the
    // first start with a key).
    try refuseMismatchedMasterKey(allocator, data_dir);
    try geode.fle_integration.catalog_mod.loadGlobalCatalogAtStartup();

    // CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-007; FEATURE="EngineBackedPersistence"; ASPECT=ServerInit; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=storage; UPDATED=2026-06-11
    // Initialize global store with engine-backed adapter (creates adapter + loads from engine).
    // SONNY-6339: no in-memory fallback. A store that does not open refuses
    // startup: in memory, users, roles, grants, policies and data are lost
    // at the next restart.
    const store = graph_store.initGlobalStore(allocator, data_dir) catch |err| {
        printAuthStateUnavailable(data_dir, "opening the storage engine", err);
        return error.StorageUnavailable;
    };

    // CANARY: REQ=REQ-AUTH-GRAPH-WIRE-007; FEATURE="AuthGraphManager Integration"; ASPECT=ServerStartup; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
    // Initialize AuthGraphManager: resolve HMAC key, verify or bootstrap auth chain
    //
    // CANARY: REQ=REQ-SONNY-6322-HMAC-KEY-REQUIRED; FEATURE="AuthGraphManager Integration"; ASPECT=NoKeyOverExistingRecords; STATUS=TESTED; TEST=tests/test_sonny6322_audit_seed_and_hmac_startup.zig; OWNER=security; UPDATED=2026-11-11
    // SONNY-6322: an existing key is looked up first; a new key file is
    // created only for a store without auth records (a first boot). A store
    // with records and no key (a restored or copied directory) refuses to
    // start and writes nothing: generating a key there could never verify
    // the chain (AuthChainTampered) and left the junk key behind.
    //
    // SONNY-6339: every failure here refuses startup. A malformed or
    // unreadable key source, or a key file that cannot be created, used to
    // log "auth graph disabled" and run with in-memory authentication.
    const hmac_key_result: auth_graph_manager.HmacKeyResult = hmac_blk: {
        if (auth_graph_manager.AuthGraphManager.resolveExistingHmacKey(allocator, data_dir)) |existing| {
            break :hmac_blk existing;
        } else |err| switch (err) {
            error.NoHmacKeyAvailable => {},
            else => {
                printHmacKeyUnusable(data_dir, err);
                return error.HmacKeyUnusable;
            },
        }
        const has_records = storeHasAuthRecords(allocator, store) catch |err| {
            printAuthStateUnavailable(data_dir, "initializing the auth graph manager", err);
            return error.AuthGraphUnavailable;
        };
        if (has_records) {
            printHmacKeyRequired(data_dir);
            return error.HmacKeyRequired;
        }
        break :hmac_blk auth_graph_manager.AuthGraphManager.resolveHmacKey(allocator, data_dir) catch |err| {
            printHmacKeyUnusable(data_dir, err);
            return error.HmacKeyUnusable;
        };
    };

    var agm_storage: ?auth_graph_manager.AuthGraphManager = agm_blk: {
        {
            const kr = &hmac_key_result;
            var agm = auth_graph_manager.AuthGraphManager.init(allocator, store) catch |err| {
                printAuthStateUnavailable(data_dir, "initializing the auth graph manager", err);
                return error.AuthGraphUnavailable;
            };

            if (agm.hasAuthRecords()) {
                // Honour both env-var spellings: `GEODE_ADMIN_PASSWORD`
                // (legacy / backward compat) and `GEODE_DEFAULT_PASSWORD`
                // (documented).  Either one being set when records already
                // exist is IGNORED — env seeding is first-boot only, the
                // persisted credential always wins. WARN (not info) so
                // operators whose serve script still carries the env var get
                // a breadcrumb explaining why that password does not work.
                if (getEnvVarOwned(allocator, "GEODE_ADMIN_PASSWORD")) |env_pw| {
                    allocator.free(env_pw);
                    log.warn("GEODE_ADMIN_PASSWORD is set but IGNORED: a persisted admin credential already exists (env seeds the admin only on first boot; rotate via ALTER USER or 'geode user reset-password')", &.{});
                    // Secret-free breadcrumb via std.debug.print so it is
                    // visible at ALL log levels (the structured sink may not
                    // surface pre-listener warns) — same rationale as the
                    // other `[startup]` lines and the first-boot password
                    // pointer below.
                    std.debug.print("[startup] GEODE_ADMIN_PASSWORD is set but IGNORED: a persisted admin credential already exists (env seeds the admin only on first boot; rotate via ALTER USER or 'geode user reset-password')\n", .{});
                } else |_| {}
                if (getEnvVarOwned(allocator, "GEODE_DEFAULT_PASSWORD")) |env_pw| {
                    allocator.free(env_pw);
                    log.warn("GEODE_DEFAULT_PASSWORD is set but IGNORED: a persisted admin credential already exists (env seeds the admin only on first boot; rotate via ALTER USER or 'geode user reset-password')", &.{});
                    std.debug.print("[startup] GEODE_DEFAULT_PASSWORD is set but IGNORED: a persisted admin credential already exists (env seeds the admin only on first boot; rotate via ALTER USER or 'geode user reset-password')\n", .{});
                } else |_| {}

                // Verify HMAC chain integrity
                agm.verifyChain(&kr.key) catch |err| {
                    // Operator escape hatch: GEODE_AUTH_RESEAL_CHAIN=1 forces a
                    // re-seal of the chain from the currently-loaded records.
                    // Use this after offline maintenance (e.g. an out-of-band
                    // password reset that bypassed the HMAC update path) when
                    // the operator is confident the records on disk are
                    // authentic and only the seal/per-record HMAC is stale.
                    // Logs a loud warning so audit trails capture the reseal.
                    const reseal_env = getEnvVarOwned(allocator, "GEODE_AUTH_RESEAL_CHAIN") catch null;
                    if (reseal_env) |env_val| {
                        defer allocator.free(env_val);
                        const truthy = std.mem.eql(u8, env_val, "1") or
                            std.ascii.eqlIgnoreCase(env_val, "true") or
                            std.ascii.eqlIgnoreCase(env_val, "yes");
                        if (truthy) {
                            log.warn("AUTH CHAIN RESEAL REQUESTED - re-signing all records (manual operator override)", &.{
                                Attr.string("verify_error", @errorName(err)),
                                Attr.string("key_source", kr.key_id),
                            });
                            // SONNY-2791: refuses to sign a policy record without a
                            // kind whose HMAC does not verify, unless its id is in
                            // GEODE_AUTH_RESEAL_ACCEPT_LEGACY (signed) or
                            // GEODE_AUTH_RESEAL_DROP_LEGACY (deleted).
                            var accept_buf: [64]u64 = undefined;
                            var drop_buf: [64]u64 = undefined;
                            const decisions: auth_graph_manager.AuthGraphManager.LegacyPolicyDecisions = .{
                                .accept = parseLegacyPolicyIds(allocator, "GEODE_AUTH_RESEAL_ACCEPT_LEGACY", &accept_buf),
                                .drop = parseLegacyPolicyIds(allocator, "GEODE_AUTH_RESEAL_DROP_LEGACY", &drop_buf),
                            };
                            agm.resealChain(&kr.key, decisions) catch |seal_err| {
                                log.err("AUTH CHAIN RESEAL FAILED", &.{
                                    Attr.string("error", @errorName(seal_err)),
                                });
                                if (seal_err == error.UnsignedLegacyPolicyRecord) {
                                    std.debug.print("[startup] AUTH CHAIN RESEAL REFUSED: policy records without a kind do not verify (see the log for their ids). After checking each one, list its id in GEODE_AUTH_RESEAL_DROP_LEGACY (delete it) or GEODE_AUTH_RESEAL_ACCEPT_LEGACY (sign it).\n", .{});
                                }
                                agm.deinit();
                                return error.AuthChainTampered;
                            };
                            log.warn("AUTH CHAIN RESEALED - unset GEODE_AUTH_RESEAL_CHAIN before next start", &.{});
                            // Re-verify so we fail loudly if the reseal is
                            // still wrong (e.g. records mutated by another
                            // process between seal and verify).
                            agm.verifyChain(&kr.key) catch |verify_err| {
                                log.err("AUTH CHAIN RESEAL DID NOT REPAIR CHAIN", &.{
                                    Attr.string("error", @errorName(verify_err)),
                                });
                                agm.deinit();
                                return error.AuthChainTampered;
                            };
                            log.info("Auth HMAC chain verified successfully after reseal", &.{
                                Attr.string("key_source", kr.key_id),
                            });
                            break :agm_blk agm;
                        }
                    }
                    log.err("AUTH TAMPER DETECTED - auth chain verification failed", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.string("key_source", kr.key_id),
                    });
                    agm.deinit();
                    return error.AuthChainTampered;
                };
                log.info("Auth HMAC chain verified successfully", &.{
                    Attr.string("key_source", kr.key_id),
                });
            } else {
                // First boot: bootstrap default admin user
                const result = agm.bootstrapDefaultAdmin(&kr.key) catch |err| {
                    if (err == error.PersistedAdminExists) {
                        // 2026-07-01 incident guard: the in-memory load saw
                        // zero auth records, but the engine still holds
                        // persisted :User records on disk. Re-seeding from
                        // GEODE_ADMIN_PASSWORD here is what silently rotated
                        // a live server's admin credential to the env value.
                        // Fail CLOSED instead: keep the auth graph manager
                        // (so the persistent resolver stays wired and we
                        // never fall through to the in-memory env-seeded
                        // `ensureDefaultUser` path) and skip bootstrap. The
                        // persisted credential remains authoritative; admin
                        // login may fail this session until the operator
                        // repairs the store — strictly better than silently
                        // destroying the persisted credential.
                        // (Review-0016: `PersistedAdminExists` is also the
                        // fail-closed mapping for engine errors during the
                        // persisted-record check — the AGM already logged the
                        // precise underlying error; the breadcrumb wording
                        // covers both refusal reasons.)
                        log.err("ADMIN BOOTSTRAP SKIPPED: persisted admin records exist on disk but none were loaded (or the engine check failed); GEODE_ADMIN_PASSWORD/GEODE_DEFAULT_PASSWORD are IGNORED (persisted credential wins). Investigate __geode_security storage health, then restart.", &.{});
                        std.debug.print("[startup] admin bootstrap SKIPPED: persisted admin records exist on disk but failed to load (or the engine check failed); GEODE_ADMIN_PASSWORD env ignored (persisted credential wins)\n", .{});
                        agm.hmac_key = kr.key;
                        break :agm_blk agm;
                    }
                    agm.deinit();
                    printAuthStateUnavailable(data_dir, "bootstrapping the default admin user", err);
                    return error.AuthGraphUnavailable;
                };
                // SEC: never print the generated admin password to stderr.
                // When neither `GEODE_ADMIN_PASSWORD` nor the documented
                // `GEODE_DEFAULT_PASSWORD` is set we still need to surface
                // the auto-generated value to the operator on first boot;
                // we mirror the legacy `geode_auth_lib` behaviour by
                // writing it to `<data_dir>/.geode_admin_password` with
                // mode 0600 and emitting only a structured-log pointer.
                const admin_env_present = blk_env: {
                    if (getEnvVarOwned(allocator, "GEODE_ADMIN_PASSWORD")) |env_pw| {
                        allocator.free(env_pw);
                        break :blk_env true;
                    } else |_| {}
                    if (getEnvVarOwned(allocator, "GEODE_DEFAULT_PASSWORD")) |env_pw| {
                        allocator.free(env_pw);
                        break :blk_env true;
                    } else |_| {}
                    break :blk_env false;
                };
                if (!admin_env_present) {
                    // Issue #819 (CWE-538/CWE-732): ensure data_dir is mode
                    // 0o700 or stricter before persisting the bootstrap
                    // password.  Fail-closed on chmod failure.
                    const perm_check = logAndApplyDataDirPermissionCheck(data_dir);
                    if (perm_check == .refuse) {
                        log.err("Bootstrap password NOT written: parent data directory permissions could not be secured; rotate via 'geode user reset-password' after hardening the directory", &.{});
                    } else {
                        // SONNY-2778: O_CREAT|O_EXCL|O_NOFOLLOW, mode 0600, never
                        // over an existing file or through a symlink, and never
                        // into the current working directory
                        // (`geode_auth.writeAdminPasswordFile`).
                        {
                            const dir = data_dir;
                            if (geode_auth.writeAdminPasswordFile(allocator, dir, result.password)) |path| {
                                defer allocator.free(path);
                                // Discoverable, SECRET-FREE breadcrumb on stdout/stderr,
                                // visible at ALL log levels via std.debug.print (like the
                                // other `[startup]` lines), so operators watching container
                                // logs and log-scraping harnesses can find the first-boot
                                // credential. The GAP-0104/S3 fix correctly stopped logging
                                // the secret but left no pointer, silently breaking every
                                // consumer that scraped the old password line — see
                                // docs/bugs/2026-06-06-admin-password-only-in-data-dir-file-not-startup-logs.md.
                                // NEVER print result.password here.
                                std.debug.print(
                                    "[startup] generated initial admin password written to {s} (mode 0600) — read it there or set GEODE_ADMIN_PASSWORD; change on first login\n",
                                    .{path},
                                );
                                log.warn("Auto-generated admin password written to file (set GEODE_ADMIN_PASSWORD or GEODE_DEFAULT_PASSWORD for production)", &.{
                                    Attr.string("path", path),
                                });
                            } else |err| {
                                log.err("Failed to create generated admin password file (operator must rotate via reset-password)", &.{
                                    Attr.string("data_dir", dir),
                                    Attr.string("error", @errorName(err)),
                                });
                                std.debug.print("[startup] generated initial admin password NOT written to {s}/.geode_admin_password ({s}); an existing file is never overwritten. Rotate via 'geode user reset-password'\n", .{ dir, @errorName(err) });
                            }
                        }
                    }
                }
                log.info("Default admin user bootstrapped via auth graph", &.{
                    Attr.string("username", result.username),
                });
                allocator.free(result.username);
                allocator.free(result.password);
            }

            // CANARY: REQ=REQ-AUTH-HMAC-PERIODIC-003; FEATURE="PeriodicHmacVerification"; ASPECT=ServerStartup; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
            // NOTE: Do NOT start periodic verification here. `agm` is a stack local
            // that will be moved by value into `agm_storage` and then again when
            // InitContext is returned. The thread captures `self` by pointer, so
            // starting it here creates a dangling pointer.  The thread is started
            // in fixupSelfPointers() after the struct reaches its final location.
            agm.hmac_key = kr.key;

            break :agm_blk agm;
        }
    };

    // Initialize shared AST cache (cross-connection) if enabled.
    const ast_cache_size = blk: {
        if (getEnvVarOwned(allocator, "GEODE_AST_CACHE_SIZE")) |v| {
            defer allocator.free(v);
            const parsed = std.fmt.parseInt(usize, v, 10) catch 0;
            break :blk parsed;
        } else |_| {}
        break :blk 2048;
    };

    // GAP-0900 Layer-3 (Fix 1): total-bytes budget for the shared AST cache.
    // The count cap (above) alone admits ~8 GB on the batch-ingest workload
    // because each ~100-MERGE×19-SET program's arena is ~4 MB. Bounding by
    // bytes turns that ~8 GB constant into a modest budget while still holding
    // thousands of typical KB-sized ASTs. Default 256 MB; override with
    // GEODE_AST_CACHE_BYTES (0 disables the byte bound → count-only legacy
    // behavior).
    const ast_cache_bytes = blk: {
        if (getEnvVarOwned(allocator, "GEODE_AST_CACHE_BYTES")) |v| {
            defer allocator.free(v);
            const parsed = std.fmt.parseInt(usize, v, 10) catch 256 * 1024 * 1024;
            break :blk parsed;
        } else |_| {}
        break :blk 256 * 1024 * 1024;
    };

    // Issue #460: Initialize shared query optimizer (cross-connection plan cache)
    const plan_cache_size = blk: {
        if (getEnvVarOwned(allocator, "GEODE_PLAN_CACHE_SIZE")) |v| {
            defer allocator.free(v);
            const parsed = std.fmt.parseInt(usize, v, 10) catch 0;
            break :blk parsed;
        } else |_| {}
        break :blk 512;
    };

    // CANARY: REQ=REQ-ABAC-WIRE-010; FEATURE="ABAC Enforcement"; ASPECT=ServerStartup; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
    // GAP-0165: Initialize SecurityManager at server startup if ABAC is enabled
    var ctx = InitContext{
        .env_config = env_config,
        .shared_ast_cache = null,
        .shared_ast_cache_storage = null,
        .security_manager = null,
        .security_manager_storage = null,
        .shared_optimizer = null,
        .shared_optimizer_storage = null,
        .auth_graph_mgr = null,
        .auth_graph_mgr_storage = agm_storage,
    };

    if (ast_cache_size > 0) {
        ctx.shared_ast_cache_storage = query_ast_cache.SharedAstCache.initWithByteBudget(allocator, ast_cache_size, ast_cache_bytes);
        // NOTE: Do NOT set ctx.shared_ast_cache here — the pointer would dangle
        // after this struct is returned by value. Caller must use fixupSelfPointers().
    }

    // Issue #460: Initialize shared optimizer for cross-connection plan reuse
    if (plan_cache_size > 0) {
        ctx.shared_optimizer_storage = query_plan_cache.SharedQueryOptimizer.init(allocator, plan_cache_size);
        // NOTE: Do NOT set ctx.shared_optimizer here — same dangling pointer issue.
        log.info("Shared query optimizer initialized", &.{
            Attr.int("cache_size", @intCast(plan_cache_size)),
        });
    }

    // CANARY: REQ=REQ-AUTH-GRAPH-WIRE-008; FEATURE="AuthGraphManager Integration"; ASPECT=SecurityManagerInit; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
    // Always initialize SecurityManager when auth graph is available so that
    // runtime password changes are persisted to disk.  ABAC policy enforcement
    // is gated separately; the SecurityManager is needed for persistence even
    // when ABAC is disabled.
    //
    // SONNY-6339: the auth graph is always available here (initialize refuses
    // to start otherwise). The legacy SecurityManager.init fallback that ran
    // without it seeded its own admin from GEODE_DEFAULT_PASSWORD and wrote a
    // random, never-used password to $GEODE_DATA_DIR/.geode_admin_password;
    // it is gone.
    {
        ctx.security_manager_storage = hydrateSecurityManagerFromGraph(allocator, &agm_storage.?, hmac_key_result) catch |err| blk: {
            log.err("Failed to hydrate SecurityManager from auth graph", &.{Attr.string("error", @errorName(err))});
            break :blk null;
        };
        // SONNY-6374: no request path calls SecurityManager.authorize or
        // its ABAC policies (authorization is GPS), so GEODE_ENABLE_ABAC
        // changes nothing; this line used to claim that it turned
        // enforcement on. Enforcement is tracked by SONNY-6376.
        if (ctx.security_manager_storage != null) {
            log.info("SecurityManager hydrated from auth graph; ABAC policies are not enforced on any request path (GEODE_ENABLE_ABAC has no effect)", &.{
                Attr.boolean("geode_enable_abac", env_config.abac_enabled),
            });
        }
    }

    return ctx;
}

// CANARY: REQ=REQ-AUTH-GRAPH-WIRE-009; FEATURE="AuthGraphManager Integration"; ASPECT=Hydration; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11
/// Hydrate SecurityManager from AuthGraphManager's stored records.
/// Creates an empty SecurityManager and populates it with users from the auth graph.
fn hydrateSecurityManagerFromGraph(
    allocator: std.mem.Allocator,
    agm: *auth_graph_manager.AuthGraphManager,
    hmac_key_result: ?auth_graph_manager.HmacKeyResult,
) !geode_auth.SecurityManager {
    var sm = try geode_auth.SecurityManager.initEmpty(allocator);

    // Hydrate roles first so user-role memberships can be restored without side effects.
    var role_count: usize = 0;
    var role_it = agm.storage.roleIterator();
    while (role_it.next()) |record| {
        const role = geode_auth.Role{
            .id = record.id,
            .name = try allocator.dupe(u8, record.getName()),
            .description = try allocator.dupe(u8, record.getDescription()),
            .permissions = std.ArrayList(geode_auth.PermissionId).empty,
            .created_at = record.created_at,
            .is_system = record.is_system,
            .priority = record.priority,
            .parent_role = if (record.parent_role == 0) null else record.parent_role,
        };
        try sm.roles.put(record.id, role);
        role_count += 1;
    }

    // Hydrate users from auth graph storage
    var user_count: usize = 0;
    var it = agm.storage.userIterator();
    while (it.next()) |record| {
        try sm.hydrateUser(
            record.id,
            record.getUsername(),
            record.getEmail(),
            record.getPasswordHash(),
            record.is_superuser,
            record.is_active,
            record.is_default_user,
            record.password_reset_required,
            record.mfa_enabled,
            record.getMFASecret(),
            record.auth_version,
            record.getAttributesJson(),
        );
        user_count += 1;
    }

    var assignment_count: usize = 0;
    var membership_it = agm.storage.userIterator();
    while (membership_it.next()) |record| {
        const role_ids = try agm.storage.listUserRoleIds(allocator, record.id);
        defer allocator.free(role_ids);

        if (role_ids.len == 0) continue;
        var entry = try sm.rbac.user_roles.getOrPut(record.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = try std.ArrayList(geode_auth.RoleId).initCapacity(allocator, role_ids.len);
        }
        for (role_ids) |role_id| {
            try entry.value_ptr.append(allocator, role_id);
            assignment_count += 1;
        }
    }

    // Set auth_graph_mgr and hmac_key on SecurityManager for future runtime mutations (Task 5)
    // NOTE: auth_graph_mgr pointer will be fixed up after InitContext is moved via fixupSelfPointers.
    // The actual pointer is set in fixupSelfPointers via the InitContext fields.
    if (hmac_key_result) |kr| {
        sm.hmac_key = kr.key;
    }

    log.info("Hydrated SecurityManager from auth graph", &.{
        Attr.int("role_count", @intCast(role_count)),
        Attr.int("user_count", @intCast(user_count)),
        Attr.int("assignment_count", @intCast(assignment_count)),
    });

    return sm;
}

// -- Graph Persistence Callbacks for SecurityManager --
// These are called via function pointers from SecurityManager, casting the opaque
// pointer back to *AuthGraphManager. All operations are best-effort (catch + log).

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-009; FEATURE="Runtime Auth Graph Persistence"; ASPECT=Callbacks; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=security; UPDATED=2026-06-11

fn graphPersistUserCreate(opaque_agm: *anyopaque, hmac_key: *const [32]u8, username: []const u8, email: []const u8, password_hash: []const u8, is_superuser: bool) callconv(.auto) u64 {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(opaque_agm));
    const version = agm.createUser(hmac_key, username, email, password_hash, is_superuser) catch |err| {
        log.warn("Failed to persist user creation to auth graph", &.{
            Attr.string("error", @errorName(err)),
            Attr.string("username", username),
        });
        return 0;
    };
    if (version != 0) user_mgmt.notePersistentAuthMutation();
    return version;
}

fn graphPersistLoginState(opaque_agm: *anyopaque, hmac_key: *const [32]u8, user_id: u64, failed_attempts: u16, lockout_until: i64) callconv(.auto) void {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(opaque_agm));
    agm.updateUserLoginState(hmac_key, user_id, failed_attempts, lockout_until) catch |err| {
        log.warn("Failed to persist login state to auth graph", &.{
            Attr.string("error", @errorName(err)),
            Attr.uint("user_id", user_id),
        });
    };
}

fn graphPersistPassword(opaque_agm: *anyopaque, hmac_key: *const [32]u8, user_id: u64, new_password_hash: []const u8) callconv(.auto) u64 {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(opaque_agm));
    const version = agm.updateUserPassword(hmac_key, user_id, new_password_hash) catch |err| {
        log.warn("Failed to persist password change to auth graph", &.{
            Attr.string("error", @errorName(err)),
            Attr.uint("user_id", user_id),
        });
        return 0;
    };
    if (version != 0) user_mgmt.notePersistentAuthMutation();
    return version;
}

fn graphPersistRoleMembership(opaque_agm: *anyopaque, hmac_key: *const [32]u8, user_id: u64, role_id: u64, assign: bool) callconv(.auto) u64 {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(opaque_agm));
    const version = if (assign)
        agm.assignUserRole(hmac_key, user_id, role_id) catch |err| {
            log.warn("Failed to persist role assignment to auth graph", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("user_id", user_id),
                Attr.uint("role_id", role_id),
            });
            return 0;
        }
    else
        agm.revokeUserRole(hmac_key, user_id, role_id) catch |err| {
            log.warn("Failed to persist role revoke to auth graph", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("user_id", user_id),
                Attr.uint("role_id", role_id),
            });
            return 0;
        };
    if (version != 0) user_mgmt.notePersistentAuthMutation();
    return version;
}

// =============================================================================
// P7: Auth DDL persistence wiring — callbacks + startup hydration
// =============================================================================

const user_mgmt = geode.user_management;
const multi_graph_security = geode.multi_graph_security;
const auth_dispatch = geode.auth_dispatch;

// -- PersistentUserWriter callbacks --
// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-031; FEATURE="AuthDDLPersistence"; ASPECT=UserWriterCallbacks; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11

fn writerCreateUser(ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: user_mgmt.Role) anyerror!void {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    // SONNY-1333: the user and its role edge, or neither (an admin is a
    // superuser with no role edge).
    _ = try agm.createUserWithRole(&agm.hmac_key, username, email, password_hash, role == .Admin, if (role == .Admin) null else role.toString());
}

// SONNY-3038: each write-through is stored or fails with the stored record
// as it was (AuthGraphManager.*WriteThrough); user_management reports the
// failure and enforces a security-reducing change in memory.
fn writerDeleteUser(ctx: ?*anyopaque, username: []const u8) anyerror!void {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    try agm.deleteUserWriteThrough(&agm.hmac_key, username);
    user_mgmt.notePersistentAuthMutation();
}

// -- FLE role grants (SONNY-6341) --

fn fleRoleGrantPersist(ctx: ?*anyopaque, username: []const u8, role: []const u8) anyerror!void {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    const uid = (try agm.findUserIdByName(username)) orelse return error.FleRoleUserNotFound;
    try agm.grantUserFleRole(&agm.hmac_key, uid, role);
}

fn fleRoleRevokePersist(ctx: ?*anyopaque, username: []const u8, role: []const u8) anyerror!bool {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    const uid = (try agm.findUserIdByName(username)) orelse return false;
    return agm.revokeUserFleRole(&agm.hmac_key, uid, role);
}

fn writerUpdatePassword(ctx: ?*anyopaque, username: []const u8, new_password_hash: []const u8) anyerror!void {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    try agm.updatePasswordWriteThrough(&agm.hmac_key, username, new_password_hash);
    user_mgmt.notePersistentAuthMutation();
}

/// SONNY-6369: a legacy BLAKE2b hash replaced at login
/// (`user_management.upgradeLegacyHash`). Refused in cluster mode (no
/// replication slice: the user would hold a different hash on each node),
/// so the legacy hash stays there.
fn writerRehashPassword(ctx: ?*anyopaque, username: []const u8, old_hash: []const u8, new_hash: []const u8) anyerror!void {
    try geode.distributed.cluster.gateUnreplicatedWrite();
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    try agm.replaceLegacyPasswordHashWriteThrough(&agm.hmac_key, username, old_hash, new_hash);
}

/// The built-in role names, for `writerSetRole`.
const builtin_role_names = [_][]const u8{ "admin", "readwrite", "user", "readonly" };

fn writerSetRole(ctx: ?*anyopaque, username: []const u8, role: user_mgmt.Role) anyerror!void {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    // geode_auth_ddl_persistence.yml regression: storage.assignUserRole
    // only short-circuits when the SAME (uid, rid) edge already exists,
    // so successive ALTER USER ... SET ROLE calls leave one HAS_ROLE
    // edge per role ever assigned.  After a restart, resolveRoleFromGraph
    // walks those edges and the first one HashMap iteration surfaces
    // wins — non-deterministic and roughly 50% of restarts hydrated the
    // OLD built-in role.  A user has exactly one built-in role at a
    // time, so revoke any prior built-in HAS_ROLE edge before assigning
    // the new one.  Custom roles live on their own HAS_ROLE edges and
    // are intentionally NOT touched here.
    try agm.setBuiltinRoleWriteThrough(&agm.hmac_key, username, role.toString(), &builtin_role_names);
    user_mgmt.notePersistentAuthMutation();
}

fn writerSetActive(ctx: ?*anyopaque, username: []const u8, active: bool) anyerror!void {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    try agm.setActiveWriteThrough(&agm.hmac_key, username, active);
    user_mgmt.notePersistentAuthMutation();
}

// -- RolePersistCallbacks for auth_dispatch --
// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-032; FEATURE="AuthDDLPersistence"; ASPECT=RoleCallbacks; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11

fn roleCreate(ctx: ?*anyopaque, name: []const u8, description: []const u8) anyerror!u64 {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    return try agm.createRole(&agm.hmac_key, name, description);
}

fn roleFindId(ctx: ?*anyopaque, name: []const u8) anyerror!?u64 {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    return try agm.findRoleIdByName(name);
}

fn roleRemove(ctx: ?*anyopaque, role_id: u64) anyerror!void {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    try agm.removeRole(&agm.hmac_key, role_id);
}

/// List roles, translating AGM RoleEntry to auth_dispatch.RoleEntry.
/// The two types have the same fields; names point into the AGM cache and
/// are stable across this call.  Caller is responsible for freeing the slice.
fn roleList(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]auth_dispatch.RoleEntry {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    const agm_entries = try agm.listRoles(allocator);
    defer allocator.free(agm_entries);
    const out = try allocator.alloc(auth_dispatch.RoleEntry, agm_entries.len);
    for (agm_entries, 0..) |e, i| {
        out[i] = .{ .id = e.id, .name = e.name, .description = e.description };
    }
    return out;
}

// -- GrantPersistCallbacks for auth_dispatch --
// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-033; FEATURE="AuthDDLPersistence"; ASPECT=GrantCallbacks; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11

fn grantResolveUserId(ctx: ?*anyopaque, username: []const u8) ?u64 {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    return agm.findUserIdByName(username) catch null;
}

/// SONNY-1333: stored and live, every action or none (the in-memory policy
/// makes the grant take effect without restart).
fn grantApply(ctx: ?*anyopaque, user_id: u64, graph_name: []const u8, actions: []const u8) anyerror!void {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    try agm.grantGraphPermissionsWriteThrough(&agm.hmac_key, multi_graph_security.getGlobalPolicy(), user_id, graph_name, actions);
}

/// SONNY-1333: live first (the privilege stops at once), then stored.
fn grantRevoke(ctx: ?*anyopaque, user_id: u64, graph_name: []const u8, action: u8) anyerror!bool {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    return agm.revokeGraphPermissionWriteThrough(&agm.hmac_key, multi_graph_security.getGlobalPolicy(), user_id, graph_name, action);
}

/// SONNY-1333: a user's stored grants, for SHOW GRANTS. The caller frees the
/// entries' graph names and the slice.
fn grantList(ctx: ?*anyopaque, allocator: std.mem.Allocator, user_id: u64) anyerror![]auth_dispatch.GrantEntry {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    const grants = try agm.listGraphGrantsForUser(allocator, user_id);
    defer allocator.free(grants);
    return auth_dispatch.grantEntriesFrom(allocator, grants);
}

// -- graph_grant_check_fn (injected into execution.zig) --
// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-034; FEATURE="AuthDDLPersistence"; ASPECT=GrantCheck; STATUS=TESTED; TEST=geodetestlab/specs/gps_phase3_use_graph_authorization.yml; OWNER=security; UPDATED=2026-06-11

fn graphGrantCheck(username: []const u8, graph_name: []const u8, action: u8) bool {
    const agm = auth_graph_manager.AuthGraphManager.getGlobal() orelse return false;
    const uid = (agm.findUserIdByName(username) catch null) orelse return false;
    const pol = multi_graph_security.getGlobalPolicy() orelse return false;
    return pol.hasGraphGrant(uid, graph_name, action);
}

// -- Startup installation function --
// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-035; FEATURE="AuthDDLPersistence"; ASPECT=StartupWiring; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-06-11

/// Wire all auth-DDL persistence callbacks and hydrate in-memory state from
/// __geode_security.  Called from fixupSelfPointers() once the AuthGraphManager
/// is at its final address.  SONNY-6567 (5): a stored record that cannot be
/// loaded fails startup (every step was best-effort: a warning, and the
/// server ran with part of its auth state).
pub fn wireAuthDDLCallbacks(agm: *auth_graph_manager.AuthGraphManager, allocator: std.mem.Allocator) !void {
    // 1. Publish the global AGM pointer (used by graphGrantCheck).
    auth_graph_manager.AuthGraphManager.setGlobal(agm);

    // 2. User-mutation write-through.
    user_mgmt.setPersistentUserWriter(.{
        .ctx = @ptrCast(agm),
        .create_fn = &writerCreateUser,
        .delete_fn = &writerDeleteUser,
        .update_password_fn = &writerUpdatePassword,
        .rehash_password_fn = &writerRehashPassword,
        .set_role_fn = &writerSetRole,
        .set_active_fn = &writerSetActive,
    });

    // 3. Role DDL persistence.
    auth_dispatch.setRolePersistCallbacks(.{
        .ctx = @ptrCast(agm),
        .create_fn = &roleCreate,
        .find_id_fn = &roleFindId,
        .remove_fn = &roleRemove,
        .list_fn = &roleList,
    });

    // 4. Grant DDL persistence.
    auth_dispatch.setGrantPersistCallbacks(.{
        .ctx = @ptrCast(agm),
        .resolve_user_id_fn = &grantResolveUserId,
        .grant_fn = &grantApply,
        .revoke_fn = &grantRevoke,
        .list_fn = &grantList,
    });

    // 4b. SONNY-6341: FLE role grants, stored and loaded.
    geode.security.fle_role_grants.setPersistence(.{
        .ctx = @ptrCast(agm),
        .grant_fn = &fleRoleGrantPersist,
        .revoke_fn = &fleRoleRevokePersist,
    });
    // SONNY-6567 (5): every stored FLE role grant, or startup fails.
    const fle_loaded = auth_startup_hydration.hydrateFleRoleGrants(allocator, agm) catch |err| {
        log.err("Auth DDL startup: the FLE role grants could not be loaded; refusing to start", &.{Attr.string("error", @errorName(err))});
        return err;
    };
    if (fle_loaded > 0) log.info("Auth DDL startup: hydrated FLE role grants", &.{Attr.int("count", @intCast(fle_loaded))});

    // 5. Per-graph grant check function for execution.zig fallback path.
    geode.execution.graph_grant_check_fn = &graphGrantCheck;

    // 5b. NEW-1 (#861): create + register the per-graph RBAC policy so graph-bind
    // authorization is actually enforced. Without this the policy is null and
    // every grant check fails open (the BOLA). Process-lifetime singleton.
    const policy = allocator.create(multi_graph_security.GraphRBACPolicy) catch |err| {
        log.err("Auth DDL startup: failed to allocate GraphRBACPolicy; refusing to start", &.{Attr.string("error", @errorName(err))});
        return err;
    };
    policy.* = multi_graph_security.GraphRBACPolicy.init(allocator);
    multi_graph_security.setGlobalPolicy(policy);
    // A startup that fails below lets go of it (`releaseAuthDDLPolicy` is
    // registered only once this returns).
    errdefer {
        multi_graph_security.setGlobalPolicy(null);
        policy.deinit();
        allocator.destroy(policy);
    }

    // CANARY: REQ=REQ-SONNY-6567-AUTH-HYDRATION; FEATURE="AuthDDLPersistence"; ASPECT=StartupRefusesPartialAuthState; STATUS=TESTED; TEST=tests/test_sonny6567_auth_hydration.zig; OWNER=security; UPDATED=2026-11-15
    // 6. Hydrate custom roles. SONNY-6567 (5): every one, or startup fails
    // (each of these steps was best-effort: a warning, and the server ran
    // with part of its roles or grants).
    auth_dispatch.hydrateCustomRolesFromGraph(allocator) catch |err| {
        log.err("Auth DDL startup: the custom roles could not be loaded; refusing to start", &.{Attr.string("error", @errorName(err))});
        return err;
    };

    // 7. Hydrate the in-memory GraphRBACPolicy from the stored grants.
    const grants_loaded = auth_startup_hydration.hydrateGraphGrants(allocator, agm, policy) catch |err| {
        log.err("Auth DDL startup: the per-graph grants could not be loaded; refusing to start", &.{Attr.string("error", @errorName(err))});
        return err;
    };
    if (grants_loaded > 0) log.info("Auth DDL startup: hydrated graph grants", &.{Attr.int("count", @intCast(grants_loaded))});

    log.info("Auth DDL persistence callbacks installed", &.{});
}

/// Free the GraphRBACPolicy `wireAuthDDLCallbacks` installed (SONNY-6378: a
/// debug server reported it leaked at exit). Called from main.zig's
/// shutdown, after every listener and request thread has stopped. Unsetting
/// the global first leaves `graphGrantCheck` denying, not reading freed
/// memory, should anything still ask.
pub fn releaseAuthDDLPolicy(allocator: std.mem.Allocator) void {
    const policy = multi_graph_security.getGlobalPolicy() orelse return;
    multi_graph_security.setGlobalPolicy(null);
    policy.deinit();
    allocator.destroy(policy);
}

// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=StartupWiring; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
/// Hydrate the in-memory PolicyCatalog from __geode_security and install
/// write-through hooks so CREATE/DROP POLICY DDL persists automatically.
///
/// Called from main.zig after wireAuthDDLCallbacks, inside the
/// `if (init_ctx.auth_graph_mgr)` block.
pub fn wireGpsPolicyHooks(
    allocator: std.mem.Allocator,
    agm: *auth_graph_manager.AuthGraphManager,
    catalog: *geode.security.policy_catalog.PolicyCatalog,
) !void {
    const policy_persistence = @import("policy_persistence");
    const policy_catalog_mod = geode.security.policy_catalog;

    // 1. Hydrate the catalog from persisted :Policy nodes. SONNY-6567 (5): a
    // catalog that cannot be loaded fails startup. It was a warning, and the
    // server ran without the stored policies: a deny policy that was not
    // loaded hides nothing.
    policy_persistence.hydrateCatalog(allocator, agm, catalog) catch |err| {
        log.err("GPS policy hydration from __geode_security failed; refusing to start", &.{
            Attr.string("error", @errorName(err)),
        });
        return err;
    };

    // 2. Install write-through hooks.  The AGM pointer is stashed in a
    //    comptime-visible static so the function pointers (which have no
    //    userdata beyond the opaque ctx) can reach it.  The dummy_ctx byte
    //    must live for the duration of the server; it is declared as a
    //    package-level var below.
    const HookCtx = struct {
        var g_agm: ?*auth_graph_manager.AuthGraphManager = null;

        fn persistFn(ctx: *anyopaque, spec: policy_catalog_mod.PolicySpec) anyerror!void {
            _ = ctx;
            const am = g_agm orelse return;
            const pp = @import("policy_persistence");
            try pp.persistPolicy(am, &am.hmac_key, spec);
        }

        fn dropFn(ctx: *anyopaque, name: []const u8) anyerror!void {
            _ = ctx;
            const am = g_agm orelse return;
            const pp = @import("policy_persistence");
            try pp.dropPolicy(am, &am.hmac_key, name);
        }

        // GAP-0858: durable ALTER POLICY write-through (enable/disable + rename).
        fn alterFn(ctx: *anyopaque, name: []const u8, set_enabled: ?bool, rename_to: ?[]const u8) anyerror!void {
            _ = ctx;
            const am = g_agm orelse return;
            const pp = @import("policy_persistence");
            try pp.alterPolicy(am, &am.hmac_key, name, set_enabled, rename_to);
        }
    };
    HookCtx.g_agm = agm;

    policy_catalog_mod.setWriteThroughHooks(.{
        .ctx = @ptrCast(agm), // non-null; actual state is in HookCtx.g_agm
        .persist = HookCtx.persistFn,
        .drop = HookCtx.dropFn,
        .alter = HookCtx.alterFn,
    });

    log.info("GPS policy persistence hooks installed", &.{});

    // CANARY: REQ=REQ-GPS-MIGRATE-001; FEATURE="GPS Grant Migration"; ASPECT=StartupWiring; STATUS=TESTED; TEST=tests/test_gps_grant_migration.zig; OWNER=security; UPDATED=2026-10-11
    // REQ-SEC-PER-GRAPH-GRANTS: grants are no longer migrated to Policy rows
    // (gps.decide reads the live GraphRBACPolicy, hydrated in
    // wireAuthDDLCallbacks). Drop the rows earlier versions migrated: a
    // stale one kept a revoked grant alive and, scoped to one graph, allowed
    // database-wide writes. Runs after hydrateCatalog, which loaded them.
    // SONNY-4877: retirement disables every migrated allow in the live
    // catalog before any step that can fail, so continuing startup after an
    // error is safe: no migrated allow is in force, and the rows still
    // stored are dropped at the next startup.
    const grant_migration = @import("grant_migration");
    const retired = grant_migration.retireMigratedGrantPolicies(allocator, agm, &agm.hmac_key, catalog) catch |err| blk: {
        log.warn("GPS: retiring grant-migrated Policy rows did not complete; the migrated allow policies are disabled, and the rows left are dropped at the next startup", &.{
            Attr.string("error", @errorName(err)),
        });
        break :blk 0;
    };
    if (retired > 0) {
        log.info("GPS: retired grant-migrated Policy rows (grants are read from the live grant table)", &.{
            Attr.int("count", @intCast(retired)),
        });
    }
}
