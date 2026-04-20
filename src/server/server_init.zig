const std = @import("std");

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const geode = @import("geode");
const server_flags = geode.server_flags;
// CANARY: REQ=REQ-BINARY-PERSIST-001; FEATURE="BinaryPersistence"; ASPECT=ServerInit; STATUS=IMPL; OWNER=server; UPDATED=2026-02-02
const graph_store = geode.graph_store;
const index_catalog = @import("index_catalog.zig");
const query_ast_cache = @import("query_ast_cache");
const query_plan_cache = geode.query_plan_cache;
// CANARY: REQ=REQ-ABAC-WIRE-001; FEATURE="ABAC Enforcement"; ASPECT=ServerInit; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Import geode_auth for SecurityManager initialization at server startup
const geode_auth = @import("geode_auth");
// CANARY: REQ=REQ-AUTH-GRAPH-WIRE-004; FEATURE="AuthGraphManager Integration"; ASPECT=ServerInit; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
const auth_graph_manager = @import("auth_graph_manager");

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
    // CANARY: REQ=REQ-ABAC-WIRE-005; FEATURE="ABAC Enforcement"; ASPECT=EnvConfig; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165 / SEC-14: ABAC enforcement enabled by default for security.
    // Set GEODE_ENABLE_ABAC=false to disable.
    abac_enabled: bool = true,
    // #683: Cache per-connection env vars at startup to avoid repeated syscalls.
    query_optimizer_enabled: bool = false,
    inline_results_enabled: bool = true,
    inline_results_max_rows: usize = 1000,
    telemetry_paging: bool = false,
};

/// Server initialization context containing all initialized resources
pub const InitContext = struct {
    env_config: EnvironmentConfig,
    // Shared AST cache for cross-connection reuse (optional).
    shared_ast_cache: ?*query_ast_cache.SharedAstCache = null,
    shared_ast_cache_storage: ?query_ast_cache.SharedAstCache = null,
    // CANARY: REQ=REQ-ABAC-WIRE-006; FEATURE="ABAC Enforcement"; ASPECT=InitContext; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: SecurityManager instance for RBAC+ABAC enforcement across all connections
    security_manager: ?*geode_auth.SecurityManager = null,
    security_manager_storage: ?geode_auth.SecurityManager = null,
    // CANARY: REQ=REQ-PERF-SHARED-OPT-001; FEATURE="SharedQueryOptimizer"; ASPECT=InitContext; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
    // Issue #460: Shared cross-connection query optimizer for plan reuse
    shared_optimizer: ?*query_plan_cache.SharedQueryOptimizer = null,
    shared_optimizer_storage: ?query_plan_cache.SharedQueryOptimizer = null,
    // CANARY: REQ=REQ-AUTH-GRAPH-WIRE-005; FEATURE="AuthGraphManager Integration"; ASPECT=InitContext; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
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

        // CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-008; FEATURE="Runtime Auth Graph Persistence"; ASPECT=WireCallbacks; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
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

        // CANARY: REQ=REQ-AUTH-HMAC-PERIODIC-003; FEATURE="PeriodicHmacVerification"; ASPECT=ServerStartup; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
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
        // CANARY: REQ=REQ-ABAC-WIRE-007; FEATURE="ABAC Enforcement"; ASPECT=Cleanup; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
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
        // CANARY: REQ=REQ-AUTH-GRAPH-WIRE-006; FEATURE="AuthGraphManager Integration"; ASPECT=Cleanup; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
        // CANARY: REQ=REQ-AUTH-HMAC-PERIODIC-004; FEATURE="PeriodicHmacVerification"; ASPECT=Shutdown; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
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

    // CANARY: REQ=REQ-ABAC-WIRE-008; FEATURE="ABAC Enforcement"; ASPECT=EnvVar; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: Check for GEODE_ENABLE_ABAC environment variable to enable ABAC enforcement
    if (getenvSlice("GEODE_ENABLE_ABAC")) |val| {
        config.abac_enabled = val.len > 0 and (val[0] == '1' or std.ascii.eqlIgnoreCase(val, "true"));
    }

    return config;
}

// CANARY: REQ=REQ-ABAC-WIRE-009; FEATURE="ABAC Enforcement"; ASPECT=SecurityInit; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Initialize SecurityManager for RBAC+ABAC policy enforcement
/// Initialize SecurityManager if ABAC is enabled
pub fn initializeSecurityManager(allocator: std.mem.Allocator) !geode_auth.SecurityManager {
    return geode_auth.SecurityManager.init(allocator);
}

