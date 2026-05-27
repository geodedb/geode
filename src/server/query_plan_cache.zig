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
const gql_ast = @import("../gql/ast.zig");

// CANARY: REQ=REQ-PERF-LRU-O1-002; FEATURE="O1LRUEviction"; ASPECT=PlanCacheEviction; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
// Query plan cache for reusing compiled query plans.
// Uses an intrusive doubly-linked list keyed by hash for O(1) LRU eviction (Issue #456).
pub const QueryPlanCache = struct {
    allocator: std.mem.Allocator,
    cache: std.AutoHashMap(u64, CachedPlan),
    max_size: usize,
    hit_count: u64,
    miss_count: u64,
    lru_head: ?u64 = null,
    lru_tail: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) QueryPlanCache {
        return .{
            .allocator = allocator,
            .cache = std.AutoHashMap(u64, CachedPlan).init(allocator),
            .max_size = max_size,
            .hit_count = 0,
            .miss_count = 0,
        };
    }

    pub fn deinit(self: *QueryPlanCache) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.query_text);
            self.allocator.free(entry.value_ptr.plan.operators);
        }
        self.cache.deinit();
    }

    // Get cached plan or return null if not found
    pub fn get(self: *QueryPlanCache, query_hash: u64) ?*const CachedPlan {
        if (self.cache.getPtr(query_hash)) |plan| {
            self.hit_count += 1;
            plan.access_count += 1;
            plan.last_accessed = compat_timestamp();
            self.lruPromote(query_hash);
            return plan;
        }
        self.miss_count += 1;
        return null;
    }

    // Store compiled plan in cache
    pub fn put(self: *QueryPlanCache, query_hash: u64, query_text: []const u8, plan: CompiledPlan) !void {
        // Evict if cache is full
        if (self.cache.count() >= self.max_size) {
            self.evictTail();
        }

        const cached_plan = CachedPlan{
            .query_text = try self.allocator.dupe(u8, query_text),
            .plan = plan,
            .created_at = compat_timestamp(),
            .last_accessed = compat_timestamp(),
            .access_count = 1,
        };

        try self.cache.put(query_hash, cached_plan);
        self.lruInsertHead(query_hash);
    }

    // Get cache statistics
    pub fn getStats(self: *QueryPlanCache) CacheStats {
        const total_requests = self.hit_count + self.miss_count;
        const hit_rate = if (total_requests > 0)
            @as(f64, @floatFromInt(self.hit_count)) / @as(f64, @floatFromInt(total_requests)) * 100.0
        else
            0.0;

        return .{
            .hits = self.hit_count,
            .misses = self.miss_count,
            .hit_rate = hit_rate,
            .cache_size = self.cache.count(),
            .max_size = self.max_size,
        };
    }

    // Clear all cached plans
    pub fn clear(self: *QueryPlanCache) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.query_text);
            self.allocator.free(entry.value_ptr.plan.operators);
        }
        self.cache.clearAndFree();
        self.hit_count = 0;
        self.miss_count = 0;
        self.lru_head = null;
        self.lru_tail = null;
    }

    /// O(1) eviction: remove the LRU tail entry.
    fn evictTail(self: *QueryPlanCache) void {
        const tail_key = self.lru_tail orelse return;
        self.lruRemoveNode(tail_key);
        if (self.cache.fetchRemove(tail_key)) |kv| {
            self.allocator.free(kv.value.query_text);
            self.allocator.free(kv.value.plan.operators);
        }
    }

    // --- LRU linked-list helpers ---

    fn lruPromote(self: *QueryPlanCache, key: u64) void {
        if (self.lru_head != null and self.lru_head.? == key) return;
        self.lruRemoveNode(key);
        self.lruInsertHead(key);
    }

    fn lruInsertHead(self: *QueryPlanCache, key: u64) void {
        const entry = self.cache.getPtr(key) orelse return;
        entry.lru_prev = null;
        entry.lru_next = self.lru_head;
        if (self.lru_head) |old_head| {
            if (self.cache.getPtr(old_head)) |h| h.lru_prev = key;
        }
        self.lru_head = key;
        if (self.lru_tail == null) self.lru_tail = key;
    }

    fn lruRemoveNode(self: *QueryPlanCache, key: u64) void {
        const entry = self.cache.getPtr(key) orelse return;
        const prev = entry.lru_prev;
        const next = entry.lru_next;
        if (prev) |pk| {
            if (self.cache.getPtr(pk)) |p| p.lru_next = next;
        } else {
            self.lru_head = next;
        }
        if (next) |nk| {
            if (self.cache.getPtr(nk)) |n| n.lru_prev = prev;
        } else {
            self.lru_tail = prev;
        }
        entry.lru_prev = null;
        entry.lru_next = null;
    }
};

