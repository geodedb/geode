// SONNY-6727 regression: CURRENT_GRAPH and CURRENT_PROPERTY_GRAPH are value
// expressions naming the session's graph.
//
// ISO/IEC 39075:2024 defines CURRENT_GRAPH / CURRENT_PROPERTY_GRAPH as value
// expressions (docs/SESSION_MANAGEMENT.md). They worked as a USE GRAPH /
// SESSION SET GRAPH target but `RETURN CURRENT_GRAPH AS g` was a 42000
// "Variable not in scope". They now evaluate to the session's graph name: the
// default graph until USE GRAPH or SESSION SET GRAPH moves it, then that graph,
// and the default again after SESSION RESET GRAPH.
//
// Real parser, executor, catalog and session; no mocks.
//
// CANARY: REQ=REQ-SONNY-6727-CURRENT-GRAPH-VALUE; FEATURE="SessionManagement"; ASPECT=CurrentGraphValue; STATUS=TESTED; TEST=tests/test_sonny6727_current_graph_value.zig; OWNER=engine; UPDATED=2026-11-17

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init() !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        _ = graph_store.getGlobalStore(testing.allocator);
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .session = execution.SessionState.init(testing.allocator),
            .ctx = .{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
    }

    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// The one string a one-row, one-column query answers.
    fn scalar(self: *Harness, query: []const u8) ![]const u8 {
        const res = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(@as(usize, 1), res.rows[0].len);
        return switch (res.rows[0][0]) {
            .Str => |s| s,
            else => error.NotAString,
        };
    }
};

test "SONNY-6727: CURRENT_GRAPH and CURRENT_PROPERTY_GRAPH name the session's graph" {
    var h = try Harness.init();
    defer h.deinit();

    // The session starts on the default graph.
    try testing.expectEqualStrings(graph_store.DEFAULT_GRAPH_NAME, try h.scalar("RETURN CURRENT_GRAPH AS g"));
    try testing.expectEqualStrings(graph_store.DEFAULT_GRAPH_NAME, try h.scalar("RETURN CURRENT_PROPERTY_GRAPH AS g"));
    try testing.expectEqualStrings(graph_store.DEFAULT_GRAPH_NAME, try h.scalar("return current_graph as g"));

    // USE GRAPH and SESSION SET GRAPH move it.
    _ = try h.exec("CREATE GRAPH sonny6727_a");
    _ = try h.exec("CREATE GRAPH sonny6727_b");
    _ = try h.exec("USE GRAPH sonny6727_a");
    try testing.expectEqualStrings("sonny6727_a", try h.scalar("RETURN CURRENT_GRAPH AS g"));
    try testing.expectEqualStrings("sonny6727_a", try h.scalar("RETURN CURRENT_PROPERTY_GRAPH AS g"));
    _ = try h.exec("SESSION SET GRAPH sonny6727_b");
    try testing.expectEqualStrings("sonny6727_b", try h.scalar("RETURN CURRENT_GRAPH AS g"));

    // It is an ordinary value expression: usable inside larger expressions.
    try testing.expectEqualStrings("on sonny6727_b", try h.scalar("RETURN 'on ' || CURRENT_GRAPH AS g"));

    // SESSION RESET GRAPH goes home.
    _ = try h.exec("SESSION RESET GRAPH");
    try testing.expectEqualStrings(graph_store.DEFAULT_GRAPH_NAME, try h.scalar("RETURN CURRENT_GRAPH AS g"));
}

test "SONNY-6727: CURRENT_GRAPH is usable after MATCH and as a USE GRAPH target" {
    var h = try Harness.init();
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH sonny6727_c");
    _ = try h.exec("USE GRAPH sonny6727_c");
    _ = try h.exec("CREATE (:Item {k: 1})");
    try testing.expectEqualStrings("sonny6727_c", try h.scalar("MATCH (n:Item) RETURN CURRENT_GRAPH AS g"));
    // USE GRAPH CURRENT_GRAPH stays where it is (unchanged behaviour).
    _ = try h.exec("USE GRAPH CURRENT_GRAPH");
    try testing.expectEqualStrings("sonny6727_c", try h.scalar("RETURN CURRENT_PROPERTY_GRAPH AS g"));
}

test "SONNY-6727: a delimited `CURRENT_GRAPH` is still a plain variable" {
    var h = try Harness.init();
    defer h.deinit();
    try testing.expectEqualStrings("mine", try h.scalar("WITH 'mine' AS `CURRENT_GRAPH` RETURN `CURRENT_GRAPH` AS g"));
}

test "SONNY-6727: CURRENT_GRAPH answers without an alias" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.exec("CREATE GRAPH sonny6727_d");
    _ = try h.exec("USE GRAPH sonny6727_d");
    try testing.expectEqualStrings("sonny6727_d", try h.scalar("RETURN CURRENT_PROPERTY_GRAPH"));
}
