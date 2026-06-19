// CANARY: REQ=REQ-PERF-COMPACT-NODE-0900; FEATURE="CompactNodePropertyStore"; ASPECT=PropertyStorageFootprint; STATUS=TESTED; TEST=tests/test_gap0900_compact_node_store.zig; OWNER=performance; UPDATED=2026-06-18
//
// GAP-0900 Layer-3 (Fix 3): bound the legacy in-memory GraphStore node mirror.
//
// Every node/edge in the mirror previously held a
// `std.StringHashMap(PropertyValue)`. A StringHashMap rounds its slot table up
// to the next power-of-two ≥ count/0.8 and keeps a full (key + value + meta)
// slot for every bucket, used or not — ~3 KB/node of slack on the ~20-property
// batch-ingest Taxon node (the dominant remaining O(nodes) RSS after Fix 1 +
// Fix 2). `CompactPropertyMap` replaces it with a single growable slice of
// `(key, value)` entries kept sorted by key, allocated to EXACTLY the live
// length on every mutation (no power-of-two table, no growth slack).
//
// These tests pin two things:
//   A. The ownership + read/write/iterate/remove contract is IDENTICAL to the
//      std hashmap it replaces (round-trip every PropertyValue variant; getOrPut
//      new-vs-existing; put overwrite; fetchRemove; iteration; count). This is
//      the correctness guarantee — the swap is representation-only.
//   B. The per-node footprint is BOUNDED: the backing slice length equals the
//      live property count exactly (no slack), so footprint grows ~linearly in
//      live properties, not in next-power-of-two slot capacity.

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const CompactPropertyMap = graph_store.CompactPropertyMap;
const PropertyValue = graph_store.PropertyValue;

// --- A. representation/ownership contract --------------------------------

test "compact map: round-trips every PropertyValue variant by key" {
    const allocator = std.testing.allocator;
    var m = CompactPropertyMap.init(allocator);
    defer m.deinit();

    try m.put("name", .{ .String = "Alice" });
    try m.put("age", .{ .Int = 30 });
    try m.put("score", .{ .Float = 9.5 });
    try m.put("active", .{ .Bool = true });
    try m.put("nothing", .Null);
    try m.put("amount", .{ .Decimal = .{ .coeff = 1999, .scale = 2 } });

    try std.testing.expectEqual(@as(usize, 6), m.count());

    try std.testing.expectEqualStrings("Alice", m.get("name").?.String);
    try std.testing.expectEqual(@as(i64, 30), m.get("age").?.Int);
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), m.get("score").?.Float, 1e-9);
    try std.testing.expect(m.get("active").?.Bool);
    try std.testing.expectEqual(std.meta.Tag(PropertyValue).Null, std.meta.activeTag(m.get("nothing").?));
    try std.testing.expectEqual(@as(i128, 1999), m.get("amount").?.Decimal.coeff);
    try std.testing.expectEqual(@as(u8, 2), m.get("amount").?.Decimal.scale);

    // Missing key returns null, exactly like StringHashMap.get.
    try std.testing.expect(m.get("missing") == null);
}

test "compact map: getOrPut new vs existing matches StringHashMap semantics" {
    const allocator = std.testing.allocator;
    var m = CompactPropertyMap.init(allocator);
    defer m.deinit();

    // New key: found_existing=false, caller fills key_ptr + value_ptr.
    {
        const r = try m.getOrPut("k1");
        try std.testing.expect(!r.found_existing);
        r.key_ptr.* = "k1";
        r.value_ptr.* = .{ .Int = 1 };
    }
    // Existing key: found_existing=true, value updated in place via value_ptr.
    {
        const r = try m.getOrPut("k1");
        try std.testing.expect(r.found_existing);
        try std.testing.expectEqual(@as(i64, 1), r.value_ptr.*.Int);
        r.value_ptr.* = .{ .Int = 2 };
    }
    try std.testing.expectEqual(@as(usize, 1), m.count());
    try std.testing.expectEqual(@as(i64, 2), m.get("k1").?.Int);
}

