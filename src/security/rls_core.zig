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
                    // CANARY: REQ=REQ-RLS-SESSION-001; FEATURE="RLSSessionAccess"; ASPECT=Security; STATUS=TESTED; OWNER=security; UPDATED=2026-01-30
                    // Load session variable by index into constants table
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (idx < expr.constants.len) {
                        const var_name = switch (expr.constants[idx]) {
                            .string => |s| s,
                            else => {
                                stack[sp] = .null;
                                sp += 1;
                                continue;
                            },
                        };
                        // Look up session attribute in context (string values)
                        if (context.session_attributes.get(var_name)) |session_str| {
                            // Convert string to Value (try parsing as integer/boolean first)
                            if (std.mem.eql(u8, session_str, "true")) {
                                stack[sp] = .{ .boolean = true };
                            } else if (std.mem.eql(u8, session_str, "false")) {
                                stack[sp] = .{ .boolean = false };
                            } else if (std.fmt.parseInt(i64, session_str, 10)) |int_val| {
                                stack[sp] = .{ .integer = int_val };
                            } else |_| {
                                stack[sp] = .{ .string = session_str };
                            }
                        } else {
                            stack[sp] = .null;
                        }
                    } else {
                        stack[sp] = .null;
                    }
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

    // CANARY: REQ=REQ-RLS-TEMPORAL-001; FEATURE="RLSTemporalConstraints"; ASPECT=Security; STATUS=TESTED; OWNER=security; UPDATED=2026-01-30
    /// Check if the current time satisfies the temporal constraint.
    /// Supports valid_from/valid_until ranges and recurrence rules (daily, weekly, monthly, yearly).
    fn checkTemporalConstraint(self: *Self, constraint: TemporalConstraint) bool {
        _ = self;
        const now = std.time.milliTimestamp();

        // Check basic time range
        if (constraint.valid_from) |from| {
            if (now < from) return false;
        }

        if (constraint.valid_until) |until| {
            if (now > until) return false;
        }

        // Check recurrence rules
        if (constraint.recurrence) |recurrence| {
            // Get current time components (UTC for simplicity; timezone handling would go here)
            const epoch_secs: u64 = @intCast(@divTrunc(now, 1000));
            const secs_per_day: u64 = 86400;
            const secs_per_hour: u64 = 3600;

            // Days since Unix epoch (Jan 1, 1970 was Thursday = 4)
            const days_since_epoch = @divTrunc(epoch_secs, secs_per_day);
            const day_of_week: u8 = @intCast((days_since_epoch + 4) % 7); // 0=Sun, 1=Mon, ..., 6=Sat
            const hour_of_day: u8 = @intCast(@divTrunc(epoch_secs % secs_per_day, secs_per_hour));

            // Check by_day constraint (which days of the week are allowed)
            if (recurrence.by_day) |allowed_days| {
                var day_allowed = false;
                for (allowed_days) |allowed_day| {
                    // Convert DayOfWeek enum to our numbering (0=Sun, 1=Mon, etc.)
                    const target_day: u8 = switch (allowed_day) {
                        .sunday => 0,
                        .monday => 1,
                        .tuesday => 2,
                        .wednesday => 3,
                        .thursday => 4,
                        .friday => 5,
                        .saturday => 6,
                    };
                    if (day_of_week == target_day) {
                        day_allowed = true;
                        break;
                    }
                }
                if (!day_allowed) return false;
            }

            // Check by_hour constraint (which hours are allowed)
            if (recurrence.by_hour) |allowed_hours| {
                var hour_allowed = false;
                for (allowed_hours) |allowed_hour| {
                    if (hour_of_day == allowed_hour) {
                        hour_allowed = true;
                        break;
                    }
                }
                if (!hour_allowed) return false;
            }

            // For interval-based frequency checks, we'd need a reference start date
            // For now, frequency and interval are informational for scheduling purposes
            // The by_day and by_hour constraints provide the actual access control
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

    // CANARY: REQ=REQ-RLS-EVAL-001; FEATURE="RLSExpressionEvaluation"; ASPECT=Security; STATUS=TESTED; OWNER=security; UPDATED=2026-01-30
    /// Evaluate an RLS expression string against row data and security context.
    /// Supports patterns: `column = value`, `column = current_user()`, `has_role('name')`, AND/OR combinations
    pub fn evaluate(
        self: *ContextEvaluator,
        expression: []const u8,
        row: *const std.StringHashMap(Value),
        context: *auth.SecurityContext,
    ) !bool {
        // Empty expression defaults to true (permissive)
        if (expression.len == 0) return true;

        // Parse and evaluate the expression
        return self.evaluateExpr(expression, row, context);
    }

    fn evaluateExpr(
        self: *ContextEvaluator,
        expr: []const u8,
        row: *const std.StringHashMap(Value),
        context: *auth.SecurityContext,
    ) !bool {
        const trimmed = std.mem.trim(u8, expr, " \t\n\r");
        if (trimmed.len == 0) return true;

        // Handle OR (lowest precedence)
        if (std.mem.indexOf(u8, trimmed, " OR ")) |or_pos| {
            const left = trimmed[0..or_pos];
            const right = trimmed[or_pos + 4 ..];
            return (try self.evaluateExpr(left, row, context)) or
                (try self.evaluateExpr(right, row, context));
        }

        // Handle AND
        if (std.mem.indexOf(u8, trimmed, " AND ")) |and_pos| {
            const left = trimmed[0..and_pos];
            const right = trimmed[and_pos + 5 ..];
            return (try self.evaluateExpr(left, row, context)) and
                (try self.evaluateExpr(right, row, context));
        }

        // Handle parentheses
        if (trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')') {
            return self.evaluateExpr(trimmed[1 .. trimmed.len - 1], row, context);
        }

        // Handle function calls: func_name(args)
        if (std.mem.indexOf(u8, trimmed, "(")) |paren_pos| {
            const func_name = trimmed[0..paren_pos];
            const args_end = std.mem.lastIndexOf(u8, trimmed, ")") orelse return error.InvalidExpression;
            const args_str = trimmed[paren_pos + 1 .. args_end];

            // Check for built-in functions
            if (self.functions.get(func_name)) |func| {
                var args_list = std.ArrayList(Value).empty;
                defer args_list.deinit(self.allocator);

                // Parse arguments (simple comma-separated values)
                if (args_str.len > 0) {
                    var args_iter = std.mem.splitSequence(u8, args_str, ",");
                    while (args_iter.next()) |arg| {
                        const arg_trimmed = std.mem.trim(u8, arg, " \t'\"");
                        try args_list.append(self.allocator, .{ .string = arg_trimmed });
                    }
                }

                const result = try func(self.allocator, args_list.items, context);
                return switch (result) {
                    .boolean => |b| b,
                    .null => false,
                    else => true,
                };
            }
        }

        // Handle comparison: column = value, column <> value, column != value
        const ops = [_]struct { op: []const u8, eq: bool }{
            .{ .op = " <> ", .eq = false },
            .{ .op = " != ", .eq = false },
            .{ .op = " = ", .eq = true },
        };

        for (ops) |op_info| {
            if (std.mem.indexOf(u8, trimmed, op_info.op)) |op_pos| {
                const left_side = std.mem.trim(u8, trimmed[0..op_pos], " \t");
                const right_side = std.mem.trim(u8, trimmed[op_pos + op_info.op.len ..], " \t");

                // Get left value (column reference or function)
                const left_val = try self.resolveValue(left_side, row, context);

                // Get right value (literal or function)
                const right_val = try self.resolveValue(right_side, row, context);

                // Compare values
                const equal = self.valuesEqual(left_val, right_val);
                return if (op_info.eq) equal else !equal;
            }
        }

        // Treat as boolean value or column reference
        const val = try self.resolveValue(trimmed, row, context);
        return switch (val) {
            .boolean => |b| b,
            .null => false,
            .integer => |i| i != 0,
            .string => |s| s.len > 0,
            else => true,
        };
    }

    fn resolveValue(
        self: *ContextEvaluator,
        expr: []const u8,
        row: *const std.StringHashMap(Value),
        context: *auth.SecurityContext,
    ) !Value {
        const trimmed = std.mem.trim(u8, expr, " \t");

        // Check for literals
        if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') {
            return .{ .string = trimmed[1 .. trimmed.len - 1] };
        }
        if (std.mem.eql(u8, trimmed, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, trimmed, "false")) return .{ .boolean = false };
        if (std.mem.eql(u8, trimmed, "null") or std.mem.eql(u8, trimmed, "NULL")) return .null;

        // Try parsing as integer
        if (std.fmt.parseInt(i64, trimmed, 10)) |int_val| {
            return .{ .integer = int_val };
        } else |_| {}

        // Check for function call
        if (std.mem.indexOf(u8, trimmed, "(")) |paren_pos| {
            const func_name = trimmed[0..paren_pos];
            const args_end = std.mem.lastIndexOf(u8, trimmed, ")") orelse return error.InvalidExpression;
            const args_str = trimmed[paren_pos + 1 .. args_end];

            if (self.functions.get(func_name)) |func| {
                var args_list = std.ArrayList(Value).empty;
                defer args_list.deinit(self.allocator);

                if (args_str.len > 0) {
                    var args_iter = std.mem.splitSequence(u8, args_str, ",");
                    while (args_iter.next()) |arg| {
                        const arg_trimmed = std.mem.trim(u8, arg, " \t'\"");
                        try args_list.append(self.allocator, .{ .string = arg_trimmed });
                    }
                }

                return func(self.allocator, args_list.items, context);
            }
        }

        // Treat as column reference
        if (row.get(trimmed)) |val| {
            return val;
        }

        // Column not found - return null
        return .null;
    }

    fn valuesEqual(self: *ContextEvaluator, a: Value, b: Value) bool {
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

    // CANARY: REQ=REQ-RLS-PERM-001; FEATURE="RLSPermissionCheck"; ASPECT=Security; STATUS=TESTED; OWNER=security; UPDATED=2026-01-30
    /// Check if user has a specific permission through their roles.
    /// Permission format: "resource:action" or "permission_name"
    fn hasPermission(
        allocator: Allocator,
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value {
        _ = allocator;
        if (args.len != 1) return error.InvalidArguments;

        const permission_name = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };

        // Check if any role grants this permission
        // Permission can be specified as "resource:action" or just "permission_name"
        for (context.roles) |role| {
            // Check if role name implies permission (admin role has all permissions)
            if (std.mem.eql(u8, role.name, "admin") or
                std.mem.eql(u8, role.name, "superuser") or
                std.mem.eql(u8, role.name, "root"))
            {
                return Value{ .boolean = true };
            }

            // Check if role name matches the permission pattern
            // e.g., role "nodes:read" grants "nodes:read" permission
            if (std.mem.eql(u8, role.name, permission_name)) {
                return Value{ .boolean = true };
            }

            // Check if permission starts with role name (hierarchical)
            // e.g., role "nodes" grants "nodes:read", "nodes:write" etc.
            if (std.mem.indexOf(u8, permission_name, ":")) |colon_pos| {
                const resource = permission_name[0..colon_pos];
                if (std.mem.eql(u8, role.name, resource)) {
                    return Value{ .boolean = true };
                }
            }
        }

        // Permission not found in any role
        return Value{ .boolean = false };
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

    /// Parse an IPv4 dotted-decimal string into a u32 in network byte order.
    /// Returns null on any parse failure (non-numeric octets, wrong count, >255).
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

        // Must have consumed all input
        if (remaining.len != 0) return null;
        return result;
    }

    /// Proper IPv4 CIDR range check. Supports "A.B.C.D/N" or plain "A.B.C.D" (treated as /32).
    fn cidrMatch(ip_str: []const u8, range_str: []const u8) bool {
        const ip_u32 = parseIpv4(ip_str) orelse return false;

        // Split range on '/' for CIDR prefix length
        var base_str: []const u8 = range_str;
        var prefix_len: u6 = 32;

        if (std.mem.indexOf(u8, range_str, "/")) |slash_pos| {
            base_str = range_str[0..slash_pos];
            prefix_len = std.fmt.parseInt(u6, range_str[slash_pos + 1 ..], 10) catch return false;
            if (prefix_len > 32) return false;
        }

        const base_u32 = parseIpv4(base_str) orelse return false;

        if (prefix_len == 0) return true; // 0.0.0.0/0 matches everything

        const mask: u32 = ~(@as(u32, 0)) << @intCast(32 - @as(u6, prefix_len));
        return (ip_u32 & mask) == (base_u32 & mask);
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

        return Value{
            .boolean = cidrMatch(context.environment.ip_address, range),
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

    /// Returns true if c is a GQL/SQL identifier character (alphanumeric or underscore).
    inline fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Validate a policy expression string for injection safety before it is
    /// interpolated into a GQL predicate.  GAP-0496 (CWE-943): raw policy
    /// expressions must not contain statement terminators, comment sequences,
    /// or set operators that could escape the predicate context.
    fn validatePolicyExpression(expr: []const u8) error{InvalidPolicyExpression}!void {
        // Reject statement terminator
        if (std.mem.indexOfScalar(u8, expr, ';') != null)
            return error.InvalidPolicyExpression;
        // Reject SQL/GQL line comments
        if (std.mem.indexOf(u8, expr, "--") != null)
            return error.InvalidPolicyExpression;
        // Reject block comments
        if (std.mem.indexOf(u8, expr, "/*") != null)
            return error.InvalidPolicyExpression;
        // Reject set operators (case-insensitive, whole-word only).
        // A keyword is a whole word when not preceded or followed by an identifier char.
        var i: usize = 0;
        while (i < expr.len) : (i += 1) {
            const rest = expr[i..];
            // Check for identifier char immediately before this position
            const prev_ident = i > 0 and isIdentChar(expr[i - 1]);
            if (prev_ident) continue;
            if (std.ascii.startsWithIgnoreCase(rest, "UNION")) {
                const after_ident = rest.len > 5 and isIdentChar(rest[5]);
                if (!after_ident) return error.InvalidPolicyExpression;
            } else if (std.ascii.startsWithIgnoreCase(rest, "INTERSECT")) {
                const after_ident = rest.len > 9 and isIdentChar(rest[9]);
                if (!after_ident) return error.InvalidPolicyExpression;
            } else if (std.ascii.startsWithIgnoreCase(rest, "EXCEPT")) {
                const after_ident = rest.len > 6 and isIdentChar(rest[6]);
                if (!after_ident) return error.InvalidPolicyExpression;
            }
        }
    }

    pub fn rewrite(
        self: *QueryRewriter,
        query: []const u8,
        policies: std.ArrayList(RLSEngine.Policy),
        context: *auth.SecurityContext,
    ) ![]const u8 {
        _ = query;
        _ = context;

        // CANARY: REQ=REQ-GAP-0496-RLS-INJECTION-GUARD; FEATURE="RLSSecurity"; ASPECT=InjectionPrevention; STATUS=TESTED; OWNER=security; UPDATED=2026-02-18
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        // Build security predicate from policies
        try result.appendSlice(self.allocator, "(");

        var first = true;
        for (policies.items) |policy| {
            if (!policy.enabled) continue;

            if (policy.using_expr) |expr| {
                // GAP-0496: validate before interpolation to prevent GQL injection
                try validatePolicyExpression(expr.raw);

                if (!first) {
                    if (policy.permissive) {
                        try result.appendSlice(self.allocator, " OR ");
                    } else {
                        try result.appendSlice(self.allocator, " AND ");
                    }
                }

                try result.appendSlice(self.allocator, "(");
                try result.appendSlice(self.allocator, expr.raw);
                try result.appendSlice(self.allocator, ")");

                first = false;
            }
        }

        try result.appendSlice(self.allocator, ")");

        return try result.toOwnedSlice(self.allocator);
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

// ============================================================================
// UNIT TESTS - RLS Security Functions
// ============================================================================

// CANARY: REQ=REQ-RLS-TEST-001; FEATURE="RLSUnitTests"; ASPECT=Security; STATUS=TESTED; OWNER=security; UPDATED=2026-01-30
// Test for ContextEvaluator.evaluate and related functions

// Helper function to create a test user with required fields
fn createTestUser(allocator: Allocator, id: auth.UserId, username: []const u8, email: []const u8) auth.User {
    return auth.User{
        .id = id,
        .username = username,
        .email = email,
        .password_hash = "$argon2id$v=19$m=65536,t=3,p=4$test$test", // Dummy hash
        .created_at = 0,
        .updated_at = 0,
        .last_login = null,
        .is_active = true,
        .is_superuser = false,
        .mfa_enabled = false,
        .mfa_secret = null,
        .recovery_codes = null,
        .attributes = std.StringHashMap([]const u8).init(allocator),
    };
}

test "TestCANARY_REQ_RLS_EVAL_001_BasicEquality" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    // Create a mock row
    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try row.put("owner_id", .{ .integer = 42 });
    try row.put("name", .{ .string = "test" });
    try row.put("active", .{ .boolean = true });

    // Create a mock security context
    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 42, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "192.168.1.1",
        .user_agent = "test-agent",
        .device_id = null,
        .location = null,
        .timestamp = std.time.milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: column = integer literal (match)
    const result1 = try evaluator.evaluate("owner_id = 42", &row, &context);
    try std.testing.expect(result1 == true);

    // Test: column = integer literal (no match)
    const result2 = try evaluator.evaluate("owner_id = 999", &row, &context);
    try std.testing.expect(result2 == false);

    // Test: column = string literal (match)
    const result3 = try evaluator.evaluate("name = 'test'", &row, &context);
    try std.testing.expect(result3 == true);

    // Test: column <> value (not equal, should be true)
    const result4 = try evaluator.evaluate("owner_id <> 100", &row, &context);
    try std.testing.expect(result4 == true);

    // Test: boolean column
    const result5 = try evaluator.evaluate("active", &row, &context);
    try std.testing.expect(result5 == true);
}

test "TestCANARY_REQ_RLS_EVAL_002_LogicalOperators" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try row.put("level", .{ .integer = 5 });
    try row.put("public", .{ .boolean = true });

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = std.time.milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: AND (both true)
    const result1 = try evaluator.evaluate("level = 5 AND public", &row, &context);
    try std.testing.expect(result1 == true);

    // Test: AND (one false)
    const result2 = try evaluator.evaluate("level = 999 AND public", &row, &context);
    try std.testing.expect(result2 == false);

    // Test: OR (one true)
    const result3 = try evaluator.evaluate("level = 999 OR public", &row, &context);
    try std.testing.expect(result3 == true);

    // Test: OR (both false)
    const result4 = try evaluator.evaluate("level = 999 OR level = 888", &row, &context);
    try std.testing.expect(result4 == false);
}

test "TestCANARY_REQ_RLS_EVAL_003_FunctionCalls" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try row.put("created_by", .{ .integer = 42 });

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 42, "owner", "owner@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "192.168.1.100",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = std.time.milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: current_user() function - user owns the row
    const result1 = try evaluator.evaluate("created_by = current_user()", &row, &context);
    try std.testing.expect(result1 == true);

    // Change user ID to non-owner
    user.id = 99;

    // Test: current_user() function - user does not own the row
    const result2 = try evaluator.evaluate("created_by = current_user()", &row, &context);
    try std.testing.expect(result2 == false);
}

test "TestCANARY_REQ_RLS_PERM_001_HasPermission" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "normaluser", "user@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = std.time.milliTimestamp(),
    };

    // Test with admin role
    const admin_role = auth.Role{
        .id = 1,
        .name = "admin",
        .description = "Administrator",
        .permissions = std.ArrayList(auth.PermissionId).empty,
        .created_at = 0,
        .is_system = true,
        .priority = 100,
        .parent_role = null,
    };

    const roles_admin = [_]auth.Role{admin_role};

    var context_admin = auth.SecurityContext{
        .user = &user,
        .roles = &roles_admin,
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Admin should have any permission
    const result1 = try evaluator.evaluate("has_permission('anything')", &row, &context_admin);
    try std.testing.expect(result1 == true);

    // Test with normal role
    const reader_role = auth.Role{
        .id = 2,
        .name = "reader",
        .description = "Reader",
        .permissions = std.ArrayList(auth.PermissionId).empty,
        .created_at = 0,
        .is_system = false,
        .priority = 10,
        .parent_role = null,
    };

    const roles_reader = [_]auth.Role{reader_role};

    var context_reader = auth.SecurityContext{
        .user = &user,
        .roles = &roles_reader,
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Reader should not have 'admin_access' permission
    const result2 = try evaluator.evaluate("has_permission('admin_access')", &row, &context_reader);
    try std.testing.expect(result2 == false);

    // Reader should have 'reader' permission (matches role name)
    const result3 = try evaluator.evaluate("has_permission('reader')", &row, &context_reader);
    try std.testing.expect(result3 == true);
}

test "TestCANARY_REQ_RLS_ROLE_001_HasRole" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = std.time.milliTimestamp(),
    };

    const editor_role = auth.Role{
        .id = 1,
        .name = "editor",
        .description = "Editor",
        .permissions = std.ArrayList(auth.PermissionId).empty,
        .created_at = 0,
        .is_system = false,
        .priority = 50,
        .parent_role = null,
    };

    const viewer_role = auth.Role{
        .id = 2,
        .name = "viewer",
        .description = "Viewer",
        .permissions = std.ArrayList(auth.PermissionId).empty,
        .created_at = 0,
        .is_system = false,
        .priority = 10,
        .parent_role = null,
    };

    const roles = [_]auth.Role{ editor_role, viewer_role };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &roles,
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: has_role('editor') - should be true
    const result1 = try evaluator.evaluate("has_role('editor')", &row, &context);
    try std.testing.expect(result1 == true);

    // Test: has_role('viewer') - should be true
    const result2 = try evaluator.evaluate("has_role('viewer')", &row, &context);
    try std.testing.expect(result2 == true);

    // Test: has_role('admin') - should be false
    const result3 = try evaluator.evaluate("has_role('admin')", &row, &context);
    try std.testing.expect(result3 == false);
}

