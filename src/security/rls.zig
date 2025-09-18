const std = @import("std");
const Allocator = std.mem.Allocator;
const auth = @import("auth");

// Row-Level Security Engine
pub const RLSEngine = struct {
    allocator: Allocator,
    policies: std.HashMap(PolicyKey, std.ArrayList(Policy), PolicyKey.HashContext, 80),
    policy_cache: PolicyCache,
    context_evaluator: ContextEvaluator,
    query_rewriter: QueryRewriter,
    
    const Self = @This();
    
    pub const PolicyKey = struct {
        graph: []const u8,
        table: []const u8,
        
        pub const HashContext = struct {
            pub fn hash(_: @This(), key: PolicyKey) u64 {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(key.graph);
                hasher.update(key.table);
                return hasher.final();
            }
            
            pub fn eql(_: @This(), a: PolicyKey, b: PolicyKey) bool {
                return std.mem.eql(u8, a.graph, b.graph) and
                       std.mem.eql(u8, a.table, b.table);
            }
        };
    };
    
    pub const Policy = struct {
        id: u64,
        name: []const u8,
        description: []const u8,
        graph: []const u8,
        table: []const u8, // Node type or edge type
        operation: Operation,
        permissive: bool, // true = OR with other policies, false = AND
        roles: []const auth.RoleId,
        using_expr: ?Expression, // Filter expression for SELECT
        check_expr: ?Expression, // Validation expression for INSERT/UPDATE
        enabled: bool,
        created_at: i64,
        updated_at: i64,
        created_by: auth.UserId,
        
        // Advanced features
        temporal: ?TemporalConstraint,
        data_classification: ?DataClassification,
        audit_level: AuditLevel,
    };
    
    pub const Operation = enum {
        select,
        insert,
        update,
        delete,
        all,
    };
    
    pub const Expression = struct {
        raw: []const u8, // Original GQL expression
        parsed: ?*anyopaque, // Parsed AST (opaque type to avoid parser dependency)
        compiled: ?*CompiledExpression, // Optimized expression
        parameters: []const Parameter,
        
        pub const Parameter = struct {
            name: []const u8,
            type: ValueType,
            source: ParameterSource,
        };
        
        pub const ParameterSource = enum {
            current_user,
            session,
            environment,
            request,
            row,
        };
    };
    
    pub const CompiledExpression = struct {
        bytecode: []const u8,
        constants: []const Value,
        jump_table: []const usize,
    };
    
    pub const TemporalConstraint = struct {
        valid_from: ?i64,
        valid_until: ?i64,
        time_zone: []const u8,
        recurrence: ?RecurrenceRule,
    };
    
    pub const RecurrenceRule = struct {
        frequency: Frequency,
        interval: u32,
        by_day: ?[]const DayOfWeek,
        by_hour: ?[]const u8,
        
        pub const Frequency = enum {
            daily,
            weekly,
            monthly,
            yearly,
        };
        
        pub const DayOfWeek = enum {
            monday,
            tuesday,
            wednesday,
            thursday,
            friday,
            saturday,
            sunday,
        };
    };
    
    pub const DataClassification = enum {
        public,
        internal,
        confidential,
        restricted,
        top_secret,
    };
    
    pub const AuditLevel = enum {
        none,
        errors_only,
        denials,
        all_access,
        detailed,
    };
    
    pub const ValueType = enum {
        boolean,
        integer,
        float,
        string,
        timestamp,
        array,
        object,
        null,
    };
    
    pub const Value = union(ValueType) {
        boolean: bool,
        integer: i64,
        float: f64,
        string: []const u8,
        timestamp: i64,
        array: []const Value,
        object: std.StringHashMap(Value),
        null: void,
    };
    
    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .policies = std.HashMap(PolicyKey, std.ArrayList(Policy), PolicyKey.HashContext, 80).init(allocator),
            .policy_cache = try PolicyCache.init(allocator),
            .context_evaluator = try ContextEvaluator.init(allocator),
            .query_rewriter = try QueryRewriter.init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        var it = self.policies.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.policies.deinit();
        self.policy_cache.deinit();
        self.context_evaluator.deinit();
        self.query_rewriter.deinit();
    }
    
    // Policy Management
    pub fn createPolicy(self: *Self, policy: Policy) !void {
        const key = PolicyKey{
            .graph = policy.graph,
            .table = policy.table,
        };
        
        const result = try self.policies.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(Policy).initCapacity(self.allocator, 0) catch unreachable;
        }
        
        // Compile expressions if provided
        const compiled_policy = policy;
        if (policy.using_expr) |expr| {
            _ = expr;
            // TODO: Compile expression
        }
        if (policy.check_expr) |expr| {
            _ = expr;
            // TODO: Compile expression
        }
        
        try result.value_ptr.append(self.allocator, compiled_policy);
        
        // Invalidate cache
        try self.policy_cache.invalidate(key);
    }
    
    pub fn updatePolicy(self: *Self, policy_id: u64, updates: Policy) !void {
        var it = self.policies.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |*policy| {
                if (policy.id == policy_id) {
                    // Update fields
                    policy.* = updates;
                    policy.updated_at = std.time.milliTimestamp();
                    
                    // Recompile expressions if changed
                    if (updates.using_expr) |*expr| {
                        expr.compiled = try self.compileExpression(expr.raw);
                    }
                    if (updates.check_expr) |*expr| {
                        expr.compiled = try self.compileExpression(expr.raw);
                    }
                    
                    // Invalidate cache
                    try self.policy_cache.invalidate(entry.key_ptr.*);
                    return;
                }
            }
        }
        return error.PolicyNotFound;
    }
    
    pub fn deletePolicy(self: *Self, policy_id: u64) !void {
        var it = self.policies.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items, 0..) |policy, i| {
                if (policy.id == policy_id) {
                    _ = entry.value_ptr.swapRemove(i);
                    try self.policy_cache.invalidate(entry.key_ptr.*);
                    return;
                }
            }
        }
        return error.PolicyNotFound;
    }
    
    // Query Rewriting
    pub fn rewriteQuery(
        self: *Self,
        query: []const u8,
        context: *auth.SecurityContext,
        graph: []const u8,
    ) ![]const u8 {
        
        // Find applicable policies
        const policies = try self.findApplicablePolicies(
            graph,
            context.user.id,
            context.roles,
        );
        
        if (policies.items.len == 0) {
            // No policies, allow full access or deny based on configuration
            return query;
        }
        
        // Rewrite the query with security predicates
        return try self.query_rewriter.rewrite(query, policies, context);
    }
    
    pub fn checkRowAccess(
        self: *Self,
        row: *const std.StringHashMap(Value),
        operation: Operation,
        context: *auth.SecurityContext,
        graph: []const u8,
        table: []const u8,
    ) !bool {
        const key = PolicyKey{ .graph = graph, .table = table };
        
        // Check cache first
        if (self.policy_cache.get(key, context.user.id, operation)) |allowed| {
            if (!allowed) return false;
        }
        
        const policies = self.policies.get(key) orelse return true; // No policies
        
        var any_permissive_allows = false;
        var all_restrictive_allow = true;
        
        for (policies.items) |policy| {
            if (!policy.enabled) continue;
            if (policy.operation != operation and policy.operation != .all) continue;
            
            // Check role membership
            var has_role = false;
            for (policy.roles) |required_role| {
                for (context.roles) |user_role| {
                    if (user_role.id == required_role) {
                        has_role = true;
                        break;
                    }
                }
            }
            if (!has_role) continue;
            
            // Check temporal constraints
            if (policy.temporal) |temporal| {
                if (!self.checkTemporalConstraint(temporal)) continue;
            }
            
            // Evaluate policy expression
            const expr = switch (operation) {
                .select, .delete => policy.using_expr,
                .insert, .update => policy.check_expr,
                .all => policy.using_expr orelse policy.check_expr,
            };
            
            if (expr) |e| {
                const result = try self.evaluateExpression(e, row, context);
                
                if (policy.permissive) {
                    if (result) any_permissive_allows = true;
                } else {
                    if (!result) all_restrictive_allow = false;
                }
            }
        }
        
        const allowed = any_permissive_allows or all_restrictive_allow;
        
        // Cache the result
        try self.policy_cache.put(key, context.user.id, operation, allowed);
        
        return allowed;
    }
    
    fn findApplicablePolicies(
        self: *Self,
        graph: []const u8,
        _: auth.UserId,
        roles: []const auth.Role,
    ) !std.ArrayList(Policy) {
        var result = std.ArrayList(Policy).initCapacity(self.allocator, 0) catch unreachable;
        
        var it = self.policies.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.graph, graph)) continue;
            
            for (entry.value_ptr.items) |policy| {
                if (!policy.enabled) continue;
                
                // Check role membership
                var has_role = false;
                for (policy.roles) |required_role| {
                    for (roles) |user_role| {
                        if (user_role.id == required_role) {
                            has_role = true;
                            break;
                        }
                    }
                }
                
                if (has_role) {
                    try result.append(self.allocator, policy);
                }
            }
        }
        
        return result;
    }
    
    fn compileExpression(self: *Self, expr: []const u8) !*CompiledExpression {
        _ = expr;
        
        // Compile to bytecode
        var bytecode = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        var constants = std.ArrayList(Value).initCapacity(self.allocator, 0) catch unreachable;
        var jump_table = std.ArrayList(usize).initCapacity(self.allocator, 0) catch unreachable;
        
        // Simplified compilation - would implement full bytecode generation
        try bytecode.append(self.allocator, 0x00); // NOP
        
        const compiled = try self.allocator.create(CompiledExpression);
        compiled.* = CompiledExpression{
            .bytecode = try bytecode.toOwnedSlice(self.allocator),
            .constants = try constants.toOwnedSlice(self.allocator),
            .jump_table = try jump_table.toOwnedSlice(self.allocator),
        };
        
        return compiled;
    }
    
    fn compileNode(
        self: *Self,
        node: *anyopaque,
        bytecode: *std.ArrayList(u8),
        constants: *std.ArrayList(Value),
        jump_table: *std.ArrayList(usize),
    ) !void {
        _ = self;
        _ = node;
        _ = bytecode;
        _ = constants;
        _ = jump_table;
        // Simplified compilation - would implement full bytecode generation
    }
    
    fn evaluateExpression(
        self: *Self,
        expr: Expression,
        row: *const std.StringHashMap(Value),
        context: *auth.SecurityContext,
    ) !bool {
        if (expr.compiled) |compiled| {
            return try self.evaluateCompiledExpression(compiled, row, context);
        }
        
        // Fall back to interpreted evaluation
        return try self.context_evaluator.evaluate(expr.raw, row, context);
    }
    
    fn evaluateCompiledExpression(
        self: *Self,
        expr: *CompiledExpression,
        row: *const std.StringHashMap(Value),
        context: *auth.SecurityContext,
    ) !bool {
        _ = self;
        _ = expr;
        _ = row;
        _ = context;
        // Simplified VM execution - would implement full bytecode interpreter
        return true;
    }
    
    fn checkTemporalConstraint(self: *Self, constraint: TemporalConstraint) bool {
        _ = self;
        const now = std.time.milliTimestamp();
        
        if (constraint.valid_from) |from| {
            if (now < from) return false;
        }
        
        if (constraint.valid_until) |until| {
            if (now > until) return false;
        }
        
        if (constraint.recurrence) |recurrence| {
            // Check recurrence rules
            // Simplified - would implement full recurrence evaluation
            _ = recurrence;
        }
        
        return true;
    }
};

