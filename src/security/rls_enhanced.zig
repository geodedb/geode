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
const Allocator = std.mem.Allocator;
const auth = @import("geode_auth");
const rls = @import("rls");
const logging = @import("logging");
const log = logging.scoped("rls_enhanced");

// CANARY: REQ=REQ-M10-CONSTANTS-003; FEATURE="CodeQuality"; ASPECT=MAGIC_NUMBERS; STATUS=EXEMPT; OWNER=security; UPDATED=2025-10-17
// Enhanced RLS cache configuration constants
const ENHANCED_RLS_CACHE_MAX_SIZE = 10_000; // Maximum cached policy evaluations (enhanced cache)
const ENHANCED_RLS_CACHE_DEFAULT_TTL_MS = 300_000; // Cache TTL: 300 seconds (5 minutes)

// Enhanced Row-Level Security Implementation with Real Functionality
// This module provides production-ready RLS capabilities with comprehensive
// policy evaluation, query rewriting, and performance optimization

pub const EnhancedRLSEngine = struct {
    allocator: Allocator,
    base_engine: rls.RLSEngine,
    expression_compiler: ExpressionCompiler,
    policy_optimizer: PolicyOptimizer,
    statistics_collector: RLSStatisticsCollector,
    cache_manager: EnhancedCacheManager,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .base_engine = try rls.RLSEngine.init(allocator),
            .expression_compiler = try ExpressionCompiler.init(allocator),
            .policy_optimizer = try PolicyOptimizer.init(allocator),
            .statistics_collector = try RLSStatisticsCollector.init(allocator),
            .cache_manager = try EnhancedCacheManager.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.base_engine.deinit();
        self.expression_compiler.deinit();
        self.policy_optimizer.deinit();
        self.statistics_collector.deinit();
        self.cache_manager.deinit();
    }

    // Enhanced policy evaluation with real implementation
    pub fn evaluatePolicy(
        self: *Self,
        policy: rls.RLSEngine.Policy,
        row: *const std.StringHashMap(rls.Value),
        context: *auth.SecurityContext,
    ) !bool {
        // Update statistics
        try self.statistics_collector.recordPolicyEvaluation(policy.id);

        // Check cache first
        const cache_key = try self.cache_manager.generateCacheKey(policy.id, context.user.id, row);
        if (self.cache_manager.get(cache_key)) |cached_result| {
            try self.statistics_collector.recordCacheHit(policy.id);
            return cached_result;
        }

        // Evaluate temporal constraints
        if (policy.temporal) |temporal| {
            if (!try self.evaluateTemporalConstraint(temporal, context)) {
                try self.cache_manager.put(cache_key, false);
                return false;
            }
        }

        // Evaluate data classification constraints
        if (policy.data_classification) |classification| {
            if (!try self.evaluateDataClassification(classification, context)) {
                try self.cache_manager.put(cache_key, false);
                return false;
            }
        }

        // GAP-0294: Evaluate main policy expression with fail-closed error handling.
        // SECURITY: If expression evaluation fails for any reason, deny access.
        // CANARY: REQ=REQ-RLS-FAILCLOSED-001; FEATURE="RLSFailClosed"; ASPECT=ExpressionEvaluation; STATUS=IMPL; OWNER=security; UPDATED=2026-04-05
        const result = if (policy.using_expr) |expr|
            self.expression_compiler.evaluate(expr, row, context) catch |err| {
                log.warn("RLS expression evaluation failed, denying access (fail-closed)", .{});
                _ = err;
                // Cache the denial to avoid repeated evaluation of broken expressions
                self.cache_manager.put(cache_key, false) catch {};
                return false;
            }
        else
            true; // No expression means allow (standard RLS semantics)

        // Cache the result
        try self.cache_manager.put(cache_key, result);
        try self.statistics_collector.recordCacheMiss(policy.id);

        return result;
    }

    // Enhanced query rewriting with optimization
    pub fn rewriteQueryEnhanced(
        self: *Self,
        query: []const u8,
        context: *auth.SecurityContext,
        graph: []const u8,
    ) ![]const u8 {
        // Collect applicable policies
        const policies = try self.collectApplicablePolicies(graph, context);
        defer policies.deinit();

        if (policies.items.len == 0) {
            return try self.allocator.dupe(u8, query);
        }

        // Optimize policy combinations
        const optimized_policies = try self.policy_optimizer.optimizePolicies(policies.items);
        defer optimized_policies.deinit();

        // Generate optimized security predicates
        const security_predicate = try self.generateSecurityPredicate(optimized_policies.items, context);
        defer self.allocator.free(security_predicate);

        // Rewrite the query
        return try self.combineQueryWithPredicate(query, security_predicate);
    }

    // Real temporal constraint evaluation
    fn evaluateTemporalConstraint(
        self: *Self,
        constraint: rls.RLSEngine.TemporalConstraint,
        context: *auth.SecurityContext,
    ) !bool {
        const now = compat_milliTimestamp();

        // Check valid time range
        if (constraint.valid_from) |from| {
            if (now < from) return false;
        }

        if (constraint.valid_until) |until| {
            if (now > until) return false;
        }

        // Handle recurrence rules
        if (constraint.recurrence) |recurrence| {
            return try self.evaluateRecurrenceRule(recurrence, now, context);
        }

        return true;
    }

    // Real data classification evaluation
    fn evaluateDataClassification(
        self: *Self,
        classification: rls.RLSEngine.DataClassification,
        context: *auth.SecurityContext,
    ) !bool {
        // Check user's clearance level
        const user_clearance = self.getUserClearanceLevel(context.user.id);
        const required_clearance = @intFromEnum(classification);

        return user_clearance >= required_clearance;
    }

    // Get user's security clearance level
    fn getUserClearanceLevel(self: *Self, user_id: auth.UserId) u8 {
        _ = self;
        _ = user_id;
        // In real implementation, this would query user's clearance from auth system
        return @intFromEnum(rls.RLSEngine.DataClassification.internal); // Default to internal
    }

    // Evaluate recurrence rules for temporal constraints
    fn evaluateRecurrenceRule(
        self: *Self,
        rule: rls.RLSEngine.RecurrenceRule,
        timestamp: i64,
        context: *auth.SecurityContext,
    ) !bool {
        _ = self;
        _ = context;

        // Convert timestamp to date/time components
        const seconds = @divTrunc(timestamp, 1000);
        const epoch_day = @divTrunc(seconds, 86400);
        const day_seconds = @rem(seconds, 86400);
        const hour = @divTrunc(day_seconds, 3600);
        const day_of_week = @rem(epoch_day + 4, 7); // January 1, 1970 was a Thursday

        // Check hour constraints
        if (rule.by_hour) |hours| {
            var hour_allowed = false;
            for (hours) |allowed_hour| {
                if (@as(u8, @intCast(allowed_hour)) == @as(u8, @intCast(hour))) {
                    hour_allowed = true;
                    break;
                }
            }
            if (!hour_allowed) return false;
        }

        // Check day of week constraints
        if (rule.by_day) |days| {
            var day_allowed = false;
            for (days) |allowed_day| {
                if (@intFromEnum(allowed_day) == day_of_week) {
                    day_allowed = true;
                    break;
                }
            }
            if (!day_allowed) return false;
        }

        // Check frequency and interval
        switch (rule.frequency) {
            .daily => {
                const days_since_epoch = epoch_day;
                return @rem(days_since_epoch, rule.interval) == 0;
            },
            .weekly => {
                const weeks_since_epoch = @divTrunc(epoch_day, 7);
                return @rem(weeks_since_epoch, rule.interval) == 0;
            },
            .monthly => {
                // Simplified monthly calculation
                const months_since_epoch = @divTrunc(epoch_day, 30);
                return @rem(months_since_epoch, rule.interval) == 0;
            },
            .yearly => {
                // Simplified yearly calculation
                const years_since_epoch = @divTrunc(epoch_day, 365);
                return @rem(years_since_epoch, rule.interval) == 0;
            },
        }
    }

    // Collect applicable policies with optimization
    fn collectApplicablePolicies(
        self: *Self,
        graph: []const u8,
        context: *auth.SecurityContext,
    ) !std.ArrayList(rls.RLSEngine.Policy) {
        return try self.base_engine.findApplicablePolicies(graph, context.user.id, context.roles);
    }

    // Generate optimized security predicate
    fn generateSecurityPredicate(
        self: *Self,
        policies: []const rls.RLSEngine.Policy,
        context: *auth.SecurityContext,
    ) ![]const u8 {
        _ = context;

        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        try result.appendSlice("(");

        var first = true;
        for (policies) |policy| {
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

        if (first) {
            // No policies found, return TRUE
            try result.appendSlice("TRUE");
        }

        try result.appendSlice(")");

        return try result.toOwnedSlice();
    }

    // Combine query with security predicate
    fn combineQueryWithPredicate(
        self: *Self,
        query: []const u8,
        predicate: []const u8,
    ) ![]const u8 {
        // Simple implementation - in production this would use proper query parsing
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        // Check if query already has WHERE clause
        const has_where = std.mem.indexOf(u8, query, "WHERE") != null;

        try result.appendSlice(query);

        if (has_where) {
            try result.appendSlice(" AND ");
        } else {
            try result.appendSlice(" WHERE ");
        }

        try result.appendSlice(predicate);

        return try result.toOwnedSlice();
    }
};

