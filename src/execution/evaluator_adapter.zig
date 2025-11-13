//! Evaluator Adapter - Dependency Injection Bridge
//!
//! CANARY: REQ=REQ-M5.3-EVALUATOR-ADAPTER-001; FEATURE="Circular Dependency Resolution"; ASPECT=AdapterPattern; STATUS=IMPL; OWNER=architecture; UPDATED=2025-11-13
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

// CANARY: REQ=REQ-M5.3-EXECUTION-CALLBACKS-001; FEATURE="Execution Callbacks"; ASPECT=CallbackInterface; STATUS=IMPL; OWNER=adapter; UPDATED=2025-11-13
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
///     .getDefaultContextFn = execution.getDefaultContext,
///     .executeQueryWithContextFn = execution.executeQueryWithContext,
///     .findShortestPathFn = execution.findShortestPath,
///     .countPatternMatchesFn = execution.countPatternMatches,
///     .executePatternComprehensionFn = execution.executePatternComprehension,
/// };
/// ```
pub const ExecutionCallbacks = struct {
    /// Get default execution context (for legacy code paths)
    getDefaultContextFn: *const fn (allocator: std.mem.Allocator) anyerror!ExecutionContext,

    /// Execute a GQL query with given context
    executeQueryWithContextFn: *const fn (allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) anyerror!ExecutionResult,

    /// Find shortest path(s) matching a graph pattern
    findShortestPathFn: *const fn (allocator: std.mem.Allocator, pattern: ast.GraphPattern, all: bool, env: Env) anyerror!Value,

    /// Count matches for a graph pattern
    countPatternMatchesFn: *const fn (allocator: std.mem.Allocator, pattern: ast.GraphPattern) anyerror!i64,

    /// Execute a pattern comprehension
    executePatternComprehensionFn: *const fn (allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, map_expr: ast.Expr, env: Env) anyerror!Value,

    // CANARY: REQ=REQ-M5.3-CALLBACK-WRAPPER-001; FEATURE="Callback Wrappers"; ASPECT=ConvenienceMethods; STATUS=IMPL; OWNER=adapter; UPDATED=2025-11-13
    /// Convenience wrapper: Get default execution context
    pub fn getDefaultContext(self: ExecutionCallbacks, allocator: std.mem.Allocator) !ExecutionContext {
        return self.getDefaultContextFn(allocator);
    }

    /// Convenience wrapper: Execute query with context
    pub fn executeQueryWithContext(self: ExecutionCallbacks, allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
        return self.executeQueryWithContextFn(allocator, q, context);
    }

    /// Convenience wrapper: Find shortest path
    pub fn findShortestPath(self: ExecutionCallbacks, allocator: std.mem.Allocator, pattern: ast.GraphPattern, all: bool, env: Env) !Value {
        return self.findShortestPathFn(allocator, pattern, all, env);
    }

    /// Convenience wrapper: Count pattern matches
    pub fn countPatternMatches(self: ExecutionCallbacks, allocator: std.mem.Allocator, pattern: ast.GraphPattern) !i64 {
        return self.countPatternMatchesFn(allocator, pattern);
    }

    /// Convenience wrapper: Execute pattern comprehension
    pub fn executePatternComprehension(self: ExecutionCallbacks, allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, map_expr: ast.Expr, env: Env) !Value {
        return self.executePatternComprehensionFn(allocator, pattern, where_filter, map_expr, env);
    }
};

// CANARY: REQ=REQ-M5.3-TYPE-FORWARD-001; FEATURE="Type Forwarding"; ASPECT=OpaqueTypes; STATUS=IMPL; OWNER=adapter; UPDATED=2025-11-13
// Forward declarations as opaque types - the actual definitions are in execution.zig
//
// This approach works because:
// 1. eval.zig only needs to pass these types through callbacks (doesn't access members directly in most cases)
// 2. When eval needs to access members (like result.rows), it's done after receiving the result
// 3. The callback functions handle the actual type conversions
//
// For cases where eval needs to access ExecutionResult members, we'll need to add
// helper functions or make ExecutionResult a proper shared type in a future refactor.
// For now, we use type punning to allow eval.zig to work with the results.

/// Execution context containing catalog and execution state
/// Actual definition in execution.zig - treated as opaque by eval.zig
pub const ExecutionContext = anyopaque;

