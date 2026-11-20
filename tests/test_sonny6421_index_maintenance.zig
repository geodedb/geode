// SONNY-6421 regression: the full-text and vector indexes answer for the
// labels and text the store holds after REMOVE n:L and after a SET that
// replaces or drops indexed text; a vector-index undo repair survives a
// background rebuild; the IndexOnEncryptedField message names no missing
// feature; and an engine-less store refuses a property write to a missing
// node.
//
//   1. REMOVE n:L takes the node out of L's full-text and vector indexes,
//      and a full-text search answers only nodes that carry the index's
//      label (a node can lose the label by a path that does no index
//      maintenance).
//   2. A SET that changes an indexed text value leaves the old words
//      unfindable.
//   3. SET n = {map} that drops (or changes) an indexed text property leaves
//      its words unfindable; a value the map sets again stays found.
//   4. A ROLLBACK whose vector-index repair lands while a non-blocking
//      background rebuild of the index is building from an earlier snapshot
//      is not overwritten by that rebuild's swap.
//   5. The IndexOnEncryptedField refusal does not point at a "searchable
//      (blind-index) field", which cannot be declared.
//   6. `GraphStore.setNodeProperty` on a store with no storage engine
//      answers NodeNotFound for an id that names no node.
//
// Through the real gRPC handlers in process (items 1-4), the real error map
// (item 5) and a real engine-less store (item 6).
//
// CANARY: REQ=REQ-SONNY-6421-INDEX-MAINTENANCE; FEATURE="Execution"; ASPECT=IndexMaintenanceRegression; STATUS=TESTED; TEST=tests/test_sonny6421_index_maintenance.zig; OWNER=execution; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const sa = @import("statement_atomicity_fixture.zig");
const fx = sa.fx;

const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

const rowsOf = sa.rowsOf;
const runs = sa.runs;

fn expectRows(ga: std.mem.Allocator, s: []const u8, what: []const u8, query: []const u8, want: usize) !void {
    const got = try rowsOf(ga, s, query);
    if (got != want) std.debug.print("{s}: '{s}' answers {d} rows; expected {d}\n", .{ what, query, got, want });
    try testing.expectEqual(want, got);
}

/// The id of the one node of `label` in the default graph.
fn onlyNodeOf(label: []const u8) !u64 {
    const st = graph_store.getGlobalStore(graph_store.global_allocator());
    const ids = st.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, label) orelse return error.NodeNotFound;
    if (ids.len != 1) return error.TestUnexpectedResult;
    return ids[0];
}

/// Does the vector index `name` hold an entry for `id`?
/// `name` is the runtime key, `<graph>\x1f<index>` (SONNY-6703).
fn vectorIndexHolds(name: []const u8, id: u64) !bool {
    const manager = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;
    const io = std.Io.Threaded.global_single_threaded.io();
    manager.rebuild_mutex.lockUncancelable(io);
    defer manager.rebuild_mutex.unlock(io);
    const wrapper = manager.advanced_vector_indexes.get(name) orelse return error.IndexNotFound;
    return wrapper.contains(id);
}

test "SONNY-6421 item 6: setNodeProperty on an engine-less store refuses a missing node" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var labels = [_][]const u8{"N6421"};
    const id = try store.createNodeWithGraph(&labels, "g6421");
    try store.setNodeProperty(id, "k", .{ .Int = 1 });
    try testing.expectError(error.NodeNotFound, store.setNodeProperty(id + 1000, "k", .{ .Int = 2 }));
}

test "SONNY-6421 item 5: the IndexOnEncryptedField refusal names no searchable / blind-index field" {
    const info = geode.proto_util.mapError(error.IndexOnEncryptedField);
    try testing.expectEqualStrings("0A000", info.code);
    try testing.expect(std.ascii.indexOfIgnoreCase(info.message, "blind") == null);
    try testing.expect(std.ascii.indexOfIgnoreCase(info.message, "searchable") == null);
    try testing.expect(std.ascii.indexOfIgnoreCase(info.message, "encrypted") != null);
}