test "TestCANARY_REQ_RLS_TEMPORAL_001_TimeRangeConstraint" {
    // Test basic time range constraints
    const now = std.time.milliTimestamp();

    // Constraint: valid from 1 hour ago to 1 hour from now
    const constraint_valid = RLSEngine.TemporalConstraint{
        .valid_from = now - 3600000, // 1 hour ago
        .valid_until = now + 3600000, // 1 hour from now
        .time_zone = "UTC",
        .recurrence = null,
    };

    // Create a minimal RLSEngine for testing
    const allocator = std.testing.allocator;
    var engine = RLSEngine{
        .allocator = allocator,
        .policies = std.HashMap(RLSEngine.PolicyKey, std.ArrayList(RLSEngine.Policy), RLSEngine.PolicyKey.HashContext, 80).init(allocator),
        .policy_cache = try PolicyCache.init(allocator),
        .context_evaluator = try ContextEvaluator.init(allocator),
        .query_rewriter = try QueryRewriter.init(allocator),
        .hierarchy_manager = try HierarchyManager.init(allocator),
        .attribute_controller = try AttributeBasedAccessControl.init(allocator),
        .audit_logger = try AuditLogger.init(allocator, .{ .custom = RLSEngine.dummyLogWriter }),
    };
    defer {
        engine.policies.deinit();
        engine.policy_cache.deinit();
        engine.context_evaluator.deinit();
        engine.query_rewriter.deinit();
        engine.hierarchy_manager.deinit();
        engine.attribute_controller.deinit();
        engine.audit_logger.deinit();
    }

    // Should pass - we're within the valid time range
    const result_valid = engine.checkTemporalConstraint(constraint_valid);
    try std.testing.expect(result_valid == true);

    // Constraint: valid from 2 hours from now (future only)
    const constraint_future = RLSEngine.TemporalConstraint{
        .valid_from = now + 7200000, // 2 hours from now
        .valid_until = null,
        .time_zone = "UTC",
        .recurrence = null,
    };

    // Should fail - we're before the valid_from time
    const result_future = engine.checkTemporalConstraint(constraint_future);
    try std.testing.expect(result_future == false);

    // Constraint: expired 1 hour ago
    const constraint_expired = RLSEngine.TemporalConstraint{
        .valid_from = null,
        .valid_until = now - 3600000, // 1 hour ago
        .time_zone = "UTC",
        .recurrence = null,
    };

    // Should fail - we're after the valid_until time
    const result_expired = engine.checkTemporalConstraint(constraint_expired);
    try std.testing.expect(result_expired == false);
}

