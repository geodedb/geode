// CANARY: REQ=REQ-REFACTOR-MATCH-007; FEATURE="MatchOperationsRefactor"; ASPECT=PatternHelpers; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// Pattern matching helper functions extracted from match_operations.zig
/// This module contains shared types and utility functions used across match operations.
const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

// Local type aliases
pub const Value = value_types.Value;
pub const Env = value_types.Env;

// ============================================================================
// CANARY: REQ=REQ-NESTING-REFACTOR-017; FEATURE="NestingReduction"; ASPECT=PropertyConversion; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
// Helper function to convert graph_store.PropertyValue to value_types.Value
// This eliminates duplicate switch statements throughout match_operations.zig
// ============================================================================
pub fn propertyValueToValue(prop_val: graph_store.PropertyValue) Value {
    return switch (prop_val) {
        .Null => Value{ .Null = {} },
        .Bool => |b| Value{ .Bool = b },
        .Int => |i| Value{ .Int = i },
        .String => |s| Value{ .Str = s },
        .Float => |f| Value{ .Double = f },
        .Decimal => |d| Value{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale, .orig_scale = d.scale, .orig_repr = null } },
        .ExtValue => |ext| Value{ .ExtValue = ext },
    };
}

// ============================================================================
// CANARY: REQ=REQ-REFACTOR-MATCH-001; FEATURE="MatchOperationsRefactor"; ASPECT=PatternInfoStruct; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-30
// Struct to hold pattern information extracted from MATCH clause
// ============================================================================
pub const PatternInfo = struct {
    match_variable: ?[]const u8 = null,
    match_labels: [][]const u8 = &.{},
    match_props: ?[]ast.Property = null,
    has_relationship: bool = false,
    rel_type: ?[]const u8 = null,
    left_node_var: ?[]const u8 = null,
    right_node_var: ?[]const u8 = null,
    rel_var: ?[]const u8 = null,
    right_labels: [][]const u8 = &.{},
    right_props: ?[]ast.Property = null,
    var_len_min: ?u32 = null,
    var_len_max: ?u32 = null,
    rel_direction: u8 = 'r', // 'r' for right (forward), 'l' for left (reverse), 'u' for undirected
    chain_path_var: ?[]const u8 = null,
};

// CANARY: REQ=REQ-REFACTOR-MATCH-002; FEATURE="MatchOperationsRefactor"; ASPECT=PatternExtraction; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-30
/// Extract pattern information from MATCH clause chains
/// This consolidates the pattern extraction logic used in executeMatchQueryImpl
pub fn extractPatternInfo(q: ast.Query) PatternInfo {
    var info = PatternInfo{};

    // Get the first chain from the pattern
    if (q.match.chains.len > 0) {
        const chain = q.match.chains[0];
        info.chain_path_var = chain.name;

        // Check if this is a relationship pattern (has hops)
        if (chain.hops.len > 0) {
            info.has_relationship = true;
            const hop = chain.hops[0];

            // Get left node info
            info.left_node_var = hop.left.name;

            // Get relationship info
            info.rel_var = hop.rel.name;
            if (hop.rel.types.len > 0) {
                info.rel_type = hop.rel.types[0];
            }

            // Check for variable-length path pattern
            // CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=PatternExtraction; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // CANARY: REQ=REQ-GQL-VARLEN-REVERSE-002; FEATURE="VariableLengthPaths"; ASPECT=DirectionExtraction; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
            info.var_len_min = hop.rel.min_len;
            info.var_len_max = hop.rel.max_len;

            // Extract relationship direction for variable-length path traversal
            info.rel_direction = switch (hop.rel.dir) {
                .right => 'r',
                .left => 'l',
                .undirected => 'u',
            };

            // Get right node info
            info.right_node_var = hop.right.name;
            info.right_labels = hop.right.labels; // Extract right node labels for filtering
            info.right_props = hop.right.props; // Extract right node properties for filtering

            // Use left node as the main match variable
            info.match_variable = info.left_node_var;
            info.match_labels = hop.left.labels;
            info.match_props = hop.left.props; // Extract left node properties
        } else if (chain.head) |node_pattern| {
            // Simple node pattern without relationships
            info.match_variable = node_pattern.name;
            info.match_labels = node_pattern.labels;
            info.match_props = node_pattern.props; // Extract node properties
        }
    }

    return info;
}

