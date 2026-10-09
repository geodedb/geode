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

    /// Convenience wrapper: Execute query with environment-scoped context
    pub fn executeQueryWithEnv(self: ExecutionCallbacks, allocator: std.mem.Allocator, q: ast.Query, env: Env) !ExecutionResult {
        // Try env.exec_context first, then fall back to getActiveContext()
        const ctx_ptr: *anyopaque = if (env.exec_context) |ptr|
            ptr
        else if (parent_execution.getActiveContext()) |active_ctx|
            @ptrCast(@constCast(active_ctx))
        else
            return error.Unsupported;
        const ctx: *ExecutionContext = @ptrCast(@alignCast(ctx_ptr));
        // CANARY: REQ=REQ-SONNY-3248-LET-SCOPE; FEATURE="ParameterBinding"; ASPECT=SubqueryParameters; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4_transport.zig; OWNER=engine; UPDATED=2026-09-29
        // SONNY-3248 (round 4b-1b review I-E): the subquery (`x IN (MATCH
        // ...)`) sees the parameters the expression around it sees: the
        // request's, with the statement's LETs (and CTEs) bound over them
        // (`env`'s). It ran with the context's, the request's alone, so an
        // outer `LET $x` read null (and `param_check` refused it), while an
        // EXISTS body, evaluated with `env`, read it.
        if (env.param_names.len == 0) return self.executeQueryWithContext(allocator, q, ctx.*);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(allocator);
        var values: std.ArrayList(Value) = .empty;
        defer values.deinit(allocator);
        try names.appendSlice(allocator, ctx.query_param_names);
        try values.appendSlice(allocator, ctx.query_param_values);
        for (env.param_names, env.param_values) |name, value| {
            for (names.items, 0..) |existing, i| {
                if (std.mem.eql(u8, existing, name)) {
                    values.items[i] = value;
                    break;
                }
            } else {
                try names.append(allocator, name);
                try values.append(allocator, value);
            }
        }
        var sub_ctx = ctx.*;
        sub_ctx.query_param_names = names.items;
        sub_ctx.query_param_values = values.items;
        return self.executeQueryWithContext(allocator, q, sub_ctx);
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
