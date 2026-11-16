// SONNY-6636 (b): replaying a suffix of the Raft log onto a store that
// already reflects it changes nothing, for every kind of entry the apply
// path takes.
//
// A node that snapshots its store at Raft index I compacts its log up to I.
// Its durable store keeps going past I, so after a crash it reflects some
// J >= I, and on restart the Raft node replays every committed entry after I
// (the log no longer has the ones before). Those entries up to J are applied
// a second time, onto a store that already holds their effects and the
// effects of every later entry up to J. The snapshot is taken with the
// applies held back, so it reflects exactly one index; this replay is what
// the restart relies on.
//
// The log below covers every apply kind: a plain create (GNC1), a keyed
// create (GN1K) and its retry under another index, a multi create with
// positional and absolute edge endpoints (GNC2), a keyed multi create
// (GN2K), MERGE ON MATCH SET (GMRG), SET / REMOVE / label changes (GUPD),
// DELETE and DETACH DELETE (GDEL), a keyed statement batch mixing creates,
// edges to existing nodes, updates, merges and deletes (GBAT), a tenant
// envelope (GTN1), CREATE GRAPH / DROP GRAPH (schema_change), noop and
// write. It is applied once through `raft_apply.applyCommand` into the real
// engine-backed global store. Then, for every split point s, the entries
// from s on are applied again, with the idempotency table as a snapshot at
// s would carry it, and the store must read back exactly as before: every
// node and edge (id, graph, tenant, labels, properties), the label counts
// and the graph list.
//
// CANARY: REQ=REQ-SONNY-6636-REPLAY-IDEMPOTENT; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6636_replay_idempotency.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const test_scratch = @import("test_scratch.zig");

const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;
const raft_consensus = geode.distributed.raft_consensus;
const raft_apply = geode.distributed.raft_apply;
const cr = geode.distributed.cluster_replication;
const Command = raft_consensus.Command;

const G = "r6636replay";
const G2 = "r6636replay2";
const BASE: u64 = 100;
const LABELS = [_][]const u8{ "Person6636", "Admin6636", "Item6636", "Batch6636", "Tenant6636", "Gone6636" };

fn s(v: []const u8) PropertyValue {
    return .{ .String = v };
}

fn int(v: i64) PropertyValue {
    return .{ .Int = v };
}

fn mutation(graph: []const u8, kind: @FieldType(raft_consensus.GraphMutation, "mutation_type"), data: []const u8) Command {
    return .{ .graph_mutation = .{ .graph = graph, .mutation_type = kind, .data = data, .txn_id = null } };
}

/// The log: entry k is committed at Raft index BASE + 1 + k.
const Log = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Command) = .empty,

    fn idx(self: *const Log) u64 {
        return BASE + 1 + self.entries.items.len;
    }

    fn add(self: *Log, cmd: Command) !void {
        try self.entries.append(self.arena.allocator(), cmd);
    }
};

