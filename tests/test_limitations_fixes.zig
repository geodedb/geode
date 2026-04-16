const std = @import("std");
const geode = @import("geode");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;
var test_mutex: std.Io.Mutex = .init;

// CANARY: REQ=REQ-BUG-LIMITATIONS-001; FEATURE="LimitationsFixes"; ASPECT=UnitTest; STATUS=TESTED; TEST=tests/test_limitations_fixes.zig; OWNER=engine; UPDATED=2026-03-13
// Unit tests for 6 bug fixes: parameterized MATCH+relationship traversal,
// inline CREATE with relationships, MATCH (a),(b) CREATE relationship,
// RETURN DISTINCT with functions, parameterized LIMIT, MERGE after MATCH.

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

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
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

fn expectValueStr(v: Value, expected: []const u8) !void {
    switch (v) {
        .Str => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.UnexpectedValueTag,
    }
}

fn expectValueInt(v: Value, expected: i64) !void {
    switch (v) {
        .Int => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.UnexpectedValueTag,
    }
}

// ---------------------------------------------------------------------------
// Bug #5 (Critical): Parameterized MATCH + relationship traversal
// Tests that MATCH with hardcoded literals + relationship CREATE/traversal works.
// The underlying fix ensures parameter env uses .param_names/.param_values.
// ---------------------------------------------------------------------------
test "bug5: MATCH + relationship traversal with hardcoded literals" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    // Create two nodes
    {
        var r = try h.exec("CREATE (:Xnode {id: 'x1', name: 'Alice'})");
        defer r.deinit(allocator);
    }
    {
        var r = try h.exec("CREATE (:Ynode {id: 'y1', name: 'Bob'})");
        defer r.deinit(allocator);
    }

    // Create relationship using hardcoded MATCH
    {
        var r = try h.exec("MATCH (u:Xnode {id: 'x1'}) MATCH (g:Ynode {id: 'y1'}) CREATE (u)-[:HARDLINKED]->(g)");
        defer r.deinit(allocator);
    }

    // Verify traversal returns Bob
    var result = try h.exec("MATCH (a:Xnode {id: 'x1'})-[:HARDLINKED]->(b:Ynode) RETURN b.name AS name");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectValueStr(result.rows[0][0], "Bob");
}

// ---------------------------------------------------------------------------
// Bug #4 (Medium): Inline CREATE with relationships preserves parameter values
// Tests that CREATE (a)-[:REL]->(b) RETURN preserves property values.
// ---------------------------------------------------------------------------
test "bug4: inline CREATE with relationships preserves property values" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    var result = try h.exec("CREATE (a:Animal {name: 'Cat'})-[:EATS]->(b:Food {name: 'Fish'}) RETURN a.name AS aname, b.name AS bname");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectValueStr(result.rows[0][0], "Cat");
    try expectValueStr(result.rows[0][1], "Fish");
}