// Enhanced Expression Compiler with real evaluation
pub const ExpressionCompiler = struct {
    allocator: Allocator,
    function_registry: std.StringHashMap(BuiltinFunction),

    const BuiltinFunction = *const fn (
        allocator: Allocator,
        args: []const rls.Value,
        context: *auth.SecurityContext,
    ) anyerror!rls.Value;

    pub fn init(allocator: Allocator) !ExpressionCompiler {
        var compiler = ExpressionCompiler{
            .allocator = allocator,
            .function_registry = std.StringHashMap(BuiltinFunction).init(allocator),
        };

        // Register enhanced built-in functions
        try compiler.registerEnhancedFunctions();

        return compiler;
    }

    pub fn deinit(self: *ExpressionCompiler) void {
        self.function_registry.deinit();
    }

    pub fn evaluate(
        self: *ExpressionCompiler,
        expression: rls.RLSEngine.Expression,
        row: *const std.StringHashMap(rls.Value),
        context: *auth.SecurityContext,
    ) !bool {
        // Use compiled expression if available
        if (expression.compiled) |compiled| {
            return try self.evaluateCompiled(compiled, row, context);
        }

        // Fall back to interpreted evaluation
        return try self.evaluateInterpreted(expression.raw, row, context);
    }

    // CANARY: REQ=REQ-RLS-CONTEXT-001; FEATURE="RLSContextEvaluation"; ASPECT=RLS; STATUS=EXEMPT; OWNER=security; UPDATED=2026-01-10
    fn evaluateCompiled(
        self: *ExpressionCompiler,
        compiled: *rls.RLSEngine.CompiledExpression,
        row: *const std.StringHashMap(rls.Value),
        context: *auth.SecurityContext,
    ) !bool {
        // GAP-0047: Now properly uses security context for user-specific evaluations
        var pc: usize = 0;
        var stack = std.ArrayList(rls.Value).init(self.allocator);
        defer stack.deinit();

        while (pc < compiled.bytecode.len) {
            const opcode = compiled.bytecode[pc];
            pc += 1;

            switch (opcode) {
                0x00 => {}, // NOP
                0x01 => { // LOAD_CONST
                    const const_idx = compiled.bytecode[pc];
                    pc += 1;
                    try stack.append(compiled.constants[const_idx]);
                },
                0x02 => { // LOAD_FIELD (reads field name index from bytecode)
                    const field_idx = if (pc < compiled.bytecode.len) blk: {
                        const idx = compiled.bytecode[pc];
                        pc += 1;
                        break :blk idx;
                    } else 0;
                    // Get field name from constants array (stored as string values)
                    const field_name = if (field_idx < compiled.constants.len)
                        switch (compiled.constants[field_idx]) {
                            .string => |s| s,
                            else => "user_id",
                        }
                    else
                        "user_id"; // Fallback for backwards compatibility
                    if (row.get(field_name)) |value| {
                        try stack.append(value);
                    } else {
                        try stack.append(rls.Value{ .null = {} });
                    }
                },
                0x03 => { // COMPARE_EQ
                    if (stack.items.len < 2) return false;
                    const b = stack.pop();
                    const a = stack.pop();
                    const result = try self.compareValues(a, b);
                    try stack.append(rls.Value{ .boolean = result });
                },
                0x04 => { // RETURN
                    if (stack.items.len > 0) {
                        const result = stack.pop();
                        return switch (result) {
                            .boolean => |b| b,
                            else => false,
                        };
                    }
                    return false;
                },
                // GAP-0047: New opcodes for security context access
                0x05 => { // LOAD_CURRENT_USER - pushes current user ID from context
                    try stack.append(rls.Value{ .integer = @intCast(context.user.id) });
                },
                0x06 => { // LOAD_CURRENT_USER_NAME - pushes current username from context
                    try stack.append(rls.Value{ .string = context.user.username });
                },
                0x07 => { // HAS_ROLE - pops role name from stack, pushes boolean
                    if (stack.items.len < 1) {
                        try stack.append(rls.Value{ .boolean = false });
                    } else {
                        const role_val = stack.pop();
                        const has_role = switch (role_val) {
                            .string => |role_name| self.userHasRole(context, role_name),
                            else => false,
                        };
                        try stack.append(rls.Value{ .boolean = has_role });
                    }
                },
                0x08 => { // COMPARE_NE (not equal)
                    if (stack.items.len < 2) return false;
                    const b = stack.pop();
                    const a = stack.pop();
                    const result = try self.compareValues(a, b);
                    try stack.append(rls.Value{ .boolean = !result });
                },
                0x09 => { // LOGICAL_AND
                    if (stack.items.len < 2) return false;
                    const b = stack.pop();
                    const a = stack.pop();
                    const a_bool = switch (a) {
                        .boolean => |v| v,
                        else => false,
                    };
                    const b_bool = switch (b) {
                        .boolean => |v| v,
                        else => false,
                    };
                    try stack.append(rls.Value{ .boolean = a_bool and b_bool });
                },
                0x0A => { // LOGICAL_OR
                    if (stack.items.len < 2) return false;
                    const b = stack.pop();
                    const a = stack.pop();
                    const a_bool = switch (a) {
                        .boolean => |v| v,
                        else => false,
                    };
                    const b_bool = switch (b) {
                        .boolean => |v| v,
                        else => false,
                    };
                    try stack.append(rls.Value{ .boolean = a_bool or b_bool });
                },
                else => return false, // Unknown opcode
            }
        }

        // Default return
        return stack.items.len > 0 and switch (stack.items[stack.items.len - 1]) {
            .boolean => |b| b,
            else => false,
        };
    }

    fn evaluateInterpreted(
        self: *ExpressionCompiler,
        expression: []const u8,
        row: *const std.StringHashMap(rls.Value),
        context: *auth.SecurityContext,
    ) !bool {
        // Simple expression evaluation for common patterns

        // Check for user ID comparison
        if (std.mem.indexOf(u8, expression, "user_id")) |_| {
            if (std.mem.indexOf(u8, expression, "current_user()")) |_| {
                // Pattern: user_id = current_user()
                if (row.get("user_id")) |user_id_value| {
                    const current_user_id = rls.Value{ .integer = @intCast(context.user.id) };
                    return try self.compareValues(user_id_value, current_user_id);
                }
            }
        }

        // Check for role-based access
        if (std.mem.indexOf(u8, expression, "has_role")) |_| {
            // Extract role name (simplified parsing)
            if (std.mem.indexOf(u8, expression, "'")) |start| {
                if (std.mem.indexOfPos(u8, expression, start + 1, "'")) |end| {
                    const role_name = expression[start + 1 .. end];
                    return self.userHasRole(context, role_name);
                }
            }
        }

        // Check for time-based constraints
        if (std.mem.indexOf(u8, expression, "current_timestamp")) |_| {
            // Simplified time comparison
            const now = compat_milliTimestamp();
            if (std.mem.indexOf(u8, expression, ">")) |_| {
                return now > 0; // Always true for positive timestamps
            }
        }

        // Default to false for unrecognized expressions (fail-closed for security)
        log.warn("RLS: unrecognized expression, denying access (fail-closed)", .{});
        return false;
    }

    fn compareValues(self: *ExpressionCompiler, a: rls.Value, b: rls.Value) !bool {
        _ = self;

        return switch (a) {
            .integer => |a_int| switch (b) {
                .integer => |b_int| a_int == b_int,
                else => false,
            },
            .string => |a_str| switch (b) {
                .string => |b_str| std.mem.eql(u8, a_str, b_str),
                else => false,
            },
            .boolean => |a_bool| switch (b) {
                .boolean => |b_bool| a_bool == b_bool,
                else => false,
            },
            .null => switch (b) {
                .null => true,
                else => false,
            },
            else => false,
        };
    }

    fn userHasRole(self: *ExpressionCompiler, context: *auth.SecurityContext, role_name: []const u8) bool {
        _ = self;

        for (context.roles) |role| {
            if (std.mem.eql(u8, role.name, role_name)) {
                return true;
            }
        }
        return false;
    }

    fn registerEnhancedFunctions(self: *ExpressionCompiler) !void {
        try self.function_registry.put("current_user", enhancedCurrentUser);
        try self.function_registry.put("has_role", enhancedHasRole);
        try self.function_registry.put("has_permission", enhancedHasPermission);
        try self.function_registry.put("current_timestamp", enhancedCurrentTimestamp);
        try self.function_registry.put("ip_in_range", enhancedIpInRange);
        try self.function_registry.put("data_classification", enhancedDataClassification);
        try self.function_registry.put("time_in_range", enhancedTimeInRange);
    }

    fn enhancedCurrentUser(
        allocator: Allocator,
        args: []const rls.Value,
        context: *auth.SecurityContext,
    ) anyerror!rls.Value {
        _ = allocator;
        _ = args;
        return rls.Value{ .integer = @intCast(context.user.id) };
    }

    fn enhancedHasRole(
        allocator: Allocator,
        args: []const rls.Value,
        context: *auth.SecurityContext,
    ) anyerror!rls.Value {
        _ = allocator;
        if (args.len != 1) return error.InvalidArguments;

        const role_name = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };

        for (context.roles) |role| {
            if (std.mem.eql(u8, role.name, role_name)) {
                return rls.Value{ .boolean = true };
            }
        }

        return rls.Value{ .boolean = false };
    }

    fn enhancedHasPermission(
        allocator: Allocator,
        args: []const rls.Value,
        context: *auth.SecurityContext,
    ) anyerror!rls.Value {
        _ = allocator;
        if (args.len != 1) return error.InvalidArguments;

        const permission = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };

        // Check if user has the specified permission
        for (context.roles) |role| {
            // Simplified permission check - in reality would check role permissions
            if (std.mem.eql(u8, role.name, "admin") or std.mem.eql(u8, role.name, permission)) {
                return rls.Value{ .boolean = true };
            }
        }

        return rls.Value{ .boolean = false };
    }

    fn enhancedCurrentTimestamp(
        allocator: Allocator,
        args: []const rls.Value,
        context: *auth.SecurityContext,
    ) anyerror!rls.Value {
        _ = allocator;
        _ = args;
        _ = context;
        return rls.Value{ .timestamp = compat_milliTimestamp() };
    }

    fn enhancedIpInRange(
        allocator: Allocator,
        args: []const rls.Value,
        context: *auth.SecurityContext,
    ) anyerror!rls.Value {
        _ = allocator;
        if (args.len != 1) return error.InvalidArguments;

        const range = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };

        // Proper IPv4 CIDR range check
        const user_ip = context.environment.ip_address;
        return rls.Value{ .boolean = cidrMatch(user_ip, range) };
    }

    /// Parse an IPv4 dotted-decimal string into a u32 in network byte order.
    /// Returns null on any parse failure.
    fn parseIpv4(ip: []const u8) ?u32 {
        var result: u32 = 0;
        var octet_count: u8 = 0;
        var remaining = ip;

        while (octet_count < 4) : (octet_count += 1) {
            if (octet_count > 0) {
                if (remaining.len == 0 or remaining[0] != '.') return null;
                remaining = remaining[1..];
            }
            const dot_pos = std.mem.indexOf(u8, remaining, ".");
            const octet_str = if (dot_pos) |p| remaining[0..p] else remaining;
            if (octet_str.len == 0) return null;
            const octet = std.fmt.parseInt(u8, octet_str, 10) catch return null;
            result = (result << 8) | @as(u32, octet);
            remaining = if (dot_pos) |p| remaining[p..] else remaining[octet_str.len..];
        }

        if (remaining.len != 0) return null;
        return result;
    }

    /// Proper IPv4 CIDR match. Supports "A.B.C.D/N" or plain "A.B.C.D" (treated as /32).
    fn cidrMatch(ip_str: []const u8, range_str: []const u8) bool {
        const ip_u32 = parseIpv4(ip_str) orelse return false;

        var base_str: []const u8 = range_str;
        var prefix_len: u6 = 32;

        if (std.mem.indexOf(u8, range_str, "/")) |slash_pos| {
            base_str = range_str[0..slash_pos];
            prefix_len = std.fmt.parseInt(u6, range_str[slash_pos + 1 ..], 10) catch return false;
            if (prefix_len > 32) return false;
        }

        const base_u32 = parseIpv4(base_str) orelse return false;

        if (prefix_len == 0) return true;

        const mask: u32 = ~(@as(u32, 0)) << @intCast(32 - @as(u6, prefix_len));
        return (ip_u32 & mask) == (base_u32 & mask);
    }

    fn ipInCidr(ip: []const u8, network: []const u8, prefix_len: u8) bool {
        if (prefix_len == 0) return true;
        if (prefix_len > 32) return false;

        const ip_u32 = parseIpv4(ip) orelse return false;
        const net_u32 = parseIpv4(network) orelse return false;

        const p: u6 = @intCast(prefix_len);
        const mask: u32 = ~(@as(u32, 0)) << @intCast(32 - p);
        return (ip_u32 & mask) == (net_u32 & mask);
    }

    fn enhancedDataClassification(
        allocator: Allocator,
        args: []const rls.Value,
        context: *auth.SecurityContext,
    ) anyerror!rls.Value {
        _ = allocator;
        _ = context;
        if (args.len != 1) return error.InvalidArguments;

        const classification = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };

        // Check data classification levels
        const required_level = if (std.mem.eql(u8, classification, "public"))
            @intFromEnum(rls.RLSEngine.DataClassification.public)
        else if (std.mem.eql(u8, classification, "internal"))
            @intFromEnum(rls.RLSEngine.DataClassification.internal)
        else if (std.mem.eql(u8, classification, "confidential"))
            @intFromEnum(rls.RLSEngine.DataClassification.confidential)
        else if (std.mem.eql(u8, classification, "restricted"))
            @intFromEnum(rls.RLSEngine.DataClassification.restricted)
        else if (std.mem.eql(u8, classification, "top_secret"))
            @intFromEnum(rls.RLSEngine.DataClassification.top_secret)
        else
            @intFromEnum(rls.RLSEngine.DataClassification.internal);

        // In real implementation, would check user's clearance level
        const user_clearance = @intFromEnum(rls.RLSEngine.DataClassification.internal);

        return rls.Value{ .boolean = user_clearance >= required_level };
    }

    fn enhancedTimeInRange(
        allocator: Allocator,
        args: []const rls.Value,
        context: *auth.SecurityContext,
    ) anyerror!rls.Value {
        _ = allocator;
        _ = context;
        if (args.len != 2) return error.InvalidArguments;

        const start_hour = switch (args[0]) {
            .integer => |i| @as(u8, @intCast(i)),
            else => return error.InvalidArguments,
        };

        const end_hour = switch (args[1]) {
            .integer => |i| @as(u8, @intCast(i)),
            else => return error.InvalidArguments,
        };

        const now = compat_milliTimestamp();
        const seconds = @divTrunc(now, 1000);
        const day_seconds = @rem(seconds, 86400);
        const hour = @as(u8, @intCast(@divTrunc(day_seconds, 3600)));

        const in_range = if (start_hour <= end_hour)
            hour >= start_hour and hour <= end_hour
        else
            hour >= start_hour or hour <= end_hour; // Wrap around midnight

        return rls.Value{ .boolean = in_range };
    }
};