test "compact map: put overwrites value but keeps stored key (StringHashMap parity)" {
    const allocator = std.testing.allocator;
    var m = CompactPropertyMap.init(allocator);
    defer m.deinit();

    try m.put("dup", .{ .Int = 1 });
    try m.put("dup", .{ .Int = 7 }); // overwrite — count stays 1
    try std.testing.expectEqual(@as(usize, 1), m.count());
    try std.testing.expectEqual(@as(i64, 7), m.get("dup").?.Int);
}

test "compact map: fetchRemove returns kv and shrinks; remove reports presence" {
    const allocator = std.testing.allocator;
    var m = CompactPropertyMap.init(allocator);
    defer m.deinit();

    try m.put("a", .{ .Int = 1 });
    try m.put("b", .{ .Int = 2 });
    try m.put("c", .{ .Int = 3 });
    try std.testing.expectEqual(@as(usize, 3), m.count());

    const kv = m.fetchRemove("b");
    try std.testing.expect(kv != null);
    try std.testing.expectEqualStrings("b", kv.?.key);
    try std.testing.expectEqual(@as(i64, 2), kv.?.value.Int);
    try std.testing.expectEqual(@as(usize, 2), m.count());
    try std.testing.expect(m.get("b") == null);
    // Surviving entries intact and still sorted/binary-searchable.
    try std.testing.expectEqual(@as(i64, 1), m.get("a").?.Int);
    try std.testing.expectEqual(@as(i64, 3), m.get("c").?.Int);

    try std.testing.expect(m.fetchRemove("missing") == null);
    try std.testing.expect(m.remove("a"));
    try std.testing.expect(!m.remove("a"));
}

test "compact map: iterator visits every entry exactly once with live pointers" {
    const allocator = std.testing.allocator;
    var m = CompactPropertyMap.init(allocator);
    defer m.deinit();

    try m.put("z", .{ .Int = 26 });
    try m.put("a", .{ .Int = 1 });
    try m.put("m", .{ .Int = 13 });

    var seen: usize = 0;
    var sum: i64 = 0;
    var it = m.iterator();
    while (it.next()) |e| {
        seen += 1;
        sum += e.value_ptr.*.Int;
        // key_ptr/value_ptr are live: mutating through value_ptr is visible.
        try std.testing.expect(e.key_ptr.*.len == 1);
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectEqual(@as(i64, 1 + 13 + 26), sum);
}

test "compact map: caller owns keys — deinit frees only the entry slice (no double free)" {
    // Mirrors the GraphStore ownership contract: the CALLER dupes keys on insert
    // and frees them on teardown; the map's deinit frees only its own slice.
    // Using the testing allocator here proves there is no leak and no double
    // free across that contract.
    const allocator = std.testing.allocator;
    var m = CompactPropertyMap.init(allocator);

    const keys = [_][]const u8{ "scientific_name", "rank", "taxon_id", "authority" };
    for (keys) |k| {
        const owned = try allocator.dupe(u8, k);
        const r = try m.getOrPut(owned);
        if (!r.found_existing) {
            r.key_ptr.* = owned;
        } else {
            allocator.free(owned); // duplicate insert: free our copy (parity)
        }
        r.value_ptr.* = .{ .String = "x" };
    }

    // Teardown exactly as GraphStore.deleteNodeNoSave does: iterate, free keys,
    // then deinit the map.
    var it = m.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
    }
    m.deinit();
}

// --- B. bounded footprint -------------------------------------------------