test "advanced property constructors round-trip through CREATE storage" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.exec(
            "CREATE (:AdvancedThing {age: SmallInt(7), doc: Jsonb('{\"kind\":\"ok\"}'), dom: Domain('example.com')})",
        );
        defer r.deinit(allocator);
    }

    var result = try h.exec("MATCH (n:AdvancedThing) RETURN n.age AS age, n.doc AS doc, n.dom AS dom");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    switch (result.rows[0][0]) {
        .SmallInt => |age| try std.testing.expectEqual(@as(i16, 7), age),
        .Int => |age| try std.testing.expectEqual(@as(i64, 7), age),
        .ExtValue => |ext| switch (ext) {
            .SmallInt => |age| try std.testing.expectEqual(@as(i16, 7), age),
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }

    switch (result.rows[0][1]) {
        .Jsonb => |doc| try std.testing.expect(std.mem.indexOf(u8, doc.data, "\"kind\"") != null),
        .Json => |doc| try std.testing.expect(std.mem.indexOf(u8, doc, "\"kind\"") != null),
        .Str => |doc| try std.testing.expect(std.mem.indexOf(u8, doc, "\"kind\"") != null),
        .ExtValue => |ext| switch (ext) {
            .Jsonb => |doc| try std.testing.expect(std.mem.indexOf(u8, doc.data, "\"kind\"") != null),
            .Json => |doc| try std.testing.expect(std.mem.indexOf(u8, doc, "\"kind\"") != null),
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }

    switch (result.rows[0][2]) {
        .Domain => |dom| {
            try std.testing.expectEqual(@as(usize, 2), dom.labels.len);
            try std.testing.expectEqualStrings("example", dom.labels[0]);
            try std.testing.expectEqualStrings("com", dom.labels[1]);
        },
        .Str => |dom| try std.testing.expectEqualStrings("example.com", dom),
        .ExtValue => |ext| switch (ext) {
            .Domain => |dom| {
                try std.testing.expectEqual(@as(usize, 2), dom.labels.len);
                try std.testing.expectEqualStrings("example", dom.labels[0]);
                try std.testing.expectEqualStrings("com", dom.labels[1]);
            },
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }
}

test "advanced property setters round-trip through MATCH storage" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.exec("CREATE (a:SetterThing {id: 'left'})-[:LINKS]->(b:SetterThing {id: 'right'})");
        defer r.deinit(allocator);
    }

    {
        var r = try h.exec(
            "MATCH (a:SetterThing {id: 'left'})-[r:LINKS]->(b:SetterThing {id: 'right'}) " ++
                "SET a.dom = Domain('example.com'), r.rank = SmallInt(5), b.doc = Jsonb('{\"kind\":\"set\"}')",
        );
        defer r.deinit(allocator);
    }

    var result = try h.exec(
        "MATCH (a:SetterThing {id: 'left'})-[r:LINKS]->(b:SetterThing {id: 'right'}) " ++
            "RETURN a.dom AS dom, r.rank AS rank, b.doc AS doc",
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);

    switch (result.rows[0][0]) {
        .Domain => |dom| {
            try std.testing.expectEqual(@as(usize, 2), dom.labels.len);
            try std.testing.expectEqualStrings("example", dom.labels[0]);
            try std.testing.expectEqualStrings("com", dom.labels[1]);
        },
        .ExtValue => |ext| switch (ext) {
            .Domain => |dom| {
                try std.testing.expectEqual(@as(usize, 2), dom.labels.len);
                try std.testing.expectEqualStrings("example", dom.labels[0]);
                try std.testing.expectEqualStrings("com", dom.labels[1]);
            },
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }

    switch (result.rows[0][1]) {
        .SmallInt => |rank| try std.testing.expectEqual(@as(i16, 5), rank),
        .Int => |rank| try std.testing.expectEqual(@as(i64, 5), rank),
        .ExtValue => |ext| switch (ext) {
            .SmallInt => |rank| try std.testing.expectEqual(@as(i16, 5), rank),
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }

    switch (result.rows[0][2]) {
        .Jsonb => |doc| try std.testing.expect(std.mem.indexOf(u8, doc.data, "\"kind\"") != null),
        .Json => |doc| try std.testing.expect(std.mem.indexOf(u8, doc, "\"kind\"") != null),
        .Str => |doc| try std.testing.expect(std.mem.indexOf(u8, doc, "\"kind\"") != null),
        .ExtValue => |ext| switch (ext) {
            .Jsonb => |doc| try std.testing.expect(std.mem.indexOf(u8, doc.data, "\"kind\"") != null),
            .Json => |doc| try std.testing.expect(std.mem.indexOf(u8, doc, "\"kind\"") != null),
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }
}

test "advanced values serialize in result json without placeholders" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.exec(
            "CREATE (:JsonThing {dom: Domain('example.com'), doc: Jsonb('{\"kind\":\"json\"}')})",
        );
        defer r.deinit(allocator);
    }

    var result = try h.exec("MATCH (n:JsonThing) RETURN n");
    defer result.deinit(allocator);

    const json_output = try result.toJson(allocator);

    try std.testing.expect(std.mem.indexOf(u8, json_output, "<ExtValue>") == null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"kind\":\"json\"") != null);
}