// CANARY: REQ=REQ-REFACTOR-MATCH-004; FEATURE="MatchOperationsRefactor"; ASPECT=SimpleNodeCheck; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-30
/// Check if all chains in the match pattern are simple node patterns (no relationships)
/// CANARY: REQ=REQ-GQL-COMMA-MATCH; FEATURE="CommaSepar atedMatches"; ASPECT=MultipleChains; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-12
pub fn checkAllSimpleNodes(chains: []const ast.Chain) bool {
    for (chains) |chain| {
        if (chain.hops.len > 0 or chain.head == null) {
            return false;
        }
    }
    return true;
}

// CANARY: REQ=REQ-REFACTOR-MATCH-005; FEATURE="MatchOperationsRefactor"; ASPECT=MultiChainDispatch; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-30
/// Dispatch result type for multi-chain handler routing
pub const DispatchResult = union(enum) {
    /// Execute multi-node match (all simple nodes, multiple chains)
    multi_node_match,
    /// Execute multi-chain relationship match (multiple chains with relationships)
    multi_chain_relationship_match,
    /// Execute match with optional patterns (has optional chains)
    match_with_optional_patterns,
    /// Continue with standard single-chain processing
    continue_processing,
};

// CANARY: REQ=REQ-REFACTOR-MATCH-006; FEATURE="MatchOperationsRefactor"; ASPECT=DispatchLogic; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-30
/// Determine which handler to dispatch to for multi-chain patterns
/// Returns the appropriate dispatch result based on chain characteristics
pub fn dispatchToMultiChainHandler(q: ast.Query, all_simple_nodes: bool) DispatchResult {
    // Handle comma-separated node patterns: MATCH (a:Node), (b:Node)
    if (all_simple_nodes and q.match.chains.len > 1) {
        // CANARY: REQ=REQ-GQL-OPTIONAL-NODE-ONLY-003; FEATURE="OptionalMatchNodeOnlyDispatch"; ASPECT=QueryDispatch; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
        // Check if any chain is optional - if so, use executeMatchWithOptionalPatterns
        for (q.match.chains) |chain| {
            if (chain.is_optional) {
                return .match_with_optional_patterns;
            }
        }
        // Handle multiple independent node patterns (all required)
        return .multi_node_match;
    }

    // CANARY: REQ=REQ-GQL-MULTI-CHAIN-REL-002; FEATURE="MultiChainRelationshipMatch"; ASPECT=Dispatch; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
    // Handle multiple chains with relationships that share variables
    // e.g., MATCH (p:Person)-[:WORKS_FOR]->(c:Company), (p)-[:PURCHASED]->(pr:Product)
    if (q.match.chains.len > 1 and !all_simple_nodes) {
        var has_any_optional = false;
        for (q.match.chains) |chain| {
            if (chain.is_optional) {
                has_any_optional = true;
                break;
            }
        }
        if (!has_any_optional) {
            // Multiple required chains with relationships - use join logic
            return .multi_chain_relationship_match;
        }
        // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-HOP-001; FEATURE="OptionalMatchWithHops"; ASPECT=Dispatch; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2026-01-29
        // When first chain has hops and there are optional chains, use executeMatchWithOptionalPatterns
        // This handles: MATCH (a)-[r]->(b) OPTIONAL MATCH (b)-[r2]->(c)
        return .match_with_optional_patterns;
    }

    // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-003; FEATURE="OptionalMatchExecution"; ASPECT=LeftOuterJoin; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
    // Handle MATCH + OPTIONAL MATCH patterns (left outer join)
    // e.g., MATCH (p:Person) OPTIONAL MATCH (p)-[:WORKS_FOR]->(c:Company)
    if (q.match.chains.len >= 2) {
        // Check if we have a mix of required and optional chains
        var has_required = false;
        var has_optional = false;
        var first_required_is_simple = false;
        for (q.match.chains, 0..) |chain, idx| {
            if (chain.is_optional) {
                has_optional = true;
            } else {
                has_required = true;
                if (idx == 0 and chain.head != null and chain.hops.len == 0) {
                    first_required_is_simple = true;
                }
            }
        }

        // Handle MATCH (node) OPTIONAL MATCH (node)-[rel]->(other) pattern
        if (has_required and has_optional and first_required_is_simple) {
            return .match_with_optional_patterns;
        }
    }

    return .continue_processing;
}