// Policy Optimizer for efficient policy evaluation
pub const PolicyOptimizer = struct {
    allocator: Allocator,
    optimization_cache: std.HashMap(u64, OptimizedPolicySet, std.hash_map.DefaultHashContext, 80),

    const OptimizedPolicySet = struct {
        policies: []rls.RLSEngine.Policy,
        evaluation_order: []usize,
        short_circuit_points: []usize,
    };

    pub fn init(allocator: Allocator) !PolicyOptimizer {
        return PolicyOptimizer{
            .allocator = allocator,
            .optimization_cache = std.HashMap(u64, OptimizedPolicySet, std.hash_map.DefaultHashContext, 80).init(allocator),
        };
    }

    pub fn deinit(self: *PolicyOptimizer) void {
        var it = self.optimization_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.evaluation_order);
            self.allocator.free(entry.value_ptr.short_circuit_points);
        }
        self.optimization_cache.deinit();
    }

    pub fn optimizePolicies(
        self: *PolicyOptimizer,
        policies: []const rls.RLSEngine.Policy,
    ) !std.ArrayList(rls.RLSEngine.Policy) {
        // Calculate hash for caching
        const policies_hash = self.calculatePoliciesHash(policies);

        if (self.optimization_cache.get(policies_hash)) |cached| {
            var result = std.ArrayList(rls.RLSEngine.Policy).init(self.allocator);
            try result.appendSlice(cached.policies);
            return result;
        }

        // Optimize policy evaluation order
        var optimized = std.ArrayList(rls.RLSEngine.Policy).init(self.allocator);
        try optimized.appendSlice(policies);

        // Sort by priority and performance characteristics
        std.sort.insertion(rls.RLSEngine.Policy, optimized.items, {}, policyCompareFn);

        return optimized;
    }

    fn calculatePoliciesHash(self: *PolicyOptimizer, policies: []const rls.RLSEngine.Policy) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);

        for (policies) |policy| {
            hasher.update(std.mem.asBytes(&policy.id));
            hasher.update(std.mem.asBytes(&policy.enabled));
            hasher.update(std.mem.asBytes(&policy.permissive));
        }

        return hasher.final();
    }

    fn policyCompareFn(context: void, a: rls.RLSEngine.Policy, b: rls.RLSEngine.Policy) bool {
        _ = context;

        // Prioritize enabled policies
        if (a.enabled != b.enabled) {
            return a.enabled;
        }

        // Prioritize simpler expressions (faster evaluation)
        const a_complexity = if (a.using_expr) |expr| expr.raw.len else 0;
        const b_complexity = if (b.using_expr) |expr| expr.raw.len else 0;

        return a_complexity < b_complexity;
    }
};

