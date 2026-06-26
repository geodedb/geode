// GAP-ENT-0002 — streaming GROUP BY / DISTINCT fast path regression test.
//
// Before fix: `MATCH (n:Taxon) RETURN n.rank AS r, count(*) AS c GROUP BY n.rank`
// falls to planned_read_runtime which materialises one row per node → O(graph) + OOM at scale.
//
// After fix: groupByAggregateFastPath detects the single-chain labeled node pattern
// with GROUP BY or RETURN DISTINCT and accumulates per-group AggAcc during the slot
// scan: O(nodes) time, O(distinct-groups) space.
// planned_read_runtime.executeIfSupported is never called; getPathRowsMaterialized() stays at 0.
//
// CANARY: REQ=GAP-ENT-0002; FEATURE="GroupByStreamingFastPath"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap_ent0002_groupby_streaming.zig; OWNER=execution; UPDATED=2026-06-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
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
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Seed `count` Taxon nodes with the given `rank` property value.
    /// Nodes are given unique source_ids so they don't collide.
    pub fn seedRanks(self: *Harness, rank: []const u8, count: usize) !void {
        const aa = self.arena.allocator();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (n:Taxon {{source_id: '{s}_{d}', rank: '{s}'}})",
                .{ rank, i, rank },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

/// Find the row in `rows` where column 0 is the string `rank_val`.
/// Returns the count value (column 1) as usize, or null if not found.
fn findGroupByRank(rows: [][]Value, rank_val: []const u8) ?usize {
    for (rows) |row| {
        if (row.len < 2) continue;
        const key = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, key, rank_val)) continue;
        return switch (row[1]) {
            .Int => |v| @intCast(v),
            .BigInt => |v| @intCast(v),
            else => null,
        };
    }
    return null;
}

/// Find a DISTINCT row where column 0 is the string `val`.
fn findDistinctRow(rows: [][]Value, val: []const u8) bool {
    for (rows) |row| {
        if (row.len < 1) continue;
        const key = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, key, val)) return true;
    }
    return false;
}

test "GROUP BY uses streaming fast path (no row materialization)" {
    // Seed: species=10, genus=5, family=3, order=2 → 20 total Taxon nodes
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedRanks("species", 10);
    try h.seedRanks("genus", 5);
    try h.seedRanks("family", 3);
    try h.seedRanks("order", 2);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.rank AS r, count(*) AS c GROUP BY n.rank");
    defer r.deinit(h.arena.allocator());

    // Correctness: 4 distinct groups
    try testing.expectEqual(@as(usize, 4), r.rows.len);

    // Order-insensitive correctness checks
    try testing.expectEqual(@as(usize, 10), findGroupByRank(r.rows, "species") orelse return error.MissingSpecies);
    try testing.expectEqual(@as(usize, 5), findGroupByRank(r.rows, "genus") orelse return error.MissingGenus);
    try testing.expectEqual(@as(usize, 3), findGroupByRank(r.rows, "family") orelse return error.MissingFamily);
    try testing.expectEqual(@as(usize, 2), findGroupByRank(r.rows, "order") orelse return error.MissingOrder);

    // Fast path gate: 0 rows materialized by planned_read_runtime.
    // Pre-fix: this is 20 (one per node). Post-fix: 0.
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
}

test "RETURN DISTINCT uses streaming fast path (no row materialization)" {
    // Seed same 20 nodes as above
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedRanks("species", 10);
    try h.seedRanks("genus", 5);
    try h.seedRanks("family", 3);
    try h.seedRanks("order", 2);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN DISTINCT n.rank");
    defer r.deinit(h.arena.allocator());

    // Correctness: 4 distinct rank values
    try testing.expectEqual(@as(usize, 4), r.rows.len);
    try testing.expect(findDistinctRow(r.rows, "species"));
    try testing.expect(findDistinctRow(r.rows, "genus"));
    try testing.expect(findDistinctRow(r.rows, "family"));
    try testing.expect(findDistinctRow(r.rows, "order"));

    // Fast path gate: 0 rows materialized.
    // Pre-fix: this is 20 (one per node). Post-fix: 0.
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
}

