// GAP-ENT-0043 T1 — index-served GROUP BY / DISTINCT / count-by-value regression.
//
// Live incident (2026-07-05, ~10M nodes): `GROUP BY source count(*)` ran 60s+
// (later OOM-killed the server) because GROUP BY materialized one FULL node row
// per matching node before aggregating. The exact node-property index already
// holds the whole answer for the count-only shapes: its postings for
// (label, key) are the distinct values and each posting LENGTH is the group
// count. T1 serves those shapes O(distinct): one posting walk + ONE
// single-property read per distinct value.
//
// GREEN(A) gates asserted here:
//   * getIndexServedAggregateTotal() delta == 1 (the query was index-served)
//   * getPathRowsMaterialized() == 0 (zero node materialization)
//   * exact results (oracle-checked against the legacy path where noted)
// Shapes oracle-checked: normal 8-value key, empty label, all-null key, single
// value, null group mix, non-indexed key (lean mode → declines → streaming
// path serves), WHERE / non-key aggregate / multi-key declines.
//
// CANARY: REQ=GAP-ENT-0043; FEATURE="IndexServedAggregate"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0043_index_served_aggregate.zig; OWNER=execution; UPDATED=2026-07-05

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
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

    /// Seed `count` Taxon nodes carrying `source` = `src` (unique source_ids).
    pub fn seedSource(self: *Harness, src: []const u8, count: usize) !void {
        const aa = self.arena.allocator();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (n:Taxon {{source_id: '{s}_{d}', source: '{s}'}})",
                .{ src, i, src },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }

    /// Seed `count` Taxon nodes WITHOUT the `source` property.
    pub fn seedNoSource(self: *Harness, tag: []const u8, count: usize) !void {
        const aa = self.arena.allocator();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const q = try std.fmt.allocPrint(aa, "MERGE (n:Taxon {{source_id: 'nosrc_{s}_{d}'}})", .{ tag, i });
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

fn findGroupCount(rows: [][]Value, key: []const u8) ?i64 {
    for (rows) |row| {
        if (row.len < 2) continue;
        const k = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, k, key)) continue;
        return switch (row[1]) {
            .Int => |v| v,
            .BigInt => |v| @intCast(v),
            else => null,
        };
    }
    return null;
}

fn findNullGroupCount(rows: [][]Value) ?i64 {
    for (rows) |row| {
        if (row.len < 2) continue;
        if (row[0] != .Null) continue;
        return switch (row[1]) {
            .Int => |v| v,
            .BigInt => |v| @intCast(v),
            else => null,
        };
    }
    return null;
}

test "T1: indexed GROUP BY count(*) is index-served — zero materialization, exact counts" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // 8-value source prop, mixed cardinality (the live headline shape).
    const specs = [_]struct { src: []const u8, n: usize }{
        .{ .src = "col", .n = 40 },
        .{ .src = "gbif", .n = 25 },
        .{ .src = "itis", .n = 13 },
        .{ .src = "worms", .n = 9 },
        .{ .src = "ncbi", .n = 6 },
        .{ .src = "bold", .n = 4 },
        .{ .src = "iucn", .n = 2 },
        .{ .src = "manual", .n = 1 },
    };
    var total: usize = 0;
    for (specs) |s| {
        try h.seedSource(s.src, s.n);
        total += s.n;
    }

    planned_read_runtime.resetPathRowsMaterialized();
    execution.resetIndexServedAggregateTotal();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r.deinit(h.arena.allocator());

    // Routing table: served from the index, ZERO rows materialized.
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    // Exact result: 8 groups, each with its exact posting count.
    try testing.expectEqual(@as(usize, specs.len), r.rows.len);
    var sum: i64 = 0;
    for (specs) |s| {
        const c = findGroupCount(r.rows, s.src) orelse return error.MissingGroup;
        try testing.expectEqual(@as(i64, @intCast(s.n)), c);
        sum += c;
    }
    try testing.expectEqual(@as(i64, @intCast(total)), sum);
}

