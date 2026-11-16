// Raft apply callback — routes committed Command variants to GraphStore mutations.
//
// This module provides the bridge between the Raft consensus layer and the
// graph storage engine.  When a Raft entry is committed, `drainReady()` in
// `raft_consensus.zig` calls the registered `apply_callback`.  The callback
// dispatches on the Command variant, applies side-effects to the GraphStore,
// and returns an (optional) result payload.
//
// Thread-safety: the callback runs inside the Raft tick loop which is
// single-threaded per RaftNode.  The GraphStore itself uses internal locking,
// so concurrent access from the query engine is safe.
//
// What reaches this module (SONNY-6547 (6)): the server proposes only
// `graph_mutation` entries (`statement_proposals.zig`, through
// `ClusterCoordinator.proposeWrite`), plus the raft library's own no-op.
// Nothing in the server proposes `schema_change`, `config_change`,
// `snapshot_pointer`, `txn_prepare` or `txn_decide`: their arms below are
// the receiving side of features that do not exist yet (replicated DDL,
// dynamic membership, log truncation, distributed transactions), kept
// because they are safe and tested, and exercised only by tests that
// propose or apply such entries directly. In cluster mode the DDL they
// would carry is refused (`cluster.gateUnreplicatedWrite`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const raft_consensus = @import("raft_consensus.zig");
const Command = raft_consensus.Command;
const GraphMutation = raft_consensus.GraphMutation;
const SchemaChange = raft_consensus.SchemaChange;
const ConfigChange = raft_consensus.ConfigChange;
const SnapshotPointer = raft_consensus.SnapshotPointer;
const TxnPrepare = raft_consensus.TxnPrepare;
const TxnDecide = raft_consensus.TxnDecide;
const TxnCoordinator = @import("txn_coordinator.zig").TxnCoordinator;
const graph_store_mod = @import("../graph_store.zig");
const GraphStore = graph_store_mod.GraphStore;
const cluster_replication = @import("cluster_replication.zig");
const raft_snapshot_manager = @import("raft_snapshot_manager.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
const fle_integration = @import("../fle_integration.zig");

const logging = @import("logging");
const log = logging.scoped("raft_apply");
const Attr = logging.Attr;

// ---------------------------------------------------------------------------
// Module-level store reference (MVP approach)
//
// The Raft apply_callback is a plain function pointer — no closure context.
// We use a module-level variable so `applyCallbackFn` can reach the store.
// `setGlobalStore` must be called once during coordinator/server init before
// the Raft node starts ticking.
// ---------------------------------------------------------------------------

var g_store: ?*GraphStore = null;

// CANARY: REQ=REQ-SONNY-6567-RAFT-APPLY-HYDRATION; FEATURE="DistributedCluster"; ASPECT=RefusedReplicatedDropHaltsApply; STATUS=TESTED; TEST=tests/test_sonny6547_single_voter_drop.zig; OWNER=distributed; UPDATED=2026-11-15
/// SONNY-6567 (6a): set when a committed entry could not be applied on this
/// node in a way that leaves it different from the others (a replicated
/// DROP GRAPH refused because a session transaction changed the graph). The
/// Raft node logs an entry it could not apply and goes on with the next one:
/// the node kept the graph every other node dropped, and applied (or
/// failed) the later entries on it differently. Instead it stops applying:
/// every later entry fails (`ReplicatedApplyHalted`), so its store stays the
/// cluster's state as of the entry before the drop (behind, never
/// different), and the operator error says to restart it. A restarted node
/// replays the committed log (cluster.zig: rebuilt by committed-log replay)
/// with no transaction open, and the drop applies. Hard stop, not a
/// decision about open transactions: that is for the replicated DDL feature
/// (nothing proposes a `schema_change` today, SONNY-6547 (6)).
var g_apply_halted: std.atomic.Value(bool) = .init(false);

fn haltApply(reason: []const u8, graph: []const u8) void {
    if (g_apply_halted.swap(true, .acq_rel)) return;
    log.err("raft apply: HALTED: a committed entry could not be applied on this node; it stops applying so it cannot diverge from the cluster. Restart the node: it replays the committed log", &.{
        Attr.string("reason", reason),
        Attr.string("graph", graph),
    });
}

/// Has this node stopped applying (SONNY-6567 (6a))?
pub fn applyHalted() bool {
    return g_apply_halted.load(.acquire);
}

/// Tests: clear the halt (a restart does, the flag is per process).
pub fn resetApplyHaltForTesting() void {
    g_apply_halted.store(false, .release);
}

/// Register the graph store used by the apply callback.
/// Must be called before the Raft node begins processing committed entries.
pub fn setGlobalStore(store: *GraphStore) void {
    g_store = store;
    loadStoreRaftIndex(store);
}

// CANARY: REQ=REQ-SONNY-6636-STORE-RAFT-INDEX; FEATURE="Raft Snapshot Persistence"; ASPECT=CoveredEntriesNotReapplied; STATUS=TESTED; TEST=tests/test_sonny6636_durable_snapshot_restore.zig; OWNER=distributed; UPDATED=2026-11-16
/// SONNY-6636 (3): the Raft index the registered durable store reflects
/// (`raft_store.index`, recorded when a snapshot restore finished); 0 when
/// none. `applyCommand` applies no entry at or below it: the snapshot
/// covered it, and a node that restarted before the snapshot was persisted
/// in its Raft log replays its older entries onto the restored store.
var g_store_raft_index: std.atomic.Value(u64) = .init(0);

pub fn storeRaftIndex() u64 {
    return g_store_raft_index.load(.acquire);
}

fn loadStoreRaftIndex(store: *GraphStore) void {
    g_store_raft_index.store(0, .release);
    const adapter = graph_store_mod.getGlobalAdapter() orelse return;
    if (graph_store_mod.getCurrentGlobalStore() != store) return;
    const point = adapter.storeRaftIndex() catch |err| {
        // Guessing low would apply entries the store already reflects.
        log.err("raft apply: the Raft index the store reflects cannot be read; this node applies nothing until it is fixed", &.{Attr.string("error", @errorName(err))});
        haltApply("raft_store.index unreadable", "");
        return;
    };
    g_store_raft_index.store(point.index, .release);
}

/// Return the currently registered store (useful in tests / diagnostics).
pub fn getGlobalStore() ?*GraphStore {
    return g_store;
}

/// Reset the global store to null (for test isolation).
pub fn resetGlobalStore() void {
    g_store = null;
    g_store_raft_index.store(0, .release);
}

// ---------------------------------------------------------------------------
// Applied cluster configuration (GAP-0870)
//
// Committed `config_change` entries mutate this membership view.  The
// coordinator registers its instance at startup (same pattern as
// `setGlobalStore`); tests register their own.  Apply runs single-threaded
// inside the Raft tick loop, so no internal locking is required — readers
// outside that loop get an eventually-consistent snapshot, which matches
// the semantics of every other raft-applied state in this module.
// ---------------------------------------------------------------------------

pub const ClusterMember = struct {
    server_id: u64,
    /// Owned by the AppliedClusterConfig allocator.
    endpoint: []u8,
    port: ?u16,
};

pub const AppliedClusterConfig = struct {
    allocator: Allocator,
    members: std.AutoHashMap(u64, ClusterMember),
    /// Bumped on every applied config_change (observable progress marker).
    version: u64 = 0,

    pub fn init(allocator: Allocator) AppliedClusterConfig {
        return .{
            .allocator = allocator,
            .members = std.AutoHashMap(u64, ClusterMember).init(allocator),
        };
    }

    pub fn deinit(self: *AppliedClusterConfig) void {
        var it = self.members.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.endpoint);
        self.members.deinit();
    }

    pub fn getMember(self: *const AppliedClusterConfig, server_id: u64) ?ClusterMember {
        return self.members.get(server_id);
    }

    pub fn memberCount(self: *const AppliedClusterConfig) usize {
        return self.members.count();
    }

    /// Upsert a member (add_server / update_server). Deterministic across
    /// nodes: a duplicate add or an update of an unknown id both resolve to
    /// "member present with these coordinates" — restart-idempotent.
    pub fn upsertMember(self: *AppliedClusterConfig, server_id: u64, endpoint: []const u8, port: ?u16) !void {
        const owned = try self.allocator.dupe(u8, endpoint);
        errdefer self.allocator.free(owned);
        const gop = try self.members.getOrPut(server_id);
        if (gop.found_existing) self.allocator.free(gop.value_ptr.endpoint);
        gop.value_ptr.* = .{ .server_id = server_id, .endpoint = owned, .port = port };
        self.version += 1;
    }

    /// Remove a member. Removing an absent member is a clean no-op
    /// (restart-idempotent replay of remove after remove).
    pub fn removeMember(self: *AppliedClusterConfig, server_id: u64) void {
        if (self.members.fetchRemove(server_id)) |kv| self.allocator.free(kv.value.endpoint);
        self.version += 1;
    }
};