fn buildLog(backing: std.mem.Allocator) !Log {
    var log: Log = .{ .arena = std.heap.ArenaAllocator.init(backing) };
    errdefer log.arena.deinit();
    const a = log.arena.allocator();

    // A: GNC1 create (id = its index).
    const a_id = log.idx();
    try log.add(mutation(G, .create, try cr.serializeNodeCreate(a, G, &.{"Person6636"}, &.{ .{ .key = "name", .value = s("a") }, .{ .key = "n", .value = int(1) } })));
    // B: GN1K keyed create.
    const b_id = log.idx();
    try log.add(mutation(G, .create, try cr.serializeNodeCreateKeyed(a, G, &.{"Person6636"}, &.{.{ .key = "name", .value = s("b") }}, "key-b-6636")));
    // C, D and edges C->D (positional), C->A (absolute): GNC2.
    const cd_index = log.idx();
    const c_id = cr.deriveMultiNodeId(cd_index, 0);
    const d_id = cr.deriveMultiNodeId(cd_index, 1);
    const cd_edge = cr.deriveMultiEdgeId(cd_index, 0);
    const ca_edge = cr.deriveMultiEdgeId(cd_index, 1);
    try log.add(mutation(G, .create, try cr.serializeMultiCreate(a, G, &.{
        .{ .labels = &.{"Item6636"}, .props = &.{.{ .key = "name", .value = s("c") }} },
        .{ .labels = &.{ "Item6636", "Gone6636" }, .props = &.{.{ .key = "name", .value = s("d") }} },
    }, &.{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "LINKS6636", .props = &.{.{ .key = "w", .value = int(1) }} },
        .{ .from = .{ .position = 0 }, .to = .{ .absolute_id = a_id }, .edge_type = "POINTS6636", .props = &.{} },
    })));
    // MERGE ON MATCH SET on A.
    try log.add(mutation(G, .merge, try cr.serializeMerge(a, G, a_id, &.{.{ .key = "n", .value = int(2) }})));
    // SET / REMOVE / labels on A and D.
    try log.add(mutation(G, .update, try cr.serializeUpdate(a, G, &.{
        .{ .node_id = a_id, .set_props = &.{.{ .key = "n", .value = int(3) }}, .remove_props = &.{"name"}, .add_labels = &.{"Admin6636"} },
        .{ .node_id = d_id, .remove_labels = &.{"Gone6636"}, .set_props = &.{.{ .key = "flag", .value = .{ .Bool = true } }} },
    })));
    // Keyed batch: create E with an edge E->B (absolute), update B, merge C,
    // delete the edge C->D.
    const batch_index = log.idx();
    const e_create = try cr.serializeMultiCreate(a, G, &.{.{ .labels = &.{"Batch6636"}, .props = &.{.{ .key = "name", .value = s("e") }} }}, &.{
        .{ .from = .{ .position = 0 }, .to = .{ .absolute_id = b_id }, .edge_type = "KNOWS6636", .props = &.{} },
    });
    try log.add(mutation(G, .create, try cr.serializeBatch(a, "key-batch-6636", &.{
        .{ .mutation = .create, .graph = G, .data = e_create },
        .{ .mutation = .update, .graph = G, .data = try cr.serializeUpdate(a, G, &.{.{ .node_id = b_id, .set_props = &.{.{ .key = "p", .value = int(1) }} }}) },
        .{ .mutation = .merge, .graph = G, .data = try cr.serializeMerge(a, G, c_id, &.{.{ .key = "q", .value = int(1) }}) },
        .{ .mutation = .delete, .graph = G, .data = try cr.serializeDelete(a, G, &.{cd_edge}, &.{}) },
    })));
    const e_id = cr.batchLaneBase(batch_index, 0);
    // DETACH DELETE A (its incident edge C->A listed by the leader).
    try log.add(mutation(G, .delete, try cr.serializeDelete(a, G, &.{ca_edge}, &.{a_id})));
    // SET B.p again: replaying the batch must not leave p = 1.
    try log.add(mutation(G, .update, try cr.serializeUpdate(a, G, &.{.{ .node_id = b_id, .set_props = &.{.{ .key = "p", .value = int(2) }} }})));
    // A create under a tenant envelope.
    try log.add(mutation(G, .create, try cr.wrapWithTenant(a, "acme6636", try cr.serializeNodeCreate(a, G, &.{"Tenant6636"}, &.{.{ .key = "name", .value = s("f") }}))));
    // GN2K keyed multi create: G and H linked.
    try log.add(mutation(G, .create, try cr.serializeMultiCreateKeyed(a, G, &.{
        .{ .labels = &.{"Item6636"}, .props = &.{.{ .key = "name", .value = s("g") }} },
        .{ .labels = &.{"Item6636"}, .props = &.{.{ .key = "name", .value = s("h") }} },
    }, &.{.{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "LINKS6636", .props = &.{} }}, "key-gh-6636")));
    // DELETE D (no edges left), then the batch's E gets a property, and E
    // is detached from B.
    try log.add(mutation(G, .delete, try cr.serializeDelete(a, G, &.{}, &.{d_id})));
    try log.add(mutation(G, .update, try cr.serializeUpdate(a, G, &.{.{ .node_id = e_id, .set_props = &.{.{ .key = "late", .value = int(7) }}, .add_labels = &.{"Admin6636"} }})));
    // The client retries B under another index: a no-op.
    try log.add(mutation(G, .create, try cr.serializeNodeCreateKeyed(a, G, &.{"Person6636"}, &.{.{ .key = "name", .value = s("b") }}, "key-b-6636")));
    // ... and the batch.
    try log.add(mutation(G, .create, try cr.serializeBatch(a, "key-batch-6636", &.{
        .{ .mutation = .create, .graph = G, .data = e_create },
    })));
    // An entry that touches a node a later entry deletes, and then one that
    // survives: replayed, it must still reach the survivor, or the survivor
    // keeps the value an earlier replayed entry gave it back.
    const x_id = log.idx();
    try log.add(mutation(G, .create, try cr.serializeNodeCreate(a, G, &.{"Person6636"}, &.{.{ .key = "name", .value = s("x") }})));
    const y_id = log.idx();
    try log.add(mutation(G, .create, try cr.serializeNodeCreate(a, G, &.{"Gone6636"}, &.{})));
    try log.add(mutation(G, .update, try cr.serializeUpdate(a, G, &.{.{ .node_id = x_id, .set_props = &.{ .{ .key = "r", .value = int(1) }, .{ .key = "t", .value = int(1) }, .{ .key = "m", .value = int(1) } } }})));
    try log.add(mutation(G, .update, try cr.serializeUpdate(a, G, &.{
        .{ .node_id = y_id, .set_props = &.{.{ .key = "n", .value = int(9) }}, .add_labels = &.{"Admin6636"} },
        .{ .node_id = x_id, .set_props = &.{.{ .key = "r", .value = int(2) }} },
    })));
    try log.add(mutation(G, .create, try cr.serializeBatch(a, null, &.{
        .{ .mutation = .merge, .graph = G, .data = try cr.serializeMerge(a, G, y_id, &.{.{ .key = "n", .value = int(10) }}) },
        .{ .mutation = .update, .graph = G, .data = try cr.serializeUpdate(a, G, &.{.{ .node_id = x_id, .set_props = &.{.{ .key = "m", .value = int(2) }} }}) },
    })));
    const xy_index = log.idx();
    try log.add(mutation(G, .create, try cr.serializeBatch(a, null, &.{
        .{ .mutation = .create, .graph = G, .data = try cr.serializeMultiCreate(a, G, &.{}, &.{
            .{ .from = .{ .absolute_id = x_id }, .to = .{ .absolute_id = y_id }, .edge_type = "POINTS6636", .props = &.{.{ .key = "w", .value = int(1) }} },
            .{ .from = .{ .absolute_id = y_id }, .to = .{ .absolute_id = x_id }, .edge_type = "POINTS6636", .props = &.{} },
        }) },
        .{ .mutation = .update, .graph = G, .data = try cr.serializeUpdate(a, G, &.{.{ .node_id = x_id, .set_props = &.{.{ .key = "t", .value = int(2) }} }}) },
    })));
    try log.add(mutation(G, .delete, try cr.serializeDelete(a, G, &.{ cr.batchLaneBase(xy_index, 0) + cr.MAX_MULTI_NODES, cr.batchLaneBase(xy_index, 0) + cr.MAX_MULTI_NODES + 1 }, &.{y_id})));
    // A graph created, written, dropped.
    try log.add(.{ .schema_change = .{ .operation = .create_graph, .graph = G2, .schema = "" } });
    try log.add(mutation(G2, .create, try cr.serializeNodeCreate(a, G2, &.{"Person6636"}, &.{})));
    try log.add(.{ .schema_change = .{ .operation = .drop_graph, .graph = G2, .schema = "" } });
    // A default-graph create, then noop and write.
    try log.add(mutation(graph_store.DEFAULT_GRAPH_NAME, .create, try cr.serializeNodeCreate(a, graph_store.DEFAULT_GRAPH_NAME, &.{"Person6636"}, &.{.{ .key = "name", .value = s("default") }})));
    try log.add(.noop);
    try log.add(.{ .write = "sonny6636" });
    return log;
}