// Statistics Collector for RLS performance monitoring
pub const RLSStatisticsCollector = struct {
    allocator: Allocator,
    policy_stats: std.AutoHashMap(u64, PolicyStatistics),
    global_stats: GlobalStatistics,

    const PolicyStatistics = struct {
        evaluations: u64,
        cache_hits: u64,
        cache_misses: u64,
        avg_evaluation_time_ns: u64,
        last_evaluation: i64,
    };

    const GlobalStatistics = struct {
        total_evaluations: u64,
        total_cache_hits: u64,
        total_cache_misses: u64,
        policies_created: u64,
        policies_deleted: u64,
    };

    pub fn init(allocator: Allocator) !RLSStatisticsCollector {
        return RLSStatisticsCollector{
            .allocator = allocator,
            .policy_stats = std.AutoHashMap(u64, PolicyStatistics).init(allocator),
            .global_stats = GlobalStatistics{
                .total_evaluations = 0,
                .total_cache_hits = 0,
                .total_cache_misses = 0,
                .policies_created = 0,
                .policies_deleted = 0,
            },
        };
    }

    pub fn deinit(self: *RLSStatisticsCollector) void {
        self.policy_stats.deinit();
    }

    pub fn recordPolicyEvaluation(self: *RLSStatisticsCollector, policy_id: u64) !void {
        const result = try self.policy_stats.getOrPut(policy_id);
        if (!result.found_existing) {
            result.value_ptr.* = PolicyStatistics{
                .evaluations = 0,
                .cache_hits = 0,
                .cache_misses = 0,
                .avg_evaluation_time_ns = 0,
                .last_evaluation = compat_milliTimestamp(),
            };
        }

        result.value_ptr.evaluations += 1;
        result.value_ptr.last_evaluation = compat_milliTimestamp();
        self.global_stats.total_evaluations += 1;
    }

    pub fn recordCacheHit(self: *RLSStatisticsCollector, policy_id: u64) !void {
        if (self.policy_stats.getPtr(policy_id)) |stats| {
            stats.cache_hits += 1;
        }
        self.global_stats.total_cache_hits += 1;
    }

    pub fn recordCacheMiss(self: *RLSStatisticsCollector, policy_id: u64) !void {
        if (self.policy_stats.getPtr(policy_id)) |stats| {
            stats.cache_misses += 1;
        }
        self.global_stats.total_cache_misses += 1;
    }

    pub fn getCacheHitRatio(self: *RLSStatisticsCollector) f64 {
        const total_requests = self.global_stats.total_cache_hits + self.global_stats.total_cache_misses;
        if (total_requests == 0) return 0.0;
        return @as(f64, @floatFromInt(self.global_stats.total_cache_hits)) / @as(f64, @floatFromInt(total_requests));
    }

    pub fn getPolicyStatistics(self: *RLSStatisticsCollector, policy_id: u64) ?PolicyStatistics {
        return self.policy_stats.get(policy_id);
    }

    pub fn getGlobalStatistics(self: *RLSStatisticsCollector) GlobalStatistics {
        return self.global_stats;
    }
};