// CANARY: REQ=REQ-GQL-MULTINODE-PROPVARREF-002; FEATURE="PropertyPatternVariableReference"; ASPECT=Detection; STATUS=EXEMPT; OWNER=engine; UPDATED=2025-12-26
/// Check if an expression contains a variable reference (e.g., Member like d.name)
/// This is used to detect property patterns like {department: d.name} that can't be
/// evaluated until we have the environment from previous chains.
pub fn containsVariableReference(expr: ast.Expr) bool {
    return switch (expr) {
        .Member => true, // e.g., d.name - target.field
        .PropertyAccess => true, // e.g., n.name - object.property
        .Ident => true, // Bare variable reference
        .Param => false, // $param - resolved from param_values, not from environment
        .Binary => |bin| containsVariableReference(bin.left.*) or containsVariableReference(bin.right.*),
        .Unary => |un| containsVariableReference(un.expr.*),
        .Call => |call| blk: {
            for (call.args) |arg| {
                if (containsVariableReference(arg.*)) break :blk true;
            }
            break :blk false;
        },
        .Case => |case| blk: {
            if (case.operand) |op| {
                if (containsVariableReference(op.*)) break :blk true;
            }
            for (case.whens) |wc| {
                if (containsVariableReference(wc.when.*)) break :blk true;
                if (containsVariableReference(wc.then_expr.*)) break :blk true;
            }
            if (case.else_expr) |ec| {
                if (containsVariableReference(ec.*)) break :blk true;
            }
            break :blk false;
        },
        .List => |list| blk: {
            for (list) |item| {
                if (containsVariableReference(item.*)) break :blk true;
            }
            break :blk false;
        },
        // Literals - no variable references
        .Int, .Decimal, .String, .Bool, .Null, .Map => false,
        // Other cases that might have nested expressions
        else => false,
    };
}

