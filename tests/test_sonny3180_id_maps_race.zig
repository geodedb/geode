// SONNY-3180 regression: GraphStore.id_maps is safe to use from threads that
// work on different graphs at once.
//
// `id_maps` (graph name -> the graph's UUID <-> engine-slot IdMap) is one map
// for the whole store. Writers of the same graph are serialized by that
// graph's lock, but writers of different graphs run at once, and
// `getOrCreateIdMap` inserted into the map with no lock: two sessions writing
// to different graphs corrupted it (Debug builds tripped the hash map's
// safety check in 1 of 12 runs of test-sonny2805-txn-sessions). And the maps
// were stored in the hash map itself, so an insert that grew it moved every
// graph's IdMap, and its mutex, from under a thread holding a pointer to it.
//
// Now the map has a lock (a read-mostly lock with a double-checked create),
// each IdMap has an address of its own that no insert moves, and the walks
// over all graphs hold the lock or copy the list under it. A dropped graph's
// IdMap is emptied and kept, with its name, until the store goes.
//
// Threads create and use IdMaps of distinct graphs, others look them up, and
// one creates and drops graphs, all at once, under the testing allocator.
//
// CANARY: REQ=REQ-SONNY-3180-ID-MAPS-LOCK; FEATURE="GraphStore"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3180_id_maps_race.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const IdMap = graph_store.IdMap;

const writers = 8;
const graphs_per_writer = 400;
const readers = 3;
const ddl_cycles = 200;

const Made = struct {
    map: *IdMap,
    uuid: u128,
    slot: u64,
};

const Shared = struct {
    st: *graph_store.GraphStore,
    made: [writers][graphs_per_writer]Made = undefined,
    writers_done: std.atomic.Value(usize) = .init(0),
    errors: std.atomic.Value(usize) = .init(0),
    lookups: std.atomic.Value(usize) = .init(0),

    fn name(buf: []u8, w: usize, i: usize) []const u8 {
        return std.fmt.bufPrint(buf, "w{d}-g{d}", .{ w, i }) catch unreachable;
    }

    fn writer(self: *Shared, w: usize) void {
        defer _ = self.writers_done.fetchAdd(1, .acq_rel);
        var buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < graphs_per_writer) : (i += 1) {
            const n = name(&buf, w, i);
            const im = self.st.getOrCreateIdMap(n) catch {
                _ = self.errors.fetchAdd(1, .acq_rel);
                continue;
            };
            const uuid: u128 = (@as(u128, w + 1) << 64) | i;
            const slot = im.insertNode(uuid) catch {
                _ = self.errors.fetchAdd(1, .acq_rel);
                continue;
            };
            self.made[w][i] = .{ .map = im, .uuid = uuid, .slot = slot };
            // Every graph this writer made so far: the same IdMap, which still
            // knows its node, however many graphs were added since.
            if (i % 50 == 49) {
                var j: usize = 0;
                while (j <= i) : (j += 1) {
                    const m = self.made[w][j];
                    const again = self.st.getOrCreateIdMap(name(&buf, w, j)) catch {
                        _ = self.errors.fetchAdd(1, .acq_rel);
                        continue;
                    };
                    if (again != m.map or m.map.nodeSlot(m.uuid) != m.slot) _ = self.errors.fetchAdd(1, .acq_rel);
                }
            }
            // A graph every writer shares.
            _ = self.st.getOrCreateIdMap("shared") catch {
                _ = self.errors.fetchAdd(1, .acq_rel);
            };
        }
    }

    fn reader(self: *Shared, r: usize) void {
        var buf: [32]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(r + 1);
        const rand = prng.random();
        while (self.writers_done.load(.acquire) < writers) {
            const w = rand.uintLessThan(usize, writers);
            const i = rand.uintLessThan(usize, graphs_per_writer);
            if (self.st.getIdMap(name(&buf, w, i))) |im| {
                const uuid: u128 = (@as(u128, w + 1) << 64) | i;
                // The writer may not have inserted its node yet.
                _ = im.nodeSlot(uuid);
            }
            _ = self.st.getNodeCount();
            _ = self.lookups.fetchAdd(1, .monotonic);
        }
    }

    fn ddl(self: *Shared) void {
        var buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < ddl_cycles) : (i += 1) {
            const n = std.fmt.bufPrint(&buf, "ddl-{d}", .{i}) catch unreachable;
            self.st.createGraph(n) catch {
                _ = self.errors.fetchAdd(1, .acq_rel);
                continue;
            };
            const im = self.st.getIdMap(n) orelse {
                _ = self.errors.fetchAdd(1, .acq_rel);
                continue;
            };
            _ = im.insertNode(@as(u128, 0xdd) << 96 | i) catch {
                _ = self.errors.fetchAdd(1, .acq_rel);
            };
            self.st.dropGraph(n) catch {
                _ = self.errors.fetchAdd(1, .acq_rel);
            };
            if (self.st.getIdMap(n) != null) _ = self.errors.fetchAdd(1, .acq_rel);
        }
    }
};

test "SONNY-3180: threads creating and using the IdMaps of distinct graphs, readers and a CREATE/DROP GRAPH loop, all at once: no corruption, and every IdMap keeps its address" {
    var st = try graph_store.GraphStore.init(testing.allocator);
    defer st.deinit();
    var shared: Shared = .{ .st = &st };
    var threads: [writers + readers + 1]std.Thread = undefined;
    var n: usize = 0;
    while (n < writers) : (n += 1) threads[n] = try std.Thread.spawn(.{}, Shared.writer, .{ &shared, n });
    var r: usize = 0;
    while (r < readers) : (r += 1) threads[writers + r] = try std.Thread.spawn(.{}, Shared.reader, .{ &shared, r });
    threads[writers + readers] = try std.Thread.spawn(.{}, Shared.ddl, .{&shared});
    for (threads) |t| t.join();

    // Every graph's IdMap is where it was made, and knows its node.
    var buf: [32]u8 = undefined;
    var moved: usize = 0;
    var lost: usize = 0;
    var w: usize = 0;
    while (w < writers) : (w += 1) {
        var i: usize = 0;
        while (i < graphs_per_writer) : (i += 1) {
            const m = shared.made[w][i];
            const now = st.getIdMap(Shared.name(&buf, w, i)) orelse {
                lost += 1;
                continue;
            };
            if (now != m.map) moved += 1;
            if (now.nodeSlot(m.uuid) != m.slot) lost += 1;
        }
    }
    std.debug.print("SONNY-3180: errors={d} moved={d} lost={d} lookups={d}\n", .{ shared.errors.load(.acquire), moved, lost, shared.lookups.load(.acquire) });
    try testing.expectEqual(@as(usize, 0), shared.errors.load(.acquire));
    try testing.expectEqual(@as(usize, 0), moved);
    try testing.expectEqual(@as(usize, 0), lost);
}

test "SONNY-3180: an IdMap keeps its address when other graphs' IdMaps are added (single thread)" {
    var st = try graph_store.GraphStore.init(testing.allocator);
    defer st.deinit();
    const first = try st.getOrCreateIdMap("first");
    const slot = try first.insertNode(42);
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 2000) : (i += 1) _ = try st.getOrCreateIdMap(try std.fmt.bufPrint(&buf, "g{d}", .{i}));
    try testing.expect(st.getIdMap("first").? == first);
    try testing.expectEqual(@as(?u64, slot), first.nodeSlot(42));
}