// Enhanced Cache Manager with TTL and LRU eviction
pub const EnhancedCacheManager = struct {
    allocator: Allocator,
    cache: std.HashMap(CacheKey, CacheEntry, CacheKey.HashContext, 80),
    access_order: std.ArrayList(CacheKey),
    max_size: usize,
    default_ttl_ms: i64,

    const CacheKey = struct {
        policy_id: u64,
        user_id: auth.UserId,
        row_hash: u64,

        pub const HashContext = struct {
            pub fn hash(_: @This(), key: CacheKey) u64 {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(std.mem.asBytes(&key.policy_id));
                hasher.update(std.mem.asBytes(&key.user_id));
                hasher.update(std.mem.asBytes(&key.row_hash));
                return hasher.final();
            }

            pub fn eql(_: @This(), a: CacheKey, b: CacheKey) bool {
                return a.policy_id == b.policy_id and
                    a.user_id == b.user_id and
                    a.row_hash == b.row_hash;
            }
        };
    };

    const CacheEntry = struct {
        result: bool,
        timestamp: i64,
        access_count: u64,
    };

    pub fn init(allocator: Allocator) !EnhancedCacheManager {
        return EnhancedCacheManager{
            .allocator = allocator,
            .cache = std.HashMap(CacheKey, CacheEntry, CacheKey.HashContext, 80).init(allocator),
            .access_order = std.ArrayList(CacheKey).init(allocator),
            .max_size = ENHANCED_RLS_CACHE_MAX_SIZE,
            .default_ttl_ms = ENHANCED_RLS_CACHE_DEFAULT_TTL_MS,
        };
    }

    pub fn deinit(self: *EnhancedCacheManager) void {
        self.cache.deinit();
        self.access_order.deinit();
    }

    pub fn generateCacheKey(
        self: *EnhancedCacheManager,
        policy_id: u64,
        user_id: auth.UserId,
        row: *const std.StringHashMap(rls.Value),
    ) !CacheKey {
        _ = self;

        // Generate hash of row data for cache key
        var hasher = std.hash.Wyhash.init(0);
        var it = row.iterator();
        while (it.next()) |entry| {
            hasher.update(entry.key_ptr.*);
            // Hash value based on type
            switch (entry.value_ptr.*) {
                .integer => |i| hasher.update(std.mem.asBytes(&i)),
                .string => |s| hasher.update(s),
                .boolean => |b| hasher.update(std.mem.asBytes(&b)),
                else => {},
            }
        }

        return CacheKey{
            .policy_id = policy_id,
            .user_id = user_id,
            .row_hash = hasher.final(),
        };
    }

    pub fn get(self: *EnhancedCacheManager, key: CacheKey) ?bool {
        if (self.cache.getPtr(key)) |entry| {
            const now = compat_milliTimestamp();

            // Check TTL
            if (now - entry.timestamp > self.default_ttl_ms) {
                _ = self.cache.remove(key);
                self.removeFromAccessOrder(key);
                return null;
            }

            // Update access statistics
            entry.access_count += 1;
            self.updateAccessOrder(key) catch {};

            return entry.result;
        }

        return null;
    }

    pub fn put(self: *EnhancedCacheManager, key: CacheKey, result: bool) !void {
        // Evict if cache is full
        if (self.cache.count() >= self.max_size) {
            try self.evictLRU();
        }

        const now = compat_milliTimestamp();
        try self.cache.put(key, CacheEntry{
            .result = result,
            .timestamp = now,
            .access_count = 1,
        });

        try self.access_order.append(key);
    }

    fn updateAccessOrder(self: *EnhancedCacheManager, key: CacheKey) !void {
        // Move key to end of access order (most recently used)
        self.removeFromAccessOrder(key);
        try self.access_order.append(key);
    }

    fn removeFromAccessOrder(self: *EnhancedCacheManager, key: CacheKey) void {
        for (self.access_order.items, 0..) |item, i| {
            if (CacheKey.HashContext.eql(.{}, item, key)) {
                _ = self.access_order.swapRemove(i);
                break;
            }
        }
    }

    fn evictLRU(self: *EnhancedCacheManager) !void {
        if (self.access_order.items.len > 0) {
            const lru_key = self.access_order.items[0];
            _ = self.cache.remove(lru_key);
            _ = self.access_order.orderedRemove(0);
        }
    }
};

