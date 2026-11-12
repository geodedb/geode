// SONNY-2742: `MATCH (n:L {tag: $t}) WHERE n.id > $x AND n.sub = $s RETURN
// n.id ORDER BY n.id LIMIT 10` must return every node the property map and
// the WHERE admit, in order. It was answered from only the NEWEST node the
// property map matched, before WHERE ran ([] or one row); the same query with
// the tag in WHERE, or without ORDER BY, was right. ThreadID's PAM access
// request listing has this shape.
//
// Driven through the real parse -> execute pipeline on a persisted store, as
// an admin (unscoped) session and as a tenant-scoped one, before and after a
// reopen from disk. The expected answers are spelled out; the oracle variants
// (tag in WHERE, no ORDER BY) are checked too.
//
// CANARY: REQ=REQ-SONNY-2742-PROPMAP-ORDERBY-LIMIT; FEATURE="Query Execution"; ASPECT=PropertyMapOrderByLimit; STATUS=TESTED; TEST=tests/test_sonny2742_propmap_orderby_limit.zig; OWNER=query; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const th = @import("sonny6338_tenant_harness.zig");

const Harness = th.Harness;

/// `Harness.run`, parsed as the server parses (`ORDER BY` on an expression,
/// the server's default; `geode.parseGql` takes identifier keys only).
fn run(h: *Harness, tenant: ?[]const u8, src: []const u8) !geode.execution.ExecutionResult {
    const aa = h.arena.allocator();
    var parsed = try geode.parseGqlOptions(src, aa, .{});
    defer parsed.deinit();
    const prev_scratch = geode.query_arena.pushScratchAllocator(aa);
    defer geode.query_arena.popScratchAllocator(prev_scratch);
    geode.fle_integration.setCurrentTenantId(tenant);
    defer geode.fle_integration.setCurrentTenantId(null);
    const ctx = h.ctxFor(tenant);
    const prev_ctx = geode.execution.pushActiveContext(&ctx);
    defer geode.execution.popActiveContext(prev_ctx);
    return geode.execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
}

/// Column 0 of every row, as strings, in row order.
fn strings(h: *Harness, tenant: ?[]const u8, src: []const u8) ![]const []const u8 {
    const res = try run(h, tenant, src);
    const aa = h.arena.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    for (res.rows) |row| {
        if (row.len == 0) return error.NoColumns;
        switch (row[0]) {
            .Str => |s| try out.append(aa, s),
            else => return error.UnexpectedValueType,
        }
    }
    return out.items;
}

fn sorted(aa: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const copy = try aa.dupe([]const u8, items);
    std.mem.sort([]const u8, copy, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return copy;
}

const Case = struct {
    q: []const u8,
    want: []const []const u8,
    /// The answer's order is not specified (no ORDER BY): compare as sets.
    unordered: bool = false,
};

const cases = [_]Case{
    // The ticket's shape.
    .{ .q = "MATCH (n:Req2742 {tag: 't'}) WHERE n.id > '' AND n.sub = 'A' RETURN n.id ORDER BY n.id LIMIT 10", .want = &.{ "a1", "a2" } },
    .{ .q = "MATCH (n:Req2742 {tag: 't'}) WHERE n.id > 'a1' AND n.sub = 'A' RETURN n.id ORDER BY n.id LIMIT 10", .want = &.{"a2"} },
    .{ .q = "MATCH (n:Req2742 {tag: 't'}) WHERE n.sub = 'B' RETURN n.id ORDER BY n.id LIMIT 10", .want = &.{"b1"} },
    .{ .q = "MATCH (n:Req2742 {tag: 't'}) WHERE n.sub = 'A' RETURN n.id ORDER BY n.id DESC LIMIT 10", .want = &.{ "a2", "a1" } },
    .{ .q = "MATCH (n:Req2742 {tag: 't'}) RETURN n.id ORDER BY n.id LIMIT 10", .want = &.{ "a1", "a2", "b1" } },
    .{ .q = "MATCH (n:Req2742 {tag: 't'}) WHERE n.sub = 'A' RETURN n.id ORDER BY n.id LIMIT 1", .want = &.{"a1"} },
    // The oracle variants the ticket reports as right.
    .{ .q = "MATCH (n:Req2742) WHERE n.tag = 't' AND n.id > '' AND n.sub = 'A' RETURN n.id ORDER BY n.id LIMIT 10", .want = &.{ "a1", "a2" } },
    .{ .q = "MATCH (n:Req2742 {tag: 't'}) WHERE n.id > '' AND n.sub = 'A' RETURN n.id", .want = &.{ "a1", "a2" }, .unordered = true },
};

fn seed(h: *Harness, tenant: ?[]const u8) !void {
    // Created in this order: a2 is the newest node the property map matches.
    try h.exec(tenant, "CREATE (:Req2742 {tag: 't', id: 'a1', sub: 'A'})");
    try h.exec(tenant, "CREATE (:Req2742 {tag: 't', id: 'b1', sub: 'B'})");
    try h.exec(tenant, "CREATE (:Req2742 {tag: 't', id: 'a2', sub: 'A'})");
    // Another tag, never in an answer.
    try h.exec(tenant, "CREATE (:Req2742 {tag: 'u', id: 'a0', sub: 'A'})");
}

fn check(h: *Harness, tenant: ?[]const u8, phase: []const u8) !usize {
    const aa = h.arena.allocator();
    var bad: usize = 0;
    for (cases) |c| {
        const got_raw = strings(h, tenant, c.q) catch |err| {
            std.debug.print("[{s} tenant={?s}] {s}\n  error {s}\n", .{ phase, tenant, c.q, @errorName(err) });
            bad += 1;
            continue;
        };
        const got = if (c.unordered) try sorted(aa, got_raw) else got_raw;
        const want = if (c.unordered) try sorted(aa, c.want) else c.want;
        var same = got.len == want.len;
        if (same) for (got, want) |g, w| {
            if (!std.mem.eql(u8, g, w)) same = false;
        };
        if (!same) {
            std.debug.print("[{s} tenant={?s}] {s}\n  want {any}\n  got  {any}\n", .{ phase, tenant, c.q, want, got });
            bad += 1;
        }
    }
    return bad;
}

test "SONNY-2742: a property-map MATCH with WHERE, ORDER BY and LIMIT returns every matching row, in order" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try seed(&h, null);
    var bad = try check(&h, null, "persisted");
    try h.reopen();
    bad += try check(&h, null, "reopened");
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-2742: the same for a tenant-scoped session" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try seed(&h, th.U);
    var bad = try check(&h, th.U, "persisted");
    bad += try check(&h, null, "persisted, admin");
    try h.reopen();
    bad += try check(&h, th.U, "reopened");
    try testing.expectEqual(@as(usize, 0), bad);
}
