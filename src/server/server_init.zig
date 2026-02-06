const std = @import("std");
const geode = @import("geode");
const server_flags = geode.server_flags;
// CANARY: REQ=REQ-BINARY-PERSIST-001; FEATURE="BinaryPersistence"; ASPECT=ServerInit; STATUS=IMPL; OWNER=server; UPDATED=2026-02-02
const graph_store = geode.graph_store;
const index_catalog = @import("index_catalog.zig");
const query_ast_cache = @import("query_ast_cache.zig");
// CANARY: REQ=REQ-ABAC-WIRE-001; FEATURE="ABAC Enforcement"; ASPECT=ServerInit; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Import geode_auth for SecurityManager initialization at server startup
const geode_auth = @import("geode_auth");

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
    // GAP-0165: Environment flag to enable ABAC enforcement
    abac_enabled: bool = false,
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

    pub fn deinit(self: *InitContext) void {
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
    }
};

/// Process environment variables and return configuration
pub fn processEnvironmentVariables(allocator: std.mem.Allocator, memcurve_profile_ref: *bool) !EnvironmentConfig {
    var config = EnvironmentConfig{};

    if (std.process.getEnvMap(allocator)) |*env_ptr| {
        var env = env_ptr.*;
        defer env.deinit();

        if (env.get("GEODE_QUERY_MEM_LIMIT_BYTES")) |th| {
            config.spill_threshold = std.fmt.parseInt(usize, th, 10) catch config.spill_threshold;
        } else if (env.get("GEODE_SPILL_THRESHOLD_BYTES")) |th| {
            config.spill_threshold = std.fmt.parseInt(usize, th, 10) catch config.spill_threshold;
        }

        if (env.get("GEODE_NULLS_LAST")) |_| {
            server_flags.setNullsLast(true);
        }

        if (env.get("GEODE_PROFILE_MEMCURVE")) |_| {
            config.memcurve_profile = true;
            memcurve_profile_ref.* = true;
        }

        if (env.get("GEODE_PROFILE_COMPACT")) |_| {
            config.compact_profile = true;
        }

        if (env.get("GEODE_DISABLE_ESTIMATES")) |_| {
            config.disable_estimates = true;
        }

        if (env.get("GEODE_ADAPT_ESTIMATES")) |_| {
            server_flags.setAdaptEstimates(true);
        }

        if (env.get("GEODE_DISABLE_INDEX_CATALOG")) |_| {
            index_catalog.setDisableCatalog(true);
        }

        if (env.get("GEODE_ORDER_KEYS_EXPR")) |val| {
            if (val.len == 0) {
                config.order_keys_expr = true;
            } else if (std.ascii.eqlIgnoreCase(val, "1") or std.ascii.eqlIgnoreCase(val, "true") or std.ascii.eqlIgnoreCase(val, "on")) {
                config.order_keys_expr = true;
            } else {
                config.order_keys_expr = false;
            }
        }

        // CANARY: REQ=REQ-ABAC-WIRE-008; FEATURE="ABAC Enforcement"; ASPECT=EnvVar; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
        // GAP-0165: Check for GEODE_ENABLE_ABAC environment variable to enable ABAC enforcement
        if (env.get("GEODE_ENABLE_ABAC")) |val| {
            config.abac_enabled = val.len > 0 and (val[0] == '1' or std.ascii.eqlIgnoreCase(val, "true"));
        }
    } else |_| {}

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
    var env_config = try processEnvironmentVariables(allocator, memcurve_profile_ref);

    // Apply ORDER BY key policy
    const order_expr = if (order_keys_mode_expr) true else env_config.order_keys_expr;
    server_flags.setOrderKeysExpr(order_expr);

    // CANARY: REQ=REQ-QUIC-CATALOG-003; FEATURE="CatalogDataDirIsolation"; ASPECT=ServerInit; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-27
    // Note: GEODE_DATA_DIR environment variable is read at startup if needed;
    // direct configuration via graph_store.setDataDirOverride() is preferred
    // Set data directory for GraphStore persistence (canonical configuration for isolation)
    graph_store.setDataDirOverride(allocator, data_dir);
    // Initialize GraphStore so we can surface checksum diagnostics if needed.
    _ = graph_store.getGlobalStore(allocator);
    if (graph_store.lastLoadHadChecksumError()) {
        env_config.storage_checksum_error = true;
    }

    // Initialize shared AST cache (cross-connection) if enabled.
    const ast_cache_size = blk: {
        if (std.process.getEnvVarOwned(allocator, "GEODE_AST_CACHE_SIZE")) |v| {
            defer allocator.free(v);
            const parsed = std.fmt.parseInt(usize, v, 10) catch 0;
            break :blk parsed;
        } else |_| {}
        break :blk 2048;
    };

    // CANARY: REQ=REQ-ABAC-WIRE-010; FEATURE="ABAC Enforcement"; ASPECT=ServerStartup; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: Initialize SecurityManager at server startup if ABAC is enabled
    var ctx = InitContext{
        .env_config = env_config,
        .shared_ast_cache = null,
        .shared_ast_cache_storage = null,
        .security_manager = null,
        .security_manager_storage = null,
    };

    if (ast_cache_size > 0) {
        ctx.shared_ast_cache_storage = query_ast_cache.SharedAstCache.init(allocator, ast_cache_size);
        ctx.shared_ast_cache = &ctx.shared_ast_cache_storage.?;
    }

    if (env_config.abac_enabled) {
        ctx.security_manager_storage = initializeSecurityManager(allocator) catch |err| blk: {
            log.err("Failed to initialize SecurityManager", &.{Attr.string("error", @errorName(err))});
            break :blk null;
        };
        if (ctx.security_manager_storage) |*sm| {
            ctx.security_manager = sm;
            log.info("ABAC enforcement enabled - SecurityManager initialized", &.{});
        }
    }

    return ctx;
}
