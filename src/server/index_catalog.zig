const std = @import("std");
const SelectivityEstimator = @import("index_selectivity").SelectivityEstimator;

// CANARY: REQ=REQ-SERVER-REFACTOR-003; FEATURE="ServerRefactoring"; ASPECT=INDEX_CATALOG; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-12
// Phase 3 M3.1 - Index Catalog Module (Incremental Extraction)
// Extracted index statistics and catalog management from server/main.zig for better modularity

/// Index statistics for cost-based query optimization
/// Tracks total rows and distinct keys for selectivity estimation
pub const IndexStats = struct {
    name: []const u8,
    key: []const u8,
    total_rows: usize,
    distinct_keys: usize,

    /// Calculate equality predicate selectivity (1 / distinct_keys)
    pub fn eqSelectivity(self: IndexStats) f64 {
        if (self.distinct_keys == 0) return 1.0;
        return 1.0 / @as(f64, @floatFromInt(self.distinct_keys));
    }
};

/// Global index catalog state
var g_index_catalog_map: std.StringHashMap(IndexStats) = undefined;
var g_index_catalog_inited = false;
var g_disable_catalog = false; // env toggle
var g_selectivity_estimator: ?*SelectivityEstimator = null;

/// Initialize the index catalog with default statistics
/// Seeds catalog with synthetic stats for x,y columns
pub fn initIndexCatalog(allocator: std.mem.Allocator) void {
    if (g_index_catalog_inited) return;
    g_index_catalog_map = std.StringHashMap(IndexStats).init(allocator);

    // Initialize selectivity estimator
    const estimator = allocator.create(SelectivityEstimator) catch return;
    estimator.* = SelectivityEstimator.init(allocator);
    g_selectivity_estimator = estimator;

    // Seed with synthetic stats for x,y columns
    g_index_catalog_map.put("x", IndexStats{ .name = "idx_x", .key = "x", .total_rows = 1000, .distinct_keys = 200 }) catch {};
    g_index_catalog_map.put("y", IndexStats{ .name = "idx_y", .key = "y", .total_rows = 1000, .distinct_keys = 500 }) catch {};

    // Update selectivity estimator with same stats
    if (g_selectivity_estimator) |est| {
        est.updateStats("x", 1000, 200, 10) catch {};
        est.updateStats("y", 1000, 500, 5) catch {};
    }

    g_index_catalog_inited = true;
}

/// Choose optimal index for a predicate using cost-based analysis.
///
/// GAP-0867: an index is only a candidate when the predicate actually
/// references the indexed property. `predicate_prop` is the property name the
/// equality predicate references (extracted by the caller from the predicate
/// expression — e.g. `n.x = 5` yields "x"). Previously the predicate was
/// ignored entirely and the lowest-selectivity index in the catalog was
/// chosen regardless of whether the predicate could use it.
///
/// Returns null when no property is referenced (`predicate_prop == null`),
/// when no index covers that property, or when a table scan is estimated to
/// be cheaper (index must beat the scan by at least 10%).
pub fn chooseIndexForPredicate(predicate_prop: ?[]const u8, has_equality: bool, est_rows: usize) ?IndexStats {
    if (g_disable_catalog or !has_equality) return null;
    const prop = predicate_prop orelse return null;
    const st = g_index_catalog_map.get(prop) orelse return null;

    const scan_cost = @as(f64, @floatFromInt(est_rows)); // table scan cost

    // Use SelectivityEstimator if available for more sophisticated cost-based decision
    if (g_selectivity_estimator) |estimator| {
        const index_cost = estimator.estimateIndexCost(st.key, .Equality, est_rows);
        if (index_cost < scan_cost * 0.9) return st; // require at least 10% benefit
        return null;
    }

    // Fallback: naive cost — index cost = selectivity * total_rows + log(total_rows)
    const idx_rows = st.eqSelectivity() * @as(f64, @floatFromInt(st.total_rows));
    const idx_cost = idx_rows + std.math.log(f64, 2, @as(f64, @floatFromInt(st.total_rows + 1)));
    if (idx_cost < scan_cost * 0.9) return st; // require at least 10% benefit
    return null;
}

/// Update index statistics after insert operation
/// Adjusts total_rows and estimates distinct_keys growth
pub fn indexStatsOnInsert(key: []const u8) void {
    if (!g_index_catalog_inited or g_disable_catalog) return;
    if (g_index_catalog_map.getPtr(key)) |st| {
        st.total_rows += 1;
        // naive: assume new distinct every 5 inserts
        if ((st.total_rows % 5) == 0) st.distinct_keys += 1;

        // Update selectivity estimator
        if (g_selectivity_estimator) |est| {
            est.updateStats(key, st.total_rows, st.distinct_keys, 0) catch {};
        }
    }
}

/// Update index statistics after delete operation
/// Decrements total_rows (distinct_keys unchanged for prototype)
pub fn indexStatsOnDelete(key: []const u8) void {
    if (!g_index_catalog_inited or g_disable_catalog) return;
    if (g_index_catalog_map.getPtr(key)) |st| {
        if (st.total_rows > 0) st.total_rows -= 1;
        // naive: distinct unaffected for prototype

        // Update selectivity estimator
        if (g_selectivity_estimator) |est| {
            est.updateStats(key, st.total_rows, st.distinct_keys, 0) catch {};
        }
    }
}

/// Set catalog disabled flag (for testing or performance tuning)
pub fn setDisableCatalog(disabled: bool) void {
    g_disable_catalog = disabled;
}

/// Check if catalog is initialized
pub fn isCatalogInitialized() bool {
    return g_index_catalog_inited;
}

/// Clean up catalog resources
pub fn deinitIndexCatalog() void {
    if (!g_index_catalog_inited) return;

    if (g_selectivity_estimator) |est| {
        const alloc = est.allocator;
        est.deinit();
        alloc.destroy(est);
    }

    g_index_catalog_map.deinit();
    g_index_catalog_inited = false;
    g_selectivity_estimator = null;
}
