// SONNY-2806 (round 7): MERGE when two nodes hold one merge key.
//
// MERGE's property index (graph_store.merge_prop_index) holds one node per
// (graph, label, key, value). Two nodes can hold a key: 1 and 1.0 key alike
// since round 6 (the key is the number's value), and CREATE writes no
// uniqueness. The index kept the LAST node written, and deleting or updating
// either node dropped the entry, so a later MERGE trusted the miss and
// created a third node. On a store upgraded with such a pair, which node
// MERGE matched depended on the order the nodes were hydrated in.
//
// The rule now, on the executor, the server's bulk MERGE and a reopened
// store: MERGE matches the LOWEST node id among the nodes holding the key.
// Removing a node drops the entry only when the node was its only holder;
// removing the lowest of several leaves the entry unresolved, and the next
// lookup finds the lowest remaining holder by a label scan.
//
// Also here:
//   * a number that is not an integer is not in MERGE's index (round 7,
//     Important 2); the server's MERGE resolves it through the exact
//     node-property index, and the executor by its label scan;
//   * the multi-property MERGE fallback compares stored values as the
//     executor does, so `{a: 1, d: date(...)}` no longer duplicates.
//
// CANARY: REQ=REQ-SONNY-2806-MERGE-EQUAL-HOLDERS; FEATURE="MergeIdempotency"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2806_merge_equal_holders.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const gsa = geode.graph_storage_adapter;
const Value = geode.value_types.Value;
const PropertyValue = graph_store.PropertyValue;
const PropKV = gsa.StorageAdapter.PropKV;
const G = graph_store.DEFAULT_GRAPH_NAME;

const Mode = enum {
    /// No storage adapter: the legacy executor.
    in_memory,
    /// Persisted, the node cache bounded.
    persisted,
    /// Persisted, the node cache unbounded (`GEODE_NODE_CACHE_ENTRIES=0`).
    unbounded_cache,
};

const modes = [_]Mode{ .in_memory, .persisted, .unbounded_cache };

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Param = struct { name: []const u8, value: Value };

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        if (mode == .unbounded_cache) {
            if (setenv("GEODE_NODE_CACHE_ENTRIES", "0", 1) != 0) return error.SetEnvFailed;
        }
        errdefer _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        // The catalog lives in the temporary directory in every mode.
        graph_store.setDataDirOverride(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);
        errdefer execution.cleanupCatalogInstance();
        const persisted = mode != .in_memory;
        if (!persisted) graph_store.setDataDirOverride(allocator, null);
        _ = graph_store.getGlobalStore(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
        return .{
            .mode = mode,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = .{ .catalog = catalog },
        };
    }

    fn deinit(self: *Session) void {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
    }

    /// Close the store and open it again on the same directory, cleanly or
    /// as after a crash (no final checkpoint).
    fn reopen(self: *Session, crash: bool) !void {
        const allocator = testing.allocator;
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        if (crash) graph_store.deinitGlobalStoreForTestCrash() else graph_store.deinitGlobalStore();
        graph_store.resetLazyHydrateCounters();
        graph_store.setDataDirOverride(allocator, self.data_dir);
        _ = graph_store.getGlobalStore(allocator);
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(allocator) };
    }

    fn run(self: *Session, query: []const u8, params: []const Param) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        const names = try aa.alloc([]const u8, params.len);
        const values = try aa.alloc(Value, params.len);
        for (params, names, values) |p, *n, *v| {
            n.* = p.name;
            v.* = p.value;
        }
        var ctx = self.ctx;
        ctx.query_param_names = names;
        ctx.query_param_values = values;
        const prev = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    }

    fn exec(self: *Session, query: []const u8) !void {
        var r = try self.run(query, &.{});
        r.deinit(self.arena.allocator());
    }

    fn execWith(self: *Session, query: []const u8, params: []const Param) !void {
        var r = try self.run(query, params);
        r.deinit(self.arena.allocator());
    }
};