var g_cluster_config: ?*AppliedClusterConfig = null;

/// Register the applied-membership view mutated by committed config_change
/// entries. Must be set before the Raft node ticks if config changes are
/// proposed; an unregistered view fails apply loudly.
pub fn setGlobalClusterConfig(cfg: *AppliedClusterConfig) void {
    g_cluster_config = cfg;
}

pub fn getGlobalClusterConfig() ?*AppliedClusterConfig {
    return g_cluster_config;
}

pub fn resetGlobalClusterConfig() void {
    g_cluster_config = null;
}

// ---------------------------------------------------------------------------
// Snapshot pointer metadata (GAP-0870)
//
// A committed `snapshot_pointer` records that a snapshot covering the log
// prefix up to `last_included_index` exists — the licence for log
// truncation. We keep the latest (highest-index) pointer; an older pointer
// arriving later (restart replay) never regresses the recorded watermark.
// ---------------------------------------------------------------------------

var g_snapshot_pointer: ?SnapshotPointer = null;

/// The latest applied snapshot pointer, or null if none committed yet.
pub fn lastSnapshotPointer() ?SnapshotPointer {
    return g_snapshot_pointer;
}

pub fn resetSnapshotPointer() void {
    g_snapshot_pointer = null;
}

// ---------------------------------------------------------------------------
// 2PC coordinator registration (GAP-0870)
//
// Committed txn_prepare / txn_decide entries route into the existing 2PC
// machinery (`txn_coordinator.TxnCoordinator`): prepare buffers the write
// set + takes locks, decide(commit) applies the write set to the store,
// decide(abort) releases without applying. No server code proposes such an
// entry (SONNY-6547 (6)): geode runs no distributed transaction.
// ---------------------------------------------------------------------------

var g_txn_coordinator: ?*TxnCoordinator = null;

/// Register the 2PC coordinator used by txn_prepare / txn_decide apply.
pub fn setGlobalTxnCoordinator(coord: *TxnCoordinator) void {
    g_txn_coordinator = coord;
}

pub fn getGlobalTxnCoordinator() ?*TxnCoordinator {
    return g_txn_coordinator;
}

pub fn resetGlobalTxnCoordinator() void {
    g_txn_coordinator = null;
}

// ---------------------------------------------------------------------------
// Idempotency-key dedup table (RC-3, 2026-06-12)
//
// "committed write -> client Timeout -> retry double-insert": a keyed create
// carries an optional client idempotency key. The apply path consults this
// process-wide table so a same-key-DIFFERENT-index retry is a NO-OP (the
// duplicate-row fix), while a same-index re-apply (restart replay) stays the
// normal index-idempotent path. The table is rebuilt naturally by replay (geode
// re-applies the full committed log on restart, in order), so it is
// cross-replica deterministic without any persistence of its own. Apply runs
// single-threaded inside the Raft tick loop, so no internal locking is needed.
// ---------------------------------------------------------------------------

var g_idempotency_dedup: ?*cluster_replication.IdempotencyDedup = null;

/// Register the idempotency-key dedup table consulted by keyed create apply.
/// The coordinator owns the table's lifetime (same pattern as setGlobalStore);
/// tests register their own. If unregistered, keyed creates fall back to
/// index-only dedup (a lazily-created per-apply table would defeat cross-entry
/// retry detection, so we instead apply the inner body directly — see the
/// `.create` branch).
pub fn setGlobalIdempotencyDedup(dedup: *cluster_replication.IdempotencyDedup) void {
    g_idempotency_dedup = dedup;
}

pub fn getGlobalIdempotencyDedup() ?*cluster_replication.IdempotencyDedup {
    return g_idempotency_dedup;
}

pub fn resetGlobalIdempotencyDedup() void {
    g_idempotency_dedup = null;
}

// ---------------------------------------------------------------------------
// Apply callback — matches the RaftNode.apply_callback signature
// ---------------------------------------------------------------------------

/// Function-pointer-compatible callback for `RaftNode.apply_callback`.
/// Delegates to `applyCommand` using the module-level `g_store`. `raft_index`
/// is the committed entry's globally-unique, cross-node-identical log index,
/// used to derive a deterministic, restart-idempotent node id.
pub fn applyCallbackFn(allocator: Allocator, cmd: Command, raft_index: u64) anyerror![]u8 {
    return applyCommand(allocator, g_store, cmd, raft_index);
}

// CANARY: REQ=REQ-SONNY-6547-APPLY-HYDRATION-OFF-RAFT-MUTEX; FEATURE="DistributedCluster"; ASPECT=PrehydrateBeforePropose; STATUS=TESTED; TEST=tests/test_sonny6547_apply_hydration_stall.zig; OWNER=distributed; UPDATED=2026-11-14
/// SONNY-6547 (4): hydrate the graph a `graph_mutation` entry's apply writes
/// (`applyGraphMutationInner`), for a proposer to call before it takes the
/// Raft node's `inner_mutex`: the apply then finds the graph hydrated and
/// builds nothing under `inner_mutex`. The products are not persisted here
/// either (the proposer may hold the graph's lock, which that persist's
/// checkpoint waits for); the next full checkpoint persists them. Ordering
/// is unchanged: hydration builds resident indexes from the engine, as any
/// first read of the graph does, and writes nothing.
///
/// SONNY-6631: also the graph of every entry of a statement batch (GBAT),
/// inside a tenant wrapper or not: a batch for one graph may write
/// another. The Raft node calls it (`RaftNode.prehydrate_callback`) for
/// every entry a follower receives and every entry a restarted node
/// replays.
pub fn prehydrateForApply(cmd: Command) void {
    const store = g_store orelse return;
    switch (cmd) {
        .graph_mutation => |gm| {
            const graph = if (gm.graph.len > 0) gm.graph else "default";
            // SONNY-6605: a build that fails transiently is tried again by the
            // apply, which fails if it fails again.
            store.ensureGraphHydratedForReplicatedApply(graph) catch {};
            const body = if (cluster_replication.isTenantPayload(gm.data))
                (cluster_replication.splitTenant(gm.data) catch return).inner
            else
                gm.data;
            if (cluster_replication.isBatchPayload(body)) {
                // A malformed batch is refused by its apply; nothing to do here.
                cluster_replication.forEachBatchGraph(body, store, prehydrateBatchEntry) catch {};
            } else internNamesOf(graph, body);
        },
        else => {},
    }
}

