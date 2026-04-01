const std = @import("std");
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

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
};

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
