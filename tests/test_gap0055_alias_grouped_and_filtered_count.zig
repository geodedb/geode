// GAP-ENT-0055 — alias-grouped GROUP BY + O(1) filtered count route to the
// exact node-property index, mirroring the DISTINCT index-served path.
//
// Live incident (Phase 6 validation, 7M store, 2026-07-05):
//   * `MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY s`  → 88s (scan)
//   * `MATCH (n:Taxon) WHERE n.source='col' RETURN count(n) AS c`        → 88s (scan)
//   * `MATCH (n:Taxon) RETURN DISTINCT n.source`                         → 106ms (index)
//
// Root cause 1 (GROUP BY): the query groups by the RETURN ALIAS `s`, which the
// parser leaves a bare Ident. Both aggregate fast paths resolved the group key
// with `extractBoundVarProperty`, which only accepts `n.<prop>` — a bare alias
// returned null → BOTH declined → the legacy path materialized O(nodes) rows to
// resolve the alias against projected columns (the 88s scan). DISTINCT never hit
// this because its key sits directly in the RETURN item expr (`n.source`).
//
// Root cause 2 (filtered count): the GAP-ENT-0019 seek fired but RE-VERIFIED
// every candidate with a per-node property read (O(matching)) — minutes for a
// high-cardinality value like `source='col'`. The exact-index posting LENGTH is
// the answer; serve it O(1).
//
// GREEN gates asserted here:
//   * alias GROUP BY  → getIndexServedAggregateTotal() delta == 1, materialized 0
//   * filtered count  → getFilteredCountIndexServedTotal() delta == 1
//   * exact results, oracle-checked against the legacy / scan path
//
// CANARY: REQ=GAP-ENT-0055; FEATURE="AliasGroupedAndFilteredIndexCount"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0055_alias_grouped_and_filtered_count.zig; OWNER=execution; UPDATED=2026-07-06

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

fn scalarCount(r: execution.ExecutionResult) !i64 {
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expectEqual(@as(usize, 1), r.rows[0].len);
    return switch (r.rows[0][0]) {
        .Int => |v| v,
        .BigInt => |v| @intCast(v),
        else => error.ExpectedNumericCount,
    };
}

// ---- Fix 1: alias-grouped GROUP BY routes to the index (the 88s headline) ----

test "0055: GROUP BY <alias> count(*) is index-served — zero materialization, exact counts" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const specs = [_]struct { src: []const u8, n: usize }{
        .{ .src = "col", .n = 40 },
        .{ .src = "gbif", .n = 25 },
        .{ .src = "itis", .n = 13 },
        .{ .src = "worms", .n = 9 },
        .{ .src = "ncbi", .n = 6 },
    };
    var total: usize = 0;
    for (specs) |s| {
        try h.seedSource(s.src, s.n);
        total += s.n;
    }

    planned_read_runtime.resetPathRowsMaterialized();
    execution.resetIndexServedAggregateTotal();
    // The exact live shape: GROUP BY references the RETURN alias `s`, not n.source.
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY s");
    defer r.deinit(h.arena.allocator());

    // Routed to the exact-index posting walk, ZERO rows materialized.
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    try testing.expectEqual(@as(usize, specs.len), r.rows.len);
    var sum: i64 = 0;
    for (specs) |s| {
        const c = findGroupCount(r.rows, s.src) orelse return error.MissingGroup;
        try testing.expectEqual(@as(i64, @intCast(s.n)), c);
        sum += c;
    }
    try testing.expectEqual(@as(i64, @intCast(total)), sum);
}

test "0055: GROUP BY <alias> with count(n) + null group — index-served, exact semantics" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedSource("col", 7);
    try h.seedSource("gbif", 3);
    try h.seedNoSource("a", 5); // null group

    planned_read_runtime.resetPathRowsMaterialized();
    execution.resetIndexServedAggregateTotal();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(n) AS c GROUP BY s");
    defer r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 3), r.rows.len); // col, gbif, null
    try testing.expectEqual(@as(i64, 7), findGroupCount(r.rows, "col") orelse return error.MissingCol);
    try testing.expectEqual(@as(i64, 3), findGroupCount(r.rows, "gbif") orelse return error.MissingGbif);
    try testing.expectEqual(@as(i64, 5), findNullGroupCount(r.rows) orelse return error.MissingNullGroup);
}

