// SONNY-2668 regression: a HAVING on a grouping key dropped every group.
//
// The grouped projection (`executeWithClauseWithGroupByAndParams`, shared by
// the planned read's RETURN and WITH stages and by the legacy executor's WITH
// stages) evaluated HAVING over the grouped row alone, whose names are the
// projected columns. `GROUP BY n.g HAVING n.g <> 'a'` names `n`, which is not
// a projected column, so `n.g` evaluated to NULL, the comparison to NULL, and
// every group failed: 0 groups instead of 2.
//
// HAVING now resolves a name against the projected columns first (aliases,
// and unaliased items' expression names), then against the group's first
// input row. Every row of a group shares its grouping key, so `n.g` there is
// the group's key.
//
// Covered on a persisted deployment (the planned read serves these: the GROUP
// BY fast paths decline a HAVING) at the RETURN and at a WITH, and on an
// in-memory deployment through a WITH stage (the legacy executor's use of the
// same function). The expected groups come from the seed.
//
// CANARY: REQ=REQ-SONNY-2668-HAVING-GROUP-KEY; FEATURE="GroupedHaving"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2668_having_group_key.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

/// An in-process deployment: persisted (the storage adapter exists, so reads
/// take the planned read) or in-memory (no adapter: the legacy executor).
const Deployment = struct {
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,

    fn init(persisted: bool) !Deployment {
        const allocator = testing.allocator;
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        var tmp: ?std.testing.TmpDir = null;
        var data_dir: ?[]u8 = null;
        errdefer {
            if (data_dir) |d| allocator.free(d);
            if (tmp) |*t| t.cleanup();
        }
        if (persisted) {
            tmp = std.testing.tmpDir(.{});
            data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.?.sub_path);
            graph_store.setDataDirOverride(allocator, data_dir.?);
        }
        _ = graph_store.getGlobalStore(allocator);
        // Fail loud rather than test the wrong deployment.
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .ctx = .{ .catalog = catalog } };
    }

    fn deinit(self: *Deployment) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        if (self.data_dir) |d| testing.allocator.free(d);
        if (self.tmp) |*t| t.cleanup();
    }

    fn run(self: *Deployment, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// 25 `:G` nodes: g = 'a' for i = 0..9, 'b' for 10..19, 'c' for 20..24.
    fn seed(self: *Deployment) !void {
        const aa = self.arena.allocator();
        for (0..25) |i| {
            const g: []const u8 = if (i < 10) "a" else if (i < 20) "b" else "c";
            var r = try self.run(try std.fmt.allocPrint(aa, "CREATE (:G {{i: {d}, g: '{s}'}})", .{ i, g }));
            r.deinit(aa);
        }
    }
};

fn renderRow(aa: std.mem.Allocator, row: []const Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (row, 0..) |cell, c| {
        if (c > 0) try out.append(aa, '|');
        switch (cell) {
            .Str => |s| try out.appendSlice(aa, s),
            .Int => |n| try out.print(aa, "{d}", .{n}),
            else => return error.UnexpectedCellKind,
        }
    }
    return out.toOwnedSlice(aa);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `query` returns exactly the groups `want`, in any order. When
/// `materialized` is given, the planned read served it and materialized that
/// many rows. Returns the groups in serve order.
fn expectGroups(d: *Deployment, query: []const u8, want: []const []const u8, materialized: ?u64) ![][]const u8 {
    const aa = d.arena.allocator();
    planned_read_runtime.resetPathRowsMaterialized();
    var result = try d.run(query);
    defer result.deinit(aa);
    const served = planned_read_runtime.getPathRowsMaterialized();
    const rows = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, 0..) |row, i| rows[i] = try renderRow(aa, row);
    const sorted = try aa.dupe([]const u8, rows);
    std.mem.sort([]const u8, sorted, {}, lessThan);
    if (sorted.len != want.len) {
        std.debug.print("{s}: expected {d} groups, found {d}\n", .{ query, want.len, sorted.len });
        return error.TestExpectedEqual;
    }
    for (want, sorted) |w, g| try testing.expectEqualStrings(w, g);
    if (materialized) |n| try testing.expectEqual(n, served);
    return rows;
}

test "SONNY-2668: a HAVING on the grouping key keeps the groups that pass, on a planned read" {
    harness.silenceEngineLogs();
    var d = try Deployment.init(true);
    defer d.deinit();
    try d.seed();

    _ = try expectGroups(&d, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING n.g <> 'a'", &.{ "b", "c" }, 25);
    _ = try expectGroups(&d, "MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g HAVING n.g <> 'a'", &.{ "b|10", "c|5" }, 25);
    // The key, beside an aggregate alias.
    _ = try expectGroups(&d, "MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g HAVING n.g <> 'a' AND c > 7", &.{"b|10"}, 25);
    // The window applies to the groups that pass.
    const all = try expectGroups(&d, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING n.g <> 'a'", &.{ "b", "c" }, 25);
    _ = try expectGroups(&d, "MATCH (n:G) RETURN n.g GROUP BY n.g HAVING n.g <> 'a' LIMIT 1", all[0..1], 25);
}

test "SONNY-2668: a HAVING on a projected alias or an aggregate alias is unchanged" {
    harness.silenceEngineLogs();
    var d = try Deployment.init(true);
    defer d.deinit();
    try d.seed();

    _ = try expectGroups(&d, "MATCH (n:G) RETURN n.g AS k GROUP BY n.g HAVING k <> 'a'", &.{ "b", "c" }, 25);
    _ = try expectGroups(&d, "MATCH (n:G) RETURN n.g, count(*) AS c GROUP BY n.g HAVING c > 7", &.{ "a|10", "b|10" }, 25);
}

fn expectWithStageGroups(persisted: bool) !void {
    harness.silenceEngineLogs();
    var d = try Deployment.init(persisted);
    defer d.deinit();
    try d.seed();
    _ = try expectGroups(&d, "MATCH (n:G) WITH n.g AS k, count(*) AS c GROUP BY n.g HAVING n.g <> 'a' RETURN k, c", &.{ "b|10", "c|5" }, null);
}

test "SONNY-2668: a HAVING on the grouping key keeps the groups that pass, at a planned read's WITH" {
    try expectWithStageGroups(true);
}

test "SONNY-2668: a HAVING on the grouping key keeps the groups that pass, at the legacy executor's WITH" {
    // In memory there is no storage adapter, so the legacy executor serves the
    // read, and its WITH stage groups in the same shared function.
    try expectWithStageGroups(false);
}