pub const CachedPlan = struct {
    query_text: []const u8,
    plan: CompiledPlan,
    created_at: i64,
    last_accessed: i64,
    access_count: u64,
    lru_prev: ?u64 = null,
    lru_next: ?u64 = null,
};

// CANARY: REQ=REQ-PERF-PLAN-LIFECYCLE-001; FEATURE="PlanCacheLifecycle"; ASPECT=CompiledPlan; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
pub const CompiledPlan = struct {
    operators: []PhysicalOperator,
    estimated_cost: f64,
    memory_requirement: usize,
    parallelism_level: u8,
    // Issue #452: Execution hints extracted from plan for advisory use
    use_index: ?[]const u8 = null,
    scan_strategy: ScanStrategy = .full_scan,
    estimated_rows: u64 = 0,
    invalidation_epoch: u64 = 0,

    pub const ScanStrategy = enum { full_scan, index_scan, label_scan };
};

// CANARY: REQ=REQ-PERF-PLAN-LIFECYCLE-002; FEATURE="PlanCacheLifecycle"; ASPECT=PhysicalOperator; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
pub const PhysicalOperator = struct {
    op_type: OperatorType,
    cost_estimate: f64,
    cardinality_estimate: usize,
    memory_usage: usize,
    target_label: ?[]const u8 = null,
    filter_selectivity: f64 = 1.0,
    index_name: ?[]const u8 = null,

    pub const OperatorType = enum {
        scan,
        index_scan,
        label_scan,
        filter,
        project,
        sort,
        hash_join,
        nested_loop_join,
        aggregation,
        union_op,
        intersect,
        except,
        path_expand,
        limit,
    };
};

pub const CacheStats = struct {
    hits: u64,
    misses: u64,
    hit_rate: f64,
    cache_size: usize,
    max_size: usize,
};

// CANARY: REQ=REQ-PERF-PLAN-LIFECYCLE-003; FEATURE="PlanCacheLifecycle"; ASPECT=StoreStats; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
/// Graph store statistics for cost-based optimization decisions
pub const StoreStats = struct {
    node_count: u64 = 0,
    edge_count: u64 = 0,
    label_node_counts: ?*const std.StringHashMap(u64) = null,
};

// CANARY: REQ=REQ-PERF-PLAN-LIFECYCLE-004; FEATURE="PlanCacheLifecycle"; ASPECT=OptimizerHints; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
/// Optimizer hints passed through ExecutionContext for advisory index selection
pub const OptimizerHints = struct {
    use_index: ?[]const u8 = null,
    scan_strategy: CompiledPlan.ScanStrategy = .full_scan,
    estimated_rows: u64 = 0,
    schema_epoch: u64 = 0,
};