fn renderCell(aa: std.mem.Allocator, cell: Value) ![]const u8 {
    return switch (cell) {
        .Str => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Null => "null",
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(cell)}),
    };
}

/// Every failed check, reported together.
const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, fmt, args));
    }

    fn deinit(self: *Failures) void {
        for (self.items.items) |msg| testing.allocator.free(msg);
        self.items.deinit(testing.allocator);
    }

    fn check(self: *Failures, name: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ name, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.MergeHolderWrong;
    }
};

/// `query` returns one row whose single cell renders as `want`.
fn expectValue(s: *Session, f: *Failures, query: []const u8, want: []const u8) !void {
    const aa = s.arena.allocator();
    var result = s.run(query, &.{}) catch |err| {
        try f.add("[{s}] {s}: error {s}", .{ @tagName(s.mode), query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    if (result.rows.len != 1 or result.rows[0].len != 1) {
        try f.add("[{s}] {s}: expected one cell {s}, got {d} rows", .{ @tagName(s.mode), query, want, result.rows.len });
        return;
    }
    const got = try renderCell(aa, result.rows[0][0]);
    if (!std.mem.eql(u8, got, want)) try f.add("[{s}] {s}: expected {s}, got {s}", .{ @tagName(s.mode), query, want, got });
}

/// `query` returns exactly the single-cell rows `want`, in this order after
/// sorting.
fn expectRows(s: *Session, f: *Failures, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    var result = s.run(query, &.{}) catch |err| {
        try f.add("[{s}] {s}: error {s}", .{ @tagName(s.mode), query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| g.* = if (row.len == 1) try renderCell(aa, row[0]) else "<row>";
    std.mem.sort([]const u8, got, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    const same = got.len == want.len and for (got, want) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) try f.add("[{s}] {s}: expected {{{s}}}, got {{{s}}}", .{ @tagName(s.mode), query, try std.mem.join(aa, " | ", want), try std.mem.join(aa, " | ", got) });
}

fn countOf(s: *Session, f: *Failures, label: []const u8, want: []const u8) !void {
    const q = try std.fmt.allocPrint(s.arena.allocator(), "MATCH (n:{s}) RETURN count(n) AS c", .{label});
    try expectValue(s, f, q, want);
}

// ---------------------------------------------------------------------------
// The executor
// ---------------------------------------------------------------------------

fn checkExecutor(s: *Session, f: *Failures) !void {
    // The reviewer's repro: delete the node the index held (the last one
    // written); MERGE created a third node.
    try s.exec("CREATE (:K {x: 1, t: 'int'})");
    try s.exec("CREATE (:K {x: 1.0, t: 'dec'})");
    try s.exec("MATCH (n:K {t: 'dec'}) DELETE n");
    try expectValue(s, f, "MERGE (n:K {x: 1}) RETURN n.t AS t", "'int'");
    try countOf(s, f, "K", "1");

    // Delete the lowest holder: the entry is unresolved, and MERGE finds the
    // other by a scan.
    try s.exec("CREATE (:K2 {x: 1, t: 'int'})");
    try s.exec("CREATE (:K2 {x: 1.0, t: 'dec'})");
    try s.exec("MATCH (n:K2 {t: 'int'}) DELETE n");
    try expectValue(s, f, "MERGE (n:K2 {x: 1.0}) RETURN n.t AS t", "'dec'");
    try expectValue(s, f, "MERGE (n:K2 {x: 1}) RETURN n.t AS t", "'dec'");
    try countOf(s, f, "K2", "1");

    // A SET that moves a holder off the key, equal representations.
    try s.exec("CREATE (:K3 {x: 'a', t: 'first'})");
    try s.exec("CREATE (:K3 {x: 'a', t: 'second'})");
    try s.exec("MATCH (n:K3 {t: 'first'}) SET n.x = 'b'");
    try expectValue(s, f, "MERGE (n:K3 {x: 'a'}) RETURN n.t AS t", "'second'");
    try s.exec("MATCH (n:K3 {t: 'second'}) SET n.x = 'c'");
    try expectValue(s, f, "MERGE (n:K3 {x: 'b'}) RETURN n.t AS t", "'first'");
    try countOf(s, f, "K3", "2");

    // The lowest node id wins, whichever was written last.
    try s.exec("CREATE (:K4 {x: 1.0, t: 'first'})");
    try s.exec("CREATE (:K4 {x: 1, t: 'second'})");
    try s.exec("CREATE (:K4 {x: 1.00, t: 'third'})");
    try expectValue(s, f, "MERGE (n:K4 {x: 1}) RETURN n.t AS t", "'first'");
    // A SET of an equal value keeps the entry.
    try s.exec("MATCH (n:K4 {t: 'first'}) SET n.x = 1");
    try expectValue(s, f, "MERGE (n:K4 {x: 1.0}) RETURN n.t AS t", "'first'");
    try s.exec("MATCH (n:K4 {t: 'first'}) DELETE n");
    try expectValue(s, f, "MERGE (n:K4 {x: 1}) RETURN n.t AS t", "'second'");
    try countOf(s, f, "K4", "2");
    // Every holder gone: MERGE creates exactly one.
    try s.exec("MATCH (n:K4) DELETE n");
    try expectValue(s, f, "MERGE (n:K4 {x: 1}) RETURN n.t AS t", "null");
    try expectValue(s, f, "MERGE (n:K4 {x: 1}) RETURN count(n) AS c", "1");
    try countOf(s, f, "K4", "1");

    // A number that is not an integer is not in MERGE's index; the scan
    // still finds it, by value.
    try s.exec("CREATE (:K5 {x: 1.5, t: 'dec'})");
    try s.execWith("CREATE (:K5 {x: $d, t: 'dbl'})", &.{.{ .name = "d", .value = .{ .Double = 2.5 } }});
    try expectValue(s, f, "MERGE (n:K5 {x: 1.50}) RETURN n.t AS t", "'dec'");
    try expectValue(s, f, "MERGE (n:K5 {x: 2.5}) RETURN n.t AS t", "'dbl'");
    try countOf(s, f, "K5", "2");

    // An inline map finds every holder of a shared key.
    try expectValue(s, f, "MATCH (n:K2 {x: 1}) RETURN count(n) AS c", "1");
    try s.exec("CREATE (:K6 {x: 1, t: 'int'})");
    try s.exec("CREATE (:K6 {x: 1.0, t: 'dec'})");
    try expectValue(s, f, "MATCH (n:K6 {x: 1}) RETURN count(n) AS c", "2");
    // The legacy point read returned the one node the index held.
    try expectRows(s, f, "MATCH (n:K6 {x: 1}) RETURN n.t AS t", &.{ "'dec'", "'int'" });
    try expectRows(s, f, "MATCH (n:K6 {x: 1.0}) RETURN n.t AS t", &.{ "'dec'", "'int'" });
    try s.exec("CREATE (:K7 {x: 'a', t: 'first'})");
    try s.exec("CREATE (:K7 {x: 'a', t: 'second'})");
    try expectRows(s, f, "MATCH (n:K7 {x: 'a'}) RETURN n.t AS t", &.{ "'first'", "'second'" });
    // One holder: the point read still answers from the index.
    try expectRows(s, f, "MATCH (n:K5 {x: 1.5}) RETURN n.t AS t", &.{"'dec'"});
    try expectRows(s, f, "MATCH (n:K3 {x: 'b'}) RETURN n.t AS t", &.{"'first'"});
}

test "SONNY-2806: MERGE matches the lowest remaining holder after a delete or a SET" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    for (modes) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        try checkExecutor(&s, &f);
    }
    try f.check("executor");
}

// ---------------------------------------------------------------------------
// The server's bulk MERGE (adapter.bulkMergeNode*), a persisted deployment
// ---------------------------------------------------------------------------

/// The `t` property of node `id`, or "" when it has none.
fn tOf(id: u64) []const u8 {
    const store = graph_store.getGlobalStore(testing.allocator);
    const v = store.getNodeProperty(id, "t") orelse return "";
    return switch (v) {
        .String => |t| t,
        else => "?",
    };
}

const Bulk = enum { direct, reserved_id };

fn bulkMerge(which: Bulk, label: []const u8, value: PropertyValue) !gsa.StorageAdapter.MergeResult {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    return switch (which) {
        .direct => adapter.bulkMergeNode(G, label, "x", value, &.{}, null, false),
        .reserved_id => adapter.bulkMergeNodeWithReservedId(G, graph_store.getGlobalStore(testing.allocator).reserveNodeId(), label, "x", value, &.{}, false),
    };
}

fn expectBulk(f: *Failures, which: Bulk, label: []const u8, value: PropertyValue, want_t: []const u8) !void {
    const r = bulkMerge(which, label, value) catch |err| {
        try f.add("[{s}] bulk MERGE (:{s} {{x: {any}}}): error {s}", .{ @tagName(which), label, value, @errorName(err) });
        return;
    };
    if (r.wrote) try f.add("[{s}] bulk MERGE (:{s} {{x: {any}}}): created or wrote a node", .{ @tagName(which), label, value });
    const got = tOf(r.id);
    if (!std.mem.eql(u8, got, want_t)) try f.add("[{s}] bulk MERGE (:{s} {{x: {any}}}): matched t='{s}', expected '{s}'", .{ @tagName(which), label, value, got, want_t });
}

const int1: PropertyValue = .{ .Int = 1 };
const dec10: PropertyValue = .{ .Decimal = .{ .coeff = 10, .scale = 1 } };
const dec150: PropertyValue = .{ .Decimal = .{ .coeff = 150, .scale = 2 } };

fn checkBulk(s: *Session, f: *Failures, which: Bulk) !void {
    const aa = s.arena.allocator();
    const l = struct {
        fn name(a: std.mem.Allocator, w: Bulk, base: []const u8) ![]const u8 {
            return std.fmt.allocPrint(a, "{s}{s}", .{ base, @tagName(w) });
        }
    }.name;
    const run = struct {
        fn q(sess: *Session, comptime fmt: []const u8, label: []const u8) !void {
            try sess.exec(try std.fmt.allocPrint(sess.arena.allocator(), fmt, .{label}));
        }
    }.q;

    // Delete the holder the index kept.
    const b1 = try l(aa, which, "B");
    try run(s, "CREATE (:{s} {{x: 1, t: 'int'}})", b1);
    try run(s, "CREATE (:{s} {{x: 1.0, t: 'dec'}})", b1);
    try run(s, "MATCH (n:{s} {{t: 'dec'}}) DELETE n", b1);
    try expectBulk(f, which, b1, int1, "int");
    try countOf(s, f, b1, "1");

    // Delete the lowest holder.
    const b2 = try l(aa, which, "BL");
    try run(s, "CREATE (:{s} {{x: 1, t: 'int'}})", b2);
    try run(s, "CREATE (:{s} {{x: 1.0, t: 'dec'}})", b2);
    try run(s, "MATCH (n:{s} {{t: 'int'}}) DELETE n", b2);
    try expectBulk(f, which, b2, dec10, "dec");
    try expectBulk(f, which, b2, int1, "dec");
    try countOf(s, f, b2, "1");

    // The lowest node id, as the executor matches.
    const b3 = try l(aa, which, "BO");
    try run(s, "CREATE (:{s} {{x: 1.0, t: 'first'}})", b3);
    try run(s, "CREATE (:{s} {{x: 1, t: 'second'}})", b3);
    try expectBulk(f, which, b3, int1, "first");
    try expectValue(s, f, try std.fmt.allocPrint(aa, "MERGE (n:{s} {{x: 1}}) RETURN n.t AS t", .{b3}), "'first'");

    // A DECIMAL or DOUBLE key that is not an integer: through the exact
    // index (it failed with MergeValueNotIndexable before round 6).
    const b4 = try l(aa, which, "BD");
    try run(s, "CREATE (:{s} {{x: 1.5, t: 'dec'}})", b4);
    try expectBulk(f, which, b4, dec150, "dec");
    const dbl = try geode.property_value_codec.valueToPropertyValue(aa, .{ .Double = 1.5 });
    try expectBulk(f, which, b4, dbl, "dec");
    try countOf(s, f, b4, "1");
    // A new one is created once, then found.
    const created = bulkMerge(which, b4, .{ .Decimal = .{ .coeff = 275, .scale = 2 } }) catch |err| blk: {
        try f.add("[{s}] bulk MERGE a new decimal: error {s}", .{ @tagName(which), @errorName(err) });
        break :blk null;
    };
    if (created) |r| if (!r.wrote) try f.add("[{s}] bulk MERGE a new decimal: matched a node", .{@tagName(which)});
    const again = bulkMerge(which, b4, .{ .Decimal = .{ .coeff = 2750, .scale = 3 } }) catch |err| blk: {
        try f.add("[{s}] bulk MERGE the new decimal again: error {s}", .{ @tagName(which), @errorName(err) });
        break :blk null;
    };
    if (again) |r| if (r.wrote) try f.add("[{s}] bulk MERGE the new decimal again: created a second node", .{@tagName(which)});
    try countOf(s, f, b4, "2");

    // A null is still refused.
    if (bulkMerge(which, b4, .Null)) |_| {
        try f.add("[{s}] bulk MERGE a null: accepted", .{@tagName(which)});
    } else |err| {
        if (err != error.MergeValueNotIndexable) try f.add("[{s}] bulk MERGE a null: error {s}", .{ @tagName(which), @errorName(err) });
    }
}

test "SONNY-2806: the server's bulk MERGE matches as the executor does" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    for ([_]Mode{ .persisted, .unbounded_cache }) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        const prev = execution.pushActiveContext(&s.ctx);
        defer execution.popActiveContext(prev);
        try checkBulk(&s, &f, .direct);
        try checkBulk(&s, &f, .reserved_id);
    }
    try f.check("bulk");
}

// ---------------------------------------------------------------------------
// A reopened store: the snapshot and the hydration scan
// ---------------------------------------------------------------------------

fn seedPairs(s: *Session) !void {
    // Lower ids first, and the index's last write is the higher id.
    try s.exec("CREATE (:H {x: 1.0, t: 'low'})");
    try s.exec("CREATE (:H {x: 1, t: 'high'})");
    try s.exec("CREATE (:HB {x: 1.0, t: 'low'})");
    try s.exec("CREATE (:HB {x: 1, t: 'high'})");
}

fn checkReopened(s: *Session, f: *Failures, tag: []const u8) !void {
    // The first op after the reopen: the server's bulk MERGE.
    try expectBulk(f, .direct, "HB", int1, "low");
    try expectValue(s, f, "MERGE (n:H {x: 1}) RETURN n.t AS t", "'low'");
    // The entry still knows another node holds the key.
    try s.exec("MATCH (n:H {t: 'low'}) DELETE n");
    try expectValue(s, f, "MERGE (n:H {x: 1}) RETURN n.t AS t", "'high'");
    try countOf(s, f, "H", "1");
    try s.exec("MATCH (n:HB {t: 'low'}) DELETE n");
    try expectBulk(f, .reserved_id, "HB", dec10, "high");
    try countOf(s, f, "HB", "1");
    _ = tag;
}

test "SONNY-2806: a reopened store matches the lowest holder, from the snapshot and from the scan" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    {
        // Clean close after a FULL checkpoint: the merge index comes back
        // from hydration_merge.snap.
        var s = try Session.init(.persisted);
        defer s.deinit();
        try seedPairs(&s);
        const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
        try adapter.checkpointAll();
        try s.reopen(false);
        const prev = execution.pushActiveContext(&s.ctx);
        defer execution.popActiveContext(prev);
        try checkReopened(&s, &f, "snapshot");
        if (graph_store.hydrationSnapshotLoadCount() == 0) try f.add("[snapshot] the merge index was not loaded from its snapshot", .{});
    }
    {
        // A crash after writes past the checkpoint: the index is rebuilt by
        // the hydration scan.
        var s = try Session.init(.persisted);
        defer s.deinit();
        const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
        try adapter.checkpointAll();
        try seedPairs(&s);
        try s.reopen(true);
        const prev = execution.pushActiveContext(&s.ctx);
        defer execution.popActiveContext(prev);
        try checkReopened(&s, &f, "scan");
    }
    try f.check("reopen");
}

// ---------------------------------------------------------------------------
// The index keeps no number that is not an integer (Important 2)
// ---------------------------------------------------------------------------

/// Entries of MERGE's index under label :MI.
fn miEntries() usize {
    const store = graph_store.getGlobalStore(testing.allocator);
    const prefix = G ++ "\x00MI\x00";
    var n: usize = 0;
    for (&store.merge_prop_index.shards) |*shard| {
        var it = shard.map.keyIterator();
        while (it.next()) |key| {
            if (std.mem.startsWith(u8, key.*, prefix)) n += 1;
        }
    }
    return n;
}

test "SONNY-2806: MERGE's index keeps integers, strings and booleans only" {
    harness.silenceEngineLogs();
    for (modes) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        try s.exec("CREATE (:MI {price: 1.99, ratio: 0.1})");
        try s.execWith("CREATE (:MI {score: $d})", &.{.{ .name = "d", .value = .{ .Double = 0.25 } }});
        try testing.expectEqual(@as(usize, 0), miEntries());
        // An integer of any representation is kept.
        try s.exec("CREATE (:MI {w: 2.0})");
        try s.execWith("CREATE (:MI {v: $d})", &.{.{ .name = "d", .value = .{ .Double = 3.0 } }});
        try s.exec("CREATE (:MI {u: 4, name: 'n', flag: true})");
        try testing.expectEqual(@as(usize, 5), miEntries());
    }
}

