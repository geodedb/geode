// SONNY-3109: `SET n:L` and `REMOVE n:L` did not update MERGE's property
// index (graph_store.merge_prop_index), whose entries are keyed by label.
//
//   * After `SET n:L`, the node was no holder of any `(L, key, value)`
//     entry, so `MERGE (:L {x: 1})` trusted the index's miss and created a
//     second node (the executor and the server's bulk MERGE alike). A node
//     that gained the label kept its lower id out of the entry, so after the
//     indexed holder was deleted MERGE created a node beside it.
//   * After `REMOVE n:L`, the entry still named the node, and the server's
//     bulk MERGE (which takes the entry's node as the match) returned a node
//     that no longer carries L. The executor verified the candidate and fell
//     back to a label scan.
//
// A label add now records the node as a holder of each of its indexed
// properties (and registered composite keys) under the new label; a label
// removal removes it from those entries, as a delete does.
//
// CANARY: REQ=REQ-SONNY-3109-MERGE-LABEL-CHANGE; FEATURE="MergeIdempotency"; ASPECT=LabelChangeIndexMaintenance; STATUS=TESTED; TEST=tests/test_sonny3109_merge_label_change.zig; OWNER=storage; UPDATED=2026-09-27

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

const Mode = enum { in_memory, persisted };

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);
        errdefer execution.cleanupCatalogInstance();
        const persisted = mode == .persisted;
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
    }

    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn exec(self: *Session, query: []const u8) !void {
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }
};

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
        return error.MergeLabelChangeWrong;
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

/// `query` returns exactly the single-cell rows `want`, in this order after
/// sorting.
fn expectRows(s: *Session, f: *Failures, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    var result = s.run(query) catch |err| {
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
    try expectRows(s, f, q, &.{want});
}

test "SONNY-3109: MERGE sees a label added by SET and forgets one removed by REMOVE (executor)" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    for ([_]Mode{ .in_memory, .persisted }) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();

        // SET n:L: the node holds the key under the new label.
        try s.exec("CREATE (:J {x: 1, t: 'j'})");
        try s.exec("MATCH (n:J) SET n:KL");
        try expectRows(&s, &f, "MERGE (n:KL {x: 1}) RETURN n.t AS t", &.{"'j'"});
        try countOf(&s, &f, "KL", "1");
        try expectRows(&s, &f, "MATCH (n:KL {x: 1}) RETURN n.t AS t", &.{"'j'"});

        // The node that gained the label has the lower id: MERGE matches it,
        // and still does once the other holder is deleted.
        try s.exec("CREATE (:J2 {x: 1, t: 'b_low'})");
        try s.exec("CREATE (:KL2 {x: 1, t: 'a_high'})");
        try s.exec("MATCH (n:J2) SET n:KL2");
        try expectRows(&s, &f, "MERGE (n:KL2 {x: 1}) RETURN n.t AS t", &.{"'b_low'"});
        try s.exec("MATCH (n:KL2 {t: 'a_high'}) DELETE n");
        try expectRows(&s, &f, "MERGE (n:KL2 {x: 1}) RETURN n.t AS t", &.{"'b_low'"});
        try countOf(&s, &f, "KL2", "1");

        // REMOVE n:L: the node no longer holds the key under L.
        try s.exec("CREATE (:RL {x: 1, t: 'rl'})");
        try s.exec("MATCH (n:RL) REMOVE n:RL");
        try expectRows(&s, &f, "MATCH (n:RL {x: 1}) RETURN n.t AS t", &.{});
        try expectRows(&s, &f, "MERGE (n:RL {x: 1}) RETURN n.t AS t", &.{"null"});
        try countOf(&s, &f, "RL", "1");
        try expectRows(&s, &f, "MATCH (n {t: 'rl'}) RETURN count(n) AS c", &.{"1"});

        // A label removed then added back.
        try s.exec("CREATE (:RB {x: 2, t: 'rb'})");
        try s.exec("MATCH (n:RB) REMOVE n:RB");
        try s.exec("MATCH (n {t: 'rb'}) SET n:RB");
        try expectRows(&s, &f, "MERGE (n:RB {x: 2}) RETURN n.t AS t", &.{"'rb'"});
        try countOf(&s, &f, "RB", "1");
    }
    try f.check("executor");
}

/// The `t` property of node `id`, or "" when it has none.
fn tOf(id: u64) []const u8 {
    const v = (graph_store.getGlobalStore(testing.allocator).getNodePropertyOrError(id, "t") catch @panic("SONNY-6621: unexpected read failure")) orelse return "";
    return switch (v) {
        .String => |t| t,
        else => "?",
    };
}

fn expectMatch(f: *Failures, what: []const u8, res: anyerror!gsa.StorageAdapter.MergeResult, want_t: []const u8) !void {
    const r = res catch |err| {
        try f.add("{s}: error {s}", .{ what, @errorName(err) });
        return;
    };
    if (r.wrote) try f.add("{s}: created a node, expected the one with t='{s}'", .{ what, want_t });
    if (!r.wrote and !std.mem.eql(u8, tOf(r.id), want_t)) try f.add("{s}: matched t='{s}', expected '{s}'", .{ what, tOf(r.id), want_t });
}

