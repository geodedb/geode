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
const rls_types = @import("rls_types");

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

    /// Seed a single Taxon node with integer `value` and `rank` properties.
    pub fn seedWithIntValue(self: *Harness, id: []const u8, rank: []const u8, value: i64) !void {
        const aa = self.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "MERGE (n:Taxon {{source_id: '{s}', rank: '{s}', value: {d}}})", .{ id, rank, value });
        var r = try self.runQuery(q);
        r.deinit(aa);
    }

    /// Seed a single Taxon node with both rank and kingdom properties.
    pub fn seedRankKingdom(self: *Harness, id: []const u8, rank: []const u8, kingdom: []const u8) !void {
        const aa = self.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "MERGE (n:Taxon {{source_id: '{s}', rank: '{s}', kingdom: '{s}'}})", .{ id, rank, kingdom });
        var r = try self.runQuery(q);
        r.deinit(aa);
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

// ── I3: dual-path parity ─────────────────────────────────────────────────────

test "GROUP BY parity: fast path and legacy produce identical group->count maps" {
    // I3: run the same GROUP BY through the fast path (no ORDER BY) and the
    // legacy path (ORDER BY c DESC forces decline via order_by gate), then compare
    // group→count maps order-insensitively to prove both paths are semantically equivalent.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedRanks("species", 10);
    try h.seedRanks("genus", 5);
    try h.seedRanks("family", 3);

    const aa = h.arena.allocator();

    // Fast path: no ORDER BY → groupByAggregateFastPath fires.
    planned_read_runtime.resetPathRowsMaterialized();
    var fast = try h.runQuery("MATCH (n:Taxon) RETURN n.rank AS r, count(*) AS c GROUP BY n.rank");
    defer fast.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    // Legacy path: ORDER BY c DESC forces the fast path to decline.
    planned_read_runtime.resetPathRowsMaterialized();
    var legacy = try h.runQuery("MATCH (n:Taxon) RETURN n.rank AS r, count(*) AS c GROUP BY n.rank ORDER BY c DESC");
    defer legacy.deinit(aa);
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);

    // Same number of groups.
    try testing.expectEqual(fast.rows.len, legacy.rows.len);

    // Build rank→count maps and compare entry-by-entry (order-insensitive).
    var fast_map = std.StringHashMap(i64).init(aa);
    var legacy_map = std.StringHashMap(i64).init(aa);
    for (fast.rows) |row| {
        const key = switch (row[0]) {
            .Str => |s| s,
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
        const key = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        const cnt: i64 = switch (row[1]) {
            .Int => |v| v,
            .BigInt => |v| @intCast(v),
            else => continue,
        };
        try legacy_map.put(key, cnt);
    }
    var it = fast_map.iterator();
    while (it.next()) |entry| {
        const legacy_cnt = legacy_map.get(entry.key_ptr.*) orelse return error.MissingGroupInLegacy;
        try testing.expectEqual(entry.value_ptr.*, legacy_cnt);
    }
}

// ── I4: RLS/tenant-active decline test ───────────────────────────────────────

test "GROUP BY declines when RLS user+policy context active, legacy returns correct result" {
    // I4: install a label deny policy (for a label absent from our data) to make
    // activeRlsPoliciesConfigured() = true.  With ctx.user set, countFastPathRlsAllowed()
    // returns false → fast path declines → legacy executor runs and returns correct result.
    //
    // Signal for decline: execution.wouldEvaluateRLS() is the direct predicate that
    // countFastPathRlsAllowed() tests.  When wouldEvaluateRLS() is true, planned_read_runtime
    // is also bypassed (see query_execution.zig), so getPathRowsMaterialized() is NOT the
    // right signal here — it stays 0 because the RLS-aware legacy executor runs directly.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedRanks("species", 4);
    try h.seedRanks("genus", 3);

    // Install a deny policy for a label NOT in our data (HiddenLabel) so that
    // activeRlsPoliciesConfigured() is true while the legacy GROUP BY result is unchanged.
    var label_engine = rls_types.RLSFilterEngine.init(testing.allocator);
    defer label_engine.deinit();
    try label_engine.addDenyPolicy("default", "HiddenLabel", "");
    rls_types.setGlobalRLSFilterEngine(&label_engine);
    defer rls_types.setGlobalRLSFilterEngine(null);

    // Set a non-null user on the context; combined with the policy above this
    // makes countFastPathRlsAllowed() = false.
    h.ctx.user = "testuser";
    defer {
        h.ctx.user = null;
    }

    // Verify the RLS gate is armed: this is the direct predicate that makes the
    // GROUP BY fast path decline.  Push context so wouldEvaluateRLS() sees it.
    {
        const prev_ctx = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev_ctx);
        try testing.expect(execution.wouldEvaluateRLS());
        try testing.expect(execution.activeRlsPoliciesConfigured());
    }

    // Run the query — fast path declines, RLS-aware legacy executor produces
    // the correct GROUP BY result for the Taxon data.
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.rank AS r, count(*) AS c GROUP BY n.rank");
    defer r.deinit(h.arena.allocator());

    // Legacy result is still correct.
    try testing.expectEqual(@as(usize, 2), r.rows.len);
    try testing.expectEqual(@as(usize, 4), findGroupByRank(r.rows, "species") orelse return error.MissingSpecies);
    try testing.expectEqual(@as(usize, 3), findGroupByRank(r.rows, "genus") orelse return error.MissingGenus);
}