// Query optimization system with plan caching
pub const QueryOptimizer = struct {
    allocator: std.mem.Allocator,
    plan_cache: QueryPlanCache,
    cost_model: CostModel,

    pub fn init(allocator: std.mem.Allocator, cache_size: usize) QueryOptimizer {
        return .{
            .allocator = allocator,
            .plan_cache = QueryPlanCache.init(allocator, cache_size),
            .cost_model = CostModel.init(),
        };
    }

    pub fn deinit(self: *QueryOptimizer) void {
        self.plan_cache.deinit();
    }

    // Optimize query with caching
    pub fn optimizeQuery(self: *QueryOptimizer, query_text: []const u8, ast: *const gql_ast.Query) !CompiledPlan {
        const query_hash = hashQueryText(query_text);

        // Check cache first
        if (self.plan_cache.get(query_hash)) |cached| {
            return cached.plan; // Return cached plan
        }

        // Generate new optimized plan
        const plan = try self.generateOptimizedPlan(ast);

        // Cache the plan
        try self.plan_cache.put(query_hash, query_text, plan);

        return plan;
    }

    // Generate optimized physical plan
    fn generateOptimizedPlan(self: *QueryOptimizer, ast: *const gql_ast.Query) !CompiledPlan {
        var operators = std.ArrayList(PhysicalOperator).initCapacity(self.allocator, 8) catch return error.OutOfMemory;

        // Rule-based optimization with cost estimation
        try self.optimizeMatchClause(ast, &operators);
        try self.optimizeFilterConditions(ast, &operators);
        try self.optimizeProjection(ast, &operators);
        try self.optimizeOrdering(ast, &operators);

        const total_cost = self.cost_model.calculateTotalCost(operators.items);
        const memory_req = self.cost_model.estimateMemoryRequirement(operators.items);

        return CompiledPlan{
            .operators = try operators.toOwnedSlice(self.allocator),
            .estimated_cost = total_cost,
            .memory_requirement = memory_req,
            .parallelism_level = self.determineParallelismLevel(operators.items),
        };
    }

    fn optimizeMatchClause(self: *QueryOptimizer, ast: *const gql_ast.Query, operators: *std.ArrayList(PhysicalOperator)) !void {
        _ = ast;
        // Choose between full scan vs index scan based on selectivity
        const selectivity = self.cost_model.estimateSelectivity();

        if (selectivity < 0.1) {
            // High selectivity - use index scan
            try operators.append(self.allocator, PhysicalOperator{
                .op_type = .index_scan,
                .cost_estimate = 50.0,
                .cardinality_estimate = 1000,
                .memory_usage = 1024 * 1024,
            });
        } else {
            // Low selectivity - use full scan
            try operators.append(self.allocator, PhysicalOperator{
                .op_type = .scan,
                .cost_estimate = 100.0,
                .cardinality_estimate = 10000,
                .memory_usage = 2 * 1024 * 1024,
            });
        }
    }

    fn optimizeFilterConditions(self: *QueryOptimizer, ast: *const gql_ast.Query, operators: *std.ArrayList(PhysicalOperator)) !void {
        _ = ast;
        // Push filters down and reorder by selectivity
        try operators.append(self.allocator, PhysicalOperator{
            .op_type = .filter,
            .cost_estimate = 20.0,
            .cardinality_estimate = 5000,
            .memory_usage = 512 * 1024,
        });
    }

    fn optimizeProjection(self: *QueryOptimizer, ast: *const gql_ast.Query, operators: *std.ArrayList(PhysicalOperator)) !void {
        _ = ast;
        try operators.append(self.allocator, PhysicalOperator{
            .op_type = .project,
            .cost_estimate = 10.0,
            .cardinality_estimate = 5000,
            .memory_usage = 256 * 1024,
        });
    }

    fn optimizeOrdering(self: *QueryOptimizer, ast: *const gql_ast.Query, operators: *std.ArrayList(PhysicalOperator)) !void {
        _ = ast;
        // Add sort operator if needed
        try operators.append(self.allocator, PhysicalOperator{
            .op_type = .sort,
            .cost_estimate = 80.0,
            .cardinality_estimate = 5000,
            .memory_usage = 1024 * 1024,
        });
    }

    fn determineParallelismLevel(self: *QueryOptimizer, operators: []const PhysicalOperator) u8 {
        _ = self;
        var max_parallelism: u8 = 1;

        for (operators) |op| {
            switch (op.op_type) {
                .scan, .index_scan => max_parallelism = @max(max_parallelism, 4),
                .sort, .aggregation => max_parallelism = @max(max_parallelism, 2),
                else => {},
            }
        }

        return max_parallelism;
    }
};