test "T1: count(n) and count(n.key) variants are index-served with exact semantics" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedSource("col", 7);
    try h.seedSource("gbif", 3);
    try h.seedNoSource("a", 5); // null group

    // count(n): n never null → equals group size, null group included.
    planned_read_runtime.resetPathRowsMaterialized();
    execution.resetIndexServedAggregateTotal();
    var r1 = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(n) AS c GROUP BY n.source");
    defer r1.deinit(h.arena.allocator());
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 3), r1.rows.len); // col, gbif, null
    try testing.expectEqual(@as(i64, 7), findGroupCount(r1.rows, "col") orelse return error.MissingCol);
    try testing.expectEqual(@as(i64, 3), findGroupCount(r1.rows, "gbif") orelse return error.MissingGbif);
    try testing.expectEqual(@as(i64, 5), findNullGroupCount(r1.rows) orelse return error.MissingNullGroup);

    // count(n.source): GQL count(expr) skips nulls → 0 for the null group.
    execution.resetIndexServedAggregateTotal();
    var r2 = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(n.source) AS c GROUP BY n.source");
    defer r2.deinit(h.arena.allocator());
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(i64, 7), findGroupCount(r2.rows, "col") orelse return error.MissingCol2);
    try testing.expectEqual(@as(i64, 0), findNullGroupCount(r2.rows) orelse return error.MissingNullGroup2);
}

test "T1: bare DISTINCT of the indexed key is index-served" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedSource("col", 5);
    try h.seedSource("gbif", 4);
    try h.seedSource("itis", 1);

    planned_read_runtime.resetPathRowsMaterialized();
    execution.resetIndexServedAggregateTotal();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN DISTINCT n.source");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 3), r.rows.len);

    var found = [_]bool{ false, false, false };
    for (r.rows) |row| {
        const s = switch (row[0]) {
            .Str => |v| v,
            else => return error.ExpectedStr,
        };
        if (std.mem.eql(u8, s, "col")) found[0] = true;
        if (std.mem.eql(u8, s, "gbif")) found[1] = true;
        if (std.mem.eql(u8, s, "itis")) found[2] = true;
    }
    for (found) |f| try testing.expect(f);
}

test "T1: DISTINCT includes a null row when some nodes lack the key" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedSource("col", 3);
    try h.seedNoSource("d", 2);

    execution.resetIndexServedAggregateTotal();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN DISTINCT n.source");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(usize, 2), r.rows.len); // "col" + null
    var found_null = false;
    var found_col = false;
    for (r.rows) |row| {
        switch (row[0]) {
            .Null => found_null = true,
            .Str => |s| {
                if (std.mem.eql(u8, s, "col")) found_col = true;
            },
            else => {},
        }
    }
    try testing.expect(found_null);
    try testing.expect(found_col);
}

test "T1: empty label serves an empty result (index-served, no error)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // Seed a DIFFERENT label so the graph exists but Taxon has zero nodes.
    const aa = h.arena.allocator();
    var r0 = try h.runQuery("MERGE (m:Other {source_id: 'x'})");
    r0.deinit(aa);

    execution.resetIndexServedAggregateTotal();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r.deinit(aa);
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(usize, 0), r.rows.len);
}

test "T1: all-null key yields exactly the null group with the label total" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedNoSource("all", 6);

    execution.resetIndexServedAggregateTotal();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expectEqual(@as(i64, 6), findNullGroupCount(r.rows) orelse return error.MissingNullGroup);
}

test "T1: single distinct value yields one group with the full count" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedSource("col", 12);

    execution.resetIndexServedAggregateTotal();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expectEqual(@as(i64, 12), findGroupCount(r.rows, "col") orelse return error.MissingCol);
}