test "0055: alias GROUP BY oracle parity — equals GROUP BY n.source and legacy" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedSource("col", 9);
    try h.seedSource("gbif", 4);
    try h.seedSource("itis", 2);
    try h.seedNoSource("p", 3);
    const aa = h.arena.allocator();

    // Alias-grouped (index-served).
    execution.resetIndexServedAggregateTotal();
    var by_alias = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY s");
    defer by_alias.deinit(aa);
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());

    // Property-grouped (also index-served — the pre-0055 accepted shape).
    execution.resetIndexServedAggregateTotal();
    var by_prop = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer by_prop.deinit(aa);
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());

    // Legacy oracle (ORDER BY forces every fast path to decline).
    execution.resetIndexServedAggregateTotal();
    var legacy = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY s ORDER BY c DESC");
    defer legacy.deinit(aa);
    try testing.expectEqual(@as(u64, 0), execution.getIndexServedAggregateTotal());

    try testing.expectEqual(legacy.rows.len, by_alias.rows.len);
    try testing.expectEqual(by_prop.rows.len, by_alias.rows.len);

    const keys = [_][]const u8{ "col", "gbif", "itis" };
    for (keys) |k| {
        const a = findGroupCount(by_alias.rows, k) orelse return error.MissingAlias;
        const p = findGroupCount(by_prop.rows, k) orelse return error.MissingProp;
        const l = findGroupCount(legacy.rows, k) orelse return error.MissingLegacy;
        try testing.expectEqual(p, a);
        try testing.expectEqual(l, a);
    }
    try testing.expectEqual(
        findNullGroupCount(by_prop.rows) orelse return error.MissingNullProp,
        findNullGroupCount(by_alias.rows) orelse return error.MissingNullAlias,
    );
}

test "0055: DISTINCT stays index-served (control — never regressed)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedSource("col", 5);
    try h.seedSource("gbif", 4);

    execution.resetIndexServedAggregateTotal();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN DISTINCT n.source AS s");
    defer r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(u64, 1), execution.getIndexServedAggregateTotal());
    try testing.expectEqual(@as(usize, 2), r.rows.len);
}

// ---- Fix 2: filtered count served O(1) from the posting length ----

test "0055: WHERE k=v count(n) served O(1) from posting length — exact" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedSource("col", 40); // high-cardinality value (the 88s headline)
    try h.seedSource("gbif", 11);
    try h.seedNoSource("z", 7);

    planned_read_runtime.resetPathRowsMaterialized();
    execution.resetFilteredCountIndexServedTotal();
    var r = try h.runQuery("MATCH (n:Taxon) WHERE n.source = 'col' RETURN count(n) AS c");
    defer r.deinit(h.arena.allocator());

    // Routed to the O(1) posting-length accessor (no candidate re-verify walk).
    try testing.expectEqual(@as(u64, 1), execution.getFilteredCountIndexServedTotal());
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(i64, 40), try scalarCount(r));
}

test "0055: filtered count parity — index O(1) equals the full scan" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedSource("col", 18);
    try h.seedSource("gbif", 5);
    const aa = h.arena.allocator();

    // Index O(1) path.
    execution.resetFilteredCountIndexServedTotal();
    var fast = try h.runQuery("MATCH (n:Taxon) WHERE n.source = 'gbif' RETURN count(n) AS c");
    defer fast.deinit(aa);
    try testing.expectEqual(@as(u64, 1), execution.getFilteredCountIndexServedTotal());
    const fast_c = try scalarCount(fast);

    // Full-scan oracle: an ordering op is NOT seek-eligible → the O(label) scan
    // serves it. `> ''` matches every non-null string source (col + gbif).
    execution.resetFilteredCountIndexServedTotal();
    var scan = try h.runQuery("MATCH (n:Taxon) WHERE n.source > '' RETURN count(n) AS c");
    defer scan.deinit(aa);
    try testing.expectEqual(@as(u64, 0), execution.getFilteredCountIndexServedTotal());
    const scan_c = try scalarCount(scan);

    try testing.expectEqual(@as(i64, 5), fast_c);
    try testing.expectEqual(@as(i64, 23), scan_c); // 18 + 5
}

test "0055: filtered count on an absent value is an authoritative 0 (index-served)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedSource("col", 6);

    execution.resetFilteredCountIndexServedTotal();
    var r = try h.runQuery("MATCH (n:Taxon) WHERE n.source = 'doesnotexist' RETURN count(n) AS c");
    defer r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(u64, 1), execution.getFilteredCountIndexServedTotal());
    try testing.expectEqual(@as(i64, 0), try scalarCount(r));
}

test "0055: non-seek-eligible predicate declines O(1), scan serves exact count" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // A numeric-looking literal is NOT seek-eligible (cross-type coercion risk),
    // so the O(1) posting path declines and the full scan serves it correctly.
    const aa = h.arena.allocator();
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const q = try std.fmt.allocPrint(aa, "MERGE (n:Taxon {{source_id: 'r_{d}', rank: '2'}})", .{i});
        var r0 = try h.runQuery(q);
        r0.deinit(aa);
    }
    try h.seedSource("col", 4); // rank absent → does not match

    execution.resetFilteredCountIndexServedTotal();
    var r = try h.runQuery("MATCH (n:Taxon) WHERE n.rank = '2' RETURN count(n) AS c");
    defer r.deinit(aa);
    try testing.expectEqual(@as(u64, 0), execution.getFilteredCountIndexServedTotal());
    try testing.expectEqual(@as(i64, 6), try scalarCount(r));
}
