const std = @import("std");
const geode = @import("geode");

// Query plan cache for reusing compiled query plans
pub const QueryPlanCache = struct {
    allocator: std.mem.Allocator,
    cache: std.AutoHashMap(u64, CachedPlan),
    max_size: usize,
    hit_count: u64,
    miss_count: u64,

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
            plan.last_accessed = std.time.timestamp();
            return plan;
        }
        self.miss_count += 1;
        return null;
    }

    // Store compiled plan in cache
    pub fn put(self: *QueryPlanCache, query_hash: u64, query_text: []const u8, plan: CompiledPlan) !void {
        // Evict if cache is full
        if (self.cache.count() >= self.max_size) {
            try self.evictLeastUsed();
        }

        const cached_plan = CachedPlan{
            .query_text = try self.allocator.dupe(u8, query_text),
            .plan = plan,
            .created_at = std.time.timestamp(),
            .last_accessed = std.time.timestamp(),
            .access_count = 1,
        };

        try self.cache.put(query_hash, cached_plan);
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
    }

    // Evict least recently used plan
    fn evictLeastUsed(self: *QueryPlanCache) !void {
        var oldest_time: i64 = std.math.maxInt(i64);
        var oldest_hash: u64 = 0;
        var found = false;

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.last_accessed < oldest_time) {
                oldest_time = entry.value_ptr.last_accessed;
                oldest_hash = entry.key_ptr.*;
                found = true;
            }
        }

        if (found) {
            if (self.cache.fetchRemove(oldest_hash)) |kv| {
                self.allocator.free(kv.value.query_text);
                self.allocator.free(kv.value.plan.operators);
            }
        }
    }
};

pub const CachedPlan = struct {
    query_text: []const u8,
    plan: CompiledPlan,
    created_at: i64,
    last_accessed: i64,
    access_count: u64,
};

pub const CompiledPlan = struct {
    operators: []PhysicalOperator,
    estimated_cost: f64,
    memory_requirement: usize,
    parallelism_level: u8,
};

pub const PhysicalOperator = struct {
    op_type: OperatorType,
    cost_estimate: f64,
    cardinality_estimate: usize,
    memory_usage: usize,

    pub const OperatorType = enum {
        scan,
        index_scan,
        filter,
        project,
        sort,
        hash_join,
        nested_loop_join,
        aggregation,
        union_op,
        intersect,
        except,
    };
};

pub const CacheStats = struct {
    hits: u64,
    misses: u64,
    hit_rate: f64,
    cache_size: usize,
    max_size: usize,
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
    pub fn optimizeQuery(self: *QueryOptimizer, query_text: []const u8, ast: *const geode.ast.Query) !CompiledPlan {
        const query_hash = self.hashQuery(query_text);

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

    // Hash query for cache key
    fn hashQuery(self: *QueryOptimizer, query_text: []const u8) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(query_text);
        return hasher.final();
    }

    // Generate optimized physical plan
    fn generateOptimizedPlan(self: *QueryOptimizer, ast: *const geode.ast.Query) !CompiledPlan {
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

    fn optimizeMatchClause(self: *QueryOptimizer, ast: *const geode.ast.Query, operators: *std.ArrayList(PhysicalOperator)) !void {
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

    fn optimizeFilterConditions(self: *QueryOptimizer, ast: *const geode.ast.Query, operators: *std.ArrayList(PhysicalOperator)) !void {
        _ = ast;
        // Push filters down and reorder by selectivity
        try operators.append(self.allocator, PhysicalOperator{
            .op_type = .filter,
            .cost_estimate = 20.0,
            .cardinality_estimate = 5000,
            .memory_usage = 512 * 1024,
        });
    }

    fn optimizeProjection(self: *QueryOptimizer, ast: *const geode.ast.Query, operators: *std.ArrayList(PhysicalOperator)) !void {
        _ = ast;
        try operators.append(self.allocator, PhysicalOperator{
            .op_type = .project,
            .cost_estimate = 10.0,
            .cardinality_estimate = 5000,
            .memory_usage = 256 * 1024,
        });
    }

    fn optimizeOrdering(self: *QueryOptimizer, ast: *const geode.ast.Query, operators: *std.ArrayList(PhysicalOperator)) !void {
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