fn prehydrateBatchEntry(store: *GraphStore, graph: []const u8, payload: []const u8) void {
    const g = if (graph.len > 0) graph else "default";
    store.ensureGraphHydratedForReplicatedApply(g) catch {};
    internNamesOf(g, payload);
}

// CANARY: REQ=REQ-SONNY-6633-INTERN-LABELS-BEFORE-APPLY; FEATURE="DistributedCluster"; ASPECT=PrehydrateInternsNames; STATUS=TESTED; TEST=tests/test_sonny6631_apply_hydration_off_mutex.zig; OWNER=distributed; UPDATED=2026-11-15
/// SONNY-6633 (4): give the labels and relationship types a lone-entry
/// payload writes their label ids before the apply, so a name new to the
/// graph is not written to disk (fsynced) under `inner_mutex`
/// (`StorageAdapter.internNamesForReplicatedApply`). The payload's own
/// graph wins over the entry's. Best effort.
fn internNamesOf(entry_graph: []const u8, payload: []const u8) void {
    // Not on a thread holding a graph's lock or the store lock (a leader's
    // proposer inside its statement): pinning takes the adapter's tier-0
    // handle mutex, never taken after a graph lock. The apply assigns them.
    if (graph_storage_adapter.threadHoldsAnyGraphOrStoreLock()) return;
    const adapter = graph_store_mod.getGlobalAdapter() orelse return;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const effect = cluster_replication.effectOf(a, payload) catch return;
    var names: std.ArrayList([]const u8) = .empty;
    for (effect.created) |c| names.appendSlice(a, c.labels) catch return;
    names.appendSlice(a, effect.written_labels) catch return;
    names.appendSlice(a, effect.edge_types) catch return;
    adapter.internNamesForReplicatedApply(if (effect.graph.len > 0) effect.graph else entry_graph, names.items);
}

// CANARY: REQ=REQ-SONNY-6622-RAFT-SNAPSHOT-RESTORE; FEATURE="Raft Snapshot Persistence"; ASPECT=RestoreIntoStore; STATUS=TESTED; TEST=tests/test_sonny6622_raft_v022_adapt.zig; OWNER=distributed; UPDATED=2026-11-15
/// SONNY-6622: `RaftNode.snapshot_restore_callback`: replace the registered
/// store's contents with the snapshot `data` the leader passed to
/// `reportSnapshot`. The Raft node runs it on its restore thread, without
/// `inner_mutex`, while it stays paused (SONNY-6636).
///
/// SONNY-6636: the durable store takes a durable snapshot (GRS3,
/// `raft_snapshot_manager.restoreDurableSnapshot`: the leader's engine
/// files, swapped in crash-safely; the store then reflects Raft `index`).
/// It refuses a JSON-lines snapshot (GRS2; `RaftSnapshotRestoreNotDurable`):
/// that one is lossy and rebuilds memory only. An in-memory store (tests)
/// takes GRS2 under the store's write lock and refuses GRS3
/// (`RaftSnapshotNeedsDurableStore`). A refusal stops the node instead of
/// applying past the snapshot.
pub fn restoreSnapshotCallbackFn(allocator: Allocator, data: []const u8, index: u64, term: u64) anyerror!void {
    const store = g_store orelse return error.StoreNotAvailable;
    const durable_adapter: ?*graph_storage_adapter.StorageAdapter = if (graph_store_mod.getCurrentGlobalStore() == store) graph_store_mod.getGlobalAdapter() else null;
    // SONNY-6636: a durable store's snapshot (the engine's files).
    if (raft_snapshot_manager.isDurableSnapshot(data)) {
        const adapter = durable_adapter orelse return error.RaftSnapshotNeedsDurableStore;
        try raft_snapshot_manager.restoreDurableSnapshot(allocator, store, adapter, data, .{ .index = index, .term = term }, g_idempotency_dedup);
        g_store_raft_index.store(index, .release);
        log.info("raft apply: durable store restored from the leader's snapshot", &.{
            Attr.uint("snapshot_index", index),
            Attr.uint("snapshot_term", term),
        });
        return;
    }
    if (durable_adapter != null) {
        log.err("raft apply: a JSON-lines snapshot cannot be restored into the durable store (it is lossy); the node stops", &.{
            Attr.uint("snapshot_index", index),
            Attr.uint("snapshot_term", term),
        });
        return error.RaftSnapshotRestoreNotDurable;
    }
    graph_storage_adapter.beginReplicatedRestore();
    defer graph_storage_adapter.endReplicatedRestore();
    // SONNY-6633 (6): the idempotency table too (it would otherwise lose
    // every key of the entries the snapshot covers).
    try raft_snapshot_manager.installRaftSnapshot(allocator, store, data, g_idempotency_dedup);
}

// ---------------------------------------------------------------------------
// Core routing logic
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GQL-RAFT-APPLY; FEATURE="Raft Apply Callback"; ASPECT=CommandRouting; STATUS=TESTED; TEST="applyCommand: noop returns empty slice"; OWNER=distributed; UPDATED=2026-04-10

/// Route a committed Raft `Command` to the appropriate graph-store mutation.
/// `raft_index` is the committed entry's log index — used to derive a
/// deterministic, restart-idempotent node id for replicated creates.
///
/// Returns a result payload (caller-owned).  For most MVP paths this is an
/// empty slice allocated from `allocator`; the caller must free it.
pub fn applyCommand(allocator: Allocator, store: ?*GraphStore, command: Command, raft_index: u64) ![]u8 {
    // SONNY-6567 (6a): a node that could not apply a committed entry stops
    // applying (see `haltApply`).
    if (g_apply_halted.load(.acquire)) {
        log.err("raft apply: HALTED; this node does not apply committed entries until it is restarted", &.{
            Attr.uint("raft_index", raft_index),
        });
        return error.ReplicatedApplyHalted;
    }
    // SONNY-6636 (3): an entry a restored snapshot covered is in the store.
    if (raft_index != 0 and store != null and store == g_store and raft_index <= g_store_raft_index.load(.acquire)) {
        log.debug("raft apply: entry covered by the restored snapshot; skipped", &.{Attr.uint("raft_index", raft_index)});
        return allocator.alloc(u8, 0);
    }
    // SONNY-6567 (6c): no hydration this apply triggers persists (waits for
    // a graph lock) under the Raft node's `inner_mutex`.
    GraphStore.enterReplicatedApply();
    defer GraphStore.leaveReplicatedApply();
    switch (command) {
        // ---- no-op: nothing to apply ----
        .noop => {
            return allocator.alloc(u8, 0);
        },

        // ---- key-value write (MVP: log and return empty) ----
        .write => |data| {
            log.info("raft apply: write command received", &.{
                Attr.uint("data_len", data.len),
            });
            // MVP: we do not persist generic key-value writes yet.
            // Future: store as metadata node or in a sidecar KV map.
            return allocator.alloc(u8, 0);
        },

        // ---- graph mutation: dispatch to store ----
        .graph_mutation => |gm| {
            return applyGraphMutation(allocator, store, gm, raft_index);
        },

        // ---- schema change: dispatch to store ----
        .schema_change => |sc| {
            return applySchemaChange(allocator, store, sc);
        },

        // ---- cluster membership change (GAP-0870) ----
        .config_change => |cc| {
            return applyConfigChange(allocator, cc);
        },

        // ---- snapshot pointer: record metadata for log truncation (GAP-0870) ----
        .snapshot_pointer => |sp| {
            return applySnapshotPointer(allocator, sp);
        },

        // ---- 2PC prepare/decide: route into TxnCoordinator (GAP-0870) ----
        .txn_prepare => |tp| {
            return applyTxnPrepare(allocator, tp);
        },
        .txn_decide => |td| {
            return applyTxnDecide(allocator, td);
        },
    }
}

