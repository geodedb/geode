const std = @import("std");
const storage_pm = @import("storage_page_manager");
const storage_catalog = @import("storage_catalog");
const server_flags = @import("server_flags.zig");
const graph_storage_mgr = @import("graph_storage_manager.zig");
const index_catalog = @import("index_catalog.zig");
const wal_manager = @import("wal_manager.zig");
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
    spill_sort: usize = 0,
    spill_distinct: usize = 0,
    spill_union: usize = 0,
    spill_threshold: usize = 0,
    storage_checksum_error: bool = false,
    wal_compact_interval: usize = 5,
    // CANARY: REQ=REQ-ABAC-WIRE-005; FEATURE="ABAC Enforcement"; ASPECT=EnvConfig; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: Environment flag to enable ABAC enforcement
    abac_enabled: bool = false,
};

/// Server initialization context containing all initialized resources
pub const InitContext = struct {
    wal: *wal_manager.WalManager,
    env_config: EnvironmentConfig,
    pm_persist_active: bool,
    pm_persist: storage_pm.PageManager,
    catalog_inited: bool,
    catalog: storage_catalog.StorageCatalog,
    // CANARY: REQ=REQ-ABAC-WIRE-006; FEATURE="ABAC Enforcement"; ASPECT=InitContext; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: SecurityManager instance for RBAC+ABAC enforcement across all connections
    security_manager: ?*geode_auth.SecurityManager = null,
    security_manager_storage: ?geode_auth.SecurityManager = null,

    pub fn deinit(self: *InitContext) void {
        // CANARY: REQ=REQ-ABAC-WIRE-007; FEATURE="ABAC Enforcement"; ASPECT=Cleanup; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
        // GAP-0165: Clean up SecurityManager on server shutdown
        if (self.security_manager_storage) |*sm| {
            sm.deinit();
        }
        if (self.catalog_inited) {
            self.catalog.save() catch {};
            self.catalog.deinit();
        }
        if (self.pm_persist_active) {
            self.pm_persist.deinit();
        }
        // Shared WAL manager lives across connections; deinit it at shutdown.
        wal_manager.deinitGlobalWalManager();
    }
};

/// Initialize WAL (Write-Ahead Log)
pub fn initializeWAL(allocator: std.mem.Allocator, test_wal_skip_ratio: ?f64) !*wal_manager.WalManager {
    return wal_manager.getOrCreateWalManager(allocator, test_wal_skip_ratio);
}

/// Process environment variables and return configuration
pub fn processEnvironmentVariables(allocator: std.mem.Allocator, memcurve_profile_ref: *bool) !EnvironmentConfig {
    var config = EnvironmentConfig{};

    if (std.process.getEnvMap(allocator)) |*env_ptr| {
        var env = env_ptr.*;
        defer env.deinit();

        if (env.get("GEODE_FORCE_SORT_SPILL")) |_| config.spill_sort = 1;
        if (env.get("GEODE_FORCE_DISTINCT_SPILL")) |_| config.spill_distinct = 1;
        if (env.get("GEODE_FORCE_UNION_SPILL")) |_| config.spill_union = 1;

        if (env.get("GEODE_QUERY_MEM_LIMIT_BYTES")) |th| {
            config.spill_threshold = std.fmt.parseInt(usize, th, 10) catch config.spill_threshold;
        } else if (env.get("GEODE_SPILL_THRESHOLD_BYTES")) |th| {
            config.spill_threshold = std.fmt.parseInt(usize, th, 10) catch config.spill_threshold;
        }

        if (env.get("GEODE_WAL_COMPACT_INTERVAL")) |ci| {
            config.wal_compact_interval = std.fmt.parseInt(usize, ci, 10) catch 5;
        }

        if (env.get("GEODE_NULLS_LAST")) |_| {
            server_flags.setNullsLast(true);
        }

        if (env.get("GEODE_PROFILE_MEMCURVE")) |_| {
            memcurve_profile_ref.* = true;
        }

        if (env.get("GEODE_ADAPT_ESTIMATES")) |_| {
            server_flags.setAdaptEstimates(true);
        }

        if (env.get("GEODE_DISABLE_INDEX_CATALOG")) |_| {
            index_catalog.setDisableCatalog(true);
        }

        // CANARY: REQ=REQ-ABAC-WIRE-008; FEATURE="ABAC Enforcement"; ASPECT=EnvVar; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
        // GAP-0165: Check for GEODE_ENABLE_ABAC environment variable to enable ABAC enforcement
        if (env.get("GEODE_ENABLE_ABAC")) |val| {
            config.abac_enabled = val.len > 0 and (val[0] == '1' or std.ascii.eqlIgnoreCase(val, "true"));
        }

        if (env.get("GEODE_CHECKSUM_TEST_PATH")) |p| {
            var pm = storage_pm.PageManager.initPersistent(allocator, 4096, p);
            defer pm.deinit();
            pm.loadPage(p, 0) catch |e| switch (e) {
                error.PageChecksumMismatch => {
                    config.storage_checksum_error = true;
                    log.err("Storage page checksum mismatch detected during startup", &.{Attr.string("path", p)});
                },
                else => {},
            };
        }
    } else |_| {}

    return config;
}

