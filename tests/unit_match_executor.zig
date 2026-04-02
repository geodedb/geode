const std = @import("std");
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const node_scan_stream = geode.node_scan_stream;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

// CANARY: REQ=REQ-GQL-017; FEATURE="MATCHExecutorBasic"; ASPECT=Unit; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; TEST=TestCANARY_REQ_GQL_017_MatchSingleHop; OWNER=engine; UPDATED=2025-09-24

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmp.dir.realpathAlloc(allocator, ".");
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], self.ctx);
    }

    pub fn execPlanned(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();

        switch (parsed.program.statements[0]) {
            .Query => |*q| {
                const planned = try planned_read_runtime.executeIfSupported(self.allocator, q, self.ctx, &.{}, &.{});
                try std.testing.expect(planned != null);
                return planned.?;
            },
            else => return error.ExpectedQueryStatement,
        }
    }
};

fn expectValueStr(value: Value, expected: []const u8) !void {
    switch (value) {
        .Str => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.UnexpectedValueTag,
    }
}

fn expectValueInt(value: Value, expected: i64) !void {
    switch (value) {
        .Int => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.UnexpectedValueTag,
    }
}

test "TestCANARY_REQ_GQL_017_MatchSingleHop" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const n1 = try store.createNode(&.{"Person"});
    try store.setNodeProperty(n1, "age", .{ .Int = 30 });
    const n2 = try store.createNode(&.{"Person"});
    try store.setNodeProperty(n2, "age", .{ .Int = 30 });
    const n3 = try store.createNode(&.{"Person"});
    try store.setNodeProperty(n3, "age", .{ .Int = 40 });
    _ = try store.createEdge(n1, n2, "KNOWS");
    _ = try store.createEdge(n2, n3, "KNOWS");

    var res = try h.exec("MATCH (a:Person {age:30})-[:KNOWS]->(b:Person) RETURN a, b");
    defer res.deinit(allocator);
    try std.testing.expect(res.rows.len > 0);
    try std.testing.expect(res.rows[0].len == 2);
    try std.testing.expect(std.meta.activeTag(res.rows[0][0]) == .Node);
    try std.testing.expect(std.meta.activeTag(res.rows[0][1]) == .Node);
}

// CANARY: REQ=REQ-PLANNER-EXEC-001; FEATURE="PlannedReadRuntime"; ASPECT=Execution; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-01
test "TestCANARY_REQ_PLANNER_EXEC_001_PlannedReadRuntimeExecutesSingleHop" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const alice = try store.createNode(&.{"Person"});
    try store.setNodeProperty(alice, "name", .{ .String = "Alice" });
    try store.setNodeProperty(alice, "age", .{ .Int = 30 });
    const bob = try store.createNode(&.{"Person"});
    try store.setNodeProperty(bob, "name", .{ .String = "Bob" });
    try store.setNodeProperty(bob, "age", .{ .Int = 41 });
    _ = try store.createEdge(alice, bob, "KNOWS");

    var res = try h.exec("MATCH (a:Person {age: 30})-[:KNOWS]->(b:Person) RETURN b.name AS name ORDER BY name LIMIT 1");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try expectValueStr(res.rows[0][0], "Bob");
}

// CANARY: REQ=REQ-PLANNER-EXEC-002; FEATURE="PlannedReadRuntime"; ASPECT=ExplainProfile; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-01
test "TestCANARY_REQ_PLANNER_EXEC_002_ExplainAndProfileUseConcretePlan" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const alice = try store.createNode(&.{"Person"});
    try store.setNodeProperty(alice, "age", .{ .Int = 30 });
    const bob = try store.createNode(&.{"Person"});
    try store.setNodeProperty(bob, "age", .{ .Int = 35 });
    _ = try store.createEdge(alice, bob, "KNOWS");

    var explain = try h.exec("EXPLAIN MATCH (a:Person {age: 30})-[:KNOWS]->(b:Person) RETURN b");
    defer explain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), explain.rows.len);
    try expectValueStr(explain.rows[0][0], "LabelScan");
    try expectValueStr(explain.rows[1][0], "ExpandOut");
    try expectValueStr(explain.rows[2][0], "Project");

    var profile = try h.exec("PROFILE MATCH (a:Person {age: 30})-[:KNOWS]->(b:Person) RETURN b.name AS name LIMIT 1");
    defer profile.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), profile.rows.len);
    try expectValueStr(profile.rows[0][1], "planned_query_profile");
    try expectValueInt(profile.rows[1][1], 1);
    try expectValueInt(profile.rows[4][1], 5);
}

