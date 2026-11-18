// SONNY-6718: a cluster must accept ordinary writes.
//
// Before: on a cluster leader
//   * `CREATE (:L {v: 3.5})`, `MERGE (...) SET n.v = 3.5` and `MATCH ... SET
//     n.v = 3.5` were refused (ClusterWriteNotReplicable, 40001): an exact
//     numeric literal is a DECIMAL and no replication codec carried one;
//   * so were `INSERT (...)`, several comma-separated chains in one CREATE
//     (`CREATE (a:A), (b:B), (a)-[:R]->(b)`) and list / date property values;
//   * and a MERGE that MATCHED with a SET (`MERGE (n:L {id: 1}) SET n.v = 2`)
//     freed its property list with the wrong allocator: the leader process
//     died ("free(): invalid pointer"), the cluster lost its leader.
//
// An in-process 3-node Raft cluster (tests/sonny3348_cluster_harness.zig), the
// statements through the real gRPC handler; what the cluster committed is read
// from the store with its exact type, coefficient and scale. The codecs
// themselves are tested in src/distributed/cluster_replication.zig
// (`zig build test-sonny6718-codec`); the freed-with-the-wrong-allocator
// crash and the follower-side values are proved over 3 real `geode serve`
// processes by tests/test_cluster_replicable_mutations.zig (SONNY-6718 tests)
// and geodetestlab-cli/specs/sonny6718_cluster_decimal_merge.yml.
//
// CANARY: REQ=REQ-SONNY-6718-CLUSTER-ORDINARY-WRITES; FEATURE="DistributedCluster"; ASPECT=DecimalAndMergeShapes; STATUS=TESTED; TEST=tests/test_sonny6718_cluster_decimal_merge.zig; OWNER=distributed; UPDATED=2026-11-18

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const ch = @import("sonny3348_cluster_harness.zig");
const Harness = ch.Harness;
const runOn = ch.runOn;
const PropertyValue = geode.graph_store.PropertyValue;

/// Run `q` on the leader, require it ran (not refused), wait for every node.
fn expectReplicates(h: *Harness, q: []const u8) !void {
    const r = try runOn(h.ga(), h.s, q, null);
    _ = try h.cl.settle();
    if (r.err != null or r.code != null) {
        std.debug.print("SONNY-6718: refused/failed: {s}\n   code={s} err={s}\n", .{ q, r.code orelse "-", if (r.err) |e| @errorName(e) else "-" });
        return error.NotReplicated;
    }
}

fn expectRefused(h: *Harness, q: []const u8) !void {
    const r = try runOn(h.ga(), h.s, q, null);
    _ = try h.cl.settle();
    try testing.expect(r.err != null or r.code != null);
    if (r.code) |c| try testing.expectEqualStrings("40001", c);
}

/// The single node of `label` in the default graph.
fn only(h: *Harness, label: []const u8) !u64 {
    const ids = h.f.st.getNodesByLabel("default", label) orelse return error.NoSuchLabel;
    try testing.expectEqual(@as(usize, 1), ids.len);
    return ids[0];
}

fn prop(h: *Harness, id: u64, key: []const u8) !PropertyValue {
    return (try h.f.st.getNodePropertyOrError(id, key)) orelse error.PropertyMissing;
}

fn expectDecimal(v: PropertyValue, coeff: i128, scale: u8) !void {
    try testing.expect(v == .Decimal);
    try testing.expectEqual(coeff, v.Decimal.coeff);
    try testing.expectEqual(scale, v.Decimal.scale);
}

test "SONNY-6718 a cluster leader replicates DECIMAL values in CREATE, MERGE and SET with coefficient and scale intact" {
    var h: Harness = .{};
    try h.init(&.{});
    defer h.deinit();

    try expectReplicates(&h, "CREATE (:DCreate {v: 3.5, neg: -0.000001, w: 1.50})");
    const c = try only(&h, "DCreate");
    try expectDecimal(try prop(&h, c, "v"), 35, 1);
    try expectDecimal(try prop(&h, c, "neg"), -1, 6);
    try expectDecimal(try prop(&h, c, "w"), 150, 2);

    // MERGE that creates, with the decimal in the key and in ON CREATE SET.
    try expectReplicates(&h, "MERGE (n:DMerge {k: 2.25}) ON CREATE SET n.v = 12345678901234567890.123456789");
    const m = try only(&h, "DMerge");
    try expectDecimal(try prop(&h, m, "k"), 225, 2);
    try expectDecimal(try prop(&h, m, "v"), 12345678901234567890123456789, 9);
    // The same MERGE again matches: no second node.
    try expectReplicates(&h, "MERGE (n:DMerge {k: 2.25}) ON CREATE SET n.v = 1.5");
    _ = try only(&h, "DMerge");

    // MATCH ... SET and MERGE ... ON MATCH SET with a decimal.
    try expectReplicates(&h, "MATCH (n:DCreate) SET n.v = 4.25");
    try expectDecimal(try prop(&h, c, "v"), 425, 2);
    try expectReplicates(&h, "MERGE (n:DMerge {k: 2.25}) ON MATCH SET n.v = 0.5");
    try expectDecimal(try prop(&h, m, "v"), 5, 1);
    // Decimal arithmetic computed on the leader replicates its result.
    try expectReplicates(&h, "MATCH (n:DCreate) SET n.sum = n.v + 1.5");
    try expectDecimal(try prop(&h, c, "sum"), 575, 2);
}

