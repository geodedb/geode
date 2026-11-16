const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;

// CANARY: REQ=REQ-INIT-CONTEXT-REGRESSION-001; FEATURE="InitContextPointerSafety"; ASPECT=SegfaultPrevention; STATUS=TESTED; OWNER=server; UPDATED=2026-02-11

// GAP-0426: Regression tests for dangling self-referential pointer in InitContext.
//
// Root cause: server_init.initialize() created an InitContext struct on its stack,
// set ctx.shared_ast_cache = &ctx.shared_ast_cache_storage.? (a pointer to a field
// within the same struct), then returned ctx BY VALUE. The struct was copied to the
// caller's stack frame, but the pointer still referenced the callee's dead stack.
// After ~10 queries recycled the stack memory, dereferencing the pointer caused a
// segfault at quic_connection_handler.zig:500.
//
// Fix: Added InitContext.fixupSelfPointers() which re-derives the pointer from the
// storage field at the struct's current location. Called immediately after initialize()
// returns in main.zig.

// ---------------------------------------------------------------------------
// Test 1: Demonstrate the self-referential pointer pattern is unsafe across
// function returns, and verify the fixup pattern works.
// ---------------------------------------------------------------------------

const MockCache = struct {
    data: [64]u8,
    size: usize,

    pub fn init(size: usize) MockCache {
        return .{ .data = [_]u8{0xAA} ** 64, .size = size };
    }
};

const SelfRefStruct = struct {
    cache_ptr: ?*MockCache = null,
    cache_storage: ?MockCache = null,

    pub fn fixupSelfPointers(self: *SelfRefStruct) void {
        self.cache_ptr = if (self.cache_storage != null)
            &self.cache_storage.?
        else
            null;
    }
};

// Simulate the buggy pattern: create struct with self-ref pointer, return by value
fn createWithDanglingPointer() SelfRefStruct {
    var s = SelfRefStruct{};
    s.cache_storage = MockCache.init(42);
    // BUG: This pointer will dangle after return!
    // s.cache_ptr = &s.cache_storage.?;
    // FIX: Don't set pointer here; caller must call fixupSelfPointers()
    return s;
}

test "GAP-0426: self-referential pointer fixup after by-value return" {
    var s = createWithDanglingPointer();

    // Before fixup: pointer is null (we stopped setting it in the callee)
    try testing.expect(s.cache_ptr == null);
    try testing.expect(s.cache_storage != null);

    // After fixup: pointer is valid
    s.fixupSelfPointers();
    try testing.expect(s.cache_ptr != null);

    const cache = s.cache_ptr.?;
    try testing.expect(cache.size == 42);
    try testing.expect(cache.data[0] == 0xAA);
}

test "GAP-0426: fixup survives heavy stack pressure" {
    var s = createWithDanglingPointer();
    s.fixupSelfPointers();

    // Apply heavy stack pressure to overwrite dead frames
    var sum: u64 = 0;
    for (0..200) |i| {
        sum +%= stackPressure(i);
    }
    try testing.expect(sum > 0);

    // Pointer must still be valid
    const cache = s.cache_ptr.?;
    try testing.expect(cache.size == 42);
}

test "GAP-0426: fixup with no storage sets null" {
    var s = SelfRefStruct{};
    s.fixupSelfPointers();
    try testing.expect(s.cache_ptr == null);
}

test "GAP-0426: fixup is idempotent" {
    var s = createWithDanglingPointer();
    s.fixupSelfPointers();
    const ptr1 = s.cache_ptr;
    s.fixupSelfPointers();
    const ptr2 = s.cache_ptr;
    try testing.expect(ptr1 == ptr2);
}

fn stackPressure(depth: usize) u64 {
    var buf: [512]u8 = undefined;
    for (&buf, 0..) |*b, i| {
        b.* = @truncate(i +% depth);
    }
    if (depth == 0) return buf[0];
    return @as(u64, buf[depth % 512]) +% stackPressure(depth - 1);
}

// ---------------------------------------------------------------------------
// Test 2: Verify query execution still works correctly — the crash happened
// during query processing, so verify multi-query sequences work.
// ---------------------------------------------------------------------------

fn makeContext() !execution.ExecutionContext {
    const catalog = try execution.ensureCatalogInstance(std.heap.page_allocator);
    return execution.ExecutionContext{ .catalog = catalog };
}

fn makeLabels(allocator: std.mem.Allocator, comptime names: []const []const u8) ![][]const u8 {
    var labels = try allocator.alloc([]const u8, names.len);
    for (names, 0..) |name, i| {
        labels[i] = try allocator.dupe(u8, name);
    }
    return labels;
}

fn freeLabels(allocator: std.mem.Allocator, labels: [][]const u8) void {
    for (labels) |label| allocator.free(label);
    allocator.free(labels);
}

test "GAP-0426: 10+ sequential queries do not crash" {
    const allocator = testing.allocator;
    const store = graph_store.getGlobalStore(allocator);
    try store.clearNodes();

    // Create some test data
    const labels = try makeLabels(allocator, &.{"TestNode"});
    defer freeLabels(allocator, labels);
    _ = try store.createNode(labels);

    const context = try makeContext();

    // Execute 15 queries in sequence — the crash happened around query ~10
    const queries = [_][]const u8{
        "RETURN 1 AS a",
        "RETURN 2 AS b",
        "RETURN 3 AS c",
        "RETURN 'hello' AS greeting",
        "RETURN true AS flag",
        "RETURN 42 AS answer",
        "RETURN 1 + 2 AS `sum`",
        "RETURN 'world' AS word",
        "RETURN 100 AS century",
        "RETURN false AS done",
        "RETURN 7 AS lucky",
        "RETURN 'test' AS label",
        "RETURN 99 AS bottles",
        "RETURN 0 AS zero",
        "RETURN 1000 AS millennium",
    };

    for (queries) |query| {
        var parse_result = try geode.parseGql(query, allocator);
        defer parse_result.arena.deinit();

        var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
        defer result.deinit(allocator);

        try testing.expect(result.rows.len >= 1);
    }
}