// CANARY: REQ=REQ-PLANNER-EXEC-003; FEATURE="PlannedReadRuntime"; ASPECT=WithAggregation; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-01
test "TestCANARY_REQ_PLANNER_EXEC_003_PlannedReadRuntimeSupportsWithAggregation" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const alice = try store.createNode(&.{"Person"});
    try store.setNodeProperty(alice, "name", .{ .String = "Alice" });
    const bob = try store.createNode(&.{"Person"});
    try store.setNodeProperty(bob, "name", .{ .String = "Bob" });
    const carol = try store.createNode(&.{"Person"});
    try store.setNodeProperty(carol, "name", .{ .String = "Carol" });
    const dana = try store.createNode(&.{"Person"});
    try store.setNodeProperty(dana, "name", .{ .String = "Dana" });

    _ = try store.createEdge(alice, bob, "KNOWS");
    _ = try store.createEdge(alice, carol, "KNOWS");
    _ = try store.createEdge(dana, bob, "KNOWS");

    var res = try h.exec(
        "MATCH (p:Person)-[:KNOWS]->(f:Person) " ++
            "WITH p.name AS person, count(f) AS friends " ++
            "WHERE friends >= 2 " ++
            "RETURN person, friends",
    );
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try expectValueStr(res.rows[0][0], "Alice");
    try expectValueInt(res.rows[0][1], 2);
}

// CANARY: REQ=REQ-PLANNER-EXEC-004; FEATURE="PlannedReadRuntime"; ASPECT=WithDistinct; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-01
test "TestCANARY_REQ_PLANNER_EXEC_004_PlannedReadRuntimeSupportsWithDistinct" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const alice = try store.createNode(&.{"Person"});
    const dana = try store.createNode(&.{"Person"});
    const bob = try store.createNode(&.{"Person"});
    try store.setNodeProperty(bob, "name", .{ .String = "Bob" });
    _ = try store.createEdge(alice, bob, "KNOWS");
    _ = try store.createEdge(dana, bob, "KNOWS");

    var res = try h.exec(
        "MATCH (p:Person)-[:KNOWS]->(f:Person) " ++
            "WITH DISTINCT f.name AS name " ++
            "RETURN name",
    );
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try expectValueStr(res.rows[0][0], "Bob");
}

// CANARY: REQ=REQ-PLANNER-EXEC-005; FEATURE="PlannedReadRuntime"; ASPECT=OptionalMatchDelegation; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-01
test "TestCANARY_REQ_PLANNER_EXEC_005_PlannedReadRuntimeHandlesOptionalMatch" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const alice = try store.createNode(&.{"Person"});
    try store.setNodeProperty(alice, "name", .{ .String = "Alice" });

    var res = try h.execPlanned(
        "MATCH (p:Person {name: 'Alice'}) OPTIONAL MATCH (p)-[:KNOWS]->(friend:Person) " ++
            "RETURN p.name AS person, friend.name AS friend",
    );
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try expectValueStr(res.rows[0][0], "Alice");
    try std.testing.expect(std.meta.activeTag(res.rows[0][1]) == .Null);
}

// CANARY: REQ=REQ-PLANNER-EXEC-006; FEATURE="PlannedReadRuntime"; ASPECT=VarLenDelegation; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-01
test "TestCANARY_REQ_PLANNER_EXEC_006_PlannedReadRuntimeHandlesVariableLengthMatch" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const alice = try store.createNode(&.{"Person"});
    try store.setNodeProperty(alice, "name", .{ .String = "Alice" });
    const bob = try store.createNode(&.{"Person"});
    try store.setNodeProperty(bob, "name", .{ .String = "Bob" });
    const carol = try store.createNode(&.{"Person"});
    try store.setNodeProperty(carol, "name", .{ .String = "Carol" });
    _ = try store.createEdge(alice, bob, "KNOWS");
    _ = try store.createEdge(bob, carol, "KNOWS");

    var res = try h.execPlanned(
        "MATCH (a:Person {name: 'Alice'})-[:KNOWS*1..2]->(b:Person) RETURN b.name AS name ORDER BY name",
    );
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
    try expectValueStr(res.rows[0][0], "Bob");
    try expectValueStr(res.rows[1][0], "Carol");
}

