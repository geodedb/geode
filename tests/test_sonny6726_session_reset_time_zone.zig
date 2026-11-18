// SONNY-6726 regression: `SESSION RESET TIME ZONE` parses and resets.
//
// ISO/IEC 39075:2024 7.1 <session reset arguments> includes TIME ZONE
// (`SESSION RESET TIME ZONE`, docs/SESSION_MANAGEMENT.md). TIME lexes as the
// .TIME keyword, and parseSessionResetStatement only matched an identifier
// TIME, so the statement was a 42000 parse error. The statement now resets the
// session's time zone to its default, as `SESSION SET TIME ZONE` set it.
//
// Real parser and executor against a real session; no mocks.
//
// CANARY: REQ=REQ-SONNY-6726-SESSION-RESET-TIME-ZONE; FEATURE="SessionManagement"; ASPECT=ResetTimeZone; STATUS=TESTED; TEST=tests/test_sonny6726_session_reset_time_zone.zig; OWNER=engine; UPDATED=2026-11-17

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;

fn run(arena: std.mem.Allocator, session: *execution.SessionState, query: []const u8) !execution.ExecutionResult {
    var parsed = try geode.parseGqlOptions(query, arena, .{});
    defer parsed.deinit();
    const catalog = try execution.ensureCatalogInstance(testing.allocator);
    const ctx = execution.ExecutionContext{ .catalog = catalog, .session_state = session };
    return execution.executeStatementWithContext(arena, parsed.program.statements[0], ctx);
}

test "SONNY-6726: SESSION RESET TIME ZONE parses and clears the session time zone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    var session = execution.SessionState.init(testing.allocator);
    defer session.deinit();

    // Each spelling parses (the parse is the regression) and resets.
    const spellings = [_][]const u8{
        "SESSION RESET TIME ZONE",
        "session reset time zone",
        "SESSION RESET TIME ZONE;",
    };
    for (spellings) |q| {
        _ = try run(arena.allocator(), &session, "SESSION SET TIME ZONE 'UTC'");
        try testing.expect(session.timezone != null);
        _ = try run(arena.allocator(), &session, q);
        try testing.expect(session.timezone == null);
    }
}

test "SONNY-6726: the other SESSION RESET arguments are unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    var session = execution.SessionState.init(testing.allocator);
    defer session.deinit();

    _ = try run(arena.allocator(), &session, "SESSION SET TIME ZONE 'UTC'");
    _ = try run(arena.allocator(), &session, "SESSION RESET ALL PARAMETERS");
    try testing.expect(session.timezone != null);
    _ = try run(arena.allocator(), &session, "SESSION RESET ALL CHARACTERISTICS");
    try testing.expect(session.timezone == null);
}

test "SONNY-6726: SESSION RESET TIME without ZONE is still refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    var session = execution.SessionState.init(testing.allocator);
    defer session.deinit();
    try testing.expectError(error.UnexpectedToken, run(arena.allocator(), &session, "SESSION RESET TIME"));
}