// Cost model for query optimization
pub const CostModel = struct {
    cpu_cost_factor: f64,
    io_cost_factor: f64,
    memory_cost_factor: f64,

    pub fn init() CostModel {
        return .{
            .cpu_cost_factor = 1.0,
            .io_cost_factor = 4.0,
            .memory_cost_factor = 0.1,
        };
    }

    pub fn calculateTotalCost(self: *CostModel, operators: []const PhysicalOperator) f64 {
        var total_cost: f64 = 0.0;

        for (operators) |op| {
            total_cost += op.cost_estimate * self.cpu_cost_factor;
            total_cost += @as(f64, @floatFromInt(op.memory_usage)) * self.memory_cost_factor / 1024.0;
        }

        return total_cost;
    }

    pub fn estimateMemoryRequirement(self: *CostModel, operators: []const PhysicalOperator) usize {
        _ = self;
        var max_memory: usize = 0;
        var current_memory: usize = 0;

        for (operators) |op| {
            current_memory += op.memory_usage;
            max_memory = @max(max_memory, current_memory);

            // Some operators free memory after completion
            switch (op.op_type) {
                .project, .filter => current_memory = op.memory_usage / 2,
                else => {},
            }
        }

        return max_memory;
    }

    pub fn estimateSelectivity(self: *CostModel) f64 {
        _ = self;
        // Simplified selectivity estimation
        return 0.05; // 5% selectivity
    }
};

// ---- Issue #460: Shared Cross-Connection Query Optimizer ----
// CANARY: REQ=REQ-PERF-SHARED-OPT-001; FEATURE="SharedQueryOptimizer"; ASPECT=CrossConnectionReuse; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17