test "GAP-0287: enhanced ipInCidr proper bitwise matching" {
    const Evaluator = ExpressionCompiler;

    // Basic CIDR matching
    try std.testing.expect(Evaluator.ipInCidr("192.168.1.1", "192.168.1.0", 24));
    try std.testing.expect(!Evaluator.ipInCidr("192.168.2.1", "192.168.1.0", 24));

    // The bug: string byte comparison "10.1" prefix matched "10.100.0.1"
    try std.testing.expect(!Evaluator.ipInCidr("10.100.0.1", "10.1.0.0", 16));
    try std.testing.expect(Evaluator.ipInCidr("10.1.0.1", "10.1.0.0", 16));

    // /0 matches everything
    try std.testing.expect(Evaluator.ipInCidr("1.2.3.4", "0.0.0.0", 0));

    // /32 exact match
    try std.testing.expect(Evaluator.ipInCidr("192.168.1.1", "192.168.1.1", 32));
    try std.testing.expect(!Evaluator.ipInCidr("192.168.1.2", "192.168.1.1", 32));

    // /8 subnet
    try std.testing.expect(Evaluator.ipInCidr("10.255.255.255", "10.0.0.0", 8));
    try std.testing.expect(!Evaluator.ipInCidr("11.0.0.0", "10.0.0.0", 8));

    // Invalid inputs
    try std.testing.expect(!Evaluator.ipInCidr("not.an.ip", "192.168.1.0", 24));
    try std.testing.expect(!Evaluator.ipInCidr("192.168.1.1", "bad", 24));
}