fn applyEntry(a: std.mem.Allocator, store: *GraphStore, cmd: Command, raft_index: u64) !void {
    const out = raft_apply.applyCommand(a, store, cmd, raft_index) catch |err| {
        // A replayed entry that refers to something a later entry removed may
        // fail; the Raft node logs it and goes on (`finishReady`).
        std.debug.print("SONNY-6636: entry {d} ({s}) failed: {s}\n", .{ raft_index, @tagName(cmd), @errorName(err) });
        return;
    };
    a.free(out);
}

fn appendValue(out: *std.ArrayList(u8), a: std.mem.Allocator, v: PropertyValue) !void {
    switch (v) {
        .String => |x| try out.print(a, "s:{s}", .{x}),
        .Int => |x| try out.print(a, "i:{d}", .{x}),
        .Float => |x| try out.print(a, "f:{e}", .{x}),
        .Bool => |x| try out.print(a, "b:{}", .{x}),
        .Null => try out.appendSlice(a, "null"),
        else => try out.print(a, "{s}", .{@tagName(v)}),
    }
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn appendProps(out: *std.ArrayList(u8), a: std.mem.Allocator, props: anytype) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(a);
    var it = props.iterator();
    while (it.next()) |p| try keys.append(a, p.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, lessStr);
    for (keys.items) |k| {
        try out.print(a, " {s}=", .{k});
        try appendValue(out, a, props.get(k).?);
    }
}