/// Thread-safe, shared query optimizer for cross-connection plan reuse.
/// Follows the SharedAstCache pattern: mutex + ref-counting + O(1) LRU.
/// Schema epoch invalidation ensures stale plans are evicted after DDL changes.
pub const SharedQueryOptimizer = struct {
    allocator: std.mem.Allocator,
    plan_cache: std.AutoHashMap(u64, SharedCachedPlan),
    max_size: usize,
    hit_count: u64 = 0,
    miss_count: u64 = 0,
    lock: std.Io.Mutex = std.Io.Mutex.init,
    schema_epoch: u64 = 0,
    lru_head: ?u64 = null,
    lru_tail: ?u64 = null,
    cost_model: CostModel,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) SharedQueryOptimizer {
        return .{
            .allocator = allocator,
            .plan_cache = std.AutoHashMap(u64, SharedCachedPlan).init(allocator),
            .max_size = max_size,
            .cost_model = CostModel.init(),
        };
    }

    pub fn deinit(self: *SharedQueryOptimizer) void {
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        var iter = self.plan_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.query_text);
            self.allocator.free(entry.value_ptr.plan.operators);
        }
        self.plan_cache.deinit();
    }

    /// Optimize a query, returning a ref-counted handle to the cached plan.
    /// Caller MUST call handle.release() when done with the plan.
    pub fn optimizeQuery(
        self: *SharedQueryOptimizer,
        query_text: []const u8,
        program: *const gql_ast.Program,
        stats: StoreStats,
    ) !SharedPlanHandle {
        const key = hashQueryText(query_text);
        const current_epoch = self.schema_epoch;

        // CANARY: REQ=REQ-QUIC-HC-105; FEATURE="High-Concurrency Query Cache"; ASPECT=PlanMissSingleFlight; STATUS=TESTED; TEST=shared_query_optimizer_plan_singleflight; OWNER=engine; UPDATED=2026-05-27
        // Keep plan generation inside the shared optimizer mutex for cache
        // misses. This deliberately trades different-query miss parallelism for
        // same-query single-flight behavior, which is the high-concurrency QUIC
        // hot path: hundreds of connections frequently release the same query
        // at once after authentication.
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.plan_cache.getPtr(key)) |cached| {
            if (std.mem.eql(u8, cached.query_text, query_text) and
                cached.schema_epoch >= current_epoch)
            {
                self.hit_count += 1;
                cached.access_count += 1;
                cached.last_accessed = compat_timestamp();
                cached.ref_count += 1;
                self.lruPromoteUnlocked(key);
                const handle = SharedPlanHandle{
                    .cache = self,
                    .key = key,
                    .plan = &cached.plan,
                };
                return handle;
            }

            // Stale entry (schema epoch mismatch) or hash collision — evict if unreferenced
            if (cached.ref_count == 0) {
                self.lruRemoveNodeUnlocked(key);
                if (self.plan_cache.fetchRemove(key)) |kv| {
                    self.allocator.free(kv.value.query_text);
                    self.allocator.free(kv.value.plan.operators);
                }
            }
        }
        self.miss_count += 1;

        const plan = try generateRealPlan(self.allocator, &self.cost_model, program, stats, current_epoch);

        if (self.plan_cache.count() >= self.max_size) {
            self.evictLeastUsedUnlocked();
        }

        const cached_plan = SharedCachedPlan{
            .query_text = try self.allocator.dupe(u8, query_text),
            .plan = plan,
            .created_at = compat_timestamp(),
            .last_accessed = compat_timestamp(),
            .access_count = 1,
            .ref_count = 1,
            .schema_epoch = current_epoch,
        };
        errdefer {
            self.allocator.free(cached_plan.query_text);
            self.allocator.free(cached_plan.plan.operators);
        }

        try self.plan_cache.put(key, cached_plan);
        self.lruInsertHeadUnlocked(key);
        const cached_ptr = self.plan_cache.getPtr(key) orelse return error.OutOfMemory;
        return SharedPlanHandle{
            .cache = self,
            .key = key,
            .plan = &cached_ptr.plan,
        };
    }

    /// Decrement ref_count for a cached entry (called by SharedPlanHandle.release)
    pub fn release(self: *SharedQueryOptimizer, key: u64) void {
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        if (self.plan_cache.getPtr(key)) |entry| {
            if (entry.ref_count > 0) entry.ref_count -= 1;
        }
    }

    /// Invalidate all cached plans (e.g., after CREATE/DROP INDEX)
    pub fn invalidateAll(self: *SharedQueryOptimizer) void {
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        self.schema_epoch += 1;
        // Entries will be lazily evicted on next miss (epoch check fails)
    }

    /// Increment schema epoch without clearing cache (lazy invalidation)
    pub fn bumpSchemaEpoch(self: *SharedQueryOptimizer) void {
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        self.schema_epoch += 1;
    }

    /// Get cache statistics
    pub fn getStats(self: *SharedQueryOptimizer) CacheStats {
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        const total_requests = self.hit_count + self.miss_count;
        const hit_rate = if (total_requests > 0)
            @as(f64, @floatFromInt(self.hit_count)) / @as(f64, @floatFromInt(total_requests)) * 100.0
        else
            0.0;
        return .{
            .hits = self.hit_count,
            .misses = self.miss_count,
            .hit_rate = hit_rate,
            .cache_size = self.plan_cache.count(),
            .max_size = self.max_size,
        };
    }

    // --- Eviction (caller holds lock) ---

    fn evictLeastUsedUnlocked(self: *SharedQueryOptimizer) void {
        var key_opt = self.lru_tail;
        while (key_opt) |key| {
            const entry = self.plan_cache.getPtr(key) orelse return;
            if (entry.ref_count == 0) {
                self.lruRemoveNodeUnlocked(key);
                if (self.plan_cache.fetchRemove(key)) |kv| {
                    self.allocator.free(kv.value.query_text);
                    self.allocator.free(kv.value.plan.operators);
                }
                return;
            }
            key_opt = entry.lru_prev;
        }
    }

    // --- LRU linked-list helpers (caller holds lock) ---

    fn lruPromoteUnlocked(self: *SharedQueryOptimizer, key: u64) void {
        if (self.lru_head != null and self.lru_head.? == key) return;
        self.lruRemoveNodeUnlocked(key);
        self.lruInsertHeadUnlocked(key);
    }

    fn lruInsertHeadUnlocked(self: *SharedQueryOptimizer, key: u64) void {
        const entry = self.plan_cache.getPtr(key) orelse return;
        entry.lru_prev = null;
        entry.lru_next = self.lru_head;
        if (self.lru_head) |old_head| {
            if (self.plan_cache.getPtr(old_head)) |h| h.lru_prev = key;
        }
        self.lru_head = key;
        if (self.lru_tail == null) self.lru_tail = key;
    }

    fn lruRemoveNodeUnlocked(self: *SharedQueryOptimizer, key: u64) void {
        const entry = self.plan_cache.getPtr(key) orelse return;
        const prev = entry.lru_prev;
        const next = entry.lru_next;
        if (prev) |pk| {
            if (self.plan_cache.getPtr(pk)) |p| p.lru_next = next;
        } else {
            self.lru_head = next;
        }
        if (next) |nk| {
            if (self.plan_cache.getPtr(nk)) |n| n.lru_prev = prev;
        } else {
            self.lru_tail = prev;
        }
        entry.lru_prev = null;
        entry.lru_next = null;
    }
};

