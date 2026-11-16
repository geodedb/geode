// RED reproduction tests — "committed write → client Timeout → retry double-insert"
// ROOT CAUSE 3 (RC-3): the replicated GraphMutation payload carries NO client
// idempotency key, and the raft apply path dedups ONLY by the committed raft log
// index (GNC1 node id = entry.index; GNC2 ids = MULTI_ID_BASE + raft_index*64 + lane).
//
// THE BUG (triage complete; file:line verified against HEAD 43031cb7):
//   * src/distributed/raft_consensus.zig:308-313 — `GraphMutation` (graph,
//     mutation_type, data, txn_id) has no client/idempotency key field.
//   * src/distributed/raft_apply.zig:383-510 — apply dispatch has no key dedup;
//     every committed entry is replayed purely by its raft index.
//   * src/distributed/cluster_replication.zig:234-251 — GNC1 mints node id ==
//     raft_index; :334-344 — GNC2 mints ids from raft_index. So the SAME logical
//     CREATE, retried by the client after a (committed-but-)Timeout, is proposed
//     AGAIN, lands at a NEW raft index, and mints NEW ids → DUPLICATE rows.
//   * The existing per-index idempotency proof (tests/test_raft_apply_restart_idempotent.zig)
//     covers ONLY same-index re-apply (restart replay). Same-KEY-different-INDEX
//     (the client retry) is UNCOVERED — these tests pin that gap.
//
// INTENDED FIX CONTRACT (what these tests pin; NOT the implementation):
//   An OPTIONAL idempotency key rides the replicated create payload. At apply
//   time a deterministic key→original-index dedup table (rebuilt naturally by
//   replay; bounded) makes a same-key-DIFFERENT-index apply a NO-OP (no new
//   rows). Same-key-SAME-index re-apply (restart replay) stays the normal
//   idempotent path. A key-LESS payload (old encoding) decodes and applies
//   EXACTLY as today (index-keyed only) — backward compatible.
//
//   Contract matrix:
//     | payload     | key      | index | expected                                |
//     |-------------|----------|-------|-----------------------------------------|
//     | keyed       | K, first | N     | normal apply + record (key K → index N) |
//     | keyed       | K, again | N     | NO-OP (restart replay; same index)      |
//     | keyed       | K, again | N+1   | NO-OP (CLIENT RETRY — the bug fix)      |
//     | keyed       | K2 ≠ K   | M     | normal apply (distinct logical write)   |
//     | keyless     | (none)   | any   | EXACTLY today's index-keyed behavior    |
//
// REQUIRED NEW SURFACE (the fixer implements these in
// src/distributed/cluster_replication.zig as top-level `pub` decls — EXACT
// names/shapes are the fixer's call so long as the CONTRACT holds; these tests
// probe for the most likely names and assert behavior. If the fixer chooses
// different names, update ONLY the `@hasDecl` probe strings — never loosen an
// assertion):
//
//   /// A bounded key→original-raft-index dedup table, rebuilt naturally by replay
//   /// (so it survives restart by re-applying the log). The fixer owns its exact
//   /// shape (init/deinit + the apply functions consult & populate it).
//   pub const IdempotencyDedup = struct { ... };
//
//   /// Serialize a single-node create carrying an OPTIONAL idempotency key.
//   /// Encodes a self-describing payload that the keyed apply path recognizes;
//   /// the LEGACY keyless `serializeNodeCreate` payload must still decode and
//   /// apply (backward-compatible codec).
//   pub fn serializeNodeCreateKeyed(
//       allocator, graph, labels, props, idempotency_key: ?[]const u8,
//   ) ![]u8 { ... }
//
//   /// Apply a (keyed OR keyless) single-node create with key-aware dedup. A
//   /// keyed payload whose key was already applied at ANY index is a NO-OP
//   /// (returns the ORIGINAL node id). A keyless payload behaves exactly like
//   /// applyNodeCreatePayload (index-keyed only). `dedup` persists across calls.
//   pub fn applyNodeCreatePayloadKeyed(
//       allocator, store, data, raft_index, dedup: *IdempotencyDedup,
//   ) !u64 { ... }
//
//   /// GNC2 multi-create analog (retried multi-create with same key → no dup
//   /// nodes/edges).
//   pub fn serializeMultiCreateKeyed(
//       allocator, graph, nodes, edges, idempotency_key: ?[]const u8,
//   ) ![]u8 { ... }
//   pub fn applyMultiCreatePayloadKeyed(
//       allocator, store, data, raft_index, dedup: *IdempotencyDedup,
//   ) !usize { ... }
//
// RED MECHANISM: the keyed tests are guarded by `comptime @hasDecl(...)`. Until
// the fixer adds the named symbols the guard's else-branch returns an error, so
// the test FAILS while the file still COMPILES (the missing-symbol then-branch is
// comptime-pruned). The keyless GUARD tests below need no symbol and run on
// current code — they must stay GREEN before AND after the fix (no regression /
// no over-dedup). Do not edit these tests to make them pass; implement the
// contract.
//
// CANARY: REQ=REQ-DIST-CLUSTER-IDEMPOTENT-RETRY; FEATURE="DistributedCluster"; ASPECT=IdempotencyKeyDedup; STATUS=TESTED; TEST=tests/test_cluster_write_idempotency.zig; OWNER=distributed; UPDATED=2026-06-12

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const cluster_replication = geode.distributed.cluster_replication;
const Prop = cluster_replication.Prop;
const NodeSpec = cluster_replication.NodeSpec;
const EdgeSpec = cluster_replication.EdgeSpec;

