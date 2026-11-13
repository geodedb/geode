// SONNY-2810: the raft snapshot serializer (GraphStore.serializeSnapshot,
// reached through raft_snapshot_manager.createSnapshotData and the cluster's
// snapshot) printed a Float property with `{d}` into a 32-byte buffer with
// `catch unreachable`. `{d}` prints positional digits: 1e40 is 41 characters,
// -1.7976931348623157e308 over 300, so a large or tiny DOUBLE (which
// cluster-replicated creates store as Float) crashed the snapshot. And an
// integral Float printed as "3" came back an Int; NaN and infinities are not
// JSON numbers, so their node or edge was dropped from the snapshot.
//
// Every value must survive createSnapshotData + installSnapshotData exactly,
// as a Float, on a node and on an edge.
//
// CANARY: REQ=REQ-SONNY-2810-SNAPSHOT-FLOAT; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2810_snapshot_float.zig; OWNER=distributed; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;
const snapshot_manager = geode.distributed.raft_snapshot_manager;

const values = [_]f64{
    1e40,
    1.2345678901234567e-20,
    -std.math.floatMax(f64),
    std.math.floatMax(f64),
    std.math.floatTrueMin(f64),
    std.math.floatMin(f64),
    3.0,
    -0.0,
    0.1,
    123456789.125,
    std.math.inf(f64),
    -std.math.inf(f64),
    std.math.nan(f64),
};

fn sameFloat(want: f64, got: PropertyValue) bool {
    const f = switch (got) {
        .Float => |v| v,
        else => return false,
    };
    if (std.math.isNan(want)) return std.math.isNan(f);
    return @as(u64, @bitCast(want)) == @as(u64, @bitCast(f));
}

test "SONNY-2810: Float properties of every magnitude survive a raft snapshot round trip, as Floats" {
    const allocator = std.testing.allocator;
    var src = try GraphStore.init(allocator);
    defer src.deinit();

    var nodes: [values.len]u64 = undefined;
    var edges: [values.len]u64 = undefined;
    const anchor = try src.createNode(&[_][]const u8{"Anchor"});
    for (values, 0..) |v, i| {
        nodes[i] = try src.createNode(&[_][]const u8{"F"});
        try src.setNodeProperty(nodes[i], "x", .{ .Float = v });
        edges[i] = try src.createEdge(anchor, nodes[i], "HAS");
        try src.setEdgeProperty(edges[i], "x", .{ .Float = v });
    }

    const snap = try snapshot_manager.createSnapshotData(allocator, &src);
    defer allocator.free(snap.data);

    var dst = try GraphStore.init(allocator);
    defer dst.deinit();
    try snapshot_manager.installSnapshotData(allocator, &dst, snap.data, snap.checksum);

    var wrong: usize = 0;
    for (values, 0..) |v, i| {
        const node = dst.nodes.get(nodes[i]) orelse {
            std.debug.print("{e}: node missing after the snapshot\n", .{v});
            wrong += 1;
            continue;
        };
        const np = node.properties.get("x") orelse PropertyValue.Null;
        if (!sameFloat(v, np)) {
            std.debug.print("{e}: node property came back as {any}\n", .{ v, np });
            wrong += 1;
        }
        const edge = dst.edges.get(edges[i]) orelse {
            std.debug.print("{e}: edge missing after the snapshot\n", .{v});
            wrong += 1;
            continue;
        };
        const ep = edge.properties.get("x") orelse PropertyValue.Null;
        if (!sameFloat(v, ep)) {
            std.debug.print("{e}: edge property came back as {any}\n", .{ v, ep });
            wrong += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}