// ---------------------------------------------------------------------------
// Config change handler (GAP-0870)
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-DIST-RAFT-CMD-VARIANTS; FEATURE="Raft Command Variants"; ASPECT=ApplyConfigChange; STATUS=TESTED; TEST=tests/test_gap0870_raft_command_variants.zig; OWNER=distributed; UPDATED=2026-06-11
fn applyConfigChange(allocator: Allocator, cc: ConfigChange) ![]u8 {
    const cfg = g_cluster_config orelse {
        log.err("raft apply: config_change received but no cluster config registered", &.{});
        return error.ClusterConfigNotAvailable;
    };

    switch (cc.change_type) {
        .add_server, .update_server => {
            // validateCommand rejects an empty endpoint at proposal time;
            // an entry from an older log without one is invalid — fail loud.
            const ep = cc.server_endpoint orelse return error.InvalidConfigChange;
            if (ep.len == 0) return error.InvalidConfigChange;
            try cfg.upsertMember(cc.server_id, ep, cc.server_port);
            log.info("raft apply: cluster member upserted", &.{
                Attr.uint("server_id", cc.server_id),
                Attr.string("endpoint", ep),
            });
        },
        .remove_server => {
            cfg.removeMember(cc.server_id);
            log.info("raft apply: cluster member removed", &.{
                Attr.uint("server_id", cc.server_id),
            });
        },
    }
    return allocator.alloc(u8, 0);
}

// ---------------------------------------------------------------------------
// Snapshot pointer handler (GAP-0870)
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-DIST-RAFT-CMD-VARIANTS; FEATURE="Raft Command Variants"; ASPECT=ApplySnapshotPointer; STATUS=TESTED; TEST=tests/test_gap0870_raft_command_variants.zig; OWNER=distributed; UPDATED=2026-06-11
fn applySnapshotPointer(allocator: Allocator, sp: SnapshotPointer) ![]u8 {
    // Monotonic: never regress the truncation watermark (an older pointer
    // can re-arrive during restart log replay).
    if (g_snapshot_pointer) |cur| {
        if (sp.last_included_index <= cur.last_included_index) {
            log.debug("raft apply: stale snapshot_pointer ignored (monotonic watermark)", &.{
                Attr.uint("incoming_index", sp.last_included_index),
                Attr.uint("current_index", cur.last_included_index),
            });
            return allocator.alloc(u8, 0);
        }
    }
    g_snapshot_pointer = sp;
    log.info("raft apply: snapshot pointer recorded", &.{
        Attr.uint("last_included_index", sp.last_included_index),
        Attr.uint("last_included_term", sp.last_included_term),
        Attr.uint("size_bytes", sp.size_bytes),
    });
    return allocator.alloc(u8, 0);
}

// ---------------------------------------------------------------------------
// 2PC prepare / decide handlers (GAP-0870)
//
// KNOWN BLOCKER (documented, unchanged): the pinned protobuf 0.1.3 cannot
// encode OR decode a TwoPhaseMessage (union-as-submessage @compileError), so
// the protobuf WIRE format stays gated behind
// `protobuf_union_submessage_supported` in tests/test_txn_coordinator_2pc.zig.
// The APPLY path below does not depend on it: write sets use the native G2PC
// codec (txn_coordinator.serializeWriteSet / deserializeWriteSet), so the
// full prepare → decide → store-mutation path is real and exercised by
// in-process tests constructing commands directly (test-gap0870). It is
// reached only that way: nothing in the server proposes these entries
// (SONNY-6547 (6)).
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-DIST-RAFT-CMD-VARIANTS; FEATURE="Raft Command Variants"; ASPECT=ApplyTxnPrepare; STATUS=TESTED; TEST=tests/test_gap0870_raft_command_variants.zig; OWNER=distributed; UPDATED=2026-06-11
fn applyTxnPrepare(allocator: Allocator, tp: TxnPrepare) ![]u8 {
    const coord = g_txn_coordinator orelse {
        log.err("raft apply: txn_prepare received but no 2PC coordinator registered", &.{});
        return error.TxnCoordinatorNotAvailable;
    };

    const vote_commit = try coord.handlePrepare(tp);
    log.info("raft apply: txn_prepare applied", &.{
        Attr.uint("xid", tp.xid),
        Attr.string("vote", if (vote_commit) "commit" else "abort"),
    });
    // Result payload: 1 byte vote (1 = VOTE_COMMIT, 0 = VOTE_ABORT).
    const result = try allocator.alloc(u8, 1);
    result[0] = if (vote_commit) 1 else 0;
    return result;
}

// CANARY: REQ=REQ-DIST-RAFT-CMD-VARIANTS; FEATURE="Raft Command Variants"; ASPECT=ApplyTxnDecide; STATUS=TESTED; TEST=tests/test_gap0870_raft_command_variants.zig; OWNER=distributed; UPDATED=2026-06-11
fn applyTxnDecide(allocator: Allocator, td: TxnDecide) ![]u8 {
    const coord = g_txn_coordinator orelse {
        log.err("raft apply: txn_decide received but no 2PC coordinator registered", &.{});
        return error.TxnCoordinatorNotAvailable;
    };

    // handleDecide commits (applies the buffered write set to the store) or
    // aborts (releases locks without applying).  An unknown xid is tolerated
    // inside handleDecide — a decide(abort) legitimately follows a prepare
    // that voted abort and never registered.
    try coord.handleDecide(td);
    log.info("raft apply: txn_decide applied", &.{
        Attr.uint("xid", td.xid),
        Attr.string("decision", if (td.commit) "commit" else "abort"),
    });
    return allocator.alloc(u8, 0);
}