/// Complete server initialization
pub fn initialize(
    allocator: std.mem.Allocator,
    order_keys_mode_expr: bool,
    data_dir: ?[]const u8,
    memcurve_profile_ref: *bool,
) !InitContext {
    // Initialize index catalog (idempotent)
    index_catalog.initIndexCatalog(allocator);

    // Process environment variables
    const env_config = try processEnvironmentVariables(allocator, memcurve_profile_ref);

    // Apply ORDER BY key policy
    const order_expr = if (order_keys_mode_expr) true else env_config.order_keys_expr;
    server_flags.setOrderKeysExpr(order_expr);

    // CANARY: REQ=REQ-QUIC-CATALOG-003; FEATURE="CatalogDataDirIsolation"; ASPECT=ServerInit; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-27
    // Note: GEODE_DATA_DIR environment variable is read at startup if needed;
    // direct configuration via graph_store.setDataDirOverride() is preferred
    // Set data directory for GraphStore persistence (canonical configuration for isolation)
    graph_store.setDataDirOverride(allocator, data_dir);

    // CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-007; FEATURE="EngineBackedPersistence"; ASPECT=ServerInit; STATUS=IMPL; OWNER=storage; UPDATED=2026-03-28
    // Initialize global store with engine-backed adapter (creates adapter + loads from engine).
    const store = if (data_dir) |dir|
        graph_store.initGlobalStore(allocator, dir) catch |err| blk: {
            log.warn("Failed to initialize engine-backed store, falling back to in-memory", &.{
                Attr.string("error", @errorName(err)),
            });
            break :blk graph_store.getGlobalStore(allocator);
        }
    else
        graph_store.getGlobalStore(allocator);

    // CANARY: REQ=REQ-AUTH-GRAPH-WIRE-007; FEATURE="AuthGraphManager Integration"; ASPECT=ServerStartup; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
    // Initialize AuthGraphManager: resolve HMAC key, verify or bootstrap auth chain
    const hmac_key_result: ?auth_graph_manager.HmacKeyResult = hmac_blk: {
        const kr = auth_graph_manager.AuthGraphManager.resolveHmacKey(allocator, data_dir) catch |err| {
            switch (err) {
                error.NoHmacKeyAvailable => {
                    log.warn("No HMAC key available for auth chain verification - auth graph disabled", &.{});
                },
            }
            break :hmac_blk null;
        };
        break :hmac_blk kr;
    };

    var agm_storage: ?auth_graph_manager.AuthGraphManager = agm_blk: {
        if (hmac_key_result) |*kr| {
            var agm = auth_graph_manager.AuthGraphManager.init(allocator, store) catch |err| {
                log.warn("AuthGraphManager initialization failed", &.{
                    Attr.string("error", @errorName(err)),
                });
                break :agm_blk null;
            };

            if (agm.hasAuthRecords()) {
                if (getEnvVarOwned(allocator, "GEODE_ADMIN_PASSWORD")) |env_pw| {
                    allocator.free(env_pw);
                    log.info("GEODE_ADMIN_PASSWORD ignored because auth records already exist", &.{});
                } else |_| {}

                // Verify HMAC chain integrity
                agm.verifyChain(&kr.key) catch |err| {
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
                    log.err("Failed to bootstrap default admin user", &.{
                        Attr.string("error", @errorName(err)),
                    });
                    agm.deinit();
                    break :agm_blk null;
                };
                // Print generated password to stderr only (never to structured log).
                // Skip the message when the password came from GEODE_ADMIN_PASSWORD
                // so test runners don't see a misleading "generated" label.
                if (getEnvVarOwned(allocator, "GEODE_ADMIN_PASSWORD")) |env_pw| {
                    allocator.free(env_pw);
                } else |_| {
                    std.debug.print("\n*** Generated admin password: {s} ***\n", .{result.password});
                }
                log.info("Default admin user bootstrapped via auth graph", &.{
                    Attr.string("username", result.username),
                });
                allocator.free(result.username);
                allocator.free(result.password);
            }

            // CANARY: REQ=REQ-AUTH-HMAC-PERIODIC-003; FEATURE="PeriodicHmacVerification"; ASPECT=ServerStartup; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
            // NOTE: Do NOT start periodic verification here. `agm` is a stack local
            // that will be moved by value into `agm_storage` and then again when
            // InitContext is returned. The thread captures `self` by pointer, so
            // starting it here creates a dangling pointer.  The thread is started
            // in fixupSelfPointers() after the struct reaches its final location.
            agm.hmac_key = kr.key;

            break :agm_blk agm;
        }
        break :agm_blk null;
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

    // Issue #460: Initialize shared query optimizer (cross-connection plan cache)
    const plan_cache_size = blk: {
        if (getEnvVarOwned(allocator, "GEODE_PLAN_CACHE_SIZE")) |v| {
            defer allocator.free(v);
            const parsed = std.fmt.parseInt(usize, v, 10) catch 0;
            break :blk parsed;
        } else |_| {}
        break :blk 512;
    };

    // CANARY: REQ=REQ-ABAC-WIRE-010; FEATURE="ABAC Enforcement"; ASPECT=ServerStartup; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
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
        ctx.shared_ast_cache_storage = query_ast_cache.SharedAstCache.init(allocator, ast_cache_size);
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

    // CANARY: REQ=REQ-AUTH-GRAPH-WIRE-008; FEATURE="AuthGraphManager Integration"; ASPECT=SecurityManagerInit; STATUS=IMPL; OWNER=security; UPDATED=2026-03-12
    // Always initialize SecurityManager when auth graph is available so that
    // runtime password changes are persisted to disk.  ABAC policy enforcement
    // is gated separately; the SecurityManager is needed for persistence even
    // when ABAC is disabled.
    if (agm_storage != null) {
        // Auth graph is available: hydrate SecurityManager from graph records
        ctx.security_manager_storage = hydrateSecurityManagerFromGraph(allocator, &agm_storage.?, hmac_key_result) catch |err| blk: {
            log.err("Failed to hydrate SecurityManager from auth graph", &.{Attr.string("error", @errorName(err))});
            break :blk null;
        };
        if (ctx.security_manager_storage != null) {
            if (env_config.abac_enabled) {
                log.info("ABAC enforcement enabled - SecurityManager hydrated from auth graph", &.{});
            } else {
                log.info("SecurityManager hydrated from auth graph (ABAC enforcement disabled)", &.{});
            }
        }
    } else if (env_config.abac_enabled) {
        // Fallback: old behavior (no auth graph, create default user)
        ctx.security_manager_storage = initializeSecurityManager(allocator) catch |err| blk: {
            log.err("Failed to initialize SecurityManager", &.{Attr.string("error", @errorName(err))});
            break :blk null;
        };
        if (ctx.security_manager_storage != null) {
            log.info("ABAC enforcement enabled - SecurityManager initialized (legacy mode)", &.{});
        }
    }

    return ctx;
}

// CANARY: REQ=REQ-AUTH-GRAPH-WIRE-009; FEATURE="AuthGraphManager Integration"; ASPECT=Hydration; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24
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

// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-009; FEATURE="Runtime Auth Graph Persistence"; ASPECT=Callbacks; STATUS=IMPL; OWNER=security; UPDATED=2026-02-24

fn graphPersistUserCreate(opaque_agm: *anyopaque, hmac_key: *const [32]u8, username: []const u8, email: []const u8, password_hash: []const u8, is_superuser: bool) callconv(.auto) u64 {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(opaque_agm));
    return agm.createUser(hmac_key, username, email, password_hash, is_superuser) catch |err| {
        log.warn("Failed to persist user creation to auth graph", &.{
            Attr.string("error", @errorName(err)),
            Attr.string("username", username),
        });
        return 0;
    };
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
    return agm.updateUserPassword(hmac_key, user_id, new_password_hash) catch |err| {
        log.warn("Failed to persist password change to auth graph", &.{
            Attr.string("error", @errorName(err)),
            Attr.uint("user_id", user_id),
        });
        return 0;
    };
}

fn graphPersistRoleMembership(opaque_agm: *anyopaque, hmac_key: *const [32]u8, user_id: u64, role_id: u64, assign: bool) callconv(.auto) u64 {
    const agm: *auth_graph_manager.AuthGraphManager = @ptrCast(@alignCast(opaque_agm));
    return if (assign)
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
}
