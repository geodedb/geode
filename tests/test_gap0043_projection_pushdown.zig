// GAP-ENT-0043 T2 — projection-pushdown streaming for the residual scan shapes.
//
// T1 serves indexed single-key count-only GROUP BY / DISTINCT from the exact
// index. Everything T1 cannot serve must still NEVER materialize whole-node
// rows: the scan reads ONLY the referenced property per node (single-property
// engine read — slot directory keys by property, whole-node decode skipped)
// and streams into O(groups) accumulators.
//
// The uncovered headline shape pinned here is the UNLABELED scan:
// `MATCH (n) RETURN n.source, count(*) GROUP BY n.source` (and DISTINCT /
// value-column aggregates / simple WHERE). Pre-fix these decline every fast
// path (all require exactly one label) and fall to planned_read_runtime,
// which materializes one FULL node row per node — the 2026-07-05 live
// 60s+/OOM family. Post-fix groupByAggregateFastPath covers labels.len == 0:
//   * unbounded cache → resident nodes-by-graph iteration,
//   * bounded cache  → engine page-scan (scanAllNodes) + per-key
//     getNodePropertyByHead single-property reads (no per-node getNode).
//
// GREEN(B) gates: getPathRowsMaterialized() == 0, exact results (oracle
// parity with the ORDER BY-declined legacy path), bounded-cache variant
// serves identically.
//
// CANARY: REQ=GAP-ENT-0043; FEATURE="ProjectionPushdownScan"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0043_projection_pushdown.zig; OWNER=execution; UPDATED=2026-07-05

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

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

    pub fn init(allocator: std.mem.Allocator, bounded_cache: bool) !Harness {
        if (bounded_cache) {
            if (setenv("GEODE_NODE_CACHE_ENTRIES", "64", 1) != 0) return error.SetEnvFailed;
        }
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
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Seed nodes with source + numeric value; `label2` adds a second label
    /// on some nodes so multi-label uniqueness is exercised.
    pub fn seed(self: *Harness, label: []const u8, src: []const u8, count: usize, base_value: i64) !void {
        const aa = self.arena.allocator();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (n:{s} {{source_id: '{s}_{s}_{d}', source: '{s}', value: {d}}})",
                .{ label, label, src, i, src, base_value + @as(i64, @intCast(i)) },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }

    pub fn seedNoSource(self: *Harness, label: []const u8, count: usize) !void {
        const aa = self.arena.allocator();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const q = try std.fmt.allocPrint(aa, "MERGE (n:{s} {{source_id: '{s}_nosrc_{d}'}})", .{ label, label, i });
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

test "T2: unlabeled GROUP BY count(*) streams — zero materialization, exact counts across labels" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    // Two labels sharing the graph: unlabeled MATCH must aggregate over ALL.
    try h.seed("Taxon", "col", 12, 0);
    try h.seed("Taxon", "gbif", 5, 100);
    try h.seed("Marine", "col", 4, 200); // same source under another label
    try h.seedNoSource("Taxon", 3); // null group

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r.deinit(h.arena.allocator());

    // GREEN(B): zero whole-node row materialization for the unavoidable scan.
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    try testing.expectEqual(@as(usize, 3), r.rows.len); // col, gbif, null
    try testing.expectEqual(@as(i64, 16), findGroupCount(r.rows, "col") orelse return error.MissingCol); // 12 + 4
    try testing.expectEqual(@as(i64, 5), findGroupCount(r.rows, "gbif") orelse return error.MissingGbif);
    try testing.expectEqual(@as(i64, 3), findNullGroupCount(r.rows) orelse return error.MissingNullGroup);
}

test "T2: unlabeled DISTINCT streams — zero materialization, exact distinct set" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try h.seed("Taxon", "col", 6, 0);
    try h.seed("Marine", "worms", 2, 50);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n) RETURN DISTINCT n.source");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 2), r.rows.len);
}

test "T2: unlabeled aggregate over a value column streams (agg needs the value column, not the whole node)" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    // values 0..4 under col (sum 10), 100..102 under gbif (sum 303).
    try h.seed("Taxon", "col", 5, 0);
    try h.seed("Taxon", "gbif", 3, 100);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n) RETURN n.source AS s, count(*) AS c, sum(n.value) AS v GROUP BY n.source");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 2), r.rows.len);
    for (r.rows) |row| {
        const s = switch (row[0]) {
            .Str => |v| v,
            else => return error.ExpectedStr,
        };
        const c: i64 = switch (row[1]) {
            .Int => |v| v,
            else => return error.ExpectedInt,
        };
        const v: i64 = switch (row[2]) {
            .Int => |x| x,
            .Double => |x| @intFromFloat(x),
            else => return error.ExpectedNumeric,
        };
        if (std.mem.eql(u8, s, "col")) {
            try testing.expectEqual(@as(i64, 5), c);
            try testing.expectEqual(@as(i64, 10), v);
        } else if (std.mem.eql(u8, s, "gbif")) {
            try testing.expectEqual(@as(i64, 3), c);
            try testing.expectEqual(@as(i64, 303), v);
        } else return error.UnexpectedGroup;
    }
}