fn expectCreate(f: *Failures, what: []const u8, res: anyerror!gsa.StorageAdapter.MergeResult) !void {
    const r = res catch |err| {
        try f.add("{s}: error {s}", .{ what, @errorName(err) });
        return;
    };
    if (!r.wrote) try f.add("{s}: matched t='{s}', which no longer carries the label", .{ what, tOf(r.id) });
}

test "SONNY-3109: the server's bulk MERGE sees a label added by SET and forgets one removed by REMOVE" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    var s = try Session.init(.persisted);
    defer s.deinit();
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const store = graph_store.getGlobalStore(testing.allocator);
    defer graph_store.clearCompositeMergeKeysForTest();

    try s.exec("CREATE (:BJ {x: 1, t: 'j'})");
    try s.exec("MATCH (n:BJ) SET n:BKL");
    try expectMatch(&f, "MERGE (:BKL {x: 1})", adapter.bulkMergeNode(G, "BKL", "x", .{ .Int = 1 }, &.{}, null, false), "j");
    try expectMatch(&f, "MERGE (:BKL {x: 1}) (reserved id)", adapter.bulkMergeNodeWithReservedId(G, store.reserveNodeId(), "BKL", "x", .{ .Int = 1 }, &.{}, false), "j");

    try s.exec("CREATE (:BRL {x: 1, t: 'rl'})");
    try s.exec("MATCH (n:BRL) REMOVE n:BRL");
    try expectCreate(&f, "MERGE (:BRL {x: 1})", adapter.bulkMergeNode(G, "BRL", "x", .{ .Int = 1 }, &.{}, null, false));

    // A composite key (registered by a first multi-property MERGE).
    const reg = [_]PropKV{ .{ .key = "a", .value = .{ .Int = 0 } }, .{ .key = "b", .value = .{ .String = "z" } } };
    _ = try adapter.bulkMergeNodeWithReservedIdMultiProp(G, store.reserveNodeId(), "CX", &reg, &.{}, false);
    try s.exec("CREATE (:CJ {a: 1, b: 'k', t: 'cj'})");
    try s.exec("MATCH (n:CJ) SET n:CKL");
    const ck = [_]PropKV{ .{ .key = "a", .value = .{ .Int = 1 } }, .{ .key = "b", .value = .{ .String = "k" } } };
    try expectMatch(&f, "MERGE (:CKL {a: 1, b: 'k'})", adapter.bulkMergeNodeWithReservedIdMultiProp(G, store.reserveNodeId(), "CKL", &ck, &.{}, false), "cj");
    try s.exec("CREATE (:CR {a: 2, b: 'k', t: 'cr'})");
    try s.exec("MATCH (n:CR) REMOVE n:CR");
    const cr = [_]PropKV{ .{ .key = "a", .value = .{ .Int = 2 } }, .{ .key = "b", .value = .{ .String = "k" } } };
    try expectCreate(&f, "MERGE (:CR {a: 2, b: 'k'})", adapter.bulkMergeNodeWithReservedIdMultiProp(G, store.reserveNodeId(), "CR", &cr, &.{}, false));

    try countOf(&s, &f, "BKL", "1");
    try countOf(&s, &f, "BRL", "1");
    try countOf(&s, &f, "CKL", "1");
    try countOf(&s, &f, "CR", "1");
    try f.check("bulk");
}

test "SONNY-3109: rolling back SET n:L or REMOVE n:L restores MERGE's index" {
    const allocator = testing.allocator;
    const txn_undo_log = geode.txn_undo_log;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    try store.createGraph("g");
    const node_id = try store.createNodeWithGraph(&[_][]const u8{"Movie"}, "g");
    try store.setNodeProperty(node_id, "x", .{ .Int = 1 });

    var id: u64 = 0;
    {
        // SET n:Person, rolled back: the node no longer holds the key under
        // Person.
        var undo = txn_undo_log.UndoLog.init(allocator);
        defer undo.deinit();
        undo.begin();
        try store.addNodeLabel(node_id, "Person");
        try undo.logAddNodeLabel(node_id, "Person");
        try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.found, store.lookupMergeCandidate("g", "Person", "x", .{ .Int = 1 }, &id));
        try undo.rollback(&store);
        try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.not_found, store.lookupMergeCandidate("g", "Person", "x", .{ .Int = 1 }, &id));
    }
    {
        // REMOVE n:Movie, rolled back: the node holds the key under Movie
        // again.
        var undo = txn_undo_log.UndoLog.init(allocator);
        defer undo.deinit();
        undo.begin();
        try store.removeNodeLabel(node_id, "Movie");
        try undo.logRemoveNodeLabel(node_id, "Movie");
        try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.not_found, store.lookupMergeCandidate("g", "Movie", "x", .{ .Int = 1 }, &id));
        try undo.rollback(&store);
        try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.found, store.lookupMergeCandidate("g", "Movie", "x", .{ .Int = 1 }, &id));
        try testing.expectEqual(node_id, id);
    }
}

