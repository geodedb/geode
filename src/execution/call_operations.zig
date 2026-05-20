const std = @import("std");
const ast = @import("../gql/ast.zig");
const graph_store = @import("../graph_store.zig");
const query_traits = @import("../query/query_traits.zig");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

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

/// Public accessor for the global CDC engine (used by gRPC transport).
pub const getGlobalCdcEngine = procedure_registry.getGlobalCdcEngine;

/// Public accessor for the CDC mutex (used by gRPC transport for thread-safe CDC access).
pub const getCdcMutex = procedure_registry.getCdcMutex;

/// Execute CALL subquery statement
/// Executes the subquery statement (Query, Call, Create, etc.) with context
/// and optionally applies RETURN clause transformation
pub fn executeCallSubquery(allocator: std.mem.Allocator, call_subq: ast.CallSubquery, context: ExecutionContext) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-GQL-CALL-SUBQUERY; FEATURE="CallSubquery"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-10-11
    // Execute the statement (can be Query, Call, Create, etc.) with context
    // Handle statements directly to avoid circular error set inference
    const subquery_result = switch (call_subq.statement.*) {
        .Query => |q| try execution.executeQueryWithContext(allocator, q, context),
        .Call => |c| try executeCallStatement(allocator, c, context),
        .Create => |c| blk: {
            const create_graph = if (context.session_state) |session| session.graph else null;
            break :blk try execution.executeCreate(allocator, c, create_graph, context);
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

fn executeCallUnsnapshotted(allocator: std.mem.Allocator, call_stmt: ast.CallStatement, context: ExecutionContext) anyerror!ExecutionResult {
    return switch (call_stmt) {
        .Procedure => |proc| try executeCallProcedure(allocator, proc, context),
        .Subquery => |subq| try executeCallSubquery(allocator, subq, context),
    };
}

/// Execute CALL statement (either procedure or subquery)
/// Routes to appropriate handler based on call statement type
pub fn executeCallStatement(allocator: std.mem.Allocator, call_stmt: ast.CallStatement, context: ExecutionContext) anyerror!ExecutionResult {
    if (query_traits.isMutatingCallStatement(&call_stmt)) {
        return try executeCallUnsnapshotted(allocator, call_stmt, context);
    }

    const store = graph_store.getWritableGlobalStore(allocator);
    var read_session = try graph_store.QueryReadSession.initIfAvailable(allocator, store);
    if (read_session) |*session| {
        defer session.deinit();
        const prev_store = graph_store.pushActiveQueryReadStore(session.store());
        defer graph_store.popActiveQueryReadStore(prev_store);
        return try executeCallUnsnapshotted(allocator, call_stmt, context);
    }

    return try executeCallUnsnapshotted(allocator, call_stmt, context);
}

const Parser = @import("../gql/parser.zig").Parser;
const Lexer = @import("../gql/lexer.zig").Lexer;
const Catalog = @import("../schema/catalog.zig").Catalog;
const testing = std.testing;

fn parseCallStatement(src: []const u8) !struct { ast.CallStatement, std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();

    var lx = Lexer{ .src = src };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();
    if (program.statements.len != 1) return error.InvalidStatement;

    return switch (program.statements[0]) {
        .Call => |call_stmt| .{ call_stmt, arena },
        else => error.InvalidStatement,
    };
}

test "executeCallStatement routes read-only procedures through QueryReadSession" {
    graph_store.deinitGlobalStore();
    defer graph_store.deinitGlobalStore();

    var store_tmp = testing.tmpDir(.{});
    defer store_tmp.cleanup();

    const store_dir = try tmpDirRealpathAlloc(testing.allocator, &store_tmp.sub_path);
    defer testing.allocator.free(store_dir);

    const store = try graph_store.initGlobalStore(testing.allocator, store_dir);
    var labels = [_][]const u8{"Person"};
    const alice = try store.createNodeWithGraph(&labels, "default");
    const bob = try store.createNodeWithGraph(&labels, "default");
    _ = try store.createEdge(alice, bob, "KNOWS");

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    try adapter.checkpointAll();

    store.deleteNodeNoSave(alice);
    try testing.expect(store.getNodePtr(alice) == null);

    var catalog_tmp = testing.tmpDir(.{});
    defer catalog_tmp.cleanup();

    const catalog_dir = try tmpDirRealpathAlloc(testing.allocator, &catalog_tmp.sub_path);
    defer testing.allocator.free(catalog_dir);

    const catalog = try Catalog.init(testing.allocator, catalog_dir);
    defer {
        catalog.deinit();
        testing.allocator.destroy(catalog);
    }

    // Test-only ExecutionContext: no principal needed — production paths
    // construct their principal at the transport boundary. See
    // docs/security/gps-principal.md for the audit conclusion.
    const context = ExecutionContext{ .catalog = catalog };

    const call_stmt, var arena = try parseCallStatement("CALL degree()");
    defer arena.deinit();

    var result = try executeCallStatement(testing.allocator, call_stmt, context);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.rows.len);
}