/// Count live nodes with the given label in the given graph (the same maintained
/// label-refcount oracle test_raft_apply_restart_idempotent.zig uses).
fn countLabel(store: *const GraphStore, graph: []const u8, label: []const u8) usize {
    return store.countNodesByLabel(graph, label, null);
}

// ===========================================================================
// RC-3 CORE (RED): client retry of a committed write must NOT duplicate rows.
// ===========================================================================

// ---------------------------------------------------------------------------
// (RC-3.1) THE BUG, distilled: the SAME logical CREATE carrying the SAME
// idempotency key, applied first at raft index N then RE-PROPOSED by a retrying
// client and applied at a DIFFERENT raft index N+1, must yield EXACTLY ONE node.
// On unfixed code each index mints a distinct id → TWO nodes (RED). After the
// key→index dedup fix the second apply is a NO-OP and count stays 1.
// ---------------------------------------------------------------------------
test "RC-3 retry: same idempotency key at different raft indices yields exactly one node" {
    if (comptime @hasDecl(cluster_replication, "serializeNodeCreateKeyed") and
        @hasDecl(cluster_replication, "applyNodeCreatePayloadKeyed") and
        @hasDecl(cluster_replication, "IdempotencyDedup"))
    {
        const a = std.testing.allocator;
        var store = try GraphStore.init(a);
        defer store.deinit();

        var dedup = cluster_replication.IdempotencyDedup.init(a);
        defer dedup.deinit();

        const labels = [_][]const u8{"Retry1"};
        const props = [_]Prop{.{ .key = "v", .value = .{ .Int = 1 } }};

        // The client's first attempt: committed at raft index N=2, then the client
        // saw a Timeout (committed-but-unknown) and RETRIED with the SAME key.
        const key = "client-req-abc-123";
        const payload = try cluster_replication.serializeNodeCreateKeyed(a, "default", &labels, &props, key);
        defer a.free(payload);

        // First apply at index 2 — normal create + record (key → index 2).
        _ = try cluster_replication.applyNodeCreatePayloadKeyed(a, &store, payload, 2, &dedup);
        try std.testing.expectEqual(@as(usize, 1), countLabel(&store, "default", "Retry1"));

        // The RETRY: the leader re-proposed the same logical write, so it lands at
        // a NEW raft index 3. SAME key → MUST be a no-op (NOT a second row).
        _ = try cluster_replication.applyNodeCreatePayloadKeyed(a, &store, payload, 3, &dedup);

        // RED on unfixed code: index-only dedup mints a 2nd id at index 3 → count==2.
        try std.testing.expectEqual(@as(usize, 1), countLabel(&store, "default", "Retry1"));

        // The single surviving node carries the property exactly once.
        var ids = try store.getNodesByLabels(a, "default", &labels, null);
        defer ids.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), ids.items.len);
        const v = (try store.getNodePropertyOrError(ids.items[0], "v")) orelse return error.MissingProperty;
        try std.testing.expectEqual(@as(i64, 1), v.Int);
    } else {
        return error.IdempotencyKeyDedupNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-3.2) RESTART REPLAY GUARD: same key at the SAME raft index (a restarted
// node replaying its committed log) stays the normal idempotent path — one node.
// This must hold post-fix too: the key dedup must not break same-index replay.
// ---------------------------------------------------------------------------
test "RC-3 replay: same idempotency key at the same raft index stays idempotent" {
    if (comptime @hasDecl(cluster_replication, "serializeNodeCreateKeyed") and
        @hasDecl(cluster_replication, "applyNodeCreatePayloadKeyed") and
        @hasDecl(cluster_replication, "IdempotencyDedup"))
    {
        const a = std.testing.allocator;
        var store = try GraphStore.init(a);
        defer store.deinit();

        var dedup = cluster_replication.IdempotencyDedup.init(a);
        defer dedup.deinit();

        const labels = [_][]const u8{"Replay1"};
        const props = [_]Prop{.{ .key = "v", .value = .{ .Int = 7 } }};
        const payload = try cluster_replication.serializeNodeCreateKeyed(a, "default", &labels, &props, "k-replay");
        defer a.free(payload);

        // Apply the SAME committed entry (same raft index 5) twice — restart replay.
        _ = try cluster_replication.applyNodeCreatePayloadKeyed(a, &store, payload, 5, &dedup);
        _ = try cluster_replication.applyNodeCreatePayloadKeyed(a, &store, payload, 5, &dedup);

        try std.testing.expectEqual(@as(usize, 1), countLabel(&store, "default", "Replay1"));
    } else {
        return error.IdempotencyKeyDedupNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-3.3) NO OVER-DEDUP GUARD: two DIFFERENT idempotency keys are two distinct
// logical writes — they must yield TWO nodes even at different indices. The fix
// must dedup by KEY, never collapse genuinely distinct writes.
// ---------------------------------------------------------------------------
test "RC-3 distinct keys: two different idempotency keys yield two distinct nodes" {
    if (comptime @hasDecl(cluster_replication, "serializeNodeCreateKeyed") and
        @hasDecl(cluster_replication, "applyNodeCreatePayloadKeyed") and
        @hasDecl(cluster_replication, "IdempotencyDedup"))
    {
        const a = std.testing.allocator;
        var store = try GraphStore.init(a);
        defer store.deinit();

        var dedup = cluster_replication.IdempotencyDedup.init(a);
        defer dedup.deinit();

        const labels = [_][]const u8{"Distinct1"};
        const p0 = try cluster_replication.serializeNodeCreateKeyed(a, "default", &labels, &.{
            .{ .key = "v", .value = .{ .Int = 1 } },
        }, "key-A");
        defer a.free(p0);
        const p1 = try cluster_replication.serializeNodeCreateKeyed(a, "default", &labels, &.{
            .{ .key = "v", .value = .{ .Int = 2 } },
        }, "key-B");
        defer a.free(p1);

        const id0 = try cluster_replication.applyNodeCreatePayloadKeyed(a, &store, p0, 2, &dedup);
        const id1 = try cluster_replication.applyNodeCreatePayloadKeyed(a, &store, p1, 3, &dedup);

        try std.testing.expect(id0 != id1);
        try std.testing.expectEqual(@as(usize, 2), countLabel(&store, "default", "Distinct1"));
    } else {
        return error.IdempotencyKeyDedupNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-3.4) GNC2 MULTI-CREATE retry: a retried edge-create (2 nodes + 1 edge)
// carrying the SAME key, applied at a different raft index, must NOT duplicate
// nodes or edges. The GNC2 id band is derived from raft_index, so the unfixed
// path mints a whole new node/edge band on retry → duplicate subgraph (RED).
// ---------------------------------------------------------------------------
test "RC-3 GNC2 retry: same idempotency key edge-create at different indices yields no duplicates" {
    if (comptime @hasDecl(cluster_replication, "serializeMultiCreateKeyed") and
        @hasDecl(cluster_replication, "applyMultiCreatePayloadKeyed") and
        @hasDecl(cluster_replication, "IdempotencyDedup"))
    {
        const a = std.testing.allocator;
        var store = try GraphStore.init(a);
        defer store.deinit();

        var dedup = cluster_replication.IdempotencyDedup.init(a);
        defer dedup.deinit();

        const la = [_][]const u8{"GNC2Retry"};
        const nodes = [_]NodeSpec{
            .{ .labels = &la, .props = &.{.{ .key = "k", .value = .{ .Int = 1 } }} },
            .{ .labels = &la, .props = &.{.{ .key = "k", .value = .{ .Int = 2 } }} },
        };
        const edges = [_]EdgeSpec{
            .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "LINKS", .props = &.{} },
        };
        const payload = try cluster_replication.serializeMultiCreateKeyed(a, "default", &nodes, &edges, "multi-key-xyz");
        defer a.free(payload);

        // First commit at index 10; client Timeout → retry re-proposes at index 11.
        _ = try cluster_replication.applyMultiCreatePayloadKeyed(a, &store, payload, 10, &dedup);
        _ = try cluster_replication.applyMultiCreatePayloadKeyed(a, &store, payload, 11, &dedup);

        // RED on unfixed code: the retry mints a fresh GNC2 band at index 11 →
        // 4 nodes + 2 edges. Must remain exactly 2 nodes + 1 edge.
        try std.testing.expectEqual(@as(usize, 2), countLabel(&store, "default", "GNC2Retry"));
        try std.testing.expectEqual(@as(usize, 1), store.edges.count());
    } else {
        return error.IdempotencyKeyDedupNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-3.5) BACKWARD-COMPAT CODEC GUARD: an OLD keyless payload (produced by the
// existing serializeNodeCreate) must STILL decode and apply through the keyed
// apply path EXACTLY as today — index-keyed only, no key recorded. This pins the
// mixed-version wire contract: a node running the fixed code must keep applying
// keyless entries already committed in the log. RED until the keyed apply path
// exists (then it must accept the legacy payload).
// ---------------------------------------------------------------------------
test "RC-3 compat: a legacy keyless payload decodes and applies through the keyed path" {
    if (comptime @hasDecl(cluster_replication, "applyNodeCreatePayloadKeyed") and
        @hasDecl(cluster_replication, "IdempotencyDedup"))
    {
        const a = std.testing.allocator;
        var store = try GraphStore.init(a);
        defer store.deinit();

        var dedup = cluster_replication.IdempotencyDedup.init(a);
        defer dedup.deinit();

        const labels = [_][]const u8{"Legacy1"};
        // Old encoding: the EXISTING keyless serializer — no key field at all.
        const legacy = try cluster_replication.serializeNodeCreate(a, "default", &labels, &.{
            .{ .key = "v", .value = .{ .Int = 99 } },
        });
        defer a.free(legacy);

        // The keyed apply path must accept the legacy payload and behave exactly
        // like applyNodeCreatePayload: id == raft_index, idempotent on same index.
        const id = try cluster_replication.applyNodeCreatePayloadKeyed(a, &store, legacy, 4, &dedup);
        try std.testing.expectEqual(@as(u64, 4), id);
        try std.testing.expectEqual(@as(usize, 1), countLabel(&store, "default", "Legacy1"));

        // Same legacy payload at the SAME index again → index-keyed no-op (NodeAlreadyExists).
        _ = try cluster_replication.applyNodeCreatePayloadKeyed(a, &store, legacy, 4, &dedup);
        try std.testing.expectEqual(@as(usize, 1), countLabel(&store, "default", "Legacy1"));

        const v = (try store.getNodePropertyOrError(4, "v")) orelse return error.MissingProperty;
        try std.testing.expectEqual(@as(i64, 99), v.Int);
    } else {
        return error.IdempotencyKeyDedupNotImplemented;
    }
}

// ---------------------------------------------------------------------------
// (RC-3.6) CODEC ROUND-TRIP: a keyed payload's idempotency key survives
// serialize → decode. The fixer must expose a way to read the key back from a
// payload (an accessor or a public decode struct) so the apply path can consult
// the dedup table. We probe the most likely accessor; if absent we still pin the
// round-trip indirectly via the dedup behavior tests above, but a direct key
// round-trip catches a codec-level key-corruption bug early.
// ---------------------------------------------------------------------------
test "RC-3 codec: a keyed payload round-trips its idempotency key" {
    if (comptime @hasDecl(cluster_replication, "serializeNodeCreateKeyed") and
        @hasDecl(cluster_replication, "idempotencyKeyOf"))
    {
        const a = std.testing.allocator;
        const labels = [_][]const u8{"K"};
        const key = "round-trip-key-7"; // gitleaks:allow — test fixture, not a secret
        const payload = try cluster_replication.serializeNodeCreateKeyed(a, "default", &labels, &.{}, key);
        defer a.free(payload);

        // The decoded key must equal what we encoded (a present key).
        const got = cluster_replication.idempotencyKeyOf(payload);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings(key, got.?);

        // A keyless legacy payload must report NO key (null), proving the codec
        // distinguishes "no key" from "empty key".
        const legacy = try cluster_replication.serializeNodeCreate(a, "default", &labels, &.{});
        defer a.free(legacy);
        try std.testing.expect(cluster_replication.idempotencyKeyOf(legacy) == null);
    } else {
        return error.IdempotencyKeyAccessorNotImplemented;
    }
}