// Helper function to check if a node matches required labels
pub fn matchesLabels(node: *graph_store.Node, required_labels: []const []const u8) bool {
    for (required_labels) |required| {
        var found = false;
        for (node.labels) |label| {
            if (std.mem.eql(u8, required, label)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

// Helper to get expression name for WITH clause
pub fn getWithExpressionName(allocator: std.mem.Allocator, expr: ast.Expr) []const u8 {
    return switch (expr) {
        .Ident => |ident| ident.orig,
        .PropertyAccess => |prop| blk: {
            const combined = std.fmt.allocPrint(allocator, "{s}.{s}", .{ prop.object, prop.property }) catch "prop";
            break :blk combined;
        },
        .Call => |call| switch (call.callee.*) {
            .Ident => |ident| ident.orig,
            else => "expr",
        },
        else => "expr",
    };
}

// E30/E31 Fix: Helper to check if an expression references a specific variable
// CANARY: REQ=REQ-GQL-OPTIONAL-WHERE-VAR-001; FEATURE="OptionalMatchWhereVar"; ASPECT=VarReference; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
pub fn whereExprReferencesVar(expr: ast.Expr, var_name: []const u8) bool {
    return switch (expr) {
        .Ident => |ident| std.mem.eql(u8, ident.orig, var_name),
        .Member => |member| {
            if (member.target.* == .Ident) {
                return std.mem.eql(u8, member.target.Ident.orig, var_name);
            }
            return whereExprReferencesVar(member.target.*, var_name);
        },
        .PropertyAccess => |prop| std.mem.eql(u8, prop.object, var_name),
        .Binary => |binary| whereExprReferencesVar(binary.left.*, var_name) or whereExprReferencesVar(binary.right.*, var_name),
        .Unary => |unary| whereExprReferencesVar(unary.expr.*, var_name),
        .IsNull => |is_null| whereExprReferencesVar(is_null.target.*, var_name),
        .Call => |call| blk: {
            for (call.args) |arg| {
                if (whereExprReferencesVar(arg.*, var_name)) break :blk true;
            }
            break :blk false;
        },
        .Case => |case| blk: {
            if (case.operand) |op| {
                if (whereExprReferencesVar(op.*, var_name)) break :blk true;
            }
            for (case.whens) |wc| {
                if (whereExprReferencesVar(wc.when.*, var_name)) break :blk true;
                if (whereExprReferencesVar(wc.then_expr.*, var_name)) break :blk true;
            }
            if (case.else_expr) |ec| {
                if (whereExprReferencesVar(ec.*, var_name)) break :blk true;
            }
            break :blk false;
        },
        .List => |list| blk: {
            for (list) |item| {
                if (whereExprReferencesVar(item.*, var_name)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

// CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-WITH-002; FEATURE="OptionalMatchWithAggregation"; ASPECT=AggregationComputation; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
// Compute aggregation for a group of rows
pub fn computeAggregationForGroup(allocator: std.mem.Allocator, expr: ast.Expr, group_rows: []const []Value, columns: []const []const u8, param_names: []const []const u8, param_values: []const Value) !Value {
    if (expr != .Call) return Value{ .Null = {} };

    const call = expr.Call;
    if (call.callee.* != .Ident) return Value{ .Null = {} };

    const func_name = call.callee.Ident.orig;
    const arg_ptr: ?*ast.Expr = if (call.args.len > 0) call.args[0] else null;

    // Handle count(*)
    if (std.ascii.eqlIgnoreCase(func_name, "count")) {
        if (arg_ptr == null or (arg_ptr.?.* == .Ident and std.mem.eql(u8, arg_ptr.?.Ident.orig, "*"))) {
            return Value{ .Int = @intCast(group_rows.len) };
        }
        // count(expr) - count non-null values
        var count: i64 = 0;
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            if (val != .Null) count += 1;
        }
        return Value{ .Int = count };
    }

    // CANARY: REQ=REQ-COUNT-DISTINCT-GROUP-001; FEATURE="CountDistinctGroupAggregation"; ASPECT=GroupAggregation; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=engine; UPDATED=2025-12-28
    // C05 Fix: Handle countDistinct(expr) - COUNT(DISTINCT expr) for groups
    if (std.ascii.eqlIgnoreCase(func_name, "countDistinct")) {
        if (arg_ptr == null) return Value{ .Int = 0 };
        var unique_int_values = std.AutoHashMap(i64, void).init(allocator);
        defer unique_int_values.deinit();
        var unique_str_values = std.StringHashMap(void).init(allocator);
        defer unique_str_values.deinit();
        var has_true = false;
        var has_false = false;

        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            switch (val) {
                .Int => |i| {
                    unique_int_values.put(i, {}) catch {};
                },
                .Str => |s| {
                    unique_str_values.put(s, {}) catch {};
                },
                .Bool => |b| {
                    if (b) has_true = true else has_false = true;
                },
                else => {}, // Skip nulls and other types
            }
        }
        const bool_count: usize = (if (has_true) @as(usize, 1) else 0) + (if (has_false) @as(usize, 1) else 0);
        return Value{ .Int = @intCast(unique_int_values.count() + unique_str_values.count() + bool_count) };
    }

    // Handle sum(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "sum")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var sum: i64 = 0;
        var has_value = false;
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            if (val == .Int) {
                sum += val.Int;
                has_value = true;
            }
        }
        return if (has_value) Value{ .Int = sum } else Value{ .Null = {} };
    }

    // Handle min(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "min")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var min: ?i64 = null;
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            if (val == .Int) {
                if (min == null or val.Int < min.?) {
                    min = val.Int;
                }
            }
        }
        return if (min) |m| Value{ .Int = m } else Value{ .Null = {} };
    }

    // Handle max(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "max")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var max: ?i64 = null;
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            if (val == .Int) {
                if (max == null or val.Int > max.?) {
                    max = val.Int;
                }
            }
        }
        return if (max) |m| Value{ .Int = m } else Value{ .Null = {} };
    }

    // CANARY: REQ=REQ-AGG-COLLECT-004; FEATURE="AggregationFunctions"; ASPECT=COLLECT_GROUP; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=engine; UPDATED=2025-12-28
    // B02 Fix: Handle collect(expr) - collect non-NULL values into a list
    if (std.ascii.eqlIgnoreCase(func_name, "collect")) {
        if (arg_ptr == null) return Value{ .List = &.{} };
        var list = std.ArrayList(Value).initCapacity(allocator, group_rows.len) catch return Value{ .List = &.{} };
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            // B02 Fix: Skip NULL values - COLLECT only collects non-NULL values
            if (val != .Null) {
                list.append(allocator, val) catch {};
            }
        }
        return Value{ .List = list.toOwnedSlice(allocator) catch &.{} };
    }

    return Value{ .Null = {} };
}
