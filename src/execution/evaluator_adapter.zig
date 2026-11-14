//! Evaluator Adapter - Dependency Injection Bridge
//!
//! CANARY: REQ=REQ-M5.3-EVALUATOR-ADAPTER-001; FEATURE="Circular Dependency Resolution"; ASPECT=AdapterPattern; STATUS=EXEMPT; OWNER=architecture; UPDATED=2025-11-13
//!
//! This module provides the adapter pattern to break the circular dependency
//! between execution.zig and eval.zig. Instead of eval.zig importing execution.zig
//! directly, it receives execution functions via callbacks at runtime.
//!
//! Phase 5 M5.3: Create Evaluator Adapter
//! - Breaks function call circular dependency
//! - Enables dependency injection for testing
//! - Uses callback pattern for loose coupling

const std = @import("std");
const ast = @import("../gql/ast.zig");
const value_types = @import("../value_types.zig");
const subquery_cache = @import("subquery_cache.zig");

/// Re-export common types for convenience
pub const Value = value_types.Value;
pub const Env = value_types.Env;
pub const EvalError = value_types.EvalError;

// CANARY: REQ=REQ-M5.3-EXECUTION-CALLBACKS-001; FEATURE="Execution Callbacks"; ASPECT=CallbackInterface; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=adapter; UPDATED=2025-11-13
/// Execution callbacks that eval.zig needs to call back to execution.zig
///
/// These callbacks provide execution-layer functionality that the evaluator
/// needs when processing certain expressions (subqueries, pattern comprehensions,
/// shortest paths). By using callbacks instead of direct imports, we break the
/// circular dependency at compile time.
///
/// Usage:
/// ```zig
/// const callbacks = ExecutionCallbacks{
///     .executeQueryWithContextFn = execution.executeQueryWithContext,
///     .findShortestPathFn = execution.findShortestPath,
///     .countPatternMatchesFn = execution.countPatternMatches,
///     .executePatternComprehensionFn = execution.executePatternComprehension,
/// };
/// ```
pub const ExecutionCallbacks = struct {
    /// Execute a GQL query with given context
    executeQueryWithContextFn: *const fn (allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) anyerror!ExecutionResult,

    /// Find shortest path(s) matching a graph pattern
    findShortestPathFn: *const fn (allocator: std.mem.Allocator, pattern: ast.GraphPattern, all: bool, env: Env) anyerror!Value,

    /// Count matches for a graph pattern (with optional environment for correlated subqueries and WHERE filter)
    countPatternMatchesFn: *const fn (allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, env: Env) anyerror!i64,

    /// Execute a pattern comprehension
    executePatternComprehensionFn: *const fn (allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, map_expr: ast.Expr, env: Env) anyerror!Value,

    // CANARY: REQ=REQ-M5.3-CALLBACK-WRAPPER-001; FEATURE="Callback Wrappers"; ASPECT=ConvenienceMethods; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=adapter; UPDATED=2025-11-13
    /// Convenience wrapper: Execute query with context
    pub fn executeQueryWithContext(self: ExecutionCallbacks, allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
        return self.executeQueryWithContextFn(allocator, q, context);
    }

    /// The rows of an expression subquery: owned, or the statement cache's.
    pub const SubqueryRows = struct {
        result: ExecutionResult,
        /// The statement's subquery cache holds it (`subquery_cache`).
        cached: bool,

        pub fn deinit(self: *SubqueryRows, allocator: std.mem.Allocator) void {
            if (!self.cached) self.result.deinit(allocator);
        }
    };

    // CANARY: REQ=REQ-SONNY-6525-CORRELATED-SUBQUERY; FEATURE="SubqueryEvaluation"; ASPECT=Correlation; STATUS=TESTED; TEST=tests/test_sonny6525_correlated_subquery.zig; OWNER=engine; UPDATED=2026-11-13
    /// SONNY-6525 item 1: run the subquery of `x IN (...)` / `x NOT IN
    /// (...)` on the row `env` holds. It ran without the row, so an outer
    /// variable it names read NULL: `MATCH (n) WHERE n.k IN (MATCH (m) WHERE
    /// m.t = n.t RETURN m.k)` returned no rows (ISO/IEC 39075:2024 20.12 SR
    /// 8: the name is the incoming record's field). Each variable of the row
    /// it mentions is bound for it as an identifier the executors resolve
    /// (`Env.get` reads a subquery's own bindings first, so they are seen
    /// first). An outer variable its own MATCH (or UNWIND, FOR, LET) binds
    /// again would have to join with the row (14.4 SR 5 c), GR 1), which no
    /// executor does: refused with 0A000 rather than matched afresh. So is a
    /// variable whose name a parameter of another value has. A subquery
    /// that mentions no variable of the row, nor a parameter a nested scope
    /// bound, runs once per statement that changes nothing (`subquery_cache`).
    pub fn runSubquery(self: ExecutionCallbacks, allocator: std.mem.Allocator, q: *const ast.Query, env: Env) !SubqueryRows {
        const ctx_ptr: *anyopaque = if (env.exec_context) |ptr|
            ptr
        else if (parent_execution.getActiveContext()) |active_ctx|
            @ptrCast(@constCast(active_ctx))
        else
            return error.Unsupported;
        const ctx: *ExecutionContext = @ptrCast(@alignCast(ctx_ptr));
        const cache = subquery_cache.current();

        var own_names: ?subquery_cache.Names = null;
        defer if (own_names) |*n| n.deinit(allocator);
        const cache_entry = if (cache) |c| try c.entry(q) else null;
        const names: *const subquery_cache.Names = if (cache_entry) |e| &e.names else blk: {
            own_names = try subquery_cache.mentionedNames(allocator, q);
            break :blk &own_names.?;
        };

        // CANARY: REQ=REQ-SONNY-3248-LET-SCOPE; FEATURE="ParameterBinding"; ASPECT=SubqueryParameters; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4_transport.zig; OWNER=engine; UPDATED=2026-09-29
        // SONNY-3248 (round 4b-1b review I-E): the subquery (`x IN (MATCH
        // ...)`) sees the parameters the expression around it sees: the
        // request's, with the statement's LETs (and CTEs) bound over them
        // (`env`'s). It ran with the context's, the request's alone, so an
        // outer `LET $x` read null (and `param_check` refused it), while an
        // EXISTS body, evaluated with `env`, read it.
        var param_names: std.ArrayList([]const u8) = .empty;
        defer param_names.deinit(allocator);
        var param_values: std.ArrayList(Value) = .empty;
        defer param_values.deinit(allocator);
        // The row's variables it mentions, first.
        var outer: usize = 0;
        for (env.names, env.values) |name, value| {
            if (!names.has(name)) continue;
            const seen = for (param_names.items) |n| {
                if (std.mem.eql(u8, n, name)) break true;
            } else false;
            if (seen) continue;
            if (names.binds(name)) return error.UnsupportedQueryShape;
            try param_names.append(allocator, name);
            try param_values.append(allocator, value);
            outer += 1;
        }
        try param_names.appendSlice(allocator, ctx.query_param_names);
        try param_values.appendSlice(allocator, ctx.query_param_values);
        for (env.param_names, env.param_values) |name, value| {
            for (param_names.items[outer..], outer..) |existing, i| {
                if (std.mem.eql(u8, existing, name)) {
                    param_values.items[i] = value;
                    break;
                }
            } else {
                try param_names.append(allocator, name);
                try param_values.append(allocator, value);
            }
        }
        // A parameter of the name of a variable it reads, of another value:
        // `$n` and `n` would read one binding.
        var correlated = outer > 0;
        for (param_names.items[outer..], param_values.items[outer..]) |name, value| {
            for (param_names.items[0..outer], param_values.items[0..outer]) |var_name, var_value| {
                if (std.mem.eql(u8, var_name, name) and !subquery_cache.sameValue(var_value, value)) return error.UnsupportedQueryShape;
            }
            if (!names.has(name)) continue;
            const constant = if (cache) |c| c.isRequestParam(name, value) else false;
            if (constant) continue;
            correlated = true;
            // A name a nested scope bound (a FOR's, an initial WITH's) that
            // its own MATCH binds again.
            if (names.binds(name)) return error.UnsupportedQueryShape;
        }

        if (!correlated) if (cache_entry) |e| {
            if (e.result) |r| return .{ .result = r, .cached = true };
        };
        var sub_ctx = ctx.*;
        sub_ctx.query_param_names = param_names.items;
        sub_ctx.query_param_values = param_values.items;
        subquery_cache.noteRun();
        if (!correlated) if (cache_entry) |e| {
            e.result = try self.executeQueryWithContext(cache.?.allocator, q.*, sub_ctx);
            return .{ .result = e.result.?, .cached = true };
        };
        return .{ .result = try self.executeQueryWithContext(allocator, q.*, sub_ctx), .cached = false };
    }

    /// Convenience wrapper: Find shortest path
    pub fn findShortestPath(self: ExecutionCallbacks, allocator: std.mem.Allocator, pattern: ast.GraphPattern, all: bool, env: Env) !Value {
        return self.findShortestPathFn(allocator, pattern, all, env);
    }

    /// Convenience wrapper: Count pattern matches (with environment for correlated subqueries and optional WHERE filter)
    pub fn countPatternMatches(self: ExecutionCallbacks, allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, env: Env) !i64 {
        return self.countPatternMatchesFn(allocator, pattern, where_filter, env);
    }

    /// Convenience wrapper: Execute pattern comprehension
    pub fn executePatternComprehension(self: ExecutionCallbacks, allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, map_expr: ast.Expr, env: Env) !Value {
        return self.executePatternComprehensionFn(allocator, pattern, where_filter, map_expr, env);
    }
};