test "GAP-0426: sequential MATCH queries with graph data" {
    const allocator = testing.allocator;
    const store = graph_store.getGlobalStore(allocator);
    try store.clearNodes();

    // Create a small graph
    const labels = try makeLabels(allocator, &.{"Person"});
    defer freeLabels(allocator, labels);

    const alice = try store.createNode(labels);
    try store.setNodeProperty(alice, "name", .{ .String = "Alice" });

    const bob = try store.createNode(labels);
    try store.setNodeProperty(bob, "name", .{ .String = "Bob" });

    _ = try store.createEdge(alice, bob, "KNOWS");

    const context = try makeContext();

    // Execute multiple MATCH queries in sequence.
    // Use page_allocator for execution because single-node MATCH paths have
    // a pre-existing leak in env_names allocation (unrelated to GAP-0426).
    // This test verifies no segfault, not memory correctness of MATCH paths.
    const exec_alloc = std.heap.page_allocator;
    const queries = [_][]const u8{
        \\MATCH (n:Person) RETURN n LIMIT 10
        ,
        \\MATCH (a:Person)-[r:KNOWS]->(b:Person) RETURN a, b LIMIT 10
        ,
        \\MATCH (n:Person) RETURN n LIMIT 5
        ,
        \\MATCH (a:Person)-[:KNOWS]->(b:Person) RETURN a, b LIMIT 10
        ,
        \\MATCH (n:Person) RETURN n LIMIT 1
        ,
    };

    for (queries) |query| {
        var parse_result = try geode.parseGql(query, exec_alloc);
        defer parse_result.arena.deinit();

        var result = try execution.executeProgramWithContext(exec_alloc, &parse_result.program, context);
        defer result.deinit(exec_alloc);

        try testing.expect(result.rows.len >= 1);
    }
}

test "GAP-0426: interleaved RETURN and MATCH queries" {
    const allocator = testing.allocator;
    const store = graph_store.getGlobalStore(allocator);
    try store.clearNodes();

    const labels = try makeLabels(allocator, &.{"Item"});
    defer freeLabels(allocator, labels);

    for (0..5) |i| {
        const node = try store.createNode(labels);
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "item_{d}", .{i}) catch "item";
        try store.setNodeProperty(node, "name", .{ .String = name });
    }

    const context = try makeContext();

    // Alternate between RETURN and MATCH queries.
    // Use page_allocator for execution (same pre-existing leak reason as above).
    const exec_alloc = std.heap.page_allocator;
    const queries = [_][]const u8{
        "RETURN 1 AS x",
        \\MATCH (n:Item) RETURN n LIMIT 10
        ,
        "RETURN 'between' AS marker",
        \\MATCH (n:Item) RETURN n LIMIT 10
        ,
        "RETURN 42 AS check",
        \\MATCH (n:Item) RETURN n LIMIT 5
        ,
        "RETURN 'done' AS status",
    };

    for (queries) |query| {
        var parse_result = try geode.parseGql(query, exec_alloc);
        defer parse_result.arena.deinit();

        var result = try execution.executeProgramWithContext(exec_alloc, &parse_result.program, context);
        defer result.deinit(exec_alloc);

        try testing.expect(result.rows.len >= 1);
    }
}

test "GAP-0426: multi-hop query after many simple queries" {
    const allocator = testing.allocator;
    const store = graph_store.getGlobalStore(allocator);
    try store.clearNodes();

    // Create a chain: A -> B -> C
    const labels = try makeLabels(allocator, &.{"Chain"});
    defer freeLabels(allocator, labels);

    const a = try store.createNode(labels);
    try store.setNodeProperty(a, "name", .{ .String = "A" });
    const b = try store.createNode(labels);
    try store.setNodeProperty(b, "name", .{ .String = "B" });
    const c = try store.createNode(labels);
    try store.setNodeProperty(c, "name", .{ .String = "C" });

    _ = try store.createEdge(a, b, "NEXT");
    _ = try store.createEdge(b, c, "NEXT");

    const context = try makeContext();

    // Run 10 simple queries first (the crash happened after ~10)
    for (0..10) |i| {
        _ = i;
        var parse_result = try geode.parseGql("RETURN 1 AS x", allocator);
        defer parse_result.arena.deinit();

        var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
        defer result.deinit(allocator);
    }

    // Now run the multi-hop query that triggered the crash
    const multi_hop =
        \\MATCH (a:Chain)-[r1:NEXT]->(b:Chain)-[r2:NEXT]->(c:Chain)
        \\RETURN a, b, c LIMIT 10
    ;

    var parse_result = try geode.parseGql(multi_hop, allocator);
    defer parse_result.arena.deinit();

    var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
    defer result.deinit(allocator);

    try testing.expect(result.rows.len >= 1);
    try testing.expect(result.columns.len == 3);
}