// CANARY: REQ=REQ-PLANNER-EXEC-007; FEATURE="PlannedReadRuntime"; ASPECT=UnwindDelegation; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-01
test "TestCANARY_REQ_PLANNER_EXEC_007_PlannedReadRuntimeHandlesUnwind" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var res = try h.execPlanned("UNWIND [1, 2, 3] AS n RETURN n ORDER BY n DESC LIMIT 2");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
    try expectValueInt(res.rows[0][0], 3);
    try expectValueInt(res.rows[1][0], 2);
}

// CANARY: REQ=REQ-PLANNER-EXEC-008; FEATURE="PlannedReadRuntime"; ASPECT=QueryChainDelegation; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-01
test "TestCANARY_REQ_PLANNER_EXEC_008_PlannedReadRuntimeHandlesQueryChains" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const alice = try store.createNode(&.{"Person"});
    const bob = try store.createNode(&.{"Person"});
    const carol = try store.createNode(&.{"Person"});
    try store.setNodeProperty(carol, "name", .{ .String = "Carol" });
    _ = try store.createEdge(alice, bob, "KNOWS");
    _ = try store.createEdge(bob, carol, "KNOWS");

    var res = try h.execPlanned(
        "MATCH (a:Person)-[:KNOWS]->(b) WITH b MATCH (b)-[:KNOWS]->(c:Person) RETURN c.name AS name",
    );
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try expectValueStr(res.rows[0][0], "Carol");
}

// CANARY: REQ=REQ-PLANNER-EXEC-009; FEATURE="PlannedReadRuntime"; ASPECT=ExplainOptionalMatchPlan; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-01
test "TestCANARY_REQ_PLANNER_EXEC_009_ExplainUsesConcretePlanForOptionalMatch" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const alice = try store.createNode(&.{"Person"});
    try store.setNodeProperty(alice, "name", .{ .String = "Alice" });

    var explain = try h.exec(
        "EXPLAIN MATCH (p:Person {name: 'Alice'}) OPTIONAL MATCH (p)-[:KNOWS]->(friend:Person) " ++
            "RETURN p.name AS person, friend.name AS friend",
    );
    defer explain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), explain.rows.len);
    try expectValueStr(explain.rows[0][0], "OptionalMatch");
    try expectValueStr(explain.rows[1][0], "LabelScan");
    try expectValueStr(explain.rows[2][0], "ExpandOut");
    try expectValueStr(explain.rows[4][0], "LegacyExecute");
}

// CANARY: REQ=REQ-PLANNER-EXEC-010; FEATURE="PlannedReadRuntime"; ASPECT=ProfileLegacyTrace; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-01
test "TestCANARY_REQ_PLANNER_EXEC_010_ProfileUsesPlannedRuntimeForUnwind" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var profile = try h.exec("PROFILE UNWIND [1, 2, 3] AS n RETURN n ORDER BY n DESC LIMIT 2");
    defer profile.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), profile.rows.len);
    try expectValueStr(profile.rows[0][1], "planned_query_profile");
    try std.testing.expect(switch (profile.rows[3][1]) {
        .Int => |value| value > 0,
        else => false,
    });
    try expectValueInt(profile.rows[4][1], 4);
}

// CANARY: REQ=REQ-PERF-UNORDERED-STREAM-001; FEATURE="UnorderedNodeScanStreaming"; ASPECT=Unit; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-02
test "TestCANARY_REQ_PERF_UNORDERED_STREAM_001_NodeScanStreamPagesSimpleLimit" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    inline for (0..5) |idx| {
        const node_id = try store.createNode(&.{"Person"});
        try store.setNodeProperty(node_id, "rank", .{ .Int = @intCast(idx) });
    }

    var parsed = try geode.parseGql("MATCH (u:Person) RETURN u LIMIT 3", allocator);
    defer parsed.deinit();

    const query_ptr = switch (parsed.program.statements[0]) {
        .Query => |*q| q,
        else => return error.ExpectedQueryStatement,
    };

    var stream = (try node_scan_stream.prepare(allocator, query_ptr, h.ctx, &.{}, &.{}, &.{})) orelse return error.ExpectedQueryStatement;
    defer stream.deinit();

    var schema_def = try stream.buildSchema(allocator);
    defer schema_def.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), schema_def.columns.items.len);
    try std.testing.expectEqualStrings("u", schema_def.columns.items[0].name);
    try std.testing.expectEqualStrings("NODE", schema_def.columns.items[0].type);

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    var page1 = try stream.buildNextPage(allocator, 2);
    defer page1.result.deinit(allocator);
    try std.testing.expect(!page1.final);
    try std.testing.expectEqual(@as(usize, 2), page1.result.rows.len);
    for (page1.result.rows) |row| {
        try std.testing.expectEqual(@as(usize, 1), row.len);
        switch (row[0]) {
            .Node => |node| try seen.put(node.id, {}),
            else => return error.UnexpectedValueTag,
        }
    }

    var page2 = try stream.buildNextPage(allocator, 2);
    defer page2.result.deinit(allocator);
    try std.testing.expect(page2.final);
    try std.testing.expectEqual(@as(usize, 1), page2.result.rows.len);
    for (page2.result.rows) |row| {
        switch (row[0]) {
            .Node => |node| try seen.put(node.id, {}),
            else => return error.UnexpectedValueTag,
        }
    }

    try std.testing.expectEqual(@as(usize, 3), seen.count());
}