// ---------------------------------------------------------------------------
// Graph mutation handler
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-SONNY-2726-REPLICATED-TENANT; FEATURE="DistributedCluster"; ASPECT=ApplyUnderTenant; STATUS=TESTED; TEST=tests/test_sonny2726_replicated_tenant.zig; OWNER=distributed; UPDATED=2026-11-12
/// SONNY-2726: an entry in a GTN1 tenant envelope is applied as that tenant:
/// the apply thread has no request context, so the creates take the tenant
/// from the thread's FLE tenant (`fle_integration.tenantPreferringActiveContext`),
/// set here for the entry and restored after it. An entry without the
/// envelope applies as before (the default tenant).
fn applyGraphMutation(allocator: Allocator, store_opt: ?*GraphStore, gm: GraphMutation, raft_index: u64) ![]u8 {
    if (!cluster_replication.isTenantPayload(gm.data)) return applyGraphMutationInner(allocator, store_opt, gm, raft_index);
    const split = try cluster_replication.splitTenant(gm.data);
    const prev = fle_integration.getCurrentTenantId();
    fle_integration.setCurrentTenantId(split.tenant);
    defer fle_integration.setCurrentTenantId(if (std.mem.eql(u8, prev, "default")) null else prev);
    var inner = gm;
    inner.data = split.inner;
    return applyGraphMutationInner(allocator, store_opt, inner, raft_index);
}