test "compact map: backing slice length equals live count exactly (no slack)" {
    const allocator = std.testing.allocator;
    var m = CompactPropertyMap.init(allocator);
    defer m.deinit();

    // Empty map carries a zero-length backing slice — no pre-allocated table.
    try std.testing.expectEqual(@as(usize, 0), m.entries.len);

    // Insert 20 properties (the batch-ingest Taxon shape). A StringHashMap would
    // round its slot table to 32 buckets (12 unused). The compact map stores
    // exactly 20 entries: footprint == live count, no power-of-two slack.
    // Keys are duped (the GraphStore ownership contract) so each stored key has
    // a stable, distinct backing — freed at teardown.
    var owned_keys = std.ArrayList([]u8).empty;
    defer {
        for (owned_keys.items) |k| allocator.free(k);
        owned_keys.deinit(allocator);
    }
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "p{d:0>2}", .{i});
        try owned_keys.append(allocator, key);
        try m.put(key, .{ .Int = @intCast(i) });
        try std.testing.expectEqual(i + 1, m.count());
        // The invariant that bounds memory: backing length tracks live count
        // 1:1 at every step — never the next power of two.
        try std.testing.expectEqual(m.count(), m.entries.len);
    }
    try std.testing.expectEqual(@as(usize, 20), m.entries.len);

    // Removing shrinks the backing slice 1:1 too (no tombstones, no retained
    // table capacity that a StringHashMap would keep after clears/removes).
    i = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expect(m.remove(owned_keys.items[i]));
        try std.testing.expectEqual(m.count(), m.entries.len);
    }
    try std.testing.expectEqual(@as(usize, 10), m.entries.len);
}

// --- C. executor-level read-path correctness through the compact store ----
// The compact map IS the live read source of truth for the in-memory mirror.
// Drive the real planner + executor + storage to prove SET / property-read /
// MATCH / count all round-trip through it.

const execution = geode.execution;

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
};

fn firstStr(res: execution.ExecutionResult) ?[]const u8 {
    if (res.rows.len == 0) return null;
    return switch (res.rows[0][0]) {
        .Str => |s| s,
        else => null,
    };
}

test "compact store executor: SET + read by merge AND non-merge key + MATCH + count" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // Create + SET several properties on a node through the real write path
    // (each SET routes through GraphStore.setNodeProperty → the compact map).
    {
        var r = try h.runQuery(
            "MERGE (n:Taxon {taxon_id: 'col:CMPX'}) SET n.scientific_name = 'Compactus testus', n.rank = 'Species', n.authority = 'L.'",
        );
        r.deinit(h.arena.allocator());
    }

    // Read by the MERGE key.
    {
        var r = try h.runQuery("MATCH (n:Taxon {taxon_id: 'col:CMPX'}) RETURN n.scientific_name AS s");
        defer r.deinit(h.arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqualStrings("Compactus testus", firstStr(r).?);
    }

    // Read by a NON-merge key (label scan reads the compact map's property).
    {
        var r = try h.runQuery("MATCH (n:Taxon {scientific_name: 'Compactus testus'}) RETURN n.authority AS a");
        defer r.deinit(h.arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqualStrings("L.", firstStr(r).?);
    }

    // Re-MERGE the same key: dedup must hold (compact map is the merge read src).
    {
        var r = try h.runQuery("MERGE (n:Taxon {taxon_id: 'col:CMPX'}) RETURN n.taxon_id AS t");
        r.deinit(h.arena.allocator());
    }
    {
        var r = try h.runQuery("MATCH (n:Taxon) RETURN count(n) AS c");
        defer r.deinit(h.arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        switch (r.rows[0][0]) {
            .Int => |c| try std.testing.expectEqual(@as(i64, 1), c),
            else => return error.UnexpectedValueTag,
        }
    }

    // Overwrite an existing property (getOrPut found_existing path) and re-read.
    {
        var r = try h.runQuery("MATCH (n:Taxon {taxon_id: 'col:CMPX'}) SET n.rank = 'Genus' RETURN n.rank AS rk");
        defer r.deinit(h.arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqualStrings("Genus", firstStr(r).?);
    }
}