/// A node of `label` holding x = `x` and t = `t`, written as the server's
/// bulk ingest writes it.
fn bulkNode(label: []const u8, t: []const u8, x: PropertyValue) !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const store = graph_store.getGlobalStore(testing.allocator);
    const props = [_]PropKV{ .{ .key = "x", .value = x }, .{ .key = "t", .value = .{ .String = t } } };
    return adapter.bulkInsertNodeWithReservedId(G, store.reserveNodeId(), &[_][]const u8{label}, &props);
}

/// `SET n:label` on `id` rolled back through the undo log, the path a
/// statement's or a transaction's ROLLBACK takes. The node no longer carries
/// the label, but the label's postings and the exact node-property index
/// may still list it (they are not rolled back with it).
fn addLabelRolledBack(id: u64, label: []const u8) !void {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const store = graph_store.getGlobalStore(testing.allocator);
    // The session's engine transaction slot, as a request of the session
    // installs it (SONNY-2823).
    var slot: gsa.SessionEngineTxn = .{};
    const scope = gsa.enterSessionEngineTxn(&slot);
    defer _ = gsa.leaveSessionEngineTxn(&slot, scope);
    var undo = geode.txn_undo_log.UndoLog.init(testing.allocator);
    defer undo.deinit();
    undo.begin();
    try adapter.beginSessionTxnLazy(G);
    try store.addNodeLabel(id, label);
    try undo.logAddNodeLabel(id, label);
    adapter.abortSessionTxn();
    try undo.rollback(store);
}

fn carriesLabel(id: u64, label: []const u8) bool {
    const node = graph_store.getGlobalStore(testing.allocator).nodes.get(id) orelse return false;
    for (node.labels) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

test "SONNY-3109: MERGE's holder search skips a node that no longer carries the label" {
    // The round-8 re-review's probe (phase rb, case b): z has the lowest id
    // and holds x = 1 under another label; `SET z:ML` rolled back leaves z
    // without :ML, yet listed under :ML where MERGE's holder search reads
    // (the label's postings and the exact index). The search checked the
    // node's graph and property, not its label, so the server's bulk MERGE
    // matched z, a node without the label. (That the rollback leaves the
    // storage's label postings with z, so a persisted MATCH (n:ML) still
    // returns it, is SONNY-3059: a rollback does not undo a label change.)
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    var s = try Session.init(.persisted);
    defer s.deinit();
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;

    // An integer key (MERGE's index; the settle reads the exact index).
    const z = try bulkNode("MZ", "z", .{ .Int = 1 });
    _ = try bulkNode("ML", "a", .{ .Int = 1 });
    _ = try bulkNode("ML", "b", .{ .Int = 1 });
    try addLabelRolledBack(z, "ML");
    if (carriesLabel(z, "ML")) try f.add("the rollback left z with :ML", .{});
    try expectMatch(&f, "MERGE (:ML {x: 1})", adapter.bulkMergeNode(G, "ML", "x", .{ .Int = 1 }, &.{}, null, false), "a");
    try expectRows(&s, &f, "MERGE (n:ML {x: 1}) RETURN n.t", &.{"'a'"});

    // A number that is not an integer (not in MERGE's index): the server's
    // MERGE finds its holders through the exact index.
    const d: PropertyValue = .{ .Float = 1.5 };
    const z2 = try bulkNode("MZ2", "z2", d);
    _ = try bulkNode("MD", "a", d);
    try addLabelRolledBack(z2, "MD");
    try expectMatch(&f, "MERGE (:MD {x: 1.5})", adapter.bulkMergeNode(G, "MD", "x", d, &.{}, null, false), "a");

    // In lean mode the settle scans the label's postings.
    {
        graph_store.setLeanIndexingForTest(true);
        defer graph_store.setLeanIndexingForTest(false);
        graph_store.registerMergeIndexKey("x");
        const z3 = try bulkNode("MZ3", "z3", .{ .Int = 3 });
        _ = try bulkNode("MN", "a", .{ .Int = 3 });
        _ = try bulkNode("MN", "b", .{ .Int = 3 });
        try addLabelRolledBack(z3, "MN");
        try expectMatch(&f, "MERGE (:MN {x: 3}) (lean)", adapter.bulkMergeNode(G, "MN", "x", .{ .Int = 3 }, &.{}, null, false), "a");
        const z4 = try bulkNode("MZ4", "z4", d);
        _ = try bulkNode("MO", "a", d);
        try addLabelRolledBack(z4, "MO");
        try expectMatch(&f, "MERGE (:MO {x: 1.5}) (lean)", adapter.bulkMergeNode(G, "MO", "x", d, &.{}, null, false), "a");
    }
    try f.check("label check");
}