fn applyGraphMutationInner(allocator: Allocator, store_opt: ?*GraphStore, gm: GraphMutation, raft_index: u64) ![]u8 {
    const store = store_opt orelse {
        log.err("raft apply: graph_mutation received but no store registered", &.{});
        return error.StoreNotAvailable;
    };

    const graph_name: []const u8 = if (gm.graph.len > 0) gm.graph else "default";

    // Ensure the target graph exists (idempotent). SONNY-6492 (3): never
    // creates a graph dropped since the store opened (a replicated DROP
    // GRAPH earlier in the log, or a local drop): GraphNotFound, on every
    // replica alike. Only a replicated CREATE GRAPH (schema_change) does.
    store.ensureGraphForReplicatedWrite(graph_name) catch |err| switch (err) {
        error.GraphAlreadyExists => {}, // fine — idempotent
        else => return err,
    };

    // CANARY: REQ=REQ-SONNY-6528-APPLY-CHECKPOINT-EXCLUSION; FEATURE="DistributedCluster"; ASPECT=ApplyHoldsReplicatedApplyMutex; STATUS=TESTED; TEST=tests/test_sonny6528_apply_checkpoint_exclusion.zig; OWNER=storage; UPDATED=2026-11-14
    // SONNY-6528 (1): the write holds the graph's `replicated_apply_mutex`,
    // so a checkpoint of the graph waits for it (every local writer holds
    // the graph's rwlock, which this thread must not take: see
    // `ManagedGraph.replicated_apply_mutex`). The graph is hydrated first,
    // outside it.
    // CANARY: REQ=REQ-SONNY-6547-APPLY-HYDRATION-OFF-RAFT-MUTEX; FEATURE="DistributedCluster"; ASPECT=ApplyHydratesWithoutPersist; STATUS=TESTED; TEST=tests/test_sonny6547_apply_hydration_stall.zig; OWNER=distributed; UPDATED=2026-11-14
    // SONNY-6547 (4): this runs under the Raft node's `inner_mutex`, so a
    // first hydration here does not persist its products: that persist is a
    // checkpoint of the graph, which waits up to 5 s for the graph's lock
    // (held by any local request on the graph), and the whole Raft node
    // waited with it (no tick, no heartbeat, no inbound message; 6.3 s
    // measured). The leader hydrates an entry's graph before it proposes
    // it, without `inner_mutex` (`prehydrateForApply`); a graph hydrated
    // here is persisted by the next full checkpoint.
    // SONNY-6605: a build that failed transiently left the graph's products
    // partial: the apply fails rather than write on them.
    try store.ensureGraphHydratedForReplicatedApply(graph_name);
    const apply_adapter = graph_store_mod.getGlobalAdapter();
    const apply_mg = if (apply_adapter) |a| try a.beginReplicatedApply(graph_name) else null;
    defer if (apply_mg) |mg| apply_adapter.?.endReplicatedApply(mg);

    // CANARY: REQ=REQ-SONNY-3348-CLUSTER-BATCH; FEATURE="DistributedCluster"; ASPECT=ApplyStatementBatch; STATUS=TESTED; TEST=tests/test_sonny3348_cluster_batch.zig; OWNER=distributed; UPDATED=2026-09-29
    // SONNY-3348 (round 19): one statement's writes, as one entry (GBAT,
    // proposed as a `.create`). Every entry of the batch is checked before
    // any is applied. A version this build does not know is logged and
    // skipped, as a build before round 19 skips the whole batch (its create
    // arm's unknown-magic branch below).
    if (cluster_replication.isBatchPayload(gm.data)) {
        const applied = cluster_replication.applyBatchPayload(allocator, store, gm.data, raft_index, g_idempotency_dedup) catch |err| switch (err) {
            error.UnsupportedBatchVersion => {
                log.err("raft apply: statement batch of an unknown version — skipping (nothing applied)", &.{
                    Attr.string("graph", graph_name),
                    Attr.uint("raft_index", raft_index),
                });
                return allocator.alloc(u8, 0);
            },
            else => return err,
        };
        log.info("raft apply: replicated statement batch", &.{
            Attr.uint("entries", applied),
            Attr.string("graph", graph_name),
        });
        return allocator.alloc(u8, 0);
    }

    switch (gm.mutation_type) {
        .create => {
            // RC-3 (2026-06-12): a keyed create wrapper (GN1K / GN2K) carries an
            // optional client idempotency key. Route it through the key-aware apply
            // so a same-key-DIFFERENT-index retry is a NO-OP (the duplicate-row
            // fix), consulting the process-wide dedup table. When no dedup table is
            // registered (single-node / non-cluster tests), we still strip the
            // wrapper and apply the inner body index-idempotently via a transient
            // per-apply table — correct for THIS entry, and cross-entry retry
            // detection only matters in a live cluster where the table is wired.
            // CANARY: REQ=REQ-DIST-CLUSTER-IDEMPOTENT-RETRY; FEATURE="DistributedCluster"; ASPECT=ApplyKeyedCreate; STATUS=TESTED; TEST=tests/test_cluster_write_idempotency.zig; OWNER=distributed; UPDATED=2026-06-12
            if (cluster_replication.isKeyedPayload(gm.data)) {
                var transient: ?cluster_replication.IdempotencyDedup = null;
                defer if (transient) |*t| t.deinit();
                const dedup = g_idempotency_dedup orelse blk: {
                    transient = cluster_replication.IdempotencyDedup.init(allocator);
                    break :blk &transient.?;
                };
                const is_multi = gm.data.len >= 4 and
                    std.mem.eql(u8, gm.data[0..4], &cluster_replication.MAGIC_KEYED2);
                if (is_multi) {
                    const touched = try cluster_replication.applyMultiCreatePayloadKeyed(allocator, store, gm.data, raft_index, dedup);
                    log.info("raft apply: replicated keyed multi create", &.{
                        Attr.uint("entities", touched),
                        Attr.string("graph", graph_name),
                    });
                    const result = try allocator.alloc(u8, 8);
                    std.mem.writeInt(u64, result[0..8], cluster_replication.deriveMultiNodeId(raft_index, 0), .little);
                    return result;
                }
                const node_id = try cluster_replication.applyNodeCreatePayloadKeyed(allocator, store, gm.data, raft_index, dedup);
                log.info("raft apply: replicated keyed node create", &.{
                    Attr.uint("node_id", node_id),
                    Attr.string("graph", graph_name),
                });
                const result = try allocator.alloc(u8, 8);
                std.mem.writeInt(u64, result[0..8], node_id, .little);
                return result;
            }

            // Cluster write replication (GNC1 payload): decode the serialized
            // single-node create and replay it deterministically. The node id is
            // the committed entry's Raft log index, which is globally unique and
            // identical on every node — so apply is cross-node deterministic AND
            // restart-idempotent (re-applying a committed entry hits an id that
            // already exists in the persisted store and is skipped). See
            // cluster_replication.zig.
            // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-CREATE; FEATURE="DistributedCluster"; ASPECT=ApplyNodeCreate; STATUS=TESTED; TEST=tests/test_cluster_3node_steady_state.zig; OWNER=distributed; UPDATED=2026-06-09
            if (cluster_replication.isNodeCreatePayload(gm.data)) {
                const node_id = try cluster_replication.applyNodeCreatePayload(allocator, store, gm.data, raft_index);
                log.info("raft apply: replicated node create", &.{
                    Attr.uint("node_id", node_id),
                    Attr.string("graph", graph_name),
                });
                const result = try allocator.alloc(u8, 8);
                std.mem.writeInt(u64, result[0..8], node_id, .little);
                return result;
            }

            // GNC2 multi-create (slice A): up to N nodes + M edges from one
            // committed entry, ids derived positionally from the raft log index
            // (cross-node identical, restart-idempotent — see cluster_replication).
            // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-EDGE-CREATE; FEATURE="DistributedCluster"; ASPECT=ApplyEdgeCreate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
            if (cluster_replication.isMultiCreatePayload(gm.data)) {
                const touched = try cluster_replication.applyMultiCreatePayload(allocator, store, gm.data, raft_index);
                log.info("raft apply: replicated multi create (edge create)", &.{
                    Attr.uint("entities", touched),
                    Attr.string("graph", graph_name),
                });
                // Return the first derived node id (mirrors the GNC1 contract) so
                // a caller that re-reads after apply has a stable handle.
                const result = try allocator.alloc(u8, 8);
                std.mem.writeInt(u64, result[0..8], cluster_replication.deriveMultiNodeId(raft_index, 0), .little);
                return result;
            }

            // Unknown create payload version: FAIL-LOUD, never create junk data.
            // The pre-slice-A code created a bogus unlabelled `_raft_data` node
            // here, which diverged real graph state on a mixed-version cluster.
            // We log-and-skip with a counter instead (returning an error would
            // only spam apply_errors — an unknown magic is not transient).
            // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-EDGE-CREATE; FEATURE="DistributedCluster"; ASPECT=MixedVersionFailLoud; STATUS=TESTED; TEST=tests/test_raft_apply.zig; OWNER=distributed; UPDATED=2026-06-09
            log.err("raft apply: unknown create payload version — skipping (no junk data)", &.{
                Attr.string("graph", graph_name),
                Attr.uint("data_len", gm.data.len),
                Attr.uint("raft_index", raft_index),
            });
            return allocator.alloc(u8, 0);
        },

        .delete => {
            // Slice B: DELETE / DETACH DELETE replication. The leader resolves the
            // MATCH set to explicit STABLE node/edge ids and proposes a GDEL
            // payload; every node (leader + followers) replays it here, deleting
            // edges first then nodes. Apply is idempotent — a missing id is a clean
            // no-op, so re-applying a committed entry after restart is safe.
            // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-DELETE; FEATURE="DistributedCluster"; ASPECT=ApplyDelete; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
            if (cluster_replication.isDeletePayload(gm.data)) {
                const removed = try cluster_replication.applyDeletePayload(allocator, store, gm.data);
                log.info("raft apply: replicated delete", &.{
                    Attr.uint("removed", removed),
                    Attr.string("graph", graph_name),
                });
                return allocator.alloc(u8, 0);
            }

            // Unknown delete payload version: log-and-skip (mixed-version posture,
            // consistent with the create branch — an unknown magic is not transient).
            log.warn("raft apply: unknown delete payload version — skipping", &.{
                Attr.string("graph", graph_name),
                Attr.uint("data_len", gm.data.len),
            });
            return allocator.alloc(u8, 0);
        },

        .merge => {
            // Slice C: MERGE replication. The leader decides match-or-create ONCE
            // and ships a concrete outcome — followers NEVER re-evaluate the match.
            //   * NOT MATCHED → leader proposes a .create (GNC1) command, applied
            //     by the .create branch above; the .merge branch never sees it.
            //   * MATCHED + ON MATCH SET → a GMRG payload, decoded here and applied
            //     idempotently by stable node id (set-by-id overwrite). The matched
            //     id is stable, so re-apply after restart is a clean no-op overwrite.
            //   * MATCHED, no ON MATCH SET → the leader short-circuits (no propose),
            //     so this branch never fires for that case either.
            // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MERGE; FEATURE="DistributedCluster"; ASPECT=ApplyMerge; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
            if (cluster_replication.isMergePayload(gm.data)) {
                const node_id = try cluster_replication.applyMergePayload(allocator, store, gm.data);
                log.info("raft apply: replicated merge (matched + ON MATCH SET)", &.{
                    Attr.uint("node_id", node_id),
                    Attr.string("graph", graph_name),
                });
                return allocator.alloc(u8, 0);
            }

            // Unknown merge payload version: log-and-skip (mixed-version posture,
            // consistent with the create/delete branches — an unknown magic is not
            // transient).
            log.warn("raft apply: unknown merge payload version — skipping", &.{
                Attr.string("graph", graph_name),
                Attr.uint("data_len", gm.data.len),
            });
            return allocator.alloc(u8, 0);
        },

        .update => {
            // Slice D: MATCH…SET / MATCH…REMOVE replication — closes the
            // silent-divergence gap. The leader resolves the MATCH set to explicit
            // STABLE node ids AND evaluates the SET expressions to concrete scalars,
            // then ships a GUPD payload; every node (leader + followers) replays it
            // here, applying set/remove props + label add/remove by stable id.
            // Apply is idempotent — a set overwrites, a remove of an absent key /
            // an add of an existing label / a remove of an absent label all no-op —
            // so re-applying a committed entry after restart is safe.
            // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-SET; FEATURE="DistributedCluster"; ASPECT=ApplyUpdate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
            if (cluster_replication.isUpdatePayload(gm.data)) {
                const applied = try cluster_replication.applyUpdatePayload(allocator, store, gm.data);
                log.info("raft apply: replicated match-set/remove update", &.{
                    Attr.uint("nodes", applied),
                    Attr.string("graph", graph_name),
                });
                return allocator.alloc(u8, 0);
            }

            // Unknown update payload version: log-and-skip (mixed-version posture,
            // consistent with the create/delete/merge branches — an unknown magic
            // is not transient).
            log.warn("raft apply: unknown update payload version — skipping", &.{
                Attr.string("graph", graph_name),
                Attr.uint("data_len", gm.data.len),
            });
            return allocator.alloc(u8, 0);
        },
    }
}

// ---------------------------------------------------------------------------
// Schema change handler
// ---------------------------------------------------------------------------