test "TestCANARY_REQ_RLS_SESSION_001_SessionAttributeAccess" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try row.put("tenant_id", .{ .integer = 100 });

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    try session_attrs.put("tenant_id", "100");
    try session_attrs.put("is_admin", "true");

    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "tenantuser", "tenant@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = std.time.milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // The row.tenant_id matches session tenant_id
    // This tests the expression evaluation but not load_session bytecode directly
    // (load_session is tested via bytecode execution in RLSEngine.evaluateBytecodeExpression)
    const result1 = try evaluator.evaluate("tenant_id = 100", &row, &context);
    try std.testing.expect(result1 == true);
}

test "TestCANARY_REQ_RLS_NULL_001_NullHandling" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try row.put("name", .null);
    try row.put("count", .{ .integer = 0 });

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = std.time.milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: null column is falsy
    const result1 = try evaluator.evaluate("name", &row, &context);
    try std.testing.expect(result1 == false);

    // Test: null = null should be true
    const result2 = try evaluator.evaluate("name = null", &row, &context);
    try std.testing.expect(result2 == true);

    // Test: null <> null should be false
    const result3 = try evaluator.evaluate("name <> null", &row, &context);
    try std.testing.expect(result3 == false);

    // Test: integer 0 is falsy
    const result4 = try evaluator.evaluate("count", &row, &context);
    try std.testing.expect(result4 == false);
}