test "SONNY-6421 item 1: REMOVE n:L takes the node out of L's full-text and vector indexes" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6421l");

    try runs(ga, s, "CREATE INDEX l6421 FOR (n:L6421) ON (n.body) USING fulltext");
    try runs(ga, s, "CREATE INDEX lv6421 ON LV6421 (emb6421) USING vector WITH (metric = 'l2')");
    try runs(ga, s, "CREATE (:L6421 {k: 1, body: 'walnut'})");
    try runs(ga, s, "CREATE (:L6421:K6421 {k: 2, body: 'hazel'})");
    try runs(ga, s, "CREATE (:LV6421 {k: 0, emb6421: vectorf32([1.0, 0.0, 0.0])})");
    try runs(ga, s, "CREATE (:LV6421:W6421 {k: 3, emb6421: vectorf32([0.0, 1.0, 0.0])})");
    try expectRows(ga, s, "seeded", "CALL geode.fts.search('l6421', 'walnut')", 1);
    const vid = try onlyNodeOf("W6421");
    try testing.expect(try vectorIndexHolds("default\x1flv6421", vid));

    try runs(ga, s, "MATCH (n:L6421) WHERE n.k = 1 REMOVE n:L6421");
    try expectRows(ga, s, "REMOVE n:L, fulltext", "CALL geode.fts.search('l6421', 'walnut')", 0);

    // The MATCH ... REMOVE ... RETURN executor, with a second label left.
    try expectRows(ga, s, "REMOVE n:L RETURN", "MATCH (n:K6421) REMOVE n:L6421 RETURN n.k", 1);
    try expectRows(ga, s, "REMOVE n:L RETURN, fulltext", "CALL geode.fts.search('l6421', 'hazel')", 0);

    try runs(ga, s, "MATCH (n:W6421) REMOVE n:LV6421");
    try testing.expect(!try vectorIndexHolds("default\x1flv6421", vid));

    // The label given back: found again.
    try runs(ga, s, "MATCH (n:K6421) SET n:L6421");
    try expectRows(ga, s, "SET n:L again", "CALL geode.fts.search('l6421', 'hazel')", 1);
}

test "SONNY-6421 item 1: a full-text search answers only nodes that carry the index's label" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6421s");

    try runs(ga, s, "CREATE INDEX s6421 FOR (n:S6421) ON (n.body) USING fulltext");
    try runs(ga, s, "CREATE (:S6421:T6421 {k: 1, body: 'chestnut'})");
    try expectRows(ga, s, "seeded", "CALL geode.fts.search('s6421', 'chestnut')", 1);

    // The store's own label removal does no index maintenance (as a
    // replicated apply or an undo of SET n:L does not): the posting stays,
    // and the search must not answer the node.
    const id = try onlyNodeOf("T6421");
    try graph_store.getGlobalStore(graph_store.global_allocator()).removeNodeLabel(id, "S6421");
    try expectRows(ga, s, "label gone", "CALL geode.fts.search('s6421', 'chestnut')", 0);
    try expectRows(ga, s, "label gone", "CALL geode.fts.phrase('s6421', 'chestnut')", 0);
}

