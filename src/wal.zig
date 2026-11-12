const std = @import("std");

const graph_store = @import("graph_store.zig");

// CANARY: REQ=REQ-WAL-HOOKS-001; FEATURE="WAL Persistence Hooks"; ASPECT=CheckpointPolicy; STATUS=TESTED; TEST=tests/test_wal.zig; OWNER=storage; UPDATED=2026-11-12
//
// Persistence-loop hooks (GAP-0268). Crash recovery and WAL encryption are
// the graph-storage engine's own: its WAL is replayed by engine.open() and
// encrypted with GEODE_TDE_KEY.
//
// SONNY-6422: the logical CDC `WriteAheadLog` wrapper that used to live here
// (record types, serialization, the global instance, the graph_store
// mutation callback and the WAL-key loader) was removed. Nothing in
// the server opened one after `initGlobalWal` went (SONNY-6325); only its
// own tests did. The server installed these hooks with no WAL behind them,
// so they requested a light checkpoint on every persistence tick, and that
// is all they do now.

const logging = @import("logging");
const log = logging.scoped("wal");
const Attr = logging.Attr;

/// The hook's checkpoint policy: a light checkpoint on every persistence
/// tick (the loop's own cadence bounds how often that is).
pub fn needsCheckpointHook() bool {
    return true;
}

/// Light (O(dirty)) engine checkpoint through the adapter, plus legacy
/// sidecar cleanup. The periodic hook must never run a full O(graph)
/// checkpoint (GAP-0900).
pub fn checkpointHook(store: *graph_store.GraphStore) void {
    store.saveToFileEx(true) catch |err| {
        log.err("WAL: saveToFile failed — data may not be persisted", &.{Attr.string("error", @errorName(err))});
    };
}

/// Install the persistence hooks in graph_store's persistence loop.
pub fn installPersistenceHooks() void {
    graph_store.setWalPersistenceHooks(null, &needsCheckpointHook, &checkpointHook);
}

/// Remove the persistence hooks (e.g., during shutdown).
pub fn removePersistenceHooks() void {
    graph_store.setWalPersistenceHooks(null, null, null);
}