/// Ref-counted handle to a cached plan. Caller must call release() when done.
pub const SharedPlanHandle = struct {
    cache: ?*SharedQueryOptimizer,
    key: u64,
    plan: *const CompiledPlan,

    pub fn release(self: *SharedPlanHandle) void {
        if (self.cache) |cache| {
            cache.release(self.key);
        }
    }

    /// Extract OptimizerHints from this plan for advisory use by the execution engine
    pub fn toHints(self: *const SharedPlanHandle) OptimizerHints {
        return .{
            .use_index = self.plan.use_index,
            .scan_strategy = self.plan.scan_strategy,
            .estimated_rows = self.plan.estimated_rows,
            .schema_epoch = self.plan.invalidation_epoch,
        };
    }
};

pub const SharedCachedPlan = struct {
    query_text: []const u8,
    plan: CompiledPlan,
    created_at: i64,
    last_accessed: i64,
    access_count: u64,
    ref_count: u32,
    schema_epoch: u64,
    lru_prev: ?u64 = null,
    lru_next: ?u64 = null,
};

// ---- Issue #452: Real Plan Generation ----
// CANARY: REQ=REQ-PERF-PLAN-LIFECYCLE-005; FEATURE="PlanCacheLifecycle"; ASPECT=RealPlanGeneration; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17