test "T2: unlabeled GROUP BY with simple WHERE streams (predicate key read only)" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try h.seed("Taxon", "col", 8, 0); // values 0..7
    try h.seed("Taxon", "gbif", 4, 100); // values 100..103

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n) WHERE n.value >= 100 RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expectEqual(@as(i64, 4), findGroupCount(r.rows, "gbif") orelse return error.MissingGbif);
}

test "T2: oracle parity — unlabeled streaming result equals the legacy (ORDER BY-declined) result" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try h.seed("Taxon", "col", 7, 0);
    try h.seed("Marine", "gbif", 3, 10);
    try h.seedNoSource("Taxon", 2);

    const aa = h.arena.allocator();

    planned_read_runtime.resetPathRowsMaterialized();
    var fast = try h.runQuery("MATCH (n) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer fast.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    planned_read_runtime.resetPathRowsMaterialized();
    var legacy = try h.runQuery("MATCH (n) RETURN n.source AS s, count(*) AS c GROUP BY n.source ORDER BY c DESC");
    defer legacy.deinit(aa);
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);

    try testing.expectEqual(legacy.rows.len, fast.rows.len);
    var fast_map = std.StringHashMap(i64).init(aa);
    var legacy_map = std.StringHashMap(i64).init(aa);
    for (fast.rows) |row| {
        const key: []const u8 = switch (row[0]) {
            .Str => |s| s,
            .Null => "null",
            else => continue,
        };
        try fast_map.put(key, switch (row[1]) {
            .Int => |v| v,
            .BigInt => |v| @intCast(v),
            else => continue,
        });
    }
    for (legacy.rows) |row| {
        const key: []const u8 = switch (row[0]) {
            .Str => |s| s,
            .Null => "null",
            else => continue,
        };
        try legacy_map.put(key, switch (row[1]) {
            .Int => |v| v,
            .BigInt => |v| @intCast(v),
            else => continue,
        });
    }
    try testing.expectEqual(fast_map.count(), legacy_map.count());
    var it = fast_map.iterator();
    while (it.next()) |entry| {
        const lc = legacy_map.get(entry.key_ptr.*) orelse return error.MissingGroupInLegacy;
        try testing.expectEqual(entry.value_ptr.*, lc);
    }
}

test "T2: bounded cache — unlabeled GROUP BY serves engine-direct, zero materialization, exact" {
    var h = try Harness.init(testing.allocator, true); // 64-entry node cache
    defer h.deinit();
    // 300 nodes >> 64 cache cap: most nodes are EVICTED — the scan must read
    // the group key engine-direct (page scan + per-key single-property read),
    // never hydrate whole nodes into rows.
    try h.seed("Taxon", "col", 140, 0);
    try h.seed("Taxon", "gbif", 90, 1000);
    try h.seed("Marine", "worms", 40, 2000);
    try h.seedNoSource("Taxon", 30);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 4), r.rows.len); // col, gbif, worms, null
    try testing.expectEqual(@as(i64, 140), findGroupCount(r.rows, "col") orelse return error.MissingCol);
    try testing.expectEqual(@as(i64, 90), findGroupCount(r.rows, "gbif") orelse return error.MissingGbif);
    try testing.expectEqual(@as(i64, 40), findGroupCount(r.rows, "worms") orelse return error.MissingWorms);
    try testing.expectEqual(@as(i64, 30), findNullGroupCount(r.rows) orelse return error.MissingNullGroup);
}

test "T2: empty graph unlabeled GROUP BY yields zero rows without error" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    const aa = h.arena.allocator();
    // Create + delete so the default graph exists but is empty.
    var r0 = try h.runQuery("MERGE (n:Taxon {source_id: 'tmp'})");
    r0.deinit(aa);
    var r1 = try h.runQuery("MATCH (n:Taxon) WHERE n.source_id = 'tmp' DELETE n");
    r1.deinit(aa);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 0), r.rows.len);
}