test "TestCANARY_REQ_PERF_UNORDERED_STREAM_001_NodeScanStreamUsesBoundedDefaultPageSize" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    var idx: usize = 0;
    while (idx < 200) : (idx += 1) {
        const node_id = try store.createNode(&.{"Person"});
        try store.setNodeProperty(node_id, "rank", .{ .Int = @intCast(idx) });
    }

    var parsed = try geode.parseGql("MATCH (u:Person) RETURN u", allocator);
    defer parsed.deinit();

    const query_ptr = switch (parsed.program.statements[0]) {
        .Query => |*q| q,
        else => return error.ExpectedQueryStatement,
    };

    var stream = (try node_scan_stream.prepare(allocator, query_ptr, h.ctx, &.{}, &.{}, &.{})) orelse return error.ExpectedQueryStatement;
    defer stream.deinit();

    var first_page = try stream.buildNextPage(allocator, 0);
    defer first_page.result.deinit(allocator);
    try std.testing.expect(!first_page.final);
    try std.testing.expectEqual(node_scan_stream.default_page_rows, first_page.result.rows.len);
}

// CANARY: REQ=REQ-PERF-UNORDERED-STREAM-002; FEATURE="UnorderedNodeScanStreaming"; ASPECT=Eligibility; STATUS=TESTED; TEST=tests/unit_match_executor.zig; OWNER=engine; UPDATED=2026-04-02
test "TestCANARY_REQ_PERF_UNORDERED_STREAM_002_NodeScanStreamRejectsOrderedQuery" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var parsed = try geode.parseGql("MATCH (u:Person) RETURN u ORDER BY u", allocator);
    defer parsed.deinit();

    const query_ptr = switch (parsed.program.statements[0]) {
        .Query => |*q| q,
        else => return error.ExpectedQueryStatement,
    };

    const stream = try node_scan_stream.prepare(allocator, query_ptr, h.ctx, &.{}, &.{}, &.{});
    try std.testing.expect(stream == null);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchSafetyGuards"; ASPECT=Unit; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; TEST=TestCANARY_REQ_GQL_017_InvalidHopBounds; OWNER=engine; UPDATED=2025-09-24

test "TestCANARY_REQ_GQL_017_InvalidHopBounds" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    _ = try store.createNode(&.{"X"});

    const res = h.exec("MATCH (a:X)-[*3..1]->(b) RETURN a, b");
    try std.testing.expectError(error.InvalidHopBounds, res);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchEmptyGraph"; ASPECT=Unit; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; TEST=TestCANARY_REQ_GQL_017_EmptyGraph; OWNER=engine; UPDATED=2025-09-24

test "TestCANARY_REQ_GQL_017_EmptyGraph" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var res = try h.exec("MATCH (a)-[:KNOWS]->(b) RETURN a, b");
    defer res.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), res.rows.len);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="PathExpandBounded"; ASPECT=Unit; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; TEST=TestCANARY_REQ_GQL_017_BoundedVarLen; OWNER=engine; UPDATED=2025-09-24

test "TestCANARY_REQ_GQL_017_BoundedVarLen" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const a = try store.createNode(&.{"Person"});
    const b = try store.createNode(&.{"Person"});
    const c = try store.createNode(&.{"Person"});
    _ = try store.createEdge(a, b, "KNOWS");
    _ = try store.createEdge(b, c, "KNOWS");

    var res = try h.exec("MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a, b");
    defer res.deinit(allocator);
    try std.testing.expect(res.rows.len >= 2);
}
