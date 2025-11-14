const std = @import("std");
const wal_mod = @import("wal");
const storage_pm = @import("storage_page_manager");
const storage_catalog = @import("storage_catalog");
const server_flags = @import("server_flags.zig");
const graph_storage_mgr = @import("graph_storage_manager.zig");
const index_catalog = @import("index_catalog.zig");

// CANARY: REQ=REQ-SERVER-REFACTOR-008; FEATURE="ServerRefactoring"; ASPECT=SERVER_INIT; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-14
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
};

/// Server initialization context containing all initialized resources
pub const InitContext = struct {
    wal: wal_mod.Wal,
    env_config: EnvironmentConfig,
    pm_persist_active: bool,
    pm_persist: storage_pm.PageManager,
    catalog_inited: bool,
    catalog: storage_catalog.StorageCatalog,

    pub fn deinit(self: *InitContext) void {
        if (self.catalog_inited) {
            self.catalog.save() catch {};
            self.catalog.deinit();
        }
        if (self.pm_persist_active) {
            self.pm_persist.deinit();
        }
        self.wal.deinit();
    }
};

/// Initialize WAL (Write-Ahead Log)
pub fn initializeWAL(allocator: std.mem.Allocator, test_wal_skip_ratio: ?f64) !wal_mod.Wal {
    var wal = wal_mod.Wal.init(allocator);
    wal.openFile("/tmp/geode_ephemeral_wal") catch {};
    if (test_wal_skip_ratio) |ov| {
        wal.test_skip_ratio_override = ov;
    }
    return wal;
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

        if (env.get("GEODE_CHECKSUM_TEST_PATH")) |p| {
            var pm = storage_pm.PageManager.initPersistent(allocator, 4096, p);
            defer pm.deinit();
            pm.loadPage(p, 0) catch |e| switch (e) {
                error.PageChecksumMismatch => {
                    config.storage_checksum_error = true;
                    std.log.err("Storage page checksum mismatch detected during startup in path: {s}", .{p});
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

    // Set data directory for graph storage manager
    graph_storage_mgr.setDataDir(data_dir);

    // Initialize persistent storage and catalog
    const storage = try initializeStorage(allocator, data_dir, catalog_create_name);

    return InitContext{
        .wal = wal,
        .env_config = env_config,
        .pm_persist_active = storage.pm_persist_active,
        .pm_persist = storage.pm_persist,
        .catalog_inited = storage.catalog_inited,
        .catalog = storage.catalog,
    };
}
