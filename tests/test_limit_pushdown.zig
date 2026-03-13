const std = @import("std");
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;
var test_mutex: std.Thread.Mutex = .{};

// CANARY: REQ=REQ-PERF-LIMIT-PUSHDOWN-001; FEATURE="LimitPushdown"; ASPECT=UnitTest; STATUS=TESTED; TEST=tests/test_limit_pushdown.zig; OWNER=engine; UPDATED=2026-03-13
// Unit tests for LIMIT pushdown optimization in MATCH queries.
// Verifies that LIMIT is pushed into the scan phase so queries like
// MATCH (u:Label) RETURN u.prop LIMIT 10 stop scanning after 10 matches.

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

/// Seed a graph with many nodes of a single label to exercise pushdown.
fn seedLargeGraph(allocator: std.mem.Allocator, count: usize) !void {
    const store = graph_store.getGlobalStore(allocator);
    const user_labels = @constCast(&[_][]const u8{"User"});
    const admin_labels = @constCast(&[_][]const u8{"Admin"});

    // Create `count` User nodes with sequential names
    for (0..count) |i| {
        const id = try store.createNode(user_labels);
        const name = try std.fmt.allocPrint(allocator, "user_{d}", .{i});
        try store.setNodeProperty(id, "name", .{ .String = name });
        try store.setNodeProperty(id, "idx", .{ .Int = @intCast(i) });
    }

    // Create a few Admin nodes to test label filtering
    for (0..3) |i| {
        const id = try store.createNode(admin_labels);
        const name = try std.fmt.allocPrint(allocator, "admin_{d}", .{i});
        try store.setNodeProperty(id, "name", .{ .String = name });
    }
}

// ---------------------------------------------------------------------------
// Test: LIMIT pushdown returns correct number of rows
// ---------------------------------------------------------------------------
test "limit pushdown: MATCH (u:User) RETURN u.name LIMIT 5 returns exactly 5 rows" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedLargeGraph(allocator, 200);

    var result = try h.exec("MATCH (u:User) RETURN u.name LIMIT 5");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), result.rows.len);
}

// ---------------------------------------------------------------------------
// Test: LIMIT 1 returns exactly one row
// ---------------------------------------------------------------------------
test "limit pushdown: MATCH (u:User) RETURN u.name LIMIT 1 returns 1 row" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedLargeGraph(allocator, 200);

    var result = try h.exec("MATCH (u:User) RETURN u.name LIMIT 1");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
}

// ---------------------------------------------------------------------------
// Test: LIMIT with OFFSET pushdown
// ---------------------------------------------------------------------------
test "limit pushdown: MATCH LIMIT with OFFSET returns correct count" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedLargeGraph(allocator, 200);

    // OFFSET 3 LIMIT 5 should return 5 rows (skipping first 3)
    var result = try h.exec("MATCH (u:User) RETURN u.name OFFSET 3 LIMIT 5");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), result.rows.len);
}

// ---------------------------------------------------------------------------
// Test: LIMIT larger than result set returns all matching
// ---------------------------------------------------------------------------
test "limit pushdown: LIMIT larger than dataset returns all rows" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedLargeGraph(allocator, 10);

    var result = try h.exec("MATCH (u:User) RETURN u.name LIMIT 100");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 10), result.rows.len);
}

// ---------------------------------------------------------------------------
// Test: LIMIT is NOT pushed down when ORDER BY is present
// (Must scan all nodes to sort correctly)
// ---------------------------------------------------------------------------
test "limit not pushed when ORDER BY present: correct sort order preserved" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedLargeGraph(allocator, 50);

    // ORDER BY idx DESC LIMIT 3 should return the 3 highest-indexed nodes
    var result = try h.exec("MATCH (u:User) RETURN u.name AS name, u.idx AS idx ORDER BY idx DESC LIMIT 3");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.rows.len);
    // First row should be idx=49 (highest)
    try expectValueInt(result.rows[0][1], 49);
    try expectValueInt(result.rows[1][1], 48);
    try expectValueInt(result.rows[2][1], 47);
}

// ---------------------------------------------------------------------------
// Test: LIMIT with DISTINCT is not pushed down
// ---------------------------------------------------------------------------
test "limit not pushed when DISTINCT present: correct dedup" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedLargeGraph(allocator, 20);

    // DISTINCT with LIMIT - should work correctly (DISTINCT applied first, then LIMIT)
    var result = try h.exec("MATCH (u:User) RETURN DISTINCT u.name LIMIT 5");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), result.rows.len);
}

// ---------------------------------------------------------------------------
// Test: LIMIT pushdown with label filtering (only matching labels)
// ---------------------------------------------------------------------------
test "limit pushdown: label filtering returns only matching label nodes" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedLargeGraph(allocator, 100);

    // Should return Admin nodes only, not User nodes
    var result = try h.exec("MATCH (a:Admin) RETURN a.name LIMIT 10");
    defer result.deinit(allocator);

    // Only 3 Admin nodes exist
    try std.testing.expectEqual(@as(usize, 3), result.rows.len);
}

// ---------------------------------------------------------------------------
// Test: LIMIT pushdown with WHERE filter
// ---------------------------------------------------------------------------
test "limit pushdown: WHERE filter with LIMIT returns correct count" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedLargeGraph(allocator, 100);

    // WHERE idx < 10 LIMIT 3 should return 3 rows (there are 10 matching)
    var result = try h.exec("MATCH (u:User) WHERE u.idx < 10 RETURN u.name LIMIT 3");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.rows.len);
}

// ---------------------------------------------------------------------------
// Test: No-label full scan with LIMIT pushdown
// ---------------------------------------------------------------------------
test "limit pushdown: full scan without labels respects LIMIT" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedLargeGraph(allocator, 100);

    // No label: full scan of all nodes (100 User + 3 Admin = 103)
    var result = try h.exec("MATCH (n) RETURN n.name LIMIT 7");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), result.rows.len);
}

// ---------------------------------------------------------------------------
// Test: Aggregation with LIMIT is not pushed down
// ---------------------------------------------------------------------------
test "limit not pushed when aggregation present: correct count" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedLargeGraph(allocator, 50);

    // count() requires scanning all nodes - LIMIT should not be pushed down
    var result = try h.exec("MATCH (u:User) RETURN count(u) AS cnt LIMIT 1");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectValueInt(result.rows[0][0], 50);
}