test "SONNY-6421 items 2 and 3: a SET that replaces or drops indexed text leaves the old words unfindable" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6421t");

    try runs(ga, s, "CREATE INDEX t6421 FOR (n:D6421) ON (n.title, n.body) USING fulltext");
    try runs(ga, s, "CREATE (:D6421 {k: 1, body: 'cherry'})");
    try runs(ga, s, "CREATE (:D6421 {k: 2, title: 'almond', body: 'quince'})");
    try runs(ga, s, "CREATE (:D6421 {k: 3, body: 'medlar'})");
    try expectRows(ga, s, "seeded", "CALL geode.fts.search('t6421', 'cherry')", 1);

    // Item 2: a changed value.
    try runs(ga, s, "MATCH (d:D6421) WHERE d.k = 1 SET d.body = 'damson'");
    try expectRows(ga, s, "SET changed", "CALL geode.fts.search('t6421', 'cherry')", 0);
    try expectRows(ga, s, "SET changed", "CALL geode.fts.search('t6421', 'damson')", 1);

    // Item 2: a string replaced by a non-string.
    try runs(ga, s, "MATCH (d:D6421) WHERE d.k = 3 SET d.body = 7");
    try expectRows(ga, s, "SET to a number", "CALL geode.fts.search('t6421', 'medlar')", 0);

    // Item 3: SET n = {map} that drops one indexed property and keeps the
    // other with the same value.
    try runs(ga, s, "MATCH (d:D6421) WHERE d.k = 2 SET d = {k: 2, body: 'quince'}");
    try expectRows(ga, s, "SET n = {map} dropped", "CALL geode.fts.search('t6421', 'almond')", 0);
    try expectRows(ga, s, "SET n = {map} kept", "CALL geode.fts.search('t6421', 'quince')", 1);

    // Item 3: SET n = {map} that changes the value.
    try runs(ga, s, "MATCH (d:D6421) WHERE d.k = 2 SET d = {k: 2, body: 'sloe'}");
    try expectRows(ga, s, "SET n = {map} changed", "CALL geode.fts.search('t6421', 'quince')", 0);
    try expectRows(ga, s, "SET n = {map} changed", "CALL geode.fts.search('t6421', 'sloe')", 1);

    // In a transaction that commits.
    try fx.begin(ga, s);
    try runs(ga, s, "MATCH (d:D6421) WHERE d.k = 1 SET d.body = 'rowan'");
    try testing.expect(try fx.commit(ga, s));
    try expectRows(ga, s, "committed SET", "CALL geode.fts.search('t6421', 'damson')", 0);
    try expectRows(ga, s, "committed SET", "CALL geode.fts.search('t6421', 'rowan')", 1);
}

// Item 4: the ROLLBACK run while the non-blocking rebuild is between its
// snapshot and its swap.
const Swap = struct {
    var ga: std.mem.Allocator = undefined;
    var session: []const u8 = "";
    var fired: std.atomic.Value(u32) = .init(0);
    var rolled_back: bool = false;
    var err: ?anyerror = null;

    fn rollbackOnThread() void {
        rolled_back = fx.rollback(ga, session) catch |e| blk: {
            err = e;
            break :blk false;
        };
    }

    fn hook(index_name: []const u8) void {
        if (!std.mem.eql(u8, index_name, "default\x1fr6421")) return;
        if (fired.fetchAdd(1, .acq_rel) != 0) return;
        const t = std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, rollbackOnThread, .{}) catch |e| {
            err = e;
            return;
        };
        t.join();
    }
};

test "SONNY-6421 item 4: a vector-index undo repair is not overwritten by a background rebuild's swap" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6421r");

    try runs(ga, s, "CREATE INDEX r6421 ON R6421 (embr6421) USING vector WITH (metric = 'l2')");
    try runs(ga, s, "CREATE (:R6421 {k: 1, embr6421: vectorf32([1.0, 0.0, 0.0])})");
    try runs(ga, s, "CREATE (:R6421 {k: 2, embr6421: vectorf32([0.0, 1.0, 0.0])})");
    const nearest_to_k2 = "MATCH (v:R6421) WHERE id(v) IN knn('embr6421', vectorf32([0.0, 0.9, 0.1]), 1, 'l2') AND v.k = 2 RETURN v";
    try expectRows(ga, s, "seeded", nearest_to_k2, 1);

    // An open transaction moves k=2 far away; its statement released the
    // graph lock, so a background rebuild snapshots the moved vector.
    try fx.begin(ga, s);
    try runs(ga, s, "MATCH (v:R6421) WHERE v.k = 2 SET v.embr6421 = vectorf32([0.0, 0.0, -5.0])");

    Swap.ga = ga;
    Swap.session = s;
    Swap.fired.store(0, .release);
    Swap.rolled_back = false;
    Swap.err = null;
    index_manager.test_vector_rebuild_before_swap = &Swap.hook;
    defer index_manager.test_vector_rebuild_before_swap = null;

    const manager = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;
    _ = try manager.rebuildAdvancedVectorIndexNonBlocking(testing.allocator, graph_store.DEFAULT_GRAPH_NAME, "default\x1fr6421");
    index_manager.test_vector_rebuild_before_swap = null;

    if (Swap.err) |e| return e;
    try testing.expect(Swap.rolled_back);
    try testing.expect(Swap.fired.load(.acquire) >= 1);
    // The index ranks k=2 by the vector the store holds again.
    try expectRows(ga, s, "repair kept after the swap", nearest_to_k2, 1);
}