// Policy Cache for performance
pub const PolicyCache = struct {
    allocator: Allocator,
    cache: std.HashMap(CacheKey, CacheEntry, CacheKey.HashContext, 80),
    max_size: usize,
    ttl_ms: i64,
    
    const CacheKey = struct {
        policy_key: RLSEngine.PolicyKey,
        user_id: auth.UserId,
        operation: RLSEngine.Operation,
        
        pub const HashContext = struct {
            pub fn hash(_: @This(), key: CacheKey) u64 {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(key.policy_key.graph);
                hasher.update(key.policy_key.table);
                hasher.update(std.mem.asBytes(&key.user_id));
                hasher.update(std.mem.asBytes(&key.operation));
                return hasher.final();
            }
            
            pub fn eql(_: @This(), a: CacheKey, b: CacheKey) bool {
                return RLSEngine.PolicyKey.HashContext.eql(.{}, a.policy_key, b.policy_key) and
                       a.user_id == b.user_id and
                       a.operation == b.operation;
            }
        };
    };
    
    const CacheEntry = struct {
        allowed: bool,
        timestamp: i64,
    };
    
    pub fn init(allocator: Allocator) !PolicyCache {
        return PolicyCache{
            .allocator = allocator,
            .cache = std.HashMap(CacheKey, CacheEntry, CacheKey.HashContext, 80).init(allocator),
            .max_size = 10000,
            .ttl_ms = 60000, // 1 minute
        };
    }
    
    pub fn deinit(self: *PolicyCache) void {
        self.cache.deinit();
    }
    
    pub fn get(
        self: *PolicyCache,
        policy_key: RLSEngine.PolicyKey,
        user_id: auth.UserId,
        operation: RLSEngine.Operation,
    ) ?bool {
        const key = CacheKey{
            .policy_key = policy_key,
            .user_id = user_id,
            .operation = operation,
        };
        
        if (self.cache.get(key)) |entry| {
            const now = std.time.milliTimestamp();
            if (now - entry.timestamp < self.ttl_ms) {
                return entry.allowed;
            }
            // Entry expired
            _ = self.cache.remove(key);
        }
        
        return null;
    }
    
    pub fn put(
        self: *PolicyCache,
        policy_key: RLSEngine.PolicyKey,
        user_id: auth.UserId,
        operation: RLSEngine.Operation,
        allowed: bool,
    ) !void {
        // Evict old entries if cache is full
        if (self.cache.count() >= self.max_size) {
            try self.evictOldest();
        }
        
        const key = CacheKey{
            .policy_key = policy_key,
            .user_id = user_id,
            .operation = operation,
        };
        
        try self.cache.put(key, CacheEntry{
            .allowed = allowed,
            .timestamp = std.time.milliTimestamp(),
        });
    }
    
    pub fn invalidate(self: *PolicyCache, policy_key: RLSEngine.PolicyKey) !void {
        var to_remove = std.ArrayList(CacheKey).initCapacity(self.allocator, 0) catch unreachable;
        defer to_remove.deinit(self.allocator);
        
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (RLSEngine.PolicyKey.HashContext.eql(.{}, entry.key_ptr.policy_key, policy_key)) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }
        
        for (to_remove.items) |key| {
            _ = self.cache.remove(key);
        }
    }
    
    fn evictOldest(self: *PolicyCache) !void {
        var oldest_key: ?CacheKey = null;
        var oldest_time: i64 = std.math.maxInt(i64);
        
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.timestamp < oldest_time) {
                oldest_time = entry.value_ptr.timestamp;
                oldest_key = entry.key_ptr.*;
            }
        }
        
        if (oldest_key) |key| {
            _ = self.cache.remove(key);
        }
    }
};

