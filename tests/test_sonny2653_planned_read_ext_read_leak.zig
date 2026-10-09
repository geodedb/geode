// SONNY-2653 regression: planned reads leaked the storage adapter's read copy
// of every extended (non-string) property value they checked a pattern
// against.
//
// The adapter's allocating decode copies an extended value's bytes (a list,
// say) onto the caller's allocator exactly as it copies a string's. The
// planned read frees what it reads with `freeStoragePropertyValue`, which
// freed only strings. `nodeMatchesPatternBySlot` and `edgeMatchesPattern` read
// every property of each candidate on the executor's own allocator (`gpa` in
// production, with or without a per-query arena installed) whenever the
// pattern has inline properties, so each candidate leaked the bytes of every
// extended value it held. Without a per-query arena, `materializeNode` /
// `materializeEdge` leaked them the same way.
//
// The harness mirrors a production request: a persisted in-process
// deployment, a query scratch arena installed on the thread (as both
// transports do), and the executor on a leak-checked allocator. Each query
// returns the nodes or edges it checked, whose list properties are checked
// against the seed, and pins that the planned read served it. The lists come
// back inside the node or edge, which the scratch arena owns: a projected
// `n.l` would add the planned read's own projection clone of the list, which
// the final projection copies and drops (a separate leak, not this one).
//
// CANARY: REQ=REQ-SONNY-2653-PLANNED-READ-EXT-LEAK; FEATURE="PlannedReadStorageReads"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2653_planned_read_ext_read_leak.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const planned_read_runtime = geode.planned_read_runtime;
const query_arena = geode.query_arena;
const Value = geode.value_types.Value;

const pairs: usize = 12;

/// `pairs` `(:V {g, s, l})-[:R {w, l}]->(:U {s})` pairs: g = 'grp' on every
/// `:V`, s = 'v00'.., l = ['v00', 'w00']..; the edge has w = 1 and
/// l = ['e00', 'f00']..; the `:U` end has s = 'u00'...
fn seed(h: *harness.Harness) !void {
    const aa = h.arena.allocator();
    for (0..pairs) |i| {
        var r = try h.run(try std.fmt.allocPrint(
            aa,
            "CREATE (:V {{g: 'grp', s: 'v{d:0>2}', l: ['v{d:0>2}', 'w{d:0>2}']}})-[:R {{w: 1, l: ['e{d:0>2}', 'f{d:0>2}']}}]->(:U {{s: 'u{d:0>2}'}})",
            .{ i, i, i, i, i, i },
        ));
        r.deinit(aa);
    }
}

/// Run `query` through the executor as a request would: a scratch arena
/// installed on the thread, and the executor on `allocator`. Calls `check`
/// with the result, then frees it.
fn runRequest(h: *harness.Harness, allocator: std.mem.Allocator, query: []const u8, check: *const fn ([]const []Value) anyerror!void) !u64 {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const prev = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev);

    var parsed = try geode.parseGql(query, h.arena.allocator());
    defer parsed.deinit();
    planned_read_runtime.resetPathRowsMaterialized();
    var result = try execution.executeStatementWithContext(allocator, parsed.program.statements[0], h.ctx);
    defer result.deinit(allocator);
    try check(result.rows);
    return planned_read_runtime.getPathRowsMaterialized();
}

/// Run `query` on a counting wrapper over `std.testing.allocator` and return
/// how many of its allocations were never freed. The whole test is
/// leak-checked as well.
fn leaksOf(h: *harness.Harness, query: []const u8, want_materialized: u64, check: *const fn ([]const []Value) anyerror!void) !usize {
    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    const materialized = try runRequest(h, counting.allocator(), query, check);
    try testing.expectEqual(want_materialized, materialized);
    return counting.allocations - counting.deallocations;
}

/// `list` is the list [a, b] with the prefixes the seed gave pair k.
fn expectList(list_value: geode.graph_store.PropertyValue, a: u8, b: u8, k: usize) !void {
    var buf: [8]u8 = undefined;
    const list = list_value.ExtValue.List;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "{c}{d:0>2}", .{ a, k }), list[0].Str);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "{c}{d:0>2}", .{ b, k }), list[1].Str);
}

/// The index a `:V` `s` value encodes ('v07' -> 7).
fn indexOf(s: []const u8) !usize {
    return std.fmt.parseInt(usize, s[1..], 10);
}

/// Every `:V` node comes back once, holding the list the seed gave it.
fn checkNodeLists(rows: []const []Value) anyerror!void {
    try testing.expectEqual(pairs, rows.len);
    var seen = [_]bool{false} ** pairs;
    for (rows) |row| {
        const node = row[0].Node;
        const k = try indexOf((node.properties.get("s") orelse return error.NodePropertyMissing).String);
        try testing.expect(!seen[k]);
        seen[k] = true;
        try expectList(node.properties.get("l") orelse return error.NodePropertyMissing, 'v', 'w', k);
    }
}

/// Every edge comes back once, holding the list the seed gave it, beside the
/// `s` of its `:V` end.
fn checkEdgeLists(rows: []const []Value) anyerror!void {
    try testing.expectEqual(pairs, rows.len);
    var seen = [_]bool{false} ** pairs;
    for (rows) |row| {
        const k = try indexOf(row[0].Str);
        try testing.expect(!seen[k]);
        seen[k] = true;
        try expectList(row[1].Edge.properties.get("l") orelse return error.EdgePropertyMissing, 'e', 'f', k);
    }
}

test "SONNY-2653: a planned read checking a node's inline properties frees the list it reads" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seed(&h);

    // Every `:V` shares g, so each of the 12 candidates is checked against the
    // pattern, reading all of its properties, its list included. The row
    // returns the node, list and all.
    const leaked = try leaksOf(&h, "MATCH (n:V {g: 'grp'}) RETURN n", pairs, checkNodeLists);
    if (leaked != 0) std.debug.print("node inline props: {d} allocations leaked\n", .{leaked});
    try testing.expectEqual(@as(usize, 0), leaked);
}

test "SONNY-2653: a planned read checking an edge's inline properties frees the list it reads" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seed(&h);

    // Each of the 12 edges is checked against `{w: 1}`, reading all of its
    // properties, its list included. The row returns the edge, list and all.
    const leaked = try leaksOf(&h, "MATCH (a:V)-[r:R {w: 1}]->(b:U) RETURN a.s, r", pairs, checkEdgeLists);
    if (leaked != 0) std.debug.print("edge inline props: {d} allocations leaked\n", .{leaked});
    try testing.expectEqual(@as(usize, 0), leaked);
}