/// SONNY-6547 (6): nothing in the server proposes a `schema_change`; CREATE
/// and DROP GRAPH are refused in cluster mode (`gateUnreplicatedWrite`).
/// This is the receiving side of a future replicated DDL, reached by tests.
fn applySchemaChange(allocator: Allocator, store_opt: ?*GraphStore, sc: SchemaChange) ![]u8 {
    const store = store_opt orelse {
        log.err("raft apply: schema_change received but no store registered", &.{});
        return error.StoreNotAvailable;
    };

    switch (sc.operation) {
        .create_graph => {
            store.createGraph(sc.graph) catch |err| switch (err) {
                error.GraphAlreadyExists => {}, // idempotent
                else => return err,
            };
            log.info("raft apply: created graph via schema_change", &.{
                Attr.string("graph", sc.graph),
            });
        },

        .drop_graph => {
            // CANARY: REQ=REQ-SONNY-3350-ROUND16-MINORS; FEATURE="DistributedCluster"; ASPECT=RaftDropGraphLock; STATUS=TESTED; TEST=tests/test_sonny3350_round16_minors.zig; OWNER=distributed; UPDATED=2026-09-28
            // SONNY-3350 (round 17): under the graph's write lock, as DROP
            // GRAPH's handlers run it (SONNY-3028): the drop waits for the
            // graph's readers and writers, and none starts during it. The
            // apply thread dropped it with no lock, and freed the graph under
            // requests holding it. A graph that is not there is not locked
            // (the lock would create it); the drop is idempotent.
            // SONNY-6384 (item 4): `GraphStore.dropGraph` takes the graph's
            // write lock itself (SONNY-3135) and reports a graph that is not
            // there as GraphNotFound without locking it. The apply checked
            // `graphExists` first and then took `acquireGraphWriteLock`; a
            // drop in between sent that lock to its global-exclusive
            // fallback for a graph that no longer existed.
            // CANARY: REQ=REQ-SONNY-6541-DROP-APPLY-NO-DEADLOCK; FEATURE="DistributedCluster"; ASPECT=DropApplyAnnouncesWait; STATUS=TESTED; TEST=tests/test_sonny6541_drop_apply_deadlock.zig; OWNER=distributed; UPDATED=2026-11-14
            // SONNY-6541 (1): that wait runs under the Raft node's
            // `inner_mutex`, and a request on the leader holds its graph's
            // lock while it proposes (taking `inner_mutex`) and waits for the
            // commit. The wait is announced on the graph first: a holder of
            // its lock that would wait for Raft gives up instead
            // (`threadHoldsGraphAwaitedByReplicatedDrop`), lets go of the
            // lock, and the drop goes on.
            const drop_adapter = graph_store_mod.getGlobalAdapter();
            const drop_mg = if (drop_adapter) |a| a.beginReplicatedDrop(sc.graph) else null;
            defer if (drop_mg) |mg| drop_adapter.?.endReplicatedDrop(mg);
            store.dropGraph(sc.graph) catch |err| switch (err) {
                error.GraphNotFound => {
                    log.info("raft apply: drop_graph of a graph that is not there (idempotent)", &.{
                        Attr.string("graph", sc.graph),
                    });
                    return allocator.alloc(u8, 0);
                },
                error.CannotDropDefaultGraph => {
                    log.warn("raft apply: attempted to drop default graph, ignoring", &.{});
                },
                // CANARY: REQ=REQ-SONNY-6547-REPLICATED-DROP-IN-USE; FEATURE="DistributedCluster"; ASPECT=RefusedDropFailsApply; STATUS=TESTED; TEST=tests/test_sonny6547_single_voter_drop.zig; OWNER=distributed; UPDATED=2026-11-14
                // SONNY-6547 (3): the graph is in use on this node (the
                // applying thread holds its read lock, or a session
                // transaction changed it, SONNY-3134): nothing was dropped,
                // and the apply fails, so the Raft node counts and logs a
                // committed entry not applied. It logged the refusal, then
                // the graph as dropped, and reported the entry applied while
                // the node kept the graph. An apply runs on the thread that
                // ticks or steps the node (the raft library commits on a
                // tick or a step, never in a propose), which holds no graph
                // lock. What a replicated drop does to an open transaction is
                // for the replicated DDL feature to decide: nothing proposes
                // a `schema_change` today (SONNY-6547 (6)).
                // SONNY-6567 (6a): and the node then stops applying
                // (`haltApply`) rather than go on without the drop.
                error.ObjectInUse => {
                    log.err("raft apply: drop_graph refused, the graph is in use on this node; the entry is not applied here", &.{
                        Attr.string("graph", sc.graph),
                    });
                    haltApply("replicated drop_graph refused: the graph is in use on this node", sc.graph);
                    return err;
                },
                // SONNY-6433: no room to record the graph lock; nothing was
                // dropped, and the apply fails.
                // SONNY-6523 (5): or the drop could not be recorded on disk;
                // nothing was dropped either.
                error.OutOfMemory, error.DroppedGraphNamesNotSaved => return err,
            };
            log.info("raft apply: dropped graph via schema_change", &.{
                Attr.string("graph", sc.graph),
            });
        },

        .alter_graph => {
            // GAP-0870: geode has no ALTER GRAPH semantics (no GQL surface,
            // no GraphStore handler).  `validateCommand` rejects this variant
            // at proposal time; an entry that nevertheless reaches apply
            // (older log / mixed version) fails LOUD instead of silently
            // skipping.  When ALTER GRAPH lands, route it through the same
            // store handler family create_graph/drop_graph use above.
            log.err("raft apply: alter_graph has no implementation — rejecting (proposal-time validation should have refused this)", &.{
                Attr.string("graph", sc.graph),
            });
            return error.UnsupportedSchemaOperation;
        },
    }

    return allocator.alloc(u8, 0);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "applyCommand: noop returns empty slice" {
    const allocator = std.testing.allocator;
    const result = try applyCommand(allocator, null, .noop, 1);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "applyCommand: write returns empty slice (MVP)" {
    const allocator = std.testing.allocator;
    const result = try applyCommand(allocator, null, .{ .write = "key=value" }, 1);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "applyCommand: config_change without registered cluster config fails loud" {
    const allocator = std.testing.allocator;
    resetGlobalClusterConfig();
    const result = applyCommand(allocator, null, .{ .config_change = .{
        .change_type = .add_server,
        .server_id = 42,
        .server_endpoint = "10.0.0.1",
    } }, 1);
    try std.testing.expectError(error.ClusterConfigNotAvailable, result);
}

test "applyCommand: config_change add/remove mutates registered cluster config" {
    const allocator = std.testing.allocator;
    var cfg = AppliedClusterConfig.init(allocator);
    defer cfg.deinit();
    setGlobalClusterConfig(&cfg);
    defer resetGlobalClusterConfig();

    const r1 = try applyCommand(allocator, null, .{ .config_change = .{
        .change_type = .add_server,
        .server_id = 42,
        .server_endpoint = "10.0.0.1",
        .server_port = 4242,
    } }, 1);
    defer allocator.free(r1);

    try std.testing.expectEqual(@as(usize, 1), cfg.memberCount());
    const m = cfg.getMember(42).?;
    try std.testing.expectEqualStrings("10.0.0.1", m.endpoint);
    try std.testing.expectEqual(@as(?u16, 4242), m.port);

    const r2 = try applyCommand(allocator, null, .{ .config_change = .{
        .change_type = .remove_server,
        .server_id = 42,
        .server_endpoint = null,
    } }, 2);
    defer allocator.free(r2);
    try std.testing.expectEqual(@as(usize, 0), cfg.memberCount());
}

test "applyCommand: snapshot_pointer records metadata, watermark is monotonic" {
    const allocator = std.testing.allocator;
    resetSnapshotPointer();
    defer resetSnapshotPointer();

    const r1 = try applyCommand(allocator, null, .{ .snapshot_pointer = .{
        .last_included_index = 50,
        .last_included_term = 2,
        .size_bytes = 1024,
        .checksum = 7,
    } }, 1);
    defer allocator.free(r1);
    try std.testing.expectEqual(@as(u64, 50), lastSnapshotPointer().?.last_included_index);

    // An older pointer (restart replay) never regresses the watermark.
    const r2 = try applyCommand(allocator, null, .{ .snapshot_pointer = .{
        .last_included_index = 10,
        .last_included_term = 1,
        .size_bytes = 64,
        .checksum = 3,
    } }, 2);
    defer allocator.free(r2);
    try std.testing.expectEqual(@as(u64, 50), lastSnapshotPointer().?.last_included_index);
}

test "applyCommand: txn_prepare without registered coordinator fails loud" {
    const allocator = std.testing.allocator;
    resetGlobalTxnCoordinator();
    const result = applyCommand(allocator, null, .{ .txn_prepare = .{
        .xid = 1,
        .shard_id = 0,
        .write_set = "",
        .metadata = "",
    } }, 1);
    try std.testing.expectError(error.TxnCoordinatorNotAvailable, result);
}

test "applyCommand: txn_decide without registered coordinator fails loud" {
    const allocator = std.testing.allocator;
    resetGlobalTxnCoordinator();
    const result = applyCommand(allocator, null, .{ .txn_decide = .{
        .xid = 1,
        .commit = true,
    } }, 1);
    try std.testing.expectError(error.TxnCoordinatorNotAvailable, result);
}

test "applyCommand: graph_mutation without store returns StoreNotAvailable" {
    const allocator = std.testing.allocator;
    const result = applyCommand(allocator, null, .{ .graph_mutation = .{
        .graph = "test_graph",
        .mutation_type = .create,
        .data = "test",
        .txn_id = null,
    } }, 1);
    try std.testing.expectError(error.StoreNotAvailable, result);
}

test "applyCommand: schema_change without store returns StoreNotAvailable" {
    const allocator = std.testing.allocator;
    const result = applyCommand(allocator, null, .{ .schema_change = .{
        .operation = .create_graph,
        .graph = "new_graph",
        .schema = "",
    } }, 1);
    try std.testing.expectError(error.StoreNotAvailable, result);
}

test "applyCommand: unknown create payload version is skipped (no junk node)" {
    // Slice A mixed-version safety: a create command whose data carries NO known
    // magic (GNC1/GNC2) must be skipped fail-loud — it must NOT mint a bogus
    // `_raft_data` node (the pre-slice-A divergence hazard). The graph is still
    // ensured (idempotent), but no node is created.
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const result = try applyCommand(allocator, &store, .{
        .graph_mutation = .{
            .graph = "test_graph",
            .mutation_type = .create,
            .data = "hello", // no GNC1/GNC2 magic
            .txn_id = null,
        },
    }, 42);
    defer allocator.free(result);

    // Skipped: empty result, NO node created.
    try std.testing.expectEqual(@as(usize, 0), result.len);
    try std.testing.expectEqual(@as(usize, 0), store.nodes.count());

    // The target graph is still ensured (idempotent).
    try std.testing.expect(store.graphs.contains("test_graph"));
}

test "applyCommand: re-applying an unknown create payload stays a no-op (creates nothing)" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const cmd: Command = .{
        .graph_mutation = .{
            .graph = "test_graph",
            .mutation_type = .create,
            .data = "hello", // unknown payload version
            .txn_id = null,
        },
    };

    const r1 = try applyCommand(allocator, &store, cmd, 9);
    defer allocator.free(r1);
    const r2 = try applyCommand(allocator, &store, cmd, 9);
    defer allocator.free(r2);

    // Both applies skip the unknown payload; the store never gains a node.
    try std.testing.expectEqual(@as(usize, 0), r1.len);
    try std.testing.expectEqual(@as(usize, 0), r2.len);
    try std.testing.expectEqual(@as(usize, 0), store.nodes.count());
}

test "applyCommand: GNC2 edge-create command applies 2 nodes + 1 edge" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const cr = @import("cluster_replication.zig");
    const la = [_][]const u8{"E"};
    const nodes = [_]cr.NodeSpec{ .{ .labels = &la, .props = &.{} }, .{ .labels = &la, .props = &.{} } };
    const edges = [_]cr.EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "LINKS", .props = &.{} },
    };
    const payload = try cr.serializeMultiCreate(allocator, "test_graph", &nodes, &edges);
    defer allocator.free(payload);

    const result = try applyCommand(allocator, &store, .{ .graph_mutation = .{
        .graph = "test_graph",
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } }, 30);
    defer allocator.free(result);

    // Returns the first derived node id.
    try std.testing.expectEqual(@as(usize, 8), result.len);
    try std.testing.expectEqual(cr.deriveMultiNodeId(30, 0), std.mem.readInt(u64, result[0..8], .little));

    try std.testing.expectEqual(@as(usize, 2), store.nodes.count());
    try std.testing.expectEqual(@as(usize, 1), store.edges.count());
}

