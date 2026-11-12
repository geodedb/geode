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

/// Register the graph store used by the apply callback.
/// Must be called before the Raft node begins processing committed entries.
pub fn setGlobalStore(store: *GraphStore) void {
    g_store = store;
}

/// Return the currently registered store (useful in tests / diagnostics).
pub fn getGlobalStore() ?*GraphStore {
    return g_store;
}

/// Reset the global store to null (for test isolation).
pub fn resetGlobalStore() void {
    g_store = null;
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
// decide(abort) releases without applying.
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
// in-process tests constructing commands directly (test-gap0870).
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

fn applyGraphMutation(allocator: Allocator, store_opt: ?*GraphStore, gm: GraphMutation, raft_index: u64) ![]u8 {
    const store = store_opt orelse {
        log.err("raft apply: graph_mutation received but no store registered", &.{});
        return error.StoreNotAvailable;
    };

    const graph_name: []const u8 = if (gm.graph.len > 0) gm.graph else "default";

    // Ensure the target graph exists (idempotent).
    store.createGraph(graph_name) catch |err| switch (err) {
        error.GraphAlreadyExists => {}, // fine — idempotent
        else => return err,
    };

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
                // SONNY-3028: the apply thread has no engine transaction open
                // on the graph; kept for the error set.
                error.ObjectInUse => {
                    log.warn("raft apply: graph in use by this thread's transaction, not dropped", &.{});
                },
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
