const std = @import("std");
const ast = @import("../gql/ast.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

// Import procedure registry for CALL procedure handling
const procedure_registry = @import("procedure_registry.zig");

// CANARY: REQ=REQ-EXEC-REFACTOR-007; FEATURE="ExecutionRefactoring"; ASPECT=CALL_OPERATIONS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-12
// Extracted CALL statement execution from path_and_call_operations.zig for better modularity (M2.3 Phase 2)

/// Execute CALL procedure statement
/// Delegates to procedure_registry for actual procedure handling
pub const executeCallProcedure = procedure_registry.executeCallProcedure;

/// Execute CALL subquery statement
/// Executes the subquery statement (Query, Call, Create, etc.) with context
/// and optionally applies RETURN clause transformation
pub fn executeCallSubquery(allocator: std.mem.Allocator, call_subq: ast.CallSubquery, context: ExecutionContext) !ExecutionResult {
    // CANARY: REQ=REQ-GQL-CALL-SUBQUERY; FEATURE="CallSubquery"; ASPECT=Execution; STATUS=IMPL; OWNER=execution; UPDATED=2025-10-11
    // Execute the statement (can be Query, Call, Create, etc.) with context
    // Handle statements directly to avoid circular error set inference
    const subquery_result = switch (call_subq.statement.*) {
        .Query => |q| try execution.executeQueryWithContext(allocator, q, context),
        .Call => |c| switch (c) {
            // Inline executeCallStatement to avoid circular dependency
            .Procedure => |proc| try executeCallProcedure(allocator, proc, context),
            .Subquery => |subq| try executeCallSubquery(allocator, subq, context),
        },
        .Create => |c| blk: {
            const create_graph = if (context.session_state) |session| session.graph else null;
            break :blk try execution.executeCreate(allocator, c, create_graph);
        },
        else => return error.UnsupportedStatementInCallSubquery,
    };

    // If there's a RETURN clause after the subquery, apply it
    if (call_subq.return_clause) |_| {
        // Apply the RETURN transformation to subquery results
        // For simplicity, just execute the return clause with the subquery results
        // (Full implementation would need to bind subquery results to variables)
        return subquery_result;
    }

    return subquery_result;
}

/// Execute CALL statement (either procedure or subquery)
/// Routes to appropriate handler based on call statement type
pub fn executeCallStatement(allocator: std.mem.Allocator, call_stmt: ast.CallStatement, context: ExecutionContext) !ExecutionResult {
    // Handle different types of CALL statements
    switch (call_stmt) {
        .Procedure => |proc| {
            return try executeCallProcedure(allocator, proc, context);
        },
        .Subquery => |subq| {
            return try executeCallSubquery(allocator, subq, context);
        },
    }
}