// ── I5: avg / min / max type-tag correctness and multi-key GROUP BY ──────────

test "GROUP BY avg integer group emits Int (parity with legacy)" {
    // I5: pure-integer avg inputs must emit Value{ .Int } (integer divide),
    // matching the legacy computeGroupAggregation in execution.zig.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // Seed: rank="a", values 10 and 20 → avg = 15 (integer divide).
    try h.seedWithIntValue("avg_a0", "a", 10);
    try h.seedWithIntValue("avg_a1", "a", 20);
    // rank="b", values 10 and 21 → avg = @divTrunc(31, 2) = 15.
    try h.seedWithIntValue("avg_b0", "b", 10);
    try h.seedWithIntValue("avg_b1", "b", 21);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.rank AS r, avg(n.value) AS a GROUP BY n.rank");
    defer r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 2), r.rows.len);

    for (r.rows) |row| {
        // avg column is index 1; must be .Int (not .Double) for pure-integer inputs.
        const rank_str = switch (row[0]) {
            .Str => |s| s,
            else => return error.ExpectedStr,
        };
        const avg_val = row[1];
        const expected_int: i64 = if (std.mem.eql(u8, rank_str, "a")) 15 else 15; // both 15
        switch (avg_val) {
            .Int => |v| try testing.expectEqual(expected_int, v),
            else => return error.ExpectedIntTagForAvg,
        }
    }
}

test "GROUP BY min/max integer group emits Int (type-tag correctness)" {
    // I5: min and max over pure-integer inputs must emit Value{ .Int }.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedWithIntValue("mm0", "g", 3);
    try h.seedWithIntValue("mm1", "g", 10);
    try h.seedWithIntValue("mm2", "g", 5);

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.rank AS r, min(n.value) AS mn, max(n.value) AS mx GROUP BY n.rank");
    defer r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try testing.expectEqual(@as(usize, 1), r.rows.len);

    const row = r.rows[0];
    try testing.expect(row.len >= 3);
    // min should be 3 as Int
    switch (row[1]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => return error.ExpectedIntTagForMin,
    }
    // max should be 10 as Int
    switch (row[2]) {
        .Int => |v| try testing.expectEqual(@as(i64, 10), v),
        else => return error.ExpectedIntTagForMax,
    }
}

test "GROUP BY multi-key: rank + kingdom produces correct group counts" {
    // I5: multi-key GROUP BY `RETURN n.rank, n.kingdom, count(*)`.
    // The fast path must correctly handle multiple GROUP BY keys.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    // 3 nodes: (species, Animalia), (species, Animalia), (genus, Plantae)
    for ([_]struct { id: []const u8, rank: []const u8, kingdom: []const u8 }{
        .{ .id = "mk0", .rank = "species", .kingdom = "Animalia" },
        .{ .id = "mk1", .rank = "species", .kingdom = "Animalia" },
        .{ .id = "mk2", .rank = "genus", .kingdom = "Plantae" },
    }) |node| {
        const q = try std.fmt.allocPrint(aa, "MERGE (n:Taxon {{source_id: '{s}', rank: '{s}', kingdom: '{s}'}})", .{ node.id, node.rank, node.kingdom });
        var res = try h.runQuery(q);
        res.deinit(aa);
    }

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n.rank AS r, n.kingdom AS k, count(*) AS c GROUP BY n.rank, n.kingdom");
    defer r.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    // 2 distinct (rank, kingdom) groups
    try testing.expectEqual(@as(usize, 2), r.rows.len);

    // Find the (species, Animalia) group and verify count = 2
    var found_species: bool = false;
    var found_genus: bool = false;
    for (r.rows) |row| {
        if (row.len < 3) continue;
        const rank_s = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        const kingdom_s = switch (row[1]) {
            .Str => |s| s,
            else => continue,
        };
        const cnt: i64 = switch (row[2]) {
            .Int => |v| v,
            .BigInt => |v| @intCast(v),
            else => continue,
        };
        if (std.mem.eql(u8, rank_s, "species") and std.mem.eql(u8, kingdom_s, "Animalia")) {
            try testing.expectEqual(@as(i64, 2), cnt);
            found_species = true;
        }
        if (std.mem.eql(u8, rank_s, "genus") and std.mem.eql(u8, kingdom_s, "Plantae")) {
            try testing.expectEqual(@as(i64, 1), cnt);
            found_genus = true;
        }
    }
    try testing.expect(found_species);
    try testing.expect(found_genus);
}