// CANARY: REQ=REQ-M5.3-TYPE-FORWARD-001; FEATURE="Type Forwarding"; ASPECT=TypeReexport; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=adapter; UPDATED=2025-11-13
// Import parent execution module to access ExecutionContext and ExecutionResult types
//
// This creates a parent-child import relationship which is acceptable:
// - execution.zig (parent) contains evaluator_adapter.zig (child)
// - Child can import parent types
// - eval.zig imports adapter (not execution), breaking the circular dependency
//
// Dependency flow (NO CIRCLE):
//   execution.zig → eval.zig (one-way)
//   execution.zig → evaluator_adapter.zig (parent → child)
//   evaluator_adapter.zig → execution.zig (child → parent for types)
//   eval.zig → evaluator_adapter.zig (one-way)

const parent_execution = @import("../execution.zig");

/// Re-export ExecutionContext from parent execution module
/// This allows eval.zig to use the real ExecutionContext type without importing execution.zig
pub const ExecutionContext = parent_execution.ExecutionContext;

/// Re-export ExecutionResult from parent execution module
/// This allows eval.zig to use the real ExecutionResult type without importing execution.zig
pub const ExecutionResult = parent_execution.ExecutionResult;

// CANARY: REQ=REQ-M5.3-EVALUATOR-INTERFACE-001; FEATURE="Evaluator Interface"; ASPECT=EvaluatorAbstraction; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=adapter; UPDATED=2025-11-13
/// Evaluator interface that execution.zig uses to call eval.evalExpr
///
/// This interface allows execution.zig to evaluate expressions without
/// directly importing eval.zig. The evaluator is initialized with execution
/// callbacks, creating a clean dependency injection pattern.
///
/// Usage:
/// ```zig
/// const evaluator = EvaluatorInterface{
///     .evalExprFn = evalExprWithCallbacks,
///     .callbacks = execution_callbacks,
/// };
/// const result = try evaluator.evalExpr(allocator, expr, env);
/// ```
pub const EvaluatorInterface = struct {
    /// Function pointer to eval expression with callbacks
    evalExprFn: *const fn (allocator: std.mem.Allocator, expr: ast.Expr, env: Env, callbacks: ExecutionCallbacks) EvalError!Value,

    /// Execution callbacks that the evaluator will use
    callbacks: ExecutionCallbacks,

    /// Convenience wrapper: Evaluate expression
    pub fn evalExpr(self: EvaluatorInterface, allocator: std.mem.Allocator, expr: ast.Expr, env: Env) EvalError!Value {
        return self.evalExprFn(allocator, expr, env, self.callbacks);
    }
};