// Context Evaluator for expression evaluation
pub const ContextEvaluator = struct {
    allocator: Allocator,
    functions: std.StringHashMap(Function),
    
    const Function = *const fn (
        allocator: Allocator,
        args: []const RLSEngine.Value,
        context: *auth.SecurityContext,
    ) anyerror!RLSEngine.Value;
    
    pub fn init(allocator: Allocator) !ContextEvaluator {
        var evaluator = ContextEvaluator{
            .allocator = allocator,
            .functions = std.StringHashMap(Function).init(allocator),
        };
        
        // Register built-in functions
        try evaluator.registerBuiltinFunctions();
        
        return evaluator;
    }
    
    pub fn deinit(self: *ContextEvaluator) void {
        self.functions.deinit();
    }
    
    pub fn evaluate(
        self: *ContextEvaluator,
        expression: []const u8,
        row: *const std.StringHashMap(RLSEngine.Value),
        context: *auth.SecurityContext,
    ) !bool {
        _ = self;
        _ = expression;
        _ = row;
        _ = context;
        // Simplified evaluation - would implement full expression evaluator
        return true;
    }
    
    fn registerBuiltinFunctions(self: *ContextEvaluator) !void {
        try self.functions.put("current_user", getCurrentUser);
        try self.functions.put("has_role", hasRole);
        try self.functions.put("has_permission", hasPermission);
        try self.functions.put("current_timestamp", getCurrentTimestamp);
        try self.functions.put("ip_in_range", ipInRange);
    }
    
    fn getCurrentUser(
        allocator: Allocator,
        args: []const RLSEngine.Value,
        context: *auth.SecurityContext,
    ) anyerror!RLSEngine.Value {
        _ = allocator;
        _ = args;
        return RLSEngine.Value{ .integer = @intCast(context.user.id) };
    }
    
    fn hasRole(
        allocator: Allocator,
        args: []const RLSEngine.Value,
        context: *auth.SecurityContext,
    ) anyerror!RLSEngine.Value {
        _ = allocator;
        if (args.len != 1) return error.InvalidArguments;
        
        const role_name = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };
        
        for (context.roles) |role| {
            if (std.mem.eql(u8, role.name, role_name)) {
                return RLSEngine.Value{ .boolean = true };
            }
        }
        
        return RLSEngine.Value{ .boolean = false };
    }
    
    fn hasPermission(
        allocator: Allocator,
        args: []const RLSEngine.Value,
        context: *auth.SecurityContext,
    ) anyerror!RLSEngine.Value {
        _ = allocator;
        _ = args;
        _ = context;
        // Simplified - would check actual permissions
        return RLSEngine.Value{ .boolean = true };
    }
    
    fn getCurrentTimestamp(
        allocator: Allocator,
        args: []const RLSEngine.Value,
        context: *auth.SecurityContext,
    ) anyerror!RLSEngine.Value {
        _ = allocator;
        _ = args;
        _ = context;
        return RLSEngine.Value{ .timestamp = std.time.milliTimestamp() };
    }
    
    fn ipInRange(
        allocator: Allocator,
        args: []const RLSEngine.Value,
        context: *auth.SecurityContext,
    ) anyerror!RLSEngine.Value {
        _ = allocator;
        if (args.len != 1) return error.InvalidArguments;
        
        const range = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };
        
        // Simplified IP range check
        return RLSEngine.Value{
            .boolean = std.mem.startsWith(u8, context.environment.ip_address, range),
        };
    }
};

// Query Rewriter for applying RLS policies
pub const QueryRewriter = struct {
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) !QueryRewriter {
        return QueryRewriter{ .allocator = allocator };
    }
    
    pub fn deinit(self: *QueryRewriter) void {
        _ = self;
    }
    
    pub fn rewrite(
        self: *QueryRewriter,
        query: []const u8,
        policies: std.ArrayList(RLSEngine.Policy),
        context: *auth.SecurityContext,
    ) ![]const u8 {
        _ = query;
        _ = context;
        
        var result = std.ArrayList(u8).init(self.allocator);
        
        // Build security predicate from policies
        try result.appendSlice("(");
        
        var first = true;
        for (policies.items) |policy| {
            if (!policy.enabled) continue;
            
            if (policy.using_expr) |expr| {
                if (!first) {
                    if (policy.permissive) {
                        try result.appendSlice(" OR ");
                    } else {
                        try result.appendSlice(" AND ");
                    }
                }
                
                try result.appendSlice("(");
                try result.appendSlice(expr.raw);
                try result.appendSlice(")");
                
                first = false;
            }
        }
        
        try result.appendSlice(")");
        
        return try result.toOwnedSlice();
    }
};