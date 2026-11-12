const std = @import("std");

const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const wal_mod = geode.wal;

// CANARY: REQ=REQ-WAL-HOOKS-001; FEATURE="WAL Persistence Hooks"; ASPECT=UnitTest; STATUS=TESTED; TEST=tests/test_wal.zig; OWNER=storage; UPDATED=2026-11-12
// The persistence-loop hooks the server installs (src/wal.zig). SONNY-6422:
// the tests of the removed logical CDC WriteAheadLog wrapper went with it.

test "WAL hooks: the persistence loop is asked for a light checkpoint on every tick" {
    try testing.expect(wal_mod.needsCheckpointHook());
}

test "WAL hooks: the checkpoint hook checkpoints the store and clears its dirty flag" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    store.dirty.store(true, .release);
    wal_mod.checkpointHook(&store);
    try testing.expect(!store.dirty.load(.acquire));
}