// CANARY: REQ=REQ-M5.3-ADAPTER-INIT-001; FEATURE="Adapter Initialization"; ASPECT=FactoryFunction; STATUS=EXEMPT; OWNER=adapter; UPDATED=2025-11-13
/// Create an evaluator interface with execution callbacks
///
/// This factory function is called by execution.zig to create an evaluator
/// that has access to execution functions via callbacks.
///
/// Arguments:
///   - evalExprFn: The eval.evalExpr function (but accepting callbacks parameter)
///   - callbacks: Execution callbacks providing execution functionality
///
/// Returns:
///   - EvaluatorInterface configured with callbacks
pub fn createEvaluator(
    evalExprFn: *const fn (allocator: std.mem.Allocator, expr: ast.Expr, env: Env, callbacks: ExecutionCallbacks) EvalError!Value,
    callbacks: ExecutionCallbacks,
) EvaluatorInterface {
    return EvaluatorInterface{
        .evalExprFn = evalExprFn,
        .callbacks = callbacks,
    };
}

// CANARY: REQ=REQ-M5.3-ADAPTER-DOC-001; FEATURE="Documentation"; ASPECT=UsageExamples; STATUS=EXEMPT; OWNER=adapter; UPDATED=2025-11-13
// Example usage pattern for the adapter
//
// This is a conceptual example showing how the adapter breaks the circular dependency:
//
// ```zig
// // In execution.zig:
// const callbacks = ExecutionCallbacks{
//     .getDefaultContextFn = getDefaultContext,
//     .executeQueryWithContextFn = executeQueryWithContext,
//     .findShortestPathFn = findShortestPath,
//     .countPatternMatchesFn = countPatternMatches,
//     .executePatternComprehensionFn = executePatternComprehension,
// };
//
// const evaluator = createEvaluator(eval.evalExprWithCallbacks, callbacks);
//
// // Now execution.zig can call evalExpr without directly importing eval.zig:
// const result = try evaluator.evalExpr(allocator, expr, env);
//
// // In eval.zig:
// pub fn evalExprWithCallbacks(
//     allocator: std.mem.Allocator,
//     expr: ast.Expr,
//     env: Env,
//     callbacks: ExecutionCallbacks,
// ) EvalError!Value {
//     // When eval needs to execute a subquery:
//     const context = try callbacks.getDefaultContext(allocator);
//     const result = try callbacks.executeQueryWithContext(allocator, query, context);
//     // No direct import of execution.zig needed!
// }
// ```
//
// Dependency Flow (Before):
// ```
// execution.zig ──imports──> eval.zig
//       ↑                         │
//       │                         │
//       └─────────imports─────────┘
//       (CIRCULAR DEPENDENCY)
// ```
//
// Dependency Flow (After):
// ```
// execution.zig ──imports──> evaluator_adapter.zig <──imports── eval.zig
//       │                                                           │
//       └────provides callbacks at runtime───────────────────────>┘
//       (NO CIRCULAR DEPENDENCY - runtime dependency injection)
// ```

