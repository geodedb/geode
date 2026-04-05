// CANARY: REQ=REQ-DIST-QUERY-COORD-001; FEATURE="Enhanced Query Coordination"; ASPECT=MergeStrategies; STATUS=IMPL; OWNER=dist; UPDATED=2026-04-05

const std = @import("std");
const protocol = @import("../protocol.zig");
const federation = @import("federation.zig");
const value_utilities = @import("../execution/value_utilities.zig");

/// Merge strategy for combining distributed query results.
pub const MergeStrategy = enum {
    union_all,
    union_distinct,
    merge_sorted,
    hash_aggregate,
    top_k,
};

/// Aggregate group for hash-aggregate merge strategy.
pub const AggregateGroup = struct {
    count: u64,
    sum: f64,
    representative_row: protocol.BindingRow,
};

// GAP-0130: ORDER BY key for distributed query sorting
// CANARY: REQ=REQ-DIST-ORDERBY-001; FEATURE="Distributed ORDER BY"; ASPECT=QueryCorrectness; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
pub const OrderByKey = struct {
    column_index: usize,
    ascending: bool = true,
    nulls_first: bool = true,
};

pub const QueryOptions = struct {
    consistency_level: federation.ConsistencyLevel = .eventual,
    use_cache: bool = true,
    cache_ttl_ms: u64 = 300000, // 5 minutes
    limit: ?usize = null,
    offset: ?usize = null,
    timeout_ms: u32 = 30000,
    // GAP-0130: ORDER BY keys for result sorting
    order_by: []const OrderByKey = &.{},
};