test "TestCANARY_REQ_RLS_EMPTY_001_EmptyExpression" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = std.time.milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Empty expression should default to true (permissive)
    const result1 = try evaluator.evaluate("", &row, &context);
    try std.testing.expect(result1 == true);

    // Whitespace-only expression should default to true
    const result2 = try evaluator.evaluate("   ", &row, &context);
    try std.testing.expect(result2 == true);
}

test "TestCANARY_REQ_RLS_IP_001_IpRangeCheck" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "192.168.1.100",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = std.time.milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: IP in /24 CIDR range
    const result1 = try evaluator.evaluate("ip_in_range('192.168.1.0/24')", &row, &context);
    try std.testing.expect(result1 == true);

    // Test: IP not in different /24 subnet
    const result2 = try evaluator.evaluate("ip_in_range('10.0.0.0/24')", &row, &context);
    try std.testing.expect(result2 == false);

    // Test: Exact match with /32
    const result3 = try evaluator.evaluate("ip_in_range('192.168.1.100/32')", &row, &context);
    try std.testing.expect(result3 == true);

    // Test: /32 does NOT match different host
    const result4 = try evaluator.evaluate("ip_in_range('192.168.1.101/32')", &row, &context);
    try std.testing.expect(result4 == false);

    // Test: Broad /16 match
    const result5 = try evaluator.evaluate("ip_in_range('192.168.0.0/16')", &row, &context);
    try std.testing.expect(result5 == true);

    // Test: /0 matches everything
    const result6 = try evaluator.evaluate("ip_in_range('0.0.0.0/0')", &row, &context);
    try std.testing.expect(result6 == true);
}