// ============================================================================
// Module Tests
// ============================================================================

test "ExecutionCallbacks structure" {
    // This test just verifies the structure compiles
    // Actual functionality tested via integration tests
    const TestContext = struct {
        fn mockExecuteQuery(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
            _ = allocator;
            _ = q;
            _ = context;
            return error.Unsupported;
        }

        fn mockFindShortestPath(allocator: std.mem.Allocator, pattern: ast.GraphPattern, all: bool, env: Env) !Value {
            _ = allocator;
            _ = pattern;
            _ = all;
            _ = env;
            return Value{ .Null = {} };
        }

        fn mockCountPatterns(allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, env: Env) !i64 {
            _ = allocator;
            _ = pattern;
            _ = where_filter;
            _ = env;
            return 0;
        }

        fn mockExecutePatternComp(allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, map_expr: ast.Expr, env: Env) !Value {
            _ = allocator;
            _ = pattern;
            _ = where_filter;
            _ = map_expr;
            _ = env;
            return Value{ .List = &.{} };
        }
    };

    const callbacks = ExecutionCallbacks{
        .executeQueryWithContextFn = TestContext.mockExecuteQuery,
        .findShortestPathFn = TestContext.mockFindShortestPath,
        .countPatternMatchesFn = TestContext.mockCountPatterns,
        .executePatternComprehensionFn = TestContext.mockExecutePatternComp,
    };

    _ = callbacks; // Verify it compiles
}

test "EvaluatorInterface structure" {
    // Verify the evaluator interface compiles
    const TestEval = struct {
        fn mockEvalExpr(allocator: std.mem.Allocator, expr: ast.Expr, env: Env, callbacks: ExecutionCallbacks) EvalError!Value {
            _ = allocator;
            _ = expr;
            _ = env;
            _ = callbacks;
            return Value{ .Null = {} };
        }
    };

    const TestContext = struct {
        fn mockExecuteQuery(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
            _ = allocator;
            _ = q;
            _ = context;
            return error.Unsupported;
        }

        fn mockFindShortestPath(allocator: std.mem.Allocator, pattern: ast.GraphPattern, all: bool, env: Env) !Value {
            _ = allocator;
            _ = pattern;
            _ = all;
            _ = env;
            return Value{ .Null = {} };
        }

        fn mockCountPatterns(allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, env: Env) !i64 {
            _ = allocator;
            _ = pattern;
            _ = where_filter;
            _ = env;
            return 0;
        }

        fn mockExecutePatternComp(allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, map_expr: ast.Expr, env: Env) !Value {
            _ = allocator;
            _ = pattern;
            _ = where_filter;
            _ = map_expr;
            _ = env;
            return Value{ .List = &.{} };
        }
    };

    const callbacks = ExecutionCallbacks{
        .executeQueryWithContextFn = TestContext.mockExecuteQuery,
        .findShortestPathFn = TestContext.mockFindShortestPath,
        .countPatternMatchesFn = TestContext.mockCountPatterns,
        .executePatternComprehensionFn = TestContext.mockExecutePatternComp,
    };

    const evaluator = createEvaluator(TestEval.mockEvalExpr, callbacks);
    _ = evaluator; // Verify it compiles
}