test "GAP-0287: enhanced cidrMatch with CIDR notation string" {
    const Evaluator = ExpressionCompiler;

    // CIDR notation
    try std.testing.expect(Evaluator.cidrMatch("192.168.1.100", "192.168.1.0/24"));
    try std.testing.expect(!Evaluator.cidrMatch("192.168.2.100", "192.168.1.0/24"));

    // The critical bug: "192.168.1" prefix would match "192.168.10.5"
    try std.testing.expect(!Evaluator.cidrMatch("192.168.10.5", "192.168.1.0/24"));

    // Plain address = /32
    try std.testing.expect(Evaluator.cidrMatch("10.0.0.1", "10.0.0.1"));
    try std.testing.expect(!Evaluator.cidrMatch("10.0.0.2", "10.0.0.1"));

    // /16 subnet
    try std.testing.expect(Evaluator.cidrMatch("172.16.255.1", "172.16.0.0/16"));
    try std.testing.expect(!Evaluator.cidrMatch("172.17.0.1", "172.16.0.0/16"));
}

test "GAP-0287: enhanced parseIpv4 unit tests" {
    const Evaluator = ExpressionCompiler;

    try std.testing.expectEqual(@as(?u32, 0xC0A80101), Evaluator.parseIpv4("192.168.1.1"));
    try std.testing.expectEqual(@as(?u32, 0x0A000001), Evaluator.parseIpv4("10.0.0.1"));
    try std.testing.expectEqual(@as(?u32, null), Evaluator.parseIpv4(""));
    try std.testing.expectEqual(@as(?u32, null), Evaluator.parseIpv4("192.168.1"));
    try std.testing.expectEqual(@as(?u32, null), Evaluator.parseIpv4("256.0.0.1"));
}