test "applyCommand: schema_change create_graph creates graph" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const result = try applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .create_graph,
        .graph = "my_graph",
        .schema = "",
    } }, 1);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);

    // Graph should exist
    try std.testing.expect(store.graphs.contains("my_graph"));
}

test "applyCommand: schema_change create_graph is idempotent" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // Create once
    const r1 = try applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .create_graph,
        .graph = "idem_graph",
        .schema = "",
    } }, 1);
    defer allocator.free(r1);

    // Create again — should not error
    const r2 = try applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .create_graph,
        .graph = "idem_graph",
        .schema = "",
    } }, 2);
    defer allocator.free(r2);
}

test "applyCommand: schema_change drop_graph drops graph" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("temp_graph");
    try std.testing.expect(store.graphs.contains("temp_graph"));

    const result = try applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .drop_graph,
        .graph = "temp_graph",
        .schema = "",
    } }, 1);
    defer allocator.free(result);

    try std.testing.expect(!store.graphs.contains("temp_graph"));
}

test "setGlobalStore and getGlobalStore round-trip" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(?*GraphStore, null), getGlobalStore());

    setGlobalStore(&store);
    try std.testing.expectEqual(@as(?*GraphStore, &store), getGlobalStore());

    resetGlobalStore();
    try std.testing.expectEqual(@as(?*GraphStore, null), getGlobalStore());
}

test "applyCallbackFn delegates to applyCommand via g_store" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    setGlobalStore(&store);
    defer resetGlobalStore();

    // Use the function-pointer-compatible callback
    const result = try applyCallbackFn(allocator, .noop, 1);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