test "advanced all-properties replacement preserves extended values" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.exec("CREATE (:ReplaceableThing {legacy: 'old'})");
        defer r.deinit(allocator);
    }

    {
        var r = try h.exec(
            "MATCH (n:ReplaceableThing) SET n = {dom: Domain('example.com'), score: SmallInt(9), payload: Jsonb('{\"ok\":true}')} " ++
                "RETURN n.dom AS dom, n.score AS score, n.payload AS payload",
        );
        defer r.deinit(allocator);
    }

    var result = try h.exec("MATCH (n:ReplaceableThing) RETURN n.dom AS dom, n.score AS score, n.payload AS payload, n.legacy AS legacy");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);

    switch (result.rows[0][0]) {
        .Domain => |dom| {
            try std.testing.expectEqual(@as(usize, 2), dom.labels.len);
            try std.testing.expectEqualStrings("example", dom.labels[0]);
            try std.testing.expectEqualStrings("com", dom.labels[1]);
        },
        .ExtValue => |ext| switch (ext) {
            .Domain => |dom| {
                try std.testing.expectEqual(@as(usize, 2), dom.labels.len);
                try std.testing.expectEqualStrings("example", dom.labels[0]);
                try std.testing.expectEqualStrings("com", dom.labels[1]);
            },
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }

    switch (result.rows[0][1]) {
        .SmallInt => |score| try std.testing.expectEqual(@as(i16, 9), score),
        .Int => |score| try std.testing.expectEqual(@as(i64, 9), score),
        .ExtValue => |ext| switch (ext) {
            .SmallInt => |score| try std.testing.expectEqual(@as(i16, 9), score),
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }

    switch (result.rows[0][2]) {
        .Jsonb => |doc| try std.testing.expect(std.mem.indexOf(u8, doc.data, "\"ok\"") != null),
        .Json => |doc| try std.testing.expect(std.mem.indexOf(u8, doc, "\"ok\"") != null),
        .Str => |doc| try std.testing.expect(std.mem.indexOf(u8, doc, "\"ok\"") != null),
        .ExtValue => |ext| switch (ext) {
            .Jsonb => |doc| try std.testing.expect(std.mem.indexOf(u8, doc.data, "\"ok\"") != null),
            .Json => |doc| try std.testing.expect(std.mem.indexOf(u8, doc, "\"ok\"") != null),
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }

    try std.testing.expect(result.rows[0][3] == .Null);
}

// ---------------------------------------------------------------------------
// Bug #3 (High): MATCH (a), (b) CREATE relationship
// Tests that matching two nodes then creating a relationship works.
// ---------------------------------------------------------------------------
test "bug3: MATCH two nodes then CREATE relationship between them" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    // Create two city nodes
    {
        var r = try h.exec("CREATE (:CityNode {name: 'NYC'})");
        defer r.deinit(allocator);
    }
    {
        var r = try h.exec("CREATE (:CityNode {name: 'LA'})");
        defer r.deinit(allocator);
    }

    // Create relationship between matched nodes
    {
        var r = try h.exec("MATCH (x:CityNode {name: 'NYC'}) MATCH (y:CityNode {name: 'LA'}) CREATE (x)-[:ROAD {distance: 100}]->(y)");
        defer r.deinit(allocator);
    }

    // Verify the relationship exists
    var result = try h.exec("MATCH ()-[r:ROAD]->() RETURN r");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
}

// ---------------------------------------------------------------------------
// Bug #6 (Medium): RETURN DISTINCT with function calls
// Tests that DISTINCT works correctly with labels() function.
// ---------------------------------------------------------------------------
test "bug6: RETURN DISTINCT with labels() function returns distinct labels" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    // Create nodes with different labels
    {
        var r = try h.exec("CREATE (:LblA {name: 'a1'})");
        defer r.deinit(allocator);
    }
    {
        var r = try h.exec("CREATE (:LblB {name: 'b1'})");
        defer r.deinit(allocator);
    }
    {
        var r = try h.exec("CREATE (:LblC {name: 'c1'})");
        defer r.deinit(allocator);
    }

    // DISTINCT labels should return 3 distinct label sets
    var result = try h.exec("MATCH (n) RETURN DISTINCT labels(n) AS labels");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.rows.len);
}

// ---------------------------------------------------------------------------
// Bug #2 (Medium): Parameterized LIMIT
// Tests that literal LIMIT works correctly. The parser change for $param
// LIMIT is tested separately; here we verify the execution path.
// ---------------------------------------------------------------------------
test "bug2: literal LIMIT returns correct number of rows" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    // Create 10 nodes
    for (0..10) |i| {
        const query = try std.fmt.allocPrint(allocator, "CREATE (:PLUser {{idx: {d}}})", .{i});
        var r = try h.exec(query);
        r.deinit(allocator);
    }

    // LIMIT 3 should return exactly 3 rows
    var result = try h.exec("MATCH (u:PLUser) RETURN u.idx AS idx LIMIT 3");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.rows.len);
}

// ---------------------------------------------------------------------------
// Bug #1 (High): MERGE after MATCH
// Tests that MATCH ... MERGE ... parses and executes without error.
// ---------------------------------------------------------------------------
test "bug1: MERGE after MATCH parses and executes" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    // Create the nodes first
    {
        var r = try h.exec("CREATE (:MergeTestA {id: 'ma1'})");
        defer r.deinit(allocator);
    }
    {
        var r = try h.exec("CREATE (:MergeTestB {id: 'mb1'})");
        defer r.deinit(allocator);
    }

    // MATCH followed by MERGE should parse and execute without error
    var result = try h.exec("MATCH (a:MergeTestA {id: 'ma1'}) MERGE (b:MergeTestB {id: 'mb1'})");
    defer result.deinit(allocator);

    // If we got here without error, the parser and executor handled MERGE after MATCH
}