test "T1: oracle parity — index-served result equals the legacy (ORDER BY-declined) result" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedSource("col", 9);
    try h.seedSource("gbif", 4);
    try h.seedSource("itis", 2);
    try h.seedNoSource("p", 3);

    const aa = h.arena.allocator();

    execution.resetIndexServedAggregateTotal();
    var fast = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer fast.deinit(aa);
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());

    // ORDER BY forces every aggregate fast path to decline → legacy oracle.
    execution.resetIndexServedAggregateTotal();
    var legacy = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY n.source ORDER BY c DESC");
    defer legacy.deinit(aa);
    try testing.expectEqual(@as(u64, 0), execution.getIndexServedAggregateTotal());

    try testing.expectEqual(legacy.rows.len, fast.rows.len);
    // Compare group→count maps order-insensitively (null key serialized "null").
    var fast_map = std.StringHashMap(i64).init(aa);
    var legacy_map = std.StringHashMap(i64).init(aa);
    for (fast.rows) |row| {
        const key: []const u8 = switch (row[0]) {
            .Str => |s| s,
            .Null => "null",
            else => continue,
        };
        const cnt: i64 = switch (row[1]) {
            .Int => |v| v,
            .BigInt => |v| @intCast(v),
            else => continue,
        };
        try fast_map.put(key, cnt);
    }
    for (legacy.rows) |row| {
        const key: []const u8 = switch (row[0]) {
            .Str => |s| s,
            .Null => "null",
            else => continue,
        };
        const cnt: i64 = switch (row[1]) {
            .Int => |v| v,
            .BigInt => |v| @intCast(v),
            else => continue,
        };
        try legacy_map.put(key, cnt);
    }
    try testing.expectEqual(fast_map.count(), legacy_map.count());
    var it = fast_map.iterator();
    while (it.next()) |entry| {
        const lc = legacy_map.get(entry.key_ptr.*) orelse return error.MissingGroupInLegacy;
        try testing.expectEqual(entry.value_ptr.*, lc);
    }
}

test "T1 routing: non-indexed key (lean mode) declines to the streaming scan — result still exact" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // Written while lean mode is OFF → the key IS in the index; the gate is
    // shouldIndexProperty at QUERY time (completeness cannot be assumed).
    try h.seedSource("col", 4);
    try h.seedSource("gbif", 2);

    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);

    planned_read_runtime.resetPathRowsMaterialized();
    execution.resetIndexServedAggregateTotal();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r.deinit(h.arena.allocator());

    // Declined T1 (non-indexed key) → streaming scan served it: still zero
    // materialization, exact counts.
    try testing.expectEqual(@as(u64, 0), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 2), r.rows.len);
    try testing.expectEqual(@as(i64, 4), findGroupCount(r.rows, "col") orelse return error.MissingCol);
    try testing.expectEqual(@as(i64, 2), findGroupCount(r.rows, "gbif") orelse return error.MissingGbif);
}

test "T1 routing: WHERE / non-key aggregate / multi-key decline (served by streaming, not index)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const q = try std.fmt.allocPrint(
            aa,
            "MERGE (n:Taxon {{source_id: 'w_{d}', source: 'col', rank: 'species', value: {d}}})",
            .{ i, i },
        );
        var r0 = try h.runQuery(q);
        r0.deinit(aa);
    }

    // WHERE → decline.
    execution.resetIndexServedAggregateTotal();
    var r1 = try h.runQuery("MATCH (n:Taxon) WHERE n.rank = 'species' RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r1.deinit(aa);
    try testing.expectEqual(@as(u64, 0), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(i64, 6), findGroupCount(r1.rows, "col") orelse return error.MissingCol);

    // Aggregate over a NON-key column → decline (T2 streaming path).
    execution.resetIndexServedAggregateTotal();
    planned_read_runtime.resetPathRowsMaterialized();
    var r2 = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, sum(n.value) AS v GROUP BY n.source");
    defer r2.deinit(aa);
    try testing.expectEqual(@as(u64, 0), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 1), r2.rows.len);
    const sum_val: i64 = switch (r2.rows[0][1]) {
        .Int => |v| v,
        .Double => |v| @intFromFloat(v),
        else => return error.ExpectedNumeric,
    };
    try testing.expectEqual(@as(i64, 15), sum_val); // 0+1+2+3+4+5

    // Multi-key GROUP BY → decline.
    execution.resetIndexServedAggregateTotal();
    var r3 = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, n.rank AS k, count(*) AS c GROUP BY n.source, n.rank");
    defer r3.deinit(aa);
    try testing.expectEqual(@as(u64, 0), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(usize, 1), r3.rows.len);
}
