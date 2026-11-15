const std = @import("std");
const ast = @import("../gql/ast.zig");
const graph_store = @import("../graph_store.zig");
const query_traits = @import("../query/query_traits.zig");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
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

/// SONNY-6561: the CDC frames' answers, one implementation for QUIC and gRPC.
pub const CdcRefusal = procedure_registry.CdcRefusal;
pub const cdcDiagnosticsAnswer = procedure_registry.cdcDiagnosticsAnswer;
pub const cdcControlAnswer = procedure_registry.cdcControlAnswer;
pub const CdcActor = procedure_registry.CdcActor;
pub const auditCdcFrameRefusal = procedure_registry.auditCdcFrameRefusal;

/// Execute CALL subquery statement
/// Executes the subquery statement (Query, Call, Create, etc.) with context
/// and optionally applies RETURN clause transformation
pub fn executeCallSubquery(allocator: std.mem.Allocator, call_subq: ast.CallSubquery, context: ExecutionContext) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-GQL-CALL-SUBQUERY; FEATURE="CallSubquery"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-10-11
    // Execute the statement (can be Query, Call, Create, etc.) with context
    // Handle statements directly to avoid circular error set inference
    const subquery_result = switch (call_subq.statement.*) {
        // SONNY-3248 (round 4b-1b review m-a): the body's SKIP and LIMIT, a
        // parameter's too, as a statement's (`execution.applyQueryWindow`).
        // Only the executors that read the window themselves applied it, so
        // `CALL { MATCH (n:G) RETURN n.i AS k LIMIT $l } RETURN k` returned
        // every row in memory, and `ORDER BY k SKIP 2 LIMIT 1` every row in
        // every session.
        .Query => |q| blk: {
            const window = try execution.queryWindow(q, context);
            var body = try execution.executeQueryWithContext(allocator, q, context);
            errdefer body.deinit(allocator);
            try execution.applyQueryWindow(allocator, &body, window);
            break :blk body;
        },
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
    const saved_override = graph_store.saveDataDirOverride();
    defer saved_override.restore();
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