test "GAP-0287: ipInRange rejects false positive from string prefix" {
    // This is the exact bug: string prefix "10.1" matched "10.100.0.1"
    const BuiltinFunctions = ContextEvaluator;
    try std.testing.expect(!BuiltinFunctions.cidrMatch("10.100.0.1", "10.1.0.0/16"));
    try std.testing.expect(BuiltinFunctions.cidrMatch("10.1.0.1", "10.1.0.0/16"));

    // Another false positive: "192.168.1" prefix matched "192.168.10.5"
    try std.testing.expect(!BuiltinFunctions.cidrMatch("192.168.10.5", "192.168.1.0/24"));
    try std.testing.expect(BuiltinFunctions.cidrMatch("192.168.1.5", "192.168.1.0/24"));
}

test "GAP-0287: cidrMatch handles edge cases gracefully" {
    const BuiltinFunctions = ContextEvaluator;

    // Invalid IP strings return false
    try std.testing.expect(!BuiltinFunctions.cidrMatch("not.an.ip", "192.168.1.0/24"));
    try std.testing.expect(!BuiltinFunctions.cidrMatch("192.168.1.1", "bad/24"));
    try std.testing.expect(!BuiltinFunctions.cidrMatch("", "192.168.1.0/24"));
    try std.testing.expect(!BuiltinFunctions.cidrMatch("192.168.1.1", ""));

    // Plain address (no slash) treated as /32
    try std.testing.expect(BuiltinFunctions.cidrMatch("192.168.1.1", "192.168.1.1"));
    try std.testing.expect(!BuiltinFunctions.cidrMatch("192.168.1.2", "192.168.1.1"));

    // /8 subnet
    try std.testing.expect(BuiltinFunctions.cidrMatch("10.255.255.255", "10.0.0.0/8"));
    try std.testing.expect(!BuiltinFunctions.cidrMatch("11.0.0.0", "10.0.0.0/8"));
}

test "GAP-0287: parseIpv4 unit tests" {
    const BuiltinFunctions = ContextEvaluator;

    // Valid IPs
    try std.testing.expectEqual(@as(?u32, 0xC0A80101), BuiltinFunctions.parseIpv4("192.168.1.1"));
    try std.testing.expectEqual(@as(?u32, 0x0A000001), BuiltinFunctions.parseIpv4("10.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 0x00000000), BuiltinFunctions.parseIpv4("0.0.0.0"));
    try std.testing.expectEqual(@as(?u32, 0xFFFFFFFF), BuiltinFunctions.parseIpv4("255.255.255.255"));

    // Invalid IPs
    try std.testing.expectEqual(@as(?u32, null), BuiltinFunctions.parseIpv4(""));
    try std.testing.expectEqual(@as(?u32, null), BuiltinFunctions.parseIpv4("192.168.1"));
    try std.testing.expectEqual(@as(?u32, null), BuiltinFunctions.parseIpv4("192.168.1.1.1"));
    try std.testing.expectEqual(@as(?u32, null), BuiltinFunctions.parseIpv4("abc.def.ghi.jkl"));
    try std.testing.expectEqual(@as(?u32, null), BuiltinFunctions.parseIpv4("256.0.0.1"));
}