test "SONNY-6718 a MERGE that matches an existing node and SETs replicates (the leader must not die)" {
    var h: Harness = .{};
    try h.init(&.{});
    defer h.deinit();

    try expectReplicates(&h, "MERGE (n:MSet {id: 21}) SET n.v = 2");
    const id = try only(&h, "MSet");
    try testing.expectEqual(@as(i64, 2), (try prop(&h, id, "v")).Int);
    // The second MERGE matches: SET (bare, and ON MATCH SET) rewrite the node.
    try expectReplicates(&h, "MERGE (n:MSet {id: 21}) SET n.v = 3");
    try testing.expectEqual(@as(i64, 3), (try prop(&h, id, "v")).Int);
    try expectReplicates(&h, "MERGE (n:MSet {id: 21}) ON MATCH SET n.m = 1, n.v = 4");
    try testing.expectEqual(@as(i64, 4), (try prop(&h, id, "v")).Int);
    try testing.expectEqual(@as(i64, 1), (try prop(&h, id, "m")).Int);
    _ = try only(&h, "MSet");
}

test "SONNY-6718 INSERT, several chains in one CREATE, list and date properties replicate" {
    var h: Harness = .{};
    try h.init(&.{});
    defer h.deinit();

    try expectReplicates(&h, "INSERT (:Ins {id: 5, d: 3.5})");
    try expectDecimal(try prop(&h, try only(&h, "Ins"), "d"), 35, 1);

    try expectReplicates(&h, "CREATE (:Two {id: 8}), (:Two {id: 9})");
    try testing.expectEqual(@as(usize, 2), ch.fx.countLabel(h.f.st, "default", "Two"));

    try expectReplicates(&h, "CREATE (a:Ca {k: 1}), (b:Cb {k: 2}), (a)-[:LINKS {w: 1.5}]->(b)");
    try testing.expectEqual(@as(usize, 1), ch.fx.countLabel(h.f.st, "default", "Ca"));
    try testing.expectEqual(@as(usize, 1), ch.fx.countLabel(h.f.st, "default", "Cb"));
    try testing.expectEqual(@as(usize, 1), try ch.rowsOf(h.ga(), h.s, "MATCH (:Ca)-[r:LINKS]->(:Cb) RETURN r"));

    try expectReplicates(&h, "CREATE (:Ext {id: 10, lst: [1, 2, 3], dt: date('2026-01-02')})");
    const e = try only(&h, "Ext");
    const lst = try prop(&h, e, "lst");
    try testing.expect(lst == .ExtValue);
    try testing.expect((try prop(&h, e, "dt")) == .ExtValue);
}

test "SONNY-6718 the shapes the cluster still refuses fail closed with 40001 and write nothing" {
    var h: Harness = .{};
    try h.init(&.{"CREATE (:Anchor {id: 1})"});
    defer h.deinit();
    // Documented residuals (docs/CLUSTER_WRITES.md): a relationship MERGE, a
    // CREATE that hangs a NEW node off a MATCHed one, a map property value.
    try expectRefused(&h, "MERGE (a:Anchor {id: 1})-[:R2]->(b:Other {id: 1})");
    try expectRefused(&h, "MATCH (a:Anchor {id: 1}) CREATE (a)-[:R4]->(:Leaf {id: 1})");
    try expectRefused(&h, "CREATE (:M {m: {a: 1}})");
    for ([_][]const u8{ "Other", "Leaf", "M" }) |label| try testing.expectEqual(@as(usize, 0), ch.fx.countLabel(h.f.st, "default", label));
    try testing.expectEqual(@as(usize, 1), ch.fx.countLabel(h.f.st, "default", "Anchor"));
}