// ---------------------------------------------------------------------------
// The multi-property MERGE fallback compares by value (Minor 1)
// ---------------------------------------------------------------------------

test "SONNY-2806: the multi-property bulk MERGE finds a stored date and a number by value" {
    harness.silenceEngineLogs();
    var s = try Session.init(.persisted);
    defer s.deinit();
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    const aa = s.arena.allocator();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const store = graph_store.getGlobalStore(testing.allocator);

    try s.exec("CREATE (:QD {a: 1, d: date('2020-01-01'), t: 'seed'})");
    var date_result = try s.run("RETURN date('2020-01-01') AS d", &.{});
    defer date_result.deinit(aa);
    const date_pv = try geode.property_value_codec.valueToPropertyValue(aa, date_result.rows[0][0]);

    const keys = [_][2]PropKV{
        .{ .{ .key = "a", .value = int1 }, .{ .key = "d", .value = date_pv } },
        .{ .{ .key = "a", .value = dec10 }, .{ .key = "d", .value = date_pv } },
    };
    for (keys) |mp| {
        const r = try adapter.bulkMergeNodeWithReservedIdMultiProp(G, store.reserveNodeId(), "QD", &mp, &.{}, false);
        try testing.expect(!r.wrote);
        try testing.expectEqualStrings("seed", tOf(r.id));
    }
    var c = try s.run("MATCH (n:QD) RETURN count(n) AS c", &.{});
    defer c.deinit(aa);
    try testing.expectEqual(@as(i64, 1), c.rows[0][0].Int);

    // The lowest of two equal matches.
    try s.exec("CREATE (:QE {a: 1.0, b: 'k', t: 'first'})");
    try s.exec("CREATE (:QE {a: 1, b: 'k', t: 'second'})");
    const qe = [_]PropKV{ .{ .key = "a", .value = int1 }, .{ .key = "b", .value = .{ .String = "k" } } };
    const r = try adapter.bulkMergeNodeWithReservedIdMultiProp(G, store.reserveNodeId(), "QE", &qe, &.{}, false);
    try testing.expect(!r.wrote);
    try testing.expectEqualStrings("first", tOf(r.id));
}