pub const QueryAnalysis = struct {
    allocator: std.mem.Allocator,
    query_type: QueryType,
    referenced_labels: std.ArrayList([]u8),
    referenced_properties: std.ArrayList([]u8),
    has_global_ordering: bool = false,
    has_aggregation: bool = false,
    estimated_selectivity: f64 = 1.0,

    pub const QueryType = enum {
        match_query,
        create_query,
        delete_query,
        other,
    };

    pub fn init(allocator: std.mem.Allocator) QueryAnalysis {
        return QueryAnalysis{
            .allocator = allocator,
            .query_type = .other,
            .referenced_labels = std.ArrayList([]u8).init(allocator),
            .referenced_properties = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *QueryAnalysis) void {
        for (self.referenced_labels.items) |label| {
            self.allocator.free(label);
        }
        self.referenced_labels.deinit();

        for (self.referenced_properties.items) |prop| {
            self.allocator.free(prop);
        }
        self.referenced_properties.deinit();
    }
};

pub const DistributedExecutionPlan = struct {
    allocator: std.mem.Allocator,
    fragments: []QueryFragment,
    merge_strategy: MergeStrategy,
    estimated_cost: f64 = 0.0,

    pub const QueryFragment = struct {
        node_id: u32,
        query_text: []const u8,
        estimated_rows: u64,
        estimated_time_ms: u64,
    };

    pub fn deinit(self: *DistributedExecutionPlan) void {
        for (self.fragments) |fragment| {
            self.allocator.free(fragment.query_text);
        }
        self.allocator.free(self.fragments);
    }
};

pub const ShardRegistry = struct {
    allocator: std.mem.Allocator,
    shards: std.StringHashMap(ShardInfo),

    pub fn init(allocator: std.mem.Allocator) !ShardRegistry {
        return ShardRegistry{
            .allocator = allocator,
            .shards = std.StringHashMap(ShardInfo).init(allocator),
        };
    }

    pub fn deinit(self: *ShardRegistry) void {
        self.shards.deinit();
    }
};

pub const NodeRegistry = struct {
    allocator: std.mem.Allocator,
    nodes: std.StringHashMap(NodeInfo),

    pub fn init(allocator: std.mem.Allocator) !NodeRegistry {
        return NodeRegistry{
            .allocator = allocator,
            .nodes = std.StringHashMap(NodeInfo).init(allocator),
        };
    }

    pub fn deinit(self: *NodeRegistry) void {
        self.nodes.deinit();
    }
};

pub const DistributedQueryOptimizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !DistributedQueryOptimizer {
        return DistributedQueryOptimizer{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DistributedQueryOptimizer) void {
        _ = self;
    }

    pub fn optimizeQuery(self: *DistributedQueryOptimizer, analysis: QueryAnalysis, shard_registry: *ShardRegistry) !DistributedExecutionPlan {
        _ = shard_registry;

        // Simplified optimization - in practice would be much more sophisticated
        var fragments = try self.allocator.alloc(DistributedExecutionPlan.QueryFragment, 1);
        fragments[0] = DistributedExecutionPlan.QueryFragment{
            .node_id = 1,
            .query_text = try self.allocator.dupe(u8, "SIMPLIFIED QUERY"),
            .estimated_rows = 1000,
            .estimated_time_ms = 100,
        };

        const strategy = if (analysis.has_global_ordering)
            MergeStrategy.merge_sorted
        else if (analysis.has_aggregation)
            MergeStrategy.hash_aggregate
        else
            MergeStrategy.union_all;

        return DistributedExecutionPlan{
            .allocator = self.allocator,
            .fragments = fragments,
            .merge_strategy = strategy,
            .estimated_cost = 100.0,
        };
    }
};

pub const QueryCache = struct {
    allocator: std.mem.Allocator,
    cache: std.StringHashMap(CacheEntry),
    enabled: bool = true,
    max_entries: usize = 1000,

    const CacheEntry = struct {
        result: federation.QueryResults,
        timestamp: i64,
        ttl_ms: u64,
    };

    pub fn init(allocator: std.mem.Allocator) !QueryCache {
        return QueryCache{
            .allocator = allocator,
            .cache = std.StringHashMap(CacheEntry).init(allocator),
        };
    }

    pub fn deinit(self: *QueryCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            var res = entry.value_ptr.result;
            res.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit();
    }

    pub fn hashQuery(self: *QueryCache, query: []const u8, params: []const protocol.Value) ![]u8 {
        _ = params;
        var hasher = std.hash_map.DefaultHasher.init();
        hasher.update(query);
        const hash_value = hasher.final();
        return try std.fmt.allocPrint(self.allocator, "{x}", .{hash_value});
    }

    pub fn get(self: *QueryCache, query_hash: []const u8) !?federation.QueryResults {
        if (!self.enabled) return null;

        if (self.cache.get(query_hash)) |entry| {
            const now = std.time.milliTimestamp();
            if (now - entry.timestamp < entry.ttl_ms) {
                return try cloneQueryResults(self.allocator, entry.result);
            } else {
                if (self.cache.fetchRemove(query_hash)) |removed| {
                    var res = removed.value.result;
                    res.deinit(self.allocator);
                    self.allocator.free(removed.key);
                }
            }
        }

        return null;
    }

    pub fn put(self: *QueryCache, query_hash: []const u8, result: federation.QueryResults, ttl_ms: u64) !void {
        if (!self.enabled) return;

        if (self.cache.fetchRemove(query_hash)) |removed| {
            var res = removed.value.result;
            res.deinit(self.allocator);
            self.allocator.free(removed.key);
        }

        const key_copy = try self.allocator.dupe(u8, query_hash);
        try self.cache.put(key_copy, CacheEntry{
            .result = try cloneQueryResults(self.allocator, result),
            .timestamp = std.time.milliTimestamp(),
            .ttl_ms = ttl_ms,
        });
    }
};

pub const CoordinatorMetrics = struct {
    total_queries: u64 = 0,
    total_time_ms: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    merge_time_ms: u64 = 0,
    shard_queries: u64 = 0,

    pub fn init() CoordinatorMetrics {
        return CoordinatorMetrics{};
    }

    pub fn recordQuery(self: *CoordinatorMetrics, time_ms: u64, shard_count: usize) void {
        self.total_queries += 1;
        self.total_time_ms += time_ms;
        self.shard_queries += @as(u64, @intCast(shard_count));
    }

    pub fn recordCacheHit(self: *CoordinatorMetrics) void {
        self.cache_hits += 1;
    }

    pub fn recordMergeTime(self: *CoordinatorMetrics, time_ms: u64) void {
        self.merge_time_ms += time_ms;
    }
};

pub const CoordinatorConfig = struct {
    cache_enabled: ?bool = null,
    max_parallel_queries: ?u32 = null,
};

pub const ShardInfo = struct {
    id: []const u8,
    node_id: u32,
    key_range_start: u64,
    key_range_end: u64,
};

pub const NodeInfo = struct {
    id: u32,
    address: []const u8,
    region: []const u8,
    capabilities: []const u8,
};

// --- Shared helper functions ---

pub fn cloneBindingRow(allocator: std.mem.Allocator, row: protocol.BindingRow) !protocol.BindingRow {
    var cols = try allocator.alloc(protocol.Value, row.cols.len);
    errdefer {
        for (cols) |val| value_utilities.freeValue(allocator, val);
        allocator.free(cols);
    }
    for (row.cols, 0..) |val, i| {
        cols[i] = try value_utilities.duplicateValue(allocator, val);
    }
    return .{ .cols = cols };
}

pub fn freeBindingRow(allocator: std.mem.Allocator, row: protocol.BindingRow) void {
    for (row.cols) |val| {
        value_utilities.freeValue(allocator, val);
    }
    if (row.cols.len > 0) allocator.free(row.cols);
}

pub fn cloneSchema(allocator: std.mem.Allocator, schema_defs: []const protocol.ColumnDef) ![]const protocol.ColumnDef {
    var cols = try allocator.alloc(protocol.ColumnDef, schema_defs.len);
    errdefer {
        for (cols) |col| {
            allocator.free(col.name);
            allocator.free(col.data_type);
        }
        allocator.free(cols);
    }
    for (schema_defs, 0..) |col, i| {
        cols[i] = .{
            .name = try allocator.dupe(u8, col.name),
            .data_type = try allocator.dupe(u8, col.data_type),
        };
    }
    return cols;
}

pub fn freeSchema(allocator: std.mem.Allocator, schema_defs: []const protocol.ColumnDef) void {
    for (schema_defs) |col| {
        allocator.free(col.name);
        allocator.free(col.data_type);
    }
    allocator.free(schema_defs);
}

pub fn cloneOrderKeys(allocator: std.mem.Allocator, keys: []const []const u8) ![]const []const u8 {
    var cloned = try allocator.alloc([]const u8, keys.len);
    errdefer {
        for (cloned) |k| allocator.free(k);
        allocator.free(cloned);
    }
    for (keys, 0..) |k, i| {
        cloned[i] = try allocator.dupe(u8, k);
    }
    return cloned;
}

pub fn cloneOrderDirs(allocator: std.mem.Allocator, dirs: []const bool) ![]const bool {
    var cloned = try allocator.alloc(bool, dirs.len);
    std.mem.copyForwards(bool, cloned, dirs);
    return cloned;
}

pub fn cloneQueryResults(allocator: std.mem.Allocator, result: federation.QueryResults) !federation.QueryResults {
    var rows = try allocator.alloc(protocol.BindingRow, result.rows.len);
    var row_idx: usize = 0;
    errdefer {
        for (rows[0..row_idx]) |row| freeBindingRow(allocator, row);
        allocator.free(rows);
    }
    for (result.rows) |row| {
        rows[row_idx] = try cloneBindingRow(allocator, row);
        row_idx += 1;
    }

    const schema = if (result.schema.len > 0) try cloneSchema(allocator, result.schema) else &.{};
    errdefer if (schema.len > 0) freeSchema(allocator, schema);

    const order_keys = if (result.order_keys.len > 0) try cloneOrderKeys(allocator, result.order_keys) else &.{};
    errdefer if (order_keys.len > 0) {
        for (order_keys) |k| allocator.free(k);
        allocator.free(order_keys);
    };

    const order_dirs = if (result.order_dirs.len > 0) try cloneOrderDirs(allocator, result.order_dirs) else &.{};
    errdefer if (order_dirs.len > 0) allocator.free(order_dirs);

    return federation.QueryResults{
        .rows = rows,
        .schema = schema,
        .execution_time_ms = result.execution_time_ms,
        .ordered = result.ordered,
        .order_keys = order_keys,
        .order_dirs = order_dirs,
        .nulls_first = result.nulls_first,
    };
}

/// Row comparison for distributed query result sorting
// CANARY: REQ=REQ-DIST-ROW-SORT-001; FEATURE="Distributed Row Sorting"; ASPECT=Distributed; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
/// GAP-0053: Implements actual field-by-field comparison using ORDER BY semantics
pub fn simpleRowCompare(context: void, a: protocol.BindingRow, b: protocol.BindingRow) bool {
    _ = context;
    // Compare rows column by column in ascending order with NULLS FIRST
    // For distributed queries without explicit ORDER BY, we use all columns as sort keys
    const max_cols = if (a.cols.len > b.cols.len) a.cols.len else b.cols.len;
    if (max_cols == 0) return false;

    var col_indices: [32]usize = undefined;
    const num_cols = if (max_cols > 32) 32 else max_cols;
    for (0..num_cols) |i| {
        col_indices[i] = i;
    }

    const ascending = [_]bool{true} ** 32;
    const cmp = protocol.compareBindingRows(
        a,
        b,
        col_indices[0..num_cols],
        ascending[0..num_cols],
        true, // NULLS FIRST by default
    );
    return cmp == .lt;
}

// GAP-0130: Context for ORDER BY-aware sorting
// CANARY: REQ=REQ-DIST-ORDERBY-003; FEATURE="ORDER BY Sort Context"; ASPECT=QueryCorrectness; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
pub const OrderBySortContext = struct {
    order_by: []const OrderByKey,
};

/// Compare rows using ORDER BY keys
pub fn orderByCompare(context: OrderBySortContext, a: protocol.BindingRow, b: protocol.BindingRow) bool {
    // Extract column indices and ascending flags from ORDER BY keys
    var col_indices: [32]usize = undefined;
    var ascending: [32]bool = undefined;

    const num_keys = if (context.order_by.len > 32) 32 else context.order_by.len;
    for (0..num_keys) |i| {
        col_indices[i] = context.order_by[i].column_index;
        ascending[i] = context.order_by[i].ascending;
    }

    // Use NULLS FIRST from first ORDER BY key (or default true)
    const nulls_first = if (context.order_by.len > 0)
        context.order_by[0].nulls_first
    else
        true;

    const cmp = protocol.compareBindingRows(
        a,
        b,
        col_indices[0..num_keys],
        ascending[0..num_keys],
        nulls_first,
    );
    return cmp == .lt;
}

/// Hash a row for deduplication
pub fn hashRow(allocator: std.mem.Allocator, row: protocol.BindingRow) ![]u8 {
    var hasher = std.hash_map.DefaultHasher.init();
    for (row.cols) |binding| {
        // Simple binding hashing - would be more sophisticated in practice
        hasher.update(std.mem.asBytes(&binding));
    }

    const hash_value = hasher.final();
    return try std.fmt.allocPrint(allocator, "{x}", .{hash_value});
}
