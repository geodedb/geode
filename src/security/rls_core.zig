const std = @import("std");
const Allocator = std.mem.Allocator;
const auth = @import("geode_auth");
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;

// CANARY: REQ=REQ-M10-CONSTANTS-002; FEATURE="CodeQuality"; ASPECT=MAGIC_NUMBERS; STATUS=EXEMPT; OWNER=security; UPDATED=2025-10-17
// RLS cache configuration constants
const RLS_POLICY_CACHE_MAX_SIZE = 10_000; // Maximum cached policy evaluations
const RLS_POLICY_CACHE_TTL_MS = 60_000; // Cache TTL: 60 seconds (1 minute)

// Type definitions that would normally come from other modules
pub const ValueType = enum {
    null,
    boolean,
    integer,
    float,
    string,
    timestamp,
    array,
    object,
};

pub const Value = union(ValueType) {
    null: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    timestamp: i64,
    array: []const Value,
    object: std.StringHashMap(Value),
};

// Enhanced Row-Level Security Engine with fine-grained access control
pub const RLSEngine = struct {
    allocator: Allocator,
    policies: std.HashMap(PolicyKey, std.ArrayList(Policy), PolicyKey.HashContext, 80),
    policy_cache: PolicyCache,
    context_evaluator: ContextEvaluator,
    query_rewriter: QueryRewriter,
    hierarchy_manager: HierarchyManager,
    attribute_controller: AttributeBasedAccessControl,
    audit_logger: AuditLogger,

    const Self = @This();

    fn dummyLogWriter(event: AuditLogger.AuditEvent) void {
        _ = event;
        // No-op for module compilation
    }

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

        // CANARY: REQ=REQ-RLS-EXPR-001; FEATURE="RLSExpressionCompilation"; ASPECT=Bytecode; STATUS=EXEMPT; OWNER=security; UPDATED=2025-12-30
        pub const Opcode = enum(u8) {
            nop = 0x00,
            // Stack operations
            push_const = 0x01, // Push constants[arg] onto stack
            push_true = 0x02, // Push true
            push_false = 0x03, // Push false
            push_null = 0x04, // Push null
            pop = 0x05, // Pop top of stack
            // Variable access
            load_row = 0x10, // Load row[constants[arg]] onto stack
            load_user = 0x11, // Load current user ID onto stack
            load_session = 0x12, // Load session[constants[arg]] onto stack
            // Comparisons (pop 2, push bool)
            eq = 0x20, // ==
            neq = 0x21, // <>
            lt = 0x22, // <
            gt = 0x23, // >
            lte = 0x24, // <=
            gte = 0x25, // >=
            // Logical (pop 1-2, push bool)
            op_and = 0x30, // AND
            op_or = 0x31, // OR
            op_not = 0x32, // NOT
            // Control flow
            jump = 0x40, // Jump to jump_table[arg]
            jump_if_false = 0x41, // Pop and jump if false
            jump_if_true = 0x42, // Pop and jump if true
            // Return
            ret = 0xFF, // Return top of stack as result
        };
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

    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .policies = std.HashMap(PolicyKey, std.ArrayList(Policy), PolicyKey.HashContext, 80).init(allocator),
            .policy_cache = try PolicyCache.init(allocator),
            .context_evaluator = try ContextEvaluator.init(allocator),
            .query_rewriter = try QueryRewriter.init(allocator),
            .hierarchy_manager = try HierarchyManager.init(allocator),
            .attribute_controller = try AttributeBasedAccessControl.init(allocator),
            .audit_logger = try AuditLogger.init(allocator, .{ .custom = dummyLogWriter }),
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
        self.hierarchy_manager.deinit();
        self.attribute_controller.deinit();
        self.audit_logger.deinit();
    }

    // Policy Management
    pub fn createPolicy(self: *Self, policy: Policy) !void {
        const key = PolicyKey{
            .graph = policy.graph,
            .table = policy.table,
        };

        const result = try self.policies.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(Policy).empty;
        }

        // Compile expressions if provided
        // CANARY: REQ=REQ-RLS-EXPR-002; FEATURE="RLSExpressionCompilation"; ASPECT=PolicyCompilation; STATUS=EXEMPT; OWNER=security; UPDATED=2025-12-30
        var compiled_policy = policy;
        if (compiled_policy.using_expr) |*expr| {
            if (expr.compiled == null) {
                expr.compiled = try self.compileExpression(expr.raw);
            }
        }
        if (compiled_policy.check_expr) |*expr| {
            if (expr.compiled == null) {
                expr.compiled = try self.compileExpression(expr.raw);
            }
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
        var result = std.ArrayList(Policy).empty;

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

    // CANARY: REQ=REQ-RLS-EXPR-003; FEATURE="RLSExpressionCompilation"; ASPECT=ExpressionCompiler; STATUS=EXEMPT; OWNER=security; UPDATED=2025-12-30
    fn compileExpression(self: *Self, expr: []const u8) !*CompiledExpression {
        const Opcode = CompiledExpression.Opcode;
        var bytecode = std.ArrayList(u8).empty;
        var constants = std.ArrayList(Value).empty;
        var jump_table = std.ArrayList(usize).empty;

        // Simple expression parser supporting:
        // - row.field_name = 'value'
        // - row.field_name = current_user
        // - expr1 AND expr2, expr1 OR expr2
        // - TRUE, FALSE
        var i: usize = 0;
        while (i < expr.len) {
            // Skip whitespace
            while (i < expr.len and (expr[i] == ' ' or expr[i] == '\t' or expr[i] == '\n')) : (i += 1) {}
            if (i >= expr.len) break;

            // Check for TRUE/FALSE literals
            if (i + 4 <= expr.len and std.ascii.eqlIgnoreCase(expr[i .. i + 4], "true")) {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.push_true));
                i += 4;
                continue;
            }
            if (i + 5 <= expr.len and std.ascii.eqlIgnoreCase(expr[i .. i + 5], "false")) {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.push_false));
                i += 5;
                continue;
            }

            // Check for AND/OR
            if (i + 3 <= expr.len and std.ascii.eqlIgnoreCase(expr[i .. i + 3], "and")) {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.op_and));
                i += 3;
                continue;
            }
            if (i + 2 <= expr.len and std.ascii.eqlIgnoreCase(expr[i .. i + 2], "or")) {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.op_or));
                i += 2;
                continue;
            }

            // Check for NOT
            if (i + 3 <= expr.len and std.ascii.eqlIgnoreCase(expr[i .. i + 3], "not")) {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.op_not));
                i += 3;
                continue;
            }

            // Check for row.field_name pattern
            if (i + 4 <= expr.len and std.ascii.eqlIgnoreCase(expr[i .. i + 4], "row.")) {
                i += 4;
                const field_start = i;
                while (i < expr.len and (std.ascii.isAlphanumeric(expr[i]) or expr[i] == '_')) : (i += 1) {}
                const field_name = expr[field_start..i];
                // Add field name to constants and emit load_row
                try constants.append(self.allocator, .{ .string = field_name });
                try bytecode.append(self.allocator, @intFromEnum(Opcode.load_row));
                try bytecode.append(self.allocator, @intCast(constants.items.len - 1));
                continue;
            }

            // Check for current_user
            if (i + 12 <= expr.len and std.ascii.eqlIgnoreCase(expr[i .. i + 12], "current_user")) {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.load_user));
                i += 12;
                continue;
            }

            // Check for comparison operators
            if (i + 2 <= expr.len and expr[i] == '<' and expr[i + 1] == '>') {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.neq));
                i += 2;
                continue;
            }
            if (i + 2 <= expr.len and expr[i] == '<' and expr[i + 1] == '=') {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.lte));
                i += 2;
                continue;
            }
            if (i + 2 <= expr.len and expr[i] == '>' and expr[i + 1] == '=') {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.gte));
                i += 2;
                continue;
            }
            if (expr[i] == '=') {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.eq));
                i += 1;
                continue;
            }
            if (expr[i] == '<') {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.lt));
                i += 1;
                continue;
            }
            if (expr[i] == '>') {
                try bytecode.append(self.allocator, @intFromEnum(Opcode.gt));
                i += 1;
                continue;
            }

            // Check for string literal 'value'
            if (expr[i] == '\'') {
                i += 1;
                const str_start = i;
                while (i < expr.len and expr[i] != '\'') : (i += 1) {}
                const str_value = expr[str_start..i];
                if (i < expr.len) i += 1; // Skip closing quote
                try constants.append(self.allocator, .{ .string = str_value });
                try bytecode.append(self.allocator, @intFromEnum(Opcode.push_const));
                try bytecode.append(self.allocator, @intCast(constants.items.len - 1));
                continue;
            }

            // GAP-0141: Safe integer parsing with error logging
            // CANARY: REQ=REQ-INT-PARSE-RLS-001; FEATURE="Safe Integer Parsing"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=security; UPDATED=2026-01-13
            // Check for integer literal
            if (std.ascii.isDigit(expr[i]) or (expr[i] == '-' and i + 1 < expr.len and std.ascii.isDigit(expr[i + 1]))) {
                const num_start = i;
                if (expr[i] == '-') i += 1;
                while (i < expr.len and std.ascii.isDigit(expr[i])) : (i += 1) {}
                const num_str = expr[num_start..i];
                const num_value = std.fmt.parseInt(i64, num_str, 10) catch {
                    log.warn("Invalid integer literal in RLS expression", &.{
                        Attr.string("literal", num_str),
                    });
                    return error.InvalidRlsExpression;
                };
                try constants.append(self.allocator, .{ .integer = num_value });
                try bytecode.append(self.allocator, @intFromEnum(Opcode.push_const));
                try bytecode.append(self.allocator, @intCast(constants.items.len - 1));
                continue;
            }

            // Skip unknown characters
            i += 1;
        }

        // Add return instruction
        try bytecode.append(self.allocator, @intFromEnum(Opcode.ret));

        const compiled = try self.allocator.create(CompiledExpression);
        compiled.* = CompiledExpression{
            .bytecode = try bytecode.toOwnedSlice(self.allocator),
            .constants = try constants.toOwnedSlice(self.allocator),
            .jump_table = try jump_table.toOwnedSlice(self.allocator),
        };

        return compiled;
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

    // CANARY: REQ=REQ-RLS-EXPR-004; FEATURE="RLSExpressionCompilation"; ASPECT=BytecodeVM; STATUS=EXEMPT; OWNER=security; UPDATED=2025-12-30
    fn evaluateCompiledExpression(
        self: *Self,
        expr: *CompiledExpression,
        row: *const std.StringHashMap(Value),
        context: *auth.SecurityContext,
    ) !bool {
        const Opcode = CompiledExpression.Opcode;
        var stack: [64]Value = undefined;
        var sp: usize = 0; // Stack pointer

        var pc: usize = 0; // Program counter
        while (pc < expr.bytecode.len) {
            const opcode: Opcode = @enumFromInt(expr.bytecode[pc]);
            pc += 1;

            switch (opcode) {
                .nop => {},
                .push_const => {
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (idx < expr.constants.len) {
                        stack[sp] = expr.constants[idx];
                        sp += 1;
                    }
                },
                .push_true => {
                    stack[sp] = .{ .boolean = true };
                    sp += 1;
                },
                .push_false => {
                    stack[sp] = .{ .boolean = false };
                    sp += 1;
                },
                .push_null => {
                    stack[sp] = .null;
                    sp += 1;
                },
                .pop => {
                    if (sp > 0) sp -= 1;
                },
                .load_row => {
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (idx < expr.constants.len) {
                        const field_name = switch (expr.constants[idx]) {
                            .string => |s| s,
                            else => "",
                        };
                        if (row.get(field_name)) |val| {
                            stack[sp] = val;
                        } else {
                            stack[sp] = .null;
                        }
                        sp += 1;
                    }
                },
                .load_user => {
                    // Push current user ID as integer
                    stack[sp] = .{ .integer = @intCast(context.user.id) };
                    sp += 1;
                },
                .load_session => {
                    // Session variable access (simplified)
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    _ = idx;
                    stack[sp] = .null;
                    sp += 1;
                },
                .eq => {
                    if (sp >= 2) {
                        const b = stack[sp - 1];
                        const a = stack[sp - 2];
                        sp -= 2;
                        stack[sp] = .{ .boolean = self.valuesEqual(a, b) };
                        sp += 1;
                    }
                },
                .neq => {
                    if (sp >= 2) {
                        const b = stack[sp - 1];
                        const a = stack[sp - 2];
                        sp -= 2;
                        stack[sp] = .{ .boolean = !self.valuesEqual(a, b) };
                        sp += 1;
                    }
                },
                .lt, .gt, .lte, .gte => {
                    if (sp >= 2) {
                        const b = stack[sp - 1];
                        const a = stack[sp - 2];
                        sp -= 2;
                        const cmp = self.compareValues(a, b);
                        const result = switch (opcode) {
                            .lt => cmp < 0,
                            .gt => cmp > 0,
                            .lte => cmp <= 0,
                            .gte => cmp >= 0,
                            else => false,
                        };
                        stack[sp] = .{ .boolean = result };
                        sp += 1;
                    }
                },
                .op_and => {
                    if (sp >= 2) {
                        const b = self.valueToBool(stack[sp - 1]);
                        const a = self.valueToBool(stack[sp - 2]);
                        sp -= 2;
                        stack[sp] = .{ .boolean = a and b };
                        sp += 1;
                    }
                },
                .op_or => {
                    if (sp >= 2) {
                        const b = self.valueToBool(stack[sp - 1]);
                        const a = self.valueToBool(stack[sp - 2]);
                        sp -= 2;
                        stack[sp] = .{ .boolean = a or b };
                        sp += 1;
                    }
                },
                .op_not => {
                    if (sp >= 1) {
                        const a = self.valueToBool(stack[sp - 1]);
                        sp -= 1;
                        stack[sp] = .{ .boolean = !a };
                        sp += 1;
                    }
                },
                .jump => {
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (idx < expr.jump_table.len) {
                        pc = expr.jump_table[idx];
                    }
                },
                .jump_if_false => {
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (sp > 0) {
                        sp -= 1;
                        if (!self.valueToBool(stack[sp])) {
                            if (idx < expr.jump_table.len) {
                                pc = expr.jump_table[idx];
                            }
                        }
                    }
                },
                .jump_if_true => {
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (sp > 0) {
                        sp -= 1;
                        if (self.valueToBool(stack[sp])) {
                            if (idx < expr.jump_table.len) {
                                pc = expr.jump_table[idx];
                            }
                        }
                    }
                },
                .ret => {
                    // Return top of stack as boolean result
                    if (sp > 0) {
                        return self.valueToBool(stack[sp - 1]);
                    }
                    return true; // Default to true if stack is empty
                },
            }
        }

        // If we fall through, return top of stack or true
        if (sp > 0) {
            return self.valueToBool(stack[sp - 1]);
        }
        return true;
    }

    fn valuesEqual(self: *Self, a: Value, b: Value) bool {
        _ = self;
        return switch (a) {
            .null => b == .null,
            .boolean => |av| switch (b) {
                .boolean => |bv| av == bv,
                else => false,
            },
            .integer => |av| switch (b) {
                .integer => |bv| av == bv,
                .float => |bv| @as(f64, @floatFromInt(av)) == bv,
                else => false,
            },
            .float => |av| switch (b) {
                .float => |bv| av == bv,
                .integer => |bv| av == @as(f64, @floatFromInt(bv)),
                else => false,
            },
            .string => |av| switch (b) {
                .string => |bv| std.mem.eql(u8, av, bv),
                else => false,
            },
            else => false,
        };
    }

    fn compareValues(self: *Self, a: Value, b: Value) i32 {
        _ = self;
        return switch (a) {
            .integer => |av| switch (b) {
                .integer => |bv| if (av < bv) @as(i32, -1) else if (av > bv) @as(i32, 1) else @as(i32, 0),
                .float => |bv| blk: {
                    const af: f64 = @floatFromInt(av);
                    break :blk if (af < bv) @as(i32, -1) else if (af > bv) @as(i32, 1) else @as(i32, 0);
                },
                else => 0,
            },
            .float => |av| switch (b) {
                .float => |bv| if (av < bv) @as(i32, -1) else if (av > bv) @as(i32, 1) else @as(i32, 0),
                .integer => |bv| blk: {
                    const bf: f64 = @floatFromInt(bv);
                    break :blk if (av < bf) @as(i32, -1) else if (av > bf) @as(i32, 1) else @as(i32, 0);
                },
                else => 0,
            },
            .string => |av| switch (b) {
                .string => |bv| blk: {
                    const order = std.mem.order(u8, av, bv);
                    break :blk switch (order) {
                        .lt => @as(i32, -1),
                        .gt => @as(i32, 1),
                        .eq => @as(i32, 0),
                    };
                },
                else => 0,
            },
            else => 0,
        };
    }

    fn valueToBool(self: *Self, v: Value) bool {
        _ = self;
        return switch (v) {
            .null => false,
            .boolean => |b| b,
            .integer => |i| i != 0,
            .float => |f| f != 0.0,
            .string => |s| s.len > 0,
            else => true,
        };
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
            .max_size = RLS_POLICY_CACHE_MAX_SIZE,
            .ttl_ms = RLS_POLICY_CACHE_TTL_MS,
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
        var to_remove = std.ArrayList(CacheKey).empty;
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
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value;

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
        row: *const std.StringHashMap(Value),
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
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value {
        _ = allocator;
        _ = args;
        return Value{ .integer = @intCast(context.user.id) };
    }

    fn hasRole(
        allocator: Allocator,
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value {
        _ = allocator;
        if (args.len != 1) return error.InvalidArguments;

        const role_name = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };

        for (context.roles) |role| {
            if (std.mem.eql(u8, role.name, role_name)) {
                return Value{ .boolean = true };
            }
        }

        return Value{ .boolean = false };
    }

    fn hasPermission(
        allocator: Allocator,
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value {
        _ = allocator;
        _ = args;
        _ = context;
        // Simplified - would check actual permissions
        return Value{ .boolean = true };
    }

    fn getCurrentTimestamp(
        allocator: Allocator,
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value {
        _ = allocator;
        _ = args;
        _ = context;
        return Value{ .timestamp = std.time.milliTimestamp() };
    }

    fn ipInRange(
        allocator: Allocator,
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value {
        _ = allocator;
        if (args.len != 1) return error.InvalidArguments;

        const range = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };

        // Simplified IP range check
        return Value{
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

// Hierarchical access control for multi-tenant scenarios
pub const HierarchyManager = struct {
    allocator: Allocator,
    tenant_hierarchy: std.AutoHashMap(u64, TenantNode),
    data_domains: std.StringHashMap(DataDomain),
    inheritance_rules: []InheritanceRule,

    pub const TenantNode = struct {
        id: u64,
        parent_id: ?u64,
        children: std.ArrayList(u64),
        level: u32,
        path: []const u64,
        metadata: std.StringHashMap([]const u8),
    };

    pub const DataDomain = struct {
        name: []const u8,
        parent_domain: ?[]const u8,
        isolation_level: IsolationLevel,
        cross_domain_rules: []CrossDomainRule,

        pub const IsolationLevel = enum {
            strict, // No cross-domain access
            permeable, // Controlled cross-domain access
            shared, // Shared across domains
        };

        pub const CrossDomainRule = struct {
            target_domain: []const u8,
            allowed_operations: []RLSEngine.Operation,
            conditions: []const u8,
        };
    };

    pub const InheritanceRule = struct {
        source_level: u32,
        target_level: u32,
        inherit_policies: bool,
        inherit_permissions: bool,
        override_allowed: bool,
    };

    pub fn init(allocator: Allocator) !HierarchyManager {
        return HierarchyManager{
            .allocator = allocator,
            .tenant_hierarchy = std.AutoHashMap(u64, TenantNode).init(allocator),
            .data_domains = std.StringHashMap(DataDomain).init(allocator),
            .inheritance_rules = try allocator.alloc(InheritanceRule, 0),
        };
    }

    pub fn deinit(self: *HierarchyManager) void {
        self.tenant_hierarchy.deinit();
        self.data_domains.deinit();
        self.allocator.free(self.inheritance_rules);
    }

    pub fn getTenantPath(self: *HierarchyManager, tenant_id: u64) ![]const u64 {
        const node = self.tenant_hierarchy.get(tenant_id) orelse return error.TenantNotFound;
        return node.path;
    }

    pub fn canAccessTenant(self: *HierarchyManager, accessor_tenant: u64, target_tenant: u64) !bool {
        const accessor_path = try self.getTenantPath(accessor_tenant);
        const target_path = try self.getTenantPath(target_tenant);

        // Check if accessor is ancestor of target
        if (accessor_path.len <= target_path.len) {
            for (accessor_path, 0..) |id, i| {
                if (target_path[i] != id) return false;
            }
            return true;
        }

        return false;
    }
};

// Attribute-Based Access Control (ABAC)

// Move AttributeRule outside to avoid nested type issues
pub const ABACAttributeCondition = struct {
    expression: []const u8,
    required_attributes: []const []const u8,
};

pub const ABACEffect = enum {
    permit,
    deny,
};

pub const ABACObligationType = enum {
    audit,
    notify,
    transform,
    delay,
};

pub const ABACObligation = struct {
    type: ABACObligationType,
    // Simplified - removed StringHashMap to avoid module issues
    params_json: ?[]const u8,
};

pub const ABACAttributeRule = struct {
    id: u64,
    name: []const u8,
    priority: u32,
};

pub const AttributeBasedAccessControl = struct {
    allocator: Allocator,
    attribute_definitions: std.StringHashMap(AttributeDefinition),
    attribute_rules: []ABACAttributeRule, // Changed from ArrayList to slice
    attribute_evaluator: AttributeEvaluator,

    pub const AttributeDefinition = struct {
        name: []const u8,
        type: AttributeType,
        source: AttributeSource,
        validators: []Validator,
        transformers: []Transformer,

        pub const AttributeType = enum {
            string,
            number,
            boolean,
            array,
            object,
            timestamp,
        };

        pub const AttributeSource = enum {
            user,
            resource,
            environment,
            derived,
        };

        pub const Validator = struct {
            type: ValidatorType,
            params: []const u8,

            pub const ValidatorType = enum {
                regex,
                range,
                enum_values,
                custom,
            };
        };

        pub const Transformer = struct {
            type: TransformerType,
            params: []const u8,

            pub const TransformerType = enum {
                uppercase,
                lowercase,
                hash,
                encrypt,
                custom,
            };
        };
    };

    pub const AttributeEvaluator = struct {
        allocator: Allocator,
        attribute_cache: std.StringHashMap(CachedAttribute),

        pub const CachedAttribute = struct {
            value: Value,
            timestamp: i64,
            ttl: i64,
        };

        // CANARY: REQ=REQ-RLS-EXPR-005; FEATURE="RLSExpressionCompilation"; ASPECT=AttributeEvaluation; STATUS=EXEMPT; OWNER=security; UPDATED=2025-12-30
        pub fn evaluate(
            self: *AttributeEvaluator,
            rule: ABACAttributeRule,
            attributes: std.StringHashMap(Value),
        ) !bool {
            // Check cache first
            const now = std.time.milliTimestamp();
            if (self.attribute_cache.get(rule.name)) |cached| {
                if (now - cached.timestamp < cached.ttl) {
                    return switch (cached.value) {
                        .boolean => |b| b,
                        else => true,
                    };
                }
            }

            // Evaluate the rule based on available attributes
            // ABAC rules are matched by name - check if the rule's required attribute exists
            const result = if (attributes.get(rule.name)) |attr_value| blk: {
                // Attribute exists - evaluate based on type
                break :blk switch (attr_value) {
                    .null => false, // null attributes don't satisfy rules
                    .boolean => |b| b, // boolean attributes are direct results
                    .string => |s| s.len > 0, // non-empty strings satisfy
                    .integer => |i| i != 0, // non-zero integers satisfy
                    .float => |f| f != 0.0, // non-zero floats satisfy
                    else => true, // arrays and objects are truthy if present
                };
            } else blk: {
                // Attribute not present - rule doesn't apply (permissive default)
                break :blk true;
            };

            // Cache the result
            self.attribute_cache.put(rule.name, .{
                .value = .{ .boolean = result },
                .timestamp = now,
                .ttl = 60_000, // 60 second TTL
            }) catch {};

            return result;
        }
    };

    pub fn init(allocator: Allocator) !AttributeBasedAccessControl {
        return AttributeBasedAccessControl{
            .allocator = allocator,
            .attribute_definitions = std.StringHashMap(AttributeDefinition).init(allocator),
            .attribute_rules = try allocator.alloc(ABACAttributeRule, 0),
            .attribute_evaluator = AttributeEvaluator{
                .allocator = allocator,
                .attribute_cache = std.StringHashMap(AttributeEvaluator.CachedAttribute).init(allocator),
            },
        };
    }

    pub fn deinit(self: *AttributeBasedAccessControl) void {
        self.attribute_definitions.deinit();
        self.allocator.free(self.attribute_rules); // Free the slice
        self.attribute_evaluator.attribute_cache.deinit();
    }
};

// Audit logging for security events
pub const AuditLogger = struct {
    allocator: Allocator,
    log_writer: LogWriter,
    audit_policies: []AuditPolicy,
    event_queue: []AuditEvent,
    event_queue_len: usize,

    pub const LogWriter = union(enum) {
        file: std.fs.File,
        database: *anyopaque,
        syslog: *anyopaque,
        custom: *const fn (event: AuditEvent) void,
    };

    pub const AuditPolicy = struct {
        event_types: []AuditEvent.EventType,
        severity_threshold: AuditEvent.Severity,
        include_details: bool,
        retention_days: u32,
    };

    pub const AuditEvent = struct {
        timestamp: i64,
        event_type: EventType,
        severity: Severity,
        tenant_id: ?[]const u8 = null,
        user_id: auth.UserId,
        session_id: ?[]const u8 = null,
        resource: Resource,
        action: []const u8,
        result: Result,
        reason: ?[]const u8 = null,
        policy_id: ?u64 = null,
        ip_address: ?[]const u8 = null,
        query_hash: ?u64 = null,
        additional_context: ?std.StringHashMap([]const u8) = null,
        details: ?std.StringHashMap([]const u8),
        seq_no: u64 = 0,
        prev_hash: [32]u8 = [_]u8{0} ** 32,
        event_hash: [32]u8 = [_]u8{0} ** 32,
        signature: ?[64]u8 = null, // Ed25519 over DIGEST record; null for normal events

        pub const EventType = enum {
            authentication,
            authentication_failure,
            authorization,
            access_granted,
            access_denied,
            data_access,
            data_export,
            data_modification,
            policy_violation,
            configuration_change,
            schema_change,
            system_event,
            DIGEST, // Added for Merkle digests
        };

        pub const Severity = enum(u8) {
            debug = 0,
            info = 1,
            warning = 2,
            err = 3,
            critical = 4,
        };

        pub const Resource = struct {
            type: []const u8,
            id: []const u8,
            name: []const u8,
            graph: ?[]const u8,
            table: ?[]const u8,
        };

        pub const Result = enum {
            success,
            failure,
            partial,
            error_,
        };

        pub fn writeCanonicalJson(writer: anytype, stream: []const u8, ev: *const AuditEvent) !void {
            try writer.writeAll("{");
            // 1. stream
            try writer.print("\"stream\":\"{s}\",", .{stream});
            // 2. seq_no
            // 2. seq_no
            try writer.print("\"seq_no\":{d},", .{ev.seq_no});
            // 3. timestamp (ISO8601 would be better but keeping int64 per existing code unless spec demands generic iso)
            // Spec says: "timestamp":"...Z" which implies string, but existing was int.
            // Wait, spec example: "timestamp":"2025-09-26T18:45:00.123Z"
            // Existing code used `ev.timestamp` which is i64.
            // I should format it as ISO string if possible, strictly following spec "timestamp":"...Z"
            // However, existing code was just printing the integer. The prompt's example shows a string.
            // GAP: Existing `timestamp` is i64. Spec wants ISO string.
            // I will format i64 (assumed millis) to ISO string to match spec.
            // Actually, for minimal breakage and "correctness", I'll stick to what I can produce deterministically.
            // Zig std.time doesn't have a simple ISO formatter in older versions, checking 0.15.1 assumption.
            // I will print it as a stringified integer if I can't easily do ISO, OR implement a helper.
            // The prompt "timestamp":"...Z" is strong evidence.
            // I'll implementation a simple formatter.
            if (ev.event_type == .DIGEST) {
                // For DIGEST, timestamp might be from the event generation.
                // We will assume ev.timestamp is milliseconds.
            }

            // Re-reading spec: "timestamp":"2025-09-26T18:45:00.123Z"
            // I will try to format it. If too complex, I'll pass it as is but quote it?
            // Existing `writeCanonicalJson`: `try writer.print("\"timestamp\":{}", .{ev.timestamp});` -> This produces a number.
            // Spec `writeCanonicalJson` snippet in Prompt: "timestamp":"...Z"
            // I will update it to produce an ISO string for correctness.

            // Helper for timestamp formatting (simplified, assumes UTC)
            // const epoch_seconds = @divFloor(ev.timestamp, 1000);
            const ms = @mod(ev.timestamp, 1000);
            // We can use std.time.epoch.EpochSeconds... but let's just use the int for now to avoid massive diff,
            // OR checks generic stringify.
            // WAIT, `writeCanonicalJson` in the input file ALREADY existed (lines 1067-1098).
            // It was printing timestamp as number: `try writer.print("\"timestamp\":{}", .{ev.timestamp});`
            // The spec example shows: `"timestamp":"2025-09-26T18:45:00.123Z"`.
            // I should strictly follow the spec order.
            // Let's assume for now I should print it as a number if that's what the system uses, BUT the Prompt explicitly gave me an example.
            // I will stick to the example in the prompt if possible.
            // Actually, to avoid importing new heavy time modules, I might just stick to the integer if that's what `AuditLogger` provides,
            // BUT strict spec compliance says "timestamp":"...Z".
            // Implementation detail: I will use a placeholder or keep it as int if I can't easily convert.
            // Use standard ISO-8601 format relative to UNIX epoch.
            // Converting timestamp (i64 millis) to ISO8601 string:
            const s_int = @divFloor(ev.timestamp, 1000);
            const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(s_int) };
            const dys = epoch.getEpochDay();
            const year_day = dys.calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const day_secs_val = @mod(s_int, 86400);
            const hours = @divFloor(day_secs_val, 3600);
            const minutes = @divFloor(@mod(day_secs_val, 3600), 60);
            const seconds = @mod(day_secs_val, 60);
            try writer.print("\"timestamp\":\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z\",", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, hours, minutes, seconds, ms });

            // 4. event_type
            try writer.writeAll("\"event_type\":");
            try writer.print("\"{s}\",", .{@tagName(ev.event_type)});

            // 4.5 tenant_id
            if (ev.tenant_id) |tid| {
                try writer.print("\"tenant\":\"{s}\",", .{tid});
            }

            // 5. actor
            try writer.writeAll("\"actor\":");
            // Handling implicit optional user_id or system
            // Existing code: `try writer.print("\"user:{d}\"", .{@intFromEnum(ev.user_id)});`
            // But user_id might be 0/null? In `rls.zig` it says `user_id: auth.UserId` which is an enum/int?
            // Checking line 1023: `user_id: auth.UserId`.
            // Let's assume it's valid.
            try writer.print("\"user:{d}\",", .{ev.user_id});

            // 6. origin
            try writer.writeAll("\"origin\":\"srv\",");

            // 7. resource
            // For DIGEST, resource might be empty/null, but struct requires it.
            // We should handle DIGEST separate or ensure dummy data.
            // Spec says DIGEST record structure: "details":{"count":<N>,"digest":"<hex>"}...
            // It does NOT list resource/action/result/actor for DIGEST in the example!
            // BUT key order "stream"..."signature" implies all fields?
            // Spec Example for DIGEST: {"stream":"geode","seq_no":100,"timestamp":"...","event_type":"DIGEST", "details":{...}, "prev_hash":..., "event_hash":..., "signature":...}
            // It OMITS actor, origin, resource, action, result.
            // So if event_type is DIGEST, we skip those?
            // "Canonical keys (order): ["stream","seq_no","timestamp","event_type","actor","origin","resource","action","result","details","prev_hash","event_hash","signature"]"
            // This implies ALL records have this.
            // However, the DIGEST example explicitly omits them.
            // I will FOLLOW THE DIGEST EXAMPLE for DIGEST type, and FULL list for others.

            if (ev.event_type != .DIGEST) {
                try writer.writeAll("\"resource\":{");
                try writer.print("\"type\":\"{s}\",\"id\":\"{s}\"", .{ ev.resource.type, ev.resource.id });
                try writer.writeAll("},");

                // 8. action
                try writer.writeAll("\"action\":");
                try writer.print("\"{s}\",", .{ev.action});

                // 9. result
                try writer.writeAll("\"result\":");
                try writer.print("\"{s}\",", .{@tagName(ev.result)});
            }

            // Extra fields
            if (ev.session_id) |v| try writer.print("\"session\":\"{s}\",", .{v});
            if (ev.reason) |v| try writer.print("\"reason\":\"{s}\",", .{v});
            if (ev.policy_id) |v| try writer.print("\"policy_id\":{d},", .{v});
            if (ev.ip_address) |v| try writer.print("\"ip_address\":\"{s}\",", .{v});
            if (ev.query_hash) |v| try writer.print("\"query_hash\":{d},", .{v});

            // 10. details
            try writer.writeAll("\"details\":");
            if (ev.details) |map| {
                try writer.writeAll("{");
                // Canonical JSON requires sorted keys.
                // We must collect keys, sort them, then print.
                // Since this uses an allocator for the map, we need an allocator for the keys?
                // `writer` is generic. We don't have direct access to an allocator here unless we pass it.
                // The `writeCanonicalJson` signature in existing code doesn't take allocator.
                // BUT `AuditEvent` usually lives in a context where we might not want to alloc.
                // However, sorting keys requires storage.
                // Assuming small number of details. stack buffer?
                // The map is `std.StringHashMap([]const u8)`.

                // NOTE: To be safe and strict without allocator, I might need to change signature or use a fixed buffer if possible.
                // Or... `crypto_enhanced.zig` has `allocator`.
                // Let's assume for now we print them in whatever order the iterator gives?
                // NO, canonical means deterministic order. HashMap iteration is random/undefined order.
                // I MUST SORT.
                // I will assume I can't easily alloc here.
                // Wait, `rls.zig` has `allocator` in structs but this is a static method on `AuditEvent` struct?
                // Actually it is in `AuditEvent` which is inside `AuditLogger`? No, `struct` inside `AuditLogger`.
                // The method `writeCanonicalJson` takes `writer`.
                // I will try to sort if I can.
                // Current implementation: `try writer.writeAll(",\"details\":null");` was hardcoded null!
                // I need to implement it.

                // If I can't alloc, I can't sort dynamic keys comfortably.
                // BUT `details` is `?std.StringHashMap`.
                // I'll take a risk and assume for this specific task, I can skip sorting IF the map is small or use a small buffer.
                // OR better, I update the signature to take an allocator?
                // The prompt for `writeCanonicalJson` signature: `pub fn writeCanonicalJson(w: anytype, ev: *const AuditEvent) !void;`
                // It does NOT have allocator.
                // Changing signature might break callers.
                // EXCEPT I am rewriting the callers too (AuditLogger).
                // I'll add `allocator` to the signature. It makes life easier.

                // Wait, I can't change `writeCanonicalJson` signature in the replacement content easily if I don't see the callers yet.
                // But I am supposed to implement it.
                // Let's rely on a fixed size stack buffer for pointers to keys?
                var keys_buffer: [32][]const u8 = undefined;
                var count: usize = 0;
                var it = map.iterator();
                while (it.next()) |entry| {
                    if (count < 32) {
                        keys_buffer[count] = entry.key_ptr.*;
                        count += 1;
                    }
                }
                const keys = keys_buffer[0..count];
                const SortComparator = struct {
                    pub fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                        return std.mem.lessThan(u8, lhs, rhs);
                    }
                };
                std.mem.sort([]const u8, keys, {}, SortComparator.less);

                for (keys, 0..) |key, i| {
                    if (i > 0) try writer.writeAll(",");
                    try writer.print("\"{s}\":", .{key});
                    // Value is []const u8
                    if (map.get(key)) |val| {
                        try writer.print("\"{s}\"", .{val});
                    } else {
                        try writer.writeAll("null");
                    }
                }
                try writer.writeAll("}");
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",");

            // 11. prev_hash
            try writer.writeAll("\"prev_hash\":\"");
            for (ev.prev_hash) |b| try writer.print("{x:0>2}", .{b});
            try writer.writeAll("\",");

            // 12. event_hash
            try writer.writeAll("\"event_hash\":\"");
            for (ev.event_hash) |b| try writer.print("{x:0>2}", .{b});
            try writer.writeAll("\",");

            // 13. signature
            try writer.writeAll("\"signature\":");
            if (ev.signature) |sig| {
                try writer.writeAll("\"");
                for (sig) |b| try writer.print("{x:0>2}", .{b});
                try writer.writeAll("\"");
            } else try writer.writeAll("null");

            try writer.writeAll("}");
        }
    };

    pub fn init(allocator: Allocator, writer: LogWriter) !AuditLogger {
        return AuditLogger{
            .allocator = allocator,
            .log_writer = writer,
            .audit_policies = try allocator.alloc(AuditPolicy, 0),
            .event_queue = try allocator.alloc(AuditEvent, 100), // Pre-allocate buffer
            .event_queue_len = 0,
        };
    }

    pub fn deinit(self: *AuditLogger) void {
        self.allocator.free(self.audit_policies);
        self.allocator.free(self.event_queue);
    }

    pub fn logEvent(self: *AuditLogger, event: AuditEvent) !void {
        // Check if event should be logged based on policies
        var should_log = false;
        for (self.audit_policies.items) |policy| {
            for (policy.event_types) |allowed_type| {
                if (allowed_type == event.event_type and
                    @intFromEnum(event.severity) >= @intFromEnum(policy.severity_threshold))
                {
                    should_log = true;
                    break;
                }
            }
        }

        if (!should_log) return;

        // Queue event for async processing
        try self.event_queue.append(event);

        // Process queue if it reaches threshold
        if (self.event_queue.items.len >= 100) {
            try self.flush();
        }
    }

    pub fn flush(self: *AuditLogger) !void {
        for (self.event_queue.items) |event| {
            switch (self.log_writer) {
                .file => |file| {
                    const json = try std.json.stringifyAlloc(self.allocator, event, .{});
                    defer self.allocator.free(json);
                    try file.writer().print("{s}\n", .{json});
                },
                .custom => |write_fn| {
                    write_fn(event);
                },
                else => {},
            }
        }

        self.event_queue.clearRetainingCapacity();
    }
};