/// Generate a real optimized plan by walking the AST and consulting store statistics.
/// Produces meaningful operators, cost estimates, and scan strategy hints.
pub fn generateRealPlan(
    allocator: std.mem.Allocator,
    cost_model: *CostModel,
    program: *const gql_ast.Program,
    stats: StoreStats,
    schema_epoch: u64,
) !CompiledPlan {
    var operators = std.ArrayList(PhysicalOperator).initCapacity(allocator, 8) catch return error.OutOfMemory;

    var scan_strategy: CompiledPlan.ScanStrategy = .full_scan;
    var first_label: ?[]const u8 = null;
    var estimated_rows: u64 = stats.node_count;
    var has_where = false;
    var has_order_by = false;
    var has_limit = false;
    var has_aggregation = false;
    var has_path_expand = false;

    // Walk program statements to extract query structure
    for (program.statements) |stmt| {
        switch (stmt) {
            .Query => |q| {
                // Analyze MATCH patterns
                for (q.match.chains) |chain| {
                    if (chain.head) |head| {
                        if (head.labels.len > 0) {
                            first_label = head.labels[0];
                            // Label available: use label_scan by default
                            scan_strategy = .label_scan;

                            // Estimate rows from label cardinality if available
                            if (stats.label_node_counts) |lc| {
                                if (lc.get(head.labels[0])) |count| {
                                    estimated_rows = count;
                                }
                            }
                        }

                        // Inline property filter → strong selectivity signal
                        if (head.props) |props| {
                            if (props.len > 0) {
                                scan_strategy = .index_scan;
                                // Each property filter cuts cardinality significantly
                                estimated_rows = estimated_rows / 10;
                                if (estimated_rows == 0) estimated_rows = 1;
                            }
                        }
                    }

                    // Hops indicate relationship traversal (path expansion)
                    if (chain.hops.len > 0) {
                        has_path_expand = true;
                    }
                }

                // WHERE clause → filter operator
                if (q.where_clause != null) {
                    has_where = true;
                }
                if (q.filter_clause != null) {
                    has_where = true;
                }

                // ORDER BY
                if (q.order_by != null) {
                    has_order_by = true;
                }

                // LIMIT
                if (q.limit != null) {
                    has_limit = true;
                }

                // Check for aggregation in RETURN items
                for (q.ret.items) |item| {
                    if (isAggregationExpr(item.expr)) {
                        has_aggregation = true;
                        break;
                    }
                }
            },
            .Union => {
                try operators.append(allocator, PhysicalOperator{
                    .op_type = .union_op,
                    .cost_estimate = 50.0,
                    .cardinality_estimate = @intCast(estimated_rows),
                    .memory_usage = 512 * 1024,
                });
            },
            .Intersect => {
                try operators.append(allocator, PhysicalOperator{
                    .op_type = .intersect,
                    .cost_estimate = 60.0,
                    .cardinality_estimate = @intCast(estimated_rows / 2),
                    .memory_usage = 512 * 1024,
                });
            },
            .Except => {
                try operators.append(allocator, PhysicalOperator{
                    .op_type = .except,
                    .cost_estimate = 60.0,
                    .cardinality_estimate = @intCast(estimated_rows / 2),
                    .memory_usage = 512 * 1024,
                });
            },
            else => {},
        }
    }

    // Build operator pipeline based on analysis

    // 1. Scan operator
    const scan_cost: f64 = switch (scan_strategy) {
        .full_scan => blk: {
            const rows_f: f64 = @floatFromInt(stats.node_count);
            break :blk rows_f * cost_model.io_cost_factor;
        },
        .label_scan => blk: {
            const rows_f: f64 = @floatFromInt(estimated_rows);
            break :blk rows_f * cost_model.io_cost_factor * 0.5;
        },
        .index_scan => blk: {
            // Logarithmic cost for index scan
            const rows_f: f64 = @floatFromInt(estimated_rows);
            break :blk @log2(rows_f + 1.0) * cost_model.io_cost_factor * 10.0;
        },
    };

    const scan_op_type: PhysicalOperator.OperatorType = switch (scan_strategy) {
        .full_scan => .scan,
        .label_scan => .label_scan,
        .index_scan => .index_scan,
    };

    try operators.append(allocator, PhysicalOperator{
        .op_type = scan_op_type,
        .cost_estimate = scan_cost,
        .cardinality_estimate = @intCast(estimated_rows),
        .memory_usage = @intCast(@min(estimated_rows * 64, 4 * 1024 * 1024)),
        .target_label = first_label,
        .filter_selectivity = if (scan_strategy == .index_scan) 0.01 else 1.0,
    });

    // 2. Path expansion operator
    if (has_path_expand) {
        const expand_rows = estimated_rows * stats.edge_count / @max(stats.node_count, 1);
        try operators.append(allocator, PhysicalOperator{
            .op_type = .path_expand,
            .cost_estimate = @as(f64, @floatFromInt(expand_rows)) * cost_model.cpu_cost_factor,
            .cardinality_estimate = @intCast(expand_rows),
            .memory_usage = @intCast(@min(expand_rows * 128, 8 * 1024 * 1024)),
        });
        estimated_rows = expand_rows;
    }

    // 3. Filter operator
    if (has_where) {
        const filter_selectivity: f64 = 0.3; // Default WHERE selectivity estimate
        const post_filter_rows = @as(u64, @intFromFloat(@as(f64, @floatFromInt(estimated_rows)) * filter_selectivity));
        const effective_rows = if (post_filter_rows == 0) @as(u64, 1) else post_filter_rows;
        try operators.append(allocator, PhysicalOperator{
            .op_type = .filter,
            .cost_estimate = @as(f64, @floatFromInt(estimated_rows)) * cost_model.cpu_cost_factor * 0.5,
            .cardinality_estimate = @intCast(effective_rows),
            .memory_usage = 256 * 1024,
            .filter_selectivity = filter_selectivity,
        });
        estimated_rows = effective_rows;
    }

    // 4. Aggregation operator
    if (has_aggregation) {
        try operators.append(allocator, PhysicalOperator{
            .op_type = .aggregation,
            .cost_estimate = @as(f64, @floatFromInt(estimated_rows)) * cost_model.cpu_cost_factor * 2.0,
            .cardinality_estimate = @intCast(@max(estimated_rows / 10, 1)),
            .memory_usage = @intCast(@min(estimated_rows * 128, 4 * 1024 * 1024)),
        });
        estimated_rows = @max(estimated_rows / 10, 1);
    }

    // 5. Sort operator
    if (has_order_by) {
        const sort_cost = if (estimated_rows > 1)
            @as(f64, @floatFromInt(estimated_rows)) * @log2(@as(f64, @floatFromInt(estimated_rows))) * cost_model.cpu_cost_factor
        else
            1.0;
        try operators.append(allocator, PhysicalOperator{
            .op_type = .sort,
            .cost_estimate = sort_cost,
            .cardinality_estimate = @intCast(estimated_rows),
            .memory_usage = @intCast(@min(estimated_rows * 64, 4 * 1024 * 1024)),
        });
    }

    // 6. Project operator (always present — RETURN clause)
    try operators.append(allocator, PhysicalOperator{
        .op_type = .project,
        .cost_estimate = @as(f64, @floatFromInt(estimated_rows)) * cost_model.cpu_cost_factor * 0.1,
        .cardinality_estimate = @intCast(estimated_rows),
        .memory_usage = @intCast(@min(estimated_rows * 32, 2 * 1024 * 1024)),
    });

    // 7. Limit operator
    if (has_limit) {
        try operators.append(allocator, PhysicalOperator{
            .op_type = .limit,
            .cost_estimate = 1.0,
            .cardinality_estimate = @intCast(estimated_rows),
            .memory_usage = 1024,
        });
    }

    const total_cost = cost_model.calculateTotalCost(operators.items);
    const memory_req = cost_model.estimateMemoryRequirement(operators.items);

    return CompiledPlan{
        .operators = try operators.toOwnedSlice(allocator),
        .estimated_cost = total_cost,
        .memory_requirement = memory_req,
        .parallelism_level = determineParallelism(operators.items),
        .scan_strategy = scan_strategy,
        .estimated_rows = estimated_rows,
        .invalidation_epoch = schema_epoch,
    };
}