/// Execution result containing query results
/// Actual definition in execution.zig
/// Note: eval.zig needs to access .rows member, so we provide a minimal definition
pub const ExecutionResult = struct {
    columns: [][]const u8,
    rows: [][]Value,
    flags: std.ArrayList([]const u8),
    owns_value_memory: bool = false,

    pub fn deinit(self: *ExecutionResult, allocator: std.mem.Allocator) void {
        // Note: This is a minimal stub. The real deinit is in execution.zig
        // In practice, the actual ExecutionResult from execution.zig will be used
        _ = self;
        _ = allocator;
    }
};

// CANARY: REQ=REQ-M5.3-EVALUATOR-INTERFACE-001; FEATURE="Evaluator Interface"; ASPECT=EvaluatorAbstraction; STATUS=IMPL; OWNER=adapter; UPDATED=2025-11-13
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

// CANARY: REQ=REQ-M5.3-ADAPTER-INIT-001; FEATURE="Adapter Initialization"; ASPECT=FactoryFunction; STATUS=IMPL; OWNER=adapter; UPDATED=2025-11-13
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

// CANARY: REQ=REQ-M5.3-ADAPTER-DOC-001; FEATURE="Documentation"; ASPECT=UsageExamples; STATUS=IMPL; OWNER=adapter; UPDATED=2025-11-13
/// Example usage pattern for the adapter
///
/// This is a conceptual example showing how the adapter breaks the circular dependency:
///
/// ```zig
/// // In execution.zig:
/// const callbacks = ExecutionCallbacks{
///     .getDefaultContextFn = getDefaultContext,
///     .executeQueryWithContextFn = executeQueryWithContext,
///     .findShortestPathFn = findShortestPath,
///     .countPatternMatchesFn = countPatternMatches,
///     .executePatternComprehensionFn = executePatternComprehension,
/// };
///
/// const evaluator = createEvaluator(eval.evalExprWithCallbacks, callbacks);
///
/// // Now execution.zig can call evalExpr without directly importing eval.zig:
/// const result = try evaluator.evalExpr(allocator, expr, env);
///
/// // In eval.zig:
/// pub fn evalExprWithCallbacks(
///     allocator: std.mem.Allocator,
///     expr: ast.Expr,
///     env: Env,
///     callbacks: ExecutionCallbacks,
/// ) EvalError!Value {
///     // When eval needs to execute a subquery:
///     const context = try callbacks.getDefaultContext(allocator);
///     const result = try callbacks.executeQueryWithContext(allocator, query, context);
///     // No direct import of execution.zig needed!
/// }
/// ```
///
/// Dependency Flow (Before):
/// ```
/// execution.zig ──imports──> eval.zig
///       ↑                         │
///       │                         │
///       └─────────imports─────────┘
///       (CIRCULAR DEPENDENCY)
/// ```
///
/// Dependency Flow (After):
/// ```
/// execution.zig ──imports──> evaluator_adapter.zig <──imports── eval.zig
///       │                                                           │
///       └────provides callbacks at runtime───────────────────────>┘
///       (NO CIRCULAR DEPENDENCY - runtime dependency injection)
/// ```

// ============================================================================
// Module Tests
// ============================================================================

test "ExecutionCallbacks structure" {
    // This test just verifies the structure compiles
    // Actual functionality tested via integration tests
    const TestContext = struct {
        fn mockGetDefaultContext(allocator: std.mem.Allocator) !ExecutionContext {
            _ = allocator;
            return error.Unsupported;
        }

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

        fn mockCountPatterns(allocator: std.mem.Allocator, pattern: ast.GraphPattern) !i64 {
            _ = allocator;
            _ = pattern;
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
        .getDefaultContextFn = TestContext.mockGetDefaultContext,
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
        fn mockGetDefaultContext(allocator: std.mem.Allocator) !ExecutionContext {
            _ = allocator;
            return error.Unsupported;
        }

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

        fn mockCountPatterns(allocator: std.mem.Allocator, pattern: ast.GraphPattern) !i64 {
            _ = allocator;
            _ = pattern;
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
        .getDefaultContextFn = TestContext.mockGetDefaultContext,
        .executeQueryWithContextFn = TestContext.mockExecuteQuery,
        .findShortestPathFn = TestContext.mockFindShortestPath,
        .countPatternMatchesFn = TestContext.mockCountPatterns,
        .executePatternComprehensionFn = TestContext.mockExecutePatternComp,
    };

    const evaluator = createEvaluator(TestEval.mockEvalExpr, callbacks);
    _ = evaluator; // Verify it compiles
}
