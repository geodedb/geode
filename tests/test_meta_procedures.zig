// Tests for db.* and dbms.* introspection procedures (GAP-0531).
//
// These procedures are essential for any CLI / IDE / LSP integration that
// needs to enumerate the labels, edge types, property keys, indexes,
// constraints, procedures, and functions available on a Geode server.
// Before this fix every CALL to db.* / dbms.* returned ExecutionError.UnknownProcedure.

const std = @import("std");
const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;

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

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], self.ctx);
    }
};

// ---------------------------------------------------------------------------
// db.labels()
// ---------------------------------------------------------------------------

test "CALL db.labels() returns distinct node labels sorted ascending" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    var person = [_][]const u8{"Person"};
    var company = [_][]const u8{"Company"};
    var both = [_][]const u8{ "Person", "Employee" };
    _ = try store.createNode(&person);
    _ = try store.createNode(&company);
    _ = try store.createNode(&both);

    var res = try h.runQuery("CALL db.labels()");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.columns.len);
    try std.testing.expectEqualStrings("label", res.columns[0]);
    // Three distinct labels: Company, Employee, Person (sorted)
    try std.testing.expectEqual(@as(usize, 3), res.rows.len);
    try std.testing.expectEqualStrings("Company", res.rows[0][0].Str);
    try std.testing.expectEqualStrings("Employee", res.rows[1][0].Str);
    try std.testing.expectEqualStrings("Person", res.rows[2][0].Str);
}

test "CALL DB.LABELS() works case-insensitively" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    var person = [_][]const u8{"Person"};
    _ = try store.createNode(&person);

    var res = try h.runQuery("CALL DB.LABELS()");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqualStrings("Person", res.rows[0][0].Str);
}

test "CALL db.labels() on empty store returns no rows" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var res = try h.runQuery("CALL db.labels()");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), res.rows.len);
}

// ---------------------------------------------------------------------------
// db.relationshipTypes()
// ---------------------------------------------------------------------------

test "CALL db.relationshipTypes() returns distinct edge labels" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    var person = [_][]const u8{"Person"};
    const a = try store.createNode(&person);
    const b = try store.createNode(&person);
    const c = try store.createNode(&person);
    _ = try store.createEdge(a, b, "KNOWS");
    _ = try store.createEdge(a, c, "KNOWS");
    _ = try store.createEdge(b, c, "WORKS_WITH");

    var res = try h.runQuery("CALL db.relationshipTypes()");
    defer res.deinit(allocator);

    try std.testing.expectEqualStrings("relationshipType", res.columns[0]);
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
    try std.testing.expectEqualStrings("KNOWS", res.rows[0][0].Str);
    try std.testing.expectEqualStrings("WORKS_WITH", res.rows[1][0].Str);
}

// ---------------------------------------------------------------------------
// db.propertyKeys()
// ---------------------------------------------------------------------------

test "CALL db.propertyKeys() returns distinct property keys from nodes and edges" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    var person = [_][]const u8{"Person"};
    const a = try store.createNode(&person);
    const b = try store.createNode(&person);
    try store.setNodeProperty(a, "name", .{ .String = "Alice" });
    try store.setNodeProperty(a, "age", .{ .Int = 30 });
    try store.setNodeProperty(b, "name", .{ .String = "Bob" });
    const e = try store.createEdge(a, b, "KNOWS");
    try store.setEdgeProperty(e, "since", .{ .Int = 2020 });

    var res = try h.runQuery("CALL db.propertyKeys()");
    defer res.deinit(allocator);

    try std.testing.expectEqualStrings("propertyKey", res.columns[0]);
    try std.testing.expectEqual(@as(usize, 3), res.rows.len);
    try std.testing.expectEqualStrings("age", res.rows[0][0].Str);
    try std.testing.expectEqualStrings("name", res.rows[1][0].Str);
    try std.testing.expectEqualStrings("since", res.rows[2][0].Str);
}

// ---------------------------------------------------------------------------
// dbms.procedures() and dbms.functions()
// ---------------------------------------------------------------------------

test "CALL dbms.procedures() returns the procedure catalog" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var res = try h.runQuery("CALL dbms.procedures()");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), res.columns.len);
    try std.testing.expectEqualStrings("name", res.columns[0]);
    try std.testing.expectEqualStrings("signature", res.columns[1]);
    try std.testing.expectEqualStrings("description", res.columns[2]);

    // The catalog has many procedures; the count must be > 0.
    try std.testing.expect(res.rows.len > 0);
}

test "CALL dbms.functions() returns the function catalog" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var res = try h.runQuery("CALL dbms.functions()");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), res.columns.len);
    try std.testing.expectEqualStrings("name", res.columns[0]);
    try std.testing.expectEqualStrings("signature", res.columns[1]);
    try std.testing.expectEqualStrings("description", res.columns[2]);
    try std.testing.expectEqualStrings("category", res.columns[3]);

    // count, sum, abs, etc. — must be many entries
    try std.testing.expect(res.rows.len > 5);

    // Verify "count" is present somewhere
    var found_count = false;
    for (res.rows) |row| {
        if (std.mem.eql(u8, row[0].Str, "count")) {
            found_count = true;
            break;
        }
    }
    try std.testing.expect(found_count);
}

test "CALL DBMS.FUNCTIONS() works case-insensitively" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var res = try h.runQuery("CALL DBMS.FUNCTIONS()");
    defer res.deinit(allocator);
    try std.testing.expect(res.rows.len > 0);
}

// ---------------------------------------------------------------------------
// db.indexes() and db.constraints()
// ---------------------------------------------------------------------------

test "CALL db.indexes() on empty catalog returns no rows" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var res = try h.runQuery("CALL db.indexes()");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), res.columns.len);
    try std.testing.expectEqualStrings("name", res.columns[0]);
    try std.testing.expectEqualStrings("type", res.columns[1]);
    try std.testing.expectEqualStrings("label", res.columns[2]);
    try std.testing.expectEqualStrings("properties", res.columns[3]);
    // No CREATE INDEX has been issued, so the catalog should be empty.
    try std.testing.expectEqual(@as(usize, 0), res.rows.len);
}

test "CALL db.constraints() on empty catalog returns no rows" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    var res = try h.runQuery("CALL db.constraints()");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), res.columns.len);
    try std.testing.expectEqualStrings("name", res.columns[0]);
    try std.testing.expectEqualStrings("type", res.columns[1]);
    try std.testing.expectEqualStrings("label", res.columns[2]);
    try std.testing.expectEqualStrings("properties", res.columns[3]);
    try std.testing.expectEqualStrings("enforced", res.columns[4]);
    try std.testing.expectEqual(@as(usize, 0), res.rows.len);
}