/// Check if an AST expression is an aggregation function call
fn isAggregationExpr(expr: gql_ast.Expr) bool {
    switch (expr) {
        .Call => |call| {
            // Callee is typically an Ident for aggregation functions
            if (call.callee.* == .Ident) {
                const name = call.callee.Ident.orig;
                if (std.ascii.eqlIgnoreCase(name, "count") or
                    std.ascii.eqlIgnoreCase(name, "sum") or
                    std.ascii.eqlIgnoreCase(name, "avg") or
                    std.ascii.eqlIgnoreCase(name, "min") or
                    std.ascii.eqlIgnoreCase(name, "max") or
                    std.ascii.eqlIgnoreCase(name, "collect") or
                    std.ascii.eqlIgnoreCase(name, "stdev") or
                    std.ascii.eqlIgnoreCase(name, "stdevp"))
                {
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn determineParallelism(operators: []const PhysicalOperator) u8 {
    var max_parallelism: u8 = 1;
    for (operators) |op| {
        switch (op.op_type) {
            .scan, .index_scan, .label_scan => max_parallelism = @max(max_parallelism, 4),
            .sort, .aggregation => max_parallelism = @max(max_parallelism, 2),
            else => {},
        }
    }
    return max_parallelism;
}

/// Hash query text for cache key (shared between per-connection and shared optimizer)
pub fn hashQueryText(query_text: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(query_text);
    return hasher.final();
}