/// Initialize persistent storage and catalog
pub fn initializeStorage(
    allocator: std.mem.Allocator,
    data_dir: ?[]const u8,
    catalog_create_name: ?[]const u8,
) !struct {
    pm_persist_active: bool,
    pm_persist: storage_pm.PageManager,
    catalog_inited: bool,
    catalog: storage_catalog.StorageCatalog,
} {
    var pm_persist_active = false;
    var pm_persist: storage_pm.PageManager = undefined;
    var catalog_inited = false;
    var catalog = storage_catalog.StorageCatalog{
        .allocator = allocator,
        .page_manager = undefined,
        .tables = undefined,
        .indexes = undefined,
        .sequences = undefined,
        .catalog_page_id = null,
        .graph_metadata = null,
    };

    if (data_dir) |dd| {
        std.fs.cwd().makePath(dd) catch {};
        pm_persist = storage_pm.PageManager.initPersistent(allocator, 4096, dd);
        pm_persist_active = true;
        pm_persist.loadPage(dd, 0) catch {};
        catalog = storage_catalog.StorageCatalog.init(allocator, &pm_persist);
        catalog.load() catch {};
        catalog_inited = true;

        if (catalog_create_name) |tname| {
            catalog.createTable(tname, &.{}) catch {};
        }

        // Try to load graph from catalog
        if (graph_storage_mgr.getCurrentGraphStorage() == null) {
            const loaded = graph_storage_mgr.tryLoadGraphFromDir(allocator, dd) catch null;
            if (loaded) |lg| {
                _ = lg; // Graph is loaded via tryLoadGraphFromDir
                // Update catalog metadata
                if (catalog.graph_metadata == null) {
                    catalog.initGraphMetadata() catch {};
                }
                if (graph_storage_mgr.getCurrentGraphStorage()) |gs| {
                    const max_edge_id = if (gs.edges.items.len > 0) gs.edges.items.len - 1 else 0;
                    catalog.saveGraphMetadata(
                        @intCast(gs.nodes.count()),
                        @intCast(gs.edges.items.len),
                        0, // max_node_id - would need to calculate
                        max_edge_id,
                    ) catch {};
                }
            }
        }
    }

    return .{
        .pm_persist_active = pm_persist_active,
        .pm_persist = pm_persist,
        .catalog_inited = catalog_inited,
        .catalog = catalog,
    };
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
    catalog_create_name: ?[]const u8,
    test_wal_skip_ratio: ?f64,
    memcurve_profile_ref: *bool,
) !InitContext {
    // Initialize WAL
    const wal = try initializeWAL(allocator, test_wal_skip_ratio);
    errdefer wal.deinit();

    // Initialize index catalog (idempotent)
    index_catalog.initIndexCatalog(allocator);

    // Process environment variables
    const env_config = try processEnvironmentVariables(allocator, memcurve_profile_ref);

    // Apply ORDER BY key policy
    server_flags.setOrderKeysExpr(order_keys_mode_expr);

    // Ensure the execution/catalog singleton uses the server's data directory.
    // Without this, ensureCatalogInstance() falls back to /tmp, and parallel
    // test servers can interfere with each other's catalog/graph metadata.
    // CANARY: REQ=REQ-QUIC-CATALOG-003; FEATURE="CatalogDataDirIsolation"; ASPECT=ServerInit; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-27
    const actual_data_dir = data_dir orelse "./data";
    std.process.setEnvVar("GEODE_DATA_DIR", actual_data_dir) catch |err| {
        log.warn("Failed to set GEODE_DATA_DIR", &.{
            Attr.string("error", @errorName(err)),
            Attr.string("data_dir", actual_data_dir),
        });
    };

    // Set data directory for graph storage manager
    graph_storage_mgr.setDataDir(data_dir);

    // Initialize persistent storage and catalog
    const storage = try initializeStorage(allocator, data_dir, catalog_create_name);

    // CANARY: REQ=REQ-ABAC-WIRE-010; FEATURE="ABAC Enforcement"; ASPECT=ServerStartup; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: Initialize SecurityManager at server startup if ABAC is enabled
    var ctx = InitContext{
        .wal = wal,
        .env_config = env_config,
        .pm_persist_active = storage.pm_persist_active,
        .pm_persist = storage.pm_persist,
        .catalog_inited = storage.catalog_inited,
        .catalog = storage.catalog,
        .security_manager = null,
        .security_manager_storage = null,
    };

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
