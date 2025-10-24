const std = @import("std");
const testing = std.testing;
const lib = @import("lib.zig");
const execution = @import("execution.zig");

// CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=StartTransactionTest; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "START TRANSACTION creates active transaction" {
    const query = "START TRANSACTION";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;
    try testing.expect(prog.statements.len == 1);
    try testing.expect(prog.statements[0] == .StartTransaction);

    const context = execution.ExecutionContext{};
    var result = try execution.executeStatementWithContext(testing.allocator, prog.statements[0], context);
    defer result.deinit(testing.allocator);

    // Should return success status
    try testing.expect(result.rows.len == 1);
    try testing.expect(result.rows[0].len == 1);
    try testing.expect(result.rows[0][0] == .Str);
}

// CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=CommitTest; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "COMMIT requires active transaction" {
    const query = "COMMIT";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;
    try testing.expect(prog.statements.len == 1);
    try testing.expect(prog.statements[0] == .Commit);

    // Without active transaction, should fail
    const context = execution.ExecutionContext{};
    const result = execution.executeStatementWithContext(testing.allocator, prog.statements[0], context);
    try testing.expectError(error.NoActiveTransaction, result);

    // With active transaction, should succeed
    const active_context = execution.ExecutionContext{ .transaction_state = .Active };
    var success_result = try execution.executeStatementWithContext(testing.allocator, prog.statements[0], active_context);
    defer success_result.deinit(testing.allocator);

    try testing.expect(success_result.rows.len == 1);
}

// CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=RollbackTest; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "ROLLBACK requires active transaction" {
    const query = "ROLLBACK";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;
    try testing.expect(prog.statements.len == 1);
    try testing.expect(prog.statements[0] == .Rollback);

    // Without active transaction, should fail
    const context = execution.ExecutionContext{};
    const rollback_result = execution.executeStatementWithContext(testing.allocator, prog.statements[0], context);
    try testing.expectError(error.NoActiveTransaction, rollback_result);

    // With active transaction, should succeed
    const active_context = execution.ExecutionContext{ .transaction_state = .Active };
    var success_result = try execution.executeStatementWithContext(testing.allocator, prog.statements[0], active_context);
    defer success_result.deinit(testing.allocator);

    try testing.expect(success_result.rows.len == 1);
}

// CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=BeginSyntaxTest; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "BEGIN is alias for START TRANSACTION" {
    const query = "BEGIN";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;
    try testing.expect(prog.statements.len == 1);
    try testing.expect(prog.statements[0] == .StartTransaction);
}

// CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionSetSchemaTest; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "SESSION SET SCHEMA updates session state" {
    const query = "SESSION SET SCHEMA myschema";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;
    try testing.expect(prog.statements.len == 1);
    try testing.expect(prog.statements[0] == .SessionSet);

    const session_set = prog.statements[0].SessionSet;
    try testing.expect(session_set.clause_type == .Schema);
    try testing.expect(std.mem.eql(u8, session_set.clause_type.Schema.name, "myschema"));

    // Execute with session state
    var session_state = execution.SessionState.init(testing.allocator);
    defer session_state.deinit();

    const context = execution.ExecutionContext{ .session_state = &session_state };
    var result = try execution.executeStatementWithContext(testing.allocator, prog.statements[0], context);
    defer result.deinit(testing.allocator);

    // Verify schema was set
    try testing.expect(session_state.schema != null);
    try testing.expect(std.mem.eql(u8, session_state.schema.?, "myschema"));
}

// CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionSetGraphTest; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "SESSION SET GRAPH updates session state" {
    const query = "SESSION SET GRAPH mygraph";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;
    try testing.expect(prog.statements.len == 1);
    try testing.expect(prog.statements[0] == .SessionSet);

    // Execute with session state
    var session_state = execution.SessionState.init(testing.allocator);
    defer session_state.deinit();

    const context = execution.ExecutionContext{ .session_state = &session_state };
    var result = try execution.executeStatementWithContext(testing.allocator, prog.statements[0], context);
    defer result.deinit(testing.allocator);

    // Verify graph was set
    try testing.expect(session_state.graph != null);
    try testing.expect(std.mem.eql(u8, session_state.graph.?, "mygraph"));
}

// CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionSetTimeZoneTest; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "SESSION SET TIME ZONE updates session state" {
    const query = "SESSION SET TIME ZONE 'UTC'";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;
    try testing.expect(prog.statements.len == 1);
    try testing.expect(prog.statements[0] == .SessionSet);

    // Execute with session state
    var session_state = execution.SessionState.init(testing.allocator);
    defer session_state.deinit();

    const context = execution.ExecutionContext{ .session_state = &session_state };
    var result = try execution.executeStatementWithContext(testing.allocator, prog.statements[0], context);
    defer result.deinit(testing.allocator);

    // Verify timezone was set
    try testing.expect(session_state.timezone != null);
    try testing.expect(std.mem.eql(u8, session_state.timezone.?, "UTC"));
}

// CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionResetTest; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "SESSION RESET clears session state" {
    // Set up session with some values
    var session_state = execution.SessionState.init(testing.allocator);
    defer session_state.deinit();

    session_state.schema = try testing.allocator.dupe(u8, "testschema");
    session_state.graph = try testing.allocator.dupe(u8, "testgraph");
    session_state.timezone = try testing.allocator.dupe(u8, "PST");

    const query = "SESSION RESET";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;
    try testing.expect(prog.statements.len == 1);
    try testing.expect(prog.statements[0] == .SessionReset);

    const context = execution.ExecutionContext{ .session_state = &session_state };
    var result = try execution.executeStatementWithContext(testing.allocator, prog.statements[0], context);
    defer result.deinit(testing.allocator);

    // Verify everything was reset
    try testing.expect(session_state.schema == null);
    try testing.expect(session_state.graph == null);
    try testing.expect(session_state.timezone == null);
}

// CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionCloseTest; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "SESSION CLOSE cleans up session" {
    const query = "SESSION CLOSE";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;
    try testing.expect(prog.statements.len == 1);
    try testing.expect(prog.statements[0] == .SessionClose);

    var session_state = execution.SessionState.init(testing.allocator);
    const context = execution.ExecutionContext{ .session_state = &session_state };
    var result = try execution.executeStatementWithContext(testing.allocator, prog.statements[0], context);
    defer result.deinit(testing.allocator);

    try testing.expect(result.rows.len == 1);
}