/// Every node and edge, the label counts and the graph list, in a canonical
/// order.
fn dump(a: std.mem.Allocator, store: *GraphStore) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const nodes = try store.getAllNodes(a);
    defer a.free(nodes);
    std.mem.sort(u64, nodes, {}, std.sort.asc(u64));
    for (nodes) |id| {
        const n = (try store.getNodePtrHydratedChecked(id)) orelse continue;
        const labels = try a.dupe([]const u8, n.labels);
        defer a.free(labels);
        std.mem.sort([]const u8, labels, {}, lessStr);
        try out.print(a, "N {d} {s} {s} [", .{ id, n.graph_name, n.tenant_id });
        for (labels) |l| try out.print(a, "{s},", .{l});
        try out.append(a, ']');
        try appendProps(&out, a, &n.properties);
        try out.append(a, '\n');
    }
    const edges = try store.getAllEdgesForTenant(a, null);
    defer a.free(edges);
    std.mem.sort(u64, edges, {}, std.sort.asc(u64));
    for (edges) |id| {
        const e = (try store.getEdgePtrHydratedChecked(id)) orelse continue;
        try out.print(a, "E {d} {d}->{d} {s} {s} {s}", .{ id, e.from_id, e.to_id, e.label, e.graph_name, e.tenant_id });
        try appendProps(&out, a, &e.properties);
        try out.append(a, '\n');
    }
    for ([_][]const u8{ G, G2, graph_store.DEFAULT_GRAPH_NAME }) |g| {
        for (LABELS) |l| try out.print(a, "C {s} {s} {d}\n", .{ g, l, store.countNodesByLabel(g, l, null) });
    }
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const names = try ad.listGraphNames(a);
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    std.mem.sort([]const u8, names, {}, lessStr);
    for (names) |n| try out.print(a, "G {s}\n", .{n});
    return out.toOwnedSlice(a);
}

test "SONNY-6636: replaying any suffix of the Raft log onto a store that already reflects it leaves the store unchanged, for every apply kind" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-replay");
    defer root.remove();
    defer graph_store.setDataDirOverride(a, null);

    const store = try graph_store.initGlobalStore(a, root.path());
    try store.loadFromFile();
    defer {
        geode.execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
    }
    try store.createGraph(G);
    raft_apply.setGlobalStore(store);
    defer raft_apply.resetGlobalStore();
    var dedup = cr.IdempotencyDedup.init(a);
    defer dedup.deinit();
    raft_apply.setGlobalIdempotencyDedup(&dedup);
    defer raft_apply.resetGlobalIdempotencyDedup();

    var log = try buildLog(a);
    defer log.arena.deinit();
    const entries = log.entries.items;

    // Applied once; the idempotency table as a snapshot at each split point
    // carries it.
    var tables: std.ArrayList([]u8) = .empty;
    defer {
        for (tables.items) |t| a.free(t);
        tables.deinit(a);
    }
    for (entries, 0..) |cmd, k| {
        var t: std.ArrayList(u8) = .empty;
        try dedup.serialize(&t, a);
        try tables.append(a, try t.toOwnedSlice(a));
        try applyEntry(a, store, cmd, BASE + 1 + k);
    }
    const expected = try dump(a, store);
    defer a.free(expected);
    std.debug.print("SONNY-6636: {d} entries applied once; the store:\n{s}", .{ entries.len, expected });
    // The log did what it says (a few spot checks).
    try testing.expect(std.mem.indexOf(u8, expected, "s:default") != null);
    try testing.expect(std.mem.indexOf(u8, expected, "p=i:2") != null);
    try testing.expect(std.mem.indexOf(u8, expected, "late=i:7") != null);
    try testing.expect(std.mem.indexOf(u8, expected, "POINTS6636") == null);
    try testing.expect(std.mem.indexOf(u8, expected, "m=i:2 name=s:x r=i:2 t=i:2") != null);
    try testing.expect(std.mem.indexOf(u8, expected, "G " ++ G2 ++ "\n") == null);

    var split: usize = entries.len;
    while (split > 0) {
        split -= 1;
        try dedup.replaceFrom(tables.items[split]);
        for (entries[split..], split..) |cmd, k| try applyEntry(a, store, cmd, BASE + 1 + k);
        const got = try dump(a, store);
        defer a.free(got);
        if (!std.mem.eql(u8, expected, got)) {
            std.debug.print("SONNY-6636: replaying from entry {d} (index {d}) changed the store to:\n{s}", .{ split, BASE + 1 + split, got });
            return error.ReplayChangedTheStore;
        }
    }
    std.debug.print("SONNY-6636: every one of the {d} suffixes replayed onto the store left it unchanged\n", .{entries.len});
}