test "GROUP BY null-group: nodes missing property form a separate null group" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // 5 nodes with rank="species"
    try h.seedRanks("species", 5);
    // 3 nodes with NO rank property (use a different property key)
    const aa = h.arena.allocator();
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const q = try std.fmt.allocPrint(aa, "MERGE (n:Taxon {{source_id: 'norank_{d}'}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.rank AS r, count(*) AS c GROUP BY n.rank");
    defer r.deinit(h.arena.allocator());

    // 2 groups: "species" with count=5, null with count=3
    try testing.expectEqual(@as(usize, 2), r.rows.len);
    try testing.expectEqual(@as(usize, 5), findGroupByRank(r.rows, "species") orelse return error.MissingSpecies);

    // null group check
    var found_null: bool = false;
    for (r.rows) |row| {
        if (row.len < 2) continue;
        const is_null = switch (row[0]) {
            .Null => true,
            else => false,
        };
        if (!is_null) continue;
        const cnt = switch (row[1]) {
            .Int => |v| @as(usize, @intCast(v)),
            .BigInt => |v| @as(usize, @intCast(v)),
            else => continue,
        };
        try testing.expectEqual(@as(usize, 3), cnt);
        found_null = true;
    }
    try testing.expect(found_null);

    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
}

test "GROUP BY multi-aggregate: count(*) and sum(n.value) in same query" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // 4 Taxon nodes with rank="a" and value=10,20,30,40
    const values = [_]i64{ 10, 20, 30, 40 };
    const aa = h.arena.allocator();
    for (values, 0..) |v, idx| {
        const q = try std.fmt.allocPrint(aa, "MERGE (n:Taxon {{source_id: 'a_{d}', rank: 'a', value: {d}}})", .{ idx, v });
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.rank AS r, count(*) AS c, sum(n.value) AS s GROUP BY n.rank");
    defer r.deinit(h.arena.allocator());

    // 1 group: rank="a", count=4, sum=100
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    const row = r.rows[0];
    try testing.expect(row.len >= 3);

    // rank should be "a"
    const rank_str = switch (row[0]) {
        .Str => |s| s,
        else => return error.ExpectedString,
    };
    try testing.expectEqualStrings("a", rank_str);

    // count should be 4
    const cnt = switch (row[1]) {
        .Int => |v| @as(usize, @intCast(v)),
        .BigInt => |v| @as(usize, @intCast(v)),
        else => return error.ExpectedInt,
    };
    try testing.expectEqual(@as(usize, 4), cnt);

    // sum should be 100
    const sum_val: i64 = switch (row[2]) {
        .Int => |v| v,
        .Double => |v| @intFromFloat(v),
        else => return error.ExpectedNumeric,
    };
    try testing.expectEqual(@as(i64, 100), sum_val);

    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
}

test "GROUP BY + ORDER BY declines to legacy path (expected materialization)" {
    // The fast path gates on q.order_by != null → returns null → legacy path fires.
    // Legacy path materializes one row per node → getPathRowsMaterialized() > 0.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedRanks("species", 3);
    try h.seedRanks("genus", 2);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.rank AS r, count(*) AS c GROUP BY n.rank ORDER BY c DESC");
    defer r.deinit(h.arena.allocator());

    // Correctness: 2 groups
    try testing.expectEqual(@as(usize, 2), r.rows.len);

    // RLS decline / legacy path check: materialized rows > 0 (planned_read_runtime ran).
    // This also serves as a regression gate: if ORDER BY suddenly bypasses the
    // decline check, this test fails alerting us to a correctness risk.
    const materialized = planned_read_runtime.getPathRowsMaterialized();
    try testing.expect(materialized > 0);
}
